/****** Script for SelectTopNRows command from SSMS  ******/
/**
407: Platine Ladestation P1
*/

--Die gewünsche Bevorratung pro Warengruppe
DECLARE @tBerechnenFuerTage AS TABLE
                               (
                                   kWarengruppe       int,
                                   nBasierendAufTage  int, --Datenbasis letzte
                                   nBerechnenFuerTage int,
                                   nMinimumAuftragspositionen int, --Mindestmenge an Auftragspositionen, damit Ware auf Lager gelegt wird
                                   PRIMARY KEY (kWarengruppe)
                               )

--Hier kann eingestellt werden, wie der Bedarf für bestimmte Warengruppen berechnet wird (kWarengruppe, nBasierendAufTage, nBerechnenFuerTage)
INSERT INTO @tBerechnenFuerTage
VALUES
    --(37, 360, 360), -- AM Messer
    (33, 20, 14, 2), --33 -> Arbeitskleidung / PSA
    (29, 20, 14, 2), --29 -> Schienen / Ketten
    (26, 20, 14, 2), --26 -> Gartengeräte
    (27, 20, 14, 4), --26 -> Ersatzteil Gartengeräte
    (35, 20, 14, 4), --26 -> Ersatzteil Husqvarna Gartengerät
    (17, 30, 20, 3), --26 -> Ersatzteil Rasenroboter
    (0, 30, 14, 2) --Default

--Hier kann eingestellt werden, welche Kunden für die Gewinnermittlung ignoriert werden.
DECLARE @tKundeIngorierenGewinn table
                                (
                                    kKunde int
                                );
insert into @tKundeIngorierenGewinn
values (61570);
--61570 -> Intern

--Hier kann eingestellt werden, welche Kunden komplett ignoriert werden.
DECLARE @tKundeIngorieren table
                          (
                              kKunde int
                          );
insert into @tKundeIngorieren
values (8728);
--8728 -> Gieseke

--Hier kann eingestellt werden, ab welchem Faktor Auftrag zum Bestellvorschlag ignoriert wird.
DECLARE @fIgnorierenAbFaktor float = 5;

/*--Auftragspositionen
select *, fEkNetto * fBestellmege as fEkNettoGesammt, fVkNetto * fBestellmege * (1 - fRabatt / 100) as fVkNettoGesammt from (
SELECT lvA.kAuftrag,
             lvA.kAuftragPosition,
             lvA.kArtikel,
             lvA.cName,
             tAu.dErstellt,
             lvA.fAnzahl,
             lvA.fGutgeschrieben,
             CASE WHEN tAu.nStorno = 1 THEN lvA.fAnzahl END                         as fStorniert,
             lvA.fAnzahl - (IIF(tAu.nStorno = 1, lvA.fAnzahl, lvA.fGutgeschrieben)) as fBestellmege,
             lvA.nAuftragStatus,
             tAu.cAuftragsNr,
             tArt.kWarengruppe,
             tBFT.nBasierendAufTage,
             tBFT.nBerechnenFuerTage,
             tAuP.fEkNetto,
             tAuP.fVkNetto,
             tAuP.fRabatt
      FROM Verkauf.lvAuftragsposition lvA
               LEFT JOIN [eazybusiness].[Verkauf].[tAuftrag] tAu ON tAu.kAuftrag = lvA.kAuftrag
               LEFT JOIN [eazybusiness].[Verkauf].[tAuftragPosition] tAuP ON tAuP.kAuftragPosition = lvA.kAuftragPosition
               LEFT JOIN eazybusiness.dbo.tArtikel tArt ON tArt.kArtikel = lvA.kArtikel
               LEFT JOIN @tBerechnenFuerTage tBFT ON
              IIF((SELECT 1
                   FROM @tBerechnenFuerTage tBFT2
                   WHERE tBFT2.kWarengruppe = tArt.kWarengruppe) = 1, tArt.kWarengruppe, 0) = tBFT.kWarengruppe
      WHERE /*tBFT.nBasierendAufTage >= DATEDIFF(day, tAu.dErstellt, getdate()) AND*/ cAuftragsNr = 'D-AU202258247'
      ) lAtAtAPtAtB*/


DECLARE @tAuftragsPositionsAnzahl60 AS TABLE
                                       (
                                           kArtikel                  int,
                                           nAuftragspositionenAnzahl float,
                                           fBestellmengeSumme        float,
                                           PRIMARY KEY (kArtikel)
                                       )

INSERT INTO @tAuftragsPositionsAnzahl60
SELECT lvA.kArtikel,
       COUNT(lvA.kArtikel) as nAuftragspositionenAnzahl,
       SUM(lvA.fAnzahl - (IIF(tAu.nStorno = 1, lvA.fAnzahl, lvA.fGutgeschrieben)))
FROM Verkauf.lvAuftragsposition lvA
         LEFT JOIN [eazybusiness].[Verkauf].[tAuftrag] tAu ON tAu.kAuftrag = lvA.kAuftrag
WHERE 60 >= DATEDIFF(day, tAu.dErstellt, getdate())
  AND lvA.kArtikel IS NOT NULL
  AND tAu.kKunde NOT IN (SELECT kKunde FROM @tKundeIngorieren)
group by lvA.kArtikel

DECLARE @tBestellmengen AS TABLE
                           (
                               kArtikel                int,
                               nBasierendAufTage       int,
                               nBerechnenFuerTage      int,
                               nMinimumAuftragspositionen      int,
                               fBestellteMenge         float,
                               fBerechneteBestellmenge float,
                               fEkNettoDurchschnitt    float,
                               fVkNettoDurchschnitt    float,
                               PRIMARY KEY (kArtikel)
                           )


--TODO Überdruchschnittliche Bestellungen rausfiltern. Diese sollten dann einfach als Druchschnittliche Bestellung gewertet werden.

INSERT INTO @tBestellmengen
select kArtikel,
       nBasierendAufTage,
       nBerechnenFuerTage,
       nMinimumAuftragspositionen,
       SUM(fBestellmenge)                                                     as fBestellmengeSumme,
       SUM(fBestellmenge) / nBasierendAufTage * nBerechnenFuerTage            as fBerechneteBestellmenge,
       IIF(SUM(fBestellmengeOhneIntern) = 0, 0, SUM(fEkNetto * fBestellmengeOhneIntern) /
                                                SUM(fBestellmengeOhneIntern)) as fEkNettoDurchschnitt,
       IIF(SUM(fBestellmengeOhneIntern) = 0, 0, SUM(fVkNetto * fBestellmengeOhneIntern * (1 - fRabatt / 100)) /
                                                SUM(fBestellmengeOhneIntern)) as fVkNettoDurchschnitt
from (select kArtikel,
             nBasierendAufTage,
             nBerechnenFuerTage,
             nMinimumAuftragspositionen,
             fEkNetto,
             fVkNetto,
             fRabatt,
             IIF(fBestellmenge > fDuchtschnittlicheBestellmenge * @fIgnorierenAbFaktor, 0,
                 fBestellmenge)                                                            as fBestellmenge,
             IIF(kKunde IN (SELECT kKunde FROM @tKundeIngorierenGewinn), 0, fBestellmenge) as fBestellmengeOhneIntern
      from (SELECT lvA.kArtikel,
                   lvA.fAnzahl - (IIF(tAu.nStorno = 1, lvA.fAnzahl, lvA.fGutgeschrieben)) as fBestellmenge,
                   tBFT.nBasierendAufTage,
                   tBFT.nBerechnenFuerTage,
                   tBFT.nMinimumAuftragspositionen,
                   tAuP.fEkNetto,
                   tAuP.fVkNetto,
                   tAuP.fRabatt,
                   tAu.kKunde,
                   tAPA60.fBestellmengeSumme / tAPA60.nAuftragspositionenAnzahl           as fDuchtschnittlicheBestellmenge
            FROM Verkauf.lvAuftragsposition lvA
                     LEFT JOIN [eazybusiness].[Verkauf].[tAuftrag] tAu ON tAu.kAuftrag = lvA.kAuftrag
                     LEFT JOIN [eazybusiness].[Verkauf].[tAuftragPosition] tAuP
                               ON tAuP.kAuftragPosition = lvA.kAuftragPosition
                     LEFT JOIN eazybusiness.dbo.tArtikel tArt ON tArt.kArtikel = lvA.kArtikel
                     LEFT JOIN @tAuftragsPositionsAnzahl60 tAPA60 ON tAPA60.kArtikel = lvA.kArtikel
                     LEFT JOIN @tBerechnenFuerTage tBFT ON
                    IIF((SELECT 1
                         FROM @tBerechnenFuerTage tBFT2
                         WHERE tBFT2.kWarengruppe = tArt.kWarengruppe) = 1, tArt.kWarengruppe, 0) = tBFT.kWarengruppe
            WHERE tBFT.nBasierendAufTage >= DATEDIFF(day, tAu.dErstellt, getdate())
              AND lvA.kArtikel IS NOT NULL
              AND tAu.kKunde NOT IN (SELECT kKunde FROM @tKundeIngorieren)
              AND lvA.fAnzahl - (IIF(tAu.nStorno = 1, lvA.fAnzahl, lvA.fGutgeschrieben)) > 0) lAtAtAPtAtB) kAfBS
group by kArtikel, nBasierendAufTage, nBerechnenFuerTage, nMinimumAuftragspositionen


--Bestellvorschläge
SELECT tA.kArtikel
                 , tA.cArtNr
                 , tAB.cName                                           as cArtikelName
                 , tLb.fVerfuegbar
                 , tLb.fZulauf
                 , tAPA60.nAuftragspositionenAnzahl                    as nAuftragsAnzahl60
                 , (SELECT MAX(x)
                    FROM (VALUES (0),
                                 (CEILING(IIF(tAPA60.nAuftragspositionenAnzahl < tBS.nMinimumAuftragspositionen, 0,
                                              tBS.fBerechneteBestellmenge) - tLb.fVerfuegbar - tLb.fAufEinkaufsliste - tLb.fZulauf
                                     ))) as value(x))                  AS BESTELLMENGE4
                    , tAPA60.nAuftragspositionenAnzahl
                    , tBS.nMinimumAuftragspositionen
                    , IIF(tAPA60.nAuftragspositionenAnzahl < tBS.nMinimumAuftragspositionen, 'JA', 'NEIN') as TF
                 , tWg.cName                                           as cWarengruppeName
                 , tWg.kWarengruppe                                    as kWarengruppe
                 , tA.fEKNetto
                 , tLp.tLieferant_kLieferant                           as kLieferant
                 , tBS.fEkNettoDurchschnitt
                 , tBS.fVkNettoDurchschnitt
                 , tBS.fVkNettoDurchschnitt - tBS.fEkNettoDurchschnitt as fGewinnNetto
                 , tBS.nBerechnenFuerTage                              as nBerechnenFuerTage
                 --, FORMAT(COUNT(Monat), '#,#')                    as AuftragsPosAnzahl
            FROM tArtikel tA
                     LEFT JOIN @tBestellmengen tBS ON tA.kArtikel = tBS.kArtikel
                     LEFT JOIN @tAuftragsPositionsAnzahl60 tAPA60 ON tA.kArtikel = tAPA60.kArtikel
                     LEFT JOIN tArtikelBeschreibung tAB ON tA.kArtikel = tAB.kArtikel
                     LEFT JOIN tWarengruppe tWg ON tA.kWarengruppe = tWg.kWarengruppe
                     LEFT JOIN tlagerbestand tLb on tA.kArtikel = tLb.kArtikel
                     JOIN tliefartikel tLp
                          on tA.kArtikel = tLp.tArtikel_kArtikel AND tLp.tLieferant_kLieferant = 2 /*Husqvarna*/
            WHERE tA.kZustand = 1 /*Zustand = Standard*/
              AND tA.kStueckliste = 0
              AND tA.nIstVater = 0
                AND tA.kArtikel = 7897
               --AND tWg.kWarengruppe = 33
               --AND tA.kArtikel = 1466