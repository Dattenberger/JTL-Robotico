-- ============================================================================
-- Device Verification on Spare-Part Orders (avoid wrong-part returns)
-- ============================================================================
--
-- Date:    2026-07-02
-- Version: 1.0
--
-- ============================================================================
-- PURPOSE
-- ============================================================================
--
-- Supports the process described in
-- docs/Prozesse/Geraete-Verifizierung-bei-Ersatzteilbestellung.md:
-- when an order contains a device-dependent spare part (motor, blade, battery,
-- charger, ...), a JTL workflow asks the customer which exact device/model they
-- own BEFORE shipping, to avoid returns caused by ordering the wrong part.
--
-- An article opts into the process via the custom field (Eigenes Feld / Attribut)
--   GeräteVerifizierungMail = 1
-- exactly like the existing LieferverzögerungKeineMail opt-out
-- (see Workflows/Lieferverzögerung/Artikel nicht verfügbar.sql).
--
-- ============================================================================
-- TWO OBJECTS
-- ============================================================================
--
--   Robotico.fnAuftragBrauchtGeraeteabfrage   (scalar BIT)
--       Gating truth value: 1 iff the order has >= 1 position whose article
--       carries GeräteVerifizierungMail = 1. Consumed by the advanced property
--       "Workflows/Geräte-Verifizierung/Auftrag - Braucht Geräteabfrage.liquid"
--       as a workflow CONDITION (a custom ACTION cannot gate; see
--       docs/SQL/JTL-CUSTOM-WORKFLOWS.md §5).
--
--   Robotico.fnAuftragGeraeteabfrageArtikelListe (scalar NVARCHAR(MAX))
--       Renders the affected positions as an HTML <li> list for the customer
--       e-mail body (used via DirectQueryScalar in the mail template).
--
-- ============================================================================
-- ARTICLE SELECTION (custom field lookup)
-- ============================================================================
--   dbo.tAttributSprache.cName = N'GeräteVerifizierungMail', kSprache = 0
--     -> dbo.tArtikelAttribut (kAttribut, kArtikel) -> kArtikelAttribut
--       -> dbo.tArtikelAttributSprache (kSprache = 0).nWertInt = 1
--   Only real catalogue positions are considered (kArtikel > 0), matching the
--   customer article lines nType IN (0,1) used elsewhere.
--
-- ============================================================================
-- DEPENDENCIES
-- ============================================================================
--   - Verkauf.tAuftragPosition (kAuftrag, kArtikel, cArtNr, cName, nType)
--   - dbo.tAttributSprache, dbo.tArtikelAttribut, dbo.tArtikelAttributSprache
--   - SQL Server 2017+ (STRING_AGG).
--   - Naming follows docs/SQL/NAMING-CONVENTIONS.md.
-- ============================================================================

USE [eazybusiness]
GO

SET XACT_ABORT ON
GO

BEGIN TRANSACTION
GO

-- ----------------------------------------------------------------------------
-- 1. Truth value: does the order need a device-verification e-mail?
--    1 iff >= 1 position's article has GeräteVerifizierungMail = 1.
-- ----------------------------------------------------------------------------
CREATE OR ALTER FUNCTION Robotico.fnAuftragBrauchtGeraeteabfrage
(
    @kAuftrag INT
)
RETURNS BIT
AS
BEGIN
    DECLARE @bResult BIT = 0;

    IF EXISTS (
        SELECT 1
        FROM Verkauf.tAuftragPosition        p
        JOIN dbo.tArtikelAttribut            aa   ON aa.kArtikel = p.kArtikel
        JOIN dbo.tAttributSprache            atts ON atts.kAttribut = aa.kAttribut
                                                 AND atts.cName     = N'GeräteVerifizierungMail'
                                                 AND atts.kSprache  = 0
        JOIN dbo.tArtikelAttributSprache     aas  ON aas.kArtikelAttribut = aa.kArtikelAttribut
                                                 AND aas.kSprache         = 0
        WHERE p.kAuftrag  = @kAuftrag
          AND p.kArtikel  > 0
          AND p.nType     IN (0, 1)           -- customer article lines only
          AND aas.nWertInt = 1                -- opt-in flag set
    )
        SET @bResult = 1;

    RETURN @bResult;
END;
GO
PRINT '+ Function Robotico.fnAuftragBrauchtGeraeteabfrage deployed';
GO

-- ----------------------------------------------------------------------------
-- 2. HTML <li> list of the affected positions, for the customer e-mail body.
--    Returns '' when nothing matches (mail template can guard on that).
-- ----------------------------------------------------------------------------
CREATE OR ALTER FUNCTION Robotico.fnAuftragGeraeteabfrageArtikelListe
(
    @kAuftrag INT
)
RETURNS NVARCHAR(MAX)
AS
BEGIN
    DECLARE @cList NVARCHAR(MAX);

    SELECT @cList = STRING_AGG(
               CONVERT(NVARCHAR(MAX),
                   N'<li>' + p.cName
                   + N' (Art.-Nr. ' + ISNULL(p.cArtNr, N'') + N', Menge '
                   + CAST(CAST(p.fAnzahl AS DECIMAL(18, 2)) AS NVARCHAR(30)) + N')</li>'),
               N'')
           WITHIN GROUP (ORDER BY p.cName)
    FROM Verkauf.tAuftragPosition        p
    JOIN dbo.tArtikelAttribut            aa   ON aa.kArtikel = p.kArtikel
    JOIN dbo.tAttributSprache            atts ON atts.kAttribut = aa.kAttribut
                                             AND atts.cName     = N'GeräteVerifizierungMail'
                                             AND atts.kSprache  = 0
    JOIN dbo.tArtikelAttributSprache     aas  ON aas.kArtikelAttribut = aa.kArtikelAttribut
                                             AND aas.kSprache         = 0
    WHERE p.kAuftrag  = @kAuftrag
      AND p.kArtikel  > 0
      AND p.nType     IN (0, 1)
      AND aas.nWertInt = 1;

    RETURN ISNULL(@cList, N'');
END;
GO
PRINT '+ Function Robotico.fnAuftragGeraeteabfrageArtikelListe deployed';
GO

IF XACT_STATE() = 1 COMMIT TRANSACTION; ELSE ROLLBACK TRANSACTION;
GO
