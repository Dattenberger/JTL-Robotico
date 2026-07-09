-- ============================================================================
-- Robotico.fnStringTrimToMaxLines — keep only the last @maxLines lines
-- ============================================================================
-- Keeps the last @maxLines lines of a multiline string, filtering empty lines.
-- Result lines are joined with CR+LF. Returns NULL when input is NULL or
-- @maxLines < 1.
--
-- Dependency: uses Robotico.fnStringCountLines (must be deployed first — grate
-- deploys functions/ alphabetically; both live in this folder).
--
-- Ported from WorkflowProcedures/api/StringAndCSVUtilities.sql (2026-07-10).
-- ============================================================================

CREATE OR ALTER FUNCTION Robotico.fnStringTrimToMaxLines(
    @str NVARCHAR(MAX),
    @maxLines INT
)
RETURNS NVARCHAR(MAX)
AS
BEGIN
    IF @str IS NULL OR @maxLines < 1
        RETURN NULL;

    DECLARE @lineCount INT = Robotico.fnStringCountLines(@str);

    -- No trimming needed
    IF @lineCount <= @maxLines
        RETURN @str;

    -- Keep the last @maxLines, filtering empty lines
    DECLARE @result NVARCHAR(MAX);

    SELECT @result = STRING_AGG(
        REPLACE(value, CHAR(13), ''),
        CHAR(13) + CHAR(10)
    ) WITHIN GROUP (ORDER BY ordinal)
    FROM STRING_SPLIT(@str, CHAR(10), 1)
    WHERE ordinal > (@lineCount - @maxLines)
      AND LEN(LTRIM(RTRIM(REPLACE(value, CHAR(13), '')))) > 0;

    RETURN @result;
END
GO
