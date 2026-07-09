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
- Implementation agents: **Opus**. Post-implementation: separate Fable low-effort static-analysis review pass (main loop, after Phase 4.7).
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

**Phase-2 checks:** briefing emitted (main loop, autonomy mode) ·
git-state clean · plan-consistency: research/adrs links resolve
(adrs/*.md are declared as §5 deliverables, not yet existing — expected) ·
E2E scope: per analysis-agent recommendation (expected: skip runtime E2E,
static verification instead — no server writes allowed)

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
runId: pending
```

Task table: pending chunks.json.

## Commits

| Commit | Kind | Task | Hash |
|---|---|---|---|
| [orchestrator] plan + research | setup | — | d4dd5d3 |

## Escalations & Postponed

(none yet)
