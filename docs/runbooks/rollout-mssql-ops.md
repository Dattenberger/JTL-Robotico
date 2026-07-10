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
- **Prerequisites:** grate on `PATH` (`dotnet tool install --global grate`); Windows auth
  to both servers; the certificate password ready to enter (never stored in git —
  `~/.claude-secrets.md`, plan O5).
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
> a real difference and a future clone would carry the wrong definition.

## Phase 2 — Deploy the global chain on test1

Stand up `RoboticoOps` (Ebene B) on the safe instance first:

```powershell
pwsh db-migrations/deploy.ps1 -Scope global -Environment TEST
```

grate creates `RoboticoOps` if absent; `0001` asserts collation
`Latin1_General_CI_AS` and fails hard on mismatch (fix per its message before retrying).
You will be prompted for the certificate password (`{{CertPassword}}` →
`Read-Host -AsSecureString` or `GRATE_CERT_PASSWORD`). Then make sure the SQL-Agent
service is running on test1 (Survey found it stopped) — the agent job needs it.

## Phase 3 — Validate the reset end-to-end on test1

Prove `StartTestmandantReset` → agent job → `internal_*` pipeline → `GetResetStatus`
works before prod ever sees it. The worker on test1 has no live credentials, so a mistake
cannot reach real customers:

➡ [`testmandant-reset-validierung.md`](testmandant-reset-validierung.md)

Do not proceed to Phase 4 until the validation runbook's checks all pass (status
`succeeded`, clone neutralised, customer data anonymised).

## Phase 4 — Deploy the global chain on prod (human gate)

Only after Phase 3 is green:

```powershell
pwsh db-migrations/deploy.ps1 -Scope global -Environment PROD
```

> [!CAUTION]
> `-Environment PROD` prompts Y/N and lists targets. Confirm the server is
> `vm-sql2.zdbikes.local` and the scope is `RoboticoOps` only. Enter the certificate
> password when prompted. Confirm the SQL-Agent service is running on prod.

## Phase 5 — Seed real keys (never via git)

The Ebene-B seed shipped `ops.Mandant` rows with a `'<SET-VIA-RUNBOOK>'` sentinel for
`ShopLicense`. Set the real per-mandant keys **in place**, in a reviewed session:

```sql
-- RoboticoOps, admin session. One UPDATE per mandant. Keys from ~/.claude-secrets.md.
UPDATE ops.Mandant SET ShopLicense = N'<real-key>' WHERE MandantKey = N'tm4';
```

Verify `ops.Config` paths (`BackupFile`, `TargetDataDir`, `SourceDb`, `ReferenceMandant`)
match prod reality. No real key ever enters a committed file.

## Phase 6 — First prod reset (tm4)

Run one real reset through the new path and watch it:

```sql
EXEC RoboticoOps.reset.StartTestmandantReset @MandantKey = N'tm4';
-- poll:
EXEC RoboticoOps.reset.GetResetStatus @MandantKey = N'tm4';
```

Confirm `Status` walks `queued → running → succeeded`, `StepLog` shows all eight steps,
and the clone is neutralised (spot-check per the validation runbook's checks). If it ends
`failed`, the clone is left as-is for diagnosis and `ErrorText`/`StepLog` say where.

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
- **A stuck reset:** a `running` row older than 4h is auto-reclaimed as `failed` on the
  job's next start; inspect with `GetResetStatus`.
