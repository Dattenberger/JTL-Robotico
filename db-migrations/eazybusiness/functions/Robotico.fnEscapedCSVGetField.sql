-- ============================================================================
-- Robotico.fnEscapedCSVGetField — READ side of the EscapedCSV API (single field)
-- ============================================================================
-- Convenience wrapper: extracts one 1-based field from an EscapedCSV line.
-- For multi-field reads use fnEscapedCSVParseLine directly (one parse, all fields).
--
-- Dependency: uses Robotico.fnEscapedCSVParseLine (same folder; deployed first
-- alphabetically).
--
-- Ported from WorkflowProcedures/api/StringAndCSVUtilities.sql (2026-07-10).
-- ============================================================================

CREATE OR ALTER FUNCTION Robotico.fnEscapedCSVGetField(
    @csvLine NVARCHAR(MAX),
    @fieldIndex INT,
    @separator NCHAR(1) = ';'
)
RETURNS NVARCHAR(MAX)
AS
BEGIN
    IF @csvLine IS NULL OR @fieldIndex < 1
        RETURN NULL;

    DECLARE @result NVARCHAR(MAX);

    SELECT @result = value
    FROM Robotico.fnEscapedCSVParseLine(@csvLine, @separator)
    WHERE ordinal = @fieldIndex;

    RETURN @result;
END
GO
