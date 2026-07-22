# RoboticoOps Data Model — `ops.*` tables

Column-level reference for the five registry tables of the RoboticoOps
infrastructure (Ebene B, database `RoboticoOps`): four tables of the
test-mandant reset plus the maintenance-job registry of the SQL-Server
maintenance suite.

> [!IMPORTANT]
> **Maintenance contract:** every edit to the table DDL in
> `db-migrations/global/up/0002_ops_schema_tables.sql`,
> `db-migrations/global/up/0021_reset_step_registry.sql` or
> `db-migrations/global/up/0023_maintenance_registry.sql` (or any future `up/`
> script that alters an `ops.*` table) MUST update this document in the same
> commit. This rule is anchored in the repository `CLAUDE.md`.

The DDL files are authoritative for types/constraints; this document is
authoritative for the *meaning* of each column. Architecture context:
[`MSSQL-OPS-ARCHITECTURE.md`](MSSQL-OPS-ARCHITECTURE.md).

---

## `ops.tMandant` — test-mandant registry

One row per test mandant (which clone belongs to whom). Defined in `up/0002`.

| Column | Type | Meaning |
|---|---|---|
| `cMandantKey` | `sysname`, PK-like (UNIQUE, NOT NULL) | Business key (e.g. `tm2`, `tm9`). Consumers address the mandant by this key in `reset.spPub_StartTestmandantReset` / `spPub_GetResetStatus`. |
| `cTargetDb` | `sysname`, NOT NULL | Name of the clone database (`eazybusiness_<key>`). Guarded three ways against ever pointing at production: table CHECK `CK_tMandant_cTargetDb`, `spPub_CreateTestmandant` validation (THROW 51092), orchestrator re-validation. |
| `cDisplayName` | `nvarchar(255)`, NOT NULL | Human-readable name, shown by `spPub_ListMandants`. |
| `cDeveloper` | `nvarchar(255)`, NULL | Informational: who owns/uses this mandant. |
| `cLoginName` | `sysname`, NULL | SQL/AD login that `spInternal_GrantAccess` maps to `db_owner` inside the clone after each reset. If the login does not exist on the instance, the grant step logs a skip. |
| `cShopUrl` | `nvarchar(500)`, NULL | Staging shop URL used by `spInternal_InvalidateCredentials` to repoint the JTL shop connection (`LIKE 'http%'`-guarded, no-op when the source has no live shop). Never returned by `spPub_ListMandants` (no column DENY — not a secret, just withheld from the list SP). |
| `cShopLicense` | `nvarchar(500)`, NULL | Shop licence key applied during credential invalidation. Secret: explicit column-level `DENY SELECT` for `ops_reset_executor` (`up/0003_roles`); never returned by `spPub_ListMandants`. |
| `bActive` | `bit`, NOT NULL, default `1` | Soft-disable: an inactive mandant is refused for new resets without deleting its row/history. |
| `dCreated` | `datetime2(0)`, NOT NULL, default `SYSUTCDATETIME()` | Audit: row creation (UTC). |
| `dModified` | `datetime2(0)`, NOT NULL, default `SYSUTCDATETIME()` | Audit: last change (UTC). |

Write access: `ops_admin` only (`up/0003_roles`). `ops_reset_executor` has no
write access; secrets columns carry an explicit column DENY.

---

## `ops.tConfig` — instance key/value configuration

Replaces the hard-coded paths of the legacy `Projekte/Testsystem` scripts.
Defined in `up/0002`, seeded in `up/0020`.

| Column | Type | Meaning |
|---|---|---|
| `cKey` | `sysname`, PK-like (UNIQUE, NOT NULL) | Configuration key. Seeded keys: `BackupFile` (COPY_ONLY backup target path), `TargetDataDir` (clone data-file directory), `SourceDb` (clone source, normally `eazybusiness`), `ReferenceMandant` (kMandant used as registration template), `StaleRunningHours` (reclaim threshold for orphaned `running` requests), `AgentJobName` (SQL Agent job to start), `NotifyOperator` (optional msdb operator for failure notification). |
| `cValue` | `nvarchar(1000)`, NULL | The value. Environment-specific values (e.g. drive paths) are adjusted per instance after the first deploy — see runbook `rollout-mssql-ops.md`. |
| `cNotes` | `nvarchar(500)`, NULL | Free-text explanation of the key. |

---

## `ops.tResetRequest` — request queue + run log

State machine and audit trail for every reset run. Defined in `up/0002`.

| Column | Type | Meaning |
|---|---|---|
| `kResetRequest` | `int IDENTITY`, PK | Request id, returned to the caller by `spPub_StartTestmandantReset`. |
| `cMandantKey` | `sysname`, NOT NULL | Mandant the reset runs for (snapshot at request time). |
| `cTargetDb` | `sysname`, NOT NULL | Clone DB at request time. Filtered unique index `IX_tResetRequest_Active` enforces **at most one active (`queued`/`running`) request per target DB** — declarative belt-and-braces on top of the SP applock. |
| `cStatus` | `nvarchar(20)`, NOT NULL | State machine: `queued → running → succeeded \| failed` (CHECK-constrained — there is no separate `cancelled` state: `spPub_CancelResetRequest` moves a request to `failed` with a `cancelled by …` note in `cErrorMessage`). |
| `cRequestedBy` | `sysname`, NOT NULL | `ORIGINAL_LOGIN()` of the requester (audit). |
| `dRequested` | `datetime2(0)`, NOT NULL, default UTC now | When the request was queued. |
| `dStarted` | `datetime2(0)`, NULL | When the orchestrator claimed it (`running`). |
| `dFinished` | `datetime2(0)`, NULL | When it reached a terminal state. |
| `cErrorMessage` | `nvarchar(max)`, NULL | Error text when `failed`. |
| `cStepLog` | `nvarchar(max)`, NULL | Line-per-event pipeline protocol (`starting step N: …`), appended by `reset.spInternal_LogStep`; surfaced by `spPub_GetResetStatus`. |
| `dModified` | `datetime2(0)`, NOT NULL, default UTC now | Last touch of the row (audit). Note: the stale-reclaim check (`StaleRunningHours`) compares against `dStarted`, not `dModified`. |

---

## `ops.tResetStep` — data-driven pipeline registry (EXT-1)

Ordered list of `reset.spInternal_*` steps that `reset.spProcessNextResetRequest`
executes. Adding a preparation step = deploy a new `spInternal_*` proc + one row
here; the orchestrator is never edited. Defined and seeded in `up/0021`.
Security model: `adrs/adr-reset-step-registry.md` (plan-scoped).

| Column | Type | Meaning |
|---|---|---|
| `kResetStep` | `int IDENTITY`, PK | Row id. |
| `nStepOrder` | `int`, NOT NULL, UNIQUE | Execution order (seeded 10…80, gaps left for insertions). |
| `cProcName` | `sysname`, NOT NULL, UNIQUE | Proc **name** only (schema is always `reset`). CHECK `CK_tResetStep_cProcName` enforces the `spInternal_%` prefix; the orchestrator additionally whitelists the name against `sys.procedures` before `EXEC` via `QUOTENAME` — only versioned-deployed procs can ever run. |
| `bEnabled` | `bit`, NOT NULL, default `1` | Toggle a step off without deleting it. |
| `bCritical` | `bit`, NOT NULL, default `1` | `1`: step failure aborts the run, clone is quarantined `failed`. `0`: failure is logged as WARN and the pipeline continues. |
| `cNotes` | `nvarchar(400)`, NULL | Short description of the step (seeded). |

Seeded default pipeline (order → proc): 10 `spInternal_CloneDatabase`,
20 `spInternal_PostRestoreSecurity`, 30 `spInternal_InvalidateCredentials`,
40 `spInternal_NeutralizeWorker`, 50 `spInternal_AnonymizeCustomerData`,
60 `spInternal_GrantAccess`, 70 `spInternal_RegisterMandant`,
80 `spInternal_ApplyJtlRoles`.

---

## `ops.tMaintenanceJob` — declarative maintenance-job registry

One row = one SQL-Agent maintenance job. `maint.spEnsureMaintenanceJobs`
synchronizes msdb from this table (create / converge / remove by the
`RoboticoOps - Maint - ` name prefix); `maint.spRunMaintenanceJob` reads the row
at run time and dispatches to the vendored Ola Hallengren procedures (D28 —
job steps are constant, values travel as real proc parameters). Defined in
`up/0023`; **rows are reconciled by the value-guarded MERGE in
`runAfterOtherAnyTimeScripts/maint.spApplyMaintenance.sql`**, not seeded in `up/`.

> [!IMPORTANT]
> This registry is **repo-owned** (deliberate deviation from `ops.tResetStep`):
> the MERGE enforces all desired columns on every deploy — live edits are
> overwritten. Maintenance tuning goes exclusively through git + deploy.
> `ops_admin` therefore has SELECT only.

| Column | Type | Meaning |
|---|---|---|
| `cJobKey` | `sysname`, PK | Stable key (`checkdb`, `index-optimize`, `cleanup-commandlog`, `cleanup-backuphistory`, `cleanup-jobhistory`, `backup-watchdog`). The constant job step passes exactly this key to `maint.spRunMaintenanceJob`. |
| `cDisplayName` | `nvarchar(128)`, NOT NULL, UNIQUE | Agent job name. CHECK-enforced prefix `RoboticoOps - Maint - ` — create **and** remove hang on this prefix window (a prefix-less row would create a ghost job outside the managed window). |
| `cOperation` | `nvarchar(20)`, NOT NULL | `IntegrityCheck` \| `IndexOptimize` \| `Cleanup` \| `BackupWatchdog` (CHECK). A **new operation kind** is deliberately not "just a row": new CHECK value + knob columns (new `up/`), new CASE branch in `spRunMaintenanceJob`, doc rows here. |
| `cDatabases` | `nvarchar(400)`, NOT NULL | **Two grammars, decided by `cOperation`** (the one column whose grammar is enforced by doc, not CHECK): an **Ola `@Databases` expression** (`IntegrityCheck`/`IndexOptimize`/`Cleanup`, e.g. `ALL_DATABASES, -eazybusiness_tm%`) or a **literal comma list** (`BackupWatchdog` — Ola tokens are invalid there; the watchdog TRIMs each token and THROWs 51100 on any non-ONLINE match, D32). Values reach Ola at run time as real proc parameters, never as step-text literals (D28). |
| `cFrequency` | `nvarchar(10)`, NOT NULL | `daily` \| `weekly` \| `hourly` (CHECK). Typed schedule instead of a cron string; the sync maps 1:1 onto `msdb.dbo.sysschedules` (D31 mapping table in `spEnsureMaintenanceJobs`). `hourly` = every hour from the `tStartTime` anchor (D35). |
| `nWeekdayMask` | `tinyint`, NULL | `weekly` only (CHECK `CK_…_Schedule`): bitmask 1=Sun … 64=Sat, OR-able (Sun+Wed = 9); identical to `sysschedules.freq_interval`. |
| `tStartTime` | `time(0)`, NOT NULL | **Local server time**; for `hourly` the day anchor of the first run (watchdog: 00:00 → around the clock). `t` prefix = `time` column (micro-convention, see NAMING-CONVENTIONS §9). |
| `bUpdateStatistics` | `bit`, NULL | `IndexOptimize` only, and **mandatory there** (D33 — NULL would mean "sync decides", which reproduced F8): `1` → `@UpdateStatistics='ALL'`, `0` → parameter omitted (deliberate exception). Liveness (D36) depends on this: `1` guarantees a per-run `UPDATE_STATISTICS` `CommandLog` heartbeat, so `spCheckMaintenanceLiveness` can see the run; `0` removes that heartbeat (and reintroduces F8) — a stats-off `IndexOptimize` row is a liveness blind edge, revisit `spCheckMaintenanceLiveness` before adding one (L-B1-3). |
| `cCleanupTarget` | `nvarchar(20)`, NULL | `Cleanup` only (mandatory there): `CommandLog` \| `BackupHistory` \| `JobHistory` (CHECK). |
| `nRetentionDays` | `int`, NULL, > 0 | `Cleanup` only (mandatory there): retention in days. Cutoff is computed **at run time** by the dispatcher. |
| `nFullMaxHours` | `int`, NULL, > 0 | `BackupWatchdog` only (mandatory there): max age of the newest non-copy-only FULL backup. |
| `nLogMaxHours` | `int`, NULL, > 0 | `BackupWatchdog` only (mandatory there): max age of the newest LOG backup (checked for `recovery_model_desc <> 'SIMPLE'`, D27). |
| `bEnabled` | `bit`, NOT NULL, default `1` | Effective job-enabled state = `bEnabled = 1` AND `ops.tConfig('MaintenanceSchedulesEnabled') <> '0'` (D34). Pausing = disabling, never deleting. |
| `bNotifyOnFail` | `bit`, NOT NULL, default `1` | `1` → the job is wired to email operator `RoboticoOps-Maint` on failure (guarded: only when the operator exists in msdb; `permissions/260` converges the first deploy). |
| `cNotes` | `nvarchar(400)`, NULL | Short description; becomes the agent job description. |
| `dCreated` | `datetime2(0)`, NOT NULL, default UTC now | Audit: row creation (UTC). |
| `dModified` | `datetime2(0)`, NOT NULL, default UTC now | Audit: last real change (UTC) — the value-guarded MERGE leaves it untouched on no-op deploys (AC7 audit signal). Also load-bearing: `spCheckMaintenanceLiveness` uses it as the first-run grace anchor (a row enabled less than one schedule window ago is not yet expected to have run, L-B1-2), so the MERGE must keep bumping it on the `bEnabled 0→1` flip. |

The CHECK `CK_tMaintenanceJob_OperationKnobs` makes the registry
self-validating: every operation must carry its mandatory knobs and leave
foreign knobs NULL.

---

## References

- DDL: `db-migrations/global/up/0002_ops_schema_tables.sql`, `db-migrations/global/up/0021_reset_step_registry.sql`, `db-migrations/global/up/0023_maintenance_registry.sql`
- Maintenance-row reconcile: `db-migrations/global/runAfterOtherAnyTimeScripts/maint.spApplyMaintenance.sql`
- Roles/grants: `db-migrations/global/up/0003_roles.sql`, `db-migrations/global/permissions/100_grants.sql`
- Architecture: [`MSSQL-OPS-ARCHITECTURE.md`](MSSQL-OPS-ARCHITECTURE.md)
- Naming convention (Hungarian, EKL): `docs/plans/2026-07-10 - mssql-ops-infrastruktur/adrs/adr-ebene-b-hungarian-naming.md`
- Clone-guard audit: `docs/plans/2026-07-10 - mssql-ops-infrastruktur/reports/clone-guard-audit.md`
