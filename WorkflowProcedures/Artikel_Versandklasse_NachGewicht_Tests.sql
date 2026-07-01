-- ============================================================================
-- Test Suite: Artikel Versandklasse nach Gewicht (transaction-based)
-- ============================================================================
-- Description:
--   Validiert Robotico.fnVersandklasseNachGewicht (rein) und
--   CustomWorkflows.spArtikelVersandklasseNachGewicht (Aktion).
--   Die SP-Tests laufen in einer Transaktion und werden zurueckgerollt -
--   es bleiben KEINE Datenbank-Aenderungen zurueck.
--
-- Pattern: BEGIN TRANSACTION -> update -> assert -> ROLLBACK TRANSACTION
--
-- Voraussetzung: Artikel_Versandklasse_NachGewicht.sql wurde deployt und in
--   dbo.tVersandklasse existiert eine Klasse 'Spedition'.
--
-- Author: Sanda Gilca
-- Date:   2026-07-01
-- ============================================================================

USE [eazybusiness]
GO

IF OBJECT_ID('tempdb..#TestResults') IS NOT NULL DROP TABLE #TestResults;
CREATE TABLE #TestResults (testName NVARCHAR(200), passed BIT, detail NVARCHAR(400));
GO

-- ============================================================================
-- Teil 1: Reine Funktion Robotico.fnVersandklasseNachGewicht
-- ============================================================================
-- Erwartung: NULL = keine Aenderung, sonst der zu setzende Klassenname.

DECLARE @schwelle DECIMAL(18,3) = 31.5;

INSERT INTO #TestResults (testName, passed, detail)
SELECT c.testName,
       CASE WHEN ISNULL(Robotico.fnVersandklasseNachGewicht(c.fGewicht, @schwelle, c.cAktuell),'<NULL>')
                 = ISNULL(c.erwartet,'<NULL>') THEN 1 ELSE 0 END,
       CONCAT('erwartet=', ISNULL(c.erwartet,'<NULL>'),
              ' / ist=', ISNULL(Robotico.fnVersandklasseNachGewicht(c.fGewicht, @schwelle, c.cAktuell),'<NULL>'))
FROM (VALUES
    -- schwer + standard            -> hochstufen auf Spedition
    ('Fn: schwer standard -> Spedition',        40.0, 'standard 31,5kg 120x60x60', 'Spedition'),
    -- schwer + Klasse NULL          -> hochstufen
    ('Fn: schwer ohne Klasse -> Spedition',     50.0, CAST(NULL AS NVARCHAR(255)), 'Spedition'),
    -- leicht + standard            -> keine Aenderung
    ('Fn: leicht standard -> keine Aenderung',   2.0, 'standard 31,5kg 120x60x60', CAST(NULL AS NVARCHAR(255))),
    -- genau auf der Schwelle (nicht groesser) -> keine Aenderung
    ('Fn: exakt Schwelle -> keine Aenderung',   31.5, 'standard 31,5kg 120x60x60', CAST(NULL AS NVARCHAR(255))),
    -- schwer + bereits Spedition   -> keine Aenderung (kein Doppel-Set)
    ('Fn: schwer bereits Spedition -> keine',   80.0, 'Spedition',                 CAST(NULL AS NVARCHAR(255))),
    -- leicht + Spedition           -> KEIN Downgrade
    ('Fn: leicht Spedition -> kein Downgrade',   5.0, 'Spedition',                 CAST(NULL AS NVARCHAR(255))),
    -- geschuetzt: DPD Lang, egal wie schwer -> unveraendert
    ('Fn: schwer DPD Lang -> geschuetzt',       40.0, 'dpd lang 1,75m 3m 31,5kg',  CAST(NULL AS NVARCHAR(255))),
    -- geschuetzt: DPD Gefahrgut                -> unveraendert
    ('Fn: schwer DPD Gefahrgut -> geschuetzt',  40.0, 'dpd gefahrgut',             CAST(NULL AS NVARCHAR(255))),
    -- geschuetzt: Abholung Showroom            -> unveraendert
    ('Fn: schwer Abholung -> geschuetzt',      300.0, 'abholung showroom',         CAST(NULL AS NVARCHAR(255)))
) AS c(testName, fGewicht, cAktuell, erwartet);
GO

-- ============================================================================
-- Teil 2: Aktion CustomWorkflows.spArtikelVersandklasseNachGewicht
-- ============================================================================
-- Strategie: einen realen Artikel nehmen, in einer Transaktion Gewicht/Klasse
-- setzen, Aktion ausfuehren, Ergebnis pruefen, dann ROLLBACK.

DECLARE @kSpedition INT = (SELECT kVersandklasse FROM dbo.tVersandklasse WHERE cName = 'Spedition');
DECLARE @kStandard  INT = (SELECT TOP 1 kVersandklasse FROM dbo.tVersandklasse WHERE cName LIKE 'standard%' ORDER BY kVersandklasse);
DECLARE @kArtikel   INT = (SELECT TOP 1 kArtikel FROM dbo.tArtikel ORDER BY kArtikel);
DECLARE @kWG1       INT = (SELECT MIN(kWarengruppe) FROM dbo.tWarengruppe);
DECLARE @kWG2       INT = (SELECT MIN(kWarengruppe) FROM dbo.tWarengruppe WHERE kWarengruppe <> (SELECT MIN(kWarengruppe) FROM dbo.tWarengruppe));

IF @kSpedition IS NULL
    INSERT INTO #TestResults VALUES ('SETUP', 0, 'Versandklasse "Spedition" fehlt in dbo.tVersandklasse');
ELSE IF @kArtikel IS NULL
    INSERT INTO #TestResults VALUES ('SETUP', 0, 'Kein Artikel in dbo.tArtikel gefunden');
ELSE
BEGIN
    -- Test A: schwerer Standard-Artikel wird auf Spedition hochgestuft
    BEGIN TRANSACTION;
        UPDATE dbo.tArtikel SET fGewicht = 42.0, kVersandklasse = @kStandard WHERE kArtikel = @kArtikel;
        EXEC CustomWorkflows.spArtikelVersandklasseNachGewicht @kArtikel = @kArtikel;  -- Default-Schwelle 31,5
        INSERT INTO #TestResults
        SELECT 'SP: schwer Standard -> Spedition',
               CASE WHEN kVersandklasse = @kSpedition THEN 1 ELSE 0 END,
               CONCAT('kVersandklasse=', kVersandklasse, ' erwartet=', @kSpedition)
        FROM dbo.tArtikel WHERE kArtikel = @kArtikel;
        -- Log-Zeile muss geschrieben worden sein
        INSERT INTO #TestResults
        SELECT 'SP: Aenderung wird geloggt',
               CASE WHEN COUNT(*) = 1 THEN 1 ELSE 0 END,
               CONCAT('Log-Zeilen=', COUNT(*), ' erwartet=1')
        FROM Robotico.tVersandklassenLog
        WHERE kArtikel = @kArtikel AND kVersandklasseNeu = @kSpedition;
    ROLLBACK TRANSACTION;

    -- Test B: leichter Standard-Artikel bleibt unveraendert
    BEGIN TRANSACTION;
        UPDATE dbo.tArtikel SET fGewicht = 3.0, kVersandklasse = @kStandard WHERE kArtikel = @kArtikel;
        EXEC CustomWorkflows.spArtikelVersandklasseNachGewicht @kArtikel = @kArtikel;
        INSERT INTO #TestResults
        SELECT 'SP: leicht Standard -> unveraendert',
               CASE WHEN kVersandklasse = @kStandard THEN 1 ELSE 0 END,
               CONCAT('kVersandklasse=', kVersandklasse, ' erwartet=', @kStandard)
        FROM dbo.tArtikel WHERE kArtikel = @kArtikel;
        -- Ohne Aenderung darf KEIN Log entstehen
        INSERT INTO #TestResults
        SELECT 'SP: keine Aenderung -> kein Log',
               CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END,
               CONCAT('Log-Zeilen=', COUNT(*), ' erwartet=0')
        FROM Robotico.tVersandklassenLog WHERE kArtikel = @kArtikel;
    ROLLBACK TRANSACTION;

    -- Test C: konfigurierbare Schwelle greift (Schwelle 10 -> 12 kg wird hochgestuft)
    BEGIN TRANSACTION;
        UPDATE dbo.tArtikel SET fGewicht = 12.0, kVersandklasse = @kStandard WHERE kArtikel = @kArtikel;
        EXEC CustomWorkflows.spArtikelVersandklasseNachGewicht @kArtikel = @kArtikel, @fSchwelleKg = 10.0;
        INSERT INTO #TestResults
        SELECT 'SP: eigene Schwelle 10kg -> Spedition',
               CASE WHEN kVersandklasse = @kSpedition THEN 1 ELSE 0 END,
               CONCAT('kVersandklasse=', kVersandklasse, ' erwartet=', @kSpedition)
        FROM dbo.tArtikel WHERE kArtikel = @kArtikel;
    ROLLBACK TRANSACTION;

    -- Test D: Warengruppen-Schutz - passende Warengruppe -> wird hochgestuft
    BEGIN TRANSACTION;
        UPDATE dbo.tArtikel SET fGewicht = 42.0, kVersandklasse = @kStandard, kWarengruppe = @kWG1 WHERE kArtikel = @kArtikel;
        EXEC CustomWorkflows.spArtikelVersandklasseNachGewicht @kArtikel = @kArtikel, @kWarengruppe = @kWG1;
        INSERT INTO #TestResults
        SELECT 'SP: Pilot-Warengruppe passt -> Spedition',
               CASE WHEN kVersandklasse = @kSpedition THEN 1 ELSE 0 END,
               CONCAT('kVersandklasse=', kVersandklasse, ' erwartet=', @kSpedition)
        FROM dbo.tArtikel WHERE kArtikel = @kArtikel;
    ROLLBACK TRANSACTION;

    -- Test E: Warengruppen-Schutz - andere Warengruppe -> bleibt unveraendert
    BEGIN TRANSACTION;
        UPDATE dbo.tArtikel SET fGewicht = 42.0, kVersandklasse = @kStandard, kWarengruppe = @kWG1 WHERE kArtikel = @kArtikel;
        EXEC CustomWorkflows.spArtikelVersandklasseNachGewicht @kArtikel = @kArtikel, @kWarengruppe = @kWG2;
        INSERT INTO #TestResults
        SELECT 'SP: andere Warengruppe -> unveraendert',
               CASE WHEN kVersandklasse = @kStandard THEN 1 ELSE 0 END,
               CONCAT('kVersandklasse=', kVersandklasse, ' erwartet=', @kStandard)
        FROM dbo.tArtikel WHERE kArtikel = @kArtikel;
    ROLLBACK TRANSACTION;
END
GO

-- ============================================================================
-- Ergebnis
-- ============================================================================
SELECT testName, CASE WHEN passed = 1 THEN 'PASS' ELSE 'FAIL' END AS Ergebnis, detail
FROM #TestResults
ORDER BY passed, testName;

DECLARE @fail INT = (SELECT COUNT(*) FROM #TestResults WHERE passed = 0);
DECLARE @all  INT = (SELECT COUNT(*) FROM #TestResults);
PRINT CONCAT('Tests: ', @all - @fail, '/', @all, ' bestanden.');
IF @fail > 0 PRINT '!!! Es sind Tests FEHLGESCHLAGEN !!!';
GO

IF OBJECT_ID('tempdb..#TestResults') IS NOT NULL DROP TABLE #TestResults;
GO
