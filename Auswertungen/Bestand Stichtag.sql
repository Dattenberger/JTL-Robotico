/*
Jedem, der eine Kopie dieser Software und der zugehörigen Dokumentationsdateien (die „Software“) erhält, wird hiermit kostenlos die Erlaubnis erteilt, ohne Einschränkung mit der Software zu handeln, einschließlich und ohne Einschränkung der Rechte zur Nutzung, zum Kopieren, Ändern, Zusammenführen, Veröffentlichen, Verteilen, Unterlizenzieren und/oder Verkaufen von Kopien der Software, und Personen, denen die Software zur Verfügung gestellt wird, dies unter den folgenden Bedingungen zu gestatten:
Der obige Urheberrechtshinweis und dieser Genehmigungshinweis müssen in allen Kopien oder wesentlichen Teilen der Software enthalten sein.
QUELLE: https://support.t4dt.com/hc/de/articles/4407053625234-Stichtagsbestand-mit-Einkaufspreis
*/

-- Mit diesem Skript lässt sich der Bestand zu einem Gewissen Datum rückrechne. Vorsicht: Es werden immer alle Lagerbestände aus allen Lagern berücksichtigt.

DECLARE @kWarenlager INT = 17; -- 6 = Laden Unterschleißheim, 17 = Unterschleißheim WMS
DECLARE @stichtag DATETIME2= N'2025-10-31'; -- 2023-06-04 2022-12-30

SELECT tA.[cArtNr]                                                                                                        AS [Artikelnummer],
       tA.[cHAN]                                                                                                          AS [HAN],
       tAB.cName                                                                                                          AS [Artikelname],
       tW.cName AS [Warengruppe],
       CONVERT(FLOAT, SUM(CASE
                              WHEN DATEDIFF(DAY, tWLE.[dErstellt], @stichtag) >= 0
                                  THEN tWLE.[fAnzahl]
                              ELSE 0
                              END -
                          ISNULL(ttWLE.[Anzahl], 0)))                                                                   AS [Stichtagsbestand],
       CONVERT(FLOAT, SUM((CASE
                               WHEN DATEDIFF(DAY, tWLE.[dErstellt], @stichtag) >= 0
                                   THEN tWLE.[fAnzahl]
                               ELSE 0
                               END - ISNULL(ttWLE.[Anzahl], 0)) * tWLE.[fEKEinzel]) / SUM(CASE
                                                                                                WHEN DATEDIFF(DAY, tWLE.[dErstellt], @stichtag) >= 0
                                                                                                    THEN tWLE.[fAnzahl]
                                                                                                ELSE 0
                                                                                                END -
                                                                                            ISNULL(ttWLE.[Anzahl], 0))) AS [Durschn. Ek],
       tliefartikel.fEKNetto                                                                                                 [Lief. Ek],
       tliefartikel.cWaehrung                                                                                                [Lief. Ek Währung]
INTO #beständeNachArtikel

FROM dbo.tWarenLagerEingang tWLE
         INNER JOIN dbo.tWarenLagerPlatz tWLP
                    ON tWLP.kWarenLagerPlatz = tWLE.kWarenLagerPlatz
                        AND tWLP.kWarenLager = @kWarenlager
         INNER JOIN dbo.tArtikel tA
                    ON tA.kArtikel = tWLE.kArtikel
         INNER JOIN dbo.tArtikelBeschreibung tAB
                    ON tAB.kArtikel = tA.kArtikel
                        AND tAB.kSprache = 1
                        AND tAB.kShop = 0
         INNER JOIN tliefartikel
                    ON tliefartikel.tArtikel_kArtikel = tA.kArtikel
                        AND tliefartikel.nStandard = 1
         LEFT JOIN tWarengruppe tW
                     ON tW.kWarengruppe = tA.kWarengruppe
         LEFT OUTER JOIN
     (SELECT SUM(ISNULL([fAnzahl], 0)) [Anzahl],
             [twla].[kWarenLagerEingang]
      FROM dbo.tWarenLagerAusgang twla
      WHERE [twla].[dErstellt] <= @stichtag
      GROUP BY [twla].[kWarenLagerEingang]) ttWLE
     ON ttWLE.kWarenLagerEingang = tWLE.kWarenLagerEingang
WHERE (CASE
           WHEN DATEDIFF(DAY, tWLE.[dErstellt], @stichtag) >= 0
               THEN tWLE.[fAnzahl]
           ELSE 0
           END - ISNULL(ttWLE.[Anzahl], 0)) > 0
GROUP BY tA.[cArtNr],
         tA.kArtikel,
         tA.[cHAN],
         tAB.cName,
         tW.cName,
         tliefartikel.fEKNetto,
         tliefartikel.cWaehrung;

--Bestände nach Artikel
SELECT *, [Stichtagsbestand] * [Durschn. Ek] as [Wert]
FROM #beständeNachArtikel
ORDER BY Wert DESC;

--Warengruppen
SELECT #beständeNachArtikel.Warengruppe,
    SUM([Stichtagsbestand])                 AS [Artikelanzahl Gesamt],
       ROUND(SUM([Stichtagsbestand] * [Durschn. Ek]), 2) AS [Wert]
FROM #beständeNachArtikel
group by #beständeNachArtikel.Warengruppe;

--Gesamtbestand
SELECT SUM([Stichtagsbestand])                 AS [Artikelanzahl Gesamt],
       ROUND(SUM([Stichtagsbestand] * [Durschn. Ek]), 2) AS [Wert]
FROM #beständeNachArtikel;

DROP TABLE IF EXISTS #beständeNachArtikel;