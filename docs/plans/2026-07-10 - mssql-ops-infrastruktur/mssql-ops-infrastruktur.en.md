# Infrastructure: MSSQL Ops — Migration Foundation, RoboticoOps DB, Testmandant Reset

> [!NOTE]
> **English translation** of the German plan file
> [`mssql-ops-infrastruktur.md`](mssql-ops-infrastruktur.md) (archive convention: an
> archived plan keeps the language it was written in and gets an `.en.md` sidecar).
> Structure, section numbering (`§1`–`§7`), decision IDs (`D1`–`D13`), open-question IDs
> (`O1`–`O5`), object names, file paths and links are identical to the source — only prose
> is translated. German domain terms that are names in the codebase, the runbooks or the
> ADRs are kept as-is: **Ebene A / Ebene B** (level A / level B of the migration chains),
> **Mandant / Testmandant** (JTL's tenant concept and its test clones).

**Status:** Implemented 2026-07-29 — archived (prod cutover done; ADRs promoted → `docs/decisions/0003`–`0007`, Accepted)
**Created:** 2026-07-10
**Repo:** JTL-Robotico
**Branch / Worktree:** feature/mssql-ops-infrastruktur (in worktrees/feature/mssql-ops-infrastruktur)
**Complexity:** Large
**Estimated Plan Size:** ~1400 lines
**Modular?:** No — detail kept flat in §1–§7; the research subspecs under `research/` are evidence, not an architectural extraction
**archive_target:** 2026-07-10 - mssql-ops-infrastruktur

**Research Outputs:**
- [research/1-migrations-tooling/1-migrations-tooling.md](research/1-migrations-tooling/1-migrations-tooling.md) — tooling comparison (grate/DbUp/Flyway/DACPAC) + grate deep-dive incl. a migration plan for the existing files
- [research/1.1-ekl-runner-grenze/1.1-ekl-runner-grenze.md](research/1.1-ekl-runner-grenze/1.1-ekl-runner-grenze.md) — boundary analysis of the EKL runner (excel_ekl): shared CustomWorkflows zone, consumed APIs, lessons
- [research/2-instanz-survey/2-instanz-survey.md](research/2-instanz-survey/2-instanz-survey.md) — current state of vm-sql-test1 (SQL 2025) / vm-sql2 (SQL 2022): DBs, principals, jobs, worker flags, queues
- [research/3-module-signing-agent-job/3-module-signing-agent-job.md](research/3-module-signing-agent-job/3-module-signing-agent-job.md) — module signing + Agent-job pattern (hybrid, queue table, audit)
- [research/4-jtl-spezifika/4-jtl-spezifika.md](research/4-jtl-spezifika/4-jtl-spezifika.md) — JTL-Wawi side conditions: worker visibility, updates, licensing, probe list
- [research/5-repo-inventar/5-repo-inventar.md](research/5-repo-inventar/5-repo-inventar.md) — inventory of the current reset process + our own objects in eazybusiness

**Associated ADRs** (promoted from `adrs/` to `docs/decisions/` on 2026-07-29, Status **Accepted**):
- [0003-grate-migration-runner.md](../../decisions/0003-grate-migration-runner.md) — D1/D3: grate as the runner, journal in its own schema
- [0004-two-chain-migration-paths.md](../../decisions/0004-two-chain-migration-paths.md) — D2/D11: two chains (Ebene A/B), script-based promotion
- [0005-module-signing-reset.md](../../decisions/0005-module-signing-reset.md) — D5–D8: hybrid signing, sa-owned Agent job, status SP, `ops.tMandant`
- [0006-reset-step-registry.md](../../decisions/0006-reset-step-registry.md) — QG2: data-driven reset pipeline (`ops.tResetStep` + whitelist dispatch)
- [0007-ebene-b-hungarian-naming.md](../../decisions/0007-ebene-b-hungarian-naming.md) — 2026-07-13: renaming of Ebene B onto the RoboticoEKL Hungarian convention

**Cross-References:**
- `docs/SQL/NAMING-CONVENTIONS.md` — schema-ownership table (extended in §5 by RoboticoOps + the shared CW zone)
- `docs/SQL/JTL-CUSTOM-WORKFLOWS.md` — custom-action registration mechanics
- excel_ekl repo: `backend/migrations/jtl/` + `docs/SQL/Migration/` — the EKL runner (stays untouched; boundary see research/1.1)
- Skills: `knowledge-sql`, `knowledge-jtl-sql` (load for every SQL implementation)

---

## Decision Log

### D1 — grate as the migration runner for JTL-Robotico

**Trigger:** requirement "migrations must be versionable + maintainable"; comparison research (research/1); user decision 2026-07-09.
**Decision:** grate (self-contained CLI, https://github.com/grate-devs/grate) is this repo's migration runner. The EKL runner in excel_ekl remains unchanged.
**Rationale:** the object inventory is CREATE-OR-ALTER-heavy → grate's anytime folders with hash tracking fit exactly; no host code of our own; `--baseline` for adopting the existing state; journal schema configurable. DACPAC is ruled out by vendor coexistence, Flyway by its licensing/Java situation, DbUp by the host program plus missing hash tracking.
**Alternatives Considered:**
- DbUp: needs a C# host, RunAlways without change detection/audit — rejected.
- Home-grown T-SQL: would rebuild what grate already ships — rejected.
- Adopting the EKL runner pattern: tied to the TS toolchain, unsuitable for a SQL-only repo (user decision) — rejected.

### D2 — Two migration chains, one procedure (Ebene A / Ebene B)

**Trigger:** user requirement "cleanly separate database-global from eazybusiness".
**Decision:** one logical chain **`eazybusiness/`** (Ebene A: copyable content that lives in every eazybusiness copy — schemas `Robotico` + our own `CustomWorkflows` objects; journal decentralized **per DB** in schema `Robotico`) and one chain **`global/`** (Ebene B: instance-unique objects — RoboticoOps DB, logins, certificates, Agent jobs, server grants; journal in the **RoboticoOps** DB of the respective instance). Dividing line: *Ebene A versions content that is copied along; Ebene B versions unique objects that are never copied. Nothing is both.*
**Rationale:** a journal-in-DB travels along automatically when a mandant is cloned (a fresh clone knows its own level); instance objects have no clone mechanism and need guard-clause idempotency. One tool for both chains minimizes cognitive load.
**Alternatives Considered:**
- Central state management for all DBs inside RoboticoOps: breaks on cloning (the level does not travel along) — rejected.
- Two different tools, one per path: unnecessary complexity — rejected.

### D3 — Journal schema `Robotico` (Ebene A) resp. `ops` in RoboticoOps (Ebene B)

**Trigger:** grate's default schema `grate`; the repo's naming conventions.
**Decision:** Ebene A: `grate --schema=Robotico` (journal tables Version/ScriptsRun/ScriptsRunErrors in `Robotico`). Ebene B: `grate --schema=ops` in RoboticoOps.
**Rationale:** the journal must live in a schema of our own (never `dbo`, vendor coexistence) and must travel along on cloning; `RoboticoEKL` is off-limits (owned by the EKL runner).
**Alternatives Considered:**
- Default schema `grate`: a third foreign schema inside the JTL DB, contradicts the naming conventions — rejected.
- Journal in CustomWorkflows: shared zone with EKL, and only actions belong there — rejected.

### D4 — The admin DB is named `RoboticoOps`

**Trigger:** user decision 2026-07-09; survey: the name is collision-free on both instances.
**Decision:** the admin/ops DB is named `RoboticoOps`, collation explicitly `Latin1_General_CI_AS`, recovery SIMPLE, owner `sa`. Schemas inside it: `ops` (registry/config/journal), `reset` (reset SPs).
**Rationale:** clearly outside the `eazybusiness_*` namespace (can never be confused with a mandant clone); collation equality with eazybusiness is mandatory (JTL update blocker + cross-DB joins).
**Alternatives Considered:** `eazybusiness_ops`: collides with the clone naming pattern `eazybusiness_*` and would be caught by script safety checks / the registry pattern — rejected.

### D5 — Reset runs asynchronously: a signed SP starts an Agent job, a queue table is the hand-off

**Trigger:** backup+restore takes minutes (client timeout); colleagues have no server rights; user decision.
**Decision:** `reset.spPub_StartTestmandantReset` (EXECUTE grant only) validates, writes a request row (`ops.tResetRequest`, state machine queued→running→succeeded/failed) and starts the Agent job `RoboticoOps - Testmandant Reset` via `msdb.dbo.sp_start_job`. The job processes the oldest queued row.
**Rationale:** Agent jobs take no parameters → a queue table is the robust, auditable pattern; asynchronous = no client timeout; a table = inspectable state.
**Alternatives Considered:**
- Synchronous inside the SP: minutes of waiting, a dropped connection leaves an unclear state — rejected.
- Service Broker: overkill for a serial, infrequent process — rejected.
- Dynamic `sp_update_jobstep`: race conditions, anti-pattern — rejected.

### D6 — Permission model: hybrid signing for the start SP, sysadmin owner for the job

**Trigger:** research/3 (Sommarskog); user decision 2026-07-09.
**Decision:** the start SP runs `WITH EXECUTE AS 'jobstartuser'` (a dedicated, disabled login with `DENY CONNECT SQL`; in msdb a user + `SQLAgentOperatorRole` + EXECUTE on sp_start_job) and is signed with certificate `RoboticoOpsSigning` (certificate with private key in RoboticoOps, public key only in master → `CREATE LOGIN ... FROM CERTIFICATE` → `GRANT AUTHENTICATE SERVER`). The Agent job is owned by `sa` → its T-SQL step runs as the Agent service account (sysadmin), **no** signing inside the job. `TRUSTWORTHY` stays OFF everywhere.
**Rationale:** the hybrid avoids countersignatures on msdb system procedures (which are lost with every CU); a sysadmin owner makes BACKUP/RESTORE/xp_create_subdir/ALTER AUTHORIZATION possible without fragile grant chains. Security rests on three layers: job content only via versioned deployment; start only via the signed SP; the job re-validates the request row itself (defense in depth).
**Alternatives Considered:**
- The pure certificate route including msdb countersignatures: CU-fragile — rejected.
- A least-privilege job owner: many adjustment points susceptible to server updates, small gain (the job has to read prod anyway) — rejected.

### D7 — Status return channel: a signed status SP, no table grants

**Trigger:** user decision 2026-07-09.
**Decision:** `reset.spPub_GetResetStatus` (+ optional `@RequestId`/`@MandantKey` filters) is the only read access for colleagues; RoboticoOps otherwise stays invisible to them. A pure read SP against its own DB → needs no signing, only an EXECUTE grant to the role `ops_reset_executor`.
**Rationale:** "the SP is the interface" carried through consistently; secret columns of the registry are protected automatically.
**Alternatives Considered:** a SELECT grant on a view: opens the DB as a usable surface and creates a permanent review duty whenever the schema is extended — rejected.

### D8 — Mandant config incl. license keys in `ops.tMandant`, protected by column permissions

**Trigger:** replacement of the gitignored `test-environment.config.json` (Google Drive sync); user decision.
**Decision:** `ops.tMandant` carries cMandantKey (tmN), cTargetDb, cDeveloper, cDisplayName, cLoginName, cShopUrl, cShopLicense, bActive. `cShopLicense` (+ any further secret columns) is protected by a column-level DENY for everyone except the reset-internal procedures/admins. Seeds with real keys NEVER go through git — a seed template with placeholders + a runbook step.
**Rationale:** one place to maintain, a versionable schema, no file sync; a permission-based protection level suffices (only the signed SP chain + admins have access anyway).
**Alternatives Considered:** ENCRYPTBYKEY encryption: key-management complexity without relevant gain in an admin-only context — rejected (can be retrofitted).

### D9 — Worker neutralization becomes a fixed part of the reset (going beyond credential invalidation)

**Trigger:** research/4 (the worker reconciles every tMandant entry; licensing guardrail); the concrete flags found by the survey.
**Decision:** in the target clone the reset job additionally neutralizes: `dbo.ebay_user.nGesperrt=1` (already in e6d7b2b), `dbo.pf_user`: `nGesperrt=1, nAktiv=0` (the Amazon counterpart, guarded — the table may be empty), queue purging (`dbo.tQueue`, `dbo.tWorkflowQueue`, `dbo.ebay_usermessagequeue`, `dbo.ebay_queue_out`, `dbo.tGlobalsQueue`, `dbo.tDruckQueue`; each an `IF OBJECT_ID`-guarded DELETE/TRUNCATE), shop repoint to staging (from ops.tMandant instead of an SQLCMD variable). `Worker.tTarget` is NOT modified (the semantics of nAbgleichstyp are unclear → probe list §4; conservatively: the locks take effect at account/shop level).
**Rationale:** clearing credentials ≠ preventing reconciliation; a queue backlog fires as soon as somebody sets credentials for a test; licensing compliance (a clone must never reconcile against production).
**Alternatives Considered:** credential invalidation only (the current state): demonstrated gaps — rejected.

### D10 — CustomWorkflows is an additively shared zone; the CW registration framework + `Robotico.*` are stable APIs

**Trigger:** research/1.1: the EKL runner creates `CustomWorkflows.spCMArtikel`/`spCMArtikelNeu` and consumes `_CheckAction`/`_SetActionDisplayName`/`vCustomAction` as well as `Robotico.fnEscapedCSVParseLine`.
**Decision:** the Ebene-A chain treats `CustomWorkflows` strictly additively: create/modify only our own, individually known objects; NEVER touch `spCMArtikel`/`spCMArtikelNeu` or `dbo.tWorkflow` rows whose cName is `EKL …`; no DROP SCHEMA. Signatures/names of `_CheckAction`, `_SetActionDisplayName`, `vCustomAction` and `Robotico.fnEscapedCSVParseLine` are to be kept backward-compatible (API contract with excel_ekl).
**Rationale:** two migration chains inhabit the same schema — only an explicit ownership/additivity rule prevents them from destroying each other.
**Alternatives Considered:** "taking over" the EKL's CW objects as well: duplicated responsibility, drift between the repos — rejected.

### D11 — Promotion exclusively script-based; test1 is a regular Ebene-A target

**Trigger:** survey: test1 = SQL 2025, prod = SQL 2022 → restore only old→new; user decision F3.
**Decision:** no rollout step may ever presuppose a DB image produced on test1; only versioned scripts flow towards prod. test1/eazybusiness becomes a regular target of the Ebene-A chain (deploy order: test1 and/or the Testmandant → prod); test-data refresh on test1 continues via a restore of a prod backup (old→new is allowed).
**Rationale:** the engine version gap forces it; matches the established EKL flow (025 on test1, 024 on prod).
**Alternatives Considered:** leaving test1 as an EKL-only system: our objects would go stale there, making advance testing impossible — rejected.

### D12 — Legacy scripts stay, the new SSoT is `db-migrations/`; the PowerShell process is retired only after validation

**Trigger:** transition safety — the current process works and is needed daily.
**Decision:** `WorkflowProcedures/*` and `Projekte/Testsystem/*` stay runnable unchanged; they get deprecation notices (comment banner + README) pointing at `db-migrations/` resp. the new reset. Physical deletion/archival only after the new path has passed E2E validation (runbook §5, a manual gate).
**Rationale:** no big bang; full rollback capability is preserved.
**Alternatives Considered:** deleting the old scripts immediately: risk without necessity — rejected.

### D13 — Hygiene findings as their own building block, with manual execution only

**Trigger:** side findings of the survey; user decision F4.
**Decision:** §6 delivers check/fix scripts + a runbook for: (a) revoking sysadmin from `dbuser_dev_dana_for_jtl` (documenting replacement grants), (b) refreshing tm2 via the new reset (JTL 1.11.6.0 → current), (c) handling `eazybusiness_premig` (backup + drop, or move; decision by Lukas). **No script from §6 is ever executed autonomously against prod.**
**Rationale:** security/cleanup topics belong documented and prepared, but production changes need a human.
**Alternatives Considered:** handling them outside the plan: they would get lost — rejected (the user wanted them in the plan).

---

## Open Questions

- **O1**: semantics of the `Worker.tTarget.nAbgleichstyp` values (0,2,3,4,5,7,8,13,17,18) — affected: §3/§4, owner: research (probe list on test1). Until clarified: do not touch tTarget (D9).
  - **Probe result (C3, 2026-07-10, `probes/01_worker_ttarget_semantics.sql` against test1):** no DB-side lookup exists — `Sync.tSyncType` is present but EMPTY; the nAbgleichstyp→meaning mapping is JTL-internal (worker source/JTL support), not derivable from the schema. test1 = 10 rows, all kMandant=1, value set identical to the prod survey. **Remains "needs clarification from the JTL side"; D9 (tTarget untouched) stays valid.**
- **O2**: does the worker discover a fresh tMandant entry immediately, or only after a restart? — affected: §4 probe list, owner: research (test1).
  - **Status (C3):** needs a manual run with the worker running — instructions in `probes/02_worker_discovery.md` (not answerable read-only via SQL). Conservative default in the runbook: the worker service is stopped before every registration.
- **O3**: `eazybusiness_premig` — backup+drop or keep? — affected: §6, owner: user.
- **O4**: are Amazon accounts (`pf_user`) present in the tm clones? — affected: §3 (the neutralization is guarded and works either way), owner: research (test1/clones).
  - **Probe result (C3, 2026-07-10, `probes/03_pf_user_in_clones.sql` against test1):** `pf_user` = 0 rows in both test1 DBs (`eazybusiness`, `eazybusiness_e2e_r3_pre_snap`). The prod tm clones live on vm-sql2 and are not queryable in this session (constraint: test1 read-only only) → **needs a manual run against prod**. Uncritical for the reset: the pf_user neutralization is `IF OBJECT_ID`-guarded and no-ops on an empty table.
- **O5**: storage of the certificate password: a `~/.claude-secrets.md` entry + deploy prompt — to be confirmed — affected: §2/§5 runbook, owner: user.

---

## Context

### Problem

The Testmandant reset is a PowerShell script that requires personal admin rights on the **production server** (`-E`, BACKUP/RESTORE, granting db_owner). There is no audit trail, no central config (a gitignored JSON via Google Drive), no migration journal for our own objects in eazybusiness (deployment ad hoc via SSMS), and hard-coded assumptions (server, paths, logins, AD group) are scattered across scripts. No defined way exists to roll a DB feature out on test first (vm-sql-test1 / Testmandant) and only then to prod.

### Goals

1. **Migration foundation:** versioned, journaled, idempotent migrations via grate — one chain for eazybusiness content (Ebene A), one for instance-unique objects (Ebene B) — with a baseline of the existing state.
2. **RoboticoOps DB:** mandant registry (incl. secrets, protected by column permissions), request/run log, Ebene-B journal, roles.
3. **New reset:** colleagues trigger the Testmandant reset via `EXECUTE` on a signed SP; an Agent job does the clone plus all post-processing (incl. the extended worker neutralization); status via a status SP; a complete audit trail.
4. **Test→prod workflow:** Ebene B via vm-sql-test1, Ebene A via test1/Testmandanten — promotion exclusively script-based.
5. **Documentation:** architecture doc, three ADRs, runbooks (baseline, rollout, validation, hygiene).

### Non-Goals / Out of Scope

- No rework of the EKL runner or its migrations (excel_ekl repo, the D10 boundary).
- No autonomous execution against **prod** (vm-sql2) in this plan — the prod rollout is a runbook with a manual gate. Read-only catalog queries are allowed.
- No change to JTL `dbo` objects (vendor).
- No replacement of JTL's own update mechanics; the clone-after-update rule is documented, not automated.
- No UI/frontend — the interface is SQL (SSMS/sqlcmd).

---

## Architectural Skeleton

### Building Blocks

| # | Building Block | Description | Detail-Location | Status |
|---|----------------|-------------|-----------------|--------|
| 1 | grate migration foundation (Ebene A) | `db-migrations/` structure, conventions, porting of the existing objects (normalized), deploy wrapper, baseline | §1 below (flat) | ✅ User-Approved |
| 2 | RoboticoOps DB + global chain (Ebene B) | DB, schemas ops/reset, registry/request tables, roles, instance objects (login, certificate, job shell), signing mechanics | §2 below (flat) | ✅ User-Approved |
| 3 | Reset SP + Agent-job logic | start SP, status SP, job procedure (clone + post-processing pipeline, ported from Projekte/Testsystem, extended by D9) | §3 below (flat) | ✅ User-Approved |
| 4 | Validation & probe list vm-sql-test1 | read-only probe scripts, validation runbook, open JTL questions (O1/O2/O4) | §4 below (flat) | ✅ User-Approved |
| 5 | Docs, ADRs, rollout runbook, decommissioning | architecture doc, 3 plan-scoped ADRs, rollout runbook, deprecation banners, naming-conventions update | §5 below (flat) | ✅ User-Approved |
| 6 | Hygiene/cleanup (preparatory only) | scripts + runbook for Dana's sysadmin, the stale tm2, the premig DB | §6 below (flat) | ✅ User-Approved |
| 7 | Tests | static convention lints + SQL test files | §7 below (flat) | ✅ User-Approved |

### Data Flow / Component Interaction

```
Colleague (EXECUTE only)                       Admin/Deployer (Lukas)
  |                                              |
  | EXEC RoboticoOps.reset.spPub_StartTestmandantReset | deploy.ps1 (grate)
  v                                              v
+---------------- RoboticoOps (Ebene B) ------------------+
| reset.spPub_StartTestmandantReset  [signed, EXECUTE AS        |
|   jobstartuser] -> validates against ops.tMandant,       |
|   applock, INSERT ops.tResetRequest(queued),             |
|   msdb.dbo.sp_start_job                                 |
| reset.spPub_GetResetStatus  [EXECUTE grant only]              |
| ops.tMandant / ops.tConfig / ops.tResetRequest             |
| ops.ScriptsRun (grate journal Ebene B)                  |
+----------------------------------------------------------+
  | Agent job "RoboticoOps - Testmandant Reset" (owner sa)
  v
reset.spProcessNextResetRequest  [runs as the Agent service account]
  1. oldest queued row -> running (re-validation!)
  2. COPY_ONLY backup of eazybusiness -> restore into target clone
  3. owner/orphans/TRUSTWORTHY sequence
  4. post-processing in the clone (dynamic SQL, USE [target]):
     invalidate credentials -> shop repoint (from ops.tMandant)
     -> worker neutralization (eBay+Amazon lock, purge queues)
     -> anonymization -> grants -> tMandant/tBenutzerFirma
     -> JTL roles
  5. succeeded/failed + cErrorMessage -> ops.tResetRequest

eazybusiness / eazybusiness_tmN / test1-eazybusiness (Ebene A)
  Robotico.* (objects + grate journal Robotico.ScriptsRun)
  CustomWorkflows.* (own objects only; additively shared
  zone with the EKL runner — D10)
```

### Affected Subsystems

- **DB / migrations**: new `db-migrations/` (both chains), baseline against the existing state
- **RoboticoOps**: new DB (created only via the Ebene-B chain)
- **Repo scripts**: `WorkflowProcedures/`, `Projekte/Testsystem/`, `Berechtigungen/` (source material + deprecation banners; no functional change)
- **Documentation**: `docs/SQL/`, `docs/runbooks/` (new), `docs/plans/` (this plan), plan-scoped `adrs/`
- **Server (read-only in this plan)**: vm-sql-test1 for the probe scripts; vm-sql2 catalog reads only

---

## §1 — grate migration foundation (Ebene A)

**Status:** ✅ User-Approved
**Detail Location:** n/a — flat

### Files to Create / Modify

| Path | Action | Notes |
|---|---|---|
| `db-migrations/README.md` | NEW | conventions SSoT (see below); mind the no-German rule: English |
| `db-migrations/targets.config.json` | NEW | target catalog without secrets (Windows auth): envs TEST/PROD, server, DB lists |
| `db-migrations/deploy.ps1` | NEW | wrapper: `-Scope eazybusiness|global -Environment TEST|PROD [-Target <db>] [-Baseline] [-DryRun]` |
| `db-migrations/eazybusiness/up/0001_robotico_schema.sql` | NEW | `IF NOT EXISTS … CREATE SCHEMA Robotico` (guarded, one-time) |
| `db-migrations/eazybusiness/up/0002_robotico_paypal_tables.sql` | NEW | tPaypalAccessToken/tPaypalSettings/tPaypalTrackingLog from `WorkflowProcedures/PayPal/Add Procudures and Tables.sql`, guarded |
| `db-migrations/eazybusiness/functions/Robotico.fn*.sql` | NEW (×~13) | one object per file: fnFindDuplicateOrders, fnHasOlderDuplicateOrder, fnGetArticleCustomFieldValue, fnEscapedCSV* (4), fnString* (6) — `CREATE OR ALTER` |
| `db-migrations/eazybusiness/sprocs/CustomWorkflows._CheckAction.sql` | NEW | registration infrastructure first (the underscore sorts before `sp`); source: extract the existing definition from the WorkflowProcedures files |
| `db-migrations/eazybusiness/sprocs/CustomWorkflows._SetActionDisplayName.sql` | NEW | likewise; **API contract D10: do not change the signature** |
| `db-migrations/eazybusiness/sprocs/Robotico.sp*.sql` | NEW (×~4) | spCheckDuplicateOrder, spEnsureArticleCustomField, spSetArticleCustomFieldValue and others |
| `db-migrations/eazybusiness/sprocs/CustomWorkflows.sp*.sql` | NEW (×~7) | spPaypalTrackingLieferschein/-Versand, spArticleAppendPriceHistory/-LabelHistory, spArticleUpdateAllHistory, spGebindeErstellen, spZustandartikelLieferantSetzen — each including its `_SetActionDisplayName` registration at the end (idempotent) |
| `db-migrations/tests/eazybusiness/*.sql` | NEW | moved/ported `*_Tests.sql` + teardown (outside the deploy folders!) |
| `docs/runbooks/migrations-baseline.md` | NEW | baseline runbook: order prod/test1/tm clones, grate commands |
| `WorkflowProcedures/README.md` | NEW | deprecation notice: deployment now via db-migrations (D12); the legacy files remain as reference |

### Implementation Approach

1. **Conventions README first** (it is the contract for all further chunks): folder semantics (up = one-time, functions/views/sprocs = anytime on hash change, permissions = everytime), **prohibitions**: no `USE`, no `GO;` (only `GO` alone on a line), exactly one object per anytime file, no hard-coded JTL IDs (resolve by name, pre-checks as a hard FAIL — lesson from research/1.1), file names = `Schema.ObjectName.sql` (anytime) resp. `NNNN_snake_case.sql` (up). Take over the EKL boundary rules from D10 verbatim. One-time scripts are NEVER edited after being applied (grate hash!); a correction is a new up script.
2. **Porting:** transfer every source from `WorkflowProcedures/` into target files: remove `USE eazybusiness`, `GO;`→`GO`, `IF EXISTS DROP + CREATE` → `CREATE OR ALTER` where possible (procs/functions/views; for inline TVFs with dependent objects the order is handled via functions→sprocs), the extended-property registration (`_SetActionDisplayName`) stays part of the same file as the action proc (one unit!). Preserve the originals' comments/headers (adding a provenance line: `-- Ported from WorkflowProcedures/... (2026-07-10)`).
3. **Extract `_CheckAction`/`_SetActionDisplayName`:** lift the definitions out of the existing workflow-action files (where they are defined inline) into files of their own; deduplicate duplicates across source files (the newest version wins; verify by diff).
4. **deploy.ps1:** keep it thin — resolve targets.config.json (environment→server, scope→sqlfilesdirectory+schema+DB list), loop over the target DBs, call grate with `--connectionstring "Server=…;Database=…;Trusted_Connection=True;TrustServerCertificate=True"`, `--schema=Robotico` (scope eazybusiness) resp. `--schema=ops` (scope global), `--environment=$Environment`, `--transaction`, `--silent`, `--version=$(git describe --tags --always 2>$null)`; `-Baseline`→`--baseline`, `-DryRun`→`--dryrun`. Check grate availability (`Get-Command grate`), otherwise print an installation hint (`dotnet tool install --global grate`). PROD environment: interactive confirmation (Y/N prompt listing the targets) — lesson 5 from research/1.1.
5. **targets.config.json:** `{"environments": {"TEST": {"server": "vm-sql-test1.zdbikes.local", "eazybusiness": ["eazybusiness"], "global": "RoboticoOps"}, "PROD": {"server": "vm-sql2.zdbikes.local", "eazybusiness": ["eazybusiness", "eazybusiness_tm2", "eazybusiness_tm3", "eazybusiness_tm4"], "global": "RoboticoOps"}}}` — the clones are regular Ebene-A targets (D11; deploying to them is normally unnecessary because cloning brings the level along, but it is needed for "test a migration on the Testmandant first").
6. **Baseline runbook:** the step sequence for adopting the existing state: (a) on prod-eazybusiness `deploy.ps1 -Scope eazybusiness -Environment PROD -Target eazybusiness -Baseline` — marks all up/anytime scripts as run without executing them; (b) afterwards the normal cycle. Warning: baselining presupposes that file content == deployed state; run the object comparison (script in §7 tests) beforehand.

### Edge Cases & Risks

- **Duplicate definitions** of `_CheckAction` across several source files with drift → diff comparison, the newest wins, document the deviations in the chunk report.
- **Anytime ordering**: alphabetical; `CustomWorkflows._*` sorts before `CustomWorkflows.sp*` and `Robotico.*` — which satisfies the registration-infrastructure→actions dependency. functions/ runs before sprocs/ (grate's folder order).
- **grate not installed** on the target workstation → deploy.ps1 aborts with instructions; no silent partial execution.
- **Never `--runallanytimescripts` in PROD** — document as a prohibition in the README.
- Clone journal drift: never edit one-time scripts; should it become unavoidable → `--warnandignoreononetimescriptchanges` is documented ONLY as an emergency valve in the runbook, never as a deploy.ps1 default.

### Acceptance

- The `db-migrations/` tree is complete; **every** file passes the convention lint (§7): no `USE `, no `GO;`, 1 CREATE per anytime file, no DROP of foreign objects, no EKL object names (`spCMArtikel`, `spCMArtikelNeu`, `RoboticoEKL`).
- Content reconciliation: every deployed object from research/5 §3 has exactly one target file (mapping table in the chunk report).
- `deploy.ps1 -DryRun` is syntactically valid (PowerShell parse check via `[System.Management.Automation.PSParser]` or a `pwsh -NoProfile -Command "…" -WhatIf`-style dry run without a server).

---

## §2 — RoboticoOps DB + global chain (Ebene B)

**Status:** ✅ User-Approved
**Detail Location:** n/a — flat

### Files to Create / Modify

| Path | Action | Notes |
|---|---|---|
| `db-migrations/global/up/0001_roboticoops_settings.sql` | NEW | secure the DB settings: collation assert (`Latin1_General_CI_AS`, hard FAIL on mismatch), `ALTER DATABASE … SET RECOVERY SIMPLE`, `ALTER AUTHORIZATION … TO sa`, TRUSTWORTHY-OFF assert |
| `db-migrations/global/up/0002_ops_schema_tables.sql` | NEW | schemas `ops`, `reset`; tables `ops.tMandant`, `ops.tConfig`, `ops.tResetRequest` (incl. filtered unique index) |
| `db-migrations/global/up/0003_roles.sql` | NEW | DB roles `ops_reset_executor`, `ops_admin`; column-level DENY on `ops.tMandant.cShopLicense` for ops_reset_executor |
| `db-migrations/global/up/0010_jobstartuser_login.sql` | NEW | guarded: `CREATE LOGIN jobstartuser` (random password via a CRYPT_GEN_RANDOM construction inside the script), `ALTER LOGIN … DISABLE`, `DENY CONNECT SQL`; msdb user + `SQLAgentOperatorRole` + GRANT EXECUTE sp_start_job |
| `db-migrations/global/up/0011_signing_certificate.sql` | NEW | guarded: `CREATE CERTIFICATE RoboticoOpsSigning` in RoboticoOps (password via the grate token `{{CertPassword}}`), public-key export to master via `certencoded()`, `CREATE LOGIN RoboticoOpsSigningLogin FROM CERTIFICATE`, `GRANT AUTHENTICATE SERVER TO RoboticoOpsSigningLogin` |
| `db-migrations/global/sprocs/reset.spPub_StartTestmandantReset.sql` | NEW | detail in §3; `WITH EXECUTE AS 'jobstartuser'` |
| `db-migrations/global/sprocs/reset.spPub_GetResetStatus.sql` | NEW | detail in §3 |
| `db-migrations/global/sprocs/reset.spProcessNextResetRequest.sql` | NEW | detail in §3 (the job body) + internal helper procs (see §3) |
| `db-migrations/global/runAfterOtherAnyTimeScripts/agent_job_testmandant_reset.sql` | NEW | idempotent: `sp_delete_job` IF EXISTS → `sp_add_job` (owner `sa`) + 1 T-SQL step `EXEC RoboticoOps.reset.spProcessNextResetRequest` + `sp_add_jobserver`; enabled, no schedule (on-demand only via sp_start_job) |
| `db-migrations/global/permissions/100_grants.sql` | NEW | everytime: EXECUTE on the start/status SPs to `ops_reset_executor`; role membership for the AD group `ZDBIKES\sql-jtl-users` (guarded CREATE USER FROM LOGIN) |
| `db-migrations/global/permissions/900_resign_procedures.sql` | NEW | everytime: checks `sys.crypt_properties` for every SP that requires a signature; if the signature is missing (e.g. after CREATE OR ALTER) → `ADD SIGNATURE … BY CERTIFICATE RoboticoOpsSigning WITH PASSWORD = '{{CertPassword}}'` |
| `db-migrations/global/up/0020_seed_mandant_template.sql` | NEW | seed for ops.tConfig (BackupFile path, TargetDataDir from copy_test_db.sql) + ops.tMandant rows tm2/tm3/tm4 with `{{…}}` placeholders ONLY for cShopLicense (a runbook step fills in the real keys — never in git) |

### Implementation Approach

1. **DB creation:** grate creates the target DB automatically if it is missing (connection to `RoboticoOps`). 0001 then validates the invariants (collation!) and aborts hard if the server default deviates — with instructions (`CREATE DATABASE … COLLATE Latin1_General_CI_AS` manually).
2. **Tables:**
   - `ops.tMandant`: `cMandantKey` (PK, e.g. 'tm4', CHECK `^tm[0-9]+$`-style via LIKE), `cTargetDb` (UNIQUE, CHECK `<> 'eazybusiness'` AND LIKE 'eazybusiness[_]%'), `cDisplayName`, `cDeveloper`, `cLoginName`, `cShopUrl`, `cShopLicense`, `bActive BIT`, audit columns (dCreated/dModified).
   - `ops.tConfig`: key/value (`BackupFile`, `TargetDataDir`, `SourceDb`='eazybusiness', `ReferenceMandant`=1) — replaces the hard-coded paths from copy_test_db.sql.
   - `ops.tResetRequest`: `kResetRequest INT IDENTITY PK`, `cMandantKey FK`, `cTargetDb`, `cStatus` (CHECK IN queued/running/succeeded/failed), `cRequestedBy` (ORIGINAL_LOGIN), `dRequested/dStarted/dFinished`, `cErrorMessage NVARCHAR(MAX)`, `cStepLog NVARCHAR(MAX)` (append-only progress text). Filtered unique index: `CREATE UNIQUE INDEX IX_tResetRequest_Active ON ops.tResetRequest(cTargetDb) WHERE cStatus IN ('queued','running')`.
3. **Signing chain (D6):** the certificate with private key lives only in RoboticoOps; master gets a public-only copy via the `certencoded()` binary-literal trick inside dynamic SQL (no file round-trip, no BACKUP CERTIFICATE to disk). `GRANT AUTHENTICATE SERVER` suffices to carry the EXECUTE AS context across DB boundaries (Sommarskog's recipe); the actual msdb access runs on the jobstartuser permissions.
4. **Token handling:** `{{CertPassword}}` arrives via `deploy.ps1 -Scope global` → a prompt (`Read-Host -AsSecureString`) or the env var `GRATE_CERT_PASSWORD`; deploy.ps1 passes it through as `--usertoken CertPassword=…`. Where the password is kept: `~/.claude-secrets.md` (a runbook step, O5).
5. **Idempotency pattern for instance objects:** every up script checks `sys.server_principals`/`sys.certificates`/`msdb.dbo.sysjobs` via `IF NOT EXISTS`; a second run is inconsequential (Ebene B has no clone mechanism — D2).

### Edge Cases & Risks

- **Server collation ≠ Latin1_General_CI_AS** → 0001 aborts (hard FAIL, with instructions); never silently accept a different collation.
- **CREATE OR ALTER on signed SPs removes the signatures** → 900_resign runs everytime and heals this within the same deploy run; the order is guaranteed (permissions/ runs after sprocs/).
- **jobstartuser password:** is never needed (login disabled, DENY CONNECT) — a random value is generated inside the script and not logged.
- **SQL Agent stopped on test1** (survey) → a runbook step "set the Agent service to Automatic + start it" before the job validation.
- The AD group grant (`ZDBIKES\sql-jtl-users`) exists on test1, and is generically guarded (if the login is missing → a PRINT warning instead of an error).

### Acceptance

- The complete `global/` tree exists, convention lint green.
- Logical check (chunk self-check): every reference the SPs make to tables/columns exists in 0002; the role grants cover exactly the start/status SPs; the re-sign script lists exactly the SPs with EXECUTE AS.
- Dry-test script `db-migrations/tests/global/validate_structure.sql` (pure parsing/reference review, see §7).

---

## §3 — Reset SP + Agent-job logic

**Status:** ✅ User-Approved
**Detail Location:** n/a — flat

### Files to Create / Modify

| Path | Action | Notes |
|---|---|---|
| `db-migrations/global/sprocs/reset.spPub_StartTestmandantReset.sql` | NEW | see the §2 table; the logic lives here |
| `db-migrations/global/sprocs/reset.spPub_GetResetStatus.sql` | NEW | likewise |
| `db-migrations/global/sprocs/reset.spProcessNextResetRequest.sql` | NEW | the job's orchestrator |
| `db-migrations/global/sprocs/reset.spInternal_CloneDatabase.sql` | NEW | backup+restore (ported from copy_test_db.sql, paths from ops.tConfig) |
| `db-migrations/global/sprocs/reset.spInternal_PostRestoreSecurity.sql` | NEW | owner→sa, orphan remap (`ALTER USER … WITH LOGIN`), user cleanup, TRUSTWORTHY-OFF check |
| `db-migrations/global/sprocs/reset.spInternal_InvalidateCredentials.sql` | NEW | ported from invalidate-credentials-for-testing.sql (state e6d7b2b); cShopUrl/cShopLicense from ops.tMandant instead of SQLCMD variables |
| `db-migrations/global/sprocs/reset.spInternal_NeutralizeWorker.sql` | NEW | NEW (D9): pf_user lock, queue purging (guarded list) |
| `db-migrations/global/sprocs/reset.spInternal_AnonymizeCustomerData.sql` | NEW | ported from clear-customer-fields.sql (incl. the CONTEXT_INFO trigger bypass); blocks in TRY/CATCH with cStepLog |
| `db-migrations/global/sprocs/reset.spInternal_GrantAccess.sql` | NEW | from grant-database-access.sql (cLoginName from ops.tMandant) |
| `db-migrations/global/sprocs/reset.spInternal_RegisterMandant.sql` | NEW | from register-mandant.sql (cDisplayName from ops.tMandant; upsert into all mandant DBs) |
| `db-migrations/global/sprocs/reset.spInternal_ApplyJtlRoles.sql` | NEW | ported from Berechtigungen/JTL-Rollen.sql, parameterized on the target DB |

### Implementation Approach

1. **`reset.spPub_StartTestmandantReset(@MandantKey sysname)`** (signed, EXECUTE AS jobstartuser):
   - `sp_getapplock` Exclusive on `'reset:' + @MandantKey` (session owner, short).
   - Validation: a row in `ops.tMandant` with `bActive=1` exists; `cTargetDb <> 'eazybusiness'` (redundant with the CHECK — defense in depth); no active request (the filtered unique index additionally catches races).
   - `INSERT ops.tResetRequest (…, cRequestedBy = ORIGINAL_LOGIN(), cStatus='queued')`.
   - `EXEC msdb.dbo.sp_start_job @job_name = N'RoboticoOps - Testmandant Reset'`; if the job is already running (error 22022) → no error to the caller, the request stays queued (the running job picks it up afterwards — the while loop in ProcessNext).
   - RETURN `kResetRequest` as a result set (`SELECT kResetRequest, 'queued' AS cStatus`).
2. **`reset.spPub_GetResetStatus(@RequestId INT = NULL, @MandantKey sysname = NULL)`**: the last N requests, or filtered; columns without secrets (kResetRequest, cMandantKey, cTargetDb, cStatus, cRequestedBy, dRequested, dStarted, dFinished, DATEDIFF duration, cErrorMessage, cStepLog). No signing needed (its own DB), EXECUTE grant to ops_reset_executor.
3. **`reset.spProcessNextResetRequest`** (called only by the job; runs as the Agent service account):
   - While loop: claim the oldest `queued` row with `UPDLOCK, READPAST` → `running` + dStarted; no row → end.
   - **Re-validation (defense in depth, D6):** cTargetDb matches the ops.tMandant registry, pattern `eazybusiness[_]%`, source never == target.
   - Pipeline in TRY/CATCH, every step appends to `cStepLog` (`step=clone ok (137s)` …): spInternal_CloneDatabase → spInternal_PostRestoreSecurity → spInternal_InvalidateCredentials → spInternal_NeutralizeWorker → spInternal_AnonymizeCustomerData → spInternal_GrantAccess → spInternal_RegisterMandant → spInternal_ApplyJtlRoles.
   - CATCH: `failed` + `ERROR_MESSAGE()` + cStepLog; the clone DB is left as it is (for diagnosis), MULTI_USER is ensured.
   - Success: `succeeded` + dFinished.
4. **Porting pattern for the internal procs:** target-DB context via dynamic SQL: `SET @sql = N'USE ' + QUOTENAME(@TargetDb) + N'; ' + <Batch>; EXEC (@sql);` — take the batches over from the source scripts, replacing the `$(cTargetDb)`/`$(cLoginName)`/`$(cShopUrl)`/`$(cShopLicense)`/`$(MandantName)` SQLCMD variables with sp_executesql parameters resp. QUOTENAME injection (string values ONLY parameterized — no concatenation of payload data into elevated SQL; DB/object names ONLY via QUOTENAME).
   - `spInternal_AnonymizeCustomerData`: the source script's 11 priority blocks as numbered sub-batches; keep the CONTEXT_INFO bypass; deviating from the original: the whole proc run is logged per block in cStepLog, and an error in one block aborts the pipeline (CATCH) — no "half-anonymized, silently continue".
   - `spInternal_NeutralizeWorker` (NEW): `ebay_user.nGesperrt=1` (taken over from e6d7b2b — it also stays in the InvalidateCredentials port, doing it twice does no harm), `pf_user SET nGesperrt=1, nAktiv=0` (IF OBJECT_ID-guarded), queue purging: DELETE (not TRUNCATE — FK-safe) on `tQueue`, `tWorkflowQueue`, `ebay_usermessagequeue`, `ebay_queue_out`, `tGlobalsQueue`, `tDruckQueue` — each guarded; do NOT touch `Worker.tTarget` (O1).
   - `spInternal_RegisterMandant`: logic from register-mandant.sql 1:1 (kMandant reuse by cDB, MAX+1, tBenutzerFirma seed from the reference mandant `ops.tConfig.ReferenceMandant`).
5. **No more PowerShell in the reset path** — the entire flow is server-side; `setup-test-environment.ps1` remains as a fallback until validation (D12).

### Edge Cases & Risks

- **Simultaneous requests for different mandanten:** the job works serially (while loop) — intentional (the backup file `ops.tConfig.BackupFile` is a single path; clone backups serialize).
- **The job dies hard** (Agent restart): the row stays `running` → the start SP allows no new request for that mandant. Solution: on startup, `reset.spProcessNextResetRequest` re-claims `running` rows older than 4 h as `failed` (`cErrorMessage='stale running request reclaimed'`).
- **Restoring a 27 GB DB**: takes ~minutes; cStepLog + spPub_GetResetStatus show progress coarsely (no STATS streaming into tables — accepted).
- **eazybusiness as the target:** prevented three times over (CHECK constraint, SP validation, job re-validation).
- **`tShop` repoint selectivity** (only nTyp=0 + http URL) retained from e6d7b2b — Check24/unicorn2 stay untouched.

### Acceptance

- All reset.* files exist, lint green, every piece of source functionality from `Projekte/Testsystem/` has a target proc (mapping table in the chunk report; clear-customer-fields evidenced block by block).
- Static security review checks (§7 lint): no payload string concatenated into dynamic SQL (only QUOTENAME/parameters); every internal proc guarded against `@TargetDb = 'eazybusiness'`.

---

## §4 — Validation & probe list vm-sql-test1

**Status:** ✅ User-Approved
**Detail Location:** n/a — flat

### Files to Create / Modify

| Path | Action | Notes |
|---|---|---|
| `db-migrations/tests/probes/01_worker_ttarget_semantics.sql` | NEW | read-only: Worker.tTarget + the corresponding JTL doc queries; guidance for interpreting nAbgleichstyp (O1) |
| `db-migrations/tests/probes/02_worker_discovery.md` | NEW | probe INSTRUCTIONS (manual, test1): worker service + a fresh tMandant entry → observe the behavior (O2) |
| `db-migrations/tests/probes/03_pf_user_in_clones.sql` | NEW | read-only across all eazybusiness* DBs: pf_user rows (O4) |
| `db-migrations/tests/probes/04_queue_inventory.sql` | NEW | read-only: all tables LIKE '%queue%' + row counts per DB — verify the complete purge list |
| `docs/runbooks/testmandant-reset-validierung.md` | NEW | E2E validation runbook on test1: deploy the global chain → start the Agent → a fake mandant registry entry → reset via the SP → verification steps (status, clone content, neutralization, anonymization) |

### Implementation Approach

1. The probe scripts are **strictly read-only** (SELECT/catalog) and intended for test1; a header comment carries the invocation (`sqlcmd -S vm-sql-test1.zdbikes.local -E -C -i …`). Implementing agents MAY run them read-only against test1 and record the results in the chunk report (access via `/opt/mssql-tools*/bin/sqlcmd -E -C` exists); writing probes (02) remain instructions for Lukas.
2. The validation runbook numbers the manual E2E sequence including rollback (drop the clone) and points at O1/O2/O4 with expected values.

### Edge Cases & Risks

- test1 has only 1 mandant and no tm clone → the runbook creates a registry entry `tmv` (validation mandant) with cTargetDb `eazybusiness_tmv`; the clone source is test1's own eazybusiness.
- The Agent service is stopped on test1 → a runbook precondition.

### Acceptance

- 4 probe artefacts + the runbook exist; the read-only probes were run once (wherever a connection was possible) and the results documented in the report; O1/O2/O4 updated in the plan or marked as "needs a manual run".

---

## §5 — Docs, ADRs, rollout runbook, decommissioning

**Status:** ✅ User-Approved
**Detail Location:** n/a — flat

### Files to Create / Modify

| Path | Action | Notes |
|---|---|---|
| `docs/SQL/MSSQL-OPS-ARCHITECTURE.md` | NEW | architecture doc (English): Ebene A/B, RoboticoOps, reset flow (diagram from this plan), the EKL boundary, operating rules (clone-after-update, post-update smoke test, re-signing) |
| `adrs/adr-grate-migration-runner.md` | NEW (plan-scoped) | D1/D3; format per knowledge-adr-format, Status `Proposed (plan-scoped — pending promotion)` |
| `adrs/adr-two-chain-migration-paths.md` | NEW (plan-scoped) | D2/D11 |
| `adrs/adr-module-signing-reset.md` | NEW (plan-scoped) | D5/D6/D7/D8 |
| `docs/runbooks/rollout-mssql-ops.md` | NEW | order: (1) baseline Ebene A on prod+test1, (2) global chain on test1, (3) validation (the §4 runbook), (4) global chain on prod [manual gate + prompt], (5) seeds with the real keys, (6) first prod reset tm4, (7) PowerShell decommissioning |
| `docs/SQL/NAMING-CONVENTIONS.md` | EDIT | add: the RoboticoOps DB (`ops`/`reset` schemas), the journal tables in Robotico, the shared CW zone (the D10 rules), a pointer to db-migrations/README |
| `Projekte/Testsystem/setup-test-environment.ps1` | EDIT | comment banner at the top only: a DEPRECATED notice pointing at the new reset + runbook (functionality unchanged, D12) |
| `Projekte/Testsystem/README.md` | NEW | briefly: the current process (fallback) + a pointer to the new process and the runbooks |
| `docs/plans/README.md` | NEW | plan archive index per convention (this repo's first plan) — folder schema, comparison logic, language rules |
| `docs/runbooks/README.md` | NEW | runbook index |

### Implementation Approach

ADRs strictly per the `knowledge-adr-format` skill + `~/.claude/templates/adr.md` (the agent loads both); NNNN placeholder, plan-scoped status; `## References` bidirectional onto this plan. Architecture doc per `knowledge-doc-format` (UDOC), in English (language convention: docs English, plan German). All runbooks in English.

### Edge Cases & Risks

- Risk of doc drift between plan and architecture doc: the architecture doc is a post-implementation snapshot and points at the plan as history (SSoT rule: operating rules live in the architecture doc, not duplicated in the plan).

### Acceptance

- All files exist; the ADRs satisfy the mandatory knowledge-adr-format sections; the NAMING-CONVENTIONS edit is minimally invasive (additions only); the deprecation banner changes no functional line.

---

## §6 — Hygiene/cleanup (preparatory only — NEVER autonomously against prod)

**Status:** ✅ User-Approved
**Detail Location:** n/a — flat

### Files to Create / Modify

| Path | Action | Notes |
|---|---|---|
| `Berechtigungen/cleanup/01_dana_sysadmin_review.sql` | NEW | read-only analysis: the effective permissions of `dbuser_dev_dana_for_jtl`; + a commented-out fix (revoke sysadmin; replacement: does dbcreator stay? granular grants) |
| `Berechtigungen/cleanup/02_tm2_refresh.md` | NEW | instructions: bring tm2 (JTL 1.11.6.0) up to the current level via the new reset |
| `Berechtigungen/cleanup/03_premig_db.sql` | NEW | read-only info (size/age) + commented-out options (backup to E:\Backup + DROP; O3) |
| `docs/runbooks/hygiene-findings.md` | NEW | runbook bundling the three points with context (survey quotes) and the pending decision (O3) |

### Implementation Approach

The scripts carry a prominent header warning ("manual execution only, production impact"); the statements to be executed are commented out and described individually. No autonomous execution whatsoever (D13).

### Acceptance

- 4 artefacts exist; no uncommented writing statement in the cleanup scripts (the lint checks this).

---

## §7 — Tests

**Status:** ✅ User-Approved

### Test Strategy

No test framework in the repo (a pure SQL repo) → three static/semi-static layers:

1. **Convention lint** (`db-migrations/tests/lint-migrations.ps1`, pwsh-compatible, runs under Linux `pwsh` AND Windows): checks `db-migrations/{eazybusiness,global}` recursively for: (a) no `^USE\s` statement, (b) no `GO;`, (c) anytime files contain exactly one `CREATE OR ALTER`/`CREATE` main object and the file name matches `Schema.Object.sql`, (d) forbidden references: `spCMArtikel`, `spCMArtikelNeu`, `RoboticoEKL` (outside comments), `DROP SCHEMA`, `TRUNCATE TABLE dbo.`, (e) up files: name pattern `NNNN_…`, (f) cleanup scripts (§6): no uncommented writes, (g) dynamic SQL: heuristic check for `+ @` concatenation of non-QUOTENAME variables in EXEC strings (warning). Exit code ≠ 0 on a violation.
2. **Object reconciliation** (`db-migrations/tests/compare-objects.sql`): lists, per eazybusiness DB, the Robotico/CustomWorkflows objects with an `OBJECT_DEFINITION` hash — for the pre-baseline check (file==DB) and the post-update smoke test.
3. **SQL test files** (ported from `WorkflowProcedures/*_Tests.sql` into `db-migrations/tests/eazybusiness/`): a documented manual run against the Testmandant; header comment with the invocation + the expectation.

### Test Files

| File | Type | Topic |
|---|---|---|
| `db-migrations/tests/lint-migrations.ps1` | static lint | conventions (a)–(g), CI-capable |
| `db-migrations/tests/compare-objects.sql` | integration (read-only) | file↔DB object reconciliation for baseline/post-update |
| `db-migrations/tests/eazybusiness/*.sql` | manual integration | ported existing tests + teardown |
| `db-migrations/tests/global/validate_structure.sql` | static | reference consistency reset.*/ops.* |
| `db-migrations/tests/probes/*.sql` | read-only probes | §4 |

---

## Verification

1. `pwsh db-migrations/tests/lint-migrations.ps1` → exit 0.
2. Completeness mapping: every object from research/5 §3 ↔ exactly one file in `db-migrations/eazybusiness/` (table in the implementation report).
3. Every piece of functionality of the 6 current reset scripts ↔ one reset.spInternal_* proc (table in the report).
4. Read-only probes run against test1 (as far as a connection is available in the implementation context), results documented.
5. ADR format check against the mandatory knowledge-adr-format sections.
6. Git: all commits per the convention `[<Phase>.<Chunk>] … (mssql-ops-infrastruktur)`.

---

## Critical Files

| Path | Action |
|---|---|
| `db-migrations/README.md` | NEW |
| `db-migrations/deploy.ps1` | NEW |
| `db-migrations/targets.config.json` | NEW |
| `db-migrations/eazybusiness/**` (up/functions/sprocs) | NEW (~28 files) |
| `db-migrations/global/**` (up/sprocs/runAfterOtherAnyTimeScripts/permissions) | NEW (~15 files) |
| `db-migrations/tests/**` | NEW (lint, comparison, tests, probes) |
| `docs/SQL/MSSQL-OPS-ARCHITECTURE.md` | NEW |
| `docs/runbooks/{migrations-baseline,rollout-mssql-ops,testmandant-reset-validierung,hygiene-findings,README}.md` | NEW |
| `adrs/adr-{grate-migration-runner,two-chain-migration-paths,module-signing-reset}.md` | NEW (plan-scoped) |
| `docs/SQL/NAMING-CONVENTIONS.md` | EDIT (addition) |
| `Projekte/Testsystem/setup-test-environment.ps1` | EDIT (banner only) |
| `Projekte/Testsystem/README.md`, `WorkflowProcedures/README.md`, `docs/plans/README.md`, `docs/runbooks/README.md` | NEW |
| `Berechtigungen/cleanup/**` | NEW (3 files) |

---

## Implementation Notes

- **Worktree:** work exclusively in `worktrees/feature/mssql-ops-infrastruktur`; communicate the edit scope to all agents. Git commands: `cd worktrees/feature/mssql-ops-infrastruktur; git …`.
- **Load skills:** SQL chunks → `knowledge-sql` + `knowledge-jtl-sql`; the ADR chunk → `knowledge-adr-format`; the docs chunk → `knowledge-doc-format`.
- **Server access:** read-only against test1/prod via `/opt/mssql-tools*/bin/sqlcmd -S <host> -E -C` is allowed (using the user's Kerberos ticket); **no writes whatsoever against any server** in this plan — deployment is a runbook matter.
- **Languages:** the plan is German; all new docs/README/runbook files are English; SQL comments are English (new code) — ported existing comments may stay German (provenance).
- **Source fidelity:** ports do NOT change behavior silently; every deliberate deviation (e.g. anonymization now aborting on a block error) is commented in the code and listed in the chunk report.
- **Secrets:** never real cShopLicense keys, certificate passwords or similar in files; placeholders `{{…}}` + a runbook.

---

## Plan Conventions (Compatibility-Block for implement-long-plan)

**Plan-Type:** greenfield implementation (with porting portions)
**Implementation Skill:** implement-long-plan-v3
**Block-Mode preparation:** chunks correspond to §1–§7 (proposal: block 1 = §1; block 2 = §2+§3; block 3 = §4+§6; block 4 = §5+§7 — the analysis agent may adjust this)
**Test-Position:** tests in §7, the lint runs in every chunk self-check once available

<!-- EXECUTION-PLAN -->
<!-- /EXECUTION-PLAN -->

---

## Iteration Log

### 2026-07-09 — Intent + research (phases 1–2)
- Intent confirmed (assumptions 1–5); 6 research reports produced (4 topic agents + instance survey + the EKL boundary)
- The user's directional decisions: grate, sysadmin job owner, status SP, secrets in the DB, asynchronous reset, RoboticoOps, F3/F4 = yes

### 2026-07-10 — Skeleton + Detailed (phases 3–4, compressed)
- User approval "all standards, implement it completely" (original: „alles Standards, komplett implementieren"): the phase-4 iteration was run compressed, with the recommended defaults
- Building blocks §1–§7 detailed; D1–D13 fixed; O1–O5 marked open
- Complexity triage: Large; flat (research subspecs as evidence)
- Status → Detailed; hand-off to implement-long-plan-v3

### 2026-07-29 — Closure: prod cutover done, program implemented

The program is implemented and live. The road from "Detailed" to here, compressed:

- **Implementation + quality rounds:** block B1 (§1–§7) implemented, followed by three
  quality rounds (QG2 with the extensibility slot → the `ops.tResetStep` registry, QG3
  port/security audit) and the test1 dress rehearsal including the renaming of Ebene B onto
  the RoboticoEKL Hungarian convention (`reports/test1-rollout-report.md`).
- **Migration test campaign (2026-07-27/28):** both chains, the reset pipeline and the
  maintenance suite were tested end-to-end against the throwaway container
  `robotico-e2e-mssql`
  ([`reports/migration-testplan/99-gesamttestplan.md`](reports/migration-testplan/99-gesamttestplan.md)).
  The campaign found **five real migration bugs**, which were fixed test-first and verified
  — 70/70 regression checks + 6 scenarios PASS
  ([`reports/migration-testplan/ergebnisse/T6-fix-verifikation.md`](reports/migration-testplan/ergebnisse/T6-fix-verifikation.md)).
  `vm-sql2` stayed off-limits for the entire campaign.
- **PROD cutover 2026-07-29** against `vm-sql2` per runbook `docs/runbooks/rollout-mssql-ops.md`
  (phases 0/4a/4/4b/5/6): legacy Ola cleanup, both deploys (Ebene B newly created, Ebene A
  as an adoption across all four `eazybusiness` copies), maintenance go-live, the mandant
  registry, and the **first prod reset (tm4) `succeeded` after 332 s**. Full protocol:
  [`reports/prod-cutover-2026-07-29.md`](reports/prod-cutover-2026-07-29.md).
- **ADR promotion 2026-07-29:** the five plan-scoped ADRs are promoted to
  [`docs/decisions/0003`–`0007`](../../decisions/README.md) and set to **Accepted**; the
  references at the top point at the new paths.
- **Open (deliberately, not part of this plan):** the five follow-up points in the cutover
  protocol's §„Offen nach dem Cutover" ("Open after the cutover" — RoboticoOps into CBB,
  watch the first night, shop license keys, the remaining post-deployment checks, phase 7 =
  decommission the legacy PowerShell path) as well as the **removal of the PayPal objects**,
  which stays parked as its own branch `feature/paypal-removal` (D12: legacy objects stay
  untouched until a decision of their own replaces them).

Status → Implemented / archived.
