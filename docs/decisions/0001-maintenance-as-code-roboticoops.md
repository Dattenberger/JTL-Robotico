# ADR-0001: SQL-Server maintenance as code — Ola Hallengren vendored in RoboticoOps, driven by a declarative job registry

**Status:** Accepted
**Subsystem:** RoboticoOps, JTL SQL Migrations, Testmandant Reset
**Date:** 2026-07-21
**Supersedes:** —
**Author:** Lukas + Claude Code

> **Cooperates with [adr-reset-step-registry](../plans/2026-07-10 - mssql-ops-infrastruktur/adrs/adr-reset-step-registry.md) and [adr-module-signing-reset](../plans/2026-07-10 - mssql-ops-infrastruktur/adrs/adr-module-signing-reset.md).** The reset-step registry owns the "declarative table drives an idempotent ensure-proc" pattern; this ADR reuses it for maintenance jobs. The module-signing ADR owns the Agent-job creation pattern (`reset.spEnsureAgentJob`, sa-owned); `maint.spEnsureMaintenanceJobs` mirrors it.

## Research

- **[6-wartung-ist-analyse](../plans/2026-07-10 - mssql-ops-infrastruktur/research/6-wartung-ist-analyse/6-wartung-ist-analyse.md) §2, F1–F9** — live read-only survey of `vm-sql2` (2026-07-21): the only scheduled maintenance job (`IndexOptimize`) **fails every night** (`Fehler 2812: dbo.IndexOptimize not found`, F2); `DatabaseIntegrityCheck`/CHECKDB last ran **2024-06-24** (F3); the Ola objects live in `eazybusiness.dbo` (F5) and were partially wiped ~2025-11-27 — the direct cause of F2; no failure alerting exists, so the daily failure went unnoticed for ~8 months (F6).
- **[6-wartung-ist-analyse §3.2](../plans/2026-07-10 - mssql-ops-infrastruktur/research/6-wartung-ist-analyse/6-wartung-ist-analyse.md)** — measured fragmentation of `eazybusiness` (22.8 GB): **0 indexes >30 %** after 8 months without maintenance (F7) → index defrag is low-ROI; CHECKDB + statistics are the real lever. The old job never updated statistics (F8, no `@UpdateStatistics`).
- **[adr-reset-step-registry](../plans/2026-07-10 - mssql-ops-infrastruktur/adrs/adr-reset-step-registry.md)** — the precedent for a declarative `ops.*` registry table materialised by an idempotent sproc; adopted here as `ops.tMaintenanceJob` + `maint.spEnsureMaintenanceJobs`.
- **Live instance facts (2026-07-21):** Database Mail is enabled (profile `Standard SMTP` via brevo), but **no operator exists** and the **SQL-Agent has no mail profile assigned** — the alerting plumbing is present but the last three wires are missing.

## Context

vm-sql2 has *no effective SQL maintenance* despite 11 installed Ola jobs. The three root failures are structural, not incidental:

1. **Wrong location** — maintenance objects sit in the JTL vendor DB (`eazybusiness.dbo`) and are destroyed by vendor refreshes/restores (which is what broke `IndexOptimize`).
2. **Unversioned click-ops** — the jobs were hand-created in SSMS; they are not in the repo and cannot be reproduced on a fresh instance.
3. **No alerting** — a nightly failure was silent for ~8 months.

The RoboticoOps infrastructure (Ebene B / global grate chain, `ops.*` registry pattern, sa-owned Agent jobs, Database Mail) already solves exactly these three problems for the reset mechanic. Maintenance should reuse that infrastructure rather than re-invent click-ops. A further requirement from the design session: the operator must be able to **read the entire maintenance landscape (which operation runs on which databases, on what schedule) from one place**.

## Decision

Maintenance is deployed **as code in RoboticoOps** and defined by a **declarative registry table** that an idempotent ensure-proc materialises into SQL-Agent jobs.

### D-A1 — Location & layering

- **Ola Hallengren procedures + `CommandLog`** are vendored into `RoboticoOps.dbo` as a **pinned version** via a one-time `db-migrations/global/up/` script (immutable-once-applied fits a frozen third-party version; an upgrade is a new numbered `up/` script). RoboticoOps survives every mandant restore, so this can never be wiped the way `eazybusiness.dbo` was.
- **Our own objects** live in a new **`maint` schema**: the registry table is `ops.tMaintenanceJob` (registries live in `ops.*`, consistent with `ops.tResetStep`), the procs are `maint.spEnsureMaintenanceJobs`, `maint.spRunMaintenanceJob` (runtime dispatcher, see D-A3), `maint.spCheckBackupChain` and `maint.spCheckMaintenanceLiveness` (liveness guard, see D-A5). Ola (third-party, `dbo`) and our tooling (`maint.*` / `ops.*`) stay visibly separate.

### D-A2 — Declarative registry as single source of truth

`ops.tMaintenanceJob` holds one row per job:

| Column | Purpose |
|---|---|
| `cJobKey` | stable key (`checkdb`, `index-optimize`, …), PK |
| `cDisplayName` | Agent job name (prefix `RoboticoOps - Maint - …`) |
| `cOperation` | `IntegrityCheck` \| `IndexOptimize` \| `Cleanup` \| `BackupWatchdog` |
| `cDatabases` | one of **two grammars, selected by `cOperation`** (documented in the data-model doc): an Ola `@Databases` expression (`USER_DATABASES`, `ALL_DATABASES, -eazybusiness_tm%`, `msdb`) for the Ola-backed operations, or a **literal comma-separated DB list** (`eazybusiness,RoboticoOps`) that `maint.spCheckBackupChain` splits itself for `BackupWatchdog` — Ola scope tokens are undefined for watchdog rows |
| `cFrequency`, `nWeekdayMask`, `tStartTime` | schedule as **typed columns** (`daily`/`weekly`/`hourly` + weekday **bitmask** (1=Sun…64=Sat, OR-able for multi-day) + start time, CHECK-validated) — not a cron string; the sync proc maps them onto `msdb.dbo.sysschedules` via a fixed conversion table (daily → `freq_type=4`/`freq_interval=1`; weekly → `freq_type=8`/`freq_interval` = the mask/`freq_recurrence_factor=1`; hourly → `freq_type=4` plus `freq_subday_type=8`/`freq_subday_interval=1`, running every hour from the `tStartTime` anchor (plan D35); `tStartTime` → int-HHMMSS `active_start_time` — constants in plan §3.2) without any parsing. Same typing rationale as the knobs below. The `t` in `tStartTime` is a documented micro-extension of the Hungarian convention (`t` = `time` column; deliberate second use of the letter besides the `t<Table>` prefix, recorded in `NAMING-CONVENTIONS.md`). |
| *typed knob columns* | operation-specific, `NULL` when N/A, each CHECK-validated: `bUpdateStatistics` (IndexOptimize — **required NOT NULL there**: `1` → `@UpdateStatistics='ALL'`, `0` → parameter omitted as a deliberate exception; a NULL would invite the "omit the parameter" reading that reproduces F8); `cCleanupTarget` + `nRetentionDays` (Cleanup); `nFullMaxHours` + `nLogMaxHours` (BackupWatchdog). **Not** a free-form parameter string — a composite CHECK enforces the required knobs per operation, so the registry is self-validating. A CHECK also enforces the `RoboticoOps - Maint - ` prefix on `cDisplayName` (create AND remove key off that prefix — an unprefixed row would spawn a ghost job outside the managed window). |
| `bEnabled`, `bNotifyOnFail` | active flag / failure-mail flag. `bEnabled` maps onto the Agent job's `enabled` state — the job exists for **every** registry row and is only en-/disabled (pausing keeps history and stays visible in SSMS); the effective state additionally honours the instance switch (D-A6). |

The whole maintenance landscape is thus **one `SELECT`** and is documented in `docs/SQL/MSSQL-OPS-DATA-MODEL.md` (per the CLAUDE.md ops-table update contract). The knobs are **typed columns, not a free-form string** — chosen for validation and safety (a free string parsed into a dynamic Ola call would be both untyped and an injection surface).

### D-A3 — Idempotent sync via `maint.spEnsureMaintenanceJobs`

An anytime proc (grate `runAfterOtherAnyTimeScripts`, exactly like `reset.spEnsureAgentJob`) reads the registry and **synchronises** the Agent jobs: create missing, update drifted (schedule/step/scope), and remove Agent jobs carrying the `RoboticoOps - Maint - ` name prefix that are no longer in the registry. Jobs are **owned by `sa`** (their T-SQL step runs as the sysadmin Agent service account — no module signing needed, same reasoning as the reset job).

**Runtime dispatch (deep-review resolution, plan D28).** Every job carries the same **constant, fully qualified step** `EXECUTE RoboticoOps.maint.spRunMaintenanceJob @cJobKey = N'<key>';` — the only sync-time substitution is the quote-doubled `cJobKey` literal. The dispatcher reads the registry row **at run time** and executes the operation from a **closed command map** (one commented `CASE` block: `RoboticoOps.dbo.<Ola proc>` for IntegrityCheck/IndexOptimize; `msdb.dbo.sp_delete_backuphistory` / `sp_purge_jobhistory` or a `CommandLog` DELETE for the cleanups — cutoffs computed at run time, never a sync-time-frozen date; `maint.spCheckBackupChain` for the watchdog). This follows the reset precedent (the reset job's step is the constant, parameterless `EXEC reset.spProcessNextResetRequest`). Two consequences: registry changes to scope/knobs take effect **immediately after the seed MERGE without touching msdb**, and a persisted job step never carries data values. A genuinely **new operation type** remains a deliberate multi-site change (CHECK value, knob columns, dispatcher branch, docs) — "add a row" extensibility applies to new instances of *existing* operation types.

Sync mechanics: the ensure proc works **per job** — create when missing, drop/recreate (`sp_delete_job … @delete_unused_schedule = 1`) only when the desired definition differs from the live msdb job, otherwise no-op. The comparison uses a **closed, canonical surface**: job (`enabled`, notify level/operator), step (constant command text, database, subsystem), schedule (`freq_type`, `freq_interval`, `freq_recurrence_factor`, `freq_subday_type`, `freq_subday_interval`, `active_start_time`, `enabled`) — registry values are converted to the msdb representation *before* comparing (D-A2's conversion table), and all comparisons are NULL-safe via `IS DISTINCT FROM`; anything less either drifts invisibly or drop/recreates on every deploy. The running-job guard checks `msdb.dbo.sysjobactivity` **scoped to the current Agent session** (`MAX(session_id)` from `msdb.dbo.syssessions` — stale rows of a killed Agent session would otherwise mark a job as "running" forever): a currently running job is skipped and reported, never a global abort; a skip converges on the next deploy because `260` re-runs the sync unconditionally (D-A5). The notify operator is wired only if it exists in `msdb.dbo.sysoperators` (else `NULL`), so a deploy never fails on a missing operator (see D-A5 for how first-deploy convergence is achieved).

Registry values (`cDatabases` and the typed knobs) reach the Ola/system procedures **exclusively as genuine T-SQL parameters of the runtime dispatcher — never rendered into a persisted step text** (the earlier "sp_executesql parameters only" phrasing was unimplementable for persisted Agent steps, which are static strings; the dispatch makes the intent hold literally, without any dynamic SQL). Data never becomes code (same principle as the `ops.tResetStep` whitelist). Combined with the typed/CHECK-validated columns (D-A2), the registry is neither an injection surface nor a source of untyped runtime errors.

The registry is **repo-owned**: the everytime seed MERGEs *all* target columns on every deploy, overwriting live edits (including `bEnabled`, times, thresholds), with a NULL-safe value guard (`IS DISTINCT FROM`) so pure NULL↔value changes are not silently swallowed, **and a `WHEN NOT MATCHED BY SOURCE THEN DELETE` branch**: rows removed from the seed disappear from the live registry and the ensure proc removes their jobs in the same deploy — without the delete branch, "repo is SSoT" would hold for updates but never for removals. Maintenance tuning happens exclusively via git + deploy — full traceability was the explicit requirement. This deliberately deviates from `ops.tResetStep`, whose seed inserts only new rows so live admin tuning wins; both semantics are documented at their proc headers.

### D-A4 — One Agent job per operation, staggered nightly

Not one chained job. Each operation is its own job for failure isolation (one broken job does not stop the others) and independent scheduling. Ordering is expressed through staggered start times, CHECKDB **before** the 03:00 full backup (so corruption is caught before it enters the backup chain):

| `cJobKey` | Operation | `cDatabases` | Schedule |
|---|---|---|---|
| `checkdb` | IntegrityCheck | `ALL_DATABASES, -eazybusiness_tm%` | weekly Sun+Wed 01:00 |
| `index-optimize` | IndexOptimize `@UpdateStatistics=ALL` | `USER_DATABASES` | daily 02:00 |
| `cleanup-commandlog` | Cleanup (CommandLog, 365 d) | `RoboticoOps` | weekly Sun 00:30 |
| `cleanup-backuphistory` | Cleanup (`sp_delete_backuphistory`, 365 d) | `msdb` | weekly Sun 00:35 |
| `cleanup-jobhistory` | Cleanup (`sp_purge_jobhistory`, 365 d) | `msdb` | weekly Sun 00:40 |
| `backup-watchdog` | BackupWatchdog | `eazybusiness,RoboticoOps` | hourly (anchor 00:00) |

Two deliberate omissions/limits: **no job output files** (history lives in `CommandLog` + Agent job history; this removes the only filesystem/CmdExec dependency and the output-file cleanup job), and **IndexOptimize runs REORGANIZE-only** (`@FragmentationHigh` without `INDEX_REBUILD_OFFLINE`): Standard Edition cannot rebuild ONLINE, and an offline rebuild at 02:00 would lock tables of a 24/7 ERP. With currently 0 indexes >30 % (F7) this costs nothing; a persistently high-fragmentation index becomes a deliberate manual maintenance-window action instead.

The tm-clone treatment differs by operation, deliberately: **IndexOptimize includes** the `eazybusiness_tm*` clones (`USER_DATABASES`) — they are worked on interactively and benefit from defrag + fresh statistics. **CHECKDB excludes** them (`-eazybusiness_tm%`) — they are throwaway copies recreated by the reset from the integrity-checked source DB, so checking each clone twice a week would be pure cost; the single `ALL_DATABASES`-based job covers user **and** system DBs (incl. `msdb`) in one run, twice weekly (Sun+Wed, each ahead of the 03:00 full). The backup watchdog also excludes the clones (SIMPLE, unbacked-up throwaways). See [adr-backups-cbb-retained](0002-backups-cbb-retained.md).

### D-A5 — Failure alerting is wired end to end

The **operator** `RoboticoOps-Maint` (email `lukas@dattenberger.com`) and the **Agent mail profile** `Standard SMTP` are ensured by the everytime permissions script `260_maintenance_operator.sql`. Because grate runs `permissions/` *after* `runAfterOtherAnyTimeScripts/`, the hash-gated sync executes before the operator exists on a first deploy — so `260`, after creating the operator, **re-executes the ensure proc unconditionally on every deploy** (plan D29; a trigger precondition would re-open the propagation hole — hash-gating plus the running-job skip would leave a skipped definition change unapplied forever, since definition drift was no trigger condition). The per-job canonical comparison (D-A3) makes the unconditional call a no-op in the healthy steady state. This closes the first-deploy alerting gap, doubles as the **everytime self-heal** for manually deleted jobs / a rebuilt `msdb` (pattern: `permissions/200_ensure_agent_job.sql`), and applies any previously skipped change on the next deploy. `260` also guards the mail-profile assignment on `msdb.dbo.sysmail_profile` existence (no phantom profile name on instances without Database Mail). The sync itself wires `@notify_email_operator` on every job with `bNotifyOnFail = 1` (operator-EXISTS guard, see D-A3). The watchdog raises its own mail via the same operator.

**Liveness guard for the "never ran" pattern (plan D36).** `bNotifyOnFail` only catches jobs that *run and fail* (the F2 pattern) — but most of the historical damage was the F3/F4 pattern: jobs that existed and never ran (two years without CHECKDB), which failure notification is structurally blind to (a live-detached schedule, a live-disabled job; the `260` self-heal converges only at the next deploy, which may be weeks away). The hourly watchdog job therefore also executes `maint.spCheckMaintenanceLiveness`: parameterless and self-configuring from the registry, it derives — per effectively enabled Ola-backed row (IntegrityCheck/IndexOptimize; honours the D-A6 switch, so test1 is a no-op) — the maximum acceptable age of the newest matching `dbo.CommandLog` entry from the declared schedule (daily → 26 h, weekly → 8 days) and raises `THROW 51105` naming the stale job keys. Cleanups are deliberately out of scope (they do not log to CommandLog and their outage is low-stakes); the watchdog covers itself via its own alert path.

Taken together: a silent multi-month *run-and-fail* outage like F2/F6 becomes impossible, and a silent *never-runs* outage like F3/F4 is caught within the derived cadence — **as long as the Agent service itself is running**. That residual blind spot cannot be self-monitored from within Agent jobs (see Failure Modes) and is assigned to the external-monitoring follow-up task (plan Gap 2).

The operator's **name and recipient email are deliberately hardcoded** in the committed `260` script — a conscious divergence from the reset infrastructure, which externalises its operator into `ops.tConfig('NotifyOperator')` (instance-tunable). The maintenance suite applies its repo-owned stance (D-A3) to the alert recipient too: changing the recipient is a git change + deploy, with the same traceability as every other maintenance tuning. Documented in the `260` header so the next reader does not mistake it for an oversight.

### D-A6 — test1 is a deploy/validation target only

The identical chain deploys to test1 (proves the migration), is validated by one manual run, but carries no permanent schedule there (its DBs are throwaways). **Realised by an instance switch, not by the Agent service state** (plan D34): `ops.tConfig('MaintenanceSchedulesEnabled')` — effective job enabled state = `bEnabled = 1` AND switch ≠ `'0'`; a missing key means enabled, so prod needs no entry. test1 sets `'0'`: the jobs exist there in full (structure and rollout gates apply), but are disabled — `sp_start_job` starts disabled jobs, so manual validation is unaffected. The Agent service state cannot serve as the gate: the test-mandant reset requires a running test1 Agent (`sp_start_job` path), so any overnight reset session would otherwise fire the full prod schedule — including a daily by-design-red backup watchdog — on test1, training alarm fatigue. The switch is admin-owned instance *state* (like `AgentJobName`/`NotifyOperator`); the registry rows stay identical on every instance.

## Alternatives Considered

1. **Keep Ola in `eazybusiness.dbo`, just repair/re-add the missing procs.** Cheapest fix. Rejected: it re-creates the exact fragility that caused the outage — the next JTL refresh wipes it again, unversioned, unmonitored. Treats the symptom, not the cause.

2. **Explicit per-job migration scripts (schedule/scope hardcoded in SQL), no registry.** Simpler per file. Rejected: the Job×DB×Schedule matrix is then scattered across many files — the operator cannot see the whole landscape at a glance, which was an explicit requirement. A registry makes it one query and one documented table.

3. **Config-key driven (`ops.tConfig` key-values).** Reuses an existing table. Rejected: a multi-column matrix (operation, scope, parameters, schedule, flags per job) does not fit a flat key-value store legibly.

4. **One chained nightly job with sequential steps.** Guarantees CHECKDB-before-IndexOptimize ordering in one calendar entry. Rejected: coarser failure isolation — an abort in step 1 stops all later maintenance, and per-operation history/alerting is muddier. Staggered per-operation jobs give the same ordering with better isolation.

5. **Ola's own `@CreateJobs='Y'`.** Ola creates its standard jobs itself. Rejected: less control over schedule/alerting/idempotency and closer to the original click-ops that failed. We keep job creation under our versioned `spEnsure…` sync.

6. **A dedicated maintenance database instead of RoboticoOps.** Independent of the RoboticoOps prod cutover. Rejected: a second ops DB to deploy, secure, back up and CHECKDB; RoboticoOps is already the ops home and will be on prod as part of the same global-chain cutover this work needs anyway.

## Consequences

**Positive:**
- The entire maintenance landscape is one `SELECT ops.tMaintenanceJob` and one documented table — the legibility requirement is met.
- Deterministically reproducible: `deploy.ps1 -Scope global` rebuilds the whole suite on any instance; a fresh server or a wiped instance is one deploy away from full maintenance.
- Survives mandant restores (objects in RoboticoOps, not the vendor DB) — the root cause of the outage is structurally removed.
- CHECKDB (User + System, incl. msdb) closes the largest actual gap; statistics are finally maintained (`@UpdateStatistics=ALL`).
- Failure alerting plus the liveness guard make another silent multi-month outage impossible while the Agent runs: run-and-fail (F2) alerts immediately, never-ran (F3/F4) alarms within the schedule-derived cadence.
- Reuses proven patterns (reset-step registry, sa-owned ensure-proc, Database Mail) — little new surface area.

**Negative:**
- Couples the maintenance rollout to the **RoboticoOps prod cutover** (RoboticoOps does not yet exist on vm-sql2). Maintenance cannot go live on prod before that global-chain deploy.
- One indirection more than hand-made jobs: to understand a live Agent job you read the registry + the ensure-proc, not just the job. (This is the price of legibility/reproducibility.)
- We now own the Ola version we vendor — upgrades are a deliberate new `up/` script, not an automatic pull.
- A genuinely new operation *type* is a multi-site change (CHECK constraint, knob columns, dispatcher branch, docs) — the registry's "add a row" extensibility covers new instances of existing operation types only (see D-A3).
- The runtime dispatch (D-A3) adds one more indirection and an additional `maint.*` proc: the live job step no longer shows the operation's parameters — evidence of what actually ran lives in `dbo.CommandLog` (`@LogToTable='Y'`) and the registry, not in the step text.

**Failure Modes:**
- **Sync removes foreign jobs by name prefix.** `maint.spEnsureMaintenanceJobs` deletes only jobs matching `RoboticoOps - Maint - `. A hand-created job that happens to use that prefix would be silently removed on the next deploy. The prefix is reserved for registry-owned jobs — documented in the runbook.
- **A job's step runs in the wrong DB context.** The constant dispatch step must be **fully qualified** (`EXECUTE RoboticoOps.maint.spRunMaintenanceJob …`), and inside the dispatcher every command of the map is fully qualified too (`RoboticoOps.dbo.<Ola proc>`, `msdb.dbo.sp_…`) — the old job's bare `EXECUTE [dbo].[IndexOptimize]` with a foreign default DB is exactly how F2 happened.
- **A forgotten instance switch silently disables all maintenance.** `ops.tConfig('MaintenanceSchedulesEnabled') = '0'` left behind on prod (e.g. copied from a test1 procedure) would keep every job disabled with green deploys. Mitigations: prod's standard cutover never sets the key (plan D34), and the rollout gate asserts the enabled *equation* (`bEnabled` AND switch), so the state is visible on every validation run.
- **Cutover job-name collision.** The 11 old Ola jobs must be removed *before* the new suite is enabled, or two IndexOptimize jobs run against different object sets. Ordering is fixed in the cutover runbook: the old install is removed **before** the deploy, because the deploy creates the new jobs immediately enabled (plan §3.6, D16).
- **A stopped Agent service silences everything — including both watchdog checks.** Every alarm in this design (failure mail, backup-chain check, liveness check) is itself an Agent job; if the Agent service stops or crashes, all of them go quiet together, reproducing the F3 blind spot at the service level. This is not self-monitorable from within Agent jobs by construction — external liveness monitoring of the Agent/instance belongs to the follow-up task that also owns Database-Mail health (plan Gap 2).
- **Alerting depends on Database Mail staying healthy.** If the brevo account/profile breaks, failures go silent again. The watchdog partially self-checks (it also mails), but Database-Mail health itself is unmonitored — noted as an Information Gap in the plan.
- **`USER_DATABASES` auto-includes any new DB on the instance.** A future unrelated DB (e.g. a new foreign DB) is silently swept into CHECKDB/IndexOptimize. Usually desirable, but the operator must know the scope is dynamic.
- **IndexOptimize vs. reset-pipeline collision on the shared `eazybusiness_tm*` clones.** IndexOptimize deliberately includes the clones (daily 02:00, D-A4) while the reset subsystem DROP+restores them **on demand** — including at 02:00. The collision is accepted, not prevented (plan D24): the reset always wins by construction — `reset.spInternal_CloneDatabase` takes the clone `SINGLE_USER WITH ROLLBACK IMMEDIATE`, killing any IndexOptimize session on it, which surfaces as a one-off red maintenance job (→ notify mail, correctly signalling the interruption); a clone mid-restore is in `RESTORING` state and is silently skipped by Ola (benign). No guard in either direction is added — the rare collision is transient and self-healing (the next nightly run covers the clone again).
- **Deploy overwrites live registry edits.** Because the registry is repo-owned (D-A3), a quick live fix (`UPDATE ops.tMaintenanceJob SET bEnabled=0 …`) silently reverts on the next global deploy. Anyone pausing a job must do it in git, or the pause evaporates.
- **Agent mail-profile assignment needs an Agent restart.** The permissions script sets the profile, but the Agent alert system only picks it up after a restart — until then, failure mails silently do not go out. The cutover runbook contains the restart step; an alert test before it is meaningless.
- **The nightly window ordering is asserted, not enforced.** CHECKDB (Sun/Wed) 01:00 → IndexOptimize 02:00 → CBB full 03:00 relies on measured durations, not dependencies. If CHECKDB grows past ~1 h, jobs overlap; the first validated runs must measure and, if needed, the registry times get adjusted.

## References

- **Related Plan:** [mssql-wartung-ola](../plans/2026-07-21 - mssql-wartung-ola/mssql-wartung-ola.md) — the plan that implements this ADR (bidirectional).
- **Research:** [6-wartung-ist-analyse](../plans/2026-07-10 - mssql-ops-infrastruktur/research/6-wartung-ist-analyse/6-wartung-ist-analyse.md)
- **Related ADRs:** [adr-reset-step-registry](../plans/2026-07-10 - mssql-ops-infrastruktur/adrs/adr-reset-step-registry.md) (registry pattern reused), [adr-module-signing-reset](../plans/2026-07-10 - mssql-ops-infrastruktur/adrs/adr-module-signing-reset.md) (Agent-job creation pattern), [adr-two-chain-migration-paths](../plans/2026-07-10 - mssql-ops-infrastruktur/adrs/adr-two-chain-migration-paths.md) (Ebene-B / global chain), [adr-ebene-b-hungarian-naming](../plans/2026-07-10 - mssql-ops-infrastruktur/adrs/adr-ebene-b-hungarian-naming.md) (naming convention adopted; the `t` = `time` column prefix in D-A2 is a documented micro-extension of it — at promotion, that ADR gets a reciprocal Decision-History note), [adr-grate-migration-runner](../plans/2026-07-10 - mssql-ops-infrastruktur/adrs/adr-grate-migration-runner.md) (grate stage/folder-order guarantee that the `260` first-deploy convergence in D-A5 relies on), [adr-backups-cbb-retained](0002-backups-cbb-retained.md) (backup ownership + watchdog).
- **Data model:** `docs/SQL/MSSQL-OPS-DATA-MODEL.md` (must gain the `ops.tMaintenanceJob` rows).
- **External:** [Ola Hallengren Maintenance Solution](https://ola.hallengren.com/)

## Decision History

### 2026-07-21 — Initial proposal

**Trigger:** Design session after the live IST-analysis showed vm-sql2 has no effective maintenance (nightly IndexOptimize failing since ~2025-11-27, no CHECKDB since 2024).

**Before:** 11 hand-created Ola jobs in `eazybusiness.dbo`; one scheduled, failing daily; no versioning, no alerting.

**After:** Maintenance is code in RoboticoOps — Ola vendored in `dbo`, a declarative `ops.tMaintenanceJob` registry, an idempotent `maint.spEnsureMaintenanceJobs` sync, one sa-owned job per operation, end-to-end failure alerting.

**Reasoning:** Reusing the RoboticoOps registry + ensure-proc + Database-Mail patterns removes the three root causes (wrong location, click-ops, no alerting) at once and makes the whole landscape legible from one table — chosen over a cheap in-place repair (alt. 1) and over scattered per-job scripts (alt. 2).

### 2026-07-21 — Design-review refinements (typing, vendoring, safety)

**Trigger:** Lukas' review questions ("is `cParameters` typed and safe?", "must the objects live in `dbo`?") plus a full re-think pass over the draft.

**Before:** Free-form `cParameters` string and a `cScheduleCron` string (both would need parsing in the sync proc); vendoring via the all-in-one `MaintenanceSolution.sql` (requires editing its `@CreateJobs` header); `DatabaseBackup` deployed though unused; 8 registry rows incl. an output-file cleanup with a CmdExec/filesystem dependency; rebuild behaviour and seed semantics unspecified.

**After:** All job knobs AND the schedule are typed, CHECK-validated columns (composite CHECK enforces required-and-only-relevant knobs per operation); execution passes values solely as typed `sp_executesql` parameters; Ola is vendored as its byte-unmodified per-object scripts *without* `DatabaseBackup.sql`; no job output files → 7 rows, no CmdExec; IndexOptimize is REORGANIZE-only on Standard Edition; the registry is explicitly repo-owned (MERGE overwrites live edits, deviating from `ops.tResetStep`); new failure modes recorded (live-edit overwrite, Agent-restart for mail profile, asserted-not-enforced night window).

**Reasoning:** The review exposed that the schedule string repeated the exact stringly-typed mistake just removed from the knobs; typed columns close it uniformly. Per-object vendoring keeps the "pinned, unmodified vendor file" principle honest, and not deploying `DatabaseBackup` turns the ADR-B "no Ola backups" rule from convention into impossibility.

### 2026-07-21 — CHECKDB cadence and scope revision

**Trigger:** Lukas' directive: CHECKDB twice per week over all databases except the test-mandant clones.

**Before:** Two daily CHECKDB jobs (`SYSTEM_DATABASES` 01:00, `USER_DATABASES` incl. tm clones 01:15); schedule model limited to a single weekday (`nWeekday`).

**After:** One `checkdb` job over `ALL_DATABASES, -eazybusiness_tm%` (Ola exclusion syntax; covers user + system DBs incl. `msdb` in one run), weekly Sun+Wed 01:00. The schedule model gained `nWeekdayMask` (bitmask, identical to `sysschedules.freq_interval`) to express multi-day weekly schedules in typed form. Registry now has 6 rows.

**Reasoning:** Full-instance CHECKDB is the suite's most expensive job; nightly runs on throwaway clones (recreated from the integrity-checked source by every reset) add cost without value. Twice weekly on the real DBs still catches corruption within days and ahead of the corresponding 03:00 full backups, and the merged `ALL_DATABASES` job removes a redundant system/user split.

### 2026-07-21 — Quality-gate consolidation (7-agent plan review)

**Trigger:** The plan's quality gate (2 Critical, 13 Important findings across 7 review agents) hit decisions owned by this ADR: the operator-vs-sync grate ordering (Critical), the unspecified sync/idempotency mechanics, the oversold "add a row" extensibility, and the dual `cDatabases` grammar.

**Before:** D-A5 left the operator's home ambiguous ("`spEnsureMaintenanceJobs` *(or a companion permissions script)*") — but grate runs `permissions/` *after* the hash-gated sync, so on a first deploy the operator would not exist when jobs are created and the notify wiring would never converge (or the deploy would hard-fail on an unknown operator). D-A3 did not specify how the sync updates drifted jobs, how it guards running jobs, or that the per-operation step commands cannot share one `dbo.<proc>` template. `cDatabases` was described as a single Ola-expression grammar; the `t` time-prefix was an undocumented naming outlier.

**After:** D-A5: operator + mail profile live in the everytime `260_maintenance_operator.sql`, which conditionally re-executes the ensure proc after creating the operator (first-deploy convergence + everytime self-heal, `200_ensure_agent_job.sql` pattern); the sync carries an operator-EXISTS guard. D-A3: per-job compare-then-drop/recreate with a `sysjobactivity` skip-and-report guard; a closed per-operation command map; a new operation type is documented as a deliberate multi-site change (also added to Consequences). D-A2: `cDatabases` carries two documented grammars (Ola expression vs. literal list for the watchdog); the `t` = `time` prefix is recorded as a naming micro-extension. The cutover failure mode now states the concrete ordering (old install removed before the deploy).

**Reasoning:** The grate stage order (`permissions/` last) plus hash-gating would leave alerting permanently unwired on a clean deploy — the conditional everytime re-trigger closes that Critical and the self-heal asymmetry against the reset precedent in one script. The remaining refinements turn implicitly assumed mechanics into specified, testable behaviour without changing the architecture.

### 2026-07-21 — Quality-gate round 2 (deep mode) — consolidator pass

**Trigger:** Second quality-gate round (9 agents, deep mode) on the revised plan; the consolidator applied the standard-agent findings owned by this ADR — the unreconciled IndexOptimize↔reset seam over the shared tm clones (SA-2), the hardcoded operator identity's divergence from the reset's config-driven operator (SA-4), and missing references to the naming and grate ADRs the design builds on (ADR-1).

**Before:** The lifecycle interaction between nightly IndexOptimize (includes the tm clones) and the on-demand reset (DROP+restores those same clones) was undiscussed — no failure mode named the collision or its resolution. D-A5 hardcoded operator name + email in `260` without recording why this deviates from the reset's `ops.tConfig('NotifyOperator')` pattern. References omitted `adr-ebene-b-hungarian-naming` (whose convention D-A2 extends with `t` = time) and `adr-grate-migration-runner` (whose folder-order guarantee D-A5's `260` convergence relies on).

**After:** New failure mode: the clone collision is accepted — the reset wins by construction (`SINGLE_USER WITH ROLLBACK IMMEDIATE` kills the IndexOptimize session → one-off red job + mail; a clone in `RESTORING` is skipped by Ola), no guard in either direction (plan D24). D-A5 records the hardcoded operator identity as a deliberate application of the repo-owned stance to the alert recipient. Both sister ADRs are referenced with their relationship; a reciprocal note on the naming ADR is queued for promotion.

**Reasoning:** The collision is rare, transient, and self-healing, and the reset's existing `SINGLE_USER` takeover already provides a deterministic winner — documenting the seam beats adding cross-subsystem coordination for a case whose worst outcome is one legitimate alert mail. The operator hardcoding follows the same traceability logic (D-A3) that governs the rest of the registry, so it is recorded as intent, not fixed. Reference wiring keeps the plan↔ADR graph navigable per the bidirectionality rule.

### 2026-07-21 — Quality-gate round 2 (deep mode) — technical deep-dive pass (FT findings)

**Trigger:** The deep-mode technical analyst mentally executed the sync/dispatch/watchdog paths and found the D-A3 security rule unimplementable for persisted Agent steps (FT-1, independently confirmed by two more agents), plus a cluster of lifecycle holes: skipped changes never re-applied (FT-2), NULL-blind comparisons and no seed-delete path (FT-5/FT-6), unnormalised schedule comparison incl. the missing `freq_recurrence_factor` (FT-7), a session-unscoped running guard (FT-8), an optional `bUpdateStatistics` (FT-10), an unprefixed-display-name hole (FT-12), and a test1 conflict: "no permanent schedule" relied on the stopped Agent that the reset subsystem requires running (FT-11).

**Before:** D-A3 built parameter-carrying step texts per operation and claimed values pass "exclusively as `sp_executesql` parameters" — impossible for a static `sysjobsteps` string. `260` re-ran the sync only conditionally (job/notify missing), so a change skipped while a job ran was never retried. The seed MERGE had no delete branch and no NULL-safe guard. The schedule mapping and comparison normal form were unspecified. D-A6 realised test1's "no permanent schedule" by not enabling the Agent.

**After:** D-A3 adopts **runtime dispatch** (plan D28, choosing the reviewer-proposed CA-1 variant over merely re-scoping the rule): constant step `EXEC maint.spRunMaintenanceJob @cJobKey = …`, a fourth `maint.*` proc owning the command map at run time, values as genuine T-SQL parameters, run-time cleanup cutoffs; the comparison surface is a closed canonical list with `IS DISTINCT FROM`, the schedule conversion constants are fixed (incl. `freq_recurrence_factor = 1`), the running guard is scoped to the current Agent session, and jobs are dropped with `@delete_unused_schedule = 1`. The seed MERGE gains `WHEN NOT MATCHED BY SOURCE THEN DELETE`. D-A5's re-trigger becomes unconditional (D29) and guards the mail-profile assignment on existence. D-A2 requires `bUpdateStatistics NOT NULL` for IndexOptimize (defined 1/0 mapping) and a `cDisplayName` prefix CHECK. D-A6 is realised by the `ops.tConfig('MaintenanceSchedulesEnabled')` instance switch instead of the Agent service state; `bEnabled` maps to the job's enabled flag. New consequences/failure modes recorded (dispatcher indirection; forgotten-switch mode).

**Reasoning:** A persisted Agent job step is a static string — any design that renders registry values into it must concatenate, so the security rule and the mechanics could not both hold. Runtime dispatch resolves the contradiction in the direction the codebase already points (the reset job's step is a constant `EXEC`), and as a side effect removes the frozen-cutoff and step-text-drift failure classes entirely. The remaining fixes turn the sync's implicit comparison and lifecycle assumptions into specified, testable invariants; the instance switch replaces an unenforceable operational assertion (Agent stays stopped) with a mechanism that survives the reset subsystem's documented need for a running Agent.

### 2026-07-22 — Quality-gate round 2 (deep mode) — feature-intent pass (FI findings)

**Trigger:** The deep-mode intent analyst held the package against the design intention ("never silent again") and the live behaviour of the old install, and found the alerting promise structurally half-covered: `bNotifyOnFail` only catches jobs that run and fail (F2), while most of the historical damage was jobs that never ran at all (F3/F4) — and the D-A5 claim "a silent multi-month failure becomes impossible" overstated what notification can deliver (FI-1). It also flagged the watchdog's daily cadence as incompatible with the "log < 1 h" freshness intent, with the schedule model unable to express intra-day frequency and `up/0023` about to become immutable (FI-3).

**Before:** D-A5 relied solely on failure notification plus deploy-time self-heal; nothing detected a live-detached schedule or disabled job between deploys, and the "becomes impossible" sentence claimed full coverage. The watchdog ran daily 08:00 (up to ~24 h detection latency against a 1-h log threshold); `cFrequency` knew only `daily`/`weekly`.

**After:** D-A5 gains the liveness guard `maint.spCheckMaintenanceLiveness` (fifth `maint.*` proc, parameterless, `THROW 51105`): executed as the second step command of the watchdog job, it derives per effectively-enabled Ola-backed registry row the maximum acceptable `CommandLog` age from the declared schedule and alarms when maintenance demonstrably did not run. The impossibility claim is precised to its true scope (run-and-fail immediate, never-ran within derived cadence, both conditional on a running Agent); a new failure mode records the stopped-Agent blind spot and assigns it to the external-monitoring follow-up (plan Gap 2). D-A2/D-A3 gain `cFrequency = 'hourly'` (`freq_subday_type=8`/`freq_subday_interval=1`; subday columns added to the canonical comparison surface), and the D-A4 watchdog row runs hourly from a 00:00 anchor (plan D35).

**Reasoning:** The intention was born from a never-runs outage, so a design whose alerting only covers run-and-fail would leave the original wound open; deriving liveness thresholds from the registry keeps the check declarative and self-configuring instead of adding new knobs. Hourly cadence makes the log-freshness promise real (detection ≤ ~2 h instead of ≤ 24 h) and had to be decided before the immutable `up/` freeze made the schema extension expensive — the mapping table was explicitly built for this additive extension.

### 2026-07-23 — Promoted + Accepted

**Trigger:** Plan `mssql-wartung-ola` implementation completed, E2E-verified and accepted; the plan-scoped ADR is promoted per `lifecycle-adr.md` §"Plan-scoped ADRs".

**Before:** `Proposed (plan-scoped — pending promotion)`, filename `adrs/adr-maintenance-as-code-roboticoops.md` inside the plan folder, header carrying the `ADR-NNNN` placeholder.

**After:** Moved to `docs/decisions/0001-maintenance-as-code-roboticoops.md` (first entry in the newly established decisions index), `ADR-NNNN` → `ADR-0001`, `Status: Accepted`. Relative links to the sister ADR (now `0002-backups-cbb-retained.md`), the plan, the older mssql-ops ADRs, and the research file were re-based to the `docs/decisions/` depth. The `adr-ebene-b-hungarian-naming` back-reference (D20 `t`=time micro-extension) was made bidirectional at the same time.

**Reasoning:** The maintenance suite is implemented, deployed to test1, and accepted; the decision is in effect and no longer plan-scoped. Promotion establishes `docs/decisions/` and makes the decision discoverable independent of the plan that produced it.
