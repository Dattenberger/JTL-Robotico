-- 200_ensure_agent_job.sql  (Ebene B / global — permissions, everytime)
--
-- Self-healing existence check for the SQL Agent job "RoboticoOps - Testmandant Reset".
-- reset.spEnsureAgentJob (runAfterOtherAnyTimeScripts) only re-executes when its file
-- hash changes, so a manually deleted job or a rebuilt/restored msdb would otherwise
-- stay broken until someone edits that file. This everytime script re-asserts bare
-- existence on every deploy; the full drop/recreate stays hash-triggered in
-- reset.spEnsureAgentJob (so a running job is not killed on every deploy).
--
-- Runs in grate's last stage (after runAfterOtherAnyTimeScripts), so the wrapper
-- procedure already exists; the OBJECT_ID guard is a belt-and-braces safety net.
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§2, §3)

SET NOCOUNT ON;

-- Single-sourced job name (CQG-8): same ops.tConfig knob as reset.spEnsureAgentJob /
-- reset.spPub_StartTestmandantReset. ISNULL keeps a pre-config instance on the built-in default.
DECLARE @jobName sysname = ISNULL(
    (SELECT cValue FROM ops.tConfig WHERE cKey = N'AgentJobName'),
    N'RoboticoOps - Testmandant Reset');

IF OBJECT_ID(N'reset.spEnsureAgentJob') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @jobName)
BEGIN
    PRINT '! Agent job [' + @jobName + '] missing — recreating via reset.spEnsureAgentJob.';
    EXEC reset.spEnsureAgentJob;
END
GO
