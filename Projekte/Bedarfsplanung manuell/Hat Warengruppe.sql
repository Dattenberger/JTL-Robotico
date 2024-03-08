use eazybusiness

DECLARE @kWarengruppe INT = 35;
DECLARE @kAuftrag INT = 139076

SELECT CASE
WHEN EXISTS (SELECT *
FROM Verkauf.vAuftrag vA
LEFT JOIN Verkauf.lvAuftragsposition lAP on vA.kAuftrag = lAP.kAuftrag
LEFT JOIN dbo.tArtikel tArt on lAP.kArtikel = tArt.kArtikel
WHERE vA.kAuftrag = @kAuftrag
AND tArt.kWarengruppe = @kWarengruppe)
THEN 'true'
ELSE 'false'
END