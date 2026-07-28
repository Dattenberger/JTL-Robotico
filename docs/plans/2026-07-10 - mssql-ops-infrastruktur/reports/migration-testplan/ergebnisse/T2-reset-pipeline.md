---
date: 2026-07-27
author: Ausführungs-Agent T2 (Reset-Pipeline E2E)
status: Ergebnisbericht — ausgeführt gegen robotico-e2e-mssql
context: Ausführung des Testplans T2-reset-pipeline.md gegen den lokalen Wegwerf-Container.
related: ../T2-reset-pipeline.md
---

# T2 — Reset-Pipeline E2E: Ergebnisse

- **Datum:** 2026-07-27, ~21:48–22:45 (UTC+2)
- **Container:** `robotico-e2e-mssql` @ `localhost,14330`, SQL Server 2025 **Developer Edition**, MachineName `3c2b38585482`, SQL-Auth `sa`, Env E2E. Guard `_e2e_guard.sql` bei jedem Write grün (kein Fehlalarm, kein PROD-/TEST-Kontakt).
- **Backup:** `/var/opt/mssql/backup/eb.bak` (getrimmt, 1.77 GB / ~1.16 Mio Pages). tConfig `BackupFile` wurde auf diesen Pfad repointet — der Seed zeigte auf das nicht existente `/var/opt/mssql/backups/eazybusiness_to_test.bak`. `BackupFile`/`TargetDataDir` bleiben am Ende bewusst auf den funktionsfähigen Container-Pfaden (T3 teilt die Umgebung und braucht lauffähige Resets).
- **Happy-Path-Login:** Wegwerf-Login `dev_e2e` statt `sa` — Begründung siehe Finding **F-2** (T2-32). Am Ende gedroppt.
- **Speed-Optimierung:** Nach dem Nachweis des vollen 8-Step-Laufs inkl. Anonymisierung P1–P11 (T2-01 Agent-Pfad + T2-02 synchron) wurde für die strukturellen Fehler-/WARN-Tests der Anonymisierungs-Step (`spInternal_AnonymizeCustomerData`, ~5 min über echte Daten) temporär `bEnabled=0` gesetzt (Pipeline-Laufzeit dann ~35 s statt ~6 min). Diese Fälle prüfen Orchestrator/GrantAccess/Register — die Anon-Präsenz ist dafür irrelevant. Am Ende wieder `bEnabled=1` (verifiziert).

## Gesamtergebnis

| Klasse | Fälle |
|---|---|
| **PASS** (inkl. THROW-OK, CHECK-OK) | T2-01, 02, 10–21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 33, 40, 41, 42, 43, 44, 50, 51, 52, 56, 57, 70, 71, 72, 73, 74, 80, 81, 82 |
| **FINDING** (PASS-erwartet, aber FAIL/Abweichung) | **F-1** = T2-54 + T2-55; **F-2** = T2-32; **F-3** = Umgebung (Agent-Pfad-Voraussetzung, repariert) |
| **RUNTIME-OPEN / inconclusive** | T2-53, T2-60 |

Zähler: **PASS 44**, **FINDING 3** (betrifft T2-32/54/55 + Umgebung), **RUNTIME-OPEN 2**. Beide vollen Pipelines (Agent + synchron) succeeded; Klon-Restore sauber; Backslash-Pfad tolerant.

## Findings

### F-1 (T2-54, T2-55) — `reset.spPub_CancelResetRequest` running-Branch unbenutzbar (Migration-Bug)
Die „läuft der Job?"-Probe im running-Zweig joint `msdb.dbo.syssessions` (und `sysjobactivity`). `jobstartuser` ist in msdb ausschließlich Mitglied von `SQLAgentOperatorRole` (up/0010) — diese Rolle besitzt **kein SELECT auf `syssessions`**, und kein `permissions/`- oder `up/`-Skript vergibt es. Folge: der Cancel eines **running**-Requests scheitert mit
> Msg 229 — „The SELECT permission was denied on the object 'syssessions', database 'msdb', schema 'dbo'."

BEVOR entweder **THROW 51007** (aktiver Job, T2-55) oder der **Force-Reclaim** (kein aktiver Job, T2-54) erreicht werden kann. Beide Nachweisziele des Plans sind damit unerreichbar. Der Gap steckt in der **Migration selbst** (Berechtigungsmodell), nicht im Container → manifestiert sich identisch auf test1/prod. Verifiziert einmal live gegen einen echten laufenden Agent-Job (T2-55) und einmal gegen eine manuell gesetzte `running`-Row ohne aktiven Job (T2-54) — beide Male 229. Der `queued`-Cancel (T2-52) ist NICHT betroffen (kein msdb-Zugriff, reines ownership-chaining auf `ops.*`).
**Empfehlung:** `GRANT SELECT ON msdb.dbo.syssessions` (und ggf. `sysjobactivity`) an `jobstartuser` in up/0010 ergänzen, oder die Probe auf eine für `SQLAgentOperatorRole` lesbare Quelle umstellen. Regressionstest ergänzen.

### F-2 (T2-32) — GrantAccess scheitert am Spezial-Prinzipal `sa`
Mit `cLoginName='sa'` geht `spInternal_GrantAccess` in den ELSE-Zweig (sa existiert als Server-Login) und führt im Klon `CREATE USER [sa] FOR LOGIN [sa]` aus →
> Msg 15405/… — „Cannot use the special principal 'sa'."

GrantAccess ist `bCritical=1` → **der ganze Reset schlägt in Step 6 fehl** (verifiziert: erster T2-01-Versuch mit `sa` endete `failed` an GrantAccess). Ein als `sa` registrierter Mandant ist damit nicht resetbar. Real-World-Relevanz gering (sa ist nie der Dev-Login), aber Robustheits-Lücke; korrigiert außerdem die Plan-/Brief-Annahme, `@LoginName='sa'` liefere „access: sa is db_owner". Happy-Path daher mit `dev_e2e` gefahren.
**Empfehlung:** in GrantAccess Spezial-Prinzipale (`sa`, `dbo`, `IS_SRVROLEMEMBER`/`sysname`-Blacklist) abfangen und als `access-skipped`-WARN behandeln statt hart zu werfen.

### F-3 (Umgebung, Agent-Pfad-Voraussetzung) — Zertifikats-Divergenz master ↔ RoboticoOps (repariert)
Zu Beginn war die msdb-Überquerung gebrochen: die signierten Procs trugen die RoboticoOps-Cert-Signatur (Thumbprint `3B25…`), der `AUTHENTICATE SERVER`-Login `RoboticoOpsSigningLogin` in **master** war aber an eine ältere, divergente Cert-Kopie (`7FC4…`) gebunden → `spPub_StartTestmandantReset` scheiterte mit „EXECUTE permission was denied on sp_start_job". Ursache: `up/0011` ist journaled (one-time) + `IF NOT EXISTS` — nach einem RoboticoOps-Rebuild (neue Cert `3B25`) wird die in master persistierte alte Cert+Login **nicht** nachgezogen. Ein normaler `db:deploy:e2e:global` heilt das NICHT (900 re-signiert nur die Procs in RoboticoOps und fasst master nicht an). **Repariert** durch Re-Kopie des aktuellen RoboticoOps-Public-Keys nach master + Neuanlage des Logins (mirror up/0011 Schritt 2+3); danach Agent-Pfad grün. In prod/test1 werden master und RoboticoOps gemeinsam aufgebaut → dort kein Problem; im **Container-Reuse-Szenario** aber eine reale Falle (Hinweis für T5/Setup: bei RoboticoOps-Rebuild die master-Cert mitziehen).

## Fall-Tabelle

| ID | Erwartet | Ergebnis | Status |
|---|---|---|---|
| **T2-01** | Agent-Pfad, voller 8-Step, succeeded | succeeded (nach F-3-Fix), alle 8 Steps, Klon ONLINE/MULTI_USER/SIMPLE/TRUSTWORTHY OFF, dev_e2e db_owner, register kMandant=6, JTL_Reader/Writer | **PASS** |
| **T2-02** | Synchroner Pfad, identisch succeeded, Applock frei | succeeded, alle 8 Steps, Applock in Fremd-Session=1 (frei), kein Doppel-Klon | **PASS** |
| T2-10 | THROW 51010 | 51010 | PASS |
| T2-11 | 51011 (SourceDb-Key weg) | failed, „…missing SourceDb/BackupFile/TargetDataDir" | PASS |
| T2-12 | 51012 (SourceDb nicht existent) | failed, „source database does not exist" | PASS |
| T2-13 | 51014 (Source==Target) | failed, „source and target are the same database" | PASS |
| T2-14 | 51020 | 51020 | PASS |
| T2-15 | 51030 | 51030 | PASS |
| T2-16 | 51040 | 51040 | PASS |
| T2-17 | 51050 | 51050 | PASS |
| T2-18 | 51060 | 51060 | PASS |
| T2-19 | 51070 | 51070 | PASS |
| T2-20 | 51071 (Register displayname leer, kritisch) | failed, „…cDisplayName is empty." | PASS |
| T2-21 | 51080 | 51080 | PASS |
| T2-22 | 51003 nur über Umweg (durch CHECK vorverlagert) | Deklarativ durch CK_tMandant_cTargetDb geblockt (s. T2-26); 51003 = Defense-in-Depth-Backstop, normal nicht erreichbar | PASS (by design) |
| T2-23 | 51002 (unbekannter Key) | 51002 | PASS |
| T2-24 | 51005 (bad whitelist step), failed | failed, „…references an unknown reset.spInternal_ procedure" | PASS |
| T2-25 | failed, re-validation, kein THROW | failed, „re-validation failed: target is not a registered test-mandant clone" | PASS |
| T2-26 | CHECK CK_tMandant_cTargetDb | Msg 547 CHECK-Verletzung | PASS |
| T2-27 | CHECK CK_tMandant_cMandantKey | Msg 547 CHECK-Verletzung | PASS |
| T2-28 | CHECK CK_tResetStep_cProcName | Msg 547 CHECK-Verletzung | PASS |
| T2-29 | Unique-Index IX_tResetRequest_Active | Msg 2601 „duplicate key … IX_tResetRequest_Active … (eazybusiness_tm9)" | PASS |
| T2-30 | 51093/51094/51090/51091/51092 | alle 5 exakt (dup-key/dup-db/leer/badkey/prodtarget) | PASS |
| T2-31 | succeeded + WARN access-skipped | succeeded, StepLog „WARN access-skipped: login dbuser_dev_dana_for_development … NO db_owner" | PASS |
| **T2-32** | „access: sa is db_owner" | **FAIL** — CREATE USER [sa] scheitert (special principal), Reset failed Step 6 | **FINDING F-2** |
| T2-33 | JTL-Rollen trotz fehlender AD-Member, succeeded | AD-Logins abwesend (0), JTL_Reader/Writer im Klon angelegt, fehlende Member übersprungen, Step succeeded | PASS |
| T2-40 | succeeded trotz Register-Fehler (non-critical WARN) | succeeded, StepLog „WARN spInternal_RegisterMandant: … cDisplayName is empty.", Folge-Step ApplyJtlRoles lief danach | PASS |
| T2-41 | kein Secret-Leak in err/log | failed (51071), canary_in_err=none, canary_in_log=none — kein Leak | PASS (harter Data-Echo-Nachweis bleibt runtime-open, s.u.) |
| T2-42 | failed, kein Klon (Windows-Pfade) | failed, xp_create_subdir „Access is denied"/„BACKUP DATABASE is terminating abnormally", clone_exists=no | PASS |
| T2-43 | RESTORING-Leiche gedroppt, Selbstheilung | Restore-Session mid-flight gekillt (pct 0.23%) → Klon in RESTORING, Row stuck running; Folgelauf: StepLog „clone: target … found in state RESTORING (leftover from a dead run) — dropping it before restore" → Neu-Restore succeeded | PASS |
| T2-44 | Cursor-Cleanup, kein 16915 im 2. Request | tm9 (1.) failed kritisch an Register, tm8 (2.) succeeded — **kein** 16915 | PASS |
| T2-50 | stale reclaim → failed | failed, „stale running request reclaimed (job likely restarted)" | PASS |
| T2-51 | stale fallback 4h (Knob fehlt) | failed, reclaimed=yes (ISNULL/TRY_CONVERT-Fallback 4h greift) | PASS |
| T2-52 | cancel queued → failed | failed, cErrorMessage „cancelled by sa (was queued)", Note „cancelled (was queued)" | PASS |
| T2-53 | Cancel-Race (Doku) | deterministisch nicht erzwingbar; guarded UPDATE (`WHERE cStatus='queued'`) ist der Race-Schutz (code-belegt) | RUNTIME-OPEN |
| **T2-54** | force-reclaim (inaktiver Job) | **FAIL** — Msg 229 syssessions denied vor Force-Reclaim | **FINDING F-1** |
| **T2-55** | THROW 51007 (aktiver Job) | **FAIL** — Msg 229 syssessions denied vor 51007 (live gegen laufenden Job) | **FINDING F-1** |
| T2-56 | 51006 / 51008 / WhatIf-DryRun | 51006 (unbekannt), 51008 (Keep=0), WhatIf lief (nur Count) | PASS |
| T2-57 | Dedup: gleiche kResetRequest | 2. Start lieferte dieselbe id (=3) + Status, kein neuer Request (live gegen in-flight) | PASS |
| T2-60 | Agent-down 22022-Schluck | Agent nicht gestoppt (Risiko/Brief) — Hypothese dokumentiert, Code bestätigt Schluck | RUNTIME-OPEN |
| T2-70 | Signatur überlebt Re-Deploy | Idempotenter Re-Deploy: Signaturen intakt. Zusätzlich: `DROP SIGNATURE` → Re-Deploy → 900 re-signiert (Signatur wieder da), Deploy grün, kein 50900/50901 | PASS |
| T2-71 | 50901 falsches Cert-PW | Deploy bricht sicher ab — als grate **`OneTimeScriptChanged` auf 0011** (Token wird VOR dem Hash substituiert), exit≠0. 50901 wird durch den Hash-Guard verschattet (deckt sich mit T1-SP-5). Kein Teil-Re-Sign. | PASS |
| T2-72 | 250 Orphan-Remap | jobstartuser gedroppt+neu (neue SID) → msdb+ops User ORPHAN, Start scheitert (15517, ≠22022). Deploy → 250 remappt beide (ORPHAN→mapped), grün. | PASS |
| T2-73 | 50010 Deploy-Guard aktiver Request | queued-Row + Job gelöscht → Deploy → 200 ruft spEnsureAgentJob → **THROW 50010** „a reset request is queued or running…", grate exit 1, Job NICHT recreated. Nach Request-Terminierung Deploy grün, Job wieder da. | PASS |
| T2-74 | EXPIRY '29991231' unter dmy ok | `SET LANGUAGE deutsch` + CREATE CERTIFICATE … EXPIRY_DATE='29991231' → OK, kein Fehler 190 | PASS |
| T2-80 | beide Job-Familien koexistieren | Nach global-Deploy: Reset-Job + 6 `RoboticoOps - Maint - *` in sysjobs; idempotenter Re-Deploy: 0 Änderungen (Job-IDs stabil) | PASS |
| T2-81 | 50010 blockt auch Wartung | Mechanik via T2-73 belegt: 50010 feuert im permissions-Stage (200) und bricht den GESAMTEN global-Chain ab. Da 200 NACH den maint-Stages (sprocs/up) läuft, wäre eine mitgebündelte Wartungsänderung bereits committed, bevor 50010 abbricht (keine umschließende Ebene-B-Transaktion) — reihenfolgeabhängig, dokumentiert; nicht separat mit Datei-Hash-Änderung erzwungen. | PASS (Mechanik belegt) |
| T2-82 | Reset ∥ Wartung ohne Verklemmung | Phase B (Schalter unset → 6 Maint-Jobs enabled). Reset (Agent, tm9) gestartet, während `running` Maint-Job `backup-watchdog` parallel gestartet: beide liefen unabhängig, **kein Blocking** (blocking_session_id leer), Reset **succeeded**, kein Abbruch durch Wartung. Danach Phase A wiederhergestellt (Schalter='0', Maint-Jobs disabled). | PASS |

## Evidenz-Details

### T2-01 (Agent-Pfad) — voller StepLog
```
starting step 1: spInternal_CloneDatabase
clone: backup+restore eazybusiness -> eazybusiness_tm9 ok
starting step 2: spInternal_PostRestoreSecurity
security: owner=sa, orphans remapped/cleaned, TRUSTWORTHY OFF
starting step 3: spInternal_InvalidateCredentials
credentials: cleared + JS-Shop repointed to staging (1 row(s))
starting step 4: spInternal_NeutralizeWorker
worker: pf_user locked + auth tokens cleared, queues emptied (Worker.tTarget untouched)
starting step 5: spInternal_AnonymizeCustomerData
anon.P1 core-person ok ... anon.P11 pos ok   (~5 min über echte Daten)
starting step 6: spInternal_GrantAccess
access: dev_e2e is db_owner on eazybusiness_tm9
starting step 7: spInternal_RegisterMandant
register: kMandant=6 (T2 E2E validation)
starting step 8: spInternal_ApplyJtlRoles
roles: JTL_Reader/JTL_Writer ensured + members applied
```
- Klon `eazybusiness_tm9`: ONLINE, MULTI_USER, RECOVERY SIMPLE, TRUSTWORTHY=OFF; dev_e2e db_owner (im Klon-Kontext geprüft); JTL_Reader/JTL_Writer vorhanden; Registrierung in `eazybusiness.dbo.tMandant` UND `eazybusiness_tm9.dbo.tMandant`.
- **Backslash-in-Linux-Pfad (offene Frage 2): RESOLVED.** `sys.master_files.physical_name` = `/var/opt/mssql/data\eazybusiness_tm9_eazybusiness.mdf` (gemischter Separator), physisch aber korrekt unter `/var/opt/mssql/data/eazybusiness_tm9_eazybusiness.mdf` (per `ls` im Container bestätigt). SQL Server on Linux normalisiert den Backslash beim FS-Write; Katalog trägt den Literal-Mischpfad (rein kosmetisch). Klon restauriert sauber.

### T2-02 (synchroner Pfad)
succeeded, identischer 8-Step-Log (register kMandant=7). `EXEC reset.spProcessNextResetRequest` blockierte bis fertig (~6 min inkl. Anon) und kehrte sauber zurück; `APPLOCK_TEST('public','reset:pipeline','Exclusive','Session')` in Fremd-Session = **1 (frei)** → kein Applock-Leak. Kein Doppel-Klon. Beweist: Pipeline ohne Agent voll lauffähig (empfohlener Container-Default, umgeht die Signaturkette komplett).

### T2-41 (Secret-Scrubbing) — Hinweis
`cShopLicense='SECRET-LEAK-CANARY-4711'`, danach kritischer Fehlschlag an RegisterMandant (51071). Weder `cErrorMessage` noch `cStepLog` enthalten den Canary. **Aber:** die 51071-Meldung echot den Lizenzwert ohnehin nicht → der REPLACE ist trivially grün. Der harte Nachweis (echtes Data-Echo im Engine-Fehlertext, z.B. Truncation 2628, das den Wert zitiert) bleibt **runtime-open** — wie im Plan §7 Punkt 3 vermerkt.

### T2-60 (Agent-down) — RUNTIME-OPEN, Hypothese
Der SQL-Agent wurde bewusst NICHT gestoppt (Brief: Risiko, Folge-Topics brauchen ihn; kein sauberer Stop/Restart im laufenden Container ohne Recreate). **Hypothese (Code-belegt):** `sp_start_job` liefert bei gestopptem Agent 22022; `spPub_StartTestmandantReset` prüft in seinem inneren CATCH nur `ERROR_NUMBER() <> 22022` (Start.sql:90) und schluckt jede 22022 als „job already running" → die Row bliebe still `queued`, niemand verarbeitet sie. Der **synchrone Pfad (T2-02)** ist der belegte Workaround. Empfehlung (falls bestätigt): Text-/Zustandsprüfung statt reiner `ERROR_NUMBER()`-Gleichheit → Folge-Ticket.

## Endzustand der Umgebung (wiederhergestellt)

`db:validate:e2e` = **grün** (validate_structure OK, validate_rollout OK, Consumer-Roundtrip OK).

- Klone `eazybusiness_tm8/tm9` gedroppt; keine `eazybusiness_*`-Klon-DBs vorhanden.
- `ops.tMandant`: nur Seeds tm2/tm3/tm4; tm8/tm9 + deren Klon-Registrierungen in `eazybusiness.dbo.tMandant` entfernt.
- `ops.tResetRequest`: 0 offene (queued/running) Requests.
- `ops.tResetStep`: alle 8 Steps `bEnabled=1`, `bCritical=1`; Test-Step `spInternal_DoesNotExist` entfernt; Anonymisierung wieder aktiv.
- `ops.tConfig`: `SourceDb=eazybusiness`, `StaleRunningHours=4`, `MaintenanceSchedulesEnabled='0'`, `BackupFile=/var/opt/mssql/backup/eb.bak`, `TargetDataDir=/var/opt/mssql/data` (funktionsfähige Container-Pfade — bewusst NICHT auf den kaputten Seed-Pfad zurückgesetzt, damit T3 resetten kann).
- Maint-Jobs: alle 6 `disabled` (Phase-A-Baseline für T3).
- `jobstartuser`-Login: nach T2-72 re-mapped + `DENY CONNECT SQL` wiederhergestellt (validate grün).
- master-Cert `RoboticoOpsSigning` = RoboticoOps-Cert (`3B25…`), Signaturen intakt (F-3-Fix); Wegwerf-Login `dev_e2e` gedroppt.
