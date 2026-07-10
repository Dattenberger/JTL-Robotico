# Block B1 — AUDIT-TEST report (TOPIC = test)

**Date:** 2026-07-10T00:57:22+02:00
**Scope:** block B1 test diff `9592c99..HEAD` filtered to `db-migrations/tests/**`
**Verdict:** No Critical/Important test defects. One Nice-to-have coverage gap (surfaced, consistent with the approved plan scope).

## Project test conventions (Step 0)

This is a SQL-only repo with **no test framework** (plan §7, CONVENTIONS). Testing is three
static/half-static layers:

1. **Convention lint** — `db-migrations/tests/lint-migrations.ps1`, the CI-capable executable
   form of `db-migrations/README.md` rules (a)–(g). This is the `test_command` /`lint_command`.
2. **Object compare** — `compare-objects.sql` (read-only file↔DB hash inventory).
3. **Ported SQL test suites** — manual integration suites moved verbatim from
   `WorkflowProcedures/*_Tests.sql`; documented manual run against a test mandant.

Hard constraint: **no writes to any SQL server**. The SQL suites all write (synthetic orders,
custom-field bindings, price/label updates) inside `BEGIN TRAN … ROLLBACK`, so they are
inherently **not runnable in this environment** and depend on a specific mandant
(`eazybusiness_tm2`) with fixed article IDs (19807/73/234) and seed order pair 236/237. This is
by design (plan §7 item 3) — audited against that convention, not against a unit-test preference.

## Step 1 — static quality (lint = the only runnable layer)

`pwsh db-migrations/tests/lint-migrations.ps1` → **exit 0**, 47 files scanned, 0 errors,
10 warnings. All 10 warnings are rule (g) dynamic-SQL heuristics on the C2 `reset.internal_*`
procs (CloneDatabase, GrantAccess, RegisterMandant) — pre-existing, documented in the C2/C4
summaries, and correct (object/DB names go through QUOTENAME; the flagged `+ @var` are inside
`RESTORE … MOVE`/`ALTER … MODIFY NAME` object-name construction, not data injection). Not new,
not this topic's concern.

Test-suite quality (the 5 ported SQL files + teardown):

- **Test names describe behavior + condition** — yes. Section labels in `#TestResults`
  ("older false / newer true", "different quantity -> false", "cancelled predecessor ignored",
  "spCheckDuplicateOrder return paths") and the `PRINT '--- Test N: … ---'` headers are all
  behavior/condition phrased.
- **Assertions concrete** — yes: exact expected values, `IS NULL`, `= @secondValue` read-backs,
  BIT/RETURN/OUTPUT triple-checks, line-count and window-boundary assertions. No snapshotting.
- **Transactional isolation** — every mutating test wraps `BEGIN TRAN … ROLLBACK` with a
  `TRY/CATCH` + `@@TRANCOUNT` guard, and each suite ends with an explicit **clean-state
  verification test** (CustomFieldAPI Test 8, HistorySPs Test 14) — a good pattern that catches
  a broken rollback.
- **No mock convention issue** — no mocking framework exists; synthetic fixtures via temp procs
  (`#CreateTestOrder`, `#GetHistoryInfo`) is the right approach and each is file-local (no
  cross-file helper duplication).
- **Doc-trail (production-code fixes during testing)** — none. All 27 deploy objects are
  faithful ports; no chunk report claims a code-bug found via tests, and the diff shows no
  production edit lacking a report entry. No `test-undocumented-code-fix`.
- **Helper/boilerplate duplication** — the ~40-line summary+cursor epilogue (`#TestResults`
  aggregate → pass/fail cursor) is repeated in all four `eazybusiness/*_Tests.sql`. Acceptable:
  these are standalone, independently-runnable ported scripts; consolidating into a shared
  include would couple them and diverge from the source. Noted, not a finding.

## Step 2 — dynamic (coverage + cross-chunk regressions)

**Not executable here** (no-writes constraint; suites need a live mandant). No coverage tool
exists for T-SQL in this repo and none is defined in CONVENTIONS. Therefore:
- No coverage % obtainable; assessed coverage by object inventory instead (below).
- **Cross-chunk regressions:** cannot be exercised. Mitigation: the block is one migration tree
  (functions/sprocs are independent `CREATE OR ALTER` objects, no shared mutable test state
  across files), and the lint — the one cross-cutting runnable check — is green.

### Coverage by object inventory

| Object group | Objects | Tested |
|---|---|---|
| `Robotico.fn*` (12 functions) | all string/CSV/customfield/duplicate fns | **12/12** ✅ (StringAndCSVUtilities, CustomFieldAPI, DuplicateOrders suites) |
| History + CustomField sprocs | spEnsure/spSet ArticleCustomField, spArticleAppend{Price,Label}History, spArticleUpdateAllHistory, spCheckDuplicateOrder | **6/6** ✅ |
| PayPal sprocs | Robotico.spPaypal{GetAccessToken,CreateAccessToken,TrackingCallApi}, CustomWorkflows.spPaypalTracking{Versand,Lieferschein} | **0/5** — external PayPal REST calls (`sp_invoke_external_rest_endpoint`); source had only manual API scripts under `PayPal/Test/`, not assertion suites. Not unit-testable in-harness. Accepted. |
| Other CustomWorkflows actions | spGebindeErstellen, spZustandartikelLieferantSetzen | **0/2** — pure DB-mutation logic, testable in principle; no `*_Tests.sql` existed in the source to port. **Gap (see finding).** |

Function coverage is thorough (branch-level: NULL/empty/whitespace/invalid/boundary cases for
every string+CSV fn; duplicate detection covers tie-break, time window ±, cancelled predecessor,
same-total-different-qty, same-total-different-article, and the 3-way sp return contract). The
gap is confined to the 7 sprocs above, all consistent with the plan's approved "port existing
tests" scope. `compare-objects.sql` does list all 7 (Robotico.* + CustomWorkflows.sp* branches),
so the post-JTL-update smoke check still guards them structurally even without functional tests.

## Findings

| ID | Severity | Description | Marker |
|---|---|---|---|
| T1 | Nice-to-have | `CustomWorkflows.spGebindeErstellen` and `spZustandartikelLieferantSetzen` — non-trivial DB-mutation actions (article/supplier-number suffixing, tGebinde creation) — ship with **zero test coverage**. A logic regression would be silent. Consistent with plan §7 (only pre-existing `*_Tests.sql` were ported; the source had none for these), so not a plan violation — surfaced so the coverage gap is a conscious decision. The 5 PayPal sprocs are also untested but are external-REST and not unit-testable here (accepted). | coverage-gap |

No Critical/Important findings. Lint green; no undocumented code fixes; no detectable
regressions; test quality (naming, assertions, isolation, clean-state checks) is sound.

## Files outside assigned scope (drift)

none — read-only audit, no files modified.
