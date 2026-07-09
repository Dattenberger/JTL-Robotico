-- ============================================================================
-- Robotico.spSetArticleCustomFieldValue — public API: write a custom field value
-- ============================================================================
-- Writes a value to an article custom field, auto-creating the binding via
-- Robotico.spEnsureArticleCustomField if needed. Returns 0 on success, -1 when
-- the binding could not be ensured.
--
-- Ported from WorkflowProcedures/api/CustomFieldAPI.sql (2026-07-10).
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
        -- Step 1: Ensure binding exists (creates if missing)
        EXEC @returnCode = Robotico.spEnsureArticleCustomField
            @kArtikel = @kArtikel,
            @fieldName = @fieldName,
            @kSprache = @kSprache,
            @kArtikelAttribut = @kArtikelAttribut OUTPUT,
            @currentValue = @currentValue OUTPUT;

        IF @returnCode <> 0
            RETURN -1;  -- Binding could not be ensured

        -- Step 2: Update the value
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
