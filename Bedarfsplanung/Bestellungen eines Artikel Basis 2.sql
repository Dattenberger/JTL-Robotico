/****** Script for SelectTopNRows command from SSMS  ******/
/**
407: Platine Ladestation P1
*/

DECLARE @Key INTEGER = 895
DECLARE @kWarenlager INTEGER = 17 --

SELECT [tAuftragPosition].kAuftragPosition as AuftragsPositionID
     , STRING_AGG([tLieferscheinPos].kLieferscheinPos, ', ') as LieferscheinPositionIDs
     , [tAuftragPosition].[kArtikel]
     , tAuftrag.cAuftragsNr as Auftragsnummer
     , tAuftrag.kAuftrag as AuftragID
     , STRING_AGG([tRechnungPosition].kRechnung, ', ') as RechnunsIDs
     , STRING_AGG(tRechnung.cRechnungsnr, ', ') as RechnunsNr
     , STRING_AGG([tGutschriftPos].tGutschrift_kGutschrift, ', ') as GutschriftIDs
     , STRING_AGG(tgutschrift.cGutschriftNr, ', ') as GutschriftNr
     , STRING_AGG(tRechnungPosition.kRechnungPosition, ', ') as RechnungsPosIDs
     , STRING_AGG([tGutschriftPos].kGutschriftPos, ', ') as GutschriftPosIDs
    /*,DATEADD(MONTH, DATEDIFF(MONTH, 0, [tAuftrag].[dErstellt]), 0) AS MonatI*/
     , [tAuftrag].[dErstellt] as Auftragsdatum
     , [tAuftragPosition].fAnzahl as AuftragsAnzahl
     , SUM([tLieferscheinPos].fAnzahl) as GeliefertAnzahl
     , SUM(CASE WHEN tgutschrift.nStorno = 0 THEN [tGutschriftPos].nAnzahl END) as Gutgeschrieben
     , SUM(CASE WHEN tgutschrift.nStorno = 1 THEN [tGutschriftPos].nAnzahl END) as GutgeschriebenUndStorniert
     , SUM(CASE WHEN [tAuftrag].nStorno = 1 THEN [tAuftragPosition].fAnzahl END) as Storniert
FROM [eazybusiness].[Verkauf].[tAuftragPosition]
         LEFT JOIN [eazybusiness].[dbo].[tLieferscheinPos] ON kAuftragPosition = kBestellPos
         LEFT JOIN [eazybusiness].[Verkauf].[tAuftrag] ON tAuftrag.kAuftrag = tAuftragPosition.kAuftrag
         LEFT JOIN [eazybusiness].[Rechnung].[tRechnungLieferscheinPosition] ON tRechnungLieferscheinPosition.kLieferscheinPosition = tLieferscheinPos.kLieferscheinPos
         LEFT JOIN [eazybusiness].[Rechnung].[tRechnungPosition] ON
             tRechnungPosition.kRechnungPosition = tRechnungLieferscheinPosition.kRechnungPosition OR
             [tRechnungPosition].kAuftragPosition = IIF(tRechnungLieferscheinPosition.kRechnungPosition IS NULL, tAuftragPosition.kAuftragPosition, NULL)
         LEFT JOIN [eazybusiness].[Rechnung].tRechnung ON tRechnung.kRechnung = [tRechnungPosition].kRechnung
         LEFT JOIN [eazybusiness].[dbo].[tGutschriftPos] ON [tGutschriftPos].kRechnungPosition = [tRechnungPosition].kRechnungPosition
         LEFT JOIN [eazybusiness].[dbo].[tgutschrift] ON [tgutschrift].kGutschrift = [tGutschriftPos].tGutschrift_kGutschrift AND [tgutschrift].nStornoTyp != 2 /*StornoTyp 2 -> Stornobeleg*/
WHERE tAuftragPosition.kArtikel = @Key AND cAuftragsNr = 'D-AU202269911'
GROUP BY [tAuftragPosition].[kArtikel], [tAuftragPosition].kAuftragPosition,
         [tAuftragPosition].fAnzahl, tAuftrag.cAuftragsNr, [tAuftrag].[dErstellt], tAuftrag.kAuftrag