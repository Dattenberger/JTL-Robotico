# ADR-NNNN: grate as the SQL migration runner for JTL-Robotico

**Status:** Proposed (plan-scoped — pending promotion)
**Subsystem:** DB / Migrations
**Date:** 2026-07-10
**Supersedes:** —
**Author:** Lukas + Claude Code

> **Cooperates with** the two-chain ADR (`adr-two-chain-migration-paths.md`). This
> ADR chooses the *tool* and its *journal schema*; the sister ADR decides *how many
> chains* the tool runs and *where each journal lives*. Both are promoted together.

## Research

The tool comparison and grate deep-dive in
[`research/1-migrations-tooling/1-migrations-tooling.md`](../research/1-migrations-tooling/1-migrations-tooling.md)
is the empirical basis:

- **Object inventory is `CREATE-OR-ALTER`-heavy** (§"Punkt-für-Punkt für unser Repo",
  L111): almost every object we own is a function or stored procedure that we re-deploy
  by redefining it. grate's *anytime* folders with content-hash tracking re-run a file
  only when its hash changes — an exact fit, no bespoke change-detection needed.
- **grate is a self-contained CLI** (§"grate-Vertiefung", L47; §"CLI", L74): a single
  `dotnet tool install --global grate` with no host program to write or maintain, unlike
  DbUp (needs a C# host) — see the comparison table at L26.
- **The journal schema is configurable** (§"Journal-Tabellen", L90): grate's
  `ScriptsRun` / `ScriptsRunErrors` / `Version` tables live in whatever `--schema` you
  pass, which is what lets us keep them out of `dbo` and inside our own schema.
- **Vendor-schema coexistence best practice** (§"Vendor-Schema-Koexistenz", L39):
  a versioned migration tool must never touch the vendor's `dbo`; an own-schema journal
  is the recommended isolation.

Cross-repo lesson from
[`research/1.1-ekl-runner-grenze/1.1-ekl-runner-grenze.md`](../research/1.1-ekl-runner-grenze/1.1-ekl-runner-grenze.md)
§"Übertragbare Lessons" (L65): the excel_ekl runner's prod incidents were caused by
hard-coded JTL IDs and silent skips — reinforcing that the runner's discipline
(resolve-by-name, hard FAIL on missing prerequisites) matters more than the specific
engine, and that a second bespoke runner in this SQL-only repo is undesirable.

## Context

The `Robotico.*` objects and our `CustomWorkflows.*` action procedures were deployed
ad hoc via SSMS — no journal, no versioning, no idempotency guarantee, no record of what
ran where. The requirement was: versioned, journalled, idempotent migrations with a way
to baseline the existing populated databases. The repo is **SQL-only** (no build system,
no package manager), and it must **coexist** with two vendors in the same instance: JTL
(owns `dbo`) and the excel_ekl runner (owns `RoboticoEKL`, co-inhabits `CustomWorkflows`).

## Decision

**grate** (https://github.com/grate-devs/grate) is the migration runner for this repo,
installed as a global .NET tool and invoked through a thin `db-migrations/deploy.ps1`
wrapper. The existing excel_ekl runner in the excel_ekl repo stays untouched.

The **journal never lives in `dbo` or grate's default `grate` schema**. It lives in an
own schema, selected per chain via grate's `--schema`:

- Ebene A (`eazybusiness/`): `--schema=Robotico` → journal tables in the `Robotico`
  schema of *every* eazybusiness copy.
- Ebene B (`global/`): `--schema=ops` → journal tables in the `ops` schema of the
  `RoboticoOps` DB.

`RoboticoEKL` is off-limits as a journal home (foreign ownership). grate's folder model
is used as: `up/` (one-time, hash-tracked, immutable after apply), `functions/` /
`views/` / `sprocs/` (anytime, re-run on hash change), `runAfterOtherAnyTimeScripts/`
(anytime, last), `permissions/` (everytime). Full folder/naming/lint contract lives in
[`db-migrations/README.md`](../../../../db-migrations/README.md).

## Alternatives Considered

1. **DbUp.** A .NET migration library. Rejected: it needs a compiled C# host program
   to run — a build artefact this SQL-only repo has no place for — and its `RunAlways`
   scripts have no content-hash change-detection or audit trail, so it would re-run every
   anytime object on every deploy (comparison table, research/1 L26).

2. **DACPAC / SSDT state-based deployment.** Declarative "desired-state" model.
   Rejected on **vendor coexistence**: DACPAC wants to own the whole schema and would try
   to reconcile (drop) JTL's and excel_ekl's objects it did not author. Migration-based
   tooling that touches only its own named objects is the only safe model here.

3. **Flyway.** Mature migration tool. Rejected on the **licence/Java** situation — the
   free tier is constrained and it drags in a Java runtime, weight this repo does not want.

4. **Hand-rolled T-SQL runner.** A batch of idempotent scripts driven by our own journal
   table. Rejected: it would reinvent exactly what grate ships (hash tracking, ordered
   folders, `--baseline`, error journal) with none of the maturity — see the EKL runner,
   which is that path and whose incidents (research/1.1 L65) show the cost.

5. **Adopt the excel_ekl runner's pattern.** Reuse the sibling repo's TypeScript-driven
   migration toolchain. Rejected (user decision 2026-07-09): it is bound to a TS
   toolchain this SQL-only repo does not have, and D10 fixes the excel_ekl runner as an
   untouched foreign system, not a template to fork.

## Consequences

**Positive:**
- Zero host code to maintain — grate is an external tool, upgraded independently.
- Anytime + hash-tracking maps 1:1 onto our `CREATE OR ALTER`-heavy object set: an
  unchanged proc file simply does not re-run.
- `--baseline` lets us adopt the already-deployed databases without re-executing objects
  (see `docs/runbooks/migrations-baseline.md`).
- Own-schema journal (`Robotico` / `ops`) keeps the vendor boundary intact and — for
  Ebene A — travels with a mandant clone so a fresh clone knows its own state.

**Negative:**
- A new external dependency (`grate` on `PATH`) that every deployer must install; a
  machine without it cannot deploy. `deploy.ps1` fails loudly with an install hint rather
  than silently doing nothing.
- The team must learn grate's folder semantics (one-time vs. anytime vs. everytime). The
  `db-migrations/README.md` is the mitigating contract, and the lint enforces the rules
  mechanically.

**Failure Modes:**
- **Editing an applied `up/` script** silently corrupts the journal: grate tracks
  one-time scripts by content hash and fails the next run with a hash mismatch — and a
  mandant clone would carry a definition that disagrees with prod. The rule "one-time
  scripts are immutable after apply; correct via a *new* `up/` script" is a footgun that
  is invisible until the next deploy. The escape hatch
  `--warnandignoreononetimescriptchanges` is runbook-only, never a `deploy.ps1` default.
- **`--runallanytimescripts` in PROD** re-runs every anytime object regardless of hash,
  needlessly dropping/recreating signatures and extended properties. Forbidden in prod;
  local-dev convenience only.
- **A wrong `--schema`** would create a *second* journal and make grate think nothing ran.
  The wrapper hard-codes the schema per `-Scope`, so this cannot happen through the
  supported entry point — but a raw `grate` call bypassing `deploy.ps1` could trip it.

## References

- **Related Plan (motivated + implements this ADR):**
  [mssql-ops-infrastruktur](../mssql-ops-infrastruktur.md) — decisions **D1** (grate as
  runner) and **D3** (journal schema `Robotico` / `ops`). §1 implements the Ebene-A tree.
- **Related ADRs:**
  - `adr-two-chain-migration-paths.md` — decides the two-chain topology this runner serves.
- Research: [`research/1-migrations-tooling`](../research/1-migrations-tooling/1-migrations-tooling.md),
  [`research/1.1-ekl-runner-grenze`](../research/1.1-ekl-runner-grenze/1.1-ekl-runner-grenze.md).
- Contract / implementation: [`db-migrations/README.md`](../../../../db-migrations/README.md),
  lint `db-migrations/tests/lint-migrations.ps1`.
- External: grate — https://github.com/grate-devs/grate (RoundhousE successor).

## Decision History

### 2026-07-10 — Initial proposal

**Trigger:** Plan requirement "migrations must be versionable + maintainable"; tool
comparison research (research/1); user direction 2026-07-09 to standardise on grate.

**Before:** No migration tooling. `Robotico.*` / `CustomWorkflows.*` objects were
deployed ad hoc via SSMS with no journal, no versioning, no idempotency guarantee.

**After:** grate is the runner (self-contained CLI, thin `deploy.ps1` wrapper), with the
journal pinned to an own schema per chain (`Robotico` for Ebene A, `ops` for Ebene B) so
it never sits in `dbo`/`grate` and — for Ebene A — travels with the clone.

**Reasoning:** The `CREATE OR ALTER`-heavy object set fits grate's anytime+hash model
exactly; no host code to maintain; `--baseline` adopts the existing databases; the
own-schema journal preserves the vendor boundary. DACPAC fails on vendor coexistence,
Flyway on the licence/Java situation, DbUp on the host-program + missing change-detection,
and a hand-rolled runner would rebuild grate badly (the EKL runner is that path, and its
incidents show the cost).
