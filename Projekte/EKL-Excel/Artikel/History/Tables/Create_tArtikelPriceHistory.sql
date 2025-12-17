-- ============================================================================
-- Article Price History Table for EKL Excel Add-In
-- Schema: Robotico
-- ============================================================================
-- Stores ALL price changes with old and new values
-- Replaces Custom-Field "||Vergangene Preise||" parsing long-term
-- ============================================================================

-- Create schema if not exists
IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'Robotico')
    EXEC('CREATE SCHEMA Robotico');
GO

-- Create table
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'Robotico.tArtikelPriceHistory') AND type = 'U')
BEGIN
    CREATE TABLE Robotico.tArtikelPriceHistory (
        kArtikelPriceHistory INT IDENTITY(1,1) PRIMARY KEY,
        kArtikel INT NOT NULL,
        kBenutzer INT NULL,                  -- FK with SET NULL
        cBenutzerName NVARCHAR(255) NULL,    -- Denormalized (login name)

        -- Prices (Old = NULL on first capture)
        fNettoOld DECIMAL(10,2) NULL,
        fNettoNew DECIMAL(10,2) NOT NULL,
        fBruttoOld DECIMAL(10,2) NULL,
        fBruttoNew DECIMAL(10,2) NOT NULL,

        -- Metadata
        cSource NVARCHAR(50) NULL,           -- 'JTL_WORKFLOW', 'BACKEND_API', 'MIGRATION'
        dCreated DATETIME NOT NULL DEFAULT GETUTCDATE(),

        -- Foreign Keys (same strategy as LabelHistory)
        CONSTRAINT FK_PriceHistory_Artikel
            FOREIGN KEY (kArtikel) REFERENCES dbo.tArtikel(kArtikel) ON DELETE CASCADE,
        CONSTRAINT FK_PriceHistory_Benutzer
            FOREIGN KEY (kBenutzer) REFERENCES dbo.tBenutzer(kBenutzer) ON DELETE SET NULL
    );

    PRINT 'Table Robotico.tArtikelPriceHistory created successfully.';
END
ELSE
    PRINT 'Table Robotico.tArtikelPriceHistory already exists.';
GO

-- ============================================================================
-- Performance Indexes
-- ============================================================================

-- Main query index: Get price history by article ordered by date
IF NOT EXISTS (SELECT * FROM sys.indexes WHERE name = 'IX_PriceHistory_kArtikel')
BEGIN
    CREATE NONCLUSTERED INDEX IX_PriceHistory_kArtikel
    ON Robotico.tArtikelPriceHistory (kArtikel, dCreated DESC)
    INCLUDE (fNettoOld, fNettoNew, fBruttoOld, fBruttoNew, cBenutzerName);
    PRINT 'Index IX_PriceHistory_kArtikel created.';
END
GO

-- ============================================================================
-- Documentation
-- ============================================================================
--
-- Purpose:
--   Replaces Custom-Field parsing for price history
--   Better performance and type safety
--   Stores both old and new values for price change tracking
--
-- Constraint Strategy:
--   kArtikel: CASCADE DELETE → History is deleted with article (desired)
--   kBenutzer: SET NULL → When user is deleted, kBenutzer becomes NULL,
--                         but cBenutzerName retains the user info
--
-- cSource Values:
--   'JTL_WORKFLOW'  - Changed via JTL WAWI workflow
--   'BACKEND_API'   - Changed via EKL Excel Add-In backend
--   'MIGRATION'     - Imported from Custom-Field during migration
--
-- Old Values:
--   fNettoOld/fBruttoOld are NULL for the first price entry
--   Subsequent entries capture the previous price values
--
-- ============================================================================
