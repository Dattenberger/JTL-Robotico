-- reset.spPub_CancelResetRequest  (Ebene B / global — signed, EXECUTE AS jobstartuser — OPS-2)
--
-- Recovery entry point for a colleague: get a mandant OUT of a stuck reset without
-- server rights and without waiting for the StaleRunningHours window.
--
--   * 'queued'    → cancelled outright (queued → failed). No job has touched it yet.
--   * 'running'   → force-reclaimed (running → failed) ONLY when the SQL-Agent reset
--                   job is NOT actually executing right now. Otherwise we would mark a
--                   row failed under a job that is mid-clone and about to overwrite it,
--                   so we refuse and tell the caller to wait / let the stale reclaim run.
--   * 'succeeded'/'failed' → no-op; the state is echoed back so the caller sees why.
--
-- Why signed + EXECUTE AS (identical model to reset.spPub_StartTestmandantReset, research/3, D6):
--   the "is the job running?" check reads msdb.dbo.sysjobactivity, which crosses the
--   RoboticoOps → msdb boundary. That is exactly what the jobstartuser proxy
--   (msdb SQLAgentOperatorRole, up/0010) + the RoboticoOpsSigning signature (up/0011,
--   AUTHENTICATE SERVER) already authorise WITHOUT TRUSTWORTHY. ops.* is reached via
--   ownership chaining; ORIGINAL_LOGIN() records the REAL caller for the audit trail.
--
-- CREATE OR ALTER strips the signature — permissions/900 re-applies it every deploy
-- (catalog-driven: it signs every EXECUTE-AS-'jobstartuser' proc, so this one is picked
-- up automatically alongside spPub_StartTestmandantReset).
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§3)
-- @see db-migrations/global/permissions/900_resign_procedures.sql
CREATE OR ALTER PROCEDURE reset.spPub_CancelResetRequest
    @RequestId int
WITH EXECUTE AS 'jobstartuser'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @status  nvarchar(20),
            @caller  sysname = ORIGINAL_LOGIN(),
            @rows    int,
            -- Same single-sourced ops.tConfig knob the job wrapper uses (CQG-8).
            @jobName sysname = ISNULL(
                (SELECT cValue FROM ops.tConfig WHERE cKey = N'AgentJobName'),
                N'RoboticoOps - Testmandant Reset');

    SELECT @status = cStatus FROM ops.tResetRequest WHERE kResetRequest = @RequestId;

    IF @status IS NULL
        THROW 51006, 'Unknown kResetRequest.', 1;

    -- Already terminal — nothing to cancel.
    IF @status IN (N'succeeded', N'failed')
    BEGIN
        SELECT @RequestId AS kResetRequest, @status AS cStatus,
               N'already finished — nothing to cancel' AS Note;
        RETURN;
    END

    -- 'queued': the job has not claimed it yet. Guard the UPDATE on cStatus = 'queued'
    -- so a claim that races us (queued → running between our read and write) is detected
    -- as 0 rows rather than silently clobbering a now-running request.
    IF @status = N'queued'
    BEGIN
        UPDATE ops.tResetRequest
           SET cStatus     = N'failed',
               cErrorMessage  = N'cancelled by ' + @caller + N' (was queued)',
               dFinished = SYSUTCDATETIME(),
               dModified = SYSUTCDATETIME()
         WHERE kResetRequest = @RequestId AND cStatus = N'queued';
        SET @rows = @@ROWCOUNT;

        IF @rows = 0
        BEGIN
            SELECT @status = cStatus FROM ops.tResetRequest WHERE kResetRequest = @RequestId;
            SELECT @RequestId AS kResetRequest, @status AS cStatus,
                   N'could not cancel: the job already picked it up — re-check status' AS Note;
            RETURN;
        END

        SELECT @RequestId AS kResetRequest, N'failed' AS cStatus, N'cancelled (was queued)' AS Note;
        RETURN;
    END

    -- 'running': force-reclaim only if the reset job is not actually executing. Restrict
    -- to the CURRENT Agent session (max agent_start_date) and look for an activity row
    -- that started but has not stopped — the canonical "is this job running now?" probe.
    IF EXISTS (
        SELECT 1
        FROM msdb.dbo.sysjobactivity ja
        JOIN msdb.dbo.sysjobs j        ON ja.job_id = j.job_id
        JOIN msdb.dbo.syssessions ss   ON ja.session_id = ss.session_id
        JOIN (SELECT MAX(agent_start_date) AS max_start FROM msdb.dbo.syssessions) cur
             ON ss.agent_start_date = cur.max_start
        WHERE j.name = @jobName
          AND ja.start_execution_date IS NOT NULL
          AND ja.stop_execution_date  IS NULL)
        THROW 51007, 'Refusing: the reset job is currently running. Wait for it to finish, or let the StaleRunningHours reclaim handle a job that has actually died.', 1;

    UPDATE ops.tResetRequest
       SET cStatus     = N'failed',
           cErrorMessage  = N'force-reclaimed by ' + @caller + N' (was running; no active agent job run)',
           dFinished = SYSUTCDATETIME(),
           dModified = SYSUTCDATETIME()
     WHERE kResetRequest = @RequestId AND cStatus = N'running';

    SELECT @RequestId AS kResetRequest, N'failed' AS cStatus,
           N'force-reclaimed (was running, no active job)' AS Note;
END
GO
