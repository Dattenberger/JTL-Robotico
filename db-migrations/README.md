# `db-migrations/` — Migration Conventions (grate, Ebene A + Ebene B)

This directory is the **single source of truth** for every versioned SQL object
JTL-Robotico deploys with [grate](https://github.com/grate-devs/grate). It holds
two independent migration chains and the rules every migration file must obey.

> [!IMPORTANT]
> This README is the **contract**. Every file under `eazybusiness/` and `global/`
> must satisfy the rules below. The rules are enforced mechanically by
> `tests/lint-migrations.ps1` — the executable form of this document. A migration
> that fails the lint does not ship.

See also:
- Naming ownership table: [`docs/SQL/NAMING-CONVENTIONS.md`](../docs/SQL/NAMING-CONVENTIONS.md)
- Custom-action mechanics: [`docs/SQL/JTL-CUSTOM-WORKFLOWS.md`](../docs/SQL/JTL-CUSTOM-WORKFLOWS.md)
- Baseline procedure: [`docs/runbooks/migrations-baseline.md`](../docs/runbooks/migrations-baseline.md)
- The plan that introduced this: `docs/plans/2026-07-10 - mssql-ops-infrastruktur/`

---

## 1. The two chains (Ebene A / Ebene B)

grate runs one chain per invocation. Which chain is selected by `deploy.ps1 -Scope`.

| Scope | Folder | Journal schema | Lives in | Contents |
|---|---|---|---|---|
| `eazybusiness` | `eazybusiness/` | `Robotico` | **every** eazybusiness copy (incl. `eazybusiness_tmN` clones) | `Robotico.*` objects + our own `CustomWorkflows.*` action procs |
| `global` | `global/` | `ops` (in `RoboticoOps`) | one instance only (`RoboticoOps` DB) | instance uniques: logins, certificates, agent jobs, ops/reset schemas |

**Why the journal schema is not `dbo` and not `grate`:** the journal must (a) live in
our own schema to respect the vendor boundary and (b) travel with a mandant clone so a
fresh clone knows its own migration state. `Robotico` satisfies both. `RoboticoEKL` is
off-limits (owned by the excel_ekl runner — see §5). Details: plan decisions D2/D3.

> [!NOTE]
> **Ebene A travels with the clone; Ebene B does not.** A mandant clone (backup+restore)
> carries its `Robotico` journal along, so it already knows which Ebene-A scripts ran.
> Ebene-B objects (`RoboticoOps`) have no clone mechanism — every Ebene-B `up/` script is
> written idempotently with `IF NOT EXISTS` guards so a re-run is harmless.

---

## 2. Folder semantics (grate run model)

grate classifies scripts by the folder they live in. The folders we use:

| Folder | grate class | Runs | Use for |
|---|---|---|---|
| `up/` | one-time | **once**, in filename order, tracked by hash | schemas, tables, seeds, instance uniques (logins/certs) |
| `functions/` | anytime | whenever the file **hash changes** | scalar / table-valued functions (`CREATE OR ALTER`) |
| `views/` | anytime | on hash change | views (`CREATE OR ALTER`) — none yet |
| `sprocs/` | anytime | on hash change | stored procedures (`CREATE OR ALTER`) |
| `runAfterOtherAnyTimeScripts/` | anytime | on hash change, **after** all other anytime folders | objects that depend on all sprocs existing (e.g. the agent-job wrapper) |
| `permissions/` | everytime | **every** run, last | grants, role membership, signature re-application |

Anytime folders run in this fixed order: `functions/` → `views/` → `sprocs/` →
`runAfterOtherAnyTimeScripts/`. Within a folder, files run **alphabetically**. This is
how ordering dependencies are expressed — see §4.

> [!CAUTION]
> **`up/` scripts are immutable after they have been applied anywhere.** grate tracks
> them by content hash; editing an applied `up/` script makes grate fail with a hash
> mismatch on the next run (and would mean a mandant clone silently disagrees with prod).
> To correct an applied one-time script, add a **new** `up/` script with the next number.
> The escape hatch `--warnandignoreononetimescriptchanges` is a documented runbook-only
> emergency lever — never a `deploy.ps1` default.

---

## 3. File-naming rules

| Folder class | Pattern | Example |
|---|---|---|
| `up/` (one-time) | `NNNN_snake_case.sql` (4-digit, zero-padded, monotonic) | `0001_robotico_schema.sql` |
| anytime (functions/views/sprocs/…) | `Schema.ObjectName.sql` — exactly the object it creates | `Robotico.fnFindDuplicateOrders.sql` |
| everytime (`permissions/`) | `NNN_snake_case.sql` (ordering prefix) | `100_grants.sql` |

The anytime filename **is** the object identity: one file = one object, named
`Schema.Object.sql`. The lint checks that the filename matches the `CREATE` inside.

---

## 4. Hard rules (lint-enforced)

Every file under `eazybusiness/` and `global/` must obey all of these. The rule letters
match `tests/lint-migrations.ps1`.

- **(a) No `USE` statement.** grate connects to the target DB itself; a `USE` would
  redirect the batch to the wrong database. Deploy target is chosen by `deploy.ps1`.
- **(b) No `GO;`.** A batch separator is `GO` **alone on its own line**. `GO;` is a
  syntax error under `sqlcmd`/grate. (This is the single most common defect in the
  legacy scripts we port from.)
- **(c) Exactly one main object per anytime file.** One `CREATE` / `CREATE OR ALTER`
  of a function/view/procedure per file in `functions/`, `views/`, `sprocs/`. Trailing
  registration calls (`EXEC CustomWorkflows._SetActionDisplayName …`) are **not** objects
  and are allowed — see §6.
- **(d) No forbidden references** (outside comments): `spCMArtikel`, `spCMArtikelNeu`,
  `RoboticoEKL`, `DROP SCHEMA`, `TRUNCATE TABLE dbo.`. The first three are the excel_ekl
  runner's territory (§5); the last two are destructive against shared/vendor space.
- **(e) `up/` files match `NNNN_…`; anytime files match `Schema.Object.sql`.**
- **(f) `Berechtigungen/cleanup/*` scripts contain no un-commented writing statement**
  (production-impact scripts are inspected, then run by a human — see plan §6).
- **(g) No user data concatenated into dynamic SQL.** Object/DB names go through
  `QUOTENAME`; data values go through `sp_executesql` parameters — never string `+ @var`
  concatenation into an `EXEC` string. (Heuristic warning; see the Ebene-B reset procs.)

Beyond the lint, two conventions the lint cannot fully check:

- **Prefer `CREATE OR ALTER`** for functions/views/procs (idempotent re-deploy without a
  drop that would orphan extended properties / signatures).
- **Never hard-code JTL IDs.** Resolve objects by name; make missing prerequisites a
  **hard FAIL**, not a silent warning (lesson from the excel_ekl prod incidents — see
  `research/1.1-ekl-runner-grenze/`).

> [!WARNING]
> **`--runallanytimescripts` is forbidden in PROD.** It re-runs every anytime script
> regardless of hash and would re-deploy unchanged objects (dropping/recreating signatures
> and extended properties needlessly). It is a local-dev-only convenience.

---

## 5. The excel_ekl boundary (D10 — verbatim)

The `CustomWorkflows` schema is **shared** with the excel_ekl migration runner
(`RoboticoEKL`). Both chains write into it. The ownership split is a hard contract:

**excel_ekl owns (this chain must NEVER touch):**
- Schema `RoboticoEKL.*` in full, incl. `tMigrationHistory` and the applock
  `RoboticoEKL_Migration`.
- In `CustomWorkflows`: `spCMArtikel`, `spCMArtikelNeu`.
- Rows in `dbo.tWorkflow` / `dbo.tWorkflowAktion` whose `cName` starts with `EKL …`.
- excel_ekl-driven state in `dbo` (e.g. `tArtikelLabel`).

**JTL-Robotico / this chain owns (excel_ekl consumes it — keep names/signatures stable):**
- Our own `CustomWorkflows.sp*` action procedures (this directory).
- `Robotico.*` — note excel_ekl reads e.g. `Robotico.fnEscapedCSVParseLine`, so its
  signature is a backward-compatibility contract.
- The `RoboticoOps` DB (invisible to excel_ekl).

**Shared zone (additive, coordinated):** `CustomWorkflows` as a container is co-inhabited.
Each side creates/alters **only its own named objects**. No `DROP SCHEMA`, no deleting
foreign objects. Idempotent `IF NOT EXISTS` schema creation is compatible on both sides.
`dbo` (JTL vendor) is touched by both only under the same idempotency / resolve-by-name
rules.

---

## 6. Custom Workflow Actions — module prerequisite (not ours to create)

Our `CustomWorkflows.sp*` procedures become JTL workflow actions by **existing in the
`CustomWorkflows` schema and satisfying three structural rules** (PK-first `int` param,
allowed datatypes, ≤7 params). There is **no registry table**.

> [!IMPORTANT]
> `CustomWorkflows._CheckAction`, `CustomWorkflows._SetActionDisplayName`,
> `CustomWorkflows._SetActionParameterDisplayName` and the views
> `CustomWorkflows.vCustomAction[Parameter|Check]` plus the tables
> `CustomWorkflows.tWorkflowObjects` / `tAllowedDatatypes` are **provided by the JTL
> "Custom Workflow Actions" module** (bookable since Wawi 1.6), **not** by this repo.
> They are vendor objects. This chain therefore does **not** create them, and must not.
> Booking the module (plus Wawi restart + license refresh) is a documented prerequisite —
> see `docs/SQL/JTL-CUSTOM-WORKFLOWS.md`. Verified from live `OBJECT_DEFINITION` in that
> doc.

**Registration pattern in our action files.** Each `CustomWorkflows.sp*` file ends with
its label registration bundled in the *same* file as the proc (a `DROP PROCEDURE` would
orphan the `DisplayName` extended property, so the two are one unit). Because the helper
is module-provided, the call is **guarded** so a machine without the module gets a clear
warning instead of a hard failure:

```sql
CREATE OR ALTER PROCEDURE CustomWorkflows.spExample @kArtikel INT AS
BEGIN
    -- ...
END
GO

-- Registration (label shown in the JTL action picker). Guarded: the helper is
-- provided by the JTL Custom Workflow Actions module, not by this chain.
IF OBJECT_ID('CustomWorkflows._SetActionDisplayName', 'P') IS NOT NULL
    EXEC CustomWorkflows._SetActionDisplayName
        @actionName  = 'spExample',
        @displayName = 'Example action';
ELSE
    PRINT '! CustomWorkflows._SetActionDisplayName missing — Custom Workflow Actions module not booked; skipping label registration.';
GO
```

---

## 7. Deploying

```powershell
# Ebene A (eazybusiness objects) against the TEST server's eazybusiness
pwsh db-migrations/deploy.ps1 -Scope eazybusiness -Environment TEST

# Ebene A against a single mandant clone (test a migration on tm2 before prod)
pwsh db-migrations/deploy.ps1 -Scope eazybusiness -Environment PROD -Target eazybusiness_tm2

# Ebene B (RoboticoOps) against TEST
pwsh db-migrations/deploy.ps1 -Scope global -Environment TEST

# Dry run (grate --dryrun; no changes applied)
pwsh db-migrations/deploy.ps1 -Scope eazybusiness -Environment TEST -DryRun

# Baseline an existing DB (mark all current scripts as run WITHOUT executing them)
pwsh db-migrations/deploy.ps1 -Scope eazybusiness -Environment PROD -Target eazybusiness -Baseline
```

Targets (servers, DB lists) are resolved from `targets.config.json` — no secrets there
(Windows authentication only). `deploy.ps1` requires grate on the `PATH`
(`dotnet tool install --global grate`) and **prompts for interactive Y/N confirmation on
`-Environment PROD`**, listing the exact target DBs first.

> [!CAUTION]
> This repository never writes to a SQL Server autonomously. PROD deployment is always a
> human-gated runbook step. See `docs/runbooks/rollout-mssql-ops.md`.

---

## 8. Testing

| File | Kind | Checks |
|---|---|---|
| `tests/lint-migrations.ps1` | static lint | rules (a)–(g) above; exit ≠ 0 on any violation |
| `tests/compare-objects.sql` | read-only integration | file ↔ deployed-object hash comparison (baseline pre-check, post-update smoke) |
| `tests/eazybusiness/*.sql` | manual integration | ported `*_Tests.sql` — run against a **test mandant**, never prod |

Run the lint locally before every commit:

```powershell
pwsh db-migrations/tests/lint-migrations.ps1
```
