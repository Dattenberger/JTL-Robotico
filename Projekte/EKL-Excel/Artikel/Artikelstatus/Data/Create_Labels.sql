-- ============================================================================
-- Artikelstatus Labels Creation Script
-- Schema: dbo (JTL Standard-Schema für Labels)
-- ============================================================================
-- Creates or updates the 9 Artikelstatus labels (7 phases + 2 overrides)
-- Uses MERGE pattern for idempotent execution
-- ============================================================================
-- Label Types in JTL:
--   nTyp = 1: Kunden-Labels
--   nTyp = 2: Auftrags-Labels
--   nTyp = 3: Artikel-Labels (used here)
--   nTyp = 4: Hersteller-Labels
-- ============================================================================

-- Temporary table for label definitions
DECLARE @Labels TABLE (
    cName NVARCHAR(255),
    cColor NVARCHAR(7),
    nSort INT
);

-- Insert label definitions
-- AS: Phases (7 labels) - sorted by lifecycle progression
INSERT INTO @Labels (cName, cColor, nSort) VALUES
    ('AS: Artikel Neu',           '#808080', 10),  -- Gray - not active yet
    ('AS: Orderartikel',          '#28A745', 20),  -- Green - fully active
    ('AS: Aktionsartikel',        '#17A2B8', 30),  -- Blue - active but limited
    ('AS: Abverkauf',             '#FFC107', 40),  -- Yellow - selling off
    ('AS: BW Nachteilig',         '#FD7E14', 45),  -- Orange - disadvantageous
    ('AS: Nicht Nachbestellbar',  '#DC3545', 50),  -- Red - not reorderable
    ('AS: Deaktiviert',           '#6C757D', 60);  -- Dark gray - inactive

-- ASO: Override labels (2 labels) - sorted after phases
INSERT INTO @Labels (cName, cColor, nSort) VALUES
    ('ASO: Überverkäufe deaktivieren', '#E83E8C', 100), -- Pink - oversell override
    ('ASO: Offline',                   '#343A40', 110); -- Black - offline override

-- ============================================================================
-- MERGE Pattern: Insert new labels, update existing ones
-- ============================================================================
MERGE INTO dbo.tLabel AS target
USING @Labels AS source
ON target.cName = source.cName AND target.nTyp = 3
WHEN MATCHED THEN
    UPDATE SET
        cColor = source.cColor,
        nSort = source.nSort
WHEN NOT MATCHED BY TARGET THEN
    INSERT (cName, cColor, nTyp, nSort)
    VALUES (source.cName, source.cColor, 3, source.nSort);

-- ============================================================================
-- Report created/updated labels
-- ============================================================================
PRINT '============================================================================';
PRINT 'Artikelstatus Labels created/updated successfully.';
PRINT '============================================================================';

SELECT
    l.kLabel,
    l.cName,
    l.cColor,
    l.nSort,
    CASE
        WHEN l.cName LIKE 'AS:%' THEN 'Phase'
        WHEN l.cName LIKE 'ASO:%' THEN 'Override'
        ELSE 'Unknown'
    END AS cType
FROM dbo.tLabel l
WHERE l.nTyp = 3
  AND (l.cName LIKE 'AS:%' OR l.cName LIKE 'ASO:%')
ORDER BY l.nSort;

PRINT '============================================================================';
GO
