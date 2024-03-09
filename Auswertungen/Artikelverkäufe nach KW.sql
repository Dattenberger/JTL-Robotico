USE eazybusiness;

DECLARE @LastDayString varchar(10) = '13.03.2024';
DECLARE @AdditionalWeeks INT = 5;

DECLARE @LastDay DATETIME = CONVERT(datetime, REPLACE(@LastDayString, '.', '-'), 105);
DECLARE @LastWeek DATETIME = DATEADD(DAY, 1 - DATEPART(WEEKDAY, @LastDay), @LastDay);
DECLARE @BeginWeek DATETIME = DATEADD(WEEK, - @AdditionalWeeks, @LastWeek);

--Hier kann eingestellt werden, welche Kunden komplett ignoriert werden.
DECLARE @tKundeIngorieren TABLE
                          (
                              kKunde int
                          );
INSERT INTO @tKundeIngorieren
VALUES (8728);
--8728 -> Gieseke

--Hier können ausgeschlossene Plattformen angegeben werden
DECLARE @tPlattformIgnorieren TABLE
                              (
                                  kPlattform int
                              );
INSERT INTO @tPlattformIgnorieren
VALUES (1);
--1 -> JTL WaWi

-- Berechnung der Verkaufszahlen pro Artikel für die aktuelle und die drei vorherigen Kalenderwochen
;WITH
     StartOfWeeks AS (SELECT DATEADD(DAY, 1 - DATEPART(WEEKDAY, @LastWeek), @LastWeek) AS StartOfWeek
                        UNION ALL
                        SELECT DATEADD(WEEK, -1, StartOfWeek)
                        FROM StartOfWeeks
                        WHERE StartOfWeek >= @BeginWeek),
     ArtikelWeeks AS (SELECT tA.kArtikel,
                                 tA.kWarengruppe,
                                 StartOfWeeks.StartOfWeek AS StartOfWeek
                          FROM StartOfWeeks
                              CROSS JOIN dbo.tArtikel tA),
     Aufträge AS (SELECT *
                  FROM Verkauf.tAuftrag tAu
                  WHERE tAu.dErstellt >= DATEADD(WEEK, -1, @BeginWeek)
                    AND tAu.dErstellt <= @LastDay
                    AND tAu.kPlattform NOT IN (SELECT kPlattform FROM @tPlattformIgnorieren)
                    AND tAu.kKunde NOT IN (SELECT kKunde FROM @tKundeIngorieren)),
     ArtikelVerkäufe AS (SELECT lvA.kArtikel,
                                tA.kWarengruppe,
                                COUNT(*)                                  AS Auftragspositionen,
                                SUM(lvA.fAnzahl)                          AS GesamtAnzahl,
                                SUM(lvA.fVKNettoGesamt) / SUM(lvA.fAnzahl)                          AS DurchschnittsVK,
                                SUM(tAP.fEkNetto * lvA.fAnzahl) / SUM(lvA.fAnzahl) AS DurchschnittsEK,
                                CAST(DATEADD(DAY, 1 - DATEPART(WEEKDAY, Aufträge.dErstellt),
                                             Aufträge.dErstellt) AS DATE) AS StartOfWeek
                         FROM Aufträge
                                  INNER JOIN Verkauf.lvAuftragsposition lvA ON Aufträge.kAuftrag = lvA.kAuftrag
                             INNER JOIN Verkauf.tAuftragPosition tAP ON lvA.kAuftragPosition = tAP.kAuftragPosition
                                  INNER JOIN dbo.tArtikel tA ON lvA.kArtikel = tA.kArtikel
                         GROUP BY lvA.kArtikel, tA.kWarengruppe,
                                  CAST(DATEADD(DAY, 1 - DATEPART(WEEKDAY, Aufträge.dErstellt),
                                               Aufträge.dErstellt) AS DATE)),
     ArtikelVerkäufeAlleWochen AS (SELECT AW.kArtikel,
                                         AW.kWarengruppe,
                                         AW.StartOfWeek,
                                         ISNULL(AV.Auftragspositionen, 0) AS Auftragspositionen,
                                         ISNULL(AV.GesamtAnzahl, 0) AS GesamtAnzahl,
                                            ISNULL(AV.DurchschnittsVK, 0) AS DurschnittsVK,
                                            ISNULL(AV.DurchschnittsEK, 0) AS DurschnittsEK
                                  FROM ArtikelWeeks AW
                                           LEFT JOIN ArtikelVerkäufe AV ON AW.kArtikel = AV.kArtikel AND AW.StartOfWeek = AV.StartOfWeek
                                  --WHERE AW.kArtikel = 365
WHERE (SELECT SUM(AV2.GesamtAnzahl) FROM ArtikelVerkäufe AV2 WHERE AV2.kArtikel = AW.kArtikel) > 0
                                  ),
     Veränderung AS (SELECT AVW.kArtikel,
                            AVW.StartOfWeek,
                            AVW.GesamtAnzahl /
                            NULLIF(LAG(AVW.GesamtAnzahl) OVER (PARTITION BY AVW.kArtikel ORDER BY AVW.StartOfWeek), 0) -
                            1 AS Veränderung
                     FROM ArtikelVerkäufeAlleWochen AVW),
     WarengruppeVeränderung AS (SELECT kWarengruppe,
                                       AVW.StartOfWeek,
                                       SUM(GesamtAnzahl)                 AS GesamtAnzahlWarengruppe,
                                       SUM(GesamtAnzahl) / NULLIF(LAG(SUM(GesamtAnzahl))
                                                                      OVER (PARTITION BY kWarengruppe ORDER BY StartOfWeek),
                                                                  0) - 1 AS VeränderungWarengruppe
                                FROM ArtikelVerkäufeAlleWochen AVW
                                GROUP BY kWarengruppe, StartOfWeek)
SELECT tAB.cName,
       AVW.kArtikel,
       AVW.kWarengruppe,
       AVW.Auftragspositionen,
       AVW.GesamtAnzahl,
       AVW.DurschnittsVK,
         AVW.DurschnittsEK,
         AVW.DurschnittsVK - AVW.DurschnittsEK AS DurschnittsGewinn,
         (AVW.DurschnittsVK - AVW.DurschnittsEK) * AVW.GesamtAnzahl AS GesamtGewinn,
       CONVERT(VARCHAR, AVW.StartOfWeek, 104)                                                                      AS Wochenanfang,
       CONCAT(DATEPART(WEEK, AVW.StartOfWeek), '.', YEAR(AVW.StartOfWeek))                                          AS KW,
       IIF(V.Veränderung IS NULL, '',
           CONCAT(CAST((V.Veränderung * 100) AS INT), ' %'))                                                      AS Veränderung,
       IIF(WGV.VeränderungWarengruppe IS NULL, '',
           CONCAT(CAST((WGV.VeränderungWarengruppe * 100) AS INT), ' %'))                                         AS VeränderungWarengruppe,
       --V.Veränderung,
       --WGV.VeränderungWarengruppe,
       IIF(V.Veränderung - WGV.VeränderungWarengruppe IS NULL, '',
           CONCAT(CAST(((V.Veränderung - WGV.VeränderungWarengruppe) * 100) AS INT),
                  ' %'))                                                                                          AS VeränderungDifferenz
FROM ArtikelVerkäufeAlleWochen AVW
         LEFT JOIN Veränderung V ON AVW.kArtikel = V.kArtikel AND AVW.StartOfWeek = V.StartOfWeek
         LEFT JOIN WarengruppeVeränderung WGV ON AVW.kWarengruppe = WGV.kWarengruppe AND AVW.StartOfWeek = WGV.StartOfWeek
         INNER JOIN dbo.tArtikelBeschreibung tAB ON AVW.kArtikel = tAB.kArtikel AND tAB.kSprache = 1
WHERE AVW.StartOfWeek >= @BeginWeek
ORDER BY AVW.kArtikel, AVW.StartOfWeek

--SELECT * FROM ArtikelVerkäufe WHERE ArtikelVerkäufe.kArtikel = 365
--SELECT * FROM ArtikelVerkäufeAlleWochen WHERE ArtikelVerkäufeAlleWochen.kArtikel = 365
-- ORDER BY kArtikel, StartOfWeek