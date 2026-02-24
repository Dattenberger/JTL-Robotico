-- ============================================================================
-- Test Suite fuer History Stored Procedures (Transaction-based)
-- ============================================================================
-- Description:
--   Test-Queries zum Validieren der History SPs nach Refactoring auf
--   Robotico Utility Functions und Custom Field API.
--   Jeder Test laeuft in einer eigenen Transaction und wird automatisch
--   zurueckgerollt - keine Datenbank-Aenderungen verbleiben nach den Tests.
--
-- Components tested:
--   - CustomWorkflows.spArticleAppendPriceHistory
--   - CustomWorkflows.spArticleAppendLabelHistory
--   - CustomWorkflows.spArticleUpdateAllHistory
--
-- Test Articles (eazybusiness_tm2):
--   kArtikel = 19807: VKNetto=293,28  Puffer=0  1 Label   KEINE History
--   kArtikel = 73:    VKNetto=11,76   Puffer=0  2 Labels  HAT History
--   kArtikel = 234:   VKNetto=242,82  Puffer=5  1 Label
--
-- Pattern: BEGIN TRANSACTION -> Test -> ROLLBACK TRANSACTION
--
-- Author: Lukas Dattenberger
-- Date: 2026-02-24
-- ============================================================================

IF OBJECT_ID('tempdb..#TestResults') IS NOT NULL DROP TABLE #TestResults;
CREATE TABLE #TestResults (testName NVARCHAR(200), passed INT, total INT);
GO

-- ============================================================================
-- Temp Helper: History-Info lesen (Zeilenanzahl + letzte Zeile)
-- ============================================================================
IF OBJECT_ID('tempdb..#GetHistoryInfo') IS NOT NULL
    EXEC('DROP PROCEDURE #GetHistoryInfo');
GO

CREATE PROCEDURE #GetHistoryInfo
    @kArtikel INT,
    @fieldName NVARCHAR(255),
    @lineCount INT OUTPUT,
    @lastLine NVARCHAR(MAX) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @history NVARCHAR(MAX) = Robotico.fnGetArticleCustomFieldValue(@kArtikel, @fieldName, 0);
    IF Robotico.fnStringIsEffectivelyEmpty(@history) = 1
    BEGIN
        SET @lineCount = 0;
        SET @lastLine = NULL;
    END
    ELSE
    BEGIN
        SET @lineCount = Robotico.fnStringCountLines(@history);
        SET @lastLine = Robotico.fnEscapedCSVGetLastLine(@history);
    END
END
GO

PRINT '============================================================================';
PRINT 'History Stored Procedures - Test Suite (Transaction-based)';
PRINT '============================================================================';
PRINT '';
PRINT 'Test Articles:';
PRINT '  kArtikel = 19807: VKNetto=293,28  Puffer=0  1 Label   KEINE History';
PRINT '  kArtikel = 73:    VKNetto=11,76   Puffer=0  2 Labels  HAT History';
PRINT '  kArtikel = 234:   VKNetto=242,82  Puffer=5  1 Label';
PRINT '';
PRINT 'All tests use transactions and rollback automatically.';
PRINT 'No database changes will remain after test execution.';
PRINT '';

-- ============================================================================
-- Test 1: PriceHistory - Erstanlage + Format + VkBrutto
-- ============================================================================
PRINT '--- Test 1: PriceHistory - Erstanlage + Format (kArtikel=19807, keine History) ---';

DECLARE @t1_passed INT = 0, @t1_total INT = 5;

BEGIN TRANSACTION;
BEGIN TRY
    EXEC CustomWorkflows.spArticleAppendPriceHistory @kArtikel = 19807, @userName = 'TestUser';

    DECLARE @t1_lines INT, @t1_last NVARCHAR(MAX);
    EXEC #GetHistoryInfo 19807, 'Vergangene Preise', @t1_lines OUTPUT, @t1_last OUTPUT;

    -- Check 1: Genau 1 Zeile (Erstanlage via spEnsureArticleCustomField)
    IF @t1_lines = 1
    BEGIN PRINT '  + Line count = 1 (Binding auto-created)'; SET @t1_passed += 1; END
    ELSE PRINT '  x Line count = ' + CAST(@t1_lines AS NVARCHAR(10)) + ' (expected 1)';

    -- Check 2: VkNetto (293,28)
    IF @t1_last LIKE '%; 293,28; %'
    BEGIN PRINT '  + VkNetto 293,28 found'; SET @t1_passed += 1; END
    ELSE PRINT '  x VkNetto not found: ' + ISNULL(LEFT(@t1_last, 80), 'NULL');

    -- Check 3: VkBrutto = VkNetto * 1.19 (349,00)
    DECLARE @t1_brutto DECIMAL(25,13) = Robotico.fnStringParseGermanDecimal(
        Robotico.fnEscapedCSVGetField(@t1_last, 3, ';'));
    DECLARE @t1_netto DECIMAL(25,13) = Robotico.fnStringParseGermanDecimal(
        Robotico.fnEscapedCSVGetField(@t1_last, 2, ';'));
    IF @t1_brutto IS NOT NULL AND ABS(@t1_brutto - @t1_netto * 1.19) < 0.01
    BEGIN PRINT '  + VkBrutto korrekt: ' + FORMAT(@t1_brutto, 'N2', 'de-DE'); SET @t1_passed += 1; END
    ELSE PRINT '  x VkBrutto falsch: ' + ISNULL(CAST(@t1_brutto AS NVARCHAR(20)), 'NULL');

    -- Check 4: Puffer 0
    IF @t1_last LIKE '%Puffer 0%'
    BEGIN PRINT '  + Puffer 0 found'; SET @t1_passed += 1; END
    ELSE PRINT '  x Puffer 0 not found';

    -- Check 5: Username
    IF @t1_last LIKE '%TestUser'
    BEGIN PRINT '  + Username found'; SET @t1_passed += 1; END
    ELSE PRINT '  x Username not found';

    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT '  x ERROR: ' + ERROR_MESSAGE();
END CATCH

PRINT '  Result: ' + CAST(@t1_passed AS NVARCHAR(5)) + '/' + CAST(@t1_total AS NVARCHAR(5)) + ' passed';
INSERT INTO #TestResults VALUES ('PriceHistory: Erstanlage + Format', @t1_passed, @t1_total);
PRINT '';
GO

-- ============================================================================
-- Test 2: PriceHistory - Keine Aenderung bei gleichem Preis
-- ============================================================================
PRINT '--- Test 2: PriceHistory - Keine Aenderung (kArtikel=73, Preis+Puffer gleich) ---';

DECLARE @t2_passed INT = 0, @t2_total INT = 1;

BEGIN TRANSACTION;
BEGIN TRY
    -- Erst Baseline setzen: SP aufrufen damit aktueller Preis als Eintrag existiert
    EXEC CustomWorkflows.spArticleAppendPriceHistory @kArtikel = 73, @userName = 'BaselineCall';

    DECLARE @t2_before INT, @t2_after INT, @t2_dummy NVARCHAR(MAX);
    EXEC #GetHistoryInfo 73, 'Vergangene Preise', @t2_before OUTPUT, @t2_dummy OUTPUT;

    -- Zweiter Aufruf: gleicher Preis/Puffer -> darf KEINEN neuen Eintrag erzeugen
    EXEC CustomWorkflows.spArticleAppendPriceHistory @kArtikel = 73, @userName = 'NoChangeTest';

    EXEC #GetHistoryInfo 73, 'Vergangene Preise', @t2_after OUTPUT, @t2_dummy OUTPUT;

    IF @t2_before = @t2_after
    BEGIN PRINT '  + Kein Eintrag (Preis unveraendert, ' + CAST(@t2_before AS NVARCHAR(10)) + ' Zeilen)'; SET @t2_passed += 1; END
    ELSE PRINT '  x Eintrag trotz gleichem Preis (vorher: ' + CAST(@t2_before AS NVARCHAR(10)) + ', nachher: ' + CAST(@t2_after AS NVARCHAR(10)) + ')';

    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT '  x ERROR: ' + ERROR_MESSAGE();
END CATCH

PRINT '  Result: ' + CAST(@t2_passed AS NVARCHAR(5)) + '/' + CAST(@t2_total AS NVARCHAR(5)) + ' passed';
INSERT INTO #TestResults VALUES ('PriceHistory: Keine Aenderung', @t2_passed, @t2_total);
PRINT '';
GO

-- ============================================================================
-- Test 3: PriceHistory - Doppelaufruf (eigenes Format korrekt zurueckgeparst)
-- ============================================================================
PRINT '--- Test 3: PriceHistory - Doppelaufruf (kArtikel=19807, 2x aufrufen) ---';

DECLARE @t3a_passed INT = 0, @t3a_total INT = 1;

BEGIN TRANSACTION;
BEGIN TRY
    -- Erster Aufruf: erstellt Eintrag
    EXEC CustomWorkflows.spArticleAppendPriceHistory @kArtikel = 19807, @userName = 'DoppelTest';

    DECLARE @t3a_after1 INT, @t3a_dummy NVARCHAR(MAX);
    EXEC #GetHistoryInfo 19807, 'Vergangene Preise', @t3a_after1 OUTPUT, @t3a_dummy OUTPUT;

    -- Zweiter Aufruf: gleicher Preis/Puffer -> darf KEINEN neuen Eintrag erzeugen
    EXEC CustomWorkflows.spArticleAppendPriceHistory @kArtikel = 19807, @userName = 'DoppelTest2';

    DECLARE @t3a_after2 INT;
    EXEC #GetHistoryInfo 19807, 'Vergangene Preise', @t3a_after2 OUTPUT, @t3a_dummy OUTPUT;

    IF @t3a_after1 = 1 AND @t3a_after2 = 1
    BEGIN PRINT '  + Zweiter Aufruf hat keinen Eintrag hinzugefuegt (1 Zeile)'; SET @t3a_passed += 1; END
    ELSE PRINT '  x Nach 1. Aufruf: ' + CAST(@t3a_after1 AS NVARCHAR(10)) + ', nach 2. Aufruf: ' + CAST(@t3a_after2 AS NVARCHAR(10)) + ' (erwartet: 1, 1)';

    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT '  x ERROR: ' + ERROR_MESSAGE();
END CATCH

PRINT '  Result: ' + CAST(@t3a_passed AS NVARCHAR(5)) + '/' + CAST(@t3a_total AS NVARCHAR(5)) + ' passed';
INSERT INTO #TestResults VALUES ('PriceHistory: Doppelaufruf', @t3a_passed, @t3a_total);
PRINT '';
GO

-- ============================================================================
-- Test 4: PriceHistory - Preisaenderung erkennen
-- ============================================================================
PRINT '--- Test 4: PriceHistory - Preisaenderung erkennen (kArtikel=73, +10 EUR) ---';

DECLARE @t3_passed INT = 0, @t3_total INT = 2;

BEGIN TRANSACTION;
BEGIN TRY
    DECLARE @t3_before INT, @t3_dummy NVARCHAR(MAX);
    EXEC #GetHistoryInfo 73, 'Vergangene Preise', @t3_before OUTPUT, @t3_dummy OUTPUT;

    UPDATE dbo.tArtikel SET fVKNetto = fVKNetto + 10.00 WHERE kArtikel = 73;

    EXEC CustomWorkflows.spArticleAppendPriceHistory @kArtikel = 73, @userName = 'PriceChangeTest';

    DECLARE @t3_after INT, @t3_last NVARCHAR(MAX);
    EXEC #GetHistoryInfo 73, 'Vergangene Preise', @t3_after OUTPUT, @t3_last OUTPUT;

    -- Check 1: Zeile hinzugefuegt
    IF @t3_after = @t3_before + 1
    BEGIN PRINT '  + Zeile hinzugefuegt (' + CAST(@t3_before AS NVARCHAR(10)) + ' -> ' + CAST(@t3_after AS NVARCHAR(10)) + ')'; SET @t3_passed += 1; END
    ELSE PRINT '  x Zeilenanzahl: vorher=' + CAST(@t3_before AS NVARCHAR(10)) + ', nachher=' + CAST(@t3_after AS NVARCHAR(10));

    -- Check 2: Neuer Preis (21,76) im Eintrag
    IF @t3_last LIKE '%; 21,76; %'
    BEGIN PRINT '  + Neuer Preis 21,76 gefunden'; SET @t3_passed += 1; END
    ELSE PRINT '  x Preis nicht gefunden: ' + ISNULL(LEFT(@t3_last, 80), 'NULL');

    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT '  x ERROR: ' + ERROR_MESSAGE();
END CATCH

PRINT '  Result: ' + CAST(@t3_passed AS NVARCHAR(5)) + '/' + CAST(@t3_total AS NVARCHAR(5)) + ' passed';
INSERT INTO #TestResults VALUES ('PriceHistory: Preisaenderung', @t3_passed, @t3_total);
PRINT '';
GO

-- ============================================================================
-- Test 5: PriceHistory - Puffer-Aenderung erkennen
-- ============================================================================
PRINT '--- Test 5: PriceHistory - Puffer-Aenderung (kArtikel=234, Puffer 5->99) ---';

DECLARE @t4_passed INT = 0, @t4_total INT = 2;

BEGIN TRANSACTION;
BEGIN TRY
    -- Puffer aendern um Change zu erzwingen
    UPDATE dbo.tArtikel SET nPuffer = 99 WHERE kArtikel = 234;

    EXEC CustomWorkflows.spArticleAppendPriceHistory @kArtikel = 234, @userName = 'PufferTest';

    DECLARE @t4_lines INT, @t4_last NVARCHAR(MAX);
    EXEC #GetHistoryInfo 234, 'Vergangene Preise', @t4_lines OUTPUT, @t4_last OUTPUT;

    -- Check 1: Eintrag erstellt
    IF @t4_lines > 0 AND @t4_last IS NOT NULL
    BEGIN PRINT '  + Eintrag erstellt (' + CAST(@t4_lines AS NVARCHAR(10)) + ' Zeilen)'; SET @t4_passed += 1; END
    ELSE PRINT '  x Kein Eintrag erstellt';

    -- Check 2: Puffer 99 im letzten Eintrag
    IF @t4_last LIKE '%Puffer 99%'
    BEGIN PRINT '  + Puffer 99 gefunden'; SET @t4_passed += 1; END
    ELSE PRINT '  x Puffer 99 nicht gefunden: ' + ISNULL(LEFT(@t4_last, 80), 'NULL');

    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT '  x ERROR: ' + ERROR_MESSAGE();
END CATCH

PRINT '  Result: ' + CAST(@t4_passed AS NVARCHAR(5)) + '/' + CAST(@t4_total AS NVARCHAR(5)) + ' passed';
INSERT INTO #TestResults VALUES ('PriceHistory: Puffer-Aenderung', @t4_passed, @t4_total);
PRINT '';
GO

-- ============================================================================
-- Test 6: PriceHistory - Username-Sanitization
-- ============================================================================
PRINT '--- Test 6: PriceHistory - Username mit Sonderzeichen ---';

DECLARE @t5_passed INT = 0, @t5_total INT = 2;

BEGIN TRANSACTION;
BEGIN TRY
    EXEC CustomWorkflows.spArticleAppendPriceHistory
        @kArtikel = 19807,
        @userName = 'Test;User"mit''Sonder;zeichen';

    DECLARE @t5_lines INT, @t5_last NVARCHAR(MAX);
    EXEC #GetHistoryInfo 19807, 'Vergangene Preise', @t5_lines OUTPUT, @t5_last OUTPUT;

    -- Check 1: Eintrag erstellt
    IF @t5_lines = 1
    BEGIN PRINT '  + Eintrag erstellt'; SET @t5_passed += 1; END
    ELSE PRINT '  x Zeilenanzahl: ' + CAST(@t5_lines AS NVARCHAR(10));

    -- Check 2: Username-Feld (Feld 5) enthaelt keine Semikolons/Quotes
    DECLARE @t5_user NVARCHAR(MAX) = Robotico.fnEscapedCSVGetField(@t5_last, 5, ';');
    IF @t5_user NOT LIKE '%;%' AND @t5_user NOT LIKE '%"%' AND @t5_user NOT LIKE '%''%'
        AND LEN(@t5_user) > 0
    BEGIN PRINT '  + Username sanitized: [' + @t5_user + ']'; SET @t5_passed += 1; END
    ELSE PRINT '  x Username nicht korrekt sanitized: [' + ISNULL(@t5_user, 'NULL') + ']';

    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT '  x ERROR: ' + ERROR_MESSAGE();
END CATCH

PRINT '  Result: ' + CAST(@t5_passed AS NVARCHAR(5)) + '/' + CAST(@t5_total AS NVARCHAR(5)) + ' passed';
INSERT INTO #TestResults VALUES ('PriceHistory: Username-Sanitization', @t5_passed, @t5_total);
PRINT '';
GO

-- ============================================================================
-- Test 7: PriceHistory - Default Username (NULL -> [Unbekannt])
-- ============================================================================
PRINT '--- Test 7: PriceHistory - Default Username (NULL -> [Unbekannt]) ---';

DECLARE @t7a_passed INT = 0, @t7a_total INT = 1;

BEGIN TRANSACTION;
BEGIN TRY
    EXEC CustomWorkflows.spArticleAppendPriceHistory @kArtikel = 19807, @userName = NULL;

    DECLARE @t7a_lines INT, @t7a_last NVARCHAR(MAX);
    EXEC #GetHistoryInfo 19807, 'Vergangene Preise', @t7a_lines OUTPUT, @t7a_last OUTPUT;

    DECLARE @t7a_user NVARCHAR(MAX) = Robotico.fnEscapedCSVGetField(@t7a_last, 5, ';');
    IF @t7a_user = '[Unbekannt]'
    BEGIN PRINT '  + Default Username korrekt: [Unbekannt]'; SET @t7a_passed += 1; END
    ELSE PRINT '  x Username: [' + ISNULL(@t7a_user, 'NULL') + '] (erwartet: [Unbekannt])';

    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT '  x ERROR: ' + ERROR_MESSAGE();
END CATCH

PRINT '  Result: ' + CAST(@t7a_passed AS NVARCHAR(5)) + '/' + CAST(@t7a_total AS NVARCHAR(5)) + ' passed';
INSERT INTO #TestResults VALUES ('PriceHistory: Default Username', @t7a_passed, @t7a_total);
PRINT '';
GO

-- ============================================================================
-- Test 8: LabelHistory - Erstanlage + Format
-- ============================================================================
PRINT '--- Test 8: LabelHistory - Erstanlage (kArtikel=19807, keine History) ---';


DECLARE @t6_passed INT = 0, @t6_total INT = 3;

BEGIN TRANSACTION;
BEGIN TRY
    EXEC CustomWorkflows.spArticleAppendLabelHistory @kArtikel = 19807, @userName = 'LabelTest';

    DECLARE @t6_lines INT, @t6_last NVARCHAR(MAX);
    EXEC #GetHistoryInfo 19807, 'Vergangene Label', @t6_lines OUTPUT, @t6_last OUTPUT;

    -- Check 1: Genau 1 Zeile
    IF @t6_lines = 1
    BEGIN PRINT '  + Line count = 1 (Binding auto-created)'; SET @t6_passed += 1; END
    ELSE PRINT '  x Line count = ' + CAST(@t6_lines AS NVARCHAR(10));

    -- Check 2: Label-Name im Eintrag
    IF @t6_last LIKE '%Sanda: ersetzt neu%'
    BEGIN PRINT '  + Label gefunden'; SET @t6_passed += 1; END
    ELSE PRINT '  x Label nicht gefunden: ' + ISNULL(LEFT(@t6_last, 80), 'NULL');

    -- Check 3: Username im Eintrag
    IF @t6_last LIKE '%LabelTest'
    BEGIN PRINT '  + Username gefunden'; SET @t6_passed += 1; END
    ELSE PRINT '  x Username nicht gefunden';

    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT '  x ERROR: ' + ERROR_MESSAGE();
END CATCH

PRINT '  Result: ' + CAST(@t6_passed AS NVARCHAR(5)) + '/' + CAST(@t6_total AS NVARCHAR(5)) + ' passed';
INSERT INTO #TestResults VALUES ('LabelHistory: Erstanlage + Format', @t6_passed, @t6_total);
PRINT '';
GO

-- ============================================================================
-- Test 9: LabelHistory - Keine Aenderung bei gleichen Labels
-- ============================================================================
PRINT '--- Test 9: LabelHistory - Keine Aenderung (kArtikel=73, Labels gleich) ---';

DECLARE @t7_passed INT = 0, @t7_total INT = 1;

BEGIN TRANSACTION;
BEGIN TRY
    -- Erst Baseline setzen: SP aufrufen damit aktuelle Labels als Eintrag existieren
    EXEC CustomWorkflows.spArticleAppendLabelHistory @kArtikel = 73, @userName = 'BaselineCall';

    DECLARE @t7_before INT, @t7_after INT, @t7_dummy NVARCHAR(MAX);
    EXEC #GetHistoryInfo 73, 'Vergangene Label', @t7_before OUTPUT, @t7_dummy OUTPUT;

    -- Zweiter Aufruf: gleiche Labels -> darf KEINEN neuen Eintrag erzeugen
    EXEC CustomWorkflows.spArticleAppendLabelHistory @kArtikel = 73, @userName = 'NoLabelChange';

    EXEC #GetHistoryInfo 73, 'Vergangene Label', @t7_after OUTPUT, @t7_dummy OUTPUT;

    IF @t7_before = @t7_after
    BEGIN PRINT '  + Kein Eintrag (Labels unveraendert, ' + CAST(@t7_before AS NVARCHAR(10)) + ' Zeilen)'; SET @t7_passed += 1; END
    ELSE PRINT '  x Eintrag trotz gleichen Labels (vorher: ' + CAST(@t7_before AS NVARCHAR(10)) + ', nachher: ' + CAST(@t7_after AS NVARCHAR(10)) + ')';

    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT '  x ERROR: ' + ERROR_MESSAGE();
END CATCH

PRINT '  Result: ' + CAST(@t7_passed AS NVARCHAR(5)) + '/' + CAST(@t7_total AS NVARCHAR(5)) + ' passed';
INSERT INTO #TestResults VALUES ('LabelHistory: Keine Aenderung', @t7_passed, @t7_total);
PRINT '';
GO

-- ============================================================================
-- Test 10: LabelHistory - Doppelaufruf (eigenes Format korrekt zurueckgeparst)
-- ============================================================================
PRINT '--- Test 10: LabelHistory - Doppelaufruf (kArtikel=19807, 2x aufrufen) ---';

DECLARE @t10a_passed INT = 0, @t10a_total INT = 1;

BEGIN TRANSACTION;
BEGIN TRY
    -- Erster Aufruf: erstellt Eintrag
    EXEC CustomWorkflows.spArticleAppendLabelHistory @kArtikel = 19807, @userName = 'DoppelLabel1';

    DECLARE @t10a_after1 INT, @t10a_dummy NVARCHAR(MAX);
    EXEC #GetHistoryInfo 19807, 'Vergangene Label', @t10a_after1 OUTPUT, @t10a_dummy OUTPUT;

    -- Zweiter Aufruf: gleiche Labels -> darf KEINEN neuen Eintrag erzeugen
    EXEC CustomWorkflows.spArticleAppendLabelHistory @kArtikel = 19807, @userName = 'DoppelLabel2';

    DECLARE @t10a_after2 INT;
    EXEC #GetHistoryInfo 19807, 'Vergangene Label', @t10a_after2 OUTPUT, @t10a_dummy OUTPUT;

    IF @t10a_after1 = 1 AND @t10a_after2 = 1
    BEGIN PRINT '  + Zweiter Aufruf hat keinen Eintrag hinzugefuegt (1 Zeile)'; SET @t10a_passed += 1; END
    ELSE PRINT '  x Nach 1. Aufruf: ' + CAST(@t10a_after1 AS NVARCHAR(10)) + ', nach 2. Aufruf: ' + CAST(@t10a_after2 AS NVARCHAR(10)) + ' (erwartet: 1, 1)';

    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT '  x ERROR: ' + ERROR_MESSAGE();
END CATCH

PRINT '  Result: ' + CAST(@t10a_passed AS NVARCHAR(5)) + '/' + CAST(@t10a_total AS NVARCHAR(5)) + ' passed';
INSERT INTO #TestResults VALUES ('LabelHistory: Doppelaufruf', @t10a_passed, @t10a_total);
PRINT '';
GO

-- ============================================================================
-- Test 11: LabelHistory - Kommas in Label-Namen werden entfernt
-- ============================================================================
PRINT '--- Test 11: LabelHistory - Komma-Sanitization (Label mit Komma im Namen) ---';

DECLARE @t11k_passed INT = 0, @t11k_total INT = 2;

BEGIN TRANSACTION;
BEGIN TRY
    -- Label mit Komma im Namen simulieren
    DECLARE @t11k_labelId INT;
    SELECT TOP 1 @t11k_labelId = al.kLabel FROM dbo.tArtikelLabel al WHERE al.kArtikel = 19807;

    UPDATE dbo.tLabel SET cName = 'Test, Label' WHERE kLabel = @t11k_labelId;

    EXEC CustomWorkflows.spArticleAppendLabelHistory @kArtikel = 19807, @userName = 'CommaTest';

    DECLARE @t11k_lines INT, @t11k_last NVARCHAR(MAX);
    EXEC #GetHistoryInfo 19807, 'Vergangene Label', @t11k_lines OUTPUT, @t11k_last OUTPUT;

    -- Check 1: Komma wurde entfernt
    DECLARE @t11k_labels NVARCHAR(MAX) = Robotico.fnEscapedCSVGetField(@t11k_last, 2, ';');
    IF @t11k_labels NOT LIKE '%,%'
    BEGIN PRINT '  + Komma entfernt: [' + @t11k_labels + ']'; SET @t11k_passed += 1; END
    ELSE PRINT '  x Komma noch vorhanden: [' + ISNULL(@t11k_labels, 'NULL') + ']';

    -- Check 2: Doppelaufruf stabil (Change Detection funktioniert trotz Komma-Label)
    EXEC CustomWorkflows.spArticleAppendLabelHistory @kArtikel = 19807, @userName = 'CommaTest2';

    DECLARE @t11k_after INT;
    EXEC #GetHistoryInfo 19807, 'Vergangene Label', @t11k_after OUTPUT, @t11k_last OUTPUT;

    IF @t11k_after = @t11k_lines
    BEGIN PRINT '  + Doppelaufruf stabil (kein neuer Eintrag)'; SET @t11k_passed += 1; END
    ELSE PRINT '  x Doppelaufruf instabil (' + CAST(@t11k_lines AS NVARCHAR(10)) + ' -> ' + CAST(@t11k_after AS NVARCHAR(10)) + ')';

    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT '  x ERROR: ' + ERROR_MESSAGE();
END CATCH

PRINT '  Result: ' + CAST(@t11k_passed AS NVARCHAR(5)) + '/' + CAST(@t11k_total AS NVARCHAR(5)) + ' passed';
INSERT INTO #TestResults VALUES ('LabelHistory: Komma-Sanitization', @t11k_passed, @t11k_total);
PRINT '';
GO

-- ============================================================================
-- Test 12: LabelHistory - Label-Aenderung erkennen
-- ============================================================================
PRINT '--- Test 12: LabelHistory - Label-Aenderung (kArtikel=73, Label entfernen) ---';

DECLARE @t8_passed INT = 0, @t8_total INT = 2;

BEGIN TRANSACTION;
BEGIN TRY
    DECLARE @t8_before INT, @t8_dummy NVARCHAR(MAX);
    EXEC #GetHistoryInfo 73, 'Vergangene Label', @t8_before OUTPUT, @t8_dummy OUTPUT;

    -- Ein Label entfernen um Change auszuloesen
    DELETE TOP(1) FROM dbo.tArtikelLabel WHERE kArtikel = 73;

    EXEC CustomWorkflows.spArticleAppendLabelHistory @kArtikel = 73, @userName = 'LabelChangeTest';

    DECLARE @t8_after INT, @t8_last NVARCHAR(MAX);
    EXEC #GetHistoryInfo 73, 'Vergangene Label', @t8_after OUTPUT, @t8_last OUTPUT;

    -- Check 1: Zeile hinzugefuegt
    IF @t8_after = @t8_before + 1
    BEGIN PRINT '  + Zeile hinzugefuegt (' + CAST(@t8_before AS NVARCHAR(10)) + ' -> ' + CAST(@t8_after AS NVARCHAR(10)) + ')'; SET @t8_passed += 1; END
    ELSE PRINT '  x Zeilenanzahl: vorher=' + CAST(@t8_before AS NVARCHAR(10)) + ', nachher=' + CAST(@t8_after AS NVARCHAR(10));

    -- Check 2: Neuer Eintrag hat Label-Inhalt
    DECLARE @t8_labels NVARCHAR(MAX) = Robotico.fnEscapedCSVGetField(@t8_last, 2, ';');
    IF @t8_labels IS NOT NULL AND LEN(@t8_labels) > 0
    BEGIN PRINT '  + Labels im Eintrag: ' + LEFT(@t8_labels, 60); SET @t8_passed += 1; END
    ELSE PRINT '  x Keine Labels im Eintrag';

    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT '  x ERROR: ' + ERROR_MESSAGE();
END CATCH

PRINT '  Result: ' + CAST(@t8_passed AS NVARCHAR(5)) + '/' + CAST(@t8_total AS NVARCHAR(5)) + ' passed';
INSERT INTO #TestResults VALUES ('LabelHistory: Label-Aenderung', @t8_passed, @t8_total);
PRINT '';
GO

-- ============================================================================
-- Test 13: UpdateAllHistory - Ruft beide SPs auf
-- ============================================================================
PRINT '--- Test 13: UpdateAllHistory (kArtikel=19807, ruft beide SPs auf) ---';

DECLARE @t9_passed INT = 0, @t9_total INT = 2;

BEGIN TRANSACTION;
BEGIN TRY
    EXEC CustomWorkflows.spArticleUpdateAllHistory @kArtikel = 19807, @userName = 'UpdateAllTest';

    DECLARE @t9_priceLines INT, @t9_labelLines INT, @t9_dummy NVARCHAR(MAX);
    EXEC #GetHistoryInfo 19807, 'Vergangene Preise', @t9_priceLines OUTPUT, @t9_dummy OUTPUT;
    EXEC #GetHistoryInfo 19807, 'Vergangene Label', @t9_labelLines OUTPUT, @t9_dummy OUTPUT;

    -- Check 1: Price History erstellt
    IF @t9_priceLines = 1
    BEGIN PRINT '  + PriceHistory-Eintrag erstellt'; SET @t9_passed += 1; END
    ELSE PRINT '  x PriceHistory Zeilen: ' + CAST(@t9_priceLines AS NVARCHAR(10));

    -- Check 2: Label History erstellt
    IF @t9_labelLines = 1
    BEGIN PRINT '  + LabelHistory-Eintrag erstellt'; SET @t9_passed += 1; END
    ELSE PRINT '  x LabelHistory Zeilen: ' + CAST(@t9_labelLines AS NVARCHAR(10));

    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT '  x ERROR: ' + ERROR_MESSAGE();
END CATCH

PRINT '  Result: ' + CAST(@t9_passed AS NVARCHAR(5)) + '/' + CAST(@t9_total AS NVARCHAR(5)) + ' passed';
INSERT INTO #TestResults VALUES ('UpdateAllHistory: beide SPs', @t9_passed, @t9_total);
PRINT '';
GO

-- ============================================================================
-- Test 14: Clean State - Alle Rollbacks verifizieren
-- ============================================================================
PRINT '--- Test 14: Clean State (19807 darf keine History haben) ---';

DECLARE @t10_passed INT = 0, @t10_total INT = 2;

DECLARE @t10_price NVARCHAR(MAX) = Robotico.fnGetArticleCustomFieldValue(19807, 'Vergangene Preise', 0);
DECLARE @t10_label NVARCHAR(MAX) = Robotico.fnGetArticleCustomFieldValue(19807, 'Vergangene Label', 0);

IF @t10_price IS NULL
BEGIN PRINT '  + PriceHistory clean (NULL)'; SET @t10_passed += 1; END
ELSE PRINT '  x PriceHistory-Daten verblieben: ' + LEFT(@t10_price, 60);

IF @t10_label IS NULL
BEGIN PRINT '  + LabelHistory clean (NULL)'; SET @t10_passed += 1; END
ELSE PRINT '  x LabelHistory-Daten verblieben: ' + LEFT(@t10_label, 60);

PRINT '  Result: ' + CAST(@t10_passed AS NVARCHAR(5)) + '/' + CAST(@t10_total AS NVARCHAR(5)) + ' passed';
INSERT INTO #TestResults VALUES ('Clean State: Rollback-Verifikation', @t10_passed, @t10_total);
PRINT '';
GO

-- ============================================================================
-- Test Summary
-- ============================================================================
DECLARE @totalPassed INT, @totalTests INT, @failedSections INT, @sectionCount INT;
SELECT @totalPassed = SUM(passed),
       @totalTests = SUM(total),
       @failedSections = SUM(CASE WHEN passed < total THEN 1 ELSE 0 END),
       @sectionCount = COUNT(*)
FROM #TestResults;

PRINT '============================================================================';
IF @failedSections = 0
BEGIN
    PRINT 'ALL TESTS PASSED: '
        + CAST(@totalPassed AS NVARCHAR(5)) + '/'
        + CAST(@totalTests AS NVARCHAR(5)) + ' checks in '
        + CAST(@sectionCount AS NVARCHAR(5)) + ' test sections';
    PRINT '';
    PRINT 'Database State: CLEAN (all transactions rolled back)';
END
ELSE
BEGIN
    PRINT 'TESTS FAILED: '
        + CAST(@totalPassed AS NVARCHAR(5)) + '/'
        + CAST(@totalTests AS NVARCHAR(5)) + ' checks passed, '
        + CAST(@failedSections AS NVARCHAR(5)) + ' section(s) with failures:';
    PRINT '';

    DECLARE @failName NVARCHAR(200), @failPassed INT, @failTotal INT;
    DECLARE failCursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT testName, passed, total FROM #TestResults WHERE passed < total;
    OPEN failCursor;
    FETCH NEXT FROM failCursor INTO @failName, @failPassed, @failTotal;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        PRINT '  x ' + @failName + ': ' + CAST(@failPassed AS NVARCHAR(5)) + '/' + CAST(@failTotal AS NVARCHAR(5));
        FETCH NEXT FROM failCursor INTO @failName, @failPassed, @failTotal;
    END
    CLOSE failCursor;
    DEALLOCATE failCursor;
END
PRINT '============================================================================';
PRINT '';

DROP TABLE #TestResults;
IF OBJECT_ID('tempdb..#GetHistoryInfo') IS NOT NULL
    EXEC('DROP PROCEDURE #GetHistoryInfo');
GO
