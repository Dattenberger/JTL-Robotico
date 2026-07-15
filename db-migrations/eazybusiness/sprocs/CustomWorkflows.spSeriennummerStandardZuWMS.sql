-- ============================================================================
-- CustomWorkflows.spSeriennummerStandardZuWMS — JTL action: copy serials to WMS
-- ============================================================================
-- Custom workflow action. For a given article, moves the still-available serial numbers
-- from the standard warehouse (kWarenlager = 6) onto the placeholder WMS stock rows
-- (kWarenlager = 17, cSeriennr = '#$KEINE$#'), excluding serials already shipped. The
-- source standard rows are suffixed '-StandardLager'. Runs in an explicit transaction.
--
-- Ported from WorkflowProcedures/Workflowaktion Artikel Seriennummern Standardlager auf WMS.Sql
--   (2026-07-15): removed `use eazybusiness`; IF EXISTS DROP + CREATE -> CREATE OR ALTER;
--   `GO;` -> `GO`; SET NOCOUNT ON added; registration guarded (module-provided helpers).
--   Logic preserved verbatim, including the hard-coded warehouse ids (6 = standard,
--   17 = WMS) and the '#$KEINE$#' placeholder marker used by the operational data model.
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§1, D10 — CustomWorkflows is
--      an additive shared zone co-inhabited by excel_ekl; only touch our own objects)
-- ============================================================================

CREATE OR ALTER PROCEDURE CustomWorkflows.spSeriennummerStandardZuWMS @kArtikel INT AS
BEGIN

    SET NOCOUNT ON;

    BEGIN

        BEGIN TRANSACTION
            DECLARE @tSeriennummerBereitsVersendet Table
                                                   (
                                                       cSeriennr       nvarchar(128),
                                                       kBestellPos     int,
                                                       kLieferscheinPo int
                                                   );

            INSERT INTO @tSeriennummerBereitsVersendet
            SELECT cSeriennr, kBestellPos, kLieferscheinPos
            FROM dbo.tLagerArtikel
            WHERE kArtikel = @kArtikel
              AND kLieferscheinPos != 0
              AND kWarenlager = 17

            DECLARE @kCountStandardlager AS INT = (SELECT COUNT(kWarenlager)
                                                   FROM dbo.tLagerArtikel
                                                   WHERE kArtikel = @kArtikel
                                                     AND kLieferscheinPos = 0
                                                     AND kWarenlager = 6
                                                     AND cSeriennr NOT IN (SELECT cSeriennr FROM @tSeriennummerBereitsVersendet));

            DECLARE @kCountWMSLager AS INT = (SELECT COUNT(kWarenlager)
                                              FROM dbo.tLagerArtikel
                                              WHERE kArtikel = @kArtikel
                                                AND kLieferscheinPos = 0
                                                AND kWarenlager = 17
                                                AND cSeriennr = '#$KEINE$#');

            PRINT @kCountStandardlager;
            PRINT @kCountWMSLager;


            IF (@kCountStandardlager <= @kCountWMSLager)
                BEGIN

                    DECLARE @tSeriennummernStandard AS TABLE
                                                       (
                                                           kRowNumberStandard     int,
                                                           kLagerArtikel          int,
                                                           cSeriennr              nvarchar(128),
                                                           fEK                    decimal(25, 13),
                                                           kLieferant             int,
                                                           kLieferantenbestellung int
                                                       )

                    INSERT INTO @tSeriennummernStandard
                    SELECT ROW_NUMBER() over (ORDER BY cSeriennr) AS kRowNumberStandard,
                           kLagerArtikel,
                           cSeriennr,
                           fEK,
                           kLieferant,
                           kLieferantenbestellung
                    FROM dbo.tLagerArtikel
                    WHERE kArtikel = @kArtikel
                      AND kLieferscheinPos = 0
                      AND kLieferscheinPos = 0
                      AND kWarenlager = 6
                      AND cSeriennr NOT IN (SELECT cSeriennr FROM @tSeriennummerBereitsVersendet);

                    DECLARE @tNeueSeriennummern AS TABLE
                                                   (
                                                       kLagerArtikel          int,
                                                       cSeriennr              nvarchar(128),
                                                       fEK                    decimal(25, 13),
                                                       kLieferant             int,
                                                       kLieferantenbestellung int
                                                   )

                    INSERT INTO @tNeueSeriennummern
                    select RowsWMS.kLagerArtikel,
                           RowsStandard.cSeriennr,
                           RowsStandard.fEK,
                           RowsStandard.kLieferant,
                           RowsStandard.kLieferantenbestellung
                    from (SELECT *, ROW_NUMBER() over (ORDER BY kLagerArtikel) kRowNumberWMS
                          FROM dbo.tLagerArtikel
                          WHERE kArtikel = @kArtikel
                            AND kLieferscheinPos = 0
                            AND kWarenlager = 17
                            AND cSeriennr = '#$KEINE$#') RowsWMS
                             JOIN @tSeriennummernStandard AS RowsStandard ON kRowNumberStandard = kRowNumberWMS;

                    UPDATE dbo.tLagerArtikel
                    SET cSeriennr              = StandardS.cSeriennr,
                        fEK                    = StandardS.fEK,
                        kLieferant             = StandardS.kLieferant,
                        kLieferantenbestellung = StandardS.kLieferantenbestellung
                    FROM dbo.tLagerArtikel AS tLA
                             INNER JOIN @tNeueSeriennummern as StandardS
                                        ON tLA.kLagerArtikel = StandardS.kLagerArtikel

                    UPDATE dbo.tLagerArtikel
                    SET cSeriennr = CONCAT(tLA.cSeriennr, '-StandardLager')
                    FROM dbo.tLagerArtikel AS tLA
                             INNER JOIN @tSeriennummernStandard as StandardS
                                        ON tLA.kLagerArtikel = StandardS.kLagerArtikel

                    SELECT *
                    FROM dbo.tLagerArtikel
                    WHERE kArtikel = @kArtikel
                      AND kLieferscheinPos = 0
                    ORDER BY cSeriennr

                END;

        COMMIT TRANSACTION;

    END
END
GO

-- Registration (see db-migrations/README.md §6). Guarded module-provided helpers.
IF OBJECT_ID('CustomWorkflows._CheckAction', 'P') IS NOT NULL
    EXEC CustomWorkflows._CheckAction @actionName = 'spSeriennummerStandardZuWMS';
ELSE
    PRINT '! CustomWorkflows._CheckAction missing — Custom Workflow Actions module not booked; skipping validation.';
GO

IF OBJECT_ID('CustomWorkflows._SetActionDisplayName', 'P') IS NOT NULL
    EXEC CustomWorkflows._SetActionDisplayName @actionName = 'spSeriennummerStandardZuWMS',
        @displayName = 'Seriennummer Standard zu WMS kopieren';
ELSE
    PRINT '! CustomWorkflows._SetActionDisplayName missing — module not booked; skipping label registration.';
GO
