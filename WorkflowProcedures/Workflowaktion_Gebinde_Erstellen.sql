USE eazybusiness
GO

IF EXISTS(SELECT 1 FROM sys.procedures WHERE Name = 'spGebindeErstellen')
    DROP PROCEDURE CustomWorkflows.spGebindeErstellen
GO

CREATE PROCEDURE CustomWorkflows.spGebindeErstellen @kArtikel INT AS
BEGIN

    SET NOCOUNT ON;

    -- Diese Prozedur erstellt ein Gebinde aus einem Artikel.
    -- 1. Prüft, ob HAN und Lieferanten-Artikelnummer übereinstimmen.
    -- 2. Erstellt einen Eintrag in tGebinde mit den alten HAN/GTIN Daten.
    -- 3. Hängt "-umgezogen" an die HAN/GTIN des Artikels und des Lieferanten an.
    
    BEGIN TRY
        BEGIN TRANSACTION
            
            -- Variables to hold Article and Supplier data
            DECLARE @cHAN NVARCHAR(255);
            DECLARE @cGTIN NVARCHAR(255);
            DECLARE @kLieferant INT;
            DECLARE @cLiefArtNr NVARCHAR(255);
            DECLARE @nLieferantenCount INT;

            -- 1. Read Data from tArtikel
            SELECT @cHAN = cHAN, @cGTIN = cBarcode
            FROM dbo.tArtikel
            WHERE kArtikel = @kArtikel;

            -- 2. Read Data from tLiefArtikel and validate count
            SELECT @nLieferantenCount = COUNT(*)
            FROM dbo.tLiefArtikel
            WHERE tArtikel_kArtikel = @kArtikel;

            IF @nLieferantenCount <> 1
            BEGIN
                RAISERROR('Fehler: Es darf genau ein Lieferant für diesen Artikel hinterlegt sein.', 16, 1);
            END

            SELECT @kLieferant = tLieferant_kLieferant, @cLiefArtNr = cLiefArtNr
            FROM dbo.tLiefArtikel
            WHERE tArtikel_kArtikel = @kArtikel;

            -- 3. Validation: HAN must match Supplier Article Number
            -- Using ISNULL to handle potential NULLs, though logic implies they should exist
            IF ISNULL(@cHAN, '') <> ISNULL(@cLiefArtNr, '')
            BEGIN
                RAISERROR('Fehler: Die HAN des Artikels stimmt nicht mit der Lieferantenartikelnummer überein.', 16, 1);
            END

            -- 4. Insert into tGebinde
            -- Assumptions on column names: kArtikel, cUPC, cGTIN, cEinheit, nMenge
            -- Mapping: UPC = Old HAN, GTIN = Old GTIN
            INSERT INTO dbo.tGebinde (kArtikel, cUPC, cEAN, cName, fAnzahl)
            VALUES (@kArtikel, @cHAN, @cGTIN, 'Stück', 1);

            -- 5. Update tArtikel (THTecke)
            -- Append '-umgezogen' to HAN and GTIN
            UPDATE dbo.tArtikel
            SET cHAN = cHAN + '-umgezogen',
                cBarcode = cBarcode + '-umgezogen'
            WHERE kArtikel = @kArtikel;

            -- 6. Update tLiefArtikel (Supplier)
            -- Append '-umgezogen' to Supplier Article Number
            UPDATE dbo.tLiefArtikel
            SET cLiefArtNr = cLiefArtNr + '-umgezogen'
            WHERE tArtikel_kArtikel = @kArtikel AND tLieferant_kLieferant = @kLieferant;

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

-- Register the action
EXEC CustomWorkflows._CheckAction @actionName = 'spGebindeErstellen'
GO

EXEC CustomWorkflows._SetActionDisplayName @actionName = 'spGebindeErstellen',
     @displayName = 'Gebinde erstellen aus HAN/GTIN'
GO
