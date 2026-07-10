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
        (N'ops.Mandant',        N'U'),
        (N'ops.Config',         N'U'),
        (N'ops.ResetRequest',   N'U'),
        (N'reset.StartTestmandantReset',      N'P'),
        (N'reset.GetResetStatus',             N'P'),
        (N'reset.ProcessNextResetRequest',    N'P'),
        (N'reset.internal_CloneDatabase',     N'P'),
        (N'reset.internal_PostRestoreSecurity', N'P'),
        (N'reset.internal_InvalidateCredentials', N'P'),
        (N'reset.internal_NeutralizeWorker',  N'P'),
        (N'reset.internal_AnonymizeCustomerData', N'P'),
        (N'reset.internal_GrantAccess',       N'P'),
        (N'reset.internal_RegisterMandant',   N'P'),
        (N'reset.internal_ApplyJtlRoles',     N'P'),
        (N'reset.EnsureAgentJob',             N'P')
    ) v(name, type)
)
INSERT INTO @problems (Check_)
SELECT N'MISSING OBJECT: ' + r.name + N' (' + r.type + N')'
FROM required r
WHERE OBJECT_ID(r.name, r.type) IS NULL;

-- --- columns the reset procs depend on -------------------------------------------
;WITH cols (tbl, col) AS (
    SELECT v.tbl, v.col FROM (VALUES
        (N'ops.Mandant', N'MandantKey'), (N'ops.Mandant', N'TargetDb'), (N'ops.Mandant', N'LoginName'),
        (N'ops.Mandant', N'ShopUrl'), (N'ops.Mandant', N'ShopLicense'), (N'ops.Mandant', N'DisplayName'),
        (N'ops.Mandant', N'IsActive'),
        (N'ops.Config', N'ConfigKey'), (N'ops.Config', N'ConfigValue'),
        (N'ops.ResetRequest', N'RequestId'), (N'ops.ResetRequest', N'MandantKey'),
        (N'ops.ResetRequest', N'TargetDb'), (N'ops.ResetRequest', N'Status'),
        (N'ops.ResetRequest', N'RequestedBy'), (N'ops.ResetRequest', N'StepLog'),
        (N'ops.ResetRequest', N'ErrorText'), (N'ops.ResetRequest', N'StartedAt'),
        (N'ops.ResetRequest', N'FinishedAt')
    ) v(tbl, col)
)
INSERT INTO @problems (Check_)
SELECT N'MISSING COLUMN: ' + c.tbl + N'.' + c.col
FROM cols c
WHERE OBJECT_ID(c.tbl, N'U') IS NULL OR COL_LENGTH(c.tbl, c.col) IS NULL;

-- --- the signed proc must actually be signed by RoboticoOpsSigning ---------------
INSERT INTO @problems (Check_)
SELECT N'UNSIGNED: reset.StartTestmandantReset is not signed by RoboticoOpsSigning'
WHERE OBJECT_ID(N'reset.StartTestmandantReset') IS NOT NULL
  AND NOT EXISTS (
        SELECT 1 FROM sys.crypt_properties cp
        JOIN sys.certificates c ON cp.thumbprint = c.thumbprint
        WHERE cp.major_id = OBJECT_ID(N'reset.StartTestmandantReset')
          AND c.name = N'RoboticoOpsSigning');

-- --- the EXECUTE-AS set must equal the signed set (exactly StartTestmandantReset) -
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
