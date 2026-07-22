# Implementation Plan: SQL Server Maintenance as Code (Ola Hallengren in RoboticoOps)

**Status:** Detailed
**Created:** 2026-07-21
**Repo:** JTL-Robotico
**Branch / Worktree:** feature/mssql-ops-infrastruktur (in worktrees/feature/mssql-ops-infrastruktur)
**Complexity:** Small–Medium
**Modular?:** No — detail kept flat in §3; the architectural decisions live in the two ADRs
**archive_target:** 2026-07-21 - mssql-wartung-ola

**Associated ADRs (promoted → `docs/decisions/`):**
- [0001-maintenance-as-code-roboticoops.md](../../decisions/0001-maintenance-as-code-roboticoops.md) — core: Ola vendored into RoboticoOps, declarative registry `ops.tMaintenanceJob`, `maint.spEnsureMaintenanceJobs` sync, one job per operation, alerting.
- [0002-backups-cbb-retained.md](../../decisions/0002-backups-cbb-retained.md) — backups stay with CBB; no Ola backup; read-only backup-chain watchdog.

**Basis:** [research/6-wartung-ist-analyse](../2026-07-10 - mssql-ops-infrastruktur/research/6-wartung-ist-analyse/6-wartung-ist-analyse.md) (live current-state of vm-sql2 maintenance).

This plan implements the two ADRs: it replaces the broken Ola installation scattered across `eazybusiness.dbo` with a versioned, registry-driven maintenance suite in RoboticoOps, deployed through the existing global-grate chain. No new architectural content — that lives in the ADRs; what is here is acceptance criteria, building blocks, file layout and the cutover procedure.

## 1. Vision and Motivation

### 1.1 Why this plan exists

vm-sql2 effectively has **no** functioning maintenance: the only scheduled job (`IndexOptimize`) has failed nightly since ~2025-11-27, CHECKDB last ran 2024-06-24, and nobody gets alerted (evidence: [6-wartung-ist-analyse §2, F1–F9](../2026-07-10 - mssql-ops-infrastruktur/research/6-wartung-ist-analyse/6-wartung-ist-analyse.md)). The cause is three structural faults — wrong location (vendor DB), click-ops (unversioned), no alerting. This plan fixes all three via the existing RoboticoOps infrastructure.

### 1.2 What problem this solves

- CHECKDB (all DBs incl. `msdb`, excluding tm clones) runs again — twice weekly, each time **before** the 03:00 full → corruption is detected within a few days (before the respective Sun/Wed full) instead of silently migrating unnoticed into the retention chain for months.
- Statistics finally get maintained (`@UpdateStatistics=ALL`).
- The entire maintenance landscape is **one table** (`ops.tMaintenanceJob`) — traceable and reproducible via `deploy.ps1 -Scope global`.
- A silently failing job is reported immediately — and a silently **non-running** job (the historically dominant F3/F4 pattern) is caught by the liveness check (D36).

### 1.3 Rejected Alternatives

See ADR-A §Alternatives (in-place repair, scattered job scripts, config keys, collector job, Ola `@CreateJobs`, dedicated maintenance DB) and ADR-B §Alternatives (consolidate backups into Ola, no monitoring, watch tm clones too).

## 2. Acceptance Criteria

1. **Registry exists:** `ops.tMaintenanceJob` is present in RoboticoOps after the global deploy and contains the target rows from §3.2 (currently **6** — the §3.2 table is SSoT for count and content). File evidence: table in `up/0023`, rows via MERGE in `runAfterOtherAnyTimeScripts/maint.spApplyMaintenance.sql` (B3) — **not** in the `up/` script (which only creates the DDL, see §3.1 NOTE).
2. **Ola in the right place:** `IndexOptimize`, `CommandExecute`, `DatabaseIntegrityCheck`, `CommandLog` exist in **`RoboticoOps.dbo`** after deploy; **`RoboticoOps.dbo.DatabaseBackup` does NOT exist** (the binary proof of the ADR-B guarantee "not vendored = not schedulable"); our chain creates **no** Ola objects in `eazybusiness`.
3. **Jobs = registry:** `maint.spEnsureMaintenanceJobs` creates exactly the registry-declared Agent jobs (name prefix `RoboticoOps - Maint - `) — one job for **every** registry row, each with its declared schedule, a **constant dispatch step** `EXECUTE RoboticoOps.maint.spRunMaintenanceJob @cJobKey = N'<key>';` (D28 — the operation-specific commands live at runtime in the command matrix of `spRunMaintenanceJob`, §3.2) and `@notify_email_operator` when `bNotifyOnFail=1`; `bEnabled` + instance switch map onto the job's enabled state (D34). Jobs not in the registry (with this prefix) are removed; **removing a target row from the seed removes the registry row AND the job on the next deploy** (MERGE delete branch, D30).
4. **No backup job:** **No** `DatabaseBackup` job is registered/created (ADR-B).
5. **Watchdog works:** `maint.spCheckBackupChain` alerts on a stale chain (alarm when `last_full <= DATEADD(HOUR, -nFullMaxHours, now)` **or** `last_log <= DATEADD(HOUR, -nLogMaxHours, now)` — **elapsed-time cutoff** analogous to `spCheckMaintenanceLiveness`, NOT `DATEDIFF(HOUR, …)` — so the edge case "exactly 26 h / 1 h" does alarm; `DATEDIFF(HOUR)` counts crossed calendar-hour boundaries instead of elapsed hours and would, at the hourly cadence, falsely report a log backup that is only minutes old but landed in the previous hour as stale (L-B1-1); `is_copy_only=0` filtered; log check for all log-based recovery models, i.e. `recovery_model_desc <> N'SIMPLE'` — covers FULL **and** BULK_LOGGED, D27) and stays silent on a fresh one — verified via a threshold test. Age comparisons compute in **local server time** (`backupset` stores local, D32); unknown, non-ONLINE, or Ola-token-specified watch targets likewise throw `51100` (target validation, D32 — a silent skip would be the watchdog variant of the F2 pattern). **Cadence: hourly** (D35, anchor 00:00) — the detection latency of a broken log chain is thereby ≤ ~2 h; a daily sample would have stretched the "log < 1 h" promise to up to 24 h latency in reality.
6. **Alerting wired up:** operator `RoboticoOps-Maint` (email `lukas@dattenberger.com`) exists; Agent mail profile = `Standard SMTP` (effective only after an Agent restart, see §3.6 no. 4); after a full deploy all `bNotifyOnFail=1` jobs carry the operator wiring (first-deploy convergence via `260`, see §3.3).
7. **Idempotency:** a repeated global deploy is a no-op. **Measurement mechanics (D18, refined by D29/D31):** grate skips `spApplyMaintenance` (hash unchanged); the everytime script `260` calls `maint.spEnsureMaintenanceJobs` **unconditionally** (D29) and the sync reports **0 changes** (per-job comparison in canonical normal form, see §3.2); the value-guarded MERGE (NULL-safe via `IS DISTINCT FROM`, D30) leaves `dModified` untouched.
8. **Docs contract:** `docs/SQL/MSSQL-OPS-DATA-MODEL.md` documents every column of `ops.tMaintenanceJob` (CLAUDE.md ops-table contract); scope incl. header/contract box see §3.4.
9. **test1:** the suite deploys cleanly; one manual run of **all Ola/cleanup jobs (all registry rows except `backup-watchdog`; §3.2 = SSoT for the count)** succeeds; the `backup-watchdog` is accepted via a logic test (on test1, lacking a CBB chain, **expected red**, see §3.5); **no** standing schedule active — enforced by the instance switch `ops.tConfig('MaintenanceSchedulesEnabled') = '0'` (jobs exist but are disabled; manual runs via `sp_start_job` still work — D34); the Agent additionally stays in its stopped baseline but does not qualify as a gate (reset work needs it running).
10. **Statistics maintenance provable:** the `index-optimize` run really passes `@UpdateStatistics = 'ALL'` to Ola — provable from the `CommandLog` entry of the B5 run (Ola logs the executed command incl. parameters; the job step itself has been a constant dispatch since D28 and no longer carries the parameters). (The core lever from F7/F8 must not remain mere registry input: the old broken job ran precisely without this parameter — which is why the CHECK now enforces `bUpdateStatistics IS NOT NULL`, D33.)
11. **Repo contracts satisfied:** the five `maint.*` procs and `ops.tMaintenanceJob` (+ key columns) are registered in `db-migrations/tests/global/validate_structure.sql` (lint rule (l)); the THROW numbers `51100`/`51105`/`51110`/`51120` are allocated in the README §4 (k) table (incl. the accompanying guidance sentence, see §3.2 NOTE); `npm run db:lint` is green — including the vendored Ola files (pre-check, see §3.1).
12. **Operability gate extended (D23):** `db-migrations/tests/global/validate_rollout.sql` checks maintenance analogously to the existing reset-job block: for **every** registry row the matching `RoboticoOps - Maint - ` Agent job exists (D34: the sync also creates `bEnabled=0` rows as a disabled job), every `bNotifyOnFail=1` job carries the operator wiring, and the operator `RoboticoOps-Maint` exists. Operability is thereby repeatably checked on prod redeploys, not only via the manual B5 checklist (the registry rows are identical on test1 and prod, see ADR-A §D-A6). **Assertions per D34 semantics:** for each registry row (regardless of `bEnabled`) the job exists; job-enabled state = `bEnabled = 1` AND `ops.tConfig('MaintenanceSchedulesEnabled')` ≠ `'0'` — the assertion checks the equation, not a blanket "enabled", and is therefore green on both test1 (switch `'0'`) and prod (no entry).
13. **Maintenance liveness monitored (D36):** `maint.spCheckMaintenanceLiveness` (second EXEC in the watchdog job step, see §3.2) alerts via `THROW 51105` when, for an **effectively enabled** registry row with `cOperation IN (IntegrityCheck, IndexOptimize)`, no sufficiently fresh `CommandLog` entry exists (target age derived from the declared schedule: daily → 26 h, weekly → 8 days) — so the historic **"never runs" path** (F3/F4: schedule live-detached, job live-disabled) is itself monitored too, not only the "runs and fails" path (F2) that `bNotifyOnFail` covers. Verified via direct `EXEC` on test1 (B5).

> [!NOTE]
> The §1.2 promise "CHECKDB finishes before the 03:00 full" deliberately has **no** AC of its own: it is asserted by start time, not enforced, and is measured and accepted on the first prod nightly run (B6 no. 6, Gap 5) — that is its named acceptance anchor.

> [!NOTE]
> Likewise, the **collision-freeness of the cutover** (old Ola jobs/objects removed before the deploy actively creates the new jobs) deliberately has no test1 AC: it is prod-cutover verification and is accepted in B6 step 1 (inventory query + deletion) and step 5 (step/notify verification) — that is its named acceptance anchor (same pattern as above).

## 3. Building Blocks

Cross-cutting for all building blocks: every new Ebene-B file gets the compact file header + `@see` anchor (README §3) pointing at this plan (`docs/plans/2026-07-21 - mssql-wartung-ola`, §3.x) and the respective governing ADR — like the existing reset files.

### §3.1 — B1: Vendor + Schema + Registry (up/)

New one-time scripts in `db-migrations/global/up/` (after 0021):

- `0022_maintenance_ola_vendor.sql` — the **pinned individual Ola scripts** (`CommandLog.sql`, `CommandExecute.sql`, `DatabaseIntegrityCheck.sql`, `IndexOptimize.sql`) into `RoboticoOps.dbo`. Deliberately the individual files instead of the aggregate `MaintenanceSolution.sql`: the individual files are objects-only and therefore genuinely **byte-unchanged** vendorable (the aggregate file would have to be edited at the `@CreateJobs` header — precisely the intervention that "pinned unchanged" forbids). Record the version in the header comment; upgrade = new `up/`. **`DatabaseBackup.sql` is deliberately NOT vendored** (ADR-B: no Ola backup — what is not deployed cannot be accidentally scheduled either). **Lint pre-check (mandatory, before the first apply):** `npm run db:lint` against the vendored files — `up/` is immutable afterwards, a rule violation (a: `USE`, b: `GO;`, h: date literals) must not first surface at deploy time. If a rule fires, a minimally invasive, commented deviation is documented with `@see` on the pinned upstream version — then "byte-unchanged" is deliberately broken, not silently. **Known deviation from the outset (FT-13):** Ola's proc individual scripts are `CREATE OR ALTER` (idempotent), but `CommandLog.sql` is an unguarded `CREATE TABLE` — a collision with the Ebene-B rule "every `up/` is hand-idempotent" (README §1 NOTE). Resolved by the same mechanism: a minimally invasive, commented `IF OBJECT_ID(N'dbo.CommandLog', N'U') IS NULL` wrapper around this one file (a deliberate, documented byte break with `@see` upstream).
- `0023_maintenance_registry.sql` — idempotent `CREATE SCHEMA maint AUTHORIZATION dbo` (own batch, literally following the pattern `up/0002`); table `ops.tMaintenanceJob` (DDL below, `ops.*` Hungarian style analogous to `ops.tResetStep`).

```sql
-- maint-Schema: idempotent + AUTHORIZATION dbo (Muster up/0002) — CREATE SCHEMA muss allein
-- im Batch stehen (daher EXEC-Wrapper + eigener GO-Batch), und das unten zugesicherte
-- Ownership-Chaining maint.* -> ops.tMaintenanceJob setzt den gemeinsamen Owner dbo voraus.
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'maint')
    EXEC (N'CREATE SCHEMA maint AUTHORIZATION dbo;');
GO

-- ops.tMaintenanceJob — deklarative Registry: eine Zeile = ein Wartungsjob.
-- maint.spEnsureMaintenanceJobs synchronisiert daraus die SQL-Agent-Jobs.
IF OBJECT_ID(N'ops.tMaintenanceJob', N'U') IS NULL
BEGIN
    CREATE TABLE ops.tMaintenanceJob
    (
        cJobKey        sysname       NOT NULL   -- stabiler Schlüssel: 'checkdb', 'index-optimize', …
            CONSTRAINT PK_tMaintenanceJob PRIMARY KEY,
        cDisplayName   nvarchar(128) NOT NULL,  -- Agent-Jobname, Präfix 'RoboticoOps - Maint - '
        cOperation     nvarchar(20)  NOT NULL,  -- IntegrityCheck | IndexOptimize | Cleanup | BackupWatchdog
        cDatabases     nvarchar(400) NOT NULL,  -- ZWEI Grammatiken je cOperation (Doku in B4): Ola-@Databases-Ausdruck
                                                -- (IntegrityCheck/IndexOptimize/Cleanup) bzw. LITERALE Komma-Liste
                                                -- (BackupWatchdog, s. §3.2 — Ola-Token dort ungültig, Laufzeit-THROW);
                                                -- Werte erreichen Ola zur Laufzeit als echte Proc-Parameter des
                                                -- Dispatchers (D28), nie als Step-Text-Literal
        -- Zeitplan: typisiert statt Cron-String (gleiche Logik wie bei den Stellschrauben — kein Parsen im Sync-Proc;
        -- nur die drei genutzten Muster, Sync mappt 1:1 auf msdb.dbo.sysschedules):
        cFrequency     nvarchar(10)  NOT NULL   -- 'daily' | 'weekly' | 'hourly' (hourly: stündlich ab tStartTime-Anker, D35)
            CONSTRAINT CK_tMaintenanceJob_cFrequency CHECK (cFrequency IN (N'daily', N'weekly', N'hourly')),
        nWeekdayMask   tinyint       NULL       -- nur bei weekly: Bitmaske 1=So,2=Mo,4=Di,8=Mi,16=Do,32=Fr,64=Sa
                                                -- (mehrere Tage ODER-bar, z. B. So+Mi = 9; identisch zu sysschedules.freq_interval)
            CONSTRAINT CK_tMaintenanceJob_nWeekdayMask CHECK (nWeekdayMask BETWEEN 1 AND 127),
        tStartTime     time(0)       NOT NULL,  -- lokale Serverzeit; bei 'hourly' der Tagesanker des ersten Laufs
                                                -- (Watchdog: 00:00 -> stündlich rund um die Uhr)
        -- operationsspezifische Stellschrauben (NULL, wenn n/a) — typisiert + CHECK-validiert statt Freitext:
        bUpdateStatistics bit          NULL,    -- IndexOptimize (Pflicht dort, s. OperationKnobs-CHECK):
                                                -- 1 -> @UpdateStatistics='ALL', 0 -> Parameter entfällt (bewusster Ausnahmefall)
        cCleanupTarget    nvarchar(20) NULL     -- Cleanup: Ziel-Log
            CONSTRAINT CK_tMaintenanceJob_cCleanupTarget
                CHECK (cCleanupTarget IN (N'CommandLog', N'BackupHistory', N'JobHistory')),
        nRetentionDays    int          NULL     -- Cleanup: Aufbewahrung (Tage)
            CONSTRAINT CK_tMaintenanceJob_nRetentionDays CHECK (nRetentionDays > 0),
        nFullMaxHours     int          NULL     -- BackupWatchdog: max. Alter letztes Full (h)
            CONSTRAINT CK_tMaintenanceJob_nFullMaxHours  CHECK (nFullMaxHours > 0),
        nLogMaxHours      int          NULL     -- BackupWatchdog: max. Alter letztes Log (h)
            CONSTRAINT CK_tMaintenanceJob_nLogMaxHours   CHECK (nLogMaxHours > 0),
        bEnabled       bit           NOT NULL
            CONSTRAINT DF_tMaintenanceJob_bEnabled DEFAULT (1),
        bNotifyOnFail  bit           NOT NULL
            CONSTRAINT DF_tMaintenanceJob_bNotifyOnFail DEFAULT (1),
        cNotes         nvarchar(400) NULL,
        dCreated       datetime2(0)  NOT NULL
            CONSTRAINT DF_tMaintenanceJob_dCreated  DEFAULT (SYSUTCDATETIME()),
        dModified      datetime2(0)  NOT NULL
            CONSTRAINT DF_tMaintenanceJob_dModified DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT UQ_tMaintenanceJob_cDisplayName UNIQUE (cDisplayName),
        -- Anlegen UND Entfernen hängen am Namenspräfix — eine präfixlose Zeile erzeugte einen
        -- Geisterjob außerhalb des verwalteten Fensters (D33; Vorbild: CK_tResetStep_cProcName):
        CONSTRAINT CK_tMaintenanceJob_cDisplayName
            CHECK (cDisplayName LIKE N'RoboticoOps - Maint - _%'),
        CONSTRAINT CK_tMaintenanceJob_cOperation
            CHECK (cOperation IN (N'IntegrityCheck', N'IndexOptimize', N'Cleanup', N'BackupWatchdog')),
        -- weekly braucht einen Wochentag, daily/hourly verbieten ihn:
        CONSTRAINT CK_tMaintenanceJob_Schedule CHECK (
               (cFrequency IN (N'daily', N'hourly') AND nWeekdayMask IS NULL)
            OR (cFrequency = N'weekly' AND nWeekdayMask IS NOT NULL)
        ),
        -- jede Operation trägt ihre Pflicht-Stellschrauben UND lässt fremde leer → die Registry ist selbst-validierend:
        CONSTRAINT CK_tMaintenanceJob_OperationKnobs CHECK (
               (cOperation = N'IntegrityCheck' AND bUpdateStatistics IS NULL AND cCleanupTarget IS NULL
                    AND nRetentionDays IS NULL AND nFullMaxHours IS NULL AND nLogMaxHours IS NULL)
            OR (cOperation = N'IndexOptimize'  AND bUpdateStatistics IS NOT NULL  -- Pflicht-Knob (D33):
                    -- NULL wäre "Sync entscheidet" — die naheliegende Lesart "Parameter weglassen"
                    -- reproduzierte exakt F8 (IndexOptimize ohne Statistikpflege)
                    AND cCleanupTarget IS NULL AND nRetentionDays IS NULL
                    AND nFullMaxHours IS NULL AND nLogMaxHours IS NULL)
            OR (cOperation = N'Cleanup'        AND cCleanupTarget IS NOT NULL AND nRetentionDays IS NOT NULL
                    AND bUpdateStatistics IS NULL AND nFullMaxHours IS NULL AND nLogMaxHours IS NULL)
            OR (cOperation = N'BackupWatchdog' AND nFullMaxHours IS NOT NULL AND nLogMaxHours IS NOT NULL
                    AND bUpdateStatistics IS NULL AND cCleanupTarget IS NULL AND nRetentionDays IS NULL)
        )
    );

    -- Registry ist repo-owned (D11/D19): Live-Schreibzugriffe würden beim nächsten Deploy
    -- vom MERGE überschrieben — daher nur SELECT für ops_admin (bewusste Abweichung von den
    -- übrigen ops.*-Tabellen, deren Write-Grants echtes Admin-Tuning tragen).
    -- Der sa-owned Agent-Job erreicht die Tabelle über Ownership-Chaining (maint/ops: AUTHORIZATION dbo).
    GRANT SELECT ON ops.tMaintenanceJob TO ops_admin;
END
GO
```

> [!NOTE]
> The table DDL is one-time (`up/`, immutable). The **target rows** are not hard-wired here but reconciled via MERGE in B3 (repo stays SSoT, schedule changes do not break grate's hash chain).

> [!NOTE]
> **Deliberate trade-off — one `cDatabases` column with two grammars:** the column carries, depending on `cOperation`, an Ola `@Databases` expression or a literal comma list (watchdog) — the only place where the grammar is enforced by documentation instead of by CHECK (all knob columns are schema-validated). A split into two columns (`cOlaDatabases`/`cWatchdogDatabases` + CHECK extension) was considered and rejected at the current 6 repo-owned rows as not worthwhile; instead the watchdog validates its target list itself at runtime (`TRIM` + `THROW 51100` on an unknown/non-ONLINE target, see §3.2/D32). Should the registry grow or a third grammar appear, the column split is the intended escalation.

### §3.2 — B2: Sync procedures (anytime)

`db-migrations/global/sprocs/` (`CREATE OR ALTER`, RoboticoEKL Hungarian):

- `maint.spEnsureMaintenanceJobs.sql` — reads `ops.tMaintenanceJob`, **synchronizes** the Agent jobs (create/update/remove by name prefix), sa-owned. Each job gets the **constant dispatch step** `EXECUTE RoboticoOps.maint.spRunMaintenanceJob @cJobKey = N'<key>';` (fully qualified — ADR-A failure mode "wrong DB context"/F2; the only sync-time substitution is the `cJobKey` literal, D28) and the schedule from `cFrequency`/`nWeekdayMask`/`tStartTime` per the **schedule-mapping table** (below, D31). The job exists for **every** registry row; `bEnabled` + instance switch (D34, NOTE below) map onto the job-enabled state — pause = disable, never delete (history stays, pause visible in SSMS). **Sync mechanics (D17/D18, refined by D29/D31) — pattern `reset.spEnsureAgentJob`, but deliberately different in three places:**
  - **Per-job comparison instead of blanket drop — in canonical normal form (D31):** job missing → create; target definition differs → drop/recreate exactly this job (`sp_delete_job … @delete_unused_schedule = 1`, otherwise orphaned schedules accumulate in msdb); otherwise no-op. The comparison surface is a **closed list**: job (`enabled`, `notify_level_email`, `notify_email_operator`), step (command text — constant since D28 —, `database_name`, `subsystem`), schedule (`freq_type`, `freq_interval`, `freq_recurrence_factor`, `freq_subday_type`, `freq_subday_interval` (D35), `active_start_time`, `enabled`). All column comparisons NULL-safe via `IS DISTINCT FROM` (D30); registry values are converted into the msdb representation BEFORE comparison (mapping table) — any facet outside the list would be invisible drift, any unnormalized comparison (e.g. `time(0)` against int HHMMSS) a permanent drop/recreate with a permanently red AC7. This is how the proc reports "0 changes" (AC7 measurement point) and is safe to call from `260` on every deploy. **Deliberately accepted:** an intended drop/recreate costs the Agent job history of exactly that job.
  - **Running-job guard:** conceptually like the model, mechanically different — there application-side (`ops.tResetRequest`), here per job against `msdb.dbo.sysjobactivity`, **scoped to the current Agent session** (`session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions)`, D31 — without this scoping a job would count as "running" forever after an Agent stop/crash left an open `stop_execution_date IS NULL` row; on test1 the Agent is deliberately started/stopped, so the false positive would be operational normality there; with the Agent stopped nothing runs): a job currently running is **skipped and reported**, no global THROW (a running nightly CHECKDB must neither be dropped nor abort the deploy). A skip **converges on the next deploy**, because `260` calls the sync unconditionally (D29).
  - **Operator-EXISTS guard:** `@notify_email_operator` is only wired when the operator exists in `msdb.dbo.sysoperators` (otherwise `NULL`, exactly like `reset.spEnsureAgentJob`) — the deploy never fails on a missing operator; first-deploy convergence is handled by `260` (§3.3).
  > [!IMPORTANT]
  > **Safety rule (Fix A — resolved via runtime dispatch, D28):** a persisted Agent job step is a static T-SQL string in `msdb.dbo.sysjobsteps` — embedding registry values into step texts would inevitably mean concatenation (the original rule wording "only `sp_executesql` parameters" was unimplementable for that, FT-1). Therefore the values are not rendered into steps at all: the step is **constant**, and `maint.spRunMaintenanceJob` reads the registry row **at runtime** and passes `cDatabases` + knobs as **real T-SQL parameters** to the Ola/system procedures — entirely without dynamic SQL. Data never becomes code; the rule holds literally (same logic as the whitelist in `ops.tResetStep`, and the same pattern as the parameterless reset step `EXEC reset.spProcessNextResetRequest`). The only sync-time substitution is the `cJobKey` literal in the dispatch call — quote-doubled when embedded (`REPLACE(@cJobKey, N'''', N'''''')`), even though repo-owned (belt-and-braces, lint rule (g)). *Actively rejected (FT-1 alternative a):* merely re-scoping the rule ("escaped literals allowed at step build") would have kept parameter-carrying, drift-prone step texts and only patched the frozen-date/comparison problems (FT-3, FT-7) instead of structurally eliminating them.

  **Schedule mapping (D31)** — registry → `msdb.dbo.sysschedules`, including the mandatory values without which `sp_add_jobschedule` fails or the normal-form comparison never converges:

  | Registry | `sysschedules` |
  |---|---|
  | `cFrequency = 'daily'` | `freq_type = 4`, `freq_interval = 1` (mandatory ≥ 1), `freq_subday_type = 1` (once at start time), `freq_subday_interval = 0` |
  | `cFrequency = 'weekly'` | `freq_type = 8`, `freq_interval = nWeekdayMask`, **`freq_recurrence_factor = 1`** (mandatory ≥ 1 — omitting it makes `sp_add_jobschedule` throw error 14266, and the first deploy of the weekly jobs fails), `freq_subday_type = 1`, `freq_subday_interval = 0` |
  | `cFrequency = 'hourly'` (D35) | `freq_type = 4`, `freq_interval = 1`, **`freq_subday_type = 8`, `freq_subday_interval = 1`** (hourly from `active_start_time` until end of day; anchor 00:00 → around the clock) |
  | `tStartTime` | `active_start_time = DATEPART(HOUR, …) * 10000 + DATEPART(MINUTE, …) * 100 + DATEPART(SECOND, …)` (int HHMMSS) |

  The subday columns have belonged to the D31 comparison surface since D35 (an additive extension of the canonical normal form — exactly the extension path the table was built for).

- `maint.spRunMaintenanceJob.sql` — **runtime dispatcher (D28, fourth `maint.*` proc):** takes `@cJobKey`, reads the registry row (unknown key → `THROW 51120`) and executes the operation per the **command matrix** — the command build has exactly one home, a commented `CASE` block in this proc. Cleanup cutoffs are computed **at runtime** (`DATEADD(DAY, -@nRetentionDays, SYSDATETIME())` from the registry column — never a sync-time frozen date that would let the cleanup silently degrade to a no-op over the years); `bUpdateStatistics` is consumed (`1 → @UpdateStatistics = 'ALL'`, `0 →` parameter omitted, D33). Registry changes to scope/knobs therefore take effect **immediately after the MERGE**, without a job drop/recreate — only schedule/notify/name changes touch msdb.

  | Operation (+target) | Runtime command in `spRunMaintenanceJob` |
  |---|---|
  | `IntegrityCheck` | `EXECUTE RoboticoOps.dbo.DatabaseIntegrityCheck @Databases = @cDatabases, @LogToTable = 'Y'` |
  | `IndexOptimize` | `EXECUTE RoboticoOps.dbo.IndexOptimize @Databases = @cDatabases, @UpdateStatistics = <Mapping D33>, @FragmentationHigh = … (REORGANIZE-only, see NOTE), @LogToTable = 'Y'` |
  | `Cleanup` + `CommandLog` | `DELETE RoboticoOps.dbo.CommandLog WHERE StartTime < DATEADD(DAY, -@nRetentionDays, SYSDATETIME())` (no Ola proc) |
  | `Cleanup` + `BackupHistory` | `DECLARE @cutoff datetime = DATEADD(DAY, -@nRetentionDays, SYSDATETIME()); EXECUTE msdb.dbo.sp_delete_backuphistory @oldest_date = @cutoff` |
  | `Cleanup` + `JobHistory` | analogous: `EXECUTE msdb.dbo.sp_purge_jobhistory @oldest_date = @cutoff` |
  | `BackupWatchdog` | `EXECUTE RoboticoOps.maint.spCheckBackupChain @Databases = @cDatabases, @FullMaxHours = @nFullMaxHours, @LogMaxHours = @nLogMaxHours;` then `EXECUTE RoboticoOps.maint.spCheckMaintenanceLiveness;` (D36 — a THROW of the first check ends the step: one alarm per run, the next hourly run reports the rest) |

  > [!NOTE]
  > A **new operation kind** is deliberately **not** "just a registry row": new `CK_…_cOperation` value, possibly new knob columns (new `up/`), new `CASE` branch in `spRunMaintenanceJob`, docs rows (B4). "Add a row" applies to new instances of **existing** operation kinds. The recipe for it is in the header of `spRunMaintenanceJob` (analogous to README §9 for reset steps).

> [!NOTE]
> **Instance switch `ops.tConfig('MaintenanceSchedulesEnabled')` (D34):** effective job-enabled state = `bEnabled = 1` AND switch ≠ `'0'` (missing key = enabled — prod needs no entry). test1 sets `'0'`: the jobs exist there in full (structure and rollout gate apply) but are disabled — **`sp_start_job` also starts disabled jobs**, so the manual B5 validation works unchanged. Thereby "no standing schedule on test1" (AC9, ADR-A §D-A6) is **enforced instead of asserted**: the test1 Agent MUST run for reset work (reset via `sp_start_job`, see `reset.spPub_StartTestmandantReset`), so the service status does not qualify as a gate — otherwise every overnight reset session would fire the full prod maintenance incl. a daily-red watchdog on test1 (alarm desensitization, exactly the ADR-B anti-goal). The switch is admin-owned instance **state** like `AgentJobName`/`NotifyOperator` (README §7 table); the registry rows stay identical on all instances (D-A6).
- `maint.spCheckBackupChain.sql` — read-only freshness check over `msdb.dbo.backupset` (filter `is_copy_only=0` for full), thresholds as proc parameters from the dispatcher (`nFullMaxHours`/`nLogMaxHours`). **Time base local (D32):** `backupset.backup_finish_date` is **local server time** — age comparisons compute with `SYSDATETIME()`, NEVER `SYSUTCDATETIME()` (at CEST/UTC+2 the UTC grab would widen the 1-h log threshold to ~3 h in reality; as a gotcha comment in the proc header, precisely BECAUSE the rest of the design uses `SYSUTCDATETIME()` throughout). Interprets `cDatabases` as a **literal comma list** (`STRING_SPLIT`; recovery model per DB from `sys.databases`) — Ola collection tokens like `USER_DATABASES` are **invalid** for watchdog rows. **Target validation (D32):** tokens are `TRIM()`ed; every token without an ONLINE match in `sys.databases` (typo, leftover whitespace, OFFLINE/RESTORING DB, accidental Ola token) → `THROW 51100` with the token in the error text — an unknown watch target is an **alarm, not a silent skip** (otherwise an unwatched production DB would be indistinguishable from a green job — the watchdog variant of the F2 pattern). Docs in B4 + proc header. **Log freshness is checked for all log-based recovery models** — filter `recovery_model_desc <> N'SIMPLE'`, covers FULL **and** BULK_LOGGED (D27; SIMPLE DBs have no log chain by construction → otherwise a permanent false alarm). Threshold semantics: alarm on `age >= threshold` (the edge case alarms, see AC5). "Alerting" = the job step throws **`THROW 51100`** on a stale chain → job fails → `NotifyOperator` mail (the same reporting path as for all maintenance jobs).
- `maint.spCheckMaintenanceLiveness.sql` — **maintenance liveness check (D36, fifth `maint.*` proc, parameterless):** `bNotifyOnFail` only catches jobs that **run and fail** (F2) — but the historically dominant damage was the **"never runs" pattern** (F3/F4: 2 years no CHECKDB despite existing jobs), and that stays invisible to Notify (schedule live-detached, job live-disabled; the `260` self-heal only kicks in on the next deploy, which may be weeks away). The proc closes the gap **self-configuring from the registry**: for every effectively enabled row (`bEnabled = 1` AND instance switch ≠ `'0'`, D34 — thus by construction a no-op on test1) with `cOperation IN (N'IntegrityCheck', N'IndexOptimize')` it derives the maximum permissible age of the most recent matching `dbo.CommandLog` entry from the declared schedule (`daily` → 26 h, `weekly` → 8 days; `CommandType` mapping: IntegrityCheck → `DBCC_CHECKDB`, IndexOptimize → `ALTER_INDEX`/`UPDATE_STATISTICS` — the latter logs on every run at `@UpdateStatistics='ALL'` with Ola default `@OnlyModifiedStatistics='N'`) and otherwise throws **`THROW 51105`** with the stale `cJobKey`s in the error text. Cleanups are deliberately excluded (they don't log to CommandLog; failure consequence uncritical), the watchdog monitors itself via its own reporting path. `CommandLog.StartTime` is **local time** (Ola logs `GETDATE()`) — same `SYSDATETIME()` time base as D32, same gotcha comment. **Remaining blind spot, deliberate:** a stopped Agent service falls silent along with the watchdog — from within Agent jobs not self-monitorable by principle; documented as an ADR-A failure mode and assigned to the external monitoring follow-up task (Gap 2).

> [!NOTE]
> **THROW allocation (lint rule (k), D21 + D28 + D36):** `51100` = `spCheckBackupChain` (stale-chain AND invalid watch target, D32), `51105` = `spCheckMaintenanceLiveness` (stale maintenance, D36), `51110` = `spEnsureMaintenanceJobs` (guard/error path, reserved), `51120` = `spRunMaintenanceJob` (unknown `cJobKey`). Enter all in the README §4 (k) table in the same commit ([EDIT] `db-migrations/README.md`) — and while doing so **carry over** the (k) guidance sentence "New steps take the next free `510x0` block" (FT-14): the next free block after the reset allocation (up to `51094`) would otherwise be exactly `51100`; new wording: `51100–51129` are maint-reserved, new reset steps start at `51130`. Likewise in the same commit: register the five `maint.*` procs (type `P`) + `ops.tMaintenanceJob` (type `U`, incl. key columns) in `db-migrations/tests/global/validate_structure.sql` (lint rule (l), [EDIT]) — otherwise the lint fails or the proc escapes the rollout gate.

> [!NOTE]
> **IndexOptimize on Standard Edition: REORGANIZE-only.** The sync passes `@FragmentationHigh` without an `INDEX_REBUILD_OFFLINE` action: Standard Edition cannot rebuild ONLINE, and an offline rebuild at 02:00 would lock the tables of a 24/7 ERP. At the current 0 indexes >30 % ([6-wartung-ist-analyse F7](../2026-07-10 - mssql-ops-infrastruktur/research/6-wartung-ist-analyse/6-wartung-ist-analyse.md)) the sacrifice costs nothing; should an index ever stay >30 % permanently, a manual rebuild in the maintenance window is the deliberate exception.

Target registry (seed goal for B3, materializes the ADR-A §D-A4 matrix):

| `cJobKey` | `cOperation` | `cDatabases` | Knobs (typed columns) | Schedule (`cFrequency`/`nWeekdayMask`/`tStartTime`) |
|---|---|---|---|---|
| `checkdb` | IntegrityCheck | `ALL_DATABASES, -eazybusiness_tm%` | — | weekly **Sun+Wed** (mask 9) 01:00 |
| `index-optimize` | IndexOptimize | `USER_DATABASES` | `bUpdateStatistics=1` | daily 02:00 |
| `cleanup-commandlog` | Cleanup | `RoboticoOps` | `cCleanupTarget=CommandLog, nRetentionDays=365` | weekly Sun 00:30 |
| `cleanup-backuphistory` | Cleanup | `msdb` | `cCleanupTarget=BackupHistory, nRetentionDays=365` | weekly Sun 00:35 |
| `cleanup-jobhistory` | Cleanup | `msdb` | `cCleanupTarget=JobHistory, nRetentionDays=365` | weekly Sun 00:40 |
| `backup-watchdog` | BackupWatchdog | `eazybusiness,RoboticoOps,msdb` | `nFullMaxHours=26, nLogMaxHours=1` | **hourly** (anchor 00:00, D35) |

**CHECKDB scope (Lukas, 2026-07-21):** twice weekly (Sun+Wed, each before the 03:00 full) via **one** job with `ALL_DATABASES, -eazybusiness_tm%` — Ola's exclusion syntax captures user **and** system DBs (incl. `msdb`) in one run and excludes the tm clones: those are throwaway copies regenerated fresh from the integrity-checked source via reset — checking them too would be pure overhead. The earlier system/user split is dropped (one job fewer). **IndexOptimize, in contrast, keeps the tm clones** (interactive work happens there → defrag + fresh statistics desired).

> [!NOTE]
> **No job output files** (deliberate): the sync proc sets no `@output_file_name` on the job steps — the history lives entirely in `dbo.CommandLog` (`@LogToTable='Y'`) + the Agent job history. This eliminates the `OutputFiles` cleanup, the only filesystem special case and any CmdExec dependency.

### §3.3 — B3: Reconcile + Ensure + Alerting (everytime / runAfter)

- `db-migrations/global/runAfterOtherAnyTimeScripts/maint.spApplyMaintenance.sql` — self-executing wrapper (pattern `reset.spEnsureAgentJob`): (a) **value-guarded MERGE** of the target rows from §3.2 into `ops.tMaintenanceJob` — `WHEN MATCHED AND (at least one target column differs) THEN UPDATE` and then explicitly sets `dModified = SYSUTCDATETIME()` (SQL Server has no ON-UPDATE default); the column comparison in the guard is **NULL-safe via `IS DISTINCT FROM`** (D30 — six target columns are NULLable, with `<>` every pure NULL↔value change would be silently swallowed: the deploy reports a no-op, git and live state diverge); unchanged rows are **not** touched → no `dModified` churn, a real no-op for AC7, and `dModified` stays usable as an audit signal. Additionally **`WHEN NOT MATCHED BY SOURCE THEN DELETE`** (D30): rows removed from the seed disappear from the live registry, and the following Ensure removes the associated job in the same deploy — without the delete branch D11 ("repo is SSoT") would hold only for updates, never for deletions, and the AC3 removal path would never fire (the row would still be target). Safe because the registry is fully repo-owned — there are no foreign rows worth protecting (exactly the B12 delimitation). — (b) `EXEC maint.spEnsureMaintenanceJobs`. Runs in grate's last anytime stage, after all sprocs exist — but **before `permissions/`**: the operator wiring of the first deploy therefore pulls in `260` (below).

> [!IMPORTANT]
> **The maintenance registry is repo-owned — a deliberate deviation from `ops.tResetStep`.** The MERGE enforces **all** target columns on every deploy (including `bEnabled`, times, thresholds): live changes to the table are overwritten on the next deploy. Maintenance tuning goes **exclusively via git + deploy** — that is intended here (full traceability was the requirement), whereas `ops.tResetStep` deliberately lets admin tuning win (seed insert-only, QG3 B12). The difference is documented in the proc header. **Why MERGE, even though `up/0021` deliberately seeds row-by-row (QG3 B12)?** The B12 collision arose from a live re-ordering of admin-owned rows under a UNIQUE constraint; this registry is repo-owned with stable keys (`cJobKey`, `cDisplayName`) and without admin reordering — the collision situation does not exist here. This rationale belongs in the proc header too (a deliberate, documented deviation from the 0021 decision).
- `db-migrations/global/permissions/260_maintenance_operator.sql` — everytime, idempotent, **three tasks in one script** (D17, task 3 refined by D29; prefix `260` orders after `250_jobstartuser_mapping` and before `900_resign`). Background: grate runs `permissions/` **after** `runAfterOtherAnyTimeScripts/` — on the first deploy the operator does not yet exist when the sync runs, and because the sync is hash-gated, the notify wiring would **never** be pulled in on a clean redeploy without this script (QG-Critical SEC-3-1):
  1. Create operator `RoboticoOps-Maint` (email `lukas@dattenberger.com`) if missing. **Deliberate deviation from the reset pattern (document in the `260` header):** the reset infra externalizes its operator in `ops.tConfig('NotifyOperator')` (instance-tunable); maintenance hard-codes name + recipient in the committed script — consistent with the repo-owned stance of the entire maintenance registry (recipient change = git + deploy, same traceability as any other tuning). Not an oversight, but the same D11 logic. *(Decided in R2, D34: the operator email stays hard-coded, even though the `ops.tConfig` switch `MaintenanceSchedulesEnabled` now exists — the switch carries instance **state** (like `AgentJobName`), the operator identity is repo-owned **policy**; no move to `ops.tConfig`.)*
  2. Set the Agent mail profile `Standard SMTP` (only if not set; do not force a restart) — and **only if the profile exists in `msdb.dbo.sysmail_profile`** (FT-16): otherwise a clear PRINT hint instead of writing a phantom profile name that the "only if not set" guard would then cement (on test1 Database Mail may not be configured; no THROW — same philosophy as the operator-EXISTS guard). **Gotcha:** the profile assignment only takes effect after an **Agent restart** — the script prints a clear hint in that case; the restart itself is a cutover-runbook step (§3.6 no. 4), never a deploy side effect.
  3. **Unconditional Ensure call + everytime self-heal (D29 — replaces the conditional re-trigger; the pattern `permissions/200_ensure_agent_job.sql` thought further):** `EXEC maint.spEnsureMaintenanceJobs` runs on **every** deploy. A trigger precondition ("job missing / notify missing") would reopen the catch-up hole: hash gating + skip-and-report + conditional trigger would mean that a definition change skipped while a job was running would NEVER be applied (grate calls `spApplyMaintenance` only on a hash change, and definition drift would not be a trigger condition — git and live state would diverge silently on a green deploy). The per-job comparison (D31) makes the unconditional call a no-op in the healthy state anyway — the condition was an optimization without a saving, but with a hole. This (a) pulls in the notify wiring on the first deploy after the operator creation (convergence for AC6), (b) heals manually deleted jobs or a restored `msdb` on every deploy — the same self-healing guarantee the reset infra deliberately introduced with the 200er —, and (c) applies any previously reported running-skip on the next deploy. No drop/recreate per deploy (normal-form comparison), a running job is never touched (guards see §3.2).

### §3.4 — B4: Docs contracts (data model + naming SSoT)

More than "append a column section" — three places in `docs/SQL/MSSQL-OPS-DATA-MODEL.md` [EDIT] plus the naming SSoT:

- **Header:** "four registry tables" → "five"; extend the scope wording around the maintenance infrastructure (the table belongs to maintenance, not to the test-tenant reset).
- **`[!IMPORTANT]` maintenance-contract box:** add `up/0023_maintenance_registry.sql` (the box currently lists only `0002`/`0021` — without this addition the same-commit contract for the new table is formally void). Optional for parity: extend the CLAUDE.md contract list by `0023` (generically covered by "any future `up/` script").
- **New column section `ops.tMaintenanceJob`** (every column; incl. the **double grammar of `cDatabases`**, see §3.1/§3.2).
- **`docs/SQL/NAMING-CONVENTIONS.md` [EDIT]:** (a) extend the §"schemas we own" by a `maint.*` row (third owned schema: `maint.spEnsureMaintenanceJobs`, `maint.spRunMaintenanceJob`, `maint.spCheckBackupChain`, `maint.spCheckMaintenanceLiveness`, `maint.spApplyMaintenance`); (b) add the type prefix **`t` = `time` column** as a documented micro-convention (D20 — a deliberate second use of the letter alongside the table prefix `t<Singular>`, so `tStartTime` is not read as a typo; see ADR-A §D-A2).
- **`docs/SQL/MSSQL-OPS-ARCHITECTURE.md` [EDIT] (D25):** the architecture doc is the declared SSoT of the Standing Operating Rules (§6) and is made factually wrong by this package — it literally says "holds two schemas (ops, reset)" and carries an Ebene-B file inventory. Existing-content update (no new architectural content — that lives in the ADRs): (a) "two schemas" → "three schemas" incl. a `maint` row in the §5 ownership table; (b) a short `maint` subsystem paragraph in §1a.2/§3 (registry `ops.tMaintenanceJob`, 5 `maint.*` procs, vendored Ola objects in `RoboticoOps.dbo`, 6 Agent jobs, watchdog incl. liveness check); (c) extend the inventory table by the 6 new files + `ops.tMaintenanceJob`; (d) **two new §6 standing rules**: "Backups stay with CBB — the maintenance suite never creates a backup job, nobody folds backups into Ola 'for tidiness'" (ADR-B boundary) and "Maintenance tuning exclusively via git + deploy — the registry is repo-owned, live edits are overwritten" (D11).

Mandatory in the same commit as B1 (CLAUDE.md contract).

### §3.5 — B5: test1 deploy + validation

`deploy.ps1 -Scope global` against test1; start the Agent temporarily or trigger the jobs manually via `sp_start_job` (also starts disabled jobs — the D34 switch setting does not disturb the manual validation). Checklist:

- **One-time (admin-owned, right after the first deploy):** set the `ops.tConfig` entry `MaintenanceSchedulesEnabled = '0'` on test1; the next `260` run or a manual `EXEC maint.spEnsureMaintenanceJobs` pulls the disabled state through for all jobs (D34). Then check: all `RoboticoOps - Maint - ` jobs exist and are disabled.

- Ola objects in `RoboticoOps.dbo`; **`RoboticoOps.dbo.DatabaseBackup` does not exist** (AC2/AC4); no `eazybusiness.dbo` Ola objects created by our chain.
- Registry contains the target rows from §3.2 (currently **6** — §3.2 is SSoT, don't maintain the number separately here).
- Jobs created; **one green run of all Ola/cleanup jobs (all registry rows except `backup-watchdog`; §3.2 = SSoT)**; CommandLog entries present.
- **`backup-watchdog`: on test1 NO green job run is reachable** (no CBB chain → stale alarm is by design, cf. ADR-B). Instead a logic test: `EXEC maint.spCheckBackupChain` directly — throws `51100` on a missing/stale chain and on an invalid watch target (D32), stays silent on a fresh chain. **Test path for "fresh" (FT-15):** a direct `INSERT` into `backupset` fails on the media-set FKs — instead create real entries via `BACKUP DATABASE … TO DISK = 'NUL'` + `BACKUP LOG … TO DISK = 'NUL'` (test1-only; **never on CBB-secured instances** — a non-copy-only full shifts the diff base there). This also covers the AC5 threshold test; while at it, also check an edge case just beyond the threshold (`>=` boundary semantics D27, local time base D32).
- **Liveness logic test (AC13, D36):** `EXEC maint.spCheckMaintenanceLiveness` directly — before the manual job runs (empty/stale CommandLog) it throws `51105` with the stale `cJobKey`s; after the green B5 runs of `checkdb` + `index-optimize` it stays silent. Additionally check the D34 path: with instance switch `'0'` and a `bEnabled=0`-simulated row it does **not** alarm (only effectively enabled rows count).
- **Sync-path tests (FI-8) — the two so-far untested core promises of the Ensure:** (a) **drift correction:** set a job schedule live in msdb → `EXEC maint.spEnsureMaintenanceJobs` reports **"1 change"** (normal-form comparison D31) and restores the registry state; (b) **foreign-job removal:** create a dummy job `RoboticoOps - Maint - zz-test` via `sp_add_job` → re-sync removes it (AC3 removal path).
- `index-optimize`: the job step is the constant dispatch (D28); the run's `CommandLog` entry shows `@UpdateStatistics = 'ALL'` (AC10) and **no** `*_REBUILD_OFFLINE` action (D13).
- **Idempotency re-deploy (AC7):** a second `deploy.ps1 -Scope global` → grate no-op, `260` calls the sync and it reports **0 changes**, no job re-creation, `dModified` unchanged.
- `npm run db:lint` + `validate_structure.sql` green (AC11).
- **AC6 limit on test1:** mail sending only takes effect after an Agent restart — here only check operator/profile existence and job wiring, no mail test (that is B6 no. 6).

Afterwards Agent back to Stopped — but the standing-schedule protection hangs on the instance switch `MaintenanceSchedulesEnabled = '0'` (D34), not on the service status: the Agent may run anytime (even overnight) for reset work without maintenance jobs firing.

### §3.6 — B6: Prod cutover (human-gated runbook)

The B6 steps are **woven into** `docs/runbooks/rollout-mssql-ops.md`, not appended as a monolithic phase ([EDIT], D22/D26 — the prod activation is part of the RoboticoOps prod cutover, whose spine this runbook is; a separate maintenance runbook would describe the activation in two places). **Weaving rule (D26):** the deploy that B6 surrounds is not a new one — the maintenance files sit in `db-migrations/global/` and deploy in the **existing Phase-4 deploy** of the runbook (`deploy.ps1 -Scope global -Environment PROD`; there is no separate "maintenance only" deploy). Therefore: **step 1 is anchored as a precondition sub-step "Phase 4a — remove old Ola" BEFORE the `deploy.ps1` call in Phase 4; steps 3–6 are hooked in as follow-up steps/phase AFTER Phase 4.** B6 must expressly NOT be hung as "Phase 8" behind Phase 7 — then step 1 would run after the deploy that has already actively created the new jobs (precisely the violation the CAUTION below forbids).

**Preconditions (before Phase 4a):**
- **Gap 5.1 is decided ✅ (Lukas, 2026-07-22, D40):** the foreign prod DBs deliberately stay **in the active maintenance scope** — the first nightly run runs CHECKDB/IndexOptimize against them too, as planned (small, ~1 GB; cost trivial; corruption detection wanted). No exclusion expressions.
- **Gap 5.3** (RoboticoOps prod cutover) as before: a hard precondition.

Execution **only with explicit release**:

1. **Remove old install — BEFORE the deploy** (runbook, not a migration; D16): first confirm all Ola objects in `eazybusiness.dbo` via an inventory query; **archive the old `CommandLog` before the drop** (D39: `SELECT * INTO RoboticoOps.dbo.CommandLog_legacy_eazybusiness FROM eazybusiness.dbo.CommandLog` — 9,218 rows, the only primary evidence of the 2025-11-27 failure pattern and the last real maintenance runs; seconds of effort, irretrievable afterwards); then delete the 11 old Ola jobs and drop `CommandLog`, `CommandExecute`, `DatabaseIntegrityCheck` as well as any remnants of `IndexOptimize`/`DatabaseBackup` and Ola tables from `eazybusiness.dbo` (respects "never dbo via migration"). **No loss of coverage:** the old jobs have been ineffective since ~2025-11 (IndexOptimize fails nightly, CHECKDB last ran 2024).
2. The global chain deploys RoboticoOps + the maintenance suite onto vm-sql2 (part of the RoboticoOps prod cutover). The new jobs are created **immediately enabled + scheduled** (`bEnabled` default 1) — collision-free thanks to step 1.
3. **Add RoboticoOps to the CBB backup** — not a new work step but the **reference to the existing Phase-2/4 backup step of the runbook** (the instruction "add RoboticoOps LOG backups" already lives there; don't describe the action twice, the SSoT stays the Phase-2/4 step). In the runbook [EDIT], add there: **"this LOG-backup activation ends the hourly `backup-watchdog` alarm for RoboticoOps."** Until it happens the watchdog fires **hourly** (D35) for RoboticoOps — that is intended: the alarm IS the detector for the missing coverage; the cadence makes it un-ignorable, so complete step 3 on the cutover day itself. **While at it also (D37): verify CBB coverage of the system DBs** — F1 proves the healthy chain only for `eazybusiness`, and precisely this plan makes `msdb` valuable (jobs, schedules, operator, `backupset` history = the watchdog's data basis), while step 1 removes the old — never-run — `SYSTEM_DATABASES` backup jobs without replacement. Query: most recent `backupset` full per system DB (`msdb`, `master`). **Already verified in advance (2026-07-22, D41):** both hang in the real chain (full 03:00 `copy_only=0`) → `msdb` has since stood in the `backup-watchdog` row (§3.2; the log check skips it as SIMPLE per D27). This step is therefore a **re-verification** on the cutover day (the CBB configuration may have changed by then); if the result differs → reopen §5 Gap 6.
4. **Restart the SQL Agent once**, so the freshly assigned mail profile takes effect in the alert system (the assignment only takes effect after an Agent restart). Do not evaluate any alarm test before that. **Guard before the restart:** verify that no Agent job is currently running — the restart kills running jobs, and the Agent is shared with the reset infra (reset via `reset.spPub_GetResetStatus`/`sysjobactivity`, maintenance via `sysjobactivity`); analogous to the deploy guard of the parent runbook ("no global deploy during a running reset").
5. **Verification (pure check — the jobs have existed since step 2):** schedules correct; per job the constant, fully qualified dispatch step `EXECUTE RoboticoOps.maint.spRunMaintenanceJob @cJobKey = …` (D28; ADR-A failure mode "wrong DB context"/F2); notify wiring present on all `bNotifyOnFail=1` jobs (`260` pulled it in after the operator creation); `MaintenanceSchedulesEnabled` **not** set on prod (jobs enabled, D34). **Check and raise the Agent job-history limit (D38):** the Agent default (1,000 rows total / 100 per job) rolls over `sysjobhistory` far before the declared 365-day retention — job outcomes incl. error texts (the F2 forensic source) live only there. Via `msdb.dbo.sp_set_sqlagent_properties @jobhistory_max_rows = 10000, @jobhistory_max_rows_per_job = 1000` (instance state, admin-owned — like the switch/operator not a migration subject); only then is the `cleanup-jobhistory` retention the actual one.
6. Observe the first nightly run — **measure durations while doing so** (CHECKDB Sun/Wed 01:00 + IndexOptimize 02:00 must really finish before the 03:00 full; the staggering is asserted by start time, not enforced — on overlap adjust the times in the registry). **Alarm-path acceptance via the natural alarm from step 3:** as long as RoboticoOps is not yet in CBB, the hourly `backup-watchdog` stale mail (THROW 51100 → operator) MUST really arrive at `lukas@dattenberger.com` — since D35 within an hour of the Agent restart, that is the side-effect-free proof that the reporting path works. No artificially forced job failure on prod needed. **While doing so, watch for false alarms in the 03:00 full window:** if CBB serializes the log backups during the large eazybusiness full, the hourly log check may slip just over the 1-h threshold there — in that case adjust `nLogMaxHours` to 2 (repo-owned, one deploy).

> [!CAUTION]
> The order is binding: remove old jobs **before** the deploy (step 1 = Phase 4a before step 2 = Phase-4 deploy) — the deploy creates the new jobs immediately active; otherwise two IndexOptimize jobs run against different object sets (ADR-A failure mode). **Time-window rule (D26):** steps 1–5 are executed **outside the window 00:30–03:00**, so that the alarm path (step 4) and verification (step 5) are demonstrably completed BEFORE the first scheduled run — otherwise unverified jobs fire without a working reporting path (e.g. deploy Sun 00:45 → checkdb 01:00). Only after that let the first nightly run (step 6) run naturally. *(Decided in R2, D34: the instance switch `MaintenanceSchedulesEnabled` now exists, but the **time-window rule stays the primary cutover safeguard** — on prod the switch stays unset (= enabled), so the standard cutover needs no additional manual toggle step and no forgotten `'0'` entry silently kills maintenance. "Deploy disabled → verify → delete switch + `EXEC maint.spEnsureMaintenanceJobs`" is mentioned in the runbook as a documented emergency lever, but is not the standard path.)*

**Rollback/abort (analogous to `rollout-mssql-ops.md` §Rollback):** if a new job stays red after the cutover, no rollback is needed — no coverage is lost (the old state was ineffective anyway). A faulty sync/step is healed via a corrected deploy (registry + procs idempotent); a manual CHECKDB / manual statistics update remains available as a fallback at any time. **If the Phase-4 deploy (step 2) aborts AFTER step 1 has already removed the old install:** likewise no rollback — the old state was ineffective, nothing is lost; fix the deploy cause (Phase-4 CAUTION of the runbook: cert password, reachability) and run again; until then the manual fallback applies.

**Runbook note (Gap 2, deliverable):** in the hooked-in follow-up phase it is explicitly noted: **"Database Mail health is unmonitored for now** — if Database Mail fails, maintenance and watchdog alarms fall silent together (owner: follow-up task in the overarching mssql-ops program)." This gives the §5 Gap-2 fallback ("noted in the runbook") a producing deliverable.

## 4. Directory Layout

```
db-migrations/global/
├── up/
│   ├── 0022_maintenance_ola_vendor.sql      [NEW]  gepinnte Ola-Objekte → RoboticoOps.dbo
│   └── 0023_maintenance_registry.sql        [NEW]  maint-Schema + ops.tMaintenanceJob (DDL)
├── sprocs/
│   ├── maint.spEnsureMaintenanceJobs.sql    [NEW]  Registry → Agent-Jobs (Sync, konstanter Dispatch-Step)
│   ├── maint.spRunMaintenanceJob.sql        [NEW]  Laufzeit-Dispatcher: Registry-Zeile → Ola-/System-Aufruf (D28)
│   ├── maint.spCheckBackupChain.sql         [NEW]  read-only Backup-Frische-Watchdog (lokale Zeitbasis, Ziel-Validierung)
│   └── maint.spCheckMaintenanceLiveness.sql [NEW]  read-only Wartungs-Liveness-Check: Registry-Soll vs. CommandLog-Frische (D36)
├── runAfterOtherAnyTimeScripts/
│   └── maint.spApplyMaintenance.sql         [NEW]  MERGE Soll-Zeilen + EXEC ensure
└── permissions/
    └── 260_maintenance_operator.sql         [NEW]  Operator + Mailprofil (guarded) + unbedingter Ensure-Aufruf/Self-Heal (everytime, D29)

db-migrations/tests/global/validate_structure.sql  [EDIT] 5 maint.*-Procs (P) + ops.tMaintenanceJob (U) + Schlüsselspalten (Lint (l))
db-migrations/tests/global/validate_rollout.sql    [EDIT] Maintenance-Operability-Block: Registry↔Agent-Jobs, Notify-Verdrahtung, Operator (AC12, D23)
db-migrations/README.md                      [EDIT] §4-(k)-Tabelle: THROW 51100/51105/51110/51120 allozieren + Guidance-Satz (Reset ab 51130, FT-14)
docs/SQL/MSSQL-OPS-DATA-MODEL.md             [EDIT] Kopf (four→five, Scope) + Vertrags-Box (0023) + ops.tMaintenanceJob-Sektion
docs/SQL/NAMING-CONVENTIONS.md               [EDIT] maint.*-Ownership-Zeile + t-Präfix (time) Mikro-Konvention
docs/SQL/MSSQL-OPS-ARCHITECTURE.md           [EDIT] three schemas + maint-Absatz + Inventar + 2 neue §6-Standing-Rules (D25, s. §3.4)
docs/runbooks/rollout-mssql-ops.md           [EDIT] B6 verwoben: Phase 4a (Alt-Ola-Entfernung) + Nachlauf-Phase nach Phase 4 (D22/D26, s. §3.6)
```

**File delta:** 8 new migration files, 7 [EDIT]s (2× tests, README, 3× SQL docs, runbook).

## Decision Log

The load-bearing decisions live in the ADRs; here the session determinations as a short reference:

| # | Decision | Source |
|---|---|---|
| D1 | Ola vendored into RoboticoOps.dbo; our objects in `maint.*` + registry in `ops.*` | ADR-A §D-A1 |
| D2 | Declarative registry `ops.tMaintenanceJob` as SSoT | ADR-A §D-A2 |
| D3 | Idempotent sync `maint.spEnsureMaintenanceJobs` (pattern `reset.spEnsureAgentJob`), sa-owned | ADR-A §D-A3 |
| D4 | One job per operation, staggered nightly, CHECKDB before the 03:00 full | ADR-A §D-A4 |
| D5 | `USER_DATABASES` incl. `eazybusiness_tm*` for index/statistics (work happens there) | ADR-A §D-A4 |
| D6 | Alerting fully wired, mail to `lukas@dattenberger.com` | ADR-A §D-A5 |
| D7 | Backups stay CBB; no Ola backup; watchdog without tm clones | ADR-B |
| D8 | Cleanup retention 365 days (reducible later) | Session 2026-07-21 |
| D9 | test1 = deploy/test target without a standing schedule | ADR-A §D-A6 |
| D10 | Schedule as typed columns (`cFrequency`/`nWeekdayMask`/`tStartTime`) instead of a cron string — same typing logic as the knobs | Review 2026-07-21 |
| D11 | Registry is **repo-owned**: seed MERGE overwrites live changes; tuning only via git+deploy (a deliberate deviation from `ops.tResetStep`) | Review 2026-07-21, §3.3 |
| D12 | No job output files → no OutputFiles cleanup, no CmdExec (registry row count: see §3.2 table as SSoT — after D15 = 6) | Review 2026-07-21, §3.2 |
| D13 | IndexOptimize REORGANIZE-only (Standard Edition: no online rebuild; offline rebuild at night unacceptable) | Review 2026-07-21, §3.2 |
| D14 | Watchdog log check only for FULL-recovery DBs; Ola individual scripts vendored (byte-unchanged), `DatabaseBackup.sql` not deployed | Review 2026-07-21, §3.1/§3.2 |
| D15 | CHECKDB **twice weekly (Sun+Wed 01:00)** as ONE job over `ALL_DATABASES, -eazybusiness_tm%` (tm clones excluded; replaces daily cadence + system/user split); schedule model extended for it to an `nWeekdayMask` bitmask | Lukas 2026-07-21, §3.2 |
| D16 | Prod cutover: old jobs/objects are removed **before** the deploy (old state ineffective anyway → no coverage loss); B6 step 5 is pure verification | QG 2026-07-21 (SEC-4-1/SEC-4-6), §3.6 |
| D17 | `260_maintenance_operator.sql` (everytime): operator + mail profile + **conditional** `EXEC maint.spEnsureMaintenanceJobs` re-trigger (pattern `200_ensure_agent_job`) — resolves the grate stage order (operator arises after the sync) and simultaneously delivers the everytime self-heal; the sync carries the operator-EXISTS guard | QG 2026-07-21 (SEC-3-1, SA-4/SEC-4-4), §3.3 |
| D18 | AC7 mechanics: grate hash gating + value-guarded MERGE (`dModified` only on a real change) + no-op `260`; sync = per-job comparison, drop/recreate only on a difference, `sysjobactivity` guard (skip + report, no global THROW) | QG 2026-07-21 (CA-4/SEC-3-8), §3.2/§3.3 |
| D19 | `ops_admin` gets only **SELECT** on `ops.tMaintenanceJob` (repo-owned: write grants would be ineffective and misleading) | QG 2026-07-21 (ADR-4), §3.1 |
| D20 | Type prefix `t` = `time` column as a documented micro-convention (a deliberate second use alongside the table prefix); [EDIT] NAMING-CONVENTIONS | QG 2026-07-21 (ADR-2/SA-7), §3.4 |
| D21 | THROW allocation: `51100` (spCheckBackupChain stale-chain), `51110` (spEnsureMaintenanceJobs, reserved); [EDIT] README §4 (k) | QG 2026-07-21 (SEC-3-3/SA-2), §3.2 |
| D22 | B6 cutover becomes a phase in `docs/runbooks/rollout-mssql-ops.md` (no separate runbook); MERGE stays despite QG3 B12 (repo-owned, stable keys, no admin reordering — rationale in the proc header) | QG 2026-07-21 (SEC-4-7, CA-6), §3.3/§3.6 |
| D23 | `validate_rollout.sql` gets a maintenance-operability block (registry↔jobs, notify, operator) — the second rollout gate of the reset infra applies to maintenance too | QG R2 2026-07-21 (SA-1), AC12/§4 |
| D24 | IndexOptimize↔reset seam over the `eazybusiness_tm*` clones: the collision is accepted — the reset wins by construction (`SINGLE_USER WITH ROLLBACK IMMEDIATE` kills the IndexOptimize session, the job reports red = one alarm; a clone in RESTORING is silently skipped by Ola); documented as an ADR-A failure mode instead of a scope change (D5 stays) | QG R2 2026-07-21 (SA-2), ADR-A |
| D25 | `docs/SQL/MSSQL-OPS-ARCHITECTURE.md` becomes an [EDIT] deliverable: existing-content update (three schemas, maint paragraph, inventory) + two new §6 standing rules (ADR-B backup boundary; git-only tuning) | QG R2 2026-07-21 (SA-3/SEC-6-2), §3.4/§4 |
| D26 | B6 is **woven** into the runbook phases (refines D22): step 1 = Phase 4a before `deploy.ps1`, steps 3–6 = follow-up after Phase 4; time-window rule (steps 1–5 outside 00:30–03:00); the Gap-5.1 decision is a cutover precondition; alarm-path acceptance via the natural watchdog stale alarm instead of a forced failure | QG R2 2026-07-21 (SEC-6-1/SA-5, SEC-6-4, SEC-6-5, SEC-6-7), §3.6 |
| D27 | Watchdog log check applies to all log-based recovery models (`recovery_model_desc <> 'SIMPLE'`, i.e. FULL + BULK_LOGGED — refines D14); threshold semantics nailed down: alarm on `age >= threshold` | QG R2 2026-07-21 (SEC-3-6, SEC-1-3), AC5/§3.2 |
| D28 | **Fix-A resolution = runtime dispatch** (CA-1 adopted, re-scope variant actively rejected): constant job step `EXEC RoboticoOps.maint.spRunMaintenanceJob @cJobKey = …`; fourth `maint.*` proc with the command matrix as a runtime `CASE`, values as real T-SQL parameters (no dynamic SQL); cleanup cutoffs at runtime (no frozen-date trap); THROW `51120`; registry changes to scope/knobs take effect without a job recreate; follows the reset precedent (constant step `EXEC reset.spProcessNextResetRequest`) | QG R2 Deep 2026-07-21 (FT-1/CA-1/SEC-3-4, FT-3), §3.2 |
| D29 | `260` calls `maint.spEnsureMaintenanceJobs` **unconditionally** on every deploy (replaces the conditional re-trigger from D17) — closes the catch-up hole from hash gating + running-skip + conditional trigger; skips converge on the next deploy | QG R2 Deep 2026-07-21 (FT-2/SEC-3-2), §3.3/AC7 |
| D30 | MERGE lifecycle complete: `WHEN NOT MATCHED BY SOURCE THEN DELETE` (rows removed from git remove the registry row + job) and NULL-safe comparisons via `IS DISTINCT FROM` (value guard of the MERGE AND drift comparison of the sync) | QG R2 Deep 2026-07-21 (FT-5/FT-6/SEC-3-3a), §3.3 |
| D31 | Sync comparison in canonical normal form: closed comparison surface (job/step/schedule), registry→msdb conversion before the comparison, schedule mandatory values (`freq_recurrence_factor=1` weekly, `freq_interval=1` daily, `active_start_time` HHMMSS), `sp_delete_job … @delete_unused_schedule=1`; running guard scoped to the current Agent session (`MAX(session_id)` from `syssessions`) | QG R2 Deep 2026-07-21 (FT-7/FT-8/CA-4), §3.2 |
| D32 | Watchdog hardening: age comparisons in **local server time** (`SYSDATETIME()` — `backupset` stores local, a UTC grab would widen the 1-h threshold to ~3 h) + **target validation** (`TRIM`, `THROW 51100` on a token without an ONLINE match — an alarm instead of a silent skip) | QG R2 Deep 2026-07-21 (FT-4/FT-9), §3.2/AC5 |
| D33 | DDL invariants sharpened: `bUpdateStatistics IS NOT NULL` in the IndexOptimize CHECK branch + a defined mapping (1→`'ALL'`, 0→parameter omitted); `CK_tMaintenanceJob_cDisplayName` enforces the job prefix (no ghost job outside the prefix window) | QG R2 Deep 2026-07-21 (FT-10/FT-12/SEC-3-1/SEC-3-5), §3.1 |
| D34 | `bEnabled` maps onto job `@enabled` (a job exists for every registry row, pause = disable); the instance switch `ops.tConfig('MaintenanceSchedulesEnabled')` (test1 `'0'`, prod without an entry = enabled) enforces D-A6 instead of asserting it (the test1 Agent must run for resets); the operator email stays hard-coded (policy vs. instance state); the time-window rule stays the primary cutover safeguard, the switch only an emergency lever | QG R2 Deep 2026-07-21 (FT-11/FI-4/FI-5/SEC-3-3b), §3.2/§3.3/§3.5/§3.6 |
| D35 | `cFrequency` extended by `'hourly'` (mapping `freq_type=4` + `freq_subday_type=8`/`freq_subday_interval=1`; subday columns in the D31 comparison surface); `backup-watchdog` runs hourly (anchor 00:00) instead of daily 08:00 — log-chain detection latency ≤ ~2 h instead of up to 24 h; decided NOW because `up/0023` is immutable after the apply | QG R2 Deep 2026-07-22 (FI-3), §3.1/§3.2/AC5 |
| D36 | Maintenance liveness check `maint.spCheckMaintenanceLiveness` (fifth proc, parameterless, THROW `51105`) as the second EXEC in the watchdog step: for each effectively enabled Ola row it derives the permissible CommandLog age from the schedule (daily → 26 h, weekly → 8 d) — covers the "never runs" path (F3/F4) that `bNotifyOnFail` does not see; remaining blind spot "Agent service down" documented as an ADR-A failure mode and assigned to Gap 2 | QG R2 Deep 2026-07-22 (FI-1), §3.2/AC13 |
| D37 | CBB coverage of the system DBs (`msdb`, `master`) is a cutover check step (B6 no. 3): the chain is proven only for `eazybusiness` (F1), while the plan makes `msdb` valuable and removes the old SYSTEM_DATABASES backup jobs; if secured → `msdb` into the watchdog row, otherwise a decision for Lukas (§5 Gap 6) | QG R2 Deep 2026-07-22 (FI-2), §3.6 |
| D38 | The Agent job-history limit is raised in the cutover (`sp_set_sqlagent_properties @jobhistory_max_rows=10000/@…_per_job=1000`, admin-owned instance state) — otherwise `sysjobhistory` rolls over far before the declared 365-d retention | QG R2 Deep 2026-07-22 (FI-6), §3.6 no. 5 |
| D39 | The old `eazybusiness.dbo.CommandLog` (9,218 rows, 2024→2025-11-27) is archived to `RoboticoOps.dbo.CommandLog_legacy_eazybusiness` before the drop — forensics of the failure history is preserved | QG R2 Deep 2026-07-22 (FI-7), §3.6 no. 1 |
| D40 | Foreign prod DBs (`ersatzteile_prod*`, `EKL*`, `HbDat001`) stay in the dynamic maintenance scope (CHECKDB + IndexOptimize) — small (~1 GB), cost trivial, corruption detection on the instance wanted; no exclusion expressions. Watchdog inclusion (Gap 1a) stays a separate follow-up task | Lukas 2026-07-22, §5 Gap 1 |
| D41 | `msdb` into the `backup-watchdog` row: CBB coverage of the system DBs verified read-only (full 03:00 `copy_only=0` for `msdb`/`master`/`model`, as of 2026-07-22) — Gap 6 closed via the D37 fallback; B6 no. 3 becomes a re-verification | Verification vm-sql2 2026-07-22, §3.2/§5 Gap 6 |

## Iteration Log

### 2026-07-21 — Quality-gate incorporation (consolidator)

All 29 consolidated QG findings (2 Critical, 13 Important, 14 Nice-to-have; from 53 raw findings by 7 review agents) incorporated. Core:

- **Critical SEC-4-1:** cutover order flipped — old-install removal **before** the deploy (B6 step 1), step 5 reworded to pure verification (D16).
- **Critical SEC-3-1 (+ SA-4/SEC-4-4):** the grate stage-order operator↔sync resolved via `260_maintenance_operator.sql` with a conditional Ensure re-trigger + operator-EXISTS guard in the sync — simultaneously covers the everytime self-heal (D17).
- Repo contracts anchored: `validate_structure.sql` (lint (l)), THROW `51100`/`51110` (lint (k), D21), lint pre-check of the Ola vendor files (SA-9) — as [EDIT] deliverables in §4 + a new AC11.
- Row-count drift 6/7/8 cleaned up (§3.2 table = SSoT; D12/§3.5 corrected), AC1 file reference corrected, AC3 replaced by the command matrix, new ACs 10/11, AC7 mechanics fixed (D18), B5 checklist reworked (watchdog logic test instead of a green run), B4 scope refined (incl. NAMING-CONVENTIONS, D20), `ops_admin` narrowed to SELECT (D19), gaps added/sharpened (active maintenance scope on foreign DBs), references completed. New decisions: D16–D22; ADRs updated with one Decision-History entry each.

### 2026-07-21 — Quality-gate round 2 (deep) — consolidator incorporation

21 of the 43 consolidated R2 findings (incorporation owner "consolidator path"; from 59 raw findings by 9 agents, 0 Critical) incorporated — the 22 special-agent findings (FT-*/FI-*) follow in their own rounds by their authors. Core:

- **Rollout gate (SA-1/D23):** `validate_rollout.sql` is extended by the maintenance-operability block — new AC12 + [EDIT] in §4.
- **tm-clone seam (SA-2/D24):** the IndexOptimize↔reset collision over the clones explicitly decided (reset wins via `SINGLE_USER WITH ROLLBACK IMMEDIATE`; accepted + documented as an ADR-A failure mode).
- **Architecture docs (SA-3+SEC-6-2/D25):** `MSSQL-OPS-ARCHITECTURE.md` anchored as the 7th [EDIT] (three schemas, inventory, 2 new §6 standing rules).
- **Cutover refinement (SEC-6-1+SA-5, SEC-6-4, SEC-6-5, SEC-6-3, SEC-6-6, SEC-6-7, SEC-6-8 / D26):** B6 is woven into Phase 4 (Phase 4a + follow-up) instead of appended; time-window rule; Gap-5.1 precondition; the CBB step as a reference instead of a duplicate; the abort-after-step-1 case in the rollback; alarm-path acceptance via the natural stale alarm; Agent-restart guard.
- **Watchdog edges (SEC-3-6, SEC-1-3 / D27):** log check `<> SIMPLE` instead of "only FULL"; threshold operator `>=` nailed down.
- **AC/prose consistency (SEC-1-1, SEC-1-2, SEC-1-4):** the §1.2 corruption promise walked back to the ADR wording ("within a few days"); the second §2 NOTE as an acceptance anchor for the old-install removal; "5 jobs" in AC9/§3.5 replaced by an SSoT-relative wording.
- **Coherence/references (SA-4, CA-2, SEC-5-2, ADR-1/2/3):** the 260er operator hard-coding documented as a deliberate deviation; the `cDatabases` double grammar recorded as a deliberate trade-off in §3.1; the Gap-2 runbook note as a deliverable in §3.6; naming + grate ADR linked in §6, promotion tasks (naming-ADR back-reference, CLAUDE.md subsystems table) noted.

Seams to the special-agent rounds are worded neutrally in the plan ("provided the further QG incorporation … introduces/refines"): bEnabled/instance-switch semantics, the Fix-A resolution, watchdog token validation and time base stay with their authors. New decisions: D23–D27.

### 2026-07-21 — Quality-gate round 2 (deep) — Fable-Tech incorporation

All 16 Fable-Tech findings (FT-1..FT-16; 11 Important, 5 Nice-to-have) incorporated; the seams left open by the consolidator (AC12 conditioning, §3.6 CAUTION alternative, §3.3 operator catch-up, CA-2 runtime validation) resolved. Core:

- **FT-1 decided — runtime dispatch (D28), CA-1 adopted, re-scope actively rejected:** the job steps become constant (`EXEC maint.spRunMaintenanceJob @cJobKey = …`), a fourth `maint.*` proc carries the command matrix as a runtime `CASE` and passes registry values as real T-SQL parameters — Fix A holds literally, and the pattern follows the reset precedent (a constant parameterless step). Also resolves FT-3 (frozen date) structurally and removes the step-text facet from FT-7; AC3/AC10/AC11, command matrix, §4 (7th migration file, `51120`) reworked.
- **Sync lifecycle closed:** unconditional `260` Ensure call (FT-2/D29), MERGE delete branch + `IS DISTINCT FROM` (FT-5/FT-6/D30), canonical comparison normal form + schedule mandatory values + `@delete_unused_schedule` (FT-7/D31), session-scoped `sysjobactivity` guard (FT-8/D31).
- **Watchdog hardened (D32):** local time base (`SYSDATETIME()` instead of `SYSUTCDATETIME()` — the 1-h threshold would otherwise be ~3 h in reality) and target validation (TRIM + `THROW 51100` on an unknown/non-ONLINE target) — simultaneously resolves the CA-2 NOTE seam in §3.1.
- **DDL invariants (D33):** `bUpdateStatistics IS NOT NULL` (IndexOptimize branch, F8 regression guard) + a defined 1/0 mapping in the dispatcher (FT-10); `cDisplayName` prefix CHECK (FT-12).
- **test1/enabled semantics (D34, FT-11):** `bEnabled` → job `@enabled`; a new instance switch `ops.tConfig('MaintenanceSchedulesEnabled')` (test1 `'0'`) replaces "Agent Stopped" as the gate (the Agent must run for resets); AC9/AC12/§3.5/§3.6 reworked. Seams finally decided: the operator email stays hard-coded (§3.3 no. 1); the time-window rule stays the primary cutover safeguard, the switch only a documented emergency lever (§3.6 CAUTION); AC12 assertions conditioned on the D34 equation.
- **Nice-to-have:** Ola `CommandLog.sql` idempotency wrapper as a documented deviation (FT-13, §3.1); README (k) guidance sentence carried over — maint reserves `51100–51129`, reset from `51130` (FT-14); B5 test path `BACKUP … TO DISK='NUL'` (FT-15); `sysmail_profile` existence guard in `260` (FT-16).

Not touched (owner Fable-Intent): the ADR-A "becomes impossible" sentence (FI-1), the system-DB watched set (FI-2), watchdog cadence/`cFrequency='hourly'` (FI-3), FI-6/7/8. Seams to there: the `cFrequency` CHECK/`CK_Schedule` rows in §3.1 and the D31 schedule-mapping table are worded so that an `'hourly'` extension (FI-3) stays additively possible (new CHECK value + mapping row `freq_subday_type`); the B5 checklist leaves room for the FI-8 sync-path tests. New decisions: D28–D34.

### 2026-07-22 — Quality-gate round 2 (deep) — Fable-Intent incorporation

The 6 remaining Fable-Intent findings (FI-1/FI-2/FI-3 Important, FI-6/FI-7/FI-8 Nice-to-have; FI-4/FI-5 had already been absorbed into FT-11/D34) incorporated — additive on top of the D28–D34 constructs, no rebuild:

- **FI-3 decided — `'hourly'` (D35), variant (b):** `cFrequency` extended by `'hourly'` (CHECK + `CK_Schedule` + mapping row `freq_subday_type=8`; subday columns additively taken into the D31 comparison surface — exactly the prepared extension path); `backup-watchdog` hourly (anchor 00:00). Rationale: the watchdog is the only detector of the chain, "log < 1 h" with a daily sample would have been an up-to-24-h guarantee in reality, and after the apply of `up/0023` the schema extension would be a new `up/`. Follow-up changes: AC5 cadence, §3.6 no. 3/6 (hourly stale mail = faster alarm-path acceptance; note on possible 03:00-window false alarms with `nLogMaxHours` adjustment).
- **FI-1 — liveness check (D36):** a fifth proc `maint.spCheckMaintenanceLiveness` (parameterless, `THROW 51105`, second EXEC in the watchdog step) checks self-configuring from the registry whether CHECKDB/IndexOptimize actually ran per CommandLog — closes the "never runs" path (F3/F4) that `bNotifyOnFail` structurally does not see. New AC13, B5 logic test, THROW/validate_structure/§4 catch-ups (8 migration files, 5 procs); ADR-A: "becomes impossible" refined + a new failure mode "Agent service stopped" (→ Gap 2).
- **FI-2 — system-DB backups (D37):** B6 no. 3 verifies the CBB coverage of `msdb`/`master` (F1 proves only `eazybusiness`; step 1 removes the old SYSTEM_DATABASES jobs without replacement); result paths: `msdb` into the watchdog row OR a new §5 Gap 6 (owner Lukas).
- **FI-6 (D38):** raising the Agent-history limit as a B6 no. 5 check point (default 1,000 rows undercuts the 365-d retention). **FI-7 (D39):** CommandLog archiving before the drop (B6 no. 1). **FI-8:** B5 checklist extended by the two untested sync core paths (drift correction = "1 change", prefix-dummy removal).

New decisions: D35–D39; both ADRs updated with one Decision-History entry each.

### 2026-07-22 — Gap closure (Lukas + live verification)

The two points still open after the QG round-2 incorporation closed:

- **Gap 5.1 / Gap 1b decided (Lukas, D40):** foreign prod DBs stay in the dynamic maintenance scope — no exclusion expressions; the cutover precondition in §3.6 is met. Gap 1a (watchdog inclusion of the foreign DBs) stays open as a follow-up task, now with a data basis: `ersatzteile_prod` + `HbDat001` hang in the real CBB chain, `EKL`/`ersatzteile_prod_latest` do not.
- **Gap 6 closed (live verification vm-sql2, read-only, D41):** `msdb`/`master`/`model` are in the real CBB chain (full 03:00 `copy_only=0`, as of 2026-07-22) → `msdb` taken into the `backup-watchdog` registry row via the D37 fallback (§3.2); B6 no. 3 becomes a re-verification on the cutover day. The ADR-B watched set updated accordingly.

## 5. Information Gaps

1. **Foreign DBs in watchdog AND active maintenance — (b) DECIDED (Lukas, 2026-07-22, D40):** the foreign DBs (`ersatzteile_prod*`, `EKL*`, `HbDat001`) **stay in the dynamic maintenance scope** (CHECKDB + IndexOptimize): all small (~1 GB, CHECKDB cost trivial), corruption on the same instance should be detected instead of ignored, and the scope thereby deliberately captures every future new DB too (ADR-A failure mode "dynamic scope" stays as documentation of the behavior). No exclusion expressions needed. — (a) watchdog inclusion of the foreign DBs stays open: `ersatzteile_prod` + `HbDat001` demonstrably hang in the real CBB chain (full 03:00 `copy_only=0` + logs, verified 2026-07-22), `EKL`/`ersatzteile_prod_latest` however do not (only copy_only 18:00) — inclusion only after clarified backup ownership. *Owner (a):* Lukas, follow-up task. *Fallback (a):* the watched set stays `eazybusiness,RoboticoOps,msdb` (§3.2 = SSoT).
2. **Database Mail health** — who watches the watcher? If Database Mail fails, maintenance and watchdog alarms fall silent together. *Owner:* Lukas — follow-up task in the overarching mssql-ops program. *Fallback:* unmonitored for now, noted in the runbook.
3. **RoboticoOps prod-cutover timing** — the maintenance prod rollout depends on it (RoboticoOps does not yet exist on vm-sql2). *Owner:* overarching mssql-ops program. *Fallback:* none — a hard precondition.
4. **Ola version to pin** — at implementation choose the current stable version and record it in the vendor-script header. *Owner:* implementation B1. *Fallback:* the current stable release version (no blocker).
5. **Nightly-window runtime** — whether CHECKDB (Sun/Wed 01:00, all DBs except tm ≈ 35 GB) + IndexOptimize (02:00) really finish before the 03:00 full is an assumption, not a measurement; the staggering is only asserted by start time. *Owner:* test1 validation (B5) + first prod nightly run (B6 no. 6). *Fallback:* adjust the times in the registry (repo-owned, one deploy).
6. **CBB coverage of the system DBs (`msdb`, `master`) — CLOSED (verified 2026-07-22, D41):** a read-only query against `msdb.dbo.backupset` on vm-sql2 proves: `msdb`, `master` (and `model`) are in the **real** CBB chain — daily full 03:00 with `is_copy_only=0` (most recent: 2026-07-22 03:00:30). Consequence implemented via the D37 fallback: `msdb` is taken into the `backup-watchdog` row (§3.2; the log check skips it as SIMPLE per D27). B6 no. 3 keeps the query as a cutover re-verification (the CBB configuration may change by then).

## 6. References

- **ADRs:** [adr-maintenance-as-code-roboticoops](../../decisions/0001-maintenance-as-code-roboticoops.md), [adr-backups-cbb-retained](../../decisions/0002-backups-cbb-retained.md) (promoted → `docs/decisions/`)
- **Research:** [6-wartung-ist-analyse](../2026-07-10 - mssql-ops-infrastruktur/research/6-wartung-ist-analyse/6-wartung-ist-analyse.md)
- **Pattern model:** `db-migrations/global/runAfterOtherAnyTimeScripts/reset.spEnsureAgentJob.sql` + `permissions/200_ensure_agent_job.sql` (sa-owned job ensure + everytime self-heal), [adr-reset-step-registry](../2026-07-10 - mssql-ops-infrastruktur/adrs/adr-reset-step-registry.md) (registry pattern), [adr-module-signing-reset](../2026-07-10 - mssql-ops-infrastruktur/adrs/adr-module-signing-reset.md) (sa-owned Agent-job pattern, rationale of D3), [adr-two-chain-migration-paths](../2026-07-10 - mssql-ops-infrastruktur/adrs/adr-two-chain-migration-paths.md) (Ebene-B placement + hand-idempotent `up/` rule), [adr-ebene-b-hungarian-naming](../2026-07-10 - mssql-ops-infrastruktur/adrs/adr-ebene-b-hungarian-naming.md) (naming convention adopted; `t`=time is a documented micro-extension, D20), [adr-grate-migration-runner](../2026-07-10 - mssql-ops-infrastruktur/adrs/adr-grate-migration-runner.md) (stage/folder-order guarantee on which the `260` first-deploy convergence relies, D17)
- **Promotion tasks (on ADR promotion of this plan) — done 2026-07-23:** (a) back-reference/Decision-History note on `adr-ebene-b-hungarian-naming` about the `t`=time micro-extension (makes the link bidirectional; the ADR's enumeration stays silently incomplete otherwise) — ✅; (b) "Subsystems" table added to `CLAUDE.md` (`RoboticoOps`, `Testmandant Reset`, `JTL SQL Migrations`), so the `Subsystem:` headers of the ADR cohort are canonically anchored — ✅. The two maintenance ADRs are promoted to `docs/decisions/0001`/`0002`; the four older mssql-ops ADRs stay plan-scoped (their plan is still active).
- **Overarching program:** [mssql-ops-infrastruktur](../2026-07-10 - mssql-ops-infrastruktur/mssql-ops-infrastruktur.md)
- **Data-model contract:** `docs/SQL/MSSQL-OPS-DATA-MODEL.md`; CLAUDE.md §"Database Object Documentation"
- **External:** [Ola Hallengren Maintenance Solution](https://ola.hallengren.com/)
