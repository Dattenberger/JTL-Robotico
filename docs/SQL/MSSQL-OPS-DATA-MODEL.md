# RoboticoOps Data Model — `ops.*` tables

Column-level reference for the four registry tables of the test-mandant reset
infrastructure (Ebene B, database `RoboticoOps`).

> [!IMPORTANT]
> **Maintenance contract:** every edit to the table DDL in
> `db-migrations/global/up/0002_ops_schema_tables.sql` or
> `db-migrations/global/up/0021_reset_step_registry.sql` (or any future `up/`
> script that alters an `ops.*` table) MUST update this document in the same
> commit. This rule is anchored in the repository `CLAUDE.md`.

The DDL files are authoritative for types/constraints; this document is
authoritative for the *meaning* of each column. Architecture context:
[`MSSQL-OPS-ARCHITECTURE.md`](MSSQL-OPS-ARCHITECTURE.md).

---

## `ops.tMandant` — test-mandant registry

One row per test mandant (which clone belongs to whom). Defined in `up/0002`.

| Column | Type | Meaning |
|---|---|---|
| `cMandantKey` | `sysname`, PK-like (UNIQUE, NOT NULL) | Business key (e.g. `tm2`, `tm9`). Consumers address the mandant by this key in `reset.spPub_StartTestmandantReset` / `spPub_GetResetStatus`. |
| `cTargetDb` | `sysname`, NOT NULL | Name of the clone database (`eazybusiness_<key>`). Guarded three ways against ever pointing at production: table CHECK `CK_tMandant_cTargetDb`, `spPub_CreateTestmandant` validation (THROW 51092), orchestrator re-validation. |
| `cDisplayName` | `nvarchar(255)`, NOT NULL | Human-readable name, shown by `spPub_ListMandants`. |
| `cDeveloper` | `nvarchar(255)`, NULL | Informational: who owns/uses this mandant. |
| `cLoginName` | `sysname`, NULL | SQL/AD login that `spInternal_GrantAccess` maps to `db_owner` inside the clone after each reset. If the login does not exist on the instance, the grant step logs a skip. |
| `cShopUrl` | `nvarchar(500)`, NULL | Staging shop URL used by `spInternal_InvalidateCredentials` to repoint the JTL shop connection (`LIKE 'http%'`-guarded, no-op when the source has no live shop). Never returned by `spPub_ListMandants` (no column DENY — not a secret, just withheld from the list SP). |
| `cShopLicense` | `nvarchar(500)`, NULL | Shop licence key applied during credential invalidation. Secret: explicit column-level `DENY SELECT` for `ops_reset_executor` (`up/0003_roles`); never returned by `spPub_ListMandants`. |
| `bActive` | `bit`, NOT NULL, default `1` | Soft-disable: an inactive mandant is refused for new resets without deleting its row/history. |
| `dCreated` | `datetime2(0)`, NOT NULL, default `SYSUTCDATETIME()` | Audit: row creation (UTC). |
| `dModified` | `datetime2(0)`, NOT NULL, default `SYSUTCDATETIME()` | Audit: last change (UTC). |

Write access: `ops_admin` only (`up/0003_roles`). `ops_reset_executor` has no
write access; secrets columns carry an explicit column DENY.

---

## `ops.tConfig` — instance key/value configuration

Replaces the hard-coded paths of the legacy `Projekte/Testsystem` scripts.
Defined in `up/0002`, seeded in `up/0020`.

| Column | Type | Meaning |
|---|---|---|
| `cKey` | `sysname`, PK-like (UNIQUE, NOT NULL) | Configuration key. Seeded keys: `BackupFile` (COPY_ONLY backup target path), `TargetDataDir` (clone data-file directory), `SourceDb` (clone source, normally `eazybusiness`), `ReferenceMandant` (kMandant used as registration template), `StaleRunningHours` (reclaim threshold for orphaned `running` requests), `AgentJobName` (SQL Agent job to start), `NotifyOperator` (optional msdb operator for failure notification). |
| `cValue` | `nvarchar(1000)`, NULL | The value. Environment-specific values (e.g. drive paths) are adjusted per instance after the first deploy — see runbook `rollout-mssql-ops.md`. |
| `cNotes` | `nvarchar(500)`, NULL | Free-text explanation of the key. |

---

## `ops.tResetRequest` — request queue + run log

State machine and audit trail for every reset run. Defined in `up/0002`.

| Column | Type | Meaning |
|---|---|---|
| `kResetRequest` | `int IDENTITY`, PK | Request id, returned to the caller by `spPub_StartTestmandantReset`. |
| `cMandantKey` | `sysname`, NOT NULL | Mandant the reset runs for (snapshot at request time). |
| `cTargetDb` | `sysname`, NOT NULL | Clone DB at request time. Filtered unique index `IX_tResetRequest_Active` enforces **at most one active (`queued`/`running`) request per target DB** — declarative belt-and-braces on top of the SP applock. |
| `cStatus` | `nvarchar(20)`, NOT NULL | State machine: `queued → running → succeeded \| failed` (CHECK-constrained — there is no separate `cancelled` state: `spPub_CancelResetRequest` moves a request to `failed` with a `cancelled by …` note in `cErrorMessage`). |
| `cRequestedBy` | `sysname`, NOT NULL | `ORIGINAL_LOGIN()` of the requester (audit). |
| `dRequested` | `datetime2(0)`, NOT NULL, default UTC now | When the request was queued. |
| `dStarted` | `datetime2(0)`, NULL | When the orchestrator claimed it (`running`). |
| `dFinished` | `datetime2(0)`, NULL | When it reached a terminal state. |
| `cErrorMessage` | `nvarchar(max)`, NULL | Error text when `failed`. |
| `cStepLog` | `nvarchar(max)`, NULL | Line-per-event pipeline protocol (`starting step N: …`), appended by `reset.spInternal_LogStep`; surfaced by `spPub_GetResetStatus`. |
| `dModified` | `datetime2(0)`, NOT NULL, default UTC now | Last touch of the row (audit). Note: the stale-reclaim check (`StaleRunningHours`) compares against `dStarted`, not `dModified`. |

---

## `ops.tResetStep` — data-driven pipeline registry (EXT-1)

Ordered list of `reset.spInternal_*` steps that `reset.spProcessNextResetRequest`
executes. Adding a preparation step = deploy a new `spInternal_*` proc + one row
here; the orchestrator is never edited. Defined and seeded in `up/0021`.
Security model: `adrs/adr-reset-step-registry.md` (plan-scoped).

| Column | Type | Meaning |
|---|---|---|
| `kResetStep` | `int IDENTITY`, PK | Row id. |
| `nStepOrder` | `int`, NOT NULL, UNIQUE | Execution order (seeded 10…80, gaps left for insertions). |
| `cProcName` | `sysname`, NOT NULL, UNIQUE | Proc **name** only (schema is always `reset`). CHECK `CK_tResetStep_cProcName` enforces the `spInternal_%` prefix; the orchestrator additionally whitelists the name against `sys.procedures` before `EXEC` via `QUOTENAME` — only versioned-deployed procs can ever run. |
| `bEnabled` | `bit`, NOT NULL, default `1` | Toggle a step off without deleting it. |
| `bCritical` | `bit`, NOT NULL, default `1` | `1`: step failure aborts the run, clone is quarantined `failed`. `0`: failure is logged as WARN and the pipeline continues. |
| `cNotes` | `nvarchar(400)`, NULL | Short description of the step (seeded). |

Seeded default pipeline (order → proc): 10 `spInternal_CloneDatabase`,
20 `spInternal_PostRestoreSecurity`, 30 `spInternal_InvalidateCredentials`,
40 `spInternal_NeutralizeWorker`, 50 `spInternal_AnonymizeCustomerData`,
60 `spInternal_GrantAccess`, 70 `spInternal_RegisterMandant`,
80 `spInternal_ApplyJtlRoles`.

---

## References

- DDL: `db-migrations/global/up/0002_ops_schema_tables.sql`, `db-migrations/global/up/0021_reset_step_registry.sql`
- Roles/grants: `db-migrations/global/up/0003_roles.sql`, `db-migrations/global/permissions/100_grants.sql`
- Architecture: [`MSSQL-OPS-ARCHITECTURE.md`](MSSQL-OPS-ARCHITECTURE.md)
- Naming convention (Hungarian, EKL): `docs/plans/2026-07-10 - mssql-ops-infrastruktur/adrs/adr-ebene-b-hungarian-naming.md`
- Clone-guard audit: `docs/plans/2026-07-10 - mssql-ops-infrastruktur/reports/clone-guard-audit.md`
