-- reset.internal_AnonymizeCustomerData  (Ebene B / global — pipeline step, job-only)
--
-- Ported from Projekte/Testsystem/clear-customer-fields.sql. Replaces all PII with
-- deterministic "Field_<id>" placeholders across the JTL schema. Structured as the
-- source's 11 priority blocks; each block runs as one batch in the TARGET database
-- (QUOTENAME(@TargetDb).sys.sp_executesql — no USE), logs "anon.P<n> ok" to
-- ops.ResetRequest.StepLog on success, and any error in a block THROWs and breaks the
-- pipeline (no "half anonymized, silently continue"). The trigger-protected tables
-- (tkunde, tAdresse) keep the source's CONTEXT_INFO trigger-bypass. All values are
-- derived from columns only — nothing external is concatenated (only @TargetDb, via
-- QUOTENAME). tKunde_suche uses DELETE, not TRUNCATE (vendor-table rule).
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§3)
-- @see Projekte/Testsystem/clear-customer-fields.sql (source of the block mapping)
CREATE OR ALTER PROCEDURE reset.internal_AnonymizeCustomerData
    @TargetDb   sysname,
    @RequestId  int,
    @MandantKey sysname   -- uniform step contract (EXT-2); not used by this step
AS
BEGIN
    SET NOCOUNT ON;

    IF @TargetDb = N'eazybusiness' OR @TargetDb NOT LIKE N'eazybusiness[_]%'
        THROW 51050, 'internal_AnonymizeCustomerData refused: target is not a test-mandant clone.', 1;

    DECLARE @exec nvarchar(300) = QUOTENAME(@TargetDb) + N'.sys.sp_executesql';
    DECLARE @b nvarchar(max);

    -- ===== PRIORITY 1: core person data ==========================================
    -- The trigger-bypass CONTEXT_INFO must be cleared even if a statement inside this
    -- batch throws (PAR-3): otherwise the bypass token leaks into the session. Mirror
    -- the legacy clear-customer-fields.sql CATCH that reset it to 0x0.
    SET @b = N'
        BEGIN TRY
        DECLARE @h varbinary(128);
        SELECT @h = HASHBYTES(''SHA1'', ''Kunde.spKundeUpdate'');
        SET CONTEXT_INFO @h;
        UPDATE dbo.tkunde SET
            cEbayName = ''cEbayName_'' + CAST(kKunde AS NVARCHAR(30)),
            cGeburtstag = NULL,
            cWWW = ''cWWW_'' + CAST(kKunde AS NVARCHAR(30)),
            cHerkunft = ''cHerkunft_'' + CAST(kKunde AS NVARCHAR(30)),
            cHRNr = ''cHRNr_'' + CAST(kKunde AS NVARCHAR(30)),
            cSteuerNr = ''cSteuerNr_'' + CAST(kKunde AS NVARCHAR(30))
        WHERE kKunde IS NOT NULL;
        SET CONTEXT_INFO 0x0;

        IF OBJECT_ID(''dbo.tKunde_suche'', ''U'') IS NOT NULL DELETE FROM dbo.tKunde_suche;

        UPDATE dbo.tinetkunde SET
            cBenutzername = ''User_'' + CAST(kInetKunde AS NVARCHAR(20)),
            cPasswort = ''Pass_'' + CAST(kInetKunde AS NVARCHAR(20)),
            cAnrede = ''Anrede_'' + CAST(kInetKunde AS NVARCHAR(20)),
            cVorname = ''cVorname_'' + CAST(kInetKunde AS NVARCHAR(20)),
            cNachname = ''cNachname_'' + CAST(kInetKunde AS NVARCHAR(20)),
            cFirma = ''cFirma_'' + CAST(kInetKunde AS NVARCHAR(20)),
            cStrasse = ''cStrasse_'' + CAST(kInetKunde AS NVARCHAR(20)),
            cPLZ = CAST(10000 + (kInetKunde % 90000) AS NVARCHAR(20)),
            cStadt = ''cStadt_'' + CAST(kInetKunde AS NVARCHAR(20)),
            cTel = ''Tel_'' + CAST(kInetKunde AS NVARCHAR(20)),
            cFax = ''Fax_'' + CAST(kInetKunde AS NVARCHAR(20)),
            cMail = ''mail_'' + CAST(kInetKunde AS NVARCHAR(20)) + ''@test.local'',
            cMobil = ''Mobil_'' + CAST(kInetKunde AS NVARCHAR(20)),
            cAdressZusatz = ''cAdressZusatz_'' + CAST(kInetKunde AS NVARCHAR(20)),
            cGeburtstag = NULL,
            cWWW = ''www_'' + CAST(kInetKunde AS NVARCHAR(20)) + ''.test.local'',
            cHerkunft = ''cHerkunft_'' + CAST(kInetKunde AS NVARCHAR(20)),
            cZusatz = ''cZusatz_'' + CAST(kInetKunde AS NVARCHAR(20)),
            cTitel = ''cTitel_'' + CAST(kInetKunde AS NVARCHAR(20)),
            cUSTID = ''USTID_'' + CAST(kInetKunde AS NVARCHAR(20)),
            cBundesland = ''Bundesland_'' + CAST(kInetKunde AS NVARCHAR(20))
        WHERE kInetKunde IS NOT NULL;

        DECLARE @ha varbinary(128);
        SELECT @ha = HASHBYTES(''SHA1'', ''dbo.spAdresseUpdate'');
        SET CONTEXT_INFO @ha;
        UPDATE dbo.tAdresse SET
            cFirma = ''cFirma_'' + CAST(kAdresse AS NVARCHAR(30)),
            cAnrede = ''Anrede_'' + CAST(kAdresse AS NVARCHAR(30)),
            cTitel = ''cTitel_'' + CAST(kAdresse AS NVARCHAR(30)),
            cVorname = ''cVorname_'' + CAST(kAdresse AS NVARCHAR(30)),
            cName = ''cName_'' + CAST(kAdresse AS NVARCHAR(30)),
            cStrasse = ''cStrasse_'' + CAST(kAdresse AS NVARCHAR(30)),
            cPLZ = CAST(10000 + (kAdresse % 90000) AS NVARCHAR(24)),
            cOrt = ''cOrt_'' + CAST(kAdresse AS NVARCHAR(30)),
            cTel = ''Tel_'' + CAST(kAdresse AS NVARCHAR(30)),
            cZusatz = ''cZusatz_'' + CAST(kAdresse AS NVARCHAR(30)),
            cAdressZusatz = ''cAdressZusatz_'' + CAST(kAdresse AS NVARCHAR(30)),
            cPostID = ''cPostID_'' + CAST(kAdresse AS NVARCHAR(30)),
            cMobil = ''Mobil_'' + CAST(kAdresse AS NVARCHAR(30)),
            cMail = ''mail_'' + CAST(kAdresse AS NVARCHAR(30)) + ''@test.local'',
            cFax = ''Fax_'' + CAST(kAdresse AS NVARCHAR(30)),
            cBundesland = ''Bundesland_'' + CAST(kAdresse AS NVARCHAR(30)),
            cUSTID = ''USTID_'' + CAST(kAdresse AS NVARCHAR(30))
        WHERE kAdresse IS NOT NULL;
        SET CONTEXT_INFO 0x0;

        IF OBJECT_ID(''dbo.tinetadress'', ''U'') IS NOT NULL
        UPDATE dbo.tinetadress SET
            cFirma = ''cFirma_'' + CAST(kInetAdress AS NVARCHAR(30)),
            cAnrede = ''Anrede_'' + CAST(kInetAdress AS NVARCHAR(30)),
            cTitel = ''cTitel_'' + CAST(kInetAdress AS NVARCHAR(30)),
            cVorname = ''cVorname_'' + CAST(kInetAdress AS NVARCHAR(30)),
            cNachname = ''cNachname_'' + CAST(kInetAdress AS NVARCHAR(30)),
            cStrasse = ''cStrasse_'' + CAST(kInetAdress AS NVARCHAR(30)),
            cPLZ = CAST(10000 + (kInetAdress % 90000) AS NVARCHAR(24)),
            cStadt = ''cStadt_'' + CAST(kInetAdress AS NVARCHAR(30)),
            cTel = ''Tel_'' + CAST(kInetAdress AS NVARCHAR(30)),
            cMobil = ''Mobil_'' + CAST(kInetAdress AS NVARCHAR(30)),
            cFax = ''Fax_'' + CAST(kInetAdress AS NVARCHAR(30)),
            cMail = ''mail_'' + CAST(kInetAdress AS NVARCHAR(30)) + ''@test.local'',
            cAdressZusatz = ''cAdressZusatz_'' + CAST(kInetAdress AS NVARCHAR(30)),
            cZusatz = ''cZusatz_'' + CAST(kInetAdress AS NVARCHAR(30)),
            cBundesland = ''Bundesland_'' + CAST(kInetAdress AS NVARCHAR(30))
        WHERE kInetAdress IS NOT NULL;

        UPDATE dbo.trechnungsadresse SET
            cFirma = ''cFirma_'' + CAST(kRechnungsAdresse AS NVARCHAR(30)),
            cAnrede = ''Anrede_'' + CAST(kRechnungsAdresse AS NVARCHAR(30)),
            cTitel = ''cTitel_'' + CAST(kRechnungsAdresse AS NVARCHAR(30)),
            cVorname = ''cVorname_'' + CAST(kRechnungsAdresse AS NVARCHAR(30)),
            cName = ''cName_'' + CAST(kRechnungsAdresse AS NVARCHAR(30)),
            cStrasse = ''cStrasse_'' + CAST(kRechnungsAdresse AS NVARCHAR(30)),
            cPLZ = CAST(10000 + (kRechnungsAdresse % 90000) AS NVARCHAR(24)),
            cOrt = ''cOrt_'' + CAST(kRechnungsAdresse AS NVARCHAR(30)),
            cTel = ''Tel_'' + CAST(kRechnungsAdresse AS NVARCHAR(30)),
            cZusatz = ''cZusatz_'' + CAST(kRechnungsAdresse AS NVARCHAR(30)),
            cAdressZusatz = ''cAdressZusatz_'' + CAST(kRechnungsAdresse AS NVARCHAR(30)),
            cPostID = ''cPostID_'' + CAST(kRechnungsAdresse AS NVARCHAR(30)),
            cMobil = ''Mobil_'' + CAST(kRechnungsAdresse AS NVARCHAR(30)),
            cMail = ''mail_'' + CAST(kRechnungsAdresse AS NVARCHAR(30)) + ''@test.local'',
            cFax = ''Fax_'' + CAST(kRechnungsAdresse AS NVARCHAR(30)),
            cZHaenden = ''cZHaenden_'' + CAST(kRechnungsAdresse AS NVARCHAR(30)),
            cBundesland = ''Bundesland_'' + CAST(kRechnungsAdresse AS NVARCHAR(30))
        WHERE kRechnungsAdresse IS NOT NULL;

        IF OBJECT_ID(''dbo.tBenutzer'', ''U'') IS NOT NULL
        UPDATE dbo.tBenutzer SET
            cLogin = ''User_'' + CAST(kBenutzer AS NVARCHAR(15)),
            cPasswort = ''Pass_'' + CAST(kBenutzer AS NVARCHAR(15)),
            cName = ''cName_'' + CAST(kBenutzer AS NVARCHAR(15)),
            cTel = ''Tel_'' + CAST(kBenutzer AS NVARCHAR(15)),
            cEMail = ''mail_'' + CAST(kBenutzer AS NVARCHAR(15)) + ''@test.local'',
            cFax = ''Fax_'' + CAST(kBenutzer AS NVARCHAR(15)),
            cMobil = ''Mobil_'' + CAST(kBenutzer AS NVARCHAR(15)),
            cHinweis = ''cHinweis_'' + CAST(kBenutzer AS NVARCHAR(15)),
            cApiToken = NULL
        WHERE kBenutzer IS NOT NULL;

        IF OBJECT_ID(''dbo.tansprechpartner'', ''U'') IS NOT NULL
        UPDATE dbo.tansprechpartner SET
            cName = ''cName_'' + CAST(kAnsprechpartner AS NVARCHAR(30)),
            cVorName = ''cVorname_'' + CAST(kAnsprechpartner AS NVARCHAR(30)),
            cAnrede = ''Anrede_'' + CAST(kAnsprechpartner AS NVARCHAR(30)),
            cTel = ''Tel_'' + CAST(kAnsprechpartner AS NVARCHAR(30)),
            cFax = ''Fax_'' + CAST(kAnsprechpartner AS NVARCHAR(30)),
            cMail = ''mail_'' + CAST(kAnsprechpartner AS NVARCHAR(30)) + ''@test.local'',
            cMobil = ''Mobil_'' + CAST(kAnsprechpartner AS NVARCHAR(30)),
            cAbteilung = ''Abt_'' + CAST(kAnsprechpartner AS NVARCHAR(30))
        WHERE kAnsprechpartner IS NOT NULL;
        END TRY
        BEGIN CATCH
            SET CONTEXT_INFO 0x0;   -- never leave the trigger-bypass token set (PAR-3)
            THROW;
        END CATCH
    ';
    EXEC @exec @b;
    EXEC reset.internal_LogStep @RequestId, N'anon.P1 core-person ok';

    -- ===== PRIORITY 2: transaction addresses =====================================
    SET @b = N'
        IF OBJECT_ID(''Verkauf.tAuftragAdresse'', ''U'') IS NOT NULL
        UPDATE Verkauf.tAuftragAdresse SET
            cFirma = ''cFirma_'' + CAST(kAuftrag AS NVARCHAR(30)) + ''_'' + CAST(nTyp AS NVARCHAR(5)),
            cAnrede = ''Anrede_'' + CAST(kAuftrag AS NVARCHAR(30)) + ''_'' + CAST(nTyp AS NVARCHAR(5)),
            cTitel = ''cTitel_'' + CAST(kAuftrag AS NVARCHAR(30)) + ''_'' + CAST(nTyp AS NVARCHAR(5)),
            cVorname = ''cVorname_'' + CAST(kAuftrag AS NVARCHAR(30)) + ''_'' + CAST(nTyp AS NVARCHAR(5)),
            cName = ''cName_'' + CAST(kAuftrag AS NVARCHAR(30)) + ''_'' + CAST(nTyp AS NVARCHAR(5)),
            cStrasse = ''cStrasse_'' + CAST(kAuftrag AS NVARCHAR(30)) + ''_'' + CAST(nTyp AS NVARCHAR(5)),
            cPLZ = CAST(10000 + (kAuftrag % 90000) AS NVARCHAR(24)),
            cOrt = ''cOrt_'' + CAST(kAuftrag AS NVARCHAR(30)) + ''_'' + CAST(nTyp AS NVARCHAR(5)),
            cTel = ''Tel_'' + CAST(kAuftrag AS NVARCHAR(30)) + ''_'' + CAST(nTyp AS NVARCHAR(5)),
            cZusatz = ''cZusatz_'' + CAST(kAuftrag AS NVARCHAR(30)) + ''_'' + CAST(nTyp AS NVARCHAR(5)),
            cAdressZusatz = ''cAdressZusatz_'' + CAST(kAuftrag AS NVARCHAR(30)) + ''_'' + CAST(nTyp AS NVARCHAR(5)),
            cPostID = ''cPostID_'' + CAST(kAuftrag AS NVARCHAR(30)) + ''_'' + CAST(nTyp AS NVARCHAR(5)),
            cMobil = ''Mobil_'' + CAST(kAuftrag AS NVARCHAR(30)) + ''_'' + CAST(nTyp AS NVARCHAR(5)),
            cMail = ''mail_'' + CAST(kAuftrag AS NVARCHAR(30)) + ''_'' + CAST(nTyp AS NVARCHAR(5)) + ''@test.local'',
            cFax = ''Fax_'' + CAST(kAuftrag AS NVARCHAR(30)) + ''_'' + CAST(nTyp AS NVARCHAR(5)),
            cBundesland = ''Bundesland_'' + CAST(kAuftrag AS NVARCHAR(30))
        WHERE kAuftrag IS NOT NULL;

        IF OBJECT_ID(''Rechnung.tRechnungAdresse'', ''U'') IS NOT NULL
        UPDATE Rechnung.tRechnungAdresse SET
            cFirma = ''cFirma_'' + CAST(kRechnung AS NVARCHAR(30)) + ''_'' + CAST(nTyp AS NVARCHAR(5)),
            cAnrede = ''Anrede_'' + CAST(kRechnung AS NVARCHAR(30)) + ''_'' + CAST(nTyp AS NVARCHAR(5)),
            cTitel = ''cTitel_'' + CAST(kRechnung AS NVARCHAR(30)) + ''_'' + CAST(nTyp AS NVARCHAR(5)),
            cVorname = ''cVorname_'' + CAST(kRechnung AS NVARCHAR(30)) + ''_'' + CAST(nTyp AS NVARCHAR(5)),
            cName = ''cName_'' + CAST(kRechnung AS NVARCHAR(30)) + ''_'' + CAST(nTyp AS NVARCHAR(5)),
            cStrasse = ''cStrasse_'' + CAST(kRechnung AS NVARCHAR(30)) + ''_'' + CAST(nTyp AS NVARCHAR(5)),
            cPLZ = CAST(10000 + (kRechnung % 90000) AS NVARCHAR(24)),
            cOrt = ''cOrt_'' + CAST(kRechnung AS NVARCHAR(30)) + ''_'' + CAST(nTyp AS NVARCHAR(5)),
            cTel = ''Tel_'' + CAST(kRechnung AS NVARCHAR(30)) + ''_'' + CAST(nTyp AS NVARCHAR(5)),
            cZusatz = ''cZusatz_'' + CAST(kRechnung AS NVARCHAR(30)) + ''_'' + CAST(nTyp AS NVARCHAR(5)),
            cAdresszusatz = ''cAdresszusatz_'' + CAST(kRechnung AS NVARCHAR(30)) + ''_'' + CAST(nTyp AS NVARCHAR(5)),
            cPostID = ''cPostID_'' + CAST(kRechnung AS NVARCHAR(30)) + ''_'' + CAST(nTyp AS NVARCHAR(5)),
            cMobil = ''Mobil_'' + CAST(kRechnung AS NVARCHAR(30)) + ''_'' + CAST(nTyp AS NVARCHAR(5)),
            cMail = ''mail_'' + CAST(kRechnung AS NVARCHAR(30)) + ''_'' + CAST(nTyp AS NVARCHAR(5)) + ''@test.local'',
            cFax = ''Fax_'' + CAST(kRechnung AS NVARCHAR(30)) + ''_'' + CAST(nTyp AS NVARCHAR(5)),
            cBundesland = ''Bundesland_'' + CAST(kRechnung AS NVARCHAR(30))
        WHERE kRechnung IS NOT NULL;

        IF OBJECT_ID(''DbeS.tLieferadresse'', ''U'') IS NOT NULL
        UPDATE DbeS.tLieferadresse SET
            cFirma = ''cFirma_'' + CAST(kLieferadresse AS NVARCHAR(30)),
            cAnrede = ''Anrede_'' + CAST(kLieferadresse AS NVARCHAR(30)),
            cTitel = ''cTitel_'' + CAST(kLieferadresse AS NVARCHAR(30)),
            cVorname = ''cVorname_'' + CAST(kLieferadresse AS NVARCHAR(30)),
            cNachname = ''cNachname_'' + CAST(kLieferadresse AS NVARCHAR(30)),
            cStrasse = ''cStrasse_'' + CAST(kLieferadresse AS NVARCHAR(30)),
            cPLZ = CAST(10000 + (kLieferadresse % 90000) AS NVARCHAR(24)),
            cOrt = ''cOrt_'' + CAST(kLieferadresse AS NVARCHAR(30)),
            cTel = ''Tel_'' + CAST(kLieferadresse AS NVARCHAR(30)),
            cMobil = ''Mobil_'' + CAST(kLieferadresse AS NVARCHAR(30)),
            cFax = ''Fax_'' + CAST(kLieferadresse AS NVARCHAR(30)),
            cMail = ''mail_'' + CAST(kLieferadresse AS NVARCHAR(30)) + ''@test.local'',
            cAdressZusatz = ''cAdressZusatz_'' + CAST(kLieferadresse AS NVARCHAR(30)),
            cBundesland = ''Bundesland_'' + CAST(kLieferadresse AS NVARCHAR(30))
        WHERE kLieferadresse IS NOT NULL;

        IF OBJECT_ID(''DbeS.tRechnungadresse'', ''U'') IS NOT NULL
        UPDATE DbeS.tRechnungadresse SET
            cFirma = ''cFirma_'' + CAST(kRechnungadresse AS NVARCHAR(30)),
            cAnrede = ''Anrede_'' + CAST(kRechnungadresse AS NVARCHAR(30)),
            cTitel = ''cTitel_'' + CAST(kRechnungadresse AS NVARCHAR(30)),
            cVorname = ''cVorname_'' + CAST(kRechnungadresse AS NVARCHAR(30)),
            cNachname = ''cNachname_'' + CAST(kRechnungadresse AS NVARCHAR(30)),
            cStrasse = ''cStrasse_'' + CAST(kRechnungadresse AS NVARCHAR(30)),
            cPLZ = CAST(10000 + (kRechnungadresse % 90000) AS NVARCHAR(24)),
            cOrt = ''cOrt_'' + CAST(kRechnungadresse AS NVARCHAR(30)),
            cTel = ''Tel_'' + CAST(kRechnungadresse AS NVARCHAR(30)),
            cMobil = ''Mobil_'' + CAST(kRechnungadresse AS NVARCHAR(30)),
            cFax = ''Fax_'' + CAST(kRechnungadresse AS NVARCHAR(30)),
            cMail = ''mail_'' + CAST(kRechnungadresse AS NVARCHAR(30)) + ''@test.local'',
            cAdressZusatz = ''cAdressZusatz_'' + CAST(kRechnungadresse AS NVARCHAR(30)),
            cBundesland = ''Bundesland_'' + CAST(kRechnungadresse AS NVARCHAR(30)),
            cUSTID = ''USTID_'' + CAST(kRechnungadresse AS NVARCHAR(30)),
            cWWW = ''www_'' + CAST(kRechnungadresse AS NVARCHAR(30)) + ''.test.local''
        WHERE kRechnungadresse IS NOT NULL;

        IF OBJECT_ID(''dbo.tinetbestellung'', ''U'') IS NOT NULL
        UPDATE dbo.tinetbestellung SET
            cKommentar = ''Kommentar_'' + CAST(kInetBestellung AS NVARCHAR(30)),
            cHinweis = ''Hinweis_'' + CAST(kInetBestellung AS NVARCHAR(30)),
            cUserAgent = ''UserAgent_'' + CAST(kInetBestellung AS NVARCHAR(30)),
            cReferrer = ''Referrer_'' + CAST(kInetBestellung AS NVARCHAR(30))
        WHERE kInetBestellung IS NOT NULL;

        IF OBJECT_ID(''Contact.tAddress'', ''U'') IS NOT NULL
        UPDATE Contact.tAddress SET
            cFirstName = ''FirstName_'' + CAST(kAddress AS NVARCHAR(30)),
            cLastName = ''LastName_'' + CAST(kAddress AS NVARCHAR(30)),
            cStreet = ''Street_'' + CAST(kAddress AS NVARCHAR(30)),
            cHouseNumber = CAST(kAddress % 999 AS NVARCHAR(30)),
            cPostalCode = CAST(10000 + (kAddress % 90000) AS NVARCHAR(24)),
            cCity = ''City_'' + CAST(kAddress AS NVARCHAR(30)),
            cCompanyName = ''Company_'' + CAST(kAddress AS NVARCHAR(30)),
            cCompanyAdditionalName = ''CompanyAdd_'' + CAST(kAddress AS NVARCHAR(30)),
            cAddressSupplement = ''AddressSup_'' + CAST(kAddress AS NVARCHAR(30)),
            cState = ''State_'' + CAST(kAddress AS NVARCHAR(30)),
            cPhoneNumber = ''Phone_'' + CAST(kAddress AS NVARCHAR(30)),
            cMobileNumber = ''Mobile_'' + CAST(kAddress AS NVARCHAR(30)),
            cFaxNumber = ''Fax_'' + CAST(kAddress AS NVARCHAR(30)),
            cEmail = ''mail_'' + CAST(kAddress AS NVARCHAR(30)) + ''@test.local'',
            cHomepage = ''www_'' + CAST(kAddress AS NVARCHAR(30)) + ''.test.local'',
            cVatId = ''VAT_'' + CAST(kAddress AS NVARCHAR(30))
        WHERE kAddress IS NOT NULL;
    ';
    EXEC @exec @b;
    EXEC reset.internal_LogStep @RequestId, N'anon.P2 tx-addresses ok';

    -- ===== PRIORITY 3: eBay checkout =============================================
    SET @b = N'
        IF OBJECT_ID(''dbo.ebay_checkout'', ''U'') IS NOT NULL
        UPDATE dbo.ebay_checkout SET
            cLieferAnrede = ''Anrede_'' + CAST(kEbayCheckout AS NVARCHAR(30)),
            cLieferVorname = ''Vorname_'' + CAST(kEbayCheckout AS NVARCHAR(30)),
            cLieferNachname = ''Nachname_'' + CAST(kEbayCheckout AS NVARCHAR(30)),
            cLieferNamenszusatz = ''Namenszusatz_'' + CAST(kEbayCheckout AS NVARCHAR(30)),
            cLieferStrasse = ''Strasse_'' + CAST(kEbayCheckout AS NVARCHAR(30)),
            cLieferAdresszusatz = ''Adresszusatz_'' + CAST(kEbayCheckout AS NVARCHAR(30)),
            cLieferPLZ = CAST(10000 + (kEbayCheckout % 90000) AS NVARCHAR(255)),
            cLieferOrt = ''Ort_'' + CAST(kEbayCheckout AS NVARCHAR(30)),
            cLieferTel = ''Tel_'' + CAST(kEbayCheckout AS NVARCHAR(30)),
            cLieferFax = ''Fax_'' + CAST(kEbayCheckout AS NVARCHAR(30)),
            cLieferHandy = ''Handy_'' + CAST(kEbayCheckout AS NVARCHAR(30)),
            cLieferFirma = ''Firma_'' + CAST(kEbayCheckout AS NVARCHAR(30)),
            cTel = ''Tel_'' + CAST(kEbayCheckout AS NVARCHAR(30)),
            cFax = ''Fax_'' + CAST(kEbayCheckout AS NVARCHAR(30)),
            cMobil = ''Mobil_'' + CAST(kEbayCheckout AS NVARCHAR(30)),
            cEMail = ''mail_'' + CAST(kEbayCheckout AS NVARCHAR(30)) + ''@test.local'',
            cComment = ''Comment_'' + CAST(kEbayCheckout AS NVARCHAR(30)),
            cFirma = ''Firma_'' + CAST(kEbayCheckout AS NVARCHAR(30)),
            cUStID = ''USTID_'' + CAST(kEbayCheckout AS NVARCHAR(30)),
            cAdresszusatz = ''Adresszusatz_'' + CAST(kEbayCheckout AS NVARCHAR(30)),
            cAnrede = ''Anrede_'' + CAST(kEbayCheckout AS NVARCHAR(30)),
            cVorname = ''Vorname_'' + CAST(kEbayCheckout AS NVARCHAR(30)),
            cNachname = ''Nachname_'' + CAST(kEbayCheckout AS NVARCHAR(30)),
            cPLZ = CAST(10000 + (kEbayCheckout % 90000) AS NVARCHAR(255)),
            cOrt = ''Ort_'' + CAST(kEbayCheckout AS NVARCHAR(30)),
            cStrasse = ''Strasse_'' + CAST(kEbayCheckout AS NVARCHAR(30)),
            cZahlungInhaber = ''Inhaber_'' + CAST(kEbayCheckout AS NVARCHAR(30)),
            cPUIZahlungsdaten = ''Zahlungsdaten_'' + CAST(kEbayCheckout AS NVARCHAR(30))
        WHERE kEbayCheckout IS NOT NULL;
    ';
    EXEC @exec @b;
    EXEC reset.internal_LogStep @RequestId, N'anon.P3 ebay-checkout ok';

    -- ===== PRIORITY 4: Amazon SFP ================================================
    SET @b = N'
        IF OBJECT_ID(''Amazon.tSFPVersand'', ''U'') IS NOT NULL
        UPDATE Amazon.tSFPVersand SET
            cFirma = ''Firma_'' + CAST(kSFPVersand AS NVARCHAR(30)),
            cStrasse = ''Strasse_'' + CAST(kSFPVersand AS NVARCHAR(30)),
            cPLZ = CAST(10000 + (kSFPVersand % 90000) AS NVARCHAR(30)),
            cOrt = ''Ort_'' + CAST(kSFPVersand AS NVARCHAR(30)),
            cTel = ''Tel_'' + CAST(kSFPVersand AS NVARCHAR(30)),
            cMail = ''mail_'' + CAST(kSFPVersand AS NVARCHAR(30)) + ''@test.local''
        WHERE kSFPVersand IS NOT NULL;
    ';
    EXEC @exec @b;
    EXEC reset.internal_LogStep @RequestId, N'anon.P4 amazon-sfp ok';

    -- ===== PRIORITY 5: history / logs ============================================
    SET @b = N'
        IF OBJECT_ID(''Verkauf.tAuftrag_Log'', ''U'') IS NOT NULL
        UPDATE Verkauf.tAuftrag_Log SET
            cEbayUsername = ''EbayUser_'' + CAST(kAuftragLog AS NVARCHAR(30)),
            cKundenNr = ''KundenNr_'' + CAST(kAuftragLog AS NVARCHAR(30)),
            cKundeUstId = ''USTID_'' + CAST(kAuftragLog AS NVARCHAR(30))
        WHERE kAuftragLog IS NOT NULL;

        IF OBJECT_ID(''Verkauf.tAuftragAdresse_Log'', ''U'') IS NOT NULL
        UPDATE Verkauf.tAuftragAdresse_Log SET
            cFirma = ''cFirma_LOG_'' + CAST(kAuftragAdresseLog AS NVARCHAR(30)),
            cAnrede = ''Anrede_LOG_'' + CAST(kAuftragAdresseLog AS NVARCHAR(30)),
            cTitel = ''cTitel_LOG_'' + CAST(kAuftragAdresseLog AS NVARCHAR(30)),
            cVorname = ''cVorname_LOG_'' + CAST(kAuftragAdresseLog AS NVARCHAR(30)),
            cName = ''cName_LOG_'' + CAST(kAuftragAdresseLog AS NVARCHAR(30)),
            cStrasse = ''cStrasse_LOG_'' + CAST(kAuftragAdresseLog AS NVARCHAR(30)),
            cPLZ = CAST(10000 + (kAuftragAdresseLog % 90000) AS NVARCHAR(24)),
            cOrt = ''cOrt_LOG_'' + CAST(kAuftragAdresseLog AS NVARCHAR(30)),
            cTel = ''Tel_LOG_'' + CAST(kAuftragAdresseLog AS NVARCHAR(30)),
            cZusatz = ''cZusatz_LOG_'' + CAST(kAuftragAdresseLog AS NVARCHAR(30)),
            cAdressZusatz = ''cAdressZusatz_LOG_'' + CAST(kAuftragAdresseLog AS NVARCHAR(30)),
            cPostID = ''cPostID_LOG_'' + CAST(kAuftragAdresseLog AS NVARCHAR(30)),
            cMobil = ''Mobil_LOG_'' + CAST(kAuftragAdresseLog AS NVARCHAR(30)),
            cMail = ''mail_LOG_'' + CAST(kAuftragAdresseLog AS NVARCHAR(30)) + ''@test.local'',
            cFax = ''Fax_LOG_'' + CAST(kAuftragAdresseLog AS NVARCHAR(30)),
            cBundesland = ''Bundesland_LOG_'' + CAST(kAuftragAdresseLog AS NVARCHAR(30))
        WHERE kAuftragAdresseLog IS NOT NULL;

        IF OBJECT_ID(''Kunde.tNotiz'', ''U'') IS NOT NULL
        UPDATE Kunde.tNotiz SET cNotiz = ''Notiz_'' + CAST(kNotiz AS NVARCHAR(30)) WHERE kNotiz IS NOT NULL;
    ';
    EXEC @exec @b;
    EXEC reset.internal_LogStep @RequestId, N'anon.P5 history/logs ok';

    -- ===== PRIORITY 6: ticket system =============================================
    SET @b = N'
        IF OBJECT_ID(''Ticketsystem.tNachricht'', ''U'') IS NOT NULL
        UPDATE Ticketsystem.tNachricht SET
            cInhalt = ''Nachricht_'' + CAST(kNachricht AS NVARCHAR(30)),
            cBeschreibung = ''Beschreibung_'' + CAST(kNachricht AS NVARCHAR(30))
        WHERE kNachricht IS NOT NULL;

        IF OBJECT_ID(''Ticketsystem.tEingangskanalEmail'', ''U'') IS NOT NULL
        UPDATE Ticketsystem.tEingangskanalEmail SET
            cBenutzername = ''User_'' + CAST(kEingangskanalEmail AS NVARCHAR(30)),
            cPasswort = ''Pass_'' + CAST(kEingangskanalEmail AS NVARCHAR(30)),
            cEmailAdresse = ''mail_'' + CAST(kEingangskanalEmail AS NVARCHAR(30)) + ''@test.local''
        WHERE kEingangskanalEmail IS NOT NULL;

        IF OBJECT_ID(''Ticketsystem.tAusgangskanalEmail'', ''U'') IS NOT NULL
        UPDATE Ticketsystem.tAusgangskanalEmail SET
            cBenutzername = ''User_'' + CAST(kAusgangskanalEmail AS NVARCHAR(30)),
            cPasswort = ''Pass_'' + CAST(kAusgangskanalEmail AS NVARCHAR(30)),
            cEmailAdresse = ''mail_'' + CAST(kAusgangskanalEmail AS NVARCHAR(30)) + ''@test.local''
        WHERE kAusgangskanalEmail IS NOT NULL;
    ';
    EXEC @exec @b;
    EXEC reset.internal_LogStep @RequestId, N'anon.P6 ticketsystem ok';

    -- ===== PRIORITY 7: returns ===================================================
    SET @b = N'
        IF OBJECT_ID(''dbo.tRMRetoure'', ''U'') IS NOT NULL
        UPDATE dbo.tRMRetoure SET
            cAnsprechpartner = ''Ansprechpartner_'' + CAST(kRMRetoure AS NVARCHAR(30)),
            cKommentarExtern = ''KommentarExtern_'' + CAST(kRMRetoure AS NVARCHAR(30)),
            cKommentarIntern = ''KommentarIntern_'' + CAST(kRMRetoure AS NVARCHAR(30)),
            cKorrekturBetragKommentar = ''Kommentar_'' + CAST(kRMRetoure AS NVARCHAR(30))
        WHERE kRMRetoure IS NOT NULL;

        IF OBJECT_ID(''dbo.tRMRetoureAbholAdresse'', ''U'') IS NOT NULL
        UPDATE dbo.tRMRetoureAbholAdresse SET
            cFirma = ''cFirma_'' + CAST(kRMRetoureAbholAdresse AS NVARCHAR(30)),
            cAnrede = ''Anrede_'' + CAST(kRMRetoureAbholAdresse AS NVARCHAR(30)),
            cTitel = ''cTitel_'' + CAST(kRMRetoureAbholAdresse AS NVARCHAR(30)),
            cVorname = ''cVorname_'' + CAST(kRMRetoureAbholAdresse AS NVARCHAR(30)),
            cName = ''cName_'' + CAST(kRMRetoureAbholAdresse AS NVARCHAR(30)),
            cStrasse = ''cStrasse_'' + CAST(kRMRetoureAbholAdresse AS NVARCHAR(30)),
            cPLZ = CAST(10000 + (kRMRetoureAbholAdresse % 90000) AS NVARCHAR(24)),
            cOrt = ''cOrt_'' + CAST(kRMRetoureAbholAdresse AS NVARCHAR(30)),
            cTel = ''Tel_'' + CAST(kRMRetoureAbholAdresse AS NVARCHAR(30)),
            cMobil = ''Mobil_'' + CAST(kRMRetoureAbholAdresse AS NVARCHAR(30)),
            cFax = ''Fax_'' + CAST(kRMRetoureAbholAdresse AS NVARCHAR(30)),
            cMail = ''mail_'' + CAST(kRMRetoureAbholAdresse AS NVARCHAR(30)) + ''@test.local''
        WHERE kRMRetoureAbholAdresse IS NOT NULL;
    ';
    EXEC @exec @b;
    EXEC reset.internal_LogStep @RequestId, N'anon.P7 returns ok';

    -- ===== PRIORITY 8: payment data ==============================================
    SET @b = N'
        IF OBJECT_ID(''dbo.tkontodaten'', ''U'') IS NOT NULL
        UPDATE dbo.tkontodaten SET
            cBankName = ''Bank_'' + CAST(kKontoDaten AS NVARCHAR(30)),
            cBLZ = ''BLZ_'' + CAST(kKontoDaten AS NVARCHAR(30)),
            cKontoNr = ''KontoNr_'' + CAST(kKontoDaten AS NVARCHAR(30)),
            cKartenNr = ''KartenNr_'' + CAST(kKontoDaten AS NVARCHAR(30)),
            cGueltigkeit = NULL,
            cCVV = NULL,
            cKartenTyp = ''Typ_'' + CAST(kKontoDaten AS NVARCHAR(30)),
            cInhaber = ''Inhaber_'' + CAST(kKontoDaten AS NVARCHAR(30)),
            cIBAN = ''IBAN_'' + CAST(kKontoDaten AS NVARCHAR(30)),
            cBIC = ''BIC_'' + CAST(kKontoDaten AS NVARCHAR(30))
        WHERE kKontoDaten IS NOT NULL;

        IF OBJECT_ID(''dbo.tinetzahlungsinfo'', ''U'') IS NOT NULL
        UPDATE dbo.tinetzahlungsinfo SET
            cBankName = ''Bank_'' + CAST(kInetZahlungsInfo AS NVARCHAR(30)),
            cBLZ = ''BLZ_'' + CAST(kInetZahlungsInfo AS NVARCHAR(30)),
            cKontoNr = ''KontoNr_'' + CAST(kInetZahlungsInfo AS NVARCHAR(30)),
            cKartenNr = ''KartenNr_'' + CAST(kInetZahlungsInfo AS NVARCHAR(30)),
            cGueltigkeit = NULL,
            cCVV = NULL,
            cKartenTyp = ''Typ_'' + CAST(kInetZahlungsInfo AS NVARCHAR(30)),
            cInhaber = ''Inhaber_'' + CAST(kInetZahlungsInfo AS NVARCHAR(30)),
            cIBAN = ''IBAN_'' + CAST(kInetZahlungsInfo AS NVARCHAR(30)),
            cBIC = ''BIC_'' + CAST(kInetZahlungsInfo AS NVARCHAR(30))
        WHERE kInetZahlungsInfo IS NOT NULL;

        IF OBJECT_ID(''dbo.tZahlung'', ''U'') IS NOT NULL
        UPDATE dbo.tZahlung SET
            cName = ''Name_'' + CAST(kZahlung AS NVARCHAR(30)),
            cHinweis = ''Hinweis_'' + CAST(kZahlung AS NVARCHAR(30))
        WHERE kZahlung IS NOT NULL;
    ';
    EXEC @exec @b;
    EXEC reset.internal_LogStep @RequestId, N'anon.P8 payment ok';

    -- ===== PRIORITY 9: access / authentication ===================================
    SET @b = N'
        IF OBJECT_ID(''dbo.tEMailEinstellung'', ''U'') IS NOT NULL
        UPDATE dbo.tEMailEinstellung SET
            cNutzernameSmtp = CASE WHEN cNutzernameSmtp IS NOT NULL AND cNutzernameSmtp <> ''''
                                   THEN ''User_SMTP_'' + CONVERT(NVARCHAR(36), NEWID()) ELSE cNutzernameSmtp END,
            cPasswortSMTP = '''',
            cServerSMTP = CASE WHEN cServerSMTP IS NOT NULL AND cServerSMTP <> ''''
                               THEN ''smtp_'' + CONVERT(NVARCHAR(36), NEWID()) + ''.test.local'' ELSE cServerSMTP END,
            cSigPortalPasswort = '''',
            cSMIMEPasswort = '''';

        IF OBJECT_ID(''dbo.tInkassoUser'', ''U'') IS NOT NULL
        UPDATE dbo.tInkassoUser SET
            cUsername = ''InkassoUser_'' + CAST(kInkassoUser AS NVARCHAR(30)),
            cPasswort = ''InkassoPass_'' + CAST(kInkassoUser AS NVARCHAR(30))
        WHERE kInkassoUser IS NOT NULL;

        -- pf_user presence AND shape are an open question in prod clones (O4). Guard
        -- every referenced column (CQG-10, matching internal_NeutralizeWorker), so a
        -- schema difference makes this block a no-op instead of THROWing and failing the
        -- whole reset. (Token columns are additionally cleared server-side elsewhere.)
        IF OBJECT_ID(''dbo.pf_user'', ''U'') IS NOT NULL
           AND COL_LENGTH(''dbo.pf_user'', ''kUser'')                IS NOT NULL
           AND COL_LENGTH(''dbo.pf_user'', ''cName'')                IS NOT NULL
           AND COL_LENGTH(''dbo.pf_user'', ''cAuthToken'')           IS NOT NULL
           AND COL_LENGTH(''dbo.pf_user'', ''cAmazonAuthToken'')     IS NOT NULL
           AND COL_LENGTH(''dbo.pf_user'', ''cFBAVersandmailKopie'') IS NOT NULL
           AND COL_LENGTH(''dbo.pf_user'', ''cFBAKommentar'')        IS NOT NULL
           AND COL_LENGTH(''dbo.pf_user'', ''cAnmerkung'')           IS NOT NULL
        UPDATE dbo.pf_user SET
            cName = ''PfUser_'' + CAST(kUser AS NVARCHAR(30)),
            cAuthToken = NULL,
            cAmazonAuthToken = NULL,
            cFBAVersandmailKopie = ''fba_'' + CAST(kUser AS NVARCHAR(30)) + ''@test.local'',
            cFBAKommentar = ''Kommentar_'' + CAST(kUser AS NVARCHAR(30)),
            cAnmerkung = ''Anmerkung_'' + CAST(kUser AS NVARCHAR(30))
        WHERE kUser IS NOT NULL;

        IF OBJECT_ID(''WMS.tMobileBenutzer'', ''U'') IS NOT NULL
        UPDATE WMS.tMobileBenutzer SET
            cName = ''WMSUser_'' + CAST(kMobileBenutzer AS NVARCHAR(30)),
            cUniqueId = ''UniqueId_'' + CAST(kMobileBenutzer AS NVARCHAR(30)),
            cIpAddress = ''192.168.1.'' + CAST((kMobileBenutzer % 254) + 1 AS NVARCHAR(3))
        WHERE kMobileBenutzer IS NOT NULL;
    ';
    EXEC @exec @b;
    EXEC reset.internal_LogStep @RequestId, N'anon.P9 access/auth ok';

    -- ===== PRIORITY 10: suppliers / incoming invoices ============================
    SET @b = N'
        IF OBJECT_ID(''dbo.tEingangsrechnung'', ''U'') IS NOT NULL
        UPDATE dbo.tEingangsrechnung SET
            cLieferant = ''Lieferant_'' + CAST(kEingangsrechnung AS NVARCHAR(30)),
            cAdresszusatz = ''Adresszusatz_'' + CAST(kEingangsrechnung AS NVARCHAR(30)),
            cStrasse = ''Strasse_'' + CAST(kEingangsrechnung AS NVARCHAR(30)),
            cPLZ = CAST(10000 + (kEingangsrechnung % 90000) AS NVARCHAR(10)),
            cOrt = ''Ort_'' + CAST(kEingangsrechnung AS NVARCHAR(30)),
            cBundesland = ''Bundesland_'' + CAST(kEingangsrechnung AS NVARCHAR(30)),
            cTel = ''Tel_'' + CAST(kEingangsrechnung AS NVARCHAR(30)),
            cFax = ''Fax_'' + CAST(kEingangsrechnung AS NVARCHAR(30)),
            cMobil = ''Mobil_'' + CAST(kEingangsrechnung AS NVARCHAR(30)),
            cMail = ''mail_'' + CAST(kEingangsrechnung AS NVARCHAR(30)) + ''@test.local'',
            cHinweise = ''Hinweise_'' + CAST(kEingangsrechnung AS NVARCHAR(30))
        WHERE kEingangsrechnung IS NOT NULL;

        IF OBJECT_ID(''dbo.tmahnung'', ''U'') IS NOT NULL
        UPDATE dbo.tmahnung SET
            cAnrede = ''Anrede_'' + CAST(kMahnung AS NVARCHAR(30)),
            cText = ''Text_'' + CAST(kMahnung AS NVARCHAR(30)),
            cKurzText = ''Kurztext_'' + CAST(kMahnung AS NVARCHAR(30))
        WHERE kMahnung IS NOT NULL;

        IF OBJECT_ID(''Rechnung.tRechnungText'', ''U'') IS NOT NULL
        UPDATE Rechnung.tRechnungText SET
            cRechnungstext = ''Rechnungstext_'' + CAST(kRechnung AS NVARCHAR(30)),
            cAnmerkung = ''Anmerkung_'' + CAST(kRechnung AS NVARCHAR(30)),
            cHinweis = ''Hinweis_'' + CAST(kRechnung AS NVARCHAR(30))
        WHERE kRechnung IS NOT NULL;

        IF OBJECT_ID(''Contact.tContact'', ''U'') IS NOT NULL
        UPDATE Contact.tContact SET cNumber = ''ContactNr_'' + CAST(kContact AS NVARCHAR(30)) WHERE kContact IS NOT NULL;
    ';
    EXEC @exec @b;
    EXEC reset.internal_LogStep @RequestId, N'anon.P10 suppliers/invoices ok';

    -- ===== PRIORITY 11: POS ======================================================
    SET @b = N'
        IF OBJECT_ID(''dbo.POS_Benutzer'', ''U'') IS NOT NULL
        UPDATE dbo.POS_Benutzer SET cPasswort = ''Pass_'' + CAST(kBenutzer AS NVARCHAR(30)) WHERE kBenutzer IS NOT NULL;
    ';
    EXEC @exec @b;
    EXEC reset.internal_LogStep @RequestId, N'anon.P11 pos ok';
END
GO
