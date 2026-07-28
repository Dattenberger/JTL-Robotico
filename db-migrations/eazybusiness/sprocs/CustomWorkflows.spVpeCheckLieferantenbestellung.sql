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
-- Write path (architecture decision): positions are written through the sanctioned JTL SP
--   Lieferantenbestellung.spLieferantenBestellungPosBearbeiten
-- via its XML batch parameter (@xLieferantenbestellungPos), NOT by a direct UPDATE.
-- Reason: dbo.tLieferantenBestellungPos carries the JTL guard trigger
-- tgr_tlieferantenBestellungPos_INSUPDEL, which ROLLBACKs any direct write unless
-- CONTEXT_INFO() holds a JTL magic value. Two ways exist to satisfy it:
--   (A) call the JTL SP, which sets the context itself — verified live: the SP does
--       SET CONTEXT_INFO 0x5123 (the "PosBearbeiten" marker) around its own writes;
--   (B) set CONTEXT_INFO to a magic constant (the research tentatively named 0x5124 for the
--       raw bypass) and issue a direct UPDATE.
-- We use (A). It neither depends on an undocumented constant nor risks a Wawi update breaking
-- it, and its XML form updates all changed positions in ONE set-based call. The SP does full
-- column overwrites, so the XML carries EVERY position column unchanged except cHinweis; and
-- because the SP only touches stock (tlagerbestand) when fMenge / fMengeGeliefert actually
-- change, round-tripping the current values back makes the position write side-effect-free.
-- cFremdbelegnummer is NOT in the head trigger's (tgr_tlieferantenBestellung_INSUPDEL)
-- guard-column list, so the head marker is written by a plain direct UPDATE (verified live).
--
-- Consistency: the two writes (positions via SP, head via UPDATE) are intentionally not
-- wrapped in one outer transaction — the SP manages its own transaction and self-rolls-back
-- on error. Because the whole action is idempotent, a partially-applied run is fully
-- repaired by simply running the workflow again.
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur/reports/vpe-workflow-research.md
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

    BEGIN TRY

        DECLARE @kLieferant INT;
        SELECT @kLieferant = kLieferant
        FROM dbo.tLieferantenBestellung
        WHERE kLieferantenBestellung = @kLieferantenBestellung;

        -- Head does not exist (spurious trigger) -> nothing to do.
        IF @kLieferant IS NULL
            RETURN;

        -- 1. Build the working set: every position of the order, joined to the supplier
        --    article for VPE + per-piece EK, with the target cHinweis fully computed.
        --    Layered CROSS APPLYs because T-SQL cannot reference a computed alias in the
        --    same SELECT list. Non-article positions (no tLiefArtikel match) fall through
        --    to marker = NULL and are naturally excluded by the change filter below.
        SELECT
            pos.kLieferantenBestellungPos,
            pos.kLieferantenBestellung,
            pos.kArtikel,
            pos.cArtNr,
            pos.cLieferantenArtNr,
            pos.cName,
            pos.cLieferantenBezeichnung,
            pos.fUST,
            pos.fMenge,
            pos.cHinweis,
            pos.fEKNetto,
            pos.nPosTyp,
            pos.cNameLieferant,
            pos.nLiefertage,
            pos.dLieferdatum,
            pos.nSort,
            pos.kLieferscheinPos,
            pos.fMengeGeliefert,
            pos.cVPEEinheit,
            pos.nVPEMenge,
            e.hasError,
            h.newHinweis
        INTO #work
        FROM dbo.tLieferantenBestellungPos AS pos
        LEFT JOIN dbo.tLiefArtikel AS la
            ON la.tArtikel_kArtikel = pos.kArtikel
           AND la.tLieferant_kLieferant = @kLieferant
        CROSS APPLY (VALUES (
            CASE WHEN la.tArtikel_kArtikel IS NOT NULL AND la.nVPEMenge >= 2 THEN 1 ELSE 0 END
        )) AS v(hasVpe)
        -- Error detection runs on RAW values (the fEKNetto columns), independent of the
        -- 2-decimal display formatting below. The la.fEKNetto > 0 guard keeps articles with
        -- an unset supplier EK (0.0) from producing a false positive against the 1.5x factor.
        CROSS APPLY (VALUES (
            CASE WHEN v.hasVpe = 1 AND la.fEKNetto > 0 AND pos.fEKNetto >= 1.5 * la.fEKNetto
                 THEN 1 ELSE 0 END
        )) AS e(hasError)
        CROSS APPLY (VALUES (
            CASE
                WHEN v.hasVpe = 0 THEN NULL
                WHEN e.hasError = 1 THEN
                    N'{{VPE=' + FORMAT(la.nVPEMenge, '0.##', 'en-US')
                    + N', VPE Error Preis ' + FORMAT(pos.fEKNetto, '0.##', 'en-US')
                    + N'>>' + FORMAT(la.fEKNetto, '0.##', 'en-US') + N'}}'
                ELSE
                    N'{{VPE=' + FORMAT(la.nVPEMenge, '0.##', 'en-US') + N'}}'
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
        -- Assemble the final note. Truncation guard: LEFT(marker + note, 2000) — because the
        -- marker is at the front, an over-length note only ever loses its own tail, never the
        -- marker. marker = NULL (no VPE) collapses to just the (marker-stripped) base note, so
        -- losing VPE cleanly restores the original text; NULLIF avoids leaving an empty string.
        CROSS APPLY (VALUES (
            CASE
                WHEN m.marker IS NULL THEN NULLIF(b.baseHinweis, N'')
                WHEN NULLIF(b.baseHinweis, N'') IS NULL THEN m.marker
                ELSE LEFT(m.marker + N' ' + b.baseHinweis, 2000)
            END
        )) AS h(newHinweis)
        WHERE pos.kLieferantenBestellung = @kLieferantenBestellung;

        -- 2. Write the positions whose note actually changes, in one batch call through the
        --    sanctioned SP. The XML carries every position column unchanged except cHinweis
        --    (full-overwrite SP → unchanged fMenge/fMengeGeliefert keeps it off the stock path,
        --    see header). The NULL-safe change filter skips positions whose note is unaffected.
        DECLARE @xPos XML = (
            SELECT
                w.kLieferantenBestellungPos AS kLieferantenbestellungPos,
                w.kLieferantenBestellung    AS kLieferantenbestellung,
                w.kArtikel                  AS kArtikel,
                w.cArtNr                    AS cArtNr,
                w.cLieferantenArtNr         AS cLieferantenArtNr,
                w.cName                     AS cName,
                w.cLieferantenBezeichnung   AS cLieferantenBezeichnung,
                w.fUST                      AS fUST,
                w.fMenge                    AS fMenge,
                w.newHinweis                AS cHinweis,
                w.fEKNetto                  AS fEKNetto,
                w.nPosTyp                   AS nPosTyp,
                w.cNameLieferant            AS cNameLieferant,
                w.nLiefertage               AS nLiefertage,
                w.dLieferdatum              AS dLieferdatum,
                w.nSort                     AS nSort,
                w.kLieferscheinPos          AS kLieferscheinPos,
                w.fMengeGeliefert           AS fMengeGeliefert,
                w.cVPEEinheit               AS cVPEEinheit,
                w.nVPEMenge                 AS nVPEMenge
            FROM #work AS w
            WHERE ISNULL(w.newHinweis, N'') <> ISNULL(w.cHinweis, N'')
            FOR XML PATH('LieferantenbestellungPos'), TYPE
        );

        IF @xPos IS NOT NULL
            EXEC Lieferantenbestellung.spLieferantenBestellungPosBearbeiten
                 @xLieferantenbestellungPos = @xPos;

        -- 3. Head marker on cFremdbelegnummer (ungated by the head trigger). Strip any old
        --    marker first (REPLACE removes every occurrence -> never doubles), then re-append
        --    when at least one position has a price error. Length-guarded to 255 by trimming
        --    the base number, never the appended marker.
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
        -- touch the head when the number actually changed, so the ungated UPDATE stays a no-op
        -- on re-runs.
        IF (@newFremd IS NULL AND @curFremd IS NOT NULL)
            OR (@newFremd IS NOT NULL AND @curFremd IS NULL)
            OR (@newFremd <> @curFremd)
            UPDATE dbo.tLieferantenBestellung
            SET cFremdbelegnummer = @newFremd
            WHERE kLieferantenBestellung = @kLieferantenBestellung;

        DROP TABLE #work;

    END TRY
    BEGIN CATCH
        IF OBJECT_ID('tempdb..#work') IS NOT NULL
            DROP TABLE #work;
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();
        DECLARE @ErrorState INT = ERROR_STATE();

        RAISERROR (@ErrorMessage, @ErrorSeverity, @ErrorState);
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
