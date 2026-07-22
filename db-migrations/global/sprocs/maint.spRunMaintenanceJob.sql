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
-- @see docs/plans/2026-07-21 - mssql-wartung-ola (§3.2)
-- @see docs/decisions/0001-maintenance-as-code-roboticoops.md
CREATE OR ALTER PROCEDURE maint.spRunMaintenanceJob
    @cJobKey sysname
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @cOperation nvarchar(20), @cDatabases nvarchar(400), @bUpdateStatistics bit,
            @cCleanupTarget nvarchar(20), @nRetentionDays int,
            @nFullMaxHours int, @nLogMaxHours int;

    SELECT @cOperation = cOperation, @cDatabases = cDatabases,
           @bUpdateStatistics = bUpdateStatistics, @cCleanupTarget = cCleanupTarget,
           @nRetentionDays = nRetentionDays, @nFullMaxHours = nFullMaxHours,
           @nLogMaxHours = nLogMaxHours
    FROM ops.tMaintenanceJob
    WHERE cJobKey = @cJobKey;

    IF @cOperation IS NULL
        THROW 51120, N'maint.spRunMaintenanceJob: unknown @cJobKey — no such row in ops.tMaintenanceJob. The agent job and the registry have diverged; run maint.spEnsureMaintenanceJobs (or redeploy the global chain).', 1;

    DECLARE @dCutoff datetime;

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
END
GO
