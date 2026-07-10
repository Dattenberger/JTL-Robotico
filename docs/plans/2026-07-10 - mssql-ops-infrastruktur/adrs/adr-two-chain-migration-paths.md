# ADR-NNNN: Two migration chains (Ebene A / Ebene B), one tool, script-only promotion

**Status:** Proposed (plan-scoped — pending promotion)
**Subsystem:** DB / Migrations
**Date:** 2026-07-10
**Supersedes:** —
**Author:** Lukas + Claude Code

> **Cooperates with** the grate-runner ADR (`adr-grate-migration-runner.md`). That ADR
> chooses grate and the own-schema journal; this ADR decides that grate runs **two**
> chains with **different journal homes** and how changes flow from test to prod.

## Research

- **Instance survey**
  [`research/2-instanz-survey/2-instanz-survey.md`](../research/2-instanz-survey/2-instanz-survey.md):
  test1 runs **SQL Server 2025**, prod runs **SQL Server 2022** (§1 "Instanz-Basis",
  L14). A backup taken on 2025 cannot be restored onto 2022 — restore is **old→new only**.
  This is the hard constraint behind script-only promotion (D11). The survey also confirms
  the `RoboticoOps` name is collision-free on both instances (§8 "RoboticoOps-Vorprüfung",
  L89).
- **grate journal mechanics**
  [`research/1-migrations-tooling`](../research/1-migrations-tooling/1-migrations-tooling.md)
  §"Journal-Tabellen" (L90): the journal lives in the `--schema` schema *inside the target
  DB*. A per-DB journal is therefore automatically part of a backup+restore clone — the
  property Ebene A relies on.
- **excel_ekl test→prod flow**
  [`research/1.1-ekl-runner-grenze`](../research/1.1-ekl-runner-grenze/1.1-ekl-runner-grenze.md)
  §3 "Ziel-DB-Konfiguration" (L32): the established EKL practice already deploys migration
  *025* on test1 and *024* on prod — an existing, proven "test first, then prod, scripts
  only" rhythm that D11 aligns with rather than reinventing.

## Context

Two very different kinds of thing need versioning, and conflating them breaks:

1. **Copyable content** — the `Robotico.*` objects and our `CustomWorkflows.*` procs that
   must exist inside *every* eazybusiness copy, including every `eazybusiness_tmN` clone.
   A mandant clone is a backup+restore of prod's `eazybusiness`, so whatever migration
   state prod had must travel into the clone.
2. **Instance uniques** — the `RoboticoOps` DB, the logins, the signing certificate, the
   SQL-Agent job, server-level grants. These exist **once per SQL instance** and are
   **never** part of a clone.

If a single journal in a central DB tracked both, the clone would lose its Ebene-A state
(the central journal does not travel with the backup), and the runner would think a fresh
clone still needs — or has already had — migrations it has not.

## Decision

Run grate as **two logically separate chains through one tool**, split by *whether the
content is copied*:

| Ebene | Folder | Journal home | Scope | Contents |
|---|---|---|---|---|
| **A** | `db-migrations/eazybusiness/` | schema `Robotico`, **decentralised per DB** | every eazybusiness copy incl. clones | `Robotico.*` + our own `CustomWorkflows.*` |
| **B** | `db-migrations/global/` | schema `ops` in the **`RoboticoOps`** DB of that instance | one instance | `RoboticoOps`, logins, certs, agent job, server grants |

**The dividing line:** *Ebene A versions content that is copied along; Ebene B versions
uniques that are never copied. Nothing is both.* Because the Ebene-A journal sits inside
each DB, a clone brings its own migration state with it and knows what already ran.
Because Ebene-B objects have no clone mechanism, every Ebene-B `up/` script is written
idempotently (`IF NOT EXISTS` guards) so a re-run is harmless.

**Promotion is script-only, and test1 is a first-class Ebene-A target (D11).** No rollout
step may ever require a DB image built on test1 (SQL 2025) to reach prod (SQL 2022) —
only versioned scripts flow toward prod. Deploy order is *test1 and/or a test mandant →
prod*. Refreshing test1 with real data still happens by restoring a prod backup
(old→new, allowed). `targets.config.json` therefore lists the mandant clones as regular
Ebene-A targets: deploying to them is normally unnecessary (the clone brings the state),
but it is the supported way to test a migration on a mandant before prod.

## Alternatives Considered

1. **One central journal for all databases (in `RoboticoOps`).** Track every DB's
   migration state in one place. Rejected: it breaks on cloning — the state lives in
   `RoboticoOps`, which is not part of an `eazybusiness` backup, so a fresh clone would
   have no journal and grate would either re-run everything or, worse, be told (from the
   central journal) that scripts ran which the clone does not actually contain.

2. **Two different tools, one per path.** e.g. grate for Ebene A, a bespoke idempotent
   script pack for Ebene B. Rejected: unnecessary cognitive load and two mental models for
   one team; one tool for both chains, split only by `-Scope`, is simpler.

3. **Image-based promotion (restore a test1-built DB onto prod).** Rejected on a hard
   engine constraint: 2025→2022 restore is impossible (research/2 §1). Even absent the
   version gap, shipping images rather than scripts loses the audit/version trail the
   whole plan exists to establish.

4. **Leave test1 as an EKL-only system (never an Ebene-A target).** Rejected: our objects
   there would rot and we could never rehearse a migration before prod (research/1.1 §3
   shows the EKL flow already treats test1 as a real target).

## Consequences

**Positive:**
- A mandant clone is self-describing: its `Robotico` journal travels with the restore, so
  no separate baseline is needed after cloning.
- Instance uniques are isolated in their own idempotent chain — re-running Ebene B on an
  instance is always safe.
- One tool, one `deploy.ps1`, `-Scope` picks the chain — minimal surface to learn.
- The engine version gap is handled by *design*, not by remembering a rule: promotion is
  script-only because that is the only chain that exists.

**Negative:**
- Two journals to reason about (a per-DB `Robotico` one and the instance `ops` one) — a
  reader must know which chain a change belongs to before writing it. The
  `db-migrations/README.md` chain table and the lint carry that knowledge.
- Ebene-B idempotency is *hand-written* (`IF NOT EXISTS`), not tool-enforced like Ebene-A
  hashes — a sloppy Ebene-B `up/` script that is not guarded would fail on re-run.

**Failure Modes:**
- **Putting a copyable object into Ebene B (or an instance-unique into Ebene A)** is the
  central mistake this split guards against, and nothing mechanical catches it: a
  `Robotico.*` object misfiled under `global/` would never reach the clones; a login
  misfiled under `eazybusiness/` would be attempted inside every clone and fail. The
  "is it copied?" test in the README is the only guard — apply it consciously.
- **Deploying Ebene A to a clone that a later re-clone will overwrite** wastes effort and
  can confuse (the re-clone resets the journal to prod's). Deploy-to-clone is *only* for
  pre-prod migration testing, not routine operation.
- **Assuming a test1 image can seed prod** re-introduces the 2025→2022 impossibility.
  Runbooks phrase every prod step as "run the scripts", never "restore the test build".

## References

- **Related Plan (motivated + implements this ADR):**
  [mssql-ops-infrastruktur](../mssql-ops-infrastruktur.md) — decisions **D2** (two chains,
  one procedure) and **D11** (script-only promotion, test1 as Ebene-A target). §1/§2
  implement the two trees; `targets.config.json` encodes the target catalogue.
- **Related ADRs:**
  - `adr-grate-migration-runner.md` — the tool and journal-schema choice this topology uses.
- Research: [`research/2-instanz-survey`](../research/2-instanz-survey/2-instanz-survey.md),
  [`research/1-migrations-tooling`](../research/1-migrations-tooling/1-migrations-tooling.md),
  [`research/1.1-ekl-runner-grenze`](../research/1.1-ekl-runner-grenze/1.1-ekl-runner-grenze.md).
- Contract: [`db-migrations/README.md`](../../../../db-migrations/README.md) §1 (the two
  chains), `db-migrations/targets.config.json`.
- Operations: [`docs/runbooks/migrations-baseline.md`](../../../runbooks/migrations-baseline.md),
  [`docs/runbooks/rollout-mssql-ops.md`](../../../runbooks/rollout-mssql-ops.md).

## Decision History

### 2026-07-10 — Initial proposal

**Trigger:** User requirement to cleanly separate "the database globally" from
"`eazybusiness` content"; the instance survey's finding of a 2025/2022 engine split
(research/2 §1); user decision F3.

**Before:** A single ad-hoc deployment habit with no notion of *where* migration state
lives, and no defined path to roll a DB feature from test to prod.

**After:** Two grate chains split by copyability — Ebene A (`eazybusiness/`, journal in
`Robotico` per DB, travels with the clone) and Ebene B (`global/`, journal in `ops` inside
`RoboticoOps`, idempotent, never copied) — with script-only promotion and test1 as a
regular Ebene-A target.

**Reasoning:** A per-DB journal is the only model where a clone knows its own state; a
central journal breaks on cloning. One tool for both chains keeps the mental model small.
The 2025→2022 restore impossibility makes script-only promotion the only physically
correct option, and it matches the excel_ekl team's established test-first rhythm.
