# Runbook — Baseline the Ebene-A migrations against existing databases

Operator runbook to adopt an **already-populated** eazybusiness database into the
grate migration journal, without re-running the objects that are already deployed.

> [!IMPORTANT]
> A baseline marks every current `up/` and anytime script as **already run** — it
> writes journal rows but executes **no** SQL against your objects. It is correct
> only when the files in `db-migrations/eazybusiness/` match what is deployed. Verify
> that first (Step 2), or you will hide a real drift.

> [!WARNING]
> **`grate --baseline` baselines the *anytime* scripts too, not only the one-time
> `up/` scripts.** This is the load-bearing subtlety: once baselined, a later *normal*
> deploy will **not** re-apply the functions/procs — grate already has their current
> hash journaled. So if the target DB is **behind** the repo (an anytime object is
> older, or missing entirely), baseline **silently records it as "applied"** while the
> DB keeps the stale/absent object. The journal then lies: it says "applied", the DB
> disagrees, and no later normal run will fix it.
>
> **Precondition — one of these must hold before you baseline:**
> 1. The target's object definitions already **equal** the repo (verify in Step 2 —
>    every object present *and* hashes match), **or**
> 2. you skip baseline and run a **normal** (non-`-Baseline`) deploy instead, which
>    reconciles anytime objects via `CREATE OR ALTER` (and creates missing ones).
>
> **E2E evidence (2026-07-11 Docker run, `reports/qg2/e2e-docker-report.md` §A2):** the
> restored prod backup was **7 objects behind** the repo. A baseline followed by a
> normal re-run reported *nothing to do* — the 7 objects stayed stale/absent. Only
> after forcing the anytime scripts to re-apply did `CREATE OR ALTER` reconcile them
> (all green against the real JTL schema). Had this been a real adoption, the estate
> would have been left behind silently.

- **Applies to:** the Ebene-A chain (`-Scope eazybusiness`). Ebene B (`RoboticoOps`)
  is greenfield and is never baselined.
- **Prerequisites:** grate on `PATH` (`dotnet tool install --global grate`); Windows
  auth to the target server; read access via `sqlcmd` for the pre-check.
- **Reference:** [`db-migrations/README.md`](../../db-migrations/README.md).

---

## Step 1 — Know your targets

The databases that hold our objects today (per `targets.config.json`):

| Environment | Server | Databases |
|---|---|---|
| PROD | `vm-sql2.zdbikes.local` | `eazybusiness`, `eazybusiness_tm2`, `eazybusiness_tm3`, `eazybusiness_tm4` |
| TEST | `vm-sql-test1.zdbikes.local` | `eazybusiness` |

Order: baseline **prod `eazybusiness` first** (it is the clone source), then test1's
`eazybusiness`, then any mandant clone you intend to deploy to directly. A freshly
made clone inherits the prod journal and needs no separate baseline.

## Step 2 — Pre-check: do the files match the deployed objects?

For each target database, dump the owned-object inventory with a per-object
definition hash. Read-only:

```bash
/opt/mssql-tools*/bin/sqlcmd -S vm-sql2.zdbikes.local -E -C \
    -d eazybusiness -i db-migrations/tests/compare-objects.sql
```

The script lists every object we own (`Robotico.*` plus our `CustomWorkflows`
action procs) with a `SHA2_256` hash of its module definition — tables appear with
a `NULL` hash so the inventory is complete. Two ways to read the output:

- **Prod `eazybusiness` (the clone source / truth):** confirm every object the files
  in `db-migrations/eazybusiness/` define is **present**. There is nothing to diff
  against — prod *is* the reference — so a missing object is the only red flag.
- **test1 and any clone you baseline directly:** run the script there too and compare
  its hash list against prod's. Equal hashes mean the deployed definition matches;
  a differing hash means the object drifted.

If an object is **missing**, do **not** baseline blindly — deploy normally instead
(grate will create the missing ones). If a hash **differs**, reconcile the file to
the deployed truth first (remember: the file is what future clones will get).

## Step 3 — Lint the files

```bash
pwsh db-migrations/tests/lint-migrations.ps1
```

Exit 0 required. A failing lint means the tree is not deployable — fix before
baselining.

## Step 4 — Baseline

Per target database (example: prod `eazybusiness`):

```powershell
pwsh db-migrations/deploy.ps1 -Scope eazybusiness -Environment PROD -Target eazybusiness -Baseline
```

`-Environment PROD` triggers the interactive Y/N confirmation (it lists the target
DBs and the BASELINE mode first). Repeat with `-Target eazybusiness_tm2` etc. only for
clones you deploy to directly.

For test1:

```powershell
pwsh db-migrations/deploy.ps1 -Scope eazybusiness -Environment TEST -Baseline
```

## Step 5 — Confirm the journal, then switch to the normal cycle

After baselining, a normal (non-baseline) run must report **nothing to do** (all
scripts already journaled):

```powershell
pwsh db-migrations/deploy.ps1 -Scope eazybusiness -Environment TEST -DryRun
```

From here the standard cycle applies: add a new object → `deploy.ps1` (no `-Baseline`)
→ grate runs only the changed anytime scripts and any new `up/` scripts.

---

## Failure modes

> [!WARNING]
> **One-time script hash mismatch on a later run.** If grate later refuses a run with
> a hash mismatch on an already-applied `up/` script, someone edited an applied
> one-time file. The fix is a **new** `up/` script (never edit the applied one). The
> emergency-only override `--warnandignoreononetimescriptchanges` exists but is not a
> `deploy.ps1` default and must be a conscious, logged decision.

> [!CAUTION]
> **Never baseline PROD when the files disagree with the deployed objects.** Baseline
> asserts "file == deployed". If they differ, the next real deploy will either skip a
> needed change or a clone will silently carry the wrong definition. Step 2 exists to
> prevent exactly this.
