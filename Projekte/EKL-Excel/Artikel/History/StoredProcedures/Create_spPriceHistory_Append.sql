-- ============================================================================
-- Price History Append Stored Procedure
-- Schema: Robotico
-- ============================================================================
-- Appends a price change entry to tArtikelPriceHistory
-- Automatically retrieves old price values from latest entry or tArtikel
-- ============================================================================

-- Create schema if not exists
IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'Robotico')
    EXEC('CREATE SCHEMA Robotico');
GO

-- Drop procedure if exists (for updates)
IF OBJECT_ID('Robotico.spPriceHistory_Append', 'P') IS NOT NULL
    DROP PROCEDURE Robotico.spPriceHistory_Append;
GO

CREATE PROCEDURE Robotico.spPriceHistory_Append
    @kArtikel INT,
    @kBenutzer INT = NULL,
    @cBenutzerName NVARCHAR(255) = NULL,
    @fNettoNew DECIMAL(10,2),
    @fBruttoNew DECIMAL(10,2),
    @cSource NVARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @fNettoOld DECIMAL(10,2);
    DECLARE @fBruttoOld DECIMAL(10,2);
    DECLARE @existingCount INT;

    BEGIN TRY
        -- Get the most recent price entry for this article
        SELECT TOP 1
            @fNettoOld = fNettoNew,
            @fBruttoOld = fBruttoNew
        FROM Robotico.tArtikelPriceHistory
        WHERE kArtikel = @kArtikel
        ORDER BY dCreated DESC;

        -- If no history exists, get current price from tArtikel
        IF @fNettoOld IS NULL
        BEGIN
            SELECT
                @fNettoOld = fVKNetto,
                @fBruttoOld = fVKBrutto  -- Note: fVKBrutto may need to be calculated
            FROM dbo.tArtikel
            WHERE kArtikel = @kArtikel;
        END

        -- Only insert if price actually changed (or if it's the first entry)
        IF @fNettoOld IS NULL OR @fNettoOld <> @fNettoNew OR @fBruttoOld <> @fBruttoNew
        BEGIN
            INSERT INTO Robotico.tArtikelPriceHistory (
                kArtikel,
                kBenutzer,
                cBenutzerName,
                fNettoOld,
                fNettoNew,
                fBruttoOld,
                fBruttoNew,
                cSource,
                dCreated
            )
            VALUES (
                @kArtikel,
                @kBenutzer,
                @cBenutzerName,
                @fNettoOld,
                @fNettoNew,
                @fBruttoOld,
                @fBruttoNew,
                @cSource,
                GETUTCDATE()
            );

            PRINT 'Price history entry created for kArtikel=' + CAST(@kArtikel AS VARCHAR(10));
        END
        ELSE
        BEGIN
            PRINT 'Price unchanged, no history entry created.';
        END
    END TRY
    BEGIN CATCH
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();
        DECLARE @ErrorState INT = ERROR_STATE();

        RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);
    END CATCH
END
GO

-- ============================================================================
-- Usage Examples
-- ============================================================================
-- EXEC Robotico.spPriceHistory_Append
--     @kArtikel = 12345,
--     @kBenutzer = 1,
--     @cBenutzerName = 'Admin',
--     @fNettoNew = 99.99,
--     @fBruttoNew = 118.99,
--     @cSource = 'JTL_WORKFLOW';
-- ============================================================================

PRINT 'Stored Procedure Robotico.spPriceHistory_Append created successfully.';
GO
