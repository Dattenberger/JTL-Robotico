-- validate_rollout.sql  (Ebene B / global — post-rollout live-instance check)
--
-- Read-only verification that a FULLY DEPLOYED instance (both chains applied) is
-- wired end-to-end: the migration journals exist and carry rows, the reset-step
-- registry is seeded, the two entry-point procs are signed, the SQL-Agent job is
-- present and enabled, and the instance-global signing/impersonation principals
-- are in their intended state (signing login present + AUTHENTICATE SERVER;
-- jobstartuser disabled + DENY CONNECT SQL).
--
-- This is the superset companion to validate_structure.sql: that one proves the
-- OBJECTS/columns/roles/signatures EXIST (runnable even on a bare structure); this
-- one proves the whole rollout actually landed and is operable. It reaches into
-- msdb / master / the SourceDb, so it expects a high-privilege (sysadmin / operator)
-- context — the deploying admin. NOT a migration (lives under tests/), so it is
-- exempt from the migration lint and safe against a live server.
--
--   sqlcmd -S vm-sql-test1.zdbikes.local -d RoboticoOps -E -C -i db-migrations/tests/global/validate_rollout.sql
--
-- Exit behaviour: one line per check; RAISERROR (severity 16) at the end if any
-- check failed, so a wrapper (validate-rollout.ps1) detects it via the error.
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§2, §7)
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur/reports/test1-rollout-plan.md (§f)

SET NOCOUNT ON;

DECLARE @problems TABLE (Check_ nvarchar(300));

-- --- Ebene B journal (grate --schema=ops) ---------------------------------------
IF OBJECT_ID(N'ops.ScriptsRun', N'U') IS NULL
    INSERT INTO @problems (Check_) VALUES (N'EBENE-B JOURNAL: ops.ScriptsRun missing (global chain never deployed here)');
ELSE IF NOT EXISTS (SELECT 1 FROM ops.ScriptsRun)
    INSERT INTO @problems (Check_) VALUES (N'EBENE-B JOURNAL: ops.ScriptsRun has 0 rows (nothing journaled)');

-- --- Ebene A journal in the SourceDb (cross-DB, resolved from ops.tConfig) --------
DECLARE @srcDb sysname = (SELECT cValue FROM ops.tConfig WHERE cKey = N'SourceDb');
IF @srcDb IS NULL
    INSERT INTO @problems (Check_) VALUES (N'CONFIG: ops.tConfig has no SourceDb row');
ELSE
BEGIN
    DECLARE @srcJournal nvarchar(400) =
        N'SELECT @cnt = CASE WHEN OBJECT_ID(' + QUOTENAME(@srcDb + N'.Robotico.ScriptsRun', N'''')
        + N', N''U'') IS NULL THEN -1 ELSE (SELECT COUNT(*) FROM '
        + QUOTENAME(@srcDb) + N'.Robotico.ScriptsRun) END;';
    DECLARE @cnt int;
    EXEC sys.sp_executesql @srcJournal, N'@cnt int OUTPUT', @cnt = @cnt OUTPUT;
    IF @cnt = -1
        INSERT INTO @problems (Check_) VALUES (N'EBENE-A JOURNAL: ' + @srcDb + N'.Robotico.ScriptsRun missing (SourceDb never deployed/baselined)');
    ELSE IF @cnt = 0
        INSERT INTO @problems (Check_) VALUES (N'EBENE-A JOURNAL: ' + @srcDb + N'.Robotico.ScriptsRun has 0 rows');
END

-- --- ops.tResetStep registry: the 8 canonical steps, enabled, in order -----------
;WITH expected (nStepOrder, cProcName) AS (
    SELECT v.nStepOrder, v.cProcName FROM (VALUES
        (10, N'spInternal_CloneDatabase'),
        (20, N'spInternal_PostRestoreSecurity'),
        (30, N'spInternal_InvalidateCredentials'),
        (40, N'spInternal_NeutralizeWorker'),
        (50, N'spInternal_AnonymizeCustomerData'),
        (60, N'spInternal_GrantAccess'),
        (70, N'spInternal_RegisterMandant'),
        (80, N'spInternal_ApplyJtlRoles')
    ) v(nStepOrder, cProcName)
)
INSERT INTO @problems (Check_)
SELECT N'RESET STEP: ' + e.cProcName + N' (order ' + CONVERT(varchar(10), e.nStepOrder) + N') '
     + CASE
         WHEN s.cProcName IS NULL THEN N'missing from ops.tResetStep'
         WHEN s.bEnabled = 0     THEN N'is disabled'
         WHEN s.nStepOrder <> e.nStepOrder THEN N'has nStepOrder ' + CONVERT(varchar(10), s.nStepOrder) + N' (expected ' + CONVERT(varchar(10), e.nStepOrder) + N')'
         ELSE N'?' END
FROM expected e
LEFT JOIN ops.tResetStep s ON s.cProcName = e.cProcName
WHERE s.cProcName IS NULL OR s.bEnabled = 0 OR s.nStepOrder <> e.nStepOrder;

-- --- the two entry-point procs must be signed by RoboticoOpsSigning --------------
;WITH signed_required (name) AS (
    SELECT v.name FROM (VALUES (N'reset.spPub_StartTestmandantReset'), (N'reset.spPub_CancelResetRequest')) v(name)
)
INSERT INTO @problems (Check_)
SELECT N'UNSIGNED: ' + s.name + N' is not signed by RoboticoOpsSigning'
FROM signed_required s
WHERE NOT EXISTS (
        SELECT 1 FROM sys.crypt_properties cp
        JOIN sys.certificates c ON cp.thumbprint = c.thumbprint
        WHERE cp.major_id = OBJECT_ID(s.name) AND c.name = N'RoboticoOpsSigning');

-- --- SQL-Agent job present and enabled (name from ops.tConfig, CQG-8) -------------
DECLARE @jobName sysname = ISNULL(
    (SELECT cValue FROM ops.tConfig WHERE cKey = N'AgentJobName'),
    N'RoboticoOps - Testmandant Reset');
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @jobName)
    INSERT INTO @problems (Check_) VALUES (N'AGENT JOB: "' + @jobName + N'" not found in msdb');
ELSE IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @jobName AND enabled = 1)
    INSERT INTO @problems (Check_) VALUES (N'AGENT JOB: "' + @jobName + N'" exists but is DISABLED');

-- --- instance-global signing / impersonation principals (master) -----------------
-- RoboticoOpsSigningLogin: created FROM the public certificate, granted AUTHENTICATE SERVER.
IF NOT EXISTS (SELECT 1 FROM master.sys.server_principals WHERE name = N'RoboticoOpsSigningLogin')
    INSERT INTO @problems (Check_) VALUES (N'MASTER LOGIN: RoboticoOpsSigningLogin missing (0011 signing bridge absent)');
ELSE IF NOT EXISTS (
    SELECT 1 FROM master.sys.server_permissions p
    JOIN master.sys.server_principals sp ON p.grantee_principal_id = sp.principal_id
    WHERE sp.name = N'RoboticoOpsSigningLogin' AND p.permission_name = N'AUTHENTICATE SERVER' AND p.state = N'G')
    INSERT INTO @problems (Check_) VALUES (N'MASTER LOGIN: RoboticoOpsSigningLogin lacks AUTHENTICATE SERVER');

-- jobstartuser: disabled login with DENY CONNECT SQL (never an interactive principal).
IF NOT EXISTS (SELECT 1 FROM master.sys.server_principals WHERE name = N'jobstartuser')
    INSERT INTO @problems (Check_) VALUES (N'MASTER LOGIN: jobstartuser missing');
ELSE
BEGIN
    IF EXISTS (SELECT 1 FROM master.sys.sql_logins WHERE name = N'jobstartuser' AND is_disabled = 0)
        INSERT INTO @problems (Check_) VALUES (N'MASTER LOGIN: jobstartuser is ENABLED (must be disabled)');
    IF NOT EXISTS (
        SELECT 1 FROM master.sys.server_permissions p
        JOIN master.sys.server_principals sp ON p.grantee_principal_id = sp.principal_id
        WHERE sp.name = N'jobstartuser' AND p.permission_name = N'CONNECT SQL' AND p.state = N'D')
        INSERT INTO @problems (Check_) VALUES (N'MASTER LOGIN: jobstartuser lacks DENY CONNECT SQL');
END

-- --- report ----------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM @problems)
BEGIN
    SELECT Check_ AS Problem FROM @problems ORDER BY Check_;
    DECLARE @n int = (SELECT COUNT(*) FROM @problems);
    RAISERROR('validate_rollout: %d problem(s) found.', 16, 1, @n);
END
ELSE
    PRINT 'validate_rollout: OK — journals populated, reset-step registry seeded, entry procs signed, agent job enabled, signing/impersonation principals correct.';
GO
