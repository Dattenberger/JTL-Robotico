# ADR-NNNN: Data-driven reset pipeline (ops.ResetStep registry + whitelisted dispatch)

**Status:** Proposed (plan-scoped — pending promotion)
**Subsystem:** RoboticoOps, Testmandant Reset
**Date:** 2026-07-11
**Supersedes:** —
**Author:** Lukas + Claude Code

> **Cooperates with** the module-signing ADR (`adr-module-signing-reset.md`). That ADR owns
> the reset security model (D5–D8): signed entry SP, sysadmin-owned agent job, queue table,
> mandant config. This ADR adds one thing on top — how the job's internal pipeline is
> *sequenced* — and **narrows** that ADR's D6 "job content only via versioned deployment"
> guarantee in a bounded, documented way. Read `adr-module-signing-reset.md` first for the
> authoritative security model.

## Research

- **User's extensibility wish** (drives this ADR): *"Optimalerweise haben wir quasi eine
  Orchestrator-SP, sodass wir künftig einfach neue Schritte zur Datenbankaufbereitung bzw.
  Testmandantenerstellung hinzufügen können."* — adding a preparation step should not mean
  rewriting the orchestrator core.
- **Extensibility review** `reports/qg2/qg-extensibility.md` (findings EXT-1, EXT-2) and the
  consolidated package `reports/qg2/consolidated-findings.md` §"Slot 1 — EXTENSIBILITY".
- **Baseline that motivated it:** the orchestrator ran a hard-coded 8-step `EXEC` list inside
  one `TRY` block (`reset.ProcessNextResetRequest.sql`, pre-EXT-1 lines 84–93) and additionally
  *routed per-step parameters* (`SELECT @ShopUrl/@ShopLicense/@LoginName/@DisplayName FROM
  ops.Mandant`, pre-EXT-1 lines 63–68). Adding a step meant editing the core in up to three
  places; per-mandant variation was impossible without an `IF @MandantKey` branch in the core.
- **Security model this must preserve:** plan Decision Log **D6** and
  `research/3-module-signing-agent-job/` — "three layers: job content only via versioned
  deployment; start only via the signed SP; the job re-validates the request row."

## Context

The reset pipeline is a linear, totally-ordered sequence of `reset.internal_*` steps run by
the SQL-Agent job (as sysadmin). It grows: new preparation steps (further neutralisation,
data reshaping, per-mandant fixups) are expected over the system's life. With a hard-coded
`EXEC` list, every such addition edits the orchestrator — an Open/Closed violation in exactly
the axis the user named — and the orchestrator's parameter-routing coupled it to each step's
input needs. We want new steps to be additive, without touching the sequencing core, **without**
weakening the D6 security model that lets a non-privileged colleague trigger a sysadmin job.

## Decision

Make the pipeline **data-driven**: the ordered, enabled steps live in a new table
`ops.ResetStep`, and `reset.ProcessNextResetRequest` dispatches them in a **whitelist-guarded
loop** instead of a fixed `EXEC` list. Two supporting changes make this safe and clean:

1. **Uniform step contract (EXT-2).** Every `reset.internal_*` proc has the signature
   `(@TargetDb sysname, @RequestId int, @MandantKey sysname)` and reads any further inputs
   (ShopUrl/ShopLicense, LoginName, DisplayName) from `ops.Mandant` itself. The orchestrator no
   longer routes per-step parameters — its single responsibility is sequencing.

2. **Whitelisted dynamic dispatch.** For each `ops.ResetStep` row the orchestrator checks the
   `ProcName` against the deployed catalog (`sys.procedures`, schema `reset`, name
   `LIKE 'internal[_]%'`) **before** it runs the proc, and the name only ever reaches `EXEC`
   through `QUOTENAME`. An unknown name breaks the run; it can neither inject SQL nor execute an
   arbitrary proc. A `CHECK (ProcName LIKE 'internal[_]%')` on the table mirrors the guard.

`ops.ResetStep` columns: `StepOrder` (execution order), `ProcName` (name only; schema always
`reset`), `IsEnabled` (toggle a step without deleting it), `IsCritical` (1 = failure aborts the
run and quarantines the clone `failed`; 0 = failure logged as WARN, pipeline continues),
`Notes`. The **canonical default order is seeded in git** (`up/0021_reset_step_registry.sql`),
so the out-of-the-box pipeline is versioned, not only a live-table state. Write access is
`ops_admin` only — the same admin-only posture as the other `ops` registry tables.

**Adding a step is now:** deploy a new `reset.internal_Foo.sql` (uniform signature, log via
`reset.internal_LogStep`) + `INSERT` one `ops.ResetStep` row. The orchestrator is not edited.

### The D6 narrowing (the bounded security change)

Before: the *executable set* and its *order* were both fixed in the deployed orchestrator
script. After: the executable set is **still** exactly the `reset.internal_*` procs the
versioned chain deployed (whitelist), but their **order and enablement are admin-only data** in
`ops.ResetStep`. This is a narrowing, not a break, of D6 because: (a) the table cannot introduce
new code — only deployed procs run; (b) its writer (`ops_admin`) is already sysadmin-equivalent
in this threat model and could already `ALTER` the orchestrator; (c) the change is auditable
(the seed is in git; live edits are admin actions). `TRUSTWORTHY` stays OFF; the signed entry SP
and sysadmin job owner (D6) are untouched.

## Alternatives Considered

1. **(a) Keep the hard-coded `EXEC` list, document an "add a step" recipe.** Cheapest and most
   readable — the whole pipeline is one greppable list, zero new trust surface. Rejected as the
   target: it does not deliver the wish (every step still edits the core), keeps the
   parameter-routing coupling, and cannot express enable/disable or per-mandant steps. It remains
   the honest fallback if the registry is ever judged not worth its cost.

2. **(c) Uniform step contract only, keep the explicit `EXEC` list.** Do EXT-2 but not the table:
   adding a step becomes one localized `EXEC` line with no parameter surgery. Gets most of the
   benefit with zero new security surface and a pipeline still readable in one file. Rejected as
   the *target* because it still edits the core per step and gives no enable/disable — but its
   work (EXT-2) is a prerequisite of the chosen option and shipped regardless, so it is a safe
   starting point rather than a discarded path.

3. **Registry with free dynamic `EXEC(@procNameFromTable)` (no whitelist).** The naive version of
   the chosen option. Rejected: it would let table data name *any* proc, eroding D6's "job
   content only via versioned deployment" and opening an injection/arbitrary-execution surface.
   The whitelist is precisely what keeps the chosen option inside D6.

4. **Per-mandant step membership as a runtime `ops.RoleMember`-style table for role membership
   (EXT-4).** Considered for the JTL_Reader/JTL_Writer member list hard-coded in
   `internal_ApplyJtlRoles`. Rejected (decision-only, no code change): a runtime table would give
   editability but split the single source of truth that `Berechtigungen/JTL-Rollen.sql` owns for
   prod. Membership changes rarely; keeping it a code SSoT (edit both mirrors + redeploy) is the
   sustainable choice. `ops.ResetStep` differs — it has no prod SSoT to split.

## Consequences

**Positive:**
- Adding a preparation step no longer edits the orchestrator (Open/Closed; the user's wish).
- The orchestrator has a single responsibility (sequencing); steps own their data dependencies.
- Enable/disable and (via a future `MandantKey` column) per-mandant steps become data, not code.
- StepLog format is centralised in `reset.internal_LogStep` (EXT-3) — one edit, not thirty.
- The default pipeline stays versioned in git; live tuning is possible but not required.

**Negative:**
- The pipeline can no longer be read top-to-bottom in one file — you query `ops.ResetStep` to see
  what runs. *Mitigated* by the git-seeded canonical order and by `GetResetStatus`/`StepLog`
  showing exactly what ran, including a "starting step N" line before each step.
- One more indirection: an unfamiliar reader must learn that step order is data, and that the
  whitelist — not the table — bounds what can execute.

**Failure Modes:**
- **A row naming a non-deployed proc** breaks the run at that step (`THROW 51005`) rather than
  silently skipping — intended, but an admin who disables/reorders carelessly can halt resets.
  The `CHECK` constraint blocks names that do not even match `internal_%`; it does **not** verify
  the proc exists (a valid-looking name for an undeployed proc still fails at run time).
- **The uniform contract is load-bearing.** A new `reset.internal_*` proc that does *not* accept
  exactly `(@TargetDb,@RequestId,@MandantKey)` will fail when the loop calls it. This is a
  convention the lint cannot check — it is documented in `db-migrations/README.md` §"Adding a
  reset step".
- **Cursor hygiene:** the dispatch cursor is `LOCAL` and is explicitly `CLOSE`/`DEALLOCATE`d
  before every `THROW` out of the loop, because the outer request `WHILE (1=1)` re-declares it on
  the next request. A future edit that adds an early exit must preserve that.
- **`IsCritical = 0`** turns a step's failure into a WARN. Marking a genuinely load-bearing step
  non-critical would let a reset report `succeeded` on a half-prepared clone. Default is 1.

## References

- **Related Plan:** [`mssql-ops-infrastruktur`](../mssql-ops-infrastruktur.md) — §3 Reset pipeline; this ADR is authored during the QG2 fix round (Slot 1).
- **Cooperating ADR:** [`adr-module-signing-reset`](adr-module-signing-reset.md) — owns D5–D8; this ADR narrows its D6 clause as described above.
- **Extensibility review:** `../reports/qg2/qg-extensibility.md` (EXT-1/EXT-2/EXT-3/EXT-4/EXT-5); consolidation `../reports/qg2/consolidated-findings.md`.
- **Implementation:** `db-migrations/global/up/0021_reset_step_registry.sql` (table + seed), `db-migrations/global/sprocs/reset.ProcessNextResetRequest.sql` (whitelist loop), `reset.internal_LogStep.sql` (helper), all `reset.internal_*` (uniform contract).
- **Architecture doc:** `docs/SQL/MSSQL-OPS-ARCHITECTURE.md` §1a.3 (data-driven pipeline).
- **Author-facing contract:** `db-migrations/README.md` §"Adding a reset step".
- **Structure test:** `db-migrations/tests/global/validate_structure.sql` (asserts `ops.ResetStep` + `reset.internal_LogStep`).

## Decision History

### 2026-07-11 — Initial proposal

**Trigger:** QG2 extensibility review (EXT-1) against the user's explicit wish to add reset
preparation steps without rewriting the orchestrator; accepted into the fix round as Slot 1.

**Before:** The orchestrator ran a hard-coded 8-step `EXEC` list and routed per-step parameters
from `ops.Mandant`. Adding a step edited the core; per-mandant variation was impossible without
an `IF @MandantKey` branch there.

**After:** Steps are rows in `ops.ResetStep`, dispatched by a whitelist-guarded loop; every
`reset.internal_*` proc takes the uniform `(@TargetDb,@RequestId,@MandantKey)` contract and reads
its own inputs from `ops.Mandant`. The executable set stays exactly the deployed procs; only
order/enablement is admin-only data.

**Reasoning:** It is the only option that delivers the extensibility wish (Open/Closed), and its
extra cost over the "uniform-contract-only" fallback is small and bounded — the whitelist keeps
the D6 "job content only via versioned deployment" guarantee intact, narrowing it (order/
enablement become data) rather than breaking it.
