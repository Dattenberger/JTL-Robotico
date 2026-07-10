# Inline-Anchor Worker Report — `tests-harness`

**Date:** 2026-07-10T02:45:00+02:00
**Group:** `db-migrations/tests/` (10 files)
**Plan:** `docs/plans/2026-07-10 - mssql-ops-infrastruktur/mssql-ops-infrastruktur.md`
**Range checked:** `9592c99..HEAD`
**Outcome:** no-change-needed — all three-anchor content already present, resolving, and accurate after repair wave 1.

## Summary

The discovery report predicted the test harness carried headers but **no `@see`**
anchors ("low value — add `@see` to the plan test-strategy section only where it
clarifies intent"). Repair wave 1 already added them. Reconciling against the final
plan, every anchor in the group resolves to an existing plan section and is
accurately attributed. No edits applied — adding or rewording anchors would be
churn, not sharpening.

## Per-file findings (all verified against the plan)

| File | Header | `@see` anchors | Verdict |
|---|---|---|---|
| `compare-objects.sql` | present (responsibility + D10 ownership boundary + read-only usage) | §7 Test Strategy (tier 2: object compare); §D10 (CW ownership boundary) | resolves — §7/§D10 exist; D10 body is exactly the additive-CW-zone rule this script enforces |
| `eazybusiness/CustomFieldAPI_Tests.sql` | present (ported provenance + component list) | §7 Test Strategy (tier 3: ported SQL test files) | resolves — matches plan §7 tier-3 (ported `*_Tests.sql`) |
| `eazybusiness/DuplicateOrders_Teardown.sql` | present (ported provenance + teardown scope + registry gotcha) | §7 Test Strategy (tier 3: ported SQL test files + teardown) | resolves — plan §7 Test Files row says "portierte Bestandstests + Teardown" |
| `eazybusiness/DuplicateOrders_Tests.sql` | present | §7 Test Strategy (tier 3) | resolves |
| `eazybusiness/HistorySPs_Tests.sql` | present | §7 Test Strategy (tier 3) | resolves |
| `eazybusiness/StringAndCSVUtilities_Tests.sql` | present | §7 Test Strategy (tier 3) | resolves |
| `lint-migrations.ps1` | present (comment-based help; "tier 1 of the three-tier test strategy") | §7 Test Strategy | resolves — plan §7 tier-1 = Konventions-Lint (this script) |
| `probes/01_worker_ttarget_semantics.sql` | present (Open Q O1 + recorded result + verdict) | §4 (Probeliste, O1); §D9 (Worker.tTarget untouched) | resolves — §4/O1/D9 exist; D9 explicitly leaves `Worker.tTarget` untouched |
| `probes/03_pf_user_in_clones.sql` | present (Open Q O4 + recorded result) | §4 (Probeliste, O4); §D9 (pf_user neutralisation) | resolves — D9 body lists `dbo.pf_user nGesperrt=1, nAktiv=0` verbatim |
| `probes/04_queue_inventory.sql` | present (queue-drain completeness + recorded result) | §4 (Probeliste); §D9 (queue-drain list) | resolves — D9 body lists exactly the 6 queues this probe verifies |

## Anchors added / updated / removed

None. No comment-noise (code-restating) anchors found to remove; no stale paths
(all anchors use the correct `2026-07-10 - mssql-ops-infrastruktur` folder); no
logic touched.

## Notes (observations only, no edits)

- **O1/O4 anchor precision (minor, defensible).** The probe `@see` tags phrase the
  target as `§4 (Validierung & Probeliste, Open Question O1/O4)`, but O1/O4 physically
  live under the sibling `## Open Questions` section, not inside `## §4`. Both sections
  exist and are cross-linked in the plan (O1/O4 carry `affected: §3/§4`), so the
  anchor is navigable and not broken — left as-is rather than split into two `@see`
  lines, which would be churn.
- Headers on the ported `eazybusiness/*_Tests.sql` files retain German body comments
  by design (provenance rule, plan Implementation Notes "Quell-Treue") — correct, not
  a drift.

## Files outside assigned scope (drift)

none
