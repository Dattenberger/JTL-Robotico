# Architecture Decision Records

Non-trivial technical decisions made across this repository, recorded as ADRs.
Each ADR captures the *why* behind a decision so a future reader can understand
it without access to the conversation, plan review, or people that produced it.

- **Format / lifecycle:** `knowledge-adr-format` skill + `~/.claude/snippets/docs/lifecycle-adr.md`.
- **Consult before designing:** scan this index for ADRs whose `Subsystem:` matches
  your area (plus all `Scope: Project-Wide` ADRs) before starting a feature or refactor.
- **Numbering:** sequential `NNNN`, assigned at promotion from a plan-scoped draft.
  Plan-scoped ADR drafts live under `docs/plans/<plan>/adrs/` until promoted here.
- **Subsystem values** come from the `CLAUDE.md` "Subsystems" table; `Scope: Project-Wide`
  rows show `*Project-Wide*` (italic) in the Subsystem / Scope column.

## Index

| Nr | Title | Subsystem / Scope | Status | Date |
|----|-------|-------------------|--------|------|
| [0001](0001-maintenance-as-code-roboticoops.md) | SQL-Server maintenance as code — Ola Hallengren vendored in RoboticoOps, declarative job registry | RoboticoOps, JTL SQL Migrations, Testmandant Reset | Accepted | 2026-07-21 |
| [0002](0002-backups-cbb-retained.md) | Backups stay with CBB — SQL maintenance monitors the chain, does not own backups | RoboticoOps, Testmandant Reset | Accepted | 2026-07-21 |
| [0003](0003-grate-migration-runner.md) | grate as the SQL migration runner for JTL-Robotico | JTL SQL Migrations | Accepted | 2026-07-10 |
| [0004](0004-two-chain-migration-paths.md) | Two migration chains (Ebene A / Ebene B), one tool, script-only promotion | JTL SQL Migrations, RoboticoOps | Accepted | 2026-07-10 |
| [0005](0005-module-signing-reset.md) | Hybrid module-signing + async agent-job for the test-mandant reset | RoboticoOps, Testmandant Reset | Accepted | 2026-07-10 |
| [0006](0006-reset-step-registry.md) | Data-driven reset pipeline (`ops.ResetStep` registry + whitelisted dispatch — today `ops.tResetStep`, see ADR-0007) | RoboticoOps, Testmandant Reset | Accepted | 2026-07-11 |
| [0007](0007-ebene-b-hungarian-naming.md) | Ebene-B (RoboticoOps) objects adopt the RoboticoEKL Hungarian naming convention | RoboticoOps, JTL SQL Migrations, Testmandant Reset | Accepted | 2026-07-13 |

> **Note on numbering vs. date:** ADR-0003…0007 carry earlier dates than ADR-0001/0002
> because they were drafted plan-scoped inside the older `mssql-ops-infrastruktur` program
> and promoted only when that program reached its production cutover (2026-07-29), while the
> shorter `mssql-wartung-ola` plan finished first. The `NNNN` sequence records promotion
> order; the `Date:` header records when the decision was made.
