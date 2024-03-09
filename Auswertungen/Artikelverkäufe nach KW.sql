USE eazybusiness;

DECLARE @LastDayString varchar(10) = '30.06.2023';
DECLARE @AdditionalWeeks INT = 3;

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
;WITH Aufträge AS (SELECT *
                  FROM Verkauf.tAuftrag tAu
                  WHERE tAu.dErstellt >= DATEADD(WEEK, -1, @BeginWeek)
                    AND tAu.dErstellt < @LastDay
                    AND tAu.kPlattform NOT IN (SELECT kPlattform FROM @tPlattformIgnorieren)
                    AND tAu.kKunde NOT IN (SELECT kKunde FROM @tKundeIngorieren)),
     ArtikelVerkäufe AS (SELECT lvA.kArtikel,
                                tA.kWarengruppe,
                                COUNT(*)                                  AS Auftragspositionen,
                                SUM(lvA.fAnzahl)                          AS GesamtAnzahl,
                                CAST(DATEADD(DAY, 1 - DATEPART(WEEKDAY, Aufträge.dErstellt),
                                             Aufträge.dErstellt) AS DATE) AS StartOfWeek
                         FROM Aufträge
                                  INNER JOIN Verkauf.lvAuftragsposition lvA ON Aufträge.kAuftrag = lvA.kAuftrag
                                  INNER JOIN dbo.tArtikel tA ON lvA.kArtikel = tA.kArtikel
                         GROUP BY lvA.kArtikel, tA.kWarengruppe,
                                  CAST(DATEADD(DAY, 1 - DATEPART(WEEKDAY, Aufträge.dErstellt),
                                               Aufträge.dErstellt) AS DATE)),
     Veränderung AS (SELECT A.kArtikel,
                            A.StartOfWeek,
                            A.GesamtAnzahl /
                            NULLIF(LAG(A.GesamtAnzahl) OVER (PARTITION BY A.kArtikel ORDER BY A.StartOfWeek), 0) -
                            1 AS Veränderung
                     FROM ArtikelVerkäufe A),
     WarengruppeVeränderung AS (SELECT kWarengruppe,
                                       AV.StartOfWeek,
                                       SUM(GesamtAnzahl)                 AS GesamtAnzahlWarengruppe,
                                       SUM(GesamtAnzahl) / NULLIF(LAG(SUM(GesamtAnzahl))
                                                                      OVER (PARTITION BY kWarengruppe ORDER BY StartOfWeek),
                                                                  0) - 1 AS VeränderungWarengruppe
                                FROM ArtikelVerkäufe AV
                                GROUP BY kWarengruppe, StartOfWeek)
SELECT tAB.cName,
       AV.kArtikel,
       AV.kWarengruppe,
       AV.Auftragspositionen,
       AV.GesamtAnzahl,
       CONVERT(VARCHAR, AV.StartOfWeek, 104)                                                                      AS Wochenanfang,
       CONCAT(DATEPART(WEEK, AV.StartOfWeek), '.', YEAR(AV.StartOfWeek))                                          AS KW,
       IIF(V.Veränderung IS NULL, '',
           CONCAT(CAST((V.Veränderung * 100) AS INT), ' %'))                                                      AS Veränderung,
       IIF(WGV.VeränderungWarengruppe IS NULL, '',
           CONCAT(CAST((WGV.VeränderungWarengruppe * 100) AS INT), ' %'))                                         AS VeränderungWarengruppe,
       --V.Veränderung,
       --WGV.VeränderungWarengruppe,
       IIF(V.Veränderung - WGV.VeränderungWarengruppe IS NULL, '',
           CONCAT(CAST(((V.Veränderung - WGV.VeränderungWarengruppe) * 100) AS INT),
                  ' %'))                                                                                          AS VeränderungDifferenz
FROM ArtikelVerkäufe AV
         LEFT JOIN Veränderung V ON AV.kArtikel = V.kArtikel AND AV.StartOfWeek = V.StartOfWeek
         LEFT JOIN WarengruppeVeränderung WGV ON AV.kWarengruppe = WGV.kWarengruppe AND AV.StartOfWeek = WGV.StartOfWeek
         INNER JOIN dbo.tArtikelBeschreibung tAB ON AV.kArtikel = tAB.kArtikel AND tAB.kSprache = 1
WHERE AV.StartOfWeek >= @BeginWeek
  -- AND AV.kArtikel = 217
ORDER BY AV.kArtikel, AV.StartOfWeek