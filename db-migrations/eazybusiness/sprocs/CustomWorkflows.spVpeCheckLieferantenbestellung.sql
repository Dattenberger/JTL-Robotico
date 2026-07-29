-- ============================================================================
-- CustomWorkflows.spVpeCheckLieferantenbestellung — JTL action: VPE marker + price check
-- ============================================================================
-- Custom workflow action on supplier orders (Lieferantenbestellungen). For every
-- position it looks up the supplier-specific packaging unit (VPE) on tLiefArtikel and,
-- when present, writes a marker to the LEFT of the position note (cHinweis) and — when
-- the imported purchase price looks like a whole-VPE price instead of a per-piece price —
-- flags a price error both on the position and on the order head (cFremdbelegnummer).
-- Idempotent: re-runs replace/remove the marker in place and never stack.
--
-- Called by JTL-Wawi as a custom workflow action with the order PK
-- (@kLieferantenBestellung). Wire it in the Wawi UI to a "Warenbestellung geändert"
-- workflow (this repo only deploys the proc, not the dbo.tWorkflow* config).
--
-- ---------------------------------------------------------------------------
-- Business rules (final spec, decided by the user):
--   * VPE source is supplier-specific: tLiefArtikel WHERE tArtikel_kArtikel = pos.kArtikel
--     AND tLieferant_kLieferant = order.kLieferant. VPE is "present" when nVPEMenge >= 2.
--   * Per-piece purchase price baseline = tLiefArtikel.fEKNetto. Volume-tiered prices
--     (tLiefArtikelPreis) are DELIBERATELY IGNORED in v1 — see research §"Offene Punkte".
--   * Position marker in cHinweis (nvarchar(2000)):
--       - VPE present, price ok        -> "{{VPE=10}}"           (10 = nVPEMenge)
--       - VPE present, price error      -> "{{VPE=10, VPE Error Preis 110>>2.27}}"
--                                          (left = pos.fEKNetto imported, right = tLiefArtikel.fEKNetto)
--     Placement: marker + single space + existing note text (existing text is kept).
--   * Price-error definition (VPE positions only):
--       pos.fEKNetto >= 1.5 * tLiefArtikel.fEKNetto  AND  tLiefArtikel.fEKNetto > 0.
--   * No tLiefArtikel match for the ordering supplier, or nVPEMenge < 2 -> no marker, no check.
--   * Head marker: if AT LEAST ONE position has a price error, append " {{VPE Error}}" to
--     tLieferantenBestellung.cFremdbelegnummer (kept as a suffix so the original number stays
--     prefix-searchable); remove it again when no position has an error anymore.
--
-- Number format for the markers (ONE format, chosen here): decimal POINT separator,
-- rounded to 2 decimals with trailing zero-decimals stripped — "110" not "110.00",
-- "2.27" stays "2.27", "10" not "10.00". Implemented via FORMAT(x, '0.##', 'en-US')
-- so the separator is locale-independent (the deploy target test1 runs a German locale).
--
-- Idempotency: a leading "{{VPE...}}" marker already present at the start of cHinweis is
-- parsed off (up to the first "}}", plus one following space) before the new marker is
-- prepended — so repeated runs replace rather than stack, and the marker is removed
-- entirely when VPE no longer applies. The head marker is stripped via REPLACE before a
-- fresh one is (re)appended, so it likewise never doubles.
--
-- Field-length guards: cHinweis is capped at 2000 chars by LEFT() over (marker + note) —
-- the marker sits at the front so truncation only ever trims the note tail, never the
-- marker. cFremdbelegnummer (255) trims the base number, never the appended marker.
--
-- ---------------------------------------------------------------------------
-- Write path (architecture decision — CONTEXT_INFO direct write, path B):
-- dbo.tLieferantenBestellungPos carries the JTL guard trigger
-- tgr_tlieferantenBestellungPos_INSUPDEL. Verified live (2026-07-29, e2e container): the
-- trigger has NO per-column list — it ROLLBACKs *every* direct INSERT/UPDATE/DELETE and
-- only lets the write through when CONTEXT_INFO() matches its whitelist:
--     0x5123, 0x5124, 0x5125, 0x5129,
--     HASHBYTES('SHA1', 'spUpdateLieferantenBestellungPosToFreiPosForStuecklistenVaeter').
-- So we save the caller's CONTEXT_INFO, SET CONTEXT_INFO 0x5123 (the value JTL's own
-- Lieferantenbestellung.spLieferantenBestellungPosBearbeiten uses), issue ONE set-based
-- UPDATE of cHinweis only, then restore the saved context (0x0 if the caller had none) —
-- on the CATCH path too, so the caller never inherits our 0x5123.
--
-- Why B over the earlier decision A (call the vendor SP with its XML full-overwrite batch):
-- REVISED 2026-07-29. Both paths satisfy the trigger. The failure mode decides it: if a
-- Wawi update ever changed these magic constants, path B fails LOUD and HARMLESS — the
-- UPDATE is rolled back, the whole action errors, the workflow log shows it. Path A round-
-- trips every position column through the vendor SP, so a future SP signature/behaviour
-- change (or a column we fail to carry) could SILENTLY drift or corrupt row data. A single
-- cHinweis UPDATE touches exactly the one column we own the value of; nothing else can move.
-- (The vendor SP also runs stock-recalc side effects we would have to suppress by exact
-- decimal round-tripping — avoided entirely here.) See reports/vpe-workflow-implementation.md
-- §"Write-path revised" and vpe-workflow-research.md §"Trigger-Schutz".
--
-- cFremdbelegnummer is NOT gated by the head trigger (tgr_tlieferantenBestellung_INSUPDEL
-- lists guard columns and cFremdbelegnummer is not among them, verified live), so the head
-- marker is a plain direct UPDATE with NO context change.
--
-- Consistency: the two writes (positions, head) are intentionally not wrapped in one outer
-- transaction. Because the whole action is idempotent, a partially-applied run is fully
-- repaired by simply running the workflow again.
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur/reports/vpe-workflow-research.md
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur/reports/vpe-workflow-implementation.md
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§1, D10 — CustomWorkflows is an
--      additive shared zone co-inhabited by excel_ekl; only touch our own objects)
-- ============================================================================

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE CustomWorkflows.spVpeCheckLieferantenbestellung @kLieferantenBestellung INT AS
BEGIN

    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @kLieferantenBestellung IS NULL
        THROW 50001, 'spVpeCheckLieferantenbestellung: @kLieferantenBestellung must not be NULL.', 1;

    -- Saved caller context for the guarded position write (see header). Declared at proc
    -- scope so the CATCH handler can restore it; @ctxChanged marks that we actually switched.
    DECLARE @prevCtx VARBINARY(128);
    DECLARE @ctxChanged BIT = 0;

    BEGIN TRY

        DECLARE @kLieferant INT;
        SELECT @kLieferant = kLieferant
        FROM dbo.tLieferantenBestellung
        WHERE kLieferantenBestellung = @kLieferantenBestellung;

        -- Head does not exist (spurious trigger) -> nothing to do.
        IF @kLieferant IS NULL
            RETURN;

        -- 1. Build the working set: for every position, the computed target note plus the
        --    price-error flag. #work holds only what the two writes below need — the join key,
        --    the old note (for the change filter), the new note, and the head-aggregate flag.
        --    hasError already folds in the VPE precondition (nVPEMenge >= 2), so the marker
        --    only needs one extra VPE test for the "VPE ok, no error" branch. Layered CROSS
        --    APPLYs because T-SQL cannot reference a computed alias in the same SELECT list.
        SELECT
            pos.kLieferantenBestellungPos,
            pos.cHinweis,
            e.hasError,
            h.newHinweis
        INTO #work
        FROM dbo.tLieferantenBestellungPos AS pos
        LEFT JOIN dbo.tLiefArtikel AS la
            ON la.tArtikel_kArtikel = pos.kArtikel
           AND la.tLieferant_kLieferant = @kLieferant
        -- Error detection runs on RAW values, independent of the 2-decimal display format
        -- below. la.fEKNetto > 0 keeps articles with an unset supplier EK (0.0) from a false
        -- positive; a NULL la (no supplier match) makes nVPEMenge >= 2 UNKNOWN -> 0.
        CROSS APPLY (VALUES (
            CASE WHEN la.nVPEMenge >= 2 AND la.fEKNetto > 0 AND pos.fEKNetto >= 1.5 * la.fEKNetto
                 THEN 1 ELSE 0 END
        )) AS e(hasError)
        CROSS APPLY (VALUES (
            CASE
                WHEN e.hasError = 1 THEN
                    N'{{VPE=' + FORMAT(la.nVPEMenge, '0.##', 'en-US')
                    + N', VPE Error Preis ' + FORMAT(pos.fEKNetto, '0.##', 'en-US')
                    + N'>>' + FORMAT(la.fEKNetto, '0.##', 'en-US') + N'}}'
                WHEN la.nVPEMenge >= 2 THEN
                    N'{{VPE=' + FORMAT(la.nVPEMenge, '0.##', 'en-US') + N'}}'
                ELSE NULL
            END
        )) AS m(marker)
        CROSS APPLY (VALUES (
            -- Idempotency: strip an existing leading "{{VPE...}}" marker (plus one following
            -- space) so a re-run replaces it instead of stacking. The marker always sits at the
            -- very front and contains no nested "}}", so the FIRST "}}" is guaranteed to be its
            -- closer — everything after it (+1 space) is the caller's original note text.
            CASE
                WHEN LEFT(pos.cHinweis, 5) = N'{{VPE' AND CHARINDEX(N'}}', pos.cHinweis) > 0
                    THEN LTRIM(SUBSTRING(pos.cHinweis, CHARINDEX(N'}}', pos.cHinweis) + 2, 2000))
                ELSE pos.cHinweis
            END
        )) AS b(baseHinweis)
        CROSS APPLY (VALUES (
            -- Assemble the final note. Truncation guard: LEFT(marker + note, 2000) — the marker
            -- is at the front, so an over-length note only loses its own tail, never the marker.
            -- marker = NULL (no VPE) collapses to just the (marker-stripped) base note, so losing
            -- VPE cleanly restores the original text; NULLIF avoids leaving an empty string.
            CASE
                WHEN m.marker IS NULL THEN NULLIF(b.baseHinweis, N'')
                WHEN NULLIF(b.baseHinweis, N'') IS NULL THEN m.marker
                ELSE LEFT(m.marker + N' ' + b.baseHinweis, 2000)
            END
        )) AS h(newHinweis)
        WHERE pos.kLieferantenBestellung = @kLieferantenBestellung;

        -- 2. Position write. The guard trigger blocks any direct write unless CONTEXT_INFO is
        --    whitelisted; 0x5123 is the "PosBearbeiten" marker (header). Save + restore the
        --    caller's context around the single set-based UPDATE; the NULL-safe change filter
        --    leaves untouched notes alone. @ctxChanged lets the CATCH path undo the switch.
        SET @prevCtx = CONTEXT_INFO();
        SET @ctxChanged = 1;
        SET CONTEXT_INFO 0x5123;

        UPDATE pos
        SET pos.cHinweis = w.newHinweis
        FROM dbo.tLieferantenBestellungPos AS pos
        JOIN #work AS w ON w.kLieferantenBestellungPos = pos.kLieferantenBestellungPos
        WHERE ISNULL(w.newHinweis, N'') <> ISNULL(w.cHinweis, N'');

        IF @prevCtx IS NULL
            SET CONTEXT_INFO 0x0;
        ELSE
            SET CONTEXT_INFO @prevCtx;
        SET @ctxChanged = 0;

        -- 3. Head marker on cFremdbelegnummer (ungated by the head trigger -> plain UPDATE, no
        --    context switch). Strip any old marker first (REPLACE removes every occurrence ->
        --    never doubles), then re-append when at least one position has a price error.
        --    Length-guarded to 255 by trimming the base number, never the appended marker.
        DECLARE @headHasError BIT =
            CASE WHEN EXISTS (SELECT 1 FROM #work WHERE hasError = 1) THEN 1 ELSE 0 END;

        DECLARE @curFremd NVARCHAR(255);
        SELECT @curFremd = cFremdbelegnummer
        FROM dbo.tLieferantenBestellung
        WHERE kLieferantenBestellung = @kLieferantenBestellung;

        DECLARE @baseFremd NVARCHAR(255) =
            RTRIM(REPLACE(REPLACE(ISNULL(@curFremd, N''), N' {{VPE Error}}', N''), N'{{VPE Error}}', N''));

        DECLARE @newFremd NVARCHAR(255) =
            CASE WHEN @headHasError = 1
                 THEN LEFT(@baseFremd, 255 - LEN(N' {{VPE Error}}')) + N' {{VPE Error}}'
                 ELSE @baseFremd
            END;
        SET @newFremd = NULLIF(@newFremd, N'');

        -- NULL-safe change detection (a plain <> is UNKNOWN when either side is NULL): only
        -- touch the head when the number actually changed, so the UPDATE stays a no-op on re-runs.
        IF (@newFremd IS NULL AND @curFremd IS NOT NULL)
            OR (@newFremd IS NOT NULL AND @curFremd IS NULL)
            OR (@newFremd <> @curFremd)
            UPDATE dbo.tLieferantenBestellung
            SET cFremdbelegnummer = @newFremd
            WHERE kLieferantenBestellung = @kLieferantenBestellung;

        DROP TABLE IF EXISTS #work;

    END TRY
    BEGIN CATCH
        -- Restore the caller's context if we switched it before failing, so the error path
        -- never leaks 0x5123 back to the workflow engine.
        IF @ctxChanged = 1
        BEGIN
            IF @prevCtx IS NULL
                SET CONTEXT_INFO 0x0;
            ELSE
                SET CONTEXT_INFO @prevCtx;
        END

        DROP TABLE IF EXISTS #work;
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        THROW;
    END CATCH
END
GO

-- Registration (see db-migrations/README.md §6). Guarded module-provided helpers.
IF OBJECT_ID('CustomWorkflows._CheckAction', 'P') IS NOT NULL
    EXEC CustomWorkflows._CheckAction @actionName = 'spVpeCheckLieferantenbestellung';
ELSE
    PRINT '! CustomWorkflows._CheckAction missing — Custom Workflow Actions module not booked; skipping validation.';
GO

IF OBJECT_ID('CustomWorkflows._SetActionDisplayName', 'P') IS NOT NULL
    EXEC CustomWorkflows._SetActionDisplayName @actionName = 'spVpeCheckLieferantenbestellung',
        @displayName = 'VPE-Check Warenbestellung';
ELSE
    PRINT '! CustomWorkflows._SetActionDisplayName missing — module not booked; skipping label registration.';
GO
