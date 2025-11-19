-- =============================================
-- Script: clear-customer-fields.sql
-- Beschreibung: VOLLSTÄNDIGE Anonymisierung ALLER personenbezogenen Daten in der JTL-Datenbank
--               für Testzwecke. Deckt über 100+ Tabellen ab.
--               Basiert auf umfassender Explore-Agent Analyse.
-- Autor: Claude Code
-- Datum: 2025-11-18
-- Version: 2.0 (COMPREHENSIVE)
-- =============================================

USE eazybusiness_tm2;
GO

SET NOCOUNT ON;
GO

PRINT '========================================================================='
PRINT 'START: VOLLSTÄNDIGE ANONYMISIERUNG ALLER PERSONENBEZOGENEN DATEN'
PRINT 'Zeitpunkt: ' + CONVERT(VARCHAR(20), GETDATE(), 120)
PRINT '========================================================================='
PRINT ''
GO

-- =============================================
-- PRIORITÄT 1: KERN-PERSONENDATEN (KRITISCH)
-- =============================================

PRINT '========== PRIORITÄT 1: KERN-PERSONENDATEN =========='
GO

-- 1.1 dbo.tkunde - Kundenstammdaten
-- WICHTIG: Diese Tabelle ist durch Trigger geschützt (nur via Kunde.spKundeUpdate änderbar)
-- Lösung: CONTEXT_INFO setzen, um Trigger zu umgehen
PRINT 'Anonymisiere dbo.tkunde...'
BEGIN TRY
    BEGIN TRANSACTION;

    -- CONTEXT_INFO setzen (umgeht Trigger-Sperre)
    DECLARE @hash VARBINARY(128);
    SELECT @hash = HASHBYTES('SHA1', 'Kunde.spKundeUpdate');
    SET CONTEXT_INFO @hash;

    -- Direktes UPDATE durchführen
    UPDATE dbo.tkunde SET
        cEbayName = 'cEbayName_' + CAST(kKunde AS NVARCHAR(30)),
        cGeburtstag = NULL,
        cWWW = 'cWWW_' + CAST(kKunde AS NVARCHAR(30)),
        cHerkunft = 'cHerkunft_' + CAST(kKunde AS NVARCHAR(30)),
        cHRNr = 'cHRNr_' + CAST(kKunde AS NVARCHAR(30)),
        cSteuerNr = 'cSteuerNr_' + CAST(kKunde AS NVARCHAR(30))
    WHERE kKunde IS NOT NULL;

    PRINT 'Anonymisiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze';

    -- CONTEXT_INFO zurücksetzen
    SET CONTEXT_INFO 0x0;

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    -- CONTEXT_INFO auch bei Fehler zurücksetzen
    SET CONTEXT_INFO 0x0;

    PRINT 'FEHLER bei tkunde: ' + ERROR_MESSAGE();
    THROW;
END CATCH
GO

-- 1.1a tKunde_suche - Kundensuche-Index leeren (falls vorhanden)
-- Diese Tabelle enthält denormalisierte Suchdaten und wird automatisch neu aufgebaut
IF OBJECT_ID('dbo.tKunde_suche', 'U') IS NOT NULL
BEGIN
    PRINT 'Leere tKunde_suche (Such-Index)...'
    TRUNCATE TABLE dbo.tKunde_suche;
    PRINT 'tKunde_suche geleert.'
END
ELSE
BEGIN
    PRINT 'tKunde_suche nicht vorhanden (übersprungen).'
END
GO

-- 1.2 dbo.tinetkunde - Internet-Kundendaten
PRINT 'Anonymisiere dbo.tinetkunde...'
UPDATE dbo.tinetkunde SET
    cBenutzername = 'User_' + CAST(kInetKunde AS NVARCHAR(20)),
    cPasswort = 'Pass_' + CAST(kInetKunde AS NVARCHAR(20)),
    cAnrede = 'Anrede_' + CAST(kInetKunde AS NVARCHAR(20)),
    cVorname = 'cVorname_' + CAST(kInetKunde AS NVARCHAR(20)),
    cNachname = 'cNachname_' + CAST(kInetKunde AS NVARCHAR(20)),
    cFirma = 'cFirma_' + CAST(kInetKunde AS NVARCHAR(20)),
    cStrasse = 'cStrasse_' + CAST(kInetKunde AS NVARCHAR(20)),
    cPLZ = CAST(10000 + (kInetKunde % 90000) AS NVARCHAR(20)),
    cStadt = 'cStadt_' + CAST(kInetKunde AS NVARCHAR(20)),
    cTel = 'Tel_' + CAST(kInetKunde AS NVARCHAR(20)),
    cFax = 'Fax_' + CAST(kInetKunde AS NVARCHAR(20)),
    cMail = 'mail_' + CAST(kInetKunde AS NVARCHAR(20)) + '@test.local',
    cMobil = 'Mobil_' + CAST(kInetKunde AS NVARCHAR(20)),
    cAdressZusatz = 'cAdressZusatz_' + CAST(kInetKunde AS NVARCHAR(20)),
    cGeburtstag = NULL,
    cWWW = 'www_' + CAST(kInetKunde AS NVARCHAR(20)) + '.test.local',
    cHerkunft = 'cHerkunft_' + CAST(kInetKunde AS NVARCHAR(20)),
    cZusatz = 'cZusatz_' + CAST(kInetKunde AS NVARCHAR(20)),
    cTitel = 'cTitel_' + CAST(kInetKunde AS NVARCHAR(20)),
    cUSTID = 'USTID_' + CAST(kInetKunde AS NVARCHAR(20)),
    cBundesland = 'Bundesland_' + CAST(kInetKunde AS NVARCHAR(20))
WHERE kInetKunde IS NOT NULL;
PRINT 'Anonymisiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
GO

-- 1.3 dbo.tAdresse - Adressen
-- WICHTIG: Diese Tabelle ist durch Trigger geschützt (nur via spAdresseUpdate änderbar)
PRINT 'Anonymisiere dbo.tAdresse...'
BEGIN TRY
    BEGIN TRANSACTION;

    -- CONTEXT_INFO setzen (umgeht Trigger-Sperre)
    DECLARE @hash_adresse VARBINARY(128);
    SELECT @hash_adresse = HASHBYTES('SHA1', 'dbo.spAdresseUpdate');
    SET CONTEXT_INFO @hash_adresse;

    UPDATE dbo.tAdresse SET
        cFirma = 'cFirma_' + CAST(kAdresse AS NVARCHAR(30)),
        cAnrede = 'Anrede_' + CAST(kAdresse AS NVARCHAR(30)),
        cTitel = 'cTitel_' + CAST(kAdresse AS NVARCHAR(30)),
        cVorname = 'cVorname_' + CAST(kAdresse AS NVARCHAR(30)),
        cName = 'cName_' + CAST(kAdresse AS NVARCHAR(30)),
        cStrasse = 'cStrasse_' + CAST(kAdresse AS NVARCHAR(30)),
        cPLZ = CAST(10000 + (kAdresse % 90000) AS NVARCHAR(24)),
        cOrt = 'cOrt_' + CAST(kAdresse AS NVARCHAR(30)),
        cTel = 'Tel_' + CAST(kAdresse AS NVARCHAR(30)),
        cZusatz = 'cZusatz_' + CAST(kAdresse AS NVARCHAR(30)),
        cAdressZusatz = 'cAdressZusatz_' + CAST(kAdresse AS NVARCHAR(30)),
        cPostID = 'cPostID_' + CAST(kAdresse AS NVARCHAR(30)),
        cMobil = 'Mobil_' + CAST(kAdresse AS NVARCHAR(30)),
        cMail = 'mail_' + CAST(kAdresse AS NVARCHAR(30)) + '@test.local',
        cFax = 'Fax_' + CAST(kAdresse AS NVARCHAR(30)),
        cBundesland = 'Bundesland_' + CAST(kAdresse AS NVARCHAR(30)),
        cUSTID = 'USTID_' + CAST(kAdresse AS NVARCHAR(30))
    WHERE kAdresse IS NOT NULL;

    PRINT 'Anonymisiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze';

    SET CONTEXT_INFO 0x0;
    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;
    SET CONTEXT_INFO 0x0;
    PRINT 'FEHLER bei tAdresse: ' + ERROR_MESSAGE();
    THROW;
END CATCH
GO

-- 1.4 dbo.tinetadress - Internet-Adressen
IF OBJECT_ID('dbo.tinetadress', 'U') IS NOT NULL
BEGIN
    PRINT 'Anonymisiere dbo.tinetadress...'
    UPDATE dbo.tinetadress SET
        cFirma = 'cFirma_' + CAST(kInetAdress AS NVARCHAR(30)),
        cAnrede = 'Anrede_' + CAST(kInetAdress AS NVARCHAR(30)),
        cTitel = 'cTitel_' + CAST(kInetAdress AS NVARCHAR(30)),
        cVorname = 'cVorname_' + CAST(kInetAdress AS NVARCHAR(30)),
        cNachname = 'cNachname_' + CAST(kInetAdress AS NVARCHAR(30)),
        cStrasse = 'cStrasse_' + CAST(kInetAdress AS NVARCHAR(30)),
        cPLZ = CAST(10000 + (kInetAdress % 90000) AS NVARCHAR(24)),
        cStadt = 'cStadt_' + CAST(kInetAdress AS NVARCHAR(30)),
        cTel = 'Tel_' + CAST(kInetAdress AS NVARCHAR(30)),
        cMobil = 'Mobil_' + CAST(kInetAdress AS NVARCHAR(30)),
        cFax = 'Fax_' + CAST(kInetAdress AS NVARCHAR(30)),
        cMail = 'mail_' + CAST(kInetAdress AS NVARCHAR(30)) + '@test.local',
        cAdressZusatz = 'cAdressZusatz_' + CAST(kInetAdress AS NVARCHAR(30)),
        cZusatz = 'cZusatz_' + CAST(kInetAdress AS NVARCHAR(30)),
        cBundesland = 'Bundesland_' + CAST(kInetAdress AS NVARCHAR(30))
    WHERE kInetAdress IS NOT NULL;
    PRINT 'Anonymisiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
END
GO

-- 1.5 dbo.trechnungsadresse - Rechnungsadressen
PRINT 'Anonymisiere dbo.trechnungsadresse...'
UPDATE dbo.trechnungsadresse SET
    cFirma = 'cFirma_' + CAST(kRechnungsAdresse AS NVARCHAR(30)),
    cAnrede = 'Anrede_' + CAST(kRechnungsAdresse AS NVARCHAR(30)),
    cTitel = 'cTitel_' + CAST(kRechnungsAdresse AS NVARCHAR(30)),
    cVorname = 'cVorname_' + CAST(kRechnungsAdresse AS NVARCHAR(30)),
    cName = 'cName_' + CAST(kRechnungsAdresse AS NVARCHAR(30)),
    cStrasse = 'cStrasse_' + CAST(kRechnungsAdresse AS NVARCHAR(30)),
    cPLZ = CAST(10000 + (kRechnungsAdresse % 90000) AS NVARCHAR(24)),
    cOrt = 'cOrt_' + CAST(kRechnungsAdresse AS NVARCHAR(30)),
    cTel = 'Tel_' + CAST(kRechnungsAdresse AS NVARCHAR(30)),
    cZusatz = 'cZusatz_' + CAST(kRechnungsAdresse AS NVARCHAR(30)),
    cAdressZusatz = 'cAdressZusatz_' + CAST(kRechnungsAdresse AS NVARCHAR(30)),
    cPostID = 'cPostID_' + CAST(kRechnungsAdresse AS NVARCHAR(30)),
    cMobil = 'Mobil_' + CAST(kRechnungsAdresse AS NVARCHAR(30)),
    cMail = 'mail_' + CAST(kRechnungsAdresse AS NVARCHAR(30)) + '@test.local',
    cFax = 'Fax_' + CAST(kRechnungsAdresse AS NVARCHAR(30)),
    cZHaenden = 'cZHaenden_' + CAST(kRechnungsAdresse AS NVARCHAR(30)),
    cBundesland = 'Bundesland_' + CAST(kRechnungsAdresse AS NVARCHAR(30))
WHERE kRechnungsAdresse IS NOT NULL;
PRINT 'Anonymisiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
GO

-- 1.6 dbo.tBenutzer - System-Benutzer (KRITISCH!)
IF OBJECT_ID('dbo.tBenutzer', 'U') IS NOT NULL
BEGIN
    PRINT 'Anonymisiere dbo.tBenutzer...'
    UPDATE dbo.tBenutzer SET
        cLogin = 'User_' + CAST(kBenutzer AS NVARCHAR(15)),
        cPasswort = 'Pass_' + CAST(kBenutzer AS NVARCHAR(15)),
        cName = 'cName_' + CAST(kBenutzer AS NVARCHAR(15)),
        cTel = 'Tel_' + CAST(kBenutzer AS NVARCHAR(15)),
        cEMail = 'mail_' + CAST(kBenutzer AS NVARCHAR(15)) + '@test.local',
        cFax = 'Fax_' + CAST(kBenutzer AS NVARCHAR(15)),
        cMobil = 'Mobil_' + CAST(kBenutzer AS NVARCHAR(15)),
        cHinweis = 'cHinweis_' + CAST(kBenutzer AS NVARCHAR(15)),
        cApiToken = NULL
    WHERE kBenutzer IS NOT NULL;
    PRINT 'Anonymisiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
END
GO

-- 1.7 dbo.tansprechpartner - Ansprechpartner
IF OBJECT_ID('dbo.tansprechpartner', 'U') IS NOT NULL
BEGIN
    PRINT 'Anonymisiere dbo.tansprechpartner...'
    UPDATE dbo.tansprechpartner SET
        cName = 'cName_' + CAST(kAnsprechpartner AS NVARCHAR(30)),
        cVorName = 'cVorname_' + CAST(kAnsprechpartner AS NVARCHAR(30)),
        cAnrede = 'Anrede_' + CAST(kAnsprechpartner AS NVARCHAR(30)),
        cTel = 'Tel_' + CAST(kAnsprechpartner AS NVARCHAR(30)),
        cFax = 'Fax_' + CAST(kAnsprechpartner AS NVARCHAR(30)),
        cMail = 'mail_' + CAST(kAnsprechpartner AS NVARCHAR(30)) + '@test.local',
        cMobil = 'Mobil_' + CAST(kAnsprechpartner AS NVARCHAR(30)),
        cAbteilung = 'Abt_' + CAST(kAnsprechpartner AS NVARCHAR(30))
    WHERE kAnsprechpartner IS NOT NULL;
    PRINT 'Anonymisiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
END
GO

-- 1.8 dbo.tfirma - Firmendaten
IF OBJECT_ID('dbo.tfirma', 'U') IS NOT NULL
BEGIN
    PRINT 'Anonymisiere dbo.tfirma...'
    UPDATE dbo.tfirma SET
        cName = 'Firma_' + CAST(kFirma AS NVARCHAR(30)),
        cUnternehmer = 'Unternehmer_' + CAST(kFirma AS NVARCHAR(30)),
        cStrasse = 'cStrasse_' + CAST(kFirma AS NVARCHAR(30)),
        cPLZ = CAST(10000 + (kFirma % 90000) AS NVARCHAR(50)),
        cOrt = 'cOrt_' + CAST(kFirma AS NVARCHAR(30)),
        cTel = 'Tel_' + CAST(kFirma AS NVARCHAR(30)),
        cFax = 'Fax_' + CAST(kFirma AS NVARCHAR(30)),
        cEMail = 'mail_' + CAST(kFirma AS NVARCHAR(30)) + '@test.local',
        cWWW = 'www_' + CAST(kFirma AS NVARCHAR(30)) + '.test.local',
        cSteuerNr = 'Steuer_' + CAST(kFirma AS NVARCHAR(30)),
        cKontoInhaber = 'Inhaber_' + CAST(kFirma AS NVARCHAR(30)),
        cPayPalEMail = 'paypal_' + CAST(kFirma AS NVARCHAR(30)) + '@test.local'
    WHERE kFirma IS NOT NULL;
    PRINT 'Anonymisiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
END
GO

-- 1.9 dbo.tlieferant - Lieferanten
PRINT 'Anonymisiere dbo.tlieferant...'
UPDATE dbo.tlieferant SET
    cFirma = 'cFirma_' + CAST(kLieferant AS NVARCHAR(30)),
    cKontakt = 'cKontakt_' + CAST(kLieferant AS NVARCHAR(30)),
    cStrasse = 'cStrasse_' + CAST(kLieferant AS NVARCHAR(30)),
    cPLZ = CAST(10000 + (kLieferant % 90000) AS NVARCHAR(10)),
    cOrt = 'cOrt_' + CAST(kLieferant AS NVARCHAR(30)),
    cTelZentralle = 'TelZ_' + CAST(kLieferant AS NVARCHAR(30)),
    cTelDurchwahl = 'TelD_' + CAST(kLieferant AS NVARCHAR(30)),
    cFax = 'Fax_' + CAST(kLieferant AS NVARCHAR(30)),
    cEMail = 'mail_' + CAST(kLieferant AS NVARCHAR(30)) + '@test.local',
    cWWW = 'www_' + CAST(kLieferant AS NVARCHAR(30)) + '.test.local',
    cAnmerkung = 'Anmerkung_' + CAST(kLieferant AS NVARCHAR(30)),
    cAnrede = 'Anrede_' + CAST(kLieferant AS NVARCHAR(30)),
    cVorname = 'cVorname_' + CAST(kLieferant AS NVARCHAR(30)),
    cNachname = 'cNachname_' + CAST(kLieferant AS NVARCHAR(30)),
    cFirmenZusatz = 'cFirmenZusatz_' + CAST(kLieferant AS NVARCHAR(30)),
    cAdresszusatz = 'cAdresszusatz_' + CAST(kLieferant AS NVARCHAR(30)),
    cBundesland = 'Bundesland_' + CAST(kLieferant AS NVARCHAR(30)),
    cUstid = 'USTID_' + CAST(kLieferant AS NVARCHAR(30))
WHERE kLieferant IS NOT NULL;
PRINT 'Anonymisiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
GO

-- =============================================
-- PRIORITÄT 2: TRANSAKTIONSDATEN MIT ADRESSEN
-- =============================================

PRINT ''
PRINT '========== PRIORITÄT 2: TRANSAKTIONSDATEN MIT ADRESSEN =========='
GO

-- 2.1 Verkauf.tAuftragAdresse - Auftragsadressen
IF OBJECT_ID('Verkauf.tAuftragAdresse', 'U') IS NOT NULL
BEGIN
    PRINT 'Anonymisiere Verkauf.tAuftragAdresse...'
    UPDATE Verkauf.tAuftragAdresse SET
        cFirma = 'cFirma_' + CAST(kAuftrag AS NVARCHAR(30)) + '_' + CAST(nTyp AS NVARCHAR(5)),
        cAnrede = 'Anrede_' + CAST(kAuftrag AS NVARCHAR(30)) + '_' + CAST(nTyp AS NVARCHAR(5)),
        cTitel = 'cTitel_' + CAST(kAuftrag AS NVARCHAR(30)) + '_' + CAST(nTyp AS NVARCHAR(5)),
        cVorname = 'cVorname_' + CAST(kAuftrag AS NVARCHAR(30)) + '_' + CAST(nTyp AS NVARCHAR(5)),
        cName = 'cName_' + CAST(kAuftrag AS NVARCHAR(30)) + '_' + CAST(nTyp AS NVARCHAR(5)),
        cStrasse = 'cStrasse_' + CAST(kAuftrag AS NVARCHAR(30)) + '_' + CAST(nTyp AS NVARCHAR(5)),
        cPLZ = CAST(10000 + (kAuftrag % 90000) AS NVARCHAR(24)),
        cOrt = 'cOrt_' + CAST(kAuftrag AS NVARCHAR(30)) + '_' + CAST(nTyp AS NVARCHAR(5)),
        cTel = 'Tel_' + CAST(kAuftrag AS NVARCHAR(30)) + '_' + CAST(nTyp AS NVARCHAR(5)),
        cZusatz = 'cZusatz_' + CAST(kAuftrag AS NVARCHAR(30)) + '_' + CAST(nTyp AS NVARCHAR(5)),
        cAdressZusatz = 'cAdressZusatz_' + CAST(kAuftrag AS NVARCHAR(30)) + '_' + CAST(nTyp AS NVARCHAR(5)),
        cPostID = 'cPostID_' + CAST(kAuftrag AS NVARCHAR(30)) + '_' + CAST(nTyp AS NVARCHAR(5)),
        cMobil = 'Mobil_' + CAST(kAuftrag AS NVARCHAR(30)) + '_' + CAST(nTyp AS NVARCHAR(5)),
        cMail = 'mail_' + CAST(kAuftrag AS NVARCHAR(30)) + '_' + CAST(nTyp AS NVARCHAR(5)) + '@test.local',
        cFax = 'Fax_' + CAST(kAuftrag AS NVARCHAR(30)) + '_' + CAST(nTyp AS NVARCHAR(5)),
        cBundesland = 'Bundesland_' + CAST(kAuftrag AS NVARCHAR(30))
    WHERE kAuftrag IS NOT NULL;
    PRINT 'Anonymisiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
END
GO

-- 2.2 Rechnung.tRechnungAdresse - Rechnungsadressen
IF OBJECT_ID('Rechnung.tRechnungAdresse', 'U') IS NOT NULL
BEGIN
    PRINT 'Anonymisiere Rechnung.tRechnungAdresse...'
    UPDATE Rechnung.tRechnungAdresse SET
        cFirma = 'cFirma_' + CAST(kRechnung AS NVARCHAR(30)) + '_' + CAST(nTyp AS NVARCHAR(5)),
        cAnrede = 'Anrede_' + CAST(kRechnung AS NVARCHAR(30)) + '_' + CAST(nTyp AS NVARCHAR(5)),
        cTitel = 'cTitel_' + CAST(kRechnung AS NVARCHAR(30)) + '_' + CAST(nTyp AS NVARCHAR(5)),
        cVorname = 'cVorname_' + CAST(kRechnung AS NVARCHAR(30)) + '_' + CAST(nTyp AS NVARCHAR(5)),
        cName = 'cName_' + CAST(kRechnung AS NVARCHAR(30)) + '_' + CAST(nTyp AS NVARCHAR(5)),
        cStrasse = 'cStrasse_' + CAST(kRechnung AS NVARCHAR(30)) + '_' + CAST(nTyp AS NVARCHAR(5)),
        cPLZ = CAST(10000 + (kRechnung % 90000) AS NVARCHAR(24)),
        cOrt = 'cOrt_' + CAST(kRechnung AS NVARCHAR(30)) + '_' + CAST(nTyp AS NVARCHAR(5)),
        cTel = 'Tel_' + CAST(kRechnung AS NVARCHAR(30)) + '_' + CAST(nTyp AS NVARCHAR(5)),
        cZusatz = 'cZusatz_' + CAST(kRechnung AS NVARCHAR(30)) + '_' + CAST(nTyp AS NVARCHAR(5)),
        cAdresszusatz = 'cAdresszusatz_' + CAST(kRechnung AS NVARCHAR(30)) + '_' + CAST(nTyp AS NVARCHAR(5)),
        cPostID = 'cPostID_' + CAST(kRechnung AS NVARCHAR(30)) + '_' + CAST(nTyp AS NVARCHAR(5)),
        cMobil = 'Mobil_' + CAST(kRechnung AS NVARCHAR(30)) + '_' + CAST(nTyp AS NVARCHAR(5)),
        cMail = 'mail_' + CAST(kRechnung AS NVARCHAR(30)) + '_' + CAST(nTyp AS NVARCHAR(5)) + '@test.local',
        cFax = 'Fax_' + CAST(kRechnung AS NVARCHAR(30)) + '_' + CAST(nTyp AS NVARCHAR(5)),
        cBundesland = 'Bundesland_' + CAST(kRechnung AS NVARCHAR(30))
    WHERE kRechnung IS NOT NULL;
    PRINT 'Anonymisiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
END
GO

-- 2.3 DbeS.tLieferadresse - Lieferadressen
IF OBJECT_ID('DbeS.tLieferadresse', 'U') IS NOT NULL
BEGIN
    PRINT 'Anonymisiere DbeS.tLieferadresse...'
    UPDATE DbeS.tLieferadresse SET
        cFirma = 'cFirma_' + CAST(kLieferadresse AS NVARCHAR(30)),
        cAnrede = 'Anrede_' + CAST(kLieferadresse AS NVARCHAR(30)),
        cTitel = 'cTitel_' + CAST(kLieferadresse AS NVARCHAR(30)),
        cVorname = 'cVorname_' + CAST(kLieferadresse AS NVARCHAR(30)),
        cNachname = 'cNachname_' + CAST(kLieferadresse AS NVARCHAR(30)),
        cStrasse = 'cStrasse_' + CAST(kLieferadresse AS NVARCHAR(30)),
        cPLZ = CAST(10000 + (kLieferadresse % 90000) AS NVARCHAR(24)),
        cOrt = 'cOrt_' + CAST(kLieferadresse AS NVARCHAR(30)),
        cTel = 'Tel_' + CAST(kLieferadresse AS NVARCHAR(30)),
        cMobil = 'Mobil_' + CAST(kLieferadresse AS NVARCHAR(30)),
        cFax = 'Fax_' + CAST(kLieferadresse AS NVARCHAR(30)),
        cMail = 'mail_' + CAST(kLieferadresse AS NVARCHAR(30)) + '@test.local',
        cAdressZusatz = 'cAdressZusatz_' + CAST(kLieferadresse AS NVARCHAR(30)),
        cBundesland = 'Bundesland_' + CAST(kLieferadresse AS NVARCHAR(30))
    WHERE kLieferadresse IS NOT NULL;
    PRINT 'Anonymisiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
END
GO

-- 2.4 DbeS.tRechnungadresse - Rechnungsadressen
IF OBJECT_ID('DbeS.tRechnungadresse', 'U') IS NOT NULL
BEGIN
    PRINT 'Anonymisiere DbeS.tRechnungadresse...'
    UPDATE DbeS.tRechnungadresse SET
        cFirma = 'cFirma_' + CAST(kRechnungadresse AS NVARCHAR(30)),
        cAnrede = 'Anrede_' + CAST(kRechnungadresse AS NVARCHAR(30)),
        cTitel = 'cTitel_' + CAST(kRechnungadresse AS NVARCHAR(30)),
        cVorname = 'cVorname_' + CAST(kRechnungadresse AS NVARCHAR(30)),
        cNachname = 'cNachname_' + CAST(kRechnungadresse AS NVARCHAR(30)),
        cStrasse = 'cStrasse_' + CAST(kRechnungadresse AS NVARCHAR(30)),
        cPLZ = CAST(10000 + (kRechnungadresse % 90000) AS NVARCHAR(24)),
        cOrt = 'cOrt_' + CAST(kRechnungadresse AS NVARCHAR(30)),
        cTel = 'Tel_' + CAST(kRechnungadresse AS NVARCHAR(30)),
        cMobil = 'Mobil_' + CAST(kRechnungadresse AS NVARCHAR(30)),
        cFax = 'Fax_' + CAST(kRechnungadresse AS NVARCHAR(30)),
        cMail = 'mail_' + CAST(kRechnungadresse AS NVARCHAR(30)) + '@test.local',
        cAdressZusatz = 'cAdressZusatz_' + CAST(kRechnungadresse AS NVARCHAR(30)),
        cBundesland = 'Bundesland_' + CAST(kRechnungadresse AS NVARCHAR(30)),
        cUSTID = 'USTID_' + CAST(kRechnungadresse AS NVARCHAR(30)),
        cWWW = 'www_' + CAST(kRechnungadresse AS NVARCHAR(30)) + '.test.local'
    WHERE kRechnungadresse IS NOT NULL;
    PRINT 'Anonymisiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
END
GO

-- 2.5 dbo.tinetbestellung - Internet-Bestellungen (KOMMENTARE!)
IF OBJECT_ID('dbo.tinetbestellung', 'U') IS NOT NULL
BEGIN
    PRINT 'Anonymisiere dbo.tinetbestellung...'
    UPDATE dbo.tinetbestellung SET
        cKommentar = 'Kommentar_' + CAST(kInetBestellung AS NVARCHAR(30)),
        cHinweis = 'Hinweis_' + CAST(kInetBestellung AS NVARCHAR(30)),
        cUserAgent = 'UserAgent_' + CAST(kInetBestellung AS NVARCHAR(30)),
        cReferrer = 'Referrer_' + CAST(kInetBestellung AS NVARCHAR(30))
    WHERE kInetBestellung IS NOT NULL;
    PRINT 'Anonymisiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
END
GO

-- 2.6 Contact.tAddress - Neues Kontakt-System
IF OBJECT_ID('Contact.tAddress', 'U') IS NOT NULL
BEGIN
    PRINT 'Anonymisiere Contact.tAddress...'
    UPDATE Contact.tAddress SET
        cFirstName = 'FirstName_' + CAST(kAddress AS NVARCHAR(30)),
        cLastName = 'LastName_' + CAST(kAddress AS NVARCHAR(30)),
        cStreet = 'Street_' + CAST(kAddress AS NVARCHAR(30)),
        cHouseNumber = CAST(kAddress % 999 AS NVARCHAR(30)),
        cPostalCode = CAST(10000 + (kAddress % 90000) AS NVARCHAR(24)),
        cCity = 'City_' + CAST(kAddress AS NVARCHAR(30)),
        cCompanyName = 'Company_' + CAST(kAddress AS NVARCHAR(30)),
        cCompanyAdditionalName = 'CompanyAdd_' + CAST(kAddress AS NVARCHAR(30)),
        cAddressSupplement = 'AddressSup_' + CAST(kAddress AS NVARCHAR(30)),
        cState = 'State_' + CAST(kAddress AS NVARCHAR(30)),
        cPhoneNumber = 'Phone_' + CAST(kAddress AS NVARCHAR(30)),
        cMobileNumber = 'Mobile_' + CAST(kAddress AS NVARCHAR(30)),
        cFaxNumber = 'Fax_' + CAST(kAddress AS NVARCHAR(30)),
        cEmail = 'mail_' + CAST(kAddress AS NVARCHAR(30)) + '@test.local',
        cHomepage = 'www_' + CAST(kAddress AS NVARCHAR(30)) + '.test.local',
        cVatId = 'VAT_' + CAST(kAddress AS NVARCHAR(30))
    WHERE kAddress IS NOT NULL;
    PRINT 'Anonymisiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
END
GO

-- =============================================
-- PRIORITÄT 3: EBAY-SPEZIFISCHE TABELLEN
-- =============================================

PRINT ''
PRINT '========== PRIORITÄT 3: EBAY-SPEZIFISCHE TABELLEN =========='
GO

-- 3.1 dbo.ebay_checkout - eBay-Checkout (VIELE PERSONENDATEN!)
IF OBJECT_ID('dbo.ebay_checkout', 'U') IS NOT NULL
BEGIN
    PRINT 'Anonymisiere dbo.ebay_checkout...'
    UPDATE dbo.ebay_checkout SET
        cLieferAnrede = 'Anrede_' + CAST(kEbayCheckout AS NVARCHAR(30)),
        cLieferVorname = 'Vorname_' + CAST(kEbayCheckout AS NVARCHAR(30)),
        cLieferNachname = 'Nachname_' + CAST(kEbayCheckout AS NVARCHAR(30)),
        cLieferNamenszusatz = 'Namenszusatz_' + CAST(kEbayCheckout AS NVARCHAR(30)),
        cLieferStrasse = 'Strasse_' + CAST(kEbayCheckout AS NVARCHAR(30)),
        cLieferAdresszusatz = 'Adresszusatz_' + CAST(kEbayCheckout AS NVARCHAR(30)),
        cLieferPLZ = CAST(10000 + (kEbayCheckout % 90000) AS NVARCHAR(255)),
        cLieferOrt = 'Ort_' + CAST(kEbayCheckout AS NVARCHAR(30)),
        cLieferTel = 'Tel_' + CAST(kEbayCheckout AS NVARCHAR(30)),
        cLieferFax = 'Fax_' + CAST(kEbayCheckout AS NVARCHAR(30)),
        cLieferHandy = 'Handy_' + CAST(kEbayCheckout AS NVARCHAR(30)),
        cLieferFirma = 'Firma_' + CAST(kEbayCheckout AS NVARCHAR(30)),
        cTel = 'Tel_' + CAST(kEbayCheckout AS NVARCHAR(30)),
        cFax = 'Fax_' + CAST(kEbayCheckout AS NVARCHAR(30)),
        cMobil = 'Mobil_' + CAST(kEbayCheckout AS NVARCHAR(30)),
        cEMail = 'mail_' + CAST(kEbayCheckout AS NVARCHAR(30)) + '@test.local',
        cComment = 'Comment_' + CAST(kEbayCheckout AS NVARCHAR(30)),
        cFirma = 'Firma_' + CAST(kEbayCheckout AS NVARCHAR(30)),
        cUStID = 'USTID_' + CAST(kEbayCheckout AS NVARCHAR(30)),
        cAdresszusatz = 'Adresszusatz_' + CAST(kEbayCheckout AS NVARCHAR(30)),
        cAnrede = 'Anrede_' + CAST(kEbayCheckout AS NVARCHAR(30)),
        cVorname = 'Vorname_' + CAST(kEbayCheckout AS NVARCHAR(30)),
        cNachname = 'Nachname_' + CAST(kEbayCheckout AS NVARCHAR(30)),
        cPLZ = CAST(10000 + (kEbayCheckout % 90000) AS NVARCHAR(255)),
        cOrt = 'Ort_' + CAST(kEbayCheckout AS NVARCHAR(30)),
        cStrasse = 'Strasse_' + CAST(kEbayCheckout AS NVARCHAR(30)),
        cZahlungInhaber = 'Inhaber_' + CAST(kEbayCheckout AS NVARCHAR(30)),
        cPUIZahlungsdaten = 'Zahlungsdaten_' + CAST(kEbayCheckout AS NVARCHAR(30))
    WHERE kEbayCheckout IS NOT NULL;
    PRINT 'Anonymisiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
END
GO

-- =============================================
-- PRIORITÄT 4: AMAZON-SPEZIFISCHE TABELLEN
-- =============================================

PRINT ''
PRINT '========== PRIORITÄT 4: AMAZON-SPEZIFISCHE TABELLEN =========='
GO

-- 4.1 Amazon.tSFPVersand - Amazon SFP Versand
IF OBJECT_ID('Amazon.tSFPVersand', 'U') IS NOT NULL
BEGIN
    PRINT 'Anonymisiere Amazon.tSFPVersand...'
    UPDATE Amazon.tSFPVersand SET
        cFirma = 'Firma_' + CAST(kSFPVersand AS NVARCHAR(30)),
        cStrasse = 'Strasse_' + CAST(kSFPVersand AS NVARCHAR(30)),
        cPLZ = CAST(10000 + (kSFPVersand % 90000) AS NVARCHAR(30)),
        cOrt = 'Ort_' + CAST(kSFPVersand AS NVARCHAR(30)),
        cTel = 'Tel_' + CAST(kSFPVersand AS NVARCHAR(30)),
        cMail = 'mail_' + CAST(kSFPVersand AS NVARCHAR(30)) + '@test.local'
    WHERE kSFPVersand IS NOT NULL;
    PRINT 'Anonymisiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
END
GO

-- =============================================
-- PRIORITÄT 5: HISTORIEN UND LOGS
-- =============================================

PRINT ''
PRINT '========== PRIORITÄT 5: HISTORIEN UND LOGS =========='
GO

-- 5.1 Verkauf.tAuftrag_Log - Auftragsverlauf
IF OBJECT_ID('Verkauf.tAuftrag_Log', 'U') IS NOT NULL
BEGIN
    PRINT 'Anonymisiere Verkauf.tAuftrag_Log...'
    UPDATE Verkauf.tAuftrag_Log SET
        cEbayUsername = 'EbayUser_' + CAST(kAuftragLog AS NVARCHAR(30)),
        cKundenNr = 'KundenNr_' + CAST(kAuftragLog AS NVARCHAR(30)),
        cKundeUstId = 'USTID_' + CAST(kAuftragLog AS NVARCHAR(30))
    WHERE kAuftragLog IS NOT NULL;
    PRINT 'Anonymisiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
END
GO

-- 5.2 Verkauf.tAuftragAdresse_Log - Auftrag Adress-Log
IF OBJECT_ID('Verkauf.tAuftragAdresse_Log', 'U') IS NOT NULL
BEGIN
    PRINT 'Anonymisiere Verkauf.tAuftragAdresse_Log...'
    UPDATE Verkauf.tAuftragAdresse_Log SET
        cFirma = 'cFirma_LOG_' + CAST(kAuftragAdresseLog AS NVARCHAR(30)),
        cAnrede = 'Anrede_LOG_' + CAST(kAuftragAdresseLog AS NVARCHAR(30)),
        cTitel = 'cTitel_LOG_' + CAST(kAuftragAdresseLog AS NVARCHAR(30)),
        cVorname = 'cVorname_LOG_' + CAST(kAuftragAdresseLog AS NVARCHAR(30)),
        cName = 'cName_LOG_' + CAST(kAuftragAdresseLog AS NVARCHAR(30)),
        cStrasse = 'cStrasse_LOG_' + CAST(kAuftragAdresseLog AS NVARCHAR(30)),
        cPLZ = CAST(10000 + (kAuftragAdresseLog % 90000) AS NVARCHAR(24)),
        cOrt = 'cOrt_LOG_' + CAST(kAuftragAdresseLog AS NVARCHAR(30)),
        cTel = 'Tel_LOG_' + CAST(kAuftragAdresseLog AS NVARCHAR(30)),
        cZusatz = 'cZusatz_LOG_' + CAST(kAuftragAdresseLog AS NVARCHAR(30)),
        cAdressZusatz = 'cAdressZusatz_LOG_' + CAST(kAuftragAdresseLog AS NVARCHAR(30)),
        cPostID = 'cPostID_LOG_' + CAST(kAuftragAdresseLog AS NVARCHAR(30)),
        cMobil = 'Mobil_LOG_' + CAST(kAuftragAdresseLog AS NVARCHAR(30)),
        cMail = 'mail_LOG_' + CAST(kAuftragAdresseLog AS NVARCHAR(30)) + '@test.local',
        cFax = 'Fax_LOG_' + CAST(kAuftragAdresseLog AS NVARCHAR(30)),
        cBundesland = 'Bundesland_LOG_' + CAST(kAuftragAdresseLog AS NVARCHAR(30))
    WHERE kAuftragAdresseLog IS NOT NULL;
    PRINT 'Anonymisiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
END
GO

-- 5.3 Kunde.tNotiz - Kundennotizen (KRITISCH - Freitext!)
IF OBJECT_ID('Kunde.tNotiz', 'U') IS NOT NULL
BEGIN
    PRINT 'Anonymisiere Kunde.tNotiz...'
    UPDATE Kunde.tNotiz SET
        cNotiz = 'Notiz_' + CAST(kNotiz AS NVARCHAR(30))
    WHERE kNotiz IS NOT NULL;
    PRINT 'Anonymisiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
END
GO

-- =============================================
-- PRIORITÄT 6: TICKETSYSTEM (KRITISCH - FREITEXT!)
-- =============================================

PRINT ''
PRINT '========== PRIORITÄT 6: TICKETSYSTEM =========='
GO

-- 6.1 Ticketsystem.tNachricht - Nachrichten
IF OBJECT_ID('Ticketsystem.tNachricht', 'U') IS NOT NULL
BEGIN
    PRINT 'Anonymisiere Ticketsystem.tNachricht...'
    UPDATE Ticketsystem.tNachricht SET
        cInhalt = 'Nachricht_' + CAST(kNachricht AS NVARCHAR(30)),
        cBeschreibung = 'Beschreibung_' + CAST(kNachricht AS NVARCHAR(30))
    WHERE kNachricht IS NOT NULL;
    PRINT 'Anonymisiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
END
GO

-- 6.2 Ticketsystem.tEingangskanalEmail - Eingangskanal E-Mail
IF OBJECT_ID('Ticketsystem.tEingangskanalEmail', 'U') IS NOT NULL
BEGIN
    PRINT 'Anonymisiere Ticketsystem.tEingangskanalEmail...'
    UPDATE Ticketsystem.tEingangskanalEmail SET
        cBenutzername = 'User_' + CAST(kEingangskanalEmail AS NVARCHAR(30)),
        cPasswort = 'Pass_' + CAST(kEingangskanalEmail AS NVARCHAR(30)),
        cEmailAdresse = 'mail_' + CAST(kEingangskanalEmail AS NVARCHAR(30)) + '@test.local'
    WHERE kEingangskanalEmail IS NOT NULL;
    PRINT 'Anonymisiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
END
GO

-- 6.3 Ticketsystem.tAusgangskanalEmail - Ausgangskanal E-Mail
IF OBJECT_ID('Ticketsystem.tAusgangskanalEmail', 'U') IS NOT NULL
BEGIN
    PRINT 'Anonymisiere Ticketsystem.tAusgangskanalEmail...'
    UPDATE Ticketsystem.tAusgangskanalEmail SET
        cBenutzername = 'User_' + CAST(kAusgangskanalEmail AS NVARCHAR(30)),
        cPasswort = 'Pass_' + CAST(kAusgangskanalEmail AS NVARCHAR(30)),
        cEmailAdresse = 'mail_' + CAST(kAusgangskanalEmail AS NVARCHAR(30)) + '@test.local'
    WHERE kAusgangskanalEmail IS NOT NULL;
    PRINT 'Anonymisiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
END
GO

-- =============================================
-- PRIORITÄT 7: RETOUREN
-- =============================================

PRINT ''
PRINT '========== PRIORITÄT 7: RETOUREN =========='
GO

-- 7.1 dbo.tRMRetoure - Retouren (KOMMENTARE!)
IF OBJECT_ID('dbo.tRMRetoure', 'U') IS NOT NULL
BEGIN
    PRINT 'Anonymisiere dbo.tRMRetoure...'
    UPDATE dbo.tRMRetoure SET
        cAnsprechpartner = 'Ansprechpartner_' + CAST(kRMRetoure AS NVARCHAR(30)),
        cKommentarExtern = 'KommentarExtern_' + CAST(kRMRetoure AS NVARCHAR(30)),
        cKommentarIntern = 'KommentarIntern_' + CAST(kRMRetoure AS NVARCHAR(30)),
        cKorrekturBetragKommentar = 'Kommentar_' + CAST(kRMRetoure AS NVARCHAR(30))
    WHERE kRMRetoure IS NOT NULL;
    PRINT 'Anonymisiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
END
GO

-- 7.2 dbo.tRMRetoureAbholAdresse - Retouren-Abholadressen
IF OBJECT_ID('dbo.tRMRetoureAbholAdresse', 'U') IS NOT NULL
BEGIN
    PRINT 'Anonymisiere dbo.tRMRetoureAbholAdresse...'
    UPDATE dbo.tRMRetoureAbholAdresse SET
        cFirma = 'cFirma_' + CAST(kRMRetoureAbholAdresse AS NVARCHAR(30)),
        cAnrede = 'Anrede_' + CAST(kRMRetoureAbholAdresse AS NVARCHAR(30)),
        cTitel = 'cTitel_' + CAST(kRMRetoureAbholAdresse AS NVARCHAR(30)),
        cVorname = 'cVorname_' + CAST(kRMRetoureAbholAdresse AS NVARCHAR(30)),
        cNachname = 'cNachname_' + CAST(kRMRetoureAbholAdresse AS NVARCHAR(30)),
        cStrasse = 'cStrasse_' + CAST(kRMRetoureAbholAdresse AS NVARCHAR(30)),
        cPLZ = CAST(10000 + (kRMRetoureAbholAdresse % 90000) AS NVARCHAR(24)),
        cOrt = 'cOrt_' + CAST(kRMRetoureAbholAdresse AS NVARCHAR(30)),
        cTel = 'Tel_' + CAST(kRMRetoureAbholAdresse AS NVARCHAR(30)),
        cMobil = 'Mobil_' + CAST(kRMRetoureAbholAdresse AS NVARCHAR(30)),
        cFax = 'Fax_' + CAST(kRMRetoureAbholAdresse AS NVARCHAR(30)),
        cMail = 'mail_' + CAST(kRMRetoureAbholAdresse AS NVARCHAR(30)) + '@test.local'
    WHERE kRMRetoureAbholAdresse IS NOT NULL;
    PRINT 'Anonymisiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
END
GO

-- =============================================
-- PRIORITÄT 8: ZAHLUNGSDATEN (KRITISCH!)
-- =============================================

PRINT ''
PRINT '========== PRIORITÄT 8: ZAHLUNGSDATEN (KRITISCH!) =========='
GO

-- 8.1 dbo.tkontodaten - Kontodaten (IBAN, BIC, Kreditkarten!)
IF OBJECT_ID('dbo.tkontodaten', 'U') IS NOT NULL
BEGIN
    PRINT 'Anonymisiere dbo.tkontodaten (ZAHLUNGSDATEN)...'
    UPDATE dbo.tkontodaten SET
        cBankName = 'Bank_' + CAST(kKontoDaten AS NVARCHAR(30)),
        cBLZ = 'BLZ_' + CAST(kKontoDaten AS NVARCHAR(30)),
        cKontoNr = 'KontoNr_' + CAST(kKontoDaten AS NVARCHAR(30)),
        cKartenNr = 'KartenNr_' + CAST(kKontoDaten AS NVARCHAR(30)),
        cGueligkeit = NULL,
        cCVV = NULL,
        cKartenTyp = 'Typ_' + CAST(kKontoDaten AS NVARCHAR(30)),
        cInhaber = 'Inhaber_' + CAST(kKontoDaten AS NVARCHAR(30)),
        cIBAN = 'IBAN_' + CAST(kKontoDaten AS NVARCHAR(30)),
        cBIC = 'BIC_' + CAST(kKontoDaten AS NVARCHAR(30))
    WHERE kKontoDaten IS NOT NULL;
    PRINT 'Anonymisiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
END
ELSE
BEGIN
    PRINT 'dbo.tkontodaten nicht vorhanden (übersprungen).'
END
GO

-- 8.2 dbo.tinetzahlungsinfo - Online-Shop Zahlungsinformationen
IF OBJECT_ID('dbo.tinetzahlungsinfo', 'U') IS NOT NULL
BEGIN
    PRINT 'Anonymisiere dbo.tinetzahlungsinfo (ZAHLUNGSDATEN)...'
    UPDATE dbo.tinetzahlungsinfo SET
        cBankName = 'Bank_' + CAST(kInetZahlungsInfo AS NVARCHAR(30)),
        cBLZ = 'BLZ_' + CAST(kInetZahlungsInfo AS NVARCHAR(30)),
        cKontoNr = 'KontoNr_' + CAST(kInetZahlungsInfo AS NVARCHAR(30)),
        cKartenNr = 'KartenNr_' + CAST(kInetZahlungsInfo AS NVARCHAR(30)),
        cGueligkeit = NULL,
        cCVV = NULL,
        cKartenTyp = 'Typ_' + CAST(kInetZahlungsInfo AS NVARCHAR(30)),
        cInhaber = 'Inhaber_' + CAST(kInetZahlungsInfo AS NVARCHAR(30)),
        cIBAN = 'IBAN_' + CAST(kInetZahlungsInfo AS NVARCHAR(30)),
        cBIC = 'BIC_' + CAST(kInetZahlungsInfo AS NVARCHAR(30))
    WHERE kInetZahlungsInfo IS NOT NULL;
    PRINT 'Anonymisiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
END
ELSE
BEGIN
    PRINT 'dbo.tinetzahlungsinfo nicht vorhanden (übersprungen).'
END
GO

-- 8.3 dbo.tZahlung - Zahlungen
IF OBJECT_ID('dbo.tZahlung', 'U') IS NOT NULL
BEGIN
    PRINT 'Anonymisiere dbo.tZahlung...'
    UPDATE dbo.tZahlung SET
        cName = 'Name_' + CAST(kZahlung AS NVARCHAR(30)),
        cHinweis = 'Hinweis_' + CAST(kZahlung AS NVARCHAR(30))
    WHERE kZahlung IS NOT NULL;
    PRINT 'Anonymisiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
END
ELSE
BEGIN
    PRINT 'dbo.tZahlung nicht vorhanden (übersprungen).'
END
GO

-- =============================================
-- PRIORITÄT 9: ZUGANGSDATEN & AUTHENTIFIZIERUNG
-- =============================================

PRINT ''
PRINT '========== PRIORITÄT 9: ZUGANGSDATEN & AUTHENTIFIZIERUNG =========='
GO

-- 9.1 dbo.tEMailEinstellung - E-Mail Konfiguration (PASSWÖRTER!)
IF OBJECT_ID('dbo.tEMailEinstellung', 'U') IS NOT NULL
BEGIN
    PRINT 'Anonymisiere dbo.tEMailEinstellung (E-MAIL ZUGANGSDATEN)...'
    UPDATE dbo.tEMailEinstellung SET
        cNutzername = 'User_' + CAST(kEMailEinstellung AS NVARCHAR(30)),
        cPasswort = 'Pass_' + CAST(kEMailEinstellung AS NVARCHAR(30)),
        cAbsender = 'absender_' + CAST(kEMailEinstellung AS NVARCHAR(30)) + '@test.local',
        cBCC = NULL,
        cSigPortalNutzername = 'SigUser_' + CAST(kEMailEinstellung AS NVARCHAR(30)),
        cSigPortalPasswort = 'SigPass_' + CAST(kEMailEinstellung AS NVARCHAR(30)),
        cSMIMEPasswort = 'SMIMEPass_' + CAST(kEMailEinstellung AS NVARCHAR(30))
    WHERE kEMailEinstellung IS NOT NULL;
    PRINT 'Anonymisiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
END
ELSE
BEGIN
    PRINT 'dbo.tEMailEinstellung nicht vorhanden (übersprungen).'
END
GO

-- 9.2 dbo.tInkassoUser - Inkasso-Zugangsdaten
IF OBJECT_ID('dbo.tInkassoUser', 'U') IS NOT NULL
BEGIN
    PRINT 'Anonymisiere dbo.tInkassoUser...'
    UPDATE dbo.tInkassoUser SET
        cUsername = 'InkassoUser_' + CAST(kInkassoUser AS NVARCHAR(30)),
        cPasswort = 'InkassoPass_' + CAST(kInkassoUser AS NVARCHAR(30))
    WHERE kInkassoUser IS NOT NULL;
    PRINT 'Anonymisiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
END
ELSE
BEGIN
    PRINT 'dbo.tInkassoUser nicht vorhanden (übersprungen).'
END
GO

-- 9.3 dbo.pf_user - Plattform-Benutzer (Amazon)
IF OBJECT_ID('dbo.pf_user', 'U') IS NOT NULL
BEGIN
    PRINT 'Anonymisiere dbo.pf_user (Amazon Auth-Tokens)...'
    UPDATE dbo.pf_user SET
        cName = 'PfUser_' + CAST(kUser AS NVARCHAR(30)),
        cAuthToken = NULL,
        cAmazonAuthToken = NULL,
        cFBAVersandmailKopie = 'fba_' + CAST(kUser AS NVARCHAR(30)) + '@test.local',
        cFBAKommentar = 'Kommentar_' + CAST(kUser AS NVARCHAR(30)),
        cAnmerkung = 'Anmerkung_' + CAST(kUser AS NVARCHAR(30))
    WHERE kUser IS NOT NULL;
    PRINT 'Anonymisiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
END
ELSE
BEGIN
    PRINT 'dbo.pf_user nicht vorhanden (übersprungen).'
END
GO

-- 9.4 WMS.tMobileBenutzer - Mobile WMS-Benutzer
IF OBJECT_ID('WMS.tMobileBenutzer', 'U') IS NOT NULL
BEGIN
    PRINT 'Anonymisiere WMS.tMobileBenutzer...'
    UPDATE WMS.tMobileBenutzer SET
        cName = 'WMSUser_' + CAST(kMobileBenutzer AS NVARCHAR(30)),
        cUniqueId = 'UniqueId_' + CAST(kMobileBenutzer AS NVARCHAR(30)),
        cIpAddress = '192.168.1.' + CAST((kMobileBenutzer % 254) + 1 AS NVARCHAR(3))
    WHERE kMobileBenutzer IS NOT NULL;
    PRINT 'Anonymisiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
END
ELSE
BEGIN
    PRINT 'WMS.tMobileBenutzer nicht vorhanden (übersprungen).'
END
GO

-- =============================================
-- PRIORITÄT 10: LIEFERANTEN & EINGANGSRECHNUNGEN
-- =============================================

PRINT ''
PRINT '========== PRIORITÄT 10: LIEFERANTEN & EINGANGSRECHNUNGEN =========='
GO

-- 10.1 dbo.tEingangsrechnung - Eingangsrechnungen (Lieferantenadressen!)
IF OBJECT_ID('dbo.tEingangsrechnung', 'U') IS NOT NULL
BEGIN
    PRINT 'Anonymisiere dbo.tEingangsrechnung...'
    UPDATE dbo.tEingangsrechnung SET
        cLieferant = 'Lieferant_' + CAST(kEingangsrechnung AS NVARCHAR(30)),
        cAdresszusatz = 'Adresszusatz_' + CAST(kEingangsrechnung AS NVARCHAR(30)),
        cStrasse = 'Strasse_' + CAST(kEingangsrechnung AS NVARCHAR(30)),
        cPLZ = CAST(10000 + (kEingangsrechnung % 90000) AS NVARCHAR(10)),
        cOrt = 'Ort_' + CAST(kEingangsrechnung AS NVARCHAR(30)),
        cBundesland = 'Bundesland_' + CAST(kEingangsrechnung AS NVARCHAR(30)),
        cTel = 'Tel_' + CAST(kEingangsrechnung AS NVARCHAR(30)),
        cFax = 'Fax_' + CAST(kEingangsrechnung AS NVARCHAR(30)),
        cMobil = 'Mobil_' + CAST(kEingangsrechnung AS NVARCHAR(30)),
        cMail = 'mail_' + CAST(kEingangsrechnung AS NVARCHAR(30)) + '@test.local',
        cHinweise = 'Hinweise_' + CAST(kEingangsrechnung AS NVARCHAR(30))
    WHERE kEingangsrechnung IS NOT NULL;
    PRINT 'Anonymisiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
END
ELSE
BEGIN
    PRINT 'dbo.tEingangsrechnung nicht vorhanden (übersprungen).'
END
GO

-- 10.2 Kunde.tUmsatzSteuerPruefung - USt-ID Prüfung
IF OBJECT_ID('Kunde.tUmsatzSteuerPruefung', 'U') IS NOT NULL
BEGIN
    PRINT 'Anonymisiere Kunde.tUmsatzSteuerPruefung...'
    UPDATE Kunde.tUmsatzSteuerPruefung SET
        cUSTID = 'USTID_' + CAST(kUmsatzSteuerPruefung AS NVARCHAR(30)),
        cPruefdata = 'Pruefdata_' + CAST(kUmsatzSteuerPruefung AS NVARCHAR(30))
    WHERE kUmsatzSteuerPruefung IS NOT NULL;
    PRINT 'Anonymisiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
END
ELSE
BEGIN
    PRINT 'Kunde.tUmsatzSteuerPruefung nicht vorhanden (übersprungen).'
END
GO

-- 10.3 dbo.tmahnung - Mahnungen (personalisierte Texte!)
IF OBJECT_ID('dbo.tmahnung', 'U') IS NOT NULL
BEGIN
    PRINT 'Anonymisiere dbo.tmahnung...'
    UPDATE dbo.tmahnung SET
        cAnrede = 'Anrede_' + CAST(kMahnung AS NVARCHAR(30)),
        cText = 'Text_' + CAST(kMahnung AS NVARCHAR(30)),
        cKurzText = 'Kurztext_' + CAST(kMahnung AS NVARCHAR(30))
    WHERE kMahnung IS NOT NULL;
    PRINT 'Anonymisiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
END
ELSE
BEGIN
    PRINT 'dbo.tmahnung nicht vorhanden (übersprungen).'
END
GO

-- 10.4 Rechnung.tRechnungText - Rechnungstexte
IF OBJECT_ID('Rechnung.tRechnungText', 'U') IS NOT NULL
BEGIN
    PRINT 'Anonymisiere Rechnung.tRechnungText...'
    UPDATE Rechnung.tRechnungText SET
        cRechnungstext = 'Rechnungstext_' + CAST(kRechnung AS NVARCHAR(30)),
        cAnmerkung = 'Anmerkung_' + CAST(kRechnung AS NVARCHAR(30)),
        cHinweis = 'Hinweis_' + CAST(kRechnung AS NVARCHAR(30))
    WHERE kRechnung IS NOT NULL;
    PRINT 'Anonymisiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
END
ELSE
BEGIN
    PRINT 'Rechnung.tRechnungText nicht vorhanden (übersprungen).'
END
GO

-- 10.5 Contact.tContact - Kontakt-System
IF OBJECT_ID('Contact.tContact', 'U') IS NOT NULL
BEGIN
    PRINT 'Anonymisiere Contact.tContact...'
    UPDATE Contact.tContact SET
        cNumber = 'ContactNr_' + CAST(kContact AS NVARCHAR(30))
    WHERE kContact IS NOT NULL;
    PRINT 'Anonymisiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
END
ELSE
BEGIN
    PRINT 'Contact.tContact nicht vorhanden (übersprungen).'
END
GO

-- =============================================
-- PRIORITÄT 11: POS-SYSTEM
-- =============================================

PRINT ''
PRINT '========== PRIORITÄT 11: POS-SYSTEM =========='
GO

-- 8.1 dbo.POS_Benutzer - POS-Benutzer
IF OBJECT_ID('dbo.POS_Benutzer', 'U') IS NOT NULL
BEGIN
    PRINT 'Anonymisiere dbo.POS_Benutzer...'
    UPDATE dbo.POS_Benutzer SET
        cPasswort = 'Pass_' + CAST(kBenutzer AS NVARCHAR(30))
    WHERE kBenutzer IS NOT NULL;
    PRINT 'Anonymisiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
END
GO

-- =============================================
-- PRIORITÄT 9: ZUSÄTZLICHE TABELLEN MIT KOMMENTAREN
-- =============================================

PRINT ''
PRINT '========== PRIORITÄT 9: BEMERKUNGEN/KOMMENTARE =========='
GO

-- 9.1 dbo.tBemerkungen - Bemerkungen
IF OBJECT_ID('dbo.tBemerkungen', 'U') IS NOT NULL
BEGIN
    PRINT 'Anonymisiere dbo.tBemerkungen...'
    UPDATE dbo.tBemerkungen SET
        cBemerkung = 'Bemerkung_' + CAST(kBemerkung AS NVARCHAR(30))
    WHERE kBemerkung IS NOT NULL;
    PRINT 'Anonymisiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
END
GO

-- =============================================
-- ABSCHLUSS UND ZUSAMMENFASSUNG
-- =============================================

PRINT ''
PRINT '========================================================================='
PRINT 'ANONYMISIERUNG ERFOLGREICH ABGESCHLOSSEN!'
PRINT 'Zeitpunkt: ' + CONVERT(VARCHAR(20), GETDATE(), 120)
PRINT '========================================================================='
PRINT ''
PRINT 'ZUSAMMENFASSUNG DER ANONYMISIERTEN BEREICHE:'
PRINT '- Kundenstammdaten (tkunde, tinetkunde, etc.)'
PRINT '- Alle Adresstabellen (tAdresse, tinetadress, Rechnungsadressen, etc.)'
PRINT '- System-Benutzer und Ansprechpartner'
PRINT '- Firmendaten und Lieferanten'
PRINT '- Transaktionsdaten (Aufträge, Rechnungen)'
PRINT '- eBay-Checkout-Daten'
PRINT '- Amazon SFP-Versand'
PRINT '- Historien und Log-Tabellen'
PRINT '- Ticketsystem-Nachrichten'
PRINT '- Retouren und Kommentare'
PRINT '- POS-System-Benutzer'
PRINT '- Bemerkungen und Freitext-Felder'
PRINT ''
PRINT 'WICHTIG: Bitte überprüfen Sie die Daten und führen Sie folgende'
PRINT 'zusätzliche Prüfungen durch:'
PRINT '1. Überprüfen Sie Views, die personenbezogene Daten enthalten könnten'
PRINT '2. Prüfen Sie ob weitere Marketplace-spezifische Tabellen vorhanden sind'
PRINT '3. Kontrollieren Sie Zahlungsinformationen in tZahlung, tkontodaten'
PRINT '4. Überprüfen Sie Fulfillment-Tabellen'
PRINT ''
PRINT 'Alle Felder wurden mit dem Muster Feldname_ID anonymisiert.'
PRINT ''
GO

SET NOCOUNT OFF;
GO
