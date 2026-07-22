# Block B1 — AUDIT-TEST (topic: test)

**Date:** 2026-07-22T21:57:00+02:00
**Block:** B1 · **Range:** `d722993..HEAD` (217314a)
**Verdict:** tests are correct and green; one coverage-parity gap in the operability gate.

## Test convention for this repo (Step 0)

This is a T-SQL migration repo with **no proc-level unit-test harness**. The
project's test convention is:

1. **`npm run db:lint`** (`tests/lint-migrations.ps1`) — static convention lint,
   incl. rule (l) "every `global/` proc is registered in `validate_structure.sql`".
   This is the `test_command` per `CONVENTIONS`.
2. **`tests/global/validate_structure.sql`** — read-only structural gate (objects,
   columns, signatures, roles). Also run automatically by the E2E docker container
   (`db:e2e:validate`).
3. **`tests/global/validate_rollout.sql`** — post-rollout operability gate (msdb
   jobs/operator wiring, journals, signed procs).
4. **Manual live verification on test1** — the plan explicitly assigns the behavioral
   ACs (AC5 watchdog thresholds, AC13 liveness, AC7 idempotency/MERGE no-op, AC10
   statistics, AC3 removal path) to a **manual B5 checklist run live on test1**, not to
   automated tests. This is the plan's deliberate strategy (§2, ACs 5/9/10/13 say
   "verifiziert per … auf test1 (B5)"), so the absence of re-runnable behavioral
   proc-tests is **by design**, not a defect.

The block's "tests" changed here are the two validate_*.sql gates. Audited against
that convention, not a unit-test preference.

## Step 1 — static quality of the test diff

Both gates were extended cleanly and idiomatically:

- **`validate_structure.sql`**: adds `ops.tMaintenanceJob` (+ 14 key columns), the 5
  `maint.*` procs and `maint.spApplyMaintenance` to the required-objects VALUES list.
  Object types correct — verified each is `CREATE OR ALTER PROCEDURE` / `CREATE TABLE`
  (`spApplyMaintenance` is a real proc → `'P'` is right even though it lives in
  `runAfterOtherAnyTimeScripts`). Column list covers all functional columns; only the
  metadata trio (`cNotes`, `dCreated`, `dModified`) is omitted — acceptable as
  non-"Schlüsselspalten" per AC11.
- **`validate_rollout.sql`**: new maintenance block mirrors the existing reset-job block.
  The D34 enabled-equation asserted here
  (`sj.enabled = (bEnabled=1 AND MaintenanceSchedulesEnabled<>'0')`) **exactly matches
  the implementation** in `maint.spEnsureMaintenanceJobs.sql:92` — the gate cannot go
  green on a wrong deploy nor red on a correct one. Notify-wiring assertion
  (`notify_level_email=2` + operator `RoboticoOps-Maint`) matches the sync's output
  (`spEnsureMaintenanceJobs.sql:93-94`). NULL-handling in the WHERE/CASE for a missing
  job is sound (`sj.job_id IS NULL` wins the CASE; the `IS DISTINCT FROM` operator term
  degrades correctly).
- No mock/helper machinery applies (SQL gates). No undocumented production-code changes
  in the diff (`test-undocumented-code-fix`: none). THROW numbers referenced by the ACs
  (51100/51105/51110/51120) are allocated in README §4 and used by the procs (51110
  intentionally reserved).

## Step 2 — dynamic

- **`npm run db:lint`: PASS — 0 errors, 2 warnings.** Both warnings are pre-existing in
  `reset.spInternal_GrantAccess.sql` (dynamic-SQL concatenation), unrelated to B1.
  Rule (l) passing confirms all 5 maint procs are registered in the structure gate.
- **No branch-coverage tooling exists for T-SQL** — not applicable; the 80% threshold in
  the AUDIT-TEST rubric has no meaning here.
- **Cross-chunk regressions: none.** The diff only *appends* rows to existing VALUES
  lists and adds one new self-contained block; no existing assertion was modified, so
  no previously-green check can turn red. Single-chunk block, so no inter-chunk path was
  touched.
- The full live gate run (both validate scripts green on test1 with switch `'0'`) is
  reported in the C1 chunk summary; the equation-parity check above confirms that green
  is meaningful.

## Findings

### T-1 (Important) — operability gate does not assert the canonical registry rows exist

`validate_rollout.sql` maint block drives its loop **from whatever rows happen to be in
`ops.tMaintenanceJob`** (`FROM ops.tMaintenanceJob m LEFT JOIN sysjobs …`). It never
asserts that the six canonical seed rows (`checkdb`, `index-optimize`,
`cleanup-commandlog`, `cleanup-backuphistory`, `cleanup-jobhistory`, `backup-watchdog`)
are present. If the registry is empty or lost rows, the loop iterates zero/fewer rows and
the block still reports **OK** (only the standalone operator-EXISTS check would fire).

This is asymmetric with the sibling **reset-step block** in the same file (lines 54-75),
which drives from a named `expected` list precisely so a *missing* row is caught — the
project's own established pattern. It is also squarely the failure mode the whole plan
exists to prevent (F3/F4 "job silently not there / never runs", plan §1): a registry that
silently lost its seed → zero maintenance jobs → gate green.

Practical probability is **low**: `spApplyMaintenance` MERGEs all six rows on every deploy
inside grate's transactional everytime stage, so a completed deploy guarantees the seed;
the hole only manifests on manual row deletion or a partial-failure state. AC12's text is
also literally satisfied ("for every registry row a job exists"). But the reset-step block
sets the convention that the rollout gate should assert canonical rows exist regardless of
the deploy-time seed, and this block breaks from it.

**Suggested fix:** add a named-`expected` CTE of the six `cJobKey`/`cDisplayName` pairs
(SSoT = plan §3.2 / the `spApplyMaintenance` MERGE) and flag any missing from
`ops.tMaintenanceJob`, mirroring the reset-step block. Keeps the per-row job/wiring loop
as-is.

## Files reviewed
- db-migrations/tests/global/validate_structure.sql
- db-migrations/tests/global/validate_rollout.sql
- db-migrations/global/sprocs/maint.spEnsureMaintenanceJobs.sql (equation cross-check)
- db-migrations/global/runAfterOtherAnyTimeScripts/maint.spApplyMaintenance.sql (seed cross-check)

Drift outside scope: none.
