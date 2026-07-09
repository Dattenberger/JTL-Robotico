-- ============================================================================
-- CustomWorkflows.spArticleAppendPriceHistory — JTL action: append price history
-- ============================================================================
-- Custom workflow action. Appends a new entry to the 'Vergangene Preise' custom
-- field of an article when the net price or buffer changed since the last entry.
-- Uses the Robotico EscapedCSV + custom-field API. Trims to the last 1000 entries.
--
-- Ported from WorkflowProcedures/history/spArticleAppendPriceHistory.sql
-- (2026-07-10): removed per-file XACT_ABORT/BEGIN TRAN scaffolding; registration
-- moved to guarded trailing calls (module-provided helpers).
-- ============================================================================

CREATE OR ALTER PROCEDURE CustomWorkflows.spArticleAppendPriceHistory
    @kArtikel INT,
    @userName NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- Configuration constants
    DECLARE @FIELD_NAME NVARCHAR(255) = 'Vergangene Preise';
    DECLARE @DEFAULT_USERNAME NVARCHAR(100) = '[Unbekannt]';
    DECLARE @VAT_RATE DECIMAL(5,4) = 0.19;
    DECLARE @MAX_ENTRIES INT = 1000;
    DECLARE @TRIM_BUFFER INT = 10;
    DECLARE @PRICE_THRESHOLD DECIMAL(10,4) = 0.001;
    DECLARE @BUFFER_PREFIX NVARCHAR(20) = 'Puffer ';

    -- Working variables
    DECLARE @currentVkNetto DECIMAL(25,13);
    DECLARE @currentPuffer INT;
    DECLARE @vkBrutto DECIMAL(25,13);
    DECLARE @lastVkNetto DECIMAL(25,13);
    DECLARE @lastPuffer INT;

    DECLARE @existingHistory NVARCHAR(MAX);
    DECLARE @lastEntry NVARCHAR(MAX);
    DECLARE @newEntry NVARCHAR(MAX);
    DECLARE @kArtikelAttribut INT;
    DECLARE @hasChanged BIT = 0;

    BEGIN TRY
        SET @userName = Robotico.fnEscapedCSVSanitize(@userName, @DEFAULT_USERNAME);

        SELECT @currentVkNetto = fVKNetto,
               @currentPuffer = ISNULL(nPuffer, 0)
        FROM dbo.tArtikel
        WHERE kArtikel = @kArtikel;

        IF @currentVkNetto IS NULL
        BEGIN
            RAISERROR('Article not found: %d', 16, 1, @kArtikel);
            RETURN;
        END

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

            SET @lastVkNetto = Robotico.fnStringParseGermanDecimal(
                Robotico.fnEscapedCSVGetField(@lastEntry, 2, ';'));

            DECLARE @pufferPart NVARCHAR(50);
            SET @pufferPart = Robotico.fnEscapedCSVGetField(@lastEntry, 4, ';');

            IF @pufferPart LIKE @BUFFER_PREFIX + '%'
                SET @lastPuffer = TRY_CAST(SUBSTRING(@pufferPart, LEN(@BUFFER_PREFIX) + 1, 10) AS INT);
        END

        IF @lastVkNetto IS NULL
            OR @lastPuffer IS NULL
            OR ABS(ROUND(@currentVkNetto, 2) - @lastVkNetto) > @PRICE_THRESHOLD
            OR @currentPuffer <> @lastPuffer
        BEGIN
            SET @hasChanged = 1;
        END

        IF @hasChanged = 1
        BEGIN
            SET @vkBrutto = @currentVkNetto * (1 + @VAT_RATE);

            SET @newEntry = CONCAT_WS('; ',
                FORMAT(GETDATE(), 'dd.MM.yyyy HH:mm:ss', 'de-DE'),
                FORMAT(@currentVkNetto, 'N2', 'de-DE'),
                FORMAT(@vkBrutto, 'N2', 'de-DE'),
                @BUFFER_PREFIX + CAST(@currentPuffer AS NVARCHAR(10)),
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
    EXEC CustomWorkflows._CheckAction @actionName = 'spArticleAppendPriceHistory';
ELSE
    PRINT '! CustomWorkflows._CheckAction missing — Custom Workflow Actions module not booked; skipping validation.';
GO

IF OBJECT_ID('CustomWorkflows._SetActionDisplayName', 'P') IS NOT NULL
    EXEC CustomWorkflows._SetActionDisplayName
        @actionName = 'spArticleAppendPriceHistory',
        @displayName = 'Historie: Preis aktualisieren';
ELSE
    PRINT '! CustomWorkflows._SetActionDisplayName missing — module not booked; skipping label registration.';
GO
