-- ============================================================================
-- CSV Column Parser Function for EKL Excel Add-In
-- Schema: Robotico
-- ============================================================================
-- Extracts a specific column from a delimited string
-- Used for parsing Custom-Field history data during migration
-- ============================================================================

-- Create schema if not exists
IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'Robotico')
    EXEC('CREATE SCHEMA Robotico');
GO

-- Drop function if exists (for updates)
IF OBJECT_ID('Robotico.fnGetCsvColumn', 'FN') IS NOT NULL
    DROP FUNCTION Robotico.fnGetCsvColumn;
GO

-- Create function
CREATE FUNCTION Robotico.fnGetCsvColumn
(
    @input NVARCHAR(MAX),       -- The delimited string to parse
    @delimiter NCHAR(1),        -- The delimiter character (e.g., ';')
    @columnIndex INT            -- 1-based column index
)
RETURNS NVARCHAR(MAX)
AS
BEGIN
    DECLARE @result NVARCHAR(MAX) = NULL;
    DECLARE @startPos INT = 1;
    DECLARE @endPos INT;
    DECLARE @currentColumn INT = 1;

    -- Validate input
    IF @input IS NULL OR @columnIndex < 1
        RETURN NULL;

    -- Find the start position of the requested column
    WHILE @currentColumn < @columnIndex AND @startPos <= LEN(@input)
    BEGIN
        SET @endPos = CHARINDEX(@delimiter, @input, @startPos);
        IF @endPos = 0
        BEGIN
            -- No more delimiters found, but we haven't reached target column
            RETURN NULL;
        END
        SET @startPos = @endPos + 1;
        SET @currentColumn = @currentColumn + 1;
    END

    -- Check if we found the column
    IF @currentColumn <> @columnIndex
        RETURN NULL;

    -- Find the end of this column
    SET @endPos = CHARINDEX(@delimiter, @input, @startPos);

    -- If no more delimiters, take rest of string
    IF @endPos = 0
        SET @result = SUBSTRING(@input, @startPos, LEN(@input) - @startPos + 1);
    ELSE
        SET @result = SUBSTRING(@input, @startPos, @endPos - @startPos);

    -- Trim whitespace
    SET @result = LTRIM(RTRIM(@result));

    -- Return NULL for empty strings
    IF @result = ''
        SET @result = NULL;

    RETURN @result;
END
GO

-- ============================================================================
-- Test Examples
-- ============================================================================
-- SELECT Robotico.fnGetCsvColumn('A;B;C', ';', 1)  -- Returns 'A'
-- SELECT Robotico.fnGetCsvColumn('A;B;C', ';', 2)  -- Returns 'B'
-- SELECT Robotico.fnGetCsvColumn('A;B;C', ';', 3)  -- Returns 'C'
-- SELECT Robotico.fnGetCsvColumn('A;B;C', ';', 4)  -- Returns NULL
-- SELECT Robotico.fnGetCsvColumn('16.12.2024 10:30:00;Label1,Label2;Admin', ';', 1)  -- Returns '16.12.2024 10:30:00'
-- SELECT Robotico.fnGetCsvColumn('16.12.2024 10:30:00;Label1,Label2;Admin', ';', 2)  -- Returns 'Label1,Label2'
-- SELECT Robotico.fnGetCsvColumn('16.12.2024 10:30:00;Label1,Label2;Admin', ';', 3)  -- Returns 'Admin'
-- ============================================================================

PRINT 'Function Robotico.fnGetCsvColumn created successfully.';
GO
