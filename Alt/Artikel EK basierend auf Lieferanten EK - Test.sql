SELECT tA.kArtikel, tA.fVKNetto, tA.fEKNetto, tA.kWarengruppe, tLA.fEKNetto FROM tArtikel tA
LEFT JOIN dbo.tliefartikel tLA ON tA.kArtikel = tLA.tArtikel_kArtikel
WHERE tA.fEKNetto != tLA.fEKNetto AND kHersteller = 3 AND kWarengruppe = 35