DECLARE @Key AS INT = 74567;

SELECT * from Verkauf.tAuftragPosition AP
         LEFT JOIN Rechnung.tRechnungPosition RP ON AP.kAuftragPosition = RP.kAuftragPosition
WHERE AP.kAuftrag = @Key AND RP.kRechnungPosition IS NULL