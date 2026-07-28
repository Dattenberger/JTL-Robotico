-- ============================================================================
-- Robotico.fnStringParseGermanDecimal — parse German number format to DECIMAL
-- ============================================================================
-- German format 1.234,56 (dot = thousands, comma = decimal) -> DECIMAL(25,13).
-- Returns NULL for invalid input. Single-RETURN CASE form so the scalar UDF
-- stays inlineable (SQL Server 2019+).
--
-- Grammar / edge cases (F4.4):
--   * '1.234,56'  -> 1234.56   (German: dot = thousands, comma = decimal)
--   * '99,99'     -> 99.99
--   * '100'       -> 100       (integer, no separators)
--   * '1,234.56'  -> NULL      (US/Anglo format: a '.' AFTER a ',' is NOT German —
--                               a German thousands-dot always PRECEDES the decimal
--                               comma, so a dot to the right of a comma is rejected
--                               rather than silently mis-parsed to 1.23456).
--   * NULL / '' / 'abc' -> NULL
--   Note: a bare dot with no comma ('1.234') stays German thousands (-> 1234); that
--   ambiguity predates F4.4 and is intentionally left unchanged.
--
-- Ported from WorkflowProcedures/api/StringAndCSVUtilities.sql (2026-07-10).
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (F4.4 — reject US decimal format)
-- ============================================================================

CREATE OR ALTER FUNCTION Robotico.fnStringParseGermanDecimal(@value NVARCHAR(100))
RETURNS DECIMAL(25,13)
WITH SCHEMABINDING   -- pure (no table refs): marks it deterministic + inlineable (Froid)
AS
BEGIN
    RETURN
        CASE
            WHEN @value IS NULL OR LEN(LTRIM(RTRIM(@value))) = 0 THEN NULL
            -- Reject US/Anglo format: a decimal point sitting to the RIGHT of a comma
            -- (e.g. '1,234.56') cannot be German. Without this guard the REPLACE below
            -- strips the '.' and turns it into a silent wrong value (1.23456).
            WHEN CHARINDEX(N',', @value) > 0
                 AND CHARINDEX(N'.', @value, CHARINDEX(N',', @value)) > 0 THEN NULL
            ELSE TRY_CAST(
                REPLACE(REPLACE(@value, '.', ''), ',', '.')
                AS DECIMAL(25,13)
            )
        END;
END
GO
