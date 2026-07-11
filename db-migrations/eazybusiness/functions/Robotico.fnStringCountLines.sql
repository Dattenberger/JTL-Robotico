-- ============================================================================
-- Robotico.fnStringCountLines — count lines (LF-based) in a multiline string
-- ============================================================================
-- NULL/empty = 0 lines; a single line (no LF) = 1. A trailing LF counts as an
-- additional (empty) line.
--
-- Ported from WorkflowProcedures/api/StringAndCSVUtilities.sql (2026-07-10).
-- ============================================================================

CREATE OR ALTER FUNCTION Robotico.fnStringCountLines(@str NVARCHAR(MAX))
RETURNS INT
WITH SCHEMABINDING   -- pure (no table refs): marks it deterministic + inlineable (Froid)
AS
BEGIN
    IF @str IS NULL OR LEN(@str) = 0
        RETURN 0;

    RETURN LEN(@str) - LEN(REPLACE(@str, CHAR(10), '')) + 1;
END
GO
