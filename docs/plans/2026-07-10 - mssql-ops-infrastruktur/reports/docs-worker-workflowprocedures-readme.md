# Doc Worker Report — `workflowprocedures-readme`

**Action:** update (reconcile against final post-repair code)
**Target:** `WorkflowProcedures/README.md`
**Timestamp:** 2026-07-10T02:45:00+02:00
**Outcome:** no-change-needed

## What I did

Verified the deprecation README's source→destination mapping table and its
surrounding claims against the shipped `db-migrations/eazybusiness/**` and
`db-migrations/tests/eazybusiness/*` code after repair wave 1
(`54f38fd`). The doc is a small non-UDOC deprecation README following an
established convention; the discovery brief scoped this item to verifying
the mapping is exact (no stragglers/renames). It is exact — no edit warranted.

## Verification detail

Shipped objects (all present, all mapped by the table):

- **functions/ (12):** `fnGetArticleCustomFieldValue`; `fnString*` (5:
  CountLines, IsEffectivelyEmpty, ParseGermanDecimal, StripWhitespace,
  TrimToMaxLines) + `fnEscapedCSV*` (4: GetField, GetLastLine, ParseLine,
  Sanitize) = the "9 functions" claim in row 2 is correct;
  `fnFindDuplicateOrders`, `fnHasOlderDuplicateOrder`.
- **sprocs/ (13):** `spEnsureArticleCustomField`, `spSetArticleCustomFieldValue`,
  `spCheckDuplicateOrder`, `spPaypal{GetAccessToken,CreateAccessToken,TrackingCallApi}`,
  `CustomWorkflows.spPaypalTracking{Versand,Lieferschein}`,
  `CustomWorkflows.spArticleAppend{Price,Label}History`, `spArticleUpdateAllHistory`,
  `spGebindeErstellen`, `spZustandartikelLieferantSetzen`.
- **up/ (2):** `0001_robotico_schema` (schema, carries a provenance note),
  `0002_robotico_paypal_tables` (row 4).
- **tests/eazybusiness/ (5):** CustomFieldAPI_Tests, DuplicateOrders_Tests,
  DuplicateOrders_Teardown, HistorySPs_Tests, StringAndCSVUtilities_Tests —
  all covered by row 9's `*_Tests.sql` + teardown glob.

Cross-checks that held:

- Every one of the 27 `db-migrations/eazybusiness/**` files carries a
  `-- Ported from …` provenance line — the README body claim ("Each
  migration file … names the `WorkflowProcedures/*` source it was ported
  from") is literally true, 0001 schema included.
- "Not migrated (intentionally)" list matches the actual leftover files:
  `Diagnose_Workflow.sql`, 4× `Workflowaktion Auftrag Preise auf Null*.Sql`,
  4× `Workflowaktion Artikel Seriennummern Standardlager auf WMS*.Sql`,
  `PayPal/Test/*`, `PayPal/Enable OLE Procedures.sql`.
- Relative link `../db-migrations/` and references to
  `docs/SQL/JTL-CUSTOM-WORKFLOWS.md`, `db-migrations/README.md` §6, and
  decision D12 all resolve.

## Sections changed

None (removed: none; added: none).

## Files touched

None.

## Files outside scope (drift)

None.

## Notes for final

- The mapping table is verified exact against post-repair code; no stale
  paths. Nothing here for the final agent to reconcile with sibling docs.
- Out-of-scope but observed (already flagged in discovery, not a doc-update
  task): `db-migrations/tests/` still has no dedicated README; the three
  plan-scoped ADR drafts remain unpromoted (`docs/decisions/` absent). Both
  are plan-lifecycle obligations, not this doc's concern.
