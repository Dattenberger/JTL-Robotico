-- ============================================================================
-- Robotico.fnEscapedCSVParseLine — READ side of the EscapedCSV API (iTVF)
-- ============================================================================
-- Parses one EscapedCSV line into (ordinal, value) rows. Inline TVF: inlined by
-- the optimizer (no call overhead). Precondition: values were written via
-- fnEscapedCSVSanitize.
--
-- NOTE: signature is a backward-compatibility contract — excel_ekl consumes
-- Robotico.fnEscapedCSVParseLine (D10). Do not change the parameter list.
--
-- Ported from WorkflowProcedures/api/StringAndCSVUtilities.sql (2026-07-10).
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§1, D10 — signature is a
--      stable API contract with excel_ekl; do not change the parameter list)
-- ============================================================================

CREATE OR ALTER FUNCTION Robotico.fnEscapedCSVParseLine(
    @line NVARCHAR(MAX),
    @separator NCHAR(1) = ';'
)
RETURNS TABLE
AS
RETURN (
    SELECT ordinal, LTRIM(RTRIM(value)) AS value
    FROM STRING_SPLIT(@line, @separator, 1)
);
GO
