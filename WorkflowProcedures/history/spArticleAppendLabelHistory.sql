USE eazybusiness
GO

IF EXISTS(SELECT 1 FROM sys.procedures WHERE Name = 'spArticleAppendLabelHistory' AND schema_id = SCHEMA_ID('CustomWorkflows'))
    DROP PROCEDURE CustomWorkflows.spArticleAppendLabelHistory
GO

CREATE PROCEDURE CustomWorkflows.spArticleAppendLabelHistory
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
    DECLARE @SEPARATOR NVARCHAR(5) = '; ';
    DECLARE @LABEL_SEPARATOR NVARCHAR(5) = ', ';

    -- Working variables
    DECLARE @currentLabels NVARCHAR(MAX);
    DECLARE @lastLabels NVARCHAR(MAX);

    DECLARE @existingHistory NVARCHAR(MAX);
    DECLARE @lastEntry NVARCHAR(MAX);
    DECLARE @newEntry NVARCHAR(MAX);
    DECLARE @kArtikelAttribut INT;
    DECLARE @hasChanged BIT = 0;
    DECLARE @lineCount INT;

    BEGIN TRY
        SET @userName = LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
            ISNULL(@userName, ''), ';', ''), CHAR(13), ''), CHAR(10), ''), '''', ''), '"', '')));
        IF LEN(@userName) = 0
            SET @userName = @DEFAULT_USERNAME;

        SELECT @currentLabels = STRING_AGG(LTRIM(RTRIM(l.cName)), @LABEL_SEPARATOR) WITHIN GROUP (ORDER BY l.cName)
        FROM dbo.tArtikelLabel al
        INNER JOIN dbo.tLabel l ON al.kLabel = l.kLabel
        WHERE al.kArtikel = @kArtikel;

        IF @currentLabels IS NULL
            SET @currentLabels = '';

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

            BEGIN TRY
                SELECT @lastLabels = LTRIM(RTRIM(value))
                FROM STRING_SPLIT(@lastEntry, ';', 1)
                WHERE ordinal = 2;

                IF @lastLabels IS NOT NULL AND LEN(@lastLabels) > 0
                BEGIN
                    SELECT @lastLabels = STRING_AGG(LTRIM(RTRIM(value)), @LABEL_SEPARATOR) WITHIN GROUP (ORDER BY value)
                    FROM STRING_SPLIT(@lastLabels, ',', 1);
                END
                ELSE
                    SET @lastLabels = '';
            END TRY
            BEGIN CATCH
                SET @lastLabels = NULL;
            END CATCH
        END

        IF @lastLabels IS NULL OR @currentLabels <> @lastLabels
        BEGIN
            SET @hasChanged = 1;
        END

        IF @hasChanged = 1
        BEGIN
            SET @newEntry =
                FORMAT(GETDATE(), 'dd.MM.yyyy HH:mm:ss', 'de-DE') + @SEPARATOR +
                @currentLabels + @SEPARATOR +
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

EXEC CustomWorkflows._CheckAction @actionName = 'spArticleAppendLabelHistory'
GO

EXEC CustomWorkflows._SetActionDisplayName
    @actionName = 'spArticleAppendLabelHistory',
    @displayName = 'Historie: Label aktualisieren'
GO
