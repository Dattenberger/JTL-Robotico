# Doc Worker Report — `testsystem-readme`

**Date:** 2026-07-10T02:45:00+02:00
**Action:** update
**Target:** `Projekte/Testsystem/README.md`
**Sources reconciled:** `Projekte/Testsystem/setup-test-environment.ps1`,
`db-migrations/global/sprocs/reset.StartTestmandantReset.sql`

## Outcome

`augmented` — one accuracy fix. The README was authored during this plan and was
already well-aligned with the shipped code; the primary verification (the "use the new
reset instead" pointer names the real entry point) passed, so this was a reconcile pass,
not a rewrite.

## Verification performed (all pass)

- **Entry point** `RoboticoOps.reset.StartTestmandantReset @MandantKey = N'tm4'` matches
  SP `reset.StartTestmandantReset` (param `@MandantKey sysname`), deployed in DB
  `RoboticoOps` — confirmed via `db-migrations/targets.config.json`
  (`"global": "RoboticoOps"`) and `docs/SQL/MSSQL-OPS-ARCHITECTURE.md`.
- **Poll SP** `RoboticoOps.reset.GetResetStatus @MandantKey = N'tm4'` matches
  `reset.GetResetStatus` (accepts `@RequestId int = NULL, @MandantKey sysname = NULL`).
- **Mapping table** — every `reset.internal_*` target exists on disk, including the new
  `reset.internal_NeutralizeWorker.sql` (D9). No stragglers or renames after repair.
- **Cross-reference links** (`MSSQL-OPS-ARCHITECTURE.md`,
  `testmandant-reset-validierung.md`, `rollout-mssql-ops.md`) all resolve to existing
  files.

## Changes applied

| Section | Change |
|---|---|
| "What this folder is" (numbered script list) | Added `register-mandant.sql` as step 5 (register the clone in `dbo.tMandant`), renumbered `JTL-Rollen.sql` to 6. The `.ps1` runs `register-mandant.sql` between `grant-database-access` and `JTL-Rollen` (lines 197-208), and the mapping table below already listed it — the numbered "runs in order" list was the only place it was missing. |

No sections added or removed. Voice, structure, and cross-references preserved.

## Files modified

- `Projekte/Testsystem/README.md` (one edit)

## Files outside assigned scope (drift)

none

## Notes for final

- none (all cross-doc links verified as resolving; no contradictions with sibling docs
  observed for this target).
