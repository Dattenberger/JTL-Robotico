/****** Script for SelectTopNRows command from SSMS  ******/

DECLARE @Key INTEGER = 1351

SELECT FORMAT(DATEADD(MONTH, DATEDIFF(MONTH, 0, Auftragsdatum), 0), 'yyyy-MM') as Monat
     , Auftragsnummer
     , FORMAT(SUM(AuftragsAnzahl), '#,#') as Bestellt
     , FORMAT(SUM(GeliefertAnzahl), '#,#') as Geliefert
     , FORMAT(SUM(Gutgeschrieben), '#,#') as Gutgeschrieben
     , FORMAT(SUM(GutgeschriebenUndStorniert), '#,#') as GutgeschriebenUndStorniert
     , FORMAT(SUM(Storniert), '#,#') as Storniert


FROM (
     SELECT [tAuftragPosition].kAuftragPosition as AuftragsPosition
          , [tLieferscheinPos].kLieferscheinPos as LieferscheinPosition
          , [tAuftragPosition].[kArtikel]
          , tAuftrag.cAuftragsNr as Auftragsnummer
          , STRING_AGG([tRechnungPosition].kRechnung, ', ') as RechnunsIDs
          , STRING_AGG(tRechnung.cRechnungsnr, ', ') as RechnunsNr
          , STRING_AGG([tGutschriftPos].tGutschrift_kGutschrift, ', ') as GutschriftIDs
          , STRING_AGG(tgutschrift.cGutschriftNr, ', ') as GutschriftNr
          , STRING_AGG(tRechnungPosition.kRechnungPosition, ', ') as RechnungsPosIDs
          , STRING_AGG([tGutschriftPos].kGutschriftPos, ', ') as GutschriftPosIDs
         /*,DATEADD(MONTH, DATEDIFF(MONTH, 0, [tAuftrag].[dErstellt]), 0) AS MonatI*/
          , [tAuftrag].[dErstellt] as Auftragsdatum
          , COUNT([tAuftragPosition].fAnzahl) as AuftragsPosAnzahl
          , [tAuftragPosition].fAnzahl as AuftragsAnzahl
          , [tLieferscheinPos].fAnzahl as GeliefertAnzahl
          , SUM(CASE WHEN tgutschrift.nStorno = 0 THEN [tGutschriftPos].nAnzahl ELSE NULL END) as Gutgeschrieben
          , SUM(CASE
                    WHEN tgutschrift.nStorno = 1 THEN [tGutschriftPos].nAnzahl
                    ELSE NULL END) as GutgeschriebenUndStorniert
          , SUM(CASE WHEN [tAuftrag].nStorno = 1 THEN [tAuftragPosition].fAnzahl ELSE NULL END) as Storniert
     FROM [eazybusiness].[Verkauf].[tAuftragPosition]
              LEFT JOIN [eazybusiness].[dbo].[tLieferscheinPos] ON kAuftragPosition = kBestellPos
              LEFT JOIN [eazybusiness].[Verkauf].[tAuftrag] ON tAuftrag.kAuftrag = tAuftragPosition.kAuftrag
              LEFT JOIN [eazybusiness].[Rechnung].[tRechnungPosition]
                        ON [tRechnungPosition].kAuftragPosition = tAuftragPosition.kAuftragPosition
              LEFT JOIN [eazybusiness].[Rechnung].tRechnung
                        ON tRechnung.kRechnung = [tRechnungPosition].kRechnung
              LEFT JOIN [eazybusiness].[dbo].[tGutschriftPos]
                        ON [tGutschriftPos].kRechnungPosition = [tRechnungPosition].kRechnungPosition
              LEFT JOIN [eazybusiness].[dbo].[tgutschrift]
                        ON [tgutschrift].kGutschrift = [tGutschriftPos].tGutschrift_kGutschrift AND
                           [tgutschrift].nStornoTyp != 2 /*StornoTyp 2 -> Stornobeleg*/
     WHERE tAuftragPosition.kArtikel = @Key /*AND cAuftragsNr = 'D-AU202243021'*/
     GROUP BY [tAuftragPosition].[kArtikel], [tAuftragPosition].kAuftragPosition, [tLieferscheinPos].kLieferscheinPos,
              [tAuftragPosition].fAnzahl, [tLieferscheinPos].fAnzahl, tAuftrag.cAuftragsNr, [tAuftrag].[dErstellt]) x
GROUP BY Auftragsnummer, Auftragsdatum
ORDER BY Monat ASC