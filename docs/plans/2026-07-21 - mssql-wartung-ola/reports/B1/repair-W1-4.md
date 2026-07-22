# Repair Wave W1-4 — report

**Date:** 2026-07-22T21:57:00+02:00
**Cluster:** convention-B1-2 (green / Nice-to-have)
**File:** `db-migrations/global/permissions/260_maintenance_operator.sql`

## Finding convention-B1-2 — fixed

The four operational `PRINT` messages in `260_maintenance_operator.sql`
anchored on the migration file number (`260:` / `! 260:`), the sole
file-number-anchored style in `permissions/`. Every sibling anchors on the
object instead (verified by grep):

- `200_ensure_agent_job.sql` → `! Agent job [...] missing — recreating ...`
- `250_jobstartuser_mapping.sql` → `! RoboticoOps jobstartuser was orphaned ...`
- `100_grants.sql` → `! Login [...] not found ...`
- `900_resign_procedures.sql` → `Re-signed ... ` (plain, non-`!`, for success)

Applied fix — dropped the `260:` file-number prefix on all four; each message
already names its object, and the `!`-vs-plain warning/success distinction is
preserved to match the sibling style:

| Line | Before | After |
|---|---|---|
| 45 | `'260: created SQL-Agent operator [RoboticoOps-Maint].'` | `'Created SQL-Agent operator [RoboticoOps-Maint].'` |
| 56 | `'! 260: Database-Mail profile [Standard SMTP] does not exist ...'` | `'! Database-Mail profile [Standard SMTP] does not exist ...'` |
| 78 | `'! 260: agent mail profile set to [Standard SMTP] ...'` | `'! Agent mail profile set to [Standard SMTP] ...'` |
| 90 | `'! 260: maint.spEnsureMaintenanceJobs missing ...'` | `'! maint.spEnsureMaintenanceJobs missing ...'` |

Cosmetic only; no behavioural change. Now greppable alongside the rest of the
operational output.

## Tests

`npm run db:lint` → OK: 0 errors, 2 warnings. Both warnings are pre-existing and
in an unrelated file (`db-migrations/global/sprocs/reset.spInternal_GrantAccess.sql`,
dynamic-SQL concatenation notices) — not touched by this change.

## Skipped

None.

## Files modified

- `/home/lukas/WebStorm/JTL-Robotico/worktrees/feature/mssql-ops-infrastruktur/db-migrations/global/permissions/260_maintenance_operator.sql`

## Drift

none
