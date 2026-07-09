-- ============================================================================
-- Robotico.fnFindDuplicateOrders — engine: list duplicate orders (iTVF)
-- ============================================================================
-- Lists the duplicate orders of a target order and flags which are OLDER than the
-- input. Two orders are duplicates when ALL hold: same customer, within the time
-- window (default +/-24h), same gross value, identical positions (fingerprint).
--
-- Three cheapest-first stages (no DB-wide self-join):
--   Stage 0  target basics (PK seek, no hashing)
--   Stage 1  candidate pre-filter via IX_Verkauf_tAuftrag_kKunde (no hashing)
--   Stage 2  SHA2_256 position fingerprint, computed only for target + candidates
--            and only when a candidate exists.
--
-- Only customer positions nType IN (0,1) feed the fingerprint; shipping/discount/
-- packaging lines are derived and covered by the gross-value comparison.
-- Requires SQL Server 2017+ (STRING_AGG). See docs/SQL/JTL-CUSTOM-WORKFLOWS.md
-- for the workflow-condition consumption (Robotico.fnHasOlderDuplicateOrder).
--
-- Ported from WorkflowProcedures/Duplikaterkennung_Bestellungen.sql (2026-07-10):
-- removed `USE [eazybusiness]` and the per-file BEGIN TRAN/COMMIT scaffolding
-- (grate wraps the deploy in --transaction); one object per anytime file.
-- ============================================================================

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
