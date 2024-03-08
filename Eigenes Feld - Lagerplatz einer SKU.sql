/****** Script for SelectTopNRows command from SSMS  ******/
SELECT TOP (1000) [tArtikelAttribut].[kArtikelAttribut]
      /*,[tArtikelAttribut].[kArtikel]
      ,[tArtikelAttribut].[kAttribut]
	  ,[tArtikelAttribut].[kArtikel]
	  ,[cArtNr]*/
      ,[tArtikelAttributSprache].[cWertVarchar] AS Lagerplatz
  FROM [eazybusiness].[dbo].[tArtikelAttribut]
JOIN tArtikelAttributSprache ON tArtikelAttribut.kArtikelAttribut = [tArtikelAttributSprache].[kArtikelAttribut]
JOIN [tArtikel] ON [tArtikel].[kArtikel] = [tArtikelAttribut].[kArtikel]
WHERE
	kAttribut = 126 /*Lagerplatz*/
	AND
	[cArtNr] = '9000402'
