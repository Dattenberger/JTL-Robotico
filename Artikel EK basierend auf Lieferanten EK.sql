UPDATE tArtikel
SET tArtikel.fEKNetto = tLA.fEKNetto
FROM tArtikel tA
LEFT JOIN dbo.tliefartikel tLA ON tA.kArtikel = tLA.tArtikel_kArtikel
WHERE tA.fEKNetto = 0 AND kHersteller = 3 AND kWarengruppe = 35