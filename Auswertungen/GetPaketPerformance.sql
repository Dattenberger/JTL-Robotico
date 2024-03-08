DECLARE @dateString nvarchar(10) = '08.03.2024';
DECLARE @pauseThreshold INT = 15; --A time gap of this amount in between Lieferscheinen will make the gap counted as a pause.

DECLARE @startDate DATETIME = CONVERT(DATETIME, @dateString, 103);
DECLARE @endDate DATETIME = DATEADD(day, 1, @startDate);

WITH LieferscheinZeiten AS (SELECT tL.kBenutzer,
                                   tL.dErstellt,
                                   ROW_NUMBER() OVER (PARTITION BY tL.kBenutzer ORDER BY tL.dErstellt) AS SeqNum
                            FROM dbo.tLieferschein tL
                            WHERE tL.dErstellt BETWEEN @startDate AND @endDate),
     Pausen AS (SELECT L1.kBenutzer,
                       DATEDIFF(MINUTE, L1.dErstellt, L2.dErstellt) AS PauseMinuten,
                       L1.dErstellt                                 AS PauseStart,
                       L2.dErstellt                                 AS PauseEnde
                FROM LieferscheinZeiten L1
                         INNER JOIN LieferscheinZeiten L2 ON L1.kBenutzer = L2.kBenutzer AND L1.SeqNum = L2.SeqNum - 1
                WHERE DATEDIFF(MINUTE, L1.dErstellt, L2.dErstellt) > @pauseThreshold),
     Summery AS
         (SELECT tB.cName                                                                             AS Benutzername,
                 COUNT(DISTINCT tL.kLieferschein)                                                     AS Lieferscheine,
                 COUNT(DISTINCT CASE
                                    WHEN tWG.cName LIKE '%Gartengerät%' OR tWG.cName LIKE '%Mähroboter%'
                                        THEN tL.kLieferschein END)                                    AS Lieferscheine_Gartengerät_Mähroboter,
                 SUM(CASE
                         WHEN tWG.cName LIKE '%Gartengerät%' OR tWG.cName LIKE '%Mähroboter%'
                             THEN tLP.fAnzahl END)                                                    AS Artikel_Gartengerät_Mähroboter,
                 DATEDIFF(MINUTE, MIN(tL.dErstellt), MAX(tL.dErstellt))                               AS Minuten,
                 ISNULL((SELECT COUNT(*) FROM Pausen p WHERE p.kBenutzer = tB.kBenutzer), 0)          AS Pausen,
                 ISNULL((SELECT SUM(PauseMinuten) FROM Pausen p WHERE p.kBenutzer = tB.kBenutzer),
                        0)                                                                            AS PauseMinuten,
                 ISNULL((SELECT STRING_AGG(CONCAT(FORMAT(PauseStart, 'HH:mm'), ' - ', FORMAT(PauseEnde, 'HH:mm')),
                                           '; ')
                         FROM Pausen p
                         WHERE p.kBenutzer = tB.kBenutzer),
                        '')                                                                           AS PausenAufstellung
          FROM (SELECT tL.kLieferschein, tL.kBenutzer, tL.dErstellt
                FROM dbo.tLieferschein tL
                WHERE tL.dErstellt BETWEEN @startDate AND @endDate) as tL
                   INNER JOIN dbo.tBenutzer tB ON tL.kBenutzer = tB.kBenutzer
                   INNER JOIN dbo.tLieferscheinPos tLP ON tL.kLieferschein = tLP.kLieferschein
                   INNER JOIN dbo.tBestellpos tBP ON tLP.kBestellPos = tBP.kBestellPos
                   INNER JOIN dbo.tArtikel tA ON tBP.tArtikel_kArtikel = tA.kArtikel
                   INNER JOIN dbo.tWarengruppe tWG ON tA.kWarengruppe = tWG.kWarengruppe
          GROUP BY tB.cName, tB.kBenutzer)
SELECT *,
       Minuten - PauseMinuten                                    AS ZeitspanneVersandMinuten,
       (60.00 * Lieferscheine / (Minuten - PauseMinuten)) as PaketeProStunde
FROM Summery