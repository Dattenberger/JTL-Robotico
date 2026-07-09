# C3 — Self-Fix (fresh eyes) report

**Chunk:** C3 · **Block:** B1 · **Date:** 2026-07-10T00:57:22+02:00
**Reviewer:** self-fix agent (fresh eyes on wave commit `172a280`)

## What I did

Reviewed the C3 diff (§4 read-only probes + §6 hygiene/cleanup scripts + their
runbooks) under three lenses — plan correctness, code quality, doc/test quality.
Re-ran the lint (`pwsh db-migrations/tests/lint-migrations.ps1`) → **OK, 0 errors,
0 warnings**. No inline fixes were needed; the implementation is complete and
defensible.

## Review findings (all lenses)

**Plan correctness (§4 + §6 acceptance):**
- All 9 named artefacts exist at the exact plan-table paths (4 probes + validation
  runbook; 3 cleanup scripts + hygiene runbook), plus the plan Open-Questions edit.
- §4: probes are strictly read-only (SELECT/catalog + read-only dynamic SQL);
  `01`/`03`/`04` executed against test1 with results recorded in-file and in the
  plan (O1/O2/O4). `02` correctly written as a manual probe (needs a running
  worker — not answerable read-only). Validation runbook numbers the E2E sequence
  (Step 0–6), includes rollback (Step 6 drop-clone), and maps O1/O2/O4 to expected
  values (Step 5 table). ✅
- §6: every cleanup script carries the "MANUAL EXECUTION ONLY — PRODUCTION IMPACT"
  banner; every mutating statement is commented out; lint rule (f) confirms it. ✅
- The one documented deviation (probes 03/04 iterate all `eazybusiness*` DBs via a
  cursor rather than one invocation per DB) is a serviceability win (D4), correctly
  documented, no impact on later chunks. Concur.

**Code quality:**
- Dynamic SQL in 03/04 interpolates only the DB name via `QUOTENAME`; row data
  goes through `sp_executesql` parameters — safe, matches the §7 lint's rule (g)
  intent. Comments explain WHY (D9 rationale, wildcard `kZiel=-1`, estimate-vs-exact
  row counts), not WHAT.
- `sys.partitions` roll-up (`index_id IN (0,1)`, `SUM(p.rows)`) is the correct
  heap-or-clustered coverage estimate for the queue inventory.
- Probe 03's CATCH-branch ambiguity (an unreadable DB and a genuinely table-less DB
  both record `HasPfUserTable=0`) is a real but acceptable diagnostic limitation —
  already documented in-file and in the impl report. Not a defect for an
  admin-run probe; no issue raised.
- Cross-reference links (runbooks → probes, cleanup .md → runbooks, → research)
  resolve: `db-migrations/README.md`, `research/2-instanz-survey`,
  `research/4-jtl-spezifika`, `Projekte/Testsystem/{register-mandant,copy_test_db}.sql`
  all exist.

**Doc/test quality (SQL-only repo — lint is the test surface):**
- New runbooks + probe `.md` files are English per the language convention; German
  appears only as direct survey citations in `hygiene-findings.md` (acceptable).
- No secrets: shop license referenced by name only ("use the staging shop license,
  never a prod key committed to git").
- Lint re-run green.

## Issues

| ID | Severity | Description (what + file:line) | Status | Marker |
|---|---|---|---|---|
| — | — | none | — | — |

## Inline fixes applied

None — the chunk needed no changes.

## Files modified

None.

## Files outside assigned scope (drift)

none.

## Final test result

`pwsh db-migrations/tests/lint-migrations.ps1` → **OK: 0 errors, 0 warnings.**
