/****** Script for SelectTopNRows command from SSMS  ******/
SELECT TOP (1000) tAPos.cName AS 'Pos Name'
                ,tA.cHAN AS 'HAN aus Artikel'
                ,[cSeriennr] AS 'Seriennummer'
FROM [eazybusiness].[dbo].[tLagerArtikel] tLA
         LEFT JOIN Verkauf.tAuftragPosition tAPos ON tLA.kBestellPos = tAPos.kAuftragPosition
         LEFT JOIN tArtikel tA ON tAPos.kArtikel = tA.kArtikel
WHERE tAPos.kAuftrag = @Key