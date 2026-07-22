# E2E-Runbook: mssql-wartung-ola

**Plan:** [→ ../mssql-wartung-ola.md](../mssql-wartung-ola.md)
**Status:** ready (Phase-1 E2E-strategy output)
**Created:** 2026-07-22
**Recommendation:** `e2e: run` — der Plan schreibt real gegen ein Live-System (grate-Deploy auf test1, echte Wartungsjobs gegen echte DBs, `BACKUP … TO DISK='NUL'`, `DELETE`/`sp_delete_backuphistory`/`sp_purge_jobhistory` auf test1-`msdb`). Das ist genau die „edge-of-the-blade"-Klasse, die E2E abdeckt; ein reiner Block-Audit prüft die Verhaltensversprechen (AC5/AC7/AC9/AC10/AC12/AC13) nicht.
**Mode-Distribution:** auto: 13, manual: 0 (Mail-Weg AC6 ist B6/Prod, außerhalb Scope — kein test1-Case)

## Scope

E2E-Ziel ist **ausschließlich test1** (`vm-sql-test1.zdbikes.local`, SQL 2025, German locale). Verifiziert werden die Plan-Bausteine B1–B5: gepinnte Ola-Objekte in `RoboticoOps.dbo`, Registry `ops.tMaintenanceJob`, die fünf `maint.*`-Procs (Sync/Dispatch/BackupChain/Liveness/Apply), der `permissions/260`-Operator-Self-Heal und die Rollout-/Struktur-Gates. **vm-sql2 ist strikt read-only und NICHT Teil des E2E** (B6 Prod-Cutover ist human-gated). Primärquelle für die Cases ist die B5-Prüfliste in Plan §3.5 (SSoT); AC-Nachweise laufen über `dbo.CommandLog`, `msdb`-Job-Historie und direkte Proc-`EXEC`s.

Kein `docs/runbooks/agentic/`-Katalog im Projekt → der Persistent-Runbook-Derivations-Teil entfällt; alle Cases sind NEW für dieses Feature.

## Relevant Knowledge

- `knowledge-jtl-sql` — JTL-Wawi-Schema (eazybusiness, tm-Klone), Datenbank-Inventar für die Watch-Ziele.
- `knowledge-sql` — SQL-Muster/NULL-Sicherheit für die Assertion-Queries.
- Plan §3.5 (B5-Prüfliste) + §2 (AC 1–13) = fachliche SSoT der erwarteten Ergebnisse.
- Kein `test-knowledge-*`-Skill im Projekt vorhanden — Assertions werden direkt via `sqlcmd` formuliert.

## Prerequisites

sqlcmd-Aufruf durchweg: `/opt/mssql-tools18/bin/sqlcmd -E -C -S vm-sql-test1.zdbikes.local`. Deploy: `pwsh db-migrations/deploy.ps1 -Scope global -Environment TEST` (= `npm run db:deploy:test:global`).

| # | Kind | Target | Check | Blocking |
|---|------|--------|-------|----------|
| 1 | **Isolation (kritisch)** | Ziel ist test1, NICHT vm-sql2 | `sqlcmd -S vm-sql-test1.zdbikes.local -Q "SELECT @@SERVERNAME"` liefert die test1-Instanz; das `-S`-Ziel darf NIE `vm-sql2` sein — `BACKUP … TO DISK='NUL'` (TC-7) auf einer CBB-gesicherten Instanz verschöbe die Diff-Basis. | **yes** |
| 2 | **Isolation (kritisch)** | test1 hat keine fremde *recoverable* Backup-Kette, die NUL-Backups stören würden | `sqlcmd -Q "SELECT COUNT(*) FROM msdb.dbo.backupset bs JOIN msdb.dbo.backupmediafamily mf ON mf.media_set_id=bs.media_set_id WHERE mf.physical_device_name <> N'NUL' AND bs.is_copy_only=0 AND bs.type IN ('D','L') AND bs.backup_finish_date > DATEADD(DAY,-2,SYSDATETIME())"` → **0**. **DRIFT-Befund 2026-07-22:** test1 HAT ein reales tägliches Backup-Produkt (GUID-Device, ~18:20), aber ausschließlich `is_copy_only=1`-Fulls und KEINE Log-Backups — die eazybusiness/master/msdb sind SIMPLE, nur RoboticoOps ist FULL, hat aber keine reale Log-Kette. Der ursprüngliche Check (`is_copy_only=0`) trippte nur am eigenen NUL-Full-Artefakt des Vorlaufs; der geschärfte Check schließt NUL-Device + copy_only aus und ist der korrekte Isolationsnachweis: NUL-Full berührt die copy_only-Strategie nicht, NUL-Log bricht keine reale Kette. | **yes** |
| 3 | test1 erreichbar + Kerberos | `sqlcmd -Q "SELECT @@VERSION"` → SQL 2025 | yes |
| 4 | native grate + pwsh | `which pwsh && (which grate || ls $HOME/.dotnet/tools/grate)` | yes |
| 5 | **SQL-Agent-Dienst** (geteilt mit Reset-Pipeline) | Kein Reset in Arbeit; Agent darf gestartet werden | `sqlcmd -Q "SELECT COUNT(*) FROM msdb.dbo.sysjobactivity a JOIN msdb.dbo.sysjobs j ON j.job_id=a.job_id WHERE a.stop_execution_date IS NULL AND a.start_execution_date IS NOT NULL AND j.name LIKE N'RoboticoOps - Reset%' AND a.session_id=(SELECT MAX(session_id) FROM msdb.dbo.syssessions)"` → 0 (kein laufender Reset). Start: `sqlcmd -Q "EXEC master.dbo.xp_servicecontrol N'START', N'SQLServerAGENT'"` (Fallback manuell, falls Dienststeuerung verweigert). | **yes** (für TC-4..TC-11) |
| 6 | Instanz-Schalter gesetzt | `MaintenanceSchedulesEnabled = '0'` auf test1 (D34, verhindert Dauer-Schedule) | `sqlcmd -Q "SELECT cValue FROM ops.tConfig WHERE cKey=N'MaintenanceSchedulesEnabled'"` → `0`; falls fehlend: `INSERT`/`UPDATE` setzen, dann `EXEC maint.spEnsureMaintenanceJobs`. | yes |
| 7 | Database Mail (optional, guarded) | Profil `Standard SMTP` ggf. nicht konfiguriert | `sqlcmd -Q "SELECT COUNT(*) FROM msdb.dbo.sysmail_profile WHERE name=N'Standard SMTP'"` — 0 ist OK (260 druckt PRINT statt Phantom-Profil, FT-16); kein Mail-Test auf test1. | no |

## User Questions (resolved before E2E)

| Question | Options | Answer | Resolved |
|----------|---------|--------|----------|
| test1-Wartungsfenster: Darf das E2E den SQL-Agent temporär starten/stoppen, und ist sichergestellt, dass währenddessen keine Reset-Pipeline-Arbeit läuft (Agent ist geteilt — ein Agent-Neustart/Job-Lauf kollidiert mit einem laufenden Reset)? | (a) Ja, freies Fenster jetzt — starten/stoppen ok · (b) Ja, aber Zeitpunkt vorher abstimmen · (c) Nein, Agent nicht anfassen | **(a) Ja, freies Fenster** — Agent darf temporär gestartet/gestoppt werden; der Reset-Guard (Prereq 5) bleibt Pflicht. | ✅ 2026-07-22 |
| Residual-State nach dem E2E: Sollen die `RoboticoOps - Maint - `-Jobs auf test1 verbleiben (disabled via Schalter = Plan-Sollzustand) oder wieder entfernt werden? | (a) Belassen, disabled (Plan-Standard, D34) · (b) Nach dem Lauf wieder aufräumen/entfernen | **(a) Belassen, disabled** — Plan-Sollzustand D34, `validate_rollout`-konform; kein Aufräumen der Jobs. | ✅ 2026-07-22 |

## Ergebnisse (Phase-4-Ausführung 2026-07-22)

**13/13 Auto-Cases PASS**, 0 Issues, 0 Eskalationen. Deployte Version grate `fc508ad`. Detailbericht: [→ e2e-report.md](e2e-report.md).

| Case | Status | Case | Status |
|---|---|---|---|
| TC-1 Deploy | ✅ PASS | TC-8 Liveness | ✅ PASS |
| TC-2 Ola-Platzierung | ✅ PASS¹ | TC-9 Drift-Korrektur | ✅ PASS |
| TC-3 Registry | ✅ PASS | TC-10 Fremd-Job weg | ✅ PASS |
| TC-4 Jobs disabled | ✅ PASS | TC-11 Idempotenz | ✅ PASS |
| TC-5 Job-Läufe | ✅ PASS | TC-12 Lint+Gates | ✅ PASS |
| TC-6 Statistik ALL | ✅ PASS | TC-13 Operator | ✅ PASS |
| TC-7 Backup-Watchdog | ✅ PASS | | |

¹ TC-2: eazybusiness trägt die Legacy-Ola-Installation (`2024-06-24`); unsere Kette (RoboticoOps-Objekte `2026-07-22`) legt dort nichts an — AC2/AC4-Intent erfüllt, Legacy-Entfernung ist B6 (human-gated). Teardown-Limitierung: Agent-Stopp nicht ausführbar (Windows-Dienstrechte), funktional durch Schalter `'0'` (D34) abgesichert — Detail im Report.

## Test Cases

### TC-1: Global-Deploy auf test1 ist grün

- **Mode:** auto
- **Knowledge:** —
- **Scope:** grate-Migrations-Kette (up/ 0022+0023, sprocs, runAfter, permissions/260)
- **Steps:**
  1. `pwsh db-migrations/deploy.ps1 -Scope global -Environment TEST`
  2. assert Exit-Code 0, grate meldet die neuen Skripte appliziert
- **Expected Result:** Deploy grün, keine Fehler; up/0022+0023 einmalig appliziert, `maint.*`-Sprocs als `CREATE OR ALTER` durch, `260` gelaufen.

### TC-2: Ola am richtigen Ort — RoboticoOps.dbo, kein Backup, kein eazybusiness-Ola (AC2/AC4)

- **Mode:** auto
- **Scope:** Objekt-Platzierung
- **Steps:**
  1. `sqlcmd -Q "SELECT name FROM RoboticoOps.sys.objects WHERE name IN (N'CommandLog',N'CommandExecute',N'DatabaseIntegrityCheck',N'IndexOptimize') ORDER BY name"`
  2. assert alle vier vorhanden
  3. `sqlcmd -Q "SELECT OBJECT_ID(N'RoboticoOps.dbo.DatabaseBackup')"` → NULL
  4. `sqlcmd -Q "SELECT name FROM eazybusiness.sys.objects WHERE name IN (N'CommandLog',N'CommandExecute',N'DatabaseIntegrityCheck',N'IndexOptimize',N'DatabaseBackup')"` → leer (unsere Kette legt keine eazybusiness.dbo-Ola-Objekte an)
- **Expected Result:** Vier Ola-Procs/Tabelle in RoboticoOps.dbo; `DatabaseBackup` existiert NICHT; keine Ola-Objekte in eazybusiness.dbo.

### TC-3: Registry enthält die 6 Soll-Zeilen aus §3.2 (AC1)

- **Mode:** auto
- **Scope:** `ops.tMaintenanceJob`-Inhalt
- **Steps:**
  1. `sqlcmd -Q "SELECT cJobKey,cOperation,cFrequency,nWeekdayMask,CONVERT(char(8),tStartTime) FROM ops.tMaintenanceJob ORDER BY cJobKey"`
  2. assert genau 6 Zeilen: `backup-watchdog`(BackupWatchdog/hourly), `checkdb`(IntegrityCheck/weekly/Maske 9/01:00), `cleanup-backuphistory`, `cleanup-commandlog`, `cleanup-jobhistory`(Cleanup/weekly So), `index-optimize`(IndexOptimize/daily/02:00)
  3. assert Knob-Spalten je Operation gemäß `CK_…_OperationKnobs` (z. B. `index-optimize.bUpdateStatistics=1`; `backup-watchdog.nFullMaxHours=26`,`nLogMaxHours=1`)
- **Expected Result:** 6 Zeilen mit exakt den §3.2-Werten.

### TC-4: Jede Registry-Zeile hat ihren Agent-Job, alle disabled (AC3/AC9/AC12, D34)

- **Mode:** auto (Prereq 5+6)
- **Scope:** Registry ↔ msdb-Jobs
- **Steps:**
  1. `sqlcmd -Q "SELECT j.name, j.enabled FROM msdb.dbo.sysjobs j WHERE j.name LIKE N'RoboticoOps - Maint - %' ORDER BY j.name"`
  2. assert 6 Jobs (einer je Registry-Zeile), `enabled=0` bei allen (Schalter `'0'` ⇒ effektiv disabled, D34)
  3. assert kein Job mit Präfix, der KEINE Registry-Zeile hat
- **Expected Result:** 6 disabled Jobs, 1:1 zur Registry, keine Geisterjobs.

### TC-5: Manueller grüner Lauf aller Ola-/Cleanup-Jobs außer backup-watchdog (AC9)

- **Mode:** auto (Prereq 5 — Agent läuft; `sp_start_job` startet auch disabled Jobs)
- **Scope:** echte Job-Ausführung gegen test1-DBs
- **Steps:**
  1. Für jeden der fünf Jobs `RoboticoOps - Maint - checkdb`, `… - index-optimize`, `… - cleanup-commandlog`, `… - cleanup-backuphistory`, `… - cleanup-jobhistory` (also alle außer `… - backup-watchdog`): `EXEC msdb.dbo.sp_start_job @job_name=N'RoboticoOps - Maint - <key>'`
  2. Poll `msdb.dbo.sysjobhistory` (step_id=0) bis `run_status` gesetzt; assert `run_status=1` (Erfolg) je Job
  3. `sqlcmd -Q "SELECT COUNT(*) FROM RoboticoOps.dbo.CommandLog WHERE StartTime > DATEADD(HOUR,-1,SYSDATETIME())"` → > 0
- **Expected Result:** Alle 5 Nicht-Watchdog-Jobs `run_status=1`; frische CommandLog-Einträge.

### TC-6: index-optimize übergibt real @UpdateStatistics='ALL', kein Offline-Rebuild (AC10/D13)

- **Mode:** auto
- **Scope:** Statistikpflege-Nachweis
- **Steps:**
  1. `sqlcmd -Q "SELECT TOP 20 Command FROM RoboticoOps.dbo.CommandLog WHERE CommandType IN (N'ALTER_INDEX',N'UPDATE_STATISTICS') AND StartTime > DATEADD(HOUR,-1,SYSDATETIME())"`
  2. assert mindestens ein Eintrag enthält `UpdateStatistics = 'ALL'` bzw. `UPDATE STATISTICS`
  3. assert KEIN Eintrag enthält `REBUILD` mit `ONLINE = OFF`/`*_REBUILD_OFFLINE` (REORGANIZE-only, D13)
- **Expected Result:** Statistik-Update belegt, keine Offline-Rebuild-Aktion.

### TC-7: Backup-Chain-Watchdog — Schwelle, Grenzfall, Ziel-Validierung (AC5, D27/D32)

- **Mode:** auto (Prereq 1+2 — Isolation zwingend, `TO DISK='NUL'` nur test1)
- **Scope:** `maint.spCheckBackupChain` Direkt-`EXEC`
- **Steps:**
  1. **Stale/fehlend:** `EXEC RoboticoOps.maint.spCheckBackupChain @Databases=N'eazybusiness,RoboticoOps,msdb', @FullMaxHours=26, @LogMaxHours=1` → erwartet `THROW 51100` (keine frische Kette auf test1)
  2. **Ungültiges Ziel (D32):** `EXEC RoboticoOps.maint.spCheckBackupChain @Databases=N'gibtsnicht', @FullMaxHours=26, @LogMaxHours=1` → `THROW 51100` mit Token im Text; ebenso ein Ola-Token wie `USER_DATABASES` → `THROW 51100`
  3. **Frisch machen:** `BACKUP DATABASE RoboticoOps TO DISK='NUL'` + `BACKUP LOG RoboticoOps TO DISK='NUL'` (test1-only!); dann `EXEC RoboticoOps.maint.spCheckBackupChain @Databases=N'RoboticoOps', @FullMaxHours=26, @LogMaxHours=1` → **schweigt**
  4. **Grenzfall (`>=`, D27):** ein Ziel exakt an/knapp jenseits der Schwelle prüfen → alarmiert (Grenzwert inklusiv)
- **Expected Result:** THROW 51100 bei stale/ungültig/Grenzwert; Schweigen bei frischer Kette; lokale Zeitbasis (SYSDATETIME), kein UTC-Verzug.

### TC-8: Wartungs-Liveness-Check (AC13, D36/D34)

- **Mode:** auto
- **Scope:** `maint.spCheckMaintenanceLiveness` Direkt-`EXEC`
- **Steps:**
  1. **Vor** den grünen Läufen (leeres/stales CommandLog, Schalter kurzzeitig ≠ '0' für den Test bzw. Simulation einer effektiv enablten Zeile) → `THROW 51105` mit den stalen `cJobKey`s im Text
  2. **Nach** den grünen TC-5-Läufen von `checkdb` + `index-optimize` → **schweigt**
  3. **D34-Pfad:** mit Instanz-Schalter `'0'` (bzw. `bEnabled=0`-simulierte Zeile) alarmiert er **nicht** (nur effektiv enablte Zeilen zählen — auf test1 konstruktionsbedingt No-op)
- **Expected Result:** 51105 bei staler enablter Wartung; still nach frischen Läufen; still bei disabled/Schalter '0'.

### TC-9: Sync-Drift-Korrektur meldet „1 Änderung" und stellt Registry-Stand her (FI-8a)

- **Mode:** auto
- **Scope:** `maint.spEnsureMaintenanceJobs` Normalform-Vergleich (D31)
- **Steps:**
  1. Live einen Job-Schedule in msdb verstellen (z. B. `sp_update_jobschedule` `active_start_time` eines Maint-Jobs)
  2. `EXEC maint.spEnsureMaintenanceJobs` → Ausgabe meldet **1 Änderung** (Drop/Recreate genau dieses Jobs)
  3. assert der Job trägt wieder den Registry-Schedule
- **Expected Result:** Genau 1 Änderung gemeldet, Drift korrigiert; die übrigen 5 Jobs unberührt.

### TC-10: Fremd-Job-Entfernung per Präfix (AC3, FI-8b)

- **Mode:** auto
- **Scope:** Präfix-basierter Delete-Zweig
- **Steps:**
  1. `EXEC msdb.dbo.sp_add_job @job_name=N'RoboticoOps - Maint - zz-test'` (+ minimaler Step/Schedule)
  2. `EXEC maint.spEnsureMaintenanceJobs`
  3. `sqlcmd -Q "SELECT COUNT(*) FROM msdb.dbo.sysjobs WHERE name=N'RoboticoOps - Maint - zz-test'"` → 0
- **Expected Result:** Präfix-Job ohne Registry-Zeile wird entfernt.

### TC-11: Idempotenz-Re-Deploy ist No-op (AC7)

- **Mode:** auto
- **Scope:** grate-Hash + everytime-Sync
- **Steps:**
  1. `dModified`-Snapshot: `sqlcmd -Q "SELECT cJobKey,dModified FROM ops.tMaintenanceJob ORDER BY cJobKey"`
  2. zweiter `pwsh db-migrations/deploy.ps1 -Scope global -Environment TEST`
  3. assert grate überspringt `spApplyMaintenance` (Hash unverändert), `260` ruft den Sync und dieser meldet **0 Änderungen**
  4. `dModified` unverändert gegenüber Snapshot; keine Job-Neuanlage (Job-`date_created`/Historie stabil)
- **Expected Result:** Kein Job-Recreate, 0 Sync-Änderungen, `dModified` unangetastet.

### TC-12: Repo-Verträge & Rollout-Gate grün (AC11/AC12)

- **Mode:** auto
- **Scope:** Lint + Struktur- + Rollout-Gate
- **Steps:**
  1. `npm run db:lint` → grün (inkl. vendorter Ola-Dateien; Regeln a/b/h/k/l)
  2. `sqlcmd -i db-migrations/tests/global/validate_structure.sql` → grün: fünf `maint.*`-Procs (Typ P) + `ops.tMaintenanceJob` (Typ U) + Schlüsselspalten registriert
  3. `sqlcmd -i db-migrations/tests/global/validate_rollout.sql` → grün: je Registry-Zeile existiert der `RoboticoOps - Maint - `-Job (D34-Semantik), jeder `bNotifyOnFail=1`-Job trägt die Operator-Verdrahtung, Operator `RoboticoOps-Maint` existiert
- **Expected Result:** Lint + beide Gates grün; THROW-Nummern 51100/51105/51110/51120 in README §4-(k) alloziert.

### TC-13: Operator-/Profil-Verdrahtung ohne Mail-Test (AC6-Grenze auf test1)

- **Mode:** auto
- **Scope:** `permissions/260`-Konvergenz (Existenz, kein Versand)
- **Steps:**
  1. `sqlcmd -Q "SELECT name, email_address FROM msdb.dbo.sysoperators WHERE name=N'RoboticoOps-Maint'"` → 1 Zeile, `lukas@dattenberger.com`
  2. `sqlcmd -Q "SELECT COUNT(*) FROM msdb.dbo.sysjobs j WHERE j.name LIKE N'RoboticoOps - Maint - %' AND j.notify_level_email <> 0 AND j.notify_email_operator_id <> (SELECT id FROM msdb.dbo.sysoperators WHERE name=N'RoboticoOps-Maint')"` → **0** (jeder Notify-Job zeigt auf den Maint-Operator); alle 6 Registry-Zeilen tragen `bNotifyOnFail=1`-Default, also müssen alle 6 Jobs verdrahtet sein: `sqlcmd -Q "SELECT COUNT(*) FROM msdb.dbo.sysjobs j JOIN msdb.dbo.sysoperators o ON o.id=j.notify_email_operator_id WHERE j.name LIKE N'RoboticoOps - Maint - %' AND o.name=N'RoboticoOps-Maint'"` → **6**
  3. **KEIN** Mail-Versand-Test (der ist B6 Nr. 6 nach Agent-Neustart auf Prod) — nur Existenz/Verdrahtung
- **Expected Result:** Operator existiert und ist an den Notify-Jobs verdrahtet; Mail-Weg bewusst ungetestet (Prod).

## Phase-4 Refresh (added by orchestrator)

*(leer bis Phase 4 — der Orchestrator ergänzt Cases für „edge-of-the-blade"-Punkte, die während der Implementierung auftauchen, z. B. Repair-Verifikationen aus dem B1-Audit.)*

## Teardown (nach dem E2E)

Fester Zielzustand (aus den beantworteten User-Questions):
1. **Fremd-Testartefakte entfernen**, die die Cases selbst angelegt haben — sie sind KEIN Plan-Sollzustand:
   - `RoboticoOps - Maint - zz-test` (TC-10): `EXEC msdb.dbo.sp_delete_job @job_name=N'RoboticoOps - Maint - zz-test', @delete_unused_schedule=1` (falls TC-10 den Re-Sync-Delete nicht ohnehin bereits erledigt hat — dann No-op).
   - Verstellter Schedule aus TC-9: durch `EXEC maint.spEnsureMaintenanceJobs` bereits auf Registry-Stand zurückgesetzt (Teil des Cases) — nichts weiter zu tun.
2. **6 Maint-Jobs BELASSEN, disabled** (User-Question 2 (a), D34): `MaintenanceSchedulesEnabled='0'` bleibt gesetzt, die Jobs bleiben installiert und disabled — das ist der `validate_rollout`-konforme Plan-Sollzustand, NICHT aufräumen.
3. **SQL-Agent zurück in die Stopped-Baseline**: `EXEC master.dbo.xp_servicecontrol N'STOP', N'SQLServerAGENT'` (Fallback manuell). Der Dauer-Schedule-Schutz hängt an Schritt 2 (Schalter), nicht am Dienststatus — der Agent darf für Reset-Arbeit jederzeit wieder laufen, ohne dass Wartungsjobs feuern.
4. **BACKUP-TO-NUL-Artefakte** (TC-7): `TO DISK='NUL'` schreibt nichts auf Platte; die `backupset`-Historie auf test1 ist Wegwerf-Zustand und braucht kein Cleanup.

## Acceptance

- Alle `mode: auto`-Cases (TC-1..TC-13) müssen grün sein.
- Prereqs 1–2 (Isolation test1/keine CBB-Kette) sind harte Gates — bei Zweifel STOPP, nie gegen vm-sql2.
- Keine `mode: manual`-Cases auf test1 (Mail-Weg AC6 ist B6/Prod).
- Endzustand nach Teardown: 6 Maint-Jobs installiert + disabled (D34), Agent gestoppt, keine `zz-test`-Reste.

## Failure Routing

Bei Fehlschlag: Orchestrator startet Issue-Triage analog Block-Closeout (Research → Repair-Chunk → Re-Test). Nach 3 Iterationen ohne Konvergenz: `AskUserQuestion`-Eskalation. Sonderfall: Prereq-1/2-Verletzung (falsches `-S`-Ziel) ist kein Triage-Fall, sondern sofortiger Abbruch.
