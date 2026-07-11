-- ============================================================================
-- Robotico.fnStringStripWhitespace — remove tabs/CR/LF from a string
-- ============================================================================
-- Removes Tab (CHAR(9)), CR (CHAR(13)) and LF (CHAR(10)). Regular spaces inside
-- the content are kept. Returns NULL when the input is NULL.
--
-- Ported from WorkflowProcedures/api/StringAndCSVUtilities.sql (2026-07-10).
-- ============================================================================

CREATE OR ALTER FUNCTION Robotico.fnStringStripWhitespace(@str NVARCHAR(MAX))
RETURNS NVARCHAR(MAX)
WITH SCHEMABINDING   -- pure (no table refs): marks it deterministic + inlineable (Froid)
AS
BEGIN
    IF @str IS NULL
        RETURN NULL;

    RETURN REPLACE(REPLACE(REPLACE(@str,
        CHAR(9), ''),   -- Tab
        CHAR(13), ''),  -- Carriage Return
        CHAR(10), '')   -- Line Feed
END
GO
