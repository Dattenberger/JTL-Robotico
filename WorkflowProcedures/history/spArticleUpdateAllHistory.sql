USE eazybusiness
GO

IF EXISTS(SELECT 1 FROM sys.procedures WHERE Name = 'spArticleUpdateAllHistory' AND schema_id = SCHEMA_ID('CustomWorkflows'))
    DROP PROCEDURE CustomWorkflows.spArticleUpdateAllHistory
GO

CREATE PROCEDURE CustomWorkflows.spArticleUpdateAllHistory
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

EXEC CustomWorkflows._CheckAction @actionName = 'spArticleUpdateAllHistory'
GO

EXEC CustomWorkflows._SetActionDisplayName
    @actionName = 'spArticleUpdateAllHistory',
    @displayName = 'Historie: Alle aktualisieren'
GO
