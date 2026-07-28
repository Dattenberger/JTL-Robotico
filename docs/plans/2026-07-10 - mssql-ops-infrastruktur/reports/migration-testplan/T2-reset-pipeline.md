---
date: 2026-07-27
author: Detail-Agent T2 (Reset-Pipeline E2E), Migrations-Testplan
status: Testplan — bereit zur Ausführung gegen den robotico-e2e-mssql-Container
context: Testplan für die Testmandanten-Reset-Pipeline (reset.*) E2E im Linux-Container. Deckt beide Ausführungspfade (Agent-Job + synchron), die Guard-/THROW-Matrix, Teilfehlschläge, Stale-Reclaim/Cancel, Signaturkette und die Reset↔Wartung-Koexistenz im geteilten Agent ab. KEINE Ausführung durch diesen Agent — nur Plan.
related-plan: ../../mssql-ops-infrastruktur.md
grundlage: 00-grundrecherche.md (§F2), 02-teilrecherche-reset-pipeline.md
scope-abgrenzung: Idempotenz-Zusammenspiel Ebene A/B nur referenziert (→ T1); Wartungssuite-Interna → T3; Container-/Backup-Aufbau → T5.
---

# T2 — Reset-Pipeline E2E: Testplan

> **Fehlerklassen:** F2.1–F2.9 (Grundrecherche §2). Referenzen relativ
> `db-migrations/global/` sofern nicht anders angegeben.
>
> **Sicherheits-Invariante:** Alle Tests laufen ausschließlich gegen den Container
> `robotico-e2e-mssql` (`localhost,14330`, Env `E2E`, SQL-Auth `sa`). `vm-sql2` = PROD
> = tabu; `vm-sql-test1` wird nicht berührt. Jedes Skript, das schreibt, trägt den
> **Servername-Guard** (`G0`) am Kopf.

---

## 0. Voraussetzungen & gemeinsames Setup

T5 liefert Container + getrimmtes `eazybusiness`-Backup. Dieser Plan setzt voraus:

- Container läuft (`npm run db:e2e:up`), Agent `Running`, Collation
  `Latin1_General_CI_AS` (`setup.ps1` assertet beides — sonst Teardown+Neubau).
- `MSSQL_SA_PASSWORD` in der Shell (`set -a; source db-migrations/tests/docker/.env.local; set +a`).
- Eine restaurierte, schema-vollständige `eazybusiness` (SQL ≤ 2022) im Container.
  Minimal-Fixtures reichen NICHT: InvalidateCredentials/NeutralizeWorker/Anonymize-P1/
  RegisterMandant referenzieren `tEMailEinstellung`/`ebay_user`/`tkunde`/`tAdresse`/
  `tMandant`/`tBenutzerFirma` ungeguardet (Teilrecherche §3i).
- Ebene B deployt: `npm run db:deploy:e2e:global` (grün — inkl. Collation-Assert 50001,
  Zertifikat, `jobstartuser`, Agent-Job, `900`-Signatur, `250`-Remap).
- Ebene A deployt auf `eazybusiness`: `npm run db:deploy:e2e` (Robotico-Journal reist
  ohnehin im Klon mit).

Alle SQL-Snippets werden per `sqlcmd` gegen `localhost,14330` (SQL-Auth) ausgeführt,
sofern nicht als "als sysadmin/dbo-Session" markiert (das ist der Default: `sa`).

### G0 — Servername-Guard (Kopf JEDES schreibenden Testskripts, PFLICHT)

```sql
-- G0: abort before any write if this is not the throwaway E2E container.
IF UPPER(CONVERT(sysname, SERVERPROPERTY('MachineName'))) LIKE N'%VM-SQL2%'
   OR UPPER(CONVERT(sysname, SERVERPROPERTY('MachineName'))) LIKE N'%VM-SQL-TEST1%'
    THROW 59000, 'GUARD: refusing to run — this is not the disposable E2E container.', 1;
GO
```

### S1 — tConfig-Repoint auf Container-Pfade (F2.5, PFLICHT vor jedem Reset)

Die Seeds `up/0020:29-30` zeigen auf Windows-Pfade (`E:\work\…`, `E:\MSSQL\Data`) — im
Linux-Container ungültig. Ohne Repoint scheitert `xp_create_subdir`/`BACKUP TO DISK`
(→ Request `failed`). Das ist zugleich Setup UND der Positiv-Anker für den Negativtest
**T2-42**.

```sql
-- run against RoboticoOps, as sysadmin/dbo. G0 first.
UPDATE ops.tConfig SET cValue = N'/var/opt/mssql/backup/eazybusiness_to_test.bak' WHERE cKey = N'BackupFile';
UPDATE ops.tConfig SET cValue = N'/var/opt/mssql/data'                            WHERE cKey = N'TargetDataDir';
-- SourceDb bleibt 'eazybusiness'. Verzeichnis /var/opt/mssql/backup muss existieren
-- (mssql-User beschreibbar) — xp_create_subdir legt TargetDataDir an, nicht das Backup-Dir.
SELECT cKey, cValue FROM ops.tConfig WHERE cKey IN (N'BackupFile',N'TargetDataDir',N'SourceDb');
```

### S2 — Validierungs-Mandant registrieren

`tm9` als Wegwerf-Mandant (kollidiert nicht mit tm2/tm3/tm4 aus dem Seed):

```sql
-- run against RoboticoOps, as ops_admin/sysadmin. G0 first.
EXEC reset.spPub_CreateTestmandant @MandantKey = N'tm9', @DisplayName = N'T2 E2E validation',
     @LoginName = N'sa', @StartReset = 0;    -- @StartReset=0: erst registrieren, Reset explizit in T2-01/02
-- @LoginName='sa' existiert im Container immer -> GrantAccess vergibt db_owner statt WARN-Skip
-- (Seed-Default 'dbuser_dev_dana_for_development' existiert im Container NICHT, s. T2-33).
```

---

## 1. Voller 8-Step-Reset — beide Pfade (F2.1, F2.2, F2.9)

### T2-01 — Agent-Job-Pfad (sp_start_job, Agent AN)

**Setup:** S1, S2 erledigt. Agent läuft. Reset-Job `RoboticoOps - Testmandant Reset`
existiert (durch `spEnsureAgentJob` beim global-Deploy).

**Aktion:**
```sql
-- run against RoboticoOps. G0 first.
EXEC reset.spPub_StartTestmandantReset @MandantKey = N'tm9';   -- -> {kResetRequest, 'queued'}
-- poll bis terminal:
EXEC reset.spPub_GetResetStatus @MandantKey = N'tm9';          -- cStatus + cStepLog beobachten
```

**Erwartet:**
- `spPub_StartTestmandantReset` liefert `kResetRequest`, `cStatus='queued'`.
- Der Agent-Job verarbeitet asynchron; nach kurzer Zeit `cStatus='succeeded'`,
  `dFinished` non-null, `cErrorMessage` NULL.
- `cStepLog` enthält in Reihenfolge je eine `starting step N: spInternal_<Name>`-Zeile
  (OPS-3, `spProcessNextResetRequest.sql:151`) + die Erfolgszeile jedes Steps:
  `clone: backup+restore … ok` → `security: owner=sa …` → `credentials: cleared + JS-Shop repointed …` →
  `worker: pf_user locked …` → `anon.P1 ok … anon.P11 ok` → `access: sa is db_owner on eazybusiness_tm9` →
  `register: kMandant=… ` → `roles: JTL_Reader/JTL_Writer ensured …`.
- Klon `eazybusiness_tm9` existiert, ONLINE, RECOVERY SIMPLE, MULTI_USER.
- Verifikation gemäß Runbook §4.2–4.6 (Version, Worker-Neutralisierung, Credential-
  Repoint, Anonymisierung, Registration+Access).

**Cleanup:** siehe C1 (am Ende).

### T2-02 — Synchroner Pfad (EXEC reset.spProcessNextResetRequest, ohne Agent)

Der von der Grundrecherche empfohlene Container-Default: Pipeline synchron, durch den
`reset:pipeline`-Applock (B3) gegen Parallelität gedeckt. Umgeht die Agent-Abhängigkeit.

**Setup:** S1 erledigt. Neuer Wegwerf-Mandant `tm8` (frisch, damit T2-01/02 unabhängig):
```sql
EXEC reset.spPub_CreateTestmandant @MandantKey = N'tm8', @DisplayName = N'T2 sync path',
     @LoginName = N'sa', @StartReset = 0;
```

**Aktion:** Row queuen OHNE Agent-Start, dann synchron abarbeiten. Da
`spPub_StartTestmandantReset` immer `sp_start_job` ruft (bei Agent-AN → Job läuft
mit), wird für den REIN synchronen Test die Row direkt enqueued:
```sql
-- als sysadmin/dbo, run against RoboticoOps. G0 first.
INSERT ops.tResetRequest (cMandantKey, cTargetDb, cStatus, cRequestedBy, dRequested, dModified)
VALUES (N'tm8', N'eazybusiness_tm8', N'queued', ORIGINAL_LOGIN(), SYSUTCDATETIME(), SYSUTCDATETIME());

EXEC reset.spProcessNextResetRequest;   -- synchron, blockiert bis fertig
EXEC reset.spPub_GetResetStatus @MandantKey = N'tm8';
```

**Erwartet:** identisches Endergebnis wie T2-01 (`succeeded`, voller `cStepLog`, Klon
online). Beweist, dass die Pipeline ohne Agent vollständig lauffähig ist (Teilrecherche
§4). Kein doppelter Klon, kein Applock-Leak (nach Rückkehr ist `reset:pipeline` frei —
prüfbar via `APPLOCK_TEST('session',N'reset:pipeline','Exclusive','Session')` in NEUER
Session = 1/verfügbar).

---

## 2. Guard- / THROW-Matrix (F2.1) — je ein Testfall pro Guard

Alle direkten `EXEC reset.spInternal_*` laufen als sysadmin/dbo-Session (die Steps sind
unsigniert; Privileg kommt sonst vom Job-Owner). `@RequestId` = eine reale queued/running
Row oder ein Dummy, `@MandantKey` beliebig gültig — der Guard feuert VOR jeder Nutzung.

| ID | Aufruf | Erwartet |
|---|---|---|
| **T2-10** | `EXEC reset.spInternal_CloneDatabase @TargetDb=N'eazybusiness',@RequestId=1,@MandantKey=N'tm9'` | **THROW 51010** (`CloneDatabase.sql:27-28`) |
| **T2-11** | CloneDatabase mit Config-Key gelöscht: `DELETE ops.tConfig WHERE cKey=N'SourceDb'` dann Reset | **THROW 51011** (`:40-41`) — danach Key wieder seeden |
| **T2-12** | CloneDatabase mit `SourceDb`=nicht-existierende DB | **THROW 51012** (`:42-43`) |
| **T2-13** | CloneDatabase, `SourceDb`==`@TargetDb` (Config `SourceDb`=`eazybusiness_tm9`, Reset tm9) | **THROW 51014** (`:47-48`) |
| **T2-14** | PostRestoreSecurity direkt mit `@TargetDb=N'eazybusiness'` | **THROW 51020** (`PostRestoreSecurity.sql:21-22`) |
| **T2-15** | InvalidateCredentials direkt, `@TargetDb=N'eazybusiness'` | **THROW 51030** (`InvalidateCredentials.sql:27-28`) |
| **T2-16** | NeutralizeWorker direkt, `@TargetDb=N'eazybusiness'` | **THROW 51040** (`NeutralizeWorker.sql:29-30`) |
| **T2-17** | AnonymizeCustomerData direkt, `@TargetDb=N'eazybusiness'` | **THROW 51050** (`AnonymizeCustomerData.sql:23-24`) |
| **T2-18** | GrantAccess direkt, `@TargetDb=N'eazybusiness'` | **THROW 51060** (`GrantAccess.sql:22-23`) |
| **T2-19** | RegisterMandant direkt, `@TargetDb=N'eazybusiness'` | **THROW 51070** (`RegisterMandant.sql:31-32`) |
| **T2-20** | RegisterMandant, `ops.tMandant.cDisplayName` für tm9 auf `''` gesetzt → Reset | **THROW 51071** (`:37-38`) |
| **T2-21** | ApplyJtlRoles direkt, `@TargetDb=N'eazybusiness'` | **THROW 51080** (`ApplyJtlRoles.sql:33-34`) |
| **T2-22** | Start-SP `EXEC reset.spPub_StartTestmandantReset @MandantKey=N'tm9'` NACH Manipulation der tm9-Row auf `cTargetDb='eazybusiness'` — geht nicht (CHECK); stattdessen Start-SP-Guard über eine tMandant-Zeile testen, deren cTargetDb den Pattern-Guard verletzt: nicht einfügbar wegen `CK_tMandant_cTargetDb`. Direkt testbar: siehe T2-25 | **THROW 51003** nur über Umweg — de facto durch CHECK vorverlagert |
| **T2-23** | Start-SP mit unbekanntem Key `@MandantKey=N'tm99'` (nicht in tMandant) | **THROW 51002** (`Start.sql:52-53`) |
| **T2-24** | Orchestrator-Whitelist: `INSERT ops.tResetStep (nStepOrder,cProcName) VALUES (5,N'spInternal_DoesNotExist')` (passt CHECK `LIKE 'spInternal[_]%'`), dann Reset | Pipeline **THROW 51005** (`spProcessNextResetRequest.sql:145`), Request `failed`; danach Zeile wieder löschen |
| **T2-25** | Orchestrator-Re-Validierung: queued Row von Hand auf `cTargetDb=N'eazybusiness_xNOTREG'` (via UPDATE der running-Row nicht möglich wegen Guard-Timing → stattdessen: tMandant-Zeile nach queue löschen) dann `EXEC spProcessNextResetRequest` | Row → **`failed`** mit `re-validation failed: target is not a registered test-mandant clone`, **kein THROW**, kein Prod-Touch (`:102-113`) |

### Deklarative Backstops (CHECK / Unique-Index)

| ID | Aufruf | Erwartet |
|---|---|---|
| **T2-26** | `INSERT ops.tMandant (…,cTargetDb) VALUES (…,N'eazybusiness',…)` | **CHECK-Verletzung** `CK_tMandant_cTargetDb` (`up/0002:49-50`) |
| **T2-27** | `INSERT ops.tMandant (cMandantKey,…) VALUES (N'tmv',…)` (nicht `tm[0-9]%`) | **CHECK-Verletzung** `CK_tMandant_cMandantKey` (`:48`) |
| **T2-28** | `INSERT ops.tResetStep (nStepOrder,cProcName) VALUES (99,N'CloneDatabase')` (fehlendes `spInternal_`-Präfix) | **CHECK-Verletzung** `CK_tResetStep_cProcName` (`up/0021:47`) |
| **T2-29** | Zwei queued Rows für dasselbe `cTargetDb=N'eazybusiness_tm9'` einfügen | **Unique-Index-Verletzung** `IX_tResetRequest_Active` (gefiltert auf queued/running, `up/0002:95-97`) |
| **T2-30** | CreateTestmandant `@MandantKey=N'tm9'` erneut | **THROW 51093** (`CreateTestmandant.sql:54-55`); mit anderem Key aber gleichem `@TargetDb` → **51094** (`:56-57`); leerer DisplayName → **51090** (`:44-45`); Key `tmv` → **51091** (`:47-48`); `@TargetDb=N'eazybusiness'` → **51092** (`:50-51`) |

### Permission gegen fehlende Prinzipale (F2.7)

| ID | Aufruf | Erwartet |
|---|---|---|
| **T2-31** | Reset mit `ops.tMandant.cLoginName` = nicht existierender Login (Default-Seed `dbuser_dev_dana_for_development`) | Reset **`succeeded`**, aber `cStepLog`-Zeile `WARN access-skipped: login … not found … NO db_owner` (`GrantAccess.sql:35-36`, PAR-1) |
| **T2-32** | Reset mit `cLoginName='sa'` (existiert) | `access: sa is db_owner on eazybusiness_tm9`; im Klon: `sa`-User ist `db_owner` |
| **T2-33** | ApplyJtlRoles: AD-Member `ZDBIKES\sql-jtl-users` etc. fehlen im Container | Rollen `JTL_Reader`/`JTL_Writer` entstehen trotzdem, fehlende Member werden übersprungen (`ApplyJtlRoles.sql:71`), Step `succeeded` |

---

## 3. Teilfehlschläge & Transaktionsgrenzen (F2.2)

### T2-40 — bCritical=0-Pfad (nicht-kritischer Step, WARN statt Abbruch)

**Setup:** einen Step auf nicht-kritisch schalten und künstlich fehlschlagen lassen.
Am saubersten über einen zusätzlichen No-Op-Step, der garantiert wirft — aber die
Whitelist verlangt einen deployten `reset.spInternal_`-Proc. Praktikabel: `ApplyJtlRoles`
(letzter Step) auf `bCritical=0` setzen und im Klon eine Kollision provozieren, ODER
`RegisterMandant` auf non-critical + `ReferenceMandant` auf ungültig. Minimal-invasiv:
`GrantAccess` non-critical + `cLoginName` auf einen Namen, der `CREATE USER` im Klon
sprengt, ist schwer erzwingbar. **Empfohlen:** eigenen Test-Step registrieren.

```sql
-- als sysadmin/dbo, RoboticoOps. G0 first.
-- 1) einen deployten Step non-critical schalten, dessen Fehlschlag reproduzierbar ist:
UPDATE ops.tResetStep SET bCritical = 0 WHERE cProcName = N'spInternal_RegisterMandant';
-- 2) RegisterMandant zum Werfen bringen: DisplayName leer -> 51071 (kritisch im Step selbst
--    ist es ein THROW; als non-critical fängt der Orchestrator ihn ab)
UPDATE ops.tMandant SET cDisplayName = N'' WHERE cMandantKey = N'tm9';
-- 3) Reset:
INSERT ops.tResetRequest (cMandantKey,cTargetDb,cStatus,cRequestedBy,dRequested,dModified)
VALUES (N'tm9',N'eazybusiness_tm9',N'queued',ORIGINAL_LOGIN(),SYSUTCDATETIME(),SYSUTCDATETIME());
EXEC reset.spProcessNextResetRequest;
EXEC reset.spPub_GetResetStatus @MandantKey = N'tm9';
```

**Erwartet:** Request **`succeeded`** trotz RegisterMandant-Fehler; `cStepLog` enthält
`WARN spInternal_RegisterMandant: …` (`spProcessNextResetRequest.sql:166`), die
Folgesteps (ApplyJtlRoles) liefen dennoch. **Danach zwingend zurücksetzen:**
`UPDATE ops.tResetStep SET bCritical=1 WHERE cProcName=N'spInternal_RegisterMandant'`,
DisplayName wiederherstellen.

### T2-41 — Secret-Scrubbing (Sec-I1)

**Setup:** `cShopLicense` auf einen erkennbaren Wert setzen und einen Fehler provozieren,
dessen Engine-Meldung Daten echot (z.B. Truncation 2628/2628). Da `cShopLicense` in
`tShop.cAPIKey` repointet wird, ist ein Truncation-Echo schwer deterministisch. Robust:
den Wert kurz halten und über den bCritical-Pfad ins persistierte `cErrorMessage`/
`cStepLog` bringen, indem ein Step wirft, während `@secret` gesetzt ist.

```sql
UPDATE ops.tMandant SET cShopLicense = N'SECRET-LEAK-CANARY-4711' WHERE cMandantKey = N'tm9';
-- Reset so provozieren, dass ein kritischer Step nach InvalidateCredentials wirft
-- (z.B. RegisterMandant DisplayName leer -> 51071, bCritical=1):
UPDATE ops.tMandant SET cDisplayName = N'' WHERE cMandantKey = N'tm9';
-- Reset ausführen (synchron), dann:
SELECT cErrorMessage, cStepLog FROM ops.tResetRequest WHERE cMandantKey=N'tm9' ORDER BY kResetRequest DESC;
```

**Erwartet:** Weder `cErrorMessage` noch `cStepLog` enthalten `SECRET-LEAK-CANARY-4711` —
falls ein Fehlertext den Wert getragen hätte, ist er durch `***` ersetzt
(`spProcessNextResetRequest.sql:169-170,218-219`). Kernpunkt: der Scrubbing-Pfad ist
scharf (REPLACE greift auch, wenn der Wert gar nicht auftauchte — dann ist der Test
trivially green; dokumentieren, dass der harte Nachweis ein echtes Data-Echo braucht →
"nur zur Laufzeit klärbar", §7).

### T2-42 — tConfig NICHT repointet → sauberer failed-Request (F2.5 Negativtest)

**Setup:** `BackupFile`/`TargetDataDir` auf die Windows-Seeds ZURÜCKsetzen (S1 rückgängig):
```sql
UPDATE ops.tConfig SET cValue=N'E:\work\eazybusiness_to_test.bak' WHERE cKey=N'BackupFile';
UPDATE ops.tConfig SET cValue=N'E:\MSSQL\Data'                     WHERE cKey=N'TargetDataDir';
-- Reset tm9 synchron
```

**Erwartet:** Request **`failed`**, `cErrorMessage` zeigt den `xp_create_subdir`- bzw.
`BACKUP`-Fehler (ungültiger Pfad). **Kein Halbschaden:** kein Klon `eazybusiness_tm9`
entsteht (CloneDatabase ist Step 1, scheitert vor jedem Datenschritt), MULTI_USER-Best-
Effort läuft leer (DB existiert nicht). Danach S1 wieder anwenden.

### T2-43 — Mid-RESTORE-Kill → RESTORING-Leiche → Selbstheilung (B10/I5)

**Setup:** Reset tm9 in einer Session starten (synchron), in einer ZWEITEN Session die
Restore-Session killen, während `RESTORE DATABASE` läuft.

```sql
-- Session A: Reset starten (blockiert im RESTORE)
EXEC reset.spProcessNextResetRequest;
-- Session B (parallel, sysadmin): laufende Restore-Session finden und killen
SELECT session_id, command, percent_complete
FROM sys.dm_exec_requests WHERE command LIKE N'RESTORE%';
-- KILL <session_id>;   -- während percent_complete < 100
```

**Erwartet nach Kill:** `eazybusiness_tm9` bleibt in `RESTORING` (oder verschwindet).
Request bleibt `running` (Session A tot) ODER wird beim Applock-freien Folgelauf
behandelt. **Folgelauf** (`EXEC reset.spProcessNextResetRequest` in neuer Session):
- Stale-Reclaim greift NUR wenn `dStarted` > StaleRunningHours zurückliegt (sonst bleibt
  die Row `running` — hier künstlich zurückdatieren, s. T2-50, um den Reclaim zu sehen),
- CloneDatabase findet den Ziel-Klon in state `RESTORING` (≠ ONLINE) → **droppt ihn** mit
  Logzeile `clone: target … found in state RESTORING … dropping it before restore`
  (`CloneDatabase.sql:78-85`), dann sauberer Neu-Restore.

**Nachweisziel:** die RESTORING-Leiche vergiftet keinen Folgelauf; sie wird gedroppt statt
per SINGLE_USER-ALTER mit irreführendem Fehler zu blockieren.

### T2-44 — Cursor-Cleanup-Regression (B2, Fehler 16915)

**Setup:** einen Fehler INNERHALB des per-Request-TRY provozieren, der KEIN Step-Fehler ist
— z.B. `spInternal_LogStep`-Deadlock oder eine defekte `spInternal_LogStep`. Schwer
deterministisch ohne Code-Eingriff. Praktikabler Ersatznachweis: prüfen, dass nach einem
kritischen Step-Fehler (T2-40 mit bCritical=1) der Cursor `stepcur` sauber
geschlossen/dealloziert ist und der NÄCHSTE queued Request NICHT mit Fehler 16915
(„cursor already exists") scheitert.

```sql
-- zwei queued Requests, erster mit erzwungenem kritischen Fehler, zweiter valide:
-- (DisplayName tm9 leer -> RegisterMandant 51071 kritisch; tm8 sauber)
-- dann EXEC reset.spProcessNextResetRequest (arbeitet BEIDE ab)
```

**Erwartet:** erster Request `failed`, zweiter Request `succeeded` (bzw. nach eigener
Logik) — insbesondere **kein** `cErrorMessage` mit „16915"/„A cursor with the name
'stepcur' already exists" (`spProcessNextResetRequest.sql:194-203`). Beweist die
`CURSOR_STATUS`-basierte Bereinigung im äußeren CATCH.

---

## 4. Stale-Reclaim, Cancel, Dedup (F2.4)

### T2-50 — Stale-Reclaim (zurückdatierte running-Row)

```sql
-- als sysadmin/dbo. G0 first.
-- eine running-Row künstlich altern lassen:
UPDATE ops.tResetRequest
   SET cStatus=N'running', dStarted = DATEADD(HOUR,-5,SYSUTCDATETIME())
 WHERE cMandantKey=N'tm9' AND kResetRequest = (SELECT MAX(kResetRequest) FROM ops.tResetRequest WHERE cMandantKey=N'tm9');
EXEC reset.spProcessNextResetRequest;   -- Reclaim läuft am Schleifen-Anfang
SELECT cStatus, cErrorMessage FROM ops.tResetRequest WHERE cMandantKey=N'tm9' ORDER BY kResetRequest DESC;
```

**Erwartet:** Row → `failed`, `cErrorMessage = 'stale running request reclaimed (job likely
restarted)'` (`:54-60`). Reclaim vergleicht `dStarted` (nicht `dModified`).

### T2-51 — Stale-Fallback bei fehlendem/nicht-numerischem Knob

```sql
DELETE ops.tConfig WHERE cKey=N'StaleRunningHours';           -- Key weg
-- ODER: UPDATE ops.tConfig SET cValue=N'abc' WHERE cKey=N'StaleRunningHours';
-- running-Row auf -5h, dann EXEC reset.spProcessNextResetRequest
```

**Erwartet:** `ISNULL(TRY_CONVERT(int,…),4)` → Fallback 4h greift, 5h-alte Row wird
reclaimed (`:50-51`). Danach Key wieder seeden (`'4'`).

### T2-52 — Cancel eines queued Requests (51-Pfad, queued→failed)

```sql
-- queued Row anlegen (kein Agent-Start), dann:
EXEC reset.spPub_CancelResetRequest @RequestId = <id>;
```
**Erwartet:** `cStatus='failed'`, Note `cancelled (was queued)`, `cErrorMessage` nennt
Aufrufer (`CancelResetRequest.sql:60-77`).

### T2-53 — Cancel-Race (queued→running zwischen Read und Write)

Schwer deterministisch; als Erwartungsdoku: wenn der Job die Row zwischen Cancel-Read und
-Write claimt, liefert der guarded UPDATE (`WHERE cStatus=N'queued'`) 0 Rows → Note
`could not cancel: the job already picked it up` (`:68-73`), keine Fehlmarkierung.

### T2-54 — Cancel eines running Requests bei INAKTIVEM Job (Force-Reclaim)

**Setup:** Agent AUS (bzw. Job läuft nicht), eine `running`-Row vorhanden.
```sql
EXEC reset.spPub_CancelResetRequest @RequestId = <running-id>;
```
**Erwartet:** `syssessions`-Probe findet keine aktive Job-Session → Force-Reclaim erlaubt →
`failed`, Note `force-reclaimed (was running, no active job)` (`:95-103`). **Sonderfall
frische Instanz:** wenn der Agent NIE lief, ist `syssessions` leer → `MAX(agent_start_date)`
NULL → EXISTS false → Force-Reclaim erlaubt (Teilrecherche §3c — gewollt, hier verifizieren).

### T2-55 — Cancel-Refusal bei AKTIVEM Job (51007)

**Setup:** Agent AN, Reset tm9 gestartet, WÄHREND `running` (Job führt aus):
```sql
EXEC reset.spPub_CancelResetRequest @RequestId = <running-id>;
```
**Erwartet:** **THROW 51007** „the reset job is currently running" (`:83-93`) — die
`sysjobactivity`-Probe (start ohne stop, aktuelle Agent-Session) erkennt den laufenden Job.
Zeitfenster ist kurz → ggf. einen künstlich langsamen Step (WAITFOR im Klon) einschieben,
um das Fenster zu vergrößern; nur zur Laufzeit robust einstellbar (§7).

### T2-56 — Unbekannter Request / Purge-Param

```sql
EXEC reset.spPub_CancelResetRequest @RequestId = 999999;   -- THROW 51006 (:44-45)
EXEC reset.spPub_PurgeOldRequests @KeepPerMandant = 0;      -- THROW 51008 (Purge.sql:25-26)
EXEC reset.spPub_PurgeOldRequests @KeepPerMandant = 1, @WhatIf = 1;  -- Dry-Run: nur Count
```

### T2-57 — Dedup laufender Requests (OPS-6)

**Setup:** tm9 queued/running, dann Start-SP erneut:
```sql
EXEC reset.spPub_StartTestmandantReset @MandantKey = N'tm9';   -- 1. Aufruf -> queued
EXEC reset.spPub_StartTestmandantReset @MandantKey = N'tm9';   -- 2. Aufruf, noch in-flight
```
**Erwartet:** 2. Aufruf liefert **dieselbe** `kResetRequest` + deren `cStatus` (kein
Fehler, kein zweiter Request), `Start.sql:64-74`. Zusätzlich: der gefilterte Unique-Index
ist der deklarative Backstop (T2-29).

---

## 5. Agent-down-Verhalten (F2.3) — 22022-Schluckverhalten

### T2-60 — sp_start_job bei gestopptem Agent

**Setup:** Agent im Container stoppen (`mssql-conf` bzw. Container mit
`MSSQL_AGENT_ENABLED=false` neu — Reset des Agent-Zustands, siehe T5/§7), Job existiert im
msdb-Katalog (durch früheren Deploy), läuft aber nicht.

```sql
EXEC reset.spPub_StartTestmandantReset @MandantKey = N'tm9';
SELECT kResetRequest, cStatus FROM ops.tResetRequest WHERE cMandantKey=N'tm9' ORDER BY kResetRequest DESC;
```

**Erwartete Hypothese (im Container zu VERIFIZIEREN, Befund offen — §7):**
`sp_start_job` wirft bei gestopptem Agent vermutlich **22022** („SQLServerAgent is not
currently running"). Das Start-SP behandelt JEDE 22022 als harmloses „job already running"
(`Start.sql:90`, prüft nur `ERROR_NUMBER()`, nicht den Text) → die Row bleibt **still
`queued`** und niemand verarbeitet sie. Erwartung dokumentieren, Befund offenlassen; falls
bestätigt, ist der synchrone Pfad (T2-02) der Workaround und ggf. ein Folge-Ticket wert.

---

## 6. Signaturkette & jobstartuser-Remap (F2.8, F2.6)

### T2-70 — Signatur-Überleben über Re-Deploy (CREATE OR ALTER strippt → 900 heilt)

**Setup:** global-Deploy ist gelaufen (Signatur da). Signaturen erfassen:
```sql
SELECT p.name FROM sys.procedures p
JOIN sys.sql_modules m ON m.object_id=p.object_id
WHERE m.execute_as_principal_id = DATABASE_PRINCIPAL_ID(N'jobstartuser');   -- die signierten Procs
SELECT OBJECT_NAME(cp.major_id) AS proc, c.name AS cert
FROM sys.crypt_properties cp JOIN sys.certificates c ON cp.thumbprint=c.thumbprint
WHERE c.name=N'RoboticoOpsSigning';   -- aktuell signierte
```
**Aktion:** erneuter global-Deploy (`npm run db:deploy:e2e:global`).
**Erwartet:** nach dem Deploy sind `spPub_StartTestmandantReset` UND
`spPub_CancelResetRequest` wieder signiert (900 re-signiert everytime nur Unsigniertes,
`900:23-34`); `PRINT Re-signed …`. Kein `50900` (Hard-Fail bei Rest-Unsigniertem).
Funktionaler Beweis: `EXEC reset.spPub_StartTestmandantReset` gelingt weiterhin (msdb-
Crossing via Signatur).

### T2-71 — Falsches {{CertPassword}} beim Re-Deploy → 50901

**Setup:** global-Deploy mit ABWEICHENDEM Cert-Passwort erzwingen (Session-Env
`GRATE_CERT_PASSWORD` auf einen falschen Wert setzen, sodass es ≠ dem Passwort ist, mit dem
`up/0011` das Zertifikat erstellt hat).
**Erwartet:** `900` scheitert mit **THROW 50901** und der erklärenden Meldung „the deploy-
time {{CertPassword}} does not match …" (`900:51-59`). Deploy bricht ab. Danach korrektes
Passwort wiederherstellen.

> [!NOTE]
> Auf einem FRISCHEN Container erzeugt `up/0011` das Zertifikat mit dem beim ersten
> global-Deploy gültigen `{{CertPassword}}`. 50901 tritt nur auf, wenn ein SPÄTERER Deploy
> ein anderes Passwort liefert. `up/0011` ist journaled/immutable — Rotation nur via
> DROP+neues up-Skript (Teilrecherche §3f).

### T2-72 — 250 Orphan-Remap (jobstartuser-SID divergiert)

**Setup:** Login-Teardown simulieren, sodass der DB-User verwaist:
```sql
-- als sysadmin. G0 first.
DROP LOGIN [jobstartuser];                 -- DB-User in msdb + RoboticoOps bleiben (orphan)
CREATE LOGIN [jobstartuser] WITH PASSWORD = N'<throwaway>', CHECK_POLICY = OFF;  -- NEUE SID
ALTER LOGIN [jobstartuser] DISABLE;
-- up/0010 ist journaled und läuft NICHT erneut -> User bleibt an alter SID gebunden = orphan
```
**Vorher-Nachweis:** `sp_start_job` aus dem impersonierten Kontext ist DENIED (SID-Mismatch)
— indirekt via fehlschlagendem `spPub_StartTestmandantReset` (msdb-Permission-Fehler, ≠ 22022
→ Row wird `failed`).
**Aktion:** global-Deploy (250 läuft everytime).
**Erwartet:** `250` re-mappt beide User (`ALTER USER … WITH LOGIN`), PRINT `! msdb
jobstartuser was orphaned — re-mapped …` und `! RoboticoOps jobstartuser was orphaned …`
(`250:26-48`). Danach `spPub_StartTestmandantReset` gelingt wieder. **No-Op-Gegenprobe:**
zweiter Deploy ohne Orphan → kein PRINT, keine Änderung (idempotent).

### T2-73 — Deploy-Guard 50010 bei aktivem Request (Nicht-No-Op-Falle, F1.4)

**Setup:** eine `queued`- oder `running`-Row für irgendeinen Mandanten anlegen, dann eine
Hash-Änderung an `reset.spEnsureAgentJob.sql` simulieren (bzw. den Re-Run erzwingen) und
global deployen.
**Erwartet:** `spEnsureAgentJob` wirft **THROW 50010** „a reset request is queued or running.
Recreating the agent job now would cancel it mid-clone …" (`spEnsureAgentJob.sql:43-44`) —
Deploy bricht ab, der laufende Reset wird NICHT mid-clone abgeschossen. Nach Terminierung
des Requests läuft der Deploy grün.

### T2-74 — Deutsche Login-Default-Language beim Deploy (F2.6, Datumsliteral)

**Setup:** einen Login mit `DEFAULT_LANGUAGE = German`/`SET LANGUAGE deutsch` anlegen und
den global-Deploy (bzw. den 0011-Pfad) unter diesem Kontext simulieren — bzw. per Session
`SET LANGUAGE deutsch` vor einem Re-Run des Zertifikat-Pfads.
**Erwartet:** `EXPIRY_DATE = '29991231'` (Basic-ISO, sprachneutral, `up/0011:43-47`) wirft
KEINEN Fehler 190 unter dmy-Locale. Grüner Deploy. (Regression gegen den test1-Incident,
Lint-Regel h.)

---

## 7. Reset ↔ Wartung im geteilten Agent (Rahmenentscheidung 6)

Beide Job-Familien koexistieren im selben Agent: Reset-Job `RoboticoOps - Testmandant
Reset` (on-demand, kein Schedule) und Wartungsjobs `RoboticoOps - Maint - *`
(`spEnsureMaintenanceJobs.sql:45`). **Keine geteilten Applocks** (`reset:pipeline` ist
reset-exklusiv; die maint-Prozeduren nutzen keinen `sp_getapplock`), distinkte Job-Namen,
distinkte Operatoren (`RoboticoOps-Maint` vs. optional `NotifyOperator`). Wartungs-Interna
→ T3; hier nur die Wechselwirkungen.

> [!IMPORTANT]
> **Scheduler-Schalter-Setup (Cross-Hinweis T3).** `ops.tConfig('MaintenanceSchedulesEnabled')`
> ist NIRGENDS geseedet; die Effektiv-Logik ist `bEnabled=1 AND cValue<>'0'` → **fehlender
> Key = ENABLED**. Im frischen Container kommen die 6 Maint-Jobs beim Erstlauf also
> **enabled mit Schedule** hoch (nicht disabled) und könnten während der Reset-Tests
> spontan feuern (Störrauschen, ungewolltes Auslösen von T2-82). Für den Reset selbst ist
> der Schalter irrelevant (er gated nur Maint-Jobs), aber das §7-Setup MUSS den Zustand
> bewusst wählen:
> - **Phase A (Reset-Isolation, Default für §1–§6):** vor den Reset-Tests
>   `MERGE`/`INSERT ops.tConfig (cKey,cValue) VALUES (N'MaintenanceSchedulesEnabled', N'0')` —
>   die Maint-Jobs bleiben idle, spontane Läufe stören die Reset-Nachweise nicht. `sp_start_job`
>   funktioniert für T2-82 trotzdem manuell (D34).
> - **Phase B (prod-nahe Koexistenz, für T2-82):** den Key bewusst **unset** lassen (bzw.
>   `<>'0'`) → Maint-Jobs enabled, wie im frischen Container. Dann ist die parallele
>   Wartungs-Aktivität real und muss die Reset-Läufe nachweislich nicht verklemmen.
>
> Die genaue Effektiv-Logik/Job-Erzeugung ist T3-Territorium; hier nur die Schalter-Setzung
> als Voraussetzung, damit die Reset-Fälle deterministisch sind.

### T2-80 — Beide Job-Familien koexistieren nach Deploy

**Erwartet:** nach vollem global-Deploy existieren in `msdb.dbo.sysjobs` sowohl der Reset-
Job als auch die `RoboticoOps - Maint - *`-Jobs; `spEnsureAgentJob` (Reset) und
`spEnsureMaintenanceJobs` (Wartung) stören sich nicht (getrennte Namen). Idempotenter
Re-Deploy: 0 Änderungen an beiden Job-Sätzen (Job-IDs stabil), sofern kein aktiver Request.

### T2-81 — 50010-Deploy-Guard während aktivem Reset blockiert AUCH Wartungs-Änderungen

**Kernwechselwirkung:** eine Wartungs-Änderung wird über den GESAMTEN global-Chain deployt.
Läuft dabei ein Reset (queued/running), feuert `spEnsureAgentJob` **50010** und der Deploy
bricht ab — die Wartungs-Änderung kommt nicht durch, solange der Reset aktiv ist.
**Setup:** running-Row + Hash-Änderung an `spEnsureAgentJob` (oder erzwungener Re-Run),
Deploy.
**Erwartet:** Abbruch mit 50010 (wie T2-73); die maint-Objekte des SELBEN Laufs werden
(ohne umschließende Ebene-B-Transaktion) je nach Ordner-Reihenfolge teils schon angewandt —
dokumentieren, welche vor 900/200 liegen. Nach Request-Terminierung grüner Deploy.

### T2-82 — Reset läuft, während ein Wartungsjob aktiv ist (und umgekehrt)

**Setup:** Phase B (Schalter unset/`<>'0'`, s. §7-Setup-Box) für den prod-nahen Zustand;
einen Wartungsjob manuell starten (`sp_start_job @job_name=N'RoboticoOps - Maint
- IndexOptimize - …'` — funktioniert auch unter Phase-A-`'0'`, D34), parallel Reset tm9
starten; und die Gegenrichtung (Reset läuft, Wartungsjob starten). Für §1–§6 gilt dagegen
Phase A (`'0'`), damit kein Maint-Schedule spontan in die Reset-Nachweise grätscht.
**Erwartet:** beide laufen unabhängig (getrennte Jobs, kein gemeinsamer Applock). Der Reset
hält `reset:pipeline` nur gegen einen zweiten Reset; ein Wartungsjob wird davon nicht
blockiert. Mögliche reale Kollision nur auf msdb-Katalogebene bei GLEICHZEITIGEM
`sp_add_job`/`sp_delete_job` (Deploy-Zeit, nicht Laufzeit) — im normalen Betrieb keine.
Nachweisziel: keine gegenseitige Verklemmung, kein Reset-Abbruch durch Wartung.

---

## „Nur zur Laufzeit klärbar" (offene Punkte für den Ausführenden)

1. **22022 bei gestopptem Agent (T2-60).** Ob `sp_start_job` bei Agent-down wirklich 22022
   liefert (und damit vom Start-SP verschluckt wird) ist unbestätigt. Erwartung: Row bleibt
   still `queued`. Befund im Container festhalten; falls bestätigt → Folge-Ticket
   (Text-/Zustandsprüfung statt reiner `ERROR_NUMBER()`-Gleichheit).
2. **Backslash-in-Linux-Pfad (T2-01 CloneDatabase).** Der MOVE-Pfad wird mit `\`
   konkateniert (`CloneDatabase.sql:56`): `/var/opt/mssql/data\eazybusiness_tm9_<logical>.mdf`.
   SQL Server on Linux normalisiert Backslashes i.d.R.; der gemischte Pfad ist explizit zu
   verifizieren (im 2026-07-11-Lauf war Linux tolerant). Falls intolerant → tConfig-Wert
   ohne trailing-Slash + Code-Fix nötig.
3. **Secret-Scrubbing harter Nachweis (T2-41).** Ein echtes Data-Echo im Engine-Fehlertext
   (z.B. Truncation 2628, das den `cShopLicense`-Wert zitiert) ist schwer deterministisch zu
   provozieren. Ohne Echo ist der REPLACE trivially grün. Zur Laufzeit einen Truncation-
   Pfad suchen, der den Wert nachweislich trägt (z.B. Ziel-Spalte künstlich verkürzen).
4. **51007-Zeitfenster (T2-55).** Der „Job läuft"-Refusal braucht ein offenes Ausführungs-
   fenster. Ohne künstliche Verlangsamung (WAITFOR im Klon-Kontext) ist es zu kurz. Der
   Ausführende muss einen langsamen Step einschieben oder gegen einen bewusst großen Klon
   testen.
5. **Agent-Zustand umschalten (T2-60).** Agent im laufenden Container stoppen/starten
   (`mssql-conf set sqlagent.enabled false` + Neustart bzw. Container-Recreate mit
   `MSSQL_AGENT_ENABLED=false`) ist ein T5-/Infra-Schritt; die Reset-Harness setzt Agent-AN
   voraus.
6. **grate ohne Ebene-B-Transaktion (T2-81).** Bei 50010-Abbruch mitten im global-Chain
   bleibt der bis dahin angewandte Teil committed (Ebene B läuft ohne umschließende
   Transaktion). Welche maint-/reset-Objekte vor dem Abbruchpunkt (900/200 laufen zuletzt)
   schon angewandt sind, ist reihenfolgeabhängig und zur Laufzeit zu protokollieren.

---

## Cleanup

### C1 — nach jedem Reset-Testfall (Klon + Registrierung)

```sql
-- als sysadmin/dbo. G0 first.
-- Klon droppen (falls vorhanden):
IF DB_ID(N'eazybusiness_tm9') IS NOT NULL
BEGIN
    ALTER DATABASE [eazybusiness_tm9] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE [eazybusiness_tm9];
END
-- RegisterMandant schreibt die tm9-Zeile in dbo.tMandant ALLER Mandanten-DBs (inkl. Source
-- eazybusiness) -> dort wieder entfernen:
DELETE FROM eazybusiness.dbo.tMandant WHERE cDB = N'eazybusiness_tm9';
-- ops-Historie: Request-Rows für tm9 löschen, dann Mandant (FK_tResetRequest_tMandant!):
DELETE ops.tResetRequest WHERE cMandantKey = N'tm9';
DELETE ops.tMandant      WHERE cMandantKey = N'tm9';
```

### C2 — tConfig / tResetStep in Seed-Zustand zurück

```sql
-- alle in §2/§4 geänderten Knobs zurücksetzen (BackupFile/TargetDataDir auf Container-Pfade
-- ODER Seed, StaleRunningHours='4', bCritical=1 für alle Steps, gelöschte Steps entfernen):
UPDATE ops.tResetStep SET bCritical = 1 WHERE bCritical = 0;
DELETE ops.tResetStep WHERE cProcName NOT LIKE N'spInternal[_]%'          -- Test-Whitelist-Zeilen
   OR cProcName = N'spInternal_DoesNotExist';
```

### C3 — Gesamt-Teardown

`npm run db:e2e:down` (Container + Volume) bzw. `:down:full` (auch `.env.local`).
Der Container ist ohnehin wegwerfbar — für einen sauberen Wiederholungslauf ist Teardown+
`db:e2e:up` der robusteste Reset (auch für den Agent-Zustand aus T2-60).
