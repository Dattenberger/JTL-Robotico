-- Regression test for reset.spPub_CancelResetRequest 'running' branch (F-1).
-- Run FROM this directory so the guard include resolves:
--   cd db-migrations/tests/global
--   sqlcmd -S <server> -U sa -C -b -d RoboticoOps -i ResetCancelRunning_Tests.sql
--
-- Scenario T2-54 (force-reclaim of a 'running' request while the reset Agent job is NOT
-- executing). The 'running' branch probes msdb.dbo.sysjobactivity+sysjobs+syssessions; under
-- the signed EXECUTE-AS-'jobstartuser' context, jobstartuser's SQLAgentOperatorRole does NOT
-- carry cross-DB, so that probe was denied (Msg 229) BEFORE the 51007 guard and the cancel was
-- dead. permissions/255 grants those three SELECTs directly to jobstartuser.
--   ROT  : EXEC raises Msg 229 (SELECT denied on 'syssessions'); request stays 'running'.
--   GRUEN: EXEC succeeds; the request is force-reclaimed 'running' -> 'failed'.
--
-- Self-cleaning: removes its own tm97 rows at start and end. Nothing else is touched.
-- @see db-migrations/global/permissions/255_reset_cancel_msdb_grants.sql
-- @see db-migrations/global/sprocs/reset.spPub_CancelResetRequest.sql
:r ../_e2e_guard.sql
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
GO

PRINT '============================================================================';
PRINT 'reset.spPub_CancelResetRequest - running-branch regression (F-1)';
PRINT '============================================================================';
PRINT '';

DECLARE @passed INT = 0, @total INT = 2;

-- clean any leftover from a prior run
DELETE FROM ops.tResetRequest WHERE cMandantKey = N'tm97';
DELETE FROM ops.tMandant      WHERE cMandantKey = N'tm97';

INSERT INTO ops.tMandant (cMandantKey, cTargetDb, cDisplayName, cLoginName)
VALUES (N'tm97', N'eazybusiness_tm97', N'F-1 cancel test', NULL);
INSERT INTO ops.tResetRequest (cMandantKey, cTargetDb, cStatus, cRequestedBy, dStarted)
VALUES (N'tm97', N'eazybusiness_tm97', N'running', N'f1test', SYSUTCDATETIME());
DECLARE @rid INT = CAST(SCOPE_IDENTITY() AS INT);
PRINT '--- request ' + CAST(@rid AS NVARCHAR(10)) + ' set up as running ---';

DECLARE @errNo INT = NULL;
BEGIN TRY
    EXEC reset.spPub_CancelResetRequest @RequestId = @rid;
END TRY
BEGIN CATCH
    SET @errNo = ERROR_NUMBER();
    PRINT '  (EXEC raised Msg ' + CAST(@errNo AS NVARCHAR(10)) + ': ' + ERROR_MESSAGE() + ')';
END CATCH

-- Check 1: the msdb.syssessions probe must NOT be denied (F-1 regression).
IF @errNo IS NULL
BEGIN PRINT '  + cancel ran without a permission error (no Msg 229)'; SET @passed += 1; END
ELSE IF @errNo = 229
    PRINT '  x REGRESSION F-1: Msg 229 (SELECT denied on syssessions) — permissions/255 not applied?';
ELSE
    PRINT '  x unexpected Msg ' + CAST(@errNo AS NVARCHAR(10));

-- Check 2: with no active job run, the request is force-reclaimed to 'failed'.
DECLARE @status NVARCHAR(20) = (SELECT cStatus FROM ops.tResetRequest WHERE kResetRequest = @rid);
IF @status = N'failed'
BEGIN PRINT '  + running request force-reclaimed to failed'; SET @passed += 1; END
ELSE PRINT '  x expected status failed, got: ' + ISNULL(@status, 'NULL');

-- cleanup
DELETE FROM ops.tResetRequest WHERE cMandantKey = N'tm97';
DELETE FROM ops.tMandant      WHERE cMandantKey = N'tm97';

PRINT '';
PRINT '============================================================================';
IF @passed = @total
    PRINT 'ALL TESTS PASSED: ' + CAST(@passed AS NVARCHAR(5)) + '/' + CAST(@total AS NVARCHAR(5));
ELSE
    PRINT 'TESTS FAILED: ' + CAST(@passed AS NVARCHAR(5)) + '/' + CAST(@total AS NVARCHAR(5));
PRINT '============================================================================';
GO
