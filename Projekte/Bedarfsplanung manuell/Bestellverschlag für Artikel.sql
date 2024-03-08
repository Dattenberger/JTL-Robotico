/****** Script for SelectTopNRows command from SSMS  ******/
/**
407: Platine Ladestation P1
*/

DECLARE @tVerkäufeAb2022 AS TABLE
                            (
                                AuftragsPositionID         int,
                                LieferscheinPositionIDs    VARCHAR(255),
                                kArtikel                   int,
                                Auftragsnummer             VARCHAR(50),
                                AuftragID                  int,
                                RechnunsIDs                VARCHAR(255),
                                RechnunsNr                 VARCHAR(255),
                                GutschriftIDs              VARCHAR(255),
                                GutschriftNr               VARCHAR(255),
                                RechnungsPosIDs            VARCHAR(255),
                                GutschriftPosIDs           VARCHAR(255),
                                dAuftragsdatum             datetime,
                                AuftragsAnzahl             decimal(25, 13) not null,
                                GeliefertAnzahl            decimal(25, 13),
                                Gutgeschrieben             decimal(25, 13),
                                GutgeschriebenUndStorniert decimal(25, 13),
                                Storniert                  decimal(25, 13)
                            );
INSERT INTO @tVerkäufeAb2022
SELECT [tAuftragPosition].kAuftragPosition                                       as AuftragsPositionID
     , STRING_AGG([tLieferscheinPos].kLieferscheinPos, ', ')                     as LieferscheinPositionIDs
     , [tAuftragPosition].[kArtikel]
     , tAuftrag.cAuftragsNr                                                      as Auftragsnummer
     , tAuftrag.kAuftrag                                                         as AuftragID
     , STRING_AGG([tRechnungPosition].kRechnung, ', ')                           as RechnunsIDs
     , STRING_AGG(tRechnung.cRechnungsnr, ', ')                                  as RechnunsNr
     , STRING_AGG([tGutschriftPos].tGutschrift_kGutschrift, ', ')                as GutschriftIDs
     , STRING_AGG(tgutschrift.cGutschriftNr, ', ')                               as GutschriftNr
     , STRING_AGG(tRechnungPosition.kRechnungPosition, ', ')                     as RechnungsPosIDs
     , STRING_AGG([tGutschriftPos].kGutschriftPos, ', ')                         as GutschriftPosIDs
    /*,DATEADD(MONTH, DATEDIFF(MONTH, 0, [tAuftrag].[dErstellt]), 0) AS MonatI*/
     , [tAuftrag].[dErstellt]                                                    as dAuftragsdatum
     , [tAuftragPosition].fAnzahl                                                as AuftragsAnzahl
     , SUM([tLieferscheinPos].fAnzahl)                                           as GeliefertAnzahl
     , SUM(CASE WHEN tgutschrift.nStorno = 0 THEN [tGutschriftPos].nAnzahl END)  as Gutgeschrieben
     , SUM(CASE WHEN tgutschrift.nStorno = 1 THEN [tGutschriftPos].nAnzahl END)  as GutgeschriebenUndStorniert
     , SUM(CASE WHEN [tAuftrag].nStorno = 1 THEN [tAuftragPosition].fAnzahl END) as Storniert
FROM [eazybusiness].[Verkauf].[tAuftragPosition]
         LEFT JOIN [eazybusiness].[dbo].[tLieferscheinPos] ON kAuftragPosition = kBestellPos
         LEFT JOIN [eazybusiness].[Verkauf].[tAuftrag] ON tAuftrag.kAuftrag = tAuftragPosition.kAuftrag
         LEFT JOIN [eazybusiness].[Rechnung].[tRechnungLieferscheinPosition]
                   ON tRechnungLieferscheinPosition.kLieferscheinPosition =
                      tLieferscheinPos.kLieferscheinPos
         LEFT JOIN [eazybusiness].[Rechnung].[tRechnungPosition] ON
            tRechnungPosition.kRechnungPosition = tRechnungLieferscheinPosition.kRechnungPosition OR
            [tRechnungPosition].kAuftragPosition =
            IIF(tRechnungLieferscheinPosition.kRechnungPosition IS NULL, tAuftragPosition.kAuftragPosition,
                NULL)
         LEFT JOIN [eazybusiness].[Rechnung].tRechnung
                   ON tRechnung.kRechnung = [tRechnungPosition].kRechnung
         LEFT JOIN [eazybusiness].[dbo].[tGutschriftPos]
                   ON [tGutschriftPos].kRechnungPosition = [tRechnungPosition].kRechnungPosition
         LEFT JOIN [eazybusiness].[dbo].[tgutschrift]
                   ON [tgutschrift].kGutschrift = [tGutschriftPos].tGutschrift_kGutschrift AND
                      [tgutschrift].nStornoTyp != 2 /*StornoTyp 2 -> Stornobeleg*/
WHERE tAuftrag.dErstellt >= '01-01-2022'
  AND NOT tAuftragPosition.kArtikel IS NULL
GROUP BY [tAuftragPosition].[kArtikel], [tAuftragPosition].kAuftragPosition,
         [tAuftragPosition].fAnzahl, tAuftrag.cAuftragsNr, [tAuftrag].[dErstellt], tAuftrag.kAuftrag


SELECT tV.kArtikel
     , tAB.cName
     , FORMAT(SUM(AuftragsAnzahl), '#,#')             as Bestellt
     , FORMAT(SUM(GeliefertAnzahl), '#,#')            as Geliefert
     , FORMAT(SUM(Gutgeschrieben), '#,#')             as Gutgeschrieben
     , FORMAT(SUM(GutgeschriebenUndStorniert), '#,#') as GutgeschriebenUndStorniert
     , FORMAT(SUM(Storniert), '#,#')                  as Storniert
     --, FORMAT(COUNT(Monat), '#,#')                    as AuftragsPosAnzahl
FROM @tVerkäufeAb2022 AS tV
         LEFT JOIN tArtikelBeschreibung tAB ON tV.kArtikel = tAB.kArtikel
WHERE dAuftragsdatum >= '22-12-2022'
GROUP BY tV.kArtikel, tAB.cName
ORDER BY tV.kArtikel DESC

DECLARE @tSum15Tage AS TABLE
                       (
                           kArtikel         int,
                           nAuftragsAnzahl  int,
                           effektivBestellt decimal(25, 13)
                       )
INSERT INTO @tSum15Tage
SELECT tV.kArtikel,
       COUNT(AuftragsAnzahl)                                                            AS AuftragsAnzahl,
       SUM(AuftragsAnzahl) - ISNULL(SUM(Storniert), 0) - ISNULL(SUM(Gutgeschrieben), 0) AS effektivBestellt
FROM @tVerkäufeAb2022 AS tV
WHERE dAuftragsdatum >= DATEADD(day, -15, getdate())
GROUP BY tV.kArtikel

DECLARE @tSum30Tage AS TABLE
                       (
                           kArtikel         int,
                           nAuftragsAnzahl  int,
                           effektivBestellt decimal(25, 13)
                       )
INSERT INTO @tSum30Tage
SELECT tV.kArtikel,
       COUNT(AuftragsAnzahl)                                                            AS AuftragsAnzahl,
       SUM(AuftragsAnzahl) - ISNULL(SUM(Storniert), 0) - ISNULL(SUM(Gutgeschrieben), 0) AS effektivBestellt
FROM @tVerkäufeAb2022 AS tV
WHERE dAuftragsdatum >= DATEADD(day, -30, getdate())
GROUP BY tV.kArtikel

DECLARE @tSum60Tage AS TABLE
                       (
                           kArtikel         int,
                           nAuftragsAnzahl  int,
                           effektivBestellt decimal(25, 13)
                       )
INSERT INTO @tSum60Tage
SELECT tV.kArtikel,
       COUNT(AuftragsAnzahl)                                                            AS AuftragsAnzahl,
       SUM(AuftragsAnzahl) - ISNULL(SUM(Storniert), 0) - ISNULL(SUM(Gutgeschrieben), 0) AS effektivBestellt
FROM @tVerkäufeAb2022 AS tV
WHERE dAuftragsdatum >= DATEADD(day, -60, getdate())
GROUP BY tV.kArtikel

--Die gewünsche Bevorratung pro Warengruppe
DECLARE @tBerechnenFuerTage AS TABLE
                       (
                           kWarengruppe         int,
                           nBerechnenFuerTage   int,
                           nDatenbasis   int, --Datenbasis letzte
                           PRIMARY KEY (kWarengruppe)
                       )

--TODO Erwarteter Gewinn anzeigen

INSERT INTO @tBerechnenFuerTage
VALUES
(0,  14, 30) , --Default
(33, 45, 60), --33 -> Arbeitskleidung / PSA
(26, 0, 60) --33 -> Gartengeräte

--Bestellvorschläge
select *
from (select kArtikel,
             cArtNr,
             cArtikelName,
             fVerfuegbar,
             fZulauf,
             AuftragsAnzahl60,
             --BESTELLMENGE,
             --BESTELLMENGE2,
             --BESTELLMENGE3,
             BESTELLMENGE4 as BestellmengeUngerundet,
             CASE
                 WHEN fEKNetto < 100 AND AuftragsAnzahl60 > 50 AND BESTELLMENGE4 > 50
                     THEN CEILING(BESTELLMENGE4 / 10) * 10
                 WHEN fEKNetto < 2 AND AuftragsAnzahl60 > 10 AND BESTELLMENGE4 > 10
                     THEN CEILING(BESTELLMENGE4 / 10) * 10
                 WHEN fEKNetto < 3 AND AuftragsAnzahl60 > 10 AND BESTELLMENGE4 > 10 THEN CEILING(BESTELLMENGE4 / 5) * 5
                 WHEN fEKNetto < 100 AND AuftragsAnzahl60 > 15 AND BESTELLMENGE4 > 15
                     THEN CEILING(BESTELLMENGE4 / 5) * 5
                 WHEN fEKNetto > 100 AND AuftragsAnzahl60 > 30 AND BESTELLMENGE4 > 30
                     THEN CEILING(BESTELLMENGE4 / 5) * 5
                 ELSE BESTELLMENGE4
                 END AS BestellmengeGerundet,
             effektivBestellt15,
             effektivBestellt30,
             effektivBestellt60,
             cWarengruppeName,
             kWarengruppe,
             nBerechnenFuerTage
      from (SELECT tA.kArtikel
                 , tA.cArtNr
                 , tAB.cName                                                                    as cArtikelName
                 , tLb.fVerfuegbar
                 , tLb.fZulauf
                 , t60.nAuftragsAnzahl                                                          as AuftragsAnzahl60
                 , (SELECT MAX(x) FROM (VALUES
                        (0),
                        (CEILING(IIF(t30.nAuftragsAnzahl > 1,
                            IIF(tBFT.nDatenbasis = 30, t30.effektivBestellt / 30, IIF(tBFT.nDatenbasis = 60, t60.effektivBestellt / 60, 0)) * tBFT.nBerechnenFuerTage,
                            0) - tLb.fVerfuegbar - tLb.fAufEinkaufsliste - tLb.fZulauf))
                    ) as value(x))                           AS BESTELLMENGE4
                 , t15.effektivBestellt                                                         as effektivBestellt15
                 , t30.effektivBestellt                                                         as effektivBestellt30
                 , t60.effektivBestellt                                                         as effektivBestellt60
                 , tWg.cName                                                                    as cWarengruppeName
                 , tWg.kWarengruppe                                                             as kWarengruppe
                 , tA.fEKNetto
                 , tLp.tLieferant_kLieferant                                                    as kLieferant
                 , tLp.fEKNetto                                                                 as fLieferantEk
                 , tBFT.nBerechnenFuerTage                                                      as nBerechnenFuerTage
                 --, FORMAT(COUNT(Monat), '#,#')                    as AuftragsPosAnzahl
            FROM tArtikel tA
                     LEFT JOIN @tSum15Tage t15 ON tA.kArtikel = t15.kArtikel
                     LEFT JOIN @tSum30Tage t30 ON tA.kArtikel = t30.kArtikel
                     LEFT JOIN @tSum60Tage t60 ON tA.kArtikel = t60.kArtikel
                     LEFT JOIN tArtikelBeschreibung tAB ON tA.kArtikel = tAB.kArtikel
                     LEFT JOIN tWarengruppe tWg ON tA.kWarengruppe = tWg.kWarengruppe
                     LEFT JOIN tlagerbestand tLb on tA.kArtikel = tLb.kArtikel
                     LEFT JOIN @tBerechnenFuerTage tBFT ON
                        IIF((SELECT 1
                         FROM @tBerechnenFuerTage tBFT2
                         WHERE tBFT2.kWarengruppe = tA.kWarengruppe) = 1, tA.kWarengruppe, 0) = tBFT.kWarengruppe
                     JOIN tliefartikel tLp
                          on tA.kArtikel = tLp.tArtikel_kArtikel AND tLp.tLieferant_kLieferant = 2 /*Husqvarna*/
            WHERE tA.kZustand = 1 /*Zustand = Standard*/
              AND tA.kStueckliste = 0
              AND tA.nIstVater = 0
              --AND tWg.kWarengruppe = 33
               --AND tA.kArtikel = 1466
           ) tB
      WHERE effektivBestellt60 > 0) t
WHERE BestellmengeGerundet > 0
ORDER BY cWarengruppeName, cArtikelName