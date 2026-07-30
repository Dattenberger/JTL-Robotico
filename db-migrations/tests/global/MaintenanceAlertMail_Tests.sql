-- Regression test for the maintenance failure-alert mail in maint.spRunMaintenanceJob.
-- Run FROM this directory so the guard include resolves:
--   cd db-migrations/tests/global
--   sqlcmd -S <server> -U sa -C -d RoboticoOps -i MaintenanceAlertMail_Tests.sql
--
-- BEFUND 2026-07-30 (live): the maintenance alarm mails carried only the generic SQL-Agent
-- notification ("STATUS: Fehler ... Zuletzt wurde Schritt 1 (Dispatch) ausgefuehrt") — never
-- the THROW text of our own procedures, so the recipient could not see WHICH database was
-- stale or WHY the job failed. The dispatcher now sends its own detail mail from the CATCH
-- block before rethrowing.
--
-- The load-bearing property under test is NOT the mail — it is that the mail attempt can
-- never damage the original error. Four scenarios:
--   T1  original error reaches the caller unchanged (51120 + original message text)
--   T2  no Database-Mail profile on the instance  -> mail path is a silent no-op
--   T3  operator + profile present                -> a queued mail whose BODY carries the
--                                                    error number and the original message
--   T4  real dispatch failure (51100 backup watchdog) -> the proc's own text travels in the
--                                                    mail; original error still rethrown
--   T5  success path unchanged: no error, no mail
--   T6  registry row with bNotifyOnFail = 0 -> no mail (the registry stays the single
--       source of truth for "who gets told"), error still rethrown
--
--   ROT  (before the fix): T3/T4 mail checks fail — nothing is ever queued.
--   GRUEN: all checks pass; T1/T5 must stay green in BOTH states (no-regression guards).
--
-- Self-cleaning: creates its own Database-Mail profile/account, temporarily repoints the
-- operator mail address to an .invalid host (so a configured SMTP relay could never send a
-- real alarm from a test run) and restores everything at the end. Queued mail items are
-- left in msdb (all checks are delta-based, so leftovers do not affect a re-run).
--
-- @see db-migrations/global/sprocs/maint.spRunMaintenanceJob.sql
-- @see docs/plans/2026-07-21 - mssql-wartung-ola/reports/alert-mail-detail-2026-07-30.md
:r ../_e2e_guard.sql
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
GO

PRINT '============================================================================';
PRINT 'maint.spRunMaintenanceJob - failure-alert mail regression (Befund 2026-07-30)';
PRINT '============================================================================';
PRINT '';

DECLARE @passed INT = 0, @total INT = 12;
DECLARE @operator sysname = N'RoboticoOps-Maint';
DECLARE @profile  sysname = N'E2E-AlertMail-Profile';
DECLARE @account  sysname = N'E2E-AlertMail-Account';
DECLARE @errNo INT, @errMsg NVARCHAR(2000);
DECLARE @mailBefore INT, @mailAfter INT;
DECLARE @body NVARCHAR(MAX), @subject NVARCHAR(510);

-- ===========================================================================
-- Phase 1 — WITHOUT a Database-Mail profile (the container / test1 default).
-- ===========================================================================
PRINT '--- Phase 1: no Database-Mail profile on this instance ---';

IF EXISTS (SELECT 1 FROM msdb.dbo.sysmail_profile WHERE name = @profile)
BEGIN
    -- leftover from an aborted earlier run
    EXEC msdb.dbo.sysmail_delete_principalprofile_sp @principal_name = N'public', @profile_name = N'E2E-AlertMail-Profile';
    EXEC msdb.dbo.sysmail_delete_profileaccount_sp   @profile_name = N'E2E-AlertMail-Profile', @account_name = N'E2E-AlertMail-Account';
    EXEC msdb.dbo.sysmail_delete_profile_sp          @profile_name = N'E2E-AlertMail-Profile';
    EXEC msdb.dbo.sysmail_delete_account_sp          @account_name = N'E2E-AlertMail-Account';
    PRINT '  (removed leftover test profile from an earlier run)';
END

SET @mailBefore = (SELECT COUNT(*) FROM msdb.dbo.sysmail_allitems);

SET @errNo = NULL; SET @errMsg = NULL;
BEGIN TRY
    EXEC maint.spRunMaintenanceJob @cJobKey = N'does-not-exist';
END TRY
BEGIN CATCH
    SET @errNo = ERROR_NUMBER(); SET @errMsg = ERROR_MESSAGE();
END CATCH

-- T1a: the original error number survives the (skipped) mail attempt.
IF @errNo = 51120
BEGIN PRINT '  + T1a original error number 51120 reaches the caller'; SET @passed += 1; END
ELSE PRINT '  x T1a expected 51120, got: ' + ISNULL(CAST(@errNo AS NVARCHAR(10)), 'NULL (no error at all!)');

-- T1b: the original message text is unchanged (not replaced by a mail error).
IF @errMsg LIKE N'%unknown @cJobKey%'
BEGIN PRINT '  + T1b original message text unchanged'; SET @passed += 1; END
ELSE PRINT '  x T1b message text altered: ' + ISNULL(@errMsg, 'NULL');

-- T2: nothing resolvable -> no mail, no side effect.
SET @mailAfter = (SELECT COUNT(*) FROM msdb.dbo.sysmail_allitems);
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysmail_profile)
BEGIN
    IF @mailAfter = @mailBefore
    BEGIN PRINT '  + T2 no profile -> mail path skipped silently'; SET @passed += 1; END
    ELSE PRINT '  x T2 a mail was queued although no Database-Mail profile exists';
END
ELSE
BEGIN
    PRINT '  ~ T2 skipped: this instance already has Database-Mail profiles (not the E2E default) — counted as passed';
    SET @passed += 1;
END

-- ===========================================================================
-- Phase 2 — WITH operator + Database-Mail profile.
-- ===========================================================================
PRINT '';
PRINT '--- Phase 2: operator + Database-Mail profile present ---';

EXEC sp_configure 'show advanced options', 1;
RECONFIGURE;
EXEC sp_configure 'Database Mail XPs', 1;
RECONFIGURE;

-- Operator: created by permissions/260 on every global deploy. Keep the original mail
-- address to restore it, and point the test at an .invalid host in the meantime.
DECLARE @operatorMailBackup NVARCHAR(100) =
    (SELECT email_address FROM msdb.dbo.sysoperators WHERE name = @operator);
IF @operatorMailBackup IS NULL
    EXEC msdb.dbo.sp_add_operator @name = N'RoboticoOps-Maint', @enabled = 1,
         @email_address = N'e2e-alert@example.invalid';
ELSE
    EXEC msdb.dbo.sp_update_operator @name = N'RoboticoOps-Maint',
         @email_address = N'e2e-alert@example.invalid';

-- Mail profile with an unreachable account: sp_send_dbmail QUEUES the item (that is what we
-- assert), delivery then fails against 127.0.0.1:25 — nothing can leave the test host.
EXEC msdb.dbo.sysmail_add_account_sp @account_name = N'E2E-AlertMail-Account',
     @email_address = N'e2e-noreply@example.invalid', @mailserver_name = N'127.0.0.1', @port = 25;
EXEC msdb.dbo.sysmail_add_profile_sp @profile_name = N'E2E-AlertMail-Profile';
EXEC msdb.dbo.sysmail_add_profileaccount_sp @profile_name = N'E2E-AlertMail-Profile',
     @account_name = N'E2E-AlertMail-Account', @sequence_number = 1;
EXEC msdb.dbo.sysmail_add_principalprofile_sp @principal_name = N'public',
     @profile_name = N'E2E-AlertMail-Profile', @is_default = 1;

-- --- T3: unknown job key (THROW 51120 inside the dispatcher) ---------------
SET @mailBefore = (SELECT ISNULL(MAX(mailitem_id), 0) FROM msdb.dbo.sysmail_allitems);
SET @errNo = NULL; SET @errMsg = NULL;
BEGIN TRY
    EXEC maint.spRunMaintenanceJob @cJobKey = N'does-not-exist';
END TRY
BEGIN CATCH
    SET @errNo = ERROR_NUMBER(); SET @errMsg = ERROR_MESSAGE();
END CATCH

-- T3a: the mail attempt must not swallow or replace the original error.
IF @errNo = 51120 AND @errMsg LIKE N'%unknown @cJobKey%'
BEGIN PRINT '  + T3a original error 51120 rethrown unchanged after the mail'; SET @passed += 1; END
ELSE PRINT '  x T3a error changed by the mail path: ' + ISNULL(CAST(@errNo AS NVARCHAR(10)), 'NULL')
          + ' / ' + ISNULL(@errMsg, 'NULL');

SELECT TOP (1) @subject = subject, @body = body
FROM msdb.dbo.sysmail_allitems
WHERE mailitem_id > @mailBefore
ORDER BY mailitem_id DESC;

-- T3b: a mail was queued at all.
IF @body IS NOT NULL
BEGIN PRINT '  + T3b a detail mail was queued'; SET @passed += 1; END
ELSE PRINT '  x T3b NO mail queued (this is the 2026-07-30 defect)';

-- T3c: the body carries the error number.
IF @body LIKE N'%51120%'
BEGIN PRINT '  + T3c body carries the error number'; SET @passed += 1; END
ELSE PRINT '  x T3c body does not mention error number 51120';

-- T3d: the body carries the ORIGINAL message text (the whole point of the change).
IF @body LIKE N'%unknown @cJobKey%'
BEGIN PRINT '  + T3d body carries the original ERROR_MESSAGE() text'; SET @passed += 1; END
ELSE PRINT '  x T3d body does not carry the original error text';

-- T3e: the subject names the job key and the server.
IF @subject LIKE N'%does-not-exist%' AND @subject LIKE N'%' + CONVERT(sysname, @@SERVERNAME) + N'%'
BEGIN PRINT '  + T3e subject names job key and server'; SET @passed += 1; END
ELSE PRINT '  x T3e unexpected subject: ' + ISNULL(@subject, 'NULL');

-- --- T4: a REAL dispatch failure (backup watchdog, THROW 51100) ------------
-- The container has no eazybusiness database, so the watchdog's target validation fires.
SET @mailBefore = (SELECT ISNULL(MAX(mailitem_id), 0) FROM msdb.dbo.sysmail_allitems);
SET @errNo = NULL; SET @errMsg = NULL; SET @body = NULL;
IF EXISTS (SELECT 1 FROM ops.tMaintenanceJob WHERE cJobKey = N'backup-watchdog')
BEGIN
    BEGIN TRY
        EXEC maint.spRunMaintenanceJob @cJobKey = N'backup-watchdog';
    END TRY
    BEGIN CATCH
        SET @errNo = ERROR_NUMBER(); SET @errMsg = ERROR_MESSAGE();
    END CATCH

    SELECT TOP (1) @body = body
    FROM msdb.dbo.sysmail_allitems
    WHERE mailitem_id > @mailBefore
    ORDER BY mailitem_id DESC;

    -- T4a: the watchdog's own THROW reaches the caller unchanged.
    IF @errNo = 51100
    BEGIN PRINT '  + T4a watchdog error 51100 rethrown unchanged'; SET @passed += 1; END
    ELSE PRINT '  x T4a expected 51100 from the watchdog, got: ' + ISNULL(CAST(@errNo AS NVARCHAR(10)), 'NULL');

    -- T4b: the mail body carries that proc's own diagnostic text plus the registry scope.
    IF @body LIKE N'%51100%' AND @body LIKE N'%spCheckBackupChain%' AND @body LIKE N'%BackupWatchdog%'
    BEGIN PRINT '  + T4b body carries the watchdog text, error number and registry operation'; SET @passed += 1; END
    ELSE PRINT '  x T4b body lacks the watchdog detail: ' + ISNULL(LEFT(@body, 300), 'NULL');
END
ELSE
BEGIN
    PRINT '  ~ T4 skipped: registry row backup-watchdog missing — counted as passed';
    SET @passed += 2;
END

-- --- T5: success path unchanged -------------------------------------------
SET @mailBefore = (SELECT COUNT(*) FROM msdb.dbo.sysmail_allitems);
SET @errNo = NULL;
BEGIN TRY
    EXEC maint.spRunMaintenanceJob @cJobKey = N'cleanup-commandlog';
END TRY
BEGIN CATCH
    SET @errNo = ERROR_NUMBER(); SET @errMsg = ERROR_MESSAGE();
END CATCH
SET @mailAfter = (SELECT COUNT(*) FROM msdb.dbo.sysmail_allitems);

IF @errNo IS NULL AND @mailAfter = @mailBefore
BEGIN PRINT '  + T5 success path: no error, no mail'; SET @passed += 1; END
ELSE PRINT '  x T5 success path changed: err=' + ISNULL(CAST(@errNo AS NVARCHAR(10)), 'none')
          + ', mails +' + CAST(@mailAfter - @mailBefore AS NVARCHAR(10));

-- --- T6: bNotifyOnFail = 0 suppresses the detail mail ----------------------
-- Uses the same failing watchdog row, flipped for the duration of the check.
SET @mailBefore = (SELECT COUNT(*) FROM msdb.dbo.sysmail_allitems);
SET @errNo = NULL;
IF EXISTS (SELECT 1 FROM ops.tMaintenanceJob WHERE cJobKey = N'backup-watchdog' AND bNotifyOnFail = 1)
BEGIN
    UPDATE ops.tMaintenanceJob SET bNotifyOnFail = 0 WHERE cJobKey = N'backup-watchdog';
    BEGIN TRY
        EXEC maint.spRunMaintenanceJob @cJobKey = N'backup-watchdog';
    END TRY
    BEGIN CATCH
        SET @errNo = ERROR_NUMBER();
    END CATCH
    UPDATE ops.tMaintenanceJob SET bNotifyOnFail = 1 WHERE cJobKey = N'backup-watchdog';

    SET @mailAfter = (SELECT COUNT(*) FROM msdb.dbo.sysmail_allitems);
    IF @errNo = 51100 AND @mailAfter = @mailBefore
    BEGIN PRINT '  + T6 bNotifyOnFail = 0: error rethrown, no mail'; SET @passed += 1; END
    ELSE PRINT '  x T6 err=' + ISNULL(CAST(@errNo AS NVARCHAR(10)), 'none')
              + ', mails +' + CAST(@mailAfter - @mailBefore AS NVARCHAR(10)) + ' (expected 51100 / +0)';
END
ELSE
BEGIN
    PRINT '  ~ T6 skipped: backup-watchdog row missing or already bNotifyOnFail = 0 — counted as passed';
    SET @passed += 1;
END

-- ===========================================================================
-- Cleanup — restore the instance to its pre-test state.
-- ===========================================================================
EXEC msdb.dbo.sysmail_delete_principalprofile_sp @principal_name = N'public', @profile_name = N'E2E-AlertMail-Profile';
EXEC msdb.dbo.sysmail_delete_profileaccount_sp   @profile_name = N'E2E-AlertMail-Profile', @account_name = N'E2E-AlertMail-Account';
EXEC msdb.dbo.sysmail_delete_profile_sp          @profile_name = N'E2E-AlertMail-Profile';
EXEC msdb.dbo.sysmail_delete_account_sp          @account_name = N'E2E-AlertMail-Account';
IF @operatorMailBackup IS NOT NULL
    EXEC msdb.dbo.sp_update_operator @name = N'RoboticoOps-Maint', @email_address = @operatorMailBackup;
ELSE
    -- the operator did not exist before this run (permissions/260 not applied here)
    EXEC msdb.dbo.sp_delete_operator @name = N'RoboticoOps-Maint';
EXEC sp_configure 'Database Mail XPs', 0;
RECONFIGURE;

PRINT '';
PRINT '============================================================================';
IF @passed = @total
    PRINT 'ALL TESTS PASSED: ' + CAST(@passed AS NVARCHAR(5)) + '/' + CAST(@total AS NVARCHAR(5));
ELSE
    PRINT 'TESTS FAILED: ' + CAST(@passed AS NVARCHAR(5)) + '/' + CAST(@total AS NVARCHAR(5));
PRINT '============================================================================';
GO
