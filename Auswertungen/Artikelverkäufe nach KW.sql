USE eazybusiness;

DECLARE @Now DATETIME = '2023-31-03 00:00:00';
DECLARE @LastWeek DATETIME = DATEADD(DAY, 1 - DATEPART(WEEKDAY, @Now), @Now);
DECLARE @BeginWeek DATETIME = DATEADD(WEEK, -3, @LastWeek);

--Hier kann eingestellt werden, welche Kunden komplett ignoriert werden.
DECLARE @tKundeIngorieren TABLE
                          (
                              kKunde int
                          );
INSERT INTO @tKundeIngorieren
VALUES (8728); --8728 -> Gieseke

--Hier können ausgeschlossene Plattformen angegeben werden
DECLARE @tPlattformIgnorieren TABLE
                              (
                                  kPlattform int
                              );
INSERT INTO @tPlattformIgnorieren
VALUES (1); --1 -> JTL WaWi

-- Berechnung der Verkaufszahlen pro Artikel für die aktuelle und die drei vorherigen Kalenderwochen
;WITH ArtikelVerkäufe AS (
    SELECT
        lvA.kArtikel,
        tA.kWarengruppe,
                                COUNT(*)                      AS Verkaufszahlen,
                                SUM(lvA.fAnzahl)              AS GesamtAnzahl,
                                --DATEPART(WEEK, tAu.dErstellt) AS Verkaufswoche,
                                --YEAR(tAu.dErstellt)           AS Verkaufsjahr,
                                CAST(DATEADD(DAY, 1 - DATEPART(WEEKDAY, tAu.dErstellt), tAu.dErstellt) AS DATE) AS StartOfWeek
                         FROM Verkauf.lvAuftragsposition lvA
                                  INNER JOIN Verkauf.tAuftrag tAu ON lvA.kAuftrag = tAu.kAuftrag AND
                                                                                  tAu.kPlattform NOT IN
                                                                                  (SELECT kPlattform FROM @tPlattformIgnorieren)
                                  INNER JOIN dbo.tArtikel tA ON lvA.kArtikel = tA.kArtikel
                         WHERE tAu.dErstellt >= DATEADD(WEEK, -1, @BeginWeek)
                           AND tAu.dErstellt < @Now
                           AND tAu.kKunde NOT IN (SELECT kKunde FROM @tKundeIngorieren)
    GROUP BY
        lvA.kArtikel, tA.kWarengruppe,
        CAST(DATEADD(DAY, 1 - DATEPART(WEEKDAY, tAu.dErstellt), tAu.dErstellt) AS DATE)
),
Veränderung AS (
    SELECT
        A.kArtikel,
        A.StartOfWeek,
        (A.GesamtAnzahl - COALESCE(LAG(A.GesamtAnzahl) OVER(PARTITION BY A.kArtikel ORDER BY A.StartOfWeek), NULL)) / COALESCE(NULLIF(LAG(A.GesamtAnzahl) OVER(PARTITION BY A.kArtikel ORDER BY A.StartOfWeek), 0), NULL) AS Veränderung
    FROM
        ArtikelVerkäufe A
),
WarengruppeVeränderung AS (
    SELECT
        kWarengruppe,
        AV.StartOfWeek,
        SUM(GesamtAnzahl) AS GesamtAnzahlWarengruppe,
        SUM(GesamtAnzahl) / COALESCE(LAG(SUM(GesamtAnzahl)) OVER(PARTITION BY kWarengruppe ORDER BY StartOfWeek), NULL) AS VeränderungWarengruppe
    FROM
        ArtikelVerkäufe AV
    GROUP BY
        kWarengruppe, StartOfWeek
)
SELECT
    tAB.cName,
    AV.kArtikel,
    AV.kWarengruppe,
    AV.Verkaufszahlen,
    AV.GesamtAnzahl,
    CONCAT(DATEPART(WEEK, AV.StartOfWeek),'.',YEAR(AV.StartOfWeek))           AS KW,
    V.Veränderung,
    WGV.VeränderungWarengruppe,
    V.Veränderung - WGV.VeränderungWarengruppe AS VeränderungDifferenz
FROM
    ArtikelVerkäufe AV
    LEFT JOIN Veränderung V ON AV.kArtikel = V.kArtikel AND AV.StartOfWeek = V.StartOfWeek
    LEFT JOIN WarengruppeVeränderung WGV ON AV.kWarengruppe = WGV.kWarengruppe AND AV.StartOfWeek = WGV.StartOfWeek
    INNER JOIN dbo.tArtikelBeschreibung tAB ON AV.kArtikel = tAB.kArtikel AND tAB.kSprache = 1
WHERE AV.kArtikel = 217 AND AV.StartOfWeek >= @BeginWeek
ORDER BY
    AV.kArtikel, AV.StartOfWeek