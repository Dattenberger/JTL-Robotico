---
date: 2026-07-13
author: Rollout agent (Claude) + Lukas
status: Analysis v2 — inventory + rename proposal (scope = "effectively everything"), NO edits applied
context: Full token inventory of every DB identifier this repo introduced, measured against the RoboticoEKL / excel_ekl naming convention (Lukas' chosen standard), with per-object rename proposals (tables + columns + constraints + ALL stored procedures), reference sites, the whitelist-mechanic knock-on, and an in-place-edit feasibility analysis.
related-plan: ../mssql-ops-infrastruktur.md
related-report: ./test1-rollout-report.md
convention-source: ~/WebStorm/excel_ekl/backend/migrations/jtl/README.md §Namenskonventionen + RoboticoEKL.* object inventory (read-only)
---

# Naming inventory — our DB objects vs. the RoboticoEKL / excel_ekl convention

Pure analysis, **no edits**. v2 widens the scope per Lukas to **"effectively everything"**
(tables, columns, constraints **and** all stored procedures/functions/views), measured
against the **RoboticoEKL** convention as documented and lived in the excel_ekl repo, and
switches identifiers to **English with a Hungarian type prefix** (`nActive`, `dCreated`, …).

## TL;DR

1. **Convention source (Lukas' standard) = RoboticoEKL / excel_ekl.** Derived from
   `excel_ekl/backend/migrations/jtl/README.md §Namenskonventionen` and the live
   `RoboticoEKL.*` object inventory (read-only). Summary in §1.
2. **The SP convention maps 1:1 onto our reset split.** EKL marks **public entry points
   `spPub_<Name>`** and leaves **internal helpers bare `sp<Name>`**. Our
   `reset.StartTestmandantReset` (public) vs `reset.internal_*` (pipeline) is exactly that
   distinction — but our SPs currently carry **no `sp` prefix at all**, so every reset proc
   gets renamed. The `internal_` → **`spInternal_`** rename must be tracked by the
   **whitelist mechanic** (`ProcessNextResetRequest` `LIKE 'internal[_]%'`, the
   `CK_..._ProcName` check, and the `ops.tResetStep` seed) — all Ebene B, all in-place-safe.
3. **Ebene B (`RoboticoOps`) is the whole in-place target** (disposable → edit files +
   teardown/redeploy): schemas, 4 `ops.*` tables + columns + constraints, and **all 17 reset
   procs**.
4. **Ebene A (`eazybusiness`) is already EKL-conformant** — `Robotico.fn*` = `fn<Pascal>`,
   `Robotico.sp*`/`CustomWorkflows.sp*` = `sp<Pascal>`, `Robotico.tPaypal*` = `t<Singular>`
   with Hungarian columns (even `bProduction` matches EKL's `b`-for-bit). → **leave** (and it
   is one-time-journaled on the non-disposable source anyway; §3).
5. **Flag columns are the one open convention conflict.** Lukas said `nActive` (n-prefix);
   the EKL standard itself uses **`b` for bit** (`RoboticoEKL.tMigrationHistory.bSuccess`).
   Flagged as decision Q1 — the mapping below shows `nActive` per Lukas' literal instruction.

---

## 1. The RoboticoEKL / excel_ekl convention (derived, read-only)

From `excel_ekl/backend/migrations/jtl/README.md §Namenskonventionen`:

| Type | Convention | EKL example |
|---|---|---|
| Table | `t<SingularName>` | `tSalesStatsCache` |
| View | `v<PurposeName>` | `vArticleCurrentState` |
| Stored proc — **public entry** | `spPub_<Action>` | `spPub_SetArticlePhase`, `spPub_SyncArticleLabels` |
| Stored proc — **internal/helper** | `sp<Action>` (bare) | `spCreateLabelSnapshot`, `spApplyArticlePhaseEffects` |
| Function | `fn<Name>` | `fnComputeArticlePhasePreview`, `fnParseLabelsSnapshot` |
| Index | `IX_<tTable>_<Purpose>` | `IX_tMigrationHistory_Applied` |
| Unique constraint | `UQ_<tTable>_<Columns>` | `UQ_tMigrationHistory_Version` |
| Foreign key | `FK_<tTable>_<RefTable>` | `FK_tArtikelCommentary_Predecessor` |
| Check constraint | `CK_<tTable>_<Column>` | `CK_tArtikelCommentary_Context` |

**Columns** (from `RoboticoEKL.tMigrationHistory`): English PascalCase with a Hungarian type
prefix — `kMigration` (PK int), `nVersion` (int), `cFileName`/`cChecksum`/`cAppliedBy`/
`cErrorMessage` (string), `dApplied` (datetime2), `nDurationMs` (int), **`bSuccess` (bit)**.

> **Two deltas from JTL-vendor Hungarian** (the secondary cross-check): EKL constraint names
> **omit the schema segment** (`UQ_tMigrationHistory_Version`, not `UQ_dbo_t…`), and EKL uses
> **English** identifiers (`dApplied`, not `dErstellt`). Both match Lukas' instructions.

**Public/internal SP split** — the live `RoboticoEKL` inventory confirms it:
`spPub_SetArticlePhase / spPub_UpdateEbayItemPrice / spPub_SyncArticleLabels / …` (public API)
vs. `spCreateLabelSnapshot / spApplyArticlePhaseEffects / spSyncSalesStatsCache / …` (internal).

---

## 2. Inventory + rename proposals

Legend — **In-place?** ✅ = Ebene B, disposable, safe to edit the SQL file + teardown/redeploy;
⛔ = do not edit in place (Ebene A: one-time-journaled on the non-disposable source and/or
external consumers) — see §3.

### 2.A Schemas

| Current | Proposal | In-place? | Notes |
|---|---|---|---|
| `ops`, `reset` | keep | — | EKL uses one schema (`RoboticoEKL`); our `ops`/`reset` split is intentional (data vs procs). Schema *names* are the grate journal schema (`--schema=ops`) — leave. |
| `Robotico`, `CustomWorkflows` | keep | ⛔ | Journal schema / vendor-shared; external + hash-bound. |

### 2.B Ebene B — `ops.*` tables + columns (all ✅)

**`ops.Mandant` → `ops.tMandant`**

| Current column | Proposal | | Current column | Proposal |
|---|---|---|---|---|
| `MandantKey` (PK) | `cMandantKey` | | `ShopUrl` | `cShopUrl` |
| `TargetDb` | `cTargetDb` | | `ShopLicense` | `cShopLicense` |
| `DisplayName` | `cDisplayName` | | `IsActive` (bit) | **`nActive`** (see Q1) |
| `Developer` | `cDeveloper` | | `CreatedAt` | `dCreated` |
| `LoginName` | `cLoginName` | | `ModifiedAt` | `dModified` |

**`ops.Config` → `ops.tConfig`**: `ConfigKey`→`cKey`, `ConfigValue`→`cValue`, `Notes`→`cNotes`.

**`ops.ResetRequest` → `ops.tResetRequest`**: `RequestId`(PK)→`kResetRequest`,
`MandantKey`→`cMandantKey`, `TargetDb`→`cTargetDb`, `Status`→`cStatus`,
`RequestedBy`→`cRequestedBy`, `RequestedAt`→`dRequested`, `StartedAt`→`dStarted`,
`FinishedAt`→`dFinished`, `ErrorText`→`cErrorMessage` (EKL idiom), `StepLog`→`cStepLog`,
`ModifiedAt`→`dModified`.

**`ops.ResetStep` → `ops.tResetStep`**: `StepId`(PK)→`kResetStep`, `StepOrder`→`nStepOrder`,
`ProcName`→`cProcName`, `IsEnabled`→`nEnabled` (Q1), `IsCritical`→`nCritical` (Q1),
`Notes`→`cNotes`.

**Constraints/indexes → EKL style `<Type>_<tTable>_<column>` (drop the `ops_` schema segment):**
`PK_ops_Mandant`→`PK_tMandant`; `CK_ops_Mandant_MandantKey`→`CK_tMandant_cMandantKey`;
`UQ_ops_Mandant_TargetDb`→`UQ_tMandant_cTargetDb`; `DF_ops_Mandant_IsActive`→`DF_tMandant_nActive`;
`PK_ops_Config`→`PK_tConfig`; `PK_ops_ResetRequest`→`PK_tResetRequest`;
`FK_ops_ResetRequest_Mandant`→`FK_tResetRequest_tMandant`;
`CK_ops_ResetRequest_Status`→`CK_tResetRequest_cStatus`;
`UX_ResetRequest_Active`→`IX_tResetRequest_Active` (also gains the missing prefix consistency);
`PK_ops_ResetStep`→`PK_tResetStep`; `UQ_ops_ResetStep_ProcName`→`UQ_tResetStep_cProcName`;
`UQ_ops_ResetStep_StepOrder`→`UQ_tResetStep_nStepOrder`;
`CK_ops_ResetStep_ProcName`→`CK_tResetStep_cProcName` (**and its LIKE pattern changes — §2.D**).

### 2.C Ebene B — reset stored procedures (all ✅, the widened scope)

EKL: public entry points `spPub_<Name>`, internal helpers bare `sp<Name>`. Our procs carry
**no `sp` prefix today**, so all 17 get renamed. The 8 pipeline steps keep a distinct
**`spInternal_`** marker so the dispatch whitelist stays a simple prefix match (§2.D).

| Current | Proposal | Tier |
|---|---|---|
| `reset.StartTestmandantReset` | `reset.spPub_StartTestmandantReset` | public |
| `reset.GetResetStatus` | `reset.spPub_GetResetStatus` | public |
| `reset.ListMandants` | `reset.spPub_ListMandants` | public |
| `reset.CancelResetRequest` | `reset.spPub_CancelResetRequest` | public |
| `reset.CreateTestmandant` | `reset.spPub_CreateTestmandant` | public |
| `reset.PurgeOldRequests` | `reset.spPub_PurgeOldRequests` | public |
| `reset.ProcessNextResetRequest` | `reset.spProcessNextResetRequest` | internal engine (bare `sp`; not whitelisted) |
| `reset.EnsureAgentJob` | `reset.spEnsureAgentJob` | internal maintenance (bare `sp`) |
| `reset.internal_LogStep` | `reset.spInternal_LogStep` | internal helper (called directly, not a registry step) |
| `reset.internal_CloneDatabase` | `reset.spInternal_CloneDatabase` | **pipeline step** (whitelisted) |
| `reset.internal_PostRestoreSecurity` | `reset.spInternal_PostRestoreSecurity` | pipeline step |
| `reset.internal_InvalidateCredentials` | `reset.spInternal_InvalidateCredentials` | pipeline step |
| `reset.internal_NeutralizeWorker` | `reset.spInternal_NeutralizeWorker` | pipeline step |
| `reset.internal_AnonymizeCustomerData` | `reset.spInternal_AnonymizeCustomerData` | pipeline step |
| `reset.internal_GrantAccess` | `reset.spInternal_GrantAccess` | pipeline step |
| `reset.internal_RegisterMandant` | `reset.spInternal_RegisterMandant` | pipeline step |
| `reset.internal_ApplyJtlRoles` | `reset.spInternal_ApplyJtlRoles` | pipeline step |

Roles `ops_admin` / `ops_reset_executor`: EKL has **no role convention** → **leave** (Q4).

### 2.D The whitelist knock-on (must move with the SP rename — load-bearing)

The pipeline is dispatch-guarded: only procs matching a name pattern may be EXEC'd. Renaming
`internal_*` → `spInternal_*` requires **three coordinated edits** (all Ebene B, in-place):

1. `reset.ProcessNextResetRequest` — the whitelist check `AND p.name LIKE N'internal[_]%'`
   → `LIKE N'spInternal[_]%'` (line ~116).
2. `up/0021_reset_step_registry.sql` — the CHECK `CK_ops_ResetStep_ProcName CHECK (ProcName
   LIKE N'internal[_]%')` → `CK_tResetStep_cProcName CHECK (cProcName LIKE N'spInternal[_]%')`,
   **and** the 8 seeded `cProcName` values (`internal_CloneDatabase` → `spInternal_CloneDatabase`, …).
3. Every `EXEC reset.internal_LogStep` / `EXEC reset.internal_<Step>` call site inside the
   step procs and the orchestrator → the new names.

Because `up/0021` is Ebene B (disposable), editing it in place is fine — teardown drops the
table, redeploy recreates it with the new CHECK + seed. (On a *non*-disposable chain this
would need a new `up/` migration; not our case.)

### 2.E Ebene A — already EKL-conformant → leave (⛔)

| Object group | EKL check | Verdict |
|---|---|---|
| `Robotico.fn*` (12) | `fn<Pascal>` ✓ (`fnComputeArticlePhasePreview` ↔ `fnFindDuplicateOrders`) | conformant — leave |
| `Robotico.sp*` (6), `CustomWorkflows.sp*` (7) | `sp<Pascal>` ✓ | conformant prefix — leave. (A `spPub_` refinement on the workflow-facing ones is *possible* but NOT worth it: external consumers + hash, §3.) |
| `Robotico.tPaypal*` (3) | `t<Singular>` ✓, Hungarian columns incl. `bProduction` (b-for-bit matches EKL) | conformant — leave |

Two cosmetic Ebene-A blemishes remain (not part of this wave): the column typo
`cBescheibung1/2` (→ `cBeschreibung`) and `cAppID` casing, both in the one-time `up/0002`.
A fix needs a **new** `up/` `sp_rename` migration (§3), never an in-place edit.

### 2.F grate journal + `ops.Config` keys

`*.ScriptsRun`/`ScriptsRunErrors`/`Version` — tool-owned (schema segment only is ours) →
leave. `ops.Config` keys (`BackupFile`, `TargetDataDir`, …) are row **data**, not identifiers
→ leave.

---

## 3. In-place feasibility & impact

### Ebene B (`RoboticoOps`) — SAFE, in-place + teardown/redeploy

Files to edit (all Ebene B): `global/up/0002_ops_schema_tables.sql` (tables/columns/constraints),
`up/0021` (ResetStep table + CHECK + seed), **every `global/sprocs/reset.*.sql`** (17 procs — the
`CREATE` names, the internal `EXEC` call sites, the `ops.*` column references), `global/permissions/100_grants.sql`
(grants on the renamed public procs), `runAfterOtherAnyTimeScripts/reset.EnsureAgentJob.sql`,
`tests/global/validate_structure.sql` **and** `validate_rollout.sql` (asserted object/column names),
`mandant.ps1` + `tests/validate-rollout.ps1` (they call `reset.CreateTestmandant`/`ListMandants`/…),
and the live docs (`db-migrations/README.md` ops.Config table + §9 pipeline, `docs/runbooks/*`,
`docs/SQL/MSSQL-OPS-ARCHITECTURE.md`, `docs/SQL/NAMING-CONVENTIONS.md`, the plan). Then:
`test1` teardown (plan §d) → `db:deploy:test:global` → `db:validate:test`; E2E container `down`+`up`.

Archival `reports/`/`research/` files are point-in-time — **not** rewritten.

### Ebene A (`eazybusiness`) — do NOT touch (the trap, avoided by scope)

`up/0001`/`0002` are one-time, already **hash-journaled on the non-disposable `eazybusiness`**
(test1 now, prod later, and clones inherit it). Any in-place change trips a grate hash mismatch.
Ebene A is EKL-conformant already (2.E), so **nothing to rename** — the trap is avoided by scope.
The cosmetic typo, if ever wanted, is a **standalone new `up/` migration** (`sp_rename`) + the two
Ebene-A procs that read the column — a separate, conscious decision.

### External consumers (why Ebene-A procs stay even though rename is "possible")

`Robotico.fnEscapedCSVParseLine` is a documented backward-compat contract for excel_ekl
(README §5); a **DotLiquid workflow property** calls `Robotico.fnHasOlderDuplicateOrder`
(via `Robotico.spCheckDuplicateOrder`). Renaming would orphan the old object on the real DB
and break external callers. The reset (Ebene B) procs have **no external consumers** — only
`mandant.ps1`/validate scripts, which we control and rename in lockstep.

---

## 4. Decision questions for Lukas

1. **Flag columns (bit): `nActive`/`nEnabled`/`nCritical` (your instruction) or `bActive`/…
   (EKL's own `bSuccess` uses `b` for bit)?** The mapping above uses `nActive` per your literal
   instruction; the EKL standard you pointed to actually uses `b`. Pick one — I'll apply it
   consistently. *(Recommendation: `bActive` to match the RoboticoEKL standard exactly; but
   your call.)*
2. **SP internal marker: `spInternal_<Name>` (explicit) or `spInt_<Name>` (symmetric with
   EKL's abbreviated `spPub_`)?** Both preserve the whitelist-prefix mechanic. *(Recommendation:
   `spInternal_` — self-documenting.)*
3. **Widen the SP rename to Ebene A too?** Recommendation: **no** — Ebene A is already
   `sp<Pascal>`/`fn<Pascal>` conformant and externally/hash-bound. Leave.
4. **Roles + schema names (`ops`/`reset`):** leave (no EKL convention for either)? Recommendation: yes.
5. **`cErrorMessage` vs `cErrorText`, `nStepOrder` vs `nSort`, `cNotes` vs `cBemerkung`** — minor
   wording. Recommendation: `cErrorMessage` (EKL), `nStepOrder`, `cNotes`.
6. **Ebene-A cosmetic typo (`cBescheibung`) — new `up/` migration now, or defer?** Recommendation: defer.

**On approval** I execute the Ebene-B rename as one change set: SQL files + the whitelist trio
(§2.D) + validate SQLs + ps1 + live docs, then teardown/redeploy test1 `RoboticoOps` and re-run
`db:validate:test` green on the new names. Ebene A untouched.
