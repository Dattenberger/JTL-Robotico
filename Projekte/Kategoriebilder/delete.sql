-- ============================================================================
-- Skript: Kategoriebilder löschen für Kategorien und Unterkategorien
-- Beschreibung: Löscht alle Einträge aus tKategoriebildPlattform für
--               angegebene Kategorien sowie deren gesamte Unterkategorie-Hierarchie
-- Datum: 2025-10-10
-- ============================================================================

USE eazybusiness;
GO

SET NOCOUNT ON;
BEGIN TRANSACTION;

PRINT 'Start: ' + CONVERT(VARCHAR(30), GETDATE(), 121);
PRINT '';

-- ============================================================================
-- KONFIGURATION: Hier die zu löschenden Kategorien eintragen
-- ============================================================================
DECLARE @KategorienZumLoeschen TABLE (
    kKategorie INT
);

-- Beispiel: Trage hier die kKategorie-Werte ein, für die Bilder gelöscht werden sollen
INSERT INTO @KategorienZumLoeschen (kKategorie) VALUES
    (242), (7876), (87)
   ;

-- ============================================================================
-- SCHRITT 1: Kategorie-Hierarchie rekursiv ermitteln
-- ============================================================================
IF OBJECT_ID('tempdb..#KategorienMitUnterkategorien') IS NOT NULL
    DROP TABLE #KategorienMitUnterkategorien;

PRINT 'Ermittle Kategorie-Hierarchie (inkl. Unterkategorien)...';

-- Rekursive CTE: Findet alle Unterkategorien der angegebenen Kategorien
;WITH KategorieHierarchie AS (
    -- Ankerpunkt: Startkategorien aus der Input-Tabelle
    SELECT
        kKategorie AS HauptKategorie,
        kKategorie AS UnterKategorie,
        0 AS Ebene
    FROM @KategorienZumLoeschen

    UNION ALL

    -- Rekursiver Teil: Findet alle Unterkategorien
    SELECT
        kh.HauptKategorie,
        k.kKategorie AS UnterKategorie,
        kh.Ebene + 1 AS Ebene
    FROM dbo.tKategorie k
    INNER JOIN KategorieHierarchie kh ON k.kOberKategorie = kh.UnterKategorie
    WHERE kh.Ebene < 10 -- Maximale Tiefe: 10 Ebenen
)
SELECT DISTINCT
    HauptKategorie,
    UnterKategorie,
    Ebene
INTO #KategorienMitUnterkategorien
FROM KategorieHierarchie
OPTION (MAXRECURSION 50);

CREATE CLUSTERED INDEX IX_KatMitUnter ON #KategorienMitUnterkategorien(UnterKategorie);

DECLARE @AnzahlKategorien INT = (SELECT COUNT(DISTINCT UnterKategorie) FROM #KategorienMitUnterkategorien);
PRINT 'Gefundene Kategorien (inkl. Unterkategorien): ' + CAST(@AnzahlKategorien AS VARCHAR(10));
PRINT '';

-- Statistik: Zeige Verteilung nach Ebenen
PRINT 'Verteilung nach Ebenen:';
SELECT
    CASE Ebene
        WHEN 0 THEN 'Hauptkategorien (direkt)'
        ELSE 'Ebene ' + CAST(Ebene AS VARCHAR)
    END AS Hierarchieebene,
    COUNT(DISTINCT UnterKategorie) AS AnzahlKategorien
FROM #KategorienMitUnterkategorien
GROUP BY Ebene
ORDER BY Ebene;
PRINT '';

-- Detail: Zeige betroffene Kategorien mit Namen
PRINT 'Betroffene Kategorien:';
SELECT
    kmu.HauptKategorie,
    kmu.UnterKategorie,
    kmu.Ebene,
    ISNULL(ks.cName, '(kein Name)') AS Kategoriename
FROM #KategorienMitUnterkategorien kmu
LEFT JOIN dbo.tKategorieSprache ks ON kmu.UnterKategorie = ks.kKategorie AND ks.kSprache = 1 -- Deutsch (Standard)
ORDER BY kmu.HauptKategorie, kmu.Ebene, kmu.UnterKategorie;
PRINT '';

-- ============================================================================
-- SCHRITT 2: Prüfe, wie viele Bilder betroffen sind
-- ============================================================================
DECLARE @AnzahlBetroffenerBilder INT;

SELECT @AnzahlBetroffenerBilder = COUNT(*)
FROM dbo.tKategoriebildPlattform kbp
WHERE EXISTS (
    SELECT 1
    FROM #KategorienMitUnterkategorien kmu
    WHERE kmu.UnterKategorie = kbp.kKategorie
);

PRINT 'Anzahl zu löschender Kategoriebilder: ' + CAST(@AnzahlBetroffenerBilder AS VARCHAR(10));

-- Detail: Zeige Verteilung nach Plattform/Shop
IF @AnzahlBetroffenerBilder > 0
BEGIN
    PRINT '';
    PRINT 'Verteilung nach Plattform/Shop:';
    SELECT
        kbp.kPlattform,
        kbp.kShop,
        COUNT(*) AS AnzahlBilder
    FROM dbo.tKategoriebildPlattform kbp
    WHERE EXISTS (
        SELECT 1
        FROM #KategorienMitUnterkategorien kmu
        WHERE kmu.UnterKategorie = kbp.kKategorie
    )
    GROUP BY kbp.kPlattform, kbp.kShop
    ORDER BY kbp.kPlattform, kbp.kShop;
END
PRINT '';

-- ============================================================================
-- SCHRITT 3: Löschen der Kategoriebilder
-- ============================================================================
IF @AnzahlBetroffenerBilder > 0
BEGIN
    PRINT 'Lösche Kategoriebilder aus tKategoriebildPlattform...';

    DELETE kbp
    FROM dbo.tKategoriebildPlattform kbp
    WHERE EXISTS (
        SELECT 1
        FROM #KategorienMitUnterkategorien kmu
        WHERE kmu.UnterKategorie = kbp.kKategorie
    );

    DECLARE @GeloeschteZeilen INT = @@ROWCOUNT;
    PRINT 'Gelöschte Einträge: ' + CAST(@GeloeschteZeilen AS VARCHAR(10));
END
ELSE
BEGIN
    PRINT 'Keine Kategoriebilder zum Löschen gefunden.';
END

-- ============================================================================
-- Aufräumen
-- ============================================================================
DROP TABLE #KategorienMitUnterkategorien;

-- ============================================================================
-- ZUSAMMENFASSUNG
-- ============================================================================
PRINT '';
PRINT '================';
PRINT 'ZUSAMMENFASSUNG:';
PRINT '================';
PRINT 'Verarbeitete Kategorien (inkl. Unterkategorien): ' + CAST(@AnzahlKategorien AS VARCHAR(10));
PRINT 'Gelöschte Kategoriebilder: ' + CAST(ISNULL(@GeloeschteZeilen, 0) AS VARCHAR(10));
PRINT 'Ende: ' + CONVERT(VARCHAR(30), GETDATE(), 121);

COMMIT TRANSACTION;
PRINT '';
PRINT 'Transaktion erfolgreich abgeschlossen.';
GO
