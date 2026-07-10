# Repair W1-4 — B1 logic cluster (green / nice-to-have)

**Date:** 2026-07-10T00:57:22+02:00
**Agent:** repair-fix (W1-4)
**Cluster:** logic-B1-1, logic-B1-2 (both green, Nice-to-have)
**Test command:** `pwsh db-migrations/tests/lint-migrations.ps1` → **OK: 0 errors, 10 warnings** (the 10 warnings are pre-existing, in unrelated `global/sprocs/reset.*` files; none in my files).

## logic-B1-1 — dead return-code contract on the custom-field API — FIXED

`Robotico.spEnsureArticleCustomField` documented a `-1` return "when the custom
field definition is not found", but the `RAISERROR(..., 16, 1, ...)` that guards
that path sits inside a `TRY`; severity 16 transfers control to the outer `CATCH`
(which `THROW`s), so the following `RETURN -1` was unreachable and every caller's
`IF @returnCode <> 0` guard was dead code.

Chosen resolution (suggested-fix option A, D4 — the long-term-honest one): make
the API **throw-based** and delete the dead code, rather than converting the
`RAISERROR` into a silent `RETURN -1`. Rationale: a missing custom-field
definition is a deployment/config error; throwing surfaces it loudly, whereas a
silent `-1` would make the two history procs silently no-op on misconfiguration.
Throwing is also already the proc's de-facto runtime behavior, so this changes
**documentation + dead code only, not runtime behavior**. Confirmed the sole
callers are the three procs below plus the manual test suites; the tests accept
the throw path (`CustomFieldAPI_Tests.sql` Test 6 checks `-1` **OR** a thrown
`%Custom field definition not found%`, so it still passes).

Edits:
- `Robotico.spEnsureArticleCustomField.sql` — removed unreachable `RETURN -1`;
  header now states it raises (not returns `-1`); added a gotcha comment
  explaining why no `RETURN` follows the `RAISERROR`.
- `Robotico.spSetArticleCustomFieldValue.sql` — removed dead
  `IF @returnCode <> 0 RETURN -1` guard and the now-unused `@returnCode` capture
  (`EXEC @returnCode = …` → `EXEC …`); header updated to the throw contract.
- `CustomWorkflows.spArticleAppendPriceHistory.sql` — removed dead
  `IF @returnCode <> 0 RETURN` guard + `@returnCode` capture.
- `CustomWorkflows.spArticleAppendLabelHistory.sql` — same guard/capture removal.

## logic-B1-2 — label names not fully sanitised + write/read-back ordering skew — FIXED

`spArticleAppendLabelHistory` stripped only commas from label names before
writing them into the semicolon-delimited entry, so a label containing `;` or
CR/LF corrupted the field structure (truncated read-back → spurious change → a
redundant identical history line every run). Secondary skew: the write side
ordered `WITHIN GROUP (ORDER BY l.cName)` (raw, with comma) while the read-back
re-aggregated `ORDER BY t.label` (comma-stripped), which could flip the
comparison for comma-bearing labels.

Fix (suggested primary — reuse the existing EscapedCSV write primitive): each
label is now `Robotico.fnEscapedCSVSanitize(REPLACE(l.cName, ',', ''), NULL)` —
comma stripped first (protects the in-field `', '` separator), then sanitised
(removes `;`, quotes, CR/LF) — inside a derived table, and the aggregate orders
`WITHIN GROUP (ORDER BY t.label)` over that normalized column. This makes the
write side structurally identical to the read-back
(`STRING_AGG(t.label, …) WITHIN GROUP (ORDER BY t.label)` over a derived table),
so identical label sets compare equal regardless of commas. Header comment
updated to document the sanitise-before-write contract and the symmetric
normalization.

Note: `HistorySPs_Tests.sql` Test 11 (comma-in-label + double-call stability)
directly exercises this path and its intent is preserved/strengthened by the fix;
it is a manual integration test requiring DB writes, which the run's hard
constraints forbid, so it was not executed here.

## Skipped / out-of-scope observations (no scope expansion)

- `spArticleAppendPriceHistory` has the **same** dead-`RETURN`-after-`RAISERROR`
  pattern in its own "Article not found" block (`RAISERROR('Article not found: %d',
  16, 1, …); RETURN;` inside the `TRY`). Left as-is: it is not in either finding's
  scope (the findings target the `spEnsure` `-1` contract and its caller guards),
  and the `RAISERROR` there is correct — only the trailing `RETURN;` is inert.
  Flagged here so a re-audit can decide whether to clean it up.

## Files modified

- `db-migrations/eazybusiness/sprocs/Robotico.spEnsureArticleCustomField.sql`
- `db-migrations/eazybusiness/sprocs/Robotico.spSetArticleCustomFieldValue.sql`
- `db-migrations/eazybusiness/sprocs/CustomWorkflows.spArticleAppendPriceHistory.sql`
- `db-migrations/eazybusiness/sprocs/CustomWorkflows.spArticleAppendLabelHistory.sql`

## Drift

none — all edits are within the cluster's four assigned files. (Other uncommitted
changes present in the worktree — `db-migrations/README.md`, the PayPal
`SET NOCOUNT ON` additions, `docs/SQL/NAMING-CONVENTIONS.md`,
`…impl-state.md` — pre-date this repair and are **not** mine.)
