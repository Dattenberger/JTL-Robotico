-- ============================================================================
-- Test Suite for Duplicate Order Detection (transaction-based)
-- ============================================================================
-- Description:
--   Validates Robotico.fnFindDuplicateOrders, Robotico.fnHasOlderDuplicateOrder
--   and Robotico.spCheckDuplicateOrder.
--   Every test runs in its own transaction and rolls back automatically -
--   NO database changes remain.
--
-- Components under test:
--   - Robotico.fnFindDuplicateOrders     (iTVF: duplicate orders + age flag)
--   - Robotico.fnHasOlderDuplicateOrder  (BIT: older identical order exists?)
--   - Robotico.spCheckDuplicateOrder     (result set + OUTPUT + RETURN code)
--
-- Test strategy:
--   Tests 1-7 create synthetic orders for a REAL customer that has no orders
--   (resolved dynamically via #TestEnv; required because of FK
--   Verkauf.tAuftrag.kKunde -> dbo.tkunde). A collision with real orders is
--   impossible because the position fingerprint contains the unique test
--   article numbers 'DUP-ART-*'. Test 8 additionally checks a real duplicate
--   pair of the test database (read-only).
--
-- Pattern: BEGIN TRANSACTION -> insert -> assert -> ROLLBACK TRANSACTION
--
-- Prerequisite: Duplikaterkennung_Bestellungen.sql has been deployed.
--
-- Author: Lukas Dattenberger
-- Date:   2026-06-08
-- ============================================================================

USE [eazybusiness]
GO

IF OBJECT_ID('tempdb..#TestResults') IS NOT NULL DROP TABLE #TestResults;
CREATE TABLE #TestResults (testName NVARCHAR(200), passed INT, total INT);
GO

-- ============================================================================
-- Test environment: a real customer WITHOUT orders as a clean test customer
-- ============================================================================
IF OBJECT_ID('tempdb..#TestEnv') IS NOT NULL DROP TABLE #TestEnv;
CREATE TABLE #TestEnv (kKunde INT);
INSERT INTO #TestEnv (kKunde)
SELECT TOP 1 k.kKunde
FROM dbo.tkunde k
WHERE NOT EXISTS (SELECT 1 FROM Verkauf.tAuftrag a WHERE a.kKunde = k.kKunde)
ORDER BY k.kKunde;
GO

-- ============================================================================
-- Temp helper: create a synthetic order (header + totals + 1 position)
-- ============================================================================
IF OBJECT_ID('tempdb..#CreateTestOrder') IS NOT NULL
    EXEC('DROP PROCEDURE #CreateTestOrder');
GO

CREATE PROCEDURE #CreateTestOrder
    @kKunde      INT,
    @dErstellt   DATETIME,
    @cArtNr      NVARCHAR(50),
    @fAnzahl     DECIMAL(18,3),
    @fVkNetto    DECIMAL(18,2),
    @fWertBrutto DECIMAL(18,2),
    @nStorno     BIT          = 0,
    @kArtikel    INT          = NULL,
    @kAuftrag    INT          OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- Valid FK seeds (kFirmaHistory -> dbo.tFirmaHistory, kSprache -> dbo.tSpracheUsed)
    DECLARE @kFirmaHistory INT = (SELECT MIN(kFirmaHistory) FROM dbo.tFirmaHistory);
    DECLARE @kSprache      INT = (SELECT MIN(kSprache)      FROM dbo.tSpracheUsed);

    INSERT INTO Verkauf.tAuftrag
        (kKunde, kBenutzer, cAuftragsNr, nType, fFaktor, kFirmaHistory, kSprache,
         cVersandlandWaehrung, fVersandlandWaehrungFaktor, fFinanzierungskosten,
         kBenutzerErstellt, dErstellt, nStorno)
    VALUES
        (@kKunde, 0, 'TEST-' + CONVERT(NVARCHAR(36), NEWID()), 1, 1, @kFirmaHistory, @kSprache,
         'EUR', 1, 0, 0, @dErstellt, @nStorno);

    SET @kAuftrag = CAST(SCOPE_IDENTITY() AS INT);

    INSERT INTO Verkauf.tAuftragEckdaten (kAuftrag, fWertBrutto)
    VALUES (@kAuftrag, @fWertBrutto);

    -- nType = 1 -> customer position (feeds the position fingerprint)
    INSERT INTO Verkauf.tAuftragPosition
        (kAuftrag, kArtikel, cArtNr, fAnzahl, fMwSt, fVkNetto, nType)
    VALUES
        (@kAuftrag, @kArtikel, @cArtNr, @fAnzahl, 19, @fVkNetto, 1);
END
GO

PRINT '============================================================================';
PRINT 'Duplicate Order Detection - Test Suite (transaction-based)';
PRINT '============================================================================';
PRINT '';
PRINT 'Tests 1-7: synthetic orders for a real customer without orders.';
PRINT 'Test 8:    real seed pair (order 236 -> false, 237 -> true).';
PRINT 'All tests roll back automatically - no changes remain.';
PRINT '';

-- ============================================================================
-- Test 1: "true from the 2nd order" - 3 identical orders, same timestamp
--         (deterministic via kAuftrag tie-break)
-- ============================================================================
PRINT '--- Test 1: 3 identical orders -> 1st false, 2nd+3rd true (tie-break) ---';

DECLARE @t1_passed INT = 0, @t1_total INT = 3;
DECLARE @kTestKunde INT = (SELECT kKunde FROM #TestEnv);

BEGIN TRANSACTION;
BEGIN TRY
    DECLARE @t1_a INT, @t1_b INT, @t1_c INT;
    EXEC #CreateTestOrder @kKunde=@kTestKunde, @dErstellt='2026-01-10T10:00:00',
         @cArtNr='DUP-ART-1', @fAnzahl=2, @fVkNetto=50.00, @fWertBrutto=119.00, @kAuftrag=@t1_a OUTPUT;
    EXEC #CreateTestOrder @kKunde=@kTestKunde, @dErstellt='2026-01-10T10:00:00',
         @cArtNr='DUP-ART-1', @fAnzahl=2, @fVkNetto=50.00, @fWertBrutto=119.00, @kAuftrag=@t1_b OUTPUT;
    EXEC #CreateTestOrder @kKunde=@kTestKunde, @dErstellt='2026-01-10T10:00:00',
         @cArtNr='DUP-ART-1', @fAnzahl=2, @fVkNetto=50.00, @fWertBrutto=119.00, @kAuftrag=@t1_c OUTPUT;

    -- 1st (lowest kAuftrag) -> false
    IF Robotico.fnHasOlderDuplicateOrder(@t1_a, 24) = 0
    BEGIN PRINT '  + 1st order: false (no older twin)'; SET @t1_passed += 1; END
    ELSE PRINT '  x 1st order should be false';

    -- 2nd -> true
    IF Robotico.fnHasOlderDuplicateOrder(@t1_b, 24) = 1
    BEGIN PRINT '  + 2nd order: true'; SET @t1_passed += 1; END
    ELSE PRINT '  x 2nd order should be true';

    -- 3rd -> true
    IF Robotico.fnHasOlderDuplicateOrder(@t1_c, 24) = 1
    BEGIN PRINT '  + 3rd order: true'; SET @t1_passed += 1; END
    ELSE PRINT '  x 3rd order should be true';

    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT '  x ERROR: ' + ERROR_MESSAGE();
END CATCH

INSERT INTO #TestResults VALUES ('2nd-order-onward semantics', @t1_passed, @t1_total);
GO

-- ============================================================================
-- Test 2: two identical orders, distinct timestamps -> older false, newer true
-- ============================================================================
PRINT '--- Test 2: distinct timestamps -> older false, newer true ---';

DECLARE @t2_passed INT = 0, @t2_total INT = 2;
DECLARE @kTestKunde INT = (SELECT kKunde FROM #TestEnv);

BEGIN TRANSACTION;
BEGIN TRY
    DECLARE @t2_a INT, @t2_b INT;
    EXEC #CreateTestOrder @kKunde=@kTestKunde, @dErstellt='2026-01-10T10:00:00',
         @cArtNr='DUP-ART-2', @fAnzahl=1, @fVkNetto=10.00, @fWertBrutto=11.90, @kAuftrag=@t2_a OUTPUT;
    EXEC #CreateTestOrder @kKunde=@kTestKunde, @dErstellt='2026-01-10T11:00:00',
         @cArtNr='DUP-ART-2', @fAnzahl=1, @fVkNetto=10.00, @fWertBrutto=11.90, @kAuftrag=@t2_b OUTPUT;

    IF Robotico.fnHasOlderDuplicateOrder(@t2_a, 24) = 0
    BEGIN PRINT '  + older order: false'; SET @t2_passed += 1; END
    ELSE PRINT '  x older order should be false';

    IF Robotico.fnHasOlderDuplicateOrder(@t2_b, 24) = 1
    BEGIN PRINT '  + newer order: true'; SET @t2_passed += 1; END
    ELSE PRINT '  x newer order should be true';

    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT '  x ERROR: ' + ERROR_MESSAGE();
END CATCH

INSERT INTO #TestResults VALUES ('older false / newer true', @t2_passed, @t2_total);
GO

-- ============================================================================
-- Test 3: same gross value, different quantity -> not a duplicate
-- ============================================================================
PRINT '--- Test 3: same total, different quantity -> false ---';

DECLARE @t3_passed INT = 0, @t3_total INT = 1;
DECLARE @kTestKunde INT = (SELECT kKunde FROM #TestEnv);

BEGIN TRANSACTION;
BEGIN TRY
    DECLARE @t3_a INT, @t3_b INT;
    -- Same gross value (119.00) but 1x100 vs 2x50 -> different quantity
    EXEC #CreateTestOrder @kKunde=@kTestKunde, @dErstellt='2026-01-10T10:00:00',
         @cArtNr='DUP-ART-3', @fAnzahl=1, @fVkNetto=100.00, @fWertBrutto=119.00, @kAuftrag=@t3_a OUTPUT;
    EXEC #CreateTestOrder @kKunde=@kTestKunde, @dErstellt='2026-01-10T11:00:00',
         @cArtNr='DUP-ART-3', @fAnzahl=2, @fVkNetto=50.00, @fWertBrutto=119.00, @kAuftrag=@t3_b OUTPUT;

    IF Robotico.fnHasOlderDuplicateOrder(@t3_b, 24) = 0
    BEGIN PRINT '  + different quantity -> false despite equal total'; SET @t3_passed += 1; END
    ELSE PRINT '  x should be false (quantity differs)';

    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT '  x ERROR: ' + ERROR_MESSAGE();
END CATCH

INSERT INTO #TestResults VALUES ('different quantity -> false', @t3_passed, @t3_total);
GO

-- ============================================================================
-- Test 4: time window +/- 24h (inside true, outside false)
-- ============================================================================
PRINT '--- Test 4: time window +/- 24h boundary ---';

DECLARE @t4_passed INT = 0, @t4_total INT = 2;
DECLARE @kTestKunde INT = (SELECT kKunde FROM #TestEnv);

BEGIN TRANSACTION;
BEGIN TRY
    DECLARE @t4_a INT, @t4_b INT, @t4_c INT;
    EXEC #CreateTestOrder @kKunde=@kTestKunde, @dErstellt='2026-01-10T10:00:00',
         @cArtNr='DUP-ART-4', @fAnzahl=1, @fVkNetto=10.00, @fWertBrutto=11.90, @kAuftrag=@t4_a OUTPUT;
    -- 23h later -> inside window
    EXEC #CreateTestOrder @kKunde=@kTestKunde, @dErstellt='2026-01-11T09:00:00',
         @cArtNr='DUP-ART-4', @fAnzahl=1, @fVkNetto=10.00, @fWertBrutto=11.90, @kAuftrag=@t4_b OUTPUT;
    -- 30h after a -> outside window relative to a
    EXEC #CreateTestOrder @kKunde=@kTestKunde, @dErstellt='2026-01-11T16:00:00',
         @cArtNr='DUP-ART-4', @fAnzahl=1, @fVkNetto=10.00, @fWertBrutto=11.90, @kAuftrag=@t4_c OUTPUT;

    -- b is 23h after a -> true
    IF Robotico.fnHasOlderDuplicateOrder(@t4_b, 24) = 1
    BEGIN PRINT '  + 23h gap: true'; SET @t4_passed += 1; END
    ELSE PRINT '  x 23h gap should be true';

    -- c: only a (30h) and b (7h) precede it; a is outside, b is inside -> still true.
    -- Narrow the window to 6h: now neither older twin is inside -> false.
    IF Robotico.fnHasOlderDuplicateOrder(@t4_c, 6) = 0
    BEGIN PRINT '  + window 6h: older twins outside -> false'; SET @t4_passed += 1; END
    ELSE PRINT '  x window 6h should be false';

    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT '  x ERROR: ' + ERROR_MESSAGE();
END CATCH

INSERT INTO #TestResults VALUES ('time window boundary', @t4_passed, @t4_total);
GO

-- ============================================================================
-- Test 5: cancelled older order is ignored
-- ============================================================================
PRINT '--- Test 5: cancelled predecessor -> false ---';

DECLARE @t5_passed INT = 0, @t5_total INT = 1;
DECLARE @kTestKunde INT = (SELECT kKunde FROM #TestEnv);

BEGIN TRANSACTION;
BEGIN TRY
    DECLARE @t5_a INT, @t5_b INT;
    -- a is cancelled
    EXEC #CreateTestOrder @kKunde=@kTestKunde, @dErstellt='2026-01-10T10:00:00',
         @cArtNr='DUP-ART-5', @fAnzahl=1, @fVkNetto=20.00, @fWertBrutto=23.80, @nStorno=1, @kAuftrag=@t5_a OUTPUT;
    EXEC #CreateTestOrder @kKunde=@kTestKunde, @dErstellt='2026-01-10T11:00:00',
         @cArtNr='DUP-ART-5', @fAnzahl=1, @fVkNetto=20.00, @fWertBrutto=23.80, @nStorno=0, @kAuftrag=@t5_b OUTPUT;

    IF Robotico.fnHasOlderDuplicateOrder(@t5_b, 24) = 0
    BEGIN PRINT '  + cancelled predecessor ignored -> false'; SET @t5_passed += 1; END
    ELSE PRINT '  x cancelled predecessor must not count';

    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT '  x ERROR: ' + ERROR_MESSAGE();
END CATCH

INSERT INTO #TestResults VALUES ('cancelled predecessor ignored', @t5_passed, @t5_total);
GO

-- ============================================================================
-- Test 6: same gross value, different article -> not a duplicate
-- ============================================================================
PRINT '--- Test 6: same total, different article -> false ---';

DECLARE @t6_passed INT = 0, @t6_total INT = 1;
DECLARE @kTestKunde INT = (SELECT kKunde FROM #TestEnv);

BEGIN TRANSACTION;
BEGIN TRY
    DECLARE @t6_a INT, @t6_b INT;
    EXEC #CreateTestOrder @kKunde=@kTestKunde, @dErstellt='2026-01-10T10:00:00',
         @cArtNr='DUP-ART-6A', @fAnzahl=1, @fVkNetto=100.00, @fWertBrutto=119.00, @kAuftrag=@t6_a OUTPUT;
    EXEC #CreateTestOrder @kKunde=@kTestKunde, @dErstellt='2026-01-10T11:00:00',
         @cArtNr='DUP-ART-6B', @fAnzahl=1, @fVkNetto=100.00, @fWertBrutto=119.00, @kAuftrag=@t6_b OUTPUT;

    IF Robotico.fnHasOlderDuplicateOrder(@t6_b, 24) = 0
    BEGIN PRINT '  + different article at equal total -> false'; SET @t6_passed += 1; END
    ELSE PRINT '  x false positive: different article flagged';

    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT '  x ERROR: ' + ERROR_MESSAGE();
END CATCH

INSERT INTO #TestResults VALUES ('different article -> false', @t6_passed, @t6_total);
GO

-- ============================================================================
-- Test 7: spCheckDuplicateOrder returns the truth value three ways
-- ============================================================================
PRINT '--- Test 7: spCheckDuplicateOrder result set + OUTPUT + RETURN ---';

DECLARE @t7_passed INT = 0, @t7_total INT = 3;
DECLARE @kTestKunde INT = (SELECT kKunde FROM #TestEnv);

BEGIN TRANSACTION;
BEGIN TRY
    DECLARE @t7_a INT, @t7_b INT;
    EXEC #CreateTestOrder @kKunde=@kTestKunde, @dErstellt='2026-01-10T10:00:00',
         @cArtNr='DUP-ART-7', @fAnzahl=3, @fVkNetto=33.33, @fWertBrutto=119.00, @kAuftrag=@t7_a OUTPUT;
    EXEC #CreateTestOrder @kKunde=@kTestKunde, @dErstellt='2026-01-10T11:00:00',
         @cArtNr='DUP-ART-7', @fAnzahl=3, @fVkNetto=33.33, @fWertBrutto=119.00, @kAuftrag=@t7_b OUTPUT;

    -- Check 1: OUTPUT parameter for the duplicate (b) = 1
    DECLARE @t7_out BIT, @t7_rc INT;
    EXEC @t7_rc = Robotico.spCheckDuplicateOrder @kAuftrag=@t7_b, @nWindowHours=24, @bIsDuplicate=@t7_out OUTPUT;
    IF @t7_out = 1
    BEGIN PRINT '  + OUTPUT = 1 for duplicate'; SET @t7_passed += 1; END
    ELSE PRINT '  x OUTPUT should be 1';

    -- Check 2: RETURN code mirrors the value
    IF @t7_rc = 1
    BEGIN PRINT '  + RETURN code = 1 for duplicate'; SET @t7_passed += 1; END
    ELSE PRINT '  x RETURN code should be 1';

    -- Check 3: OUTPUT = 0 for the first order (a)
    DECLARE @t7_out_a BIT;
    EXEC Robotico.spCheckDuplicateOrder @kAuftrag=@t7_a, @nWindowHours=24, @bIsDuplicate=@t7_out_a OUTPUT;
    IF @t7_out_a = 0
    BEGIN PRINT '  + OUTPUT = 0 for first order'; SET @t7_passed += 1; END
    ELSE PRINT '  x OUTPUT should be 0 for first order';

    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT '  x ERROR: ' + ERROR_MESSAGE();
END CATCH

INSERT INTO #TestResults VALUES ('spCheckDuplicateOrder return paths', @t7_passed, @t7_total);
GO

-- ============================================================================
-- Test 8: real seed pair (read-only) - order 236 false, 237 true; list check
-- ============================================================================
PRINT '--- Test 8: real seed pair (236 false, 237 true) ---';

DECLARE @t8_passed INT = 0, @t8_total INT = 3;

BEGIN TRY
    -- 236 is the older of the identical pair -> false
    IF Robotico.fnHasOlderDuplicateOrder(236, 24) = 0
    BEGIN PRINT '  + real order 236: false (older)'; SET @t8_passed += 1; END
    ELSE PRINT '  x real order 236 should be false (seed changed?)';

    -- 237 is the later one -> true
    IF Robotico.fnHasOlderDuplicateOrder(237, 24) = 1
    BEGIN PRINT '  + real order 237: true (newer)'; SET @t8_passed += 1; END
    ELSE PRINT '  x real order 237 should be true (seed changed?)';

    -- fnFindDuplicateOrders(237) lists 236 as the older duplicate
    IF EXISTS (SELECT 1 FROM Robotico.fnFindDuplicateOrders(237, 24)
               WHERE kDuplicateOrder = 236 AND bIsOlderThanInput = 1)
    BEGIN PRINT '  + list: 236 flagged as older duplicate of 237'; SET @t8_passed += 1; END
    ELSE PRINT '  x list should contain 236 as older duplicate';
END TRY
BEGIN CATCH
    PRINT '  x ERROR: ' + ERROR_MESSAGE();
END CATCH

INSERT INTO #TestResults VALUES ('real seed pair 236/237', @t8_passed, @t8_total);
GO

-- ============================================================================
-- Summary
-- ============================================================================
PRINT '';
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
IF OBJECT_ID('tempdb..#TestEnv') IS NOT NULL DROP TABLE #TestEnv;
IF OBJECT_ID('tempdb..#CreateTestOrder') IS NOT NULL
    EXEC('DROP PROCEDURE #CreateTestOrder');
GO
