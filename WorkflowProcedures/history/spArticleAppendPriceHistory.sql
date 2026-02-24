USE eazybusiness
GO

IF EXISTS(SELECT 1 FROM sys.procedures WHERE Name = 'spArticleAppendPriceHistory' AND schema_id = SCHEMA_ID('CustomWorkflows'))
    DROP PROCEDURE CustomWorkflows.spArticleAppendPriceHistory
GO

CREATE PROCEDURE CustomWorkflows.spArticleAppendPriceHistory
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
    DECLARE @SEPARATOR NVARCHAR(5) = '; ';

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
    DECLARE @lineCount INT;

    DECLARE @ParsedParts TABLE (ordinal INT, value NVARCHAR(MAX));

    BEGIN TRY
        SET @userName = LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
            ISNULL(@userName, ''), ';', ''), CHAR(13), ''), CHAR(10), ''), '''', ''), '"', '')));
        IF LEN(@userName) = 0
            SET @userName = @DEFAULT_USERNAME;

        SELECT @currentVkNetto = fVKNetto,
               @currentPuffer = ISNULL(nPuffer, 0)
        FROM dbo.tArtikel
        WHERE kArtikel = @kArtikel;

        IF @currentVkNetto IS NULL
        BEGIN
            RAISERROR('Article not found: %d', 16, 1, @kArtikel);
            RETURN;
        END

        SELECT @kArtikelAttribut = aa.kArtikelAttribut,
               @existingHistory = aas.cWertVarchar
        FROM dbo.tArtikelAttribut aa
        INNER JOIN dbo.tAttribut attr ON aa.kAttribut = attr.kAttribut
        INNER JOIN dbo.tArtikelAttributSprache aas ON aa.kArtikelAttribut = aas.kArtikelAttribut
        INNER JOIN dbo.tAttributSprache attrs ON attr.kAttribut = attrs.kAttribut
        WHERE aa.kArtikel = @kArtikel
          AND attrs.cName = @FIELD_NAME
          AND aas.kSprache = 0
          AND attrs.kSprache = 0
          AND aa.kShop = 0;

        IF @kArtikelAttribut IS NULL
        BEGIN
            RAISERROR('Custom field not found: %s', 16, 1, @FIELD_NAME);
            RETURN;
        END

        -- Check if history has actual content (not just whitespace including Tab/CR/LF)
        IF @existingHistory IS NOT NULL AND LEN(LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(@existingHistory, CHAR(9), ''), CHAR(13), ''), CHAR(10), '')))) > 0
        BEGIN
            IF CHARINDEX(CHAR(10), @existingHistory) > 0
                SET @lastEntry = RIGHT(@existingHistory, CHARINDEX(CHAR(10), REVERSE(@existingHistory)) - 1);
            ELSE
                SET @lastEntry = @existingHistory;

            SET @lastEntry = REPLACE(@lastEntry, CHAR(13), '');

            INSERT INTO @ParsedParts (ordinal, value)
            SELECT ordinal, LTRIM(RTRIM(value))
            FROM STRING_SPLIT(@lastEntry, ';', 1);

            BEGIN TRY
                -- German number format: Remove thousand separators (dots) first, then replace decimal comma
                SELECT @lastVkNetto = TRY_CAST(REPLACE(REPLACE(value, '.', ''), ',', '.') AS DECIMAL(25,13))
                FROM @ParsedParts WHERE ordinal = 2;

                DECLARE @pufferPart NVARCHAR(50);
                SELECT @pufferPart = value FROM @ParsedParts WHERE ordinal = 4;

                IF @pufferPart LIKE @BUFFER_PREFIX + '%'
                    SET @lastPuffer = TRY_CAST(SUBSTRING(@pufferPart, LEN(@BUFFER_PREFIX) + 1, 10) AS INT);
            END TRY
            BEGIN CATCH
                SET @lastVkNetto = NULL;
                SET @lastPuffer = NULL;
            END CATCH
        END

        IF @lastVkNetto IS NULL
            OR @lastPuffer IS NULL
            OR ABS(@currentVkNetto - @lastVkNetto) > @PRICE_THRESHOLD
            OR @currentPuffer <> @lastPuffer
        BEGIN
            SET @hasChanged = 1;
        END

        IF @hasChanged = 1
        BEGIN
            SET @vkBrutto = @currentVkNetto * (1 + @VAT_RATE);

            SET @newEntry =
                FORMAT(GETDATE(), 'dd.MM.yyyy HH:mm:ss', 'de-DE') + @SEPARATOR +
                FORMAT(@currentVkNetto, 'N2', 'de-DE') + @SEPARATOR +
                FORMAT(@vkBrutto, 'N2', 'de-DE') + @SEPARATOR +
                @BUFFER_PREFIX + CAST(@currentPuffer AS NVARCHAR(10)) + @SEPARATOR +
                @userName;

            -- Treat whitespace-only (including Tab/CR/LF) as empty
            IF @existingHistory IS NULL OR LEN(LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(@existingHistory, CHAR(9), ''), CHAR(13), ''), CHAR(10), '')))) = 0
                SET @existingHistory = @newEntry;
            ELSE
                SET @existingHistory = @existingHistory + CHAR(13) + CHAR(10) + @newEntry;

            UPDATE dbo.tArtikelAttributSprache
            SET cWertVarchar = @existingHistory
            WHERE kArtikelAttribut = @kArtikelAttribut AND kSprache = 0;

            SET @lineCount = LEN(@existingHistory) - LEN(REPLACE(@existingHistory, CHAR(10), '')) + 1;

            IF @lineCount > @MAX_ENTRIES + @TRIM_BUFFER
            BEGIN
                DECLARE @trimmedValue NVARCHAR(MAX);
                SELECT @trimmedValue = STRING_AGG(
                    REPLACE(value, CHAR(13), ''),
                    CHAR(13) + CHAR(10)
                ) WITHIN GROUP (ORDER BY ordinal)
                FROM STRING_SPLIT(@existingHistory, CHAR(10), 1)
                WHERE ordinal > (@lineCount - @MAX_ENTRIES)
                  AND LEN(LTRIM(RTRIM(REPLACE(value, CHAR(13), '')))) > 0;

                UPDATE dbo.tArtikelAttributSprache
                SET cWertVarchar = @trimmedValue
                WHERE kArtikelAttribut = @kArtikelAttribut AND kSprache = 0;
            END
        END

    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO

EXEC CustomWorkflows._CheckAction @actionName = 'spArticleAppendPriceHistory'
GO

EXEC CustomWorkflows._SetActionDisplayName
    @actionName = 'spArticleAppendPriceHistory',
    @displayName = 'Historie: Preis aktualisieren'
GO
