---
date: 2026-07-13
author: Rollout agent (Claude) + Lukas (team-lead ran the test1 writes)
status: Report — dress rehearsal on vm-sql-test1 COMPLETE, all green
context: Execution record of the full db-migrations/ dress rehearsal against the real test server vm-sql-test1 — both migration chains, the RoboticoOps reset infrastructure, and a full tm9 reset — plus the three bugs the rehearsal surfaced and the repeatable validation test built alongside.
related-plan: ../mssql-ops-infrastruktur.md
related-report: ./test1-rollout-plan.md
related-runbooks: ../../../runbooks/rollout-mssql-ops.md, ../../../runbooks/testmandant-reset-validierung.md
---

# test1 Rollout Report — dress rehearsal COMPLETE (all green)

The whole `db-migrations/` stack was deployed and exercised end-to-end against the **real**
test server `vm-sql-test1.zdbikes.local`, and a full test-mandant reset (`tm9`) ran through
the new server-side pipeline. The rehearsal surfaced **three real bugs** (all fixed) and
produced a repeatable, npm-callable validation test. This is the closure record.

> **Division of labour:** the test1 *writes* (deploys, reset, login creation) were run by
> Lukas / team-lead in the main session; this agent did the recon, planning, all repo edits
> (tooling, bug fixes, validation test), and the read-only verification.

## Result

| Phase | What | Verdict |
|---|---|---|
| b.0 | Install .NET 8 + grate 1.6.0 natively; prove Kerberos auth via native grate | ✅ |
| b.1 | Convention lint | ✅ 0 errors |
| b.2 | Ebene A **normal deploy** (not baseline) → adopt + reconcile test1 `eazybusiness` | ✅ 27 journal rows |
| b.3 | Ebene B global deploy → `RoboticoOps` (after fixing 3 bugs) | ✅ |
| b.5 | `ops.Config` repoint to test1's C: paths | ✅ |
| b.7 | Full `tm9` reset via `StartTestmandantReset` → agent job → 8-step pipeline | ✅ succeeded, 325 s |
| b.8 | Repeatable validation test (`db:validate:test`) | ✅ green |

**`npm run db:validate:test` is green**, and every tm9 clone/​source outcome check passes
(numbers below). The dress rehearsal is a success: the production reset path works
end-to-end on a real server via the low-privilege signing chain.

---

## Deviations & bugs (the value of the rehearsal)

### Three bugs surfaced by the real b.3 global deploy (all fixed + committed)

The E2E Docker container (SQL 2022, `us_english`) had hidden three environment-specific
defects that only a real German-locale server exposed:

- **Bug A — language-dependent date literal (blocker).** `CREATE CERTIFICATE … EXPIRY_DATE =
  '2999-12-31'` threw error 190 on the German login (`DATEFORMAT dmy` reparses the dashed
  ISO date). Fixed to the language-neutral `'29991231'`; added **lint rule (h)** forbidding
  dashed date literals in migration code (a tree sweep confirmed it was the only occurrence).
  Commit `e318e3b`.
- **Bug B — cert-password store corruption (critical).** `Save-PersistedCertPassword` appended
  the new `KEY=VALUE` onto the previous line without a newline, hiding the key from the reader
  (a second deploy would have minted a *different* password the immutable cert could never be
  unlocked with). Rewrote Save/Read to a deterministic raw-read + explicit-join form; repaired
  the real `~/.robotico-ops/grate-cert.env`; filed the TEST password in `~/.claude-secrets.md`.
  Commit `3a38f2c`.
- **Bug C — sqlcmd resolver (blocker).** `Test-SigningCertExists` used a bare `Get-Command
  sqlcmd`, which picks the Kerberos-incapable go-sqlcmd on Linux and aborted the deploy.
  Added the shared `Get-RoboticoSqlcmd` resolver in `lib/targets.ps1` (prefers the ODBC build),
  used by `deploy.ps1`, `mandant.ps1`, `validate-rollout.ps1`. Commit `3a38f2c`.

After the fixes the b.3 retry deployed cleanly, the cert password resolving from tier 2 (the
repaired store) — no regeneration.

### Conscious decisions

- **Ebene A: normal deploy, NOT `--baseline` (D-b.2).** test1 was behind the repo (32 vs 38
  `Robotico` objects) and both `up/` scripts are idempotent, so a normal deploy adopted the
  journal *and* reconciled the anytime objects via `CREATE OR ALTER` — avoiding the baseline
  masking trap. 27 journal rows; a follow-up DryRun reported nothing to do.
- **grate runner: native, not Docker (D-b.0).** The Docker grate runner cannot do Kerberos; a
  native `.NET 8 + grate 1.6.0` install authenticates via the operator's ticket exactly like
  `sqlcmd -E`. grate pinned to **1.6.0** (the E2E-validated version; 2.1.5 needs .NET 10).
- **PAR-1 verified.** One approved read-only query against PROD (`vm-sql2`) confirmed the seed
  login `dbuser_dev_dana_for_development` exists on prod (alongside `_for_jtl`, `_lukas_claude`).
  up/0020's TODO resolved (comment-only, before b.3 so the applied hash matches). Commit `f47c205`.
- **tm9 developer login: throwaway `dbuser_dev_test1`.** The seed login lives on prod, not
  test1, so a disposable SQL login was created (CSPRNG password, used once, not persisted) to
  exercise the real `GrantAccess` path. It is `db_owner` on the clone (verified).
- **`ops.Config` repoint.** test1 has only a C: drive; the E:\ seed defaults were UPDATEd to
  `C:\Program Files\Microsoft SQL Server\MSSQL17.MSSQLSERVER\MSSQL\DATA\…`.
- **Runbook drift fixed.** `tVersion` column is `cVersion` (not `nVersion`) — corrected in the
  validation runbook. Commit `e023da4`.

---

## tm9 reset — outcome checks (read-only, all pass)

`reset.GetResetStatus @MandantKey='tm9'` → **succeeded**, RequestId 1, 325 s, no ErrorText,
full StepLog (all 8 steps). TargetDb `eazybusiness_tm9`.

| Check | Result |
|---|---|
| Clone version `cVersion` | **2.0.5.0** ✓ |
| Worker queues (tQueue/tWorkflowQueue/ebay_queue_out/ebay_usermessagequeue/tGlobalsQueue/tDruckQueue) | all **0** ✓ |
| `ebay_user` | 1 row, **locked** (`nGesperrt=1`) ✓ |
| `pf_user` | 0 rows (empty on test1 → guard no-op, matches O4) ✓ |
| Credentials blanked (`tEMailEinstellung` SMTP/SMIME/Portal pw; `ebay_user.Passwort`; `tOauthToken.nInvalid`; `tShipperAccount` pw/IBAN) | **0 non-blank / 0 still-valid** ✓ |
| Shop repoint (`tShop nTyp=0`) | `cServerWeb=NULL` — no live shop on test1, guarded repoint (`LIKE 'http%'`) correctly no-ops ✓ |
| Customer anonymization | `tAdresse` 417 948 / 417 948 `cName` anonymized; `tkunde` 226 786 / 226 786 `cHerkunft` anonymized ✓ (100%) |
| Dev-login access | `dbuser_dev_test1` is **db_owner** on `eazybusiness_tm9` ✓ |
| Source registration | `dbo.tMandant` row **kMandant=2**, cName `Reset validation (dress rehearsal)`, cDB `eazybusiness_tm9`; `tBenutzerFirma` **68 rows** seeded for kMandant 2 ✓ |
| Source untouched (control) | source `eazybusiness.tAdresse` — **0** anonymized (anonymization hit only the clone) ✓ |

Structure/rollout validation (`db:validate:test`): validate_structure OK, validate_rollout OK
(both journals, 8 ResetStep rows, 2 signed procs, agent job enabled, master principals),
consumer roundtrip OK.

---

## Current state of test1 (left in place for inspection)

- **`RoboticoOps`** deployed (cert, signing login in master, `jobstartuser`, agent job, 8
  ResetStep rows, roles). Cert password in `~/.robotico-ops/grate-cert.env` (`_TEST`) +
  `~/.claude-secrets.md`.
- **`eazybusiness`** — Ebene A adopted + reconciled (Robotico journal, 38 objects). Source data
  untouched except the intended tm9 registry rows.
- **`eazybusiness_tm9`** clone — the reset result (anonymized, neutralized).
- **`dbuser_dev_test1`** login — db_owner on the clone.
- SQL Agent **service running**; JTL Worker **stopped** (host actions by Lukas).
- Leftover from earlier work: `eazybusiness_e2e_r3_pre_snap` snapshot (unrelated; drop anytime).

### Cleanup (when the rehearsal artifacts are no longer needed)

```sql
-- 1. throwaway clone + its registration + dev login
ALTER DATABASE [eazybusiness_tm9] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
DROP DATABASE [eazybusiness_tm9];
DELETE FROM dbo.tMandant       WHERE cDB = 'eazybusiness_tm9';   -- in eazybusiness (kMandant=2)
DELETE FROM dbo.tBenutzerFirma WHERE kMandant = 2;               -- reviewed
DROP LOGIN [dbuser_dev_test1];
-- optionally clear the tm9 ops history:  EXEC RoboticoOps.reset.PurgeOldRequests @KeepPerMandant = 0;  (or leave)

-- 2. (only for a FULL Ebene-B teardown, e.g. before the naming-rename redeploy)
--    see test1-rollout-plan.md §d: DROP DATABASE RoboticoOps; DROP LOGIN RoboticoOpsSigningLogin;
--    DROP CERTIFICATE RoboticoOpsSigning (master); sp_delete_job; DROP LOGIN jobstartuser;
```

Return test1 to baseline if desired: stop the SQL Agent service (back to Manual) and restart
the JTL Worker.

---

## Artifacts produced

- `db-migrations/tests/validate-rollout.ps1` + `tests/global/validate_rollout.sql` —
  environment-agnostic rollout validation (npm `db:validate` / `:test` / `:e2e`; optional
  `-FullReset`, `-RightsTestLogin`).
- Bug fixes: `deploy.ps1` (store robustness + resolver), `lib/targets.ps1` (`Get-RoboticoSqlcmd`),
  `mandant.ps1`, lint rule (h), `up/0011` date literal, `up/0020` TODO resolution.
- Reports: `test1-rollout-plan.md` (plan), this file, `naming-inventory-hungarian.md` (follow-up).

Commits on `feature/mssql-ops-infrastruktur`: `0d440e0`, `e023da4`, `f47c205`, `e318e3b`, `3a38f2c`.

---

## Open items / next steps

1. **Naming normalization (separate task, pending Lukas' review).** The Hungarian-notation
   inventory (`naming-inventory-hungarian.md`) proposes an Ebene-B-only rename wave (disposable →
   in-place + teardown/redeploy). Six decision questions await Lukas. When approved, the rename
   is executed as its own change set (with test1 `RoboticoOps` rebuilt and validation re-run).
2. **PROD rollout (Phase 4, future).** The rollout runbook's prod steps remain human-gated and
   are **not** part of this rehearsal. The dress rehearsal is the evidence that the prod path is
   safe.
3. **Cleanup** of the tm9 rehearsal artifacts per above, at Lukas' discretion.
