-- ============================================================================
-- Article Label History Append Stored Procedure
-- Schema: Robotico
-- ============================================================================
-- Compares current labels with last snapshot and writes SET/REMOVED events
-- Stores new snapshot for future comparisons
-- ============================================================================

-- Create schema if not exists
IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'Robotico')
    EXEC('CREATE SCHEMA Robotico');
GO

-- Drop procedure if exists (for updates)
IF OBJECT_ID('Robotico.spArticleAppendLabelHistory', 'P') IS NOT NULL
    DROP PROCEDURE Robotico.spArticleAppendLabelHistory;
GO

CREATE PROCEDURE Robotico.spArticleAppendLabelHistory
    @kArtikel INT,
    @kBenutzer INT = NULL,
    @cBenutzerName NVARCHAR(255) = NULL,
    @cSource NVARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @currentLabels TABLE (kLabel INT, cLabelName NVARCHAR(255));
    DECLARE @previousLabels TABLE (kLabel INT);
    DECLARE @newLabelsSnapshot NVARCHAR(MAX);
    DECLARE @dNow DATETIME2 = GETDATE();

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Get current labels from tArtikelLabel
        INSERT INTO @currentLabels (kLabel, cLabelName)
        SELECT al.kLabel, l.cName
        FROM dbo.tArtikelLabel al
        INNER JOIN dbo.tLabel l ON al.kLabel = l.kLabel
        WHERE al.kArtikel = @kArtikel;

        -- Get labels from last snapshot (parse JSON or use distinct query)
        -- For simplicity, we query the most recent SET events that weren't REMOVED
        ;WITH LastEvents AS (
            SELECT
                kLabel,
                cAction,
                ROW_NUMBER() OVER (PARTITION BY kLabel ORDER BY dCreated DESC) AS rn
            FROM Robotico.tArtikelLabelHistory
            WHERE kArtikel = @kArtikel
        )
        INSERT INTO @previousLabels (kLabel)
        SELECT kLabel
        FROM LastEvents
        WHERE rn = 1 AND cAction = 'SET';

        -- Build new snapshot JSON
        SELECT @newLabelsSnapshot = '[' +
            STUFF((
                SELECT ',"' + REPLACE(cLabelName, '"', '\"') + '"'
                FROM @currentLabels
                FOR XML PATH(''), TYPE
            ).value('.', 'NVARCHAR(MAX)'), 1, 1, '') + ']';

        -- If no labels, set empty array
        IF @newLabelsSnapshot IS NULL
            SET @newLabelsSnapshot = '[]';

        -- Insert SET events for new labels (in current but not in previous)
        INSERT INTO Robotico.tArtikelLabelHistory (
            kArtikel, kLabel, cLabelName, cAction, kBenutzer, cBenutzerName, cSource, dCreated, cLabelsSnapshot
        )
        SELECT
            @kArtikel,
            c.kLabel,
            c.cLabelName,
            'SET',
            @kBenutzer,
            @cBenutzerName,
            @cSource,
            @dNow,
            @newLabelsSnapshot
        FROM @currentLabels c
        WHERE NOT EXISTS (SELECT 1 FROM @previousLabels p WHERE p.kLabel = c.kLabel);

        -- Insert REMOVED events for removed labels (in previous but not in current)
        INSERT INTO Robotico.tArtikelLabelHistory (
            kArtikel, kLabel, cLabelName, cAction, kBenutzer, cBenutzerName, cSource, dCreated, cLabelsSnapshot
        )
        SELECT
            @kArtikel,
            p.kLabel,
            l.cName,
            'REMOVED',
            @kBenutzer,
            @cBenutzerName,
            @cSource,
            @dNow,
            @newLabelsSnapshot
        FROM @previousLabels p
        INNER JOIN dbo.tLabel l ON p.kLabel = l.kLabel
        WHERE NOT EXISTS (SELECT 1 FROM @currentLabels c WHERE c.kLabel = p.kLabel);

        COMMIT TRANSACTION;

        -- Report results
        DECLARE @setCount INT = (SELECT COUNT(*) FROM @currentLabels c WHERE NOT EXISTS (SELECT 1 FROM @previousLabels p WHERE p.kLabel = c.kLabel));
        DECLARE @removedCount INT = (SELECT COUNT(*) FROM @previousLabels p WHERE NOT EXISTS (SELECT 1 FROM @currentLabels c WHERE c.kLabel = p.kLabel));

        IF @setCount > 0 OR @removedCount > 0
            PRINT 'Label history updated for kArtikel=' + CAST(@kArtikel AS VARCHAR(10)) +
                  ': ' + CAST(@setCount AS VARCHAR(10)) + ' SET, ' + CAST(@removedCount AS VARCHAR(10)) + ' REMOVED';
        ELSE
            PRINT 'No label changes detected for kArtikel=' + CAST(@kArtikel AS VARCHAR(10));

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();
        DECLARE @ErrorState INT = ERROR_STATE();

        RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);
    END CATCH
END
GO

-- ============================================================================
-- Usage Examples
-- ============================================================================
-- EXEC Robotico.spArticleAppendLabelHistory
--     @kArtikel = 12345,
--     @kBenutzer = 1,
--     @cBenutzerName = 'Admin',
--     @cSource = 'JTL_WORKFLOW';
-- ============================================================================

PRINT 'Stored Procedure Robotico.spArticleAppendLabelHistory created successfully.';
GO
