-- Verkaufte Geräte mit spezifischen Artikelnummern (9000369, 9000773, 9008229)
-- die ab dem 15.08.2025 (einschließlich) versendet wurden
-- mit Auftragsdatum, Rechnungsdatum, Versanddatum, Auftragsnummer, Rechnungsnummer,
-- Artikelnummer, Seriennummern, Kundennummer und Kundenname

SELECT DISTINCT
    tK.cKundenNr AS 'Kundennummer',
    COALESCE(tAdr.cFirma, CONCAT(COALESCE(tAdr.cVorname + ' ', ''), tAdr.cName)) AS 'Kundenname',
    tA.cAuftragsNr AS 'Auftragsnummer',
    tA.dErstellt AS 'Auftragsdatum',
    tR.cRechnungsnr AS 'Rechnungsnummer',
    tR.dErstellt AS 'Rechnungsdatum',
    tV.dVersendet AS 'Versanddatum',
    tArt.cArtNr AS 'Artikelnummer',
    tLA.cSeriennr AS 'Seriennummer',
    tAPos.cName AS 'Positionsname'
FROM [Verkauf].[tAuftragPosition] tAPos
    INNER JOIN [eazybusiness].[Verkauf].[tAuftrag] tA
        ON tAPos.kAuftrag = tA.kAuftrag
    -- Join zu Artikel für Artikelnummer
    INNER JOIN [dbo].[tArtikel] tArt
        ON tAPos.kArtikel = tArt.kArtikel
    -- Join zu LagerArtikel für Seriennummern
    LEFT JOIN [dbo].[tLagerArtikel] tLA
        ON tAPos.kAuftragPosition = tLA.kBestellPos
    -- Join zu Rechnung über Verkauf.tAuftragRechnung
    LEFT JOIN [Rechnung].[tRechnungPosition] tRPos
        ON tAPos.kAuftragPosition = tRPos.kAuftragPosition
    LEFT JOIN [Rechnung].[tRechnung] tR
              ON tRPos.kRechnung = tR.kRechnung
    LEFT JOIN [dbo].[tLieferscheinPos] tLPos
              ON tAPos.kAuftragPosition = tLPos.kBestellPos
    -- Join zu Lieferschein über Lieferscheinpos
    INNER JOIN [dbo].[tLieferschein] tL
               ON tLPos.kLieferschein = tL.kLieferschein
    -- Join zu Versand über Lieferschein
    INNER JOIN [dbo].[tVersand] tV
               ON tL.kLieferschein = tV.kLieferschein
    -- Join zu Kunde für Kundennummer
    LEFT JOIN [dbo].[tkunde] tK
              ON tA.kKunde = tK.kKunde
    -- Join zu Adresse für Kundenname (Standardadresse mit nTyp=1 für Rechnungsadresse)
    LEFT JOIN [dbo].[tAdresse] tAdr
              ON tK.kKunde = tAdr.kKunde
                  AND (tAdr.nStandard = 1 AND tAdr.nTyp = 1)
-- Join zu Auftragspositionen
WHERE
    -- Filter für spezifische Artikelnummern
    tArt.cArtNr IN ('9000369', '9000773', '9000775', '9008039')
    -- Filter für Versanddatum ab einschließlich 15.08.2025
    AND tV.dVersendet >= CONVERT(datetime, '2025-08-15', 120)
    AND tR.nStorno = 0 -- Nur nicht-stornierte Rechnungen
ORDER BY
    tV.dVersendet DESC,
    tA.cAuftragsNr,
    tArt.cArtNr
