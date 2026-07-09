-- ============================================================================
-- Robotico.fnStringIsEffectivelyEmpty — is a string NULL or whitespace-only?
-- ============================================================================
-- Returns BIT 1 when the input is NULL or contains only whitespace (space, tab,
-- CR, LF); 0 when it has content.
--
-- Ported from WorkflowProcedures/api/StringAndCSVUtilities.sql (2026-07-10).
-- ============================================================================

CREATE OR ALTER FUNCTION Robotico.fnStringIsEffectivelyEmpty(@str NVARCHAR(MAX))
RETURNS BIT
AS
BEGIN
    RETURN CASE
        WHEN @str IS NULL THEN 1
        WHEN LEN(
            REPLACE(REPLACE(REPLACE(REPLACE(@str,
                ' ', ''),       -- Space
                CHAR(9), ''),   -- Tab
                CHAR(13), ''),  -- Carriage Return
                CHAR(10), '')   -- Line Feed
        ) = 0 THEN 1
        ELSE 0
    END
END
GO
