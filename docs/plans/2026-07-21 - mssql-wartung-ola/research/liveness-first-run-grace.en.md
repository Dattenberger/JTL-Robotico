# Research: liveness-first-run-grace

**Date:** 2026-07-22T21:57:00+02:00
**Triggered by:** Finding L-B1-2 (Nice-to-have) — `maint.spCheckMaintenanceLiveness`
false-fires `THROW 51105` for a freshly enabled / first-time-created maintenance job
that has no `CommandLog` history yet, up until its first scheduled run.
**Agent-ID:** repair-research (implement-long-plan-v3)

## Problem statement

`maint.spCheckMaintenanceLiveness` (D36, AC13) alarms for every effectively enabled
`IntegrityCheck` / `IndexOptimize` registry row that has **no `CommandLog` entry within
its derived window** (daily → 26 h, weekly → 8 days). The check derives the window
purely from `cFrequency` and looks only at `RoboticoOps.dbo.CommandLog`.

A job that was **just enabled** (`bEnabled 0→1` via deploy) or **just created** (first
deploy / new registry row) has no history and is, to this check, indistinguishable from
a job that has silently **stopped** running — the exact F3/F4 pattern the proc exists to
catch. It therefore false-fires on every hourly watchdog run from the moment the job
becomes effectively enabled until its first scheduled fire produces a `CommandLog` row
(e.g. enabled 10:00, first `index-optimize` run 02:00 → ~16 h of hourly false alarms; at
go-live `CommandLog` is empty for the same reason).

Today this is only *masked*, not solved: in `spRunMaintenanceJob` the backup-watchdog
step runs `spCheckBackupChain` **first**, and at go-live its `51100` (fresh/empty chain)
throws and ends the step before liveness runs. Relying on that ordering is fragile — as
soon as the backup chain is healthy but a single maintenance row was freshly enabled, the
false alarm surfaces.

## Sources

1. `docs/plans/2026-07-21 - mssql-wartung-ola/mssql-wartung-ola.md` — §3.2 (D36), AC13,
   the D34 effective-enabled semantics, and the D32 local-time-base gotcha.
2. `db-migrations/global/sprocs/maint.spCheckMaintenanceLiveness.sql` — the current
   implementation (registry + `CommandLog` + `tConfig` only; reads **no** msdb table).
3. `db-migrations/global/runAfterOtherAnyTimeScripts/maint.spApplyMaintenance.sql` —
   the value-guarded MERGE (D30). Lines 22–27 document `dModified` explicitly as
   *"usable as an audit signal (set explicitly on UPDATE)"*; it is touched **only** when
   a desired column actually changes.
4. `db-migrations/global/up/0023_maintenance_registry.sql` (l.67–70) — `dModified`
   `DEFAULT SYSUTCDATETIME()` (UTC); set to deploy time on the fresh-row INSERT.
5. `db-migrations/global/up/0022_maintenance_ola_vendor.sql` — the vendored Ola
   `CommandLog` DDL: columns are run-evidence only (`StartTime`, `CommandType`, …); there
   is **no** column carrying "when the job was enabled".
6. SQL Server `msdb.dbo.sysjobs` schema (Microsoft Docs): carries `date_created` /
   `date_modified` and `enabled` (bit) but **no "enabled-since" timestamp** — enable time
   is not recoverable from msdb, and `date_created` is reset by the sync's drift
   drop/recreate (`sp_delete_job`/`sp_add_job`).

## Findings

### The right anchor is "how long has this row been effectively enabled", not "is CommandLog empty"

Blinding the check on empty `CommandLog` is **wrong**: at go-live you *do* want it to
alarm once a full window has elapsed with the jobs still never having run (the F3/F4
case is real even with an empty log). The correct grace is temporal — *do not expect a
`CommandLog` entry yet if the job has not been enabled long enough for a scheduled run to
have occurred.* A row that has been effectively enabled for **less than one full window**
cannot yet be stale; a row enabled **longer than one window** with no fresh entry is
genuinely stale and must alarm.

### `ops.tMaintenanceJob.dModified` is the correct, already-available grace anchor

`dModified` captures exactly "when was this row last (re)defined, including its
enablement", for three independent reasons in the code:

- **Fresh row (first deploy / new registry row):** the MERGE `INSERT` leaves `dModified`
  to its `DEFAULT SYSUTCDATETIME()` → deploy time (source 4).
- **Enablement flip (`bEnabled 0→1`) or any schedule change:** `bEnabled` and the
  schedule columns are in the value-guarded `WHEN MATCHED` predicate, so the `UPDATE`
  fires and sets `dModified = SYSUTCDATETIME()` (source 3, l.66/81/84).
- **True no-op deploy:** unchanged rows are not touched → `dModified` stays put → no
  spurious grace resets (AC7 idempotency preserved).

This keeps the proc **registry-only** — it already reads no msdb table, and this fix
adds none. That is the maintainability win over the alternatives below.

### Rejected alternatives

- **`msdb.dbo.sysjobs.date_created` grace.** No more precise than `dModified` (source 6:
  msdb has no enabled-since column), and it *couples* the liveness check to msdb job
  identity and gets reset by the sync's drift drop/recreate. Registry `dModified` is the
  single-source-of-truth anchor and avoids the coupling. Rejected.
- **`sysjobschedules.next_run_date` / `sysjobhistory` grace.** `next_run_*` is
  agent-maintained and unreliable when the agent is stopped (the test1 baseline, and
  precisely the failure the watchdog guards). `sysjobhistory` would add a second
  run-evidence source alongside `CommandLog` for no gain — both `IntegrityCheck` and
  `IndexOptimize` log to `CommandLog` on **every** run (IndexOptimize with
  `@UpdateStatistics='ALL'` + Ola default `@OnlyModifiedStatistics='N'` logs
  `UPDATE_STATISTICS` even when nothing is fragmented — noted in the proc header), so
  `CommandLog` is already reliable run-evidence. Rejected.
- **Skip when `CommandLog` is empty.** Blinds the check exactly in the F3/F4 "never ran"
  case it exists to catch. Rejected.

### Trade-off accepted by the `dModified` anchor

`dModified` bumps on **any** desired-column change (e.g. editing `cNotes`), not only on
enablement. So an unrelated edit to a long-running job re-grants grace for one window,
suppressing a real staleness alarm for at most that one window — and only right after a
supervised deploy that changed that very row. This is a tiny, bounded false-**negative**
traded for eliminating the false-**positives**, and is arguably correct anyway (a row
whose definition just changed may have had its schedule changed). Acceptable for a
Nice-to-have hardening; document it inline.

## Implementation Hints

Concrete change in `db-migrations/global/sprocs/maint.spCheckMaintenanceLiveness.sql`:

1. **Capture a UTC "now" alongside the existing local one.** Keep `@dNow = SYSDATETIME()`
   for the `CommandLog.StartTime` comparison (local — D32, unchanged). Add
   `DECLARE @dNowUtc datetime2(0) = SYSUTCDATETIME();` for the `dModified` grace
   comparison (`dModified` is stored UTC — source 4). This is a second, internally
   consistent time base; add a one-line comment mirroring the existing D32 gotcha so the
   next reader does not "fix" it to one clock.

2. **Derive the window once per row (removes the current duplicated CASE).** Add a
   `CROSS APPLY (SELECT nWindowHours = CASE j.cFrequency WHEN N'daily' THEN 26
   WHEN N'weekly' THEN 192 ELSE 26 END) w` (`192 h = 8 days`, matching the existing
   `DATEADD(DAY, -8, …)`). Use `w.nWindowHours` for **both** the grace floor and the
   staleness floor, so a single constant drives both — a DRY improvement over the two
   inline CASE expressions.

3. **Add the grace predicate to the `WHERE`:**
   ```sql
   -- First-run grace (L-B1-2): a row effectively enabled for less than one full
   -- window cannot be stale yet — its first scheduled run has not been due. dModified
   -- (UTC, set on INSERT and on any registry change incl. bEnabled 0->1) is the anchor.
   AND j.dModified <= DATEADD(HOUR, -w.nWindowHours, @dNowUtc)
   ```
   Express the boundary as `dModified <= DATEADD(HOUR, -window, @dNowUtc)` rather than
   `DATEDIFF(HOUR, dModified, @dNowUtc) >= window` to avoid `DATEDIFF`'s
   boundary-crossing off-by-one (it can shorten the grace by up to ~1 h).

4. **Staleness floor uses the same window against local `@dNow`:**
   `cl.StartTime >= DATEADD(HOUR, -w.nWindowHours, @dNow)`.

Correctness check against the finding's scenario (daily `index-optimize`, enabled 10:00
day1, first run 02:00 day2): grace window 26 h → holds until 12:00 day2. Before 02:00
day2 there is no log but the row is within grace → skipped. From 02:00 day2 a
`CommandLog` entry exists (age < 26 h) → not stale. After 12:00 day2 grace has expired but
the 02:00 entry is only ~10 h old → fresh. Never false-fires; still alarms if the 02:00
run never produces a log. Weekly (192 h grace, run due within 7 days) is covered
identically.

### Documentation / test notes for the fix agent

- Update the proc header block: add the first-run-grace rationale next to the existing
  D36 explanation, and note the second (UTC) time base.
- Consider a one-line note in the plan §3.2/AC13 (or leave the code header as SSoT per the
  anti-redundancy rule — the plan already says "derives the max allowed age from the
  schedule"; the grace is an implementation refinement of that, not a spec change).
- **Testing gotcha:** on test1 the proc is a construction-time no-op
  (`MaintenanceSchedulesEnabled = '0'` → early `RETURN`), so the grace path cannot be
  exercised through the effective-enabled entry point there. A regression test should
  assert the *predicate* directly (e.g. seed a row with recent `dModified` + empty
  `CommandLog` → no throw; a row with old `dModified` + no fresh entry → `51105`) rather
  than relying on the B5 direct-`EXEC`, which returns early. This is a Nice-to-have
  hardening — keep the test scope proportionate.

## References

- Plan: `docs/plans/2026-07-21 - mssql-wartung-ola/mssql-wartung-ola.md` — §3.2 (D36),
  AC13, D30 (value-guarded MERGE), D32 (local time base), D34 (effective-enabled).
- ADR: `docs/decisions/0001-maintenance-as-code-roboticoops.md`.
- Code: `db-migrations/global/sprocs/maint.spCheckMaintenanceLiveness.sql`,
  `db-migrations/global/runAfterOtherAnyTimeScripts/maint.spApplyMaintenance.sql`,
  `db-migrations/global/up/0023_maintenance_registry.sql`,
  `db-migrations/global/up/0022_maintenance_ola_vendor.sql`.
