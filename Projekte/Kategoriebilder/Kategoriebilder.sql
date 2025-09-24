-- ============================================================================
-- Skript: Kategoriebilder automatisch setzen (ULTRA-OPTIMIERT MIT UNTERKATEGORIEN)
-- Beschreibung: Setzt Kategoriebilder aus eigenen Artikeln ODER Unterkategorien
--               mit maximaler Performance durch einmalige Hierarchie-Berechnung
-- Datum: 2025-09-24
-- ============================================================================

USE eazybusiness;
GO

SET NOCOUNT ON;
BEGIN TRANSACTION

PRINT 'Start: ' + CONVERT(VARCHAR(30), GETDATE(), 121);

-- Temporäre Tabelle für Plattform/Shop-Kombinationen
IF OBJECT_ID('tempdb..#PlattformShopKombinationen') IS NOT NULL
    DROP TABLE #PlattformShopKombinationen;

CREATE TABLE #PlattformShopKombinationen (
    kPlattform INT,
    kShop INT,
    nInet INT
);

INSERT INTO #PlattformShopKombinationen (kPlattform, kShop, nInet) VALUES
    (1, 0, 0),      -- JTL-WaWi
    (10001, 0, 0),  -- Weitere Plattform
    (2, 1, 1),      -- Shop 1 (aktiv im Internet)
    (2, 3, 0);      -- Shop 3 (inaktiv)

-- SCHRITT 1: Kategorie-Hierarchie EINMAL vorberechnen für ALLE Kategorien
IF OBJECT_ID('tempdb..#KategorieHierarchie') IS NOT NULL
    DROP TABLE #KategorieHierarchie;

PRINT 'Berechne Kategorie-Hierarchie...';

-- Rekursive CTE nur EINMAL für alle Kategorien ausführen
;WITH KategorieHierarchie AS (
    -- Alle Kategorien als Startkategorien (Ebene 0)
    SELECT
        kKategorie AS HauptKategorie,
        kKategorie AS UnterKategorie,
        0 AS Ebene
    FROM dbo.tKategorie
    WHERE cAktiv = 'Y'

    UNION ALL

    -- Rekursiv alle Unterkategorien finden
    SELECT
        kh.HauptKategorie,
        k.kKategorie AS UnterKategorie,
        kh.Ebene + 1 AS Ebene
    FROM dbo.tKategorie k
    INNER JOIN KategorieHierarchie kh ON k.kOberKategorie = kh.UnterKategorie
    WHERE k.cAktiv = 'Y'
      AND kh.Ebene < 5 -- Maximal 6 Ebenen tief (0, 1, 2, 3, 4, 5)
)
SELECT
    HauptKategorie,
    UnterKategorie,
    Ebene
INTO #KategorieHierarchie
FROM KategorieHierarchie
OPTION (MAXRECURSION 20); -- Sicherheit gegen Endlosschleifen (erhöht für 5 Ebenen)

CREATE CLUSTERED INDEX IX_KatHier_Haupt ON #KategorieHierarchie(HauptKategorie, Ebene);
CREATE INDEX IX_KatHier_Unter ON #KategorieHierarchie(UnterKategorie);

PRINT 'Hierarchie berechnet: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Beziehungen';

-- SCHRITT 2: Artikel-Bild-Zuordnungen für alle relevanten Kategorien
IF OBJECT_ID('tempdb..#ArtikelBilder') IS NOT NULL
    DROP TABLE #ArtikelBilder;

PRINT 'Lade Artikel-Bild-Zuordnungen...';
SELECT
    ka.kKategorie,
    ka.kArtikel,
    MIN(abp.kBild) AS kBild -- Deterministisch: kleinstes Bild-ID
INTO #ArtikelBilder
FROM dbo.tKategorieArtikel ka WITH (NOLOCK)
INNER JOIN dbo.tArtikelbildPlattform abp WITH (NOLOCK) ON ka.kArtikel = abp.kArtikel
WHERE abp.nNr = 1 -- Nur erste Bilder
GROUP BY ka.kKategorie, ka.kArtikel;

CREATE CLUSTERED INDEX IX_ArtikelBilder ON #ArtikelBilder(kKategorie);
PRINT 'Artikel-Bilder geladen: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Zuordnungen';

-- SCHRITT 3: Beste Bilder pro Hauptkategorie finden (mit Priorität nach Ebene)
IF OBJECT_ID('tempdb..#BesteBilder') IS NOT NULL
    DROP TABLE #BesteBilder;

PRINT 'Ermittle beste Bilder pro Kategorie...';

;WITH BilderMitPriorität AS (
    SELECT
        kh.HauptKategorie,
        ab.kBild,
        kh.Ebene,
        -- Priorität: Ebene 0 (direkt) > Ebene 1 > Ebene 2
        ROW_NUMBER() OVER (
            PARTITION BY kh.HauptKategorie
            ORDER BY kh.Ebene, ab.kBild -- Ebene zuerst, dann kleinste Bild-ID
        ) AS rn
    FROM #KategorieHierarchie kh
    INNER JOIN #ArtikelBilder ab ON ab.kKategorie = kh.UnterKategorie
)
SELECT
    HauptKategorie AS kKategorie,
    kBild,
    Ebene
INTO #BesteBilder
FROM BilderMitPriorität
WHERE rn = 1;

CREATE CLUSTERED INDEX IX_BesteBilder ON #BesteBilder(kKategorie);
PRINT 'Beste Bilder ermittelt: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Kategorien';

-- Statistik nach Ebene
SELECT
    CASE Ebene
        WHEN 0 THEN 'Direkt aus Kategorie'
        ELSE 'Aus Unterkategorie (' + CAST(Ebene AS VARCHAR) + '. Ebene)'
    END AS Herkunft,
    COUNT(*) AS Anzahl
FROM #BesteBilder
GROUP BY Ebene
ORDER BY Ebene;

-- SCHRITT 4: Kategorien ohne Bild identifizieren
IF OBJECT_ID('tempdb..#KategorienOhneBild') IS NOT NULL
    DROP TABLE #KategorienOhneBild;

PRINT 'Identifiziere Kategorien ohne Bild...';
SELECT k.kKategorie
INTO #KategorienOhneBild
FROM dbo.tKategorie k WITH (NOLOCK)
WHERE cAktiv = 'Y'
  AND NOT EXISTS (
      SELECT 1
      FROM dbo.tKategoriebildPlattform kbp WITH (NOLOCK)
      WHERE kbp.kKategorie = k.kKategorie
  );

PRINT 'Kategorien ohne Bild: ' + CAST(@@ROWCOUNT AS VARCHAR(10));

-- SCHRITT 5: Matching - welche Kategorien können Bilder bekommen?
IF OBJECT_ID('tempdb..#NeueKategorieBilder') IS NOT NULL
    DROP TABLE #NeueKategorieBilder;

SELECT
    kob.kKategorie,
    bb.kBild,
    bb.Ebene
INTO #NeueKategorieBilder
FROM #KategorienOhneBild kob
INNER JOIN #BesteBilder bb ON kob.kKategorie = bb.kKategorie;

PRINT 'Kategorien mit neuen Bildern: ' + CAST(@@ROWCOUNT AS VARCHAR(10));

-- SCHRITT 6: Bulk-Insert aller Kombinationen
PRINT 'Füge Kategoriebilder ein...';
INSERT INTO dbo.tKategoriebildPlattform (
    kBild,
    kKategorie,
    kPlattform,
    kShop,
    nNr,
    nInet
)
SELECT
    nkb.kBild,
    nkb.kKategorie,
    ps.kPlattform,
    ps.kShop,
    1 as nNr,
    ps.nInet
FROM #NeueKategorieBilder nkb
CROSS JOIN #PlattformShopKombinationen ps;

DECLARE @Inserted INT = @@ROWCOUNT;
PRINT 'Eingefügte Einträge: ' + CAST(@Inserted AS VARCHAR(10));

-- Aufräumen
DROP TABLE #KategorieHierarchie;
DROP TABLE #ArtikelBilder;
DROP TABLE #BesteBilder;
DROP TABLE #KategorienOhneBild;
DROP TABLE #NeueKategorieBilder;
DROP TABLE #PlattformShopKombinationen;

-- Zusammenfassung
PRINT '';
PRINT 'ZUSAMMENFASSUNG:';
PRINT '================';
PRINT 'Neue Einträge: ' + CAST(@Inserted AS VARCHAR(10));
PRINT 'Ende: ' + CONVERT(VARCHAR(30), GETDATE(), 121);

-- Finale Statistik
SELECT
    'Kategorien mit Bild' AS Status,
    COUNT(DISTINCT kKategorie) AS Anzahl
FROM dbo.tKategoriebildPlattform kbp
WHERE EXISTS (SELECT 1 FROM dbo.tKategorie k WHERE k.kKategorie = kbp.kKategorie AND k.cAktiv = 'Y')
UNION ALL
SELECT
    'Kategorien ohne Bild' AS Status,
    COUNT(*) AS Anzahl
FROM dbo.tKategorie k
WHERE k.cAktiv = 'Y'
  AND NOT EXISTS (
      SELECT 1 FROM dbo.tKategoriebildPlattform kbp
      WHERE kbp.kKategorie = k.kKategorie
  );

-- Detail: Welche Kategorien haben immer noch kein Bild?
IF EXISTS (
    SELECT 1 FROM dbo.tKategorie k
    WHERE k.cAktiv = 'Y'
      AND NOT EXISTS (
          SELECT 1 FROM dbo.tKategoriebildPlattform kbp
          WHERE kbp.kKategorie = k.kKategorie
      )
)
BEGIN
    PRINT '';
    PRINT 'Kategorien ohne verfügbare Bilder (auch nicht in Unterkategorien):';
    -- Liste der Kategorien ohne Bild
    SELECT
        k.kKategorie,
        ks.cName
    FROM dbo.tKategorie k
    LEFT JOIN dbo.tKategorieSprache ks ON k.kKategorie = ks.kKategorie
    WHERE k.cAktiv = 'Y'
      AND NOT EXISTS (
          SELECT 1 FROM dbo.tKategoriebildPlattform kbp
          WHERE kbp.kKategorie = k.kKategorie
      )
    ORDER BY ks.cName;
END

COMMIT TRANSACTION
PRINT 'Transaktion erfolgreich abgeschlossen.';
GO