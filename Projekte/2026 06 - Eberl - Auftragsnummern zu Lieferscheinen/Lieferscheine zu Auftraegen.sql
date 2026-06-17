USE eazybusiness;

/*
    Ziel: Lieferscheine zu Aufträgen zuordnen.

    Für jede angegebene Auftragsnummer wird geprüft, wie viele Lieferscheine
    existieren:
      - genau 1 Lieferschein  -> es wird nur die Lieferscheinnummer ausgegeben
      - mehr als 1 Lieferschein -> es wird ein String je Lieferschein ausgegeben
        im Format "Lieferscheinnummer Mengex Artikelnummer Artikelname, ...",
        die einzelnen Lieferscheine sind mit ";" getrennt, z. B.:
        "D-AU2026273683-001 2x 9018148 Artikelname; D-AU2026273683-002 1x 8847 Name"
        Damit ist die Zuordnung manuell möglich.

    Die zu prüfenden Auftragsnummern stehen unten in der VALUES-Liste (@Auftraege).
*/

-- Eingabe: Liste der Auftragsnummern (cBestellNr / cAuftragsNr)
WITH Auftraege(cBestellNr) AS (
    SELECT cBestellNr
    FROM (VALUES
        ('D-AU2026273458'),
        ('D-AU2026274717'),
        ('D-AU2026276460'),
        ('D-AU2026276494'),
        ('D-AU2026279510'),
        ('D-AU2026280158'),
        ('D-AU2026273683'),
        ('D-AU2026280075'),
        ('D-AU2026279612'),
        ('D-AU2026277272'),
        ('D-AU2026277071'),
        ('D-AU2026280336'),
        ('D-AU2026280687'),
        ('D-AU2026280460'),
        ('D-AU2026280406'),
        ('D-AU2026280996'),
        ('D-AU2026280937'),
        ('D-AU2026280748'),
        ('D-AU2026281442'),
        ('D-AU2026280819'),
        ('D-AU2026277559'),
        ('D-AU2026283885'),
        ('D-AU2026284390'),
        ('D-AU2026285264'),
        ('D-AU2026284445'),
        ('D-AU2026285582'),
        ('D-AU2026286301')
    ) AS v(cBestellNr)
),

-- Je Lieferschein eines Auftrags: Lieferscheinnummer + Artikel inkl. Menge (aus den Lieferscheinpositionen)
LieferscheinMitArtikel AS (
    SELECT
        a.cBestellNr,
        tL.kLieferschein,
        tL.cLieferscheinNr,
        -- Artikel dieses Lieferscheins als "Mengex Artikelnummer Artikelname", mit Komma getrennt.
        -- Position wird angezeigt, sobald Artikelnummer ODER Name vorhanden ist;
        -- die Artikelnummer wird nur eingefügt, wenn sie nicht leer ist.
        STRING_AGG(
            CASE
                WHEN COALESCE(NULLIF(tBP.cArtNr, ''), NULLIF(tBP.cString, '')) IS NOT NULL
                    THEN FORMAT(tLP.fAnzahl, '0.###') + 'x '
                         + ISNULL(NULLIF(tBP.cArtNr, '') + ' ', '')
                         + ISNULL(tBP.cString, '')
            END,
            ', '
        ) WITHIN GROUP (ORDER BY tBP.cArtNr) AS cArtikel
    FROM Auftraege a
        INNER JOIN dbo.tBestellung      tB  ON tB.cBestellNr     = a.cBestellNr
        INNER JOIN dbo.tLieferschein    tL  ON tL.kBestellung    = tB.kBestellung
        LEFT  JOIN dbo.tLieferscheinPos tLP ON tLP.kLieferschein = tL.kLieferschein
        LEFT  JOIN dbo.tBestellpos      tBP ON tBP.kBestellPos   = tLP.kBestellPos
    GROUP BY a.cBestellNr, tL.kLieferschein, tL.cLieferscheinNr
)

SELECT
    a.cBestellNr AS Auftragsnummer,
    COUNT(lma.kLieferschein) AS AnzahlLieferscheine,
    CASE
        -- genau ein Lieferschein -> nur die Lieferscheinnummer
        WHEN COUNT(lma.kLieferschein) = 1
            THEN MAX(lma.cLieferscheinNr)
        -- mehrere Lieferscheine -> "LieferscheinNr Mengex Artikelnummer Artikelname, ..." je Lieferschein, mit ";" getrennt
        ELSE STRING_AGG(
                lma.cLieferscheinNr + ISNULL(' ' + lma.cArtikel, ''),
                '; '
             ) WITHIN GROUP (ORDER BY lma.cLieferscheinNr)
    END AS Lieferschein
FROM Auftraege a
    LEFT JOIN LieferscheinMitArtikel lma ON lma.cBestellNr = a.cBestellNr
GROUP BY a.cBestellNr
ORDER BY a.cBestellNr;
