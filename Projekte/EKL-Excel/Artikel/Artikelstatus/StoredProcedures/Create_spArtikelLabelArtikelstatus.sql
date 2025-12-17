-- ============================================================================
-- Artikelstatus Label Processing Stored Procedure
-- Schema: Robotico
-- ============================================================================
-- Processes AS:/ASO: labels and applies corresponding settings:
--   - Oversell (nPufferTyp, nPuffer, tPlattformUeberverkaeufeMoeglich)
--   - Online Status (cInet)
--   - eBay Auto-List (ebay_item.nAutomatischEinstellen)
-- ============================================================================
-- Workflow Name: "Artikelstatus-Label verarbeiten"
-- Trigger: JTL Workflow on label change (AS:% or ASO:%)
-- ============================================================================

-- Create schema if not exists
IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'Robotico')
    EXEC('CREATE SCHEMA Robotico');
GO

-- Drop procedure if exists (for updates)
IF OBJECT_ID('Robotico.spArtikelLabelArtikelstatus', 'P') IS NOT NULL
    DROP PROCEDURE Robotico.spArtikelLabelArtikelstatus;
GO

CREATE PROCEDURE Robotico.spArtikelLabelArtikelstatus
    @kArtikel INT,
    @kBenutzer INT = NULL,
    @cBenutzerName NVARCHAR(255) = NULL,
    @cSource NVARCHAR(50) = 'JTL_WORKFLOW'
AS
BEGIN
    SET NOCOUNT ON;

    -- ========================================================================
    -- Phase Configuration Table
    -- ========================================================================
    DECLARE @PhaseConfig TABLE (
        cLabelName NVARCHAR(255),
        nPhaseOrder INT,           -- Lower = earlier in lifecycle
        bOversellEnabled BIT,
        bOnlineEnabled BIT,
        bEbayEnabled BIT
    );

    INSERT INTO @PhaseConfig VALUES
        ('AS: Artikel Neu',           10, 0, 0, 0),  -- New: nothing enabled
        ('AS: Orderartikel',          20, 1, 1, 1),  -- Order: everything enabled
        ('AS: Aktionsartikel',        30, 0, 1, 1),  -- Action: online+eBay, no oversell
        ('AS: Abverkauf',             40, 0, 1, 1),  -- Selling off: online+eBay, no oversell
        ('AS: BW Nachteilig',         45, 0, 1, 1),  -- Disadvantageous: online+eBay, no oversell
        ('AS: Nicht Nachbestellbar',  50, 0, 1, 1),  -- Not reorderable: online+eBay, no oversell
        ('AS: Deaktiviert',           60, 0, 0, 0);  -- Deactivated: nothing enabled

    -- ========================================================================
    -- Variables
    -- ========================================================================
    DECLARE @ActiveASLabel NVARCHAR(255) = NULL;
    DECLARE @ActiveASLabelId INT = NULL;
    DECLARE @bOversellEnabled BIT = 0;
    DECLARE @bOnlineEnabled BIT = 0;
    DECLARE @bEbayEnabled BIT = 0;

    -- Override flags
    DECLARE @bOversellOverride BIT = 0;  -- ASO: Überverkäufe deaktivieren
    DECLARE @bOfflineOverride BIT = 0;   -- ASO: Offline

    -- Final settings (after applying overrides)
    DECLARE @FinalOversell BIT;
    DECLARE @FinalOnline BIT;
    DECLARE @FinalEbay BIT;

    -- Label IDs for overrides
    DECLARE @kLabelOversellOverride INT;
    DECLARE @kLabelOfflineOverride INT;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- ====================================================================
        -- Step 1: Get Override Label IDs
        -- ====================================================================
        SELECT @kLabelOversellOverride = kLabel FROM dbo.tLabel
        WHERE cName = 'ASO: Überverkäufe deaktivieren' AND nTyp = 3;

        SELECT @kLabelOfflineOverride = kLabel FROM dbo.tLabel
        WHERE cName = 'ASO: Offline' AND nTyp = 3;

        -- ====================================================================
        -- Step 2: Get all current AS: labels for this article
        -- ====================================================================
        DECLARE @CurrentASLabels TABLE (
            kLabel INT,
            cLabelName NVARCHAR(255),
            dLastSet DATETIME2 NULL,
            nPhaseOrder INT
        );

        INSERT INTO @CurrentASLabels (kLabel, cLabelName, nPhaseOrder)
        SELECT
            al.kLabel,
            l.cName,
            pc.nPhaseOrder
        FROM dbo.tArtikelLabel al
        INNER JOIN dbo.tLabel l ON al.kLabel = l.kLabel
        INNER JOIN @PhaseConfig pc ON l.cName = pc.cLabelName
        WHERE al.kArtikel = @kArtikel;

        -- Get last SET timestamp from history for each label
        UPDATE cal
        SET dLastSet = (
            SELECT TOP 1 dCreated
            FROM Robotico.tArtikelLabelHistory h
            WHERE h.kArtikel = @kArtikel
              AND h.kLabel = cal.kLabel
              AND h.cAction = 'SET'
            ORDER BY dCreated DESC
        )
        FROM @CurrentASLabels cal;

        -- ====================================================================
        -- Step 3: Conflict Resolution - Only one AS: label allowed
        -- ====================================================================
        DECLARE @ASLabelCount INT = (SELECT COUNT(*) FROM @CurrentASLabels);

        IF @ASLabelCount > 1
        BEGIN
            -- Multiple AS: labels found - keep only the most recent one
            -- Primary: Most recently set (dLastSet DESC)
            -- Secondary (tie-breaker): Lower phase order wins (nPhaseOrder ASC)
            -- Tertiary (NULL timestamps): Lower phase order wins

            SELECT TOP 1
                @ActiveASLabel = cLabelName,
                @ActiveASLabelId = kLabel
            FROM @CurrentASLabels
            ORDER BY
                CASE WHEN dLastSet IS NULL THEN 1 ELSE 0 END,  -- NULLs last
                dLastSet DESC,
                nPhaseOrder ASC;

            -- Remove all other AS: labels
            DELETE al
            FROM dbo.tArtikelLabel al
            INNER JOIN @CurrentASLabels cal ON al.kLabel = cal.kLabel
            WHERE al.kArtikel = @kArtikel
              AND al.kLabel <> @ActiveASLabelId;

            -- Log removed labels to history
            INSERT INTO Robotico.tArtikelLabelHistory (
                kArtikel, kLabel, cLabelName, cAction, kBenutzer, cBenutzerName, cSource, dCreated
            )
            SELECT
                @kArtikel,
                cal.kLabel,
                cal.cLabelName,
                'REMOVED',
                @kBenutzer,
                @cBenutzerName,
                @cSource + '_CONFLICT_RESOLUTION',
                GETDATE()
            FROM @CurrentASLabels cal
            WHERE cal.kLabel <> @ActiveASLabelId;

            PRINT 'Conflict resolved: Kept "' + @ActiveASLabel + '", removed ' +
                  CAST(@ASLabelCount - 1 AS VARCHAR(10)) + ' conflicting AS: label(s).';
        END
        ELSE IF @ASLabelCount = 1
        BEGIN
            -- Single AS: label - use it
            SELECT TOP 1
                @ActiveASLabel = cLabelName,
                @ActiveASLabelId = kLabel
            FROM @CurrentASLabels;
        END
        -- @ASLabelCount = 0: Handled in Step 5 (Initial Status)

        -- ====================================================================
        -- Step 4: Check Override Labels (ASO:)
        -- ====================================================================
        IF EXISTS (
            SELECT 1 FROM dbo.tArtikelLabel
            WHERE kArtikel = @kArtikel AND kLabel = @kLabelOversellOverride
        )
            SET @bOversellOverride = 1;

        IF EXISTS (
            SELECT 1 FROM dbo.tArtikelLabel
            WHERE kArtikel = @kArtikel AND kLabel = @kLabelOfflineOverride
        )
            SET @bOfflineOverride = 1;

        -- ====================================================================
        -- Step 5: Initial Status Assignment (if no AS: label)
        -- ====================================================================
        IF @ActiveASLabel IS NULL
        BEGIN
            -- Determine initial status based on article state
            DECLARE @cInet CHAR(1);
            DECLARE @bCurrentOversell BIT;

            SELECT
                @cInet = cInet,
                @bCurrentOversell = CASE
                    WHEN nPufferTyp > 0 OR EXISTS (
                        SELECT 1 FROM dbo.tPlattformUeberverkaeufeMoeglich
                        WHERE kArtikel = @kArtikel
                    ) THEN 1 ELSE 0
                END
            FROM dbo.tArtikel
            WHERE kArtikel = @kArtikel;

            -- Logic: cInet='N' → Artikel Neu
            --        cInet='Y' + Oversell → Orderartikel
            --        cInet='Y' + no Oversell → Aktionsartikel
            IF @cInet = 'N'
                SET @ActiveASLabel = 'AS: Artikel Neu';
            ELSE IF @bCurrentOversell = 1
                SET @ActiveASLabel = 'AS: Orderartikel';
            ELSE
                SET @ActiveASLabel = 'AS: Aktionsartikel';

            -- Get label ID
            SELECT @ActiveASLabelId = kLabel
            FROM dbo.tLabel
            WHERE cName = @ActiveASLabel AND nTyp = 3;

            -- Insert the label
            IF @ActiveASLabelId IS NOT NULL AND NOT EXISTS (
                SELECT 1 FROM dbo.tArtikelLabel
                WHERE kArtikel = @kArtikel AND kLabel = @ActiveASLabelId
            )
            BEGIN
                INSERT INTO dbo.tArtikelLabel (kArtikel, kLabel)
                VALUES (@kArtikel, @ActiveASLabelId);

                -- Write history entry for initial status
                INSERT INTO Robotico.tArtikelLabelHistory (
                    kArtikel, kLabel, cLabelName, cAction, kBenutzer, cBenutzerName, cSource, dCreated
                )
                VALUES (
                    @kArtikel,
                    @ActiveASLabelId,
                    @ActiveASLabel,
                    'SET',
                    @kBenutzer,
                    @cBenutzerName,
                    @cSource + '_INITIAL_STATUS',
                    GETDATE()
                );

                PRINT 'Initial status assigned: ' + @ActiveASLabel;
            END
        END

        -- ====================================================================
        -- Step 6: Get Phase Configuration
        -- ====================================================================
        IF @ActiveASLabel IS NOT NULL
        BEGIN
            SELECT
                @bOversellEnabled = bOversellEnabled,
                @bOnlineEnabled = bOnlineEnabled,
                @bEbayEnabled = bEbayEnabled
            FROM @PhaseConfig
            WHERE cLabelName = @ActiveASLabel;
        END

        -- ====================================================================
        -- Step 7: Apply Overrides
        -- ====================================================================
        SET @FinalOversell = CASE WHEN @bOversellOverride = 1 THEN 0 ELSE @bOversellEnabled END;
        SET @FinalOnline = CASE WHEN @bOfflineOverride = 1 THEN 0 ELSE @bOnlineEnabled END;
        SET @FinalEbay = CASE WHEN @bOfflineOverride = 1 THEN 0 ELSE @bEbayEnabled END;

        -- ====================================================================
        -- Step 8: Execute Actions
        -- ====================================================================

        -- 8a: Update Oversell Settings
        IF @FinalOversell = 1
        BEGIN
            -- Enable oversell: nPufferTyp = 1 (relative), nPuffer = 100 (100%)
            UPDATE dbo.tArtikel
            SET nPufferTyp = 1, nPuffer = 100
            WHERE kArtikel = @kArtikel;

            -- Enable platform oversell
            IF NOT EXISTS (SELECT 1 FROM dbo.tPlattformUeberverkaeufeMoeglich WHERE kArtikel = @kArtikel AND nPlattform = 1)
                INSERT INTO dbo.tPlattformUeberverkaeufeMoeglich (kArtikel, nPlattform) VALUES (@kArtikel, 1); -- Shop

            IF NOT EXISTS (SELECT 1 FROM dbo.tPlattformUeberverkaeufeMoeglich WHERE kArtikel = @kArtikel AND nPlattform = 2)
                INSERT INTO dbo.tPlattformUeberverkaeufeMoeglich (kArtikel, nPlattform) VALUES (@kArtikel, 2); -- eBay
        END
        ELSE
        BEGIN
            -- Disable oversell
            UPDATE dbo.tArtikel
            SET nPufferTyp = 0, nPuffer = 0
            WHERE kArtikel = @kArtikel;

            -- Remove platform oversell entries
            DELETE FROM dbo.tPlattformUeberverkaeufeMoeglich
            WHERE kArtikel = @kArtikel;
        END

        -- 8b: Update Online Status
        UPDATE dbo.tArtikel
        SET cInet = CASE WHEN @FinalOnline = 1 THEN 'Y' ELSE 'N' END
        WHERE kArtikel = @kArtikel;

        -- 8c: Update eBay Auto-List
        -- Note: ebay_item table may not exist or article may not have eBay listing
        IF OBJECT_ID('dbo.ebay_item', 'U') IS NOT NULL
        BEGIN
            UPDATE dbo.ebay_item
            SET nAutomatischEinstellen = @FinalEbay
            WHERE kArtikel = @kArtikel;
        END

        -- ====================================================================
        -- Step 9: Commit and Report
        -- ====================================================================
        COMMIT TRANSACTION;

        PRINT '============================================================================';
        PRINT 'Artikelstatus processed for kArtikel=' + CAST(@kArtikel AS VARCHAR(10));
        PRINT 'Active Phase: ' + ISNULL(@ActiveASLabel, 'NONE');
        PRINT 'Oversell Override: ' + CASE WHEN @bOversellOverride = 1 THEN 'YES' ELSE 'NO' END;
        PRINT 'Offline Override: ' + CASE WHEN @bOfflineOverride = 1 THEN 'YES' ELSE 'NO' END;
        PRINT '----------------------------------------------------------------------------';
        PRINT 'Final Settings:';
        PRINT '  Oversell: ' + CASE WHEN @FinalOversell = 1 THEN 'ENABLED' ELSE 'DISABLED' END;
        PRINT '  Online: ' + CASE WHEN @FinalOnline = 1 THEN 'YES' ELSE 'NO' END;
        PRINT '  eBay: ' + CASE WHEN @FinalEbay = 1 THEN 'ENABLED' ELSE 'DISABLED' END;
        PRINT '============================================================================';

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();
        DECLARE @ErrorState INT = ERROR_STATE();

        PRINT 'ERROR processing Artikelstatus for kArtikel=' + CAST(@kArtikel AS VARCHAR(10));
        PRINT 'Error: ' + @ErrorMessage;

        RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);
    END CATCH
END
GO

-- ============================================================================
-- Usage Examples
-- ============================================================================
-- Called from JTL Workflow "Artikelstatus-Label verarbeiten":
--
-- EXEC Robotico.spArtikelLabelArtikelstatus
--     @kArtikel = {{ Artikel.Schluessel }},
--     @kBenutzer = {{ Benutzer.Schluessel }},
--     @cBenutzerName = '{{ Benutzer.Login }}',
--     @cSource = 'JTL_WORKFLOW';
--
-- Manual testing:
-- EXEC Robotico.spArtikelLabelArtikelstatus @kArtikel = 12345;
-- ============================================================================

PRINT 'Stored Procedure Robotico.spArtikelLabelArtikelstatus created successfully.';
GO
