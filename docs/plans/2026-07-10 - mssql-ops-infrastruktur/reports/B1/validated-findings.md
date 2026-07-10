# Block B1 — Audit Consolidation (validated findings)

**Mode:** initial · **Block:** B1 (chunks C1–C4) · **Timestamp:** 2026-07-10T00:57:22+02:00
**Consolidated from:** audit-plan-and-api, audit-convention, audit-logic, audit-test

## Summary

Six findings were reported across the four topic audits. **All six survive validation** against
the code at HEAD; **none were eliminated** as false positives, and there were no duplicates to
merge. The block is highly consistent: plan-and-api found nothing (every cross-chunk contract —
proc signatures, `ops.*` column graph, job name, grants, deploy flags — verified clean), and the
surviving findings are one Important documentation-accuracy defect plus five Nice-to-have items
(convention harmonization and two pre-existing ported-logic edge cases). All fixes are clear from
the finding text; nothing needs a research topic (all classified **green**).

## Validated findings

### convention-B1-1 — Naming SSoT claims a convention the Ebene-B objects do not follow (Important, green)

**Files:** `docs/SQL/NAMING-CONVENTIONS.md` (§9, line 178), `db-migrations/global/up/0002_ops_schema_tables.sql` (lines 30–96)

Verified: §2 (line 38) mandates `t<SingularName>` table names and §3 (lines 58–70) mandates
Hungarian column/param prefixes (`k/n/c/f/d/b`). §9 line 178 states ops/reset "follows the same
rules as `Robotico` (sections 2–4)" with only two listed exceptions. The as-built `ops.*` tables
directly contradict this: `ops.Mandant`, `ops.Config`, `ops.ResetRequest` (no `t`), columns
`MandantKey/TargetDb/DisplayName/RequestId/Status/StepLog` (PascalCase, no Hungarian prefix), and
`UX_ResetRequest_Active` (line 92) uses neither the `IX_` nor `UQ_` prefix (the other constraints
in the same file do follow `PK_ops_`/`FK_ops_`/`CK_ops_`/`UQ_ops_`). The PascalCase choice for an
admin DB is self-consistent and reasonable; the defect is that the naming SSoT misdescribes it, so
a maintainer following §9 → §2–4 literally would add `ops.tSomething` with `cName` columns and
drift the schema.

**Fix:** correct §9 to document the Ebene-B convention (PascalCase, unprefixed, admin-DB style)
rather than claim §2–4 apply; optionally rename `UX_ResetRequest_Active` → `UQ_ops_ResetRequest_Active`
or cover it in the doc note. Do **not** rename the shipped `ops.*` tables/columns (referenced across
11 reset procs) — the doc is the inaccurate side.

### convention-B1-2 — `SET NOCOUNT ON` applied inconsistently across the ported procs (Nice-to-have, green)

**Files:** `db-migrations/eazybusiness/sprocs/Robotico.spPaypalGetAccessToken.sql`,
`Robotico.spPaypalCreateAccessToken.sql`, `Robotico.spPaypalTrackingCallApi.sql`,
`CustomWorkflows.spPaypalTrackingVersand.sql`, `CustomWorkflows.spPaypalTrackingLieferschein.sql`

Verified: `spPaypalGetAccessToken` opens its body directly with `BEGIN TRANSACTION` (line 17), no
`SET NOCOUNT ON`. The other 8 C1 procs (e.g. `spEnsureArticleCustomField` line 23) and all 11 C2
`reset.*` procs include it. The C1 port-normalization pass harmonized every proc's scaffolding
except these five — undocumented drift, not a stated deviation. Harmless at runtime.

**Fix:** add `SET NOCOUNT ON;` as the first body statement (inside `BEGIN`) of the five PayPal procs.

### convention-B1-3 — File-header comment style diverges between C1 and C2 (Nice-to-have, green)

**Files:** `db-migrations/eazybusiness/**/*.sql` (boxed banner) vs `db-migrations/global/**/*.sql`
(plain one-liner), e.g. `Robotico.fnEscapedCSVSanitize.sql` vs `reset.internal_CloneDatabase.sql`

Cosmetic cross-chunk layout inconsistency: C1 uses a boxed `-- ===…===` banner, C2 uses a plain
`-- object.name (Ebene B / global — …)` one-liner; the `@see` anchor appears in some C2 `up/` files
but no C1 files. Both are internally consistent per chunk.

**Fix:** pick one header shape (the richer boxed C1 form) and record it in `db-migrations/README.md`
§3, or accept the divergence — low priority.

### logic-B1-1 — `RETURN -1` contract is unreachable dead code (Nice-to-have, green)

**Files:** `db-migrations/eazybusiness/sprocs/Robotico.spEnsureArticleCustomField.sql` (lines 9, 39–40,
102–103), and the dependent dead guards in `Robotico.spSetArticleCustomFieldValue.sql`
(`IF @returnCode <> 0 RETURN -1`), `CustomWorkflows.spArticleAppendPriceHistory.sql` and
`...spArticleAppendLabelHistory.sql` (`IF @returnCode <> 0 RETURN`)

Verified: the `RAISERROR('Custom field definition not found …', 16, 1, …)` at line 39 sits inside a
TRY block; severity 16 transfers control to the CATCH (line 102, which `THROW`s), so `RETURN -1` at
line 40 is unreachable. The documented "-1 when the definition is not found" contract (header line 9)
never fires — the proc throws instead — so every caller's return-code guard is dead code.
`CustomFieldAPI_Tests.sql` Test 6 confirms this: it passes via its CATCH branch, not the
`@returnCode = -1` branch. Benign at runtime (error still surfaces); a maintenance trap. Faithful
port (identical to `WorkflowProcedures/api/CustomFieldAPI.sql:161-162,317`), pre-existing.

**Fix:** either drop the `RETURN -1` + the dead `IF @returnCode <> 0` guards and document "raises on
missing field definition", or move the `IF @kAttribut IS NULL` check out of the TRY / replace
`RAISERROR`+`RETURN` with a plain `RETURN -1` so the code matches its documented contract.

### logic-B1-2 — label names not sanitised before writing to a `;`-delimited entry (Nice-to-have, green)

**File:** `db-migrations/eazybusiness/sprocs/CustomWorkflows.spArticleAppendLabelHistory.sql`

Verified against the logic audit: labels are stripped of commas only (to protect the in-field `', '`
separator) but not run through `Robotico.fnEscapedCSVSanitize` before being written into the
semicolon-delimited entry `CONCAT_WS('; ', date, @currentLabels, @userName)`. A label containing `;`
(or CR/LF) corrupts field structure: on the next run `fnEscapedCSVGetField(@lastEntry, 2, ';')`
returns a truncated `@lastLabels`, so change-detection compares a truncated last-set against the full
current-set, reports a spurious change, and appends a redundant identical history line every run
(bounded only by the 1000-line trim). A rarer secondary divergence: current labels order by `l.cName`
(with comma) while the read-back re-aggregates `ORDER BY t.label` (comma-stripped), which can flip the
comparison for comma-bearing labels. Data-dependent, low-probability, self-limiting; ported/pre-existing.

**Fix:** run each label through `Robotico.fnEscapedCSVSanitize` (or at minimum strip `;` and CR/LF) on
the write side, mirroring the EscapedCSV "sanitise before write" contract the rest of the API follows.

### T1 — coverage gap: two DB-mutation actions ship untested (Nice-to-have, green)

**Files:** `db-migrations/eazybusiness/sprocs/CustomWorkflows.spGebindeErstellen.sql`,
`CustomWorkflows.spZustandartikelLieferantSetzen.sql`

`spGebindeErstellen` and `spZustandartikelLieferantSetzen` are non-trivial DB-mutation workflow
actions (article/supplier-number suffixing, `tGebinde` creation) shipping with zero test coverage, so
a logic regression would be silent. Consistent with the approved plan scope (§7 ports only pre-existing
`*_Tests.sql`; the source had none for these two) — **not a plan violation**, surfaced so the gap is a
conscious decision. The 5 PayPal sprocs are also untested but make external PayPal REST calls and are
not unit-testable in this harness (accepted). All 12 functions and the history/custom-field/duplicate
sprocs are well covered. The SQL suites are manual-integration-only (require writes to a live mandant),
so no coverage/regression numbers were obtainable under the no-writes constraint; lint is green (exit 0).

**Fix:** optionally add a transaction-rolled-back `*_Tests.sql` for the two actions (HAN/GTIN-match,
unique-supplier-number, standard-condition-untouched, idempotent-suffix branches), following the ported
-suite pattern. No action required if the accepted-scope decision stands.

## Eliminated findings

None — every reported finding was validated as real against the code at HEAD.

## Cross-cut patterns

- **Documentation-accuracy vs. code:** convention-B1-1 is the only Important finding — it is a
  doc-side inaccuracy (the shipped schema is fine), so the fix lives entirely in
  `NAMING-CONVENTIONS.md`. convention-B1-3 is a related, lower-priority doc/convention item.
- **Convention harmonization pass:** B1-2 (NOCOUNT) and B1-3 (headers) both stem from the C1 port
  normalization not being applied uniformly to the five PayPal files — they cluster on the PayPal
  proc set and can be fixed together.
- **Pre-existing ported-logic edge cases:** logic-B1-1 and logic-B1-2 are both faithful verbatim
  ports of latent issues in `WorkflowProcedures/*`; neither was introduced by this block. They can be
  fixed as a small hardening pass on the CustomField/history layer or explicitly accepted as
  pre-existing.
</content>
</invoke>
