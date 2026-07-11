-- reset.EnsureAgentJob  (Ebene B / global — runAfterOtherAnyTimeScripts, anytime)
--
-- (Re)creates the SQL Agent job "RoboticoOps - Testmandant Reset": owner sa (so its
-- single T-SQL step runs as the sysadmin Agent service account — no signing needed in
-- the job, research/3 §3), one step "EXEC reset.ProcessNextResetRequest", enabled,
-- NO schedule (on-demand only, kicked by reset.StartTestmandantReset -> sp_start_job).
--
-- OPS-4: failure notification is OPTIONAL and config-gated. A failed/stale-reclaimed
-- reset is otherwise pull-only (nobody is told unless they poll reset.GetResetStatus).
-- If the admin seeds ops.Config('NotifyOperator') with an existing SQL-Agent operator
-- (requires Database Mail), this wires an on-failure email; otherwise the job stays
-- silent so an instance without Database Mail still deploys cleanly. The runbook
-- documents the pull-only fallback.
--
-- Runs after all sprocs (this folder is grate's last anytime stage), so
-- reset.ProcessNextResetRequest already exists. Idempotent: drop-if-exists then add.
--
-- NOTE (deviation from the plan filename "agent_job_testmandant_reset.sql"): the lint
-- treats every file in an anytime folder as one Schema.Object CREATE (README §3/§4).
-- A bare sp_add_job script cannot satisfy that, so the job DDL lives in this small
-- self-executing wrapper proc (named reset.EnsureAgentJob) instead. A lint gap was
-- filed so the folder can later be exempted and the wrapper dropped if preferred.
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§2, §3)
CREATE OR ALTER PROCEDURE reset.EnsureAgentJob
AS
BEGIN
    SET NOCOUNT ON;

    -- Single-sourced job name (CQG-8): the same ops.Config knob is read here, in
    -- reset.StartTestmandantReset (sp_start_job) and in permissions/200_ensure_agent_job
    -- (existence check). ISNULL keeps a pre-config instance on the built-in default.
    DECLARE @jobName sysname = ISNULL(
        (SELECT ConfigValue FROM ops.Config WHERE ConfigKey = N'AgentJobName'),
        N'RoboticoOps - Testmandant Reset');

    -- Guard: sp_delete_job stops a RUNNING job mid-step. Recreating the job while a
    -- reset is queued/running would cancel the backup/restore mid-clone and leave the
    -- request stuck in 'running' until the stale-reclaim in reset.ProcessNextResetRequest.
    -- Fail the deploy instead; rerun once the active reset has finished.
    IF EXISTS (SELECT 1 FROM ops.ResetRequest WHERE Status IN (N'queued', N'running'))
        THROW 50001, N'reset.EnsureAgentJob: a reset request is queued or running. Recreating the agent job now would cancel it mid-clone. Wait until ops.ResetRequest has no queued/running row (check reset.GetResetStatus), then rerun the global deploy.', 1;

    -- OPS-4: resolve the optional failure-notification operator. Only wire the email if
    -- the configured operator actually exists in msdb — passing an unknown operator name
    -- to sp_add_job would fail the deploy, so a missing/blank config stays silent.
    DECLARE @notifyOperator sysname =
        NULLIF((SELECT ConfigValue FROM ops.Config WHERE ConfigKey = N'NotifyOperator'), N'');
    DECLARE @notifyLevel int = 0;   -- 0 = never email
    IF @notifyOperator IS NOT NULL
       AND EXISTS (SELECT 1 FROM msdb.dbo.sysoperators WHERE name = @notifyOperator)
        SET @notifyLevel = 2;       -- 2 = email on failure
    ELSE
        SET @notifyOperator = NULL; -- do not pass an operator name msdb does not know

    IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @jobName)
        EXEC msdb.dbo.sp_delete_job @job_name = @jobName, @delete_unused_schedule = 1;

    DECLARE @jobId uniqueidentifier;
    EXEC msdb.dbo.sp_add_job
         @job_name = @jobName,
         @enabled = 1,
         @owner_login_name = N'sa',
         @description = N'On-demand test-mandant reset. Started by reset.StartTestmandantReset via sp_start_job.',
         @notify_level_email = @notifyLevel,
         @notify_email_operator_name = @notifyOperator,
         @job_id = @jobId OUTPUT;

    EXEC msdb.dbo.sp_add_jobstep
         @job_id = @jobId,
         @step_name = N'Process reset queue',
         @subsystem = N'TSQL',
         @database_name = N'RoboticoOps',
         @command = N'EXEC reset.ProcessNextResetRequest;',
         @retry_attempts = 0,
         @on_success_action = 1,   -- quit reporting success
         @on_fail_action = 2;      -- quit reporting failure

    EXEC msdb.dbo.sp_add_jobserver @job_id = @jobId, @server_name = N'(LOCAL)';
END
GO

-- Apply on every deploy where this file's hash changed. Bare existence is additionally
-- self-healed on every deploy by permissions/200_ensure_agent_job.sql (everytime).
EXEC reset.EnsureAgentJob;
GO
