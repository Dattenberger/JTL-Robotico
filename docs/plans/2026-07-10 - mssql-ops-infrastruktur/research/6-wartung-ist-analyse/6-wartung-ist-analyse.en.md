---
date: 2026-07-21
author: Lukas + Claude Code
status: Research
context: Live as-is analysis of SQL Server maintenance on vm-sql2 (PROD) — what is installed from Ola Hallengren vs. what actually runs, as the basis for a sustainable, versioned maintenance infrastructure.
related-plan: ../../mssql-ops-infrastruktur.md
related-adrs: —
---

This research file records the **actual** maintenance state of the production instance `vm-sql2` — collected live and read-only on 2026-07-21. It corrects the claim from [`2-instanz-survey`](../2-instanz-survey/2-instanz-survey.md) §4 (“prod has a working backup chain / 11 Ola Hallengren jobs”), which **confused job existence with job execution**. It describes the as-is state and the consequences that follow for the target design — the concrete target design (maintenance-as-code in RoboticoOps) belongs in an ADR + implementation plan, not here.

## 1. Vision and Motivation

### 1.1 Why this analysis exists

The question “should we set up reindexing/CHECKDB as regular jobs?” (from a parallel session) assumed that no maintenance exists on prod yet. The instance survey claimed the opposite (“11 Ola Hallengren jobs, working backup chain”). **Both assumptions are partly wrong** — and the difference decides whether we *build something new* or *repair something existing and lift it into our infrastructure*. This file establishes the verified as-is state.

### 1.2 What problem this solves

- Prevents us from planning on the basis of the wrong survey line (building something new that partly exists — or assuming something runs that has been failing for months).
- Makes the **silent maintenance gap** visible: a job that fails daily and that nobody has noticed for ~8 months, and an integrity check that has not run for ~2 years.
- Delivers the measurements (fragmentation, DB sizes, recovery models) on which the threshold and scope decisions of the target design can be founded.

### 1.3 Rejected interpretations

- **“Prod runs 11 Ola jobs” (survey §4)** — rejected: it counts entries in `msdb.dbo.sysjobs`, not schedules/history. Of the 11 jobs exactly **one** has a schedule, and that one fails.
- **“The Ola tools are installed but not used yet” (Lukas' assumption)** — almost correct: they are installed and *one* job is even scheduled — it has just been broken since ~2025-11-27. More precisely: installed, largely unused, and the one part in use is defective.

## 2. Findings + Conclusions

Numbered core findings (evidence in §3.2):

1. **F1 — Backups are healthy, but NOT via Ola.** The backup chain runs externally (CBB): `eazybusiness` full daily at 03:00, diff, T-log every ~15 min (last T-log 2026-07-21 11:45). The Ola `DatabaseBackup` jobs have **no schedule** and have **never run**. → Backups are **not** a gap.
2. **F2 — Index maintenance is broken.** `IndexOptimize - USER_DATABASES` is the only maintenance job with a daily schedule (04:00), **but it has failed every single day since ~2025-11-27** with `Fehler 2812: gespeicherte Prozedur "dbo.IndexOptimize" wurde nicht gefunden` (error 2812: stored procedure "dbo.IndexOptimize" not found). The procedure no longer exists **anywhere on the instance**.
3. **F3 — CHECKDB effectively never runs.** `DatabaseIntegrityCheck` (proc + jobs) is installed, but **without a schedule**. Last actual run: **2024-06-24** (a single time, presumably an install test). System DBs (incl. `msdb` — home of our job/signature infrastructure): **never**. → ~2 years without a consistency check.
4. **F4 — Cleanups never run.** `CommandLog Cleanup`, `Output File Cleanup`, `sp_delete_backuphistory`, `sp_purge_jobhistory`: all unscheduled, never run.
5. **F5 — The wrong installation location is the likely cause of F2.** The Ola objects live in **`eazybusiness.dbo`** (the JTL vendor DB), not in a dedicated ops DB. A DB refresh / (partial) reinstall around 2025-11-27 took `IndexOptimize` + `CommandExecute` with it; `CommandLog`/`DatabaseBackup`/`DatabaseIntegrityCheck` were left behind. Objects in the vendor DB can be destroyed by vendor operations.
6. **F6 — No failure alerting.** No operator/Database Mail attached to the jobs → the daily failure from F2 went unnoticed for ~8 months. This matches the open OPS-4 gap (`NotifyOperator`) of the reset infrastructure.
7. **F7 — Index maintenance is low-ROI here anyway.** `eazybusiness` (22.8 GB) has **no** index above 30 % fragmentation (>1,000 pages): 92 indexes at 5–30 % (5.8 GB), 48 below 5 % (4.8 GB) — and that **after** ~8 months without index maintenance. The real lever is **CHECKDB + statistics**, not defragmentation.
8. **F8 — Even the (broken) index maintenance maintained no statistics.** The job step calls `IndexOptimize @Databases='USER_DATABASES', @LogToTable='Y'` without `@UpdateStatistics` → a statistics update was never part of the run.
9. **F9 — RoboticoOps does not (yet) exist on prod.** The ops DB exists only on test1. “Maintenance in RoboticoOps” presupposes the global prod cutover — the same milestone the entire ops infrastructure needs anyway.

**Conclusion:** the survey's phrase “working maintenance” is wrong for everything except the (external) backups. Effective maintenance on vm-sql2 today consists of **nothing** — one job fails daily, CHECKDB has been silent for two years, and nobody gets alerted. The three root defects to fix: **the wrong location** (vendor DB), **unversioned/not reproducible** (click ops), **no alerting**.

## 3. Body

### 3.1 Methodology

All queries read-only, metadata only, against `vm-sql2.zdbikes.local` via Kerberos ODBC sqlcmd (`/opt/mssql-tools18/bin/sqlcmd -E -C`), on 2026-07-21. No payload data read, no changes made. Sources inspected: `sys.dm_server_services`, `msdb.dbo.sysjobs` / `sysjobsteps` / `sysjobschedules` / `sysschedules` / `sysjobhistory`, `sys.databases` / `sys.master_files`, `<db>.sys.objects`, `msdb.dbo.backupset`, `sys.dm_db_index_physical_stats(..., 'LIMITED')`, `eazybusiness.dbo.CommandLog`.

Reproduction (example — job/schedule status):

```sql
SELECT j.name, j.enabled, s.name AS schedule, s.enabled AS sch_on
FROM msdb.dbo.sysjobs j
LEFT JOIN msdb.dbo.sysjobschedules js ON j.job_id = js.job_id
LEFT JOIN msdb.dbo.sysschedules   s  ON js.schedule_id = s.schedule_id
ORDER BY j.name;
```

### 3.2 Data

**Instance:** `VM-SQL2`, SQL Server 2022 `16.0.4225.2`, **Standard Edition**. SQL Server Agent: **Running / Automatic**.

**Agent jobs — schedule + actual execution:**

| Job | enabled | Schedule | Last run | Outcome |
|---|:---:|---|---|---|
| `IndexOptimize - USER_DATABASES` | 1 | **daily 04:00** | 2026-07-21 04:00 | ❌ **error 2812** (daily) |
| `DatabaseIntegrityCheck - USER_DATABASES` | 1 | — none — | 2024-06-24 (1×) | (one-off) |
| `DatabaseIntegrityCheck - SYSTEM_DATABASES` | 1 | — none — | never | — |
| `DatabaseBackup - USER_DATABASES - FULL/DIFF/LOG` | 1 | — none — | never | — |
| `DatabaseBackup - SYSTEM_DATABASES - FULL` | 1 | — none — | never | — |
| `CommandLog Cleanup` | 1 | — none — | never | — |
| `Output File Cleanup` | 1 | — none — | never | — |
| `sp_delete_backuphistory` / `sp_purge_jobhistory` | 1 | — none — | never | — |
| `syspolicy_purge_history` (system) | 1 | daily 02:00 | 2026-07-21 02:00 | ✅ |

> [!CAUTION]
> `IndexOptimize` runs into the void every day. Full message of the last run (verbatim from the German-locale instance):
> `Ausgeführt als Benutzer: 'NT SERVICE\SQLSERVERAGENT'. Die gespeicherte Prozedur "dbo.IndexOptimize" wurde nicht gefunden. [SQLSTATE 42000] (Fehler 2812). Fehler bei Schritt.`
> Instance-wide cross-check (all DBs): `IndexOptimize` and `CommandExecute` exist **nowhere**.

**Ola objects (actual inventory in `eazybusiness.dbo`, `create_date 2024-06-24`):**

| Object | Type | present? |
|---|---|:---:|
| `CommandLog` | table | ✅ |
| `DatabaseBackup` | proc | ✅ |
| `DatabaseIntegrityCheck` | proc | ✅ |
| `IndexOptimize` | proc | ❌ **missing** |
| `CommandExecute` | proc | ❌ **missing** (required by IndexOptimize) |

`CommandLog`: 9,218 rows, oldest entry 2024-06-24, **most recent entry 2025-11-27 04:01** → no logged Ola operation since that date (consistent with the disappearance of `IndexOptimize`).

**Backup reality for `eazybusiness` (last 14 days, external via CBB):**

| Type | Last backup | Count/14 d |
|---|---|---:|
| D (full) | 2026-07-21 03:00 | 41 |
| I (diff) | 2026-07-21 09:00 | 140 |
| L (log) | 2026-07-21 11:45 | 881 (~every 15 min) |

**DB inventory (user DBs, `USER_DATABASES` scope):**

| DB | Recovery | Size (MB) |
|---|---|---:|
| `eazybusiness` | FULL | 22,800.8 |
| `eazybusiness_tm2` / `_tm3` / `_tm4` | SIMPLE | 20,100 / 16,100 / 16,100 |
| `EKL` / `EKL_preRebuild` | FULL | 1,552 / 272 |
| `ersatzteile_prod` / `_latest` | FULL | 1,424 / 6,480 |
| `ersatzteile_prod_old_bis_2026_…` | SIMPLE | 912 |
| `HbDat001` | FULL | 1,616 |

**`RoboticoOps`:** **not present** on vm-sql2 (test1 only).

**Fragmentation of `eazybusiness` (`sys.dm_db_index_physical_stats` LIMITED, >1,000 pages, `index_id>0`):**

| Fragmentation | Indexes | Data volume |
|---|---:|---:|
| > 30 % | **0** | — |
| 5–30 % | 92 | 5,783 MB |
| < 5 % | 48 | 4,773 MB |

**Job owner:** all maintenance jobs run as `sa`.

### 3.3 Consequences for the target design (brief — detail in the ADR/plan)

- **Location:** the Ola objects belong in **`RoboticoOps`** (level B), not in `eazybusiness` (F5). Presupposes the prod cutover of RoboticoOps (F9) — the same milestone as the rest of the ops chain.
- **Reproducibility:** Ola as a **pinned vendor version inside the `up/` script**; jobs created idempotently by migration (`spEnsureMaintenanceJobs`, analogous to `reset.spEnsureAgentJob`), **with a schedule**.
- **Parameters:** CHECKDB weekly for user **and system** databases (F3); IndexOptimize threshold-based **incl. `@UpdateStatistics='ALL'`** (F7/F8) — weekly is enough, statistics are the lever; enable the cleanups (F4).
- **Alerting:** failure mail via the already-wired `NotifyOperator`/Database Mail rail (F6).
- **Scope:** include `RoboticoOps` itself in backup + CHECKDB (it holds config + secrets). Decide deliberately whether the `_tm*` clones should be in the CHECKDB scope.

## 4. Information Gaps

1. **Ola version** — not readable from the existing objects (the version string is not in the expected place; `IndexOptimize`, its usual carrier, is missing). *Owner:* implementation plan — we pin our own vendored version anyway, so this is not critical.
2. **Root cause of the 2025-11-27 breakage** — “DB refresh / partial reinstall” is the most plausible explanation, but it is not proven (no change log was inspected). *Owner:* optional; irrelevant to the solution, since the new location (RoboticoOps) structurally prevents a recurrence. *Fallback:* marked as a hypothesis.
3. **Maintenance claim for `ersatzteile_prod*` / `HbDat001` / `EKL`** — these foreign DBs have not fallen into our scope so far; whether they should be maintained as well is a product/ownership question. *Owner:* Lukas. *Fallback:* the target design starts with `eazybusiness` + `RoboticoOps` + system DBs.

## 5. Change History

### 2026-07-21 — Initial version

- **Trigger:** Lukas' doubts about the claim “prod runs Ola Hallengren jobs” (session mssql-ops-infrastruktur).
- **Reasoning:** a live read-only survey against vm-sql2 showed that job existence ≠ job execution; a daily-failing IndexOptimize + no CHECKDB since 2024.
- **What changed:** new research file; corrects [`2-instanz-survey`](../2-instanz-survey/2-instanz-survey.md) §4 and its §4 conclusion.

## 6. References

- Plan: [`mssql-ops-infrastruktur.md`](../../mssql-ops-infrastruktur.md)
- Corrects: [`2-instanz-survey/2-instanz-survey.md`](../2-instanz-survey/2-instanz-survey.md) §4 (SQL Agent)
- Related: [`3-module-signing-agent-job`](../3-module-signing-agent-job/3-module-signing-agent-job.md) (the pattern for signed, sa-owned Agent jobs — the model for `spEnsureMaintenanceJobs`)
- OPS-4 / `NotifyOperator`: `db-migrations/README.md` §Config; `db-migrations/global/runAfterOtherAnyTimeScripts/reset.spEnsureAgentJob.sql`
- Ola Hallengren Maintenance Solution: https://ola.hallengren.com/
