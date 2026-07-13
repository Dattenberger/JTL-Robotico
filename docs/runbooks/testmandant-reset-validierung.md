# Runbook — Validate the RoboticoOps test-mandant reset end-to-end (on test1)

Operator runbook to prove the new server-side reset (`reset.spPub_StartTestmandantReset`
→ SQL-Agent job → `reset.spInternal_*` pipeline) works end-to-end **before** it is
trusted on prod. It runs entirely on **vm-sql-test1**, whose worker has no live
marketplace/shop credentials, so a mistake here cannot reach real customers.

> [!CAUTION]
> This runbook clones a database and registers a mandant. Run it **only on
> vm-sql-test1**. The whole point of validating on test1 is that its worker is
> harmless — never rehearse this against prod (vm-sql2).

- **Applies to:** the Ebene-B `global` chain (`RoboticoOps` DB) plus the Ebene-A
  chain on the clone. See the plan §3 for the SP pipeline.
- **Prerequisites:** the `global` chain deployed to test1 (`RoboticoOps` exists,
  reset SPs + SQL-Agent job installed); Windows auth; `sqlcmd` read access for the
  checks. The reset SP names below are the plan's §3 objects.
- **Reference:** [`db-migrations/README.md`](../../db-migrations/README.md),
  plan `docs/plans/2026-07-10 - mssql-ops-infrastruktur`.

---

## Step 0 — Preconditions (verify before touching anything)

> [!IMPORTANT]
> The worker service on the test1 host must be **fully stopped** (as a Windows
> service — "disable in config" is not enough; see `research/4-jtl-spezifika` §3).
> A freshly registered mandant must never be visible to a running worker. Open
> question O2 (does the worker pick up a new `tMandant` row immediately?) is not
> yet answered — until it is, "worker stopped" is a hard gate, not a nicety.

Checks (read-only):

```bash
# test1 has one real mandant + no tm clone yet — confirm the starting shape:
/opt/mssql-tools18/bin/sqlcmd -S vm-sql-test1.zdbikes.local -E -C \
    -d eazybusiness -Q "SELECT kMandant, cName FROM dbo.tMandant ORDER BY kMandant;"

# RoboticoOps + the reset SPs must exist (global chain deployed):
/opt/mssql-tools18/bin/sqlcmd -S vm-sql-test1.zdbikes.local -E -C \
    -d RoboticoOps -Q "SELECT name FROM sys.procedures WHERE name LIKE 'spPub_StartTestmandantReset' OR name LIKE 'spPub_GetResetStatus';"
```

## Step 1 — Seed a validation mandant in `ops.tMandant`

test1 has only 1 mandant and no `tm*` clone, so the validation uses a dedicated
throwaway mandant **`tm9`** (a deliberately high number that won't collide with
the real `tm1`/`tm2` mandants), cloned from test1's own `eazybusiness`, targeting
a fresh DB `eazybusiness_tm9`.

**Preferred — one call via `reset.spPub_CreateTestmandant` (admin):** register the mandant AND
kick its first reset (which builds the clone) in a single step, instead of a manual
`INSERT` + separate `spPub_StartTestmandantReset`:

```sql
-- run against RoboticoOps, as an ops_admin member
EXEC reset.spPub_CreateTestmandant @MandantKey = N'tm9', @DisplayName = N'Reset validation';
-- registers ops.tMandant (cLoginName / cShopLicense default to the 0020 template + sentinel;
-- pass @LoginName / @ShopUrl / @ShopLicense to override) and returns {kResetRequest, cStatus}.
-- Steps 2–3 (Agent + trigger) are then already done — skip to Step 4 (watch progress).
```

or via the wrapper: `npm run db:mandant:create -- -Environment TEST -MandantKey tm9 -DisplayName "Reset validation"`.
An existing key is a hard error (no silent upsert); corrections go through an admin `UPDATE`.

**Manual alternative** (if you only want to register without resetting, e.g. to inspect the
row first): insert one `ops.tMandant` row for `tm9` (`bActive = 1`, `cTargetDb =
'eazybusiness_tm9'`, `cDeveloper`/`cDisplayName`/`cLoginName`/`cShopUrl`/`cShopLicense`
per the seed template — use the staging shop license, never a prod key committed
to git; see plan D8), or call `spPub_CreateTestmandant … @StartReset = 0`. Do this with the same
seed mechanism the rollout runbook uses; do not hand-edit prod data.

> [!NOTE]
> Two shape constraints gate the seed row. `cMandantKey` must match `tm[0-9]%`
> (`CK_tMandant_cMandantKey`) — a non-numeric key like `tmv` is rejected at
> insert, so use a `tm<digit>` key such as `tm9`. `cTargetDb` must match
> `eazybusiness[_]%` and must never equal `eazybusiness`; the reset refuses
> `eazybusiness` as a target in three independent places (CHECK constraint,
> Start-SP validation, job re-validation, plan D6). `tm9` / `eazybusiness_tm9`
> exercises the happy path without tripping either guard.

## Step 2 — Enable the SQL-Agent

test1's SQL-Agent is Stopped/Manual by default (survey §4). The reset job runs
under the Agent, so start it for the duration of the test:

- Start the SQL Server Agent service on the test1 host.
- Confirm the reset job exists: job name `RoboticoOps - Testmandant Reset`.

## Step 3 — Trigger the reset

```sql
-- run against RoboticoOps
EXEC reset.spPub_StartTestmandantReset @MandantKey = N'tm9';
-- returns: kResetRequest, cStatus='queued'
-- Idempotent (OPS-6): calling it again while tm9 is still queued/running returns the
-- SAME in-flight kResetRequest + its cStatus instead of erroring — safe to re-run.
```

Then poll status until it reaches `succeeded` or `failed`:

```sql
EXEC reset.spPub_GetResetStatus @MandantKey = N'tm9';
-- watch cStatus + cStepLog. Before each step the orchestrator writes a
-- "starting step N: spInternal_<Name>" line (OPS-3), so live progress and — on a
-- failure — the exact step that broke are visible. Default order:
--   clone -> post-restore-security -> invalidate-credentials -> neutralize-worker
--   -> anonymize -> grant-access -> register-mandant -> apply-roles
```

To discover which mandant keys exist without `ops_admin` rights (e.g. on prod), a
colleague can run `EXEC reset.spPub_ListMandants;` (OPS-1) — it lists `cMandantKey`,
`cDisplayName`, `cDeveloper`, `cTargetDb`, `bActive` and the last reset's status, and
deliberately shows no shop license/URL.

## Step 4 — Verify the outcome

Run each check read-only against the **clone** (`-d eazybusiness_tm9`) unless noted.

### 4.1 Request status

`spPub_GetResetStatus` shows `cStatus = 'succeeded'`, a populated `cStepLog` with every
pipeline step, and a non-null `dFinished`. No `cErrorMessage`.

### 4.2 Clone exists and is version-correct

```sql
SELECT DB_NAME() AS db,
       (SELECT cVersion FROM dbo.tVersion) AS jtl_version;  -- expect 2.0.5.0
```

> [!NOTE]
> The JTL version column is **`cVersion`** (`nvarchar`, e.g. `2.0.5.0`) — verified
> against the live test1 schema on 2026-07-13. There is no `nVersion` column.

### 4.3 Worker neutralisation (D9)

```sql
-- eBay account locked:
SELECT nGesperrt FROM dbo.ebay_user;                 -- expect 1 (or 0 rows)
-- Amazon/platform accounts locked (guarded — table may be empty on test1, see O4):
SELECT COUNT(*) AS pf_rows,
       SUM(CASE WHEN nGesperrt=1 AND nAktiv=0 THEN 1 ELSE 0 END) AS locked
FROM dbo.pf_user;                                    -- expect pf_rows = locked
-- Queues drained (must all be 0):
SELECT 'tQueue' q, COUNT(*) n FROM dbo.tQueue
UNION ALL SELECT 'tWorkflowQueue', COUNT(*) FROM dbo.tWorkflowQueue
UNION ALL SELECT 'ebay_usermessagequeue', COUNT(*) FROM dbo.ebay_usermessagequeue
UNION ALL SELECT 'ebay_queue_out', COUNT(*) FROM dbo.ebay_queue_out
UNION ALL SELECT 'tGlobalsQueue', COUNT(*) FROM dbo.tGlobalsQueue
UNION ALL SELECT 'tDruckQueue', COUNT(*) FROM dbo.tDruckQueue;
```

Cross-check completeness with
[`../../db-migrations/tests/probes/04_queue_inventory.sql`](../../db-migrations/tests/probes/04_queue_inventory.sql):
every **non-empty** queue it lists must be in the drain set above. As of the
2026-07-10 probe run that set was complete on test1.

> [!NOTE]
> `Worker.tTarget` is deliberately **not** touched (plan D9, open question O1 —
> the `nAbgleichstyp` enum has no DB-side lookup, so its semantics are
> unconfirmed). Do not add a tTarget check that expects it changed; expect it
> **unchanged** from the source DB. See
> [`../../db-migrations/tests/probes/01_worker_ttarget_semantics.sql`](../../db-migrations/tests/probes/01_worker_ttarget_semantics.sql).

### 4.4 Credential invalidation + shop repoint

Spot-check that SMTP passwords are blanked and the shop URL points at staging
(not the live shop), per the ported `invalidate-credentials` logic. Check24/unicorn2
(`nTyp <> 0`) must be **untouched**.

### 4.5 Customer-data anonymisation

Spot-check a few `dbo.tKunde` / address rows: names/emails/phone cleared per the
ported `clear-customer-fields` blocks. The pipeline anonymises inside a
CONTEXT_INFO trigger-bypass; a partial anonymisation must have failed the whole
request (CATCH), so `succeeded` implies all 11 blocks ran.

### 4.6 Registration + access

`eazybusiness_tm9` appears as a mandant (`dbo.tMandant` upsert) and the configured
`cLoginName` has access (JTL roles applied). The WaWi client can log into `tm9`
(manual — this also partly answers O2: note whether the just-registered mandant
is visible/where the worker would have picked it up, but keep the worker stopped).

## Step 5 — Record open-question outcomes

Update the plan's Open Questions with what this run showed:

| Q | Expectation on test1 | How this run confirms it |
|---|---|---|
| O1 | `Worker.tTarget` unchanged by reset | 4.3 note — tTarget identical to source |
| O2 | worker does not auto-service `tm9` while stopped | Step 0 gate + 4.6 observation (needs the manual probe `02_worker_discovery.md` for the running-worker case) |
| O4 | `pf_user` guard no-ops cleanly when empty | 4.3 — pf_rows may be 0 on test1; step still succeeds |

## Step 6 — Rollback / cleanup

The validation mandant is throwaway. After the run:

```sql
-- remove the mandant registration from the real test1 eazybusiness:
--   DELETE dbo.tMandant WHERE cDB = 'eazybusiness_tm9';   (manual, reviewed)
-- drop the clone:
--   ALTER DATABASE [eazybusiness_tm9] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
--   DROP DATABASE [eazybusiness_tm9];
```

Optionally clear the `tm9` `ops.tResetRequest` history. For routine retention (not this
throwaway run) an admin can trim the audit log with `EXEC reset.spPub_PurgeOldRequests
@KeepPerMandant = 20;` — it keeps the newest N rows per mandant and never deletes a
`queued`/`running` row (OPS-5; run with `@WhatIf = 1` first to preview the count). Set the
`ops.tMandant` `tm9` row `bActive = 0` (or delete it) so it can't be reset again by accident.
Stop the SQL-Agent again if test1 should return to its Stopped/Manual baseline.

---

## Failure modes

> [!WARNING]
> **Request stuck in `running`.** If the Agent job dies mid-pipeline, the request
> stays `running` and the Start-SP returns that in-flight request instead of queuing a
> new one for `tm9`. The pipeline auto-reclaims `running` rows older than
> `ops.tConfig('StaleRunningHours')` (default 4h) as `failed` on its next start. To
> recover **sooner** without server rights (OPS-2), a colleague runs:
>
> ```sql
> EXEC reset.spPub_CancelResetRequest @RequestId = <id>;   -- id from spPub_GetResetStatus
> ```
>
> It cancels a `queued` request outright, and force-reclaims a `running` one to
> `failed` **only** when the reset job is not actually executing (it checks msdb job
> activity first), so a genuinely-running clone is never yanked. If the job *is* still
> running it refuses with a clear message. After a successful cancel, re-trigger. An
> `ops_admin` can alternatively hand-fix the row (it now has `UPDATE` on
> `ops.tResetRequest`); no raw sysadmin is required.

> [!WARNING]
> **Clone left behind after a failure.** On CATCH the clone DB is left as-is for
> diagnosis (MULTI_USER ensured). Inspect it, then drop it (Step 6) before
> re-running — a stale `eazybusiness_tm9` will collide with the next clone.

> [!CAUTION]
> **Never run this with the worker running against real accounts.** If test1's
> worker ever gains live credentials, this runbook stops being safe. The Step 0
> "worker stopped" gate is the load-bearing precondition, not a formality.
