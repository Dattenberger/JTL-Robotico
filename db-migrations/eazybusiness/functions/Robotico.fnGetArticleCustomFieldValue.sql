-- ============================================================================
-- Robotico.fnGetArticleCustomFieldValue — read a JTL custom field value
-- ============================================================================
-- Read-only function to retrieve a custom field (eigenes Feld) value for an
-- article. Usable directly in SELECT/WHERE.
--
-- Parameters:
--   @kArtikel  - Article ID
--   @fieldName - Custom field name (e.g. 'Vergangene Preise')
--   @kSprache  - Language ID (0 = German, default)
-- Returns: NVARCHAR(MAX) value, or NULL if not found.
--
-- Ported from WorkflowProcedures/api/CustomFieldAPI.sql (2026-07-10).
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
