# Block Audit — B1 · Topic: plan-and-api

**Date:** 2026-07-22T21:57:00+02:00 · **Block:** B1 (whole plan scope B1–B5, chunk C1) · **Agent:** block-audit / plan-and-api
**Baseline:** `d722993ae64b0a7e0dbcb5fd37fa8c6a7e7180a9`..HEAD (`217314a`)
**Grounding loaded:** `knowledge-jtl-sql`, `knowledge-sql` (companion).

## Scope

Topic covers: (a) plan fidelity — implementation vs. plan §2 (AC1–AC13) and §3.1–§3.6, cross-checked against the C1 deviation tables; (b) stubs / placeholder returns / throw-not-implemented; (c) API-consumer match across the maint.* procs, the vendored Ola procs, the agent job steps, and the two validation gates.

## Coverage

| File | Audited | Notes |
|---|---|---|
| `up/0022_maintenance_ola_vendor.sql` | ✓ (headers + object/param signatures; 5350 lines byte-vendored not line-audited) | 4 objects only (CommandLog table + 3 procs); **no DatabaseBackup object** (only a header comment mentions it); 3 `VENDOR-DEVIATION` byte-breaks marked; upstream version stamp present |
| `up/0023_maintenance_registry.sql` | ✓ | DDL byte-faithful to §3.1 SSoT block incl. every CHECK; `GRANT SELECT`-only |
| `sprocs/maint.spEnsureMaintenanceJobs.sql` | ✓ | closed D31 comparison surface, running-guard, operator-EXISTS guard, prefix removal pass |
| `sprocs/maint.spRunMaintenanceJob.sql` | ✓ | command matrix 1:1 with §3.2; THROW 51120 both paths |
| `sprocs/maint.spCheckBackupChain.sql` | ✓ | target validation + freshness, THROW 51100 |
| `sprocs/maint.spCheckMaintenanceLiveness.sql` | ✓ | D34 gate + CommandType mapping, THROW 51105 |
| `runAfterOtherAnyTimeScripts/maint.spApplyMaintenance.sql` | ✓ | 6 seed rows exact match to §3.2 table; full MERGE lifecycle |
| `permissions/260_maintenance_operator.sql` | ✓ | operator + guarded mail profile + unconditional ensure |
| `tests/global/validate_structure.sql` | ✓ | 5 maint.* procs + table + 14 key columns registered |
| `tests/global/validate_rollout.sql` | ✓ | D34-equation assertion, notify + operator checks |
| `README.md`, DATA-MODEL, NAMING, ARCHITECTURE, runbook | ✓ | doc contract (AC8), THROW allocation (AC11), B6 weave |

## Verdict

Plan fidelity is **complete**. Every AC1–AC13 requirement and every §3.1–§3.6 spec item is present and traceable in the diff. All six documented C1 deviations are defensible D4 calls (not re-litigated). **No stubs, no placeholder returns, no throw-not-implemented** — the two `THROW 51120` branches are real error handling; `51110` is documented as "reserved, unused by design". **API-consumer match verified end-to-end:**

- Agent job step `EXECUTE RoboticoOps.maint.spRunMaintenanceJob @cJobKey = N'…'` ↔ `spRunMaintenanceJob(@cJobKey sysname)` ✓
- Dispatcher → `maint.spCheckBackupChain(@Databases nvarchar(400), @FullMaxHours int, @LogMaxHours int)` ✓ (exact positional/named match)
- Dispatcher → `maint.spCheckMaintenanceLiveness` (parameterless) ✓
- Dispatcher → vendored `dbo.IndexOptimize` (@Databases/@UpdateStatistics/@FragmentationMedium/@FragmentationHigh/@LogToTable — all present in the vendored signature) ✓; the deviation of also pinning `@FragmentationMedium='INDEX_REORGANIZE'` is confirmed **necessary** — Ola's Medium default is `'INDEX_REORGANIZE,INDEX_REBUILD_ONLINE,INDEX_REBUILD_OFFLINE'`, so pinning only High (per the plan's shorthand) would have left an offline-rebuild path open (D13 hole closed).
- Dispatcher → vendored `dbo.DatabaseIntegrityCheck` (@Databases/@LogToTable) ✓
- `validate_structure`/`validate_rollout` object + column names ↔ actual DDL ✓

## Findings

### plan-and-api-B1-1 — Nice-to-have — liveness detectability is coupled to `bUpdateStatistics = 1` (latent)

`maint.spCheckMaintenanceLiveness` (`sprocs/maint.spCheckMaintenanceLiveness.sql:54-63`) considers an `IndexOptimize` row live only if a `CommandLog` row of `CommandType IN ('ALTER_INDEX','UPDATE_STATISTICS')` exists within the window. This is faithful to the plan (D36 explicitly relies on `UPDATE_STATISTICS` logging on **every** run *with `@UpdateStatistics='ALL'`*). But the DDL and the dispatcher deliberately support `bUpdateStatistics = 0` as a "deliberate exception" (`spRunMaintenanceJob.sql:71-78` omits the parameter). For a future `IndexOptimize` registry row with `bUpdateStatistics = 0`, Ola logs no `UPDATE_STATISTICS`, and on a night where no index crosses the 30 % threshold it logs no `ALTER_INDEX` either — the job runs green yet the watchdog would raise a **false `THROW 51105`**. Dormant today (the only IndexOptimize seed row, `index-optimize`, is `bUpdateStatistics = 1`), so no live impact; flagged so a maintainer adding a stats-off IndexOptimize row knows the liveness check must be revisited (e.g. exempt `bUpdateStatistics = 0` rows, or key off a run-marker rather than `UPDATE_STATISTICS`). Leans toward the `logic` topic; surfaced here because it is a plan-design ↔ knob-space consistency gap. Suggested fix: needs a small design decision — either document the coupling in the proc header + the `bUpdateStatistics` column doc, or exclude `bUpdateStatistics = 0` IndexOptimize rows from the liveness scan.

## Out-of-scope observations (for the consolidator)

- **[convention/logic]** `DATEDIFF(HOUR, …)` in `spCheckBackupChain.sql:77,92` counts hour-boundary crossings, not elapsed hours, so the 1 h log threshold can alarm at <60 min elapsed. This is the plan's documented, accepted behaviour (`>=`-boundary alarms, AC5/D27) and the runbook already prescribes bumping `nLogMaxHours` to 2 if the 03:00-full window trips it — **not a defect**, noted only for completeness.
- **[docs]** The plan §3.2 IndexOptimize command-matrix row and NOTE mention only `@FragmentationHigh`; the (correct) implementation also pins `@FragmentationMedium`. Plan-text shorthand, resolved in the C1 deviation table — no code action.

## Nothing else

No plan-fidelity gaps, no stubs, no API-consumer mismatches. The block already passed two internal review passes (C1 impl self-check + C1 fresh-eyes self-fix) and a full live B5 checklist on test1; this external plan-and-api pass confirms them.
