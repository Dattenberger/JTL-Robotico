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
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§1, D10 — CustomWorkflows is
--      an additive shared zone co-inhabited by excel_ekl; only touch our own objects)
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
    -- Fallback only: the article's ACTUAL domestic rate is resolved below; this
    -- constant is used solely when that resolution yields nothing.
    DECLARE @VAT_RATE_FALLBACK DECIMAL(6,4) = 0.19;
    DECLARE @vatRate DECIMAL(6,4);
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

        -- Resolve the article's ACTUAL domestic VAT rate (README §4: resolve by name,
        -- don't hard-code). Reduced-rate articles (7%) otherwise get a wrong gross value
        -- in the history. The gross is display-only — change-detection compares net +
        -- buffer, not gross — so an unresolvable rate degrades gracefully to the 19%
        -- fallback rather than failing the workflow. "Inland" is JTL's domestic tax zone.
        SELECT TOP (1) @vatRate = ss.fSteuersatz / 100.0
        FROM dbo.tArtikel a
        JOIN dbo.tSteuersatz ss ON ss.kSteuerklasse = a.kSteuerklasse
        JOIN dbo.tSteuerzone sz ON sz.kSteuerzone   = ss.kSteuerzone
        WHERE a.kArtikel = @kArtikel
          AND sz.cName   = N'Inland'
        ORDER BY sz.kSteuerzone;

        IF @vatRate IS NULL
            SET @vatRate = @VAT_RATE_FALLBACK;

        -- A missing 'Vergangene Preise' field definition throws inside the helper
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
            SET @vkBrutto = @currentVkNetto * (1 + @vatRate);

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
