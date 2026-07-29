---
name: instanz-survey-test1-prod
description: Read-only survey of the instances vm-sql-test1 (SQL 2025) and vm-sql2 (SQL 2022) — versions, DBs, principals, jobs, worker flags (2026-07-09)
status: Research
---

# Current State of the SQL Instances — Survey for the Migration Design

> Source: Opus agent "sql-survey", session 2026-07-09, via sqlcmd/Kerberos (`/opt/mssql-tools*/bin/sqlcmd -S <host> -E -C`), strictly read-only.
> Access gotcha: the go-sqlcmd at `/usr/local/bin/sqlcmd` CANNOT do Kerberos — use the ODBC sqlcmd.

Both instances reachable: `vm-sql-test1.zdbikes.local`, `vm-sql2.zdbikes.local` (also `VM-SQL2`/`vm-sql2`).

## 1. Instance basics

| | **vm-sql-test1** (test) | **vm-sql2** (prod) |
|---|---|---|
| ProductVersion | **17.0.1000.7 → SQL Server 2025** | **16.0.4225.2 → SQL Server 2022** |
| Edition | Developer | Standard |
| ProductLevel | RTM | RTM (CU/GDR level) |
| Collation | Latin1_General_CI_AS | Latin1_General_CI_AS |
| @@SERVERNAME | VM-SQL-TEST1 | VM-SQL2 |
| Auth | Mixed | Mixed |

**test1 is the NEWER version — a central restriction, see the assessment.**

## 2. Databases

**test1** (instance directory `MSSQL17.MSSQLSERVER`, everything SIMPLE):
| DB | Recovery | Compat | Size ROWS/LOG | Owner |
|---|---|---|---|---|
| eazybusiness | SIMPLE | **170** | 27,240 / 1 MB | WIN-UHHQ6G7KDOG\Administrator |
| eazybusiness_e2e_r3_pre_snap | SIMPLE | 170 | 27,240 MB | same |

**prod** (`MSSQL16.MSSQLSERVER`; production DBs FULL):
| DB | Recovery | Compat | Size | Owner |
|---|---|---|---|---|
| eazybusiness | **FULL** | **160** | 27,240 / 4,301 MB | ZDBIKES\lukas |
| eazybusiness_premig | FULL | 160 | same as prod (in `E:\Backup\`!) | ZDBIKES\lukas |
| eazybusiness_tm2 | SIMPLE | 160 | 36,740 MB | ZDBIKES\lukas |
| eazybusiness_tm3 | SIMPLE | 160 | 27,240 MB | ZDBIKES\sanda |
| eazybusiness_tm4 | SIMPLE | 160 | 27,240 MB | ZDBIKES\lukas |
| ersatzteile_prod / _latest / _old_bis_2026_03_03 | FULL/SIMPLE | 150 | ~1 GB each | lukas / dana login |
| HbDat001 | FULL | 150 | 1,352 MB | ZDBIKES\lukas |

## 3. Server principals & roles

**test1** — lean: SQL logins only `sa` + `ekl_testmssql_app` (2026-06-23). Windows: ZDBIKES\lukas, groups `sql-admins`, `sql-jtl-users`, local admin, service accounts. sysadmin: sa, lukas, sql-admins, local admin, service accounts.

**prod** — 16 SQL logins (`dbuser_eazybusiness_jtl`, `_jtl_cli`, `_greyhound`, `_powershell`, `_docker1`, `_datawow`, `dbuser_eazybusiness_ekl_addin_*` [backend/readonly/testdb], `dbuser_dev_*`, `dbuser_ersatzteile_prod_scraper`, `dbuser_HbDat001_alfbanco`). Windows: lukas, aylin, kiana, sanda + groups. **sysadmin: contains the SQL login `dbuser_dev_dana_for_jtl` (a dev account with full server authority!)**. dbcreator: dbuser_dev_dana_for_development, dbuser_dev_dana_for_jtl, dbuser_eazybusiness_jtl, ZDBIKES\sanda.

## 4. SQL Agent

| | test1 | prod |
|---|---|---|
| Service | **Stopped / Manual** | Running / Automatic |
| Jobs | only syspolicy_purge_history | 11 Ola Hallengren jobs *installed* (DatabaseBackup FULL/DIFF/LOG USER+SYSTEM, IndexOptimize, IntegrityCheck, cleanups) |
| Proxies | none | none |

> [!WARNING]
> **Correction 2026-07-21 (live re-check):** the row above counts job *existence*, not execution. In fact **exactly one** of the 11 Ola jobs has a schedule (`IndexOptimize`, daily 04:00) — and it **has been failing daily since ~2025-11-27** (`dbo.IndexOptimize` no longer exists). `DatabaseIntegrityCheck`/CHECKDB last ran **2024-06-24** (a single time), backups run externally via CBB (not Ola). Full current-state analysis: [`6-wartung-ist-analyse`](../6-wartung-ist-analyse/6-wartung-ist-analyse.md).

→ Backups on prod do run (externally via CBB); **effective SQL maintenance does not in fact exist** (see the correction above). test1 has no maintenance/backups whatsoever.

## 5. Certificates (master)

Both: only MS system certificates (`##MS_*##`). **No application-owned certificates** — module signing starts on a greenfield.

## 6. eazybusiness DBs in detail

**JTL schema version (dbo.tVersion):** **2.0.5.0** throughout (test1, prod, _premig, _tm3, _tm4). Outlier: **_tm2 = 1.11.6.0**.

**Mandants (dbo.tMandant):** test1: 1 mandant ("TEST-DB: eB-Standard"). prod: 4 — 1 eB-Standard→eazybusiness, 3 Testmandant2(Dana)→_tm2, 4 Testmandant3(Sanda/Lukas)→_tm3, 5 Testmandant4(Lukas)→_tm4.

**Own schemas** (both instances): Robotico, RoboticoEKL, CustomWorkflows. Object divergence (test1 is ahead): RoboticoEKL 18/17/14 (tables/procs/views) vs. prod 17/16/13; table present only on test1: `RoboticoEKL.tArticleLabelCategory`. CustomWorkflows: 14 (test1) vs. 15 (prod) procs. Robotico identical (4 tables / 10 fns / 6 procs). Schema owner of RoboticoEKL: test1=`ekl_testmssql_app`, prod=`dbuser_eazybusiness_ekl_addin_backend`; Robotico/CustomWorkflows=dbo.

**Migration journal found: `RoboticoEKL.tMigrationHistory`** (kMigration, nVersion, cFileName, cChecksum, dApplied, nDurationMs, cAppliedBy, bSuccess, cErrorMessage) — the runner of the excel_ekl repo:
- test1: **25 migrations**, highest `025_label_family_and_delta` (2026-07-05), all bSuccess=1.
- prod: **24 migrations**, highest `024_workflow_kbenutzer_string` (2026-07-02).
- → test1 runs exactly one migration ahead of prod; this explains the object divergence. **A script-based test1→prod flow is established in-house.** Robotico and CustomWorkflows have NO journal of their own.

## 7. Worker/sync configuration (prod/eazybusiness)

**Per-account lock/sync flags:**
- **`dbo.ebay_user`**: `nGesperrt`, `dLetzerEbayAbgleich`, `dLetzterBestellabgleich`, `nOutOfStockControl`, `nLagerbestaendeAendern` — 1 account, nGesperrt=0.
- **`dbo.pf_user`** (Amazon/platform): `nGesperrt`, `nAktiv`, `dVcsSperreUtc`/`dVcsLiteSperreUtc`, `nIsTerminated` — **0 rows in the main DB** (Amazon accounts may exist only in the mandant DBs, or are not set up).
- **`dbo.tShop`**: `nAktiv`, `nGesperrt` — 2 shops: "robotico" (active, open), "unicorn 2: Check24" (active, **locked**).
- **`Worker.tTarget`** (sync targets): uTargetId, kMandant, nAbgleichstyp, kZiel — 10 rows, all kMandant=1, nAbgleichstyp ∈ {0,2,3,4,5,7,8,13,17,18}, kZiel mostly -1 (wildcard). JTL-side control over which sync types run per mandant.

**Queue row counts (partition_stats):** tQueue 9,759, tWorkflowQueue 5,266, ebay_usermessagequeue 1,337, tGlobalsQueue 1,221, tDruckQueue 33, ebay_queue_out 4; Amazon/FulfillmentNetwork/SCX/Pos queues = 0.

## 8. RoboticoOps pre-check

**A clean field** — no DB/schema/objects named RoboticoOps/Ops/Admin on either instance.

## Assessment for the migration design

**Version parity (critical):** restore only old→new:
- prod (2022) → test1 (2025): **works** (test-data refresh possible; compat stays at 160 until raised manually).
- test1 (2025) → prod (2022): **impossible** (no downgrade restore/attach).
- **Consequence:** "test on test1, then prod" is viable ONLY on a script/migration basis (exactly the established RoboticoEKL pattern). No rollout may ever presuppose a test1 DB image.

**What is missing/different on test1:** no running Agent, no backups/maintenance, 1 instead of 4 mandants, no tm setup, lean principals. test1 acts as a pure RoboticoEKL lead-in/E2E system.

**Anomalies (hygiene):**
- The SQL login `dbuser_dev_dana_for_jtl` is **sysadmin on prod**.
- `eazybusiness_tm2` is on the old JTL level 1.11.6.0.
- `eazybusiness_premig` physically resides in `E:\Backup\` (FULL recovery).
- Third-party DBs (ersatzteile_prod*, HbDat001) on the prod instance — resource/maintenance planning.

## Open points

- Exact prod CU level vs. test1 RTM if needed; the fundamental old→new statement stands.
- `pf_user` empty: check the Amazon accounts in the `_tm*` DBs.
- The `_tm*` DBs were not checked for their RoboticoEKL migration levels.
- The `cAppliedBy`/checksums of the EKL migrations were not read out.
- Clarify the semantics of the `Worker.tTarget.nAbgleichstyp` values (sample list).
