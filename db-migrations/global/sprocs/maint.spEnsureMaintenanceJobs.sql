-- maint.spEnsureMaintenanceJobs  (Ebene B / global — sprocs, anytime)
--
-- Registry -> SQL-Agent sync: reads ops.tMaintenanceJob and makes msdb match it.
-- Pattern reset.spEnsureAgentJob, deliberately different in three places (plan §3.2):
--   1. PER-JOB comparison in canonical msdb normal form (D31) instead of an
--      unconditional drop/recreate: missing job -> create; definition drift ->
--      drop/recreate exactly that job; otherwise no-op. The comparison surface is a
--      CLOSED list (job enabled/notify, step command/database/subsystem, schedule
--      freq_type/freq_interval/freq_recurrence_factor/freq_subday_type/
--      freq_subday_interval/active_start_time/enabled), NULL-safe via
--      IS DISTINCT FROM (D30). This makes the proc report "0 changes" on a healthy
--      redeploy (AC7 measuring point) and safe for the unconditional 260 call (D29).
--      Accepted: a WANTED drop/recreate loses that one job's agent history.
--   2. RUNNING-JOB guard per job against msdb.dbo.sysjobactivity, scoped to the
--      CURRENT agent session (MAX(session_id) — without the scoping a job would count
--      as "running" forever after an agent stop/crash left stop_execution_date NULL;
--      on test1 the agent is routinely started/stopped). A running job is skipped and
--      reported, never dropped and never a global THROW — the next deploy converges
--      (260 calls this unconditionally, D29).
--   3. Operator-EXISTS guard: @notify_email_operator is wired only when the operator
--      exists in msdb.dbo.sysoperators (else NULL) — a deploy never fails on a missing
--      operator; first-deploy convergence is done by permissions/260.
--
-- Every job gets the CONSTANT dispatch step
--   EXECUTE RoboticoOps.maint.spRunMaintenanceJob @cJobKey = N'<key>';
-- (fully qualified — ADR-A failure mode "wrong DB context"/F2). The only sync-time
-- substitution is the cJobKey literal, quote-doubled although repo-owned
-- (belt-and-braces, lint rule (g)); all operation-specific values reach Ola at RUN
-- time as real proc parameters inside the dispatcher (D28) — data never becomes code.
--
-- Effective job-enabled state = bEnabled = 1 AND ops.tConfig('MaintenanceSchedulesEnabled')
-- <> '0' (missing key = enabled; test1 sets '0' so jobs exist but stay disabled — D34).
-- Pausing = disabling, never deleting (history stays, pause visible in SSMS).
--
-- THROW allocation: 51110 is reserved for this proc's guard/error path (README §4 (k));
-- currently unused by design — running jobs are skip-and-report, not errors.
--
-- @see docs/plans/2026-07-21 - mssql-wartung-ola (§3.2)
-- @see docs/plans/2026-07-21 - mssql-wartung-ola/adrs/adr-maintenance-as-code-roboticoops.md
CREATE OR ALTER PROCEDURE maint.spEnsureMaintenanceJobs
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @cPrefix nvarchar(30) = N'RoboticoOps - Maint - ';
    DECLARE @nChanges int = 0, @nSkipped int = 0;

    -- D34 instance switch: missing key or any value other than '0' = schedules enabled.
    DECLARE @bSchedulesEnabled bit =
        CASE WHEN EXISTS (SELECT 1 FROM ops.tConfig
                          WHERE cKey = N'MaintenanceSchedulesEnabled' AND cValue = N'0')
             THEN 0 ELSE 1 END;

    -- Operator-EXISTS guard (repo-owned policy name, created by permissions/260).
    DECLARE @cOperator sysname = N'RoboticoOps-Maint';
    IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysoperators WHERE name = @cOperator)
        SET @cOperator = NULL;

    -- Running-job guard scope: the CURRENT agent session (D31). With a stopped agent
    -- this is NULL and nothing can be running.
    DECLARE @nAgentSession int = (SELECT MAX(session_id) FROM msdb.dbo.syssessions);

    -- ------------------------------------------------------------------
    -- Desired set in canonical msdb normal form (D31 mapping table):
    --   daily  -> freq_type 4, interval 1, subday 1/0
    --   weekly -> freq_type 8, interval nWeekdayMask, recurrence_factor 1, subday 1/0
    --   hourly -> freq_type 4, interval 1, subday 8/1 (hourly from the anchor, D35)
    --   tStartTime -> active_start_time int HHMMSS
    -- ------------------------------------------------------------------
    DECLARE @tDesired TABLE
    (
        cJobKey            sysname       NOT NULL PRIMARY KEY,
        cDisplayName       sysname       NOT NULL,
        bJobEnabled        bit           NOT NULL,
        nNotifyLevel       int           NOT NULL,
        cNotifyOperator    sysname       NULL,
        cStepCommand       nvarchar(400) NOT NULL,
        nFreqType          int           NOT NULL,
        nFreqInterval      int           NOT NULL,
        nFreqRecurrence    int           NOT NULL,
        nFreqSubdayType    int           NOT NULL,
        nFreqSubdayInterval int          NOT NULL,
        nActiveStartTime   int           NOT NULL,
        cNotes             nvarchar(400) NULL
    );

    INSERT INTO @tDesired (cJobKey, cDisplayName, bJobEnabled, nNotifyLevel, cNotifyOperator,
                           cStepCommand, nFreqType, nFreqInterval, nFreqRecurrence,
                           nFreqSubdayType, nFreqSubdayInterval, nActiveStartTime, cNotes)
    SELECT j.cJobKey,
           j.cDisplayName,
           CASE WHEN j.bEnabled = 1 AND @bSchedulesEnabled = 1 THEN 1 ELSE 0 END,
           CASE WHEN j.bNotifyOnFail = 1 AND @cOperator IS NOT NULL THEN 2 ELSE 0 END,
           CASE WHEN j.bNotifyOnFail = 1 THEN @cOperator ELSE NULL END,
           -- Constant dispatch step (D28); the cJobKey literal is the ONLY sync-time
           -- substitution, quote-doubled (belt-and-braces, rule (g)):
           N'EXECUTE RoboticoOps.maint.spRunMaintenanceJob @cJobKey = N'''
               + REPLACE(j.cJobKey, N'''', N'''''') + N''';',
           CASE j.cFrequency WHEN N'weekly' THEN 8 ELSE 4 END,
           CASE j.cFrequency WHEN N'weekly' THEN j.nWeekdayMask ELSE 1 END,
           CASE j.cFrequency WHEN N'weekly' THEN 1 ELSE 0 END,   -- mandatory >= 1 for weekly (err 14266)
           CASE j.cFrequency WHEN N'hourly' THEN 8 ELSE 1 END,
           CASE j.cFrequency WHEN N'hourly' THEN 1 ELSE 0 END,
           DATEPART(HOUR, j.tStartTime) * 10000
               + DATEPART(MINUTE, j.tStartTime) * 100
               + DATEPART(SECOND, j.tStartTime),
           j.cNotes
    FROM ops.tMaintenanceJob j;

    -- ------------------------------------------------------------------
    -- Pass 1: remove jobs inside the managed prefix window that the registry no
    -- longer declares (AC3 removal path; the prefix CHECK on cDisplayName guarantees
    -- every managed job sits inside this window).
    -- ------------------------------------------------------------------
    DECLARE @cJobName sysname, @jobId uniqueidentifier;
    DECLARE curExtra CURSOR LOCAL FAST_FORWARD FOR
        SELECT sj.name, sj.job_id
        FROM msdb.dbo.sysjobs sj
        WHERE sj.name LIKE @cPrefix + N'%'
          AND NOT EXISTS (SELECT 1 FROM @tDesired d WHERE d.cDisplayName = sj.name);
    OPEN curExtra;
    FETCH NEXT FROM curExtra INTO @cJobName, @jobId;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobactivity ja
                   WHERE ja.job_id = @jobId AND ja.session_id = @nAgentSession
                     AND ja.start_execution_date IS NOT NULL
                     AND ja.stop_execution_date IS NULL)
        BEGIN
            SET @nSkipped += 1;
            PRINT '! maint.spEnsureMaintenanceJobs: job [' + @cJobName
                + '] is RUNNING — removal skipped, converges on the next deploy (D29).';
        END
        ELSE
        BEGIN
            EXEC msdb.dbo.sp_delete_job @job_id = @jobId, @delete_unused_schedule = 1;
            SET @nChanges += 1;
            PRINT 'maint.spEnsureMaintenanceJobs: removed unregistered job [' + @cJobName + '].';
        END
        FETCH NEXT FROM curExtra INTO @cJobName, @jobId;
    END
    CLOSE curExtra; DEALLOCATE curExtra;

    -- ------------------------------------------------------------------
    -- Pass 2: create-or-converge every registry row.
    -- ------------------------------------------------------------------
    DECLARE @cJobKey sysname, @cDisplayName sysname, @bJobEnabled bit, @nNotifyLevel int,
            @cNotifyOperator sysname, @cStepCommand nvarchar(400), @nFreqType int,
            @nFreqInterval int, @nFreqRecurrence int, @nFreqSubdayType int,
            @nFreqSubdayInterval int, @nActiveStartTime int, @cNotes nvarchar(400);

    DECLARE curDesired CURSOR LOCAL FAST_FORWARD FOR
        SELECT cJobKey, cDisplayName, bJobEnabled, nNotifyLevel, cNotifyOperator,
               cStepCommand, nFreqType, nFreqInterval, nFreqRecurrence, nFreqSubdayType,
               nFreqSubdayInterval, nActiveStartTime, cNotes
        FROM @tDesired ORDER BY cJobKey;
    OPEN curDesired;
    FETCH NEXT FROM curDesired INTO @cJobKey, @cDisplayName, @bJobEnabled, @nNotifyLevel,
        @cNotifyOperator, @cStepCommand, @nFreqType, @nFreqInterval, @nFreqRecurrence,
        @nFreqSubdayType, @nFreqSubdayInterval, @nActiveStartTime, @cNotes;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @jobId = (SELECT job_id FROM msdb.dbo.sysjobs WHERE name = @cDisplayName);

        DECLARE @bNeedsCreate bit = 0, @bDrift bit = 0;
        IF @jobId IS NULL
            SET @bNeedsCreate = 1;
        ELSE
        BEGIN
            -- Canonical-normal-form comparison over the CLOSED surface (D31), every
            -- column NULL-safe via IS DISTINCT FROM (D30). Anything outside this list
            -- is deliberately NOT compared (invisible drift is preferred over a
            -- perpetual drop/recreate on facets we do not manage).
            IF NOT EXISTS (
                SELECT 1
                FROM msdb.dbo.sysjobs sj
                JOIN msdb.dbo.sysjobsteps st
                  ON st.job_id = sj.job_id AND st.step_id = 1
                JOIN msdb.dbo.sysjobschedules js ON js.job_id = sj.job_id
                JOIN msdb.dbo.sysschedules ss    ON ss.schedule_id = js.schedule_id
                LEFT JOIN msdb.dbo.sysoperators op
                  ON op.id = sj.notify_email_operator_id
                WHERE sj.job_id = @jobId
                  AND (SELECT COUNT(*) FROM msdb.dbo.sysjobsteps s2 WHERE s2.job_id = sj.job_id) = 1
                  AND (SELECT COUNT(*) FROM msdb.dbo.sysjobschedules j2 WHERE j2.job_id = sj.job_id) = 1
                  AND NOT (sj.enabled            IS DISTINCT FROM @bJobEnabled)
                  AND NOT (sj.notify_level_email IS DISTINCT FROM @nNotifyLevel)
                  AND NOT (op.name               IS DISTINCT FROM @cNotifyOperator)
                  AND NOT (st.command            IS DISTINCT FROM @cStepCommand)
                  AND NOT (st.database_name      IS DISTINCT FROM N'RoboticoOps')
                  AND NOT (st.subsystem          IS DISTINCT FROM N'TSQL')
                  AND NOT (ss.freq_type          IS DISTINCT FROM @nFreqType)
                  AND NOT (ss.freq_interval      IS DISTINCT FROM @nFreqInterval)
                  AND NOT (ss.freq_recurrence_factor IS DISTINCT FROM @nFreqRecurrence)
                  AND NOT (ss.freq_subday_type       IS DISTINCT FROM @nFreqSubdayType)
                  AND NOT (ss.freq_subday_interval   IS DISTINCT FROM @nFreqSubdayInterval)
                  AND NOT (ss.active_start_time  IS DISTINCT FROM @nActiveStartTime)
                  AND NOT (ss.enabled            IS DISTINCT FROM 1))
                SET @bDrift = 1;
        END

        IF @bDrift = 1
        BEGIN
            IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobactivity ja
                       WHERE ja.job_id = @jobId AND ja.session_id = @nAgentSession
                         AND ja.start_execution_date IS NOT NULL
                         AND ja.stop_execution_date IS NULL)
            BEGIN
                SET @nSkipped += 1;
                PRINT '! maint.spEnsureMaintenanceJobs: job [' + @cDisplayName
                    + '] drifted but is RUNNING — skipped, converges on the next deploy (D29).';
            END
            ELSE
            BEGIN
                -- Drop/recreate exactly this job (accepted cost: its agent history).
                EXEC msdb.dbo.sp_delete_job @job_id = @jobId, @delete_unused_schedule = 1;
                SET @bNeedsCreate = 1;
                PRINT 'maint.spEnsureMaintenanceJobs: job [' + @cDisplayName + '] drifted — recreating.';
            END
        END

        IF @bNeedsCreate = 1
        BEGIN
            SET @jobId = NULL;
            EXEC msdb.dbo.sp_add_job
                 @job_name = @cDisplayName,
                 @enabled = @bJobEnabled,
                 @owner_login_name = N'sa',
                 @description = @cNotes,
                 @notify_level_email = @nNotifyLevel,
                 @notify_email_operator_name = @cNotifyOperator,
                 @job_id = @jobId OUTPUT;

            EXEC msdb.dbo.sp_add_jobstep
                 @job_id = @jobId,
                 @step_name = N'Dispatch',
                 @subsystem = N'TSQL',
                 @database_name = N'RoboticoOps',
                 @command = @cStepCommand,
                 @retry_attempts = 0,
                 @on_success_action = 1,   -- quit reporting success
                 @on_fail_action = 2;      -- quit reporting failure

            DECLARE @cScheduleName sysname = @cDisplayName + N' schedule';
            EXEC msdb.dbo.sp_add_jobschedule
                 @job_id = @jobId,
                 @name = @cScheduleName,
                 @enabled = 1,
                 @freq_type = @nFreqType,
                 @freq_interval = @nFreqInterval,
                 @freq_recurrence_factor = @nFreqRecurrence,
                 @freq_subday_type = @nFreqSubdayType,
                 @freq_subday_interval = @nFreqSubdayInterval,
                 @active_start_time = @nActiveStartTime;

            EXEC msdb.dbo.sp_add_jobserver @job_id = @jobId, @server_name = N'(LOCAL)';
            SET @nChanges += 1;
        END

        FETCH NEXT FROM curDesired INTO @cJobKey, @cDisplayName, @bJobEnabled, @nNotifyLevel,
            @cNotifyOperator, @cStepCommand, @nFreqType, @nFreqInterval, @nFreqRecurrence,
            @nFreqSubdayType, @nFreqSubdayInterval, @nActiveStartTime, @cNotes;
    END
    CLOSE curDesired; DEALLOCATE curDesired;

    -- AC7 measuring point: a healthy redeploy prints "0 change(s)".
    PRINT 'maint.spEnsureMaintenanceJobs: ' + CONVERT(nvarchar(10), @nChanges)
        + ' change(s), ' + CONVERT(nvarchar(10), @nSkipped) + ' running-job skip(s).';
END
GO
