---
date: 2026-07-13
author: Rollout agent (Claude) + Lukas
status: Analysis — inventory + rename proposal, NO edits applied
context: Full token inventory of every DB identifier this repo introduced, measured against the JTL-Wawi Hungarian naming convention, with per-object rename proposals, reference sites, and an in-place-edit feasibility/impact analysis (esp. the already-journaled Ebene-A chain).
related-plan: ../mssql-ops-infrastruktur.md
related-runbooks: ../../../runbooks/rollout-mssql-ops.md
---

# Naming inventory — our DB objects vs. the JTL Hungarian convention

Pure analysis, **no edits**. Goal: give Lukas a decision-ready map of every identifier
**we** introduced, what a JTL-conformant name would be, where each is referenced, and —
the load-bearing part — **whether it can be renamed in place** or needs a different
strategy because the object is already deployed with a tracked hash on a non-disposable
database.

## TL;DR (read this first)

1. **The whole normalization effort is cleanly scoped to Ebene B (`RoboticoOps`).** That
   database is **disposable** (teardown + redeploy), so its objects can be renamed
   **in-place in the SQL files** and rebuilt. This is where the non-conformant names live:
   the schemas `ops`/`reset`, the four `ops.*` tables, their columns, and the
   `PK_/CK_/DF_/UQ_/FK_/UX_` constraints.
2. **Ebene A (`eazybusiness`) needs essentially no renaming** — the `Robotico.tPaypal*`
   tables are **already** JTL-conformant (`t`-prefix, Hungarian columns), because they were
   ported from prod objects that already followed the convention. The `Robotico.fn*` /
   `sp*` / `CustomWorkflows.sp*` names have **no JTL vendor pattern to conform to** (JTL
   ships no UDFs/SPs in `A_Context`) and are **externally load-bearing** (excel_ekl + a
   DotLiquid workflow property depend on exact names). → leave as-is.
3. **Ebene A is the trap, and it is already de-fused:** its `up/` scripts are one-time,
   **already journaled with a content hash on the non-disposable `eazybusiness`** (test1
   now, prod later). Even a cosmetic in-place change there (e.g. the `cBescheibung` typo)
   would trip a grate hash-mismatch — so **any** Ebene-A change must go through a **new**
   `up/` migration (`sp_rename`), never an in-place edit. But since Ebene A needs no
   renames, this trap is avoided entirely.
4. **grate journal tables** (`*.ScriptsRun` / `ScriptsRunErrors` / `Version`) are
   **tool-owned**. Only the *schema* segment (`Robotico` / `ops`) is ours; the table names
   are grate defaults. Leave them.

**Net:** a clean, low-risk rename wave on Ebene B only; Ebene A and the journal stay put.

---

## 1. The JTL convention (derived empirically)

Derived from `A_Context/JTL 1.10.11.0/` (the vendor schema) and cross-checked against the
`knowledge-jtl-sql` skill.

### Object-name prefixes

| Object | Prefix | JTL examples (from `A_Context`) |
|---|---|---|
| Table | `t` | `tArtikel`, `tLieferant`, `Amazon.tFbaInbound` |
| View | `v` (list views `lv`) | `Abgleich.vZulaufLagerartikel`, `Amazon.lvAmazonAbgleichBestellungen` |
| Function | *(no vendor precedent)* | **JTL ships no UDFs in `A_Context`** — no pattern to mirror |
| Stored proc | *(no vendor precedent)* | **JTL ships no SPs in `A_Context`** — no pattern to mirror |

### Column-type prefixes (frequency in `dbo.tArtikel`)

| Prefix | Meaning | Count | Example |
|---|---|---|---|
| `c` | char / string | 59 | `cArtNr`, `cName` |
| `n` | numeric / int | 44 | `nAktiv`, `nIstVater` |
| `f` | float / money | 32 | `fVKNetto`, `fEKNetto` |
| `k` | key (PK / FK, int) | 26 | `kArtikel`, `kSprache` |
| `d` | datetime | 6 | `dErstellt`, `dGeaendert` |
| `b` | bit | 1 | (rare — JTL usually models flags as `n…`) |
| `u` | uniqueidentifier | — | `uObserverId`, `uArtikelTyp` (from constraint names) |

FK columns often carry the referenced-table pattern `<tTable>_<kColumn>`
(e.g. `tLieferant_kLieferant`). Active flags are inconsistent in JTL itself: `nAktiv`
(int) on `tArtikel`, `cAktiv='Y'` on `tLieferant`/`tKunde` — **`nAktiv` is the dominant
idiom** even for boolean-ish flags.

### Constraint / index names

JTL uses **`<Type>_<schema>_<tTable>_<column>`**:
- `CK_dbo_tArtikel_cInet`, `CK_Amazon_tSettlementPosKostentypen_nKostentyp`
- i.e. the schema **and** the `t`-prefixed table name are both in the constraint name.

Our constraints already use `PK_/CK_/DF_/UQ_ + schema + table`, but the table segment
**lacks the `t` prefix** (`CK_ops_Mandant_MandantKey` vs. JTL's `CK_ops_tMandant_cMandantKey`).

> Sources for grate journal configurability: grate is a RoundhousE fork; the **schema** is
> configurable (`--schema`), the journal **table names** are grate defaults.
> [grate ConfigurationOptions](https://github.com/grate-devs/grate/blob/main/docs/ConfigurationOptions/index.md),
> [MigratingFromRoundhousE](https://github.com/grate-devs/grate/blob/main/docs/MigratingFromRoundhousE.md).

---

## 2. Inventory + rename proposals

Legend for **In-place?**: ✅ = safe in-place SQL edit (Ebene B, disposable → teardown+redeploy);
⛔ = must NOT be edited in place (one-time script already journaled on a non-disposable DB, or
external consumer) — see §3.

### 2.A Schemas

| Current | JTL-conformant proposal | In-place? | Notes / reference sites |
|---|---|---|---|
| `ops` | `Ops` (casing only) — **low value** | ⚠️ optional | Journal schema of Ebene B (`ops.ScriptsRun`); casing is cosmetic under `CI_AS`. Renaming churns every `ops.*` reference (~40 files) + the `--schema=ops` in `deploy.ps1`. **Recommend: leave.** |
| `reset` | `Reset` (casing only) — **low value** | ⚠️ optional | Proc schema. Same churn argument. **Recommend: leave.** |
| `Robotico` | keep | ⛔ | Ebene-A journal schema (`--schema=Robotico`), **travels with mandant clones**, and excel_ekl reads `Robotico.*`. Renaming = journal break + external break. **Keep.** |
| `CustomWorkflows` | keep (vendor-shared) | ⛔ | Co-inhabited with excel_ekl + the JTL Custom Workflow Actions module. Not ours to rename (README §5). |

### 2.B Ebene B — `ops.*` tables (the main rename target — all ✅ in-place)

Disposable `RoboticoOps` → rename in the SQL files, then teardown + redeploy (§3).

**`ops.Mandant` → `ops.tMandant`**

| Column (current) | Proposal | Rationale |
|---|---|---|
| `MandantKey` (PK, sysname) | `cMandantKey` | string business key |
| `TargetDb` | `cTargetDb` | string |
| `DisplayName` | `cDisplayName` (or `cName`) | JTL idiom `cName` |
| `Developer` | `cDeveloper` | string |
| `LoginName` | `cLoginName` | string |
| `ShopUrl` | `cShopUrl` | string |
| `ShopLicense` | `cShopLicense` | string |
| `IsActive` (bit) | `nAktiv` | JTL active-flag idiom |
| `CreatedAt` (datetime2) | `dErstellt` | JTL datetime idiom |
| `ModifiedAt` | `dGeaendert` | JTL datetime idiom |

Constraints: `PK_ops_Mandant`→`PK_ops_tMandant`, `CK_ops_Mandant_MandantKey`→`CK_ops_tMandant_cMandantKey`,
`CK_ops_Mandant_TargetDb`→`CK_ops_tMandant_cTargetDb`, `UQ_ops_Mandant_TargetDb`→`UQ_ops_tMandant_cTargetDb`,
`DF_ops_Mandant_IsActive`→`DF_ops_tMandant_nAktiv`, `DF_ops_Mandant_CreatedAt`→`DF_ops_tMandant_dErstellt`,
`DF_ops_Mandant_ModifiedAt`→`DF_ops_tMandant_dGeaendert`.

**`ops.Config` → `ops.tConfig`** (JTL idiom would be `tEinstellung`)

| Column | Proposal | Rationale |
|---|---|---|
| `ConfigKey` (PK) | `cKey` | matches `Robotico.tPaypalSettings.cKey` (internal consistency) |
| `ConfigValue` | `cValue` (JTL-pure `cWert`) | matches `tPaypalSettings.cValue` |
| `Notes` | `cBemerkung` | JTL idiom |

Constraint `PK_ops_Config`→`PK_ops_tConfig`.

**`ops.ResetRequest` → `ops.tResetRequest`**

| Column | Proposal | Rationale |
|---|---|---|
| `RequestId` (PK, int identity) | `kResetRequest` | JTL surrogate-key idiom `k<Table>` |
| `MandantKey` (FK) | `cMandantKey` | FK to `ops.tMandant.cMandantKey` |
| `TargetDb` | `cTargetDb` | string |
| `Status` | `cStatus` | string |
| `RequestedBy` | `cRequestedBy` | string |
| `RequestedAt` | `dRequested` (or `dErstellt`) | datetime |
| `StartedAt` | `dStarted` | datetime |
| `FinishedAt` | `dFinished` | datetime |
| `ErrorText` | `cErrorText` | string |
| `StepLog` | `cStepLog` | string |
| `ModifiedAt` | `dGeaendert` | datetime |

Constraints: `PK_ops_ResetRequest`→`PK_ops_tResetRequest`, `FK_ops_ResetRequest_Mandant`→`FK_ops_tResetRequest_tMandant`,
`CK_ops_ResetRequest_Status`→`CK_ops_tResetRequest_cStatus`, `DF_*` → `DF_ops_tResetRequest_<newcol>`,
index `UX_ResetRequest_Active`→`UX_ops_tResetRequest_Active` (note: current name even omits the schema — fix that too).

**`ops.ResetStep` → `ops.tResetStep`**

| Column | Proposal | Rationale |
|---|---|---|
| `StepId` (PK, int identity) | `kResetStep` | JTL surrogate |
| `StepOrder` | `nSort` (JTL idiom) or `nStepOrder` | int ordering |
| `ProcName` | `cProcName` | string |
| `IsEnabled` (bit) | `nAktiv` | active-flag idiom |
| `IsCritical` (bit) | `nKritisch` | flag |
| `Notes` | `cBemerkung` | JTL idiom |

Constraints: `PK_ops_ResetStep`→`PK_ops_tResetStep`, `UQ_ops_ResetStep_ProcName`→`UQ_ops_tResetStep_cProcName`,
`UQ_ops_ResetStep_StepOrder`→`UQ_ops_tResetStep_nSort`, `CK_ops_ResetStep_ProcName`→`CK_ops_tResetStep_cProcName`,
`DF_*` → renamed accordingly.

**Reference sites for the `ops.*` group** (rename touches all *live* ones; archival report/research
files under `docs/plans/.../reports|research/` are point-in-time records — **do not** rewrite them):
- **Live code (must update):** all `db-migrations/global/sprocs/reset.*.sql` (they read/write every
  `ops.*` table + column), `db-migrations/global/up/0002/0020/0021`, `db-migrations/global/permissions/100_grants.sql`,
  `db-migrations/tests/global/validate_structure.sql` **and** `validate_rollout.sql`,
  `db-migrations/mandant.ps1`, `db-migrations/tests/validate-rollout.ps1`.
- **Live docs (update):** `db-migrations/README.md` (ops.Config knobs table), `docs/runbooks/*.md`,
  `docs/SQL/MSSQL-OPS-ARCHITECTURE.md`, `docs/SQL/NAMING-CONVENTIONS.md`, the plan `mssql-ops-infrastruktur.md`.
- **Archival (leave):** everything under `reports/` and `research/` (incl. this file's siblings).

Rough magnitude (grep of identifier → files): `TargetDb` 49, `MandantKey` 44, `ops.Mandant` 39,
`StepLog` 35, `ShopLicense` 34, `ops.ResetRequest` 33, `ops.Config` 30 — but **the majority are archival**;
the live surface is ~15–20 files.

### 2.C Ebene B — `reset` procs + roles

| Object | Proposal | In-place? | Notes |
|---|---|---|---|
| `reset.StartTestmandantReset`, `GetResetStatus`, `ListMandants`, `CancelResetRequest`, `CreateTestmandant`, `PurgeOldRequests`, `ProcessNextResetRequest`, `internal_*` (8 steps + `internal_LogStep`) | **keep** | ✅ if ever | No JTL vendor SP convention exists. These are anytime (`CREATE OR ALTER`); the `internal_` prefix is a deliberate pipeline/ whitelist convention (`ops.tResetStep.cProcName LIKE 'internal_%'`). Renaming would ripple into the registry seed + orchestrator whitelist for zero conformance gain. **Recommend: leave.** |
| Roles `ops_admin`, `ops_reset_executor` | keep | ✅ if ever | JTL has no role-naming convention. **Leave.** |

### 2.D Ebene A — `eazybusiness` objects (already conformant / externally bound)

| Object | Status | In-place? | Notes |
|---|---|---|---|
| `Robotico.tPaypalAccessToken` / `tPaypalTrackingLog` / `tPaypalSettings` | **already conformant** (`t`-prefix, columns `kKey`/`cScope`/`nExpiresInSeconds`/`dTokenCreated`/`bProduction`/…) | ⛔ | Nothing to rename. **Two cosmetic blemishes** noted, NOT worth changing: column typo `cBescheibung1/2` (should be `cBeschreibung`) in `tPaypalTrackingLog`, and `cAppID` casing. Both live in the **one-time** `up/0002`, already journaled on the non-disposable `eazybusiness` → a fix needs a **new** `up/` `sp_rename` migration, never an in-place edit (§3). |
| `Robotico.fn*` (12), `Robotico.sp*` (6), `CustomWorkflows.sp*` (7) | keep | ⛔ | (a) No JTL vendor fn/sp pattern to conform to; (b) already `fn`/`sp` Hungarian-prefixed; (c) **externally load-bearing**: excel_ekl reads `Robotico.fnEscapedCSVParseLine` (backward-compat contract, README §5), and a **DotLiquid workflow property** calls `Robotico.fnHasOlderDuplicateOrder` (via `Robotico.spCheckDuplicateOrder`; referenced in `db-migrations/README.md` + `WorkflowProcedures/Duplikaterkennung_Bestellungen.sql`). Renaming would orphan the old object on the real DB **and** break external callers. **Leave.** |

### 2.E `ops.Config` keys (data, not schema — listed for completeness)

`BackupFile`, `TargetDataDir`, `SourceDb`, `ReferenceMandant`, `StaleRunningHours`,
`AgentJobName`, `NotifyOperator`. These are **row values**, not identifiers — no Hungarian
convention applies. Changing them is a normal `UPDATE`, not a schema rename. **Leave.**

### 2.F grate journal tables (tool-owned)

| Object | Ours? | Action |
|---|---|---|
| `Robotico.ScriptsRun` / `ScriptsRunErrors` / `Version` (Ebene A) | schema only | Leave — table names are grate defaults; renaming diverges from the tool + forces re-baselining. |
| `ops.ScriptsRun` / `ScriptsRunErrors` / `Version` (Ebene B) | schema only | Leave — same. |

---

## 3. Impact of an in-place edit (the critical part)

### Ebene B (`RoboticoOps`) — SAFE, in-place

`RoboticoOps` is **disposable**. Procedure for the rename wave:
1. Edit the SQL files in place: `global/up/0002_ops_schema_tables.sql` (table + column + constraint names),
   `0020`/`0021` (seeds referencing columns), every `global/sprocs/reset.*.sql`, `permissions/100_grants.sql`,
   both validate SQLs, `mandant.ps1`, `validate-rollout.ps1`, and the live docs.
2. **Teardown test1 `RoboticoOps`** via the rollback SQL from the test1 plan §d
   (`DROP DATABASE RoboticoOps` + `DROP LOGIN RoboticoOpsSigningLogin` + `DROP CERTIFICATE RoboticoOpsSigning`
   in master + `sp_delete_job` + `DROP LOGIN jobstartuser`).
3. **Teardown the E2E container:** `npm run db:e2e:down` then `db:e2e:up` (fresh, picks up renamed files).
4. Redeploy: `npm run db:deploy:test:global` → fresh `RoboticoOps` with conformant names; re-run
   `npm run db:validate:test` (I will update both validate SQLs to assert the new names).

Because `up/0002` etc. are re-created from scratch on the fresh DB, the **new content hash is journaled
cleanly** — no mismatch, because there is no prior journal (the DB was dropped).

### Ebene A (`eazybusiness`) — the trap (why we DON'T touch it)

This is the point to be careful about:

- Ebene-A `up/` scripts (`0001_robotico_schema`, `0002_robotico_paypal_tables`) are **one-time** and
  grate tracks them **by content hash**. They are **already journaled** on:
  - **test1 `eazybusiness`** — a **real, non-disposable** database (it is the JTL working DB with a live
    worker), just adopted into the journal by the b.2 normal deploy;
  - **prod `eazybusiness`** — will be journaled at prod rollout; also non-disposable and the clone source.
- Editing an applied one-time script (even a comment or a column typo) changes its hash → grate fails the
  next Ebene-A deploy with a **hash mismatch**, and a mandant clone would silently disagree with the source.
- Therefore **any** Ebene-A change must be a **NEW** `up/NNNN_…` migration performing `sp_rename` /
  `ALTER`, **never** an in-place edit of `0001`/`0002`.

**But Ebene A needs no renames** (2.D): the tables are already conformant, and the functions/procs are
externally bound. So we simply **do not touch Ebene A** — the trap is avoided by scope, not by cleverness.
If Lukas later wants the cosmetic `cBescheibung`→`cBeschreibung` typo fixed, that is a **standalone new
`up/` migration** (`sp_rename` column) + updating the two Ebene-A procs that read it — a separate,
conscious decision, not part of this rename wave.

### Roles/logins/cert/agent-job (instance-global)

The Ebene-B teardown re-touches instance-global objects (server login `jobstartuser`,
`RoboticoOpsSigningLogin` + cert in `master`, the sysadmin agent job). The rollback SQL in the test1 plan
§d covers all of them; the redeploy recreates them. The **cert password is immutable** — after teardown,
the fresh deploy auto-generates a NEW one (cert absent again) and persists it; update `~/.claude-secrets.md`
accordingly. (No name change to the cert/login/job themselves is proposed — they are English proper nouns,
not Hungarian-scoped.)

---

## 4. Top decision questions for Lukas

1. **Confirm the scope: Ebene B only?** Recommendation: yes — rename the `ops.*` schema/tables/columns/
   constraints in place + teardown/redeploy; leave Ebene A, the reset procs, roles, and the grate journal
   untouched. (This is the low-risk 90% of the value.)
2. **Table naming: English `ops.tConfig`/`tResetRequest`/`tResetStep`/`tMandant`, or JTL-German
   (`tEinstellung`, `tResetAnfrage`, …)?** Recommendation: keep the English domain terms (the whole reset
   subsystem is English) but add the `t`-prefix + Hungarian columns.
3. **Active-flag type: `nAktiv` (JTL idiom, int) or `bAktiv` (type-accurate bit)?** JTL overwhelmingly uses
   `nAktiv`. Recommendation: `nAktiv`, keep the column `bit` (or widen to `int` for exact idiom — cosmetic).
4. **Column value naming consistency: `cValue`/`cKey` (match our own `tPaypalSettings`) or JTL-pure
   `cWert`/`cKey`?** Recommendation: `cKey`/`cValue` for internal consistency with the already-shipped
   PayPal settings table.
5. **The two Ebene-A cosmetic blemishes (`cBescheibung` typo, `cAppID` casing): fix now via a new `up/`
   migration, or leave?** Recommendation: leave for now (out of scope; needs a separate `sp_rename`
   migration + proc updates, and touches the non-disposable chain).
6. **Reset procs / roles / schema-casing (`ops`→`Ops`): rename too?** Recommendation: no — churn without
   conformance benefit (no JTL vendor pattern for procs/roles; schema casing is cosmetic under `CI_AS`).

**Next step after Lukas' review:** if approved, I execute the Ebene-B in-place renames + teardown/redeploy
+ validate-SQL updates as a separate, single change set (with the test1 `RoboticoOps` rebuilt and
`db:validate:test` green on the new names).
