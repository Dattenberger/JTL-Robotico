---
date: 2026-07-13
author: Rollout agent (Claude) + Lukas
status: Plan — Phase-1 recon complete, awaiting Phase-2 go-ahead
context: Full dress rehearsal of the db-migrations/ migration + test-mandant-reset infrastructure against the real test server vm-sql-test1, plus a repeatable rollout-validation test.
related-plan: ../mssql-ops-infrastruktur.md
related-runbooks: ../../../runbooks/rollout-mssql-ops.md, ../../../runbooks/migrations-baseline.md, ../../../runbooks/testmandant-reset-validierung.md
---

# test1 Rollout Plan — dress rehearsal on vm-sql-test1

Roll the whole `db-migrations/` stack (Ebene A migrations + Ebene B `RoboticoOps`
reset infrastructure) once, end-to-end, against the **real** test server
`vm-sql-test1.zdbikes.local`, and leave behind a repeatable, npm-callable
validation test (`db:validate:test`). This file is the **plan**; nothing here has
been executed against any SQL server (Phase 1 was read-only).

> [!CAUTION]
> `vm-sql2.zdbikes.local` is **production** and was never touched, not even
> read-only. One optional read-only PROD query (PAR-1, §e) is proposed but gated on
> explicit approval.

---

## (a) Ist-Zustand test1 (read-only recon, 2026-07-13)

| Aspect | Finding | Consequence |
|---|---|---|
| Engine | SQL Server **2025** `17.0.1000.7`, **Developer** Edition, RTM | > SQL-2022 floor (3-arg `STRING_SPLIT`) → **compatible**. Repo restore rule is old→new only; here we deploy scripts, not restore, so fine. |
| Collation | `Latin1_General_CI_AS` (server + all DBs, compat 170) | Matches `0001` collation assertion → global deploy will not hard-fail. |
| My rights | `ZDBIKES\lukas`, **sysadmin = 1** | Full deploy possible. Kerberos ticket `lukas@ZDBIKES.LOCAL` valid (renew until 14.07). |
| `RoboticoOps` | **ABSENT** | Greenfield Ebene B. grate will create it. |
| Signing cert `RoboticoOpsSigning` | **ABSENT** (only built-in `##MS_*` certs) | Cert-password **tier-3 auto-gen fires** on first global deploy → persists to `~/.robotico-ops/grate-cert.env` as `GRATE_CERT_PASSWORD_TEST`. |
| Persisted cert store | `~/.robotico-ops/grate-cert.env` exists but holds **only** `GRATE_CERT_PASSWORD_E2E` | No `_TEST` key yet → consistent with a first-time TEST deploy. |
| Login `jobstartuser` | **ABSENT** | Created by `0010` (server login, disabled + DENY CONNECT SQL). |
| Login `dbuser_dev_dana_for_development` | **ABSENT** on test1 (it lives on PROD) | `internal_GrantAccess` would **skip** granting → clone unusable by the seeded dev. For the tm9 rehearsal, override `-LoginName` with a login that exists on test1 (decision §b.6). |
| Agent job / `ops_*` roles / stray remnants | **None** (no `RoboticoOps - Testmandant Reset` job, no `ops_admin`/`ops_reset_executor`, no orphan `jobstartuser`) | Clean slate — no prior-attempt residue to clear. |
| `eazybusiness` (source) | ONLINE, SIMPLE, ~**26.6 GB**, compat 170; schema `Robotico` **present (32 objs)**, `CustomWorkflows` (19 objs), `RoboticoEKL` present (excel_ekl). **grate journal `Robotico.ScriptsRun` ABSENT** (never baselined). `tVersion.cVersion = 2.0.5.0`. | Ebene A is deployed-but-not-journaled, and **behind the repo** (repo carries 38 `Robotico` objs vs 32 here — same gap as the Jul-08 prod backup, see e2e report §A2b). Adoption strategy: **normal deploy, not `--baseline`** (§b.2). |
| Data / log dir | `C:\Program Files\Microsoft SQL Server\MSSQL17.MSSQLSERVER\MSSQL\DATA` | **`ops.Config` E:\ defaults (`E:\work\…bak`, `E:\MSSQL\Data`) do not exist here.** Must repoint to C: before first reset (§b.5). |
| Disks | **only `C:`**, ~**103 GB free** | Enough for one clone (~26 GB) + one COPY_ONLY backup (~≤26 GB) ≈ 52 GB. No E: drive. |
| Leftover | `eazybusiness_e2e_r3_pre_snap` — a **database snapshot** (`.ss`) on `eazybusiness` | Sparse on disk, harmless to the clone/backup flow; **cleanup candidate**. Note: it is a snapshot, not a full DB. |
| **JTL Worker** | **RUNNING against test1**: `7 - JTL Worker JTL-Wawi C#` (sa, 3 sessions), `JTL.MessageBroker` (2), `50 - API`, `#Hidden#` workers; plus excel_ekl `node-mssql ekl_testmssql_app` (2) | **Hard gate.** The reset-validation runbook Step 0 requires the worker **fully stopped** (Windows service) before registering/resetting a mandant. **Must be stopped on the test1 host before §b.6/§b.7** — cannot be done from this Linux box. |

### Execution-mechanics finding (the gating one)

- **No native grate**: `dotnet` is not installed, `~/.dotnet` absent, `grate` not on PATH. deploy.ps1 would therefore fall back to its **Docker runner** (`erikbra/grate`).
- **The Docker runner cannot do Windows/Kerberos auth.** TEST uses integrated auth → grate connection string `Trusted_Connection=True`. Inside the `erikbra/grate` container there is **no Kerberos ticket** (not domain-joined, no ccache), so an integrated-auth deploy against test1 from the container **will fail to authenticate**. (No grate image is even cached locally right now.)
- **Only clean path from this Linux box:** install the **.NET runtime + grate as a global tool** so deploy.ps1 uses the **native** runner, which runs as `lukas` and authenticates via the existing Kerberos ticket — exactly as `sqlcmd -E` already does successfully. See §b.0 and the open question in §e.

---

## (b) Exact step sequence (every write, in order)

> Prerequisites unchanged from recon: valid Kerberos ticket (`klist` shows
> `lukas@ZDBIKES.LOCAL`); pwsh 7.6.2 present; sysadmin on test1.

### b.0 — Make grate runnable natively (system change, needs go-ahead)

```bash
# .NET (SDK or runtime ≥ 8) — e.g. via the dotnet-install script or apt/snap, then:
dotnet tool install --global grate
export PATH="$PATH:$HOME/.dotnet/tools"
grate --version            # confirm native runner is now detected
```

Verification that native grate authenticates via Kerberos before any real deploy:

```bash
# read-only DryRun proves the connection + auth path without changing anything:
pwsh db-migrations/deploy.ps1 -Scope eazybusiness -Environment TEST -DryRun
```

If the DryRun connects (grate logs the target and “would run …” lines), Kerberos
integrated auth through native grate works and we proceed. If it cannot connect,
STOP — do not fall back to the Docker runner (it cannot authenticate); escalate
(run the deploy from a domain Windows host instead).

### b.1 — Phase 0 gate (local, no server)

```bash
npm run db:lint          # pwsh db-migrations/tests/lint-migrations.ps1 — must exit 0
```

### b.2 — Ebene A adopt + reconcile on test1 `eazybusiness` — **normal deploy, NOT --baseline**

Rationale (deviates from the runbook’s literal “baseline test1” wording, on
purpose): test1 is **behind** the repo (32 vs 38 objects) and both `up/` scripts
are fully idempotent (`IF NOT EXISTS` / `MERGE WHEN NOT MATCHED`). A `--baseline`
here would **mask** the 6 missing objects (e2e report §A2). A **normal** deploy
instead:
- runs `up/0001`, `up/0002` as harmless no-ops (grate journals them, creating
  `Robotico.ScriptsRun`), then
- `CREATE OR ALTER`s all 25 anytime objects → reconciles test1 to the exact repo
  version against the real 2025 schema (a genuine reconcile test), with a correct
  journal and **no masking**.

```bash
# DryRun first (already done in b.0 as the auth check), then the real run:
npm run db:deploy:test          # deploy.ps1 -Scope eazybusiness -Environment TEST
```

Writes: creates `Robotico.ScriptsRun/Version/ScriptsRunErrors`; `CREATE OR ALTER`
of our own `Robotico.*` (12 fn + 6 sp) and `CustomWorkflows.sp*` (7) objects in the
**real** test1 `eazybusiness`. Scope is strictly our own objects — no `dbo`, no
`RoboticoEKL`.

Post-check: `npm run db:deploy:test -- -DryRun` reports “No sql run” (all journaled).

### b.3 — Ebene B global deploy on test1 (`RoboticoOps`) — greenfield

```bash
npm run db:deploy:test:global   # deploy.ps1 -Scope global -Environment TEST
```

The first `-Scope global` run auto-generates the cert password (tier 3, cert
absent), persists it to `~/.robotico-ops/grate-cert.env` (`GRATE_CERT_PASSWORD_TEST`,
`chmod 600`) and prints it **once**. **Copy that value into `~/.claude-secrets.md`
(JTL-Robotico → RoboticoOps cert password TEST).**

Writes performed by this scope (each idempotent, `IF NOT EXISTS`-guarded):
| Script | Write | Scope |
|---|---|---|
| (grate) | **CREATE DATABASE `RoboticoOps`** | instance |
| `0001` | settings, collation assert | RoboticoOps |
| `0002` | `ops` schema + `ops.Config/Mandant/ResetRequest/ResetStep` tables | RoboticoOps |
| `0003` | roles `ops_admin`, `ops_reset_executor` | RoboticoOps (DB-scoped) |
| `0010` | **server login `jobstartuser`** (disabled, DENY CONNECT SQL) + user in RoboticoOps + **user in msdb** (`SQLAgentOperatorRole` + `GRANT EXECUTE sp_start_job`) | **instance + msdb** |
| `0011` | **cert `RoboticoOpsSigning`** (priv key) in RoboticoOps; **public key copied into `master`**; **login `RoboticoOpsSigningLogin` FROM CERTIFICATE in `master`** + `GRANT AUTHENTICATE SERVER` | **instance + master** |
| `0020` | seed `ops.Config` (E:\ defaults — corrected in b.5) + template `ops.Mandant` rows tm2/tm3/tm4 (`ShopLicense` sentinel) | RoboticoOps |
| `0021` | seed 8 `ops.ResetStep` rows | RoboticoOps |
| `100_grants` | grants to the two roles | RoboticoOps |
| `200_ensure_agent_job` / `EnsureAgentJob` | **SQL Agent job `RoboticoOps - Testmandant Reset`** (owner sa) | **msdb** |
| `900_resign_procedures` | signs the 2 entry-point SPs with the cert | RoboticoOps |

### b.4 — Start SQL Server Agent on test1 (host action, Lukas)

Agent is **Stopped / Manual**. Start it (the reset job runs under the Agent):
`Start-Service SQLSERVERAGENT` on the test1 host (or SSMS). Confirm the job
`RoboticoOps - Testmandant Reset` exists and is enabled.

### b.5 — Repoint `ops.Config` to test1 reality (data UPDATE, admin session)

The E:\ defaults do not exist here (only C:). Against `RoboticoOps`:

```sql
UPDATE ops.Config SET ConfigValue = N'C:\Program Files\Microsoft SQL Server\MSSQL17.MSSQLSERVER\MSSQL\DATA\reset_clone.bak'
  WHERE ConfigKey = N'BackupFile';
UPDATE ops.Config SET ConfigValue = N'C:\Program Files\Microsoft SQL Server\MSSQL17.MSSQLSERVER\MSSQL\DATA'
  WHERE ConfigKey = N'TargetDataDir';
-- SourceDb=eazybusiness, ReferenceMandant=1 already correct.
```

(The clone step builds `TargetDataDir + '\' + file` — native Windows path here, no
separator worry.)

### b.6 — **Stop the JTL Worker on test1** (host action, Lukas) — HARD GATE

Before any mandant registration/reset touches the source `eazybusiness`
(`RegisterMandant` writes a `tMandant` row + `tBenutzerFirma` seed into the **real**
source — CQG-5 intended blast radius), the JTL Worker **Windows service** on
VM-SQL-TEST1 must be **fully stopped** (config-disable is not enough; runbook Step 0).
Optionally quiesce the excel_ekl `node-mssql` app too. Cannot be done from Linux.

### b.7 — tm9 reset rehearsal (throwaway mandant), as admin

Use a `-LoginName` that **exists on test1** (decision, §b below) so `GrantAccess`
has a real target — e.g. create a throwaway `dbuser_dev_test1` login first, or pass
`ZDBIKES\lukas`. Then:

```bash
npm run db:mandant:create -- -Environment TEST -MandantKey tm9 \
    -DisplayName "Reset validation" -LoginName "<existing-login>"
# registers ops.Mandant tm9 (TargetDb eazybusiness_tm9) AND kicks the first reset.
```

Writes: clone DB `eazybusiness_tm9` (~26 GB restore on C:), full 8-step reset
pipeline on the clone, and the `RegisterMandant` write into the **source**
`eazybusiness` (`tMandant` row + `tBenutzerFirma` seed for the new kMandant).

Poll to completion:

```bash
npm run db:mandant:list -- -Environment TEST     # or EXEC reset.GetResetStatus @MandantKey='tm9'
```

### b.8 — Validation test (the deliverable) + npm run

```bash
npm run db:validate:test          # structure + live-instance + roundtrip checks (read-only)
npm run db:validate:test -- -FullReset   # optional: drives a fresh tm9 reset then verifies it
```

Then commit the new test files (§f).

---

## (c) Instance-global / hard-to-reverse writes (call-outs)

These outlive a simple DB drop and warrant conscious confirmation:

1. **Server login `jobstartuser`** — instance-scope principal, disabled + DENY
   CONNECT SQL. Harmless but persists at server level.
2. **`master` writes (0011):** certificate `RoboticoOpsSigning` (public key) **in
   master** + **login `RoboticoOpsSigningLogin` FROM CERTIFICATE** with `AUTHENTICATE
   SERVER`. This is the cross-DB signing bridge; it is a server-level trust grant.
3. **SQL Agent job `RoboticoOps - Testmandant Reset`** (owner sa) in **msdb** — a
   sysadmin-owned job that runs `reset.ProcessNextResetRequest`.
4. **`msdb` grants** to `jobstartuser` (`SQLAgentOperatorRole`, `EXECUTE sp_start_job`).
5. **Cert password** is minted once and **immutable** (up/0011 is one-time). Losing it
   means dropping+recreating the cert via a new `up/` script. File it immediately.
6. **Ebene A `CREATE OR ALTER`** rewrites our own objects in the **real** test1
   `eazybusiness` (forward-only; not a destructive change, but it does modify live
   objects).
7. **`RegisterMandant` writes to the source `eazybusiness`** (`tMandant` +
   `tBenutzerFirma`) — the only reset write that leaves the clone and lands in the
   real source DB. This is why the worker-stop gate (b.6) matters.

Everything in `RoboticoOps` itself (DB, schemas, tables, roles, SPs, seeds) is
contained and dropped wholesale by dropping the DB.

---

## (d) Rollback / cleanup

```sql
-- 1. throwaway mandant + clone (after the rehearsal):
ALTER DATABASE [eazybusiness_tm9] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
DROP DATABASE [eazybusiness_tm9];
-- remove the source registration (manual, reviewed):
--   DELETE FROM dbo.tMandant WHERE cDB = 'eazybusiness_tm9';   (in eazybusiness)
--   plus the tBenutzerFirma rows seeded for that kMandant.

-- 2. Ebene B teardown (instance-global — do only for a full undo):
--   sp_delete_job 'RoboticoOps - Testmandant Reset'  (msdb)
DROP DATABASE [RoboticoOps];
DROP LOGIN [RoboticoOpsSigningLogin];      -- master
DROP CERTIFICATE [RoboticoOpsSigning];     -- master (public copy)
DROP LOGIN [jobstartuser];                 -- (msdb user drops with the login’s DB users)

-- 3. cert password store, if fully resetting:
--   remove the GRATE_CERT_PASSWORD_TEST line from ~/.robotico-ops/grate-cert.env
```

- **Ebene A** is additive/forward-only — no rollback; a bad object is fixed by a
  corrected file + redeploy.
- **Leftover snapshot** `eazybusiness_e2e_r3_pre_snap` can be dropped independently
  (`DROP DATABASE`), unrelated to this rollout.
- Stop the SQL Agent again if test1 should return to its Stopped/Manual baseline.

---

## (e) Risks + open questions

1. **[BLOCKER] grate execution auth.** Native grate is not installed; the Docker
   runner cannot Kerberos. → **Install .NET + `grate` global tool** (b.0) so the
   native runner authenticates via the existing ticket. This is a **system change**
   on the workstation — needs go-ahead. Fallback: run the deploys from a domain
   Windows host. **Do not** use the Docker runner against test1.
2. **[BLOCKER] JTL Worker is live on test1.** Must be stopped on the host (b.6)
   before b.7 — a host action only Lukas can do. Until then the reset rehearsal is
   gated.
3. **Dev login for `GrantAccess` (decision).** `dbuser_dev_dana_for_development` is
   absent on test1. For tm9, pass `-LoginName` with a login that exists on test1
   (create a throwaway `dbuser_dev_test1`, or use `ZDBIKES\lukas`). Recommendation:
   create a disposable `dbuser_dev_test1` SQL login so the grant path is genuinely
   exercised, drop it in cleanup.
4. **`ops.Config` E:\ → C:\ repoint (b.5) is mandatory** or the clone step fails
   (no E: drive). Data UPDATE, not a file edit.
5. **PAR-1 / VM-SQL2 (needs explicit approval).** up/0020 carries a TODO to confirm
   the exact prod dev-login name. This requires a **read-only** query against
   **production** (`vm-sql2`): `SELECT name FROM sys.server_principals WHERE name
   LIKE 'dbuser_dev%'`. Proposed as an isolated, read-only, approval-gated step —
   **not** part of the test1 critical path.
6. **Runbook doc drift (minor, fix in Phase 2).** Validation runbook §4.2 checks
   `SELECT nVersion FROM dbo.tVersion`; the real column is **`cVersion`** (value
   `2.0.5.0`). Correct the runbook while here.
7. **Reset duration.** test1 `eazybusiness` is the **full ~26 GB** (not the trimmed
   e2e DB), so clone restore + `AnonymizeCustomerData` will take **longer** than the
   ~7 min seen in the container. Budget 15–25 min for b.7.
8. **Cert-password one-time display.** Must be captured on the first global deploy;
   there is no second chance without dropping the cert.

---

## (f) Validation-test design

**Decision: a new, environment-agnostic `db-migrations/tests/validate-rollout.ps1`**
(not a retrofit of `validate.ps1`). Rationale (sustainable/SOLID): `validate.ps1`
has a single narrow job (quick SQL-auth check of the local container); bolting
`-Environment` onto it would muddy that. The new script **reuses `lib/targets.ps1`**
as the auth SSoT, so the **same** script validates TEST (Kerberos `-E`), E2E (SQL
auth) and later PROD, with no duplicated connection logic. `validate.ps1` stays as
the container quick-check.

**`validate-rollout.ps1` params:** `-Environment TEST|PROD|E2E` (default TEST),
`-FullReset` (switch), `-MandantKey tm9` (default), `-RightsTestLogin <name>`
(optional low-priv negative test), `-WhatIf`. Exit non-zero on any failed check;
one line per check (mirrors `validate_structure.sql`).

**Checks (all read-only unless `-FullReset`):**
1. Runs the existing `tests/global/validate_structure.sql` (objects, columns,
   signatures, roles) against `RoboticoOps`.
2. **New `tests/global/validate_rollout.sql`** — live-instance superset:
   - Ebene A journal `Robotico.ScriptsRun` present on `eazybusiness` with rows.
   - Ebene B journal `ops.ScriptsRun` present with rows.
   - `ops.ResetStep` = 8 enabled rows in `StepOrder` sequence.
   - both entry-point SPs signed by `RoboticoOpsSigning` (assert count = 2).
   - Agent job `RoboticoOps - Testmandant Reset` exists **and enabled** (`msdb`).
   - `master`: `RoboticoOpsSigningLogin` present with `AUTHENTICATE SERVER`;
     `jobstartuser` present, **disabled**, DENY CONNECT SQL.
3. **Roundtrip:** `EXEC reset.ListMandants` returns rows and exposes **no**
   `ShopLicense`/`ShopUrl`; `EXEC reset.GetResetStatus @MandantKey=<known>` returns
   a status.
4. **Rights negative test (optional):** if `-RightsTestLogin` is supplied, connect
   as that low-priv principal and assert a direct `SELECT ShopLicense FROM
   ops.Mandant` is **denied** (column DENY). Skipped with a printed note when no
   low-priv login is available (the pure-Kerberos-sysadmin case on test1) — the
   negative path is already proven in the container e2e (assertion 13); here it is
   opt-in.
5. **`-FullReset` (TC-M chain):** create a throwaway `tm9` via
   `reset.CreateTestmandant`, poll `GetResetStatus` to `succeeded`/`failed`, then run
   the runbook §4 **read-only** outcome checks against the clone (version
   `cVersion=2.0.5.0`; queues drained; credentials blanked; a customer-anonymisation
   spot-check; registration present), and print the cleanup SQL (§d). Does **not**
   auto-drop the clone (leaves it for inspection, like the runbook).

**npm surface (added to `package.json`):**
```jsonc
"db:validate":        "pwsh db-migrations/tests/validate-rollout.ps1",
"db:validate:test":   "pwsh db-migrations/tests/validate-rollout.ps1 -Environment TEST",
"db:validate:e2e":    "pwsh db-migrations/tests/validate-rollout.ps1 -Environment E2E"
```
(`-- -FullReset` opts into the reset roundtrip on any of them.)

Commit (normal concise English message, no `[Phase.Chunk]` prefix per the task):
the two new test files + the package.json entries.

---

## (g) Estimated duration

| Step | Estimate |
|---|---|
| b.0 install .NET + grate + DryRun auth check | 10–15 min |
| b.1 lint | < 1 min |
| b.2 Ebene A deploy (2 up + 25 anytime) | 1–2 min |
| b.3 Ebene B global deploy (greenfield) | 1–2 min |
| b.4 start Agent (host) | 1 min |
| b.5 ops.Config repoint | < 1 min |
| b.6 stop JTL Worker (host) | 2–5 min |
| b.7 tm9 create + full reset (26 GB, full anonymise) | 15–25 min |
| b.8 write + run validation test | 30–45 min (authoring) |
| **Total active** | **≈ 1.0–1.5 h** + host-coordination for worker/agent |

---

## Ready-to-run order (once approved)

`b.0 → b.1 → b.2 → b.3 → (b.4 host) → b.5 → (b.6 host: stop worker) → b.7 → b.8`.
Blockers to clear before b.7: native grate working (b.0), Agent started (b.4), JTL
Worker stopped (b.6), `-LoginName` decided (§e.3).
