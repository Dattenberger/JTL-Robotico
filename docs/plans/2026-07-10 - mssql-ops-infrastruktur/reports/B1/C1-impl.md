# C1 — Migration foundation (Ebene A) + conventions SSoT + lint harness — IMPL report

**Chunk:** C1 (Block B1) · **Plan sections:** §1, §7 · **Timestamp:** 2026-07-10T00:57:22+02:00

## What was done

Built the Ebene-A grate migration foundation: the conventions-contract README, the
`targets.config.json` catalog, a thin `deploy.ps1` wrapper (parse-validated, PROD Y/N
gate, grate presence check, cert-token pass-through), the full `eazybusiness/` object
tree ported and normalized from `WorkflowProcedures/*`, the ported manual test suite,
the baseline runbook, the `WorkflowProcedures/` deprecation README, and the §7 test
stack (`lint-migrations.ps1` + `compare-objects.sql`). The lint is the executable form
of the README contract and was self-verified against a violation fixture.

**Test run:** `pwsh db-migrations/tests/lint-migrations.ps1` → **0 errors, 0 warnings, exit 0**
across 27 deploy files. `deploy.ps1` and `lint-migrations.ps1` both pass
`[System.Management.Automation.Language.Parser]::ParseFile`. No SQL was executed against
any server (read-only constraint honored; no live run was needed for §1 acceptance).

## Object mapping (research/5 §3 → target file) — completeness

| Deployed object (source) | Target file |
|---|---|
| `Robotico.fnGetArticleCustomFieldValue` (api/CustomFieldAPI.sql) | `functions/Robotico.fnGetArticleCustomFieldValue.sql` |
| `Robotico.spEnsureArticleCustomField` | `sprocs/Robotico.spEnsureArticleCustomField.sql` |
| `Robotico.spSetArticleCustomFieldValue` | `sprocs/Robotico.spSetArticleCustomFieldValue.sql` |
| `Robotico.fnStringStripWhitespace` (api/StringAndCSVUtilities.sql) | `functions/Robotico.fnStringStripWhitespace.sql` |
| `Robotico.fnStringIsEffectivelyEmpty` | `functions/Robotico.fnStringIsEffectivelyEmpty.sql` |
| `Robotico.fnStringCountLines` | `functions/Robotico.fnStringCountLines.sql` |
| `Robotico.fnStringTrimToMaxLines` | `functions/Robotico.fnStringTrimToMaxLines.sql` |
| `Robotico.fnStringParseGermanDecimal` | `functions/Robotico.fnStringParseGermanDecimal.sql` |
| `Robotico.fnEscapedCSVSanitize` | `functions/Robotico.fnEscapedCSVSanitize.sql` |
| `Robotico.fnEscapedCSVParseLine` | `functions/Robotico.fnEscapedCSVParseLine.sql` |
| `Robotico.fnEscapedCSVGetField` | `functions/Robotico.fnEscapedCSVGetField.sql` |
| `Robotico.fnEscapedCSVGetLastLine` | `functions/Robotico.fnEscapedCSVGetLastLine.sql` |
| `Robotico.fnFindDuplicateOrders` (Duplikaterkennung) | `functions/Robotico.fnFindDuplicateOrders.sql` |
| `Robotico.fnHasOlderDuplicateOrder` | `functions/Robotico.fnHasOlderDuplicateOrder.sql` |
| `Robotico.spCheckDuplicateOrder` | `sprocs/Robotico.spCheckDuplicateOrder.sql` |
| `Robotico.tPaypalAccessToken/tPaypalSettings/tPaypalTrackingLog` (PayPal/Add…) | `up/0002_robotico_paypal_tables.sql` (incl. settings seed) |
| `CustomWorkflows.spPaypalTrackingVersand` (PayPal/Workflowaktion) | `sprocs/CustomWorkflows.spPaypalTrackingVersand.sql` |
| `CustomWorkflows.spPaypalTrackingLieferschein` | `sprocs/CustomWorkflows.spPaypalTrackingLieferschein.sql` |
| `CustomWorkflows.spArticleAppendPriceHistory` (history/) | `sprocs/CustomWorkflows.spArticleAppendPriceHistory.sql` |
| `CustomWorkflows.spArticleAppendLabelHistory` | `sprocs/CustomWorkflows.spArticleAppendLabelHistory.sql` |
| `CustomWorkflows.spArticleUpdateAllHistory` | `sprocs/CustomWorkflows.spArticleUpdateAllHistory.sql` |
| `CustomWorkflows.spGebindeErstellen` | `sprocs/CustomWorkflows.spGebindeErstellen.sql` |
| `CustomWorkflows.spZustandartikelLieferantSetzen` | `sprocs/CustomWorkflows.spZustandartikelLieferantSetzen.sql` |
| **(not in research/5 §3; found in PayPal source)** `Robotico.spPaypalGetAccessToken` | `sprocs/Robotico.spPaypalGetAccessToken.sql` |
| `Robotico.spPaypalCreateAccessToken` | `sprocs/Robotico.spPaypalCreateAccessToken.sql` |
| `Robotico.spPaypalTrackingCallApi` | `sprocs/Robotico.spPaypalTrackingCallApi.sql` |

All research/5 §3 deployed objects are covered by exactly one target file.

## Deviations

| Deviation | Plan location | What changed | Why | Impact on later chunks | Resolved? |
|---|---|---|---|---|---|
| `CustomWorkflows._CheckAction.sql` / `._SetActionDisplayName.sql` **not created** | §1 file table + Impl step 3 (`extract inline definition from Workflowaktion files`) | These two files were not created. | The plan's premise is factually wrong: grep shows `_CheckAction`/`_SetActionDisplayName` are only ever `EXEC`'d, never `CREATE`'d in the repo. `docs/SQL/JTL-CUSTOM-WORKFLOWS.md` proves (live `OBJECT_DEFINITION`) they are **JTL "Custom Workflow Actions" module** objects (vendor, since Wawi 1.6). Recreating vendor objects in our chain would claim ownership we don't have and get overwritten on module updates. | None for C2/C3 (global chain). Affects D10 framing + §5 ADR/naming-doc: they call these "our stable API"; they are actually module-provided (excel_ekl and we are both *consumers*). | Resolved for this chunk: module documented as a prerequisite (README §6 + WorkflowProcedures/README), and each action's registration call is **guarded** (`IF OBJECT_ID(...) IS NOT NULL … ELSE PRINT`). Flagged for audit — see issue C1-1. |
| Ported 3 extra PayPal API procs (`Robotico.spPaypalGetAccessToken/CreateAccessToken/TrackingCallApi`) | §1 sproc list says `Robotico.sp* (×~4) … u.a.` — these 3 not named | Created 3 additional `sprocs/Robotico.spPaypal*.sql` files. | They live in the same source file (`PayPal/Add Procudures and Tables.sql`), are deployed objects, and the `CustomWorkflows.spPaypalTracking*` actions call them at runtime — omitting them breaks the PayPal actions. research/5 §3 under-inventoried this file (listed only its 3 tables). | The PayPal action chain is complete. | Resolved (implemented). |
| Function count 12, not ~13 | §1 file table `NEW (×~13)` | Exactly 12 function files. | Actual inventory: 3 duplicate/custom-field + 4 EscapedCSV + 5 String = 12. Plan estimate said "~13" (`fnString* (6)`; there are 5). | none | Resolved (estimate reconciled). |
| Stripped per-file transaction/PRINT scaffolding from ported objects | §1 Impl step 2 ("normalized") | Removed `SET XACT_ABORT ON` / `BEGIN TRANSACTION` / `COMMIT` / `XACT_STATE()` deployment banners; kept object body + guarded registration. | grate wraps each deploy in `--transaction`; the manual scaffolding is redundant, splits the file into extra batches, and conflicts with the "one clean CREATE per anytime file" rule. | Downstream ports (C2/C3) should follow the same normalization. | Resolved (documented pattern in README §6). |
| §7 lint rule (g) heuristic tightened | §7 rule (g) | Rule (g) now fires only inside real string-execution contexts (`EXEC(<string>)` / `sp_executesql`), not on `PRINT '…' + @var` / URL building / ordinary `EXEC proc` calls. | Original broad heuristic produced 21 false positives on the PayPal procs (which use `EXEC sp_OAMethod`, not dynamic SQL). Precise version stays meaningful for the C2/C3 reset procs that build `USE [db]; …` strings. | C2/C3 reset procs will still be checked for un-QUOTENAME'd data concatenation. | Resolved. |

## Inline fixes applied

- Normalized `GO;` → `GO`, removed `USE eazybusiness`, converted double-quoted display
  names (`"…"`) to single quotes in the PayPal action port (would require
  `QUOTED_IDENTIFIER OFF`, fragile), and `IF EXISTS DROP + CREATE` → `CREATE OR ALTER`
  throughout — all per §1 Impl step 2.
- Added `SET ANSI_NULLS ON` / `SET QUOTED_IDENTIFIER ON` before
  `CustomWorkflows.spZustandartikelLieferantSetzen` (filtered-index requirement, error
  1934) — preserved the source's documented gotcha.

## Issues

| ID | Severity | Description (what + file:line) | Status | Marker |
|---|---|---|---|---|
| C1-1 | Important | D10 / research/1.1 / §1 treat `CustomWorkflows._CheckAction` + `_SetActionDisplayName` (+ `vCustomAction*`, `tWorkflowObjects`, `tAllowedDatatypes`) as **our** stable API to create/own. `docs/SQL/JTL-CUSTOM-WORKFLOWS.md` (live `OBJECT_DEFINITION`) proves they are **JTL-module-provided vendor objects**; excel_ekl and we are both *consumers*. §5's D10 ADR + `NAMING-CONVENTIONS.md` edit should be worded as "shared consumption of a JTL-module API" (keep names stable because both consume it), not "our API for excel_ekl". No object files should be created for them. | delegated | plan-deviation-resolved |

## Files modified (all NEW)

- `db-migrations/README.md`, `db-migrations/targets.config.json`, `db-migrations/deploy.ps1`
- `db-migrations/eazybusiness/up/0001_robotico_schema.sql`, `…/up/0002_robotico_paypal_tables.sql`
- `db-migrations/eazybusiness/functions/*.sql` (12)
- `db-migrations/eazybusiness/sprocs/*.sql` (13: 6 Robotico + 7 CustomWorkflows)
- `db-migrations/tests/lint-migrations.ps1`, `db-migrations/tests/compare-objects.sql`
- `db-migrations/tests/eazybusiness/*.sql` (4 ported tests + 1 teardown)
- `docs/runbooks/migrations-baseline.md`
- `WorkflowProcedures/README.md`

## Drift (files outside assigned scope)

- `WorkflowProcedures/README.md` — NEW, but explicitly a §1 plan item (deprecation banner,
  D12). Not drift; listed here for transparency. No existing `WorkflowProcedures/*.sql`
  file was modified (D12: alt scripts stay runnable).

## Helper decisions

- New reusable harness `db-migrations/tests/lint-migrations.ps1` created (no prior lint
  existed) — the executable contract for all downstream chunks; self-tested against a
  violation fixture (rules a/b/c/d/e all fire; clean files pass).
- `compare-objects.sql` created as the file↔DB baseline/smoke check (read-only).
