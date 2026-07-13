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

**File-header convention.** Every migration file opens with a header comment block
before the first statement: the object/file identity, a one-line purpose, and — for
ported or plan-driven objects — an `@see` anchor to the plan section (and the legacy
source script / research it derives from), per the repo's inline-anchor convention.
The header is documentation, not lint-enforced, but it is the first thing a maintainer
reads; keep the identity line in sync with the `CREATE` below it. Two sanctioned
shapes, chosen by layer:

- **Ebene A (`eazybusiness/`)** — **boxed banner**. The object is a self-contained
  function/proc, so the header just needs to stand out and state the purpose:

  ```sql
  -- ============================================================================
  -- Robotico.fnFindDuplicateOrders — engine: list duplicate orders (iTVF)
  -- ============================================================================
  -- <what it does, preconditions, gotchas>
  ```

- **Ebene B (`global/`)** — **compact header line + `@see`**. Reset-infrastructure
  files must announce their *chain and runtime role* up front (which chain; whether
  they are job-only / signed / everytime), which the identity line carries directly;
  an `@see` plan anchor follows the prose:

  ```sql
  -- reset.spInternal_CloneDatabase  (Ebene B / global — pipeline step, job-only)
  --
  -- <what it does, security model>
  -- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§3)
  ```

  The `@see` anchor is expected on every Ebene-B file (the reset chain leans heavily
  on the plan/research for its security model); on Ebene-A files it is optional.

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
- **(h) No ambiguous dashed date literal.** A `'YYYY-MM-DD'` string is parsed against the
  session's language / `DATEFORMAT`, so on a non-US login (German = `dmy`) it is read
  year-day-month and throws (error 190 on `CREATE CERTIFICATE … EXPIRY_DATE` — a real
  test1 deploy failure that passed the `us_english` E2E container silently). Use the
  language-neutral basic ISO form `'YYYYMMDD'`. (Comments are stripped first, so header /
  `@see` dates never trip this.)

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
orphan the `cDisplayName` extended property, so the two are one unit). Because the helper
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

### npm run shortcuts

The repo-root `package.json` exposes the whole infrastructure surface via `npm run`
(cross-platform `pwsh`). Extra args pass through after `--`:

| Script | Runs |
|---|---|
| `npm run db:lint` | the convention lint (must be 0 errors) |
| `npm run db:deploy -- -Scope … -Environment …` | generic `deploy.ps1` (any arg combination) |
| `npm run db:deploy:test` / `:test:global` | Ebene A / B against TEST |
| `npm run db:deploy:prod` / `:prod:global` | Ebene A / B against PROD (keeps the interactive Y/N gate) |
| `npm run db:deploy:e2e` / `:e2e:global` | Ebene A / B against the local E2E container |
| `npm run db:e2e:up` / `:down` / `:down:full` | container `setup.ps1` / `teardown.ps1` / teardown `-PurgeSecrets` |
| `npm run db:e2e:validate` | `validate_structure.sql` against the container's RoboticoOps |
| `npm run db:e2e:copy-logins` | copy real server logins into the container (see below) |
| `npm run db:mandant:create -- -Environment … -MandantKey tmN -DisplayName "…"` | create a new test mandant (registers + kicks the first reset, which **builds** the clone). Admin-only |
| `npm run db:mandant:list -- -Environment …` | list mandants (wraps `reset.spPub_ListMandants`) |

Add `-- -DryRun` to any deploy variant for a no-op run (e.g. `npm run db:deploy:test -- -DryRun`).
The two `Deploy Test Environment:*` legacy entries are kept as the D12 PowerShell fallback.

> [!NOTE]
> **`npm run db:e2e:copy-logins`** (`tests/docker/copy-logins.ps1`) mirrors **SQL** server
> logins from a read-only source (default `vm-sql-test1`) into the container, **preserving
> their SID + password hash**, so the reset's orphan-remap/grant paths can be exercised
> against real SIDs. Windows/AD logins are **skipped by design** — a SQL login's SID is
> `binary(16)`, an AD SID is longer (28 bytes), and `CREATE LOGIN … FROM WINDOWS` needs the
> domain a stand-alone container is not joined to. Hashes/passwords are applied via sqlcmd
> STDIN, never written to a file. `-WhatIf` previews without applying.

Targets (servers, DB lists) are resolved from `targets.config.json` — no secrets there
(Windows authentication only). `deploy.ps1` requires grate on the `PATH`
(`dotnet tool install --global grate`) and **prompts for interactive Y/N confirmation on
`-Environment PROD`**, listing the exact target DBs first (a `-DryRun` against PROD
changes nothing and therefore skips the confirmation).

> [!NOTE]
> **Ebene B resolves the module-signing certificate password automatically.** `-Scope global`
> applies the `RoboticoOpsSigning` signing chain (`global/up/0011_signing_certificate.sql`,
> `global/permissions/900_resign_procedures.sql`), whose `{{CertPassword}}` token
> `deploy.ps1` fills at run time in this order:
>
> 1. **`$env:GRATE_CERT_PASSWORD`** — explicit session override (highest priority).
> 2. **Persisted per-environment store** — survives sessions, keyed `GRATE_CERT_PASSWORD_<ENV>`
>    (`TEST`/`PROD`/`E2E`). Windows: a `User`-scoped environment variable. Linux/macOS:
>    `~/.robotico-ops/grate-cert.env` (`KEY=VALUE`, `chmod 600`), read automatically.
> 3. **Auto-generate + persist** — first-run convenience. A 100-char, purely alphanumeric
>    (`[A-Za-z0-9]`, so no quoting hazard) CSPRNG password with guaranteed upper/lower/digit
>    is minted, persisted (tier 2 location), and shown **once** on screen so you can also
>    file it in your password manager.
>
> The password is a secret — it never lives in `targets.config.json` or anywhere in git.
> `-Scope eazybusiness` needs no such token.
>
> > [!CAUTION]
> > **Auto-generation is hard-guarded (CQG-4 mismatch trap).** Tier 3 runs **only** when the
> > target instance has **no** `RoboticoOpsSigning` certificate yet (probed via `sqlcmd`
> > against the global DB / `master`). If the certificate already exists but no password is
> > known (empty env + empty store), `deploy.ps1` **aborts** with a clear message — it will
> > **never** mint a fresh password for an existing cert, because that new value could not
> > unlock the immutable private key from `up/0011` and every re-sign would fail. If the
> > safety probe cannot run (no `sqlcmd`, or the server is unreachable), the deploy also
> > aborts rather than generate blind — set `$env:GRATE_CERT_PASSWORD` explicitly then.
>
> **Runtime exposure.** grate accepts the token only as a `--usertokens=CertPassword=…`
> **command-line argument**, so during a `-Scope global` deploy the password is briefly
> visible in the host's process table (`ps`, `Get-CimInstance Win32_Process`) to any local
> user. Run global deploys only on a single-operator / least-privilege host, and never echo
> `$grateArgs` from `deploy.ps1` (a `# @see` gotcha marks that line). `deploy.ps1` prints
> only the password *source* (`session env` / `persisted store` / `auto-generated`), never
> the value — except the one-time display when a password is freshly generated.
>
> Two constraints on the cert password (the token is substituted **textually** into a
> single-quoted SQL literal, so grate cannot escape it):
> - **No single quote (`'`).** A quote breaks out of the literal in `0011`/`900`;
>   `deploy.ps1` rejects such a password before invoking grate.
> - **Set once, immutable.** `0011` is a one-time script — the private-key password is
>   fixed at the first global deploy, and the everytime `900_resign_procedures` must unlock
>   that same key with the identical password on every later deploy. A mismatch fails
>   re-signing with an explicit "does not match up/0011" error (900's TRY/CATCH). Rotating
>   the password means dropping+recreating the certificate via a new `up/` script.

> [!NOTE]
> **`ops.tConfig` runtime knobs (Ebene B).** A few reset behaviours are data, not code —
> tune them by `UPDATE ops.tConfig` (admin-only), no redeploy needed. Seeded by
> `global/up/0020_seed_mandant_template.sql`:
>
> | cKey | Default | Meaning |
> |---|---|---|
> | `BackupFile` | `E:\work\eazybusiness_to_test.bak` | COPY_ONLY backup staging path (single path ⇒ resets serialize) |
> | `TargetDataDir` | `E:\MSSQL\Data` | Data dir for clone `.mdf`/`.ldf` |
> | `SourceDb` | `eazybusiness` | Clone source database |
> | `ReferenceMandant` | `1` | kMandant used as the `tBenutzerFirma` seed template |
> | `StaleRunningHours` | `4` | Age after which `spProcessNextResetRequest` reclaims a still-`running` request as `failed` |
> | `AgentJobName` | `RoboticoOps - Testmandant Reset` | SQL Agent job name; single-sourced for `spPub_StartTestmandantReset` / `spEnsureAgentJob` / `200_ensure_agent_job` |
> | `NotifyOperator` | *(empty)* | Optional SQL-Agent operator emailed when the reset job **fails** (OPS-4). Empty ⇒ failures are pull-only (poll `spPub_GetResetStatus`). Requires Database Mail + an existing operator; wired by `reset.spEnsureAgentJob` |

> [!CAUTION]
> This repository never writes to a SQL Server autonomously. PROD deployment is always a
> human-gated runbook step. See `docs/runbooks/rollout-mssql-ops.md`.

---

## 8. Testing

| File | Kind | Checks |
|---|---|---|
| `tests/lint-migrations.ps1` | static lint | rules (a)–(g) above; exit ≠ 0 on any violation |
| `tests/compare-objects.sql` | read-only integration | **DB↔DB** object-hash drift (run against two databases, diff the outputs — baseline pre-check, post-update smoke). Not a file↔DB compare: it hashes `OBJECT_DEFINITION` (engine-normalized text), which never byte-matches a file's raw source. |
| `tests/eazybusiness/*.sql` | manual integration | ported `*_Tests.sql` — run against a **test mandant**, never prod |

Run the lint locally before every commit:

```powershell
pwsh db-migrations/tests/lint-migrations.ps1
```

> [!IMPORTANT]
> **Engine floor for the Ebene-A string/CSV API: SQL Server 2022+.**
> `Robotico.fnEscapedCSVParseLine` and `Robotico.fnStringTrimToMaxLines` use the
> 3-argument `STRING_SPLIT(…, 1)` (`enable_ordinal`), introduced in SQL Server 2022 (16.x).
> Their consumers (the history procs, `fnEscapedCSVGetField`, the duplicate-order flow)
> inherit that floor. `CREATE` succeeds on older engines, but the functions **fail at
> runtime** there — and Ebene-A objects travel with mandant clones, which can carry a lower
> database compatibility level than their host. Before relying on these on a new target,
> verify its engine version / compat level.

---

## 9. Adding a reset step (Ebene B pipeline)

The test-mandant reset pipeline is **data-driven** (`adr-reset-step-registry.md`): the ordered
steps are rows in `ops.tResetStep`, and `reset.spProcessNextResetRequest` dispatches them in a
whitelist-guarded loop. Adding a preparation step therefore does **not** edit the orchestrator.

1. **Write the step proc** `db-migrations/global/sprocs/reset.spInternal_<Name>.sql`. It **must**
   have the uniform contract — the loop calls every step exactly this way:

   ```sql
   CREATE OR ALTER PROCEDURE reset.spInternal_<Name>
       @TargetDb   sysname,
       @RequestId  int,
       @MandantKey sysname
   AS
   BEGIN
       SET NOCOUNT ON;

       -- Guard: never touch prod. Keep a distinct THROW code (51xxx) per step so the
       -- number identifies the refusing step in an error (kept inline on purpose).
       IF @TargetDb = N'eazybusiness' OR @TargetDb NOT LIKE N'eazybusiness[_]%'
           THROW 510xx, 'spInternal_<Name> refused: target is not a test-mandant clone.', 1;

       -- Read any further inputs from ops.tMandant yourself (do NOT expect the
       -- orchestrator to route them):
       --   DECLARE @Foo ... ; SELECT @Foo = Foo FROM ops.tMandant WHERE cMandantKey = @MandantKey;

       -- ... the work, inside the target DB via QUOTENAME(@TargetDb).sys.sp_executesql ...

       -- Append progress through the shared helper (owns the cStepLog format):
       EXEC reset.spInternal_LogStep @RequestId, N'<name>: <what happened>';
   END
   GO
   ```

   - The message passed to `spInternal_LogStep` carries **no** leading space and **no** trailing
     newline (the helper adds both).
   - Data values go through `sp_executesql` parameters; object/DB names through `QUOTENAME`
     (rule (g)). Never concatenate user data into an `EXEC` string.

2. **Register it** in `ops.tResetStep` by extending the seed `MERGE` in
   `db-migrations/global/up/0021_reset_step_registry.sql` — but as a **new** `up/NNNN_…` script
   (0021 is applied and immutable; see §2 CAUTION). Give it a `nStepOrder` that places it in the
   pipeline, set `bCritical = 0` only if a failure should warn-and-continue rather than abort.

3. **Extend the structure test** `db-migrations/tests/global/validate_structure.sql`: add
   `reset.spInternal_<Name>` to the required-objects list.

That is the whole change — the orchestrator, the signing chain, and the grants are untouched.
The loop **whitelists** `cProcName` against the deployed `reset.spInternal_*` procs before running
it, so a row must name a proc that the chain actually deployed (the executable set stays
versioned; only order/enablement is data — the D6 narrowing in the ADR).

> [!NOTE]
> **Role membership is deliberately NOT data (EXT-4).** The JTL_Reader/JTL_Writer member list in
> `reset.spInternal_ApplyJtlRoles` stays a code SSoT mirroring `Berechtigungen/JTL-Rollen.sql`
> (the prod source of truth). Do not move it into a runtime table — that would split the SSoT.
> Change both mirrors and redeploy. Rationale: `adr-reset-step-registry.md` §Alternatives.
