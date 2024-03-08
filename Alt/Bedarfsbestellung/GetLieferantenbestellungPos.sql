DECLARE @kLieferantenbestellung nvarchar(50) = '2711';

SELECT kLieferantenBestellungPos,
       tLBP.kArtikel,
       tA.kWarengruppe,
       tW.cName AS cWarengruppe,
       tLBP.cArtNr,
       cLieferantenArtNr,
       tLBP.cName,
       fMenge,
       cHinweis,
       nPosTyp,
       tLBP.nSort,
       nVPE,
       nVPEMenge
FROM tLieferantenBestellungPos tLBP
         LEFT JOIN tArtikel tA ON tLBP.kArtikel = tA.kArtikel
         LEFT JOIN tWarengruppe tW ON tA.kWarengruppe = tW.kWarengruppe
WHERE kLieferantenBestellung = @kLieferantenbestellung
ORDER BY nSort