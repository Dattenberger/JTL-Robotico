# QG2 — Architecture / Extensibility Review

Lens: the reset orchestrator against the explicit user wish — *"Optimalerweise haben wir
quasi eine Orchestrator-SP, sodass wir künftig einfach neue Schritte zur
Datenbankaufbereitung bzw. Testmandantenerstellung hinzufügen können."* Bar:
long-term maintainable / serviceable / extensible, SOLID baseline, **not** over-engineered.

Scope reviewed: `db-migrations/global/sprocs/reset.*`, `db-migrations/global/up/0002_ops_schema_tables.sql`,
`0020_seed_mandant_template.sql`, `permissions/*`, `db-migrations/README.md`,
`docs/SQL/MSSQL-OPS-ARCHITECTURE.md`, plan Decision Log D5–D10.

READ-ONLY analysis. Findings are ordered; EXT-1 is the main deliverable.

---

## 1. What adding a step costs today (baseline)

To add one preparation step (say `internal_ResetSalesData`) a developer must touch:

1. **New file** `db-migrations/global/sprocs/reset.internal_ResetSalesData.sql` — unavoidable, correct.
2. **Edit the orchestrator** `reset.ProcessNextResetRequest.sql`: insert a new `EXEC reset.internal_…`
   line at the right position inside the hardcoded TRY block (lines 84–93). *This is the
   Open/Closed touch* — the sequencing core must be modified to extend the pipeline.
3. **Maybe edit the orchestrator again**: if the step needs a value not already fetched, extend
   both the `DECLARE` block (l. 35–37) and the `SELECT … FROM ops.Mandant` block (l. 63–68).
   The orchestrator is currently also a *parameter router* (it fetches ShopUrl/ShopLicense/
   LoginName/DisplayName and hands them to individual steps), so a new per-step input means
   surgery in three places.
4. **Edit the architecture doc** — `MSSQL-OPS-ARCHITECTURE.md` §1a.3 hardcodes the 8-step ASCII
   pipeline; it silently goes stale on every step addition.

Cheap dimensions (good): **no grant / signing change** is needed — `internal_*` procs are
unsigned and run only inside the sysadmin Agent job via ownership chaining. **No StepLog schema
change** — steps append text to the one `ops.ResetRequest.StepLog` column.

### Verdict on acceptability

The friction is real but *small* today (the EXEC list is 8 readable lines). It is not a
correctness or security defect — nothing is broken. But it violates Open/Closed in exactly the
axis the user named, and it has two sharper edges that will bite as the pipeline grows:

- **Parameter-routing coupling (step 3 above).** The orchestrator knows each step's input needs.
  Every new input is a change to the core, not just to the step. This is the part that actually
  rots.
- **No per-mandant variation.** "tm4 additionally needs step X" is impossible without an
  `IF @MandantKey = …` branch *inside* the core — the real Open/Closed anti-pattern.

So: acceptable as-is for a static 8-step pipeline, but it does not deliver the stated wish and
the parameter-routing coupling should be removed regardless of how far we go on the registry.

---

## EXT-1 — Orchestrator is not Open/Closed: adopt a step registry driving a generic loop  · important · size L

**This is the main deliverable.** Recommendation with the requested a/b/c comparison.

### The three options

**(a) Keep the hardcoded sequence, document an "add a step" recipe.**
Cheapest, most readable (the pipeline is one greppable list), zero new trust surface. But it does
*not* satisfy the wish (every step still edits the core), keeps the parameter-routing coupling,
and cannot express enable/disable or per-mandant steps. Rejected as the target — it is the
"do nothing structural" option.

**(b) `ops.ResetStep` registry table + generic loop.** *Recommended.* A row per step
(order, proc name, enabled, optional per-mandant scope) drives a loop in the orchestrator. New
step = new proc + one seed row; the orchestrator is **never edited again**. Directly fulfils the
wish; naturally forces the uniform step contract (EXT-2) that also removes the parameter-routing
coupling; enables enable/disable and per-mandant steps for free.

**(c) Uniform step contract only, keep the explicit EXEC list (EXT-2 without the table).**
The de-risk middle ground. Each step becomes self-sufficient on `@MandantKey`, so the
orchestrator's TRY block is a clean uniform list of `EXEC reset.internal_X @TargetDb, @RequestId,
@MandantKey` and adding a step is *one localized line* with no param surgery. Gets ~80 % of the
benefit with **zero** new security surface and the pipeline stays readable in one file. Does not
give zero-touch-orchestrator or per-mandant overrides.

### Recommendation: **(b)**, built on the (c) refactor, gated by a documented D6 narrowing.

Why (b) over (a)/(c): it is the only option that literally delivers the user's wish (extend
without rewriting the core), and its extra cost over (c) is small **and** defensible — see the
security analysis below. (c) is the correct fallback if the team judges (b) over-engineered;
crucially, the (c) work (EXT-2) is a prerequisite of (b), so it is committed either way and no
effort is wasted by starting there.

### Schema sketch (new `up/` script, e.g. `0003_reset_step_registry.sql`)

```sql
CREATE TABLE ops.ResetStep
(
    StepId      int IDENTITY(1,1) NOT NULL CONSTRAINT PK_ops_ResetStep PRIMARY KEY,
    StepOrder   int      NOT NULL,
    ProcName    sysname  NOT NULL,          -- name only; schema is always 'reset'
    IsEnabled   bit      NOT NULL CONSTRAINT DF_ResetStep_Enabled  DEFAULT (1),
    IsCritical  bit      NOT NULL CONSTRAINT DF_ResetStep_Critical DEFAULT (1), -- 0 => failure = WARN, pipeline continues
    MandantKey  sysname  NULL,              -- NULL = all mandants; set = per-mandant addition
    Notes       nvarchar(400) NULL,
    -- one ordering per (mandant scope); NULL scope handled with a filtered pair of indexes
    CONSTRAINT UQ_ResetStep_Order_Global UNIQUE (StepOrder, MandantKey)
);
```

Seed the canonical order in the **same versioned script** (so the pipeline definition still lives
in git, not only in a live table):

```sql
INSERT ops.ResetStep (StepOrder, ProcName) VALUES
 (10,N'internal_CloneDatabase'),      (20,N'internal_PostRestoreSecurity'),
 (30,N'internal_InvalidateCredentials'),(40,N'internal_NeutralizeWorker'),
 (50,N'internal_AnonymizeCustomerData'),(60,N'internal_GrantAccess'),
 (70,N'internal_RegisterMandant'),    (80,N'internal_ApplyJtlRoles');
```

### Orchestrator sketch (replaces the fixed EXEC block, l. 84–93; everything else unchanged)

```sql
DECLARE @stepProc sysname, @isCritical bit, @full nvarchar(300);

DECLARE stepcur CURSOR LOCAL FAST_FORWARD FOR
    SELECT ProcName, IsCritical
    FROM ops.ResetStep
    WHERE IsEnabled = 1
      AND (MandantKey IS NULL OR MandantKey = @MandantKey)
    ORDER BY StepOrder;
OPEN stepcur; FETCH NEXT FROM stepcur INTO @stepProc, @isCritical;
WHILE @@FETCH_STATUS = 0
BEGIN
    -- WHITELIST: only a deployed reset.internal_* proc may run. Blocks arbitrary-proc
    -- execution / injection from table data — this is what keeps the D6 guarantee intact.
    IF NOT EXISTS (SELECT 1 FROM sys.procedures p
                   WHERE p.schema_id = SCHEMA_ID(N'reset')
                     AND p.name = @stepProc
                     AND p.name LIKE N'internal[_]%')
        THROW 51005, 'ops.ResetStep names an unknown reset.internal_ procedure.', 1;

    SET @full = N'reset.' + QUOTENAME(@stepProc);
    BEGIN TRY
        EXEC @full @TargetDb = @TargetDb, @RequestId = @RequestId, @MandantKey = @MandantKey;
    END TRY
    BEGIN CATCH
        IF @isCritical = 1 THROW;   -- abort pipeline (current all-or-nothing behaviour)
        EXEC reset.internal_LogStep @RequestId, N'WARN ' + @stepProc + N': ' + ERROR_MESSAGE();
    END CATCH
    FETCH NEXT FROM stepcur INTO @stepProc, @isCritical;
END
CLOSE stepcur; DEALLOCATE stepcur;
```

The outer structure (reclaim-stale, claim-oldest with UPDLOCK/READPAST, re-validation,
CATCH → `failed` + MULTI_USER) is **untouched**. Only the inner fixed list becomes data-driven.
`IsCritical = 0` (optional steps that warn instead of aborting) is a free bonus; drop the column
for a leaner v1 if you prefer strict all-or-nothing.

### Security analysis (the crux — dynamic EXEC vs. D6)

D6's guarantee is *"job content only via versioned deployment; start only via signed SP; job
re-validates the row."* A naive registry that did `EXEC(@anyProcNameFromTable)` would erode the
first clause. This design does **not**, for three reasons:

1. **Whitelist, not free EXEC.** The proc name is validated against the deployed catalog
   (`sys.procedures`, schema `reset`, `internal_` prefix) and only ever placed into an `EXEC`
   via `QUOTENAME`. The table can only *select among already-deployed procs*; it cannot introduce
   new code and cannot inject.
2. **The writer is already sysadmin-equivalent.** `ops.ResetStep` gets no grants (same posture as
   `ops.Mandant` secret columns). Anyone who can write it can already `ALTER` the orchestrator
   proc. So reorder/disable-via-table is **not a new privilege**.
3. **Executable set unchanged.** The *set* of runnable procs is still exactly what the versioned
   chain deployed; only their *order/enablement* becomes admin-only data. That is a narrow,
   defensible relaxation of D6 — but it **is** a change to the security narrative and must be
   written down (see EXT-5: new plan-scoped ADR `adr-reset-step-registry`).

### Trade-off to accept honestly

The pipeline can no longer be read top-to-bottom in one file — you query a table to see what
runs. Mitigations: the canonical order is seeded in a versioned `up/` script (git remains the
source of truth for the default pipeline); `GetResetStatus`/`StepLog` still show exactly what ran.
Net: a small serviceability cost for a real extensibility gain that the user explicitly asked for.

**Depends on EXT-2** (uniform contract) — implement that first.

---

## EXT-2 — Make each step self-sufficient on `@MandantKey`; stop routing params through the core  · important · size M

Today the orchestrator fetches `@ShopUrl/@ShopLicense/@LoginName/@DisplayName` from `ops.Mandant`
and passes them to individual steps (l. 63–68, 87–92). This is what makes step-3 of the baseline
("edit the core to add an input") necessary, and it violates SRP — the orchestrator's single job
should be *sequencing*, not knowing each step's data needs.

**Fix:** give every `internal_*` proc the uniform signature `(@TargetDb sysname, @RequestId int,
@MandantKey sysname)` and have each read its own inputs from `ops.Mandant` (same ownership-chaining
pattern the steps already use to read `ops.Config`). Example:

```sql
-- before: reset.internal_InvalidateCredentials @TargetDb, @RequestId, @ShopUrl, @ShopLicense
-- after:  reset.internal_InvalidateCredentials @TargetDb, @RequestId, @MandantKey
--   body: SELECT @ShopUrl = ShopUrl, @ShopLicense = ShopLicense
--         FROM ops.Mandant WHERE MandantKey = @MandantKey;
```

`GrantAccess` (@LoginName) and `RegisterMandant` (@DisplayName) get the same treatment;
`CloneDatabase / PostRestoreSecurity / NeutralizeWorker / AnonymizeCustomerData / ApplyJtlRoles`
already fit `(@TargetDb, @RequestId)` and just gain the ignored `@MandantKey` for a uniform
contract. The orchestrator then only needs `@MandantKey` + `@TargetDb` (+ `@RequestId`) and its
`SELECT … FROM ops.Mandant` param-fetch block disappears.

This is the linchpin: it improves SRP on its own, it *is* option (c), and it is the precondition
for the EXT-1 generic loop. Ship it even if EXT-1's table is rejected.

Note: `@ShopUrl/@ShopLicense` reads touch the column-protected secret; the internal procs run in
the sysadmin job context, so no extra grant is needed — but confirm no column-DENY is added to the
Agent service account when D8's column protection is implemented.

---

## EXT-3 — Extract the duplicated StepLog + guard boilerplate into shared helpers  · nice · size S

Two blocks are copy-pasted verbatim across all 8 steps:

- **StepLog append** — `UPDATE ops.ResetRequest SET StepLog = ISNULL(StepLog,N'') +
  CONVERT(nvarchar(19),SYSUTCDATETIME(),126) + … + NCHAR(10), ModifiedAt = SYSUTCDATETIME()
  WHERE RequestId = @RequestId;` (8×, plus the same format inside RegisterMandant's per-DB warnings).
- **Test-clone guard** — `IF @TargetDb = N'eazybusiness' OR @TargetDb NOT LIKE N'eazybusiness[_]%'
  THROW 51xxx …;` (8×).

Extract:

```sql
CREATE OR ALTER PROCEDURE reset.internal_LogStep @RequestId int, @Message nvarchar(400) AS
BEGIN
    SET NOCOUNT ON;
    UPDATE ops.ResetRequest
       SET StepLog = ISNULL(StepLog, N'') + CONVERT(nvarchar(19), SYSUTCDATETIME(), 126)
                   + N' ' + @Message + NCHAR(10),
           ModifiedAt = SYSUTCDATETIME()
     WHERE RequestId = @RequestId;
END
```

`internal_LogStep` is a clean win (pure boilerplate, the generic loop's WARN path already assumes
it). It also makes the StepLog format a single point of change — today a format tweak means 8+
edits.

A parallel `internal_AssertTestClone @TargetDb` is *optionally* worth it, but note the trade-off:
the current per-step `THROW 51010/51020/…` codes are a real debugging aid (the number tells you
which step refused). A shared guard loses that unless you pass a `@stepName`/code through. Given
that, recommend `internal_LogStep` firmly and treat `AssertTestClone` as optional — or keep the
guard inline. Small either way.

---

## EXT-4 — Hardcoded JTL role-member list inside `internal_ApplyJtlRoles`  · nice · size S

`internal_ApplyJtlRoles` embeds the 8-principal `JTL_Reader/JTL_Writer` membership as a `VALUES`
literal (l. 49–57). This is the same class of smell as the orchestrator: changing team membership
requires editing and **redeploying a chain proc**. It parallels the user's extensibility wish
(add/remove people without rewriting core logic).

Trade-off — do **not** blindly table-ify: the proc comment deliberately states it "mirrors
`Berechtigungen/JTL-Rollen.sql`, the single source of truth for prod." Moving members into an
`ops.RoleMember` table would give runtime-editable membership but **split that SSoT** across a git
file and a live table. Recommendation: **keep in code for now** (single SSoT wins over
runtime-editability for a rarely-changing list), but if membership churn becomes a pain, introduce
`ops.RoleMember (RoleName, PrincipalName)` and have *both* `JTL-Rollen.sql` and the reset step read
it. Flag, not a mandate — logged because it is the second-most-likely "I have to edit core code to
change config" friction after the orchestrator.

---

## EXT-5 — Documentation/convention coherence under the recommendation  · nice · size S

Under EXT-1/EXT-2 the following must be updated to stay coherent (the review's item 4):

- **New plan-scoped ADR** `adrs/adr-reset-step-registry.md` — records the D6 narrowing (executable
  set = deployed procs; order/enablement is admin-only data), the whitelist mechanism, and the
  a/b/c alternatives. Cross-ref D5/D6 and `adr-module-signing-reset`. **Required** — this is a
  security-model change, not a refactor. Promote to `docs/decisions/NNNN-…` before archival.
- **`docs/SQL/MSSQL-OPS-ARCHITECTURE.md`** — §1a.3 hardcodes the 8-step ASCII pipeline; rewrite it
  to say "steps are rows in `ops.ResetStep` (default order seeded in `up/0003…`)" so it no longer
  goes stale on every step addition. Add an `ops.ResetStep` row to the §3 component table.
- **`db-migrations/README.md`** — add an **"Adding a reset step"** recipe: new
  `reset.internal_*.sql` file, uniform `(@TargetDb, @RequestId, @MandantKey)` signature, use
  `internal_LogStep`, register a seed row. The README is the file-level contract SSoT; this is
  where the "add a step" convention belongs (and it is where a maintainer will look first).
- **`0002_ops_schema_tables.sql` header** — mention the new `ops.ResetStep` alongside the other
  three tables if the table lands in `0002`; otherwise the new `up/0003` script gets its own
  header per README §3.

With these four edits the convention set stays internally consistent and the "add a step" story is
documented in exactly one authoritative place (README) with the decision behind it in the ADR.

---

## Summary

The orchestrator meets a correctness/security bar but not the stated extensibility wish. The
sustainable target is a **step registry (EXT-1)** built on a **uniform, self-sufficient step
contract (EXT-2)**, with the dynamic dispatch hardened by a deployed-proc whitelist so D6 survives.
EXT-2 is committed either way and is the safe place to start; EXT-3/4/5 are the DRY/config/doc
tail. Nothing here rises to *critical* — this is enhancement toward a goal, not defect repair, and
the design is deliberately kept to the whitelist-loop level rather than a general plugin engine.
