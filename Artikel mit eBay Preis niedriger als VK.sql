-- Declare the variable to be used.
DECLARE @ProvisionBis200 FLOAT;
SET @ProvisionBis200 = 0.8572;
DECLARE @ProvisionAb200 FLOAT;
SET @ProvisionAb200 = 0.9762;
DECLARE @Grenzwert FLOAT;
SET @Grenzwert = 171.44;

/****** Script for SelectTopNRows command from SSMS  ******/
SELECT * FROM (
	SELECT *, ebayBrutto - vkBrutto AS vkDifferenceBrutto, ebayBrutto - minVkEbayButto as margeBrutto, (ebayBrutto - minVkEbayButto) / (minVkEbayButto + 0.0001) * 100 as margeAufschlagProzent
	FROM (
		SELECT [ebay_item].[kArtikel], [ebay_item].[kItem], [cName], [cArtNr], [ItemID], [fEKNetto], ROUND([fVKNetto] * 1.19, 4) AS vkBrutto, [StartPrice] AS ebayBrutto,
		(SELECT MAX(Price) FROM (VALUES ([fEKNetto] * 1.19 - @Grenzwert), (0)) AS AllPrices(Price)) / @ProvisionAb200 +
		(SELECT MIN(Price) FROM (VALUES ([fEKNetto] * 1.19),(@Grenzwert)) AS AllPrices(Price)) / @ProvisionBis200
		as minVkEbayButto, nVariationenAktiv, [nAutomatischEinstellen]
		FROM [eazybusiness].[dbo].[ebay_item]
		INNER JOIN [eazybusiness].[dbo].[tArtikel] ON [ebay_item].[kArtikel]=[tArtikel].[kArtikel] AND /*Nur aktive Artikel*/ [cAktiv] = 'Y'
		LEFT JOIN [tArtikelBeschreibung] ON [tArtikelBeschreibung].[kArtikel]=[tArtikel].[kArtikel] AND [tArtikelBeschreibung].kSprache = 1
	) x
) x
WHERE (ItemID != '' OR [nAutomatischEinstellen] != 0) AND margeAufschlagProzent < 10
ORDER BY margeAufschlagProzent