-- Regression test for CustomWorkflows.spGebindeErstellen idempotency (F4.6).
-- Manual integration test; run against a test mandant / the E2E container, never prod.
-- Run FROM this directory so the guard include resolves:
--   cd db-migrations/tests/eazybusiness
--   sqlcmd -S <server> -U sa -C -b -d <eazybusiness clone> -i GebindeErstellen_Tests.sql
--
-- All writes happen inside a transaction that is ALWAYS rolled back — no DB changes remain.
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (F4.6 — spGebindeErstellen idempotency)
-- @see db-migrations/eazybusiness/sprocs/CustomWorkflows.spGebindeErstellen.sql
:r ../_e2e_guard.sql
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
GO

IF OBJECT_ID('tempdb..#TestResults') IS NOT NULL DROP TABLE #TestResults;
CREATE TABLE #TestResults (testName NVARCHAR(200), passed INT, total INT);
GO

PRINT '============================================================================';
PRINT 'CustomWorkflows.spGebindeErstellen - Idempotency Regression (F4.6)';
PRINT '============================================================================';
PRINT '';

-- ============================================================================
-- Test 1: single run (baseline) -> exactly 1 tGebinde row + single suffix
-- ============================================================================
PRINT '--- Test 1: single run -> 1 tGebinde row, single suffix ---';

DECLARE @t1_passed INT = 0, @t1_total INT = 2;

BEGIN TRANSACTION;
BEGIN TRY
    INSERT INTO dbo.tArtikel (cArtNr, nPuffer, cHAN, cBarcode)
    VALUES (N'F46-ART-1', 0, N'F46-HAN-1', N'F46-GTIN-1');
    DECLARE @k1 INT = CAST(SCOPE_IDENTITY() AS INT);

    EXEC CustomWorkflows.spGebindeErstellen @kArtikel = @k1;

    DECLARE @g1 INT = (SELECT COUNT(*) FROM dbo.tGebinde WHERE kArtikel = @k1);
    IF @g1 = 1
    BEGIN PRINT '  + single run -> 1 tGebinde row'; SET @t1_passed += 1; END
    ELSE PRINT '  x single run: expected 1 tGebinde row (got ' + CAST(@g1 AS NVARCHAR(10)) + ')';

    DECLARE @han1 NVARCHAR(255) = (SELECT cHAN FROM dbo.tArtikel WHERE kArtikel = @k1);
    IF @han1 = N'F46-HAN-1-keine-Lieferanten-angepasst'
    BEGIN PRINT '  + single suffix applied: ' + @han1; SET @t1_passed += 1; END
    ELSE PRINT '  x single suffix: FAILED (got: "' + ISNULL(@han1, 'NULL') + '")';

    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT '  x ERROR: ' + ERROR_MESSAGE();
END CATCH

INSERT INTO #TestResults VALUES ('single run baseline', @t1_passed, @t1_total);
GO

-- ============================================================================
-- Test 2: DOUBLE run -> still exactly 1 row + NO doubled suffix (idempotent)
--         This is the F4.6 regression: pre-fix this produced 2 rows and a
--         '...-keine-Lieferanten-angepasst-keine-Lieferanten-angepasst' HAN.
-- ============================================================================
PRINT '--- Test 2: double run -> idempotent (1 row, single suffix) ---';

DECLARE @t2_passed INT = 0, @t2_total INT = 2;

BEGIN TRANSACTION;
BEGIN TRY
    INSERT INTO dbo.tArtikel (cArtNr, nPuffer, cHAN, cBarcode)
    VALUES (N'F46-ART-2', 0, N'F46-HAN-2', N'F46-GTIN-2');
    DECLARE @k2 INT = CAST(SCOPE_IDENTITY() AS INT);

    EXEC CustomWorkflows.spGebindeErstellen @kArtikel = @k2;
    EXEC CustomWorkflows.spGebindeErstellen @kArtikel = @k2;   -- second call must be a no-op

    DECLARE @gcount INT = (SELECT COUNT(*) FROM dbo.tGebinde WHERE kArtikel = @k2);
    IF @gcount = 1
    BEGIN PRINT '  + double run -> still 1 tGebinde row (no duplicate insert)'; SET @t2_passed += 1; END
    ELSE PRINT '  x double run: expected 1 tGebinde row (got ' + CAST(@gcount AS NVARCHAR(10)) + ')';

    DECLARE @han2 NVARCHAR(255) = (SELECT cHAN FROM dbo.tArtikel WHERE kArtikel = @k2);
    IF @han2 = N'F46-HAN-2-keine-Lieferanten-angepasst'
    BEGIN PRINT '  + suffix not doubled: ' + @han2; SET @t2_passed += 1; END
    ELSE PRINT '  x suffix doubled/wrong: FAILED (got: "' + ISNULL(@han2, 'NULL') + '")';

    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT '  x ERROR: ' + ERROR_MESSAGE();
END CATCH

INSERT INTO #TestResults VALUES ('double run idempotent', @t2_passed, @t2_total);
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
        + ' checks in ' + CAST(@sectionCount AS NVARCHAR(5)) + ' sections. DB State: CLEAN (rolled back)';
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
