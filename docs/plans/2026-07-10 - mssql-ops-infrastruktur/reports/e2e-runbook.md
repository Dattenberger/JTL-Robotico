# E2E-Runbook: mssql-ops-infrastruktur

**Plan:** [→ ../mssql-ops-infrastruktur.md](../mssql-ops-infrastruktur.md)
**Status:** ready (Phase-1 E2E-strategy output)
**Created:** 2026-07-10
**Mode-Distribution:** auto: 6, manual: 5

## Scope

Auto-verifiable layer of this plan is **static + read-only only** — the plan
forbids any write against a SQL server (hard constraint, state-file autonomy
mandate). The auto E2E therefore covers: the convention lint, PowerShell parse
checks, static security/reference review of the reset SQL, object/functionality
completeness mapping, ADR/doc-format checks, and read-only catalog probes against
`vm-sql-test1.zdbikes.local`. Everything that requires a grate deployment, a
RoboticoOps DB, a running Agent job, or a live reset (i.e. every behavior test
that writes) is **manual** and delegated to the §4 validation runbook
(`docs/runbooks/testmandant-reset-validierung.md`) plus the rollout runbook
(`docs/runbooks/rollout-mssql-ops.md`). The Mandanten-reset behavior itself is
never automated in this plan.

**Auto-scope recommendation: RUN** (six meaningful non-mutating cases).
**Write/deploy E2E: SKIP for auto** → manual runbook cases TC-M1…TC-M5.

## Relevant Knowledge

- `knowledge-sql` — SQL review methodology (dynamic-SQL safety, reference consistency)
- `knowledge-jtl-sql` — JTL-Wawi schema for interpreting the read-only probes
- `knowledge-adr-format` — mandatory ADR sections (TC-6)
- `knowledge-doc-format` — UDOC section check (TC-6)
- No runtime test harness exists in this repo (SQL-only); the lint tool
  `db-migrations/tests/lint-migrations.ps1` (produced by chunk C1) is the
  executable convention gate.

## Prerequisites

| # | Kind | Target | Check | Blocking |
|---|------|--------|-------|----------|
| 1 | tool-pwsh | PowerShell 7 | `command -v pwsh` (verified: /usr/bin/pwsh) | yes (lint + parse cases) |
| 2 | artifact-lint | lint tool exists | `test -f "db-migrations/tests/lint-migrations.ps1"` (produced by C1) | yes (auto gate) |
| 3 | tool-sqlcmd | mssql-tools18 | `ls /opt/mssql-tools*/bin/sqlcmd` (verified: mssql-tools18) | no (probes degrade to manual) |
| 4 | sqlcmd-readonly | vm-sql-test1.zdbikes.local | `/opt/mssql-tools18/bin/sqlcmd -S vm-sql-test1.zdbikes.local -E -C -Q "SELECT 1"` (verified 2026-07-10, Kerberos ticket) | no (read-only; unreachable ⇒ probe cases become manual, not a code failure) |
| 5 | isolation-guard | never prod (vm-sql2) | any sqlcmd in auto cases targets ONLY `vm-sql-test1`; grep the executed command line for `-S vm-sql-test1` | yes (prod protection) |

## User Questions (resolved before E2E — answered conservatively per autonomy mandate, user offline)

| Question | Options | Answer (conservative default) | Resolved |
|----------|---------|-------------------------------|----------|
| Should the §4 read-only probes actually be executed against `vm-sql-test1` during the auto E2E, or left manual? | (a) run read-only (SELECT/catalog only), (b) leave fully manual | **(a) run read-only** — probes are strictly non-mutating (SELECT/`sys.*`), the Kerberos read-only path is already verified, and results answer O1/O2/O4. On any connection error, degrade to manual instead of failing the run. | 2026-07-10 |
| Is any deploy/reset behavior test in scope for automation in this plan? | (a) yes, automate on test1, (b) manual only | **(b) manual only** — forced by the hard "no server writes" constraint. All deploy/reset E2E is manual (TC-M1…TC-M5), delegated to the §4/§5 runbooks. | 2026-07-10 |
| Should the auto run fail if probes cannot reach test1? | (a) fail, (b) degrade to manual | **(b) degrade to manual** — probe unreachability is an environment condition, not a code defect; the case is marked manual-pending, the run does not block. | 2026-07-10 |
| Which test1 database do the read-only probes target? | (a) test1 `eazybusiness`, (b) all `eazybusiness*` DBs | **catalog-wide read (all `eazybusiness*` on test1) but SELECT-only** — matches §4 probes 03/04 which inventory pf_user/queues across clones; strictly read, no clone created. | 2026-07-10 |

## Test Cases

### TC-1: Convention lint passes (central auto gate)

- **Mode:** auto
- **Knowledge:** knowledge-sql
- **Scope:** §1/§2/§3/§6 conventions across the whole migration tree
- **Steps:**
  1. `cd` into the worktree.
  2. `pwsh db-migrations/tests/lint-migrations.ps1`
  3. Assert exit code `0`.
- **Expected Result:** Exit 0. No `^USE\s`, no `GO;`, exactly one main object per anytime file with matching `Schema.Objekt.sql` name, `NNNN_` prefix on up-files, no forbidden EKL references (`spCMArtikel`, `spCMArtikelNeu`, `RoboticoEKL`), no `DROP SCHEMA`, no uncommented writes in `Berechtigungen/cleanup/*`, dynamic-SQL concat heuristic clean. Covers plan §1 Acceptance + §7 Verification #1 + §6 Acceptance.

### TC-2: PowerShell scripts parse cleanly (no server)

- **Mode:** auto
- **Knowledge:** —
- **Scope:** §1 deploy.ps1 + §7 lint tool syntactic validity
- **Steps:**
  1. For each of `db-migrations/deploy.ps1`, `db-migrations/tests/lint-migrations.ps1`:
     `pwsh -NoProfile -Command "$e=$null; [System.Management.Automation.Language.Parser]::ParseFile('<abs-path>',[ref]$null,[ref]$e); if($e){$e|%{Write-Error $_}; exit 1}"`
  2. Assert exit code `0` for both.
- **Expected Result:** Both parse with zero syntax errors. No server contacted. Covers §1 Acceptance (`deploy.ps1 -DryRun` syntactic validity, done as a pure parse — never a live run).

### TC-3: Reset SQL is injection-safe and target-guarded (static)

- **Mode:** auto
- **Knowledge:** knowledge-sql
- **Scope:** §3 security acceptance (dynamic SQL safety, eazybusiness guard)
- **Steps:**
  1. For every `db-migrations/global/sprocs/reset.internal_*.sql`: grep-review that dynamic SQL builds DB/object names only via `QUOTENAME(...)` and passes payload values only as `sp_executesql` parameters (flag any `+ @`-concatenation of a non-QUOTENAME variable inside an `EXEC`/`sp_executesql` string).
  2. Assert every `reset.internal_*.sql` and `reset.ProcessNextResetRequest.sql` contains an explicit guard rejecting `@TargetDb = 'eazybusiness'` (and the `eazybusiness[_]%` pattern check).
  3. Assert `reset.StartTestmandantReset.sql` carries `WITH EXECUTE AS 'jobstartuser'` and that `permissions/900_resign_procedures.sql` re-signs exactly the SPs declared with `EXECUTE AS`.
- **Expected Result:** No user-data concatenation into elevated dynamic SQL; triple `eazybusiness`-target guard present (CHECK + SP + job re-validation); signing/re-signing set consistent. Covers §3 Acceptance + §2 signing risks. (Overlaps the lint's heuristic (g) but is the authoritative manual-grade static review.)

### TC-4: Object & functionality completeness mapping (static)

- **Mode:** auto
- **Knowledge:** knowledge-jtl-sql
- **Scope:** §1/§3 completeness (Verification #2 + #3)
- **Steps:**
  1. Cross-check the C1 chunk-report mapping table: every object listed in `research/5-repo-inventar §3` resolves to exactly one file under `db-migrations/eazybusiness/{functions,sprocs,up}/`.
  2. Cross-check the C2 chunk-report mapping table: each of the 6 legacy reset scripts in `Projekte/Testsystem/` maps to one `reset.internal_*` proc (clear-customer-fields blockwise).
  3. Assert no orphan/duplicate target files (one object per anytime file) and no EKL-owned object names anywhere in the tree.
- **Expected Result:** Bijective source→target mapping, no gaps, no duplicates. Covers §7 Verification #2/#3.

### TC-5: Read-only probes against test1 (O1/O2/O4 evidence)

- **Mode:** auto (degrades to manual if test1 unreachable — see User Questions)
- **Knowledge:** knowledge-jtl-sql
- **Scope:** §4 read-only probes
- **Steps:**
  1. Preflight #4 green. For each `db-migrations/tests/probes/*.sql`:
     `/opt/mssql-tools18/bin/sqlcmd -S vm-sql-test1.zdbikes.local -E -C -i "<probe>.sql"` (strictly SELECT/catalog).
     Per-probe `-d` requirement: probe `01_worker_ttarget_semantics.sql` targets a single
     JTL DB and needs `-d eazybusiness` (without it, default `master` fails with Msg 208);
     probes `03`/`04` iterate all `eazybusiness*` DBs via a `sys.databases` cursor and need no `-d`.
  2. Confirm the executed command targets `-S vm-sql-test1` (Preflight #5 isolation guard) and that each probe contains no INSERT/UPDATE/DELETE/DDL.
  3. Capture output; record O1 (`nAbgleichstyp` semantics), O4 (`pf_user` presence in clones), queue inventory in the E2E report.
  4. `02_worker_discovery.md` is NOT run here (needs a running worker) → manual (TC-M4).
- **Expected Result:** Probes return rows without error, no mutation performed; O1/O2/O4 either answered or explicitly flagged "needs manual worker run". Covers §4 Acceptance + §7 Verification #4.

### TC-6: ADR and doc-format compliance (static)

- **Mode:** auto
- **Knowledge:** knowledge-adr-format, knowledge-doc-format
- **Scope:** §5 documentation deliverables
- **Steps:**
  1. Each of the three `adrs/adr-*.md` contains the mandatory knowledge-adr-format sections (Research, Context, Decision, Alternatives, Consequences, References, Decision History), a `# ADR-NNNN:` placeholder header, `Status: Proposed (plan-scoped — pending promotion)`, and a bidirectional `## References` link to this plan.
  2. `docs/SQL/MSSQL-OPS-ARCHITECTURE.md` follows UDOC (knowledge-doc-format) and is English.
  3. `docs/SQL/NAMING-CONVENTIONS.md` change is additive only (`git diff` shows insertions, no deletions of existing rows); `Projekte/Testsystem/setup-test-environment.ps1` diff touches only a comment banner (no functional line).
- **Expected Result:** All doc deliverables format-valid; edits provably additive/comment-only. Covers §5 Acceptance + §7 Verification #5.

---

### TC-M1: Baseline + Ebene-A deploy on test1 (manual)

- **Mode:** manual
- **Knowledge:** knowledge-sql
- **Scope:** grate deployment (writes) — out of auto scope
- **Steps:** Follow `docs/runbooks/migrations-baseline.md`: run `compare-objects.sql` (read-only) first, then `deploy.ps1 -Scope eazybusiness -Environment TEST -Baseline`, then a normal cycle. Verify grate journal `Robotico.ScriptsRun` populated.
- **Expected Result:** Baseline marks existing objects as run without re-executing; subsequent deploy is idempotent.

### TC-M2: Ebene-B (global) chain deploy on test1 (manual)

- **Mode:** manual
- **Knowledge:** knowledge-sql
- **Scope:** RoboticoOps DB, cert, roles, Agent job (writes)
- **Steps:** Per `docs/runbooks/rollout-mssql-ops.md` step 2: `deploy.ps1 -Scope global -Environment TEST` with `{{CertPassword}}` token; verify collation assert passes, cert public key in master, `RoboticoOps - Testmandant Reset` job exists (owner sa), SQL Agent service started.
- **Expected Result:** Global chain applies idempotently; signatures present on the EXECUTE-AS SPs.

### TC-M3: Full reset E2E on test1 (manual — the behavior test)

- **Mode:** manual
- **Knowledge:** knowledge-jtl-sql
- **Scope:** signed SP → Agent job → clone → neutralization → status (writes, minutes-long)
- **Steps:** Execute `docs/runbooks/testmandant-reset-validierung.md` end-to-end: seed a `tm9` registry row (the validation-mandant key used by that runbook), `EXEC reset.StartTestmandantReset`, poll `reset.GetResetStatus`, then verify clone content, credential invalidation, D9 worker neutralization (ebay_user/pf_user locked, queues empty), anonymization, grants, and rollback (drop clone).
- **Expected Result:** Status `succeeded`; clone neutralized per D9; `eazybusiness` never touched; StepLog complete.

### TC-M4: Worker discovery probe (manual — needs running worker)

- **Mode:** manual
- **Knowledge:** knowledge-jtl-sql
- **Scope:** §4 probe 02 (O2)
- **Steps:** Per `db-migrations/tests/probes/02_worker_discovery.md`: with the JTL worker service running on test1, insert a fresh tMandant entry and observe whether discovery is immediate or needs a restart.
- **Expected Result:** O2 answered (immediate vs. restart-triggered).

### TC-M5: Signature survival after re-deploy (manual)

- **Mode:** manual
- **Knowledge:** knowledge-sql
- **Scope:** §2 CREATE-OR-ALTER strips signatures → 900_resign heals
- **Steps:** After TC-M2, re-run `deploy.ps1 -Scope global -Environment TEST` (re-applies anytime sprocs) and query `sys.crypt_properties` for the EXECUTE-AS SPs.
- **Expected Result:** All signed SPs carry a valid signature after the same deploy run (900_resign heals in-run).

## Phase-4 Refresh (added by orchestrator)

Added by the Phase-4 E2E agent (2026-07-10) after reading the block audit +
repair-wave-1 reports. Repair wave 1 (commit `54f38fd`) fixed three convention/logic
findings by editing shipped SQL; the case below guards those fixes as a static
regression so a future re-port cannot silently reintroduce the defects.

### TC-R1: Repair-wave-1 fixes are still in place (static regression)

- **Mode:** auto
- **Knowledge:** knowledge-sql
- **Scope:** regression guard for `validated-findings.md` convention-B1-2 / logic-B1-1 / logic-B1-2
- **Steps:**
  1. Assert every proc under `db-migrations/{eazybusiness,global}/sprocs/*.sql` contains
     `SET NOCOUNT ON` (convention-B1-2 — the five PayPal procs were the gap).
  2. Assert `grep -rniE "returnCode" db-migrations/eazybusiness/sprocs/` returns nothing
     (logic-B1-1 — the unreachable `RETURN -1` contract and its dead caller guards were removed).
  3. Assert `CustomWorkflows.spArticleAppendLabelHistory.sql` runs each label through
     `Robotico.fnEscapedCSVSanitize(...)` on the write side (logic-B1-2 — `;`/CR/LF sanitisation).
- **Expected Result:** All three assertions hold. Covers the repair-wave-1 delta on top of §1/§6.

## Acceptance

- All `mode: auto` cases (TC-1…TC-6) pass; TC-5 may be marked manual-pending if
  test1 is unreachable (not a failure).
- All `mode: manual` cases (TC-M1…TC-M5) are confirmed by the user during the
  rollout/validation runbooks — not gating the automated plan run.
- No write of any kind was issued against any SQL server by an auto case
  (Preflight #5 isolation guard holds; only `-S vm-sql-test1` read-only sqlcmd).

## Failure Routing

On an auto-case failure: orchestrator starts issue-triage analogous to
block-closeout (research → repair-chunk → re-test). After 3 iterations without
convergence: `AskUserQuestion` escalation. Manual cases route to the user via
the runbooks, never into the automated repair loop.

## How to use this file

The Phase-4 E2E agent runs TC-1…TC-6 (auto) directly and records TC-5 probe
output. TC-M1…TC-M5 are handed to the user through the §4/§5 runbooks. Phase-4
appends repair-related cases under "Phase-4 Refresh".
