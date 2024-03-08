SELECT tA.cArtNr, tAB.cName, COUNT(tAB.cName) AS c/*, tLagerArtikel.**/
        FROM dbo.tLagerArtikel
        JOIN tArtikel tA on tLagerArtikel.kArtikel = tA.kArtikel
        JOIN tArtikelBeschreibung tAB on tA.kArtikel = tAB.kArtikel
        WHERE cSeriennr = '#$KEINE$#'
GROUP BY cName, tA.cArtNr
ORDER BY c/*, cSeriennr*/
