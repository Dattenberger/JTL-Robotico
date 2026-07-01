-- ============================================================================
-- Artikel: Versandklasse nach Gewicht setzen
-- ============================================================================
--
-- Author:  Sanda Gilca
-- Date:    2026-07-01
-- Version: 1.0
--
-- ============================================================================
-- PURPOSE
-- ============================================================================
--
-- Setzt fuer einen einzelnen Artikel (kArtikel) automatisch die Versandklasse
-- auf "Spedition", wenn das Versandgewicht (dbo.tArtikel.fGewicht) eine
-- Schwelle ueberschreitet. Gedacht als Custom Workflow Action auf dem
-- Workflowobjekt "Artikel" (Trigger: Artikel erstellt / geaendert).
--
-- ============================================================================
-- ENTSCHEIDUNGSLOGIK (bewusst eng gefasst)
-- ============================================================================
--
-- Nur GEWICHT ist in eazybusiness zuverlaessig gepflegt. Die Maßfelder
-- (Breite/Hoehe/Laenge) sind im Bestand leer, und Gefahrgut ist ein
-- Kennzeichen, kein Gewicht. Datenanalyse (JTL-Export 4001 Artikel +
-- Husqvarna-ECAT) zeigt daher: Gewicht kann sauber NUR "standard" <-> "spedition"
-- entscheiden. Die anderen Klassen haengen an anderen Kriterien:
--
--   standard 31,5kg 120x60x60   leicht  -> Standard (99% der Artikel)
--   spedition                   schwer  -> ab Schwelle
--   dpd lang ...                Laenge  -> NICHT ueber Gewicht  (geschuetzt)
--   dpd gefahrgut               Gefahr  -> NICHT ueber Gewicht  (geschuetzt)
--   abholung showroom           Abholung-> NICHT ueber Gewicht  (geschuetzt)
--
-- Regeln, umgesetzt in Robotico.fnVersandklasseNachGewicht:
--   1. GESCHUETZT: Ist die aktuelle Klasse 'DPD%' oder 'Abholung%', bleibt sie
--      IMMER unveraendert (Laenge/Gefahrgut/Abholung schlagen Gewicht).
--   2. NUR HOCHSTUFEN: fGewicht > Schwelle  ->  'Spedition'.
--      Es wird NIE herabgestuft (leichte Speditionsware, z.B. sperrige
--      Akku-Maeher, bleibt bewusst Spedition).
--   3. Sonst: keine Aenderung.
--
-- Default-Schwelle = 31,5 kg. Das ist die im Standard-Klassennamen genannte
-- Obergrenze ("31,5kg"); im Bestand verletzen 42 "standard"-Artikel diese
-- Grenze (bis 276 kg) - genau die korrigiert diese Aktion.
-- Die Schwelle ist als Aktionsparameter konfigurierbar (DotLiquid-faehig).
--
-- PILOT-/SICHERHEITSGRENZE (@kWarengruppe):
--   Optionaler dritter Parameter. Ist er gesetzt, wirkt die Aktion NUR auf
--   Artikel dieser einen Warengruppe (dbo.tArtikel.kWarengruppe). So kann der
--   Workflow risikoarm erst fuer EINE Warengruppe pilotiert werden; laeuft
--   etwas schief, ist der Schaden auf diese Gruppe begrenzt. Fuer den spaeteren
--   Voll-Rollout den Parameter einfach leer lassen (NULL = alle Warengruppen).
--   Warengruppen-ID ermitteln:  SELECT kWarengruppe, cName FROM dbo.tWarengruppe;
--
-- ============================================================================
-- ZWEI LAYER
-- ============================================================================
--
--   Robotico.fnVersandklasseNachGewicht    (scalar) - reine Entscheidung:
--       gibt den NAMEN der Zielklasse zurueck, oder NULL = keine Aenderung.
--       Kennt keine Artikel/keine Tabellen -> trivial testbar.
--   CustomWorkflows.spArtikelVersandklasseNachGewicht (SP) - Aktion:
--       liest Gewicht + aktuelle Klasse, ruft die Funktion, loest den
--       Zielnamen zu kVersandklasse auf und schreibt dbo.tArtikel.
--
-- AUDIT-LOG:
--   Jede TATSAECHLICHE Aenderung wird in Robotico.tVersandklassenLog
--   protokolliert (Artikel, alt/neu, Gewicht, Schwelle, Benutzer, Zeit).
--   Bequem auswertbar ueber die View Robotico.vVersandklassenLog:
--       SELECT * FROM Robotico.vVersandklassenLog ORDER BY dErstellt DESC;
--   Optionaler Parameter @cBenutzer nimmt das JTL-Login auf (DotLiquid:
--   {{ AktuellerBenutzer.Login }}); sonst wird der DB-User geloggt.
--
-- Idempotent (CREATE OR ALTER) und transaktional. Gegen eazybusiness ausfuehren.
-- Voraussetzung: Modul "Custom Workflow Actions" lizenziert (siehe
-- docs/SQL/JTL-CUSTOM-WORKFLOWS.md).
-- ============================================================================

USE [eazybusiness]
GO

SET XACT_ABORT ON
GO

BEGIN TRANSACTION
GO

-- ----------------------------------------------------------------------------
-- Audit-Log: jede automatische Aenderung wird hier protokolliert
-- ----------------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables
               WHERE name = 'tVersandklassenLog' AND schema_id = SCHEMA_ID('Robotico'))
    CREATE TABLE Robotico.tVersandklassenLog
    (
        kVersandklassenLog INT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_tVersandklassenLog PRIMARY KEY,
        kArtikel           INT            NOT NULL,
        cArtNr             NVARCHAR(255)  NULL,   -- Snapshot der Artikelnummer
        fGewicht           DECIMAL(25,13) NULL,   -- Gewicht, das die Aenderung ausloeste
        fSchwelleKg        DECIMAL(18,3)  NULL,   -- verwendete Schwelle
        kVersandklasseAlt  INT            NULL,
        cVersandklasseAlt  NVARCHAR(255)  NULL,
        kVersandklasseNeu  INT            NULL,
        cVersandklasseNeu  NVARCHAR(255)  NULL,
        cBenutzer          NVARCHAR(255)  NULL,   -- JTL-Login (falls uebergeben) sonst DB-User
        dErstellt          DATETIME2(0)   NOT NULL
            CONSTRAINT DF_tVersandklassenLog_dErstellt DEFAULT (SYSDATETIME())
    );
GO

-- ----------------------------------------------------------------------------
-- Layer 1: reine Entscheidungsfunktion (kein Tabellenzugriff)
-- ----------------------------------------------------------------------------
CREATE OR ALTER FUNCTION Robotico.fnVersandklasseNachGewicht
(
    @fGewicht    DECIMAL(25, 13),   -- Versandgewicht des Artikels (kg)
    @fSchwelleKg DECIMAL(18, 3),    -- Grenze, ab der "Spedition" gilt
    @cAktuell    NVARCHAR(255)      -- aktueller Versandklassen-Name (kann NULL sein)
)
RETURNS NVARCHAR(255)              -- Name der ZU SETZENDEN Klasse, oder NULL = keine Aenderung
AS
BEGIN
    -- 1. Geschuetzte Klassen: Laenge/Gefahrgut/Abholung schlagen Gewicht.
    IF @cAktuell LIKE 'DPD%' OR @cAktuell LIKE 'Abholung%'
        RETURN NULL;

    -- 2. Nur hochstufen: schwer -> Spedition (kein Downgrade).
    IF @fGewicht > @fSchwelleKg
       AND (@cAktuell IS NULL OR @cAktuell <> 'Spedition')
        RETURN 'Spedition';

    -- 3. Leicht / bereits korrekt -> unveraendert lassen.
    RETURN NULL;
END
GO

-- ----------------------------------------------------------------------------
-- Layer 2: Custom Workflow Action (Workflowobjekt Artikel -> @kArtikel)
-- ----------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE CustomWorkflows.spArtikelVersandklasseNachGewicht
    @kArtikel     INT,                      -- pos 0: PK, von JTL zur Laufzeit gefuellt
    @fSchwelleKg  DECIMAL(18, 3) = 31.5,    -- pos 1: Grenze in kg (im Workflow einstellbar)
    @kWarengruppe INT           = NULL,     -- pos 2: OPTIONAL. Wenn gesetzt, wirkt die
                                            --        Aktion NUR auf Artikel dieser
                                            --        Warengruppe (Pilot-/Sicherheits-
                                            --        grenze). NULL = alle Warengruppen.
    @cBenutzer    NVARCHAR(255) = NULL      -- pos 3: OPTIONAL. JTL-Login fuers Log,
                                            --        im Workflow via DotLiquid:
                                            --        {{ AktuellerBenutzer.Login }}
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @fGewicht          DECIMAL(25, 13),
            @cAktuell          NVARCHAR(255),
            @kAlt              INT,
            @cArtNr            NVARCHAR(255),
            @kArtikelWarengrp  INT,
            @cZiel             NVARCHAR(255),
            @kZiel             INT;

    -- Gewicht + aktuelle Klasse (Id+Name) + Warengruppe + Snapshotfeld lesen
    SELECT @fGewicht         = a.fGewicht,
           @kAlt             = a.kVersandklasse,
           @cAktuell         = vk.cName,
           @cArtNr           = a.cArtNr,
           @kArtikelWarengrp = a.kWarengruppe
    FROM dbo.tArtikel a
             LEFT JOIN dbo.tVersandklasse vk ON vk.kVersandklasse = a.kVersandklasse
    WHERE a.kArtikel = @kArtikel;

    IF @@ROWCOUNT = 0
        RETURN;   -- Artikel existiert nicht -> nichts tun

    -- Sicherheitsgrenze: nur die Pilot-Warengruppe anfassen (falls gesetzt)
    IF @kWarengruppe IS NOT NULL AND @kArtikelWarengrp <> @kWarengruppe
        RETURN;   -- gehoert nicht zur Pilot-Warengruppe -> nichts tun

    -- Entscheidung an die reine Funktion delegieren
    SET @cZiel = Robotico.fnVersandklasseNachGewicht(@fGewicht, @fSchwelleKg, @cAktuell);

    IF @cZiel IS NULL
        RETURN;   -- keine Aenderung noetig

    -- Zielklasse aufloesen (CI-Collation -> Groß/Kleinschreibung egal)
    SELECT @kZiel = kVersandklasse
    FROM dbo.tVersandklasse
    WHERE cName = @cZiel;

    IF @kZiel IS NULL
    BEGIN
        -- Fehlkonfiguration sichtbar machen (bei CancelOnError=false bricht der
        -- Workflow NICHT ab; der Artikel bleibt einfach unveraendert).
        RAISERROR('Versandklasse "%s" nicht in dbo.tVersandklasse gefunden - Artikel %d unveraendert.',
                  11, 0, @cZiel, @kArtikel);
        RETURN;
    END

    UPDATE dbo.tArtikel
    SET kVersandklasse = @kZiel
    WHERE kArtikel = @kArtikel
      AND (kVersandklasse IS NULL OR kVersandklasse <> @kZiel);

    -- Nur bei tatsaechlicher Aenderung protokollieren
    IF @@ROWCOUNT > 0
        INSERT INTO Robotico.tVersandklassenLog
            (kArtikel, cArtNr, fGewicht, fSchwelleKg,
             kVersandklasseAlt, cVersandklasseAlt, kVersandklasseNeu, cVersandklasseNeu, cBenutzer)
        VALUES
            (@kArtikel, @cArtNr, @fGewicht, @fSchwelleKg,
             @kAlt, @cAktuell, @kZiel, @cZiel, ISNULL(@cBenutzer, SUSER_SNAME()));
END
GO

-- ----------------------------------------------------------------------------
-- Auswertungs-View auf das Log (bequem fuer "was hat der Workflow geaendert?")
-- ----------------------------------------------------------------------------
CREATE OR ALTER VIEW Robotico.vVersandklassenLog
AS
SELECT l.kVersandklassenLog,
       l.dErstellt,
       l.kArtikel,
       l.cArtNr,
       wg.cName AS cWarengruppe,
       l.fGewicht,
       l.fSchwelleKg,
       l.cVersandklasseAlt,
       l.cVersandklasseNeu,
       l.cBenutzer
FROM Robotico.tVersandklassenLog l
         LEFT JOIN dbo.tArtikel a     ON a.kArtikel = l.kArtikel
         LEFT JOIN dbo.tWarengruppe wg ON wg.kWarengruppe = a.kWarengruppe;
GO

IF XACT_STATE() = 1 COMMIT TRANSACTION; ELSE ROLLBACK TRANSACTION;
GO

-- ----------------------------------------------------------------------------
-- Registrierung als JTL-Aktion (Validierung + UI-Label)
-- ----------------------------------------------------------------------------
EXEC CustomWorkflows._CheckAction @actionName = 'spArtikelVersandklasseNachGewicht'
GO

EXEC CustomWorkflows._SetActionDisplayName
     @actionName  = 'spArtikelVersandklasseNachGewicht',
     @displayName = 'Artikel: Versandklasse nach Gewicht setzen'
GO
