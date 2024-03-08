/****** Script for SelectTopNRows command from SSMS  ******/
SELECT TOP (1000) [tArtikel].[kArtikel]
      ,[cArtNr]
	  ,[cName]
      ,[fVKNetto]
      ,[fUVP]
      ,[cAktiv]
      ,[fEKNetto]
      ,[fEbayPreis]
	  ,[fLagerbestand]
	  ,[fLagerbestand] * [fEKNetto] as ekGesammt
	  ,[fLagerbestand] * [fVKNetto] as vkGesammt
  FROM [eazybusiness].[dbo].[tArtikel]
  LEFT JOIN [tArtikelBeschreibung] ON [tArtikelBeschreibung].[kArtikel]=[tArtikel].[kArtikel] AND [tArtikelBeschreibung].kSprache = 1
  LEFT JOIN [eazybusiness].[dbo].[tlagerbestand] ON [tlagerbestand].[kArtikel]=[tArtikel].[kArtikel] 
  ORDER BY ekGesammt DESC