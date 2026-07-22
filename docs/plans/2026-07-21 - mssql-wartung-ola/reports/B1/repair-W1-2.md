# Repair W1-2 — validate_rollout maintenance registry completeness

**Date:** 2026-07-22T21:57:00+02:00
**Agent-ID:** repair-W1-2
**Finding:** T-1 (green, Important)

## Finding fixed — T-1

**Problem:** The maintenance operability gate in `db-migrations/tests/global/validate_rollout.sql`
drove its check loop FROM `ops.tMaintenanceJob` (LEFT JOIN to `msdb.dbo.sysjobs`) and never
asserted that the six canonical seed rows exist. An empty or partial registry left the loop with
nothing to iterate and reported OK — asymmetric with the sibling reset-step block (L54-75), which
drives from a named `expected` CTE so a missing row is caught.

**Fix:** Added a named `expected` CTE of the six `cJobKey`/`cDisplayName` pairs, inserted inside
the `ELSE BEGIN` block (where `ops.tMaintenanceJob` is known to exist), before the existing per-row
operability loop. The CTE LEFT JOINs to `ops.tMaintenanceJob` on `cJobKey` and flags any expected
row that is missing, mirroring the reset-step block. The existing per-row job/enabled/notify loop is
unchanged.

- SSoT for the six pairs: the `src` VALUES list in
  `db-migrations/global/runAfterOtherAnyTimeScripts/maint.spApplyMaintenance.sql` (L41-47, "plan §3.2 = SSoT"):
  `checkdb`, `index-optimize`, `cleanup-commandlog`, `cleanup-backuphistory`, `cleanup-jobhistory`, `backup-watchdog`
  (display name = `RoboticoOps - Maint - ` + key).
- New block: `db-migrations/tests/global/validate_rollout.sql` L139-153 (post-edit).

## Skipped findings

none

## Files modified

- `/home/lukas/WebStorm/JTL-Robotico/worktrees/feature/mssql-ops-infrastruktur/db-migrations/tests/global/validate_rollout.sql`

## Tests

`npm run db:lint` → OK: 0 errors, 2 warning(s) (both pre-existing, in
`reset.spInternal_GrantAccess.sql`, unrelated to this change). The edited file lives under `tests/`
and is exempt from the migration lint; it parses clean. Live `sqlcmd` structure_check against test1
requires a deployed instance and was not run (outside this repair's reach).

## Drift

none
