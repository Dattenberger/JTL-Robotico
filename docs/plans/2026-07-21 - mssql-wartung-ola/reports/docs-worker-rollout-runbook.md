# Doc Worker — rollout-runbook (update)

**Date:** 2026-07-23T00:05:00+02:00
**Target:** `docs/runbooks/rollout-mssql-ops.md`
**Action:** update (verification/consistency pass)
**Plan-start commit:** `d722993ae64b0a7e0dbcb5fd37fa8c6a7e7180a9`
**Agent:** doc-worker rollout-runbook (implement-long-plan-v3)
**Outcome:** `no-change-needed`

## Summary

The runbook's maintenance-cutover content (Phase 4a + Phase 4b) was already woven in
during implementation (single commit `923b6c7 [B1.C1] …`). This run was a fresh-eyes
verification of every load-bearing claim in Phase 4a/4b against the four assigned
source files plus the registry seed and dispatch proc. All claims match the shipped
code — no stale text, no false claims, no leftover placeholders. No edit applied.

## Verification performed (claim → source evidence)

| Runbook claim | Source | Result |
|---|---|---|
| Six `RoboticoOps - Maint - *` agent jobs, immediately enabled + scheduled | `maint.spApplyMaintenance.sql` seed: 6 rows (`checkdb`, `index-optimize`, `cleanup-commandlog`, `cleanup-backuphistory`, `cleanup-jobhistory`, `backup-watchdog`), all `bEnabled=1` | consistent |
| backup-watchdog stale mail = THROW 51100 → operator | `maint.spCheckBackupChain.sql` (both alarm paths THROW 51100; module header §"THROW allocation") | consistent |
| Each job's single step = `EXECUTE RoboticoOps.maint.spRunMaintenanceJob @cJobKey = …` (D28) | `maint.spRunMaintenanceJob.sql` param `@cJobKey sysname`; header usage line identical | consistent |
| Operator wiring on every `bNotifyOnFail=1` job; `260` pulls it in after operator creation | `260_maintenance_operator.sql` (operator create → unconditional `spEnsureMaintenanceJobs`); all 6 seed rows `bNotifyOnFail=1` | consistent |
| Freshly assigned Database-Mail profile (`permissions/260`) needs an agent restart | `260_maintenance_operator.sql` GOTCHA + PRINT "takes effect only after a SQL-AGENT RESTART" | consistent |
| Database-Mail profile name `Standard SMTP`, guarded when profile absent | `260_maintenance_operator.sql` §2 (`@cProfile = N'Standard SMTP'`, existence guard, no THROW) | consistent |
| `MaintenanceSchedulesEnabled` = instance state, unset = enabled (D34); operator identity repo-owned | `260_maintenance_operator.sql` DELIBERATE-deviation note (R2/D34) | consistent |
| backup-watchdog runs hourly, watches `eazybusiness,RoboticoOps,msdb`; RoboticoOps not-yet-in-CBB → alarm fires | seed row `backup-watchdog` cadence `hourly`, DB list `eazybusiness,RoboticoOps,msdb` | consistent |
| `nLogMaxHours` default 1, adjust to 2 on false alarm; local time base | seed row `nLogMaxHours` = 1; `maint.spCheckBackupChain.sql` GOTCHA (SYSDATETIME local base) | consistent |
| `validate_rollout.sql` as the go-live check | `db-migrations/tests/global/validate_rollout.sql` exists (per discovery §1) | consistent |

## Changes applied

None. Sections unchanged, none added, none removed.

## Notes for final

- The runbook is internally consistent with the DATA-MODEL / NAMING / ARCHITECTURE /
  README counts noted in the discovery report (5 `maint.*` procs · 6 jobs · THROW
  block 51100–51129) — no cross-doc contradiction observed from the runbook side.
- Two operational facts in Phase 4a ("11 legacy Ola jobs", "9,218 CommandLog rows") are
  prod-estate observations, not code-derivable — left as-is; they are the deployer's
  inventory step, correctly framed as a manual runbook action.
- ADR back-links in the runbook point at plan-scoped ADR paths (`{plan}/adrs/…` via
  D-references, not direct links); if the plan's closure step promotes those ADRs to
  `docs/decisions/NNNN-…`, no runbook link needs rewriting (the runbook references them
  by decision-ID D-number, not by file path). No action for the final agent.
