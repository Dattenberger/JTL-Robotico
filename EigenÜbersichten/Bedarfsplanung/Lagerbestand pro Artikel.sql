/****** Script for SelectTopNRows command from SSMS  ******/

DECLARE @Key INTEGER = 305

SELECT
[wl].[cKuerzel],
FORMAT([v].[fBestand], '0.##')
FROM [tlagerbestandProLagerLagerartikel] [v]
JOIN dbo.[tArtikel] [a] ON [a].[kArtikel] = [v].kArtikel
JOIN dbo.[tWarenLager] [wl] ON [wl].[kWarenLager] = [v].[kWarenlager]
WHERE a.kArtikel = @Key
ORDER BY cBeschreibung ASC;