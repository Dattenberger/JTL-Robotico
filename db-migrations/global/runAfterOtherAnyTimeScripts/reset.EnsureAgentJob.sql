-- reset.EnsureAgentJob  (Ebene B / global — runAfterOtherAnyTimeScripts, anytime)
--
-- (Re)creates the SQL Agent job "RoboticoOps - Testmandant Reset": owner sa (so its
-- single T-SQL step runs as the sysadmin Agent service account — no signing needed in
-- the job, research/3 §3), one step "EXEC reset.ProcessNextResetRequest", enabled,
-- NO schedule (on-demand only, kicked by reset.StartTestmandantReset -> sp_start_job).
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

    DECLARE @jobName sysname = N'RoboticoOps - Testmandant Reset';

    IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @jobName)
        EXEC msdb.dbo.sp_delete_job @job_name = @jobName, @delete_unused_schedule = 1;

    DECLARE @jobId uniqueidentifier;
    EXEC msdb.dbo.sp_add_job
         @job_name = @jobName,
         @enabled = 1,
         @owner_login_name = N'sa',
         @description = N'On-demand test-mandant reset. Started by reset.StartTestmandantReset via sp_start_job.',
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

-- Apply on every deploy where this file's hash changed.
EXEC reset.EnsureAgentJob;
GO
