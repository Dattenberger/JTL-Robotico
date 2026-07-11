-- ============================================================================
-- Robotico.fnEscapedCSVSanitize — WRITE side of the EscapedCSV API
-- ============================================================================
-- Cleans a value for safe writing into the EscapedCSV format: removes semicolons
-- (field separator), single/double quotes, CR and LF. Returns @defaultValue when
-- the result is empty; NULL when empty and no default given.
--
-- EscapedCSV = CSV where every value is sanitised BEFORE writing (forbidden chars
-- removed, not escaped), so reading is a plain split on the separator.
--
-- Ported from WorkflowProcedures/api/StringAndCSVUtilities.sql (2026-07-10).
-- ============================================================================

CREATE OR ALTER FUNCTION Robotico.fnEscapedCSVSanitize(
    @input NVARCHAR(MAX),
    @defaultValue NVARCHAR(100) = NULL
)
RETURNS NVARCHAR(MAX)
WITH SCHEMABINDING   -- pure (no table refs): marks it deterministic + inlineable (Froid)
AS
BEGIN
    DECLARE @cleaned NVARCHAR(MAX);

    SET @cleaned = LTRIM(RTRIM(
        REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
            ISNULL(@input, ''),
            ';', ''),       -- Semicolon (field separator)
            CHAR(13), ''),  -- Carriage Return
            CHAR(10), ''),  -- Line Feed
            '''', ''),      -- Single quote
            '"', '')        -- Double quote
    ));

    IF LEN(@cleaned) = 0
    BEGIN
        IF @defaultValue IS NOT NULL
            RETURN @defaultValue;
        RETURN NULL;
    END

    RETURN @cleaned;
END
GO
