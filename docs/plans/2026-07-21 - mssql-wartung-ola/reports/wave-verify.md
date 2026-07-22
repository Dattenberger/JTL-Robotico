# Wave-Verify Report — mssql-wartung-ola

**Timestamp:** 2026-07-22T21:57:00+02:00
**HEAD:** `fc508ad [B1] repair wave 2 (mssql-wartung-ola)`
**Verdict:** ✅ CLEAN — all checks passed, plan workflow may report `complete`.

This gate verifies the objective git/compiler state only; agent self-reports do
not count here. Nothing was fixed — measured, reported, verdict returned.

## Check 1 — Everything landed

`git status --porcelain -- <ALL_FILES>` → **empty** (exit 0). Every one of the 15
`ALL_FILES` is reachable from HEAD (not staged-only, not working-tree-only).

Existence in HEAD confirmed for each (clean status alone could mask a missing
file). All 15 present:

| File | In HEAD |
|---|---|
| db-migrations/global/up/0022_maintenance_ola_vendor.sql | OK |
| db-migrations/global/up/0023_maintenance_registry.sql | OK |
| db-migrations/global/sprocs/maint.spEnsureMaintenanceJobs.sql | OK |
| db-migrations/global/sprocs/maint.spRunMaintenanceJob.sql | OK |
| db-migrations/global/sprocs/maint.spCheckBackupChain.sql | OK |
| db-migrations/global/sprocs/maint.spCheckMaintenanceLiveness.sql | OK |
| db-migrations/global/runAfterOtherAnyTimeScripts/maint.spApplyMaintenance.sql | OK |
| db-migrations/global/permissions/260_maintenance_operator.sql | OK |
| db-migrations/tests/global/validate_structure.sql | OK |
| db-migrations/tests/global/validate_rollout.sql | OK |
| db-migrations/README.md | OK |
| docs/SQL/MSSQL-OPS-DATA-MODEL.md | OK |
| docs/SQL/NAMING-CONVENTIONS.md | OK |
| docs/SQL/MSSQL-OPS-ARCHITECTURE.md | OK |
| docs/runbooks/rollout-mssql-ops.md | OK |

Other dirty/untracked paths in the working tree (PayPal removals,
`0003_drop_paypal_mechanic.sql`, `250_jobstartuser_mapping.sql`, plan report
scaffolding, `tmp/`) belong to OTHER concurrent work — not in `ALL_FILES`, out of
scope for this gate.

## Check 2 — Untracked-producer guard

`git ls-files --others --exclude-standard` over the run's source dirs
(`db-migrations/`, `docs/SQL/`, `docs/runbooks/`) → two untracked source files:

- `db-migrations/eazybusiness/up/0003_drop_paypal_mechanic.sql`
- `db-migrations/global/permissions/250_jobstartuser_mapping.sql`

Both are unrelated concurrent work. Checked whether any COMMITTED `ALL_FILES`
file depends on an object these untracked files produce:

- The only `ALL_FILES` reference to `jobstartuser`/`250` is a **comment** in
  `260_maintenance_operator.sql:4` describing permission-script ordering
  ("after 250_jobstartuser_mapping and before 900_resign") — not a hard
  dependency.
- The `jobstartuser` login/user itself is produced by the **committed**
  `db-migrations/global/up/0010_jobstartuser_login.sql`. The untracked `250` is a
  self-healing orphan re-map that produces no new object the maintenance code
  requires.
- `0003_drop_paypal_mechanic.sql` is not referenced by any maintenance file.

→ No committed file's function depends on an untracked producer. **No problem.**

## Check 3 — Clean-HEAD lint (typecheck equivalent)

SQL repo, no compiler. `CONVENTIONS` lint/test command:
`npm run db:lint` = `pwsh db-migrations/tests/lint-migrations.ps1`. Exit code
measured directly to a log (no pipe):

```
EXIT=0
lint-migrations: scanned 61 file(s) under db-migrations/{eazybusiness,global}
WARNING [g] reset.spInternal_GrantAccess.sql: possible data concatenation ... near '@LoginName'
WARNING [g] reset.spInternal_GrantAccess.sql: possible data concatenation ... near '@TargetDb'
OK: 0 errors, 2 warning(s).
```

Exit 0, 0 errors. The 2 warnings are on `reset.spInternal_GrantAccess.sql`, a
pre-existing file NOT in this run's `ALL_FILES`; warnings do not fail the gate.

The structure/rollout sqlcmd checks (`validate_structure.sql`,
`validate_rollout.sql`) require a live deploy to the test1 server and are the
deploy-time gate, not part of this static HEAD-verify.

## Verdict

All three checks passed → `clean = true`, no problems.
