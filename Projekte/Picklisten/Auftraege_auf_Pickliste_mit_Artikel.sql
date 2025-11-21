DECLARE @kPickliste INT = 102937; -- Hier die Picklisten-ID eintragen
DECLARE @cArtNr VARCHAR(255) = '9000520'; -- Hier die gesuchte Artikelnummer eintragen

-- 1. Finde alle Aufträge auf der Pickliste, die den gesuchten Artikel enthalten
WITH RelevanteAuftraege AS (
    SELECT DISTINCT tPP.kBestellung
    FROM dbo.tPicklistePos tPP
    INNER JOIN dbo.tBestellpos tBP_Filter ON tPP.kBestellPos = tBP_Filter.kBestellPos
    WHERE tPP.kPickliste = @kPickliste
      AND tBP_Filter.cArtNr = @cArtNr
),
-- 2. Erstelle alle Zeilen mit Positionen und Leerzeilen
AlleZeilen AS (
    SELECT 
        tB.cBestellNr + ': ' + tBP.cArtNr + ' ' + tBP.cString + ' ' + CAST(CAST(tBP.nAnzahl AS DECIMAL(10,2)) AS VARCHAR(20)) AS Ausgabe,
        tB.cBestellNr AS SortierBestellNr,
        tBP.nSort,
        tBP.cArtNr AS SortierArtNr,
        0 AS IstLeerzeile
    FROM dbo.tBestellpos tBP
    INNER JOIN dbo.tBestellung tB ON tBP.tBestellung_kBestellung = tB.kBestellung
    INNER JOIN RelevanteAuftraege RA ON tB.kBestellung = RA.kBestellung
    WHERE tBP.cArtNr IS NOT NULL 
      AND tBP.cString IS NOT NULL 
      AND tBP.nAnzahl IS NOT NULL

    UNION ALL

    -- Leerzeilen zwischen Aufträgen einfügen
    SELECT 
        '' AS Ausgabe,
        tB.cBestellNr AS SortierBestellNr,
        999999 AS nSort,
        'ZZZZZ' AS SortierArtNr,
        1 AS IstLeerzeile
    FROM dbo.tBestellung tB
    INNER JOIN RelevanteAuftraege RA ON tB.kBestellung = RA.kBestellung
)
-- 3. Konkateniere alle Zeilen zu einem String mit Zeilenumbrüchen
SELECT STRING_AGG(Ausgabe, CHAR(13) + CHAR(10)) WITHIN GROUP (ORDER BY SortierBestellNr, IstLeerzeile, nSort, SortierArtNr) AS Ergebnis
FROM AlleZeilen;