-- ============================================================================
-- Robotico.spEnsureArticleCustomField — internal helper (auto-create binding)
-- ============================================================================
-- Ensures an article-attribute binding exists for a custom field, creating the
-- tArtikelAttribut + tArtikelAttributSprache entries if missing. Handles the
-- concurrent-creation race (UNIQUE violation 2627 -> re-query). Internal helper;
-- public writes go through Robotico.spSetArticleCustomFieldValue.
--
-- Returns 0 on success, -1 when the custom field definition is not found.
--
-- Ported from WorkflowProcedures/api/CustomFieldAPI.sql (2026-07-10):
-- removed the per-file XACT_ABORT/BEGIN TRAN scaffolding (grate --transaction).
-- ============================================================================

CREATE OR ALTER PROCEDURE Robotico.spEnsureArticleCustomField
    @kArtikel INT,
    @fieldName NVARCHAR(255),
    @kSprache INT = 0,  -- Default: German
    @kArtikelAttribut INT OUTPUT,
    @currentValue NVARCHAR(MAX) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @kAttribut INT;

    BEGIN TRY
        -- Step 1: Lookup kAttribut for the custom field definition
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

        -- Step 2: Lookup existing article-attribute binding
        SELECT @kArtikelAttribut = aa.kArtikelAttribut,
               @currentValue = aas.cWertVarchar
        FROM dbo.tArtikelAttribut aa
        INNER JOIN dbo.tArtikelAttributSprache aas
            ON aa.kArtikelAttribut = aas.kArtikelAttribut
        WHERE aa.kArtikel = @kArtikel
          AND aa.kAttribut = @kAttribut
          AND aa.kShop = 0
          AND aas.kSprache = @kSprache;

        -- Step 3: Auto-create binding if missing
        IF @kArtikelAttribut IS NULL
        BEGIN
            BEGIN TRY
                INSERT INTO dbo.tArtikelAttribut (kArtikel, kAttribut, kShop)
                VALUES (@kArtikel, @kAttribut, 0);  -- kShop = 0 (Global)

                SET @kArtikelAttribut = SCOPE_IDENTITY();

                INSERT INTO dbo.tArtikelAttributSprache (
                    kArtikelAttribut,
                    kSprache,
                    cWertVarchar
                )
                VALUES (
                    @kArtikelAttribut,
                    @kSprache,
                    NULL  -- Empty initially, populated by caller
                );

                SET @currentValue = NULL;
            END TRY
            BEGIN CATCH
                -- Race: another workflow created the binding concurrently.
                -- UNIQUE constraint on (kArtikel, kAttribut, kShop) -> error 2627.
                IF ERROR_NUMBER() = 2627  -- UNIQUE constraint violation
                BEGIN
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
