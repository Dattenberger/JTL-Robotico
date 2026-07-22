-- 260_maintenance_operator.sql  (Ebene B / global — permissions, everytime)
--
-- Three tasks in one everytime script (D17/D29; prefix 260 orders after
-- 250_jobstartuser_mapping and before 900_resign):
--   1. create the SQL-Agent operator 'RoboticoOps-Maint' (mail lukas@dattenberger.com)
--      if missing;
--   2. assign the agent Database-Mail profile 'Standard SMTP' (guarded, see below);
--   3. UNCONDITIONALLY call maint.spEnsureMaintenanceJobs (D29 self-heal).
--
-- WHY: grate runs permissions/ AFTER runAfterOtherAnyTimeScripts/ — on the first
-- deploy the operator does not exist yet when the sync runs, and because the sync is
-- hash-gated, notify wiring would NEVER be pulled in on a clean redeploy without this
-- script (QG-Critical SEC-3-1). The unconditional ensure call (a) pulls in notify
-- wiring after operator creation (AC6 convergence), (b) heals manually deleted jobs /
-- a restored msdb on every deploy (same self-heal guarantee as
-- permissions/200_ensure_agent_job for the reset job), (c) applies any previously
-- reported running-skip. The per-job normal-form comparison (D31) makes it a no-op in
-- the healthy state — no drop/recreate per deploy, a running job is never touched.
--
-- DELIBERATE deviation from the reset pattern (which externalizes its operator in
-- ops.tConfig('NotifyOperator'), instance-tunable): the maintenance operator NAME +
-- RECIPIENT are hard-coded in this committed script — consistent with the repo-owned
-- stance of the whole maintenance registry (recipient change = git + deploy, same
-- traceability as any other tuning). Not an accident: the same D11 logic. Decided in
-- R2/D34: the ops.tConfig switch 'MaintenanceSchedulesEnabled' carries instance
-- STATE; the operator identity is repo-owned POLICY — no move into ops.tConfig.
--
-- GOTCHA: the agent mail-profile assignment only takes effect after an AGENT RESTART.
-- The script prints a clear hint in that case; the restart itself is a cutover
-- runbook step (rollout-mssql-ops.md, maintenance go-live phase), never a deploy side
-- effect.
--
-- @see docs/plans/2026-07-21 - mssql-wartung-ola (§3.3)
-- @see docs/decisions/0001-maintenance-as-code-roboticoops.md

SET NOCOUNT ON;

-- --- 1. operator (repo-owned policy) ----------------------------------------------
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysoperators WHERE name = N'RoboticoOps-Maint')
BEGIN
    EXEC msdb.dbo.sp_add_operator
         @name = N'RoboticoOps-Maint',
         @enabled = 1,
         @email_address = N'lukas@dattenberger.com';
    PRINT 'Created SQL-Agent operator [RoboticoOps-Maint].';
END
GO

-- --- 2. agent Database-Mail profile (guarded, FT-16) ------------------------------
-- Only when the profile actually exists in msdb.dbo.sysmail_profile (on test1
-- Database Mail may be unconfigured): otherwise a clear PRINT instead of writing a
-- phantom profile name that the "only if unset" guard would then cement. No THROW —
-- same philosophy as the operator-EXISTS guard in the sync proc.
DECLARE @cProfile sysname = N'Standard SMTP';
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysmail_profile WHERE name = @cProfile)
    PRINT '! Database-Mail profile [Standard SMTP] does not exist on this instance — agent mail profile NOT set. Maintenance-failure mails stay silent until Database Mail is configured.';
ELSE
BEGIN
    DECLARE @cCurrentProfile nvarchar(256);
    EXEC master.dbo.xp_instance_regread
         N'HKEY_LOCAL_MACHINE',
         N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent',
         N'DatabaseMailProfile',
         @cCurrentProfile OUTPUT,
         N'no_output';
    IF @cCurrentProfile IS NULL OR @cCurrentProfile = N''
    BEGIN
        EXEC master.dbo.xp_instance_regwrite
             N'HKEY_LOCAL_MACHINE',
             N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent',
             N'UseDatabaseMail',
             N'REG_DWORD', 1;
        EXEC master.dbo.xp_instance_regwrite
             N'HKEY_LOCAL_MACHINE',
             N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent',
             N'DatabaseMailProfile',
             N'REG_SZ', @cProfile;
        PRINT '! Agent mail profile set to [Standard SMTP] — takes effect only after a SQL-AGENT RESTART (runbook step, never a deploy side effect).';
    END
    -- else: already set — never overwrite an admin-chosen profile.
END
GO

-- --- 3. unconditional ensure (D29 self-heal) --------------------------------------
-- Runs in grate's last stage (after runAfterOtherAnyTimeScripts), so the proc exists;
-- the OBJECT_ID guard is a belt-and-braces safety net (pattern 200_ensure_agent_job).
IF OBJECT_ID(N'maint.spEnsureMaintenanceJobs', N'P') IS NOT NULL
    EXEC maint.spEnsureMaintenanceJobs;
ELSE
    PRINT '! maint.spEnsureMaintenanceJobs missing — maintenance sync skipped.';
GO
