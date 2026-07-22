# Doc Worker Report — migrations-readme

**Date:** 2026-07-23T00:05:00+02:00
**Target doc:** `db-migrations/README.md`
**Action:** update (verification/consistency pass)
**Agent:** doc-worker (implement-long-plan-v3)
**Outcome:** no-change-needed

## Summary

`db-migrations/README.md` was already updated inline during implementation
(plan §3.2 NOTE / AC11 / FT-14). This run is a verification pass against the
shipped source files. Every claim the README makes about the `maint.*` suite
is consistent with the actual code; no edit was needed.

## Verification (README claims ↔ source)

Source-file footprint checked: the four `maint.*` procs + `validate_structure.sql`.

| README claim (rule (k) / config table) | Source evidence | Verdict |
|---|---|---|
| `51100` maint.spCheckBackupChain | `maint.spCheckBackupChain.sql` THROW 51100 (lines 58, 102) | consistent |
| `51105` maint.spCheckMaintenanceLiveness | `maint.spCheckMaintenanceLiveness.sql` THROW 51105 (line 98) | consistent |
| `51110` maint.spEnsureMaintenanceJobs (guard/error path, reserved) | `maint.spEnsureMaintenanceJobs.sql` header comment (line 35): "51110 is reserved for this proc's guard/error path (README §4 (k))"; no live THROW — matches "reserved" | consistent |
| `51120` maint.spRunMaintenanceJob (unknown `cJobKey`) | `maint.spRunMaintenanceJob.sql` THROW 51120 (lines 53, 116) | consistent |
| `51100–51129` reserved for `maint.*`; reset-next-free `51130` | no maint THROW outside 51100–51120; range headroom intact | consistent |
| Rule (l): every `global/` proc registered in `validate_structure.sql` | all five maint objects present (spEnsureMaintenanceJobs, spRunMaintenanceJob, spCheckBackupChain, spCheckMaintenanceLiveness, spApplyMaintenance — lines 46-50) | consistent |
| `MaintenanceSchedulesEnabled` config row: `'0'` ⇒ jobs created disabled; `RoboticoOps - Maint - *` naming | `maint.spEnsureMaintenanceJobs.sql`: cKey check `= N'0'` (line 51), prefix `N'RoboticoOps - Maint - '` (line 45) | consistent |

## Changes applied

None. Doc already reflects shipped code.

## Removed / added sections

None.

## Files outside assigned scope (drift)

None.

## Notes for final

- The diff since plan-start also added rule **(m)** (`up/` comments must be
  English) to §4, driven by `up/0023` (outside this worker's SOURCE_FILES).
  It is present and internally consistent; flagged only so the final agent
  knows the (k)/(l)/(m) block is a single coherent edit, not a partial one.
- No cross-doc contradictions observed from this doc's side. The `maint.*`
  count (5 procs) and job count (6) that this README does not itself state
  live in `docs/SQL/MSSQL-OPS-ARCHITECTURE.md` / `NAMING-CONVENTIONS.md`;
  the README only carries the THROW allocation and the config knob, both
  verified above.
