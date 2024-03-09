WITH Basis AS (
    SELECT
        tA.kAuftrag,
        tAP.kAuftragPosition,
        tAP.nType,
        tRP.kZustand,
        tAP.fAnzahl AS AuftragMenge,  -- Menge aus der Auftragsposition
        ISNULL(tRP.kRMRetourePos, 0) AS Retourniert, -- 0 bedeutet nicht retourniert
        ISNULL(tRP.fAnzahl, 0) AS RetourMenge,  -- Menge der Retoure, 0 wenn nicht retourniert
        tAP.kAuftragStueckliste,  -- Hinzugefügt für die neue Prüfung
        tRP.nGutschreiben,  -- Prüfung ob gutgeschrieben werden soll
        tSV.kRMStatus,      -- Status der Retoure
        tRP.kRMRetoure,      -- Retoure-ID zur Prüfung auf Eindeutigkeit
        CASE WHEN tAP.kAuftragStueckliste = tAP.kAuftragPosition THEN 1 ELSE 0 END AS IstStueckliste -- Prüfung ob gutgeschrieben werden soll
    FROM Verkauf.tAuftrag tA
             LEFT JOIN Verkauf.tAuftragPosition tAP
                       ON tA.kAuftrag = tAP.kAuftrag
                           AND tAP.nType NOT IN (2, 15) -- Ignorieren von Versandkosten und Kartonagen
             LEFT JOIN dbo.tLieferscheinPos tLP
                       ON tAP.kAuftragPosition = tLP.kBestellPos
             LEFT JOIN dbo.tRMRetourePos tRP
                       ON tLP.kLieferscheinPos = tRP.kLieferscheinPos
             LEFT JOIN dbo.tRMStatusVerlauf tSV
                       ON tRP.kRMStatusVerlauf = tSV.kRMStatusVerlauf
    WHERE tA.kAuftrag = 243846 --217148
),
     RetourenPruefung AS (
         -- Prüfung auf maximal eine eindeutige Retoure
         SELECT COUNT(DISTINCT kRMRetoure) AS AnzahlUnterschiedlicherRetouren
         FROM Basis
         WHERE kRMRetoure IS NOT NULL
           AND IstStueckliste != 1
     ),
     Pruefungen AS (
         SELECT
             COUNT(*) AS AnzahlPositionen,
             SUM(CASE WHEN Retourniert > 0 THEN 1 ELSE 0 END) AS AnzahlRetourniert,
             SUM(CASE WHEN kZustand = 1 THEN 1 ELSE 0 END) AS AnzahlZustand,
             SUM(CASE WHEN nType = 1 THEN 1 ELSE 0 END) AS AnzahlTyp,
             SUM(CASE WHEN AuftragMenge = RetourMenge THEN 1 ELSE 0 END) AS AnzahlVollstaendigRetourniert,
             --SUM(CASE WHEN kAuftragStueckliste IS NULL OR kAuftragStueckliste = 0 THEN 1 ELSE 0 END) AS AnzahlOhneStueckliste,
             SUM(CASE WHEN nGutschreiben = 1 THEN 1 ELSE 0 END) AS AnzahlGutschreiben,
             SUM(CASE WHEN kRMStatus = 6 THEN 1 ELSE 0 END) AS AnzahlErstattungOffen
         FROM Basis
         WHERE IstStueckliste != 1
     )
SELECT
    CASE
        WHEN AnzahlPositionen = 0 THEN 'FALSCH'
        WHEN AnzahlPositionen = AnzahlRetourniert AND  -- Alle Positionen sind retourniert
             AnzahlPositionen = AnzahlZustand AND      -- Alle Retouren haben den Zustand Standard
             AnzahlPositionen = AnzahlTyp AND         -- Alle Artikelpositionen sind Typ 1 (Standard Artikel)
             AnzahlPositionen = AnzahlVollstaendigRetourniert AND -- Alle Retourenpositionen vollständig retourniert
             --AnzahlPositionen = AnzahlOhneStueckliste AND -- Kein Artikel hat einen Wert bei kAuftragStueckliste
             AnzahlPositionen = AnzahlGutschreiben AND -- Alle Positionen haben nGutschreiben = 1
             AnzahlPositionen = AnzahlErstattungOffen AND -- Alle haben Status "Erstattung offen" (6)
             (SELECT AnzahlUnterschiedlicherRetouren FROM RetourenPruefung) <= 1  -- Maximal eine Retoure
            THEN 'TRUE'
        ELSE 'FALSE'
        END AS Ergebnis,
    AnzahlPositionen,
    AnzahlRetourniert,
    AnzahlZustand,
    AnzahlTyp,
    AnzahlVollstaendigRetourniert,
    AnzahlOhneStueckliste,
    AnzahlGutschreiben,
    AnzahlErstattungOffen,
    (SELECT AnzahlUnterschiedlicherRetouren FROM RetourenPruefung) AS AnzahlRetouren
FROM Pruefungen;