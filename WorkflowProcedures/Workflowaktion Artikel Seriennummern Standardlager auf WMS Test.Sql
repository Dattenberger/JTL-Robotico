DECLARE @kArtikel AS INT = 1025;
--DECLARE @kArtikel AS INT = 1024;

BEGIN TRANSACTION

DECLARE @tSeriennummerBereitsVersendet Table
                                       (
                                           cSeriennr       nvarchar(128),
                                           kBestellPos     int,
                                           kLieferscheinPo int
                                       );

INSERT INTO @tSeriennummerBereitsVersendet
SELECT cSeriennr, kBestellPos, kLieferscheinPos
FROM eazybusiness.dbo.tLagerArtikel
WHERE kArtikel = @kArtikel
  AND (kLieferscheinPos != 0 OR cSeriennr LIKE 'Inventur%' OR cSeriennr = '#$KEINE$#' OR kLager = 17)
/*
  AND kWarenlager = 17*/

  SELECT * FROM @tSeriennummerBereitsVersendet;

--Auftrag Preise Auf Null -> U.a. für Interne Aufträge
DECLARE @kCountStandardlager AS INT = (SELECT COUNT(kWarenlager)
                                       FROM eazybusiness_restore.dbo.tLagerArtikel
                                       WHERE kArtikel = @kArtikel
                                         AND kLieferscheinPos = 0
                                         AND kWarenlager = 6
                                         AND cSeriennr NOT IN (SELECT cSeriennr FROM @tSeriennummerBereitsVersendet));

DECLARE @kCountWMSLager AS INT = (SELECT COUNT(kWarenlager)
                                  FROM eazybusiness.dbo.tLagerArtikel
                                  WHERE kArtikel = @kArtikel
                                    AND kLieferscheinPos = 0
                                    AND kWarenlager = 17
                                    AND cSeriennr = '#$KEINE$#');

PRINT @kCountStandardlager;
PRINT @kCountWMSLager;

SELECT *
    FROM eazybusiness.dbo.tLagerArtikel
    WHERE kArtikel = @kArtikel
      AND kLieferscheinPos = 0
    ORDER BY cSeriennr

--IF (@kCountStandardlager <= @kCountWMSLager)
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
    FROM eazybusiness_restore.dbo.tLagerArtikel
    WHERE kArtikel = @kArtikel
      AND kLieferscheinPos = 0
      AND kLieferscheinPos = 0
      AND kWarenlager = 6
      AND cSeriennr NOT IN (SELECT cSeriennr FROM @tSeriennummerBereitsVersendet);

    SELECT * FROM @tSeriennummernStandard;

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
          FROM eazybusiness.dbo.tLagerArtikel
          WHERE kArtikel = @kArtikel
            AND kLieferscheinPos = 0
            AND kWarenlager = 17
            AND cSeriennr = '#$KEINE$#') RowsWMS
             JOIN @tSeriennummernStandard AS RowsStandard ON kRowNumberStandard = kRowNumberWMS;

    SELECT * FROM @tNeueSeriennummern;

    UPDATE eazybusiness.dbo.tLagerArtikel
    SET cSeriennr              = NeueS.cSeriennr,
        fEK                    = NeueS.fEK,
        kLieferant             = NeueS.kLieferant,
        kLieferantenbestellung = NeueS.kLieferantenbestellung
    FROM eazybusiness.dbo.tLagerArtikel AS tLA
             INNER JOIN @tNeueSeriennummern as NeueS
                        ON tLA.kLagerArtikel = NeueS.kLagerArtikel

    /*UPDATE eazybusiness.dbo.tLagerArtikel
    SET cSeriennr = CONCAT(tLA.cSeriennr, '-StandardLager')
    FROM eazybusiness.dbo.tLagerArtikel AS tLA
             INNER JOIN @tSeriennummernStandard as StandardS
                        ON tLA.kLagerArtikel = StandardS.kLagerArtikel*/

    SELECT *
    FROM eazybusiness.dbo.tLagerArtikel
    WHERE kArtikel = @kArtikel
      AND kLieferscheinPos = 0
    ORDER BY cSeriennr

END;

COMMIT TRANSACTION;