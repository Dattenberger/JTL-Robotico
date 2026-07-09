-- ============================================================================
-- CustomWorkflows.spZustandartikelLieferantSetzen — JTL action: fix Zustand HAN
-- ============================================================================
-- Custom workflow action. When JTL duplicates an article into a condition article
-- (Zustandsartikel) it copies the supplier tab incl. the supplier article number.
-- This action replaces that copied number with a unique one (HAN + condition
-- suffix), or clears it (NULL) when no unique number can be formed. The standard
-- condition (kZustand = 1) is never touched. Idempotent (never doubles the suffix).
--
-- QUOTED_IDENTIFIER/ANSI_NULLS must be ON at create time: tliefartikel carries
-- filtered indexes, otherwise error 1934 on the UPDATE. Baked into the proc via
-- the SET statements below (sqlcmd/grate batch context).
--
-- Ported from WorkflowProcedures/Workflowaktion_Zustandartikel_Lieferant_Setzen.sql
-- (2026-07-10): removed `USE eazybusiness`; IF EXISTS DROP + CREATE -> CREATE OR
-- ALTER; registration guarded. The one-off bulk-cleanup block from the original
-- (commented out there) is intentionally NOT part of the deployed action.
-- ============================================================================

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE CustomWorkflows.spZustandartikelLieferantSetzen @kArtikel INT AS
BEGIN

    SET NOCOUNT ON;

    -- Key observation: JTL already appends the condition suffix (dbo.tZustand.cSuffix)
    -- to cArtNr AND cHAN of the condition article when duplicating (verified across all
    -- condition articles in stock, 2026-07-08). So the condition article's own HAN is
    -- already "base HAN + suffix"; no lookup on the main article is needed.
    --
    -- Rules:
    --   * The standard condition is never touched. Standard is fixed at kZustand = 1
    --     (JTL hardcodes this itself). Do NOT filter on nLieferantenEntfernen.
    --   * Condition without suffix, or article without HAN: no unique number can be
    --     formed -> clear cLiefArtNr (NULL) so the copied foreign number never remains.
    --   * Idempotent: if the HAN unexpectedly does not yet end in the suffix, append it;
    --     otherwise take the HAN unchanged. The suffix is never appended twice.
    --   * All supplier rows of the article are set.
    --
    -- A single UPDATE is atomic - deliberately without transaction/TRY-CATCH scaffolding;
    -- errors propagate straight to the JTL workflow.

    UPDATE la
    SET la.cLiefArtNr =
        CASE
            WHEN ISNULL(z.cSuffix, '') = '' OR ISNULL(a.cHAN, '') = ''
                THEN NULL                       -- no unique number formable -> clear
            WHEN RIGHT(a.cHAN, LEN(z.cSuffix)) = z.cSuffix
                THEN a.cHAN                     -- HAN already carries the suffix
            ELSE a.cHAN + z.cSuffix             -- edge case: suffix still missing
        END
    FROM dbo.tliefartikel la
    JOIN dbo.tArtikel a ON a.kArtikel = la.tArtikel_kArtikel
    JOIN dbo.tZustand z ON z.kZustand = a.kZustand
    WHERE la.tArtikel_kArtikel = @kArtikel
      AND a.kZustand <> 1;                      -- never touch the standard condition

END
GO

-- Registration (see db-migrations/README.md §6). Guarded module-provided helpers.
IF OBJECT_ID('CustomWorkflows._CheckAction', 'P') IS NOT NULL
    EXEC CustomWorkflows._CheckAction @actionName = 'spZustandartikelLieferantSetzen';
ELSE
    PRINT '! CustomWorkflows._CheckAction missing — Custom Workflow Actions module not booked; skipping validation.';
GO

IF OBJECT_ID('CustomWorkflows._SetActionDisplayName', 'P') IS NOT NULL
    EXEC CustomWorkflows._SetActionDisplayName @actionName = 'spZustandartikelLieferantSetzen',
        @displayName = 'Zustandsartikel: Lieferantennummer auf HAN+Zustand setzen';
ELSE
    PRINT '! CustomWorkflows._SetActionDisplayName missing — module not booked; skipping label registration.';
GO
