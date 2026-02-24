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

-- No transaction needed for read-only test
DECLARE @testValue NVARCHAR(MAX);
SET @testValue = Robotico.fnGetArticleCustomFieldValue(19807, 'Vergangene Preise', 0);

IF @testValue IS NULL
    PRINT '✓ Correctly returns NULL (article has no binding yet)';
ELSE
    PRINT '⚠ Value found: ' + LEFT(@testValue, 50) + CASE WHEN LEN(@testValue) > 50 THEN '...' ELSE '' END;

PRINT '';
GO

-- ============================================================================
-- Test 2: Read Function - Non-existing Field Definition
-- ============================================================================
PRINT '--- Test 2: Read Function (non-existing field definition) ---';

-- No transaction needed for read-only test
DECLARE @testValue NVARCHAR(MAX);
SET @testValue = Robotico.fnGetArticleCustomFieldValue(19807, 'NonExistentFieldDefinition', 0);

IF @testValue IS NULL
    PRINT '✓ Correctly returns NULL for non-existing field definition';
ELSE
    PRINT '✗ ERROR: Should return NULL for non-existing field';

PRINT '';
GO

-- ============================================================================
-- Test 3: Auto-Create Binding via spEnsure (with Rollback)
-- ============================================================================
PRINT '--- Test 3: Auto-create binding (with automatic rollback) ---';

BEGIN TRANSACTION;
BEGIN TRY
    DECLARE @kArtikelAttribut INT;
    DECLARE @currentValue NVARCHAR(MAX);
    DECLARE @returnCode INT;

    -- This should auto-create the binding since 19807 has no binding yet
    EXEC @returnCode = Robotico.spEnsureArticleCustomField
        @kArtikel = 19807,
        @fieldName = 'Vergangene Preise',
        @kSprache = 0,
        @kArtikelAttribut = @kArtikelAttribut OUTPUT,
        @currentValue = @currentValue OUTPUT;

    IF @returnCode = 0
    BEGIN
        PRINT '✓ Binding ensured successfully (auto-created)';
        PRINT '  - kArtikelAttribut: ' + CAST(@kArtikelAttribut AS NVARCHAR(20));
        PRINT '  - Current Value: ' + ISNULL(LEFT(@currentValue, 50), 'NULL (expected for new binding)');

        -- Verify binding exists within transaction
        DECLARE @verifyValue NVARCHAR(MAX);
        SET @verifyValue = Robotico.fnGetArticleCustomFieldValue(19807, 'Vergangene Preise', 0);

        IF @verifyValue IS NULL
            PRINT '✓ Binding verified (NULL value as expected)';
        ELSE
            PRINT '⚠ Unexpected value in binding';
    END
    ELSE
        PRINT '✗ ERROR: Return code = ' + CAST(@returnCode AS NVARCHAR(10));

    -- Rollback - binding will be deleted
    ROLLBACK TRANSACTION;
    PRINT '✓ Transaction rolled back - no data remains in database';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;
    PRINT '✗ ERROR: ' + ERROR_MESSAGE();
END CATCH

PRINT '';
GO

-- ============================================================================
-- Test 4: Write SP - First Entry with Auto-Creation (with Rollback)
-- ============================================================================
PRINT '--- Test 4: Write SP (auto-create and write first value, then rollback) ---';

BEGIN TRANSACTION;
BEGIN TRY
    DECLARE @timestamp NVARCHAR(50) = FORMAT(GETDATE(), 'yyyy-MM-dd HH:mm:ss');
    DECLARE @testValue NVARCHAR(MAX) = 'API Test Entry ' + @timestamp + '; 99,99€; Test User';
    DECLARE @returnCode INT;

    -- Write value (will auto-create binding if it doesn't exist)
    EXEC @returnCode = Robotico.spSetArticleCustomFieldValue
        @kArtikel = 19807,
        @fieldName = 'Vergangene Preise',
        @newValue = @testValue;

    IF @returnCode = 0
    BEGIN
        PRINT '✓ Value written successfully (binding auto-created)';

        -- Verify with read function
        DECLARE @readBack NVARCHAR(MAX);
        SET @readBack = Robotico.fnGetArticleCustomFieldValue(19807, 'Vergangene Preise', 0);

        IF @readBack = @testValue
            PRINT '✓ Read-back verification successful';
        ELSE IF @readBack IS NOT NULL
            PRINT '⚠ Read-back value differs (unexpected)';
        ELSE
            PRINT '✗ ERROR: Read-back returned NULL after write';
    END
    ELSE
        PRINT '✗ ERROR: Return code = ' + CAST(@returnCode AS NVARCHAR(10));

    -- Rollback - all changes will be undone
    ROLLBACK TRANSACTION;
    PRINT '✓ Transaction rolled back - no data remains in database';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;
    PRINT '✗ ERROR: ' + ERROR_MESSAGE();
END CATCH

PRINT '';
GO

-- ============================================================================
-- Test 5: Write SP - Update Existing Value (with Rollback)
-- ============================================================================
PRINT '--- Test 5: Write SP (create, update, then rollback both) ---';

BEGIN TRANSACTION;
BEGIN TRY
    DECLARE @timestamp NVARCHAR(50) = FORMAT(GETDATE(), 'yyyy-MM-dd HH:mm:ss');
    DECLARE @firstValue NVARCHAR(MAX) = 'First Entry ' + @timestamp + '; 99,99€; User1';
    DECLARE @secondValue NVARCHAR(MAX) = 'Updated Entry ' + @timestamp + '; 105,50€; User2';
    DECLARE @returnCode INT;

    -- Write first value
    EXEC @returnCode = Robotico.spSetArticleCustomFieldValue
        @kArtikel = 19807,
        @fieldName = 'Vergangene Preise',
        @newValue = @firstValue;

    IF @returnCode = 0
        PRINT '✓ First value written';
    ELSE
        RAISERROR('First write failed', 16, 1);

    -- Update with second value
    EXEC @returnCode = Robotico.spSetArticleCustomFieldValue
        @kArtikel = 19807,
        @fieldName = 'Vergangene Preise',
        @newValue = @secondValue;

    IF @returnCode = 0
    BEGIN
        PRINT '✓ Value updated successfully';

        -- Verify update
        DECLARE @readBack NVARCHAR(MAX);
        SET @readBack = Robotico.fnGetArticleCustomFieldValue(19807, 'Vergangene Preise', 0);

        IF @readBack = @secondValue
            PRINT '✓ Update verification successful';
        ELSE
            PRINT '⚠ Read-back value differs from expected';
    END
    ELSE
        PRINT '✗ ERROR: Return code = ' + CAST(@returnCode AS NVARCHAR(10));

    -- Rollback - both writes will be undone
    ROLLBACK TRANSACTION;
    PRINT '✓ Transaction rolled back - no data remains in database';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;
    PRINT '✗ ERROR: ' + ERROR_MESSAGE();
END CATCH

PRINT '';
GO

-- ============================================================================
-- Test 6: Error Handling - Non-existing Field Definition
-- ============================================================================
PRINT '--- Test 6: Error handling (non-existing field definition) ---';

BEGIN TRANSACTION;
BEGIN TRY
    DECLARE @returnCode INT;
    EXEC @returnCode = Robotico.spSetArticleCustomFieldValue
        @kArtikel = 19807,
        @fieldName = 'NonExistentFieldDefinitionInJTL',
        @newValue = 'Test';

    IF @returnCode = -1
        PRINT '✓ Correctly returns error code -1 for non-existing field';
    ELSE
        PRINT '⚠ Unexpected return code: ' + CAST(@returnCode AS NVARCHAR(10));

    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    IF ERROR_MESSAGE() LIKE '%Custom field definition not found%'
        PRINT '✓ Correctly throws error for non-existing field definition';
    ELSE
        PRINT '⚠ Unexpected error: ' + ERROR_MESSAGE();
END CATCH

PRINT '';
GO

-- ============================================================================
-- Test 7: Append to History - Multiple Entries (with Rollback)
-- ============================================================================
PRINT '--- Test 7: Append multiple entries (history pattern, then rollback) ---';

BEGIN TRANSACTION;
BEGIN TRY
    DECLARE @returnCode INT;

    -- Write first entry
    DECLARE @entry1 NVARCHAR(MAX) = FORMAT(GETDATE(), 'dd.MM.yyyy HH:mm:ss') + '; 99,99€; Entry 1';
    EXEC @returnCode = Robotico.spSetArticleCustomFieldValue
        @kArtikel = 19807,
        @fieldName = 'Vergangene Preise',
        @newValue = @entry1;

    IF @returnCode <> 0
        RAISERROR('First entry write failed', 16, 1);

    -- Read and append second entry
    DECLARE @existingHistory NVARCHAR(MAX);
    SET @existingHistory = Robotico.fnGetArticleCustomFieldValue(19807, 'Vergangene Preise', 0);

    DECLARE @entry2 NVARCHAR(MAX) = FORMAT(GETDATE(), 'dd.MM.yyyy HH:mm:ss') + '; 105,50€; Entry 2';
    DECLARE @updatedHistory NVARCHAR(MAX) = @existingHistory + CHAR(13) + CHAR(10) + @entry2;

    EXEC @returnCode = Robotico.spSetArticleCustomFieldValue
        @kArtikel = 19807,
        @fieldName = 'Vergangene Preise',
        @newValue = @updatedHistory;

    IF @returnCode <> 0
        RAISERROR('Second entry append failed', 16, 1);

    -- Read and append third entry
    SET @existingHistory = Robotico.fnGetArticleCustomFieldValue(19807, 'Vergangene Preise', 0);

    DECLARE @entry3 NVARCHAR(MAX) = FORMAT(GETDATE(), 'dd.MM.yyyy HH:mm:ss') + '; 110,00€; Entry 3';
    SET @updatedHistory = @existingHistory + CHAR(13) + CHAR(10) + @entry3;

    EXEC @returnCode = Robotico.spSetArticleCustomFieldValue
        @kArtikel = 19807,
        @fieldName = 'Vergangene Preise',
        @newValue = @updatedHistory;

    IF @returnCode = 0
    BEGIN
        PRINT '✓ History entries appended successfully';

        -- Count lines
        DECLARE @readBack NVARCHAR(MAX);
        SET @readBack = Robotico.fnGetArticleCustomFieldValue(19807, 'Vergangene Preise', 0);

        DECLARE @lineCount INT;
        SET @lineCount = LEN(@readBack) - LEN(REPLACE(@readBack, CHAR(10), '')) + 1;

        PRINT '  - History contains ' + CAST(@lineCount AS NVARCHAR(10)) + ' entries (expected: 3)';

        IF @lineCount = 3
            PRINT '✓ Line count correct';
        ELSE
            PRINT '⚠ Line count mismatch';
    END
    ELSE
        PRINT '✗ ERROR: Return code = ' + CAST(@returnCode AS NVARCHAR(10));

    -- Rollback - all 3 entries will be deleted
    ROLLBACK TRANSACTION;
    PRINT '✓ Transaction rolled back - no data remains in database';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;
    PRINT '✗ ERROR: ' + ERROR_MESSAGE();
END CATCH

PRINT '';
GO

-- ============================================================================
-- Test 8: Verify Clean State (19807 should have no bindings after rollbacks)
-- ============================================================================
PRINT '--- Test 8: Verify clean state (19807 should have no bindings) ---';

DECLARE @finalValue NVARCHAR(MAX);
SET @finalValue = Robotico.fnGetArticleCustomFieldValue(19807, 'Vergangene Preise', 0);

IF @finalValue IS NULL
    PRINT '✓ Article 19807 has no bindings - database is clean after tests';
ELSE
BEGIN
    PRINT '✗ ERROR: Article 19807 has data remaining after tests!';
    PRINT '  Value found: ' + LEFT(@finalValue, 100);
    PRINT '  This indicates a transaction was not rolled back correctly.';
END

PRINT '';
GO

-- ============================================================================
-- Test Summary
-- ============================================================================
PRINT '============================================================================';
PRINT 'Test Suite Complete';
PRINT '============================================================================';
PRINT '';
PRINT 'All tests executed using transactions with automatic rollback.';
PRINT 'Article kArtikel = 19807 should remain unchanged (no custom field data).';
PRINT '';
PRINT 'Review the output above for any ✗ ERROR or ⚠ WARNING indicators.';
PRINT 'All tests with ✓ markers have passed successfully.';
PRINT '';
PRINT 'Database State: CLEAN (all transactions rolled back)';
PRINT '';
GO
