# Implementation Report — mssql-ops-infrastruktur

**Plan:** [→ mssql-ops-infrastruktur.md](../mssql-ops-infrastruktur.md)
**Aggregated:** 2026-07-10 (Phase 4.7, read-only) · **Aggregator:** implementation-reporting
**Run:** plan `wf_50fde12a-9be` (Phase 3) + finalize `wf_e523c9ab-28a` (Phase 4)

## Counters

| Dimension | Value |
|---|---|
| Blocks / chunks / waves | 1 block (B1) · 4 chunks (C1–C4) · 1 repair wave (W1) |
| Agents (Phase 3 / Phase 4) | 28 impl+audit+repair / 15 docs workers (+3 failed, spend limit) |
| Errors during runs | 0 |
| Tracked issues (all sources) | 11 |
| Audit findings → validated → eliminated | 6 → 6 → 0 |
| Repair-wave outcome | 5 fixed, 1 skipped (T1, accepted) → re-audit **converged** (findings: []) |
| Documented deviations | 16 (C1 ×5, C2 ×9, C3 ×1, C4 ×1) — all D4-defensible |
| E2E | 6 auto + 1 refresh **pass**, 0 fail, 5 manual pending (TC-M1…M5) |
| Docs | 11 targets reconciled, 1 inline group anchored, 1 substantive doc bug fixed |
| Classification | 🔴 0 · 🟠 8 · 🟢 9 (green listed by family) |

**Headline:** The block landed cleanly — no Critical defects, no escalations, no
postponed blockers. The repair wave converged on the first pass and the re-audit found
nothing new (no cascade). The two things a reviewer should actually look at are process
obligations, not code defects: (1) **3 plan-scoped ADR drafts must be promoted before
archival**, and (2) **inline anchors for the `tests/` harness + peripheral/legacy files
may be incomplete** because 3 doc-inline agents were killed by the Anthropic monthly
spend limit — their reports claim "no-change-needed", but that verdict was produced under
degraded conditions and warrants a 2-minute spot-check.

---

## 🔴 needs-research

**None.** No Critical issue, no issue that needed ≥2 repair attempts, no escalation, no
repair wave with drift ≥5 files, and the re-audit introduced no new findings (converged,
no cascade). Nothing on this run requires a follow-up research agent.

---

## 🟠 review-recommended

1. **[deviation, architecture — resolved] `CustomWorkflows._CheckAction` /
   `_SetActionDisplayName` are JTL-module VENDOR objects, not ported (C1).** The plan
   (§1, D10, research/1.1) treated these as "our stable API to create/own for excel_ekl".
   C1 proved via `docs/SQL/JTL-CUSTOM-WORKFLOWS.md` (live `OBJECT_DEFINITION`) that they
   are provided by the JTL "Custom Workflow Actions" module (vendor, since Wawi 1.6) and
   only ever `EXEC`'d, never `CREATE`'d in the repo. **No object files were created for
   them; all 7 `CustomWorkflows.sp*` action registrations are guarded**
   (`IF OBJECT_ID(...) IS NOT NULL … ELSE PRINT`). The framing was corrected across
   `db-migrations/README.md` §6, `NAMING-CONVENTIONS.md` §10, and
   `MSSQL-OPS-ARCHITECTURE.md` (issue C1-1). Verify: the "module prerequisite" framing is
   the intended contract and both excel_ekl and this repo are consumers.

2. **[deviation, scope — resolved] 3 extra PayPal API procs ported (C1).**
   `Robotico.spPaypalGetAccessToken` / `spPaypalCreateAccessToken` / `spPaypalTrackingCallApi`
   were **not named in plan §1** — research/5 §3 under-inventoried `PayPal/Add Procudures
   and Tables.sql` (listed only its 3 tables). They are deployed objects the
   `CustomWorkflows.spPaypalTracking*` actions call at runtime; omitting them would break
   the PayPal action chain. Ported into `sprocs/Robotico.spPaypal*.sql`. Verify: the
   inventory gap in research/5 is understood and the 3 procs belong in the chain.

3. **[Important, resolved doc-side] convention-B1-1 — Naming SSoT lied about the Ebene-B
   convention.** `NAMING-CONVENTIONS.md` §9 claimed `ops.*` / `reset.*` "follow sections
   2–4" (i.e. `t<Name>` tables, Hungarian `k/n/c/…` prefixes), but the shipped admin-DB
   objects deliberately use PascalCase unprefixed identifiers (`ops.Mandant`,
   `MandantKey`, `@TargetDb`, `reset.StartTestmandantReset`). The shipped schema is fine;
   the **doc was the inaccurate side** and would have led a maintainer to add
   `ops.tSomething`/`cName` and drift the schema. Fixed by rewriting §9 to document the
   admin-DB convention (repair W1-1); shipped tables/columns correctly left unrenamed.

4. **[Important, worked-around not fixed] C2-1 — lint classifies `runAfterOtherAnyTimeScripts/`
   as an object-anytime folder.** `lint-migrations.ps1` enforces single-`Schema.Object`
   CREATE + matching filename there, but README §2 designates that folder for the
   (non-object) agent-job wrapper. C2 worked around it with a **self-executing wrapper
   proc** (`reset.EnsureAgentJob` with `EXEC reset.EnsureAgentJob;`) so the lint passes.
   The cleaner fix (exempt that folder in the lint) was left undone — foreign file (C1
   scope). Verify whether the lint should be relaxed for that folder, or the wrapper-proc
   pattern is the intended permanent shape.

5. **[process — blocks archival] 3 plan-scoped ADR drafts are unpromoted.**
   `adr-grate-migration-runner` (D1), `adr-two-chain-migration-paths` (D2/D3),
   `adr-module-signing-reset` (D5/D6) are `Status: Proposed (plan-scoped — pending
   promotion)` under the plan's `adrs/`. `docs/decisions/` does not exist yet. They must be
   promoted (assign `NNNN`, move to `docs/decisions/`, add index row, rewrite cross-refs —
   `MSSQL-OPS-ARCHITECTURE.md` links the draft paths directly) **before the plan is
   archived**. Out of scope for doc workers; a plan-lifecycle obligation.

6. **[gap — needs spot-check] Inline anchors for `tests/` + peripheral/legacy possibly
   incomplete (spend-limit fallout).** State file records **3 doc-inline agent failures**
   (DOCS-INLINE-tests-harness ×2, DOCS-INLINE-peripheral-hygiene-legacy ×1) caused by the
   Anthropic **monthly spend limit**, and the budget note states "some inline anchors for
   the tests harness + peripheral hygiene/legacy files are MISSING." The corresponding
   verify-reports (`docs-inline-tests-harness.md`, `docs-inline-peripheral-hygiene-legacy.md`)
   exist and claim **no-change-needed** (repair wave 1 already added anchors). These two
   claims are in tension. Recommend a 2-minute spot-check that `db-migrations/tests/**`,
   `Berechtigungen/cleanup/0{1,3}.sql`, and `setup-test-environment.ps1` actually carry
   their `@see` anchors before trusting the "no-change-needed" verdict.

7. **[substantive doc bug — fixed] Reset-validation runbook seeded a mandant key the
   shipped CHECK constraint rejects.** `testmandant-reset-validierung.md` used `tmv`, which
   violates the shipped `CK_ops_Mandant_MandantKey CHECK (MandantKey LIKE 'tm[0-9]%')` — the
   runbook's happy path could **never run**. Docs-final renamed `tmv`→`tm9` throughout and
   expanded the constraint `[!NOTE]`. Residual `tmv` mentions remain in two non-touched
   artifacts (plan body §L412 = historical record, keep; `reports/e2e-runbook.md` §L147 =
   transient orchestration artifact) — flagged, low urgency.

8. **[repair drift — sanctioned] Repair wave touched files outside the findings' `files`
   arrays.** W1-3 edited `db-migrations/README.md` §3 (the finding's own suggested fix
   directed recording the header convention there); W1-1 rewrote `NAMING-CONVENTIONS.md`
   §9. Both are the intended fix targets, not scope creep, but per the drift rule any
   repair drift ≥1 file is surfaced. See the drift list.

---

## 🟢 informational

Fully resolved or consciously accepted; listed compactly by family (**9 families** below).

- **Convention harmonization (repair W1, all fixed):** `SET NOCOUNT ON;` added to the 5
  PayPal procs that lacked it (convention-B1-2); file-header convention recorded in
  README §3 rather than mass-reformatting 45 files (convention-B1-3).
- **Ported-logic edge cases (repair W1, both fixed — pre-existing faithful ports):**
  unreachable `RETURN -1` dead code + dead caller guards removed across 4 CustomField/
  history procs, headers switched to the throw contract (logic-B1-1); label names now run
  through `Robotico.fnEscapedCSVSanitize` on the write side with symmetric ORDER BY,
  closing a spurious-history-line path (logic-B1-2).
- **Accepted coverage gap (T1, skipped by design):** `spGebindeErstellen` +
  `spZustandartikelLieferantSetzen` ship untested — the source had no `*_Tests.sql` to
  port (plan §7 ports only pre-existing suites) and a valid red→green test is impossible
  under the no-writes constraint. Documented conscious decision, not a defect.
- **Self-fix polish:** `$env`→`$envConfig` rename in `deploy.ps1` (collision-readability,
  C1-SF); architecture-doc file count `~15`→`~20` (C4-SF). No defects found in C2/C3 self-fix.
- **Impl-time normalizations (C1, all documented):** `GO;`→`GO`, `IF EXISTS DROP+CREATE`
  → `CREATE OR ALTER`, stripped redundant per-file transaction/PRINT scaffolding (grate
  wraps each deploy), `SET ANSI_NULLS/QUOTED_IDENTIFIER ON` preserved for the filtered-index
  gotcha (error 1934), lint rule (g) heuristic tightened to real dynamic-SQL contexts.
- **E2E-1 (nice-to-have, fixed inline):** reset-validation runbook TC-5 didn't note that
  probe `01_worker_ttarget_semantics.sql` needs `-d eazybusiness` (default `master` →
  Msg 208); orchestrator fixed it together with the `tmv`→`tm9` drift.
- **C2-2 (nice-to-have, accepted):** `reset.internal_ApplyJtlRoles` member list duplicates
  `Berechtigungen/JTL-Rollen.sql`; kept in sync by comment (no shared table exists).
- **Docs-final minor flags (5, all navigability/wording, no correctness impact):**
  `tmv`→`tm9` residuals; JTL-CUSTOM-WORKFLOWS back-link; runbook-index "Phase 7" wording;
  optional architecture↔naming cross-link; README §8 test-table subset (self-resolves once
  the tests README exists).
- **Doc gap (1, follow-up default: no):** `db-migrations/tests/` has no dedicated README;
  the harness is only described from the architecture doc + inline anchors.

---

## Full issue list (chronological)

| # | ID | Source | Severity | Status | Summary |
|---|---|---|---|---|---|
| 1 | C1-1 | C1 impl | Important | resolved (docs) | `_CheckAction`/`_SetActionDisplayName` = vendor objects; D10 reframed as shared module consumption |
| 2 | C1-SF-1 | C1 self-fix | Nice-to-have | resolved later | forward-ref to `rollout-mssql-ops.md` (later-chunk deliverable; resolved when C4 landed) |
| 3 | C2-1 | C2 impl | Important | worked-around | lint anytime-folder classification vs agent-job wrapper; wrapper-proc workaround |
| 4 | C2-2 | C2 impl | Nice-to-have | accepted | `ApplyJtlRoles` member-list duplication (comment-synced) |
| 5 | convention-B1-1 | audit-convention | Important | fixed (W1-1) | Naming SSoT §9 misdescribed Ebene-B PascalCase convention |
| 6 | convention-B1-2 | audit-convention | Nice-to-have | fixed (W1-2) | 5 PayPal procs missing `SET NOCOUNT ON` |
| 7 | convention-B1-3 | audit-convention | Nice-to-have | fixed (W1-3) | C1 boxed vs C2 one-liner file headers; recorded in README §3 |
| 8 | logic-B1-1 | audit-logic | Nice-to-have | fixed (W1-4) | unreachable `RETURN -1` + dead caller guards (ported) |
| 9 | logic-B1-2 | audit-logic | Nice-to-have | fixed (W1-4) | label names not sanitised before `;`-delimited write (ported) |
| 10 | T1 | audit-test | Nice-to-have | skipped (W1-5) | 2 DB-mutation actions untested (accepted plan-scope decision) |
| 11 | E2E-1 | e2e-test | Nice-to-have | fixed inline | runbook TC-5 probe-01 missing `-d eazybusiness` note |

Process/lifecycle items (not code issues): 3 unpromoted ADRs; tests/README gap; 3
doc-inline agent failures (spend limit) → possible missing anchors.

## Full deviation / drift list

**Documented deviations (16 — all D4-defensible, none is a plan violation):**

- **C1 (5):** `_CheckAction`/`_SetActionDisplayName` not created (vendor); +3 PayPal procs;
  12 vs "~13" functions (estimate reconciled); stripped per-file transaction scaffolding;
  lint rule (g) tightened.
- **C2 (9):** StepLog-direct vs `@StepLog OUTPUT`; `QUOTENAME(db).sys.sp_executesql` vs
  `USE`; `EnsureAgentJob` wrapper vs bare `agent_job_*.sql`; `<SET-VIA-RUNBOOK>` sentinel
  vs `{{ShopLicense}}` token; dropped `RoboticoEKL` grant (D10 boundary); banking blocks
  covered by AnonymizeCustomerData not InvalidateCredentials; `DELETE` vs `TRUNCATE` (lint
  d); removed BEGIN TRAN/PRINT/verification SELECTs; gap-fill `jobstartuser` RoboticoOps USER.
- **C3 (1):** probes 03/04 iterate all `eazybusiness*` DBs via cursor (serviceability).
- **C4 (1):** architecture doc placed at `docs/SQL/` (plan-prescribed path, not `docs/architecture/`).

**Drift (files edited outside assigned scope):**

| Source | File | Rationale |
|---|---|---|
| C1 impl | `WorkflowProcedures/README.md` (NEW) | explicit §1 deprecation deliverable (D12); no existing `.sql` touched |
| C3 impl | plan `.md` (O1/O2/O4 appended) | §4 acceptance requires plan Open-Questions update |
| repair W1-3 | `db-migrations/README.md` §3 | the finding's suggested fix directed recording the convention there |
| repair W1-1 | `docs/SQL/NAMING-CONVENTIONS.md` §9 | the fix target for convention-B1-1 |

No repair wave had drift ≥5 files. No self-fix or audit agent drifted. No SQL was executed
against any server on the entire run (read-only hard constraint held; isolation guard #5
enforced — every sqlcmd targeted `vm-sql-test1`, never prod `vm-sql2`).

## Full fix list by family

- **inline-impl (C1):** `GO;`→`GO`, `CREATE OR ALTER`, quote normalization, ANSI_NULLS/
  QUOTED_IDENTIFIER preservation, stripped deploy scaffolding, lint rule (g) tightening.
- **self-fix:** `deploy.ps1` `$env`→`$envConfig` (C1-SF); architecture count `~15`→`~20`
  (C4-SF). C2/C3 self-fix: no changes needed.
- **mid-repair:** none (no mid-chunk triage fired).
- **block-repair (W1, 5 fixed / 1 skipped):** W1-1 NAMING §9 rewrite; W1-2 `SET NOCOUNT ON`
  ×5; W1-3 README §3 header convention; W1-4 logic-B1-1 dead-code removal (4 files) +
  logic-B1-2 label sanitise; W1-5 T1 skipped (documented).
- **integration-repair:** none (1 block; integration phase skipped).
- **e2e-repair:** E2E-1 runbook `-d` note fixed inline by orchestrator (with `tmv`→`tm9`).
- **docs (finalize):** 6 docs augmented, `tmv`→`tm9` substantive constraint-violation fix,
  `eazybusiness-ebene-a` inline group anchored (14/27 files, +28/-0); 3 inline groups
  no-change-needed (per reports; see 🟠 #6 caveat).

## Research files

None produced during implementation. Six planning-phase research docs feed the plan and
are cross-linked by the chunks/ADRs (evidence-only, no `## Specification` → no spec
conversions): `1-migrations-tooling`, `1.1-ekl-runner-grenze`, `2-instanz-survey`,
`3-module-signing-agent-job`, `4-jtl-spezifika`, `5-repo-inventar`. Note: research/5 §3
under-inventoried the PayPal source file (see 🟠 #2).

## Block timeline

```
Phase 3 (plan wf_50fde12a-9be, start 9592c99):
  C1 (foundation + lint) cf02f1a → self-fix 86abb31
  C2 (RoboticoOps + reset) ff9141c → self-fix 8a7007d   ┐ C2 ∥ C3 (both dep C1)
  C3 (probes + hygiene)    172a280 → self-fix d4878e4   ┘
  C4 (docs + ADRs)         66a1969 → self-fix d8f30f0   (dep C1,C2,C3)
  AUDIT-B1 (4 topics) → 6 findings → validated 6/6 (0 eliminated)
  repair W1 (54f38fd): 5 fixed, 1 skipped → re-audit CONVERGED (findings: [])

Phase 4 (finalize wf_e523c9ab-28a):
  integration: skipped (1 block)
  E2E auto: TC-1…TC-6 + TC-R1 refresh → 7 pass, 0 fail; TC-M1…M5 manual pending
  docs (ca0fd32): 11 reconciled, 1 group anchored, tmv→tm9 fix; 3 inline agents
    killed by monthly spend limit
```

## Audit of the audit (eliminated findings)

**Zero findings eliminated.** All 6 topic-audit findings survived consolidation validation
against HEAD (no false positives, no duplicates to merge) — the validated-findings report
classified all 6 green (fixes clear from text, no research topic needed). The re-audit of
repair wave 1 confirmed all 5 fixes resolved and the skip (T1) accepted, with **no new
problems introduced** by the wave. Clean convergence, no cascade.

## Source coverage (self-check)

Read in full: state file; all 4 chunk impl + 4 self-fix reports; 4 topic audits;
validated-findings; 5 repair reports; re-audit; e2e-test; docs-discovery; docs-final;
4 inline-anchor reports (`eazybusiness-ebene-a`, `global-ebene-b`, `tests-harness`,
`peripheral-hygiene-legacy`); 6 research docs (skimmed). The 11 `docs-worker-*.md` reports
are covered via the docs-final aggregation table (each listed with its reconcile outcome);
`e2e-runbook.md` is the executed runbook behind `e2e-test.md`. No report file is unaccounted
for. Counters above are consistent between summary and lists.
