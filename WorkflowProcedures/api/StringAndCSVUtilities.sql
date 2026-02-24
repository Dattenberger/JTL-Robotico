-- ============================================================================
-- String & EscapedCSV Utility Functions for JTL eazybusiness
-- ============================================================================
--
-- Author: Lukas Dattenberger
-- Date: 2026-02-24
-- Version: 1.0
--
-- ============================================================================
-- WAS IST ESCAPED CSV?
-- ============================================================================
--
-- EscapedCSV ist ein vereinfachtes CSV-Format, bei dem alle Feldwerte
-- VOR dem Schreiben bereinigt ("escaped") werden. Dadurch entfaellt beim
-- Lesen jegliches Quoting/Escaping - ein einfacher Split am Separator
-- reicht aus.
--
-- Verbotene Zeichen in Feldwerten (werden durch fnEscapedCSVSanitize entfernt):
--   - Semikolon (;)    -> Feld-Separator
--   - Einfaches Quote (')
--   - Doppeltes Quote (")
--   - Carriage Return (CR, CHAR(13))
--   - Line Feed (LF, CHAR(10))
--
-- Format einer EscapedCSV-Zeile:
--   Wert1; Wert2; Wert3; Wert4
--
-- Format eines mehrzeiligen EscapedCSV-Strings (z.B. History):
--   Zeile1-Wert1; Zeile1-Wert2; Zeile1-Wert3    <-- aeltester Eintrag
--   Zeile2-Wert1; Zeile2-Wert2; Zeile2-Wert3
--   Zeile3-Wert1; Zeile3-Wert2; Zeile3-Wert3    <-- neuester Eintrag
--   (Zeilen getrennt durch CRLF = CHAR(13)+CHAR(10))
--
-- Vertrag:
--   Wer mit fnEscapedCSVSanitize schreibt, kann sich darauf verlassen
--   dass fnEscapedCSVParseLine/GetField/GetLastLine korrekt liest.
--
-- ============================================================================
-- WRITE PATTERN (Zeile schreiben)
-- ============================================================================
--
-- Schritt 1: Jeden variablen Wert mit fnEscapedCSVSanitize bereinigen
-- Schritt 2: Zeile mit CONCAT_WS (built-in, SQL Server 2017+) zusammenbauen
--
-- Beispiel (Preis-History):
--
--   SET @userName = Robotico.fnEscapedCSVSanitize(@userName, '[Unbekannt]');
--
--   SET @newEntry = CONCAT_WS('; ',
--       FORMAT(GETDATE(), 'dd.MM.yyyy HH:mm:ss', 'de-DE'),
--       FORMAT(@currentVkNetto, 'N2', 'de-DE'),
--       FORMAT(@vkBrutto, 'N2', 'de-DE'),
--       'Puffer ' + CAST(@currentPuffer AS NVARCHAR(10)),
--       @userName
--   );
--
--   -- Ergebnis: '24.02.2026 10:45:00; 99,99; 118,99; Puffer 3; Lukas'
--
-- An bestehende History anhaengen:
--
--   IF Robotico.fnStringIsEffectivelyEmpty(@existingHistory) = 1
--       SET @existingHistory = @newEntry;
--   ELSE
--       SET @existingHistory = @existingHistory + CHAR(13) + CHAR(10) + @newEntry;
--
-- ============================================================================
-- READ PATTERN (Zeile lesen)
-- ============================================================================
--
-- Schritt 1: Letzte Zeile extrahieren (bei mehrzeiligem String)
-- Schritt 2: Felder parsen mit fnEscapedCSVParseLine (einmal parsen, alles lesen)
--
-- Beispiel:
--
--   SET @lastLine = Robotico.fnEscapedCSVGetLastLine(@existingHistory);
--
--   -- Alle benoetigten Felder in einem Durchgang lesen:
--   SELECT @datum  = MAX(CASE WHEN ordinal = 1 THEN value END),
--          @preis  = MAX(CASE WHEN ordinal = 2 THEN value END),
--          @puffer = MAX(CASE WHEN ordinal = 4 THEN value END),
--          @user   = MAX(CASE WHEN ordinal = 5 THEN value END)
--   FROM Robotico.fnEscapedCSVParseLine(@lastLine, ';');
--
--   -- Preis von deutschem Format zu DECIMAL konvertieren:
--   SET @vkNetto = Robotico.fnStringParseGermanDecimal(@preis);
--
--   -- Oder: Einzelnes Feld lesen (Convenience, aber weniger effizient):
--   SET @user = Robotico.fnEscapedCSVGetField(@lastLine, 5, ';');
--
-- ============================================================================
-- FUNCTION UEBERSICHT
-- ============================================================================
--
-- String Functions (generische String-Operationen):
--   1. Robotico.fnStringStripWhitespace        - Entfernt Tabs, CR, LF
--   2. Robotico.fnStringIsEffectivelyEmpty     - Prueft ob String NULL/nur Whitespace
--   3. Robotico.fnStringCountLines              - Zaehlt Zeilen (LF-basiert)
--   4. Robotico.fnStringTrimToMaxLines          - Behaelt nur die letzten N Zeilen
--   5. Robotico.fnStringParseGermanDecimal      - Parst deutsches Zahlenformat
--
-- EscapedCSV API:
--   6. Robotico.fnEscapedCSVSanitize            - Write: Bereinigt Wert fuer CSV
--   7. Robotico.fnEscapedCSVParseLine           - Read: Parst Zeile (iTVF)
--   8. Robotico.fnEscapedCSVGetField            - Read: Einzelfeld-Zugriff
--   9. Robotico.fnEscapedCSVGetLastLine         - Read: Letzte Zeile extrahieren
--      + CONCAT_WS (built-in)                   - Write: Zeile zusammenbauen
--
-- Dependencies (Erstellungsreihenfolge beachten):
--   #4 nutzt #3 (fnStringTrimToMaxLines -> fnStringCountLines)
--   #8 nutzt #7 (fnEscapedCSVGetField -> fnEscapedCSVParseLine)
--
-- ============================================================================

-- ============================================================================
-- Create Robotico Schema if it doesn't exist
-- ============================================================================
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'Robotico')
BEGIN
    EXEC('CREATE SCHEMA Robotico');
    PRINT '+ Schema Robotico created';
END
ELSE
    PRINT '= Schema Robotico already exists';
GO

-- ============================================================================
-- Transactional Deployment
-- ============================================================================
-- SET XACT_ABORT ON sorgt dafuer, dass bei jedem Fehler die Transaction
-- automatisch als "doomed" markiert wird. Nachfolgende Batches koennen dann
-- nicht mehr schreiben und am Ende wird alles zurueckgerollt.
-- ============================================================================
SET XACT_ABORT ON
GO

BEGIN TRANSACTION
GO

-- ============================================================================
-- ============================================================================
--                         STRING FUNCTIONS
-- ============================================================================
-- ============================================================================

-- ============================================================================
-- 1. fnStringStripWhitespace
-- ============================================================================
-- Description:
--   Entfernt Tabs (CHAR(9)), Carriage Returns (CHAR(13)) und
--   Line Feeds (CHAR(10)) aus einem String. Regulaere Leerzeichen
--   innerhalb des Inhalts bleiben erhalten.
--
-- Parameters:
--   @str - Der zu bereinigende String
--
-- Returns:
--   NVARCHAR(MAX): String ohne Tabs/CR/LF, NULL wenn Input NULL
--
-- Usage:
--   SELECT Robotico.fnStringStripWhitespace('Hello' + CHAR(10) + 'World')
--   -- Returns: 'HelloWorld'
-- ============================================================================

CREATE OR ALTER FUNCTION Robotico.fnStringStripWhitespace(@str NVARCHAR(MAX))
RETURNS NVARCHAR(MAX)
AS
BEGIN
    IF @str IS NULL
        RETURN NULL;

    RETURN REPLACE(REPLACE(REPLACE(@str,
        CHAR(9), ''),   -- Tab
        CHAR(13), ''),  -- Carriage Return
        CHAR(10), '')   -- Line Feed
END
GO

PRINT '+ Function Robotico.fnStringStripWhitespace created';
GO

-- ============================================================================
-- 2. fnStringIsEffectivelyEmpty
-- ============================================================================
-- Description:
--   Prueft ob ein String NULL ist oder nur aus Whitespace besteht
--   (Leerzeichen, Tabs, Carriage Returns, Line Feeds).
--   Entfernt alle Whitespace-Zeichen direkt per REPLACE und prueft LEN = 0.
--
-- Parameters:
--   @str - Der zu pruefende String
--
-- Returns:
--   BIT: 1 wenn NULL oder effektiv leer, 0 wenn Inhalt vorhanden
--
-- Usage:
--   SELECT Robotico.fnStringIsEffectivelyEmpty(NULL)               -- 1
--   SELECT Robotico.fnStringIsEffectivelyEmpty('')                 -- 1
--   SELECT Robotico.fnStringIsEffectivelyEmpty('   ')              -- 1
--   SELECT Robotico.fnStringIsEffectivelyEmpty(CHAR(9)+CHAR(13))   -- 1
--   SELECT Robotico.fnStringIsEffectivelyEmpty('Hello')            -- 0
--
--   -- In History-SPs:
--   IF Robotico.fnStringIsEffectivelyEmpty(@existingHistory) = 0
--       -- History hat Inhalt, letzte Entry parsen
-- ============================================================================

CREATE OR ALTER FUNCTION Robotico.fnStringIsEffectivelyEmpty(@str NVARCHAR(MAX))
RETURNS BIT
AS
BEGIN
    RETURN CASE
        WHEN @str IS NULL THEN 1
        WHEN LEN(
            REPLACE(REPLACE(REPLACE(REPLACE(@str,
                ' ', ''),       -- Space
                CHAR(9), ''),   -- Tab
                CHAR(13), ''),  -- Carriage Return
                CHAR(10), '')   -- Line Feed
        ) = 0 THEN 1
        ELSE 0
    END
END
GO

PRINT '+ Function Robotico.fnStringIsEffectivelyEmpty created';
GO

-- ============================================================================
-- 3. fnStringCountLines
-- ============================================================================
-- Description:
--   Zaehlt die Anzahl der Zeilen in einem mehrzeiligen String (LF-basiert).
--   NULL oder leerer String = 0 Zeilen, einzelne Zeile (kein LF) = 1 Zeile.
--   HINWEIS: Trailing LF zaehlt als zusaetzliche (leere) Zeile.
--
-- Parameters:
--   @str - Der zu zaehlende String
--
-- Returns:
--   INT: Anzahl der Zeilen (0 bei NULL/leer)
--
-- Usage:
--   SELECT Robotico.fnStringCountLines(NULL)                             -- 0
--   SELECT Robotico.fnStringCountLines('')                               -- 0
--   SELECT Robotico.fnStringCountLines('Hello')                          -- 1
--   SELECT Robotico.fnStringCountLines('Line1' + CHAR(10) + 'Line2')    -- 2
--   SELECT Robotico.fnStringCountLines('A' + CHAR(10))                   -- 2 (trailing LF)
-- ============================================================================

CREATE OR ALTER FUNCTION Robotico.fnStringCountLines(@str NVARCHAR(MAX))
RETURNS INT
AS
BEGIN
    IF @str IS NULL OR LEN(@str) = 0
        RETURN 0;

    RETURN LEN(@str) - LEN(REPLACE(@str, CHAR(10), '')) + 1;
END
GO

PRINT '+ Function Robotico.fnStringCountLines created';
GO

-- ============================================================================
-- 4. fnStringTrimToMaxLines
-- ============================================================================
-- Description:
--   Behaelt nur die letzten @maxLines Zeilen eines mehrzeiligen Strings.
--   Leere Zeilen werden bei der Ausgabe herausgefiltert.
--   Verwendet Windows-Zeilenumbruch (CR+LF) als Separator im Ergebnis.
--
--   HINWEIS: Nutzt intern Robotico.fnStringCountLines - muss nach #3 erstellt werden.
--
-- Parameters:
--   @str      - Der zu trimmende String
--   @maxLines - Maximale Anzahl der zu behaltenden Zeilen (muss >= 1 sein)
--
-- Returns:
--   NVARCHAR(MAX): Getrimmter String, oder NULL wenn Input NULL oder @maxLines < 1
--
-- Usage:
--   -- In History-SPs (Trim auf letzte 1000 Eintraege):
--   IF Robotico.fnStringCountLines(@existingHistory) > @MAX_ENTRIES + @TRIM_BUFFER
--       SET @existingHistory = Robotico.fnStringTrimToMaxLines(@existingHistory, @MAX_ENTRIES);
-- ============================================================================

CREATE OR ALTER FUNCTION Robotico.fnStringTrimToMaxLines(
    @str NVARCHAR(MAX),
    @maxLines INT
)
RETURNS NVARCHAR(MAX)
AS
BEGIN
    IF @str IS NULL OR @maxLines < 1
        RETURN NULL;

    DECLARE @lineCount INT = Robotico.fnStringCountLines(@str);

    -- Kein Trimming noetig
    IF @lineCount <= @maxLines
        RETURN @str;

    -- Letzte @maxLines behalten, Leerzeilen filtern
    DECLARE @result NVARCHAR(MAX);

    SELECT @result = STRING_AGG(
        REPLACE(value, CHAR(13), ''),
        CHAR(13) + CHAR(10)
    ) WITHIN GROUP (ORDER BY ordinal)
    FROM STRING_SPLIT(@str, CHAR(10), 1)
    WHERE ordinal > (@lineCount - @maxLines)
      AND LEN(LTRIM(RTRIM(REPLACE(value, CHAR(13), '')))) > 0;

    RETURN @result;
END
GO

PRINT '+ Function Robotico.fnStringTrimToMaxLines created';
GO

-- ============================================================================
-- 5. fnStringParseGermanDecimal
-- ============================================================================
-- Description:
--   Parst einen String im deutschen Zahlenformat zu DECIMAL.
--   Deutsches Format: 1.234,56 (Punkt = Tausender, Komma = Dezimal)
--   SQL Format:       1234.56  (Punkt = Dezimal)
--
--   Schritte:
--   1. Tausender-Trennzeichen (Punkte) entfernen
--   2. Dezimal-Komma durch Punkt ersetzen
--   3. TRY_CAST zu DECIMAL (NULL bei ungueltigem Format)
--
-- Parameters:
--   @value - String im deutschen Zahlenformat (z.B. '1.234,56' oder '99,99')
--
-- Returns:
--   DECIMAL(25,13): Geparster Wert, oder NULL bei ungueltigem Format
--
-- Usage:
--   SELECT Robotico.fnStringParseGermanDecimal('1.234,56')   -- 1234.560000...
--   SELECT Robotico.fnStringParseGermanDecimal('99,99')      -- 99.990000...
--   SELECT Robotico.fnStringParseGermanDecimal('abc')        -- NULL
--   SELECT Robotico.fnStringParseGermanDecimal(NULL)         -- NULL
-- ============================================================================

CREATE OR ALTER FUNCTION Robotico.fnStringParseGermanDecimal(@value NVARCHAR(100))
RETURNS DECIMAL(25,13)
AS
BEGIN
    IF @value IS NULL OR LEN(LTRIM(RTRIM(@value))) = 0
        RETURN NULL;

    -- 1. Tausender-Punkte entfernen, 2. Dezimal-Komma durch Punkt ersetzen
    RETURN TRY_CAST(
        REPLACE(REPLACE(@value, '.', ''), ',', '.')
        AS DECIMAL(25,13)
    );
END
GO

PRINT '+ Function Robotico.fnStringParseGermanDecimal created';
GO

-- ============================================================================
-- ============================================================================
--                       ESCAPED CSV API
-- ============================================================================
-- ============================================================================
--
-- EscapedCSV = CSV-Format bei dem alle Feldwerte VOR dem Schreiben bereinigt
-- werden. Verbotene Zeichen (;  '  "  CR  LF) werden entfernt, nicht escaped.
-- Dadurch reicht beim Lesen ein einfacher Split am Separator - kein Quoting-
-- Parser noetig.
--
-- WRITE:  fnEscapedCSVSanitize (pro Wert) + CONCAT_WS (built-in, Zeile bauen)
-- READ:   fnEscapedCSVGetLastLine + fnEscapedCSVParseLine / fnEscapedCSVGetField
--
-- Siehe Datei-Header fuer vollstaendige Write/Read-Beispiele.
--
-- ============================================================================

-- ============================================================================
-- 6. fnEscapedCSVSanitize
-- ============================================================================
-- Description:
--   WRITE-SEITE der EscapedCSV API.
--   Bereinigt einen Wert fuer sicheres Schreiben in EscapedCSV-Format.
--   Entfernt: Semikolons (;), einfache/doppelte Anfuehrungszeichen,
--   Carriage Returns und Line Feeds.
--   Gibt @defaultValue zurueck wenn das Ergebnis leer ist.
--   Gibt NULL zurueck wenn das Ergebnis leer ist UND kein @defaultValue.
--
-- Parameters:
--   @input        - Der zu bereinigende Wert
--   @defaultValue - Rueckgabewert wenn Ergebnis leer (optional, default NULL)
--
-- Returns:
--   NVARCHAR(MAX): Bereinigter Wert, @defaultValue, oder NULL
--
-- Usage:
--   -- Username fuer History-Eintrag vorbereiten:
--   SET @userName = Robotico.fnEscapedCSVSanitize(@userName, '[Unbekannt]');
--
--   -- Wert bereinigen ohne Default:
--   SET @clean = Robotico.fnEscapedCSVSanitize(@dirtyInput, NULL);
-- ============================================================================

CREATE OR ALTER FUNCTION Robotico.fnEscapedCSVSanitize(
    @input NVARCHAR(MAX),
    @defaultValue NVARCHAR(100) = NULL
)
RETURNS NVARCHAR(MAX)
AS
BEGIN
    DECLARE @cleaned NVARCHAR(MAX);

    SET @cleaned = LTRIM(RTRIM(
        REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
            ISNULL(@input, ''),
            ';', ''),       -- Semikolon (Feld-Separator)
            CHAR(13), ''),  -- Carriage Return
            CHAR(10), ''),  -- Line Feed
            '''', ''),      -- Einfaches Anfuehrungszeichen
            '"', '')        -- Doppeltes Anfuehrungszeichen
    ));

    IF LEN(@cleaned) = 0
    BEGIN
        IF @defaultValue IS NOT NULL
            RETURN @defaultValue;
        RETURN NULL;
    END

    RETURN @cleaned;
END
GO

PRINT '+ Function Robotico.fnEscapedCSVSanitize created';
GO

-- ============================================================================
-- 7. fnEscapedCSVParseLine (Inline Table-Valued Function)
-- ============================================================================
-- Description:
--   READ-SEITE der EscapedCSV API - Kernfunktion.
--   Parst eine EscapedCSV-Zeile in einzelne Felder.
--   Inline TVF: wird vom Query Optimizer direkt in den Execution Plan
--   eingebettet (kein Function-Call-Overhead).
--
--   VORBEDINGUNG: Werte muessen durch fnEscapedCSVSanitize bereinigt sein.
--
-- Parameters:
--   @line      - Die CSV-Zeile (z.B. '24.02.2026; 99,99; Lukas')
--   @separator - Trennzeichen (default: ';')
--
-- Returns:
--   TABLE(ordinal INT, value NVARCHAR(MAX)):
--     ordinal = 1-basierter Feld-Index
--     value   = Getrimmter Feldwert
--
-- Usage:
--   -- Alle Felder einer Zeile lesen:
--   SELECT * FROM Robotico.fnEscapedCSVParseLine('A; B; C', ';');
--
--   -- Mehrere Felder effizient lesen (1x Parse statt Nx):
--   SELECT @datum  = MAX(CASE WHEN ordinal = 1 THEN value END),
--          @preis  = MAX(CASE WHEN ordinal = 2 THEN value END),
--          @puffer = MAX(CASE WHEN ordinal = 4 THEN value END)
--   FROM Robotico.fnEscapedCSVParseLine(@lastEntry, ';');
-- ============================================================================

CREATE OR ALTER FUNCTION Robotico.fnEscapedCSVParseLine(
    @line NVARCHAR(MAX),
    @separator NCHAR(1) = ';'
)
RETURNS TABLE
AS
RETURN (
    SELECT ordinal, LTRIM(RTRIM(value)) AS value
    FROM STRING_SPLIT(@line, @separator, 1)
);
GO

PRINT '+ Function Robotico.fnEscapedCSVParseLine created';
GO

-- ============================================================================
-- 8. fnEscapedCSVGetField
-- ============================================================================
-- Description:
--   READ-SEITE der EscapedCSV API - Convenience-Wrapper.
--   Extrahiert ein einzelnes Feld aus einer EscapedCSV-Zeile.
--   Fuer Einzelzugriffe lesbarer als fnEscapedCSVParseLine.
--   Fuer Multi-Feld-Zugriffe: fnEscapedCSVParseLine direkt nutzen.
--
--   HINWEIS: Nutzt intern fnEscapedCSVParseLine - muss nach #7 erstellt werden.
--
-- Parameters:
--   @csvLine    - Die CSV-Zeile (z.B. 'Datum; Preis; Benutzer')
--   @fieldIndex - 1-basierter Index des gewuenschten Feldes
--   @separator  - Trennzeichen (default: ';')
--
-- Returns:
--   NVARCHAR(MAX): Getrimmter Feldwert, oder NULL wenn nicht vorhanden
--
-- Usage:
--   SELECT Robotico.fnEscapedCSVGetField('A; B; C', 1, ';')   -- 'A'
--   SELECT Robotico.fnEscapedCSVGetField('A; B; C', 2, ';')   -- 'B'
--   SELECT Robotico.fnEscapedCSVGetField('A; B; C', 4, ';')   -- NULL
-- ============================================================================

CREATE OR ALTER FUNCTION Robotico.fnEscapedCSVGetField(
    @csvLine NVARCHAR(MAX),
    @fieldIndex INT,
    @separator NCHAR(1) = ';'
)
RETURNS NVARCHAR(MAX)
AS
BEGIN
    IF @csvLine IS NULL OR @fieldIndex < 1
        RETURN NULL;

    DECLARE @result NVARCHAR(MAX);

    SELECT @result = value
    FROM Robotico.fnEscapedCSVParseLine(@csvLine, @separator)
    WHERE ordinal = @fieldIndex;

    RETURN @result;
END
GO

PRINT '+ Function Robotico.fnEscapedCSVGetField created';
GO

-- ============================================================================
-- 9. fnEscapedCSVGetLastLine
-- ============================================================================
-- Description:
--   READ-SEITE der EscapedCSV API.
--   Extrahiert die letzte Zeile aus einem mehrzeiligen EscapedCSV-String.
--   Trailing CR/LF am Ende des Inputs werden vor dem Parsing entfernt.
--   Carriage Returns werden aus dem Ergebnis entfernt.
--   Bei einzeiligem Input wird der gesamte String zurueckgegeben.
--
-- Parameters:
--   @multiLineCSV - Der mehrzeilige CSV-String (LF- oder CRLF-separiert)
--
-- Returns:
--   NVARCHAR(MAX): Letzte Zeile ohne CR, oder NULL wenn Input NULL/leer
--
-- Usage:
--   SET @lastEntry = Robotico.fnEscapedCSVGetLastLine(@existingHistory);
-- ============================================================================

CREATE OR ALTER FUNCTION Robotico.fnEscapedCSVGetLastLine(@multiLineCSV NVARCHAR(MAX))
RETURNS NVARCHAR(MAX)
AS
BEGIN
    IF @multiLineCSV IS NULL OR LEN(@multiLineCSV) = 0
        RETURN NULL;

    -- Trailing CR/LF entfernen um Leer-Ergebnis bei 'Line1\nLine2\n' zu vermeiden
    WHILE LEN(@multiLineCSV) > 0 AND UNICODE(RIGHT(@multiLineCSV, 1)) IN (10, 13)
        SET @multiLineCSV = LEFT(@multiLineCSV, LEN(@multiLineCSV + N'x') - 2);

    IF LEN(@multiLineCSV) = 0
        RETURN NULL;

    DECLARE @lastLine NVARCHAR(MAX);

    IF CHARINDEX(CHAR(10), @multiLineCSV) > 0
        SET @lastLine = RIGHT(@multiLineCSV, CHARINDEX(CHAR(10), REVERSE(@multiLineCSV)) - 1);
    ELSE
        SET @lastLine = @multiLineCSV;

    -- CR entfernen
    RETURN REPLACE(@lastLine, CHAR(13), '');
END
GO

PRINT '+ Function Robotico.fnEscapedCSVGetLastLine created';
GO

-- ============================================================================
-- Transaction Commit / Rollback
-- ============================================================================
IF XACT_STATE() = 1
BEGIN
    COMMIT TRANSACTION;
    PRINT '';
    PRINT '============================================================================';
    PRINT 'String & EscapedCSV Utility Functions deployed successfully!';
    PRINT '============================================================================';
    PRINT '';
    PRINT 'String Functions:';
    PRINT '  1. Robotico.fnStringStripWhitespace        (NVARCHAR)';
    PRINT '  2. Robotico.fnStringIsEffectivelyEmpty     (BIT)';
    PRINT '  3. Robotico.fnStringCountLines              (INT)';
    PRINT '  4. Robotico.fnStringTrimToMaxLines          (NVARCHAR) -> nutzt #3';
    PRINT '  5. Robotico.fnStringParseGermanDecimal      (DECIMAL)';
    PRINT '';
    PRINT 'EscapedCSV API:';
    PRINT '  6. Robotico.fnEscapedCSVSanitize            (NVARCHAR) [Write]';
    PRINT '  7. Robotico.fnEscapedCSVParseLine           (TABLE)    [Read - iTVF]';
    PRINT '  8. Robotico.fnEscapedCSVGetField            (NVARCHAR) [Read] -> nutzt #7';
    PRINT '  9. Robotico.fnEscapedCSVGetLastLine         (NVARCHAR) [Read]';
    PRINT '';
    PRINT '============================================================================';
    PRINT '';
END
ELSE
BEGIN
    IF XACT_STATE() = -1
        ROLLBACK TRANSACTION;
    PRINT '';
    PRINT '!!! DEPLOYMENT FAILED - Alle Aenderungen wurden zurueckgerollt !!!';
    PRINT '';
END
GO
