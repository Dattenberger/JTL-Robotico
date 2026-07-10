# Docs Discovery + Classification — mssql-ops-infrastruktur

**Date:** 2026-07-10T02:45:00+02:00
**Plan:** `docs/plans/2026-07-10 - mssql-ops-infrastruktur/mssql-ops-infrastruktur.md`
**Range:** `9592c99..HEAD` (HEAD = `54f38fd [B1] repair wave 1`)
**Activation:** full

## Summary

Documentation for this plan was authored **during** implementation — the architecture
doc, naming conventions, the `db-migrations/` contract README, two deprecation READMEs,
and five runbooks are all present and already reference the implemented reality (D-numbers,
ADR slugs, concrete object/file paths). The doc-worker job here is therefore
**reconcile-and-sharpen against the final code after repair wave 1**, not first-draft
authoring. No spec-conversion candidates exist (no research file carries a
`## Specification` section — the plan is flat, research is evidence-only).

Two structural gaps stand out: (1) the three plan-scoped ADR drafts are **unpromoted** —
`docs/decisions/` does not exist yet; (2) the `db-migrations/tests/` harness has no
dedicated README (only referenced from the architecture doc).

## Source footprint (touched, non-doc)

- `db-migrations/eazybusiness/` — 11 functions (`Robotico.fn*`), 12 sprocs
  (`Robotico.sp*` + `CustomWorkflows.sp*`), 2 `up/` scripts. Ebene A, ported objects.
- `db-migrations/global/` — 13 reset sprocs (`reset.*`), 6 `up/` scripts, 2 `permissions/`
  scripts, 1 `runAfterOtherAnyTimeScripts/`. Ebene B, greenfield.
- `db-migrations/tests/` — `lint-migrations.ps1`, `compare-objects.sql`,
  `global/validate_structure.sql`, 5 `eazybusiness/*_Tests.sql`, 4 `probes/`.
- `db-migrations/deploy.ps1`, `db-migrations/targets.config.json` — runner + config.
- `Berechtigungen/cleanup/` — 3 hygiene scripts (1 `.md`, 2 `.sql`).
- `Projekte/Testsystem/setup-test-environment.ps1` — legacy reset (deprecated).

## Doc landscape (no `docs/architecture/`; architecture lives in `docs/SQL/`)

| Doc | Type | State | Relation to footprint |
|---|---|---|---|
| `docs/SQL/MSSQL-OPS-ARCHITECTURE.md` | Architecture (cross-cutting) | Present, `status: Accepted`, post-impl snapshot | The map over the whole `db-migrations/` stack; §6 standing rules |
| `docs/SQL/NAMING-CONVENTIONS.md` | Architecture (cross-cutting) | Present, updated for RoboticoOps + shared CW zone | Schema ownership table for all `Robotico.*` / `CustomWorkflows.*` objects |
| `docs/SQL/JTL-CUSTOM-WORKFLOWS.md` | Research/reference | Present, **not touched** since plan start | Mechanics of `CustomWorkflows.*` actions (ported sprocs registered here) |
| `db-migrations/README.md` | Code-Pattern README (contract) | Present, contract-level | The migration-file contract for both chains |
| `WorkflowProcedures/README.md` | Code-Pattern README | Present, deprecation + object-mapping table | Old source of `Robotico.*` / `CustomWorkflows.*`, now ported |
| `Projekte/Testsystem/README.md` | Code-Pattern README | Present, deprecation notice | Legacy PowerShell reset superseded by `reset.*` SPs |
| `docs/runbooks/README.md` | Runbook index | Present | Index of the 4 runbooks below |
| `docs/runbooks/rollout-mssql-ops.md` | Runbook | Present | The test→prod spine over the whole stack |
| `docs/runbooks/migrations-baseline.md` | Runbook | Present | Baseline Ebene A into the grate journal |
| `docs/runbooks/testmandant-reset-validierung.md` | Runbook | Present | Prove `reset.*` pipeline end-to-end on test1 |
| `docs/runbooks/hygiene-findings.md` | Runbook | Present | Manual prod hygiene (`Berechtigungen/cleanup/`) |

No `docs/runbooks/agentic/` — runbooks are normal docs, scheduled **last** so they absorb
what the architecture/README updates settle.

## Work items — `update`

All are **reconcile against final code**, most-load-bearing first; runbooks last.

| Slug | Target | Source files to reconcile against | Why |
|---|---|---|---|
| `mssql-ops-architecture` | `docs/SQL/MSSQL-OPS-ARCHITECTURE.md` | whole `db-migrations/` stack, `deploy.ps1`, tests | Map-level doc; verify §2 tables (deploy flags, journal schemas), §6 rules, and the `permissions/900` / `EnsureAgentJob` mechanics match post-repair code |
| `db-migrations-readme` | `db-migrations/README.md` | `eazybusiness/`, `global/`, `deploy.ps1`, `tests/lint-migrations.ps1` | The contract; verify folder/journal rules and lint rules (a)–(g) still match `lint-migrations.ps1` |
| `naming-conventions` | `docs/SQL/NAMING-CONVENTIONS.md` | `Robotico.*`, `CustomWorkflows.*`, `ops.*`, `reset.*` objects | Verify ownership table + prefix rules cover every newly-added object namespace |
| `workflowprocedures-readme` | `WorkflowProcedures/README.md` | `db-migrations/eazybusiness/**`, `tests/eazybusiness/*` | Verify the source→destination mapping table lists every ported object exactly (no stragglers/renames after repair) |
| `testsystem-readme` | `Projekte/Testsystem/README.md` | `reset.*` SPs, `setup-test-environment.ps1` | Verify the "use the new reset instead" pointer names the real `reset.StartTestmandantReset` entry point |
| `jtl-custom-workflows` | `docs/SQL/JTL-CUSTOM-WORKFLOWS.md` | `CustomWorkflows.sp*` (ported) | Untouched since plan start; low-priority verify that ported CW sprocs don't contradict the registration mechanics described (likely no-change) |
| `runbooks-index` | `docs/runbooks/README.md` | (the 4 runbooks) | Verify index rows + the fit-together diagram after the runbook updates below |
| `rollout-mssql-ops` | `docs/runbooks/rollout-mssql-ops.md` | `deploy.ps1`, `global/**`, `permissions/**` | Verify phase order + `deploy.ps1` flags + object names match final code |
| `migrations-baseline` | `docs/runbooks/migrations-baseline.md` | `targets.config.json`, `eazybusiness/**`, `compare-objects.sql` | Verify target DB list + baseline `--baseline` flow + pre-check against `compare-objects.sql` |
| `testmandant-reset-validierung` | `docs/runbooks/testmandant-reset-validierung.md` | `reset.*` SPs, `EnsureAgentJob`, `ops.ResetRequest` | Verify SP names, agent-job name, status-machine states match final `global/` code |
| `hygiene-findings` | `docs/runbooks/hygiene-findings.md` | `Berechtigungen/cleanup/0[13]_*.sql`, `02_*.md` | Verify the three findings + commented-out fixes match the cleanup scripts |

No `convert` items (no `## Specification` sections in research).

## Inline-anchor inventory

Three-anchor convention (module header / `@see` plan-ADR / gotcha). Findings:

- **`db-migrations/global/`** (Ebene B): **strong** — reset SPs carry full headers,
  security-model gotchas, and `@see` plan/§ + `@see` sibling-file tags. Gaps: `up/0003`,
  `up/0010`, `up/0011`, `up/0020`, `permissions/100` have `@see` but **no module header
  block** — add a one-line header. Otherwise near-complete.
- **`db-migrations/eazybusiness/`** (Ebene A): headers present on all functions/sprocs,
  but **`@see` plan/ADR tags absent** across the board (they carry `-- Ported from …`
  provenance instead). Add `@see` to the plan §/ADR where the object embodies a plan
  decision (duplicate-order engine, CustomField API, PayPal tracking).
- **`db-migrations/tests/`**: headers present; no `@see`. Low value — add `@see` to the
  plan test-strategy section only where it clarifies intent.
- **`Berechtigungen/cleanup/` + `Projekte/Testsystem/setup-test-environment.ps1`**:
  headers present; no `@see`. Peripheral/legacy — light touch.
- `targets.config.json`: JSON, no comment surface — excluded.

Grouped into worker units by module (see `inline_groups` in the return).

## Gaps (flag only)

- **`db-migrations/tests/` has no dedicated README.** The harness (lint rules, how to run
  the `*_Tests.sql`, the `compare-objects.sql` drift check, the `validate_structure.sql`
  gate, and the four `probes/` — what each proves) is only referenced from the
  architecture doc. A short `db-migrations/tests/README.md` would make the test surface
  self-describing. Not auto-generated.

## ADR flags (flag only — promotion out of scope for doc workers)

`docs/decisions/` **does not exist**. All three plan-scoped ADR drafts are
`Status: Proposed (plan-scoped — pending promotion)` and must be promoted (assigned
`NNNN`, moved to `docs/decisions/`, index row added, cross-refs rewritten) **before the
plan is archived** — this is the plan's lifecycle obligation, not a doc-update task:

- `adr-grate-migration-runner.md` — D1 (grate as the migration runner).
- `adr-two-chain-migration-paths.md` — D2/D3 (Ebene A / Ebene B, one tool, script-only promotion).
- `adr-module-signing-reset.md` — D5/D6 (hybrid module-signing + async agent-job reset).

No qualifying architectural decision in the plan lacks a draft (D4 DB-name, D12 deprecation,
D13 manual-hygiene are config/convention/runbook-level, not ADR-worthy).
