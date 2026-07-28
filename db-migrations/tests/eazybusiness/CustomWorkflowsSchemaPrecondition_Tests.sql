-- Regression test for the CustomWorkflows-schema precondition (F4.1 / up/0004).
-- Manual integration test; run against the E2E container / a test server, never prod.
-- Run FROM this directory so the guard include resolves:
--   cd db-migrations/tests/eazybusiness
--   sqlcmd -S <server> -U sa -C -b -d eazybusiness -i CustomWorkflowsSchemaPrecondition_Tests.sql
--
-- Proves:
--   ROT (pre-fix behaviour): a CREATE of a CustomWorkflows.* proc in a DB WITHOUT the
--        schema fails with the bare, unhelpful Msg 2760.
--   GRUEN (fix): the precondition up/0004 turns that into a clear, actionable THROW 50002
--        naming the missing JTL "Custom Workflow Actions" module.
--
-- It creates and drops a throwaway scratch DB; nothing else is modified. The -d database
-- (eazybusiness, which HAS the schema) is only READ, to exercise the real up/0004 no-op path.
-- @see db-migrations/eazybusiness/up/0004_customworkflows_schema_precondition.sql
:r ../_e2e_guard.sql
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
GO

IF OBJECT_ID('tempdb..#TestResults') IS NOT NULL DROP TABLE #TestResults;
CREATE TABLE #TestResults (testName NVARCHAR(200), passed INT, total INT);
GO

PRINT '============================================================================';
PRINT 'CustomWorkflows schema precondition - Regression (F4.1 / up/0004)';
PRINT '============================================================================';
PRINT '';

DECLARE @scratch sysname = N'robotico_f41_precond_test';
DECLARE @sql nvarchar(max);

-- Fresh scratch DB WITHOUT the CustomWorkflows schema. (A function call like QUOTENAME
-- cannot sit inside EXEC()'s concatenated argument, so build each statement into @sql first.)
IF DB_ID(@scratch) IS NOT NULL
BEGIN
    SET @sql = N'ALTER DATABASE ' + QUOTENAME(@scratch) + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE ' + QUOTENAME(@scratch) + N';';
    EXEC(@sql);
END
SET @sql = N'CREATE DATABASE ' + QUOTENAME(@scratch) + N';';
EXEC(@sql);
PRINT 'scratch DB [' + @scratch + '] created (no CustomWorkflows schema).';
PRINT '';

-- ============================================================================
-- Test 1: ROT condition — bare Msg 2760 without the schema
-- ============================================================================
PRINT '--- Test 1: CustomWorkflows proc CREATE without schema -> Msg 2760 ---';
DECLARE @t1_passed INT = 0, @t1_total INT = 1;
DECLARE @createInScratch nvarchar(max) =
    N'USE ' + QUOTENAME(@scratch) + N'; ' +
    N'EXEC(''CREATE OR ALTER PROCEDURE CustomWorkflows.spProbe @k INT AS BEGIN SET NOCOUNT ON; END'');';
BEGIN TRY
    EXEC(@createInScratch);
    PRINT '  x CREATE unexpectedly succeeded (schema present?)';
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 2760
    BEGIN PRINT '  + got the expected bare Msg 2760 (schema missing)'; SET @t1_passed += 1; END
    ELSE PRINT '  x expected Msg 2760, got Msg ' + CAST(ERROR_NUMBER() AS NVARCHAR(10)) + ': ' + ERROR_MESSAGE();
END CATCH
INSERT INTO #TestResults VALUES ('bare 2760 without schema', @t1_passed, @t1_total);

-- ============================================================================
-- Test 2: GRUEN — the precondition check yields a clear THROW 50002.
--         (Mirrors up/0004's SCHEMA_ID guard; up/0004 is the SSoT — run against the
--         scratch DB context here. Kept in lock-step with that file.)
-- ============================================================================
PRINT '--- Test 2: precondition on schema-less DB -> clear THROW 50002 ---';
DECLARE @t2_passed INT = 0, @t2_total INT = 2;
DECLARE @precondInScratch nvarchar(max) =
    N'USE ' + QUOTENAME(@scratch) + N'; ' +
    N'IF SCHEMA_ID(N''CustomWorkflows'') IS NULL ' +
    N'THROW 50002, ''Precondition failed: schema [CustomWorkflows] is missing. It is provided by the JTL "Custom Workflow Actions" module (not by this chain) — book the module, restart Wawi and refresh the license, then re-deploy. See docs/SQL/JTL-CUSTOM-WORKFLOWS.md.'', 1;';
BEGIN TRY
    EXEC(@precondInScratch);
    PRINT '  x precondition did not THROW (schema unexpectedly present?)';
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 50002
    BEGIN PRINT '  + precondition THROWs 50002 (fail-fast)'; SET @t2_passed += 1; END
    ELSE PRINT '  x expected Msg 50002, got Msg ' + CAST(ERROR_NUMBER() AS NVARCHAR(10));

    IF ERROR_MESSAGE() LIKE N'%Custom Workflow Actions%module%'
    BEGIN PRINT '  + message names the missing module (actionable)'; SET @t2_passed += 1; END
    ELSE PRINT '  x message not actionable: ' + ERROR_MESSAGE();
END CATCH
INSERT INTO #TestResults VALUES ('clear THROW 50002 without schema', @t2_passed, @t2_total);

-- ============================================================================
-- Test 3: no-op path — the REAL up/0004 file passes where the schema EXISTS.
--         Runs against the connected -d DB (eazybusiness has CustomWorkflows).
-- ============================================================================
PRINT '--- Test 3: real up/0004 is a no-op where CustomWorkflows exists ---';
DECLARE @t3_passed INT = 0, @t3_total INT = 1;
IF SCHEMA_ID(N'CustomWorkflows') IS NOT NULL
BEGIN PRINT '  + connected DB has CustomWorkflows -> up/0004 would PRINT OK and journal (no THROW)'; SET @t3_passed += 1; END
ELSE PRINT '  x connected DB lacks CustomWorkflows -> run this against an eazybusiness DB with the module booked';
INSERT INTO #TestResults VALUES ('up/0004 no-op with schema', @t3_passed, @t3_total);
GO
-- Exercise the actual fix file end-to-end against the connected DB (must not THROW here).
:r ../../eazybusiness/up/0004_customworkflows_schema_precondition.sql

-- Cleanup scratch DB.
DECLARE @scratch2 sysname = N'robotico_f41_precond_test';
DECLARE @sqlc nvarchar(max);
IF DB_ID(@scratch2) IS NOT NULL
BEGIN
    SET @sqlc = N'ALTER DATABASE ' + QUOTENAME(@scratch2) + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE ' + QUOTENAME(@scratch2) + N';';
    EXEC(@sqlc);
END
PRINT 'scratch DB dropped.';
GO

-- ============================================================================
-- Summary
-- ============================================================================
DECLARE @totalPassed INT, @totalTests INT, @failedSections INT, @sectionCount INT;
SELECT @totalPassed = SUM(passed), @totalTests = SUM(total),
       @failedSections = SUM(CASE WHEN passed < total THEN 1 ELSE 0 END),
       @sectionCount = COUNT(*)
FROM #TestResults;

PRINT '';
PRINT '============================================================================';
IF @failedSections = 0
    PRINT 'ALL TESTS PASSED: ' + CAST(@totalPassed AS NVARCHAR(5)) + '/' + CAST(@totalTests AS NVARCHAR(5))
        + ' checks in ' + CAST(@sectionCount AS NVARCHAR(5)) + ' sections.';
ELSE
BEGIN
    PRINT 'TESTS FAILED: ' + CAST(@totalPassed AS NVARCHAR(5)) + '/' + CAST(@totalTests AS NVARCHAR(5))
        + ' passed, ' + CAST(@failedSections AS NVARCHAR(5)) + ' section(s) with failures.';
    DECLARE @fn NVARCHAR(200), @fp INT, @ft INT;
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT testName, passed, total FROM #TestResults WHERE passed < total;
    OPEN c; FETCH NEXT FROM c INTO @fn, @fp, @ft;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        PRINT '  x ' + @fn + ': ' + CAST(@fp AS NVARCHAR(5)) + '/' + CAST(@ft AS NVARCHAR(5));
        FETCH NEXT FROM c INTO @fn, @fp, @ft;
    END
    CLOSE c; DEALLOCATE c;
END
PRINT '============================================================================';

DROP TABLE #TestResults;
GO
