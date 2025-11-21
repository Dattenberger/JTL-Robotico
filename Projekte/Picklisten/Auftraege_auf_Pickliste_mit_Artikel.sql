DECLARE @kPickliste INT = 102937; -- Hier die Picklisten-ID eintragen
DECLARE @cArtNr VARCHAR(255) = '9000520'; -- Hier die gesuchte Artikelnummer eintragen

-- OPTIMIERT: Direkter Zugriff auf Basistabellen statt Views
-- 1. Finde alle Aufträge auf der Pickliste, die den gesuchten Artikel enthalten
WITH RelevanteAuftraege AS (
    -- Optimierung: kBestellung direkt aus tPicklistePos + direkter Join zu Verkauf.tAuftragPosition
    SELECT DISTINCT tPP.kBestellung
    FROM dbo.tPicklistePos tPP
    INNER JOIN Verkauf.tAuftragPosition tAP ON tPP.kBestellPos = tAP.kAuftragPosition
    WHERE tPP.kPickliste = @kPickliste
      AND tAP.cArtNr = @cArtNr
),
-- 2. Erstelle alle Zeilen mit Positionen und Leerzeilen
AlleZeilen AS (
    SELECT
        tA.cAuftragsNr + ': ' + tAP.cArtNr + ' ' + tAP.cName + ' ' + CAST(CAST(tAP.fAnzahl AS DECIMAL(10,2)) AS VARCHAR(20)) AS Ausgabe,
        tA.cAuftragsNr AS SortierBestellNr,
        tAP.nSort,
        tAP.cArtNr AS SortierArtNr,
        0 AS IstLeerzeile
    FROM Verkauf.tAuftragPosition tAP
    INNER JOIN Verkauf.tAuftrag tA ON tAP.kAuftrag = tA.kAuftrag
    INNER JOIN RelevanteAuftraege RA ON tA.kAuftrag = RA.kBestellung
    WHERE tAP.cArtNr IS NOT NULL
      AND tAP.cName IS NOT NULL
      AND tAP.fAnzahl IS NOT NULL

    UNION ALL

    -- Leerzeilen zwischen Aufträgen einfügen
    SELECT
        '' AS Ausgabe,
        tA.cAuftragsNr AS SortierBestellNr,
        999999 AS nSort,
        'ZZZZZ' AS SortierArtNr,
        1 AS IstLeerzeile
    FROM Verkauf.tAuftrag tA
    INNER JOIN RelevanteAuftraege RA ON tA.kAuftrag = RA.kBestellung
)
-- 3. Konkateniere alle Zeilen zu einem String mit Zeilenumbrüchen
SELECT STRING_AGG(Ausgabe, CHAR(13) + CHAR(10)) WITHIN GROUP (ORDER BY SortierBestellNr, IstLeerzeile, nSort, SortierArtNr) AS Ergebnis
FROM AlleZeilen;