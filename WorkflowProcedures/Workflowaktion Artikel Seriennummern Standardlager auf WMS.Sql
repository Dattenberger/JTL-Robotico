--Auftrag Preise Auf Null -> U.a. für Interne Aufträge

use eazybusiness

IF EXISTS(SELECT 1
          FROM sys.procedures
          WHERE Name = 'spSeriennummerStandardZuWMS')
    DROP PROCEDURE CustomWorkflows.spSeriennummerStandardZuWMS
GO;

CREATE PROCEDURE CustomWorkflows.spSeriennummerStandardZuWMS @kArtikel INT AS
BEGIN
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

--Auftrag Preise Auf Null -> U.a. für Interne Aufträge
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
GO;

EXEC CustomWorkflows._CheckAction @actionName = 'spSeriennummerStandardZuWMS'
GO;

EXEC CustomWorkflows._SetActionDisplayName @actionName = 'spSeriennummerStandardZuWMS',
     @displayName = "Seriennummer Standard zu WMS kopieren"
GO;