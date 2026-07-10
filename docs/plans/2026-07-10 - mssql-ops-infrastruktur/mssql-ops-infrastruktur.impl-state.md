# State: mssql-ops-infrastruktur (implement-long-plan-v3)

> **On resume:** re-read `~/.claude/skills/implement-long-plan-v3/SKILL.md`
> and this file in full before any other action.
> (Planning-phase state lives in `mssql-ops-infrastruktur.state.md` — historical.)

**Plan:** [→ mssql-ops-infrastruktur.md](mssql-ops-infrastruktur.md)
**Chunks:** [→ chunks.json](chunks.json) (Phase 1 output, pending)
**Reports:** ./reports/
**Started:** 2026-07-10
**Worktree:** worktrees/feature/mssql-ops-infrastruktur (branch feature/mssql-ops-infrastruktur) — ALL edits inside only

## Autonomy mandate (user, 2026-07-10)

User pre-approved ALL standard choices and is offline overnight:
- At every decision point choose the recommended/default option and document it here (no blocking AskUserQuestion).
- Implementation agents: **Opus**.
- Post-implementation review pass (user directive 2026-07-10, refined): SMALL number of **Fable agents at effort LOW** perform a static code analysis focused on ARCHITECTURE problems + "everything cleanly implemented, nothing over-complicated, no missing features". Findings are then FIXED in a follow-up wave: per finding, choose the executor by size/complexity — **Opus (high effort)** for larger/mechanical rework, **Fable (low)** for small nuanced corrections. Re-verify after fixes.
- Hard constraints: **no writes against any SQL server** (read-only sqlcmd against vm-sql-test1.zdbikes.local allowed via `/opt/mssql-tools*/bin/sqlcmd -E -C`); no secrets in files; edits only inside the worktree.

## plan_lifecycle

```yaml
current_path: docs/plans/2026-07-10 - mssql-ops-infrastruktur/mssql-ops-infrastruktur.md
status: moved            # already created in-place in docs/plans, no move needed
moved_at: 2026-07-10 (created in place, commit d4dd5d3)
```

## Documentation Plan

```yaml
doc_activation: full          # default chosen per autonomy mandate
doc_landscape: "docs/SQL (2 files: JTL-CUSTOM-WORKFLOWS.md, NAMING-CONVENTIONS.md); docs/plans (this plan); NO docs/architecture, docs/decisions, docs/runbooks yet"
doc_plan_sketch:
  - "NEW docs/SQL/MSSQL-OPS-ARCHITECTURE.md (plan §5)"
  - "NEW docs/runbooks/ (4 runbooks + README, plan §1/§4/§5/§6)"
  - "EDIT docs/SQL/NAMING-CONVENTIONS.md (RoboticoOps, shared CW zone)"
  - "3 plan-scoped ADRs under plan adrs/ (promotion to docs/decisions/ at plan completion)"
  - "NEW db-migrations/README.md is the conventions SSoT for the migration tree"
```

## Conventions

```yaml
build_command: none (SQL-only repo)
test_command: "pwsh db-migrations/tests/lint-migrations.ps1"   # created by §7; before it exists: n/a
lint_command: same as test_command
test_file_pattern: "db-migrations/tests/**"
commit_format: "[{block}.{chunk}] {title} (mssql-ops-infrastruktur)"
language: "new docs/READMEs/runbooks English; SQL comments English for new code; ported legacy German comments may stay"
```

## Pre-Flight

```yaml
- kind: worktree
  check: "git -C worktrees/feature/mssql-ops-infrastruktur status --porcelain"
  status: pass (clean after plan commit d4dd5d3)
- kind: sqlcmd-readonly
  target: vm-sql-test1.zdbikes.local
  check: "/opt/mssql-tools*/bin/sqlcmd -S vm-sql-test1.zdbikes.local -E -C -Q 'SELECT 1'"
  status: pass (verified 2026-07-09; re-verified 2026-07-10; Kerberos ticket of user lukas)
  blocking: false            # read-only probes degrade to manual if unreachable
# --- E2E-added (Phase 1 continuation, 2026-07-10) ---
- kind: tool-pwsh
  target: PowerShell 7 (lint + parse-check cases)
  check: "command -v pwsh"
  status: pass (/usr/bin/pwsh)
  blocking: true
- kind: artifact-lint
  target: db-migrations/tests/lint-migrations.ps1 (produced by chunk C1)
  check: "test -f 'db-migrations/tests/lint-migrations.ps1'"
  status: pending (created during C1)
  blocking: true             # central auto E2E gate
- kind: isolation-guard
  target: never prod (vm-sql2) — auto sqlcmd targets ONLY vm-sql-test1
  check: "every auto-case sqlcmd command line contains -S vm-sql-test1"
  status: enforced-by-runbook
  blocking: true
```

**Phase-2 checks (2026-07-10 00:57, autonomy mode):** briefing emitted in main
conversation · decisions per mandate: chunk cut ADOPTED (C1 → C2 ∥ C3 → C4),
doc activation FULL, E2E scope RUN (auto: 6 static/read-only cases; write-E2E
manual via runbooks) · git-state clean (plan artifacts committed 9592c99) ·
plan-consistency pass (research links resolve; adrs/*.md are §5 deliverables)

## End-to-End-Test-Plan

```yaml
scope: "Static + read-only only (hard constraint: no server writes). Auto = convention lint, PowerShell parse checks, static reset-SQL security/reference review, object/functionality completeness mapping, ADR/doc-format checks, read-only probes against vm-sql-test1. All deploy/reset behavior tests are MANUAL (delegated to docs/runbooks/testmandant-reset-validierung.md + rollout-mssql-ops.md)."
auto_recommendation: run            # 6 meaningful non-mutating cases
write_e2e: skip-for-auto            # manual only, no server writes allowed
runbook: ./reports/e2e-runbook.md
cases: { auto: 6, manual: 5 }       # TC-1..TC-6 auto; TC-M1..TC-M5 manual
degrade_rule: "TC-5 read-only probes → manual-pending if test1 unreachable (env condition, not a code failure)"
```

## Phase-3 Run (plan.workflow.js)

```yaml
runId: wf_50fde12a-9be    # launched 2026-07-10 ~01:00
planStartCommit: 9592c99
defaultModel: opus        # user mandate: Opus workers
maxParallel: 3
repairCap: 3
```

**Task table** (1 block, cross-chunk deps direct) — **run complete 2026-07-10 ~02:40, status: complete, 28 agents, 0 errors:**

| Task | Block | Deps | Status |
|---|---|---|---|
| C1 (Migration foundation + lint harness) | B1 | — | ✅ cf02f1a + self-fix 86abb31 |
| C2 (RoboticoOps + reset SP/job) | B1 | C1 | ✅ ff9141c + self-fix 8a7007d |
| C3 (Probes §4 + Hygiene §6) | B1 | C1 | ✅ 172a280 + self-fix d4878e4 |
| C4 (Docs, ADRs, rollout, banners) | B1 | C1, C2, C3 | ✅ 66a1969 + self-fix d8f30f0 |
| AUDIT-B1 | B1 | C1–C4 | ✅ 6 findings → repair wave 1 (54f38fd) fixed 5, skipped 1 (T1, documented nice-to-have) |

**Key deviation (C1, sound):** `CustomWorkflows._CheckAction`/`._SetActionDisplayName` are
JTL-module VENDOR objects (only ever EXEC'd in repo, never CREATE'd) — NOT ported into our
chain; documented as module prerequisite, every registration call guarded (IF OBJECT_ID … ELSE PRINT).
Plus: 3 PayPal API procs (Robotico.spPaypal*) ported that research/5 under-inventoried.

**Probe outcomes (C3):** O1 answered — Worker.tTarget has no DB-side semantics lookup
(Sync.tSyncType empty), leave untouched confirmed. O4 partial — pf_user 0 rows on test1
(prod tm* clones need manual run). O2 remains manual (running worker needed).

## Commits

| Commit | Kind | Task | Hash |
|---|---|---|---|
| [orchestrator] plan + research | setup | — | d4dd5d3 |

## Escalations & Postponed

(none — Phase 3 complete without escalations; postponed: [])

## Phase 4 (finalize workflow)

```yaml
runId: wf_e523c9ab-28a    # launched 2026-07-10 ~02:45, complete ~03:05
integration: skipped (1 block)
e2e: { auto: 7 pass (TC-1..TC-6 + TC-R1 regression re-check), fail: 0, manual_pending: 5 (TC-M1..TC-M5) }
docs: { workers: 15, docs_commit: ca0fd32, flagged: 5 minor, gaps: 1 (tests/README, follow-up default no) }
postponed_e2e: E2E-1 (runbook -d note) — FIXED inline by orchestrator together with tmv→tm9 drift
agent_failures: 3 (DOCS-INLINE-tests-harness ×2, DOCS-INLINE-peripheral-hygiene-legacy ×1) — cause: MONTHLY SPEND LIMIT hit
adr_flag: 3 plan-scoped ADRs need promotion to docs/decisions/ before archival (docs/decisions/ does not exist yet)
```

**⚠️ Budget note (2026-07-10 ~03:05):** Anthropic monthly spend limit was hit during the
docs-inline wave — some inline anchors for the tests harness + peripheral hygiene/legacy
files are MISSING. Remaining phases run budget-conscious: orchestrator does small fixes
itself; review pass kept to 3 Fable-low agents as mandated; Phase 5 (closure/translations)
deferred to user acceptance anyway.

### Docs (docs-final, 2026-07-10T02:45:00+02:00)

```yaml
doc_workers: 11        # 6 augmented, 5 no-change-needed
inline_groups: 4       # 1 anchored (eazybusiness-ebene-a, +28/-0), 3 no-change-needed
spec_conversions: 0
auto_fixes: 0          # no doc relocated / no anchor renamed → no safe link auto-fix
flagged: 5             # tmv→tm9 drift into plan+e2e artifacts; JTL-CW back-link; index Phase-7 wording; arch↔naming cross-link (opt); README §8 test-table subset
gaps: 1                # db-migrations/tests/README.md missing (follow-up doc plan default: no)
adr_flags: 1           # 3 plan-scoped ADRs unpromoted; docs/decisions/ absent; arch doc links draft paths → rewrite at promotion
knowledge_flags: 0
substantive: "reset-validation runbook seeded tmv, violating shipped CK_ops_Mandant_MandantKey (tm[0-9]%) — renamed tm9 (would-never-run bug in the doc)"
report: docs/plans/2026-07-10 - mssql-ops-infrastruktur/reports/docs-final-report.md
```

## Phase 4.7 Implementation Report

```yaml
report_file: ./reports/implementation-report.md
markers: { needs_research: 0, review_recommended: 8, informational: 9 }
verification_pass: done (source coverage complete, counter fix applied)
user_decision: pending (autonomy mode: proceeding to review pass; acceptance in the morning)
```

## Fable-low Static Review (user directive)

```yaml
runId: wf_b0fed360-d5b    # launched 2026-07-10 ~03:15
shape: 3 Fable-low lenses (architektur / vollstaendigkeit / einfachheit)
       -> file-disjoint fix clusters (large->Opus-high, small->Fable-low)
       -> single commit -> Fable-low recheck
```

### Review result (2026-07-10 ~03:30)

```yaml
findings: 5 (1 important ARCH-1, 4 nice)   # architektur 3, vollstaendigkeit 1, einfachheit 1
fixed: 5 / rejected: 0                      # fix commit 53067b0, all clusters small -> Fable-low
recheck: all resolved, lint green (0 errors, 12 known heuristic warnings)
notable: ARCH-1 RegisterMandant no longer swallows errors (WARN accumulation + hard THROW for
  the clone itself); ARCH-2 job existence self-heals via everytime 200_ensure_agent_job.sql;
  ARCH-3 re-sign set is now catalog-driven (execute_as jobstartuser without signature -> signed);
  F1 EnsureAgentJob refuses drop/recreate while a reset is queued/running; SCA-1 deploy abort exits 1.
```

## Session close (2026-07-10 ~03:35)

- Worktree clean, HEAD 5ec7d33. Partial inline anchors of the spend-limit-failed doc
  workers were verified (comment-only) and committed.
- NEXT STEPS FOR THE USER (morning):
  1. Review implementation report (reports/implementation-report.md, 🔴0 🟠8 🟢9) and this state file.
  2. Manual E2E: TC-M1 (baseline deploy test1) → TC-M2 (global chain test1, needs cert
     password + SQL Agent started) → TC-M3 (full reset E2E) → TC-M4/TC-M5. Runbooks under docs/runbooks/.
  3. Decide O3 (premig DB) + O5 (cert password location, suggested ~/.claude-secrets.md).
  4. Accept plan → Phase 5 closure (ADR promotion to docs/decisions/, archive, EN translations)
     — deliberately NOT run (needs user acceptance; also budget-conscious after spend-limit hit).
  5. Missing inline-anchor coverage (tests harness / hygiene-legacy remainder) can be finished
     by re-running the finalize docs stage after the spend limit is raised.
