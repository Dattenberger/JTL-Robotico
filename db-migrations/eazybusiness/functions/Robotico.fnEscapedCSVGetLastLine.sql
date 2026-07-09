-- ============================================================================
-- Robotico.fnEscapedCSVGetLastLine — READ side of the EscapedCSV API (last line)
-- ============================================================================
-- Extracts the last line from a multiline EscapedCSV string. Trailing CR/LF are
-- stripped before parsing; CR is removed from the result. Single-line input is
-- returned as-is. Returns NULL for NULL/empty input.
--
-- Ported from WorkflowProcedures/api/StringAndCSVUtilities.sql (2026-07-10).
-- ============================================================================

CREATE OR ALTER FUNCTION Robotico.fnEscapedCSVGetLastLine(@multiLineCSV NVARCHAR(MAX))
RETURNS NVARCHAR(MAX)
AS
BEGIN
    IF @multiLineCSV IS NULL OR LEN(@multiLineCSV) = 0
        RETURN NULL;

    -- Strip trailing CR/LF to avoid an empty result for 'Line1\nLine2\n'
    WHILE LEN(@multiLineCSV) > 0 AND UNICODE(RIGHT(@multiLineCSV, 1)) IN (10, 13)
        SET @multiLineCSV = LEFT(@multiLineCSV, LEN(@multiLineCSV + N'x') - 2);

    IF LEN(@multiLineCSV) = 0
        RETURN NULL;

    DECLARE @lastLine NVARCHAR(MAX);

    IF CHARINDEX(CHAR(10), @multiLineCSV) > 0
        SET @lastLine = RIGHT(@multiLineCSV, CHARINDEX(CHAR(10), REVERSE(@multiLineCSV)) - 1);
    ELSE
        SET @lastLine = @multiLineCSV;

    RETURN REPLACE(@lastLine, CHAR(13), '');
END
GO
