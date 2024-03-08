/**
  Name des Vorgabelageplatzes eines Artikels.
 */

DECLARE @artikel AS INTEGER = 1917;

SELECT cName FROM dbo.tWarenlagerArtikelOptionen tWAO
         JOIN tWarenLagerPlatz tWLP on tWAO.kWarenLagerPlatz = tWLP.kWarenLagerPlatz
         WHERE kArtikel = @artikel AND tWAO.kWarenlager = 17;