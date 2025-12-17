-- ============================================================================
-- Article Label Duration View
-- Schema: Robotico
-- ============================================================================
-- Shows how long each label has been set on an article
-- Uses tArtikelLabelHistory table (not Custom-Field parsing)
-- ============================================================================

-- Create schema if not exists
IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'Robotico')
    EXEC('CREATE SCHEMA Robotico');
GO

-- Drop view if exists
IF OBJECT_ID('Robotico.vArtikelLabelDuration', 'V') IS NOT NULL
    DROP VIEW Robotico.vArtikelLabelDuration;
GO

CREATE VIEW Robotico.vArtikelLabelDuration AS
WITH CurrentLabels AS (
    -- Get all currently active labels
    SELECT
        al.kArtikel,
        al.kLabel,
        l.cName AS cLabelName
    FROM dbo.tArtikelLabel al
    INNER JOIN dbo.tLabel l ON al.kLabel = l.kLabel
),
LastSetEvent AS (
    -- Find the most recent SET event for each article-label combination
    SELECT
        kArtikel,
        kLabel,
        dCreated AS dSetDate,
        ROW_NUMBER() OVER (PARTITION BY kArtikel, kLabel ORDER BY dCreated DESC) AS rn
    FROM Robotico.tArtikelLabelHistory
    WHERE cAction = 'SET'
)
SELECT
    cl.kArtikel,
    cl.kLabel,
    cl.cLabelName,
    lse.dSetDate,
    -- Calculate duration in days
    DATEDIFF(DAY, lse.dSetDate, GETDATE()) AS nDurationDays,
    -- Calculate duration as human-readable string
    CASE
        WHEN DATEDIFF(DAY, lse.dSetDate, GETDATE()) = 0 THEN 'Heute'
        WHEN DATEDIFF(DAY, lse.dSetDate, GETDATE()) = 1 THEN 'Gestern'
        WHEN DATEDIFF(DAY, lse.dSetDate, GETDATE()) < 7 THEN CAST(DATEDIFF(DAY, lse.dSetDate, GETDATE()) AS VARCHAR) + ' Tage'
        WHEN DATEDIFF(DAY, lse.dSetDate, GETDATE()) < 30 THEN CAST(DATEDIFF(DAY, lse.dSetDate, GETDATE()) / 7 AS VARCHAR) + ' Woche(n)'
        WHEN DATEDIFF(DAY, lse.dSetDate, GETDATE()) < 365 THEN CAST(DATEDIFF(MONTH, lse.dSetDate, GETDATE()) AS VARCHAR) + ' Monat(e)'
        ELSE CAST(DATEDIFF(YEAR, lse.dSetDate, GETDATE()) AS VARCHAR) + ' Jahr(e)'
    END AS cDurationText
FROM CurrentLabels cl
LEFT JOIN LastSetEvent lse ON cl.kArtikel = lse.kArtikel
                           AND cl.kLabel = lse.kLabel
                           AND lse.rn = 1;
GO

-- ============================================================================
-- Usage
-- ============================================================================
-- Get all label durations for an article:
-- SELECT * FROM Robotico.vArtikelLabelDuration WHERE kArtikel = 12345;
--
-- Find articles with labels set for more than 30 days:
-- SELECT * FROM Robotico.vArtikelLabelDuration WHERE nDurationDays > 30;
--
-- Find articles with specific Artikelstatus label:
-- SELECT * FROM Robotico.vArtikelLabelDuration WHERE cLabelName LIKE 'AS:%';
-- ============================================================================

PRINT 'View Robotico.vArtikelLabelDuration created successfully.';
GO
