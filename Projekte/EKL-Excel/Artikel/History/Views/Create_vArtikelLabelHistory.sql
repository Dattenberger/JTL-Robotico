-- ============================================================================
-- Article Label History View (Custom-Field Parser)
-- Schema: Robotico
-- ============================================================================
-- Parses the Custom-Field "||Vergangene Label||" for label history
-- Used during transition phase before full migration to tArtikelLabelHistory
-- ============================================================================
-- Custom-Field Format:
-- Each line: DD.MM.YYYY HH:MM:SS;Label1,Label2,Label3;Benutzer
-- Lines are separated by newlines
-- ============================================================================

-- Create schema if not exists
IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'Robotico')
    EXEC('CREATE SCHEMA Robotico');
GO

-- Drop view if exists
IF OBJECT_ID('Robotico.vArtikelLabelHistory', 'V') IS NOT NULL
    DROP VIEW Robotico.vArtikelLabelHistory;
GO

CREATE VIEW Robotico.vArtikelLabelHistory AS
WITH CustomFieldData AS (
    -- Get the Custom-Field content
    SELECT
        a.kArtikel,
        aas.cWert AS cHistoryContent
    FROM dbo.tArtikel a
    INNER JOIN dbo.tArtikelAttribut aa ON a.kArtikel = aa.kArtikel
    INNER JOIN dbo.tArtikelAttributSprache aas ON aa.kArtikelAttribut = aas.kArtikelAttribut
    WHERE aa.cName = '||Vergangene Label||'
      AND aas.kSprache = 1  -- German
      AND aas.cWert IS NOT NULL
      AND LEN(aas.cWert) > 0
),
SplitLines AS (
    -- Split by newlines (assuming CR+LF or LF)
    SELECT
        kArtikel,
        LTRIM(RTRIM(value)) AS cLine
    FROM CustomFieldData
    CROSS APPLY STRING_SPLIT(REPLACE(cHistoryContent, CHAR(13), ''), CHAR(10))
    WHERE LEN(LTRIM(RTRIM(value))) > 0
),
ParsedLines AS (
    -- Parse each line into columns
    SELECT
        kArtikel,
        cLine,
        Robotico.fnGetCsvColumn(cLine, ';', 1) AS cDateTimeStr,
        Robotico.fnGetCsvColumn(cLine, ';', 2) AS cLabels,
        Robotico.fnGetCsvColumn(cLine, ';', 3) AS cBenutzerName
    FROM SplitLines
    WHERE cLine IS NOT NULL
      AND LEN(cLine) > 0
)
SELECT
    p.kArtikel,
    -- Parse German datetime format: DD.MM.YYYY HH:MM:SS
    TRY_CONVERT(DATETIME,
        -- Convert to YYYY-MM-DD HH:MM:SS format
        SUBSTRING(p.cDateTimeStr, 7, 4) + '-' +   -- Year
        SUBSTRING(p.cDateTimeStr, 4, 2) + '-' +   -- Month
        SUBSTRING(p.cDateTimeStr, 1, 2) + ' ' +   -- Day
        SUBSTRING(p.cDateTimeStr, 12, 8),         -- Time
        120  -- ODBC format
    ) AS dDatum,
    p.cLabels,
    p.cBenutzerName,
    -- Try to find kBenutzer by login name
    b.kBenutzer
FROM ParsedLines p
LEFT JOIN dbo.tBenutzer b ON b.cLogin = p.cBenutzerName
WHERE p.cDateTimeStr IS NOT NULL;
GO

-- ============================================================================
-- Usage
-- ============================================================================
-- SELECT * FROM Robotico.vArtikelLabelHistory WHERE kArtikel = 12345 ORDER BY dDatum DESC;
-- ============================================================================

PRINT 'View Robotico.vArtikelLabelHistory created successfully.';
GO
