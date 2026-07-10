# Inline-Anchor Worker Report — eazybusiness-ebene-a

**Date:** 2026-07-10T02:45:00+02:00
**Slug:** eazybusiness-ebene-a
**Scope:** `db-migrations/eazybusiness/` — 12 functions, 13 sprocs, 2 `up/` scripts (27 target files)
**Plan range:** `9592c99..HEAD`

## What I did

Added the missing **`@see` plan/ADR anchor** (the one of the three anchors the
discovery report found absent across Ebene A — module headers already exist on every
file, provenance is carried by `-- Ported from …` lines). No module headers added
(all present), no gotcha comments added (existing headers already carry the empirical
quirks, e.g. `QUOTED_IDENTIFIER` in `spZustandartikelLieferantSetzen`, OLE-Automation
requirement in the PayPal procs). No comment noise removed — no restate-the-code
comments exist in this scope.

**14 of 27 files anchored** (+2 comment lines each; no code, formatting, or imports
touched — verified via `git diff --stat`: 28 insertions, 0 deletions).

## Anchor target convention (decision)

Anchored to the **plan section + Decision-Log number** (`docs/plans/2026-07-10 -
mssql-ops-infrastruktur (§1, Dn)`), matching the established Ebene-B sibling
convention (`db-migrations/global/**`), **not** to the ADR draft paths. Rationale:
the three ADRs are still plan-scoped (`docs/plans/.../adrs/adr-*.md`, `docs/decisions/`
does not exist yet) — pointing at `docs/decisions/NNNN-*` would be a dangling link, and
pointing at the draft path would churn on promotion. Plan §/D anchors are resolvable now
and stable across archival (the archive step rewrites plan links); the Decision-Log
entries themselves cross-reference the ADRs. See `notes_for_final`.

## Anchors added

| File | Anchor | Why (decision the code alone doesn't justify) |
|---|---|---|
| `functions/Robotico.fnEscapedCSVParseLine.sql` | §1, D10 | Named API contract with excel_ekl — signature must stay stable |
| `functions/Robotico.fnFindDuplicateOrders.sql` | §1 | Duplicate-order engine (principal public object of the cluster) |
| `functions/Robotico.fnGetArticleCustomFieldValue.sql` | §1 | CustomField API — public read side |
| `sprocs/Robotico.spSetArticleCustomFieldValue.sql` | §1 | CustomField API — public write side |
| `sprocs/Robotico.spPaypalTrackingCallApi.sql` | §1 | PayPal tracking API entry point behind the CW actions |
| `sprocs/CustomWorkflows.spArticleAppendLabelHistory.sql` | §1, D10 | Additive shared zone co-inhabited by excel_ekl |
| `sprocs/CustomWorkflows.spArticleAppendPriceHistory.sql` | §1, D10 | " |
| `sprocs/CustomWorkflows.spArticleUpdateAllHistory.sql` | §1, D10 | " |
| `sprocs/CustomWorkflows.spGebindeErstellen.sql` | §1, D10 | " |
| `sprocs/CustomWorkflows.spZustandartikelLieferantSetzen.sql` | §1, D10 | " |
| `sprocs/CustomWorkflows.spPaypalTrackingLieferschein.sql` | §1, D10 | " |
| `sprocs/CustomWorkflows.spPaypalTrackingVersand.sql` | §1, D10 | " |
| `up/0001_robotico_schema.sql` | §1, D2, D3 | Robotico schema is the Ebene-A journal home; two-chain split |
| `up/0002_robotico_paypal_tables.sql` | §1 | Ebene-A port of PayPal DDL + settings seed |

## Skipped (deliberate — with reason)

One anchor per decision point; generic helpers and internal-only objects carry no plan
decision beyond "ported" (already covered by their `-- Ported from …` line):

- `functions/Robotico.fnEscapedCSVGetField.sql`, `fnEscapedCSVGetLastLine.sql`,
  `fnEscapedCSVSanitize.sql` — helper/wrapper + write side; only `fnEscapedCSVParseLine`
  is the D10-named contract.
- `functions/Robotico.fnString*` (6: CountLines, IsEffectivelyEmpty,
  ParseGermanDecimal, StripWhitespace, TrimToMaxLines) — generic string utilities, no
  plan decision.
- `functions/Robotico.fnHasOlderDuplicateOrder.sql`, `sprocs/Robotico.spCheckDuplicateOrder.sql`
  — thin wrappers over the anchored engine `fnFindDuplicateOrders`; header already links
  the engine + `docs/SQL/JTL-CUSTOM-WORKFLOWS.md`. Engine carries the cluster anchor.
- `sprocs/Robotico.spEnsureArticleCustomField.sql` — internal helper (header says so);
  public surface `spSetArticleCustomFieldValue` is anchored.
- `sprocs/Robotico.spPaypalCreateAccessToken.sql`, `spPaypalGetAccessToken.sql` —
  internal token management; the tracking entry point `spPaypalTrackingCallApi` is anchored.

## Self-check

- All anchor targets resolve: §1 (plan L236), D2 (L45), D3 (L54), D10 (L110) exist.
- No logic touched — every edit is inside the leading `-- ===` header comment block,
  before the `CREATE`/DDL. `git diff --stat`: 14 files, +28/-0, all comment lines.
- No comment noise added; existing `-- Ported from …` provenance retained (complements,
  does not duplicate, the `@see` — prose = local why, `@see` = navigable SSoT).

## Files outside assigned scope (drift)

none

## Notes

- **ADR promotion gap (already flagged by discovery, out of scope here):** once the three
  plan-scoped ADRs are promoted to `docs/decisions/NNNN-*`, these `@see (§1, Dn)` anchors
  could optionally gain a companion `@see docs/decisions/NNNN-…` line — but the plan-§/D
  anchor stays valid and is the primary. No action needed from the inline worker.
