# E2E Test Report — mssql-ops-infrastruktur

**Runbook:** [→ e2e-runbook.md](./e2e-runbook.md)
**Executed:** 2026-07-10T02:45:00+02:00
**Executor:** Phase-4 E2E agent (implement-long-plan-v3)
**Constraint honoured:** no writes against any SQL server — only read-only sqlcmd
(`-E -C`) against `vm-sql-test1.zdbikes.local`; isolation guard #5 held (every
sqlcmd command line targeted `-S vm-sql-test1`, never prod `vm-sql2`).

## Summary

| Bucket | Count | Result |
|---|---|---|
| Auto cases (TC-1…TC-6) | 6 | **6 pass** |
| Refresh case (TC-R1) | 1 | **1 pass** |
| Manual cases (TC-M1…TC-M5) | 5 | forwarded to user (not executed — write/deploy) |
| Blocking issues | 0 | — |
| Non-blocking issues | 1 | Nice-to-have runbook-doc nuance (TC-5 probe-01 invocation) |

All automated behaviour that can be verified without a server write is green. The
plan's write/deploy/reset behaviour (grate deploy, RoboticoOps DB, Agent job, live
clone+neutralisation) is manual by design and delegated to the §4/§5 runbooks.

## Pre-flight

| # | Check | Result |
|---|---|---|
| 1 | `command -v pwsh` | pass (`/usr/bin/pwsh`) |
| 2 | `test -f db-migrations/tests/lint-migrations.ps1` | pass (produced by C1) |
| 3 | `ls /opt/mssql-tools*/bin/sqlcmd` | pass (mssql-tools18) |
| 4 | read-only `SELECT 1` on vm-sql-test1 | pass (Kerberos, `VM-SQL-TEST1`, SQL 17.0.1000.7) |
| 5 | isolation guard (only `-S vm-sql-test1`) | enforced throughout |

## Auto case results

### TC-1 — Convention lint passes → **pass**
`pwsh db-migrations/tests/lint-migrations.ps1` → **exit 0**, 47 files scanned, 0 errors,
10 warnings. All 10 warnings are rule (g) dynamic-SQL heuristics on the `reset.internal_*`
procs (`CloneDatabase`, `GrantAccess`, `RegisterMandant`) — pre-existing, documented, and
confirmed safe in TC-3 (object/DB names go through `QUOTENAME`, values through
`sp_executesql` params). No `USE`, no `GO;`, no forbidden EKL refs, no `DROP SCHEMA`.

### TC-2 — PowerShell scripts parse cleanly → **pass**
`deploy.ps1` and `lint-migrations.ps1` both `ParseFile` with zero syntax errors (exit 0).
No server contacted (pure AST parse).

### TC-3 — Reset SQL injection-safe and target-guarded → **pass**
- Dynamic SQL: DB/object names only via `QUOTENAME(...)`; payload values only as
  `sp_executesql` parameters. Verified in `CloneDatabase` (BACKUP/RESTORE with `@bf`,
  `@df/@lf` as params), `GrantAccess` (`QUOTENAME(@TargetDb).sys.sp_executesql`, login
  names via `QUOTENAME(@ln)`), `RegisterMandant` (all cross-DB reads/writes via
  `sp_executesql` with typed params). No user-data concatenation into elevated dynamic SQL.
- Triple `eazybusiness` guard present: all 8 `reset.internal_*` procs **and**
  `reset.ProcessNextResetRequest` **and** `reset.StartTestmandantReset` carry
  `IF @TargetDb = N'eazybusiness' OR @TargetDb NOT LIKE N'eazybusiness[_]%'`.
- Signing consistent: `StartTestmandantReset` is the sole `WITH EXECUTE AS 'jobstartuser'`
  proc; `permissions/900_resign_procedures.sql` re-signs exactly that one proc with cert
  `RoboticoOpsSigning` (idempotent, checks `sys.crypt_properties` first).

### TC-4 — Object & functionality completeness mapping → **pass**
All 36 anytime SQL objects (12 `Robotico.fn*`, 13 `eazybusiness` sprocs, 11 `reset.*`
global sprocs) map bijectively: exactly one `CREATE OR ALTER` per file and the object
name equals the `Schema.Object.sql` filename in every case — no orphans, no duplicates,
no EKL-owned object names created. Consistent with the plan-and-api audit's independent
source→target confirmation against `research/5-repo-inventar §3` and the 6 legacy
`Projekte/Testsystem/` reset scripts.

### TC-5 — Read-only probes against test1 (O1/O2/O4) → **pass**
Executed against `vm-sql-test1` (read-only; probes 03/04 only write to session-local
tempdb temp tables, never to real data):
- **Probe 01** (`-d eazybusiness`, per its own header): `Worker.tTarget` = 10 rows, all
  `kMandant=1`, `nAbgleichstyp ∈ {0,2,3,4,5,7,8,13,17,18}`, `kZiel=1` for type 0 else `-1`
  — matches the recorded prod survey. `Sync.tSyncType` is **empty** ⇒ **O1 confirmed**: no
  DB-side sync-type lookup exists, so D9 (leave `Worker.tTarget` untouched, neutralise at
  account/shop level) holds.
- **Probe 03** (`pf_user` in clones): `pf_user` table present in both `eazybusiness` and
  `eazybusiness_e2e_r3_pre_snap`, **0 rows** in each ⇒ **O4 partial** (table exists,
  empty on test1; prod `tm*` clones need the manual run to populate/verify locking).
- **Probe 04** (queue inventory): full queue inventory returned for `eazybusiness` (e.g.
  `dbo.tQueue`≈9765, `ebay_usermessagequeue`≈1469, `tWorkflowQueue`≈1209) and the e2e clone;
  no error. Confirms the queue set the reset's `NeutralizeWorker` step must clear.
- **O2** (worker discovery) remains **manual** (TC-M4 — needs a running worker).

### TC-6 — ADR and doc-format compliance → **pass**
- All 3 plan-scoped ADRs (`adr-grate-migration-runner`, `adr-two-chain-migration-paths`,
  `adr-module-signing-reset`) carry the `# ADR-NNNN:` placeholder header,
  `Status: Proposed (plan-scoped — pending promotion)`, all 7 mandatory knowledge-adr-format
  sections (Research/Context/Decision/Alternatives/Consequences/References/Decision History),
  and a bidirectional plan link.
- `docs/SQL/MSSQL-OPS-ARCHITECTURE.md` present, English, UDOC frontmatter + GitHub alerts.
- `docs/SQL/NAMING-CONVENTIONS.md` edit provably additive: `git diff 9592c99..HEAD` = **96
  insertions, 0 deletions**.
- `Projekte/Testsystem/setup-test-environment.ps1` edit = **17 insertions, 0 deletions**,
  all a DEPRECATED comment banner (0 functional lines changed; "logic below is unchanged").

### TC-R1 — Repair-wave-1 fixes still in place (refresh regression) → **pass**
- `SET NOCOUNT ON` present in every `{eazybusiness,global}/sprocs/*.sql` (the 5 PayPal procs
  that convention-B1-2 flagged now have it).
- Zero `returnCode` references remain under `eazybusiness/sprocs/` (logic-B1-1 dead-code
  removal held).
- `spArticleAppendLabelHistory` runs each label through `Robotico.fnEscapedCSVSanitize(...)`
  on the write side (logic-B1-2 sanitisation held).

## Issues

| ID | Severity | Case | Description |
|---|---|---|---|
| E2E-1 | Nice-to-have | TC-5 | Runbook TC-5 step 1 gives a generic probe command `sqlcmd … -i "<probe>.sql"` without `-d`. Probe `01_worker_ttarget_semantics.sql` targets a single JTL DB and, per its own header (lines 10–15), requires `-d eazybusiness`; run without it (default `master`) it fails `Msg 208 Invalid object name 'Worker.tTarget'`. Probes 03/04 iterate `eazybusiness*` via a `sys.databases` cursor and need no `-d`. Self-corrected during execution (re-ran probe 01 with `-d eazybusiness`, passed). Doc nuance only — no plan-deliverable defect. Fix: note the per-probe `-d` requirement in runbook TC-5 (or the §4 validation runbook). Files: `docs/plans/2026-07-10 - mssql-ops-infrastruktur/reports/e2e-runbook.md`. |

## Manual cases (forwarded to user — not executed)

TC-M1…TC-M5 require SQL-server writes / deploys / a running worker and are handled through
the rollout + validation runbooks, not the automated run:

- **TC-M1** — Baseline + Ebene-A deploy on test1 (`docs/runbooks/migrations-baseline.md`).
- **TC-M2** — Ebene-B (global) chain deploy on test1 (`docs/runbooks/rollout-mssql-ops.md`).
- **TC-M3** — Full reset E2E on test1, the behaviour test
  (`docs/runbooks/testmandant-reset-validierung.md`).
- **TC-M4** — Worker discovery probe (needs a running JTL worker; answers O2).
- **TC-M5** — Signature survival after a re-deploy (`sys.crypt_properties` after re-run).

## Acceptance verdict

All `mode: auto` cases (TC-1…TC-6) pass; TC-5 probes reached test1 (no manual-pending
degrade needed). Refresh TC-R1 passes. No write of any kind was issued against any SQL
server. Manual TC-M1…TC-M5 remain for the user via the runbooks. **Auto E2E: GREEN.**
