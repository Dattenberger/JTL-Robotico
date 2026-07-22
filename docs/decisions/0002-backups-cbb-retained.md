# ADR-0002: Backups stay with CBB — SQL maintenance does not own backups, but monitors the chain

**Status:** Accepted
**Subsystem:** RoboticoOps, Testmandant Reset
**Date:** 2026-07-21
**Supersedes:** —
**Author:** Lukas + Claude Code

> **Cooperates with [adr-maintenance-as-code-roboticoops](0001-maintenance-as-code-roboticoops.md).** That ADR owns the maintenance suite and the registry; this ADR fixes one scope boundary within it — backups are explicitly *out*, monitoring is *in*.

## Research

- **[6-wartung-ist-analyse §2 F1 + §3.2](../plans/2026-07-10 - mssql-ops-infrastruktur/research/6-wartung-ist-analyse/6-wartung-ist-analyse.md)** — live evidence that backups already run healthily and **externally via CBB**, not via Ola: `eazybusiness` full daily 03:00 (`copy_only=0`, `NT-AUTORITÄT\SYSTEM`), diff, and log every ~15 min (last log 2026-07-21 11:45). The Ola `DatabaseBackup` jobs have no schedule and have **never run**.
- **[6-wartung-ist-analyse §2 F2/F6](../plans/2026-07-10 - mssql-ops-infrastruktur/research/6-wartung-ist-analyse/6-wartung-ist-analyse.md)** — the outage pattern that motivates the watchdog: a scheduled job failed silently for ~8 months because nothing checks liveness. Backups deserve the same liveness guard.
- **Backup-time distribution (§3.2)** — the real chain-relevant full is a single daily 03:00 run; the 18:00 run and ad-hoc runs are `copy_only` and do not affect the chain. This is what the maintenance window schedules *around*.

## Context

When adding an SQL maintenance suite, the natural temptation is to let Ola own everything including backups (`DatabaseBackup`), yielding "one maintenance solution". But backups on vm-sql2 are already handled by CBB and are demonstrably healthy. Two questions must be answered explicitly so a future reader does not "consolidate" backups into Ola by reflex: (1) who owns backups, and (2) how do we avoid the same silent-failure blind spot for the backup chain that we just found for maintenance.

## Decision

**Backups remain the responsibility of CBB. The SQL maintenance suite does not create or schedule any backup job. Instead it adds a read-only backup-chain watchdog.**

- **No Ola `DatabaseBackup`.** `DatabaseBackup.sql` is **not even vendored** — the pinned per-object vendor script deploys only `CommandLog`/`CommandExecute`/`DatabaseIntegrityCheck`/`IndexOptimize`, so an Ola backup job is not merely unregistered but impossible to schedule against RoboticoOps. CBB stays the sole backup mechanism; its schedule, storage, retention and restore story are untouched.
- **Backup-chain watchdog (`maint.spCheckBackupChain`).** An **hourly** job (anchored 00:00; plan D35 — a daily probe would stretch the "log < 1 h" freshness promise to an up-to-24-h detection latency, ~90 lost recovery-point hours worst case; hourly caps it at ~2 h, and the schedule model gained `'hourly'` for exactly this row before the immutable `up/` freeze) queries `msdb.dbo.backupset` per watched DB and alerts (via the maintenance operator, by failing its job step with `THROW 51100` — allocated in the migration lint's THROW table — → `NotifyOperator` mail) if the chain is stale: **last full < 26 h** (`is_copy_only = 0` only) and **last log < 1 h** (thresholds in the typed registry columns `nFullMaxHours`/`nLogMaxHours`; boundary semantics fixed: the alarm fires when `age >= threshold`, so an exactly-26-h-old full already alarms — this makes the plan's threshold test deterministic at the boundary). The **log check applies to all log-based recovery models** — filter `recovery_model_desc <> N'SIMPLE'`, covering FULL **and** BULK_LOGGED (a SIMPLE-recovery DB has no log chain by design and would otherwise alarm permanently; a BULK_LOGGED DB does keep a log chain and must not silently drop out of the check). **Age arithmetic runs in local server time** (`SYSDATETIME()`, plan D32): `backupset.backup_finish_date` is stored in local time, so a `SYSUTCDATETIME()`-based comparison — the natural grab, since every other timestamp in the design is UTC — would widen the 1-h log threshold to ~3 h under CEST; a gotcha comment in the proc header pins this. **The target list is validated at run time** (plan D32): tokens are `TRIM()`ed, and any token without an ONLINE match in `sys.databases` (typo, stray whitespace, OFFLINE/RESTORING database, or a mistaken Ola scope token) raises the same `THROW 51100` with the token in the message — an unknown watch target is an alarm, never a silent skip, because a silently unchecked production DB would be indistinguishable from a healthy one (the watchdog variant of the F2 pattern). The watchdog is pure metadata, read-only, and never writes or takes backups. (The same job step also runs the maintenance-liveness check `maint.spCheckMaintenanceLiveness` — owned by the sister ADR, D-A5.)
- **Watched set = real, chain-backed DBs only.** Default `eazybusiness, RoboticoOps`, given in the registry's `cDatabases` as a **literal comma-separated DB list** that the proc splits itself — Ola scope tokens (`USER_DATABASES` etc.) are undefined for watchdog rows (see the sister ADR's registry grammar note). The `eazybusiness_tm*` clones are **excluded** — they are SIMPLE-recovery throwaways with no backup chain, so a freshness check there would false-alarm. (They remain fully in scope for CHECKDB and IndexOptimize — see the sister ADR.) Foreign DBs (`ersatzteile_prod*`, `EKL*`, `HbDat001`) are out of the watched set until their backup ownership is confirmed (plan Information Gap; live evidence 2026-07-22: `ersatzteile_prod` and `HbDat001` do sit in the real CBB chain, `EKL`/`ersatzteile_prod_latest` do not). **System DBs: verified and included (plan D41).** A read-only `backupset` probe (2026-07-22) confirmed `msdb`/`master`/`model` in the real CBB chain (daily 03:00 full, `copy_only=0`) — `msdb` is therefore in the watched list (its log check self-skips as SIMPLE); the cutover re-verifies this before relying on it (plan B6 step 3).

## Alternatives Considered

1. **Consolidate backups into Ola `DatabaseBackup`.** One tool for everything, uniform logging. Rejected: requires decommissioning a working CBB chain and rebuilding storage/retention/offsite/restore around Ola — a large, high-risk project orthogonal to fixing maintenance, with no benefit while CBB works.

2. **No backup monitoring at all — trust CBB to self-alert.** Simplest. Rejected: CBB's own alerting is unverified, and we just learned (F2/F6) that "assume it's running" hides multi-month failures. A cheap read-only freshness check is the exact lesson from the outage.

3. **Watch all databases, including tm-clones.** Uniform. Rejected: tm-clones have no chain by design; including them guarantees permanent false alarms that would train the operator to ignore the watchdog.

## Consequences

**Positive:**
- No disruption to a working, proven backup chain; the maintenance project stays small and low-risk.
- The backup chain gains the same liveness guarantee as the maintenance jobs — a silent CBB stop is caught within ~2 hours (hourly check), not at the next failed restore.
- Clear ownership boundary recorded, so nobody later folds backups into Ola "for tidiness".

**Negative:**
- Two systems remain in play (CBB for backups, RoboticoOps/Ola for the rest) rather than one unified tool — a coordination seam a future operator must know about.
- The watchdog encodes CBB's cadence (full < 26 h, log < 1 h) as thresholds; if CBB's schedule changes, the registry columns `nFullMaxHours`/`nLogMaxHours` must be updated (via git + deploy) or the watchdog false-alarms.
- An unresolved alarm repeats **hourly** until fixed (plan D35) — deliberate escalation pressure for a single-operator setup, accepted over a daily reminder; cadence and thresholds stay git-tunable if it ever overwhelms. If CBB serialises log backups during the large 03:00 full, the hourly check may graze the 1-h threshold there — the first prod nights watch for this and raise `nLogMaxHours` to 2 if needed (plan §3.6).

**Failure Modes:**
- **Watched-set drift.** A new production DB added to the instance is NOT auto-watched (the watched set is an explicit list, unlike the dynamic `USER_DATABASES` maintenance scope). Someone must add it to the watchdog row — otherwise its backup chain is unmonitored while it silently looks "fine".
- **copy_only confusion.** `backupset` contains `copy_only=1` fulls (the 18:00 and ad-hoc runs). The watchdog must filter to `is_copy_only=0` for the full-freshness check, or a copy-only run masks a stopped real chain.
- **Watchdog depends on the same Database Mail path** as the maintenance alerts; if Database Mail breaks, both go silent together (noted as an Information Gap in the plan).
- **RoboticoOps starts unwatched-by-CBB at cutover.** Until CBB's backup set includes RoboticoOps (an explicit cutover-runbook step), the watchdog alarms hourly for it — deliberately: the alarm *is* the detector for the missing coverage, and the hourly cadence makes it unignorable, so the CBB step is finished on cutover day itself. Operators must treat it as an action item, not noise to be silenced.

## References

- **Related Plan:** [mssql-wartung-ola](../plans/2026-07-21 - mssql-wartung-ola/mssql-wartung-ola.md) (bidirectional).
- **Research:** [6-wartung-ist-analyse](../plans/2026-07-10 - mssql-ops-infrastruktur/research/6-wartung-ist-analyse/6-wartung-ist-analyse.md) §2 (F1), §3.2 (backup-time distribution).
- **Related ADRs:** [adr-maintenance-as-code-roboticoops](0001-maintenance-as-code-roboticoops.md) (parent suite; owns the registry and the tm-clone maintenance scope).

## Decision History

### 2026-07-21 — Initial proposal

**Trigger:** Design session — deciding whether the new maintenance suite should also own backups, given CBB already runs them.

**Before:** Implicit assumption (survey) that "prod has a functioning backup chain" with no independent verification; Ola `DatabaseBackup` procs installed but dormant.

**After:** CBB stays the sole backup owner; no Ola backup job; a read-only `maint.spCheckBackupChain` watchdog guards chain freshness for `eazybusiness` + `RoboticoOps`, tm-clones excluded.

**Reasoning:** CBB works and re-platforming backups is out of scope and high-risk (alt. 1); but the outage taught that unmonitored liveness is the real danger (alt. 2), so a cheap metadata watchdog is the proportionate answer.

### 2026-07-21 — Review refinements (same day)

**Trigger:** Full re-think pass over the draft after Lukas' typing/safety questions on the registry.

**Before:** Watchdog thresholds in a free-form parameter string; Ola's `DatabaseBackup` proc deployed-but-dormant; log-freshness check implicitly applied to every watched DB; alerting mechanism unspecified.

**After:** Thresholds are typed registry columns (`nFullMaxHours`/`nLogMaxHours`); `DatabaseBackup.sql` is not vendored at all (per-object vendoring, see sister ADR); the log check skips SIMPLE-recovery DBs; the watchdog alarms by failing its job step (`NotifyOperator` mail); RoboticoOps' initial CBB gap is documented as a self-announcing cutover item.

**Reasoning:** Making the unused backup proc undeployable turns the "no Ola backups" boundary from convention into guarantee; the SIMPLE-skip and `is_copy_only` filter remove the false-alarm sources that would train operators to ignore the watchdog.

### 2026-07-21 — Quality-gate consolidation (7-agent plan review)

**Trigger:** The plan's quality gate flagged two watchdog underspecifications owned by this ADR: how the watched set is expressed in the shared `cDatabases` registry column, and the missing error-number allocation for the stale-chain alert.

**Before:** The watched set was described only as "default `eazybusiness, RoboticoOps`" without naming the grammar — the same registry column carries Ola `@Databases` expressions for the other operations, so an Ola token in a watchdog row was a latent, undefined-behaviour trap. The alert was "failing its job step" without an allocated error number (the migration lint requires chain-unique 5-digit THROW numbers).

**After:** The watched set is a **literal comma-separated list** the proc splits itself; Ola scope tokens are explicitly undefined/invalid for watchdog rows. The stale-chain alert throws **error `51100`**, allocated in the migration lint's THROW table. (Test-target note, owned by the plan: on test1 there is no CBB chain, so the watchdog is *expected red* there and is accepted via a direct logic test instead of a green job run — plan §3.5.)

**Reasoning:** Naming the grammar removes the one place where the registry's two `cDatabases` micro-languages could be confused, and the lint-allocated THROW number keeps chain-wide error numbers unique — both make the watchdog implementable without guessing, with no change to the decision itself.

### 2026-07-21 — Quality-gate round 2 (deep mode) — consolidator pass

**Trigger:** Second quality-gate round flagged two edge underspecifications in the watchdog decision: the log-freshness check was scoped to "FULL-recovery only", silently skipping BULK_LOGGED databases (SEC-3-6), and the threshold comparison left the boundary case (age exactly = threshold) undefined, making the plan's required threshold test non-deterministic (SEC-1-3).

**Before:** "The log check applies only to FULL-recovery databases"; thresholds stated as "< 26 h / < 1 h" without fixing whether an age exactly at the threshold alarms.

**After:** The log check applies to all log-based recovery models (`recovery_model_desc <> N'SIMPLE'`, i.e. FULL + BULK_LOGGED); the alarm fires at `age >= threshold` (plan D27, AC5).

**Reasoning:** BULK_LOGGED keeps a log chain and is backed up by log backups — excluding it would reproduce, for a future foreign DB, exactly the silent-unmonitored pattern this watchdog exists to prevent; for the current watched set (both FULL) the change is behaviour-neutral. Pinning `>=` costs one word and makes the boundary assertion of the threshold test writable.

### 2026-07-21 — Quality-gate round 2 (deep mode) — technical deep-dive pass (FT findings)

**Trigger:** The deep-mode technical analyst mentally executed the watchdog's data path and found two silent-wrong-result hazards: `msdb.dbo.backupset` stores **local server time** while every other timestamp in the design uses `SYSUTCDATETIME()` — priming an implementation whose 1-h log threshold would effectively become ~3 h under CEST (FT-4); and the split-then-join target resolution silently skips any token that matches no database — a typo, stray whitespace after the comma, an OFFLINE/RESTORING DB, or a mistaken Ola scope token would leave a production DB unwatched while the job runs green (FT-9).

**Before:** The freshness comparison named no time base; an Ola token in a watchdog row was "undefined/invalid" with no specified runtime behaviour, and unknown or non-ONLINE targets fell out of the check silently.

**After:** Age arithmetic is pinned to local server time (`SYSDATETIME()`, gotcha comment in the proc header); the target list is validated at run time — `TRIM()`ed tokens, and any token without an ONLINE match in `sys.databases` raises `THROW 51100` with the token in the message (plan D32).

**Reasoning:** Both fixes close gaps where the watchdog would look healthy while guarding nothing — the exact silent-failure class (F2/F6) that motivated it. Turning "undefined" into a loud runtime error also resolves the registry's dual-grammar risk for watchdog rows without a schema split (the sister plan's documented trade-off).

### 2026-07-22 — Quality-gate round 2 (deep mode) — feature-intent pass (FI findings)

**Trigger:** The deep-mode intent analyst measured the watchdog against the freshness intent and the research evidence: a daily 08:00 probe against a 1-h log threshold yields up to ~24 h detection latency — the "log < 1 h" promise held only at the moment of the probe (FI-3) — and the "backups are not a gap" conclusion (F1) is evidenced only for `eazybusiness`, leaving the system DBs (`msdb`/`master`) unverified and unwatched while the plan removes the old — never-run — `SYSTEM_DATABASES` backup jobs and makes `msdb` operationally valuable (FI-2).

**Before:** The watchdog ran daily at 08:00; the watched-set decision addressed tm-clones and foreign DBs but was silent on system DBs; the consequences did not name the detection latency or alarm cadence.

**After:** The watchdog runs **hourly** (00:00 anchor, plan D35) — detection of a torn log chain within ~2 h; an unresolved alarm now repeats hourly (recorded as a deliberate escalation consequence, with the 03:00-full-window false-positive watch and `nLogMaxHours` tuning path noted). The watched-set decision records the system DBs as **pending verification**: the cutover verifies CBB's `msdb`/`master` coverage and either adds `msdb` to the watched list or escalates (plan D37/Gap 6). The RoboticoOps cutover failure mode reflects the hourly cadence; the watchdog job step additionally runs the sister ADR's maintenance-liveness check.

**Reasoning:** The watchdog is the chain's only detector, so its own sampling latency must match the freshness it asserts — hourly is the cheapest cadence that makes the 1-h threshold meaningful, and the schedule-model extension had to land before the `up/` freeze. For the system DBs, the same lesson as F2/F6 applies one level up: an unverified assumption ("CBB surely covers msdb") is exactly the silent-gap pattern this ADR exists to prevent — verification plus an explicit decision beats silent non-coverage.

### 2026-07-22 — Gap closure: system-DB coverage verified, msdb watched

**Trigger:** Closing the plan's open items after the round-2 quality gate: Gap 6 (is `msdb`/`master` covered by CBB?) and Gap 5.1 (foreign DBs in the active maintenance scope).

**Before:** System DBs were recorded as *pending verification* — the cutover would probe CBB's coverage and either add `msdb` to the watched list or escalate; foreign-DB scope inclusion was an open user decision.

**After:** A read-only `backupset` probe on vm-sql2 (2026-07-22) confirmed `msdb`, `master` and `model` in the real CBB chain (daily 03:00 full, `copy_only=0`). `msdb` is now part of the watched set (registry row `eazybusiness,RoboticoOps,msdb`; plan D41); the cutover step becomes a re-verification. Lukas decided (plan D40) that foreign DBs stay in the active CHECKDB/IndexOptimize scope — the watchdog's watched set is unaffected; foreign-DB *watching* remains a follow-up task, now with evidence (`ersatzteile_prod`/`HbDat001` chain-backed, `EKL`/`ersatzteile_prod_latest` not).

**Reasoning:** Verification beat assumption at the cost of one metadata query — the exact remedy this ADR prescribes for silent gaps. Adding `msdb` now (rather than at cutover) keeps the immutable seed migration complete and makes the watchdog guard the database this whole suite depends on from day one.

### 2026-07-23 — Promoted + Accepted

**Trigger:** Plan `mssql-wartung-ola` implementation completed, E2E-verified and accepted; the plan-scoped ADR is promoted alongside its sister ADR-0001 per `lifecycle-adr.md` §"Plan-scoped ADRs".

**Before:** `Proposed (plan-scoped — pending promotion)`, filename `adrs/adr-backups-cbb-retained.md` inside the plan folder, header carrying the `ADR-NNNN` placeholder.

**After:** Moved to `docs/decisions/0002-backups-cbb-retained.md`, `ADR-NNNN` → `ADR-0002`, `Status: Accepted`. The sister-ADR link (now `0001-maintenance-as-code-roboticoops.md`), the plan link, and the research link were re-based to the `docs/decisions/` depth.

**Reasoning:** The backup-chain watchdog is implemented, deployed to test1, and accepted; the scope boundary (CBB owns backups, maintenance monitors the chain) is in effect and no longer plan-scoped. Promoted together with ADR-0001 so the cooperating pair keeps consistent, navigable addresses.
