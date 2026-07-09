-- ============================================================================
-- Robotico.fnStringParseGermanDecimal — parse German number format to DECIMAL
-- ============================================================================
-- German format 1.234,56 (dot = thousands, comma = decimal) -> DECIMAL(25,13).
-- Returns NULL for invalid input. Single-RETURN CASE form so the scalar UDF
-- stays inlineable (SQL Server 2019+).
--
-- Ported from WorkflowProcedures/api/StringAndCSVUtilities.sql (2026-07-10).
-- ============================================================================

CREATE OR ALTER FUNCTION Robotico.fnStringParseGermanDecimal(@value NVARCHAR(100))
RETURNS DECIMAL(25,13)
AS
BEGIN
    RETURN
        CASE
            WHEN @value IS NULL OR LEN(LTRIM(RTRIM(@value))) = 0 THEN NULL
            ELSE TRY_CAST(
                REPLACE(REPLACE(@value, '.', ''), ',', '.')
                AS DECIMAL(25,13)
            )
        END;
END
GO
