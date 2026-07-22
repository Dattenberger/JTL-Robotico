# Block Audit B1 — Topic: logic

**Date:** 2026-07-22T21:57:00+02:00 · **Block:** B1 · **Agent:** block-audit (logic) · **Verify base:** d722993

Grounding loaded: `knowledge-sql` (NULL safety, boundary/threshold patterns), `knowledge-jtl-sql`.

## Scope audited

| File | Logic-audited | Note |
|---|---|---|
| `maint.spEnsureMaintenanceJobs.sql` | full | sync/drift/running-guard/HHMMSS/schedule-mapping |
| `maint.spRunMaintenanceJob.sql` | full | dispatcher CASE matrix, cutoffs, watchdog chaining |
| `maint.spCheckBackupChain.sql` | full | parse/validate/freshness — **finding L-B1-1** |
| `maint.spCheckMaintenanceLiveness.sql` | full | CommandType mapping, freshness — **findings L-B1-2, L-B1-3** |
| `maint.spApplyMaintenance.sql` | full | MERGE guard (IS DISTINCT FROM), seed rows |
| `up/0023_maintenance_registry.sql` | full | CHECK constraints, OperationKnobs matrix |
| `permissions/260_maintenance_operator.sql` | full | operator/mail-profile guards — clean |
| `up/0022_maintenance_ola_vendor.sql` | **skipped** | pinned third-party Ola (5350 lines); logic not repo-owned |
| docs / validate_* / README | out of topic | belong to plan-and-api / convention topics |

---

## Findings

### L-B1-1 — `spCheckBackupChain` age test uses `DATEDIFF(HOUR)` (clock-boundary count, not elapsed time) → false STALE alarms, acute at `nLogMaxHours = 1`  — **Important**

`maint.spCheckBackupChain.sql` L77 (full) and L92 (log):

```sql
WHERE ... OR DATEDIFF(HOUR, f.dLastFull, @dNow) >= @FullMaxHours
WHERE ... OR DATEDIFF(HOUR, l.dLastLog,  @dNow) >= @LogMaxHours
```

`DATEDIFF(HOUR, a, b)` returns the number of **clock-hour boundaries crossed**, not the
number of elapsed hours. Two timestamps 10 minutes apart return `1` whenever they fall
in different clock-hours (`DATEDIFF(HOUR,'10:50','11:00') = 1`).

With the seeded `backup-watchdog` config `nLogMaxHours = 1` (spApplyMaintenance L47),
`eazybusiness` in FULL recovery, hourly CBB log backups and the hourly watchdog (anchor
00:00): whenever the newest log backup lands in the clock-hour **before** the watchdog
run — the normal steady state, roughly every hour — `DATEDIFF(HOUR) = 1 >= 1` fires a
`THROW 51100` STALE alarm on a log backup that is only minutes old. The watchdog for the
production ERP DB therefore false-alarms recurrently, training the operator to ignore
backup-chain mail — the exact "cry wolf" erosion the whole design exists to prevent.

**Failure scenario (concrete):** newest `eazybusiness` log backup `backup_finish_date =
2026-07-22 10:50:00`; watchdog runs `2026-07-22 11:00:05`. Real age = 10 min. `DATEDIFF(HOUR,
'10:50:00','11:00:05') = 1`; `1 >= @LogMaxHours(1)` → `THROW 51100 "STALE backup chain …
last LOG …"` → false NotifyOperator mail.

Note this is **plan-prescribed** (plan §AC5, line 42 literally specifies the `DATEDIFF(HOUR,
…) >= nLogMaxHours` formula), so it is a shared plan+implementation logic flaw, not an
impl deviation — flagging per the `logic` topic (boundary / off-by-one). The runbook
(Phase 4b step 4) already observes "the hourly log check can slip just over the 1-h
threshold" and recommends bumping `nLogMaxHours` to 2, but attributes it to CBB
serialization during the 03:00 full and treats a code bug as a config knob; raising to 2
only *masks* the boundary artefact (it does not make a 10-minute-old log read as fresh at
`=1`). The sibling proc `spCheckMaintenanceLiveness` (L59-62) already does the correct
thing with elapsed-time `DATEADD` comparison — the inconsistency confirms this is an
oversight.

**Suggested fix:** compare against an elapsed-time cutoff, mirroring the liveness proc and
preserving the AC5 ">= threshold alarms" boundary semantics:
```sql
-- full:  f.dLastFull <= DATEADD(HOUR, -@FullMaxHours, @dNow)   (NULL still alarms)
-- log:   l.dLastLog  <= DATEADD(HOUR, -@LogMaxHours,  @dNow)
```
(or `DATEDIFF(MINUTE, …, @dNow) >= @FullMaxHours * 60`). Requires a matching correction to
the plan's AC5 formula. Because the fix contradicts the plan's literal AC5 SQL, route as a
plan-deviation decision rather than a silent inline change.

---

### L-B1-2 — `spCheckMaintenanceLiveness` has no grace for freshly-enabled / newly-created jobs → false `51105` until the first run — **Nice-to-have**

`maint.spCheckMaintenanceLiveness.sql` L49-63 alarms for any effectively-enabled
`IntegrityCheck`/`IndexOptimize` row with no CommandLog entry inside its freshness window.
A job that was just enabled (bEnabled `0→1` via deploy) or created for the first time has
**no history yet** and is indistinguishable from a job that stopped running — the proc
cannot tell "never ran because just enabled" from "never runs (F3/F4)".

**Failure scenario:** operator enables `index-optimize` via git+deploy at 10:00; its next
scheduled run is 02:00. From the next hourly watchdog until 02:00 (≈16 h) the liveness
check `THROW 51105 "… never runs pattern (F3/F4) is live again"` fires every hour on a
perfectly healthy, freshly enabled job. At initial prod go-live (`RoboticoOps.dbo.CommandLog`
is empty) the same applies to both checkdb and index-optimize.

Impact is muted: at go-live the `spCheckBackupChain` `THROW 51100` (RoboticoOps not yet in
CBB) fires *first* in the same step (spRunMaintenanceJob L102 before L106), suppressing the
liveness check until the chain is fresh; and enabling a job is a rare, human-supervised
deploy event. Hence Nice-to-have. **Suggested fix (or documented accept):** also require
the newest matching CommandLog gap to exceed the window *since the job became eligible* —
e.g. gate on `dModified`/a "last enabled" marker, or add a one-line runbook note that a
first run must be triggered manually (`sp_start_job`) right after enabling, as the B5
test1 checklist in fact did.

---

### L-B1-3 — `spCheckMaintenanceLiveness` IndexOptimize freshness assumes statistics logging; an `IndexOptimize` row with `bUpdateStatistics = 0` and no fragmentation logs nothing → false `51105` — **Nice-to-have**

`maint.spCheckMaintenanceLiveness.sql` L57-58 treats an `IndexOptimize` run as "alive" only
if a `ALTER_INDEX` **or** `UPDATE_STATISTICS` CommandLog row exists in the window. For the
current seed (`index-optimize` has `bUpdateStatistics = 1`) `UPDATE_STATISTICS` logs on
every run (Ola default `@OnlyModifiedStatistics = 'N'`), so it holds. But `up/0023`
explicitly permits `bUpdateStatistics = 0` (the "parameter omitted" exception, D33), and
`spRunMaintenanceJob` L74-78 then calls `IndexOptimize` with no statistics maintenance. On a
run where nothing is fragmented enough to reorganize, **no** `ALTER_INDEX` and no
`UPDATE_STATISTICS` row is written → the liveness check false-alarms `51105` even though the
job ran green.

Latent only — no such row is seeded today. **Failure scenario:** a future
`bUpdateStatistics = 0` IndexOptimize job on a low-churn DB runs nightly, produces zero
CommandLog rows on quiet nights, and the daily watchdog `THROW 51105` marks it "never runs".
**Suggested fix (or documented accept):** note the coupling in the DATA-MODEL contract
(IndexOptimize liveness requires a per-run log row, which only `bUpdateStatistics = 1`
guarantees), or have IndexOptimize log an unconditional heartbeat.

---

## Verified-correct (no finding)

- `spEnsureMaintenanceJobs`: HHMMSS conversion (L104-106), weekly `freq_recurrence_factor = 1`
  guard against err 14266 (L101), hourly `freq_subday_type 8 / interval 1` (L102-103), the
  running-job guard scoped to `MAX(session_id)` (correctly NULL-safe when the agent never
  started), the closed-surface drift comparison with `COUNT(steps)=1 / COUNT(schedules)=1`
  and every column `IS DISTINCT FROM` — all internally consistent and NULL-safe.
- `spRunMaintenanceJob`: cutoffs computed at run time via `DATEADD(DAY, -@nRetentionDays,
  SYSDATETIME())` (no frozen-date no-op), the `51120` guards on both unknown key and
  unmatched CASE, `@FragmentationMedium/High` both pinned REORGANIZE (closes Ola's Medium =
  INDEX_REBUILD_OFFLINE default — the impl's own D13 deviation, defensible).
- `spCheckBackupChain`: `is_copy_only = 0` full filter, `recovery_model_desc <> 'SIMPLE'`
  log filter (FULL + BULK_LOGGED), TRIM + ONLINE target validation with the token in the
  message, `SYSDATETIME()` local-time base (D32) — all correct. (Only the DATEDIFF age test
  is the L-B1-1 flaw.)
- `spCheckMaintenanceLiveness`: the paired-CASE `CommandType IN (…)` resolves correctly
  (IntegrityCheck → `DBCC_CHECKDB`; IndexOptimize → `ALTER_INDEX`/`UPDATE_STATISTICS`); D34
  `RETURN` short-circuit; `DATEADD` elapsed-time cutoff (the *correct* pattern L-B1-1 should
  copy).
- `spApplyMaintenance`: MERGE `WHEN MATCHED` guard is fully `IS DISTINCT FROM` (NULL-safe over
  the six NULLable columns), `dModified` set only on real change (AC7 no-churn), `NOT MATCHED
  BY SOURCE THEN DELETE` safe for the fully repo-owned registry.
- `up/0023`: the `CK_OperationKnobs` matrix makes the registry self-validating per operation;
  `CK_Schedule` forces `nWeekdayMask` present iff weekly; prefix CHECK guards ghost jobs.

## Out-of-scope observations (for the consolidator)

- (convention) `spEnsureMaintenanceJobs` hard-codes `@owner_login_name = N'sa'` (L228) — matches
  the reused `reset.spEnsureAgentJob` primitive; consistent, not a logic fault, noted only for
  the convention lens.

## Coverage note

All six repo-owned SQL logic files fully read at HEAD and diffed against d722993. The 5350-line
`up/0022` vendored Ola file was intentionally not logic-audited (pinned third-party; the impl's
3 documented byte-breaks are a convention/plan concern, not logic). Docs, validation gates,
README belong to other topics.
