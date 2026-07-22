-- maint.spCheckMaintenanceLiveness  (Ebene B / global — sprocs, anytime; read-only liveness check)
--
-- Maintenance liveness check (D36): bNotifyOnFail only catches jobs that RUN AND FAIL
-- (the F2 pattern). The historically dominant damage was the "never runs" pattern
-- (F3/F4: 2 years without CHECKDB while the jobs existed — schedule detached live,
-- job disabled live), which stays invisible to notify; the 260 self-heal only runs on
-- the next deploy, which can be weeks away. This proc closes that gap
-- SELF-CONFIGURING from the registry: for every EFFECTIVELY enabled row (bEnabled = 1
-- AND ops.tConfig('MaintenanceSchedulesEnabled') <> '0', D34 — on test1 therefore a
-- no-op by construction) with cOperation IN (IntegrityCheck, IndexOptimize) it
-- derives the maximum allowed age of the newest matching dbo.CommandLog entry from
-- the declared schedule (daily -> 26 h, weekly -> 8 days) and THROWs 51105 with the
-- stale cJobKeys otherwise.
--
-- CommandType mapping: IntegrityCheck -> DBCC_CHECKDB; IndexOptimize -> ALTER_INDEX /
-- UPDATE_STATISTICS (the latter logs on every run with @UpdateStatistics='ALL' and
-- Ola default @OnlyModifiedStatistics='N').
--
-- IndexOptimize liveness relies on that per-run UPDATE_STATISTICS heartbeat, which only
-- registry bUpdateStatistics = 1 guarantees (L-B1-3). A bUpdateStatistics = 0 row (Ola
-- runs with no statistics maintenance — itself the F8 anti-pattern this suite exists to
-- remove, ADR-A §F8/AC10) has NO reliable per-run heartbeat: ALTER_INDEX is logged only
-- when an index crosses the reorg threshold, so a green run on a low-churn night logs
-- nothing and this check would false-fire 51105. Before enabling a stats-off IndexOptimize
-- row, revisit this scan — either add a run-marker, or exempt that row here as a DOCUMENTED
-- liveness blind spot (mirroring the Cleanup exemption). Do not silently exclude it.
--
-- Cleanups are deliberately excluded (they do not log to CommandLog; failure impact
-- uncritical). The watchdog watches itself via its own reporting path.
--
-- First-run grace (L-B1-2): a freshly enabled (bEnabled 0->1) or newly created row has no
-- CommandLog history and would otherwise be indistinguishable from a stopped job (a false
-- 51105 on every hourly run until its first scheduled fire). A row effectively enabled for
-- LESS than one full schedule window cannot be stale yet — its first scheduled run has not
-- been due — so it is skipped until it has been enabled longer than one window; a row
-- enabled LONGER than one window with no fresh CommandLog entry is genuinely stale and
-- alarms. The grace anchor is ops.tMaintenanceJob.dModified (set on INSERT and on any
-- registry change incl. the bEnabled 0->1 flip via the value-guarded MERGE, D30).
--
-- GOTCHA — local time base: CommandLog.StartTime is LOCAL time (Ola logs GETDATE()),
-- so age comparisons use SYSDATETIME(), NEVER SYSUTCDATETIME() (same D32 gotcha as
-- maint.spCheckBackupChain, even though the rest of the design is UTC).
-- GOTCHA — TWO clocks on purpose: the first-run grace compares dModified (stored UTC)
-- against SYSUTCDATETIME(), so this proc deliberately keeps a second UTC base (@dNowUtc)
-- alongside the local @dNow. Do not collapse them to one clock.
--
-- DELIBERATE residual blind spot: a stopped agent service silences the watchdog with
-- it — not self-monitorable from inside agent jobs; documented as ADR-A failure mode,
-- owned by the external-monitoring follow-up task (Gap 2).
--
-- THROW allocation (README §4 (k)): 51105 = stale maintenance.
--
-- @see docs/plans/2026-07-21 - mssql-wartung-ola (§3.2, D36)
-- @see docs/decisions/0001-maintenance-as-code-roboticoops.md
CREATE OR ALTER PROCEDURE maint.spCheckMaintenanceLiveness
AS
BEGIN
    SET NOCOUNT ON;

    -- D34 instance switch: effectively enabled rows only (test1 with '0' => no-op).
    DECLARE @bSchedulesEnabled bit =
        CASE WHEN EXISTS (SELECT 1 FROM ops.tConfig
                          WHERE cKey = N'MaintenanceSchedulesEnabled' AND cValue = N'0')
             THEN 0 ELSE 1 END;
    IF @bSchedulesEnabled = 0
        RETURN;

    DECLARE @dNow datetime2(0) = SYSDATETIME();       -- local base for CommandLog.StartTime (D32 gotcha)
    DECLARE @dNowUtc datetime2(0) = SYSUTCDATETIME();  -- UTC base for the dModified first-run grace (L-B1-2)

    DECLARE @cStaleKeys nvarchar(1000) =
        (SELECT STRING_AGG(j.cJobKey, N', ')
         FROM ops.tMaintenanceJob j
         -- one window per row drives BOTH the grace floor and the staleness floor (DRY):
         CROSS APPLY (SELECT nWindowHours = CASE j.cFrequency
                                                 WHEN N'daily'  THEN 26
                                                 WHEN N'weekly' THEN 192   -- 8 days
                                                 ELSE 26                    -- defensive: hourly rows are not liveness-watched ops
                                            END) w
         WHERE j.bEnabled = 1
           AND j.cOperation IN (N'IntegrityCheck', N'IndexOptimize')
           -- First-run grace (L-B1-2): a row enabled for less than one full window cannot be
           -- stale yet — skip it until dModified is older than one window. Expressed as
           -- dModified <= now-window (not DATEDIFF >= window) to avoid DATEDIFF's boundary
           -- off-by-one, which can shorten the grace by up to ~1 h.
           AND j.dModified <= DATEADD(HOUR, -w.nWindowHours, @dNowUtc)
           AND NOT EXISTS (
                 SELECT 1
                 FROM RoboticoOps.dbo.CommandLog cl
                 WHERE cl.CommandType IN (CASE j.cOperation WHEN N'IntegrityCheck' THEN N'DBCC_CHECKDB' ELSE N'ALTER_INDEX' END,
                                          CASE j.cOperation WHEN N'IndexOptimize'  THEN N'UPDATE_STATISTICS' ELSE N'DBCC_CHECKDB' END)
                   AND cl.StartTime >= DATEADD(HOUR, -w.nWindowHours, @dNow)));

    IF @cStaleKeys IS NOT NULL
    BEGIN
        DECLARE @cMsg nvarchar(2000) = N'maint.spCheckMaintenanceLiveness: no sufficiently fresh CommandLog entry for effectively enabled maintenance job(s): '
            + @cStaleKeys + N'. The "never runs" pattern (F3/F4) is live again — check schedules/job enablement in msdb and rerun maint.spEnsureMaintenanceJobs.';
        THROW 51105, @cMsg, 1;
    END
END
GO
