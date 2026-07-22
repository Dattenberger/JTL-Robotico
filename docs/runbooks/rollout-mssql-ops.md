# Runbook — Roll out the MSSQL ops infrastructure (test → prod)

The end-to-end rollout order for the whole `db-migrations/` stack: baseline the existing
databases, stand up `RoboticoOps` on test, prove the reset on test, then gate the same
onto prod, and finally retire the old PowerShell path. Each phase points at the focused
runbook that owns its detail — this file is the **spine**.

> [!CAUTION]
> Every prod step here changes production and is **human-gated**. Nothing in this repo
> deploys autonomously. `deploy.ps1 -Environment PROD` prompts for interactive Y/N and
> lists the exact target DBs first — read that list before you type `Y`.

- **Applies to:** first full rollout of the plan `2026-07-10 - mssql-ops-infrastruktur`.
- **Actors:** Lukas (admin/deployer). Colleagues only ever call the reset SPs.
- **Prerequisites:** grate on `PATH` (`dotnet tool install --global grate`) — or Docker,
  to which `deploy.ps1` falls back automatically (`erikbra/grate` image); Windows auth
  to both servers; the certificate password available to `deploy.ps1` (never stored in
  git — `~/.claude-secrets.md`, plan O5; resolution model in Phase 2).
- **References:** [`db-migrations/README.md`](../../db-migrations/README.md),
  [architecture doc](../SQL/MSSQL-OPS-ARCHITECTURE.md), runbook index
  [`README.md`](README.md).

---

## Phase 0 — Gate before you start

```bash
pwsh db-migrations/tests/lint-migrations.ps1     # must exit 0
```

A failing lint means the tree is not deployable. Fix first. Confirm the two servers and
their DB lists in `db-migrations/targets.config.json` are current (test1 = SQL 2025,
prod = SQL 2022 — restore is old→new only; promotion is script-only).

## Phase 1 — Baseline Ebene A (prod + test1)

Adopt the already-deployed `Robotico.*` / `CustomWorkflows.*` objects into the grate
journal **without re-running them**. Full procedure, incl. the mandatory file-vs-deployed
pre-check:

➡ [`migrations-baseline.md`](migrations-baseline.md)

Order: baseline prod `eazybusiness` first (the clone source), then test1's `eazybusiness`.
Do **not** baseline a mandant clone you can simply re-clone later.

> [!WARNING]
> Baseline asserts "file == deployed". If Step 2 of the baseline runbook shows drift,
> reconcile the files to the deployed truth **before** baselining — a wrong baseline hides
> a real difference and a future clone would carry the wrong definition. Note that
> `--baseline` also journals the **anytime** scripts, so a behind-the-repo estate is
> masked (a later normal deploy will not re-apply them) — see the baseline runbook's
> "grate `--baseline` baselines the anytime scripts too" warning and the E2E evidence
> (`reports/qg2/e2e-docker-report.md` §A2: the prod backup was 7 objects behind). If in
> doubt, run a normal (non-`-Baseline`) deploy, which reconciles via `CREATE OR ALTER`.

## Phase 2 — Deploy the global chain on test1

Stand up `RoboticoOps` (Ebene B) on the safe instance first:

```powershell
pwsh db-migrations/deploy.ps1 -Scope global -Environment TEST
```

grate creates `RoboticoOps` if absent; `0001` asserts collation
`Latin1_General_CI_AS` and fails hard on mismatch (fix per its message before retrying).

**Certificate password — there is NO interactive prompt.** `deploy.ps1` resolves the
`{{CertPassword}}` token in three tiers (full detail: `db-migrations/README.md` §7):

1. `$env:GRATE_CERT_PASSWORD` — explicit session override;
2. the persisted per-environment store (`GRATE_CERT_PASSWORD_TEST` — a Windows *User*
   env var, or `~/.robotico-ops/grate-cert.env` on Linux/macOS);
3. auto-generate (CSPRNG) + persist — **only** when the target instance has no
   `RoboticoOpsSigning` certificate yet. If the cert exists but no password is known, or
   the safety probe cannot reach the server, the deploy **aborts** with instructions
   instead of minting a value that could never unlock the existing private key.

Then make sure the SQL-Agent service is running on test1 (Survey found it stopped) — the
agent job needs it.

> [!IMPORTANT]
> **Backup plan: add RoboticoOps LOG backups.** `up/0001` puts `RoboticoOps` on
> `RECOVERY FULL` (point-in-time recovery for the ops metadata). FULL **without log
> backups is strictly worse than SIMPLE** — the transaction log grows unbounded. As part
> of this phase, add `RoboticoOps` to the instance backup plan with regular **LOG**
> backups (on top of the usual FULL/DIFF). This applies to `RoboticoOps` only; the
> throwaway `eazybusiness_tmN` clones are deliberately switched to SIMPLE by the reset
> pipeline (`spInternal_CloneDatabase`) and stay that way.

## Phase 3 — Validate the reset end-to-end on test1

Prove `spPub_StartTestmandantReset` → agent job → `spInternal_*` pipeline → `spPub_GetResetStatus`
works before prod ever sees it. The worker on test1 has no live credentials, so a mistake
cannot reach real customers:

➡ [`testmandant-reset-validierung.md`](testmandant-reset-validierung.md)

Do not proceed to Phase 4 until the validation runbook's checks all pass (status
`succeeded`, clone neutralised, customer data anonymised).

## Phase 4 — Deploy the global chain on prod (human gate)

Only after Phase 3 is green.

### Phase 4a — remove the old Ola install (BEFORE the deploy)

The global chain now also carries the maintenance suite (plan
`2026-07-21 - mssql-wartung-ola` §3.6): the Phase-4 deploy creates the six
`RoboticoOps - Maint - *` agent jobs **immediately enabled and scheduled**. The broken
legacy Ola install in `eazybusiness.dbo` must therefore be removed **before** the
deploy — otherwise two IndexOptimize jobs run against different object sets (ADR-A
failure mode). Manual runbook step, not a migration (`dbo` is never touched by a
migration).

This cleanup covers **both instances in the same step** — prod (`vm-sql2`) and the test
instance (`vm-sql-test1`). Rationale: prod is the source of every test1 re-seed, so a
restore drags the legacy remnants back onto test1. Cleaning only one instance means the
next re-seed re-imports the remnants; only cleaning both together is robust
(Research: `docs/plans/2026-07-21 - mssql-wartung-ola/reports/followup-R1-legacy-ola-test1.md`).

**On prod (`vm-sql2`) — 11 legacy Ola jobs + `eazybusiness.dbo` remnants:**

1. Inventory: confirm the Ola objects in `eazybusiness.dbo` and the 11 legacy Ola jobs
   (query `sys.objects` for `CommandLog`/`CommandExecute`/`DatabaseIntegrityCheck`/
   `IndexOptimize`/`DatabaseBackup`; `msdb.dbo.sysjobs` for the old job names).
2. **Archive the old CommandLog before dropping** (D39 — 9,218 rows, the only primary
   evidence of the 2025-11-27 failure pattern and the last real maintenance runs):
   `SELECT * INTO RoboticoOps.dbo.CommandLog_legacy_eazybusiness FROM eazybusiness.dbo.CommandLog;`
3. Delete the 11 legacy Ola jobs; drop `CommandLog`, `CommandExecute`,
   `DatabaseIntegrityCheck` and any remains of `IndexOptimize`/`DatabaseBackup` and Ola
   tables from `eazybusiness.dbo`. No coverage is lost: the old jobs have been
   ineffective since ~2025-11 (IndexOptimize failing nightly, last CHECKDB 2024).

**On test1 (`vm-sql-test1`) — only 3 DB objects, no msdb jobs:**

test1 carries **no** legacy Ola agent jobs — only three orphaned DB objects, and they are
already functionally broken (`dbo.CommandExecute` is missing, so nothing can invoke them):

4. **Archive test1's CommandLog before dropping** (D39, same pattern — `dbo.CommandLog`
   holds 9,218 rows):
   `SELECT * INTO RoboticoOps.dbo.CommandLog_legacy_eazybusiness FROM eazybusiness.dbo.CommandLog;`
   (run against the test1 instance's own RoboticoOps).
5. Drop the three objects from `eazybusiness.dbo`: `CommandLog`, `DatabaseBackup`,
   `DatabaseIntegrityCheck`. No msdb jobs to delete. Leave the separate
   `eazybusiness.DBA.spOla*` group (2026-06-13) untouched — it is a different install and
   out of scope here.

Preconditions: the RoboticoOps prod cutover itself (this runbook's Phases 1–3); the
foreign prod DBs stay deliberately in the active maintenance scope (D40 — no exclusion
expressions).

> [!CAUTION]
> **Order is binding (D26):** Phase 4a runs before the Phase-4 deploy, and Phase 4a
> through the maintenance verification below are executed **outside the 00:30–03:00
> window**, so the alert path and verification are provably complete BEFORE the first
> scheduled run (e.g. a deploy Sun 00:45 would meet checkdb at 01:00 unverified).
> The instance switch `MaintenanceSchedulesEnabled` stays **unset on prod** (= enabled;
> a forgotten `'0'` would silently kill maintenance). "Deploy disabled → verify →
> delete switch + `EXEC maint.spEnsureMaintenanceJobs`" is a documented emergency
> lever, not the standard path.

```powershell
pwsh db-migrations/deploy.ps1 -Scope global -Environment PROD
```

> [!CAUTION]
> `-Environment PROD` prompts Y/N and lists targets. Confirm the server is
> `vm-sql2.zdbikes.local` and the scope is `RoboticoOps` only. Confirm the SQL-Agent
> service is running on prod.
>
> **Certificate password:** same three-tier resolution as Phase 2 — no prompt. On the
> **first** PROD global deploy the instance has no `RoboticoOpsSigning` cert yet, so tier 3
> auto-generates a fresh password, persists it under `GRATE_CERT_PASSWORD_PROD`, and shows
> it **once** — file it in the password manager / `~/.claude-secrets.md` immediately (the
> private key is otherwise unrecoverable; rotation means drop + recreate the cert via a new
> `up/` script). Also repeat the Phase-2 backup-plan step: add prod's `RoboticoOps` LOG
> backups — **this LOG-backup activation also ends the hourly `backup-watchdog` alarm for
> RoboticoOps** (until it happens, the watchdog fires hourly for RoboticoOps — that alarm
> IS the detector for the missing coverage; finish this on the cutover day itself).
> While there, **re-verify CBB coverage of the system DBs** (D37/D41): newest
> non-copy-only full per `msdb`/`master` in `msdb.dbo.backupset` — verified healthy
> 2026-07-22; if it diverged, reopen plan §5 Gap 6 before proceeding.

### Phase 4b — maintenance go-live (after the deploy)

The deploy created the maintenance jobs (Phase 4a made that collision-free). Now, still
outside the 00:30–03:00 window:

1. **Restart the SQL Agent once**, so the freshly assigned Database-Mail profile
   (`permissions/260`) takes effect in the alert system — no alarm test counts before
   that. **Guard:** verify no agent job is currently running (the restart kills running
   jobs, and the agent is shared with the reset infrastructure — check
   `reset.spPub_GetResetStatus` / `msdb.dbo.sysjobactivity`).
2. **Verify** (pure checks — the jobs exist since the deploy): schedules correct; each
   job's single step is the constant, fully qualified dispatch
   `EXECUTE RoboticoOps.maint.spRunMaintenanceJob @cJobKey = …` (D28); operator wiring on
   every `bNotifyOnFail=1` job (260 pulled it in after operator creation);
   `MaintenanceSchedulesEnabled` NOT set on prod (jobs enabled, D34). Easiest:
   `sqlcmd … -i db-migrations/tests/global/validate_rollout.sql`.
3. **Raise the agent job-history limit (D38):** the default (1,000 rows total / 100 per
   job) rolls `sysjobhistory` far before the declared 365-day retention —
   `EXEC msdb.dbo.sp_set_sqlagent_properties @jobhistory_max_rows = 10000, @jobhistory_max_rows_per_job = 1000;`
   (instance state, admin-owned — not a migration). Only then is the
   `cleanup-jobhistory` retention the real one.
4. **Watch the first night run — and measure runtimes:** CHECKDB (Sun/Wed 01:00) and
   IndexOptimize (02:00) must really finish before the 03:00 full; the staggering is
   asserted by start time, not enforced — on overlap, adjust times in the registry
   (git + deploy). **Alert-path acceptance via the natural alarm:** as long as
   RoboticoOps is not yet in CBB, the hourly `backup-watchdog` stale mail (THROW 51100 →
   operator) MUST really arrive at `lukas@dattenberger.com` within an hour of the agent
   restart — the side-effect-free proof the reporting path works; no artificial job
   failure on prod needed. Watch for false alarms in the 03:00-full window: if CBB
   serializes log backups during the big eazybusiness full, the hourly log check can
   slip just over the 1-h threshold — then adjust `nLogMaxHours` to 2 (repo-owned, one
   deploy).

> [!NOTE]
> **Database-Mail health is unmonitored for now** — if Database Mail fails, maintenance
> and watchdog alarms fall silent together (owner: follow-up task in the parent
> mssql-ops program).

**Rollback/abort (maintenance part):** if a new job stays red after cutover, no
teardown is needed — no coverage is lost (the old state was ineffective anyway); a
faulty sync/step is healed by a corrected deploy (registry + procs idempotent); manual
CHECKDB / statistics updates remain the stopgap. If the Phase-4 deploy aborts AFTER
Phase 4a already removed the old install: likewise no teardown — fix the deploy cause
(cert password, reachability — see the Phase-4 CAUTION) and rerun; until then the
manual stopgap applies.

> [!WARNING]
> Do not run a global deploy while a test-mandant reset is queued or running: if
> `reset.spEnsureAgentJob.sql` changed, its drop/recreate would cancel the running agent
> job mid-clone. The script guards this itself (it THROWs when `ops.tResetRequest` has a
> `queued`/`running` row) — if the deploy fails with that message, wait for the reset to
> finish (check `reset.spPub_GetResetStatus`) and rerun. If the blocking `running` row
> belongs to a **dead** job run (nothing actually executing), do not wait for the
> `StaleRunningHours` reclaim — run `EXEC reset.spPub_CancelResetRequest @RequestId = <id>;`
> (it refuses while the job really runs; see
> [`testmandant-reset-validierung.md`](testmandant-reset-validierung.md) §Failure modes).

## Phase 5 — Seed real keys (never via git)

The Ebene-B seed shipped `ops.tMandant` rows with a `'<SET-VIA-RUNBOOK>'` sentinel for
`cShopLicense`. Set the real per-mandant keys **in place**, in a reviewed session:

```sql
-- RoboticoOps, admin session. One UPDATE per mandant. Keys from ~/.claude-secrets.md.
UPDATE ops.tMandant SET cShopLicense = N'<real-key>' WHERE cMandantKey = N'tm4';
```

Verify `ops.tConfig` paths (`BackupFile`, `TargetDataDir`, `SourceDb`, `ReferenceMandant`)
match prod reality. No real key ever enters a committed file.

## Phase 6 — First prod reset (tm4)

Run one real reset through the new path and watch it:

```sql
EXEC RoboticoOps.reset.spPub_StartTestmandantReset @MandantKey = N'tm4';
-- poll:
EXEC RoboticoOps.reset.spPub_GetResetStatus @MandantKey = N'tm4';
```

Confirm `cStatus` walks `queued → running → succeeded`, `cStepLog` shows all eight steps,
and the clone is neutralised (spot-check per the validation runbook's checks). If it ends
`failed`, the clone is left as-is for diagnosis and `cErrorMessage`/`cStepLog` say where.

## Phase 7 — Retire the PowerShell path (D12)

Only after Phase 6 succeeds and you trust the new path:

- The old scripts under `Projekte/Testsystem/` and `WorkflowProcedures/` already carry
  deprecation banners and READMEs (they stayed functional as a fallback throughout).
- Physical removal/archival is a **separate, conscious** step — do it once the new reset
  has run cleanly for real mandants. Until then, the fallback stays.

The hygiene findings (Dana sysadmin, tm2 backlog, `eazybusiness_premig`) are **not** part
of this rollout — they are handled separately and manually:

➡ [`hygiene-findings.md`](hygiene-findings.md)

---

## Rollback

- **Ebene A:** grate is additive; a bad anytime object is fixed by a corrected file +
  redeploy (never edit an applied `up/`). No destructive rollback needed.
- **Ebene B on prod (Phase 4):** if the global deploy misbehaves, the objects are
  idempotent and inspectable; a failed reset never touches prod `eazybusiness` (it only
  writes the clone). The old PowerShell reset remains available until Phase 7.
- **A stuck reset:** a `running` row older than `ops.tConfig('StaleRunningHours')` (default
  4h) is auto-reclaimed as `failed` on the job's next start; inspect with `spPub_GetResetStatus`.
  To recover sooner without server rights, a colleague runs
  `EXEC reset.spPub_CancelResetRequest @RequestId = <id>;` — it cancels a `queued` request and
  force-reclaims a `running` one only when the job is not actually executing (OPS-2).
