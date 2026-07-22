# Repair W1-1 — report

**Date:** 2026-07-22T21:57:00+02:00
**Agent:** repair-fix (implement-long-plan-v3), block B1
**Cluster:** convention-B1-1, L-B1-3, L-B1-2

## Summary

Applied the two liveness hardening findings (L-B1-3, L-B1-2) as documentation +
query-logic changes to the two **anytime** maintenance sprocs and the data-model doc.
**Skipped convention-B1-1** (German→English translation of `up/0023`) because the target
is an immutable one-time script that has **already been applied to test1** — an in-place
edit would break the next global deploy. Lint is green (0 errors, 2 pre-existing warnings
in an unrelated file).

## Per finding

### L-B1-3 — IndexOptimize stats-off liveness heartbeat (FIXED, research fix A: doc-only)

Research (`research/indexoptimize-liveness-heartbeat.md`) recommended fix A — make the
implicit coupling explicit at every maintainer touch-point, **no behaviour change**.
Applied at three sites:

- `db-migrations/global/sprocs/maint.spCheckMaintenanceLiveness.sql` — header: new
  paragraph after the CommandType-mapping note explaining that IndexOptimize liveness
  relies on the per-run `UPDATE_STATISTICS` heartbeat that only `bUpdateStatistics = 1`
  guarantees; a stats-off row is the F8 anti-pattern and a false-`51105` risk; revisit the
  scan (add run-marker or documented exemption) before enabling one. Query predicate left
  unchanged per the research (keeping `ALTER_INDEX` in the OR can only reduce false alarms).
- `db-migrations/global/sprocs/maint.spRunMaintenanceJob.sql` — `NB (L-B1-3)` comment on
  the `bUpdateStatistics = 0` dispatch branch pointing at the liveness proc header.
- `docs/SQL/MSSQL-OPS-DATA-MODEL.md` — `bUpdateStatistics` row extended with the liveness
  (D36) coupling (`1` → heartbeat visible; `0` → blind edge, revisit liveness first).

### L-B1-2 — liveness first-run grace (FIXED, research design + query change)

Per `research/liveness-first-run-grace.md`, in
`db-migrations/global/sprocs/maint.spCheckMaintenanceLiveness.sql`:

- Added `@dNowUtc = SYSUTCDATETIME()` alongside the existing local `@dNow`, with a
  second-time-base GOTCHA in the header (mirroring the D32 local-time gotcha). `dModified`
  is stored UTC, so the grace comparison must use a UTC clock.
- Added a `CROSS APPLY (SELECT nWindowHours = CASE cFrequency …)` deriving the schedule
  window once per row (26 h daily / 192 h = 8 days weekly), driving **both** the grace floor
  and the staleness floor (removed the previously duplicated inline CASE — DRY).
- Added the grace predicate `AND j.dModified <= DATEADD(HOUR, -w.nWindowHours, @dNowUtc)`
  — a row effectively enabled for less than one window is skipped (cannot be stale yet).
  Expressed as `dModified <= now-window` (not `DATEDIFF >= window`) to avoid DATEDIFF's
  boundary off-by-one, per the research hint.
- Header: first-run-grace rationale added next to the D36 explanation.
- Cross-referenced `dModified`'s new load-bearing role in `docs/SQL/MSSQL-OPS-DATA-MODEL.md`
  (so a future maintainer does not "optimize" the MERGE to stop bumping it).

Correctness re-checked against the research scenario (daily row enabled 10:00 day1, first
run 02:00 day2): within-grace until 12:00 day2 (skipped), `CommandLog` entry from 02:00
onward keeps it fresh — never false-fires, still alarms if the 02:00 run never logs.

### convention-B1-1 — translate up/0023 German comments (SKIPPED — deploy-safety conflict)

The finding's own GOTCHA flagged the immutability window ("land it before the first prod
apply"). Verification shows the constraint is already binding **before prod**: `up/0023`
was applied to **test1** today at `2026-07-22 20:04:59` (confirmed read-only in
`RoboticoOps.ops.ScriptsRun`, `text_hash = YI/pHClE3a8lty4q1Tf3…`). Consequences of editing
it in place:

- `db-migrations/deploy.ps1` runs grate **without** `--warn-on-one-time-script-changes`, so
  a changed one-time script hash makes the next global deploy **error and stop** (the
  QG3-C1 incident shape; README §2 CAUTION / §4 rule i).
- The lint gate (`lint-migrations.ps1` rule i) turns the in-place edit into a hard **ERROR**
  (`npm run db:lint` FAIL). Its acknowledgement hatch (`$upEditAcknowledged`) is explicitly
  gated on the script having "**provably never been applied anywhere**" — which is now
  verifiably false — so acknowledging it would be recording a falsehood and shipping a
  latent deploy-breaker.

The comment-language convention violation is real, but a cosmetic (comment-only) fix does
not justify breaking one-time-script immutability, and the two guardrails (grate + lint)
both forbid it. **The 0023 working-tree edit was reverted** to its committed state; the file
is clean.

**Needs an orchestrator/human decision** (out of a repair agent's scope), options:
1. Accept the German comments in `up/0023` as a frozen historical artifact (it is applied;
   its comments cannot change without a rehash) — recommended, lowest risk.
2. If the team wants English there, it requires a deliberate deploy-tooling action (deploy
   once with `--warn-on-one-time-script-changes` so grate re-hashes, or a controlled test1
   rebaseline) plus the `$upEditAcknowledged` entry — an operational decision, not a lint
   edit a fixer should make silently.

## Files modified

- `/home/lukas/WebStorm/JTL-Robotico/worktrees/feature/mssql-ops-infrastruktur/db-migrations/global/sprocs/maint.spCheckMaintenanceLiveness.sql`
- `/home/lukas/WebStorm/JTL-Robotico/worktrees/feature/mssql-ops-infrastruktur/db-migrations/global/sprocs/maint.spRunMaintenanceJob.sql`
- `/home/lukas/WebStorm/JTL-Robotico/worktrees/feature/mssql-ops-infrastruktur/docs/SQL/MSSQL-OPS-DATA-MODEL.md`

## Drift (outside the cluster's three SQL files)

- `docs/SQL/MSSQL-OPS-DATA-MODEL.md` — not in any finding's `files` list, but the L-B1-3
  suggested_fix explicitly names "the DATA-MODEL contract", and the CLAUDE.md same-commit
  doc contract governs `ops.*` column semantics. Two rows touched (`bUpdateStatistics`,
  `dModified`). Documentation only, no DDL/behaviour change.
- No source/test code touched outside the cluster. `up/0023` was edited then reverted (net
  zero); `lint-migrations.ps1` was **not** modified (I deliberately did not add a false
  acknowledgement).

## Tests

`npm run db:lint` → **OK: 0 errors, 2 warning(s)** (both warnings pre-existing in
`reset.spInternal_GrantAccess.sql`, unrelated to this cluster). No SQL execution test
available for these anytime procs on test1 (proc early-`RETURN`s under
`MaintenanceSchedulesEnabled = '0'`, D34); both changes are doc + registry-only predicate
refinements as the research notes.
