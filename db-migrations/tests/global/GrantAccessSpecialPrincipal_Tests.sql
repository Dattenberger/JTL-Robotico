-- Regression test for reset.spInternal_GrantAccess special-principal handling (F-2/F4).
-- Run FROM this directory so the guard include resolves:
--   cd db-migrations/tests/global
--   sqlcmd -S <server> -U sa -C -b -d RoboticoOps -i GrantAccessSpecialPrincipal_Tests.sql
--
-- A mandant whose cLoginName is a sysadmin (here 'sa') used to break the reset: the step
-- ran CREATE USER [sa] FOR LOGIN [sa], which throws Msg 15405 ("Cannot use the special
-- principal 'sa'"). As a critical step that failed the whole reset. The fix detects a
-- sysadmin login and WARN-skips it (it already maps to dbo), like the missing-login case.
--   ROT  : EXEC raises Msg 15405; no cStepLog WARN written.
--   GRUEN: EXEC succeeds; a 'WARN access-skipped ... sysadmin' line is logged; and NO
--          database user named 'sa' is created in the clone.
--
-- Self-cleaning: creates + drops a throwaway clone DB and removes its own tm96 rows.
-- @see db-migrations/global/sprocs/reset.spInternal_GrantAccess.sql
:r ../_e2e_guard.sql
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
GO

PRINT '============================================================================';
PRINT 'reset.spInternal_GrantAccess - special-principal regression (F-2)';
PRINT '============================================================================';
PRINT '';

DECLARE @passed INT = 0, @total INT = 3;
DECLARE @clone sysname = N'eazybusiness_tm96';
DECLARE @sql nvarchar(max);

-- fresh throwaway clone DB (name must match the eazybusiness_ clone guard). A function
-- call (QUOTENAME) cannot sit inside EXEC()'s concatenated argument, so build @sql first.
IF DB_ID(@clone) IS NOT NULL
BEGIN
    SET @sql = N'ALTER DATABASE ' + QUOTENAME(@clone) + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE ' + QUOTENAME(@clone) + N';';
    EXEC(@sql);
END
SET @sql = N'CREATE DATABASE ' + QUOTENAME(@clone) + N';';
EXEC(@sql);

DELETE FROM ops.tResetRequest WHERE cMandantKey = N'tm96';
DELETE FROM ops.tMandant      WHERE cMandantKey = N'tm96';
INSERT INTO ops.tMandant (cMandantKey, cTargetDb, cDisplayName, cLoginName)
VALUES (N'tm96', @clone, N'F-2 sa grant test', N'sa');
INSERT INTO ops.tResetRequest (cMandantKey, cTargetDb, cStatus, cRequestedBy, dStarted)
VALUES (N'tm96', @clone, N'running', N'f2test', SYSUTCDATETIME());
DECLARE @rid INT = CAST(SCOPE_IDENTITY() AS INT);
PRINT '--- request ' + CAST(@rid AS NVARCHAR(10)) + ' set up (cLoginName=sa, clone ' + @clone + ') ---';

DECLARE @errNo INT = NULL;
BEGIN TRY
    EXEC reset.spInternal_GrantAccess @TargetDb = @clone, @RequestId = @rid, @MandantKey = N'tm96';
END TRY
BEGIN CATCH
    SET @errNo = ERROR_NUMBER();
    PRINT '  (EXEC raised Msg ' + CAST(@errNo AS NVARCHAR(10)) + ': ' + ERROR_MESSAGE() + ')';
END CATCH

-- Check 1: the step must NOT fail on the special principal (F-2 regression).
IF @errNo IS NULL
BEGIN PRINT '  + GrantAccess ran without error for sysadmin login'; SET @passed += 1; END
ELSE IF @errNo = 15405 OR @errNo = 15063
    PRINT '  x REGRESSION F-2: Msg ' + CAST(@errNo AS NVARCHAR(10)) + ' — special principal not skipped';
ELSE
    PRINT '  x unexpected Msg ' + CAST(@errNo AS NVARCHAR(10));

-- Check 2: a WARN skip line was logged (analogous to the missing-login PAR-1 note).
DECLARE @log NVARCHAR(MAX) = (SELECT cStepLog FROM ops.tResetRequest WHERE kResetRequest = @rid);
IF @log LIKE N'%WARN access-skipped%sysadmin%'
BEGIN PRINT '  + cStepLog carries the sysadmin WARN-skip note'; SET @passed += 1; END
ELSE PRINT '  x expected a WARN access-skipped ... sysadmin note, got: ' + ISNULL(@log, 'NULL');

-- Check 3: NO database user named 'sa' was created in the clone.
DECLARE @saUsers INT;
DECLARE @q nvarchar(400) = N'SELECT @c = COUNT(*) FROM ' + QUOTENAME(@clone)
    + N'.sys.database_principals WHERE name = N''sa''';
EXEC sys.sp_executesql @q, N'@c int OUTPUT', @c = @saUsers OUTPUT;
IF @saUsers = 0
BEGIN PRINT '  + no [sa] db_owner user created in the clone'; SET @passed += 1; END
ELSE PRINT '  x an [sa] user was created in the clone (should be skipped)';

-- cleanup
DELETE FROM ops.tResetRequest WHERE cMandantKey = N'tm96';
DELETE FROM ops.tMandant      WHERE cMandantKey = N'tm96';
IF DB_ID(@clone) IS NOT NULL
BEGIN
    SET @sql = N'ALTER DATABASE ' + QUOTENAME(@clone) + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE ' + QUOTENAME(@clone) + N';';
    EXEC(@sql);
END

PRINT '';
PRINT '============================================================================';
IF @passed = @total
    PRINT 'ALL TESTS PASSED: ' + CAST(@passed AS NVARCHAR(5)) + '/' + CAST(@total AS NVARCHAR(5));
ELSE
    PRINT 'TESTS FAILED: ' + CAST(@passed AS NVARCHAR(5)) + '/' + CAST(@total AS NVARCHAR(5));
PRINT '============================================================================';
GO
