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
