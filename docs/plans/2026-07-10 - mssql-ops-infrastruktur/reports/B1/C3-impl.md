# C3 — Read-only probes (§4) + hygiene/cleanup (§6) + runbooks — impl report

**Chunk:** C3 · **Block:** B1 · **Date:** 2026-07-10

## What I did

Created the §4 read-only probe suite (4 probes + validation runbook) and the §6
hygiene/cleanup scripts (3 scripts + runbook). Ran all read-only probes against
vm-sql-test1 and recorded the results in-file and in the plan's Open Questions
(O1/O2/O4). No writes were issued against any SQL server.

## Files created

**§4 probes:**
- `db-migrations/tests/probes/01_worker_ttarget_semantics.sql` — Worker.tTarget survey (O1)
- `db-migrations/tests/probes/02_worker_discovery.md` — manual running-worker probe (O2)
- `db-migrations/tests/probes/03_pf_user_in_clones.sql` — pf_user per DB (O4)
- `db-migrations/tests/probes/04_queue_inventory.sql` — queue-table inventory per DB
- `docs/runbooks/testmandant-reset-validierung.md` — E2E validation runbook

**§6 hygiene:**
- `Berechtigungen/cleanup/01_dana_sysadmin_review.sql`
- `Berechtigungen/cleanup/02_tm2_refresh.md`
- `Berechtigungen/cleanup/03_premig_db.sql`
- `docs/runbooks/hygiene-findings.md`

**Edited:** `docs/plans/2026-07-10 - mssql-ops-infrastruktur/mssql-ops-infrastruktur.md`
— appended C3 probe outcomes under O1/O2/O4.

## Probe results (read-only, vm-sql-test1, 2026-07-10)

- **O1 / Worker.tTarget:** 10 rows, all kMandant=1, nAbgleichstyp ∈
  {0,2,3,4,5,7,8,13,17,18}, kZiel=1 for type 0 else -1 (matches prod survey). No
  DB-side lookup (`Sync.tSyncType` exists but is EMPTY) → semantics stay
  JTL-internal; **D9 (leave tTarget untouched) confirmed.** O1 = needs JTL-side
  clarification.
- **O2 / worker discovery:** cannot be answered read-only (needs a running
  worker) → written up as manual probe `02_worker_discovery.md`. Marked "needs
  manual run".
- **O4 / pf_user:** 0 rows in both test1 DBs (`eazybusiness`,
  `eazybusiness_e2e_r3_pre_snap`). Prod tm* clones live on vm-sql2 (out of scope
  for this read-only-test1 session) → **needs manual run against prod.** Reset's
  guarded pf_user step no-ops on the empty table, so correct either way.
- **Queue inventory:** 23 queue tables. Non-empty on test1: tQueue (9765),
  ebay_usermessagequeue (1469), tGlobalsQueue (1221), tWorkflowQueue (~1209–1233),
  tDruckQueue (33), ebay_queue_out (4). **Every non-empty queue is in the reset
  drain list (D9) — COMPLETE.**

## Deviations

| Deviation | Plan location | What changed | Why | Impact on later chunks | Resolved? |
|---|---|---|---|---|---|
| Probes 03/04 iterate all `eazybusiness*` DBs themselves via a cursor (run from `-d master`) instead of one invocation per DB | §4 approach ("je DB" / "über alle eazybusiness*-DBs") | Single self-contained script covers every DB on the instance | Serviceability (D4): one call, no missed DB, safe to run on prod where clones live | none | ✅ |

## Issues

| ID | Severity | Description (what + file:line) | Status | Marker |
|---|---|---|---|---|
| — | — | none | — | — |

Minor limitation (documented in-file, not an issue): probe 03's CATCH branch
records an unreadable DB as `HasPfUserTable=0, RowCountTotal=NULL`, which is
indistinguishable from a genuinely table-less DB. Acceptable for a diagnostic
probe run by an admin login.

## Inline fixes applied

None — all files are new; no foreign code touched.

## Files outside assigned scope (drift)

- `docs/plans/2026-07-10 - mssql-ops-infrastruktur/mssql-ops-infrastruktur.md` —
  appended probe outcomes to O1/O2/O4. Rationale: §4 acceptance explicitly
  requires "O1/O2/O4 updated in the plan or marked 'needs manual run'".

## Test / lint result

`pwsh db-migrations/tests/lint-migrations.ps1` → **OK: 0 errors, 0 warnings**
(rule (f) confirms the §6 cleanup scripts have no un-commented writing statement).
All read-only probes executed successfully against vm-sql-test1 with no errors.

## Helper decisions

No new SQL helpers — probes are standalone catalog queries; cleanup scripts are
standalone read-only analyses with commented remediation.
