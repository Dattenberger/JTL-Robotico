-- ============================================================================
-- Article Label History Table for EKL Excel Add-In
-- Schema: Robotico
-- ============================================================================
-- Stores ALL label changes (SET + REMOVED) for ALL labels
-- Replaces Custom-Field "||Vergangene Label||" parsing long-term
-- ============================================================================

-- Create schema if not exists
IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'Robotico')
    EXEC('CREATE SCHEMA Robotico');
GO

-- Drop table if exists (for development - remove in production!)
-- IF OBJECT_ID('Robotico.tArtikelLabelHistory', 'U') IS NOT NULL
--     DROP TABLE Robotico.tArtikelLabelHistory;
-- GO

-- Create table
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'Robotico.tArtikelLabelHistory') AND type = 'U')
BEGIN
    CREATE TABLE Robotico.tArtikelLabelHistory (
        kArtikelLabelHistory INT IDENTITY(1,1) PRIMARY KEY,
        kArtikel INT NOT NULL,
        kLabel INT NOT NULL,
        cLabelName NVARCHAR(255) NULL,       -- Denormalized for performance (label name at time of event)
        cAction NVARCHAR(10) NOT NULL,       -- 'SET' or 'REMOVED'
        kBenutzer INT NULL,                  -- FK with SET NULL (user info remains in cBenutzerName)
        cBenutzerName NVARCHAR(255) NULL,    -- Denormalized (login name)
        cSource NVARCHAR(50) NULL,           -- 'JTL_WORKFLOW', 'BACKEND_API', 'MIGRATION'
        dCreated DATETIME2 NOT NULL DEFAULT GETDATE(),

        -- Optional: Snapshot of all labels at this point (for state reconstruction)
        cLabelsSnapshot NVARCHAR(MAX) NULL,  -- JSON: ["Label1", "Label2", ...]

        -- Constraints
        CONSTRAINT CK_LabelHistory_Action CHECK (cAction IN ('SET', 'REMOVED')),

        -- Foreign Keys with different delete behaviors
        CONSTRAINT FK_LabelHistory_Artikel
            FOREIGN KEY (kArtikel) REFERENCES dbo.tArtikel(kArtikel) ON DELETE CASCADE,
        CONSTRAINT FK_LabelHistory_Benutzer
            FOREIGN KEY (kBenutzer) REFERENCES dbo.tBenutzer(kBenutzer) ON DELETE SET NULL
    );

    PRINT 'Table Robotico.tArtikelLabelHistory created successfully.';
END
ELSE
    PRINT 'Table Robotico.tArtikelLabelHistory already exists.';
GO

-- ============================================================================
-- Performance Indexes
-- ============================================================================

-- Main query index: Get history by article ordered by date
IF NOT EXISTS (SELECT * FROM sys.indexes WHERE name = 'IX_LabelHistory_Artikel_Created')
BEGIN
    CREATE NONCLUSTERED INDEX IX_LabelHistory_Artikel_Created
    ON Robotico.tArtikelLabelHistory (kArtikel, dCreated DESC)
    INCLUDE (kLabel, cLabelName, cAction, cBenutzerName);
    PRINT 'Index IX_LabelHistory_Artikel_Created created.';
END
GO

-- Index for "most recent SET wins" conflict resolution
IF NOT EXISTS (SELECT * FROM sys.indexes WHERE name = 'IX_LabelHistory_Artikel_Label_Action')
BEGIN
    CREATE NONCLUSTERED INDEX IX_LabelHistory_Artikel_Label_Action
    ON Robotico.tArtikelLabelHistory (kArtikel, kLabel, cAction, dCreated DESC);
    PRINT 'Index IX_LabelHistory_Artikel_Label_Action created.';
END
GO

-- Index for label-based lookups (e.g., "all articles with this label")
IF NOT EXISTS (SELECT * FROM sys.indexes WHERE name = 'IX_LabelHistory_kLabel')
BEGIN
    CREATE NONCLUSTERED INDEX IX_LabelHistory_kLabel
    ON Robotico.tArtikelLabelHistory (kLabel)
    INCLUDE (kArtikel, dCreated);
    PRINT 'Index IX_LabelHistory_kLabel created.';
END
GO

-- ============================================================================
-- Documentation
-- ============================================================================
--
-- Purpose:
--   Enables "most recently set label wins" for Artikelstatus conflict resolution
--   Complete label history for ALL labels (not just AS:/ASO:)
--   SET + REMOVED events enable state reconstruction
--   Replaces Custom-Field parsing long-term
--
-- Constraint Strategy:
--   kArtikel: CASCADE DELETE → History is deleted with article (desired)
--   kBenutzer: SET NULL → When user is deleted, kBenutzer becomes NULL,
--                         but cBenutzerName retains the user info
--
-- Action Values:
--   'SET'     - Label was added to the article
--   'REMOVED' - Label was removed from the article
--
-- cSource Values:
--   'JTL_WORKFLOW'  - Changed via JTL WAWI workflow
--   'BACKEND_API'   - Changed via EKL Excel Add-In backend
--   'MIGRATION'     - Imported from Custom-Field during migration
--
-- cLabelsSnapshot:
--   Optional JSON array of all labels at the time of this event
--   Enables full state reconstruction without replaying event history
--   Format: ["Label1", "Label2", "AS: Orderartikel"]
--
-- ============================================================================
