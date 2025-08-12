USE eazybusiness;

-- Auswertung: Aufträge aus 2023 mit PayPal Ausgangszahlungen ohne externe Transaktions-ID
-- Zeigt nur Aufträge aus 2023, die PayPal Ausgangszahlungen (negative Beträge) ohne cExternalTransactionId haben
-- Fokussiert sich ausschließlich auf PayPal Zahlungen, ignoriert andere Zahlungsarten

-- Aufträge 2023 mit PayPal Ausgangszahlung ohne externe ID
WITH AuftraegeOhneZahlungsID AS (
    -- Aufträge aus 2023 mit PayPal Ausgangszahlungen ohne externe ID identifizieren
    SELECT DISTINCT
        tA.kAuftrag,
        tA.cAuftragsNr AS Auftragsnummer,
        CAST(tA.dErstellt AS date) AS Auftragsdatum,
        tK.nDebitorennr AS Debitorennummer,
        tK.cKundenNr AS KundenNr,
        lvK.cName AS Kundenname
    FROM Verkauf.tAuftrag tA
        LEFT JOIN dbo.tkunde tK ON tA.kKunde = tK.kKunde
        LEFT JOIN Kunde.lvKunde lvK ON tA.kKunde = lvK.kKunde
        INNER JOIN dbo.tZahlung Z ON Z.kBestellung = tA.kAuftrag
        LEFT JOIN dbo.tZahlungsart ZA ON Z.kZahlungsart = ZA.kZahlungsart
    WHERE YEAR(tA.dErstellt) = 2023  -- Nur Aufträge aus 2023
        AND tA.nStorno = 0  -- Keine stornierten Aufträge
        AND Z.dDatum IS NOT NULL  -- Nur Zahlungen mit Datum
        AND (Z.cExternalTransactionId IS NULL OR Z.cExternalTransactionId = '')  -- Ohne externe ID
        AND Z.fBetrag < 0  -- Nur Ausgangszahlungen (negative Beträge)
        AND COALESCE(ZA.cName, '') = 'PayPal'  -- Nur PayPal Zahlungen
),

-- Positionssummen für Rechnungen
RechnungSum AS (
    SELECT
        RP.kRechnung,
        SUM(RP.fWertBruttoGesamtFixiert) AS BetragPosBrutto
    FROM Rechnung.tRechnungPosition RP
    GROUP BY RP.kRechnung
),

-- Positionssummen für Gutschriften (Rechnungskorrekturen)
GutschriftSum AS (
    SELECT
        GP.tGutschrift_kGutschrift,
        SUM(GP.fVKPreis) AS BetragPosBrutto
    FROM dbo.tGutschriftPos GP
    GROUP BY GP.tGutschrift_kGutschrift
),

BelegeDetails AS (
    -- Alle Belege (Rechnungen, Rechnungskorrekturen, Stornos) für die gefilterten Aufträge
    -- Rechnungen
    SELECT 
        AR.kAuftrag,
        RE.cRechnungsnr AS Belegnummer,
        RE.dErstellt AS Belegdatum,
        'Rechnung' AS Belegtyp,
        COALESCE(RS.BetragPosBrutto, 0) AS Betrag
    FROM AuftraegeOhneZahlungsID A  -- Nur gefilterte Aufträge
        INNER JOIN Verkauf.tAuftragRechnung AR ON A.kAuftrag = AR.kAuftrag
        INNER JOIN Rechnung.tRechnung RE ON AR.kRechnung = RE.kRechnung
        LEFT JOIN RechnungSum RS ON RS.kRechnung = RE.kRechnung

    UNION ALL
    -- Rechnungskorrekturen
    SELECT 
        AR.kAuftrag,
        GS.cGutschriftNr AS Belegnummer,
        GS.dErstellt AS Belegdatum,
        'Rechnungskorrektur' AS Belegtyp,
        -COALESCE(GSU.BetragPosBrutto, 0) AS Betrag
    FROM AuftraegeOhneZahlungsID A  -- Nur gefilterte Aufträge
        INNER JOIN Verkauf.tAuftragRechnung AR ON A.kAuftrag = AR.kAuftrag
        INNER JOIN Rechnung.tRechnung RE ON AR.kRechnung = RE.kRechnung
        INNER JOIN dbo.tGutschrift GS ON GS.kRechnung = RE.kRechnung
        LEFT JOIN GutschriftSum GSU ON GSU.tGutschrift_kGutschrift = GS.kGutschrift

    UNION ALL
    -- Rechnungsstorno (Storno-Gutschrift)
    SELECT 
        AR.kAuftrag,
        GS_Sto.cGutschriftNr AS Belegnummer,
        GS_Sto.dErstellt AS Belegdatum,
        'Rechnungsstorno' AS Belegtyp,
        -COALESCE(GSU_Sto.BetragPosBrutto, 0) AS Betrag
    FROM AuftraegeOhneZahlungsID A  -- Nur gefilterte Aufträge
        INNER JOIN Verkauf.tAuftragRechnung AR ON A.kAuftrag = AR.kAuftrag
        INNER JOIN Rechnung.tRechnungStorno RSto ON AR.kRechnung = RSto.kRechnung
        INNER JOIN dbo.tGutschrift GS_Sto ON GS_Sto.kGutschrift = RSto.kStornoGutschrift
        LEFT JOIN GutschriftSum GSU_Sto ON GSU_Sto.tGutschrift_kGutschrift = GS_Sto.kGutschrift

    UNION ALL
    -- Rechnungskorrekturstorno (Storno einer Gutschrift)
    SELECT 
        AR.kAuftrag,
        GS_Sto.cGutschriftNr AS Belegnummer,
        GS_Sto.dErstellt AS Belegdatum,
        'Rechnungskorrekturstorno' AS Belegtyp,
        -COALESCE(GSU_Sto.BetragPosBrutto, 0) AS Betrag
    FROM AuftraegeOhneZahlungsID A  -- Nur gefilterte Aufträge
        INNER JOIN Verkauf.tAuftragRechnung AR ON A.kAuftrag = AR.kAuftrag
        INNER JOIN Rechnung.tRechnung RE ON AR.kRechnung = RE.kRechnung
        INNER JOIN dbo.tGutschrift GS_Orig ON GS_Orig.kRechnung = RE.kRechnung
        INNER JOIN dbo.tGutschriftStorno GSto ON GS_Orig.kGutschrift = GSto.kGutschrift
        INNER JOIN dbo.tGutschrift GS_Sto ON GS_Sto.kGutschrift = GSto.kStornoGutschrift
        LEFT JOIN GutschriftSum GSU_Sto ON GSU_Sto.tGutschrift_kGutschrift = GS_Sto.kGutschrift
),

BelegeGruppiert AS (
    -- Alle Belegnummern je Auftrag zusammenfassen
    SELECT 
        kAuftrag,
        STRING_AGG(
            Belegnummer + ' (' + 
            FORMAT(Betrag, 'N2') + ' am ' +
            FORMAT(Belegdatum, 'dd.MM.yyyy') + ')', 
            ', '
        ) WITHIN GROUP (ORDER BY Belegdatum, Belegnummer) AS Belegnummern
    FROM BelegeDetails
    GROUP BY kAuftrag
),

ZahlungsDetails AS (
    -- Detaillierte Zahlungsinformationen je Auftrag (alle Zahlungen + PayPal Statistiken)
    SELECT 
        Z.kBestellung AS kAuftrag,
        COUNT(*) AS GesamtZahlungen,
        COUNT(CASE WHEN COALESCE(ZA.cName, '') = 'PayPal' AND Z.fBetrag < 0 THEN 1 END) AS GesamtPayPalAusgangszahlungen,
        SUM(CASE 
            WHEN COALESCE(ZA.cName, '') = 'PayPal' 
                AND Z.fBetrag < 0 
                AND (Z.cExternalTransactionId IS NULL OR Z.cExternalTransactionId = '')
            THEN 1 ELSE 0 END) AS PayPalAusgangOhneID,
        SUM(CASE 
            WHEN COALESCE(ZA.cName, '') = 'PayPal' 
                AND Z.fBetrag < 0 
                AND Z.cExternalTransactionId IS NOT NULL AND Z.cExternalTransactionId <> '' 
            THEN 1 ELSE 0 END) AS PayPalAusgangMitID,
        MIN(Z.dDatum) AS ErsteZahlung,
        MAX(Z.dDatum) AS LetzteZahlung,
        SUM(Z.fBetrag) AS GesamtBetrag,
        -- Alle Zahlungen als verkettete Zeichenkette
        STRING_AGG(
            COALESCE(ZA.cName, 'Unbekannt') + ' ' +
            FORMAT(Z.dDatum, 'dd.MM.yyyy') + ' ' +
            FORMAT(Z.fBetrag, 'N2') + ' (' +
            COALESCE(Z.cExternalTransactionId, 'KEINE ID') + ')',
            ' | '
        ) WITHIN GROUP (ORDER BY Z.dDatum) AS AlleZahlungen
    FROM dbo.tZahlung Z
        LEFT JOIN dbo.tZahlungsart ZA ON Z.kZahlungsart = ZA.kZahlungsart
    WHERE Z.dDatum IS NOT NULL
        AND Z.kBestellung IN (SELECT kAuftrag FROM AuftraegeOhneZahlungsID)
    GROUP BY Z.kBestellung
)

-- Hauptabfrage: Aufträge mit PayPal Ausgangszahlungen ohne externe Zahlungs-IDs
-- Zeigt alle Zahlungen des Auftrags, aber filtert nur Aufträge mit PayPal Ausgangszahlungen ohne ID
SELECT 
    A.Debitorennummer,
    A.KundenNr,
    A.Kundenname,
    A.Auftragsnummer,
    A.Auftragsdatum,
    -- Allgemeine Zahlungsstatistiken
    ZD.GesamtZahlungen,
    CAST(ZD.ErsteZahlung AS date) AS ErsteZahlung,
    CAST(ZD.LetzteZahlung AS date) AS LetzteZahlung,
    ZD.GesamtBetrag,
    -- PayPal spezifische Statistiken
    ZD.GesamtPayPalAusgangszahlungen,
    ZD.PayPalAusgangOhneID,
    ZD.PayPalAusgangMitID,
    CASE 
        WHEN ZD.GesamtPayPalAusgangszahlungen > 0 
        THEN CAST(ROUND((ZD.PayPalAusgangOhneID * 100.0 / ZD.GesamtPayPalAusgangszahlungen), 1) AS decimal(5,1))
        ELSE 0 
    END AS ProzentPayPalOhneID,
    -- Alle Zahlungen als verkettete Zeichenkette
    ZD.AlleZahlungen,
    -- Alle Belegnummern als verkettete Zeichenkette
    BG.Belegnummern
FROM AuftraegeOhneZahlungsID A
    INNER JOIN ZahlungsDetails ZD ON A.kAuftrag = ZD.kAuftrag
    LEFT JOIN BelegeGruppiert BG ON A.kAuftrag = BG.kAuftrag

ORDER BY 
    ZD.PayPalAusgangOhneID DESC,  -- Aufträge mit meisten PayPal Ausgängen ohne ID zuerst
    A.Auftragsdatum DESC,
    A.Debitorennummer;