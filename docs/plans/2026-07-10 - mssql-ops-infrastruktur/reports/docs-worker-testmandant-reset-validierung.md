# Doc Worker Report — testmandant-reset-validierung

**Date:** 2026-07-10T02:45:00+02:00
**Action:** `update`
**Target:** `docs/runbooks/testmandant-reset-validierung.md`
**Source files reconciled against:**
- `db-migrations/global/sprocs/reset.StartTestmandantReset.sql`
- `db-migrations/global/sprocs/reset.GetResetStatus.sql`
- `db-migrations/global/runAfterOtherAnyTimeScripts/reset.EnsureAgentJob.sql`
- `db-migrations/global/up/0002_ops_schema_tables.sql`

All four source files were **added** by this plan (`git diff 9592c99..HEAD` = 259
insertions, no prior versions), so the shipped code is the reconcile target.

## Substantive finding — runbook contradicted a shipped CHECK constraint

`0002_ops_schema_tables.sql` ships
`CONSTRAINT CK_ops_Mandant_MandantKey CHECK (MandantKey LIKE 'tm[0-9]%')` on
`ops.Mandant`. The runbook seeded its throwaway validation mandant under the key
**`tmv`** (the `v` standing for "validation"). `tmv` does **not** match
`tm[0-9]%` — the third character must be a digit — so the Step 1 seed `INSERT`
would be rejected at insert time and the happy-path runbook could never run as
written.

**Fix:** renamed the validation mandant to **`tm9`** (a high `tm<digit>` number
that satisfies the constraint and won't collide with the real `tm1`/`tm2`
mandants). Replaced every `tmv` / `eazybusiness_tmv` occurrence with
`tm9` / `eazybusiness_tm9` across Steps 1–6, the failure modes, and the
open-question table.

## Changes applied per section

| Section | Change |
|---|---|
| Step 1 body (§Seed) | Reworded the mandant introduction: `tmv` → `tm9`, dropped the "(validation mandant)" gloss that motivated the invalid `v`, added the "high number won't collide" rationale. |
| Step 1 `[!NOTE]` | Expanded from a TargetDb-only note to cover **both** shape constraints. Now states `MandantKey` must match `tm[0-9]%` (`CK_ops_Mandant_MandantKey`), names `tmv` as the rejected example, and keeps the existing TargetDb guard text. |
| Steps 3, 4, 5, 6 + failure modes | Mechanical `tmv`→`tm9`, `eazybusiness_tmv`→`eazybusiness_tm9`. |

## Reconcile points that already matched shipped code (no change)

- SP names `reset.StartTestmandantReset`, `reset.GetResetStatus` and the Step 0
  `sys.procedures` probe — match.
- `StartTestmandantReset` return shape `RequestId, Status='queued'` — matches SP body.
- `GetResetStatus` parameters `@RequestId`/`@MandantKey` — match.
- Agent-job name `RoboticoOps - Testmandant Reset` — matches `EnsureAgentJob`.
- State machine `queued → running → succeeded | failed` — matches the
  `CK_ops_ResetRequest_Status` constraint and the `UX_ResetRequest_Active`
  filtered index.
- TargetDb triple-guard (CHECK + Start-SP validation + job re-validation) — matches
  `CK_ops_Mandant_TargetDb` plus the Start-SP `THROW 51003` check.
- Failure-mode "Start-SP refuses a new one" — matches the Start-SP
  `THROW 51004` on an existing `queued`/`running` request for the TargetDb
  (keyed on TargetDb, 1:1 with the mandant, so the runbook phrasing holds).

The `StepLog` step list and the "reclaims running rows older than 4h" claim live
in `reset.ProcessNextResetRequest` (outside this worker's source set) and cite
plan §3 — left untouched.

## Files touched

- `docs/runbooks/testmandant-reset-validierung.md`

## Notes for final

- The runbook cross-links `db-migrations/README.md`, two `probes/*.sql`, and one
  `probes/02_worker_discovery.md`. Relative paths were not changed; the final
  agent should confirm those probe filenames still resolve (probes are outside
  this worker's source set).
- Sibling runbook `rollout-mssql-ops.md` is the "same seed mechanism" this
  runbook defers to for seeding `ops.Mandant`. If that runbook documents a
  concrete seed key/example, the final agent should confirm it also respects the
  `tm[0-9]%` `MandantKey` shape so the two runbooks don't drift.
