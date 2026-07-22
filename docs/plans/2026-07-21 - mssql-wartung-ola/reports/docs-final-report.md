# Docs Final — cross-doc sanity + link resolution + report

**Date:** 2026-07-23T00:05:00+02:00
**Plan:** `docs/plans/2026-07-21 - mssql-wartung-ola/mssql-wartung-ola.md`
**Agent:** docs-final (implement-long-plan-v3)
**Activation:** full

## Executive summary

The documentation for this plan was authored **inline during implementation** (the
plan carried its own doc contract in B4 §3.4 / B6 §3.6, and every `[EDIT]` deliverable
landed with the code). The doc-worker wave was therefore a verification/consistency
pass, not a from-scratch effort. Result: **five of six worker units returned
`no-change-needed`; one applied a single dangling-reference fix** (ARCHITECTURE
frontmatter + §8 References gained navigable ADR-A/ADR-B links). This final pass
confirms the whole doc set is internally consistent, every link in the one touched
doc resolves, and no doc-on-doc contradictions exist.

**No auto-fixes were required in this pass** — the only structural link gap was already
repaired by the ops-architecture worker before hand-off. Nothing here blocks the plan;
the sole forward-looking item is the ADR-promotion link rewrite owed at plan closure.

## Job 1 — Cross-doc sanity

Touched-doc set for this run: **`docs/SQL/MSSQL-OPS-ARCHITECTURE.md`** (the only doc
edited; the other four doc targets + inline anchors were `no-change-needed`). Read
end-to-end, and the load-bearing counts spot-checked across all five affected docs.

**Contradictions / drift / terminology mismatches found: none.** Cross-check of the
canonical numbers (grep across ARCHITECTURE, DATA-MODEL, NAMING, README, rollout-runbook):

| Fact | Value | Consistency |
|---|---|---|
| Agent jobs in registry | **6** (checkdb, index-optimize, cleanup-commandlog, cleanup-backuphistory, cleanup-jobhistory, backup-watchdog) | ARCHITECTURE §1a.2 "6 agent jobs" ↔ runbook seed 6 rows ↔ DATA-MODEL 6 `cJobKey` values — aligned |
| `maint.*` procs | **5** (spEnsureMaintenanceJobs, spRunMaintenanceJob, spCheckBackupChain, spCheckMaintenanceLiveness, spApplyMaintenance) | ARCHITECTURE §3 table ↔ NAMING §9 list ↔ 5 files on disk — aligned |
| Owned schemas | **three** (ops / reset / maint) | ARCHITECTURE §1a.2 ↔ NAMING §9 — aligned |
| Registry tables | **five** (tMandant, tConfig, tResetRequest, tResetStep, tMaintenanceJob) | DATA-MODEL header ↔ ARCHITECTURE §1a.2 — aligned |
| THROW allocation | `51100` backup-chain · `51105` liveness · `51110` ensure (reserved) · `51120` run · block `51100–51129` reserved · reset next-free `51130` | README §4 (k) ↔ ARCHITECTURE §3 table ↔ runbook — aligned |
| Vendored Ola set | CommandLog / CommandExecute / DatabaseIntegrityCheck / IndexOptimize, **no DatabaseBackup** (ADR-B) | ARCHITECTURE §1a.2 + §6.5 + §3 table ↔ up/0022 — aligned |

## Job 2 — Link resolution + conservative auto-fix

Scanned the touched doc (`MSSQL-OPS-ARCHITECTURE.md`) plus the inline `@see` anchors
recorded in the worker reports.

**Auto-fixes applied: 0.** No safe-case link breakage remained — the ops-architecture
worker had already added the two ADR-file links (frontmatter `related-adrs` + §8
"Maintenance suite" bullet) that the inline "ADR-A/ADR-B" labels previously pointed at
with no navigable target.

Targets verified to resolve on disk:

- `adrs/adr-maintenance-as-code-roboticoops.md` (ADR-A) — exists ✅
- `adrs/adr-backups-cbb-retained.md` (ADR-B) — exists ✅
- `mssql-wartung-ola.md` plan file — exists ✅
- Four older mssql-ops ADRs (grate / two-chain / module-signing / reset-step-registry) — exist ✅
- Sibling relative links (`../../db-migrations/README.md`, `NAMING-CONVENTIONS.md`,
  `JTL-CUSTOM-WORKFLOWS.md`, `MSSQL-OPS-DATA-MODEL.md`, `../runbooks/README.md`,
  `../runbooks/rollout-mssql-ops.md`, `../runbooks/testmandant-reset-validierung.md`) — all resolve ✅

The eight inline `@see` ADR anchors in the new SQL files point at the two plan-scoped
ADR files, which exist. Their **path form** (`@see docs/plans/2026-07-21 - mssql-wartung-ola (§3.1)`
— folder+section rather than the canonical file+section) is intentionally consistent
with the wider mssql-ops program convention and resolves unambiguously; not auto-fixed
(a repo-wide stylistic normalization is out of scope and would diverge these files from
their siblings). Awareness-only, per the inline-anchor worker.

## Job 3 — Aggregated worker outcomes

| Unit | Target | Outcome |
|---|---|---|
| data-model | `docs/SQL/MSSQL-OPS-DATA-MODEL.md` | no-change-needed (17 columns of `ops.tMaintenanceJob` verified vs. up/0023 DDL) |
| naming-conventions | `docs/SQL/NAMING-CONVENTIONS.md` | no-change-needed (5-proc `maint.*` list + `t`=time D20 micro-convention verified) |
| ops-architecture | `docs/SQL/MSSQL-OPS-ARCHITECTURE.md` | **augmented** — dangling ADR-A/ADR-B reference completed (frontmatter + §8) |
| migrations-readme | `db-migrations/README.md` | no-change-needed (THROW 51100/51105/51110/51120 + config knob verified) |
| rollout-runbook | `docs/runbooks/rollout-mssql-ops.md` | no-change-needed (Phase 4a/4b cutover claims verified vs. source) |
| inline: maint-suite-global | 8 new SQL files | no-change-needed (three-anchor set present + resolving on all 8) |

## Flagged items (user judgment / closure step)

1. **ADR promotion pending → link rewrite owed at plan closure.** The two plan-scoped
   ADRs (`adr-maintenance-as-code-roboticoops` = ADR-A, `adr-backups-cbb-retained` = ADR-B)
   are still `Proposed (plan-scoped)`. When they are promoted to `docs/decisions/NNNN-…`
   before archival (this repo has **no `docs/decisions/` yet** — promotion would establish
   it), these link sites must be rewritten to the promoted paths and the
   "(plan-scoped — pending promotion)" qualifiers dropped:
   - ARCHITECTURE frontmatter `related-adrs` + §8 References (both ADR cohorts: the 2 new
     + the 4 older mssql-ops ADRs, uniformly)
   - NAMING §9 symbolic ref `ADR-A §D-A2 (plan 2026-07-21 - mssql-wartung-ola)`
   - the 8 `@see` ADR anchors in the new SQL files
   This is an ADR-lifecycle / closure task (append-only territory), **out of doc-worker
   scope** — surfaced here so it is not lost at archival. Also tracked in plan §6.

## Documentation gaps

**None.** Every touched source file maps to an already-updated doc home (maint subsystem
→ ARCHITECTURE; the registry table → DATA-MODEL; the schema → NAMING; the error numbers +
config knob → README; the cutover → rollout-runbook; all 8 SQL files carry the full
three-anchor set). No follow-up doc plan recommended.

## ADR flags

- Two plan-scoped ADRs pending promotion (see Flagged #1). Not written/edited here (ADRs
  are out of docs-final scope).
- Plan §6 promotion follow-ups already declared: (a) back-reference /
  Decision-History note on `adr-ebene-b-hungarian-naming` for the `t`=time D20 extension;
  (b) a "Subsystems" table in `CLAUDE.md` anchoring the `Subsystem:` headers. Both are
  ADR-promotion-time tasks, not this run.

## Knowledge-skill flags

None. No pattern encountered that belongs in a `knowledge-*` skill but is missing.

## Counters

- Docs updated this run: **1** (ARCHITECTURE — worker edit) · verified consistent: **5** docs + **8** inline-anchor files
- Auto-fixes applied by docs-final: **0**
- Flagged: **1** (ADR-promotion link rewrite, closure step)
- Gaps: **0**
