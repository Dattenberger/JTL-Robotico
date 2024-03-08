--DECLARE @kBestellung AS INT = 78538;
DECLARE @kBestellung AS INT = 88934;

/**
  Kriterien, die nicht in dieser SQL geprüft werden:
  Darf nicht Warenpost sein.
  Darf nicht Unhandlich beinhalten.
 */

/** Die folgende Query ermittelt alle Offenen Positionen inklusive dem vorraussichtlichem Lieferdatum.
  Es werden nur offene Positionen berücksichtigt, die aus den o.g. Warengruppen stammen.
  Es wird True ausgegeben, wenn
  -für alle offenen Artikelpositionen ein Lieferdatum gesetzt ist,
  -alle maximal 2 Tage auseinander liegen,
  -diese nicht mehr als eine Woche in der Zukunft liegen
  -und mindestens 1 artikel verfügbar ist.

  Akzeptierte Warengruppen:
  -27 -> Ersatzteil Gartengeräte
  -35 -> Ersatzteil Husqvarna Gartengerät

  Kleine Info am Rande:
  tbestellpos: Tabelle der Positionen im Auftrag
*/


select IIF(SUM(IIF(dVoraussichtlichVerfügbarAm IS NULL, 1, 0)) = 0
               AND DATEDIFF(day, MIN(dVoraussichtlichVerfügbarAm), MAX(dVoraussichtlichVerfügbarAm)) < 3
               AND DATEDIFF(day, GETDATE(), MAX(dVoraussichtlichVerfügbarAm)) < 4, 'TRUE', 'FALSE')
from (SELECT --ROW_NUMBER() OVER (ORDER BY tbestellpos.cArtNr)                                        AS kNummer,
             --tbestellpos.cArtNr                                                                     AS cArtikelnummer,
             --tbestellpos.cString                                                                    AS cBezeichnung,
             --IIF(ISNULL(BestellposLieferung.fAnzahlFehlbestandEigen, 0.0) > tbestellpos.nAnzahl, tbestellpos.nAnzahl,
             --    ISNULL(BestellposLieferung.fAnzahlFehlbestandEigen, 0.0))                          AS fOffeneMenge,
             ISNULL(BestellposLieferung.dLieferungEingetroffen,
                    IIF(ISNULL(tBestellung.dLieferdatum, GETDATE()) <= GETDATE(), GETDATE(),
                        NULL))                                                                      AS dVoraussichtlichVerfügbarAm--,
             --IIF(ISNULL(BestellposLieferung.dLieferungEingetroffen, IIF(ISNULL(tBestellung.dLieferdatum, GETDATE()) <= GETDATE(), GETDATE(), NULL)) < GETDATE(), 1, 0) AS nIstVergangenheit
      FROM dbo.tbestellpos
               JOIN dbo.tBestellung ON tbestellpos.tBestellung_kBestellung = tBestellung.kBestellung
          -- Eigenes Feld 'Text Lieferzeit DE' ermitteln
               JOIN
           (SELECT vBestellPosLieferInfo.kBestellung,
                   vBestellPosLieferInfo.kBestellPos,
                   vBestellPosLieferInfo.fAnzahlOffen,
                   vBestellPosLieferInfo.fAnzahlFehlbestandEigen,
                   MIN(ZulaufAnDatum.dLieferdatum) AS dLieferungEingetroffen
            FROM Versand.vBestellPosLieferInfo
                     LEFT JOIN
                 (SELECT tLieferantenBestellungPos.kArtikel,
                         tLieferantenBestellungPos.dLieferdatum,
                         SUM(tLieferantenBestellungPos.fAnzahlOffen)
                             OVER (PARTITION BY tLieferantenBestellungPos.kArtikel ORDER BY tLieferantenBestellungPos.dLieferdatum ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS fZulaufAnDatum
                  FROM tLieferantenBestellungPos
                           JOIN dbo.tLieferantenBestellung ON tLieferantenBestellungPos.kLieferantenBestellung =
                                                              tLieferantenBestellung.kLieferantenBestellung
                  WHERE tLieferantenBestellung.nStatus IN (20, 30) -- Lieferantenbestellung mit Zuläufen berücksichtigen
                    AND tLieferantenBestellungPos.kArtikel > 0) ZulaufAnDatum
                 ON ZulaufAnDatum.kArtikel = vBestellPosLieferInfo.kArtikel
            INNER JOIN tArtikel ON tArtikel.kArtikel = vBestellPosLieferInfo.kArtikel AND tArtikel.kWarengruppe IN (27, 35)
            WHERE vBestellPosLieferInfo.fAnzahlFehlbestandEigen <=
                  ISNULL(ZulaufAnDatum.fZulaufAnDatum, vBestellPosLieferInfo.fAnzahlFehlbestandEigen)
              AND vBestellPosLieferInfo.fAnzahlFehlbestandEigen > 0.0
            GROUP BY vBestellPosLieferInfo.kBestellung,
                     vBestellPosLieferInfo.kBestellPos,
                     vBestellPosLieferInfo.fAnzahlOffen,
                     vBestellPosLieferInfo.fAnzahlFehlbestandEigen,
                     vBestellPosLieferInfo.kArtikel) AS BestellposLieferung
           ON BestellposLieferung.kBestellPos = tbestellpos.kBestellPos
      WHERE tbestellpos.tBestellung_kBestellung = @kBestellung
        AND tbestellpos.nType IN (0, 1, 11, 17, 18)) tV
-- die Typen hab ich aus spReservierungenAktualisieren kopiert + 0 für Freipositionen
--AND ISNULL(tbestellung.dLieferdatum, DATEADD(dd, 2, GETDATE())) < dLieferungEingetroffen