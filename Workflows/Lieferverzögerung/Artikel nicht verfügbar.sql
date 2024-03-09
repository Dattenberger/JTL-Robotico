-- Artikel nicht verfügbar
DECLARE @kBestellung AS INT = 233514;

WITH ZulaufAnDatumMitNull AS (SELECT tLieferantenBestellungPos.kArtikel,
                                     tLieferantenBestellungPos.dLieferdatum,
                                     SUM(tLieferantenBestellungPos.fAnzahlOffen)
                                         OVER (
                                             PARTITION BY tLieferantenBestellungPos.kArtikel
                                             ORDER BY tLieferantenBestellungPos.dLieferdatum
                                             ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
                                             ) AS fZulaufAnDatum
                              FROM tLieferantenBestellungPos
                                       JOIN dbo.tLieferantenBestellung
                                            ON tLieferantenBestellungPos.kLieferantenBestellung =
                                               tLieferantenBestellung.kLieferantenBestellung
                              WHERE tLieferantenBestellung.nStatus IN (20, 30) -- Lieferantenbestellung mit Zuläufen berücksichtigen
                                AND tLieferantenBestellungPos.kArtikel > 0),
     ZulaufAnDatum AS (
         SELECT * FROM ZulaufAnDatumMitNull WHERE fZulaufAnDatum > 0
     )
SELECT ROW_NUMBER() OVER (ORDER BY tbestellpos.cArtNr) AS Nummer,
       tbestellpos.cArtNr AS Artikelnummer,
       tbestellpos.cString AS Bezeichnung,
       IIF(ISNULL(BestellposLieferung.fAnzahlFehlbestandEigen, 0.0) > tbestellpos.nAnzahl, tbestellpos.nAnzahl, ISNULL(BestellposLieferung.fAnzahlFehlbestandEigen, 0.0)) AS OffeneMenge,
       CONVERT(DATE, ISNULL(BestellposLieferung.dLieferungEingetroffen, CASE WHEN ISNULL(tBestellung.dLieferdatum, GETDATE()) <= GETDATE() THEN GETDATE() ELSE tBestellung.dLieferdatum END)) AS VoraussichtlichVerfügbarAm,
       CASE WHEN CONVERT(DATE, ISNULL(BestellposLieferung.dLieferungEingetroffen, CASE WHEN ISNULL(tBestellung.dLieferdatum, GETDATE()) <= GETDATE() THEN GETDATE() ELSE tBestellung.dLieferdatum END)) < GETDATE() THEN 1 ELSE 0 END AS nIstVergangenheit,
       --wenn kein Zulauf Datum bekann ist, soll 1 ausgegeben werden. Ansonsten 0
       CASE WHEN BestellposLieferung.dLieferungEingetroffen IS NULL THEN 1 ELSE 0 END AS nKeinZulaufDatum,
       ISNULL(tArtikelAttributSpracheDE.cWertVarchar, '') AS cAttributDE,
       ISNULL(tArtikelAttributSpracheEN.cWertVarchar, '') AS cAttributEN
FROM dbo.tbestellpos
         JOIN dbo.tBestellung ON tbestellpos.tBestellung_kBestellung = tBestellung.kBestellung
    -- Eigenes Feld 'Text Lieferzeit DE' ermitteln
         LEFT JOIN dbo.tAttributSprache AS tAttributSpracheDE ON tAttributSpracheDE.cName = 'Text Lieferzeit DE'
    AND tAttributSpracheDE.kSprache = 0
         LEFT JOIN dbo.tArtikelAttribut AS tArtikelAttributDE ON tbestellpos.tArtikel_kArtikel = tArtikelAttributDE.kArtikel
    AND tArtikelAttributDE.kAttribut = tAttributSpracheDE.kAttribut
         LEFT JOIN dbo.tArtikelAttributSprache AS tArtikelAttributSpracheDE ON tArtikelAttributDE.kArtikelAttribut = tArtikelAttributSpracheDE.kArtikelAttribut
    AND tArtikelAttributSpracheDE.kSprache = 0
         LEFT JOIN dbo.tAttributSprache AS tAttributSpracheEN ON tAttributSpracheEN.cName = 'Text Lieferzeit ENG'
    AND tAttributSpracheDE.kSprache = 0
         LEFT JOIN dbo.tArtikelAttribut AS tArtikelAttributEN ON tbestellpos.tArtikel_kArtikel = tArtikelAttributEN.kArtikel
    AND tArtikelAttributEN.kAttribut = tAttributSpracheEN.kAttribut
         LEFT JOIN dbo.tArtikelAttributSprache AS tArtikelAttributSpracheEN ON tArtikelAttributEN.kArtikelAttribut = tArtikelAttributSpracheEN.kArtikelAttribut
    AND tArtikelAttributSpracheEN.kSprache = 0
         JOIN
     (
         SELECT vBestellPosLieferInfo.kBestellung,
                vBestellPosLieferInfo.kBestellPos,
                vBestellPosLieferInfo.fAnzahlOffen,
                vBestellPosLieferInfo.fAnzahlFehlbestandEigen,
                MIN(ZulaufAnDatum.dLieferdatum) AS dLieferungEingetroffen
         FROM Versand.vBestellPosLieferInfo
                  LEFT JOIN ZulaufAnDatum ON ZulaufAnDatum.kArtikel = vBestellPosLieferInfo.kArtikel
                  LEFT JOIN
              (
                  --
                  -- Artikel ausschließen mit dem Eigenen Feld LieferverzögerungKeineMail = 1
                  --
                  SELECT DISTINCT tArtikel.kArtikel
                  FROM dbo.tAttributSprache
                           JOIN dbo.tArtikelAttribut ON tAttributSprache.kAttribut = tArtikelAttribut.kAttribut
                           JOIN dbo.tArtikelAttributSprache ON tArtikelAttribut.kArtikelAttribut = tArtikelAttributSprache.kArtikelAttribut
                           JOIN dbo.tArtikel ON tArtikelAttribut.kArtikel = tArtikel.kArtikel
                  WHERE tAttributSprache.cName = 'LieferverzögerungKeineMail'
                    AND tArtikelAttributSprache.nWertInt = 1
              ) AS ausgeschlosseneArtikel ON ZulaufAnDatum.kArtikel = ausgeschlosseneArtikel.kArtikel
         WHERE vBestellPosLieferInfo.fAnzahlFehlbestandEigen <= ISNULL(ZulaufAnDatum.fZulaufAnDatum, vBestellPosLieferInfo.fAnzahlFehlbestandEigen)
           AND vBestellPosLieferInfo.fAnzahlFehlbestandEigen > 0.0
           AND ausgeschlosseneArtikel.kArtikel IS NULL
         GROUP BY vBestellPosLieferInfo.kBestellung,
                  vBestellPosLieferInfo.kBestellPos,
                  vBestellPosLieferInfo.fAnzahlOffen,
                  vBestellPosLieferInfo.fAnzahlFehlbestandEigen,
                  vBestellPosLieferInfo.kArtikel
     ) AS BestellposLieferung ON BestellposLieferung.kBestellPos = tbestellpos.kBestellPos
WHERE tbestellpos.tBestellung_kBestellung = @kBestellung
  AND tbestellpos.nType IN (0, 1, 11, 17, 18) -- die Typen hab ich aus spReservierungenAktualisieren kopiert + 0 für Freipositionen
--AND ISNULL(tbestellung.dLieferdatum, DATEADD(dd, 2, GETDATE())) < dLieferungEingetroffen --Einkommentieren wenn das vor. Lieferdatum von Aufträgen vor der eintreffenden Lieferung liegen soll