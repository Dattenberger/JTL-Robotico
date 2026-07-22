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
-- Cleanups are deliberately excluded (they do not log to CommandLog; failure impact
-- uncritical). The watchdog watches itself via its own reporting path.
--
-- GOTCHA — local time base: CommandLog.StartTime is LOCAL time (Ola logs GETDATE()),
-- so age comparisons use SYSDATETIME(), NEVER SYSUTCDATETIME() (same D32 gotcha as
-- maint.spCheckBackupChain, even though the rest of the design is UTC).
--
-- DELIBERATE residual blind spot: a stopped agent service silences the watchdog with
-- it — not self-monitorable from inside agent jobs; documented as ADR-A failure mode,
-- owned by the external-monitoring follow-up task (Gap 2).
--
-- THROW allocation (README §4 (k)): 51105 = stale maintenance.
--
-- @see docs/plans/2026-07-21 - mssql-wartung-ola (§3.2, D36)
-- @see docs/plans/2026-07-21 - mssql-wartung-ola/adrs/adr-maintenance-as-code-roboticoops.md
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

    DECLARE @dNow datetime2(0) = SYSDATETIME();   -- local time base (D32 gotcha)

    DECLARE @cStaleKeys nvarchar(1000) =
        (SELECT STRING_AGG(j.cJobKey, N', ')
         FROM ops.tMaintenanceJob j
         WHERE j.bEnabled = 1
           AND j.cOperation IN (N'IntegrityCheck', N'IndexOptimize')
           AND NOT EXISTS (
                 SELECT 1
                 FROM RoboticoOps.dbo.CommandLog cl
                 WHERE cl.CommandType IN (CASE j.cOperation WHEN N'IntegrityCheck' THEN N'DBCC_CHECKDB' ELSE N'ALTER_INDEX' END,
                                          CASE j.cOperation WHEN N'IndexOptimize'  THEN N'UPDATE_STATISTICS' ELSE N'DBCC_CHECKDB' END)
                   AND cl.StartTime >= CASE j.cFrequency
                                            WHEN N'daily'  THEN DATEADD(HOUR, -26, @dNow)
                                            WHEN N'weekly' THEN DATEADD(DAY,  -8, @dNow)
                                            ELSE DATEADD(HOUR, -26, @dNow)   -- defensive: hourly rows are not liveness-watched ops
                                       END));

    IF @cStaleKeys IS NOT NULL
    BEGIN
        DECLARE @cMsg nvarchar(2000) = N'maint.spCheckMaintenanceLiveness: no sufficiently fresh CommandLog entry for effectively enabled maintenance job(s): '
            + @cStaleKeys + N'. The "never runs" pattern (F3/F4) is live again — check schedules/job enablement in msdb and rerun maint.spEnsureMaintenanceJobs.';
        THROW 51105, @cMsg, 1;
    END
END
GO
