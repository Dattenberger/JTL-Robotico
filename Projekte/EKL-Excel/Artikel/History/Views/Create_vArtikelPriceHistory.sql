-- ============================================================================
-- Article Price History View (Custom-Field Parser)
-- Schema: Robotico
-- ============================================================================
-- Parses the Custom-Field "||Vergangene Preise||" for price history
-- Used during transition phase before full migration to tArtikelPriceHistory
-- ============================================================================
-- Custom-Field Format:
-- Each line: DD.MM.YYYY HH:MM:SS;Netto;Brutto;Name;Benutzer
-- Lines are separated by newlines
-- ============================================================================

-- Create schema if not exists
IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'Robotico')
    EXEC('CREATE SCHEMA Robotico');
GO

-- Drop view if exists
IF OBJECT_ID('Robotico.vArtikelPriceHistory', 'V') IS NOT NULL
    DROP VIEW Robotico.vArtikelPriceHistory;
GO

CREATE VIEW Robotico.vArtikelPriceHistory AS
WITH CustomFieldData AS (
    -- Get the Custom-Field content
    SELECT
        a.kArtikel,
        aas.cWert AS cHistoryContent
    FROM dbo.tArtikel a
    INNER JOIN dbo.tArtikelAttribut aa ON a.kArtikel = aa.kArtikel
    INNER JOIN dbo.tArtikelAttributSprache aas ON aa.kArtikelAttribut = aas.kArtikelAttribut
    WHERE aa.cName = '||Vergangene Preise||'
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
        Robotico.fnGetCsvColumn(cLine, ';', 2) AS cNettoStr,
        Robotico.fnGetCsvColumn(cLine, ';', 3) AS cBruttoStr,
        Robotico.fnGetCsvColumn(cLine, ';', 4) AS cName,        -- Article name at time
        Robotico.fnGetCsvColumn(cLine, ';', 5) AS cBenutzerName
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
        SUBSTRING(p.cDateTimeStr, 1, 2) + ' ' +   -- Time
        SUBSTRING(p.cDateTimeStr, 12, 8),
        120  -- ODBC format
    ) AS dDatum,
    -- Parse prices (German format with comma as decimal separator)
    TRY_CONVERT(DECIMAL(10,2), REPLACE(p.cNettoStr, ',', '.')) AS fVKNetto,
    TRY_CONVERT(DECIMAL(10,2), REPLACE(p.cBruttoStr, ',', '.')) AS fVKBrutto,
    p.cName AS cArtikelName,
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
-- SELECT * FROM Robotico.vArtikelPriceHistory WHERE kArtikel = 12345 ORDER BY dDatum DESC;
-- ============================================================================

PRINT 'View Robotico.vArtikelPriceHistory created successfully.';
GO
