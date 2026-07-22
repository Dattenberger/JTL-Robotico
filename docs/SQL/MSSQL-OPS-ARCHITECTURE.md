---
date: 2026-07-10
author: Lukas + Claude Code
status: Accepted
context: How the MSSQL ops infrastructure fits together — the two migration chains, the RoboticoOps admin DB, the server-side test-mandant reset, the excel_ekl boundary, and the standing operating rules.
related-plan: ../plans/2026-07-10 - mssql-ops-infrastruktur/mssql-ops-infrastruktur.md
related-adrs: adr-grate-migration-runner, adr-two-chain-migration-paths, adr-module-signing-reset, adr-reset-step-registry (plan-scoped — pending promotion)
---

# MSSQL Ops Architecture

How JTL-Robotico versions its own SQL objects, administers its SQL instances, and resets
test mandants — server-side, audited, and without personal admin rights on production.

> [!NOTE]
> This document is the **post-implementation snapshot** and the **single source of truth
> for the standing operating rules** (§6). The *decisions* and their alternatives live in
> the plan's Decision Log (D1–D13) and in the three ADRs; they are referenced here, not
> repeated. The *file-level contract* for migration authors lives in
> [`db-migrations/README.md`](../../db-migrations/README.md); this doc is the map above it.

## 1. Vision and Motivation

### 1.1 Why this infrastructure exists

Two operational problems shared one root cause — *nothing about our SQL estate was
versioned or self-service*:

- Our own objects (`Robotico.*`, our `CustomWorkflows.*` procs) were deployed ad hoc via
  SSMS. No journal, no idempotency, no record of what ran on which database.
- The test-mandant reset was a PowerShell script that required the operator to hold
  **personal admin rights on the production server**, had no audit trail, and read its
  config from a git-ignored JSON synced over Google Drive.

### 1.2 What problem this solves

- **Drift & opacity** — no way to know whether a clone carries the same object definitions
  as prod, or which migrations a database has seen.
- **Privilege sprawl** — every colleague who needed a reset needed prod server rights.
- **Silent, un-auditable operations** — a failed reset left an unclear state and no log.
- **Secrets in sync-ware** — licence keys lived in a Google-Drive-synced file.
- **No test→prod path** — no defined way to roll a DB feature to test first, then prod.

### 1.3 Discarded alternatives (pointers)

The big "why not X" answers live in the ADRs, one paragraph each:
DACPAC / Flyway / DbUp / hand-rolled runner → `adr-grate-migration-runner.md`;
one central journal / image-based promotion → `adr-two-chain-migration-paths.md`;
synchronous reset / Service Broker / pure-certificate signing / least-privilege job owner
/ status view / encrypted licence column → `adr-module-signing-reset.md`.

### 1.4 What this architecture buys us

1. Versioned, journalled, idempotent migrations (grate) with a baseline of the existing estate.
2. A clone that is self-describing — it carries its own migration journal.
3. A reset any colleague triggers with a single `EXECUTE`, fully audited, no server rights.
4. A reset that survives SQL Server cumulative updates (no msdb countersignatures to lose).
5. One versioned config home; licence keys never touch git.
6. A script-only, engine-version-safe path from test to prod.

## 1a. Architecture Walkthrough

### 1a.0 The two chains + the admin DB (stack)

```
┌───────────────────────────────────────────────────────────────────────────┐
│  Ebene A — copyable content            Scope: eazybusiness                  │
│  Folder:  db-migrations/eazybusiness/                                       │
│  Journal: schema Robotico, DECENTRALISED (one per eazybusiness copy)        │
│  Payload: Robotico.*  +  our own CustomWorkflows.* action procs             │
│  Lives in: eazybusiness, eazybusiness_tmN clones, test1's eazybusiness      │
└───────────────────────────────────────────────────────────────────────────┘
        │ travels with a backup+restore clone (journal is inside the DB)
        ▼
┌───────────────────────────────────────────────────────────────────────────┐
│  Ebene B — instance uniques            Scope: global                        │
│  Folder:  db-migrations/global/                                             │
│  Journal: schema ops, in the RoboticoOps DB of THIS instance               │
│  Payload: RoboticoOps DB, logins, signing cert, SQL-Agent job, grants       │
│  Lives in: exactly one place per SQL instance — never cloned                │
└───────────────────────────────────────────────────────────────────────────┘

  One tool (grate), one wrapper (deploy.ps1). -Scope picks the chain.
  Dividing line: Ebene A versions what is copied; Ebene B versions uniques
  that are never copied. Nothing is both.  (ADR two-chain / plan D2)
```

### 1a.1 Ebene A — the eazybusiness chain

- **Purpose:** deploy our objects into every eazybusiness copy.
- **Location:** `db-migrations/eazybusiness/{up,functions,views,sprocs}/`.
- **Journal:** `Robotico.ScriptsRun` etc. — inside each DB, so a clone brings its state.
- **Contract:** [`db-migrations/README.md`](../../db-migrations/README.md) §1–§6.

### 1a.2 Ebene B — the global chain + RoboticoOps

- **Purpose:** create and maintain the one-per-instance admin objects.
- **Location:** `db-migrations/global/{up,sprocs,runAfterOtherAnyTimeScripts,permissions}/`.
- **Journal:** `ops.ScriptsRun` in `RoboticoOps`.
- **RoboticoOps** (collation `Latin1_General_CI_AS`, recovery FULL — the instance backup
  plan must include RoboticoOps LOG backups or the log grows unbounded, see
  `rollout-mssql-ops.md`; owner `sa`) holds
  three schemas:
  - `ops` — registry & state: `ops.tMandant` (config incl. column-protected `cShopLicense`),
    `ops.tConfig` (paths, source DB, reference mandant), `ops.tResetRequest` (the queue /
    audit log), `ops.tResetStep` (the ordered pipeline definition — see §1a.3),
    `ops.tMaintenanceJob` (the declarative maintenance-job registry — see below), and the
    grate journal.
  - `reset` — the reset SPs (entry, status, orchestrator, the `spInternal_*` steps, and the
    `spInternal_LogStep` cStepLog helper).
  - `maint` — the SQL-Server maintenance suite (plan `2026-07-21 - mssql-wartung-ola`,
    ADR-A/ADR-B): the registry `ops.tMaintenanceJob` declares 6 agent jobs
    (`RoboticoOps - Maint - *`: CHECKDB, IndexOptimize+statistics, 3 cleanups, backup
    watchdog); `maint.spEnsureMaintenanceJobs` syncs msdb from it (per-job canonical
    normal-form comparison, running-job guard); every job carries the constant dispatch
    step `EXECUTE RoboticoOps.maint.spRunMaintenanceJob @cJobKey = …` (D28 — values are
    runtime proc parameters, never step-text); the vendored Ola Hallengren objects
    (`CommandLog`, `CommandExecute`, `DatabaseIntegrityCheck`, `IndexOptimize` — **no**
    `DatabaseBackup`) live in `RoboticoOps.dbo`; `maint.spCheckBackupChain` +
    `maint.spCheckMaintenanceLiveness` are the hourly read-only watchdog (stale CBB
    backup chain / "never runs" maintenance, THROW → operator mail).

### 1a.3 The reset control path

```
Colleague (EXECUTE only)                     RoboticoOps (Ebene B)
   │                                          ┌──────────────────────────────────┐
   │ EXEC reset.spPub_StartTestmandantReset ───────▶│ spPub_StartTestmandantReset            │
   │   @MandantKey = 'tm4'                     │  [signed, EXECUTE AS jobstartuser]│
   │                                           │  validate vs ops.tMandant          │
   │                                           │  applock + INSERT ops.tResetRequest │
   │                                           │  (queued) + msdb.sp_start_job      │
   │ EXEC reset.spPub_GetResetStatus  ──────────────▶│ spPub_GetResetStatus [EXECUTE grant only]│
   │   (poll)                                  └──────────────────────────────────┘
   │                                                         │ sp_start_job
   ▼                                                         ▼
                              SQL-Agent job "RoboticoOps - Testmandant Reset" (owner sa)
                              runs its T-SQL step as the Agent service account (sysadmin)
                                                             │
                                                             ▼
                              reset.spProcessNextResetRequest  [no in-job signing]
                                1. claim oldest queued → running  (RE-VALIDATE the row)
                                2. FOR EACH enabled ops.tResetStep row, ORDER BY nStepOrder:
                                     whitelist cProcName (deployed reset.spInternal_* only)
                                     → EXEC reset.[<cProcName>] @TargetDb,@RequestId,@MandantKey
                                     (each step reads its own inputs from ops.tMandant)
                                   default seeded order (up/0021):
                                     CloneDatabase → PostRestoreSecurity →
                                     InvalidateCredentials → NeutralizeWorker →
                                     AnonymizeCustomerData → GrantAccess →
                                     RegisterMandant → ApplyJtlRoles
                                → succeeded / failed + cErrorMessage + cStepLog
```

Why this shape: an Agent job takes no parameters, so the `ops.tResetRequest` queue is the
parameter-passing **and** audit mechanism; async avoids the client timeout of a
minutes-long restore; the signed entry SP lets a non-privileged colleague start a
sysadmin-context job without holding any server rights. Full rationale:
`adr-module-signing-reset.md` (plan D5–D8).

The pipeline itself is **data-driven** (`adr-reset-step-registry.md`): the ordered,
enabled steps are rows in `ops.tResetStep`, not a hard-coded `EXEC` list, so a new
preparation step is "deploy a `reset.spInternal_*` proc + `INSERT` one row" without editing
the orchestrator. The orchestrator whitelists each `cProcName` against the deployed catalog
before running it (only `reset.spInternal_*` procs may run, name via `QUOTENAME`), so the
executable set stays exactly what the versioned chain deployed — only step order/enablement
is admin-only data. Every step takes the uniform `(@TargetDb,@RequestId,@MandantKey)`
contract and logs through `reset.spInternal_LogStep`; the loop writes a "starting step N"
line before each step so a mid-step failure is attributable in `cStepLog`.

## 2. Properties this architecture guarantees

1. **Clone self-description** — a mandant clone carries its `Robotico` journal; no
   post-clone baseline is needed.
2. **Vendor isolation** — the migration journal never sits in `dbo` or `RoboticoEKL`;
   the chains touch only their own named objects.
3. **Self-service reset** — a colleague needs only EXECUTE on four SPs (start / poll /
   discover / cancel); `RoboticoOps` is otherwise invisible to them.
4. **CU survivability** — signing is confined to our two `EXECUTE AS` entry SPs
   (`spPub_StartTestmandantReset` + `spPub_CancelResetRequest`); no msdb countersignatures exist to
   be dropped by a cumulative update.
5. **Full audit** — every reset is a durable `ops.tResetRequest` row (who/when/status/
   error/step-log).
6. **No secrets in git** — licence keys are seeded by placeholder + runbook UPDATE.
7. **Engine-safe promotion** — only versioned scripts flow toward prod; no test1-built
   image is ever restored onto prod (SQL 2025 → 2022 is impossible).
8. **No autonomous prod writes** — every production change is a human-gated runbook step.

## 3. Component reference (code pointers)

| Component | Location | Notes |
|---|---|---|
| Ebene-A tree | `db-migrations/eazybusiness/` | ~28 files; journal `Robotico` |
| Ebene-B tree | `db-migrations/global/` | ~20 files; journal `ops` in RoboticoOps |
| Deploy wrapper | `db-migrations/deploy.ps1` | `-Scope`, `-Environment`, `-Target`, `-Baseline`, `-DryRun` |
| Target catalogue | `db-migrations/targets.config.json` | servers + DB lists; Windows auth, no secrets |
| Registry & queue | `db-migrations/global/up/0002_ops_schema_tables.sql` | `ops.tMandant` / `ops.tConfig` / `ops.tResetRequest` |
| Pipeline registry | `db-migrations/global/up/0021_reset_step_registry.sql` | `ops.tResetStep` — ordered `reset.spInternal_*` steps + seed (data-driven pipeline, EXT-1) |
| Signing cert | `db-migrations/global/up/0011_signing_certificate.sql` | private key in RoboticoOps, public in master |
| Proxy login | `db-migrations/global/up/0010_jobstartuser_login.sql` | DISABLEd, `DENY CONNECT SQL`, msdb SQLAgentOperatorRole |
| Reset colleague SPs | `db-migrations/global/sprocs/reset.{spPub_StartTestmandantReset,spPub_GetResetStatus,spPub_ListMandants,spPub_CancelResetRequest}.sql` | self-service surface (EXECUTE → `ops_reset_executor`). Start + Cancel are signed `EXECUTE AS jobstartuser` (cross into msdb); Status + List are grant-only |
| Reset admin SPs | `db-migrations/global/sprocs/reset.{spPub_PurgeOldRequests,spPub_CreateTestmandant}.sql` | EXECUTE → `ops_admin` only. `spPub_PurgeOldRequests` = audit-log retention (keep-last-N per mandant). `spPub_CreateTestmandant` = one-call mandant creation: registers `ops.tMandant` (no silent upsert — existing key THROWs) then EXECs `spPub_StartTestmandantReset`, whose first reset **builds** the clone DB (`spInternal_CloneDatabase` RESTOREs it). Not signed; delegates the msdb crossing to the signed `Start` |
| Reset pipeline | `db-migrations/global/sprocs/reset.{spProcessNextResetRequest,spInternal_*}.sql` | whitelist-guarded loop over `ops.tResetStep`; uniform-contract steps; `spInternal_LogStep` cStepLog helper |
| Agent-job wrapper | `db-migrations/global/runAfterOtherAnyTimeScripts/reset.spEnsureAgentJob.sql` | idempotent job (re)install, owner `sa` |
| Re-signing | `db-migrations/global/permissions/900_resign_procedures.sql` | everytime; heals dropped signatures |
| Maintenance registry | `db-migrations/global/up/0023_maintenance_registry.sql` | `maint` schema + `ops.tMaintenanceJob` DDL (rows via `maint.spApplyMaintenance` MERGE) |
| Vendored Ola objects | `db-migrations/global/up/0022_maintenance_ola_vendor.sql` | pinned `dbo.CommandLog`/`CommandExecute`/`DatabaseIntegrityCheck`/`IndexOptimize`; **no `DatabaseBackup`** (ADR-B) |
| Maintenance sync | `db-migrations/global/sprocs/maint.spEnsureMaintenanceJobs.sql` | registry → agent jobs (constant dispatch step, D28/D31) |
| Maintenance dispatcher | `db-migrations/global/sprocs/maint.spRunMaintenanceJob.sql` | runtime command matrix: registry row → Ola/system call |
| Backup watchdog | `db-migrations/global/sprocs/maint.spCheckBackupChain.sql` | read-only CBB-chain freshness (local time base, target validation, THROW 51100) |
| Liveness check | `db-migrations/global/sprocs/maint.spCheckMaintenanceLiveness.sql` | registry desired-state vs. CommandLog freshness (D36, THROW 51105) |
| Maintenance reconcile | `db-migrations/global/runAfterOtherAnyTimeScripts/maint.spApplyMaintenance.sql` | value-guarded MERGE of the desired rows + ensure call |
| Maintenance operator | `db-migrations/global/permissions/260_maintenance_operator.sql` | everytime: operator + agent mail profile (guarded) + unconditional ensure self-heal (D29) |
| Lint | `db-migrations/tests/lint-migrations.ps1` | rules (a)–(l) + up/-number uniqueness, the executable contract |

## 4. The excel_ekl boundary

`CustomWorkflows` is a **shared, additive** schema co-inhabited by our Ebene-A chain and
the excel_ekl migration runner (`RoboticoEKL`). The ownership split is a hard contract
(plan **D10**) reproduced verbatim in [`db-migrations/README.md`](../../db-migrations/README.md)
§5. In short: each side creates/alters only its own named objects; we never touch
`spCMArtikel` / `spCMArtikelNeu`, the `RoboticoEKL` schema, or `dbo.tWorkflow` rows named
`EKL …`; no `DROP SCHEMA`. Names/signatures excel_ekl consumes (e.g.
`Robotico.fnEscapedCSVParseLine`, `_CheckAction`, `_SetActionDisplayName`, `vCustomAction`)
are a backward-compatibility contract. The `RoboticoOps` DB is invisible to excel_ekl.

> [!IMPORTANT]
> Our `CustomWorkflows.sp*` procedures become JTL workflow actions only because the JTL
> **"Custom Workflow Actions" module** provides `_CheckAction` / `_SetActionDisplayName`
> / the `vCustomAction*` views and their backing tables. Those are **vendor objects**;
> this repo does not create them and must not. Booking the module (+ Wawi restart +
> licence refresh) is a prerequisite — see
> [`docs/SQL/JTL-CUSTOM-WORKFLOWS.md`](JTL-CUSTOM-WORKFLOWS.md).

## 5. Naming & schema ownership

Schema ownership (who may write where) and object-naming rules live in
[`docs/SQL/NAMING-CONVENTIONS.md`](NAMING-CONVENTIONS.md), extended by this plan with the
`RoboticoOps` DB (`ops` / `reset` schemas), the per-DB `Robotico` journal, and the shared
`CustomWorkflows` zone.

## 6. Operating rules (SSoT)

These are the **standing rules** for running the estate. They live here and nowhere else.

### 6.1 Clone-after-update

JTL updates run against `eazybusiness` on prod. A mandant clone made **before** an update
carries the old schema. **Rule:** after a JTL Wawi update, re-clone the test mandants from
the updated prod `eazybusiness` (via the reset) before trusting them for tests — the reset
is the supported refresh path (see plan D9/D11 and `hygiene-findings.md` finding 2 for the
tm2 backlog case).

### 6.2 Post-update smoke test (object drift)

A JTL update can, in principle, alter shared surfaces our objects depend on. **Rule:**
after any JTL update on a database that carries our objects, run the read-only object
comparison and confirm every `Robotico.*` / `CustomWorkflows.sp*` object is present and
matches the files:

```bash
/opt/mssql-tools*/bin/sqlcmd -S <server> -E -C -d eazybusiness \
    -i db-migrations/tests/compare-objects.sql
```

A missing or drifted object means: deploy the Ebene-A chain again (grate re-runs only the
changed anytime scripts). Never edit an applied `up/` script to "fix" drift — add a new one.

### 6.3 Re-signing after a signed-SP redeploy

`CREATE OR ALTER` on a signed SP **drops its signature**. Two procs are signed —
`reset.spPub_StartTestmandantReset` and `reset.spPub_CancelResetRequest`, our two `EXECUTE AS`
entry points that cross into msdb (§2, item 4). The everytime
`permissions/900_resign_procedures.sql` re-signs **every** unsigned
`EXECUTE AS 'jobstartuser'` proc within the same grate run (it derives the set from the
catalog, so a new EXECUTE-AS entry point is signed automatically), so a normal
`deploy.ps1 -Scope global` is always self-healing. That deploy prompts for the
`RoboticoOpsSigning` certificate password (or reads `$env:GRATE_CERT_PASSWORD`) and passes
it to grate as the `{{CertPassword}}` token — the private-key password never touches git.

**Rule:** never `CREATE OR ALTER` a signed reset entry point
(`reset.spPub_StartTestmandantReset`, `reset.spPub_CancelResetRequest`) directly in SSMS on a live
instance — redeploy the `global` chain so the re-signing step runs. Note that
`900_resign_procedures.sql` carries the `{{CertPassword}}` grate token and is therefore not
runnable as raw SQL; if you must hotfix, re-sign by hand with `ADD SIGNATURE TO
<proc> BY CERTIFICATE RoboticoOpsSigning WITH PASSWORD = '<real cert password>'` for each
affected proc, or the next non-privileged caller fails with an opaque permissions error.

### 6.4 Worker-stopped gate before registering a mandant

The worker service on a host must be **fully stopped** (as a Windows service) before a
freshly registered `tMandant` row exists there — open question O2 (does a running worker
pick up a new mandant immediately?) is not yet answered, so "worker stopped" is a hard
gate. See [`testmandant-reset-validierung.md`](../runbooks/testmandant-reset-validierung.md)
Step 0.

### 6.5 Backups stay with CBB — the maintenance suite never creates a backup job

Backups are owned by Cloudberry Backup (CBB), full stop (ADR-B, plan
`2026-07-21 - mssql-wartung-ola`). The maintenance suite deliberately does **not**
vendor `dbo.DatabaseBackup`, and `ops.tMaintenanceJob` has no backup operation kind —
what is not deployed cannot be scheduled. **Rule:** nobody folds backups "for
tidiness" into Ola/the maintenance registry; the suite only *watches* the CBB chain
(`maint.spCheckBackupChain`, hourly).

### 6.6 Maintenance tuning exclusively via git + deploy

`ops.tMaintenanceJob` is **repo-owned** (D11): the `maint.spApplyMaintenance` MERGE
enforces all desired columns on every deploy — live edits to the registry (and manual
edits to the `RoboticoOps - Maint - *` agent jobs, via the ensure sync) are
overwritten. **Rule:** schedule/threshold/scope changes are made in
`maint.spApplyMaintenance.sql` and deployed, never edited live. (Instance *state*
stays admin-owned in `ops.tConfig`: `MaintenanceSchedulesEnabled = '0'` on test1.)

### 6.7 Never write to a server autonomously

No process in this repo writes to a SQL Server on its own. Read-only catalog queries
against test1/prod are fine; every deploy/reset against **prod** is a human-gated runbook
step (`rollout-mssql-ops.md`). PROD deploys go through `deploy.ps1`, which prompts for
interactive Y/N confirmation and lists the exact target DBs first.

## 7. Information Gaps

1. **`Worker.tTarget.nAbgleichstyp` semantics** — the value→meaning mapping is
   JTL-internal (no DB-side lookup; `Sync.tSyncType` is empty). Owner: JTL-side
   clarification. Fallback: the reset does **not** touch `tTarget` (plan D9/O1); worker
   neutralisation acts on account/shop level only.
2. **Worker discovery timing (O2)** — whether a running worker picks up a new `tMandant`
   row immediately is unanswered read-only. Owner: a manual run with a live worker
   (`db-migrations/tests/probes/02_worker_discovery.md`). Fallback: worker-stopped gate
   (§6.4).
3. **`pf_user` presence in prod clones (O4)** — empty on test1; prod tm* clones live on
   vm-sql2 and were out of scope for the read-only test1 session. Owner: a manual run
   against prod. Fallback: the `pf_user` neutralisation step is `IF OBJECT_ID`-guarded and
   no-ops on an empty/absent table.
4. **`eazybusiness_premig` disposition (O3)** — backup+drop vs. keep is Lukas's call; see
   `hygiene-findings.md` finding 3.

## 8. References

- **Plan (history + decisions D1–D13):**
  [`../plans/2026-07-10 - mssql-ops-infrastruktur/mssql-ops-infrastruktur.md`](../plans/2026-07-10%20-%20mssql-ops-infrastruktur/mssql-ops-infrastruktur.md)
- **ADRs (plan-scoped — pending promotion):**
  [`adr-grate-migration-runner`](../plans/2026-07-10%20-%20mssql-ops-infrastruktur/adrs/adr-grate-migration-runner.md),
  [`adr-two-chain-migration-paths`](../plans/2026-07-10%20-%20mssql-ops-infrastruktur/adrs/adr-two-chain-migration-paths.md),
  [`adr-module-signing-reset`](../plans/2026-07-10%20-%20mssql-ops-infrastruktur/adrs/adr-module-signing-reset.md),
  [`adr-reset-step-registry`](../plans/2026-07-10%20-%20mssql-ops-infrastruktur/adrs/adr-reset-step-registry.md)
- **Migration contract:** [`db-migrations/README.md`](../../db-migrations/README.md)
- **Naming / ownership:** [`NAMING-CONVENTIONS.md`](NAMING-CONVENTIONS.md)
- **Custom-action prerequisite:** [`JTL-CUSTOM-WORKFLOWS.md`](JTL-CUSTOM-WORKFLOWS.md)
- **Runbooks:** [`../runbooks/README.md`](../runbooks/README.md) (index) —
  baseline, rollout, reset-validation, hygiene.
