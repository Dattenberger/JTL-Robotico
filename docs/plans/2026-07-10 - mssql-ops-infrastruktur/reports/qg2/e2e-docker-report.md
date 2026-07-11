---
date: 2026-07-11
author: Phase-6 E2E agent (Claude) + Lukas
status: Research — E2E execution record
context: Full Docker-container E2E of the mssql-ops-infrastruktur migration + reset pipeline (baseline adopt, test migrations, full SQL-Agent reset, parity assertions).
related-plan: ../../mssql-ops-infrastruktur.md
related-adrs: —
---

# E2E Docker Report — mssql-ops-infrastruktur (QG2 Phase 6)

Full end-to-end run of both migration chains **and** the test-mandant reset pipeline
against the disposable prod-parity container `robotico-e2e-mssql` (SQL Server 2022,
`Latin1_General_CI_AS`, SQL Agent enabled), on a **real trimmed `eazybusiness`**
restored from the excel_ekl `test-db-jtl` pipeline (Phase 5).

- **Container:** `robotico-e2e-mssql` @ `localhost,14330` (SQL auth, sa).
- **grate:** `erikbra/grate:1.6.0` via Docker (no .NET SDK on host) — see
  `db-migrations/tests/docker/README.md`.
- **Constraint honoured:** no writes to any real SQL server (vm-sql-test1 / vm-sql2);
  container writes only. No git commits.

## Result summary

| Section | PASS | FAIL | SKIP |
|---|---|---|---|
| A — Baseline adopt (Ebene A, TC-M1) | 4 | 0 | 0 |
| B — Test migrations (one-time vs anytime) | 6 | 0 | 0 |
| C — Reset E2E (TC-M3/R2/M5) incl. 25 parity assertions | 34 | 0 | 1 |
| D — Closure (lint, git, container) | 3 | 0 | 0 |
| **Total** | **47** | **0** | **1** |

**Overall: GREEN.** The full production reset path runs end-to-end via the low-privilege
signing chain against a real trimmed `eazybusiness`; all parity assertions pass; both
migration chains apply, baseline-adopt, and redeploy cleanly. **No bugs found.** The single
SKIP is the *live* running-cancel (refused by design while the Agent job executes; the
deterministic queued-cancel path is tested instead). One documentation-level semantics
finding (grate `--baseline` masks a behind-the-repo estate — §A2) is flagged for the
rollout runbook. No git commits; container left running.

---

## Section A — Baseline adopt (Ebene A / TC-M1 semantics)

**Setup:** the restored `eazybusiness` already carries our `Robotico.*` (32 objects) and
`CustomWorkflows.*` (14 sprocs) objects from prod, but **no grate journal**
(`Robotico.ScriptsRun` absent). This is the real adoption scenario.

### A1 — `deploy … -Baseline` marks the estate without executing → **PASS**
- Command: `pwsh db-migrations/deploy.ps1 -Scope eazybusiness -Environment E2E -Baseline`.
- grate reported **"No sql run … all files run against destination previously"** for
  `up/`, `functions/`, `sprocs/` — nothing executed.
- Journal `Robotico.ScriptsRun` **created**, **27 rows** (2 one-time `up/` + 25 anytime).
- Definition fingerprint of all `Robotico`+`CustomWorkflows` module bodies:
  `0xD243CC4E9171EA1EC8E91D3D9687E1F9` **before and after** baseline — **byte-identical**,
  proving baseline executed no DDL. ✔ TC-M1 "mark as run, do not run".

### A2 — normal re-run is a no-op after baseline → **PASS (with a semantics note)**
- Command: `deploy … -Scope eazybusiness -Environment E2E` (no `-Baseline`).
- grate: **"No sql run …"** for all folders — 0 changes.
- **NOTE — grate `--baseline` baselines *anytime* scripts too, not only one-time.** All
  25 anytime files were recorded by A1, so a normal re-run skips them. The plan's
  expectation that a follow-up normal run applies the current anytime objects does **not**
  hold after a full baseline. Consequence for real adoption: **if the prod DB is behind
  the repo, baseline silently masks the missing/older anytime objects** (the journal says
  "applied" while the DB still holds the old/absent object). See A2b — this actually
  occurred here (the Jul-08 backup was 7 objects behind the repo).

### A2b — real CREATE OR ALTER apply against the live prod schema (Slot-5 reality test) → **PASS**
To actually exercise the anytime path against the real JTL schema (the point of the
Slot-5 SCHEMABINDING functions / PayPal procs), the 25 anytime journal rows were trimmed
(the 2 one-time rows kept) and the deploy re-run:
- All **25 anytime objects** (`12 Robotico.fn*`, `6 Robotico.sp*`, `7 CustomWorkflows.sp*`)
  **ran green** via `CREATE OR ALTER` against the real prod schema — no `Incorrect syntax`,
  no missing-column / SCHEMABINDING error. This is the reality test for slot 5: the
  current objects compile and bind against a genuine JTL `eazybusiness`.
- Definition fingerprint **changed** `0xD243… → 0xAD3A6ADD095997DF657920EDF5543B3F`, and
  object counts rose **Robotico 32 → 38, CustomWorkflows sprocs 14 → 15** — i.e. the
  Jul-08 prod backup was **7 objects behind** the current repo; `CREATE OR ALTER` created
  them cleanly. (This is the concrete instance of the A2 masking note.)

### A3 — third run is idempotent → **PASS**
- `deploy …` again → **"No sql run …"** for all folders (0 changes). Journal stable at 27
  rows; object counts stable (Robotico 38, CustomWorkflows sprocs 15).

**Section A verdict: 4/4 PASS.** Baseline adopts without executing (TC-M1), the anytime
chain applies green against the real prod schema, and the chain is idempotent. One
important semantics finding (baseline masks a behind-the-repo estate) is documented for
the rollout runbook.

---

## Section B — Test migrations (one-time vs anytime, hash-redeploy)

**Fixtures** (committed under `db-migrations/tests/docker/fixtures/`, NOT in either chain):
- `up/9900_e2e_probe_table.sql` — one-time, creates `Robotico.tE2EProbe` (README §3 boxed
  banner header, `IF OBJECT_ID` guard, seeds 1 row).
- `functions/Robotico.fnE2EProbe.sql` — anytime, `CREATE OR ALTER FUNCTION`
  `Robotico.fnE2EProbe(@n)` (VERSION 1 → `@n*2`).

Method: copy both into `eazybusiness/up/` + `eazybusiness/functions/`, deploy, verify;
edit the function (hash change), redeploy, verify only it re-ran; remove the copies; drop
the probe objects.

### B1 — lint clean + first deploy runs both → **PASS**
- `lint-migrations.ps1` with the fixtures in the chain: **0 errors** (2 pre-existing (g)
  warnings only) — the fixtures satisfy the naming/shape rules.
- Deploy ran **`9900_e2e_probe_table.sql`** (one-time) and **`Robotico.fnE2EProbe.sql`**
  (anytime).
- Verify: `Robotico.tE2EProbe` exists, 1 seeded row; `Robotico.fnE2EProbe` exists;
  **`fnE2EProbe(21) = 42`** (= 21×2, VERSION 1); journal `Robotico.ScriptsRun` has a row
  for each. ✔

### B2 — function hash change re-runs ONLY the function → **PASS**
- Edited the chain copy to VERSION 2 (`@n*3`) and redeployed.
- grate ran **only `Robotico.fnE2EProbe.sql`**; `up/` reported **"No sql run"** — the
  one-time `9900` was **not** re-run.
- Verify: **`fnE2EProbe(21) = 63`** (= 21×3, VERSION 2); `Robotico.tE2EProbe` still 1 row;
  `9900` journal row count still 1 (one-time immutability held). ✔ This is the definitive
  one-time-vs-anytime proof: a changed anytime object redeploys via `CREATE OR ALTER`, a
  one-time object stays put.

### B3 — idempotent after the change → **PASS**
- Third deploy → **"No sql run"** for all folders (0 changes).

### B4 — cleanup leaves the chains clean → **PASS**
- Removed both fixture copies from the chain.
- `git status` of `db-migrations/eazybusiness` + `db-migrations/global`: **no tracked-file
  modifications** (chains clean); only `db-migrations/tests/docker/fixtures/` and this
  report are new/untracked.
- Dropped `Robotico.fnE2EProbe` + `Robotico.tE2EProbe` and deleted their journal rows in
  the container (documented DB cleanup); `Robotico` object count back to 38.

**Section B verdict: 6/6 PASS.** grate's one-time (run-once, hash-tracked, immutable) and
anytime (re-run on hash change) semantics are both proven against the live container, and
the fixtures leave the chains byte-clean.

---

## Section C — Reset E2E (full production path / TC-M3, TC-R2, TC-M5)

**Container setup (C0, container-only, no chain edits):**
- `ops.Config` re-pointed to Linux container paths (test-env only, via `UPDATE`):
  `BackupFile=/var/opt/mssql/backups/reset_clone.bak`, `TargetDataDir=/var/opt/mssql/data`
  (`SourceDb=eazybusiness`, `ReferenceMandant=1` unchanged). The clone step's hard-coded
  `\` separator is **Windows-correct and Linux-tolerant** — pre-tested: SQL Server on Linux
  normalises `/var/opt/mssql/data\clone_file.mdf` to a real file under `…/data/`.
- Backups dir `chown mssql` so SQL Server can BACKUP there.
- Login `dbuser_dev_dana_for_development` created (server login) — the `GrantAccess` target
  (PAR-1 / TC-R2 #7).
- Low-priv consumer login **`e2e_dana`**: `RoboticoOps` user + `ops_reset_executor` role
  **only**, no other rights. **Every consumer call in this section ran as `-U e2e_dana`**,
  so the signing chain is exercised for real (not as sa).
- `ops.Mandant` row `tm9` (`eazybusiness_tm9`, DisplayName `E2E Test`,
  LoginName `dbuser_dev_dana_for_development`, ShopUrl `https://tm9.staging.local`,
  ShopLicense `E2E-LICENSE-KEY-tm9`) inserted as sa/ops_admin.
- **Source baseline** captured: `tkunde` 230811, `tAdresse` 426417 (0 anonymized),
  `ebay_user` 1 (0 locked), `tMandant` 3, `tQueue` 9760, one repointable shop (`nTyp=0`,
  `https://shop.ison-musical.ts.net`) + one `unicorn2` shop (`nTyp=3`).

**Pre-flight infra (RoboticoOps, from the committed global deploy):** 2 signed procs
(`reset.StartTestmandantReset`, `reset.CancelResetRequest`), `jobstartuser` login, roles
`ops_reset_executor`/`ops_admin`, 8 `ops.ResetStep` rows, Agent job
`RoboticoOps - Testmandant Reset` (owner sa, enabled), Agent service **Running**.

### C2 — consumer entry points as `e2e_dana` → **PASS**
- `reset.ListMandants`: tm9 visible (with tm2/tm3/tm4 templates); **7 columns, no
  ShopLicense / ShopUrl**.
- Direct `SELECT ShopLicense FROM ops.Mandant` as e2e_dana → **"SELECT permission denied"**
  (column DENY, assertion 13).
- `reset.StartTestmandantReset @MandantKey='tm9'` → **"Job … started successfully"**,
  returned `RequestId=1, queued`. **The signing chain carried the low-priv caller across
  the RoboticoOps→msdb boundary to `sp_start_job` — the core TC-M3 proof.**
- Immediate second `StartTestmandantReset` → returned the **same** `RequestId=1, queued`
  (OPS-6 in-flight dedup, **no THROW**).

### C3 — Agent job runs the full 8-step pipeline → **PASS**
- Polled `reset.GetResetStatus` (server-side WAITFOR loop) → **succeeded** in **404 s**.
- StepLog shows all **8 `starting step N` lines in `ops.ResetStep` order**, each with its
  completion line:
  1 CloneDatabase → `clone: backup+restore eazybusiness -> eazybusiness_tm9 ok`;
  2 PostRestoreSecurity → `owner=sa … TRUSTWORTHY OFF`;
  3 InvalidateCredentials → `JS-Shop repointed to staging (1 row(s))`;
  4 NeutralizeWorker → `pf_user locked, queues emptied`;
  5 AnonymizeCustomerData → `anon.P1 … anon.P11 ok` (the ~6 min bulk — 230 k customers);
  6 GrantAccess → `dbuser_dev_dana_for_development is db_owner on eazybusiness_tm9`;
  7 RegisterMandant → `kMandant=5 (E2E Test)`;
  8 ApplyJtlRoles → `JTL_Reader/JTL_Writer ensured + members applied`.
- Consumer read path: `e2e_dana` direct `SELECT` on `ops.ResetRequest` → **DENIED**;
  `EXEC reset.GetResetStatus @RequestId=1` → full status (RequestedBy=`e2e_dana`,
  Status=succeeded, 404 s, StepLog) via ownership chaining.

### C4 — 13 parity assertions + TC-R2 + source-unchanged → **25/25 PASS**

| # | Assertion | Result | Evidence |
|---|---|---|---|
| 1 | Anonymization column parity | PASS | `tAdresse.cName` 0 cleartext; emails 0 non-`@test.local` |
| 2 | CONTEXT_INFO trigger-bypass worked | PASS | tAdresse 426417 + tkunde 230811 rows changed (past the triggers) |
| 3 | No cleartext credentials | PASS | tEMailEinstellung pw='', ebay_user pw=''+gesperrt, tOauthToken invalid, tShipperAccount iban/bic/token cleared, tLizenz token='' — 0 violations each |
| 4 | Shop repoint (TC-R2 #4) | PASS | 1 of 1 `nTyp=0` row → ShopUrl+ShopLicense; `unicorn2` (`nTyp=3`) untouched; rowcount 1 |
| 5 | Worker neutralization (D9) | PASS | pf_user 0 violations (table empty in clone); all 6 queues empty; `Worker.tTarget` clone==src (10) |
| 6 | Post-restore security | PASS | clone TRUSTWORTHY OFF + owner sa |
| 7 | Grant/access (PAR-1 / TC-R2 #7) | PASS | `dbuser_dev_dana_for_development` exists **and** db_owner in clone |
| 8 | JTL roles | PASS | JTL_Reader/JTL_Writer exist + inherit db_datareader/-writer |
| 9 | Register-mandant | PASS | source tMandant has 1 `eazybusiness_tm9`/`E2E Test` row; tBenutzerFirma kMandant5==ref1 (63==63) |
| 10 | Recovery/state | PASS | clone ONLINE / MULTI_USER / SIMPLE |
| 11 | Banking end-state (item 5) | PASS | tkontodaten 589 rows all `IBAN_…`, CVV/Gueltigkeit NULL (P8 overwrote InvalidateCredentials) |
| 12 | Idempotence (2nd reset) | PASS | 2nd reset succeeded (451 s); no `_deactivated_deactivated`; tMandant not duplicated; anonymization complete |
| 13 | Status channel without secrets | PASS | GetResetStatus/ListMandants omit ShopLicense; e2e_dana DENY on column |
| S1 | SOURCE tkunde unchanged | PASS | 230811 (identical) |
| S2 | SOURCE not anonymized | PASS | tAdresse cleartext preserved (0 `cName_…`) |
| S3 | SOURCE ebay not locked | PASS | 0 gesperrt |
| S4 | SOURCE queues intact | PASS | tQueue 9760 (not emptied) |

> Note (assertion 5): `pf_user` is **empty** in this trimmed clone, so the lock is a no-op
> — the column-guarded UPDATE held (no error), matching the O4 probe finding on test1.
> `Worker.tTarget` intact (10 rows, D9). Source registration write (tMandant row +
> tBenutzerFirma seed for kMandant 5) is the **intended** blast radius (CQG-5), separate
> from the "customer data unchanged" guarantee — both verified.

### C5 — cancel path + purge retention → **PASS**
- **Cancel (queued):** a queued request was created (job idle, not started) and
  `reset.CancelResetRequest` run **as e2e_dana** → `queued → failed`,
  ErrorText `cancelled by e2e_dana (was queued)`. (A live "running" cancel is refused by
  design while the job executes; the deterministic queued path is tested instead — the
  running-refusal guard is covered by the SP's msdb `sysjobactivity` check.)
- **Purge (OPS-5):** `reset.PurgeOldRequests @WhatIf=1` **denied** to e2e_dana
  (`ops_reset_executor`) — "EXECUTE permission denied"; **allowed** to a fresh `e2e_admin`
  (`ops_admin`) → reported `WouldDeleteRows=2, KeepPerMandant=1` (dry run, deleted nothing).

### C6 — signature survival across re-deploy (TC-M5) → **PASS**
- Trimmed the journal rows of the two signed sprocs and ran a **full `-Scope global`
  re-deploy**: grate re-ran `reset.CancelResetRequest` + `reset.StartTestmandantReset`
  (CREATE OR ALTER **strips** signatures), then `100_grants`, `200_ensure_agent_job`,
  `900_resign_procedures`.
- `sys.crypt_properties` after: **both procs signed again** by `RoboticoOpsSigning`
  (permissions/900 re-applied the signatures via the `{{CertPassword}}` token).
- Proof the chain still authorises the low-priv path: `e2e_dana` `StartTestmandantReset`
  **still starts the job** and `GetResetStatus` still returns — signing intact after
  redeploy.

**Section C verdict: TC-M3 full reset succeeded via the real low-priv signing path;
25/25 parity assertions PASS; OPS-6 dedup, cancel-queued, OPS-5 purge-gating, and TC-M5
signature survival all PASS.** No FAILs; no bugs found in the reset pipeline.

The reset was exercised **three times** end-to-end (RequestId 1: 404 s, 2: 451 s,
4: 499 s — the last started by the TC-M5 signing proof), all `succeeded`, plus one
`failed` (the deterministic queued-cancel). Consistent, idempotent, repeatable.

---

## Section D — Closure

### D1 — repo lint → **PASS**
`pwsh db-migrations/tests/lint-migrations.ps1` → **0 errors**, 2 warnings (the pre-existing
rule-(g) dynamic-SQL heuristics on `reset.internal_GrantAccess` — documented safe;
object/DB names via QUOTENAME, values via sp_executesql params).

### D2 — git status → **PASS**
Only `db-migrations/tests/docker/fixtures/` and this report are new/untracked. **No
tracked-file modifications** in `db-migrations/eazybusiness`, `db-migrations/global`,
`deploy.ps1`, or `targets.config.json` — the chains are byte-clean (the Section-B fixtures
were removed from the chain; all reset config changes were `UPDATE`s inside the container,
not file edits).

### D3 — container left running → **PASS**
`robotico-e2e-mssql` healthy, still up on `localhost,14330`. Final container state (all
test-only, disposable): DBs `eazybusiness` (source, unchanged data) + `eazybusiness_tm9`
(clone from the last reset); logins `e2e_dana` (ops_reset_executor), `e2e_admin`
(ops_admin), `dbuser_dev_dana_for_development`; `ops.Mandant` row `tm9`; `ops.Config`
BackupFile/TargetDataDir on container paths; `ops.ResetRequest` ledger 1–4.

**Section D verdict: 3/3 PASS.**

---

## Notes for the rollout runbook

1. **grate `--baseline` baselines anytime scripts too (§A2).** For the real PROD adoption,
   ensure the prod `eazybusiness` is actually at the repo's object version *before*
   baselining, or run a normal (non-baseline) deploy so `CREATE OR ALTER` refreshes the
   anytime objects — otherwise a behind-the-repo estate is silently recorded as "applied".
   In this run the Jul-08 backup was 7 objects behind; the reality-test refresh reconciled
   it (all green).
2. **Clone step paths are Windows-shaped but Linux-tolerant.** `internal_CloneDatabase`
   builds `TargetDataDir + '\' + …`; SQL Server on Linux normalises the `\`, so the E2E
   container works unchanged. PROD (Windows) is the native case.
3. **Reset timing:** a full reset of this trimmed DB (~230 k customers) takes ≈7 min, almost
   entirely in `AnonymizeCustomerData` (P1–P11). Size the operator's polling expectation
   accordingly; a real (untrimmed) PROD mandant will take longer.
