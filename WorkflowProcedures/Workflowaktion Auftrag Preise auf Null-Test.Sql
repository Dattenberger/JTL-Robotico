DECLARE @kAuftrag AS INT = 74567;

BEGIN
    BEGIN
        Update AP
        SET fEkNetto = 0,
            fVkNetto= 0
        From Verkauf.tAuftragPosition AP
                 LEFT JOIN Rechnung.tRechnungPosition RP ON AP.kAuftragPosition = RP.kAuftragPosition
        WHERE AP.kAuftrag = @kAuftrag
          AND RP.kRechnungPosition IS NULL
    END

    BEGIN
        declare @auftrag Verkauf.TYPE_spAuftragEckdatenBerechnen
        insert into @auftrag values (@kAuftrag)
        exec Verkauf.spAuftragEckdatenBerechnen @auftrag
    END
END