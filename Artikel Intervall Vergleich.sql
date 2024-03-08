DECLARE @Key INT;
SET @Key = 781;
DECLARE @Intevall INT;
SET @Intevall = 14;

/*SELECT ROUND(CONVERT(FLOAT, ISNULL(SUM(tbestellpos.nAnzahl), 0.0)), 2) AS absatz*/
SELECT *, 
(CAST(anzahl AS float) / CAST(vorherige_woche AS float)) as vorherige_woche_wachstum FROM(
SELECT *, (LEAD(anzahl,1,0) OVER(ORDER BY woche_bis_jetzt)) as vorherige_woche
FROM (
SELECT COUNT(nAnzahl) AS anzahl, floor(DATEDIFF (day , dErstellt , getdate()) / @Intevall) as woche_bis_jetzt, DATEADD(day, (floor(DATEDIFF (day , dErstellt , getdate()) / @Intevall) + 1) * @Intevall * (-1), getdate() ) as woche_ab_wann
    FROM tbestellung
    JOIN tbestellpos ON tbestellpos.tBestellung_kBestellung = tBestellung.kBestellung
    WHERE tbestellpos.tArtikel_kArtikel = @Key
        AND tBestellung.nStorno = 0 -- Stornierte Aufträge nicht beachten
        AND tbestellung.cType = 'B'
        AND tBestellung.dErstellt > DATEADD(DAY, -180, getdate())
	GROUP BY floor(DATEDIFF (day , dErstellt , getdate()) / @Intevall)
) as x
) as y