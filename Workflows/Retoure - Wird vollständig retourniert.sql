
--Retoure
SELECT * FROM tRMRetoure
         JOIN tRMRetourePos ON tRMRetourePos.kRMRetoure = tRMRetoure.kRMRetoure
         WHERE cRetoureNr = 'D-RT202512636';

SELECT * FROM tRMStatus;

SELECT
    *
FROM Verkauf.tAuftrag tA
         LEFT JOIN Verkauf.tAuftragPosition tAP
                   ON tA.kAuftrag = tAP.kAuftrag
                       AND tAP.nType NOT IN (2, 15)  -- Ignorieren von Versandkosten und Kartonagen
         LEFT JOIN dbo.tLieferscheinPos tLP
                   ON tAP.kAuftragPosition = tLP.kBestellPos
         LEFT JOIN dbo.tRMRetourePos tRP
                   ON tLP.kLieferscheinPos = tRP.kLieferscheinPos
         LEFT JOIN dbo.tRMStatusVerlauf tSV
                   ON tRP.kRMStatusVerlauf = tSV.kRMStatusVerlauf
WHERE tA.kAuftrag = 151613; --217148

WITH RetourenProAuftrag AS (
    -- Ermittle für jeden Auftrag die Anzahl unterschiedlicher Retouren
    SELECT
        tA.kAuftrag,
        tA.cAuftragsNr,
        COUNT(DISTINCT tRP.kRMRetoure) AS AnzahlRetouren
    FROM Verkauf.tAuftrag tA
             INNER JOIN Verkauf.tAuftragPosition tAP
                        ON tA.kAuftrag = tAP.kAuftrag
             INNER JOIN dbo.tLieferscheinPos tLP
                        ON tAP.kAuftragPosition = tLP.kBestellPos
             INNER JOIN dbo.tRMRetourePos tRP
                        ON tLP.kLieferscheinPos = tRP.kLieferscheinPos
    WHERE tRP.kRMRetoure IS NOT NULL
    GROUP BY tA.kAuftrag, tA.cAuftragsNr
    HAVING COUNT(DISTINCT tRP.kRMRetoure) > 1
)

-- Hauptabfrage für die Aufträge mit mehreren Retouren
SELECT
    r.kAuftrag,
    r.cAuftragsNr,
    r.AnzahlRetouren,
    (
        -- Subquery für die Retourennummern
        SELECT STRING_AGG(CAST(rr.cRetoureNr AS NVARCHAR(MAX)), ', ')
        FROM (
                 SELECT DISTINCT
                     tRM.cRetoureNr
                 FROM dbo.tRMRetoure tRM
                          INNER JOIN dbo.tRMRetourePos tRP ON tRM.kRMRetoure = tRP.kRMRetoure
                          INNER JOIN dbo.tLieferscheinPos tLP ON tRP.kLieferscheinPos = tLP.kLieferscheinPos
                          INNER JOIN Verkauf.tAuftragPosition tAP ON tLP.kBestellPos = tAP.kAuftragPosition
                 WHERE tAP.kAuftrag = r.kAuftrag
             ) rr
    ) AS Retourennummern,
    (
        -- Subquery für die Retourendaten
        SELECT STRING_AGG(CONVERT(NVARCHAR(20), rd.dErstellt, 104), ', ')
        FROM (
                 SELECT DISTINCT
                     tRM.dErstellt
                 FROM dbo.tRMRetoure tRM
                          INNER JOIN dbo.tRMRetourePos tRP ON tRM.kRMRetoure = tRP.kRMRetoure
                          INNER JOIN dbo.tLieferscheinPos tLP ON tRP.kLieferscheinPos = tLP.kLieferscheinPos
                          INNER JOIN Verkauf.tAuftragPosition tAP ON tLP.kBestellPos = tAP.kAuftragPosition
                 WHERE tAP.kAuftrag = r.kAuftrag
             ) rd
    ) AS Retourendaten
FROM RetourenProAuftrag r
ORDER BY r.AnzahlRetouren DESC, r.kAuftrag;

--Auftrag
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
        tRP.kRMRetoure      -- Retoure-ID zur Prüfung auf Eindeutigkeit
    FROM Verkauf.tAuftrag tA
             LEFT JOIN Verkauf.tAuftragPosition tAP
                       ON tA.kAuftrag = tAP.kAuftrag
                           AND tAP.nType NOT IN (2, 15)  -- Ignorieren von Versandkosten und Kartonagen
             LEFT JOIN dbo.tLieferscheinPos tLP
                       ON tAP.kAuftragPosition = tLP.kBestellPos
             LEFT JOIN dbo.tRMRetourePos tRP
                       ON tLP.kLieferscheinPos = tRP.kLieferscheinPos
             LEFT JOIN dbo.tRMStatusVerlauf tSV
                       ON tRP.kRMStatusVerlauf = tSV.kRMStatusVerlauf
    WHERE tA.kAuftrag = 217409 --217148
),
     RetourenPruefung AS (
         -- Prüfung auf maximal eine eindeutige Retoure
         SELECT COUNT(DISTINCT kRMRetoure) AS AnzahlUnterschiedlicherRetouren
         FROM Basis
         WHERE kRMRetoure IS NOT NULL
     ),
     Pruefungen AS (
         SELECT
             COUNT(*) AS AnzahlPositionen,
             SUM(CASE WHEN Retourniert > 0 THEN 1 ELSE 0 END) AS AnzahlRetourniert,
             SUM(CASE WHEN kZustand = 1 THEN 1 ELSE 0 END) AS AnzahlZustand,
             SUM(CASE WHEN nType = 1 THEN 1 ELSE 0 END) AS AnzahlTyp,
             SUM(CASE WHEN AuftragMenge = RetourMenge THEN 1 ELSE 0 END) AS AnzahlVollstaendigRetourniert,
             SUM(CASE WHEN kAuftragStueckliste IS NULL OR kAuftragStueckliste = 0 THEN 1 ELSE 0 END) AS AnzahlOhneStueckliste,
             SUM(CASE WHEN nGutschreiben = 1 THEN 1 ELSE 0 END) AS AnzahlGutschreiben,
             SUM(CASE WHEN kRMStatus = 6 THEN 1 ELSE 0 END) AS AnzahlErstattungOffen
         FROM Basis
     )
SELECT
    CASE
        WHEN AnzahlPositionen = 0 THEN 'FALSCH'
        WHEN AnzahlPositionen = AnzahlRetourniert AND  -- Alle Positionen sind retourniert
             AnzahlPositionen = AnzahlZustand AND      -- Alle Retouren haben den Zustand Standard
             AnzahlPositionen = AnzahlTyp AND         -- Alle Artikelpositionen sind Typ 1 (Standard Artikel)
             AnzahlPositionen = AnzahlVollstaendigRetourniert AND -- Alle Retourenpositionen vollständig retourniert
             AnzahlPositionen = AnzahlOhneStueckliste AND -- Kein Artikel hat einen Wert bei kAuftragStueckliste
             AnzahlPositionen = AnzahlGutschreiben AND -- Alle Positionen haben nGutschreiben = 1
             AnzahlPositionen = AnzahlErstattungOffen AND -- Alle haben Status "Erstattung offen" (6)
             (SELECT AnzahlUnterschiedlicherRetouren FROM RetourenPruefung) <= 1  -- Maximal eine Retoure
            THEN 'WAHR'
        ELSE 'FALSCH'
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