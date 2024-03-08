DECLARE @tOffeneBezahlteBestellungen TABLE (
    kBestellung int
,[tRechnung_kRechnung] int
--,[tBenutzer_kBenutzer]
--,[tAdresse_kAdresse]
----,[tText_kText]
,[tKunde_kKunde] int
,[cBestellNr] NVARCHAR(100)
--,[cType]
--,[cAnmerkung]
,dErstellt DATETIME
,fWert FLOAT
)

INSERT INTO @tOffeneBezahlteBestellungen
SELECT DISTINCT tBestellung.kBestellung
,[tRechnung_kRechnung]
--,[tBenutzer_kBenutzer]
--,[tAdresse_kAdresse]
----,[tText_kText]
,[tKunde_kKunde]
,[cBestellNr]
--,[cType]
--,[cAnmerkung]
,tBestellung.dErstellt
,fWert
--,[nZahlungsziel]
--,[tVersandArt_kVersandArt]
--,[fVersandBruttoPreis]
--,tBestellung.fRabatt
--,[kInetBestellung]
--,[cVersandInfo]
--,[dVersandt]
--,[cIdentCode]
--,[cBeschreibung]
--,[cInet]
--,tBestellung.dLieferdatum
--,[kBestellHinweis]
--,[cErloeskonto]
--,tBestellung.cWaehrung
--,tBestellung.fFaktor
--,[kShop]
--,[kFirma]
--,[kLogistik]
--,[nPlatform]
--,[kSprache]
--,tBestellung.fGutschein
--,[dGedruckt]
--,[dMailVersandt]
--,[cInetBestellNr]
--,tBestellung.kZahlungsArt
--,[kLieferAdresse]
--,[kRechnungsAdresse]
--,[nIGL]
--,[nUStFrei]
--,[cStatus]
--,[dVersandMail]
--,[dZahlungsMail]
--,[cUserName]
--,[cVerwendungszweck]
--,[fSkonto]
--,[kColor]
--,[nStorno]
--,[cModulID]
--,[nZahlungsTyp]
--,tBestellung.nHatUpload
--,[fZusatzGewicht]
--,[nKomplettAusgeliefert]
--,[dBezahlt]
--,[kSplitBestellung]
--,[cPUIZahlungsdaten]
--,[nPrio]
--,[cVersandlandISO]
--,[cUstId]
--,[nPremium]
--,[cVersandlandWaehrung]
--,[fVersandlandWaehrungFaktor]
--,[kRueckhalteGrund]
--,[cOutboundId]
--,[kFulfillmentLieferant]
--,[cKundenauftragsnummer]
--,[nIstReadOnly]
--,[cAmazonServiceLevel]
--,[nIstExterneRechnung]
--,[cKampagne]
--,[cKampagneParam]
--,[cKampagneName]
--,[cUserAgent]
--,[cReferrer]
--,[nMaxLiefertage]
--,[dErstelltWawi]
FROM tBestellung
JOIN dbo.vBestellungEckDaten ON vBestellungEckDaten.kBestellung = tBestellung.kBestellung
JOIN dbo.tZahlungsart ON tBestellung.kZahlungsart = tZahlungsart.kZahlungsart
JOIN dbo.tbestellpos ON tBestellung.kBestellung = tbestellpos.tBestellung_kBestellung
JOIN dbo.tlagerbestand ON tlagerbestand.kArtikel = tbestellpos.tArtikel_kArtikel
WHERE (vBestellungEckDaten.fWert-vBestellungEckDaten.fZahlung <= 0 /* Bezahlt oder Wert 0 */
OR tZahlungsart.nAusliefernVorZahlung = 1) /* oder Auslieferung vor Zahlung */
AND tBestellung.nKomplettAusgeliefert = 0 /* noch nicht komplett geliefert */
AND tBestellung.nStorno = 0 /* nicht storniert */
AND tBestellung.kRueckhaltegrund = 0 /* nicht zurückgehalten */
AND tBestellung.cType = 'B' /* Bestellung, kein Angebot oder Umlagerung */
AND ( tlagerbestand.fLagerbestand < tbestellpos.nAnzahl /* Genug auf Lager je Position */
OR tbestellpos.nType = 0 ) /* oder ist Freiposition */
AND tBestellung.dErstellt <= DATEADD(DAY, -10, GETDATE())

--Bestellungen
SELECT * FROM @tOffeneBezahlteBestellungen;

--Summen
SELECT COUNT(fWert) as 'Anzahl Aufträge', SUM(fWert) as 'Summe' FROM @tOffeneBezahlteBestellungen;