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

            --DECLARE @kArtikel INT = 17984; /*9016484*/

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

            -- 3. Prüfung: Bei mehreren Lieferanten oder keinem Lieferanten -> Flag setzen
            IF @nLieferantenCount <> 1
            BEGIN
                SET @bKeineLieferantenAngepasst = 1;
            END

            -- 4. Bei genau 1 Lieferant: Daten laden und HAN prüfen
            IF @nLieferantenCount = 1
            BEGIN
                SELECT @kLieferant = tLieferant_kLieferant, @cLiefArtNr = cLiefArtNr
                FROM dbo.tLiefArtikel
                WHERE tArtikel_kArtikel = @kArtikel;

                -- Wenn HAN nicht mit Lieferanten-Artikelnummer übereinstimmt -> Flag setzen
                IF ISNULL(@cHAN, '') <> ISNULL(@cLiefArtNr, '')
                BEGIN
                    SET @bKeineLieferantenAngepasst = 1;
                END
            END

            -- 5. Insert into tGebinde (immer mit Original-Daten)
            -- WICHTIG: tGebinde.cName ist als nvarchar(255) definiert, wird von JTL aber als
            -- Fremdschlüssel auf tEinheit.kEinheit verwendet! Der Wert muss die ID der Einheit sein.
            -- Die Einheit-ID kann ermittelt werden mit:
            --   SELECT e.kEinheit, es.cName FROM dbo.tEinheit e
            --   JOIN dbo.tEinheitSprache es ON e.kEinheit = es.kEinheit WHERE es.cName = 'Stk.'
            -- Aktuell: 81 = "Stk." (Stück)
            INSERT INTO dbo.tGebinde (kArtikel, cUPC, cEAN, cName, fAnzahl)
            VALUES (@kArtikel, @cHAN, @cGTIN, '81', 1);

            -- 6. Update je nach Fall
            IF @bKeineLieferantenAngepasst = 1
            BEGIN
                -- Mehrere Lieferanten, kein Lieferant, oder HAN stimmt nicht überein
                UPDATE dbo.tArtikel
                SET cHAN = cHAN + '-keine-Lieferanten-angepasst',
                    cBarcode = cBarcode + '-keine-Lieferanten-angepasst'
                WHERE kArtikel = @kArtikel;
                -- Lieferanten werden NICHT angepasst
            END
            ELSE
            BEGIN
                -- Genau 1 Lieferant und HAN stimmt überein
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

-- Register the action
EXEC CustomWorkflows._CheckAction @actionName = 'spGebindeErstellen'
GO

EXEC CustomWorkflows._SetActionDisplayName @actionName = 'spGebindeErstellen',
     @displayName = 'Gebinde erstellen aus HAN/GTIN'
GO
