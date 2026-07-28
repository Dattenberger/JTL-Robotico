# Teilrecherche: Reset-Pipeline — Fehlerfall-Analyse

> Rohbefund eines delegierten Research-Agenten (2026-07-27), unverändert übernommen.
> Eingang für `00-grundrecherche.md` (Konsolidierung durch den Lead-Agenten).

## 1. Pipeline End-to-End (kurz)

1. **`reset.spPub_StartTestmandantReset @MandantKey`** (signiert, `EXECUTE AS 'jobstartuser'`): applock `reset:<MandantKey>`, Validierung gegen `ops.tMandant` (THROW 51002/51003), Dedup laufender Requests (OPS-6: gibt existierende kResetRequest zurück statt Fehler), INSERT `ops.tResetRequest` (`queued`), dann `msdb.dbo.sp_start_job` (Jobname aus `ops.tConfig('AgentJobName')`). — `sprocs/reset.spPub_StartTestmandantReset.sql`
2. **Agent-Job "RoboticoOps - Testmandant Reset"** (Owner sa, ein T-SQL-Step in DB RoboticoOps, kein Schedule): `EXEC reset.spProcessNextResetRequest` — angelegt durch `runAfterOtherAnyTimeScripts/reset.spEnsureAgentJob.sql:62-87`, Existenz-Self-Heal in `permissions/200_ensure_agent_job.sql`.
3. **`reset.spProcessNextResetRequest`**: exklusiver Session-Applock `reset:pipeline` (Timeout 0, zweite Instanz kehrt still zurück, Z. 40-44); Stale-Reclaim (Z. 54-60); Claim-Loop mit UPDLOCK/READPAST (Z. 80-97); Re-Validierung der Zeile (Z. 102-113); dann datengetriebene Step-Schleife über `ops.tResetStep` (bEnabled, ORDER BY nStepOrder) mit Katalog-Whitelist (Z. 139-146, THROW 51005) und einheitlichem Kontrakt `(@TargetDb,@RequestId,@MandantKey)`.
4. **Default-Steps** (Seed `up/0021:70-77`): CloneDatabase (10) → PostRestoreSecurity (20) → InvalidateCredentials (30) → NeutralizeWorker (40) → AnonymizeCustomerData (50) → GrantAccess (60) → RegisterMandant (70) → ApplyJtlRoles (80). Jeder Step loggt via `spInternal_LogStep` in `cStepLog`; Ergebnis `succeeded`/`failed` mit Status-Guard gegen Cancel-Races (B4, Z. 182-187/223-231).

## 2. Sicherheits-/Signaturmodell

- **Zertifikat** `RoboticoOpsSigning` mit Private Key (Passwort = grate-Token `{{CertPassword}}`) in RoboticoOps; Public Key via `CERTENCODED` als Binärliteral nach master kopiert; Login `RoboticoOpsSigningLogin` FROM CERTIFICATE mit `AUTHENTICATE SERVER` (`up/0011:38-68`). Das trägt den impersonierten Kontext über die RoboticoOps→msdb-Grenze ohne TRUSTWORTHY.
- **Signierte Prozeduren**: katalog-getrieben genau die mit `execute_as_principal_id = jobstartuser` — aktuell `spPub_StartTestmandantReset` und `spPub_CancelResetRequest`. `CREATE OR ALTER` strippt die Signatur; `permissions/900_resign_procedures.sql:23-65` signiert everytime nach, THROW 50901 bei falschem `{{CertPassword}}`, Hard-Fail 50900 wenn danach noch etwas unsigniert ist (Z. 70-87).
- **`jobstartuser`** (`up/0010`): Server-Login mit CSPRNG-Passwort, sofort DISABLED + `DENY CONNECT SQL` (via master-Kontext, Z. 44-48); DB-User in RoboticoOps (EXECUTE-AS-Ziel) und in msdb mit `SQLAgentOperatorRole` + EXECUTE auf `sp_start_job` (Z. 57-69). Operator-Rolle nötig, weil der Job sa-owned ist.
- **`ops.*`-Zugriff** in den signierten Procs via Ownership Chaining (Schemas `ops`/`reset` AUTHORIZATION dbo, `up/0002:22-28`); `ORIGINAL_LOGIN()` protokolliert den echten Aufrufer.
- **250_jobstartuser_mapping.sql** (untracked, everytime): heilt verwaiste `jobstartuser`-DB-User in msdb und RoboticoOps per `ALTER USER ... WITH LOGIN` nach einem Teardown/Redeploy des Logins (frische SID). Ohne das schlägt `sp_start_job` mit Permission-Denied fehl (Dress-Rehearsal-Finding, Kommentar Z. 5-18).
- **Die Pipeline-Steps selbst sind unsigniert** — Privileg kommt vom Job-Owner sa (Agent-Service-Account, sysadmin), `spProcessNextResetRequest.sql:1-5`.

## 3. Fehlerfall-Katalog (Container-Testfälle)

### 3a. Clone-Guard / THROW-Codes

Jeder Step + Entry-Points prüfen `@TargetDb = 'eazybusiness' OR NOT LIKE 'eazybusiness[_]%'`:

| THROW | Ort |
|---|---|
| 51003 | Start-SP `spPub_StartTestmandantReset.sql:56-57` |
| (kein THROW — Row wird `failed`) | Orchestrator-Re-Validierung `spProcessNextResetRequest.sql:102-113` (auch: MandantKey/TargetDb-Paar nicht mehr in `ops.tMandant`) |
| 51010/51011/51012/51013/51014 | CloneDatabase Z. 27-28, 40-48, 62-64 (fehlende tConfig-Keys, Source fehlt, Source==Target, kein ROWS/LOG-File) |
| 51020/51021 | PostRestoreSecurity Z. 21-22, 89-90 (TRUSTWORTHY-Assert) |
| 51030 | InvalidateCredentials Z. 27-28 |
| 51040 | NeutralizeWorker Z. 29-30 |
| 51050 | AnonymizeCustomerData Z. 23-24 |
| 51060 | GrantAccess Z. 22-23 |
| 51070/51071 | RegisterMandant Z. 31-32, 37-38 (leerer DisplayName) |
| 51080 | ApplyJtlRoles Z. 33-34 |
| 51090–51094 | CreateTestmandant Z. 44-57 |
| 51005 | Orchestrator-Whitelist (unbekannter `spInternal_`-Name), Z. 145 |
| 51001/51002 | Start-SP Applock/unbekannter Key |
| 51006/51007/51008 | Cancel unknown / Job läuft / Purge-Param |

Deklarative Backstops: `CK_tMandant_cTargetDb` + `CK_tMandant_cMandantKey` (`up/0002:48-51`), `CK_tResetStep_cProcName` (`up/0021:47`), gefilterter Unique-Index `IX_tResetRequest_Active` (`up/0002:95-97`). Testfälle: direkter `EXEC reset.spInternal_CloneDatabase @TargetDb='eazybusiness'` (51010), INSERT in tMandant mit `cTargetDb='eazybusiness'` (CHECK), manipulierte tResetRequest-Zeile → Orchestrator markiert `failed` ohne Prod-Touch, tResetStep-Zeile mit nicht deploytem Namen (`spInternal_DoesNotExist` passiert den CHECK → 51005 zur Laufzeit).

### 3b. Teilfehlschlag in der Step-Schleife

- **Keine umschließende Transaktion** — bewusst (BACKUP/RESTORE transaktionsunfähig; halbfertiger Clone bleibt zur Diagnose), `spProcessNextResetRequest.sql:28-29`. Jedes Statement in den Steps auto-committet. D.h.: Fehlschlag in Anonymize-P5 lässt P1–P4 anonymisiert stehen; `cStepLog` zeigt die letzten "anon.P4 ... ok"-Zeilen + die "starting step N"-Zeile ohne Erfolgszeile (OPS-3, Z. 148-152).
- **bCritical=1** (Default): THROW → äußerer CATCH, Cursor-Cleanup (B2, Z. 194-203 — testenswert: Fehler außerhalb eines Steps, z.B. LogStep-Deadlock, darf nicht Folge-Requests mit Cursor-Fehler 16915 vergiften), Best-Effort `MULTI_USER` (Z. 206-214), Row → `failed` mit Status-Guard (B4). **bCritical=0**: WARN-Zeile in cStepLog, Pipeline läuft weiter (Z. 158-172). Testfall: Step-Zeile auf bCritical=0 setzen, Step künstlich fehlschlagen lassen → Request trotzdem `succeeded` mit WARN.
- **Secret-Scrubbing**: cShopLicense wird aus persistierten Fehlertexten ersetzt (Sec-I1, Z. 99, 166-171, 216-219) — Testfall mit gesetzter Lizenz + provoziertem Fehler, der den Wert echot (z.B. Truncation 2628).
- **Mid-RESTORE-Kill**: Clone bleibt in RESTORING; nächster Lauf droppt ihn (B10/I5, `CloneDatabase.sql:69-92`) — expliziter Container-Testfall (KILL der Session während RESTORE).

### 3c. Agent-Job-Abhängigkeiten

- Linux-Container: SQL Agent ist standardmäßig **deaktiviert** (`MSSQL_AGENT_ENABLED=true` bzw. `mssql-conf sqlagent.enabled` nötig). `sp_add_job`/`sp_add_jobstep`/`sp_add_jobserver` (spEnsureAgentJob:62-81) funktionieren auch mit gestopptem Agent (msdb-Katalog), der Job läuft nur nicht.
- **Verdachtsfall, im Container verifizieren**: `sp_start_job` bei nicht laufendem Agent wirft vermutlich ebenfalls Fehlernummer 22022 ("SQLServerAgent is not currently running"). `spPub_StartTestmandantReset.sql:90` behandelt **jede** 22022 als harmloses "job already running" — bei Agent-down bliebe die Row still `queued` und niemand verarbeitet sie (bis manuell). Der Code prüft nur `ERROR_NUMBER()`, nicht den Text. Muss getestet werden.
- `spPub_CancelResetRequest.sql:83-93` joint `msdb.dbo.syssessions`/`sysjobactivity`; auf einer Instanz, wo der Agent nie lief, ist `syssessions` leer → `MAX(agent_start_date)` NULL → EXISTS false → Force-Reclaim erlaubt (gewollt, aber testen).
- **Workaround für Container-Tests**: die Pipeline ist ohne Agent synchron testbar via manuellem `EXEC reset.spProcessNextResetRequest` (sysadmin-Session) — genau dafür existiert der `reset:pipeline`-Applock (B3).
- `spEnsureAgentJob` THROW 50010, wenn beim Deploy ein Request queued/running ist (Z. 43-44) — Testfall: Redeploy während Reset.
- Database Mail/NotifyOperator: leerer Config-Wert → stumm, kein Deploy-Fehler (spEnsureAgentJob:49-56) — im Container so belassen.

### 3d. StaleRunningHours-Reclaim

`spProcessNextResetRequest.sql:47-60`: Knob `ops.tConfig('StaleRunningHours')`, `ISNULL(TRY_CONVERT(int,...), 4)` — Testfälle: Key gelöscht / nicht-numerisch → Fallback 4; `running`-Row mit `dStarted` künstlich >4h zurückdatiert → beim nächsten Pipeline-Lauf `failed` mit fixem Text "stale running request reclaimed". Wichtig: Reclaim vergleicht `dStarted`, nicht `dModified` (dokumentiert in `MSSQL-OPS-DATA-MODEL.md:73`). Ein echter Langläufer wird nicht vom Parallel-Job reclaimed, weil die zweite Instanz am Applock (Timeout 0) vor dem Reclaim aussteigt (Z. 40-44) — aber eine **manuelle** Session nach Applock-Freigabe (Job tot, Session zu) reclaimed korrekt. Zusätzlich: `spPub_CancelResetRequest` als Sofort-Reclaim (nur wenn Job nicht aktiv, 51007).

### 3e. BackupFile/TargetDataDir (Windows-Pfade im Linux-Container)

Seed `up/0020:29-30`: `E:\work\eazybusiness_to_test.bak` und `E:\MSSQL\Data` — **im Container ungültig**; `xp_create_subdir` (`CloneDatabase.sql:95`) und `BACKUP TO DISK` schlagen fehl (kritischer Step → Request `failed`). Vor Tests zwingend `UPDATE ops.tConfig` auf Container-Pfade (`/var/opt/mssql/...`). Zweiter Punkt: der MOVE-Pfad wird mit Backslash gebaut (`@TargetDataDir + N'\' + ...`, Z. 56) — SQL Server on Linux normalisiert Backslashes i.d.R., aber ein gemischter Pfad `/var/opt/mssql/data\eazybusiness_tm9_...` ist explizit zu verifizieren (Testfall). Positiv: MOVE-Liste kommt aus `sys.master_files` (CQG-2, Z. 55-64), funktioniert für jedes Datei-Layout; ein einzelner BackupFile-Pfad serialisiert Resets (WITH INIT überschreibt).

### 3f. Zertifikat / Datumsliteral / Locale

`up/0011:43-47`: `EXPIRY_DATE = '29991231'` (Basic-ISO, sprachneutral) — der Fehlerfall (dashed `'2999-12-31'` + German dmy-Login → Error 190) ist bereits behoben und lint-bewacht (Regel h). Container-Testfall: Deploy mit Login, dessen Default Language German ist (`SET LANGUAGE deutsch`), muss grün bleiben. `{{CertPassword}}`: grate-Token, kein Single-Quote erlaubt (CQG-3/4, Kopfkommentar Z. 19-30); Re-Deploy mit **anderem** Passwort → 900 THROW 50901 mit erklärender Meldung. Rotation nur via DROP+neues up-Skript.

### 3g. Permission-Skripte gegen fehlende Logins

- `100_grants.sql:42-45`: AD-Gruppe `ZDBIKES\sql-jtl-users` existiert im Container nie → PRINT-Skip, Deploy grün (testen: kein Fehler, keine Membership).
- `spInternal_GrantAccess.sql:31-37`: `dbuser_dev_dana_for_development` (Seed `0020:61-63`) existiert im Container nicht → WARN-Skip, Reset `succeeded`, **niemand hat db_owner** (D4/PAR-1 — im Container-Test Login vorher anlegen oder WARN-Zeile assertieren).
- `spInternal_ApplyJtlRoles.sql:71-79`: fehlende Member-Principals werden übersprungen; Rollen JTL_Reader/Writer entstehen trotzdem.
- `250_jobstartuser_mapping.sql`: No-Op wenn SIDs stimmen; Orphan-Testfall: `DROP LOGIN jobstartuser` + Login manuell neu anlegen (neue SID; up/0010 ist journaled und läuft nicht erneut) → 250 muss re-mappen, sonst sp_start_job DENIED.

### 3h. Idempotenz eines Ketten-Re-Runs

Erwartung No-Op, mit diesen Mechanismen: up/-Skripte journaled (einmalig); `0020`-MERGE nur `WHEN NOT MATCHED` (überschreibt Admin-Korrekturen nie, Z. 38-39/66-68); `0021`-Seed cursor-basiert, keyed by cProcName, kollidierende nStepOrder → MAX+10-Fallback (QG3 B12, Z. 82-92); `0010`/`0011` IF-NOT-EXISTS (aber: `ALTER LOGIN ... DISABLE` + `DENY CONNECT` laufen immer — harmlose No-Ops); sprocs CREATE OR ALTER; `900` signiert nur Unsigniertes; `200` nur bei fehlendem Job; `250` nur bei Orphan. **Nicht-No-Op-Falle**: `reset.spEnsureAgentJob` re-executet bei Hash-Änderung → droppt/recreated den Job und THROWt 50010 bei aktivem Request. Testfall: kompletter zweiter grate-Lauf → 0 geänderte Zeilen in ops.*, Job-ID unverändert, Signaturen intakt.

### 3i. Restore alt→neu / CloneDatabase-Mechanik

- Clone ist instanz-intern (BACKUP+RESTORE derselben Version) — kein Versionsproblem. Das Versions-Thema betrifft das **Einspielen des Prod-Backups** in den Container: nur alt→neu möglich (SQL2022-Backup → SQL2025-Container ok, Rückweg unmöglich). Ein im neueren Container erzeugter Clone kann nie zurück.
- Mechanik: COPY_ONLY-BACKUP der Source (Z. 98-100), RESTORE ... WITH MOVE (alle Files aus sys.master_files, Namensschema `<TargetDataDir>\<TargetDb>_<logicalname>.mdf/.ldf`), REPLACE, danach RECOVERY SIMPLE + MULTI_USER (Z. 105-113). Testfälle: Ziel-DB existiert ONLINE (SINGLE_USER-Kickout Z. 89-91), Ziel in RESTORING (Drop-Pfad Z. 76-85), Source fehlt (51012), Multi-File-Source (zweites NDF anlegen → beide MOVEs).
- **Voraussetzung im Container**: eine echte `eazybusiness`-DB als Source. Ohne sie: 51012. Mit Minimal-Fixture statt echtem JTL-Schema brechen spätere Steps hart: `InvalidateCredentials` (Z. 42-92: tEMailEinstellung, ebay_user, tOauthConfig, tOauthToken, tShop, tShipperAccount **ungeguarded**), `NeutralizeWorker` (Z. 35: ebay_user ungeguarded), `AnonymizeCustomerData` P1 (tkunde/tinetkunde/tAdresse/trechnungsadresse ungeguarded, Z. 38-135), `RegisterMandant` (braucht dbo.tMandant/tBenutzerFirma/tBenutzer/tFirma in Source und Clone). D.h. Containertest realistisch nur mit restauriertem eazybusiness-Backup.
- **Container-Sonderfall 0001**: grate legt RoboticoOps mit der Instanz-Default-Collation an; Standard-Container = `SQL_Latin1_General_CP1_CI_AS` → **Hard-Fail THROW 50001** (`up/0001:26-35`). Container mit `MSSQL_COLLATION=Latin1_General_CI_AS` starten oder DB vorab mit COLLATE anlegen. Das ist der erste Fehler, den ein naiver Container-Deploy produziert — als expliziter Testfall (Assert greift) und als Setup-Hinweis.

## 4. Grundsätzlich nicht lauffähig vs. mit Anpassung testbar

**Nicht lauffähig im Container (auslassen / mocken):**
- Windows-/AD-Authentifizierung: `ZDBIKES\sql-jtl-users`-Membership (100_grants Skip-Pfad ist selbst der Test), AD-Member in ApplyJtlRoles, Kerberos-Login-Szenarien.
- Database-Mail-Failure-Notification (OPS-4) und Operator-Mail — konfig-gated aus.
- JTL-Worker-Interaktion (O2), WaWi-Client-Login (Runbook 4.6), Shop-/Marktplatz-Seiteneffekte.
- CBB-Backup-Kette / maint-Watchdog-Realbedingungen.
- Prod-Blast-Radius von RegisterMandant — im Container ist "prod" die lokale Source-DB, das Verhalten (Upsert in alle Mandanten-DBs, WARN bei Fehlern, CQG-5) ist aber gut simulierbar.

**Mit Anpassung testbar:**
- Gesamte Reset-Pipeline synchron via manuellem `EXEC reset.spProcessNextResetRequest`, nach `UPDATE ops.tConfig` für BackupFile/TargetDataDir auf Linux-Pfade und restauriertem eazybusiness-Backup als Source.
- sp_start_job-E2E inkl. Signaturkette (0011 + 900 + 0010 + 250), wenn der Container-Agent aktiviert wird (`MSSQL_AGENT_ENABLED=true`).
- Alle THROW-/Guard-/Idempotenz-/Reclaim-/Cancel-Fälle aus §3.
- Collation-/Locale-Fälle über Container-Env bzw. Login-Default-Language.
- `MaintenanceSchedulesEnabled` ist für den Reset irrelevant (Gate nur für maint-Jobs, D34/ADR-A D-A6); der Reset-Job hat keinen Schedule — relevant ist allein, dass der Agent-Dienst läuft.

**Offene Unsicherheiten (nur live klärbar):** (a) 22022-Verhalten bei gestopptem Agent (§3c); (b) Backslash-in-Linux-Pfad-Verhalten von RESTORE MOVE (§3e); (c) ob grate die RoboticoOps-DB im Container tatsächlich mit Instanz-Default-Collation anlegt — der 0001-Assert fängt es in jedem Fall.

Relevante Dateien: `db-migrations/global/up/0001…0021`, `db-migrations/global/sprocs/reset.*.sql`, `db-migrations/global/runAfterOtherAnyTimeScripts/reset.spEnsureAgentJob.sql`, `db-migrations/global/permissions/{100,200,250,900}*.sql`, `docs/runbooks/testmandant-reset-validierung.md`, `docs/SQL/MSSQL-OPS-DATA-MODEL.md`, `docs/SQL/MSSQL-OPS-ARCHITECTURE.md`.
