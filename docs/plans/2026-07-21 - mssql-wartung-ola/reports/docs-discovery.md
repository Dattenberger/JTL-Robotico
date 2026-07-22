# Docs Discovery + Classification — mssql-wartung-ola

**Date:** 2026-07-23T00:05:00+02:00
**Plan:** `docs/plans/2026-07-21 - mssql-wartung-ola/mssql-wartung-ola.md`
**Plan-start commit:** `d722993ae64b0a7e0dbcb5fd37fa8c6a7e7180a9`
**Activation:** full
**Agent:** docs-discovery (implement-long-plan-v3)

## Executive summary

The plan carried its own documentation contract (B4 §3.4, B6 §3.6) and the
implementation already executed every [EDIT] inline. All five affected docs are
updated, all eight new SQL files carry the full three-anchor set (module header +
`@see` plan tag + `@see` ADR tag), and the runbook B6 weaving (Phase 4a + Phase 4b)
is in place. The work-list below is therefore a **verification/consistency pass**,
not a from-scratch documentation effort — the highest-value worker job is confirming
the cross-doc counts stay consistent (5 `maint.*` procs · 6 agent jobs · 8 new
migration files · THROW block `51100–51129`).

Repo shape note: this repo keeps ADRs **plan-scoped** (`{plan}/adrs/`); there is **no
`docs/decisions/` directory** and no `docs/architecture/` directory — cross-cutting SQL
docs live under `docs/SQL/`, runbooks under `docs/runbooks/`.

## 1. Source-file footprint (since plan-start commit)

Filtered to source + doc files (plan-internal reports and the plan/state files excluded):

| File | Kind |
|---|---|
| `db-migrations/global/up/0022_maintenance_ola_vendor.sql` | source (vendored Ola) |
| `db-migrations/global/up/0023_maintenance_registry.sql` | source (schema + registry DDL) |
| `db-migrations/global/sprocs/maint.spEnsureMaintenanceJobs.sql` | source |
| `db-migrations/global/sprocs/maint.spRunMaintenanceJob.sql` | source |
| `db-migrations/global/sprocs/maint.spCheckBackupChain.sql` | source |
| `db-migrations/global/sprocs/maint.spCheckMaintenanceLiveness.sql` | source |
| `db-migrations/global/runAfterOtherAnyTimeScripts/maint.spApplyMaintenance.sql` | source |
| `db-migrations/global/permissions/260_maintenance_operator.sql` | source |
| `db-migrations/tests/global/validate_structure.sql` | test (registry/proc registration) |
| `db-migrations/tests/global/validate_rollout.sql` | test (operability gate) |
| `db-migrations/tests/lint-migrations.ps1` | test tooling |
| `db-migrations/README.md` | doc |
| `docs/SQL/MSSQL-OPS-DATA-MODEL.md` | doc |
| `docs/SQL/NAMING-CONVENTIONS.md` | doc |
| `docs/SQL/MSSQL-OPS-ARCHITECTURE.md` | doc |
| `docs/runbooks/rollout-mssql-ops.md` | doc |

## 2. Doc landscape

- `docs/SQL/` — cross-cutting SQL docs (DATA-MODEL, ARCHITECTURE, NAMING, plus the
  unrelated JTL-CUSTOM-WORKFLOWS).
- `docs/runbooks/` — `rollout-mssql-ops.md` (the RoboticoOps prod-cutover spine),
  plus hygiene/baseline/reset runbooks. **No `docs/runbooks/agentic/`** → no agentic
  runbook duty.
- **No `docs/decisions/`**, **no `docs/architecture/`**.
- Plan-scoped ADRs: `adrs/adr-maintenance-as-code-roboticoops.md`,
  `adrs/adr-backups-cbb-retained.md` (drafts, `Proposed (plan-scoped)`).
- Plan `research/` — three files, all **Research genre** (header + Problem/Sources/
  Findings/Implementation-Hints/References; **no `## Specification` section**) →
  **not conversion candidates**. They document repair-wave findings (liveness
  heartbeat edge case, first-run grace, up/0023 immutable-German-comments decision).
- Module READMEs: `db-migrations/README.md` (touched), `db-migrations/tests/docker/README.md`
  (unrelated).

## 3. File → doc mapping (update items)

Every mapped doc was **already updated during implementation** (all appear in the
plan-start..HEAD diff). Verification evidence noted per row.

| Doc | Driven by (source) | Plan ref | State | Verify focus |
|---|---|---|---|---|
| `docs/SQL/MSSQL-OPS-DATA-MODEL.md` | `up/0023` (ops.tMaintenanceJob DDL) | AC8, §3.4 | Updated: "five registry tables"; `## ops.tMaintenanceJob` section; contract box + DDL list carry `0023` | Every column of `ops.tMaintenanceJob` present incl. the double-grammar `cDatabases`; count "five" consistent |
| `docs/SQL/NAMING-CONVENTIONS.md` | `maint.*` procs, `tStartTime` | §3.4, D20 | Updated: `maint.*` ownership row (5 procs); `t`=time double-booking note (D20) | 5 procs listed; `t`-prefix micro-convention wording |
| `docs/SQL/MSSQL-OPS-ARCHITECTURE.md` | all maint files | §3.4, D25 | Updated: "three schemas" + `maint` subsystem para + inventory rows + 2 new §6 standing rules (CBB/ADR-B boundary; git-only tuning) | 6 jobs / 5 procs / vendored-Ola-in-RoboticoOps.dbo consistency; both standing rules present |
| `db-migrations/README.md` | THROW numbers, structure registration | AC11, §3.2 NOTE, FT-14 | Updated: (k)-table `51100/51105/51110/51120`; guidance "reset from 51130"; `MaintenanceSchedulesEnabled` config row | THROW block `51100–51129` reserved; reset-next-free = `51130` |
| `docs/runbooks/rollout-mssql-ops.md` | B6 cutover (all maint files) | §3.6, D22/D26/D37/D38/D39 | Updated: Phase 4a (Alt-Ola removal + CommandLog archive) before deploy; Phase 4b go-live after; watchdog/liveness/jobhistory/mail-unmonitored notes woven | Order-binding CAUTION; time-window rule; Gap-2 mail-unmonitored deliverable; D37 system-DB re-verification |

`validate_structure.sql` / `validate_rollout.sql` / `lint-migrations.ps1` are
test/tooling files, not docs — no doc item.

## 4. Inline-anchor inventory

All eight new SQL files carry the complete three-anchor set already:

| File | Module header | `@see` plan | `@see` ADR | Gotcha comments |
|---|---|---|---|---|
| `up/0022_maintenance_ola_vendor.sql` | present | §3.1 | ADR-A + ADR-B | present (DatabaseBackup-not-vendored, CommandLog idempotency wrapper) |
| `up/0023_maintenance_registry.sql` | present | §3.1 | ADR-A | present (+ `@see` DATA-MODEL same-commit contract) |
| `sprocs/maint.spEnsureMaintenanceJobs.sql` | present | §3.2 | ADR-A | present (per-job normal form, running-guard scoping) |
| `sprocs/maint.spRunMaintenanceJob.sql` | present | §3.2 | ADR-A | present (runtime dispatch, no dynamic SQL) |
| `sprocs/maint.spCheckBackupChain.sql` | present | §3.2 | ADR-B | present (local time base, target validation) |
| `sprocs/maint.spCheckMaintenanceLiveness.sql` | present | §3.2, D36 | ADR-A | present (F3/F4 rationale, CommandType mapping) |
| `runAfterOtherAnyTimeScripts/maint.spApplyMaintenance.sql` | present | §3.3 | ADR-A | present (repo-owned MERGE deviation) |
| `permissions/260_maintenance_operator.sql` | present | §3.3 | ADR-A | present (grate stage-order, Standard-SMTP guard) |

One worker unit — all files share the `db-migrations/global/` maintenance subsystem.
Expected outcome: `no-change-needed` (anchors already high-quality); listed for the
fresh-eyes confirmation.

## 5. Gaps (flag only)

None. Every touched source file maps to an already-updated doc; the maint subsystem is
covered in ARCHITECTURE, the table in DATA-MODEL, the schema in NAMING, the error
numbers in README, the cutover in the runbook.

## 6. ADR flags (flag only — append-only, out of scope for doc workers)

1. **Two plan-scoped ADRs pending promotion** — `adr-maintenance-as-code-roboticoops.md`
   and `adr-backups-cbb-retained.md` are still `Proposed (plan-scoped)` in
   `{plan}/adrs/`. Per the ADR lifecycle they must be promoted to `docs/decisions/NNNN-…`
   **before the plan is archived** (this repo has no `docs/decisions/` yet — promotion
   would establish it / follow the parent mssql-ops program's convention). Not a
   doc-worker task; belongs to the plan's closure/promotion step.
2. **Promotion follow-ups declared in plan §6** — (a) bidirectional back-reference /
   Decision-History note on `adr-ebene-b-hungarian-naming` for the `t`=time
   micro-extension (D20); (b) a "Subsystems" table in `CLAUDE.md`
   (`RoboticoOps`, `Testmandant Reset`, `JTL SQL Migrations`, `DB / Migrations`) to
   anchor the `Subsystem:` headers of the six-ADR cohort. Both are ADR-promotion-time
   tasks, not this docs run.
