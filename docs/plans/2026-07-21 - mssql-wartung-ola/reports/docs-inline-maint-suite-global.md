# Inline-Anchor Worker Report — maint-suite-global

**Date:** 2026-07-23T00:05:00+02:00
**Agent:** doc-worker-inline (implement-long-plan-v3)
**Slug:** maint-suite-global
**Plan:** `docs/plans/2026-07-21 - mssql-wartung-ola/mssql-wartung-ola.md`
**Plan-start commit:** `d722993ae64b0a7e0dbcb5fd37fa8c6a7e7180a9`

## Summary

Fresh-eyes verification pass over the three sanctioned inline anchors of the
eight new maintenance SQL files. The implementation had already authored the
complete anchor set inline (module header + `@see` plan tag + `@see` ADR tag,
plus gotcha comments where warranted). Every file was reviewed against its plan
section and the diff; **all anchors are present, resolve, and are high-quality**.
No edits applied — outcome `no-change-needed`.

## Anchor inventory (verified per file)

| File | Module header | `@see` plan | `@see` ADR | Gotcha(s) | Verdict |
|---|---|---|---|---|---|
| `up/0022_maintenance_ola_vendor.sql` | present | §3.1 | ADR-A + ADR-B | VENDOR-DEVIATION (dashed-date rewrite, CRLF/BOM), DatabaseBackup-not-vendored, upstream idempotency | OK |
| `up/0023_maintenance_registry.sql` | present | §3.1 | ADR-A | immutable-DDL / rows-not-seeded, double-grammar `cDatabases`, repo-owned GRANT, `@see` DATA-MODEL same-commit contract | OK |
| `sprocs/maint.spEnsureMaintenanceJobs.sql` | present | §3.2 | ADR-A | per-job normal form (D31), running-guard session scoping, THROW 51110 reserved | OK |
| `sprocs/maint.spRunMaintenanceJob.sql` | present | §3.2 | ADR-A | runtime dispatch / no dynamic SQL (D28), run-time cutoffs, REORGANIZE-only (D13), THROW 51120, new-operation recipe | OK |
| `sprocs/maint.spCheckBackupChain.sql` | present | §3.2 | ADR-B | local time base (D32), literal-list target validation, recovery-model filter, THROW 51100 | OK |
| `sprocs/maint.spCheckMaintenanceLiveness.sql` | present | §3.2, D36 | ADR-A | two-clocks-on-purpose, first-run grace (L-B1-2), stats-off blind spot (L-B1-3), residual agent-down blind spot, THROW 51105 | OK |
| `runAfterOtherAnyTimeScripts/maint.spApplyMaintenance.sql` | present | §3.3 | ADR-A | repo-owned MERGE deviation from tResetStep, QG3-B12 rationale, IS DISTINCT FROM (D30) | OK |
| `permissions/260_maintenance_operator.sql` | present | §3.3 | ADR-A | grate stage-order (permissions after runAfter), Standard-SMTP guard, agent-restart gotcha, repo-owned operator identity | OK |

## Target-resolution checks

- ADR files exist: `adrs/adr-maintenance-as-code-roboticoops.md` (ADR-A),
  `adrs/adr-backups-cbb-retained.md` (ADR-B).
- Plan sections resolve: `### §3.1` (line 62), `### §3.2` (line 165),
  `### §3.3` (line 228); `D36` defined (plan lines 30/50/196/204/207).
- `up/0023` header's cross-anchor to `docs/SQL/MSSQL-OPS-DATA-MODEL.md`
  (same-commit contract) matches the CLAUDE.md update contract — appropriate.

## Anchors added / updated / removed

None. All anchors were pre-existing and correct.

## Skips (with reason)

- No module header added/removed anywhere — every file already carries an
  intent-level header covering responsibility + non-obvious patterns.
- No comment-noise removals: spot review found no comments that merely restate
  code; every inline comment carries non-derivable WHY (protocol quirks, msdb
  normal-form mapping, THROW allocation, deliberate deviations).

## SSoT check

No double-truth. Headers carry local WHY + gotchas (correct home per the
anti-redundancy table); plan intention is linked via `@see`, never paraphrased;
architectural decisions are referenced by ADR/decision-ID (D-numbers) rather
than restated.

## Files outside assigned scope (drift)

none

## Notes for final

- **Plan-path anchor form is folder+section, not file+section.** All eight
  files use `@see docs/plans/2026-07-21 - mssql-wartung-ola (§3.1)` (the plan
  *folder* with a parenthesized section) rather than the knowledge-doc-format
  canonical `@see docs/plans/.../mssql-wartung-ola.md §3.1` (plan *file*). It
  resolves unambiguously (one plan file in the folder) and is consistent across
  all eight files and — per the discovery report — with the wider mssql-ops
  program's convention. Left unchanged: a repo-wide stylistic normalization is
  out of scope for a single-plan verification pass and would risk diverging
  these files from their siblings. Flagged for awareness only.
- Two plan-scoped ADRs (`adr-maintenance-as-code-roboticoops.md`,
  `adr-backups-cbb-retained.md`) are still `Proposed (plan-scoped)`. When they
  are promoted to `docs/decisions/NNNN-…` before archival, the eight `@see`
  ADR anchors here must have their paths rewritten to the promoted locations.
  Not a doc-worker task (append-only ADR lifecycle); belongs to plan closure.
