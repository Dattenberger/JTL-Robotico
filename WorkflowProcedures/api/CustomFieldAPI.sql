-- ============================================================================
-- Generic Custom Field API for JTL eazybusiness
-- ============================================================================
-- Description:
--   Reusable API for reading and writing JTL custom fields (eigene Felder)
--   with automatic binding creation.
--
-- Public API (2 components):
--   1. Robotico.fnGetArticleCustomFieldValue    - Read-only function for SELECT
--   2. Robotico.spSetArticleCustomFieldValue    - Write SP with auto-creation
--
-- Internal Helper:
--   - Robotico.spEnsureArticleCustomField       - Auto-creates bindings (used internally)
--
-- Author: Lukas Dattenberger
-- Date: 2026-02-24
-- Version: 1.0
-- ============================================================================

-- ============================================================================
-- Create Robotico Schema if it doesn't exist
-- ============================================================================
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'Robotico')
BEGIN
    EXEC('CREATE SCHEMA Robotico');
    PRINT '+ Schema Robotico created';
END
ELSE
    PRINT '= Schema Robotico already exists';
GO

-- ============================================================================
-- Transactional Deployment
-- ============================================================================
SET XACT_ABORT ON
GO

BEGIN TRANSACTION
GO

-- ============================================================================
-- 1. READ FUNCTION: fnGetArticleCustomFieldValue
-- ============================================================================
-- Description:
--   Read-only function to retrieve custom field values for articles.
--   Can be used directly in SELECT statements.
--
-- Parameters:
--   @kArtikel    - Article ID
--   @fieldName   - Custom field name (e.g., 'Vergangene Preise')
--   @kSprache    - Language ID (0 = German, default)
--
-- Returns:
--   NVARCHAR(MAX) - Custom field value, or NULL if not found
--
-- Usage:
--   -- Simple read
--   SELECT Robotico.fnGetArticleCustomFieldValue(19808, 'Vergangene Preise', 0);
--
--   -- In SELECT statement
--   SELECT
--     a.cArtikelnummer,
--     a.fVKNetto,
--     Robotico.fnGetArticleCustomFieldValue(a.kArtikel, 'Vergangene Preise', 0) AS Historie
--   FROM dbo.tArtikel a
--   WHERE a.kArtikel IN (19807, 19808);
--
--   -- In WHERE clause
--   SELECT * FROM dbo.tArtikel a
--   WHERE Robotico.fnGetArticleCustomFieldValue(a.kArtikel, 'Vergangene Preise', 0) IS NOT NULL;
-- ============================================================================

CREATE OR ALTER FUNCTION Robotico.fnGetArticleCustomFieldValue
(
    @kArtikel INT,
    @fieldName NVARCHAR(255),
    @kSprache INT = 0  -- Default: German
)
RETURNS NVARCHAR(MAX)
AS
BEGIN
    DECLARE @value NVARCHAR(MAX);

    -- Query custom field value with 4-table JOIN
    SELECT @value = aas.cWertVarchar
    FROM dbo.tArtikelAttribut aa
    INNER JOIN dbo.tAttribut attr
        ON aa.kAttribut = attr.kAttribut
    INNER JOIN dbo.tArtikelAttributSprache aas
        ON aa.kArtikelAttribut = aas.kArtikelAttribut
    INNER JOIN dbo.tAttributSprache attrs
        ON attr.kAttribut = attrs.kAttribut
    WHERE aa.kArtikel = @kArtikel
      AND attrs.cName = @fieldName
      AND aa.kShop = 0                    -- Global (not shop-specific)
      AND aas.kSprache = @kSprache        -- Language match
      AND attrs.kSprache = @kSprache      -- Language match
      AND attr.nIstFreifeld = 1;          -- Only custom fields

    RETURN @value;  -- Returns NULL if not found
END
GO

PRINT '+ Function Robotico.fnGetArticleCustomFieldValue created';
GO

-- ============================================================================
-- 2. INTERNAL HELPER: spEnsureArticleCustomField
-- ============================================================================
-- Description:
--   Internal helper SP that ensures an article-attribute binding exists.
--   Automatically creates:
--   - tArtikelAttribut entry (article-attribute link)
--   - tArtikelAttributSprache entry (language-specific value, initially NULL)
--
--   Includes race-condition handling: If another process creates the binding
--   concurrently, the UNIQUE constraint violation is caught and the newly
--   created binding is re-queried.
--
--   NOTE: This is an internal helper. Public API should use spSetArticleCustomFieldValue.
--
-- Parameters:
--   @kArtikel           - Article ID
--   @fieldName          - Custom field name (e.g., 'Vergangene Preise')
--   @kSprache           - Language ID (0 = German, default)
--   @kArtikelAttribut   - OUTPUT: Article-attribute binding ID
--   @currentValue       - OUTPUT: Current field value (or NULL if empty)
--
-- Returns:
--   0  - Success
--   -1 - Error (custom field definition not found)
-- ============================================================================

CREATE OR ALTER PROCEDURE Robotico.spEnsureArticleCustomField
    @kArtikel INT,
    @fieldName NVARCHAR(255),
    @kSprache INT = 0,  -- Default: German
    -- Output parameters
    @kArtikelAttribut INT OUTPUT,
    @currentValue NVARCHAR(MAX) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @kAttribut INT;

    BEGIN TRY
        -- ====================================================================
        -- Step 1: Lookup kAttribut for the custom field definition
        -- ====================================================================
        SELECT @kAttribut = attr.kAttribut
        FROM dbo.tAttribut attr
        INNER JOIN dbo.tAttributSprache attrs
            ON attr.kAttribut = attrs.kAttribut
        WHERE attrs.cName = @fieldName
          AND attrs.kSprache = @kSprache
          AND attr.nIstFreifeld = 1;  -- Only custom fields

        IF @kAttribut IS NULL
        BEGIN
            RAISERROR('Custom field definition not found in JTL: %s', 16, 1, @fieldName);
            RETURN -1;
        END

        -- ====================================================================
        -- Step 2: Lookup existing article-attribute binding
        -- ====================================================================
        SELECT @kArtikelAttribut = aa.kArtikelAttribut,
               @currentValue = aas.cWertVarchar
        FROM dbo.tArtikelAttribut aa
        INNER JOIN dbo.tArtikelAttributSprache aas
            ON aa.kArtikelAttribut = aas.kArtikelAttribut
        WHERE aa.kArtikel = @kArtikel
          AND aa.kAttribut = @kAttribut
          AND aa.kShop = 0
          AND aas.kSprache = @kSprache;

        -- ====================================================================
        -- Step 3: Auto-create binding if missing
        -- ====================================================================
        IF @kArtikelAttribut IS NULL
        BEGIN
            BEGIN TRY
                -- Create article-attribute binding
                INSERT INTO dbo.tArtikelAttribut (kArtikel, kAttribut, kShop)
                VALUES (@kArtikel, @kAttribut, 0);  -- kShop = 0 (Global)

                -- Get the newly created ID
                SET @kArtikelAttribut = SCOPE_IDENTITY();

                -- Create language-specific entry (value initially NULL)
                INSERT INTO dbo.tArtikelAttributSprache (
                    kArtikelAttribut,
                    kSprache,
                    cWertVarchar
                )
                VALUES (
                    @kArtikelAttribut,
                    @kSprache,
                    NULL  -- Empty initially, will be populated by caller
                );

                SET @currentValue = NULL;
            END TRY
            BEGIN CATCH
                -- ============================================================
                -- Race Condition Handling:
                -- Another workflow may have created the binding concurrently.
                -- The UNIQUE constraint on (kArtikel, kAttribut, kShop)
                -- will cause error 2627. Re-query the newly created binding.
                -- ============================================================
                IF ERROR_NUMBER() = 2627  -- UNIQUE constraint violation
                BEGIN
                    -- Re-query the binding created by the other process
                    SELECT @kArtikelAttribut = aa.kArtikelAttribut,
                           @currentValue = aas.cWertVarchar
                    FROM dbo.tArtikelAttribut aa
                    INNER JOIN dbo.tArtikelAttributSprache aas
                        ON aa.kArtikelAttribut = aas.kArtikelAttribut
                    WHERE aa.kArtikel = @kArtikel
                      AND aa.kAttribut = @kAttribut
                      AND aa.kShop = 0
                      AND aas.kSprache = @kSprache;

                    IF @kArtikelAttribut IS NULL
                        THROW;  -- Still NULL = different error occurred
                END
                ELSE
                    THROW;  -- Not a constraint violation, re-throw
            END CATCH
        END

        RETURN 0;  -- Success

    END TRY
    BEGIN CATCH
        THROW;  -- Propagate error to caller
    END CATCH
END
GO

PRINT '+ Stored Procedure Robotico.spEnsureArticleCustomField created';
GO

-- ============================================================================
-- 3. WRITE SP: spSetArticleCustomFieldValue (PUBLIC API)
-- ============================================================================
-- Description:
--   Writes a value to a custom field for the specified article.
--   Automatically creates the article-attribute binding if it doesn't exist
--   by calling spEnsureArticleCustomField internally.
--
--   This is the recommended way to write custom field values. It handles
--   all complexity internally (binding creation, race conditions, etc.).
--
-- Parameters:
--   @kArtikel    - Article ID
--   @fieldName   - Custom field name (e.g., 'Vergangene Preise')
--   @newValue    - New value to write (NVARCHAR(MAX))
--   @kSprache    - Language ID (0 = German, default)
--
-- Returns:
--   0  - Success
--   -1 - Error (binding could not be ensured)
--
-- Usage:
--   -- Simple write operation
--   EXEC Robotico.spSetArticleCustomFieldValue
--       @kArtikel = 19808,
--       @fieldName = 'Vergangene Preise',
--       @newValue = '24.02.2026 10:45:00; 99,99; 119,99; Puffer 3; John Doe';
--
--   -- Auto-creates binding if article doesn't have the field yet
--   EXEC Robotico.spSetArticleCustomFieldValue
--       @kArtikel = 99999,
--       @fieldName = 'Vergangene Preise',
--       @newValue = 'First entry';
--
--   -- Check return code
--   DECLARE @returnCode INT;
--   EXEC @returnCode = Robotico.spSetArticleCustomFieldValue
--       @kArtikel = 19808,
--       @fieldName = 'Vergangene Preise',
--       @newValue = 'New value';
--
--   IF @returnCode = 0
--       PRINT 'Value written successfully';
--   ELSE
--       PRINT 'Error writing value';
-- ============================================================================

CREATE OR ALTER PROCEDURE Robotico.spSetArticleCustomFieldValue
    @kArtikel INT,
    @fieldName NVARCHAR(255),
    @newValue NVARCHAR(MAX),
    @kSprache INT = 0  -- Default: German
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @kArtikelAttribut INT;
    DECLARE @currentValue NVARCHAR(MAX);
    DECLARE @returnCode INT;

    BEGIN TRY
        -- ====================================================================
        -- Step 1: Ensure binding exists (creates if missing)
        -- ====================================================================
        EXEC @returnCode = Robotico.spEnsureArticleCustomField
            @kArtikel = @kArtikel,
            @fieldName = @fieldName,
            @kSprache = @kSprache,
            @kArtikelAttribut = @kArtikelAttribut OUTPUT,
            @currentValue = @currentValue OUTPUT;

        IF @returnCode <> 0
            RETURN -1;  -- Binding could not be ensured

        -- ====================================================================
        -- Step 2: Update the value
        -- ====================================================================
        UPDATE dbo.tArtikelAttributSprache
        SET cWertVarchar = @newValue
        WHERE kArtikelAttribut = @kArtikelAttribut
          AND kSprache = @kSprache;

        RETURN 0;  -- Success

    END TRY
    BEGIN CATCH
        THROW;  -- Propagate error to caller
    END CATCH
END
GO

PRINT '+ Stored Procedure Robotico.spSetArticleCustomFieldValue created';
GO

-- ============================================================================
-- Transaction Commit / Rollback
-- ============================================================================
IF XACT_STATE() = 1
BEGIN
    COMMIT TRANSACTION;
    PRINT '';
    PRINT '============================================================================';
    PRINT 'Generic Article Custom Field API deployed successfully!';
    PRINT '============================================================================';
    PRINT '';
    PRINT 'Public API (use these in your workflows):';
    PRINT '  - Robotico.fnGetArticleCustomFieldValue      (Function for SELECT statements)';
    PRINT '  - Robotico.spSetArticleCustomFieldValue      (SP for writing values)';
    PRINT '';
    PRINT 'Internal Helper (used by spSetArticleCustomFieldValue):';
    PRINT '  - Robotico.spEnsureArticleCustomField        (Auto-creates bindings)';
    PRINT '';
    PRINT '============================================================================';
    PRINT '';
END
ELSE
BEGIN
    IF XACT_STATE() = -1
        ROLLBACK TRANSACTION;
    PRINT '';
    PRINT '!!! DEPLOYMENT FAILED - Alle Aenderungen wurden zurueckgerollt !!!';
    PRINT '';
END
GO
