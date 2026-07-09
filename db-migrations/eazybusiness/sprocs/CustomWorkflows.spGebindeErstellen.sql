-- ============================================================================
-- CustomWorkflows.spGebindeErstellen — JTL action: create a Gebinde from HAN/GTIN
-- ============================================================================
-- Custom workflow action. Creates a tGebinde entry from an article's HAN/GTIN and
-- appends a migration suffix to the article (and, when exactly one supplier with a
-- matching HAN exists, to the supplier article number). Atomic via TRY/CATCH.
--
-- Ported from WorkflowProcedures/Workflowaktion_Gebinde_Erstellen.sql (2026-07-10):
--   removed `USE eazybusiness`; IF EXISTS DROP + CREATE -> CREATE OR ALTER;
--   registration guarded (module-provided helpers).
-- ============================================================================

CREATE OR ALTER PROCEDURE CustomWorkflows.spGebindeErstellen @kArtikel INT AS
BEGIN

    SET NOCOUNT ON;

    -- Creates a Gebinde from an article:
    -- 1. Checks whether HAN and supplier article number match.
    -- 2. Creates a tGebinde entry with the old HAN/GTIN data.
    -- 3. Appends "-umgezogen" to the article's and supplier's HAN/GTIN.

    BEGIN TRY
        BEGIN TRANSACTION

            -- Variables to hold Article and Supplier data
            DECLARE @cHAN NVARCHAR(255);
            DECLARE @cGTIN NVARCHAR(255);
            DECLARE @kLieferant INT;
            DECLARE @cLiefArtNr NVARCHAR(255);
            DECLARE @nLieferantenCount INT;
            DECLARE @bKeineLieferantenAngepasst BIT = 0;

            -- 1. Read Data from tArtikel
            SELECT @cHAN = cHAN, @cGTIN = cBarcode
            FROM dbo.tArtikel
            WHERE kArtikel = @kArtikel;

            -- 2. Read Data from tLiefArtikel and validate count
            SELECT @nLieferantenCount = COUNT(*)
            FROM dbo.tLiefArtikel
            WHERE tArtikel_kArtikel = @kArtikel;

            -- 3. Multiple or no suppliers -> set flag
            IF @nLieferantenCount <> 1
            BEGIN
                SET @bKeineLieferantenAngepasst = 1;
            END

            -- 4. Exactly one supplier: load data and check HAN
            IF @nLieferantenCount = 1
            BEGIN
                SELECT @kLieferant = tLieferant_kLieferant, @cLiefArtNr = cLiefArtNr
                FROM dbo.tLiefArtikel
                WHERE tArtikel_kArtikel = @kArtikel;

                -- If HAN does not match the supplier article number -> set flag
                IF ISNULL(@cHAN, '') <> ISNULL(@cLiefArtNr, '')
                BEGIN
                    SET @bKeineLieferantenAngepasst = 1;
                END
            END

            -- 5. Insert into tGebinde (always with the original data)
            -- IMPORTANT: tGebinde.cName is nvarchar(255) but JTL uses it as a
            -- foreign key onto tEinheit.kEinheit! The value must be the unit ID.
            -- Currently: 81 = "Stk." (piece).
            INSERT INTO dbo.tGebinde (kArtikel, cUPC, cEAN, cName, fAnzahl)
            VALUES (@kArtikel, @cHAN, @cGTIN, '81', 1);

            -- 6. Update depending on case
            IF @bKeineLieferantenAngepasst = 1
            BEGIN
                -- Multiple suppliers, no supplier, or HAN mismatch
                UPDATE dbo.tArtikel
                SET cHAN = cHAN + '-keine-Lieferanten-angepasst',
                    cBarcode = cBarcode + '-keine-Lieferanten-angepasst'
                WHERE kArtikel = @kArtikel;
                -- Suppliers are NOT touched
            END
            ELSE
            BEGIN
                -- Exactly one supplier and HAN matches
                UPDATE dbo.tArtikel
                SET cHAN = cHAN + '-gebinde-umgezogen',
                    cBarcode = cBarcode + '-gebinde-umgezogen'
                WHERE kArtikel = @kArtikel;

                UPDATE dbo.tLiefArtikel
                SET cLiefArtNr = cLiefArtNr + '-gebinde-umgezogen'
                WHERE tArtikel_kArtikel = @kArtikel AND tLieferant_kLieferant = @kLieferant;
            END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();
        DECLARE @ErrorState INT = ERROR_STATE();

        RAISERROR (@ErrorMessage, @ErrorSeverity, @ErrorState);
    END CATCH
END
GO

-- Registration (see db-migrations/README.md §6). Guarded module-provided helpers.
IF OBJECT_ID('CustomWorkflows._CheckAction', 'P') IS NOT NULL
    EXEC CustomWorkflows._CheckAction @actionName = 'spGebindeErstellen';
ELSE
    PRINT '! CustomWorkflows._CheckAction missing — Custom Workflow Actions module not booked; skipping validation.';
GO

IF OBJECT_ID('CustomWorkflows._SetActionDisplayName', 'P') IS NOT NULL
    EXEC CustomWorkflows._SetActionDisplayName @actionName = 'spGebindeErstellen',
        @displayName = 'Gebinde erstellen aus HAN/GTIN';
ELSE
    PRINT '! CustomWorkflows._SetActionDisplayName missing — module not booked; skipping label registration.';
GO
