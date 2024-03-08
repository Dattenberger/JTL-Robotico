DECLARE @kArtikel AS INT = 1313;

DECLARE @SeriennummerBereitsVersendet Table (cSeriennr nvarchar(128), kBestellPos int, kLieferscheinPo int);

INSERT INTO @SeriennummerBereitsVersendet
SELECT cSeriennr, kBestellPos, kLieferscheinPos
        FROM dbo.tLagerArtikel
        WHERE kArtikel = @kArtikel
          AND kLieferscheinPos != 0
          AND kWarenlager = 17

SELECT * FROM @SeriennummerBereitsVersendet;


--Auftrag Preise Auf Null -> U.a. für Interne Aufträge
DECLARE @kCountStandardlager AS INT = (SELECT COUNT(kWarenlager)
                                       FROM dbo.tLagerArtikel
                                       WHERE kArtikel = @kArtikel
                                         AND kLieferscheinPos = 0
                                         AND kWarenlager = 6
                                        AND cSeriennr NOT IN (SELECT cSeriennr FROM @SeriennummerBereitsVersendet));

SELECT cSeriennr
                                       FROM dbo.tLagerArtikel
                                       WHERE kArtikel = @kArtikel
                                         AND kLieferscheinPos = 0
                                         AND kWarenlager = 6
                                        --AND cSeriennr NOT IN (SELECT cSeriennr FROM @SeriennummerBereitsVersendet)

PRINT @kCountStandardlager