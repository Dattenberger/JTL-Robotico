SET XACT_ABORT ON
GO

BEGIN TRANSACTION
GO

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

IF XACT_STATE() = 1
BEGIN
    COMMIT TRANSACTION;
    PRINT '+ Stored Procedure CustomWorkflows.spArticleAppendPriceHistory deployed';

    EXEC CustomWorkflows._CheckAction @actionName = 'spArticleAppendPriceHistory';

    EXEC CustomWorkflows._SetActionDisplayName
        @actionName = 'spArticleAppendPriceHistory',
        @displayName = 'Historie: Preis aktualisieren';
END
ELSE
BEGIN
    IF XACT_STATE() = -1
        ROLLBACK TRANSACTION;
    PRINT '! DEPLOYMENT FAILED - Alle Aenderungen wurden zurueckgerollt';
END
GO
