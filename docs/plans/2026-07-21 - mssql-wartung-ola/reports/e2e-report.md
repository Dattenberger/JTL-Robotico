# E2E-Testbericht: mssql-wartung-ola

**Runbook:** [→ e2e-runbook.md](e2e-runbook.md)
**Plan:** [→ ../mssql-wartung-ola.md](../mssql-wartung-ola.md)
**Ausgeführt:** 2026-07-22, autonome Phase-4-E2E (Fable 5)
**Ziel:** vm-sql-test1.zdbikes.local (SQL 2025, `VM-SQL-TEST1`) — test1 only, vm-sql2 nie berührt
**Deployte Version:** grate `fc508ad` (planStartCommit `d722993` → HEAD `fc508ad`)
**Ergebnis:** **13/13 Auto-Cases PASS**, 0 manuelle Cases, 0 Issues, 0 Eskalationen. Eine Teardown-Limitierung (Agent-Stopp nicht möglich, funktional folgenlos, s. u.).

## Zusammenfassung

| Zähler | Wert |
|---|---|
| Auto-Cases gesamt | 13 |
| PASS | 13 |
| FAIL | 0 |
| BLOCKED | 0 |
| Manuelle Cases | 0 (Mail-Weg AC6 = B6/Prod, außerhalb Scope) |
| Issues (Critical/Important/Nice) | 0 / 0 / 0 |

## Drift-Research (vor Ausführung)

Diff `d722993..HEAD`: 4 Commits (Erst-Impl `923b6c7`, Self-Fix `217314a`, Repair-Wave-1 `2a420d6`, Repair-Wave-2 `fc508ad`). Alle 8 neuen + 7 editierten Dateien wie geplant geliefert.

Verifiziert gegen die Runbook-Erwartungen — **keine substanzielle Drift**:
- Registry-Seed (`maint.spApplyMaintenance.sql`): 6 Zeilen exakt wie §3.2 (checkdb weekly Maske 9 01:00, index-optimize daily 02:00 bUpd=1, 3 Cleanups weekly, backup-watchdog hourly 26/1).
- Proc-Signaturen: `spCheckBackupChain(@Databases,@FullMaxHours,@LogMaxHours)`, `spRunMaintenanceJob(@cJobKey)` wie erwartet.
- THROW-Nummern: 51100 (BackupChain, stale+invalid target), 51105 (Liveness), 51120 (RunMaintenanceJob unknown/unsupported key) — wie Runbook.
- Operator `RoboticoOps-Maint` / `lukas@dattenberger.com`, konstanter Dispatch-Step — bestätigt.

Zwei **Umwelt-Drifts** gegenüber den Runbook-Annahmen erkannt und Cases angepasst (statt blind zu scheitern):
1. **test1 HAT ein reales Backup-Regime** (GUID-Device, täglich ~18:20), aber ausschließlich `is_copy_only=1`-Fulls und **keine** Log-Backups. eazybusiness/master/msdb sind SIMPLE, nur RoboticoOps FULL (ohne reale Log-Kette). → Prereq-2-Check geschärft (schließt NUL-Device + copy_only aus): `BACKUP … TO NUL` berührt weder die copy_only-Strategie noch eine reale Log-Kette. Isolation gewahrt.
2. **test1 trägt die Legacy-Ola-Installation** in `eazybusiness.dbo` (CommandLog/DatabaseBackup/DatabaseIntegrityCheck, `create_date = 2024-06-24` — exakt das im Plan dokumentierte Altdatum). → TC-2 auf Provenienz-Nachweis präzisiert: unsere Kette (RoboticoOps-Objekte `2026-07-22`) legt **keine** eazybusiness-Ola-Objekte an; die Legacy entfernt B6 (human-gated, außerhalb Scope).

## Pre-Flight (alle bestanden)

| # | Check | Ergebnis |
|---|---|---|
| 1 | Isolation: `@@SERVERNAME` = `VM-SQL-TEST1`, nie vm-sql2 | PASS |
| 2 | Isolation: keine fremde recoverable Kette (non-NUL, non-copy-only, 2 Tage) | PASS (0; geschärfter Check, s. Drift 1) |
| 3 | Konnektivität + Kerberos (SQL 2025) | PASS |
| 4 | pwsh + native grate `~/.dotnet/tools/grate` (v1.6.0) | PASS |
| 5 | kein Reset-Job laufend (geteilter Agent) | PASS (0) |
| 6 | Schalter `MaintenanceSchedulesEnabled` = `'0'` (in RoboticoOps.ops.tConfig) | PASS |
| 7 | Database-Mail-Profil `Standard SMTP` (guarded) | absent (0) — OK, 260 druckt PRINT statt Phantom (FT-16) |

## Case-Ergebnisse

| Case | Status | Evidenz (Kurz) |
|---|---|---|
| TC-1 Deploy grün | **PASS** | `deploy.ps1 -Scope global -Environment TEST` exit 0; grate `d722993→fc508ad`; 3 Repair-Wave-Sprocs re-run, up/ unverändert |
| TC-2 Ola-Platzierung | **PASS** | Ola-4 in RoboticoOps.dbo (created `2026-07-22`); `RoboticoOps.dbo.DatabaseBackup` absent (OBJECT_ID=NULL); eazybusiness-Ola = Legacy `2024-06-24` (nicht von unserer Kette; Ziel-DB=RoboticoOps) |
| TC-3 Registry 6 Zeilen | **PASS** | 6 Zeilen exakt §3.2 (Keys/Operation/Frequency/Maske/Startzeit/Knobs) |
| TC-4 Jobs disabled | **PASS** | 6 `RoboticoOps - Maint - `-Jobs, alle `enabled=0`, kein Präfix-Job ohne Registry-Zeile |
| TC-5 Job-Läufe grün | **PASS** | checkdb + index-optimize + 3 Cleanups je `run_status=1`; CommandLog +8599 Einträge |
| TC-6 Statistik `ALL` | **PASS** | 8594 `UPDATE_STATISTICS`-Einträge/10 min (alter defekter Job: 0); 0 `*_REBUILD_OFFLINE` (D13) |
| TC-7 Backup-Watchdog | **PASS** | stale→51100; `gibtsnicht`/`USER_DATABASES`→51100 mit Token; nach BACKUP-NUL-Full+Log→SILENT; `@FullMaxHours=0`→51100 (inklusive `>=`-Grenze) |
| TC-8 Liveness | **PASS** | Alarm-Pfad (dModified −10 d + CommandLog stale + switch='1')→51105 mit `checkdb`; healthy (switch='1', frisch)→SILENT; D34-No-op (switch='0')→SILENT; First-Run-Grace L-B1-2 mitvalidiert; alles transaktional zurückgerollt |
| TC-9 Drift-Korrektur | **PASS** | checkdb-Startzeit 01:00→05:00 verstellt → Ensure „1 change(s)" + „drifted — recreating" → Startzeit 010000 wiederhergestellt |
| TC-10 Fremd-Job weg | **PASS** | `zz-test` per sp_add_job → Ensure „removed unregistered job [zz-test]" + „1 change(s)" → entfernt (0); 6 Registry-Jobs bleiben |
| TC-11 Idempotenz | **PASS** | 2. Deploy: runAfter „No sql run" (MERGE lief nicht); dModified identisch; Ensure „0 change(s)"; checkdb-Job nicht neu angelegt |
| TC-12 Lint+Gates | **PASS** | `db:lint` exit 0, 0 errors (2 Warnings in fremdem `reset.spInternal_GrantAccess.sql`); `validate_structure` OK (maint.*/ops.* präsent); `validate_rollout` OK (maintenance jobs/operator wired) |
| TC-13 Operator-Verdrahtung | **PASS** | Operator `RoboticoOps-Maint`/`lukas@dattenberger.com`; 6 Notify-Jobs korrekt verdrahtet, 0 falsch; kein Mail-Test (AC6=B6/Prod) |

## Issues

Keine. Kein Case gescheitert, kein unerwartetes Verhalten. Ein zunächst „nicht geworfener" Liveness-Alarm (TC-8 erster Versuch) war **kein Defekt**, sondern der korrekt greifende First-Run-Grace (L-B1-2): frisch geseedete Registry-Zeilen (`dModified = heute`) sind jünger als ein Schedule-Fenster und können definitionsgemäß noch nicht stale sein. Der Case wurde faithful nachgestellt (dModified über das Fenster gealtert) → Alarm wie erwartet.

## Teardown

- **zz-test-Fremd-Job:** entfernt (durch TC-10 selbst).
- **6 Maint-Jobs:** installiert + disabled belassen (`enabled_sum=0`), Schalter `'0'` gesetzt — Plan-Sollzustand D34, `validate_rollout`-konform (User-Question 2 (a)).
- **BACKUP-TO-NUL-Artefakte:** belassen (folgenlos, verifiziert — keine reale Kette gestört).
- **SQL-Agent Stopped-Baseline: NICHT ausführbar.** Der Agent lief bereits **vor** dieser Session (nicht von mir gestartet); der Stopp via `xp_servicecontrol STOP` scheitert an „Zugriff verweigert" (Fehler 5) — das Kerberos-SQL-Login ist sysadmin in SQL, hat aber keine Windows-Dienststeuerungs-Rechte. **Funktional folgenlos:** der Dauer-Schedule-Schutz hängt per Design (D34) am Schalter `'0'`, nicht am Dienststatus — bei laufendem Agent feuert dennoch kein Wartungsjob (das ist genau der Zweck des D34-Schalters, damit der geteilte Agent für Reset-Arbeit laufen darf). Wenn die Stopped-Baseline dennoch gewünscht ist, ist das ein manueller Schritt für jemanden mit Windows-/Dienst-Rechten.

## Endzustand test1 (verifiziert)

- 6 `RoboticoOps - Maint - `-Jobs, alle disabled; kein `zz-test`.
- `ops.tConfig('MaintenanceSchedulesEnabled') = '0'`.
- `ops.tMaintenanceJob`: 6 Zeilen, `dModified` unverändert (`2026-07-22 20:04:59`).
- Ola-4 in RoboticoOps.dbo, `DatabaseBackup` absent.
- SQL-Agent: Running (nicht stoppbar, s. Teardown — durch Schalter abgesichert).
