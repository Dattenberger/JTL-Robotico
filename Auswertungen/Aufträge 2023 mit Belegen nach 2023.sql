USE eazybusiness;

-- Abfrage für Aufträge aus 2023, die erst später in Rechnung gestellt wurden
-- Zeigt Aufträge an, die 2023 erstellt wurden, aber erst 2024 oder später berechnet wurden
-- Inkl. Zahlungsinformationen: Zahlungsart, erstes Zahlungsdatum und alle Zahlungen als verkettete Zeichenkette

--Aufträge 2023 mit Belegen nach 2023
WITH AuftraegeAus2023 AS (
    -- Basis: Alle Aufträge aus 2023
    SELECT 
        tA.kAuftrag,
        tA.cAuftragsNr AS Auftragsnummer,
        CAST(tA.dErstellt AS date) AS Auftragsdatum,
        tA.kZahlungsart,
        tK.nDebitorennr AS Debitorennummer,
        tK.cKundenNr AS KundenNr,
        lvK.cName AS Kundenname
    FROM Verkauf.tAuftrag tA
        LEFT JOIN dbo.tkunde tK ON tA.kKunde = tK.kKunde
        LEFT JOIN Kunde.lvKunde lvK ON tA.kKunde = lvK.kKunde
    WHERE YEAR(tA.dErstellt) = 2023
        AND tA.nStorno = 0  -- Keine stornierten Aufträge
),

-- Storno-Gutschriften (IDs), damit wir sie in Rechnungskorrekturen ausschließen
StornoGutschriften AS (
    SELECT kStornoGutschrift AS kGutschrift FROM Rechnung.tRechnungStorno
    UNION
    SELECT kStornoGutschrift AS kGutschrift FROM dbo.tGutschriftStorno
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

BelegeNach2023 AS (
    -- Alle Belege (Rechnungen, Rechnungskorrekturen, Stornos) nach 2023
    -- Rechnungen
    SELECT 
        AR.kAuftrag,
        RE.cRechnungsnr AS Belegnummer,
        RE.dErstellt AS Belegdatum,
        'Rechnung' AS Belegtyp,
        COALESCE(RS.BetragPosBrutto, 0) AS Betrag,
        RE.kRechnung AS ReferenzId,
        NULL AS kGutschrift
    FROM AuftraegeAus2023 A23  -- Nur Aufträge aus 2023
        INNER JOIN Verkauf.tAuftragRechnung AR ON A23.kAuftrag = AR.kAuftrag
        INNER JOIN Rechnung.tRechnung RE ON AR.kRechnung = RE.kRechnung
        LEFT JOIN RechnungSum RS ON RS.kRechnung = RE.kRechnung

    UNION ALL
    -- Rechnungskorrekturen (ohne Storno-Gutschriften)
    SELECT 
        AR.kAuftrag,
        GS.cGutschriftNr AS Belegnummer,
        GS.dErstellt AS Belegdatum,
        'Rechnungskorrektur' AS Belegtyp,
        -COALESCE(GSU.BetragPosBrutto, 0) AS Betrag,
        RE.kRechnung AS ReferenzId,
        GS.kGutschrift
    FROM AuftraegeAus2023 A23  -- Nur Aufträge aus 2023
        INNER JOIN Verkauf.tAuftragRechnung AR ON A23.kAuftrag = AR.kAuftrag
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
        -COALESCE(GSU_Sto.BetragPosBrutto, 0) AS Betrag,
        RSto.kRechnung AS ReferenzId,
        GS_Sto.kGutschrift
    FROM AuftraegeAus2023 A23  -- Nur Aufträge aus 2023
        INNER JOIN Verkauf.tAuftragRechnung AR ON A23.kAuftrag = AR.kAuftrag
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
        -COALESCE(GSU_Sto.BetragPosBrutto, 0) AS Betrag,
        RE.kRechnung AS ReferenzId,
        GS_Sto.kGutschrift
    FROM AuftraegeAus2023 A23  -- Nur Aufträge aus 2023
        INNER JOIN Verkauf.tAuftragRechnung AR ON A23.kAuftrag = AR.kAuftrag
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
        ) WITHIN GROUP (ORDER BY Belegdatum, Belegnummer) AS AlleBelegnummern,
        MIN(Belegdatum) AS ErstesBelegdatum,
        MIN(ReferenzId) AS kRechnung  -- Für Zahlungsinformationen
    FROM BelegeNach2023
    GROUP BY kAuftrag
),

ZahlungsInfo AS (
    -- Erste Zahlung je Auftrag (über alle Rechnungen und Gutschriften)
    SELECT 
        B.kAuftrag,
        MIN(CAST(Z.dDatum AS date)) AS ErstesZahlungsdatum
    FROM AuftraegeAus2023 B
        LEFT JOIN dbo.tZahlung Z ON Z.kBestellung = B.kAuftrag
    WHERE Z.dDatum IS NOT NULL
    GROUP BY B.kAuftrag
),

VersandInfo AS (
    -- Erstes Versanddatum je Auftrag
    SELECT 
        B.kAuftrag,
        MIN(CAST(L.dErstellt AS date)) AS ErstesVersanddatum
    FROM AuftraegeAus2023 B
        LEFT JOIN dbo.tLieferschein L ON L.kBestellung = B.kAuftrag
    WHERE L.dErstellt IS NOT NULL
    GROUP BY B.kAuftrag
),

AlleZahlungen AS (
    -- Alle Zahlungen als verkettete Zeichenkette je Auftrag
    SELECT 
        B.kAuftrag,
        COUNT(Z.kZahlung) AS AnzahlZahlungen,
        SUM(CASE WHEN YEAR(Z.dDatum) = 2023 THEN Z.fBetrag ELSE 0 END) AS ZahlungenSumme2023,
        CASE WHEN SUM(CASE WHEN (Z.cExternalTransactionId IS NULL OR Z.cExternalTransactionId = '') AND Z.dDatum IS NOT NULL THEN 1 ELSE 0 END) > 0 THEN 'WAHR' ELSE 'FALSCH' END AS ZahlungOhneIDVorhanden,
        STRING_AGG(
            COALESCE(ZA.cName, 'Unbekannt') + ' ' +
            FORMAT(Z.dDatum, 'dd.MM.yyyy') + ' ' +
            FORMAT(Z.fBetrag, 'N2') + ' (' +
            COALESCE(Z.cExternalTransactionId, 'KEINE ID') + ')',
            ' | '
        ) WITHIN GROUP (ORDER BY Z.dDatum) AS AlleZahlungenKonkateniert
    FROM AuftraegeAus2023 B
        LEFT JOIN dbo.tZahlung Z ON Z.kBestellung = B.kAuftrag AND Z.dDatum IS NOT NULL
        LEFT JOIN dbo.tZahlungsart ZA ON Z.kZahlungsart = ZA.kZahlungsart
    GROUP BY B.kAuftrag
)

-- Hauptabfrage: Aufträge 2023 mit Belegen nach 2023 inkl. Zahlungsinformationen
SELECT 
    A23.Debitorennummer,
    A23.KundenNr,
    A23.Kundenname,
    A23.Auftragsnummer,
    A23.Auftragsdatum,
    ZA.cName AS Zahlungsart,
    ZI.ErstesZahlungsdatum,
    YEAR(ZI.ErstesZahlungsdatum) AS ErstesZahlungsjahr,
    VI.ErstesVersanddatum,
    CAST(BG.ErstesBelegdatum AS date) AS ErstesBelegdatum,
    YEAR(BG.ErstesBelegdatum) AS ErstesBelegjahr,
    BG.AlleBelegnummern AS Belegnummern,
    COALESCE(AZ.AnzahlZahlungen, 0) AS AnzahlZahlungen,
    COALESCE(AZ.ZahlungenSumme2023, 0) AS ZahlungenSumme2023,
    COALESCE(AZ.ZahlungOhneIDVorhanden, 'FALSCH') AS ZahlungOhneIDVorhanden,
    AZ.AlleZahlungenKonkateniert
FROM AuftraegeAus2023 A23
    INNER JOIN BelegeGruppiert BG ON A23.kAuftrag = BG.kAuftrag
    LEFT JOIN dbo.tZahlungsart ZA ON A23.kZahlungsart = ZA.kZahlungsart
    LEFT JOIN ZahlungsInfo ZI ON A23.kAuftrag = ZI.kAuftrag
    LEFT JOIN VersandInfo VI ON A23.kAuftrag = VI.kAuftrag
    LEFT JOIN AlleZahlungen AZ ON A23.kAuftrag = AZ.kAuftrag
WHERE
    -- Nur Aufträge, die Belege nach 2023 haben
    YEAR(BG.ErstesBelegdatum) > 2023
    AND YEAR(ErstesZahlungsdatum) = 2023

ORDER BY
    A23.Auftragsdatum,
    BG.ErstesBelegdatum,
    A23.Debitorennummer;