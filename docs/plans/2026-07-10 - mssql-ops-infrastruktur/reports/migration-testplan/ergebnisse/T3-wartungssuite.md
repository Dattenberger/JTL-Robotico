# Ergebnis — T3 Wartungssuite E2E im Linux-Container

**Ausgeführt:** 2026-07-27, Detail-Agent T3 (Opus), gegen Container `robotico-e2e-mssql` (`localhost,14330`, Env E2E, SQL-Auth sa).
**Server-Identität:** MachineName `3c2b38585482` / Developer Edition (64-bit) — Guard `E2E-GUARD ok` bei jedem schreibenden Skript.
**Sicherheit:** Nur gegen den lokalen Container. Keine Commits. PayPal-Staging unangetastet. Backups ausschließlich `TO DISK='NUL'`.

## Gesamtergebnis

| Kategorie | Anzahl |
|---|---|
| PASS | 18 |
| THROW-OK (THROW by design = PASS) | 4 |
| RUNTIME-OPEN / dokumentierend | 1 (T3-09) |
| FAIL / Finding | 0 |
| SKIP (Querverweis) | 1 (T3-21) |

24 Positionen (T3-01…T3-23 + T3-09b). **Kein einziger FAIL, kein unerwarteter THROW-Ausfall.**

**Endzustand:** GRÜN — Schalter `'0'`, 6 Maint-Jobs disabled (0 enabled), keine Fremd-/zz-Jobs, Registry 6 Soll-Zeilen, RoboticoOps-Recovery zurück auf FULL, künstliches Mail-Profil entfernt, Operator verdrahtet, Agent Running. `validate_rollout` + `db:validate:e2e` **OK**.

## Fall-für-Fall

| Fall | Status | Evidenz |
|---|---|---|
| T3-01 | PASS | 3 Schemata (maint/ops/reset); 5 `maint.*`-Procs (Typ P). Deploy exit 0. |
| T3-02 | PASS | 4 Ola-Objekte (CommandExecute/CommandLog/DatabaseIntegrityCheck/IndexOptimize) in `dbo`; `DatabaseBackup` = NULL (bewusst nicht vendored). |
| T3-03 | PASS | 6 Registry-Zeilen mit Soll-Knobs (checkdb weekly/Maske9/01:00, index-optimize daily/02:00/bUpdateStatistics=1, 3× cleanup weekly/365, backup-watchdog hourly/26/1). Alle bEnabled=1, bNotifyOnFail=1. |
| T3-04 | PASS | Operator `RoboticoOps-Maint`/`lukas@dattenberger.com`; alle 6 Jobs notify_level_email=2, Operator verdrahtet. |
| T3-05 | PASS | Operator-loser Ensure → notify0=6 (sp_delete_operator nullt Wiring, Ensure meldet 0 change); 260 → Operator neu + 6 Jobs "drifted — recreating" → notify2=6. D29-Selbstheilung belegt. |
| T3-06 | PASS | unset → 6 enabled (drift-recreate); `'0'` → 0 enabled. Effektiv-Gleichung bestätigt, Aufgaben-Formulierung widerlegt. |
| T3-07 | PASS | Redeploy exit 0; Ensure "0 change(s), 0 running-job skip(s)"; dModified unverändert (19:37:50). |
| T3-08 | PASS | Orphan-Zeile+Ensure → Job=1; spApplyMaintenance → Registry-DELETE (NOT MATCHED BY SOURCE) + Ensure "removed unregistered job" → reg=0/job=0; reiner Fremd-Job → Ensure "removed unregistered job" → 0. |
| T3-09 | RUNTIME-OPEN (dokumentierend) | regread initial NULL (kein Fehler); regwrite läuft fehlerfrei, 260 PRINT "…takes effect only after a SQL-AGENT RESTART"; **Rücklese-Wert nach regwrite = NULL** → XP-Registry-Pfad auf Linux nicht persistent/wirksam; effektive Agent-Mail-Nutzung unbewiesen (mssql-conf-Weg kanonisch). |
| T3-09b | PASS | Ohne `Standard SMTP`-Profil: 260 PRINT "…does not exist on this instance — agent mail profile NOT set", exit 0; Operator trotzdem angelegt. |
| T3-10 | PASS | Alle 5 Nicht-Watchdog-Jobs via `sp_start_job` gestartet trotz disabled (D34); run_status=1 (checkdb/index-optimize/3× cleanup). index-optimize lief ~8 min gegen eazybusiness (großes Ziel), Job succeeded. |
| T3-11 | PASS | Direkter Dispatcher `spRunMaintenanceJob @cJobKey='checkdb'` exit 0 → `DBCC CHECKDB([eazybusiness])` + alle 5 DBs, keine Konsistenzfehler. DBCC_CHECKDB (5 DBs: eazybusiness,master,model,msdb,RoboticoOps) + ALTER_INDEX + UPDATE_STATISTICS im CommandLog. index-optimize-Dispatcherlauf über den Agent-Jobstep (ruft dieselbe Proc). |
| T3-12 | PASS | 0× `REBUILD … ONLINE = OFF`; 89× `ALTER INDEX … REORGANIZE` (REORGANIZE-only, D13). `@UpdateStatistics='ALL'` (Proc Z.67) belegt durch 4335 `UPDATE_STATISTICS` inkl. Spalten-Stats (`_WA_Sys_*`). NB: „WITH … ALL" ist der Proc-Parameter (Index+Spalten-Stats), kein T-SQL-Klausel-Literal. |
| T3-13 | THROW-OK | THROW 51100 (Line 102) "STALE backup chain — msdb/RoboticoOps: last FULL NEVER; RoboticoOps: last LOG NEVER" (RoboticoOps=FULL → Log-Zweig aktiv). |
| T3-14 | THROW-OK | `gibtsnicht` → 51100 (Line 58) invalid target; `USER_DATABASES` → 51100 invalid target (Ola-Token abgelehnt); `eazybusiness,…` → 51100 freshness-NEVER (Line 102), da eazybusiness ONLINE → Invalid-Target-Zweig nicht getroffen. Beide Zweige belegt. |
| T3-15 | PASS | (1) FULL + frischer Full ohne Log → THROW 51100 "last LOG NEVER"; (2) FULL + Full + Log → **schweigt** (exit 0); (3) SIMPLE + Full → **schweigt** (SIMPLE → Log-Check ausgeblendet, D27). SIMPLE-Blindheit belegt. |
| T3-16 | THROW-OK | frischer Full + `@FullMaxHours=0` → THROW 51100 "last FULL … (max 0h)" — `<=`-Vergleich macht Grenze inklusiv (kein Off-by-one). |
| T3-17 | PASS | Schalter `'0'` → `spCheckMaintenanceLiveness` schweigt, exit 0, kein THROW. |
| T3-18 | PASS | unset (effektiv enabled) + First-Run-Grace → liveness schweigt trotz fehlender Heartbeats (dModified jung < Fenster), exit 0. |
| T3-19 | THROW-OK | unset + CommandLog geleert + dModified der IntegrityCheck/IndexOptimize-Rows −30 Tage → THROW 51105 "no sufficiently fresh CommandLog entry … : checkdb, index-optimize. The \"never runs\" pattern (F3/F4) is live again". |
| T3-20 | PASS (dokumentierend) | `UPDATE_STATISTICS`-Heartbeat > 0 (4335, Registry-Default bUpdateStatistics=1). stats-off-False-Fire nicht laufzeittestbar (keine Seed-Zeile) — als Blind-Spot ausgewiesen. |
| T3-21 | SKIP | Querverweis auf T3-06 (Schalter-Matrix) — kein separater Fall. |
| T3-22 | PASS | zz-long RUNNING → Ensure "is RUNNING — removal skipped", "1 running-job skip", Job bleibt; nach Job-Ende Ensure → Job entfernt. |
| T3-23 | PASS | 6 Maint-Jobs + 1 `RoboticoOps - Testmandant Reset` nebeneinander im geteilten Agent; Reset enabled=1, Maint disabled; kein Namens-/Owner-Konflikt. |

## Grenzen / dokumentierte Blind-Spots (§9 Plan)

- **T3-09 (xp_instance_reg\* Linux):** regread/regwrite laufen fehlerfrei, aber der geschriebene Wert ist per regread NICHT zurücklesbar (NULL) → auf Linux kein wirksamer XP-Pfad; effektive Mail-Nutzung nur über `mssql-conf sqlagent.databasemailprofile` (nicht im Container-Scope).
- **Echter Database-Mail-Versand:** out of scope (kein SMTP-Profil). Operator-Notify-Wiring strukturell verifiziert (T3-04), Versand nicht.
- **CEST-Zeitbasis-Bug:** im UTC-Container konstruktionsbedingt nicht reproduzierbar.
- **stats-off IndexOptimize-False-Fire (T3-20):** keine `bUpdateStatistics=0`-Seed-Zeile → nicht laufzeittestbar; per Registry-CHECK abgesichert.

## Endzustand-Wiederherstellung

Nach allen Fällen bewusst in den Plan-Sollzustand zurückgeführt (verifiziert):

| Aspekt | Sollwert | Verifiziert |
|---|---|---|
| Schalter `MaintenanceSchedulesEnabled` | `'0'` | ✓ |
| Maint-Jobs | 6, alle disabled (`EXEC maint.spEnsureMaintenanceJobs` konvergiert, 0 change) | ✓ enabled=0 |
| Fremd-/zz-Jobs + zz-Registry-Zeilen | keine | ✓ zz_jobs=0, zz_reg=0 |
| Registry `ops.tMaintenanceJob` | 6 Soll-Zeilen, dModified via `spApplyMaintenance` neu gesetzt (T3-19-Rückdatierung aufgehoben) | ✓ reg_rows=6 |
| RoboticoOps Recovery-Model | FULL (Container-Ausgangswert) — nach T3-15 SIMPLE zurückgestellt | ✓ FULL |
| Künstliches Mail-Profil `Standard SMTP` | entfernt (T3-09c) | ✓ 0 |
| Operator `RoboticoOps-Maint` | verdrahtet | ✓ 1 |
| SQL Agent | Running | ✓ |
| Abschluss-Gate | `validate_rollout: OK … maintenance jobs/operator wired.` + `npm run db:validate:e2e` → **Rollout validation OK** | ✓ |

Backups ausschließlich `TO DISK='NUL'` (keine reale Kette berührt). Keine Server-Writes außerhalb des Containers, keine Commits, PayPal-Staging unangetastet.
