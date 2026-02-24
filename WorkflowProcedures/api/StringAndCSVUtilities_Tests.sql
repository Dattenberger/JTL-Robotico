-- ============================================================================
-- Test Suite fuer String & EscapedCSV Utility Functions
-- ============================================================================
-- Description:
--   Test-Queries zum Validieren der String & EscapedCSV Utility Functions
--   nach Deployment. Alle Tests sind rein funktional (keine DB-Aenderungen),
--   da nur Scalar Functions und eine iTVF getestet werden.
--
-- Components tested:
--   String Functions:
--     1. Robotico.fnStringStripWhitespace
--     2. Robotico.fnStringIsEffectivelyEmpty
--     3. Robotico.fnStringCountLines
--     4. Robotico.fnStringTrimToMaxLines
--     5. Robotico.fnStringParseGermanDecimal
--   EscapedCSV API:
--     6. Robotico.fnEscapedCSVSanitize
--     7. Robotico.fnEscapedCSVParseLine
--     8. Robotico.fnEscapedCSVGetField
--     9. Robotico.fnEscapedCSVGetLastLine
--
-- Author: Lukas Dattenberger
-- Date: 2026-02-24
-- ============================================================================

IF OBJECT_ID('tempdb..#TestResults') IS NOT NULL DROP TABLE #TestResults;
CREATE TABLE #TestResults (testName NVARCHAR(100), passed INT, total INT);
GO

PRINT '============================================================================';
PRINT 'String & EscapedCSV Utility Functions - Test Suite';
PRINT '============================================================================';
PRINT '';
PRINT 'All tests are read-only (function calls only, no DB changes).';
PRINT '';

-- ============================================================================
-- Test 1: fnStringStripWhitespace
-- ============================================================================
PRINT '--- Test 1: fnStringStripWhitespace ---';

DECLARE @t1_passed INT = 0;
DECLARE @t1_total INT = 4;

-- 1a: NULL -> NULL
IF Robotico.fnStringStripWhitespace(NULL) IS NULL
BEGIN PRINT '  + NULL -> NULL'; SET @t1_passed += 1; END
ELSE PRINT '  x NULL: FAILED (expected NULL)';

-- 1b: Tabs entfernen
IF Robotico.fnStringStripWhitespace('Hello' + CHAR(9) + 'World') = 'HelloWorld'
BEGIN PRINT '  + Tab removed'; SET @t1_passed += 1; END
ELSE PRINT '  x Tab removal: FAILED';

-- 1c: CR+LF entfernen
IF Robotico.fnStringStripWhitespace('Line1' + CHAR(13) + CHAR(10) + 'Line2') = 'Line1Line2'
BEGIN PRINT '  + CR+LF removed'; SET @t1_passed += 1; END
ELSE PRINT '  x CR+LF removal: FAILED';

-- 1d: Spaces bleiben erhalten
IF Robotico.fnStringStripWhitespace('Hello World') = 'Hello World'
BEGIN PRINT '  + Spaces preserved'; SET @t1_passed += 1; END
ELSE PRINT '  x Space preservation: FAILED';

PRINT '  Result: ' + CAST(@t1_passed AS NVARCHAR(5)) + '/' + CAST(@t1_total AS NVARCHAR(5)) + ' passed';
INSERT INTO #TestResults VALUES ('fnStringStripWhitespace', @t1_passed, @t1_total);
PRINT '';
GO

-- ============================================================================
-- Test 2: fnStringIsEffectivelyEmpty
-- ============================================================================
PRINT '--- Test 2: fnStringIsEffectivelyEmpty ---';

DECLARE @t2_passed INT = 0;
DECLARE @t2_total INT = 6;

-- 2a: NULL -> 1
IF Robotico.fnStringIsEffectivelyEmpty(NULL) = 1
BEGIN PRINT '  + NULL -> 1 (empty)'; SET @t2_passed += 1; END
ELSE PRINT '  x NULL: FAILED (expected 1)';

-- 2b: Leerer String -> 1
IF Robotico.fnStringIsEffectivelyEmpty('') = 1
BEGIN PRINT '  + Empty string -> 1 (empty)'; SET @t2_passed += 1; END
ELSE PRINT '  x Empty string: FAILED (expected 1)';

-- 2c: Nur Leerzeichen -> 1
IF Robotico.fnStringIsEffectivelyEmpty('     ') = 1
BEGIN PRINT '  + Spaces only -> 1 (empty)'; SET @t2_passed += 1; END
ELSE PRINT '  x Spaces only: FAILED (expected 1)';

-- 2d: Tabs und Newlines -> 1
IF Robotico.fnStringIsEffectivelyEmpty(CHAR(9) + CHAR(13) + CHAR(10) + '  ') = 1
BEGIN PRINT '  + Tab+CR+LF+Spaces -> 1 (empty)'; SET @t2_passed += 1; END
ELSE PRINT '  x Tab+CR+LF+Spaces: FAILED (expected 1)';

-- 2e: Inhalt vorhanden -> 0
IF Robotico.fnStringIsEffectivelyEmpty('Hello') = 0
BEGIN PRINT '  + "Hello" -> 0 (not empty)'; SET @t2_passed += 1; END
ELSE PRINT '  x "Hello": FAILED (expected 0)';

-- 2f: Inhalt mit Whitespace drumherum -> 0
IF Robotico.fnStringIsEffectivelyEmpty('  ' + CHAR(10) + 'Data' + CHAR(13) + '  ') = 0
BEGIN PRINT '  + Whitespace+Data+Whitespace -> 0 (not empty)'; SET @t2_passed += 1; END
ELSE PRINT '  x Whitespace+Data+Whitespace: FAILED (expected 0)';

PRINT '  Result: ' + CAST(@t2_passed AS NVARCHAR(5)) + '/' + CAST(@t2_total AS NVARCHAR(5)) + ' passed';
INSERT INTO #TestResults VALUES ('fnStringIsEffectivelyEmpty', @t2_passed, @t2_total);
PRINT '';
GO

-- ============================================================================
-- Test 3: fnStringCountLines
-- ============================================================================
PRINT '--- Test 3: fnStringCountLines ---';

DECLARE @t3_passed INT = 0;
DECLARE @t3_total INT = 6;

-- 3a: NULL -> 0
IF Robotico.fnStringCountLines(NULL) = 0
BEGIN PRINT '  + NULL -> 0'; SET @t3_passed += 1; END
ELSE PRINT '  x NULL: FAILED (expected 0)';

-- 3b: Leerer String -> 0
IF Robotico.fnStringCountLines('') = 0
BEGIN PRINT '  + Empty -> 0'; SET @t3_passed += 1; END
ELSE PRINT '  x Empty: FAILED (expected 0)';

-- 3c: Einzelne Zeile -> 1
IF Robotico.fnStringCountLines('Hello World') = 1
BEGIN PRINT '  + Single line -> 1'; SET @t3_passed += 1; END
ELSE PRINT '  x Single line: FAILED (got: ' + CAST(Robotico.fnStringCountLines('Hello World') AS NVARCHAR(10)) + ')';

-- 3d: Zwei Zeilen (LF) -> 2
IF Robotico.fnStringCountLines('Line1' + CHAR(10) + 'Line2') = 2
BEGIN PRINT '  + Two lines (LF) -> 2'; SET @t3_passed += 1; END
ELSE PRINT '  x Two lines: FAILED (got: ' + CAST(Robotico.fnStringCountLines('Line1' + CHAR(10) + 'Line2') AS NVARCHAR(10)) + ')';

-- 3e: Drei Zeilen (CR+LF) -> 3
IF Robotico.fnStringCountLines('A' + CHAR(13)+CHAR(10) + 'B' + CHAR(13)+CHAR(10) + 'C') = 3
BEGIN PRINT '  + Three lines (CRLF) -> 3'; SET @t3_passed += 1; END
ELSE PRINT '  x Three lines: FAILED (got: ' + CAST(Robotico.fnStringCountLines('A' + CHAR(13)+CHAR(10) + 'B' + CHAR(13)+CHAR(10) + 'C') AS NVARCHAR(10)) + ')';

-- 3f: Trailing LF -> zaehlt als 2 Zeilen (leere Trailing-Zeile wird mitgezaehlt)
IF Robotico.fnStringCountLines('A' + CHAR(10)) = 2
BEGIN PRINT '  + Trailing LF -> 2 (empty trailing line counted)'; SET @t3_passed += 1; END
ELSE PRINT '  x Trailing LF: FAILED (got: ' + CAST(Robotico.fnStringCountLines('A' + CHAR(10)) AS NVARCHAR(10)) + ')';

PRINT '  Result: ' + CAST(@t3_passed AS NVARCHAR(5)) + '/' + CAST(@t3_total AS NVARCHAR(5)) + ' passed';
INSERT INTO #TestResults VALUES ('fnStringCountLines', @t3_passed, @t3_total);
PRINT '';
GO

-- ============================================================================
-- Test 4: fnStringTrimToMaxLines
-- ============================================================================
PRINT '--- Test 4: fnStringTrimToMaxLines ---';

DECLARE @t4_passed INT = 0;
DECLARE @t4_total INT = 5;

-- 4a: NULL -> NULL
IF Robotico.fnStringTrimToMaxLines(NULL, 5) IS NULL
BEGIN PRINT '  + NULL -> NULL'; SET @t4_passed += 1; END
ELSE PRINT '  x NULL: FAILED';

-- 4b: Weniger Zeilen als Max -> unveraendert
DECLARE @t4_input2 NVARCHAR(MAX) = 'A' + CHAR(13)+CHAR(10) + 'B' + CHAR(13)+CHAR(10) + 'C';
DECLARE @t4_result2 NVARCHAR(MAX) = Robotico.fnStringTrimToMaxLines(@t4_input2, 5);
IF @t4_result2 = @t4_input2
BEGIN PRINT '  + 3 lines, max 5 -> unchanged (identical)'; SET @t4_passed += 1; END
ELSE PRINT '  x Under max: FAILED';

-- 4c: Mehr Zeilen als Max -> getrimmt
DECLARE @t4_input3 NVARCHAR(MAX) = 'A' + CHAR(10) + 'B' + CHAR(10) + 'C' + CHAR(10) + 'D' + CHAR(10) + 'E';
DECLARE @t4_result3 NVARCHAR(MAX) = Robotico.fnStringTrimToMaxLines(@t4_input3, 3);
DECLARE @t4_count3 INT = Robotico.fnStringCountLines(@t4_result3);
IF @t4_count3 = 3
BEGIN PRINT '  + 5 lines, max 3 -> 3 lines (trimmed)'; SET @t4_passed += 1; END
ELSE PRINT '  x Over max: FAILED (got: ' + CAST(@t4_count3 AS NVARCHAR(10)) + ' lines)';

-- 4d: Letzte Zeilen behalten (nicht erste)
DECLARE @t4_input4 NVARCHAR(MAX) = 'A' + CHAR(10) + 'B' + CHAR(10) + 'C' + CHAR(10) + 'D' + CHAR(10) + 'E';
DECLARE @t4_result4 NVARCHAR(MAX) = Robotico.fnStringTrimToMaxLines(@t4_input4, 2);
IF @t4_result4 LIKE '%D%' AND @t4_result4 LIKE '%E%' AND @t4_result4 NOT LIKE '%A%'
BEGIN PRINT '  + Keeps last lines (D, E), removes first (A)'; SET @t4_passed += 1; END
ELSE PRINT '  x Last lines: FAILED (got: "' + ISNULL(@t4_result4, 'NULL') + '")';

-- 4e: maxLines = 0 -> NULL (Guard)
IF Robotico.fnStringTrimToMaxLines('A' + CHAR(10) + 'B', 0) IS NULL
BEGIN PRINT '  + maxLines=0 -> NULL (guarded)'; SET @t4_passed += 1; END
ELSE PRINT '  x maxLines=0: FAILED (expected NULL)';

PRINT '  Result: ' + CAST(@t4_passed AS NVARCHAR(5)) + '/' + CAST(@t4_total AS NVARCHAR(5)) + ' passed';
INSERT INTO #TestResults VALUES ('fnStringTrimToMaxLines', @t4_passed, @t4_total);
PRINT '';
GO

-- ============================================================================
-- Test 5: fnStringParseGermanDecimal
-- ============================================================================
PRINT '--- Test 5: fnStringParseGermanDecimal ---';

DECLARE @t5_passed INT = 0;
DECLARE @t5_total INT = 6;

-- 5a: Einfache Dezimalzahl
DECLARE @t5a DECIMAL(25,13) = Robotico.fnStringParseGermanDecimal('99,99');
IF @t5a BETWEEN 99.989 AND 99.991
BEGIN PRINT '  + "99,99" -> ' + CAST(@t5a AS NVARCHAR(30)); SET @t5_passed += 1; END
ELSE PRINT '  x "99,99": FAILED (got: ' + ISNULL(CAST(@t5a AS NVARCHAR(30)), 'NULL') + ')';

-- 5b: Mit Tausender-Trennzeichen
DECLARE @t5b DECIMAL(25,13) = Robotico.fnStringParseGermanDecimal('1.234,56');
IF @t5b BETWEEN 1234.559 AND 1234.561
BEGIN PRINT '  + "1.234,56" -> ' + CAST(@t5b AS NVARCHAR(30)); SET @t5_passed += 1; END
ELSE PRINT '  x "1.234,56": FAILED (got: ' + ISNULL(CAST(@t5b AS NVARCHAR(30)), 'NULL') + ')';

-- 5c: Ganzzahl ohne Dezimal
DECLARE @t5c DECIMAL(25,13) = Robotico.fnStringParseGermanDecimal('100');
IF @t5c BETWEEN 99.999 AND 100.001
BEGIN PRINT '  + "100" -> ' + CAST(@t5c AS NVARCHAR(30)); SET @t5_passed += 1; END
ELSE PRINT '  x "100": FAILED (got: ' + ISNULL(CAST(@t5c AS NVARCHAR(30)), 'NULL') + ')';

-- 5d: NULL -> NULL
IF Robotico.fnStringParseGermanDecimal(NULL) IS NULL
BEGIN PRINT '  + NULL -> NULL'; SET @t5_passed += 1; END
ELSE PRINT '  x NULL: FAILED';

-- 5e: Leerer String -> NULL
IF Robotico.fnStringParseGermanDecimal('') IS NULL
BEGIN PRINT '  + Empty -> NULL'; SET @t5_passed += 1; END
ELSE PRINT '  x Empty: FAILED';

-- 5f: Ungueltiger String -> NULL
IF Robotico.fnStringParseGermanDecimal('abc') IS NULL
BEGIN PRINT '  + "abc" -> NULL (invalid)'; SET @t5_passed += 1; END
ELSE PRINT '  x "abc": FAILED (expected NULL)';

PRINT '  Result: ' + CAST(@t5_passed AS NVARCHAR(5)) + '/' + CAST(@t5_total AS NVARCHAR(5)) + ' passed';
INSERT INTO #TestResults VALUES ('fnStringParseGermanDecimal', @t5_passed, @t5_total);
PRINT '';
GO

-- ============================================================================
-- ============================================================================
--                    ESCAPED CSV API TESTS
-- ============================================================================
-- ============================================================================

-- ============================================================================
-- Test 6: fnEscapedCSVSanitize
-- ============================================================================
PRINT '--- Test 6: fnEscapedCSVSanitize ---';

DECLARE @t6_passed INT = 0;
DECLARE @t6_total INT = 8;

-- 6a: NULL mit Default -> Default
IF Robotico.fnEscapedCSVSanitize(NULL, '[Unbekannt]') = '[Unbekannt]'
BEGIN PRINT '  + NULL with default -> "[Unbekannt]"'; SET @t6_passed += 1; END
ELSE PRINT '  x NULL with default: FAILED';

-- 6b: Leerer String mit Default -> Default
IF Robotico.fnEscapedCSVSanitize('', '[Unbekannt]') = '[Unbekannt]'
BEGIN PRINT '  + Empty with default -> "[Unbekannt]"'; SET @t6_passed += 1; END
ELSE PRINT '  x Empty with default: FAILED';

-- 6c: Semikolons entfernen
IF Robotico.fnEscapedCSVSanitize('John; Doe', NULL) = 'John Doe'
BEGIN PRINT '  + Semicolons removed: "John; Doe" -> "John Doe"'; SET @t6_passed += 1; END
ELSE PRINT '  x Semicolon removal: FAILED (got: "' + ISNULL(Robotico.fnEscapedCSVSanitize('John; Doe', NULL), 'NULL') + '")';

-- 6d: Anfuehrungszeichen entfernen
IF Robotico.fnEscapedCSVSanitize('Test"Wert''s', NULL) = 'TestWerts'
BEGIN PRINT '  + Quotes removed'; SET @t6_passed += 1; END
ELSE PRINT '  x Quote removal: FAILED (got: "' + ISNULL(Robotico.fnEscapedCSVSanitize('Test"Wert''s', NULL), 'NULL') + '")';

-- 6e: Newlines entfernen
IF Robotico.fnEscapedCSVSanitize('Line1' + CHAR(13) + CHAR(10) + 'Line2', NULL) = 'Line1Line2'
BEGIN PRINT '  + Newlines removed'; SET @t6_passed += 1; END
ELSE PRINT '  x Newline removal: FAILED';

-- 6f: Sauberer Input -> getrimmt
IF Robotico.fnEscapedCSVSanitize('  Lukas Dattenberger  ', NULL) = 'Lukas Dattenberger'
BEGIN PRINT '  + Clean input trimmed: "Lukas Dattenberger"'; SET @t6_passed += 1; END
ELSE PRINT '  x Clean input: FAILED (got: "' + ISNULL(Robotico.fnEscapedCSVSanitize('  Lukas Dattenberger  ', NULL), 'NULL') + '")';

-- 6g: NULL ohne Default -> NULL (nicht leerer String!)
IF Robotico.fnEscapedCSVSanitize(NULL, NULL) IS NULL
BEGIN PRINT '  + NULL without default -> NULL'; SET @t6_passed += 1; END
ELSE PRINT '  x NULL without default: FAILED (expected NULL)';

-- 6h: Leerer String ohne Default -> NULL
IF Robotico.fnEscapedCSVSanitize('', NULL) IS NULL
BEGIN PRINT '  + Empty without default -> NULL'; SET @t6_passed += 1; END
ELSE PRINT '  x Empty without default: FAILED (expected NULL)';

PRINT '  Result: ' + CAST(@t6_passed AS NVARCHAR(5)) + '/' + CAST(@t6_total AS NVARCHAR(5)) + ' passed';
INSERT INTO #TestResults VALUES ('fnEscapedCSVSanitize', @t6_passed, @t6_total);
PRINT '';
GO

-- ============================================================================
-- Test 7: fnEscapedCSVParseLine (iTVF)
-- ============================================================================
PRINT '--- Test 7: fnEscapedCSVParseLine ---';

DECLARE @t7_passed INT = 0;
DECLARE @t7_total INT = 4;

DECLARE @t7_csv NVARCHAR(200) = '24.02.2026 10:45:00; 99,99; 118,99; Puffer 3; Lukas';

-- 7a: Korrekte Anzahl Felder
DECLARE @t7_fieldCount INT;
SELECT @t7_fieldCount = COUNT(*) FROM Robotico.fnEscapedCSVParseLine(@t7_csv, ';');
IF @t7_fieldCount = 5
BEGIN PRINT '  + 5 fields parsed'; SET @t7_passed += 1; END
ELSE PRINT '  x Field count: FAILED (got: ' + CAST(@t7_fieldCount AS NVARCHAR(10)) + ')';

-- 7b: Multi-Feld-Lesen in einem Durchgang (Kernfeature)
DECLARE @t7_datum NVARCHAR(50), @t7_preis NVARCHAR(50), @t7_puffer NVARCHAR(50), @t7_user NVARCHAR(50);
SELECT @t7_datum  = MAX(CASE WHEN ordinal = 1 THEN value END),
       @t7_preis  = MAX(CASE WHEN ordinal = 2 THEN value END),
       @t7_puffer = MAX(CASE WHEN ordinal = 4 THEN value END),
       @t7_user   = MAX(CASE WHEN ordinal = 5 THEN value END)
FROM Robotico.fnEscapedCSVParseLine(@t7_csv, ';');

IF @t7_datum = '24.02.2026 10:45:00'
BEGIN PRINT '  + Field 1 (Datum): "' + @t7_datum + '"'; SET @t7_passed += 1; END
ELSE PRINT '  x Field 1: FAILED (got: "' + ISNULL(@t7_datum, 'NULL') + '")';

IF @t7_preis = '99,99' AND @t7_puffer = 'Puffer 3' AND @t7_user = 'Lukas'
BEGIN PRINT '  + Fields 2,4,5 correct (multi-read)'; SET @t7_passed += 1; END
ELSE PRINT '  x Multi-read: FAILED';

-- 7c: Werte sind automatisch getrimmt
DECLARE @t7_trimCheck NVARCHAR(50);
SELECT @t7_trimCheck = value FROM Robotico.fnEscapedCSVParseLine('  A  ;  B  ', ';') WHERE ordinal = 1;
IF @t7_trimCheck = 'A'
BEGIN PRINT '  + Values auto-trimmed: "  A  " -> "A"'; SET @t7_passed += 1; END
ELSE PRINT '  x Auto-trim: FAILED (got: "' + ISNULL(@t7_trimCheck, 'NULL') + '")';

PRINT '  Result: ' + CAST(@t7_passed AS NVARCHAR(5)) + '/' + CAST(@t7_total AS NVARCHAR(5)) + ' passed';
INSERT INTO #TestResults VALUES ('fnEscapedCSVParseLine', @t7_passed, @t7_total);
PRINT '';
GO

-- ============================================================================
-- Test 8: fnEscapedCSVGetField
-- ============================================================================
PRINT '--- Test 8: fnEscapedCSVGetField ---';

DECLARE @t8_passed INT = 0;
DECLARE @t8_total INT = 6;

DECLARE @t8_csv NVARCHAR(200) = '24.02.2026 10:45:00; 99,99; 118,99; Puffer 3; Lukas';

-- 8a: Feld 1 (Datum)
IF Robotico.fnEscapedCSVGetField(@t8_csv, 1, ';') = '24.02.2026 10:45:00'
BEGIN PRINT '  + Field 1 -> "24.02.2026 10:45:00"'; SET @t8_passed += 1; END
ELSE PRINT '  x Field 1: FAILED (got: "' + ISNULL(Robotico.fnEscapedCSVGetField(@t8_csv, 1, ';'), 'NULL') + '")';

-- 8b: Feld 2 (Preis)
IF Robotico.fnEscapedCSVGetField(@t8_csv, 2, ';') = '99,99'
BEGIN PRINT '  + Field 2 -> "99,99"'; SET @t8_passed += 1; END
ELSE PRINT '  x Field 2: FAILED (got: "' + ISNULL(Robotico.fnEscapedCSVGetField(@t8_csv, 2, ';'), 'NULL') + '")';

-- 8c: Feld 4 (Puffer)
IF Robotico.fnEscapedCSVGetField(@t8_csv, 4, ';') = 'Puffer 3'
BEGIN PRINT '  + Field 4 -> "Puffer 3"'; SET @t8_passed += 1; END
ELSE PRINT '  x Field 4: FAILED (got: "' + ISNULL(Robotico.fnEscapedCSVGetField(@t8_csv, 4, ';'), 'NULL') + '")';

-- 8d: Feld 5 (Name)
IF Robotico.fnEscapedCSVGetField(@t8_csv, 5, ';') = 'Lukas'
BEGIN PRINT '  + Field 5 -> "Lukas"'; SET @t8_passed += 1; END
ELSE PRINT '  x Field 5: FAILED (got: "' + ISNULL(Robotico.fnEscapedCSVGetField(@t8_csv, 5, ';'), 'NULL') + '")';

-- 8e: Nicht existierendes Feld -> NULL
IF Robotico.fnEscapedCSVGetField(@t8_csv, 10, ';') IS NULL
BEGIN PRINT '  + Field 10 -> NULL (out of range)'; SET @t8_passed += 1; END
ELSE PRINT '  x Field 10: FAILED (expected NULL)';

-- 8f: NULL Input -> NULL
IF Robotico.fnEscapedCSVGetField(NULL, 1, ';') IS NULL
BEGIN PRINT '  + NULL input -> NULL'; SET @t8_passed += 1; END
ELSE PRINT '  x NULL input: FAILED';

PRINT '  Result: ' + CAST(@t8_passed AS NVARCHAR(5)) + '/' + CAST(@t8_total AS NVARCHAR(5)) + ' passed';
INSERT INTO #TestResults VALUES ('fnEscapedCSVGetField', @t8_passed, @t8_total);
PRINT '';
GO

-- ============================================================================
-- Test 9: fnEscapedCSVGetLastLine
-- ============================================================================
PRINT '--- Test 9: fnEscapedCSVGetLastLine ---';

DECLARE @t9_passed INT = 0;
DECLARE @t9_total INT = 5;

-- 9a: NULL -> NULL
IF Robotico.fnEscapedCSVGetLastLine(NULL) IS NULL
BEGIN PRINT '  + NULL -> NULL'; SET @t9_passed += 1; END
ELSE PRINT '  x NULL: FAILED';

-- 9b: Leerer String -> NULL
IF Robotico.fnEscapedCSVGetLastLine('') IS NULL
BEGIN PRINT '  + Empty -> NULL'; SET @t9_passed += 1; END
ELSE PRINT '  x Empty: FAILED';

-- 9c: Einzeilig -> gesamter String
IF Robotico.fnEscapedCSVGetLastLine('24.02.2026; 99,99; Lukas') = '24.02.2026; 99,99; Lukas'
BEGIN PRINT '  + Single line -> entire string'; SET @t9_passed += 1; END
ELSE PRINT '  x Single line: FAILED';

-- 9d: Mehrzeilig -> letzte Zeile (ohne CR)
DECLARE @t9_history NVARCHAR(MAX) = '24.02.2026; 50,00; User1' + CHAR(13)+CHAR(10) + '25.02.2026; 99,99; User2';
DECLARE @t9_result NVARCHAR(MAX) = Robotico.fnEscapedCSVGetLastLine(@t9_history);
IF @t9_result = '25.02.2026; 99,99; User2'
BEGIN PRINT '  + Multiline -> last line (CR removed)'; SET @t9_passed += 1; END
ELSE PRINT '  x Multiline: FAILED (got: "' + ISNULL(@t9_result, 'NULL') + '")';

-- 9e: Trailing CRLF -> gibt trotzdem letzte Content-Zeile zurueck
DECLARE @t9_trailing NVARCHAR(MAX) = 'Line1' + CHAR(10) + 'Line2' + CHAR(13) + CHAR(10);
DECLARE @t9_trailing_result NVARCHAR(MAX) = Robotico.fnEscapedCSVGetLastLine(@t9_trailing);
IF @t9_trailing_result = 'Line2'
BEGIN PRINT '  + Trailing CRLF -> "Line2" (not empty)'; SET @t9_passed += 1; END
ELSE PRINT '  x Trailing CRLF: FAILED (got: "' + ISNULL(@t9_trailing_result, 'NULL') + '")';

PRINT '  Result: ' + CAST(@t9_passed AS NVARCHAR(5)) + '/' + CAST(@t9_total AS NVARCHAR(5)) + ' passed';
INSERT INTO #TestResults VALUES ('fnEscapedCSVGetLastLine', @t9_passed, @t9_total);
PRINT '';
GO

-- ============================================================================
-- Integration Test: Full History-SP Pattern (Write + Read)
-- ============================================================================
PRINT '--- Integration Test: Full History-SP Pattern (Write + Read) ---';

DECLARE @ti_passed INT = 0;
DECLARE @ti_total INT = 5;

-- Simuliere Write: Username sanitizen
DECLARE @rawUser NVARCHAR(100) = '  Lukas; "Dansen"  ';
DECLARE @cleanUser NVARCHAR(100) = Robotico.fnEscapedCSVSanitize(@rawUser, '[Unbekannt]');
IF @cleanUser = 'Lukas Dansen'
BEGIN PRINT '  + Sanitize: "' + @rawUser + '" -> "' + @cleanUser + '"'; SET @ti_passed += 1; END
ELSE PRINT '  x Sanitize: FAILED (got: "' + ISNULL(@cleanUser, 'NULL') + '")';

-- Simuliere History mit 3 Eintraegen
DECLARE @history NVARCHAR(MAX) =
    '20.02.2026 10:00:00; 50,00; 59,50; Puffer 0; Admin' + CHAR(13)+CHAR(10) +
    '22.02.2026 14:30:00; 75,50; 89,85; Puffer 2; Lukas' + CHAR(13)+CHAR(10) +
    '24.02.2026 09:15:00; 99,99; 118,99; Puffer 3; System';

-- Read: Letzte Zeile extrahieren
DECLARE @lastLine NVARCHAR(MAX) = Robotico.fnEscapedCSVGetLastLine(@history);
IF @lastLine = '24.02.2026 09:15:00; 99,99; 118,99; Puffer 3; System'
BEGIN PRINT '  + Last line extracted correctly'; SET @ti_passed += 1; END
ELSE PRINT '  x Last line: FAILED (got: "' + ISNULL(@lastLine, 'NULL') + '")';

-- Read: Alle Felder in einem Durchgang parsen (iTVF Kernfeature)
DECLARE @datum NVARCHAR(50), @preis NVARCHAR(50), @puffer NVARCHAR(50), @user NVARCHAR(50);
SELECT @datum  = MAX(CASE WHEN ordinal = 1 THEN value END),
       @preis  = MAX(CASE WHEN ordinal = 2 THEN value END),
       @puffer = MAX(CASE WHEN ordinal = 4 THEN value END),
       @user   = MAX(CASE WHEN ordinal = 5 THEN value END)
FROM Robotico.fnEscapedCSVParseLine(@lastLine, ';');

IF @datum = '24.02.2026 09:15:00' AND @user = 'System'
BEGIN PRINT '  + ParseLine multi-read: datum="' + @datum + '", user="' + @user + '"'; SET @ti_passed += 1; END
ELSE PRINT '  x ParseLine: FAILED';

-- Read: Preis parsen (German Decimal)
DECLARE @preisDecimal DECIMAL(25,13) = Robotico.fnStringParseGermanDecimal(@preis);
IF @preisDecimal BETWEEN 99.989 AND 99.991
BEGIN PRINT '  + Price parsed: ' + CAST(@preisDecimal AS NVARCHAR(30)); SET @ti_passed += 1; END
ELSE PRINT '  x Price parsing: FAILED (got: ' + ISNULL(CAST(@preisDecimal AS NVARCHAR(30)), 'NULL') + ')';

-- Read: Puffer extrahieren
IF @puffer = 'Puffer 3'
BEGIN PRINT '  + Buffer field: "' + @puffer + '"'; SET @ti_passed += 1; END
ELSE PRINT '  x Buffer field: FAILED (got: "' + ISNULL(@puffer, 'NULL') + '")';

PRINT '  Result: ' + CAST(@ti_passed AS NVARCHAR(5)) + '/' + CAST(@ti_total AS NVARCHAR(5)) + ' passed';
INSERT INTO #TestResults VALUES ('Integration Test', @ti_passed, @ti_total);
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
END
ELSE
BEGIN
    PRINT 'TESTS FAILED: '
        + CAST(@totalPassed AS NVARCHAR(5)) + '/'
        + CAST(@totalTests AS NVARCHAR(5)) + ' checks passed, '
        + CAST(@failedSections AS NVARCHAR(5)) + ' section(s) with failures:';
    PRINT '';

    DECLARE @failName NVARCHAR(100), @failPassed INT, @failTotal INT;
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
GO
