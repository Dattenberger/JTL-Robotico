DECLARE @Key INT = 12297; -- 217148

SELECT
    --tAP.kAuftrag,
    --tAP.kAuftragPosition,
    tAP.cName                                              as ArtikelName,
    FORMAT(tAP.fAnzahl, 'F2')                              AS AuftragMenge,      -- Menge aus der Auftragsposition
    tZustandSprache.cName                                  as RetourZustand,     -- Zustand der Retournierten Position
    --ISNULL(tRP.kRMRetourePos, 0) AS Retourniert, -- 0 bedeutet nicht retourniert
    tRMStatusSprache.cName                                 AS RetourenStatus,    -- Status der Retoure
    FORMAT(ISNULL(tRP.fAnzahl, 0), 'F2')                   AS RetourMenge,       -- Menge in der Retoure, 0 wenn nicht retourniert
    FORMAT(lAP.fAnzRetoure, 'F2')                          AS RetourMengeGesamt, -- Retournierte Menge über alle Retouren
    IIF(tAP.kAuftragStueckliste IS NULL, 'FALSCH', 'WAHR') AS IstStückliste,     -- Prüfung ob gutgeschrieben werden soll
    FORMAT(lAP.fVKBrutto, 'F4')                            AS StückpreisBrutto,
    FORMAT(lAP.fVKBrutto * (1 - tAP.fRabatt / 100), 'F4')  AS StückpreisInklRabatt
--tRP.kRMRetoure      -- Retoure-ID zur Prüfung auf Eindeutigkeit
FROM RM.lvRetoure lR
         LEFT JOIN Verkauf.tAuftragPosition tAP
                   ON lR.kBestellung = tAP.kAuftrag
                       AND tAP.nType NOT IN (2, 15) -- Ignorieren von Versandkosten und Kartonagen
         LEFT JOIN Verkauf.lvAuftragsposition lAP
                   ON tAP.kAuftragPosition = lAP.kAuftragPosition
         LEFT JOIN dbo.tLieferscheinPos tLP
                   ON tAP.kAuftragPosition = tLP.kBestellPos
         LEFT JOIN RM.lvRetourePosition tRP
                   ON tLP.kLieferscheinPos = tRP.kLieferscheinPos
         LEFT JOIN dbo.tZustandSprache
                   ON tRP.kZustand = tZustandSprache.kZustand AND tZustandSprache.kSprache = 1 --German
         LEFT JOIN dbo.tRMStatusSprache
                   ON tRP.kRMStatus = tRMStatusSprache.kRMStatus AND tRMStatusSprache.kSprache = 1 --German
WHERE lR.kRMRetoure = @Key --217148