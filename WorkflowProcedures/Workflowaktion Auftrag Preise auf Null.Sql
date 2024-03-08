--Auftrag Preise Auf Null -> U.a. für Interne Aufträge

IF EXISTS(SELECT 1
          FROM sys.procedures
          WHERE Name = 'spAuftragPreiseAufNull')
    DROP PROCEDURE CustomWorkflows.spAuftragPreiseAufNull
GO;

CREATE PROCEDURE CustomWorkflows.spAuftragPreiseAufNull @kAuftrag INT AS
BEGIN
    BEGIN
        Update AP
        SET fEkNetto = 0,
            fVkNetto= 0
        From Verkauf.tAuftragPosition AP
                 LEFT JOIN Rechnung.tRechnungPosition RP ON AP  .kAuftragPosition = RP.kAuftragPosition
        WHERE AP.kAuftrag = @kAuftrag
          AND RP.kRechnungPosition IS NULL
    END

    BEGIN
        declare @auftrag Verkauf.TYPE_spAuftragEckdatenBerechnen
        insert into @auftrag values (@kAuftrag)
        exec Verkauf.spAuftragEckdatenBerechnen @auftrag
    END
END
GO;

EXEC CustomWorkflows._CheckAction @actionName = 'auftragPreiseNull'
GO;

EXEC CustomWorkflows._SetActionDisplayName @actionName = 'spAuftragPreiseAufNull', @displayName = "Auftrag Preise auf Null setzen"
GO;