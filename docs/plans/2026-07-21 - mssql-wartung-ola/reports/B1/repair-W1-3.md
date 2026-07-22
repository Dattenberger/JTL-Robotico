# Repair W1-3 — L-B1-1 backup-chain age test

**Date:** 2026-07-22T21:57:00+02:00
**Agent:** repair-fix (implement-long-plan-v3)
**Cluster:** L-B1-1 (Important, green)

## Finding L-B1-1 — fixed

`maint.spCheckBackupChain` used `DATEDIFF(HOUR, lastBackup, @dNow) >= threshold`
for both the FULL (L77) and LOG (L92) freshness tests. `DATEDIFF(HOUR)` counts
the number of clock-hour boundaries crossed, not elapsed hours: a log backup only
minutes old but landed in the previous clock-hour scores `1 >= 1` and fires a
false `THROW 51100` STALE alarm. With the seeded `nLogMaxHours=1`, eazybusiness
in FULL recovery, hourly CBB log backups and the hourly watchdog cadence (D35),
this recurs in the normal steady state on the production ERP DB.

### What I did

- **`db-migrations/global/sprocs/maint.spCheckBackupChain.sql`**
  - L77 (FULL): `DATEDIFF(HOUR, f.dLastFull, @dNow) >= @FullMaxHours`
    → `f.dLastFull <= DATEADD(HOUR, -@FullMaxHours, @dNow)`.
  - L92 (LOG): `DATEDIFF(HOUR, l.dLastLog, @dNow) >= @LogMaxHours`
    → `l.dLastLog <= DATEADD(HOUR, -@LogMaxHours, @dNow)`.
  - Extended the `-- Freshness …` header comment to document the elapsed-time
    cutoff and why `DATEDIFF(HOUR)` is wrong, so the bug cannot be reintroduced.

  This mirrors the correct `DATEADD` elapsed-time cutoff already used by the
  sibling proc `maint.spCheckMaintenanceLiveness` (L59-62), confirming the
  original `DATEDIFF` was an inconsistency/oversight. Boundary semantics (AC5/D27:
  age exactly `= threshold` alarms) are preserved — `dLast = now − threshold`
  satisfies `dLast <= DATEADD(HOUR, -threshold, now)`; `NULL` (NEVER) still alarms
  via the retained `IS NULL` branch.

- **`docs/plans/2026-07-21 - mssql-wartung-ola/mssql-wartung-ola.md`** (§AC5, line 42)
  Corrected the acceptance-criterion formula from
  `DATEDIFF(HOUR, letztes_full, now) >= nFullMaxHours` (and the log twin) to the
  elapsed-time cutoff `letztes_full <= DATEADD(HOUR, -nFullMaxHours, now)`
  (and log twin), with a one-line rationale referencing L-B1-1. This is the
  plan-deviation half of the finding: §AC5 literally prescribed the flawed
  `DATEDIFF` formula, so the plan is corrected in lockstep with the impl.
  The D27/D32 decision rows and §3.2 reference (line 203) state only the
  `age >= threshold` boundary semantics, which remain valid unchanged — no edit
  needed there.

## Verification

- `npm run db:lint` → **OK: 0 errors, 2 warning(s)**. The 2 warnings are
  pre-existing and unrelated (`reset.spInternal_GrantAccess.sql` dynamic-SQL
  concatenation), not touched by this fix.

## Self-check

Re-read the diff: both age tests converted, `IS NULL` branches retained
(NEVER still alarms), boundary case preserved per AC5, `@dNow` unchanged
(`SYSDATETIME()` local time base D32 intact). Plan AC5 formula now matches the
impl. No regressions; no imports affected (T-SQL). Finding fully addressed.

## Skipped

none

## Files modified

- `/home/lukas/WebStorm/JTL-Robotico/worktrees/feature/mssql-ops-infrastruktur/db-migrations/global/sprocs/maint.spCheckBackupChain.sql`
- `/home/lukas/WebStorm/JTL-Robotico/worktrees/feature/mssql-ops-infrastruktur/docs/plans/2026-07-21 - mssql-wartung-ola/mssql-wartung-ola.md`

## Drift

none — both edits are in scope: the impl file is the finding's named file; the
plan AC5 edit is the plan-deviation half the finding explicitly requires ("route
the fixer as a plan-deviation decision … requires a matching correction to the
plan's AC5 formula").
