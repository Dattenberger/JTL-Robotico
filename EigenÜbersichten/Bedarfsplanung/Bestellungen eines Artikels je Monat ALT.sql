/****** Script for SelectTopNRows command from SSMS  ******/

DECLARE @Key INTEGER = 305

SELECT FORMAT (MonatI,'yyyy-MM') as Monat
      ,FORMAT(SUM(AuftragAnzahl), '#,#') as Bestellt
      ,FORMAT(SUM(GeliefertAnzahl), '#,#') as Geliefert
      ,FORMAT(SUM(Storniert), '#,#') as Storniert
	  ,COUNT(DISTINCT [kAuftrag]) as Aufträge
	  FROM (
	SELECT [tAuftragPosition].[kArtikel]
      ,tAuftragPosition.[kAuftrag]
	  ,DATEADD(MONTH, DATEDIFF(MONTH, 0, [dErstellt]), 0) AS MonatI
	  ,[tAuftragPosition].fAnzahl as AuftragAnzahl
	  ,[tLieferscheinPos].fAnzahl as GeliefertAnzahl
	  ,[tGutschriftPos].nAnzahl as Gutgeschrieben
	  ,CASE WHEN [tAuftrag].nStorno = 1 THEN [tAuftragPosition].fAnzahl ELSE NULL END as Storniert
  FROM [eazybusiness].[Verkauf].[tAuftragPosition]
  LEFT JOIN [eazybusiness].[dbo].[tLieferscheinPos] ON kAuftragPosition = kBestellPos
  LEFT JOIN [eazybusiness].[Verkauf].[tAuftrag] ON tAuftrag.kAuftrag = tAuftragPosition.kAuftrag
  LEFT JOIN [eazybusiness].[Rechnung].[tRechnungPosition] ON [tRechnungPosition].kAuftrag = tAuftrag.kAuftrag
  LEFT JOIN [eazybusiness].[dbo].[tGutschriftPos] ON [tGutschriftPos].kRechnungPosition = [tRechnungPosition].kRechnungPosition
  WHERE tAuftragPosition.kArtikel = @Key
) x
GROUP BY MonatI
ORDER BY Monat ASC