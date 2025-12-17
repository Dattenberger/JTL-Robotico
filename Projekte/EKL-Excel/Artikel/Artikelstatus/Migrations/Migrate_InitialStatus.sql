-- ============================================================================
-- Initial Artikelstatus Migration Script
-- Schema: Robotico
-- ============================================================================
-- Assigns initial Artikelstatus (AS: label) to all articles without one.
-- Should be run ONCE after labels and SP are created.
-- ============================================================================
-- IMPORTANT: Run in batches for large databases to avoid timeout/locking issues
-- ============================================================================

SET NOCOUNT ON;

DECLARE @BatchSize INT = 1000;
DECLARE @ProcessedCount INT = 0;
DECLARE @TotalCount INT;
DECLARE @BatchNumber INT = 0;

-- ============================================================================
-- Step 1: Find articles without AS: label
-- ============================================================================
DECLARE @ArticlesToProcess TABLE (
    kArtikel INT PRIMARY KEY,
    nRowNum INT
);

INSERT INTO @ArticlesToProcess (kArtikel, nRowNum)
SELECT
    a.kArtikel,
    ROW_NUMBER() OVER (ORDER BY a.kArtikel) AS nRowNum
FROM dbo.tArtikel a
WHERE a.nIstVater = 0  -- Exclude parent articles
  AND NOT EXISTS (
    SELECT 1
    FROM dbo.tArtikelLabel al
    INNER JOIN dbo.tLabel l ON al.kLabel = l.kLabel
    WHERE al.kArtikel = a.kArtikel
      AND l.cName LIKE 'AS:%'
      AND l.nTyp = 3
  );

SET @TotalCount = (SELECT COUNT(*) FROM @ArticlesToProcess);

PRINT '============================================================================';
PRINT 'Initial Artikelstatus Migration';
PRINT '============================================================================';
PRINT 'Articles without AS: label found: ' + CAST(@TotalCount AS VARCHAR(10));
PRINT 'Batch size: ' + CAST(@BatchSize AS VARCHAR(10));
PRINT '============================================================================';

IF @TotalCount = 0
BEGIN
    PRINT 'No articles to process. All articles already have an AS: label.';
    RETURN;
END

-- ============================================================================
-- Step 2: Process in batches
-- ============================================================================
WHILE @ProcessedCount < @TotalCount
BEGIN
    SET @BatchNumber = @BatchNumber + 1;

    DECLARE @BatchStart INT = @ProcessedCount + 1;
    DECLARE @BatchEnd INT = @ProcessedCount + @BatchSize;

    PRINT '';
    PRINT 'Processing batch ' + CAST(@BatchNumber AS VARCHAR(10)) +
          ' (rows ' + CAST(@BatchStart AS VARCHAR(10)) +
          ' to ' + CAST(CASE WHEN @BatchEnd > @TotalCount THEN @TotalCount ELSE @BatchEnd END AS VARCHAR(10)) +
          ' of ' + CAST(@TotalCount AS VARCHAR(10)) + ')...';

    -- Process each article in the batch
    DECLARE @kArtikel INT;
    DECLARE batch_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT kArtikel
        FROM @ArticlesToProcess
        WHERE nRowNum >= @BatchStart AND nRowNum <= @BatchEnd
        ORDER BY nRowNum;

    OPEN batch_cursor;
    FETCH NEXT FROM batch_cursor INTO @kArtikel;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            -- Call the SP to assign initial status
            EXEC Robotico.spArtikelLabelArtikelstatus
                @kArtikel = @kArtikel,
                @kBenutzer = NULL,
                @cBenutzerName = 'MIGRATION',
                @cSource = 'MIGRATION_INITIAL_STATUS';

            SET @ProcessedCount = @ProcessedCount + 1;
        END TRY
        BEGIN CATCH
            PRINT 'ERROR processing kArtikel=' + CAST(@kArtikel AS VARCHAR(10)) +
                  ': ' + ERROR_MESSAGE();
        END CATCH

        FETCH NEXT FROM batch_cursor INTO @kArtikel;
    END

    CLOSE batch_cursor;
    DEALLOCATE batch_cursor;

    -- Progress report
    PRINT 'Batch ' + CAST(@BatchNumber AS VARCHAR(10)) + ' complete. ' +
          'Total processed: ' + CAST(@ProcessedCount AS VARCHAR(10)) + '/' + CAST(@TotalCount AS VARCHAR(10)) +
          ' (' + CAST(CAST(@ProcessedCount * 100.0 / @TotalCount AS INT) AS VARCHAR(3)) + '%)';

    -- Optional: Add delay between batches to reduce server load
    -- WAITFOR DELAY '00:00:01';
END

-- ============================================================================
-- Step 3: Summary Report
-- ============================================================================
PRINT '';
PRINT '============================================================================';
PRINT 'Migration Complete';
PRINT '============================================================================';
PRINT 'Total articles processed: ' + CAST(@ProcessedCount AS VARCHAR(10));
PRINT '';

-- Show distribution of assigned labels
SELECT
    l.cName AS cLabelName,
    COUNT(*) AS nArticleCount
FROM dbo.tArtikelLabel al
INNER JOIN dbo.tLabel l ON al.kLabel = l.kLabel
INNER JOIN Robotico.tArtikelLabelHistory h ON h.kArtikel = al.kArtikel AND h.kLabel = al.kLabel
WHERE l.cName LIKE 'AS:%'
  AND l.nTyp = 3
  AND h.cSource LIKE 'MIGRATION%'
GROUP BY l.cName
ORDER BY COUNT(*) DESC;

PRINT '============================================================================';
GO
