-- ============================================================================
-- Robotico.spSetArticleCustomFieldValue — public API: write a custom field value
-- ============================================================================
-- Writes a value to an article custom field, auto-creating the binding via
-- Robotico.spEnsureArticleCustomField if needed. Returns 0 on success. A missing
-- custom-field definition surfaces as a thrown error (propagated from
-- spEnsureArticleCustomField), not as a return code.
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

    BEGIN TRY
        -- Step 1: Ensure binding exists (creates if missing). A missing field
        -- definition throws inside the helper and propagates through this TRY.
        EXEC Robotico.spEnsureArticleCustomField
            @kArtikel = @kArtikel,
            @fieldName = @fieldName,
            @kSprache = @kSprache,
            @kArtikelAttribut = @kArtikelAttribut OUTPUT,
            @currentValue = @currentValue OUTPUT;

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
