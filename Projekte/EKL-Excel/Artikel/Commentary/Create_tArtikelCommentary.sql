-- ============================================================================
-- Article Commentary Table for EKL Excel Add-In
-- Schema: Robotico (custom schema, separate from JTL's dbo)
-- ============================================================================

-- Create schema if not exists
IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'Robotico')
    EXEC('CREATE SCHEMA Robotico');
GO

-- Create table
CREATE TABLE Robotico.tArtikelCommentary(
    kArtikelCommentary  INTEGER IDENTITY(1,1) PRIMARY KEY,
    kArtikel            INTEGER NOT NULL,              -- Logical FK to dbo.tArtikel (no constraint!)
    kBenutzer           INTEGER,                       -- Logical FK to dbo.tBenutzer (no constraint!)

    cComment            NVARCHAR(2000) NOT NULL,
    cContext            NVARCHAR(50) NOT NULL,         -- 'Price', 'Label', 'General'

    dCreated            DATETIME NOT NULL DEFAULT GETUTCDATE(),
    bDeleted            BIT NOT NULL DEFAULT 0,

    -- Versioning
    kPredecessor        INTEGER,                       -- Self-reference to previous version
    nVersion            INTEGER NOT NULL DEFAULT 1,
    dModified           DATETIME,
    kUserModified       INTEGER,                       -- Logical FK to dbo.tBenutzer (no constraint!)

    -- Constraints
    CONSTRAINT CK_ArticleCommentary_Context
        CHECK (cContext IN ('Price', 'Label', 'General')),

    -- Self-referencing FK only (within our schema)
    CONSTRAINT FK_ArticleCommentary_Predecessor
        FOREIGN KEY (kPredecessor) REFERENCES Robotico.tArtikelCommentary (kArtikelCommentary)

    -- NOTE: NO foreign keys to JTL tables (dbo.tArtikel, dbo.tBenutzer)!
    -- kArtikel, kBenutzer, kUserModified are "logical" FKs only.
    -- This avoids conflicts with JTL's own processes (deletes, schema changes).
);
GO

-- ============================================================================
-- Performance Indexes
-- ============================================================================

-- Main query index: Get comments by article with optional context filter
-- Covers: WHERE kArtikel = ? AND bDeleted = 0 [AND cContext = ?]
CREATE INDEX IX_ArticleCommentary_Artikel_Context
ON Robotico.tArtikelCommentary (kArtikel, cContext)
INCLUDE (bDeleted, dCreated)
WHERE bDeleted = 0;
GO

-- Index for version chain traversal
-- Covers: WHERE kPredecessor = ? (finding successors)
CREATE INDEX IX_ArticleCommentary_Predecessor
ON Robotico.tArtikelCommentary (kPredecessor)
WHERE kPredecessor IS NOT NULL;
GO

-- ============================================================================
-- Comments / Documentation
-- ============================================================================
--
-- Context Values:
--   'Price'   - Comments related to price changes
--   'Label'   - Comments related to label changes
--   'General' - General article comments
--
-- Versioning:
--   When editing a comment, a new row is created with:
--   - kPredecessor = ID of the original comment
--   - nVersion = previous nVersion + 1
--   The original comment remains unchanged (immutable history).
--
-- Soft Delete:
--   bDeleted = 1 hides the comment, but data is retained.
--   Queries should filter by bDeleted = 0 for active comments.
--
-- No JTL FK Constraints:
--   To avoid blocking JTL's internal processes (article/user deletion),
--   we only store kArtikel/kBenutzer values without DB-level enforcement.
--   Application layer handles validation.
-- ============================================================================
