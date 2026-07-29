# Plan: MSSQL-Ops infrastructure (migration foundation, RoboticoOps DB, test-mandant reset)

**Status:** Implemented 2026-07-29 (PROD cutover on `vm-sql2` complete; first production reset green)
**Plan file:** [mssql-ops-infrastruktur.md](mssql-ops-infrastruktur.md)
**Created:** 2026-07-10 · **Branch:** feature/mssql-ops-infrastruktur

## Summary

This is the founding plan of the repository's server-side ops tooling. It replaced ad-hoc
SSMS deployment and a privileged PowerShell reset script with three things that did not
exist before: a **versioned migration foundation** (grate, two chains), an **admin database**
(`RoboticoOps`) that survives every mandant restore, and a **self-service test-mandant
reset** a colleague can trigger without holding any rights on the production server.

The migration foundation runs grate as two logically separate chains through one
`deploy.ps1`: Ebene A (`db-migrations/eazybusiness/`, journal in schema `Robotico` inside
*every* `eazybusiness` copy, so a clone carries its own migration state) and Ebene B
(`db-migrations/global/`, journal in schema `ops` inside `RoboticoOps`, hand-idempotent
because instance uniques are never cloned). Promotion is script-only — the test instance
runs SQL Server 2025 and production runs 2022, so no database image can ever travel from
test to prod.

The reset is asynchronous by construction: a certificate-signed entry procedure
(`reset.spPub_StartTestmandantReset`) validates against the `ops.tMandant` registry and
enqueues into `ops.tResetRequest`, then starts an `sa`-owned SQL-Agent job whose single step
runs the pipeline as the Agent service account. The pipeline itself is data-driven — its
eight steps are rows in `ops.tResetStep`, dispatched through a whitelist that admits only
deployed `reset.spInternal_*` procedures — so adding a preparation step never edits the
orchestrator. Colleagues read status back through `reset.spPub_GetResetStatus`; `RoboticoOps`
is otherwise invisible to them.

## What changed vs. before

- **Before:** `Robotico.*` and our `CustomWorkflows.*` objects were deployed by hand via
  SSMS — no journal, no versioning, no record of what ran where. The test-mandant reset was
  a PowerShell script requiring personal admin rights on production, configured through a
  git-ignored JSON synced over Google Drive, with no audit trail.
- **After:** every object we own is deployed by a journalled, hash-tracked chain and is
  reproducible from git. `RoboticoOps` holds the registries (`ops.tMandant`, `ops.tConfig`,
  `ops.tResetRequest`, `ops.tResetStep`) as the single versioned config home — licence keys
  included, column-protected, seeded by sentinel plus a runbook UPDATE so no secret ever
  enters git. A reset is one `EXEC` for a rights-less caller and leaves a full audit row.

## Deliberate non-changes / scope boundaries

- **`dbo` is never touched by a migration.** JTL owns it; the `RoboticoEKL` schema belongs to
  the excel_ekl runner, which stays untouched (D10, plan `research/1.1`).
- **Ebene A is not renamed** onto the Hungarian convention. Its `up/` scripts are hash-journaled
  on the non-disposable `eazybusiness` and it is externally bound (an excel_ekl compat
  contract plus a DotLiquid workflow property) — see [ADR-0007](../../decisions/0007-ebene-b-hungarian-naming.md)
  §Failure Modes.
- **The legacy PowerShell path was not decommissioned** by this plan (D12). Phase 7 —
  retiring it — is a separate, deliberate step after trust is built.
- **PayPal object removal is out of scope** and parked on its own branch
  `feature/paypal-removal`. The PROD cutover left the PayPal objects untouched.
- **No plan step ever wrote to a SQL server.** Deployment is runbook work; the test campaign
  ran exclusively against a throwaway container.

## Reports

Per-run artefacts live in [`./reports/`](reports/):

- **[`prod-cutover-2026-07-29.md`](reports/prod-cutover-2026-07-29.md)** — the production
  cutover protocol: legacy-Ola cleanup, both deploys, maintenance go-live, mandant registry,
  and the first production reset (tm4, `succeeded` after 332 s). Closes with five follow-ups
  that outlive this plan.
- **[`migration-testplan/`](reports/migration-testplan/)** — the migration test campaign:
  five detail plans (T1–T5) consolidated into
  [`99-gesamttestplan.md`](reports/migration-testplan/99-gesamttestplan.md), with execution
  results under [`ergebnisse/`](reports/migration-testplan/ergebnisse/). It surfaced five real
  migration bugs; [`T6-fix-verifikation.md`](reports/migration-testplan/ergebnisse/T6-fix-verifikation.md)
  records all five VERIFIED-FIXED at 70/70 regression checks.
- **[`test1-rollout-report.md`](reports/test1-rollout-report.md)** — the test1 dress rehearsal
  plus the teardown/redeploy that carried the Ebene-B rename; its companion mapping is
  [`naming-inventory-hungarian.md`](reports/naming-inventory-hungarian.md).
- **[`implementation-report.md`](reports/implementation-report.md)**,
  [`e2e-test.md`](reports/e2e-test.md) / [`e2e-runbook.md`](reports/e2e-runbook.md), the block-B1
  audit and repair reports ([`reports/B1/`](reports/B1/)), the quality-gate rounds
  ([`qg2/`](reports/qg2/), [`qg3/`](reports/qg3/)), and the documentation-run reports.
- **YouTrack knowledge-base source files** — the colleague-facing documentation is maintained
  here and uploaded to YouTrack, because the API can only overwrite an article wholesale:
  [`youtrack-testmandant-reset-kurzanleitung.md`](reports/youtrack-testmandant-reset-kurzanleitung.md)
  (article JTL-A-20, German) and its English twin
  [`youtrack-testmandant-reset-kurzanleitung.en.md`](reports/youtrack-testmandant-reset-kurzanleitung.en.md)
  (JTL-A-21). **Edit these files, then re-upload** — and keep the mandant table in sync with
  `ops.tMandant.cDeveloper`.

Research evidence sits in [`./research/`](research/) (tooling comparison, instance survey,
module-signing recipe, JTL specifics, repo inventory, and the maintenance baseline analysis
that the sister plan `2026-07-21 - mssql-wartung-ola` builds on).

## Related ADRs

All five were drafted plan-scoped and promoted to `docs/decisions/` on 2026-07-29 with the
production cutover; all are **Accepted** and cross-reference this plan bidirectionally.

- [ADR-0003 — grate as the SQL migration runner](../../decisions/0003-grate-migration-runner.md):
  grate over DACPAC/Flyway/DbUp/hand-rolled, journal pinned to an own schema per chain.
- [ADR-0004 — Two migration chains, one tool, script-only promotion](../../decisions/0004-two-chain-migration-paths.md):
  Ebene A versions what is copied, Ebene B versions what is unique; no image promotion.
- [ADR-0005 — Hybrid module-signing + async agent-job reset](../../decisions/0005-module-signing-reset.md):
  signed entry SP, `sa`-owned job, queue table as parameter + audit mechanism, status SP,
  column-protected licence config.
- [ADR-0006 — Data-driven reset pipeline](../../decisions/0006-reset-step-registry.md):
  `ops.tResetStep` registry + whitelisted dispatch, and the bounded narrowing of ADR-0005's D6.
- [ADR-0007 — Ebene-B objects adopt the RoboticoEKL Hungarian convention](../../decisions/0007-ebene-b-hungarian-naming.md):
  the in-place rename, why it was safe on a disposable database, and why Ebene A is exempt.

The sister plan [`2026-07-21 - mssql-wartung-ola`](../2026-07-21%20-%20mssql-wartung-ola/)
builds the maintenance suite on top of this foundation
([ADR-0001](../../decisions/0001-maintenance-as-code-roboticoops.md),
[ADR-0002](../../decisions/0002-backups-cbb-retained.md)) and depended on this plan's PROD
cutover as a hard precondition.

## Where the living documentation lives

The plan is history; the operating rules are not. They live at:

- [`docs/SQL/MSSQL-OPS-ARCHITECTURE.md`](../../SQL/MSSQL-OPS-ARCHITECTURE.md) — how the pieces fit together.
- [`docs/SQL/MSSQL-OPS-DATA-MODEL.md`](../../SQL/MSSQL-OPS-DATA-MODEL.md) — column-level `ops.*` reference (update contract in `CLAUDE.md`).
- [`db-migrations/README.md`](../../../db-migrations/README.md) — the migration contract, folder semantics, and "adding a reset step".
- [`docs/runbooks/`](../../runbooks/) — rollout, baseline, reset validation, hygiene findings.

## Archive artefacts (unchanged on purpose)

`mssql-ops-infrastruktur.state.md`, `mssql-ops-infrastruktur.impl-state.md` and
`chunks.json` are the orchestration record of the implementation run. They are kept as
written — including the pre-rename object names and plan-scoped ADR paths they mention — so
the run stays auditable.
