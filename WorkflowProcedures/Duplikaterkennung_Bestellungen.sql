-- ============================================================================
-- Duplicate Order Detection (accidental double orders)
-- ============================================================================
--
-- Author:  Lukas Dattenberger
-- Date:    2026-06-08
-- Version: 2.0  (Boolean architecture; replaces the v1 logging design)
--
-- ============================================================================
-- PURPOSE
-- ============================================================================
--
-- Detects whether an order is an accidental duplicate of an EARLIER, identical
-- order by the same customer. Input is a single K-Auftrag (kAuftrag).
--
-- Two orders count as duplicates when ALL of the following hold:
--   1. Same customer            (Verkauf.tAuftrag.kKunde)
--   2. Within the time window   (default: +/- 24 hours around dErstellt)
--   3. Same gross value         (Verkauf.tAuftragEckdaten.fWertBrutto)
--   4. Identical positions      (same articles + quantities -> fingerprint)
--
-- ============================================================================
-- TRUTH-VALUE SEMANTICS ("true from the 2nd order onward")
-- ============================================================================
--
-- The boolean is TRUE only when there is at least one OLDER identical order.
-- Therefore the very FIRST order of a duplicate group is FALSE (it has no
-- older twin); every later order is TRUE. Example for a 3-order group A<B<C:
--   A -> false (no older), B -> true (A is older), C -> true (A,B are older).
--
-- "Older" is deterministic: dErstellt is frequently day-granular, so ties are
-- broken by kAuftrag (lower kAuftrag = created earlier, identity column). This
-- guarantees exactly one "first" order per group.
--
-- ============================================================================
-- THREE LAYERS
-- ============================================================================
--
--   Robotico.fnFindDuplicateOrders   (iTVF)   - engine: lists duplicate orders
--                                               + flag bIsOlderThanInput
--   Robotico.fnHasOlderDuplicateOrder(scalar) - truth value: BIT, 1 iff an
--                                               older identical order exists
--   Robotico.spCheckDuplicateOrder   (SP)     - outer layer for workflow/tests:
--                                               returns bIsDuplicate as a
--                                               result set + OUTPUT + RETURN code
--
-- ============================================================================
-- WHY THE POSITION COMPARISON IS MANDATORY
-- ============================================================================
--
-- Equal gross value alone is NOT enough. The live data contains pairs with an
-- identical total but different content (e.g. a demo unit as a free-text line
-- with an explicit discount vs. the same catalogue article with a line
-- discount - same total, different article). Those are NOT duplicates.
--
-- Validation against the test database (eazybusiness, ~297k orders):
--   - 525 candidate pairs (same customer, <=24h, same gross value)
--   - of which 497 are real duplicates (positions identical, too)
--   - the 28 remaining pairs are false positives the fingerprint discards.
--
-- ============================================================================
-- EFFICIENCY (why the check stays cheap)
-- ============================================================================
--
-- The workflow passes a single kAuftrag. That yields a cheap two-stage filter
-- - NO database-wide self-join:
--   Stage 0  Load the target order (1 row): customer, time, gross value,
--            position fingerprint.
--   Stage 1  Candidates = only orders of THE SAME customer within the window
--            with the same gross value. Uses IX_Verkauf_tAuftrag_kKunde
--            (index seek instead of table scan).
--   Stage 2  Compute the position fingerprint only for those (usually 0-2)
--            candidates and compare it.
--
-- The fingerprint is a SHA2_256 hash over the sorted set of customer positions
-- "article#quantity", turning the position comparison into a single string
-- comparison. Measured ~40 ms per call even for the customer with the most
-- orders (1607).
--
-- ============================================================================
-- POSITION TYPES (Verkauf.tAuftragPosition.nType)
-- ============================================================================
--
--   0  article line (free text / no kArtikel, cArtNr set)
--   1  article line (catalogue article with kArtikel)   <- customer choice
--   2  shipping line  (e.g. "DHL Paket")                 derived
--   3  discount line  (e.g. "LigaRabatt")                derived
--   5  payment discount (e.g. "Vorkasserabatt")          derived
--  15  packaging (added automatically)                   derived
--
-- Only customer positions nType IN (0,1) feed the fingerprint. Shipping,
-- discounts and packaging are derived and are covered indirectly by the
-- gross-value comparison.
--
-- ============================================================================
-- USE IN A JTL WORKFLOW
-- ============================================================================
--
-- A JTL custom ACTION cannot return a boolean that gates the workflow (actions
-- are fire-and-forget; see docs/SQL/JTL-CUSTOM-WORKFLOWS.md). The truth value is
-- consumed through a "erweiterte Eigenschaft" (advanced property, DotLiquid)
-- used as a Bedingung. The shipped property
-- "Workflows/Auftrag - Ist Duplikat.liquid" returns the word
-- WAHR / FALSCH via DirectQueryScalar:
--
--     DECLARE @kAuftrag INT = {{ Vorgang.Stammdaten.InterneAuftragsnummer }};
--     SELECT CASE WHEN Robotico.fnHasOlderDuplicateOrder(@kAuftrag, 24) = 1
--                 THEN 'WAHR' ELSE 'FALSCH' END;
--
-- (InterneAuftragsnummer == kBestellung == Verkauf.tAuftrag.kAuftrag.)
-- Programmatic callers can use Robotico.spCheckDuplicateOrder (returns BIT).
--
-- ============================================================================
-- DEPENDENCIES
-- ============================================================================
--   - Verkauf.tAuftrag, Verkauf.tAuftragEckdaten, Verkauf.tAuftragPosition
--   - tAuftragEckdaten.fWertBrutto must be populated at check time
--     (present after order creation in JTL).
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
-- 1. Engine: list the duplicate orders of a target order (incl. age flag)
--    Inline TVF (set-based) -> optimally inlineable.
--
--    Three stages, cheapest first:
--      Stage 0  target basics (PK seek)          - no hashing
--      Stage 1  candidate pre-filter (kKunde idx) - no hashing; empty here means
--               the customer has no matching sibling -> nothing else runs
--      Stage 2  position fingerprint, defined exactly ONCE, computed only for
--               the target + candidates and ONLY when a candidate exists
--    A customer without a matching sibling order therefore triggers no hashing.
-- ----------------------------------------------------------------------------
CREATE OR ALTER FUNCTION Robotico.fnFindDuplicateOrders
(
    @kAuftrag     INT,
    @nWindowHours INT = 24
)
RETURNS TABLE
AS
RETURN
(
    -- Stage 0: target basics (PK seek, no hashing)
    WITH Target AS (
        SELECT a.kKunde,
               a.dErstellt,
               CAST(e.fWertBrutto AS DECIMAL(18,2)) AS GrossValue
        FROM Verkauf.tAuftrag a
        JOIN Verkauf.tAuftragEckdaten e ON e.kAuftrag = a.kAuftrag
        WHERE a.kAuftrag = @kAuftrag
    ),
    -- Stage 1: candidate pre-filter via index IX_Verkauf_tAuftrag_kKunde (no hashing)
    Candidates AS (
        SELECT a.kAuftrag,
               a.cAuftragsNr,
               a.dErstellt,
               t.dErstellt AS dTarget,
               t.GrossValue
        FROM Target t
        JOIN Verkauf.tAuftrag a          ON a.kKunde   = t.kKunde
        JOIN Verkauf.tAuftragEckdaten e  ON e.kAuftrag = a.kAuftrag
        WHERE a.kAuftrag <> @kAuftrag
          AND a.nStorno   = 0                                  -- ignore cancelled orders
          AND CAST(e.fWertBrutto AS DECIMAL(18,2)) = t.GrossValue
          AND a.dErstellt BETWEEN DATEADD(HOUR, -@nWindowHours, t.dErstellt)
                              AND DATEADD(HOUR,  @nWindowHours, t.dErstellt)
    ),
    -- Orders whose fingerprint we need: the candidates, plus the target - but
    -- the target only if at least one candidate exists (else: hash nothing).
    OrdersToFingerprint AS (
        SELECT kAuftrag FROM Candidates
        UNION
        SELECT @kAuftrag WHERE EXISTS (SELECT 1 FROM Candidates)
    ),
    -- Stage 2: the position fingerprint - defined exactly ONCE here.
    Fingerprints AS (
        SELECT p.kAuftrag,
               CONVERT(VARCHAR(64), HASHBYTES('SHA2_256',
                   STRING_AGG(CONVERT(NVARCHAR(MAX),
                       COALESCE(CAST(p.kArtikel AS NVARCHAR(50)), 'F:' + p.cArtNr)
                       + '#' + CAST(CAST(p.fAnzahl AS DECIMAL(18,3)) AS NVARCHAR(30))), '|')
                     WITHIN GROUP (ORDER BY
                       COALESCE(CAST(p.kArtikel AS NVARCHAR(50)), 'F:' + p.cArtNr)
                       + '#' + CAST(CAST(p.fAnzahl AS DECIMAL(18,3)) AS NVARCHAR(30)))
               ), 2) AS Fingerprint
        FROM Verkauf.tAuftragPosition p
        JOIN OrdersToFingerprint o ON o.kAuftrag = p.kAuftrag
        WHERE p.nType IN (0, 1)
        GROUP BY p.kAuftrag
    )
    SELECT c.kAuftrag    AS kDuplicateOrder,
           c.cAuftragsNr AS cAuftragsNr,
           c.dErstellt   AS dCreated,
           c.GrossValue  AS fGrossValue,
           ABS(DATEDIFF(MINUTE, c.dTarget, c.dErstellt)) AS nMinutesApart,
           CAST(CASE
                WHEN c.dErstellt < c.dTarget THEN 1
                WHEN c.dErstellt = c.dTarget AND c.kAuftrag < @kAuftrag THEN 1
                ELSE 0
           END AS BIT) AS bIsOlderThanInput
    FROM Candidates c
    JOIN Fingerprints fc ON fc.kAuftrag = c.kAuftrag
    JOIN Fingerprints ft ON ft.kAuftrag = @kAuftrag
    WHERE fc.Fingerprint = ft.Fingerprint
);
GO
PRINT '+ Function Robotico.fnFindDuplicateOrders deployed';
GO

-- ----------------------------------------------------------------------------
-- 2. Truth value: is the order a duplicate (an older identical order exists)?
-- ----------------------------------------------------------------------------
CREATE OR ALTER FUNCTION Robotico.fnHasOlderDuplicateOrder
(
    @kAuftrag    INT,
    @nWindowHours INT = 24
)
RETURNS BIT
AS
BEGIN
    RETURN CASE
        WHEN EXISTS (
            SELECT 1
            FROM Robotico.fnFindDuplicateOrders(@kAuftrag, @nWindowHours)
            WHERE bIsOlderThanInput = 1
        ) THEN 1
        ELSE 0
    END;
END
GO
PRINT '+ Function Robotico.fnHasOlderDuplicateOrder deployed';
GO

-- ----------------------------------------------------------------------------
-- 3. Outer layer for workflow/tests: returns the truth value three ways
--    (single-row result set "bIsDuplicate" + OUTPUT parameter + RETURN code).
-- ----------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE Robotico.spCheckDuplicateOrder
    @kAuftrag     INT,
    @nWindowHours INT = 24,
    @bIsDuplicate BIT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @bIsDuplicate = Robotico.fnHasOlderDuplicateOrder(@kAuftrag, @nWindowHours);

    SELECT @bIsDuplicate AS bIsDuplicate;

    RETURN @bIsDuplicate;
END
GO
PRINT '+ Procedure Robotico.spCheckDuplicateOrder deployed';
GO

-- ----------------------------------------------------------------------------
-- 4. Finish deployment
-- ----------------------------------------------------------------------------
IF XACT_STATE() = 1
BEGIN
    COMMIT TRANSACTION;
    PRINT '+ Duplicate order detection deployed successfully';
END
ELSE
BEGIN
    IF XACT_STATE() = -1
        ROLLBACK TRANSACTION;
    PRINT '! DEPLOYMENT FAILED - all changes rolled back';
END
GO
