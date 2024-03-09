USE eazybusiness;

-- 1) Auftragsbasis (nur Aufträge aus 2023)
WITH AuftragsBasis AS (
    SELECT
        tA.kAuftrag,
        CAST(tA.dErstellt AS date) AS Auftragsdatum,
        tA.cAuftragsNr             AS Auftragsnummer,
        tK.nDebitorennr            AS Debitorennummer,
        tK.cKundenNr               AS KundenNr,
        lvK.cName                  AS Kundenname
    FROM Verkauf.lvAuftragsverwaltung lA
             LEFT JOIN Verkauf.tAuftrag  tA  ON lA.kAuftrag = tA.kAuftrag
             LEFT JOIN dbo.tkunde        tK  ON lA.kKunde   = tK.kKunde
             LEFT JOIN Kunde.lvKunde     lvK ON lA.kKunde   = lvK.kKunde
    WHERE YEAR(tA.dErstellt) = 2023
),

-- 2) Versanddatum (erstes Versanddatum je Auftrag)
     VersandDatum AS (
         SELECT
             ls.kBestellung,                                 -- bei euch = kAuftrag
             CAST(MIN(ls.dErstellt) AS date) AS Versanddatum -- ggf. auf dBelegdatum wechseln
         FROM dbo.tlieferschein ls
         GROUP BY ls.kBestellung
     ),

-- 3) Positionssummen für Rechnungen
     RechnungSum AS (
         SELECT
             RP.kRechnung,
             SUM(RP.fWertBruttoGesamtFixiert) AS BetragPosBrutto
         FROM Rechnung.tRechnungPosition RP
         GROUP BY RP.kRechnung
     ),

-- 4) Positionssummen für Gutschriften (Rechnungskorrekturen)
     GutschriftSum AS (
         SELECT
             GP.tGutschrift_kGutschrift,
             SUM(GP.fVKPreis) AS BetragPosBrutto
         FROM dbo.tGutschriftPos GP
         GROUP BY GP.tGutschrift_kGutschrift
     ),

-- 5) Storno-Gutschriften (IDs), damit wir sie in C) ausschließen
     StornoGutschriften AS (
         SELECT kStornoGutschrift AS kGutschrift FROM Rechnung.tRechnungStorno
         UNION
         SELECT kStornoGutschrift AS kGutschrift FROM dbo.tGutschriftStorno
     ),

-- 6) Alle Beleg-Daten (nur fürs Jahres-Checking, je Auftrag)
     Belegdaten AS (
         -- Rechnungen
         SELECT AB.kAuftrag, CAST(RE.dErstellt AS date) AS Belegdatum
         FROM AuftragsBasis AB
                  INNER JOIN Verkauf.tAuftragRechnung AR ON AR.kAuftrag  = AB.kAuftrag
                  INNER JOIN Rechnung.tRechnung       RE ON RE.kRechnung = AR.kRechnung

         UNION ALL
         -- Rechnungskorrekturen (ohne Storno-Gutschriften)
         SELECT AB.kAuftrag, CAST(GS.dErstellt AS date) AS Belegdatum
         FROM AuftragsBasis AB
                  INNER JOIN Verkauf.tAuftragRechnung AR ON AR.kAuftrag  = AB.kAuftrag
                  INNER JOIN Rechnung.tRechnung       RE ON RE.kRechnung = AR.kRechnung
                  INNER JOIN dbo.tGutschrift          GS ON GS.kRechnung = RE.kRechnung
         WHERE GS.kGutschrift NOT IN (SELECT kGutschrift FROM StornoGutschriften)

         UNION ALL
         -- Rechnungsstorno (Storno-Gutschrift)
         SELECT AB.kAuftrag, CAST(GS_Sto.dErstellt AS date) AS Belegdatum
         FROM Rechnung.tRechnungStorno RSto
                  INNER JOIN Verkauf.tAuftragRechnung AR ON AR.kRechnung = RSto.kRechnung
                  INNER JOIN AuftragsBasis AB          ON AB.kAuftrag   = AR.kAuftrag
                  INNER JOIN dbo.tGutschrift GS_Sto    ON GS_Sto.kGutschrift = RSto.kStornoGutschrift

         UNION ALL
         -- Rechnungskorrekturstorno (Storno einer Gutschrift)
         SELECT AB.kAuftrag, CAST(GS_Sto.dErstellt AS date) AS Belegdatum
         FROM dbo.tGutschriftStorno GSto
                  INNER JOIN dbo.tGutschrift GS_Orig   ON GS_Orig.kGutschrift = GSto.kGutschrift
                  INNER JOIN Rechnung.tRechnung RE     ON RE.kRechnung = GS_Orig.kRechnung
                  INNER JOIN Verkauf.tAuftragRechnung AR ON AR.kRechnung = RE.kRechnung
                  INNER JOIN AuftragsBasis AB          ON AB.kAuftrag  = AR.kAuftrag
                  INNER JOIN dbo.tGutschrift GS_Sto    ON GS_Sto.kGutschrift = GSto.kStornoGutschrift
     ),

-- 7) Jahres-Check je Auftrag
     JahresCheck AS (
         SELECT
             AB.kAuftrag,
             YEAR(AB.Auftragsdatum)   AS AuftragsJahr,
             MIN(YEAR(BD.Belegdatum)) AS MinBelegJahr,
             MAX(YEAR(BD.Belegdatum)) AS MaxBelegJahr
         FROM AuftragsBasis AB
                  INNER JOIN Belegdaten BD ON BD.kAuftrag = AB.kAuftrag
         GROUP BY AB.kAuftrag, YEAR(AB.Auftragsdatum)
     ),

-- 8) Marker für abweichende Aufträge (nur 2023)
     AbweichendeAuftraege AS (
         SELECT
             JC.kAuftrag
         FROM JahresCheck JC
         WHERE (JC.MinBelegJahr <> JC.MaxBelegJahr
             OR JC.MinBelegJahr <> JC.AuftragsJahr
             OR JC.MaxBelegJahr <> JC.AuftragsJahr)
           AND JC.AuftragsJahr = 2023
     )

-- ========================= ERGEBNIS NUR FÜR ABWEICHENDE AUFTRÄGE (2023) =========================

-- A) RECHNUNGEN
SELECT
    AB.Debitorennummer,
    AB.Kundenname,
    AB.KundenNr,
    AB.Auftragsdatum,
    AB.Auftragsnummer,
    VD.Versanddatum,
    RE.cRechnungsnr                               AS Belegnummer,
    CAST(RE.dErstellt AS date)                    AS Belegdatum,
    COALESCE(RS.BetragPosBrutto, 0)               AS Betrag,
    'Rechnung'                                    AS Beleg,
    CAST(NULL AS nvarchar(100))                   AS [Beleg zu],
    CAST(1 AS bit)                                AS BelegjahreAbweichend
FROM AuftragsBasis AB
         INNER JOIN AbweichendeAuftraege AO ON AO.kAuftrag = AB.kAuftrag
         INNER JOIN Verkauf.tAuftragRechnung AR ON AR.kAuftrag  = AB.kAuftrag
         INNER JOIN Rechnung.tRechnung       RE ON RE.kRechnung = AR.kRechnung
         LEFT  JOIN RechnungSum              RS ON RS.kRechnung = RE.kRechnung
         LEFT  JOIN VersandDatum             VD ON VD.kBestellung  = AB.kAuftrag

UNION ALL

-- B) RECHNUNGSSTORNO
SELECT
    AB.Debitorennummer,
    AB.Kundenname,
    AB.KundenNr,
    AB.Auftragsdatum,
    AB.Auftragsnummer,
    VD.Versanddatum,
    GS_Sto.cGutschriftNr                          AS Belegnummer,
    CAST(GS_Sto.dErstellt AS date)                AS Belegdatum,
    -COALESCE(GSU_Sto.BetragPosBrutto, 0)         AS Betrag,
    'Rechnungsstorno'                             AS Beleg,
    RE_Orig.cRechnungsnr                          AS [Beleg zu],
    CAST(1 AS bit)                                AS BelegjahreAbweichend
FROM Rechnung.tRechnungStorno RSto
         INNER JOIN Verkauf.tAuftragRechnung AR ON AR.kRechnung = RSto.kRechnung
         INNER JOIN AuftragsBasis AB          ON AB.kAuftrag    = AR.kAuftrag
         INNER JOIN AbweichendeAuftraege AO   ON AO.kAuftrag    = AB.kAuftrag
         INNER JOIN Rechnung.tRechnung RE_Orig ON RE_Orig.kRechnung = RSto.kRechnung
         INNER JOIN dbo.tGutschrift GS_Sto    ON GS_Sto.kGutschrift = RSto.kStornoGutschrift
         LEFT  JOIN GutschriftSum GSU_Sto     ON GSU_Sto.tGutschrift_kGutschrift = GS_Sto.kGutschrift
         LEFT  JOIN VersandDatum  VD          ON VD.kBestellung = AB.kAuftrag

UNION ALL

-- C) RECHNUNGSKORREKTUR (ohne Storno-Gutschriften)
SELECT
    AB.Debitorennummer,
    AB.Kundenname,
    AB.KundenNr,
    AB.Auftragsdatum,
    AB.Auftragsnummer,
    VD.Versanddatum,
    GS.cGutschriftNr                              AS Belegnummer,
    CAST(GS.dErstellt AS date)                    AS Belegdatum,
    -COALESCE(GSU.BetragPosBrutto, 0)             AS Betrag,
    'Rechnungskorrektur'                          AS Beleg,
    CAST(NULL AS nvarchar(100))                   AS [Beleg zu],
    CAST(1 AS bit)                                AS BelegjahreAbweichend
FROM AuftragsBasis AB
         INNER JOIN AbweichendeAuftraege AO ON AO.kAuftrag = AB.kAuftrag
         INNER JOIN Verkauf.tAuftragRechnung AR ON AR.kAuftrag  = AB.kAuftrag
         INNER JOIN Rechnung.tRechnung       RE ON RE.kRechnung = AR.kRechnung
         INNER JOIN dbo.tGutschrift          GS ON GS.kRechnung = RE.kRechnung
         LEFT  JOIN GutschriftSum            GSU ON GSU.tGutschrift_kGutschrift = GS.kGutschrift
         LEFT  JOIN VersandDatum             VD  ON VD.kBestellung = AB.kAuftrag
WHERE GS.kGutschrift NOT IN (SELECT kGutschrift FROM StornoGutschriften)

UNION ALL

-- D) RECHNUNGSKORREKTURSTORNO
SELECT
    AB.Debitorennummer,
    AB.Kundenname,
    AB.KundenNr,
    AB.Auftragsdatum,
    AB.Auftragsnummer,
    VD.Versanddatum,
    GS_Sto.cGutschriftNr                          AS Belegnummer,
    CAST(GS_Sto.dErstellt AS date)                AS Belegdatum,
    -COALESCE(GSU_Sto.BetragPosBrutto, 0)         AS Betrag,
    'Rechnungskorrekturstorno'                    AS Beleg,
    GS_Orig.cGutschriftNr                         AS [Beleg zu],
    CAST(1 AS bit)                                AS BelegjahreAbweichend
FROM dbo.tGutschriftStorno GSto
         INNER JOIN dbo.tGutschrift GS_Orig   ON GS_Orig.kGutschrift = GSto.kGutschrift
         INNER JOIN Rechnung.tRechnung RE     ON RE.kRechnung = GS_Orig.kRechnung
         INNER JOIN Verkauf.tAuftragRechnung AR ON AR.kRechnung = RE.kRechnung
         INNER JOIN AuftragsBasis AB          ON AB.kAuftrag  = AR.kAuftrag
         INNER JOIN AbweichendeAuftraege AO   ON AO.kAuftrag  = AB.kAuftrag
         INNER JOIN dbo.tGutschrift GS_Sto    ON GS_Sto.kGutschrift = GSto.kStornoGutschrift
         LEFT  JOIN GutschriftSum GSU_Sto     ON GSU_Sto.tGutschrift_kGutschrift = GS_Sto.kGutschrift
         LEFT  JOIN VersandDatum  VD          ON VD.kBestellung = AB.kAuftrag

ORDER BY Debitorennummer, Belegdatum, Belegnummer;
