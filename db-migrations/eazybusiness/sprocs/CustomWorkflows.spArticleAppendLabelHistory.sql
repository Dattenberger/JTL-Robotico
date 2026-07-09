-- ============================================================================
-- CustomWorkflows.spArticleAppendLabelHistory — JTL action: append label history
-- ============================================================================
-- Custom workflow action. Appends a new entry to the 'Vergangene Label' custom
-- field when the article's label set changed since the last entry. Commas are
-- stripped from label names to keep the ', ' separator unambiguous on read-back.
--
-- Ported from WorkflowProcedures/history/spArticleAppendLabelHistory.sql (2026-07-10).
-- ============================================================================

CREATE OR ALTER PROCEDURE CustomWorkflows.spArticleAppendLabelHistory
    @kArtikel INT,
    @userName NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- Configuration constants
    DECLARE @FIELD_NAME NVARCHAR(255) = 'Vergangene Label';
    DECLARE @DEFAULT_USERNAME NVARCHAR(100) = '[Unbekannt]';
    DECLARE @MAX_ENTRIES INT = 1000;
    DECLARE @TRIM_BUFFER INT = 10;
    DECLARE @LABEL_SEPARATOR NVARCHAR(5) = ', ';

    -- Working variables
    DECLARE @currentLabels NVARCHAR(MAX);
    DECLARE @lastLabels NVARCHAR(MAX);

    DECLARE @existingHistory NVARCHAR(MAX);
    DECLARE @lastEntry NVARCHAR(MAX);
    DECLARE @newEntry NVARCHAR(MAX);
    DECLARE @kArtikelAttribut INT;
    DECLARE @hasChanged BIT = 0;

    BEGIN TRY
        SET @userName = Robotico.fnEscapedCSVSanitize(@userName, @DEFAULT_USERNAME);

        -- Strip commas from label names: the ', ' separator would otherwise be ambiguous on read-back
        SELECT @currentLabels = STRING_AGG(LTRIM(RTRIM(REPLACE(l.cName, ',', ''))), @LABEL_SEPARATOR) WITHIN GROUP (ORDER BY l.cName)
        FROM dbo.tArtikelLabel al
        INNER JOIN dbo.tLabel l ON al.kLabel = l.kLabel
        WHERE al.kArtikel = @kArtikel;

        IF @currentLabels IS NULL
            SET @currentLabels = '';

        DECLARE @returnCode INT;
        EXEC @returnCode = Robotico.spEnsureArticleCustomField
            @kArtikel = @kArtikel,
            @fieldName = @FIELD_NAME,
            @kSprache = 0,
            @kArtikelAttribut = @kArtikelAttribut OUTPUT,
            @currentValue = @existingHistory OUTPUT;

        IF @returnCode <> 0
            RETURN;

        IF Robotico.fnStringIsEffectivelyEmpty(@existingHistory) = 0
        BEGIN
            SET @lastEntry = Robotico.fnEscapedCSVGetLastLine(@existingHistory);
            SET @lastLabels = Robotico.fnEscapedCSVGetField(@lastEntry, 2, ';');

            IF @lastLabels IS NOT NULL AND LEN(@lastLabels) > 0
            BEGIN
                SELECT @lastLabels = STRING_AGG(t.label, @LABEL_SEPARATOR) WITHIN GROUP (ORDER BY t.label)
                FROM (SELECT LTRIM(RTRIM(value)) AS label FROM STRING_SPLIT(@lastLabels, ',', 1)) t;
            END
            ELSE
                SET @lastLabels = '';
        END

        IF @lastLabels IS NULL OR @currentLabels <> @lastLabels
        BEGIN
            SET @hasChanged = 1;
        END

        IF @hasChanged = 1
        BEGIN
            SET @newEntry = CONCAT_WS('; ',
                FORMAT(GETDATE(), 'dd.MM.yyyy HH:mm:ss', 'de-DE'),
                @currentLabels,
                @userName);

            IF Robotico.fnStringIsEffectivelyEmpty(@existingHistory) = 1
                SET @existingHistory = @newEntry;
            ELSE
                SET @existingHistory = @existingHistory + CHAR(13) + CHAR(10) + @newEntry;

            IF Robotico.fnStringCountLines(@existingHistory) > @MAX_ENTRIES + @TRIM_BUFFER
                SET @existingHistory = Robotico.fnStringTrimToMaxLines(@existingHistory, @MAX_ENTRIES);

            UPDATE dbo.tArtikelAttributSprache
            SET cWertVarchar = @existingHistory
            WHERE kArtikelAttribut = @kArtikelAttribut AND kSprache = 0;
        END

    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO

-- Registration (see db-migrations/README.md §6). Guarded module-provided helpers.
IF OBJECT_ID('CustomWorkflows._CheckAction', 'P') IS NOT NULL
    EXEC CustomWorkflows._CheckAction @actionName = 'spArticleAppendLabelHistory';
ELSE
    PRINT '! CustomWorkflows._CheckAction missing — Custom Workflow Actions module not booked; skipping validation.';
GO

IF OBJECT_ID('CustomWorkflows._SetActionDisplayName', 'P') IS NOT NULL
    EXEC CustomWorkflows._SetActionDisplayName
        @actionName = 'spArticleAppendLabelHistory',
        @displayName = 'Historie: Label aktualisieren';
ELSE
    PRINT '! CustomWorkflows._SetActionDisplayName missing — module not booked; skipping label registration.';
GO
