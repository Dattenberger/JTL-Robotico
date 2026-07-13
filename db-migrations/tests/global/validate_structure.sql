-- validate_structure.sql  (Ebene B / global — static reference-consistency check)
--
-- Read-only structural review of a deployed RoboticoOps: every reset.* proc exists,
-- the ops.* tables + key columns the procs reference exist, the signed proc is
-- actually signed, and the roles/grants are in place. NOT a migration (lives under
-- tests/, not global/), so it is exempt from the migration lint and safe to run
-- against a live server.
--
--   sqlcmd -S vm-sql-test1.zdbikes.local -d RoboticoOps -E -C -i db-migrations/tests/global/validate_structure.sql
--
-- Exit behaviour: prints one line per check; RAISERRORs (severity 16) at the end if
-- any check failed, so a CI wrapper can detect it via the error.
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§2, §7)

SET NOCOUNT ON;

DECLARE @problems TABLE (Check_ nvarchar(200));

-- --- objects that must exist -----------------------------------------------------
;WITH required (name, type) AS (
    SELECT v.name, v.type FROM (VALUES
        (N'ops.tMandant',        N'U'),
        (N'ops.tConfig',         N'U'),
        (N'ops.tResetRequest',   N'U'),
        (N'ops.tResetStep',      N'U'),
        (N'reset.spPub_StartTestmandantReset',      N'P'),
        (N'reset.spPub_GetResetStatus',             N'P'),
        (N'reset.spPub_ListMandants',               N'P'),
        (N'reset.spPub_CancelResetRequest',         N'P'),
        (N'reset.spPub_CreateTestmandant',          N'P'),
        (N'reset.spPub_PurgeOldRequests',           N'P'),
        (N'reset.spProcessNextResetRequest',    N'P'),
        (N'reset.spInternal_LogStep',           N'P'),
        (N'reset.spInternal_CloneDatabase',     N'P'),
        (N'reset.spInternal_PostRestoreSecurity', N'P'),
        (N'reset.spInternal_InvalidateCredentials', N'P'),
        (N'reset.spInternal_NeutralizeWorker',  N'P'),
        (N'reset.spInternal_AnonymizeCustomerData', N'P'),
        (N'reset.spInternal_GrantAccess',       N'P'),
        (N'reset.spInternal_RegisterMandant',   N'P'),
        (N'reset.spInternal_ApplyJtlRoles',     N'P'),
        (N'reset.spEnsureAgentJob',             N'P')
    ) v(name, type)
)
INSERT INTO @problems (Check_)
SELECT N'MISSING OBJECT: ' + r.name + N' (' + r.type + N')'
FROM required r
WHERE OBJECT_ID(r.name, r.type) IS NULL;

-- --- columns the reset procs depend on -------------------------------------------
;WITH cols (tbl, col) AS (
    SELECT v.tbl, v.col FROM (VALUES
        (N'ops.tMandant', N'cMandantKey'), (N'ops.tMandant', N'cTargetDb'), (N'ops.tMandant', N'cLoginName'),
        (N'ops.tMandant', N'cShopUrl'), (N'ops.tMandant', N'cShopLicense'), (N'ops.tMandant', N'cDisplayName'),
        (N'ops.tMandant', N'bActive'),
        (N'ops.tConfig', N'cKey'), (N'ops.tConfig', N'cValue'),
        (N'ops.tResetRequest', N'kResetRequest'), (N'ops.tResetRequest', N'cMandantKey'),
        (N'ops.tResetRequest', N'cTargetDb'), (N'ops.tResetRequest', N'cStatus'),
        (N'ops.tResetRequest', N'cRequestedBy'), (N'ops.tResetRequest', N'cStepLog'),
        (N'ops.tResetRequest', N'cErrorMessage'), (N'ops.tResetRequest', N'dStarted'),
        (N'ops.tResetRequest', N'dFinished'),
        (N'ops.tResetStep', N'nStepOrder'), (N'ops.tResetStep', N'cProcName'),
        (N'ops.tResetStep', N'bEnabled'), (N'ops.tResetStep', N'bCritical')
    ) v(tbl, col)
)
INSERT INTO @problems (Check_)
SELECT N'MISSING COLUMN: ' + c.tbl + N'.' + c.col
FROM cols c
WHERE OBJECT_ID(c.tbl, N'U') IS NULL OR COL_LENGTH(c.tbl, c.col) IS NULL;

-- --- the signature-required procs must actually be signed by RoboticoOpsSigning ---
-- Signed set = the EXECUTE-AS-'jobstartuser' entry points that cross into msdb:
-- reset.spPub_StartTestmandantReset (sp_start_job) and reset.spPub_CancelResetRequest (job-activity
-- read). A named check here catches the case where someone drops a proc's EXECUTE AS
-- clause — the generic assertion below only sees procs that STILL declare EXECUTE AS.
;WITH signed_required (name) AS (
    SELECT v.name FROM (VALUES
        (N'reset.spPub_StartTestmandantReset'),
        (N'reset.spPub_CancelResetRequest')
    ) v(name)
)
INSERT INTO @problems (Check_)
SELECT N'UNSIGNED: ' + s.name + N' is not signed by RoboticoOpsSigning'
FROM signed_required s
WHERE OBJECT_ID(s.name) IS NOT NULL
  AND NOT EXISTS (
        SELECT 1 FROM sys.crypt_properties cp
        JOIN sys.certificates c ON cp.thumbprint = c.thumbprint
        WHERE cp.major_id = OBJECT_ID(s.name)
          AND c.name = N'RoboticoOpsSigning');

-- --- every EXECUTE-AS reset proc must be signed (the signed set = the EXECUTE-AS set:
-- --- currently spPub_StartTestmandantReset + spPub_CancelResetRequest) -----------------------
INSERT INTO @problems (Check_)
SELECT N'EXECUTE-AS proc without signature: ' + OBJECT_SCHEMA_NAME(m.object_id) + N'.' + OBJECT_NAME(m.object_id)
FROM sys.sql_modules m
WHERE m.execute_as_principal_id IS NOT NULL
  AND OBJECT_SCHEMA_NAME(m.object_id) = N'reset'
  AND NOT EXISTS (SELECT 1 FROM sys.crypt_properties cp WHERE cp.major_id = m.object_id);

-- --- roles -----------------------------------------------------------------------
;WITH roles (name) AS (SELECT v.name FROM (VALUES (N'ops_reset_executor'), (N'ops_admin')) v(name))
INSERT INTO @problems (Check_)
SELECT N'MISSING ROLE: ' + r.name
FROM roles r
WHERE NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = r.name AND type = 'R');

-- --- report ----------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM @problems)
BEGIN
    SELECT Check_ AS Problem FROM @problems ORDER BY Check_;
    DECLARE @n int = (SELECT COUNT(*) FROM @problems);
    RAISERROR('validate_structure: %d problem(s) found.', 16, 1, @n);
END
ELSE
    PRINT 'validate_structure: OK — all reset.*/ops.* objects, columns, signature and roles present.';
GO
