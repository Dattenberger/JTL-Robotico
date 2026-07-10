# Repair Report — cluster W1-5

**Timestamp:** 2026-07-10T00:57:22+02:00
**Agent role:** repair-fix (green cluster)
**Report file:** docs/plans/2026-07-10 - mssql-ops-infrastruktur/reports/B1/repair-W1-5.md

## Summary

One finding in this cluster (T1, green / Nice-to-have). After reading the two
affected procs, the existing ported test suites, and the approved plan §7, the
finding is **skipped as a documented conscious decision** — no code change. The
finding text itself frames its fix as optional ("No action required if the
accepted-scope decision stands"), and that decision does stand.

## Findings

### T1 — Coverage gap: spGebindeErstellen & spZustandartikelLieferantSetzen (SKIPPED)

- **Files:** `db-migrations/eazybusiness/sprocs/CustomWorkflows.spGebindeErstellen.sql`,
  `db-migrations/eazybusiness/sprocs/CustomWorkflows.spZustandartikelLieferantSetzen.sql`
- **Classification:** green / Nice-to-have
- **Decision:** Skipped (no fix applied), for four compounding reasons:

  1. **Suggested fix is explicitly optional & scope-conditional.** The finding
     states it is "Consistent with the approved plan scope … not a plan
     violation" and "No action required if the accepted-scope decision stands."
     It was surfaced so the gap is a conscious decision, not because a defect
     exists.

  2. **Adding the tests would expand beyond the approved plan §7 scope.**
     Plan §7 (Status: ✅ User-Approved) defines the SQL test layer as
     *"portiert aus `WorkflowProcedures/*_Tests.sql`"* — only pre-existing
     suites are ported. The source shipped no `*_Tests.sql` for either of these
     two actions, so under the approved scope they deliberately get none.
     Unilaterally authoring new suites is a scope expansion the repair role
     should not take on a green finding.

  3. **The hard no-writes constraint makes a valid test impossible to produce
     here.** `hard_constraints` forbids any writes against a SQL server; the
     existing suites (e.g. `HistorySPs_Tests.sql`) are manual-integration
     tests that require a live test mandant (they `INSERT`/`UPDATE`/`DELETE`
     inside a transaction and `ROLLBACK`). I cannot run such a test to observe
     it go red then green. Per the project's test-first rule, "a test that
     never saw red is a hopeful assertion, not a regression test."

  4. **Sustainability (D4).** For DB-mutation procs, a robust suite would have
     to fabricate `tArtikel`/`tLiefArtikel`/`tGebinde` rows (many NOT NULL
     columns) or depend on specific live-mandant article state — neither
     verifiable under the constraint. Shipping an unrunnable, unvalidated test
     file would give false confidence and is worse than a documented gap. The
     long-term-better outcome is to leave the gap explicit here and let Lukas
     add a transaction-rolled-back suite (following the existing
     `*_Tests.sql` pattern: HAN/GTIN-match, unique-supplier-number,
     standard-condition-untouched kZustand=1, idempotent-suffix branches) when
     a test mandant is available for red→green validation.

  The 5 PayPal procs noted in the finding make external PayPal REST calls and
  are not unit-testable in this harness (accepted); no action.

- **Reason string (for re-audit):** `skipped: green/Nice-to-have; fix is
  optional per finding text; adding suites expands beyond approved plan §7
  scope (ports pre-existing *_Tests.sql only) and cannot be validated red→green
  under the no-writes hard constraint.`

## Tests

`pwsh db-migrations/tests/lint-migrations.ps1` → **OK: 0 errors, 10 warning(s)**
(the 10 warnings are pre-existing rule-(g) dynamic-SQL heuristics, unrelated to
this cluster). No files changed, so no regression risk.

## Files modified

none

## Drift

none
