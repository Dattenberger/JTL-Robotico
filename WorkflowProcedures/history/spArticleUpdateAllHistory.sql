SET XACT_ABORT ON
GO

BEGIN TRANSACTION
GO

CREATE OR ALTER PROCEDURE CustomWorkflows.spArticleUpdateAllHistory
    @kArtikel INT,
    @userName NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ErrorMsg NVARCHAR(4000);

    BEGIN TRY
        EXEC CustomWorkflows.spArticleAppendPriceHistory @kArtikel = @kArtikel, @userName = @userName;
    END TRY
    BEGIN CATCH
        SET @ErrorMsg = ERROR_MESSAGE();
        RAISERROR('Price history failed: %s', 10, 1, @ErrorMsg) WITH NOWAIT;
    END CATCH

    BEGIN TRY
        EXEC CustomWorkflows.spArticleAppendLabelHistory @kArtikel = @kArtikel, @userName = @userName;
    END TRY
    BEGIN CATCH
        SET @ErrorMsg = ERROR_MESSAGE();
        RAISERROR('Label history failed: %s', 10, 1, @ErrorMsg) WITH NOWAIT;
    END CATCH
END
GO

IF XACT_STATE() = 1
BEGIN
    COMMIT TRANSACTION;
    PRINT '+ Stored Procedure CustomWorkflows.spArticleUpdateAllHistory deployed';

    EXEC CustomWorkflows._CheckAction @actionName = 'spArticleUpdateAllHistory';

    EXEC CustomWorkflows._SetActionDisplayName
        @actionName = 'spArticleUpdateAllHistory',
        @displayName = 'Historie: Alle aktualisieren';
END
ELSE
BEGIN
    IF XACT_STATE() = -1
        ROLLBACK TRANSACTION;
    PRINT '! DEPLOYMENT FAILED - Alle Aenderungen wurden zurueckgerollt';
END
GO
