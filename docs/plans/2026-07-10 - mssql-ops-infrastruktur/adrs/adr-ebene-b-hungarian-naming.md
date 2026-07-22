# ADR-NNNN: Ebene-B (RoboticoOps) objects adopt the RoboticoEKL Hungarian naming convention

**Status:** Proposed (plan-scoped — pending promotion)
**Subsystem:** RoboticoOps, JTL SQL Migrations, Testmandant Reset
**Date:** 2026-07-13
**Supersedes:** —
**Author:** Lukas + Claude Code

> **Reverses an earlier in-plan decision.** The plan originally gave the `RoboticoOps`
> (`ops.*` / `reset.*`) objects a plain, un-prefixed PascalCase "admin-DB" style
> (`ops.Mandant`, columns `MandantKey`/`IsActive`/`CreatedAt`, procs `StartTestmandantReset`
> with no `sp` prefix), documented in `docs/SQL/NAMING-CONVENTIONS.md §9`. This ADR records
> the reversal onto the RoboticoEKL Hungarian convention and why it was safe to do in place.

## Research

- **The RoboticoEKL convention (the standard Lukas set as the yardstick)**, obtained read-only
  from the sister repo: `excel_ekl/backend/migrations/jtl/README.md §Namenskonventionen`
  (tables `t<Singular>`, views `v<Purpose>`, SPs `sp<Action>`, index `IX_<tTable>_<Purpose>`,
  constraints `UQ|FK|CK_<tTable>_<…>` — note **no schema segment**) and the live
  `RoboticoEKL.*` object inventory: public entry procs `spPub_SetArticlePhase` /
  `spPub_UpdateEbayItemPrice` vs. internal helpers `spCreateLabelSnapshot` /
  `spApplyArticlePhaseEffects`, and `RoboticoEKL.tMigrationHistory` columns
  (`kMigration`/`nVersion`/`cFileName`/`dApplied`/**`bSuccess`** — `b` for `bit`).
- **Naming inventory** `reports/naming-inventory-hungarian.md` (v2): the full per-object mapping,
  the finding that **Ebene A was already conformant** (`Robotico.fn*`/`sp*`/`tPaypal*` with
  Hungarian columns), and the impact analysis that scoped the change to Ebene B.
- **The `bActive` vs `nActive` conflict**, surfaced during the research: Lukas' first instruction
  said `nActive` (n-prefix), but the EKL reference itself uses `b` for `bit` (`bSuccess`) — Lukas
  then chose `bActive` to match the chosen standard exactly (§4 Q1 of the inventory).
- **Dress-rehearsal evidence** that the rename is deployable: `reports/test1-rollout-report.md`
  — `RoboticoOps` is disposable (full teardown + redeploy proven green), unlike the Ebene-A
  `eazybusiness` chain whose one-time scripts are hash-journaled on a non-disposable DB.

## Context

Ebene A (`eazybusiness` content, schema `Robotico`) already followed the JTL / RoboticoEKL
Hungarian convention because it was ported from prod objects that already used it. Ebene B
(`RoboticoOps`, schemas `ops`/`reset`) was written fresh in a plain "admin-DB" style and
diverged: un-prefixed tables, PascalCase columns, and stored procedures with **no `sp` prefix
at all**. That split — two of our own schemas following two different conventions — is exactly
the kind of inconsistency the next maintainer pays for. Lukas decided to align Ebene B with the
RoboticoEKL standard. The open question was feasibility: Ebene-B's `up/` scripts are one-time
and grate tracks them by content hash, so an in-place rename is only safe where the deployed
database can be rebuilt.

## Decision

Rename **all Ebene-B (`RoboticoOps`) objects** onto the RoboticoEKL Hungarian convention, in
place in the SQL files, and rebuild the deployed instance by teardown + redeploy (not via a new
`up/` migration). Concretely:

- **Tables:** `ops.Mandant/Config/ResetRequest/ResetStep` → `ops.tMandant/tConfig/tResetRequest/tResetStep`.
- **Columns:** English identifier + Hungarian type prefix — `c` string, `k` int surrogate key,
  `b` bit, `d` datetime, `n` non-key int. E.g. `MandantKey`→`cMandantKey`, `IsActive`→**`bActive`**,
  `CreatedAt`→`dCreated`, `RequestId`→`kResetRequest`, `StepOrder`→`nStepOrder`,
  `ConfigKey/Value`→`cKey/cValue`, `ErrorText`→`cErrorMessage`.
- **Constraints/indexes:** EKL style `<Type>_<tTable>_<column>`, **dropping the schema segment**
  (`PK_ops_Mandant`→`PK_tMandant`, `CK_ops_ResetRequest_Status`→`CK_tResetRequest_cStatus`,
  `UX_ResetRequest_Active`→`IX_tResetRequest_Active`).
- **Stored procedures:** the public/internal split from EKL — **`spPub_<Name>`** for the six
  colleague-facing entry points (`spPub_StartTestmandantReset`, `spPub_GetResetStatus`,
  `spPub_ListMandants`, `spPub_CancelResetRequest`, `spPub_CreateTestmandant`,
  `spPub_PurgeOldRequests`); **`spInternal_<Name>`** for the eight pipeline steps + `spInternal_LogStep`;
  plain **`sp<Name>`** for the orchestrator/infra procs (`spProcessNextResetRequest`,
  `spEnsureAgentJob`). The anytime filename equals the object (lint-enforced), so each proc file
  is renamed too.
- **Left unchanged:** the schemas `ops`/`reset` (they are the grate journal schema and a
  deliberate data/procs split), the roles `ops_admin`/`ops_reset_executor` (EKL has no role
  convention), the instance-global proper nouns (`jobstartuser`, `RoboticoOpsSigning`,
  `RoboticoOpsSigningLogin`, the agent job), the grate journal tables (tool-owned), and **all of
  Ebene A** (already conformant, and externally/hash-bound — see Failure Modes).

The dispatch whitelist moves with the proc rename (see Failure Modes): the `internal_` marker
becomes `spInternal_` in the orchestrator's `p.name LIKE N'spInternal[_]%'` guard, the
`CK_tResetStep_cProcName` CHECK, and the eight `ops.tResetStep` seed rows.

Implemented in commit `72f8c17`; the reversal is documented in `NAMING-CONVENTIONS.md §9` (and
§5 clarifies that the `spPub_`/`spInternal_` *naming markers* are adopted while the excel_ekl
article-orchestration *apparatus* is not).

## Alternatives Considered

1. **Keep the plain PascalCase "admin-DB" style.** Zero churn, and the reset subsystem reads
   fine on its own. Rejected: it leaves two of our own schemas (`Robotico` vs `ops`/`reset`) on
   two different conventions, which is precisely the inconsistency a naming convention exists to
   remove; and the `RoboticoEKL` tooling/readers expect the Hungarian shape.

2. **JTL-vendor German Hungarian (`dErstellt`, `nAktiv`, `CK_dbo_t…` with schema segment).**
   The literal JTL-Wawi vendor style. Rejected in favour of the *RoboticoEKL* variant Lukas
   named as the standard: English identifiers (`dCreated`, `bActive`) and schema-less constraint
   names (`PK_tMandant`), which is what the sister repo actually ships and what our own Ebene-A
   objects already lean toward.

3. **`nActive` for the bit flag (Lukas' first instinct).** Matches JTL's dominant `nAktiv`
   idiom. Rejected once the research showed the RoboticoEKL reference itself uses `b` for `bit`
   (`bSuccess`); Lukas chose `bActive` to match the chosen yardstick exactly rather than the
   JTL-vendor idiom.

4. **Fix it via a new `up/` migration (`sp_rename`) instead of editing the applied scripts.**
   The only correct approach on a *non-disposable* chain. Rejected for Ebene B because
   `RoboticoOps` is disposable: an in-place edit + teardown/redeploy yields a clean journal with
   the new content hash and no `sp_rename` scar tissue. (This alternative *is* the mandated path
   for any future Ebene-A change — see Failure Modes.)

## Consequences

**Positive:**
- One convention across all of our own DB objects (`Robotico` and `RoboticoOps`), matching the
  `RoboticoEKL` sister project — a maintainer learns the shape once.
- The `spPub_`/`spInternal_` split makes the public API vs. internal pipeline visible in the name
  itself, reinforcing (and self-documenting) the reset security boundary.
- Constraint names are shorter and schema-independent, matching the EKL/JTL house style.

**Negative:**
- A large one-time churn: 38 files, ~30 columns, ~20 constraints, 17 proc renames, plus every
  validator/PowerShell/live-doc reference — all had to move in lockstep.
- It reverses a previously *documented* decision (`NAMING-CONVENTIONS.md §9`), so the doc now
  carries a "this replaces an earlier decision" note and this ADR — a small ongoing cost in
  explaining "why did the names change once".
- The deployed `RoboticoOps` must be **rebuilt** (teardown + redeploy), not migrated — acceptable
  only because Ebene B is disposable.

**Failure Modes:**
- **The dispatch whitelist is load-bearing and split across three places.** A pipeline step proc
  MUST be named `spInternal_<Name>` or `reset.spProcessNextResetRequest` will refuse to run it
  (`p.name LIKE N'spInternal[_]%'`), and `ops.tResetStep.cProcName` has a matching CHECK. Rename a
  step without updating all three (orchestrator guard, CHECK, seed) and either the deploy fails
  (CHECK) or the step is silently skipped as "unknown proc". The §9 runbook for adding a step
  now says `spInternal_`.
- **Teardown must drop the master signing artefacts too, not just the DB.** Dropping only
  `RoboticoOps` leaves the old public certificate + `RoboticoOpsSigningLogin` in `master`; the
  redeployed `up/0011` mints a **new** certificate (new thumbprint) that no longer matches them,
  and the module-signing chain into `msdb` breaks. The teardown must also
  `DROP CERTIFICATE RoboticoOpsSigning` + `DROP LOGIN RoboticoOpsSigningLogin` in `master` so
  `0011` rebuilds the whole chain consistently (the cert password persists via deploy.ps1 tier 2).
- **Ebene A must NOT be renamed the same way.** Its `up/0001`/`0002` are one-time scripts already
  hash-journaled on the non-disposable `eazybusiness` (and clones inherit them); an in-place edit
  trips a grate hash mismatch. It is also externally bound — `Robotico.fnEscapedCSVParseLine` is
  an excel_ekl backward-compat contract and a DotLiquid workflow property calls
  `Robotico.fnHasOlderDuplicateOrder`. Any future Ebene-A rename is a **new `up/` `sp_rename`
  migration** plus coordinated consumer updates, never an in-place edit.
- **Constraint de-schema-qualification narrows the namespace.** `PK_tMandant` (no schema segment)
  would collide if a second `tMandant` were ever created in another schema of `RoboticoOps`.
  Constraint names are database-global; the EKL style trades the schema disambiguator for
  brevity. Low risk here (one `tMandant`), but worth knowing before adding same-named tables.

## References

- **Related Plan:** [mssql-ops-infrastruktur](../mssql-ops-infrastruktur.md) — the plan whose
  dress rehearsal surfaced this decision.
- **Naming inventory (research/spec):** [`reports/naming-inventory-hungarian.md`](../reports/naming-inventory-hungarian.md) — full per-object mapping + impact analysis.
- **Rollout report:** [`reports/test1-rollout-report.md`](../reports/test1-rollout-report.md) — dress rehearsal + rename teardown/redeploy/re-validation.
- **Convention doc:** [`docs/SQL/NAMING-CONVENTIONS.md`](../../../SQL/NAMING-CONVENTIONS.md) §5, §9 (records the reversal).
- **Implementation:** commit `72f8c17`; validators `db-migrations/tests/global/validate_structure.sql` + `validate_rollout.sql`.
- **Related ADRs:** `adr-reset-step-registry.md` — owns the whitelisted-dispatch mechanic whose `internal_`→`spInternal_` marker this ADR renames; `adr-module-signing-reset.md` — owns the signing chain whose teardown caveat appears in Failure Modes; [`../../../decisions/0001-maintenance-as-code-roboticoops.md`](../../../decisions/0001-maintenance-as-code-roboticoops.md) §D-A2 — extends this convention with the `t` = `time`-column micro-use (`ops.tMaintenanceJob.tStartTime`, D20), the deliberate second booking of the `t` prefix beyond `t<Table>`.

## Decision History

### 2026-07-13 — Initial proposal

**Trigger:** After the test1 dress rehearsal proved the reset infrastructure end-to-end, Lukas
reviewed the object names and decided our own `RoboticoOps` objects should match the RoboticoEKL
naming standard (the excel_ekl migration schema), not the plain PascalCase style the plan had
shipped. A read-only study of the EKL convention (`naming-inventory-hungarian.md`) produced the
mapping and surfaced the `bActive`-vs-`nActive` conflict.

**Before:** Ebene B used un-prefixed PascalCase tables/columns and `sp`-less procedures
(`ops.Mandant.MandantKey`, `reset.StartTestmandantReset`, `reset.internal_CloneDatabase`), as
documented in `NAMING-CONVENTIONS.md §9`. Ebene A already followed the Hungarian convention.

**After:** Ebene B follows the RoboticoEKL Hungarian convention — `t`-prefixed tables, English
Hungarian columns (`bActive`/`dCreated`/`kResetRequest`/`cStatus`…), schema-less EKL constraint
names, and the `spPub_`/`spInternal_`/`sp` proc split (with the dispatch whitelist moved to
`spInternal_`). Ebene A, roles, schemas, and instance-global proper nouns are unchanged.
Implemented in `72f8c17`; the deployed test1 `RoboticoOps` was rebuilt via teardown + redeploy
and re-validated green.

**Reasoning:** One convention across all our DB objects beats a two-style split; RoboticoEKL is
the chosen house standard and Ebene A already aligned with it. The change was safe in place only
because `RoboticoOps` is disposable — the same rename on the non-disposable Ebene-A chain would
require a new `sp_rename` migration and is therefore explicitly out of scope.

### 2026-07-23 — `t` prefix micro-extension: `time`-typed columns (D20)

**Trigger:** The `mssql-wartung-ola` plan (now [ADR-0001](../../../decisions/0001-maintenance-as-code-roboticoops.md)) introduced `ops.tMaintenanceJob.tStartTime`, a `time`-typed schedule column, and needed a Hungarian prefix for it. This is a reciprocal note added when ADR-0001 was promoted to `docs/decisions/`, making the cross-reference bidirectional per `lifecycle-adr.md`.

**Before:** The Hungarian type-prefix set recorded here was `c`/`k`/`b`/`d`/`n` (string / int key / bit / datetime / non-key int), and a leading `t` marked only a **table** (`t<Singular>`).

**After:** The `t` prefix is deliberately double-booked: on a **table** it stays `t<Singular>`; on a **column** it marks a `time`-typed column (`tStartTime`). Context (table name vs. column name) disambiguates. Recorded as a micro-convention in `docs/SQL/NAMING-CONVENTIONS.md §9` and owned in detail by ADR-0001 §D-A2.

**Reasoning:** A `time`-typed schedule column needed a prefix; reusing `t` (mnemonic for `time`) with table/column context as the disambiguator was preferred over inventing a new letter or leaving the column unprefixed and inconsistent. The extension is additive — it does not change any existing column or table name recorded above.
