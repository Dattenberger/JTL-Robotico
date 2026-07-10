# Block B1 — Logic Audit

**Topic:** logic (logic errors + edge cases: boundaries, null/empty, off-by-one, races, error-path coverage)
**Block:** B1 (chunks C1–C4)
**Diff base:** 9592c99..HEAD (file-scoped to BLOCK_FILES)
**Timestamp:** 2026-07-10T00:57:22+02:00
**Grounding loaded:** knowledge-sql (NULL safety, optional-parameter pattern), knowledge-jtl-sql (active-flag/PK quirks)

## Summary

Block B1 is an all-new addition (6649 insertions): the Ebene-A object tree
(functions + sprocs ported from `WorkflowProcedures/*`), the Ebene-B global
reset pipeline (new orchestration), the migration/lint harness, probes and docs.
The new orchestration code (reset pipeline, ops schema, duplicate-detection
refactor, `deploy.ps1`) is carefully guarded — cross-DB work is parameterised,
every internal step is triple-guarded against `@TargetDb='eazybusiness'`, the
`ops.*` schema columns line up exactly with every reference in the pipeline, and
the request state machine + filtered unique index + applock are consistent. The
duplicate-order engine's staged fingerprint, tie-break on equal timestamps, and
gross-value rounding are correct.

Two genuine but low-severity logic issues remain, both in the ported
`CustomFieldAPI` / history layer and both pre-existing (faithful ports — verified
identical to the `WorkflowProcedures/*` originals). No Critical/Important logic
defects found in the new code.

## Findings

### logic-B1-1 — `RETURN -1` contract is unreachable dead code (Nice-to-have)

**Files:**
`db-migrations/eazybusiness/sprocs/Robotico.spEnsureArticleCustomField.sql:52-56`
(the `RAISERROR(...,16,1,...)` + `RETURN -1`), and the dead downstream branches
that depend on it:
`db-migrations/eazybusiness/sprocs/Robotico.spSetArticleCustomFieldValue.sql`
(`IF @returnCode <> 0 RETURN -1`),
`db-migrations/eazybusiness/sprocs/CustomWorkflows.spArticleAppendPriceHistory.sql`
and `...spArticleAppendLabelHistory.sql` (`IF @returnCode <> 0 RETURN`).

**What's wrong:** `RAISERROR` with severity 16 issued *inside a `TRY` block*
transfers control straight to the associated `CATCH` (which does `THROW`). So the
`RETURN -1` on the next line never executes. When the custom-field definition is
missing, the proc **throws** rather than returning `-1`. Every documented "returns
`-1` when the definition is not found" contract, and every caller's
`IF @returnCode <> 0 …` guard, is therefore dead code — the callers never observe
a return code because the callee has already raised.

**Evidence it is the real behaviour:** `db-migrations/tests/eazybusiness/CustomFieldAPI_Tests.sql`
Test 6 is written to pass via *either* `IF @returnCode = -1` **or** its `CATCH`
branch (`ERROR_MESSAGE() LIKE '%Custom field definition not found%'`). The
`@returnCode = -1` branch is the dead one; the throw path is what actually fires.

**Impact:** benign at runtime (the error still surfaces, just as an exception
instead of a graceful code). The risk is maintenance: a future caller that relies
on the documented `-1` return will silently get an unhandled throw instead.

**Provenance:** faithful port — identical to `WorkflowProcedures/api/CustomFieldAPI.sql:161-162`
and `:317`. Pre-existing, not introduced by this block.

**Suggested fix (or leave as documented pre-existing):** either drop the `RETURN -1`
and the dead `IF @returnCode <> 0` guards and document "raises on missing field
definition", or move the `IF @kAttribut IS NULL` check out of the `TRY` (or replace
`RAISERROR`+`RETURN` with a plain `RETURN -1`) so the code matches its documented
contract.

### logic-B1-2 — label names not sanitised before writing to a `;`-delimited entry (Nice-to-have)

**File:** `db-migrations/eazybusiness/sprocs/CustomWorkflows.spArticleAppendLabelHistory.sql`
(the `@currentLabels` `STRING_AGG(... REPLACE(l.cName, ',', '') ...)` and the
`CONCAT_WS('; ', ..., @currentLabels, @userName)` entry it is written into).

**What's wrong:** label names are stripped of commas only (to protect the `', '`
in-field separator) but are **not** run through `Robotico.fnEscapedCSVSanitize`
before being placed into a semicolon-delimited entry line. If a label name
contains a `;` (or CR/LF), the entry's field structure is corrupted: on the next
run `Robotico.fnEscapedCSVGetField(@lastEntry, 2, ';')` splits on `;` and returns
a truncated `@lastLabels`, so the change-detection compares a truncated
"last" set against the full current set, reports a spurious change, and appends a
redundant identical history line on **every** workflow run (bounded only by the
1000-line trim). A secondary, much rarer divergence exists in the re-sort
(`current` orders by `l.cName` *with* comma; the read-back re-aggregates
`ORDER BY t.label` on the comma-stripped value), which can also flip the
comparison for comma-bearing labels.

**Impact:** data-dependent and low-probability (label names rarely contain `;` /
CR / LF), self-limiting via the trim. Cosmetic history noise, not data loss.

**Provenance:** ported logic from `WorkflowProcedures/history/spArticleAppendLabelHistory.sql`;
pre-existing.

**Suggested fix:** run each label through `Robotico.fnEscapedCSVSanitize` (or at
least strip `;`/CR/LF) on the write side, mirroring the EscapedCSV "sanitise before
write" contract the rest of the API follows.

## Out-of-scope observations (for the consolidator)

- **convention / robustness (not logic):** the ported PayPal procs
  (`Robotico.spPaypalCreateAccessToken.sql`, `...TrackingCallApi.sql`) do no
  HTTP-status checking and build `PRINT`/`INSERT` strings by concatenating
  `@ResponseStatus` / `@ResponseText`; if `sp_OAMethod` leaves those NULL the whole
  concatenated string becomes NULL. This is a faithful verbatim port and explicitly
  documented as such, so not flagged as a new logic defect — noted for awareness.
- **`deploy.ps1` PROD gate** correctly fires for BASELINE and skips only for
  `-DryRun`; logic verified, no finding.

## Coverage note

**Audited (read in full):** all 12 `Robotico.fn*` functions; all Ebene-A sprocs
(`spEnsureArticleCustomField`, `spSetArticleCustomFieldValue`, `spCheckDuplicateOrder`,
the 3 history sprocs, `spGebindeErstellen`, `spZustandartikelLieferantSetzen`, the
3 PayPal sprocs, the 2 PayPal workflow-action sprocs); the PayPal table DDL
(`0002_robotico_paypal_tables.sql`) cross-checked against the procs' positional
INSERT / column reads (consistent); the full reset pipeline (`StartTestmandantReset`,
`ProcessNextResetRequest`, `GetResetStatus`, all 8 `internal_*` steps);
`0001_roboticoops_settings.sql`, `0002_ops_schema_tables.sql`,
`0011_signing_certificate.sql`, `0020_seed_mandant_template.sql`,
`reset.EnsureAgentJob.sql`, `permissions/100`+`900`; `deploy.ps1`; Test 6 of
`CustomFieldAPI_Tests.sql`.

**Skimmed / structure-only (not deep logic surface):** the remaining test files
(`StringAndCSVUtilities_Tests.sql`, `DuplicateOrders_Tests.sql`, `HistorySPs_Tests.sql`,
teardown) — belong to the `test` topic; `lint-migrations.ps1`, `compare-objects.sql`,
`validate_structure.sql`, the read-only probes, and all Markdown docs/runbooks/ADRs
(no runtime logic). `0001_robotico_schema.sql` (schema-only).
