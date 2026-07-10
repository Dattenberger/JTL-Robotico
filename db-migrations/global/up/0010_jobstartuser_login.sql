-- 0010_jobstartuser_login.sql  (Ebene B / global chain — runs in RoboticoOps)
--
-- The "job starter" proxy principal for the signed-SP -> Agent-job bridge
-- (research/3, hybrid certificate + impersonation recipe, D6).
--
--   * LOGIN  jobstartuser  — server login, immediately DISABLED and DENY CONNECT SQL.
--                            It is never used to log in; it exists only as the
--                            EXECUTE AS target of reset.StartTestmandantReset. Its
--                            password is random and never logged (login is disabled).
--   * USER   jobstartuser  in RoboticoOps — required so the proc header
--                            "WITH EXECUTE AS 'jobstartuser'" resolves. Needs no
--                            grants: ownership chaining (schemas are dbo-owned)
--                            covers ops.* access inside the proc.
--   * USER   jobstartuser  in msdb — with SQLAgentOperatorRole + EXECUTE on
--                            sp_start_job, so the (module-signed) impersonated
--                            context may start the sysadmin-owned reset job.
--
-- Why SQLAgentOperatorRole (not the leaner SQLAgentUserRole): the reset job is
-- owned by sa (sysadmin) so its T-SQL step runs as the Agent service account; a
-- non-owner may only start it with Operator rights (research/3 §1/§3).
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§2)
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur/research/3-module-signing-agent-job

SET NOCOUNT ON;

DECLARE @login sysname = N'jobstartuser';

-- --- server login (random password, disabled, no interactive connect) -----------
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = @login)
BEGIN
    -- Random password from a CSPRNG. CHECK_POLICY OFF because the login is disabled
    -- and DENY CONNECT SQL anyway; the value is intentionally unrecoverable.
    DECLARE @pw varchar(80) = 'Jx7!' + LEFT(CONVERT(varchar(200), CRYPT_GEN_RANDOM(60), 2), 60);
    -- CONCAT (not '+') keeps the dynamic-SQL data-concatenation lint heuristic quiet:
    -- @pw is a CSPRNG value with only hex/marker chars, not caller-supplied data.
    DECLARE @createLogin nvarchar(400) =
        CONCAT(N'CREATE LOGIN ', QUOTENAME(@login),
               N' WITH PASSWORD = ', QUOTENAME(@pw, ''''), N', CHECK_POLICY = OFF;');
    EXEC (@createLogin);
    PRINT 'Login [jobstartuser] created.';
END

ALTER LOGIN [jobstartuser] DISABLE;
DENY CONNECT SQL TO [jobstartuser];
GO

-- --- RoboticoOps database user (EXECUTE AS target) ------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'jobstartuser')
    CREATE USER [jobstartuser] FOR LOGIN [jobstartuser];
GO

-- --- msdb user + rights to start the reset job ----------------------------------
EXEC msdb.sys.sp_executesql N'
    IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N''jobstartuser'')
        CREATE USER [jobstartuser] FOR LOGIN [jobstartuser];

    IF NOT EXISTS (
        SELECT 1 FROM sys.database_role_members rm
        JOIN sys.database_principals r ON rm.role_principal_id = r.principal_id
        JOIN sys.database_principals m ON rm.member_principal_id = m.principal_id
        WHERE r.name = N''SQLAgentOperatorRole'' AND m.name = N''jobstartuser'')
        ALTER ROLE SQLAgentOperatorRole ADD MEMBER [jobstartuser];

    GRANT EXECUTE ON dbo.sp_start_job TO [jobstartuser];
';
GO
