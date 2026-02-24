-- ============================================================================
-- Test Suite für Generic Article Custom Field API (Transaction-based)
-- ============================================================================
-- Description:
--   Test-Queries zum Validieren der Article Custom Field API nach Deployment.
--   Jeder Test läuft in einer eigenen Transaction und wird automatisch
--   zurückgerollt - keine Datenbank-Änderungen verbleiben nach den Tests.
--
-- Components tested:
--   - Robotico.fnGetArticleCustomFieldValue      (Read Function)
--   - Robotico.spEnsureArticleCustomField        (Internal Helper)
--   - Robotico.spSetArticleCustomFieldValue      (Write SP)
--
-- Test Article: kArtikel = 19807 (KEINE Custom Field Werte - ideal für Tests)
--
-- Pattern: BEGIN TRANSACTION → Test → ROLLBACK TRANSACTION
--
-- Author: Lukas Dattenberger
-- Date: 2026-02-24
-- ============================================================================

IF OBJECT_ID('tempdb..#TestResults') IS NOT NULL DROP TABLE #TestResults;
CREATE TABLE #TestResults (testName NVARCHAR(100), passed INT, total INT);
GO

PRINT '============================================================================';
PRINT 'Article Custom Field API Test Suite (Transaction-based)';
PRINT '============================================================================';
PRINT '';
PRINT 'Test Article: kArtikel = 19807 (KEINE Custom Field Werte)';
PRINT 'All tests use transactions and rollback automatically.';
PRINT 'No database changes will remain after test execution.';
PRINT '';

-- ============================================================================
-- Test 1: Read Function - Empty Value (19807 hat KEINE Werte)
-- ============================================================================
PRINT '--- Test 1: Read Function (should return NULL - 19807 has no bindings) ---';

DECLARE @t1_passed INT = 0, @t1_total INT = 1;
DECLARE @testValue NVARCHAR(MAX);
SET @testValue = Robotico.fnGetArticleCustomFieldValue(19807, 'Vergangene Preise', 0);

IF @testValue IS NULL
BEGIN PRINT '  + NULL returned (no binding yet)'; SET @t1_passed += 1; END
ELSE
    PRINT '  x Value found: ' + LEFT(@testValue, 50) + CASE WHEN LEN(@testValue) > 50 THEN '...' ELSE '' END;

PRINT '  Result: ' + CAST(@t1_passed AS NVARCHAR(5)) + '/' + CAST(@t1_total AS NVARCHAR(5)) + ' passed';
INSERT INTO #TestResults VALUES ('Read: NULL for unbound article', @t1_passed, @t1_total);
PRINT '';
GO

-- ============================================================================
-- Test 2: Read Function - Non-existing Field Definition
-- ============================================================================
PRINT '--- Test 2: Read Function (non-existing field definition) ---';

DECLARE @t2_passed INT = 0, @t2_total INT = 1;
DECLARE @testValue NVARCHAR(MAX);
SET @testValue = Robotico.fnGetArticleCustomFieldValue(19807, 'NonExistentFieldDefinition', 0);

IF @testValue IS NULL
BEGIN PRINT '  + NULL for non-existing field definition'; SET @t2_passed += 1; END
ELSE
    PRINT '  x Should return NULL for non-existing field';

PRINT '  Result: ' + CAST(@t2_passed AS NVARCHAR(5)) + '/' + CAST(@t2_total AS NVARCHAR(5)) + ' passed';
INSERT INTO #TestResults VALUES ('Read: NULL for non-existing field', @t2_passed, @t2_total);
PRINT '';
GO

-- ============================================================================
-- Test 3: Auto-Create Binding via spEnsure (with Rollback)
-- ============================================================================
PRINT '--- Test 3: Auto-create binding (with automatic rollback) ---';

DECLARE @t3_passed INT = 0, @t3_total INT = 2;

BEGIN TRANSACTION;
BEGIN TRY
    DECLARE @kArtikelAttribut INT;
    DECLARE @currentValue NVARCHAR(MAX);
    DECLARE @returnCode INT;

    EXEC @returnCode = Robotico.spEnsureArticleCustomField
        @kArtikel = 19807,
        @fieldName = 'Vergangene Preise',
        @kSprache = 0,
        @kArtikelAttribut = @kArtikelAttribut OUTPUT,
        @currentValue = @currentValue OUTPUT;

    IF @returnCode = 0
    BEGIN
        PRINT '  + Binding ensured (kArtikelAttribut=' + CAST(@kArtikelAttribut AS NVARCHAR(20)) + ')';
        SET @t3_passed += 1;

        DECLARE @verifyValue NVARCHAR(MAX);
        SET @verifyValue = Robotico.fnGetArticleCustomFieldValue(19807, 'Vergangene Preise', 0);

        IF @verifyValue IS NULL
        BEGIN PRINT '  + Binding verified (NULL value as expected)'; SET @t3_passed += 1; END
        ELSE
            PRINT '  x Unexpected value in binding';
    END
    ELSE
        PRINT '  x Return code = ' + CAST(@returnCode AS NVARCHAR(10));

    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;
    PRINT '  x ERROR: ' + ERROR_MESSAGE();
END CATCH

PRINT '  Result: ' + CAST(@t3_passed AS NVARCHAR(5)) + '/' + CAST(@t3_total AS NVARCHAR(5)) + ' passed';
INSERT INTO #TestResults VALUES ('spEnsureArticleCustomField', @t3_passed, @t3_total);
PRINT '';
GO

-- ============================================================================
-- Test 4: Write SP - First Entry with Auto-Creation (with Rollback)
-- ============================================================================
PRINT '--- Test 4: Write SP (auto-create and write first value, then rollback) ---';

DECLARE @t4_passed INT = 0, @t4_total INT = 2;

BEGIN TRANSACTION;
BEGIN TRY
    DECLARE @timestamp NVARCHAR(50) = FORMAT(GETDATE(), 'yyyy-MM-dd HH:mm:ss');
    DECLARE @testValue NVARCHAR(MAX) = 'API Test Entry ' + @timestamp + '; 99,99; Test User';
    DECLARE @returnCode INT;

    EXEC @returnCode = Robotico.spSetArticleCustomFieldValue
        @kArtikel = 19807,
        @fieldName = 'Vergangene Preise',
        @newValue = @testValue;

    IF @returnCode = 0
    BEGIN
        PRINT '  + Value written (binding auto-created)';
        SET @t4_passed += 1;

        DECLARE @readBack NVARCHAR(MAX);
        SET @readBack = Robotico.fnGetArticleCustomFieldValue(19807, 'Vergangene Preise', 0);

        IF @readBack = @testValue
        BEGIN PRINT '  + Read-back verification successful'; SET @t4_passed += 1; END
        ELSE
            PRINT '  x Read-back mismatch (got: ' + ISNULL(LEFT(@readBack, 50), 'NULL') + ')';
    END
    ELSE
        PRINT '  x Return code = ' + CAST(@returnCode AS NVARCHAR(10));

    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;
    PRINT '  x ERROR: ' + ERROR_MESSAGE();
END CATCH

PRINT '  Result: ' + CAST(@t4_passed AS NVARCHAR(5)) + '/' + CAST(@t4_total AS NVARCHAR(5)) + ' passed';
INSERT INTO #TestResults VALUES ('Write: auto-create + write', @t4_passed, @t4_total);
PRINT '';
GO

-- ============================================================================
-- Test 5: Write SP - Update Existing Value (with Rollback)
-- ============================================================================
PRINT '--- Test 5: Write SP (create, update, then rollback both) ---';

DECLARE @t5_passed INT = 0, @t5_total INT = 3;

BEGIN TRANSACTION;
BEGIN TRY
    DECLARE @timestamp NVARCHAR(50) = FORMAT(GETDATE(), 'yyyy-MM-dd HH:mm:ss');
    DECLARE @firstValue NVARCHAR(MAX) = 'First Entry ' + @timestamp + '; 99,99; User1';
    DECLARE @secondValue NVARCHAR(MAX) = 'Updated Entry ' + @timestamp + '; 105,50; User2';
    DECLARE @returnCode INT;

    EXEC @returnCode = Robotico.spSetArticleCustomFieldValue
        @kArtikel = 19807,
        @fieldName = 'Vergangene Preise',
        @newValue = @firstValue;

    IF @returnCode = 0
    BEGIN PRINT '  + First value written'; SET @t5_passed += 1; END
    ELSE
        RAISERROR('First write failed', 16, 1);

    EXEC @returnCode = Robotico.spSetArticleCustomFieldValue
        @kArtikel = 19807,
        @fieldName = 'Vergangene Preise',
        @newValue = @secondValue;

    IF @returnCode = 0
    BEGIN
        PRINT '  + Value updated'; SET @t5_passed += 1;

        DECLARE @readBack NVARCHAR(MAX);
        SET @readBack = Robotico.fnGetArticleCustomFieldValue(19807, 'Vergangene Preise', 0);

        IF @readBack = @secondValue
        BEGIN PRINT '  + Update verification successful'; SET @t5_passed += 1; END
        ELSE
            PRINT '  x Read-back value differs';
    END
    ELSE
        PRINT '  x Return code = ' + CAST(@returnCode AS NVARCHAR(10));

    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;
    PRINT '  x ERROR: ' + ERROR_MESSAGE();
END CATCH

PRINT '  Result: ' + CAST(@t5_passed AS NVARCHAR(5)) + '/' + CAST(@t5_total AS NVARCHAR(5)) + ' passed';
INSERT INTO #TestResults VALUES ('Write: update existing value', @t5_passed, @t5_total);
PRINT '';
GO

-- ============================================================================
-- Test 6: Error Handling - Non-existing Field Definition
-- ============================================================================
PRINT '--- Test 6: Error handling (non-existing field definition) ---';

DECLARE @t6_passed INT = 0, @t6_total INT = 1;

BEGIN TRANSACTION;
BEGIN TRY
    DECLARE @returnCode INT;
    EXEC @returnCode = Robotico.spSetArticleCustomFieldValue
        @kArtikel = 19807,
        @fieldName = 'NonExistentFieldDefinitionInJTL',
        @newValue = 'Test';

    IF @returnCode = -1
    BEGIN PRINT '  + Error code -1 for non-existing field'; SET @t6_passed += 1; END
    ELSE
        PRINT '  x Unexpected return code: ' + CAST(@returnCode AS NVARCHAR(10));

    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    IF ERROR_MESSAGE() LIKE '%Custom field definition not found%'
    BEGIN PRINT '  + Error thrown for non-existing field definition'; SET @t6_passed += 1; END
    ELSE
        PRINT '  x Unexpected error: ' + ERROR_MESSAGE();
END CATCH

PRINT '  Result: ' + CAST(@t6_passed AS NVARCHAR(5)) + '/' + CAST(@t6_total AS NVARCHAR(5)) + ' passed';
INSERT INTO #TestResults VALUES ('Error: non-existing field', @t6_passed, @t6_total);
PRINT '';
GO

-- ============================================================================
-- Test 7: Append to History - Multiple Entries (with Rollback)
-- ============================================================================
PRINT '--- Test 7: Append multiple entries (history pattern, then rollback) ---';

DECLARE @t7_passed INT = 0, @t7_total INT = 2;

BEGIN TRANSACTION;
BEGIN TRY
    DECLARE @returnCode INT;

    DECLARE @entry1 NVARCHAR(MAX) = FORMAT(GETDATE(), 'dd.MM.yyyy HH:mm:ss') + '; 99,99; Entry 1';
    EXEC @returnCode = Robotico.spSetArticleCustomFieldValue
        @kArtikel = 19807,
        @fieldName = 'Vergangene Preise',
        @newValue = @entry1;

    IF @returnCode <> 0
        RAISERROR('First entry write failed', 16, 1);

    DECLARE @existingHistory NVARCHAR(MAX);
    SET @existingHistory = Robotico.fnGetArticleCustomFieldValue(19807, 'Vergangene Preise', 0);

    DECLARE @entry2 NVARCHAR(MAX) = FORMAT(GETDATE(), 'dd.MM.yyyy HH:mm:ss') + '; 105,50; Entry 2';
    DECLARE @updatedHistory NVARCHAR(MAX) = @existingHistory + CHAR(13) + CHAR(10) + @entry2;

    EXEC @returnCode = Robotico.spSetArticleCustomFieldValue
        @kArtikel = 19807,
        @fieldName = 'Vergangene Preise',
        @newValue = @updatedHistory;

    IF @returnCode <> 0
        RAISERROR('Second entry append failed', 16, 1);

    SET @existingHistory = Robotico.fnGetArticleCustomFieldValue(19807, 'Vergangene Preise', 0);

    DECLARE @entry3 NVARCHAR(MAX) = FORMAT(GETDATE(), 'dd.MM.yyyy HH:mm:ss') + '; 110,00; Entry 3';
    SET @updatedHistory = @existingHistory + CHAR(13) + CHAR(10) + @entry3;

    EXEC @returnCode = Robotico.spSetArticleCustomFieldValue
        @kArtikel = 19807,
        @fieldName = 'Vergangene Preise',
        @newValue = @updatedHistory;

    IF @returnCode = 0
    BEGIN
        PRINT '  + 3 history entries appended'; SET @t7_passed += 1;

        DECLARE @readBack NVARCHAR(MAX);
        SET @readBack = Robotico.fnGetArticleCustomFieldValue(19807, 'Vergangene Preise', 0);

        DECLARE @lineCount INT;
        SET @lineCount = LEN(@readBack) - LEN(REPLACE(@readBack, CHAR(10), '')) + 1;

        IF @lineCount = 3
        BEGIN PRINT '  + Line count correct (3)'; SET @t7_passed += 1; END
        ELSE
            PRINT '  x Line count mismatch (got: ' + CAST(@lineCount AS NVARCHAR(10)) + ')';
    END
    ELSE
        PRINT '  x Return code = ' + CAST(@returnCode AS NVARCHAR(10));

    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;
    PRINT '  x ERROR: ' + ERROR_MESSAGE();
END CATCH

PRINT '  Result: ' + CAST(@t7_passed AS NVARCHAR(5)) + '/' + CAST(@t7_total AS NVARCHAR(5)) + ' passed';
INSERT INTO #TestResults VALUES ('Write: append history entries', @t7_passed, @t7_total);
PRINT '';
GO

-- ============================================================================
-- Test 8: Verify Clean State (19807 should have no bindings after rollbacks)
-- ============================================================================
PRINT '--- Test 8: Verify clean state (19807 should have no bindings) ---';

DECLARE @t8_passed INT = 0, @t8_total INT = 1;
DECLARE @finalValue NVARCHAR(MAX);
SET @finalValue = Robotico.fnGetArticleCustomFieldValue(19807, 'Vergangene Preise', 0);

IF @finalValue IS NULL
BEGIN PRINT '  + Database clean (no bindings remain)'; SET @t8_passed += 1; END
ELSE
BEGIN
    PRINT '  x Data remaining after tests!';
    PRINT '    Value: ' + LEFT(@finalValue, 100);
    PRINT '    Transaction was not rolled back correctly.';
END

PRINT '  Result: ' + CAST(@t8_passed AS NVARCHAR(5)) + '/' + CAST(@t8_total AS NVARCHAR(5)) + ' passed';
INSERT INTO #TestResults VALUES ('Verify: clean state', @t8_passed, @t8_total);
PRINT '';
GO

-- ============================================================================
-- Test Summary
-- ============================================================================
DECLARE @totalPassed INT, @totalTests INT, @failedSections INT, @sectionCount INT;
SELECT @totalPassed = SUM(passed),
       @totalTests = SUM(total),
       @failedSections = SUM(CASE WHEN passed < total THEN 1 ELSE 0 END),
       @sectionCount = COUNT(*)
FROM #TestResults;

PRINT '============================================================================';
IF @failedSections = 0
BEGIN
    PRINT 'ALL TESTS PASSED: '
        + CAST(@totalPassed AS NVARCHAR(5)) + '/'
        + CAST(@totalTests AS NVARCHAR(5)) + ' checks in '
        + CAST(@sectionCount AS NVARCHAR(5)) + ' test sections';
    PRINT '';
    PRINT 'Database State: CLEAN (all transactions rolled back)';
END
ELSE
BEGIN
    PRINT 'TESTS FAILED: '
        + CAST(@totalPassed AS NVARCHAR(5)) + '/'
        + CAST(@totalTests AS NVARCHAR(5)) + ' checks passed, '
        + CAST(@failedSections AS NVARCHAR(5)) + ' section(s) with failures:';
    PRINT '';

    DECLARE @failName NVARCHAR(100), @failPassed INT, @failTotal INT;
    DECLARE failCursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT testName, passed, total FROM #TestResults WHERE passed < total;
    OPEN failCursor;
    FETCH NEXT FROM failCursor INTO @failName, @failPassed, @failTotal;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        PRINT '  x ' + @failName + ': ' + CAST(@failPassed AS NVARCHAR(5)) + '/' + CAST(@failTotal AS NVARCHAR(5));
        FETCH NEXT FROM failCursor INTO @failName, @failPassed, @failTotal;
    END
    CLOSE failCursor;
    DEALLOCATE failCursor;
END
PRINT '============================================================================';
PRINT '';

DROP TABLE #TestResults;
GO
