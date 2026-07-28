-- 250_jobstartuser_mapping.sql  (Ebene B / global — permissions, everytime)
--
-- Self-healing SID re-map for the `jobstartuser` database users (msdb + RoboticoOps).
--
-- WHY everytime (and NOT folded into up/0010): a full Ebene-B teardown that DROP LOGINs
-- jobstartuser but leaves a database USER behind ORPHANS that user — dropping a login does
-- NOT drop the database users mapped to it. The redeploy recreates the login with a FRESH
-- SID; up/0010 is a one-time journaled script and cannot repair a standing environment
-- (editing it would only change its hash and break the next deploy). This everytime script
-- re-binds an orphaned user to the current login SID on every deploy — an idempotent no-op
-- when already correct, the repair when orphaned. Without it, the module-signed reset proc's
-- impersonated context reaches msdb with no rights and sp_start_job is DENIED
-- (dress-rehearsal finding, 2026-07-15; audit B1).
--
-- Only the login mapping needs healing here: the msdb SQLAgentOperatorRole membership and
-- the sp_start_job GRANT key on principal_id, which survives an orphan — up/0010 stays the
-- source of the initial CREATE USER + role + grant. Same pattern as 200_ensure_agent_job:
-- an everytime assert on top of the one-time setup.
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur/reports/paypal-removal-audit-fable.md (B1)
-- @see db-migrations/global/up/0010_jobstartuser_login.sql

SET NOCOUNT ON;

-- msdb: re-map only when the user exists, the login exists, and their SIDs diverge (orphan).
EXEC msdb.sys.sp_executesql N'
    IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N''jobstartuser'')
       AND SUSER_ID(N''jobstartuser'') IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM sys.database_principals dp
                       JOIN sys.server_principals sp ON dp.sid = sp.sid
                       WHERE dp.name = N''jobstartuser'')
    BEGIN
        ALTER USER [jobstartuser] WITH LOGIN = [jobstartuser];
        PRINT ''! msdb jobstartuser was orphaned — re-mapped to the current login SID.'';
    END
';
GO

-- RoboticoOps-local (the EXECUTE AS target user): same defense-in-depth.
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'jobstartuser')
   AND SUSER_ID(N'jobstartuser') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.database_principals dp
                   JOIN sys.server_principals sp ON dp.sid = sp.sid
                   WHERE dp.name = N'jobstartuser')
BEGIN
    ALTER USER [jobstartuser] WITH LOGIN = [jobstartuser];
    PRINT '! RoboticoOps jobstartuser was orphaned — re-mapped to the current login SID.';
END
GO
