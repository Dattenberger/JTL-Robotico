-- ============================================================================
-- CustomWorkflows.spArticleAppendLabelHistory — JTL action: append label history
-- ============================================================================
-- Custom workflow action. Appends a new entry to the 'Vergangene Label' custom
-- field when the article's label set changed since the last entry. Label names
-- are comma-stripped (to keep the in-field ', ' separator unambiguous) and then
-- run through Robotico.fnEscapedCSVSanitize (removes ';', quotes, CR/LF) so they
-- cannot break the '; ' field separator or the CRLF entry separator on read-back.
-- Write and read-back aggregate identically (same normalization, same ORDER BY),
-- so change-detection is stable even for comma-bearing labels.
--
-- Ported from WorkflowProcedures/history/spArticleAppendLabelHistory.sql (2026-07-10).
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§1, D10 — CustomWorkflows is
--      an additive shared zone co-inhabited by excel_ekl; only touch our own objects)
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

        -- Normalize each label (strip commas that would clash with the ', '
        -- in-field separator, then sanitise ';'/quotes/CR/LF via the EscapedCSV
        -- write contract) and order by that normalized form. The read-back below
        -- re-aggregates the same way (STRING_AGG(t.label) WITHIN GROUP (ORDER BY
        -- t.label) over a derived table), so identical label sets compare equal.
        SELECT @currentLabels = STRING_AGG(t.label, @LABEL_SEPARATOR) WITHIN GROUP (ORDER BY t.label)
        FROM (
            SELECT Robotico.fnEscapedCSVSanitize(REPLACE(l.cName, ',', ''), NULL) AS label
            FROM dbo.tArtikelLabel al
            INNER JOIN dbo.tLabel l ON al.kLabel = l.kLabel
            WHERE al.kArtikel = @kArtikel
        ) t;

        IF @currentLabels IS NULL
            SET @currentLabels = '';

        -- A missing 'Vergangene Label' field definition throws inside the helper
        -- and propagates through this TRY (no return-code path).
        EXEC Robotico.spEnsureArticleCustomField
            @kArtikel = @kArtikel,
            @fieldName = @FIELD_NAME,
            @kSprache = 0,
            @kArtikelAttribut = @kArtikelAttribut OUTPUT,
            @currentValue = @existingHistory OUTPUT;

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
