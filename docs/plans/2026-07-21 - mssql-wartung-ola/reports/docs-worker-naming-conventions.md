# Doc Worker Report — naming-conventions

**Date:** 2026-07-23T00:05:00+02:00
**Target doc:** `docs/SQL/NAMING-CONVENTIONS.md`
**Action:** update (verification/consistency pass)
**Agent:** doc-worker (implement-long-plan-v3)
**Outcome:** no-change-needed

## Summary

The plan carried its own inline documentation contract (§3.4, D20) and the
implementation already applied every edit to `NAMING-CONVENTIONS.md` during the
implementation phase (visible in the `plan-start..HEAD` diff). My job was the
fresh-eyes verification of cross-doc counts and micro-convention wording. All
claims are consistent with the shipped source; no edit was warranted.

## Verification performed

| Claim in doc | Source of truth | Result |
|---|---|---|
| §9 "three schemas we own" (ops / reset / maint) | `db-migrations/global/` layout | Consistent — `maint.*` row added |
| §9 `maint.*` proc list: `spEnsureMaintenanceJobs`, `spRunMaintenanceJob`, `spCheckBackupChain`, `spCheckMaintenanceLiveness`, `spApplyMaintenance` (5) | 5 files on disk under `sprocs/` + `runAfterOtherAnyTimeScripts/`, each `CREATE OR ALTER PROCEDURE maint.<name>` | Exact match — 5 procs, no more, no fewer |
| §9 "vendored Ola objects live in `RoboticoOps.dbo`, upstream-named" | `up/0022_maintenance_ola_vendor.sql` (per discovery §4) | Consistent |
| §9 `ops.*` registry row now includes `ops.tMaintenanceJob` | `up/0023_maintenance_registry.sql` (`CREATE TABLE ops.tMaintenanceJob`) | Consistent |
| §9 TIME-column row: `t<Name>` → `ops.tMaintenanceJob.tStartTime` | `up/0023` col `tStartTime time(0) NOT NULL` | Consistent — column exists, is `time`-typed |
| §9 D20 NOTE: `t` prefix double-booked (table vs. time column) | `up/0023` (`tMaintenanceJob` table + `tStartTime` column coexist) | Consistent; ADR reference `ADR-A §D-A2` is symbolic, not a file path |

## Sections changed

None. Doc is already in line with shipped code.

## Sections removed / added

None.

## Self-check

Re-read the full doc for stale paths, leftover placeholders, and internal
consistency. §9 count "three schemas" matches the ops/reset/maint triple; the
five-proc `maint.*` list matches the five source files byte-for-byte on the proc
names; the `tStartTime` example matches the actual `time(0)` column; the D20
NOTE's disambiguation (table `t` vs. column `t`) is factually correct against the
DDL. No stale references found. The `reset.*` and `ops.*` rows are outside this
plan's footprint and were not part of the diff — left untouched.

## Notes for final

- `NAMING-CONVENTIONS.md` §9 references `ADR-A §D-A2 (plan 2026-07-21 -
  mssql-wartung-ola)` for the D20 `t`-double-booking micro-convention. That ADR
  is still plan-scoped (`adrs/adr-maintenance-as-code-roboticoops.md`, per
  discovery §6). When the ADR is promoted to `docs/decisions/NNNN-…` at plan
  closure, this symbolic reference should be updated to the promoted path. Not a
  doc-worker fix (append-only ADR territory + cross-doc concern).
- Cross-doc count consistency confirmed for this doc's scope: 5 `maint.*` procs
  and the `ops.tMaintenanceJob` registry table align with what DATA-MODEL and
  ARCHITECTURE assert (verify there via their own workers).
