# Doc Worker Report — ops-architecture (`docs/SQL/MSSQL-OPS-ARCHITECTURE.md`)

**Date:** 2026-07-23T00:05:00+02:00
**Action:** update (verification/consistency pass)
**Agent:** doc-worker `ops-architecture` (implement-long-plan-v3)
**Outcome:** augmented (small in-place edit — dangling-reference fix)

## Context

Per the discovery report, the maint subsystem content was already woven into
this doc during implementation (all in the plan-start..HEAD diff). This run was
a verification/consistency pass with one targeted fix.

## Verification (all consistent — no change needed)

Cross-checked the doc's shipped claims against source:

| Claim in doc | Source of truth | Result |
|---|---|---|
| "three schemas" (ops / reset / maint) | `up/0023`, sprocs | consistent |
| 6 agent jobs (checkdb, index-optimize, 3 cleanups, backup-watchdog) | `maint.spApplyMaintenance.sql` MERGE (6 desired rows: `checkdb`, `index-optimize`, `cleanup-commandlog`, `cleanup-backuphistory`, `cleanup-jobhistory`, `backup-watchdog`) | consistent |
| 5 maint procs in §3 component table | sprocs dir (`spEnsureMaintenanceJobs`, `spRunMaintenanceJob`, `spCheckBackupChain`, `spCheckMaintenanceLiveness`, `spApplyMaintenance`) | consistent |
| `spCheckBackupChain` THROW 51100 | `maint.spCheckBackupChain.sql:58,102` | consistent |
| `spCheckMaintenanceLiveness` THROW 51105 (D36) | `maint.spCheckMaintenanceLiveness.sql:98` | consistent |
| Vendored Ola objects: CommandLog/CommandExecute/DatabaseIntegrityCheck/IndexOptimize, **no DatabaseBackup** | `up/0022_maintenance_ola_vendor.sql` (line 14: DatabaseBackup deliberately not vendored) | consistent |
| Both new standing rules §6.5 (CBB/ADR-B boundary) + §6.6 (git-only tuning), §6.5→§6.7 renumber | doc body | present, correctly renumbered |

## Change applied

**Section: Frontmatter + §8 References — dangling ADR reference completed.**
The implementation edit added inline "ADR-A/ADR-B" labels (§1a.2, §6.5) and cited
plan `2026-07-21 - mssql-wartung-ola`, but neither the frontmatter `related-adrs`
nor §8 References provided a navigable target for those labels — §8 linked only
the four older mssql-ops-infrastruktur ADRs. Per `knowledge-doc-format` the
References section must link companion ADRs; a reader hitting "ADR-B" had no path
to the file.

- Frontmatter `related-adrs`: appended `adr-maintenance-as-code-roboticoops (ADR-A)`
  and `adr-backups-cbb-retained (ADR-B)`, marked all plan-scoped / pending promotion.
- §8 References: added a "Maintenance suite" bullet linking the wartung-ola plan
  file and both ADR files (ADR-A / ADR-B expanded), URL-encoded paths matching the
  existing mssql-ops reference style. All three targets verified to exist on disk.

No other edits: voice, structure, cross-references, and all diagrams preserved.

## Inline anchors

Not touched (doc worker scope excludes source). Discovery §4 already confirmed all
eight new SQL files carry the complete three-anchor set.

## Notes for final

- **ADR promotion pending (out of doc-worker scope).** The two new ADRs
  (`adr-maintenance-as-code-roboticoops`, `adr-backups-cbb-retained`) are still
  `Proposed (plan-scoped)`. When they are promoted to `docs/decisions/NNNN-…`
  (this repo has no `docs/decisions/` yet), the links I added in frontmatter +
  §8 — and the four older plan-scoped ADR links already in this doc — must be
  rewritten to the promoted paths, and the "(plan-scoped — pending promotion)"
  qualifiers dropped. This affects both ADR cohorts uniformly.
- No cross-doc contradictions found with sibling docs (DATA-MODEL, NAMING,
  README, runbook) — counts (5 procs / 6 jobs / THROW 51100–51129) are consistent
  across them per the discovery report.

## Files touched

- `/home/lukas/WebStorm/JTL-Robotico/worktrees/feature/mssql-ops-infrastruktur/docs/SQL/MSSQL-OPS-ARCHITECTURE.md`

## Drift (files outside assigned target)

none
