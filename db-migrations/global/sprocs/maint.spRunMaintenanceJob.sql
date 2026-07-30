-- maint.spRunMaintenanceJob  (Ebene B / global — sprocs, anytime; job-only dispatcher)
--
-- Runtime dispatcher (D28): every maintenance agent job carries the CONSTANT step
--   EXECUTE RoboticoOps.maint.spRunMaintenanceJob @cJobKey = N'<key>';
-- This proc reads the ops.tMaintenanceJob row AT RUN TIME and passes cDatabases and
-- the typed knobs as REAL T-SQL parameters to the Ola / system procedures — no
-- dynamic SQL anywhere, data never becomes code (same logic as the ops.tResetStep
-- whitelist and the parameterless reset step). Registry changes to scope/knobs take
-- effect IMMEDIATELY after the MERGE, without a job drop/recreate — only
-- schedule/notify/name changes touch msdb (via maint.spEnsureMaintenanceJobs).
--
-- The command matrix below is the ONE home of command construction (plan §3.2).
--
-- ADDING A NEW OPERATION KIND is deliberately NOT "just a registry row":
--   1. new CK_tMaintenanceJob_cOperation value + (if needed) new knob columns — a NEW
--      up/ script (0023 is immutable);
--   2. a new CASE branch below;
--   3. doc rows in docs/SQL/MSSQL-OPS-DATA-MODEL.md (same-commit contract).
-- "Add a row" applies to new INSTANCES of existing operation kinds only (analog
-- README §9 for reset steps).
--
-- Cleanup cutoffs are computed AT RUN TIME (DATEADD(DAY, -@nRetentionDays,
-- SYSDATETIME())) — never a sync-time frozen date that would silently turn the
-- cleanup into a no-op over the years. SYSDATETIME (local) because CommandLog and
-- msdb history store local server time.
--
-- IndexOptimize on Standard Edition is REORGANIZE-only (D13): no ONLINE rebuild
-- available, and an OFFLINE rebuild at 02:00 would lock tables of a 24/7 ERP —
-- @FragmentationMedium/@FragmentationHigh are pinned to INDEX_REORGANIZE.
--
-- THROW allocation (README §4 (k)): 51120 = unknown/unsupported @cJobKey.
--
-- FAILURE-DETAIL MAIL (Befund 2026-07-30) — why this proc mails at all.
-- The SQL-Agent operator notification wired by maint.spEnsureMaintenanceJobs only ever
-- carries the agent's generic step status ("STATUS: Fehler … Zuletzt wurde Schritt 1
-- (Dispatch) ausgeführt"); the THROW text of OUR procedures — e.g. 51100 naming which
-- database has been without a backup for how long — never reaches the recipient, who then
-- knows THAT something broke but not WHAT. The dispatcher therefore sends its own detail
-- mail from the CATCH block and rethrows afterwards. The resulting DOUBLE mail per failure
-- is deliberate: the agent notification stays the delivery-guaranteed channel (it survives
-- a proc that cannot mail at all), this one carries the diagnosis.
--
--   * Language ENGLISH — the whole maint suite (comments, PRINTs, and above all the
--     ERROR_MESSAGE() texts quoted verbatim in the body) is English; a German frame around
--     English error text would read worse than one consistent language.
--   * The registry decides WHETHER to mail: bNotifyOnFail = 0 suppresses this alert exactly
--     as it suppresses the agent notification — one switch, both channels.
--   * Recipient + profile are resolved AT RUN TIME, never hard-coded here: the address
--     comes from the SQL-Agent operator (name = repo-owned policy from permissions/260,
--     which is also the single home of the address), the profile from the agent's own
--     Database-Mail profile / the default profile. Nothing resolvable => the mail is
--     skipped with a PRINT; a missing mail configuration must never turn into a second
--     failure on top of the first.
--   * ROBUSTNESS RULE: the mail may never swallow, delay or replace the original error.
--     The error facts are snapshotted into variables BEFORE the mail attempt, the whole
--     mail block sits in its own nested TRY/CATCH that discards every mail error, and the
--     rethrow is a bare `THROW;` (verified on SQL Server 2022: a nested CATCH does not
--     clobber the outer CATCH's error context — MaintenanceAlertMail_Tests.sql T1/T3a/T4a
--     guard exactly this).
--   * Known failure modes, accepted: (1) inside a doomed transaction (XACT_STATE() = -1)
--     the queue INSERT of sp_send_dbmail fails — we do NOT roll back someone else's
--     transaction to get a mail out, so the alert degrades to the agent notification;
--     (2) an unreachable SMTP relay only queues the item (msdb.dbo.sysmail_faileditems);
--     (3) a caller without DatabaseMailUserRole cannot resolve/send — same silent skip.
--
-- @see docs/plans/2026-07-21 - mssql-wartung-ola (§3.2)
-- @see docs/plans/2026-07-21 - mssql-wartung-ola/reports/alert-mail-detail-2026-07-30.md
-- @see docs/decisions/0001-maintenance-as-code-roboticoops.md
CREATE OR ALTER PROCEDURE maint.spRunMaintenanceJob
    @cJobKey sysname
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @cOperation nvarchar(20), @cDatabases nvarchar(400), @bUpdateStatistics bit,
            @cCleanupTarget nvarchar(20), @nRetentionDays int,
            @nFullMaxHours int, @nLogMaxHours int, @cDisplayName sysname,
            @bNotifyOnFail bit;

    DECLARE @dCutoff datetime;

    BEGIN TRY
        SELECT @cOperation = cOperation, @cDatabases = cDatabases,
               @bUpdateStatistics = bUpdateStatistics, @cCleanupTarget = cCleanupTarget,
               @nRetentionDays = nRetentionDays, @nFullMaxHours = nFullMaxHours,
               @nLogMaxHours = nLogMaxHours, @cDisplayName = cDisplayName,
               @bNotifyOnFail = bNotifyOnFail
        FROM ops.tMaintenanceJob
        WHERE cJobKey = @cJobKey;

        IF @cOperation IS NULL
            THROW 51120, N'maint.spRunMaintenanceJob: unknown @cJobKey — no such row in ops.tMaintenanceJob. The agent job and the registry have diverged; run maint.spEnsureMaintenanceJobs (or redeploy the global chain).', 1;

        IF @cOperation = N'IntegrityCheck'
            EXECUTE RoboticoOps.dbo.DatabaseIntegrityCheck
                @Databases = @cDatabases,
                @LogToTable = 'Y';

        ELSE IF @cOperation = N'IndexOptimize'
        BEGIN
            IF @bUpdateStatistics = 1
                EXECUTE RoboticoOps.dbo.IndexOptimize
                    @Databases = @cDatabases,
                    @UpdateStatistics = 'ALL',          -- the F7/F8 core lever (D33)
                    @FragmentationMedium = 'INDEX_REORGANIZE',
                    @FragmentationHigh = 'INDEX_REORGANIZE',   -- REORGANIZE-only (D13)
                    @LogToTable = 'Y';
            ELSE
                -- bUpdateStatistics = 0 is the deliberate exception: the parameter is
                -- omitted entirely (Ola default = no statistics maintenance).
                -- NB (L-B1-3): a stats-off IndexOptimize has NO guaranteed per-run CommandLog
                -- heartbeat (no UPDATE_STATISTICS rows; ALTER_INDEX only above the reorg
                -- threshold) — revisit maint.spCheckMaintenanceLiveness before enabling such a row.
                EXECUTE RoboticoOps.dbo.IndexOptimize
                    @Databases = @cDatabases,
                    @FragmentationMedium = 'INDEX_REORGANIZE',
                    @FragmentationHigh = 'INDEX_REORGANIZE',
                    @LogToTable = 'Y';
        END

        ELSE IF @cOperation = N'Cleanup' AND @cCleanupTarget = N'CommandLog'
            -- No Ola proc for this — plain retention delete on our own vendored table.
            DELETE RoboticoOps.dbo.CommandLog
            WHERE StartTime < DATEADD(DAY, -@nRetentionDays, SYSDATETIME());

        ELSE IF @cOperation = N'Cleanup' AND @cCleanupTarget = N'BackupHistory'
        BEGIN
            SET @dCutoff = DATEADD(DAY, -@nRetentionDays, SYSDATETIME());
            EXECUTE msdb.dbo.sp_delete_backuphistory @oldest_date = @dCutoff;
        END

        ELSE IF @cOperation = N'Cleanup' AND @cCleanupTarget = N'JobHistory'
        BEGIN
            SET @dCutoff = DATEADD(DAY, -@nRetentionDays, SYSDATETIME());
            EXECUTE msdb.dbo.sp_purge_jobhistory @oldest_date = @dCutoff;
        END

        ELSE IF @cOperation = N'BackupWatchdog'
        BEGIN
            -- A THROW of the first check ends the step: one alarm per run, the next
            -- hourly run reports the rest (D36).
            EXECUTE RoboticoOps.maint.spCheckBackupChain
                @Databases = @cDatabases,
                @FullMaxHours = @nFullMaxHours,
                @LogMaxHours = @nLogMaxHours;
            EXECUTE RoboticoOps.maint.spCheckMaintenanceLiveness;
        END

        ELSE
            -- Defensive: cOperation/cCleanupTarget are CHECK-constrained, so this branch
            -- is only reachable when a new operation kind was added to the table without
            -- its CASE branch here (the recipe in the header).
            THROW 51120, N'maint.spRunMaintenanceJob: registry row has an operation/target combination this dispatcher has no branch for — follow the new-operation recipe in the proc header.', 1;
    END TRY
    BEGIN CATCH
        -- Step 1 — snapshot the error FIRST. Everything below is best-effort; only these
        -- variables are guaranteed to still describe the original failure afterwards.
        DECLARE @nErrNumber   int            = ERROR_NUMBER(),
                @nErrSeverity int            = ERROR_SEVERITY(),
                @nErrState    int            = ERROR_STATE(),
                @cErrProc     nvarchar(200)  = ISNULL(ERROR_PROCEDURE(), N'(ad-hoc batch)'),
                @nErrLine     int            = ERROR_LINE(),
                @cErrMessage  nvarchar(4000) = ERROR_MESSAGE();

        -- Step 2 — best-effort detail mail. Every failure in here is discarded (PRINT only):
        -- a broken mail configuration must never mask the maintenance failure itself.
        BEGIN TRY
            -- Recipient: the operator is repo-owned policy (name AND address live in
            -- permissions/260) — resolved here, never a second copy of the address.
            DECLARE @cRecipients nvarchar(200) =
                (SELECT NULLIF(LTRIM(RTRIM(email_address)), N'')
                 FROM msdb.dbo.sysoperators
                 WHERE name = N'RoboticoOps-Maint' AND enabled = 1);

            -- Profile, in the order that best matches how the agent itself would mail:
            --   1. the agent's own Database-Mail profile (registry; sysadmin-only read, and
            --      the job runs as sa — the IS_SRVROLEMEMBER guard keeps a non-sysadmin
            --      caller from turning a permission error into a skipped mail),
            --   2. the default profile (private before public),
            --   3. the only profile on the instance.
            DECLARE @cProfile sysname = NULL, @cAgentProfile nvarchar(256) = NULL;

            IF IS_SRVROLEMEMBER('sysadmin') = 1
            BEGIN
                -- Own TRY/CATCH: on a platform where the registry shim is unavailable the
                -- read must cost us only THIS resolution step, not the whole mail.
                BEGIN TRY
                    EXEC master.dbo.xp_instance_regread
                         N'HKEY_LOCAL_MACHINE',
                         N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent',
                         N'DatabaseMailProfile',
                         @cAgentProfile OUTPUT,
                         N'no_output';
                END TRY
                BEGIN CATCH
                    SET @cAgentProfile = NULL;
                END CATCH
                SET @cProfile = (SELECT name FROM msdb.dbo.sysmail_profile WHERE name = @cAgentProfile);
            END

            IF @cProfile IS NULL
                SELECT TOP (1) @cProfile = p.name
                FROM msdb.dbo.sysmail_profile p
                JOIN msdb.dbo.sysmail_principalprofile pp ON pp.profile_id = p.profile_id
                WHERE pp.is_default = 1
                  AND pp.principal_sid IN (SUSER_SID(), 0x00)   -- 0x00 = the public profile
                ORDER BY CASE WHEN pp.principal_sid = 0x00 THEN 1 ELSE 0 END, p.name;

            IF @cProfile IS NULL AND (SELECT COUNT(*) FROM msdb.dbo.sysmail_profile) = 1
                SET @cProfile = (SELECT name FROM msdb.dbo.sysmail_profile);

            -- The registry stays the single source of truth for "who gets told": a row with
            -- bNotifyOnFail = 0 has no agent notification wired either (see
            -- maint.spEnsureMaintenanceJobs), and this mail must not quietly re-introduce
            -- one. NULL (= no registry row at all) DOES mail — a job whose registry row
            -- vanished is exactly the divergence worth reporting.
            IF ISNULL(@bNotifyOnFail, 1) = 0
                PRINT '! maint.spRunMaintenanceJob: registry row has bNotifyOnFail = 0 — detail alert deliberately skipped.';
            ELSE IF @cRecipients IS NULL OR @cProfile IS NULL
                PRINT '! maint.spRunMaintenanceJob: no operator address or no Database-Mail profile resolvable — detail alert skipped (the agent notification still reports the failure).';
            ELSE
            BEGIN
                -- CONCAT (not '+') keeps the data-concat lint heuristic quiet and is
                -- NULL-safe: an unknown job key has no registry row to report.
                DECLARE @cSubject nvarchar(255) = CONCAT(
                    N'[RoboticoOps] Maintenance FAILED: ', @cJobKey,
                    N' on ', CONVERT(sysname, @@SERVERNAME));

                DECLARE @cBody nvarchar(max) = CONCAT(
                    N'Maintenance job "', @cJobKey, N'" failed on ', CONVERT(sysname, @@SERVERNAME),
                    N' at ', CONVERT(nvarchar(19), SYSDATETIME(), 120), N' (server local time).',
                    NCHAR(13), NCHAR(10), NCHAR(13), NCHAR(10),
                    N'Error   : ', @nErrNumber, N' (severity ', @nErrSeverity, N', state ', @nErrState, N')',
                    NCHAR(13), NCHAR(10),
                    N'Source  : ', @cErrProc, N', line ', @nErrLine,
                    NCHAR(13), NCHAR(10),
                    N'Message : ', @cErrMessage,
                    NCHAR(13), NCHAR(10), NCHAR(13), NCHAR(10),
                    N'Registry (RoboticoOps.ops.tMaintenanceJob):',
                    NCHAR(13), NCHAR(10),
                    N'  Job key   : ', @cJobKey,
                    NCHAR(13), NCHAR(10),
                    N'  Operation : ', ISNULL(@cOperation, N'(no registry row for this job key)'),
                    CASE WHEN @cCleanupTarget IS NULL THEN N'' ELSE CONCAT(N' / ', @cCleanupTarget) END,
                    NCHAR(13), NCHAR(10),
                    N'  Target(s) : ', ISNULL(@cDatabases, N'(unknown)'),
                    NCHAR(13), NCHAR(10),
                    N'  Agent job : ', ISNULL(@cDisplayName, N'(none — registry and job have diverged)'),
                    NCHAR(13), NCHAR(10), NCHAR(13), NCHAR(10),
                    N'Where to look next:',
                    NCHAR(13), NCHAR(10),
                    N'  * Agent job history (step 1 "Dispatch") of the job named above',
                    NCHAR(13), NCHAR(10),
                    N'  * SELECT * FROM RoboticoOps.ops.tMaintenanceJob WHERE cJobKey = N''', @cJobKey, N''';',
                    NCHAR(13), NCHAR(10),
                    N'  * SELECT TOP (50) * FROM RoboticoOps.dbo.CommandLog ORDER BY ID DESC;   -- Ola command log',
                    NCHAR(13), NCHAR(10), NCHAR(13), NCHAR(10),
                    N'Sent by maint.spRunMaintenanceJob. The SQL-Agent operator notification for the',
                    NCHAR(13), NCHAR(10),
                    N'same failure arrives separately and carries only the generic step status.');

                EXEC msdb.dbo.sp_send_dbmail
                     @profile_name = @cProfile,
                     @recipients   = @cRecipients,
                     @subject      = @cSubject,
                     @body         = @cBody;
            END
        END TRY
        BEGIN CATCH
            PRINT '! maint.spRunMaintenanceJob: failure-alert mail could not be sent ('
                + ERROR_MESSAGE() + ') — the original error is rethrown unchanged below.';
        END CATCH;   -- the semicolon is REQUIRED: THROW needs a terminated predecessor

        -- Step 3 — the original error, unchanged: the job step must stay red and the agent
        -- notification must still fire. A bare THROW keeps number, severity, state and text
        -- (a rethrow with explicit values could not carry engine errors below 50000 at all).
        THROW;
    END CATCH
END
GO
