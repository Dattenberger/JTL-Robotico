-- ============================================================================
-- Add Foreign Key Constraints to tArtikelCommentary
-- Schema: Robotico
-- ============================================================================
-- Adds proper FK constraints with CASCADE DELETE on kArtikel
-- and SET NULL on kBenutzer/kUserModified
-- ============================================================================

-- Add FK for kArtikel with CASCADE DELETE
-- (When article is deleted, comments are also deleted)
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_Commentary_Artikel')
BEGIN
    ALTER TABLE Robotico.tArtikelCommentary
    ADD CONSTRAINT FK_Commentary_Artikel
        FOREIGN KEY (kArtikel) REFERENCES dbo.tArtikel(kArtikel) ON DELETE CASCADE;
    PRINT 'FK_Commentary_Artikel created';
END
ELSE
    PRINT 'FK_Commentary_Artikel already exists';
GO

-- Add FK for kBenutzer with SET NULL
-- (When user is deleted, kBenutzer becomes NULL but cContext remains)
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_Commentary_Benutzer')
BEGIN
    ALTER TABLE Robotico.tArtikelCommentary
    ADD CONSTRAINT FK_Commentary_Benutzer
        FOREIGN KEY (kBenutzer) REFERENCES dbo.tBenutzer(kBenutzer) ON DELETE SET NULL;
    PRINT 'FK_Commentary_Benutzer created';
END
ELSE
    PRINT 'FK_Commentary_Benutzer already exists';
GO

-- Add FK for kUserModified with SET NULL
-- (When user is deleted, kUserModified becomes NULL but comment history remains)
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_Commentary_UserModified')
BEGIN
    ALTER TABLE Robotico.tArtikelCommentary
    ADD CONSTRAINT FK_Commentary_UserModified
        FOREIGN KEY (kUserModified) REFERENCES dbo.tBenutzer(kBenutzer) ON DELETE SET NULL;
    PRINT 'FK_Commentary_UserModified created';
END
ELSE
    PRINT 'FK_Commentary_UserModified already exists';
GO

PRINT 'All Commentary FK constraints processed successfully.';
