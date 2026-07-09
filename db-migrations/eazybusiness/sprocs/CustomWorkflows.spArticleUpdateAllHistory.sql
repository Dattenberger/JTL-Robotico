-- ============================================================================
-- CustomWorkflows.spArticleUpdateAllHistory — JTL action: update all histories
-- ============================================================================
-- Custom workflow action. Runs both the price and label history actions for an
-- article; each is wrapped in TRY/CATCH so a failure in one still lets the other
-- run (errors surface as low-severity RAISERROR, not an abort).
--
-- Ported from WorkflowProcedures/history/spArticleUpdateAllHistory.sql (2026-07-10).
-- ============================================================================

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

-- Registration (see db-migrations/README.md §6). Guarded module-provided helpers.
IF OBJECT_ID('CustomWorkflows._CheckAction', 'P') IS NOT NULL
    EXEC CustomWorkflows._CheckAction @actionName = 'spArticleUpdateAllHistory';
ELSE
    PRINT '! CustomWorkflows._CheckAction missing — Custom Workflow Actions module not booked; skipping validation.';
GO

IF OBJECT_ID('CustomWorkflows._SetActionDisplayName', 'P') IS NOT NULL
    EXEC CustomWorkflows._SetActionDisplayName
        @actionName = 'spArticleUpdateAllHistory',
        @displayName = 'Historie: Alle aktualisieren';
ELSE
    PRINT '! CustomWorkflows._SetActionDisplayName missing — module not booked; skipping label registration.';
GO
