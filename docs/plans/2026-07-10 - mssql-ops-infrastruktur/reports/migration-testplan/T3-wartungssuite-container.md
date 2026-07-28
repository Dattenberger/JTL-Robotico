---
date: 2026-07-27
author: Detail-Agent T3 (Opus) — Migrations-Testplan Phase 2
status: Testplan — ausführbereite Fälle, NOCH NICHT ausgeführt
context: T3-Themengebiet „Wartungssuite E2E im Linux-Container" (höchste Neuheit — bisher NUR auf test1/SQL 2025 getestet, nie im Container). Baut auf 00-grundrecherche.md (F3.*) und 03-teilrecherche-ebene-a-wartung.md §3 auf. Vorbild: archiviertes Wartungs-E2E (2026-07-21 - mssql-wartung-ola/reports/e2e-runbook.md, 13 test1-Cases).
related-plan: ../../mssql-ops-infrastruktur.md
related-plan-2: ../../../2026-07-21 - mssql-wartung-ola/mssql-wartung-ola.md
depends-on: T5 (Container-Aufbau + optionale eazybusiness-Restore) — Enabler für alle Cases
interface-to: T2 (geteilter Agent Reset↔Wartung — Kernfall hier einmal, Detail bei T2)
---

# T3 — Wartungssuite E2E im Linux-Container (Testplan)

## 0. Kernbefund vorab (Korrektur zur Aufgabenstellung)

> [!IMPORTANT]
> **Der Schalter `MaintenanceSchedulesEnabled` ist NIRGENDS geseedet** (bestätigt:
> `grep` über `db-migrations/global/up/*` findet keinen Insert; `README.md:397`). Die
> Effektiv-Enabled-Gleichung ist in allen drei Verbrauchern identisch:
> `bEnabled = 1 AND ops.tConfig('MaintenanceSchedulesEnabled') <> '0'`, und
> **fehlender Key = enabled** (`spEnsureMaintenanceJobs.sql:49-52`,
> `spCheckMaintenanceLiveness.sql:61-64`). Daraus folgt der zentrale Container-Unterschied
> zu test1: **Der Erstlauf im frischen Container erzeugt die Jobs ENABLED** (Registry
> `bEnabled=1` × Key-unset), NICHT disabled. Test1 setzte den Key explizit auf `'0'`
> (E2E-Runbook Prereq 6). Die Formulierung der Aufgabenstellung „Jobs entstehen disabled
> bei Schalter unset/'0'" ist für **unset** falsch — sie stimmt nur für `'0'`. Das ist
> selbst ein Prüfpunkt (T3-06) und bestimmt die Setup-Strategie (§2.3).

## 1. Scope & Abgrenzung

**Abgedeckt (im Container real testbar):** die vier vendored Ola-Objekte
(`up/0022`); Registry `ops.tMaintenanceJob` (`up/0023`) + wertegeguardeter MERGE
(`spApplyMaintenance`); die fünf `maint.*`-Prozeduren; Deploy-Konvergenz inkl. D29
(Operator-Notify) und AC7 (0-change-Redeploy); MERGE-Removal-Pfad; `xp_instance_reg*`
unter Linux (Verhaltensfrage); reale Job-Ausführung via `sp_start_job`; die
Backup-Chain-Watchdog-Falsch-Alarm-Matrix; Liveness First-Run-Grace + Staleness;
Schalter-Matrix; Running-Job-Guard; Koexistenz mit dem Reset-Job im geteilten Agent.

**Außerhalb Scope (Grenzen, §9):** echter Database-Mail-Versand (nur Struktur/PRINT-Pfad;
Mail = B6/Prod); CBB-Backup-Kette (extern); der CEST-Zeitbasis-Bug (im UTC-Container
konstruktionsbedingt nicht reproduzierbar); Agent-Mail-Profil-Wirksamkeit nach echtem
Agent-Restart in Prod. `vm-sql2`/Prod und test1 sind **tabu**.

## 2. Voraussetzungen & Setup

### 2.1 Container (T5-Enabler)

Container `robotico-e2e-mssql`, SQL 2022, `MSSQL_AGENT_ENABLED=true`,
`MSSQL_COLLATION=Latin1_General_CI_AS`, Host-Port 14330 (`tests/docker/README.md`).
Hochfahren + Ebene-B-Deploy (Wartungssuite lebt komplett in Ebene B / RoboticoOps —
**braucht keine restaurierte eazybusiness** für den Kern):

```bash
npm run db:e2e:up                              # setup.ps1: Secrets, up -d, healthy, SELECT 1 + Agent Running + Collation
set -a; source db-migrations/tests/docker/.env.local; set +a   # MSSQL_SA_PASSWORD in die Shell
npm run db:deploy:e2e:global                   # grate Ebene B -> RoboticoOps (Docker-Runner erikbra/grate:1.6.0)
```

Die eazybusiness-Restore (T5, excel_ekl-Trim-Pipeline) ist **nur** für die Watchdog-
Valid-Target-Fälle (T3-14/15) und die Koexistenz (T3-23) nötig; alle übrigen Fälle
laufen gegen die reine RoboticoOps-Instanz.

### 2.2 sqlcmd-Aufruf (SQL-Auth, Container)

Alle Snippets nutzen diesen Aufruf (ODBC-Build, TrustServerCertificate):

```bash
SQLCMD() { /opt/mssql-tools18/bin/sqlcmd -S localhost,14330 -U sa -P "$MSSQL_SA_PASSWORD" -C -b "$@"; }
```

`-b` = non-zero Exit bei THROW (nötig, um „erwartet ROT" maschinell zu werten).

### 2.3 Setup-Strategie zum Schalter (Konsequenz aus §0)

Zwei Test-Phasen bewusst getrennt:

- **Phase A — kontrolliert (Default für die meisten Fälle):** Schalter VOR dem ersten
  Deploy auf `'0'` setzen (wie test1), damit kein unkontrollierter Live-Schedule feuert.
  Da `up/0001` den Key nicht anlegt und die Grants der Registry nur SELECT sind, aber
  `ops.tConfig` normal beschreibbar ist:
  ```bash
  SQLCMD -Q "IF NOT EXISTS (SELECT 1 FROM RoboticoOps.ops.tConfig WHERE cKey=N'MaintenanceSchedulesEnabled') INSERT RoboticoOps.ops.tConfig(cKey,cValue) VALUES(N'MaintenanceSchedulesEnabled',N'0'); ELSE UPDATE RoboticoOps.ops.tConfig SET cValue=N'0' WHERE cKey=N'MaintenanceSchedulesEnabled';"
  # danach Sync nachziehen, damit die Jobs den disabled-Zustand übernehmen:
  SQLCMD -Q "EXEC RoboticoOps.maint.spEnsureMaintenanceJobs;"
  ```
- **Phase B — prod-nah (dedizierte Fälle T3-06/17/18/21):** Key entfernen (unset) →
  Jobs enabled → prüfen, dass Liveness/Sync die Prod-Semantik zeigen.

> [!NOTE]
> **Warum überhaupt Phase A:** Im frischen Container feuert der `backup-watchdog`
> (hourly, Anker 00:00) bei enabled-Zustand innerhalb einer Stunde und THROWt 51100
> (keine Backup-Kette) — harmlos (Mail schweigt mangels Profil), aber unkontrolliert.
> `'0'` macht das Testfenster deterministisch; `sp_start_job` startet die Jobs trotzdem
> manuell (README:397, D34), sodass Phase A die Ausführung nicht behindert.

### 2.4 Servername-Guard (Pflicht-Kopf jedes schreibenden Skripts, §3.4 Grundrecherche)

```sql
IF UPPER(CONVERT(sysname, SERVERPROPERTY('MachineName'))) LIKE N'VM-SQL%'
   OR @@SERVERNAME LIKE N'vm-sql%'
    THROW 59999, N'ABORT: Ziel sieht aus wie test1/prod — Wartungs-Testskript verweigert Ausführung.', 1;
```
Der Container-Servername ist der Container-Host (Hex-ID), nie `VM-SQL2`/`VM-SQL-TEST1` —
der Guard trippt also nur bei versehentlichem Fehl-Ziel.

---

## 3. Deploy-Konvergenz & Idempotenz

### T3-01 — Global-Deploy grün, up/0022+0023 einmalig, sprocs/260 durch
- **Setup:** frischer Container, Ebene-B-Deploy (§2.1).
- **Snippet:** Deploy-Exit-Code prüfen; danach Objekt-Existenz.
  ```bash
  npm run db:deploy:e2e:global    # Exit 0
  SQLCMD -Q "SELECT name FROM RoboticoOps.sys.schemas WHERE name IN (N'ops',N'maint',N'reset') ORDER BY name;"
  SQLCMD -Q "SELECT name FROM RoboticoOps.sys.objects WHERE name IN (N'spEnsureMaintenanceJobs',N'spRunMaintenanceJob',N'spCheckBackupChain',N'spCheckMaintenanceLiveness',N'spApplyMaintenance') ORDER BY name;"
  ```
- **Erwartet:** Exit 0; Schemata `maint`/`ops`/`reset` vorhanden; alle fünf `maint.*`-Procs (Typ P).

### T3-02 — Ola am richtigen Ort (RoboticoOps.dbo), kein DatabaseBackup (AC2/AC4)
- **Snippet:**
  ```bash
  SQLCMD -Q "SELECT name FROM RoboticoOps.sys.objects WHERE name IN (N'CommandLog',N'CommandExecute',N'DatabaseIntegrityCheck',N'IndexOptimize') ORDER BY name;"
  SQLCMD -Q "SELECT OBJECT_ID(N'RoboticoOps.dbo.DatabaseBackup');"
  ```
- **Erwartet:** genau die vier Objekte in `RoboticoOps.dbo`; `DatabaseBackup` = NULL (bewusst nicht vendored, ADR-0002/CBB, `up/0022:14-15`).

### T3-03 — Registry hat die 6 Soll-Zeilen inkl. Knob-Spalten (AC1)
- **Snippet:**
  ```bash
  SQLCMD -Q "SELECT cJobKey,cOperation,cFrequency,nWeekdayMask,CONVERT(char(8),tStartTime) t,bUpdateStatistics,cCleanupTarget,nRetentionDays,nFullMaxHours,nLogMaxHours,bEnabled,bNotifyOnFail FROM RoboticoOps.ops.tMaintenanceJob ORDER BY cJobKey;"
  ```
- **Erwartet:** 6 Zeilen mit den `spApplyMaintenance.sql:42-47`-Werten:
  `checkdb`(IntegrityCheck/weekly/Maske 9/01:00), `index-optimize`(IndexOptimize/daily/02:00/bUpdateStatistics=1),
  `cleanup-commandlog`(Cleanup/CommandLog/365), `cleanup-backuphistory`(Cleanup/BackupHistory/365),
  `cleanup-jobhistory`(Cleanup/JobHistory/365), `backup-watchdog`(BackupWatchdog/hourly/nFullMaxHours=26/nLogMaxHours=1).
  Alle `bEnabled=1`, `bNotifyOnFail=1`. Der `CK_tMaintenanceJob_OperationKnobs`-CHECK erzwingt,
  dass fremde Knobs NULL sind — implizit durch den Deploy verifiziert.

### T3-04 — D29-Konvergenz: Notify-Verdrahtung im End-Zustand nach Voll-Deploy (AC6)
- **Kontext:** grate läuft `runAfterOtherAnyTimeScripts/` (spApplyMaintenance → ensure, Operator existiert noch nicht → NotifyLevel 0) VOR `permissions/260` (legt Operator an + ruft ensure unconditional → Drift → Recreate mit Notify). Der **End**-Zustand eines Voll-Deploys ist bereits konvergiert.
- **Snippet:**
  ```bash
  SQLCMD -Q "SELECT j.name, j.notify_level_email, o.name AS op FROM msdb.dbo.sysjobs j LEFT JOIN msdb.dbo.sysoperators o ON o.id=j.notify_email_operator_id WHERE j.name LIKE N'RoboticoOps - Maint - %' ORDER BY j.name;"
  SQLCMD -Q "SELECT name,email_address FROM msdb.dbo.sysoperators WHERE name=N'RoboticoOps-Maint';"
  ```
- **Erwartet:** Operator `RoboticoOps-Maint`/`lukas@dattenberger.com` existiert; alle 6 Jobs `notify_level_email=2` und Operator=`RoboticoOps-Maint` (`260:39-46`, `spEnsureMaintenanceJobs.sql:93-94`).

### T3-05 — D29-Zwischenzustand bewusst reproduzieren (Ensure ohne Operator → NotifyLevel 0)
- **Zweck:** den durch 260 versöhnten Übergang sichtbar machen (im Voll-Deploy unsichtbar, weil beide Stufen laufen).
- **Snippet:**
  ```bash
  # Operator-losen Zustand erzwingen und NUR den Sync fahren:
  SQLCMD -Q "IF EXISTS(SELECT 1 FROM msdb.dbo.sysoperators WHERE name=N'RoboticoOps-Maint') EXEC msdb.dbo.sp_delete_operator @name=N'RoboticoOps-Maint';"
  SQLCMD -Q "EXEC RoboticoOps.maint.spEnsureMaintenanceJobs;"       # Operator fehlt -> Drift -> Recreate mit NotifyLevel 0
  SQLCMD -Q "SELECT COUNT(*) AS notify0 FROM msdb.dbo.sysjobs WHERE name LIKE N'RoboticoOps - Maint - %' AND notify_level_email=0;"   # erwartet 6
  # 260 nachfahren (Operator anlegen + unconditional ensure):
  SQLCMD -i db-migrations/global/permissions/260_maintenance_operator.sql -d RoboticoOps
  SQLCMD -Q "SELECT COUNT(*) AS notify2 FROM msdb.dbo.sysjobs WHERE name LIKE N'RoboticoOps - Maint - %' AND notify_level_email=2;"   # erwartet 6
  ```
- **Erwartet:** nach dem operator-losen Ensure 6 Jobs mit NotifyLevel 0; nach 260 6 Jobs mit NotifyLevel 2. Belegt den D29-Selbstheilungspfad (`260:14-18`).
- **Hinweis:** `260` enthält mehrere `GO`-Batches; als `-i`-Datei direkt gegen `RoboticoOps` fahrbar (die XP-Regwrite-Stufe ist gegen fehlendes Mail-Profil geguarded, s. T3-09).

### T3-06 — Effektiv-Enabled-Gleichung: unset=enabled vs. '0'=disabled (F3.6, D34)
- **Snippet (Phase B, unset):**
  ```bash
  SQLCMD -Q "DELETE RoboticoOps.ops.tConfig WHERE cKey=N'MaintenanceSchedulesEnabled'; EXEC RoboticoOps.maint.spEnsureMaintenanceJobs;"
  SQLCMD -Q "SELECT COUNT(*) AS enabled_jobs FROM msdb.dbo.sysjobs WHERE name LIKE N'RoboticoOps - Maint - %' AND enabled=1;"   # erwartet 6
  # dann '0' (Phase A):
  SQLCMD -Q "IF NOT EXISTS(SELECT 1 FROM RoboticoOps.ops.tConfig WHERE cKey=N'MaintenanceSchedulesEnabled') INSERT RoboticoOps.ops.tConfig(cKey,cValue) VALUES(N'MaintenanceSchedulesEnabled',N'0'); ELSE UPDATE RoboticoOps.ops.tConfig SET cValue=N'0' WHERE cKey=N'MaintenanceSchedulesEnabled'; EXEC RoboticoOps.maint.spEnsureMaintenanceJobs;"
  SQLCMD -Q "SELECT COUNT(*) AS enabled_jobs FROM msdb.dbo.sysjobs WHERE name LIKE N'RoboticoOps - Maint - %' AND enabled=1;"   # erwartet 0
  ```
- **Erwartet:** unset → 6 enabled Jobs; `'0'` → 0 enabled Jobs (alle disabled). Der Sync wechselt den enabled-State ohne Job-Neuanlage nur, wenn `enabled` driftet (Drop/Recreate genau dieser Jobs; Historieverlust akzeptiert). **Widerlegt die Aufgaben-Formulierung** (§0).

### T3-07 — Zweitlauf „0 change(s)" (AC7, Idempotenz)
- **Snippet:**
  ```bash
  SQLCMD -Q "SELECT cJobKey,dModified FROM RoboticoOps.ops.tMaintenanceJob ORDER BY cJobKey;"   # Snapshot
  npm run db:deploy:e2e:global      # zweiter Deploy
  SQLCMD -Q "EXEC RoboticoOps.maint.spEnsureMaintenanceJobs;"   # explizit, um die PRINT-Zeile zu sehen
  SQLCMD -Q "SELECT cJobKey,dModified FROM RoboticoOps.ops.tMaintenanceJob ORDER BY cJobKey;"   # unverändert?
  ```
- **Erwartet:** grate überspringt `spApplyMaintenance` (Hash unverändert); der Sync-PRINT meldet `0 change(s), 0 running-job skip(s)` (`spEnsureMaintenanceJobs.sql:266-268`); `dModified` je Zeile unverändert (MERGE `IS DISTINCT FROM`, kein Churn, `spApplyMaintenance.sql:54-68`); keine `date_created`-Änderung der Jobs.

### T3-08 — MERGE Removal-Pfad: NOT MATCHED BY SOURCE DELETE + Job-Entfernung (AC3)
- **Zweck:** Removal-Zweig des MERGE + präfixbasierter Delete-Zweig des Sync in einem Fall.
- **Snippet:**
  ```bash
  # a) Fremd-Registry-Zeile künstlich (simuliert eine entfernte Seed-Zeile beim nächsten Apply):
  SQLCMD -Q "INSERT RoboticoOps.ops.tMaintenanceJob(cJobKey,cDisplayName,cOperation,cDatabases,cFrequency,tStartTime,cCleanupTarget,nRetentionDays,bEnabled,bNotifyOnFail) VALUES(N'zz-orphan',N'RoboticoOps - Maint - zz-orphan',N'Cleanup',N'RoboticoOps',N'weekly',NULL,N'CommandLog',30,1,1);"
  # -> schlaegt am CK_Schedule (weekly braucht nWeekdayMask) fehl; daher stattdessen valide Zeile:
  SQLCMD -Q "INSERT RoboticoOps.ops.tMaintenanceJob(cJobKey,cDisplayName,cOperation,cDatabases,cFrequency,nWeekdayMask,tStartTime,cCleanupTarget,nRetentionDays,bEnabled,bNotifyOnFail) VALUES(N'zz-orphan',N'RoboticoOps - Maint - zz-orphan',N'Cleanup',N'RoboticoOps',N'weekly',1,N'03:00',N'CommandLog',30,1,1); EXEC RoboticoOps.maint.spEnsureMaintenanceJobs;"
  SQLCMD -Q "SELECT COUNT(*) FROM msdb.dbo.sysjobs WHERE name=N'RoboticoOps - Maint - zz-orphan';"   # erwartet 1 (Job angelegt)
  # b) spApplyMaintenance re-run -> Zeile ist NOT MATCHED BY SOURCE -> DELETE -> ensure entfernt Job:
  SQLCMD -Q "EXEC RoboticoOps.maint.spApplyMaintenance;"
  SQLCMD -Q "SELECT COUNT(*) AS reg FROM RoboticoOps.ops.tMaintenanceJob WHERE cJobKey=N'zz-orphan'; SELECT COUNT(*) AS job FROM msdb.dbo.sysjobs WHERE name=N'RoboticoOps - Maint - zz-orphan';"
  ```
- **Erwartet:** nach (a) 1 Job; nach (b) Registry-Zeile UND Job entfernt (`spApplyMaintenance.sql:93` DELETE + `spEnsureMaintenanceJobs.sql:116-142` Präfix-Removal). Zusätzlich testbar: reiner Fremd-Job OHNE Registry-Zeile (`sp_add_job @job_name=N'RoboticoOps - Maint - zz-test'`) → nächster Ensure entfernt ihn (E2E-Runbook TC-10).

---

## 4. F3.1 — `xp_instance_reg*` unter Linux (Verhaltensfrage, Erwartung offen)

### T3-09 — Registry-XP-Verhalten + Agent-Mail-Profil
- **Kontext:** `260:60-77` liest `SQLServerAgent\DatabaseMailProfile` per `xp_instance_regread`, schreibt bei leer `UseDatabaseMail=1` + `DatabaseMailProfile='Standard SMTP'` per `xp_instance_regwrite` — aber nur, wenn `msdb.dbo.sysmail_profile` eine Zeile `Standard SMTP` hat (im Container fehlt sie → nur PRINT, `260:55-56`). Der dokumentierte Linux-Weg wäre `mssql-conf set sqlagent.databasemailprofile`; ob der Agent den per XP gesetzten Wert liest, ist **offen**.
- **Snippet (Verhalten dokumentieren, kein PASS/FAIL):**
  ```bash
  # (1) Existiert regread und liefert es leer/NULL ohne Fehler?
  SQLCMD -Q "DECLARE @p nvarchar(256); EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE',N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent',N'DatabaseMailProfile',@p OUTPUT,N'no_output'; SELECT ISNULL(@p,N'<NULL>') AS current_profile;"
  # (2) Profil kuenstlich anlegen, damit der ELSE-Zweig von 260 den regwrite ausfuehrt:
  SQLCMD -Q "IF NOT EXISTS(SELECT 1 FROM msdb.dbo.sysmail_profile WHERE name=N'Standard SMTP') EXEC msdb.dbo.sysmail_add_profile_sp @profile_name=N'Standard SMTP';"
  SQLCMD -i db-migrations/global/permissions/260_maintenance_operator.sql -d RoboticoOps   # erwartet: regwrite-PRINT '...takes effect only after a SQL-AGENT RESTART...'
  # (3) Wert nach regwrite zurueckgelesen?
  SQLCMD -Q "DECLARE @p nvarchar(256); EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE',N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent',N'DatabaseMailProfile',@p OUTPUT,N'no_output'; SELECT ISNULL(@p,N'<NULL>') AS after_write;"
  ```
- **Erwartet (zu dokumentieren, nicht vorab bekannt):** (a) `xp_instance_regread` läuft ohne Fehler und liefert initial NULL/leer; (b) `xp_instance_regwrite` läuft ohne Fehler, 260 gibt den Restart-Hinweis-PRINT; (c) der Rücklese-Wert ist `Standard SMTP`. **Selbst wenn (a)-(c) grün sind, ist damit NICHT bewiesen, dass der Linux-Agent das Profil tatsächlich verwendet** — echter Mail-Versand ist out of scope (§9). Ergebnis in den Container-Spezifika-Report aufnehmen: „regread/regwrite: OK/FEHLER; effektive Mail-Nutzung: unbewiesen (mssql-conf-Weg offen)".
- **Cleanup:** das künstliche Profil wieder entfernen (`sysmail_delete_profile_sp`), sonst verfälscht es T3-04 nicht (Operator-Weg unabhängig), aber sauber halten.

### T3-09b — Guard-Pfad ohne Mail-Profil (Deploy grün)
- **Snippet:** frischer Zustand (kein `Standard SMTP`-Profil), `260` fahren.
- **Erwartet:** `260:56` PRINT „`… does not exist on this instance — agent mail profile NOT set`", Exit 0, kein THROW. Operator wird trotzdem angelegt (`sp_add_operator` funktioniert überall, `260:41-44`).

---

## 5. Reale Job-Ausführung (Ola-Procs im Container)

### T3-10 — Jeden maint-Job manuell starten (sp_start_job, Jobs disabled = startbar)
- **Setup:** Phase A (`'0'`, Jobs disabled). Voraussetzung: Agent läuft (setup.ps1 verifiziert das).
- **Snippet (je Nicht-Watchdog-Job):**
  ```bash
  for k in checkdb index-optimize cleanup-commandlog cleanup-backuphistory cleanup-jobhistory; do
    SQLCMD -Q "EXEC msdb.dbo.sp_start_job @job_name=N'RoboticoOps - Maint - $k';"
  done
  # poll bis run_status gesetzt:
  SQLCMD -Q "SELECT j.name, h.run_status, h.run_date, h.run_time FROM msdb.dbo.sysjobhistory h JOIN msdb.dbo.sysjobs j ON j.job_id=h.job_id WHERE j.name LIKE N'RoboticoOps - Maint - %' AND h.step_id=0 ORDER BY h.run_date DESC, h.run_time DESC;"
  ```
- **Erwartet:** `sp_start_job` funktioniert trotz disabled Job (D34/README:397); jeder der 5 Jobs `run_status=1` (Erfolg). **Grenze:** `checkdb`/`index-optimize` brauchen valide Ziele — mit nur RoboticoOps im Container läuft `checkdb` (`ALL_DATABASES,-eazybusiness_tm%`) gegen die vorhandenen DBs; `index-optimize` (`USER_DATABASES`) findet ggf. nur RoboticoOps. Ohne restaurierte eazybusiness ist das ein reduziertes, aber gültiges Ziel-Set.

### T3-11 — Ola-Procs real (DatabaseIntegrityCheck, IndexOptimize) + CommandLog-Heartbeats
- **Snippet:** direkter Dispatcher-Aufruf (umgeht Agent, zeigt Ola-Lauf pur):
  ```bash
  SQLCMD -Q "EXEC RoboticoOps.maint.spRunMaintenanceJob @cJobKey=N'checkdb';"
  SQLCMD -Q "EXEC RoboticoOps.maint.spRunMaintenanceJob @cJobKey=N'index-optimize';"
  SQLCMD -Q "SELECT TOP 20 CommandType, DatabaseName, LEFT(Command,80) AS cmd, StartTime FROM RoboticoOps.dbo.CommandLog WHERE StartTime > DATEADD(HOUR,-1,SYSDATETIME()) ORDER BY ID DESC;"
  ```
- **Erwartet:** beide Procs laufen fehlerfrei (reines T-SQL, `up/0022`-Kommentar „Ola-Procs laufen auf Linux normal"); CommandLog enthält `DBCC_CHECKDB`-Zeilen und `ALTER_INDEX`/`UPDATE_STATISTICS`-Zeilen der letzten Stunde.

### T3-12 — index-optimize: @UpdateStatistics='ALL', REORGANIZE-only, kein Offline-Rebuild (AC10/D13)
- **Snippet:**
  ```bash
  SQLCMD -Q "SELECT TOP 20 Command FROM RoboticoOps.dbo.CommandLog WHERE CommandType IN (N'ALTER_INDEX',N'UPDATE_STATISTICS') AND StartTime > DATEADD(HOUR,-1,SYSDATETIME());"
  ```
- **Erwartet:** mind. eine `UPDATE STATISTICS … WITH … ALL`-Zeile (Heartbeat, `spRunMaintenanceJob.sql:64-70`); KEIN `REBUILD` mit `ONLINE = OFF` (die Fragmentierungs-Aktionen sind auf `INDEX_REORGANIZE` gepinnt, `spRunMaintenanceJob.sql:68-69`).

---

## 6. F3.4 — Backup-Chain-Watchdog Falsch-Alarm-Matrix

Alle direkt via `EXEC RoboticoOps.maint.spCheckBackupChain @Databases=…, @FullMaxHours=…, @LogMaxHours=…`. THROW 51100 = `-b`-Exit ≠ 0.

### T3-13 — Leere/fehlende Kette → THROW 51100 'NEVER' (by design, erwartet ROT)
- **Snippet:**
  ```bash
  SQLCMD -Q "EXEC RoboticoOps.maint.spCheckBackupChain @Databases=N'RoboticoOps,msdb', @FullMaxHours=26, @LogMaxHours=1;"
  ```
- **Erwartet ROT:** THROW 51100, Text „STALE backup chain — …: last FULL NEVER …" (`spCheckBackupChain.sql:98-102`). Der frische Container hat keine non-copy-only-Fulls in `msdb.dbo.backupset`.

### T3-14 — Invalid-Target: fehlende DB / Ola-Token → THROW 51100 VOR Freshness (D32, erwartet ROT)
- **Snippet:**
  ```bash
  SQLCMD -Q "EXEC RoboticoOps.maint.spCheckBackupChain @Databases=N'gibtsnicht', @FullMaxHours=26, @LogMaxHours=1;"
  SQLCMD -Q "EXEC RoboticoOps.maint.spCheckBackupChain @Databases=N'USER_DATABASES', @FullMaxHours=26, @LogMaxHours=1;"
  # Wenn eazybusiness NICHT restauriert ist, ist die Seed-Watchliste selbst ein Invalid-Target-Fall:
  SQLCMD -Q "EXEC RoboticoOps.maint.spCheckBackupChain @Databases=N'eazybusiness,RoboticoOps,msdb', @FullMaxHours=26, @LogMaxHours=1;"
  ```
- **Erwartet ROT:** je THROW 51100, Text „invalid watch target(s) — no ONLINE database match for: <token>" (`spCheckBackupChain.sql:54-59`). `USER_DATABASES` wird explizit als ungültig behandelt (kein Ola-Ausdruck). Der dritte Aufruf trippt genau dann am Invalid-Target, wenn eazybusiness fehlt — dokumentieren, dass die produktive Seed-Watchliste ohne restaurierte eazybusiness alarmiert (D32-Beleg).

### T3-15 — SIMPLE-Blindheit + FULL-Recovery-Log-Fall + frische Kette schweigt
- **Snippet:**
  ```bash
  # RoboticoOps auf FULL stellen, damit der Log-Zweig sichtbar wird:
  SQLCMD -Q "ALTER DATABASE RoboticoOps SET RECOVERY FULL;"
  # frische Kette herstellen (TO DISK='NUL' schreibt nichts, Container-only unkritisch):
  SQLCMD -Q "BACKUP DATABASE RoboticoOps TO DISK='NUL';"
  SQLCMD -Q "EXEC RoboticoOps.maint.spCheckBackupChain @Databases=N'RoboticoOps', @FullMaxHours=26, @LogMaxHours=1;"   # noch ROT: Log fehlt (FULL, kein Log-Backup)
  SQLCMD -Q "BACKUP LOG RoboticoOps TO DISK='NUL';"
  SQLCMD -Q "EXEC RoboticoOps.maint.spCheckBackupChain @Databases=N'RoboticoOps', @FullMaxHours=26, @LogMaxHours=1;"   # jetzt STILL (Full+Log frisch)
  # SIMPLE-DB: nur Full-Anforderung, KEIN Log-Zweig:
  SQLCMD -Q "ALTER DATABASE RoboticoOps SET RECOVERY SIMPLE; BACKUP DATABASE RoboticoOps TO DISK='NUL';"
  SQLCMD -Q "EXEC RoboticoOps.maint.spCheckBackupChain @Databases=N'RoboticoOps', @FullMaxHours=26, @LogMaxHours=1;"   # STILL (SIMPLE -> Log ignoriert)
  ```
- **Erwartet:** (1) FULL + frischer Full aber kein Log → ROT (Log 'NEVER'); (2) FULL + frischer Full + frisches Log → **schweigt**; (3) SIMPLE + frischer Full → **schweigt**, weil `recovery_model_desc <> 'SIMPLE'` den Log-Check ausblendet (`spCheckBackupChain.sql:94`, D27). Belegt: SIMPLE-DBs lösen keinen Dauer-Log-Alarm aus.
- **Cleanup:** `RoboticoOps` zurück auf den Ausgangs-Recovery-Model (i. d. R. SIMPLE oder FULL — vorher via `SELECT recovery_model_desc FROM sys.databases WHERE name='RoboticoOps'` festhalten).

### T3-16 — Freshness-Grenzwert inklusiv (age ≥ threshold alarmiert, AC5/D27)
- **Snippet:** einen Full frisch machen, dann mit `@FullMaxHours=0` prüfen (jede Kette ist ≥ 0h alt):
  ```bash
  SQLCMD -Q "BACKUP DATABASE RoboticoOps TO DISK='NUL';"
  SQLCMD -Q "EXEC RoboticoOps.maint.spCheckBackupChain @Databases=N'RoboticoOps', @FullMaxHours=0, @LogMaxHours=1;"   # ROT: DATEADD(HOUR,0)=jetzt, dLast<=jetzt trifft zu
  ```
- **Erwartet ROT:** THROW 51100 — der `<=`-Vergleich (`spCheckBackupChain.sql:81`) macht die Grenze inklusiv. Belegt, dass der Watchdog am Schwellwert selbst schon alarmiert (kein Off-by-one nach oben).
- **Hinweis:** Der Elapsed-Cutoff (`dLast <= now - h`) statt `DATEDIFF(HOUR)` ist absichtlich (Header `:62-65`) — der Ein-Stunden-Log-Fall auf hourly-Kadenz würde sonst false-alarmen; im UTC-Container ohne Uhrversatz nicht gesondert reproduzierbar (§9).

---

## 7. F3.5 — spCheckMaintenanceLiveness

### T3-17 — Schalter '0' → sofortiger RETURN (No-op)
- **Snippet:**
  ```bash
  SQLCMD -Q "IF NOT EXISTS(SELECT 1 FROM RoboticoOps.ops.tConfig WHERE cKey=N'MaintenanceSchedulesEnabled') INSERT RoboticoOps.ops.tConfig(cKey,cValue) VALUES(N'MaintenanceSchedulesEnabled',N'0'); ELSE UPDATE RoboticoOps.ops.tConfig SET cValue=N'0' WHERE cKey=N'MaintenanceSchedulesEnabled';"
  SQLCMD -Q "EXEC RoboticoOps.maint.spCheckMaintenanceLiveness;"   # erwartet: schweigt, Exit 0
  ```
- **Erwartet:** kein THROW, Exit 0 — `spCheckMaintenanceLiveness.sql:65-66` RETURNt sofort bei `'0'`. (Das ist der test1-No-op-by-construction.)

### T3-18 — unset + First-Run-Grace → schweigt trotz fehlender CommandLog-Historie (L-B1-2)
- **Snippet:**
  ```bash
  SQLCMD -Q "DELETE RoboticoOps.ops.tConfig WHERE cKey=N'MaintenanceSchedulesEnabled';"   # unset -> effektiv enabled
  SQLCMD -Q "EXEC RoboticoOps.maint.spCheckMaintenanceLiveness;"   # frische Rows: dModified jung -> Grace -> schweigt
  ```
- **Erwartet:** kein THROW. Die `checkdb`/`index-optimize`-Rows wurden gerade erst per MERGE angelegt (`dModified` jung); die Grace-Bedingung `dModified <= now-window` (26h/192h, `spCheckMaintenanceLiveness.sql:82-86`) ist noch nicht erfüllt → keine Staleness. Belegt, dass frisch deployte Wartung nicht sofort alarmiert.

### T3-19 — Staleness: dModified zurückdatieren → THROW 51105 mit cJobKeys (erwartet ROT)
- **Snippet:**
  ```bash
  # unset (enabled), Grace austricksen: dModified der beiden liveness-gewachten Rows > Fenster zurueckdatieren, CommandLog leer lassen:
  SQLCMD -Q "DELETE RoboticoOps.ops.tConfig WHERE cKey=N'MaintenanceSchedulesEnabled';"
  SQLCMD -Q "DELETE RoboticoOps.dbo.CommandLog;"   # keine frischen Heartbeats
  SQLCMD -Q "UPDATE RoboticoOps.ops.tMaintenanceJob SET dModified = DATEADD(DAY,-30,SYSUTCDATETIME()) WHERE cOperation IN (N'IntegrityCheck',N'IndexOptimize');"
  SQLCMD -Q "EXEC RoboticoOps.maint.spCheckMaintenanceLiveness;"
  ```
- **Erwartet ROT:** THROW 51105, Text enthält die stalen `cJobKey`s `checkdb, index-optimize` und „The \"never runs\" pattern (F3/F4) is live again" (`spCheckMaintenanceLiveness.sql:94-98`). Belegt den „läuft nie"-Detektor.
- **Wichtig:** `dModified` ist danach künstlich; vor Wiederverwendung der Registry `spApplyMaintenance` erneut fahren (setzt Werte + dModified zurück) oder Container-Reset.

### T3-20 — IndexOptimize-Heartbeat-Kopplung an bUpdateStatistics (L-B1-3, dokumentierender Fall)
- **Kontext:** Der Liveness-Check zählt für `index-optimize` `ALTER_INDEX`/`UPDATE_STATISTICS`. Nur `bUpdateStatistics=1` garantiert den per-run `UPDATE_STATISTICS`-Heartbeat; eine stats-off-Zeile hätte ihn nicht (`spRunMaintenanceJob.sql:74-76`).
- **Snippet:** nach T3-11 (index-optimize lief mit bUpdateStatistics=1) prüfen, dass ein Heartbeat existiert:
  ```bash
  SQLCMD -Q "SELECT COUNT(*) AS stats_heartbeat FROM RoboticoOps.dbo.CommandLog WHERE CommandType=N'UPDATE_STATISTICS' AND StartTime > DATEADD(HOUR,-1,SYSDATETIME());"
  ```
- **Erwartet:** > 0 Heartbeat-Zeilen (Registry-Default `bUpdateStatistics=1`). Dokumentieren: eine stats-off-Zeile ist im Repo NICHT vorhanden, daher kein False-Fire-Fall im Container reproduzierbar — die Kopplung ist per Registry-CHECK (`CK_OperationKnobs`, `up/0023:87-91`) und Header-NB abgesichert, nicht laufzeittestbar ohne bewusste Fehl-Zeile. Als Grenze ausweisen.

---

## 8. Running-Job-Guard & Koexistenz

### T3-21 — (bereits in T3-06) Schalter-Matrix — Querverweis
Der enabled/disabled-Job-State pro Schalterzustand ist in T3-06 abgedeckt (F3.6). Kein separater Fall.

### T3-22 — Running-Job-Guard: langlaufender Job während Ensure → Skip + spätere Konvergenz (F3.7)
- **Snippet:**
  ```bash
  # Fremd-Job mit langem WAITFOR anlegen (ausserhalb Registry -> Removal-Kandidat), starten:
  SQLCMD -Q "EXEC msdb.dbo.sp_add_job @job_name=N'RoboticoOps - Maint - zz-long', @owner_login_name=N'sa'; EXEC msdb.dbo.sp_add_jobstep @job_name=N'RoboticoOps - Maint - zz-long', @step_name=N'wait', @subsystem=N'TSQL', @command=N'WAITFOR DELAY ''00:02:00'';'; EXEC msdb.dbo.sp_add_jobserver @job_name=N'RoboticoOps - Maint - zz-long', @server_name=N'(LOCAL)'; EXEC msdb.dbo.sp_start_job @job_name=N'RoboticoOps - Maint - zz-long';"
  sleep 3
  SQLCMD -Q "EXEC RoboticoOps.maint.spEnsureMaintenanceJobs;"   # erwartet PRINT '! ... is RUNNING — removal skipped, converges on the next deploy'
  SQLCMD -Q "SELECT COUNT(*) FROM msdb.dbo.sysjobs WHERE name=N'RoboticoOps - Maint - zz-long';"   # noch 1 (skip)
  # nach Job-Ende erneut:
  SQLCMD -Q "WAITFOR DELAY '00:02:05'; EXEC RoboticoOps.maint.spEnsureMaintenanceJobs;"
  SQLCMD -Q "SELECT COUNT(*) FROM msdb.dbo.sysjobs WHERE name=N'RoboticoOps - Maint - zz-long';"   # jetzt 0 (removed)
  ```
- **Erwartet:** Erster Ensure meldet 1 running-job skip, Job bleibt; zweiter Ensure (nach Job-Ende) entfernt ihn. Belegt den session-scoped Running-Guard (`spEnsureMaintenanceJobs.sql:125-133`, `:59-61`). Der Guard nutzt `MAX(session_id)` aus `msdb.dbo.syssessions` — im Container mit laufendem Agent ist das die aktuelle Session.

### T3-23 — Koexistenz Reset-Job + Maint-Jobs im geteilten Agent (Schnittstelle zu T2)
- **Zweck:** ein Kernfall hier; Reset-Detailtests bei T2.
- **Snippet (nach Voll-Deploy Ebene B):**
  ```bash
  SQLCMD -Q "SELECT name, enabled FROM msdb.dbo.sysjobs WHERE name=N'RoboticoOps - Testmandant Reset' OR name LIKE N'RoboticoOps - Maint - %' ORDER BY name;"
  ```
- **Erwartet:** beide Job-Familien nebeneinander im selben Agent vorhanden — 1× Reset-Job (`permissions/200`/`reset.spEnsureAgentJob`) + 6× Maint-Jobs. Beide sind sa-owned und über `sp_start_job` startbar; kein Namens-/Owner-Konflikt (Reset-Präfix ≠ Maint-Präfix `RoboticoOps - Maint - `). Die Detail-Interaktion (Agent-Restart killt laufende Jobs beider Familien; Running-Guard des Reset) liegt bei T2 — hier nur die Präsenz + Startbarkeit.

---

## 9. Grenzen / nur zur Laufzeit klärbar

> [!IMPORTANT]
> Diese Punkte sind **nicht** vorab entscheidbar oder bewusst außerhalb Container-Scope:

1. **`xp_instance_regread`/`regwrite`-Verhalten (T3-09):** ob die XPs im Container fehlerfrei laufen, was regread initial liefert, und ob der Linux-Agent den per regwrite gesetzten Wert überhaupt konsumiert — **nur zur Laufzeit klärbar**. Selbst grüne XP-Aufrufe beweisen die effektive Mail-Nutzung nicht (dokumentierter Linux-Weg: `mssql-conf sqlagent.databasemailprofile`).
2. **Echter Mail-Versand:** out of scope — kein SMTP-Profil, Database Mail nur Struktur/PRINT-Pfad. Der Operator-Notify-Weg (`notify_level_email=2` + Operator-Verdrahtung) ist strukturell verifizierbar (T3-04), der Versand nicht (B6/Prod).
3. **CEST-Zeitbasis-Bug:** Der SYSDATETIME-vs-SYSUTCDATETIME-Unterschied (`spCheckBackupChain.sql:19-22`) ist im UTC-Container konstruktionsbedingt NULL (lokal == UTC) → der Bug ist hier **nicht reproduzierbar**. Nur auf einem CEST-Server sichtbar; als Testlücke ausweisen.
4. **CBB-Backup-Kette:** extern (ADR-0002). Die Watchdog-Fälle simulieren Frische ausschließlich über `BACKUP … TO DISK='NUL'` (schreibt nichts, Container-only) — die reale CBB-Kette ist nicht Teil des Containers.
5. **Recovery-Model von RoboticoOps/msdb im frischen Container:** hängt vom `model`-DB-Zustand des Images ab (FULL vs. SIMPLE) → bestimmt, ob der Log-Zweig des Watchdogs ohne T3-15-Eingriff überhaupt greift. Vor T3-15 per `SELECT recovery_model_desc` festhalten.
6. **stats-off IndexOptimize-False-Fire (T3-20):** im Repo existiert keine `bUpdateStatistics=0`-Zeile (CHECK erlaubt sie, Seed nutzt sie nicht) → der Liveness-False-Fire-Pfad ist ohne bewusste Fehl-Zeile nicht reproduzierbar; nur als Header-dokumentierter Blind-Spot belegbar.
7. **Ziel-Set von checkdb/index-optimize ohne eazybusiness:** ist die eazybusiness nicht restauriert (T5), läuft `checkdb`/`index-optimize` gegen ein reduziertes DB-Set (nur System + RoboticoOps). Der Lauf ist gültig, aber nicht prod-repräsentativ — für vollständige Ziel-Abdeckung eazybusiness-Restore voraussetzen.

## 10. Cleanup (nach den Fällen)

1. **Künstliche Registry-/Job-Artefakte entfernen:** `zz-orphan`, `zz-test`, `zz-long` (soweit nicht bereits durch den Removal-Pfad/Ensure entfernt): `EXEC msdb.dbo.sp_delete_job @job_name=N'…', @delete_unused_schedule=1;` und `DELETE RoboticoOps.ops.tMaintenanceJob WHERE cJobKey LIKE N'zz-%';`.
2. **Registry auf Soll zurücksetzen:** nach T3-19 (zurückdatiertes `dModified`) und T3-08 `EXEC RoboticoOps.maint.spApplyMaintenance;` fahren — MERGE stellt Werte + `dModified` wieder her.
3. **RoboticoOps-Recovery-Model zurücksetzen** (T3-15) auf den vorab festgehaltenen Ausgangswert.
4. **Künstliches Mail-Profil entfernen** (T3-09): `EXEC msdb.dbo.sysmail_delete_profile_sp @profile_name=N'Standard SMTP';`.
5. **Schalter-Endzustand:** für einen sauberen Plan-Sollzustand `MaintenanceSchedulesEnabled='0'` setzen (Jobs bleiben installiert + disabled, `validate_rollout`-konform) — oder Container komplett verwerfen (`npm run db:e2e:down:full`), was für den isolierten T3-Lauf die einfachste Variante ist.
6. **CommandLog-Reste** (aus T3-11/19): unkritisch; `db:e2e:down` wischt das Volume ohnehin.

## 11. Abschluss-Gate

```bash
SQLCMD -i db-migrations/tests/global/validate_rollout.sql -d RoboticoOps
```
- **Erwartet (im Plan-Sollzustand, Schalter '0'):** `validate_rollout: OK — … maintenance jobs/operator wired.` Die Maint-Sektion (`validate_rollout.sql:122-178`) prüft die 6 Registry-Zeilen, die D34-Enabled-Gleichung, Operator-Verdrahtung und Operator-Existenz in einem Rutsch.
