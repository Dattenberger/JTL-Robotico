# C2 — RoboticoOps DB + global chain (Ebene B) + reset SP/agent-job orchestration

**Chunk:** C2 (block B1) · **Timestamp:** 2026-07-10T00:57:22+02:00
**Plan sections:** §2 (L281-326), §3 (L330-383), §7 test `global/validate_structure.sql` (L495)

## What I did

Built the complete `db-migrations/global/` chain (Ebene B): RoboticoOps settings +
ops/reset schemas + registry/queue tables + roles + jobstartuser proxy + signing
certificate + seed; the signed reset entry point, status reader, job orchestrator and
the 8 internal pipeline steps (ported from `Projekte/Testsystem/*` + `Berechtigungen/
JTL-Rollen.sql`); the agent-job wrapper; the everytime grants + re-signing; and the
static structure test. Lint green (0 errors).

## Test run

`pwsh db-migrations/tests/lint-migrations.ps1` → **exit 0**, 0 errors, 10 rule-(g)
warnings — all verified false positives (see below). No SQL was executed against any
server (hard constraint; RoboticoOps is not deployed on test1 yet). Runtime behaviour
is exercised later by the §4 validation runbook + E2E.

### Rule-(g) warnings — all safe (no user-data in dynamic SQL)

| File | Flagged | Why it is safe |
|---|---|---|
| internal_CloneDatabase | `@TargetDb`,`@SourceDb` | DB names via `QUOTENAME`; the `@TargetDataDir + '\' + @TargetDb + '.mdf'` path is passed as an sp_executesql **parameter** to RESTORE, never concatenated into executed text. @TargetDb is pattern-validated. |
| internal_GrantAccess | `@TargetDb`,`@LoginName`,`@note` | `@exec`=`QUOTENAME(@TargetDb).sys.sp_executesql`; login passed as `@ln` param, DDL built with `QUOTENAME(@ln)`; `@note` is StepLog text. |
| internal_RegisterMandant | `@DisplayName` | goes into dynamic SQL only as an sp_executesql parameter; the flagged `+ @DisplayName` is StepLog message text. |

The §3 security bar ("no user-data string concatenated into dynamic SQL; only
QUOTENAME/parameters") holds: every dynamic batch runs in the target DB via
`QUOTENAME(@TargetDb).sys.sp_executesql`, object/DB names go through `QUOTENAME`, all
data values (paths, ShopUrl/ShopLicense, DisplayName, login) are sp_executesql params.
Every internal proc is guarded `@TargetDb = 'eazybusiness' OR NOT LIKE 'eazybusiness[_]%'`.

## Object → file mapping (plan Verification #2/#3)

| Source (Projekte/Testsystem, Berechtigungen) | Target proc |
|---|---|
| copy_test_db.sql | reset.internal_CloneDatabase |
| (research/3 §5 post-restore) | reset.internal_PostRestoreSecurity |
| invalidate-credentials-for-testing.sql (e6d7b2b) | reset.internal_InvalidateCredentials |
| NEW (D9) | reset.internal_NeutralizeWorker |
| clear-customer-fields.sql (11 priority blocks) | reset.internal_AnonymizeCustomerData |
| grant-database-access.sql | reset.internal_GrantAccess |
| register-mandant.sql | reset.internal_RegisterMandant |
| JTL-Rollen.sql | reset.internal_ApplyJtlRoles |

Orchestration: reset.StartTestmandantReset (signed) → queue → reset.EnsureAgentJob
(agent job) → reset.ProcessNextResetRequest (loops the 8 steps) → reset.GetResetStatus.

## Deviations

| Deviation | Plan location | What changed | Why | Impact | Resolved? |
|---|---|---|---|---|---|
| StepLog contract | §3 | internal procs take `@RequestId` and append to `ops.ResetRequest.StepLog` directly (not a `@StepLog OUTPUT`) | live progress that **survives** a mid-block failure (OUTPUT params are lost on THROW) — needed for the 11-block anonymize | none (internal) | yes |
| Cross-DB exec pattern | §3 pt 4 | `EXEC QUOTENAME(@TargetDb).sys.sp_executesql @batch, …params` instead of `N'USE '+…+'; '+batch; EXEC(@sql)` | parameterizes data, no `USE` (lint rule a), stronger D6 posture | none | yes |
| agent-job filename | §2 | `reset.EnsureAgentJob.sql` (self-executing wrapper proc) instead of `agent_job_testmandant_reset.sql` | lint treats anytime-folder files as one `Schema.Object` CREATE; a bare sp_add_job script cannot satisfy rules (c)+(e) | see issue C2-1 | yes |
| ShopLicense placeholder | §2 (0020) | seed uses sentinel `'<SET-VIA-RUNBOOK>'`, not a `{{ShopLicense}}` token | `{{…}}` collides with grate's own token syntax (would substitute/error at deploy) | runbook UPDATEs real keys | yes |
| RoboticoEKL grant dropped | §3 (ApplyJtlRoles) | omitted `GRANT EXECUTE ON SCHEMA::RoboticoEKL` from the JTL-Rollen port | forbidden token (lint d) + D10 boundary; restored clone already carries the grant; EKL runner owns it | none | yes |
| banking blocks in invalidate | §3 (InvalidateCredentials) | tkontodaten/tinetzahlungsinfo NOT ported into invalidate | fully covered by AnonymizeCustomerData block 8 (runs after) — SSoT, avoids drift | none | yes |
| tKunde_suche TRUNCATE→DELETE | §3 (anonymize) | `DELETE FROM dbo.tKunde_suche` instead of source `TRUNCATE` | lint rule d forbids `TRUNCATE TABLE dbo.` | none | yes |
| removed BEGIN TRAN / PRINTs / verification SELECTs | §3 | ported scripts run without their transaction wrapper and diagnostic output | each UPDATE auto-commits; a failure quarantines the clone as 'failed' for diagnosis; StepLog/GetResetStatus replace PRINTs | none | yes |
| gap-fill: jobstartuser RoboticoOps USER | §2 (0010) | added `CREATE USER jobstartuser` in RoboticoOps | required for `WITH EXECUTE AS 'jobstartuser'` to resolve | none | yes |

## Issues

| ID | Severity | Description | Status | Marker |
|---|---|---|---|---|
| C2-1 | Important | `tests/lint-migrations.ps1` classes `runAfterOtherAnyTimeScripts/` as anytime and enforces single-`Schema.Object` CREATE + `Schema.Object` filename — but README §2 designates that folder for the (non-object) agent-job wrapper. Worked around here with a self-executing wrapper proc; the lint could instead exempt this folder so a plain script is allowed. Foreign file (C1 scope) — not edited. | delegated | plan-deviation-resolved |
| C2-2 | Nice-to-have | The `reset.internal_ApplyJtlRoles` member list duplicates `Berechtigungen/JTL-Rollen.sql` (no shared table exists). Kept in sync by comment; a future ops.Config-driven list would remove the drift risk. | delegated | none |

## Runtime-unverifiable notes (need the §4 runbook / E2E)

- The signature → AUTHENTICATE-SERVER → cross-DB `sp_start_job` chain is structurally
  per research/3 but cannot be exercised without a deployed RoboticoOps.
- `pf_user` columns (`nGesperrt`/`nAktiv`) are existence-guarded (`COL_LENGTH`) since
  the live schema was not queried; anonymize `pf_user` columns are from the source
  script and assumed present.

## Files outside my scope (drift)

none — all edits are under `db-migrations/global/**` and `db-migrations/tests/global/`.

## Files modified

All NEW under `db-migrations/global/`:
up/{0001_roboticoops_settings, 0002_ops_schema_tables, 0003_roles, 0010_jobstartuser_login,
0011_signing_certificate, 0020_seed_mandant_template}.sql;
sprocs/{reset.StartTestmandantReset, reset.GetResetStatus, reset.ProcessNextResetRequest,
reset.internal_CloneDatabase, reset.internal_PostRestoreSecurity,
reset.internal_InvalidateCredentials, reset.internal_NeutralizeWorker,
reset.internal_AnonymizeCustomerData, reset.internal_GrantAccess,
reset.internal_RegisterMandant, reset.internal_ApplyJtlRoles}.sql;
runAfterOtherAnyTimeScripts/reset.EnsureAgentJob.sql;
permissions/{100_grants, 900_resign_procedures}.sql;
plus db-migrations/tests/global/validate_structure.sql.
