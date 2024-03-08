/****** Script for SelectTopNRows command from SSMS  ******/
SELECT TOP (1000) [kPicklistePos]
      ,[kPickliste]
      ,[tPicklistePos].[kWarenLager]
      ,[kWarenLagerEingang]
      ,[tPicklistePos].[fAnzahl]
      ,[kBestellPos]
      ,[kPicklistePosStatus]
      ,[tPicklistePos].[kArtikel]
      ,[kWarenlagerPlatz]
      ,[kBestellung]
      ,[nPickPrio]
	  ,cName
	  ,[cAuftragsNr]
  FROM [eazybusiness].[dbo].[tPicklistePos]
  JOIN [eazybusiness].[Verkauf].[tAuftragPosition] ON tPicklistePos.kBestellPos = [tAuftragPosition].kAuftragPosition
  JOIN [eazybusiness].[Verkauf].[tAuftrag] ON tAuftrag.kAuftrag = [tAuftragPosition].kAuftrag
  WHERE kPickliste = 76806
  ORDER BY kArtikel, [tPicklistePos].[kWarenLager] ASC