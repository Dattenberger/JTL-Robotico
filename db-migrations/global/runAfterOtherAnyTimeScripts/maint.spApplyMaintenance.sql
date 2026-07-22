-- maint.spApplyMaintenance  (Ebene B / global — runAfterOtherAnyTimeScripts, anytime)
--
-- Self-executing wrapper (pattern reset.spEnsureAgentJob): (a) value-guarded MERGE of
-- the desired maintenance-registry rows (plan §3.2 table = SSoT) into
-- ops.tMaintenanceJob, (b) EXEC maint.spEnsureMaintenanceJobs. Runs in grate's last
-- anytime stage, after all sprocs exist — but BEFORE permissions/, so first-deploy
-- operator wiring is pulled in afterwards by permissions/260 (D29).
--
-- THE MAINTENANCE REGISTRY IS REPO-OWNED — deliberate deviation from ops.tResetStep.
-- The MERGE enforces ALL desired columns on every deploy (incl. bEnabled, times,
-- thresholds): live edits to the table are overwritten on the next deploy.
-- Maintenance tuning goes EXCLUSIVELY through git + deploy (full traceability was the
-- requirement, D11), while ops.tResetStep deliberately lets admin tuning win (seed is
-- insert-new-only, QG3 B12).
--
-- WHY a MERGE although up/0021 deliberately seeds row-by-row (QG3 B12): the B12
-- collision arose from live re-ordering of ADMIN-owned rows under a UNIQUE
-- constraint; this registry is repo-owned with stable keys (cJobKey, cDisplayName)
-- and no admin re-ordering — the collision situation does not exist here. (Conscious,
-- documented deviation from the 0021 decision.)
--
-- MERGE mechanics (D30): the WHEN MATCHED guard compares every desired column
-- NULL-SAFE via IS DISTINCT FROM — six desired columns are NULLable; with <> a pure
-- NULL<->value change would be silently swallowed (deploy reports no-op, git and live
-- diverge). Unchanged rows are NOT touched -> no dModified churn, a real no-op for
-- AC7, and dModified stays usable as an audit signal (set explicitly on UPDATE —
-- SQL Server has no ON-UPDATE default). WHEN NOT MATCHED BY SOURCE THEN DELETE:
-- rows removed from this seed disappear from the live registry, and the subsequent
-- ensure removes the job in the same deploy (AC3 removal path). Safe because the
-- registry is fully repo-owned — there are no foreign rows to protect.
--
-- @see docs/plans/2026-07-21 - mssql-wartung-ola (§3.3)
-- @see docs/decisions/0001-maintenance-as-code-roboticoops.md
CREATE OR ALTER PROCEDURE maint.spApplyMaintenance
AS
BEGIN
    SET NOCOUNT ON;

    -- Desired rows (plan §3.2 = SSoT; display name = prefix + cJobKey).
    WITH src AS (
        SELECT * FROM (VALUES
            (N'checkdb',              N'RoboticoOps - Maint - checkdb',              N'IntegrityCheck', N'ALL_DATABASES, -eazybusiness_tm%', N'weekly', CONVERT(tinyint, 9),    CONVERT(time(0), '01:00'), CONVERT(bit, NULL), CONVERT(nvarchar(20), NULL), CONVERT(int, NULL), CONVERT(int, NULL), CONVERT(int, NULL), CONVERT(bit, 1), CONVERT(bit, 1), N'CHECKDB all DBs incl. system, excl. tm clones; Sun+Wed before the 03:00 full'),
            (N'index-optimize',       N'RoboticoOps - Maint - index-optimize',       N'IndexOptimize',  N'USER_DATABASES',                   N'daily',  CONVERT(tinyint, NULL), CONVERT(time(0), '02:00'), CONVERT(bit, 1),    CONVERT(nvarchar(20), NULL), CONVERT(int, NULL), CONVERT(int, NULL), CONVERT(int, NULL), CONVERT(bit, 1), CONVERT(bit, 1), N'Defrag (REORGANIZE-only, D13) + statistics ALL — incl. tm clones (worked on interactively)'),
            (N'cleanup-commandlog',   N'RoboticoOps - Maint - cleanup-commandlog',   N'Cleanup',        N'RoboticoOps',                      N'weekly', CONVERT(tinyint, 1),    CONVERT(time(0), '00:30'), CONVERT(bit, NULL), N'CommandLog',               CONVERT(int, 365),  CONVERT(int, NULL), CONVERT(int, NULL), CONVERT(bit, 1), CONVERT(bit, 1), N'dbo.CommandLog retention 365 days'),
            (N'cleanup-backuphistory', N'RoboticoOps - Maint - cleanup-backuphistory', N'Cleanup',      N'msdb',                             N'weekly', CONVERT(tinyint, 1),    CONVERT(time(0), '00:35'), CONVERT(bit, NULL), N'BackupHistory',            CONVERT(int, 365),  CONVERT(int, NULL), CONVERT(int, NULL), CONVERT(bit, 1), CONVERT(bit, 1), N'msdb backup history retention 365 days'),
            (N'cleanup-jobhistory',   N'RoboticoOps - Maint - cleanup-jobhistory',   N'Cleanup',        N'msdb',                             N'weekly', CONVERT(tinyint, 1),    CONVERT(time(0), '00:40'), CONVERT(bit, NULL), N'JobHistory',               CONVERT(int, 365),  CONVERT(int, NULL), CONVERT(int, NULL), CONVERT(bit, 1), CONVERT(bit, 1), N'msdb job history retention 365 days (needs raised agent history limit, D38)'),
            (N'backup-watchdog',      N'RoboticoOps - Maint - backup-watchdog',      N'BackupWatchdog', N'eazybusiness,RoboticoOps,msdb',    N'hourly', CONVERT(tinyint, NULL), CONVERT(time(0), '00:00'), CONVERT(bit, NULL), CONVERT(nvarchar(20), NULL), CONVERT(int, NULL), CONVERT(int, 26),   CONVERT(int, 1),    CONVERT(bit, 1), CONVERT(bit, 1), N'CBB chain freshness (literal DB list, D32) + maintenance liveness (D36); hourly (D35)')
        ) v (cJobKey, cDisplayName, cOperation, cDatabases, cFrequency, nWeekdayMask,
             tStartTime, bUpdateStatistics, cCleanupTarget, nRetentionDays,
             nFullMaxHours, nLogMaxHours, bEnabled, bNotifyOnFail, cNotes)
    )
    MERGE ops.tMaintenanceJob AS tgt
    USING src ON tgt.cJobKey = src.cJobKey
    WHEN MATCHED AND (
           tgt.cDisplayName      IS DISTINCT FROM src.cDisplayName
        OR tgt.cOperation        IS DISTINCT FROM src.cOperation
        OR tgt.cDatabases        IS DISTINCT FROM src.cDatabases
        OR tgt.cFrequency        IS DISTINCT FROM src.cFrequency
        OR tgt.nWeekdayMask      IS DISTINCT FROM src.nWeekdayMask
        OR tgt.tStartTime        IS DISTINCT FROM src.tStartTime
        OR tgt.bUpdateStatistics IS DISTINCT FROM src.bUpdateStatistics
        OR tgt.cCleanupTarget    IS DISTINCT FROM src.cCleanupTarget
        OR tgt.nRetentionDays    IS DISTINCT FROM src.nRetentionDays
        OR tgt.nFullMaxHours     IS DISTINCT FROM src.nFullMaxHours
        OR tgt.nLogMaxHours      IS DISTINCT FROM src.nLogMaxHours
        OR tgt.bEnabled          IS DISTINCT FROM src.bEnabled
        OR tgt.bNotifyOnFail     IS DISTINCT FROM src.bNotifyOnFail
        OR tgt.cNotes            IS DISTINCT FROM src.cNotes)
    THEN UPDATE SET
        tgt.cDisplayName      = src.cDisplayName,
        tgt.cOperation        = src.cOperation,
        tgt.cDatabases        = src.cDatabases,
        tgt.cFrequency        = src.cFrequency,
        tgt.nWeekdayMask      = src.nWeekdayMask,
        tgt.tStartTime        = src.tStartTime,
        tgt.bUpdateStatistics = src.bUpdateStatistics,
        tgt.cCleanupTarget    = src.cCleanupTarget,
        tgt.nRetentionDays    = src.nRetentionDays,
        tgt.nFullMaxHours     = src.nFullMaxHours,
        tgt.nLogMaxHours      = src.nLogMaxHours,
        tgt.bEnabled          = src.bEnabled,
        tgt.bNotifyOnFail     = src.bNotifyOnFail,
        tgt.cNotes            = src.cNotes,
        tgt.dModified         = SYSUTCDATETIME()
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (cJobKey, cDisplayName, cOperation, cDatabases, cFrequency, nWeekdayMask,
                tStartTime, bUpdateStatistics, cCleanupTarget, nRetentionDays,
                nFullMaxHours, nLogMaxHours, bEnabled, bNotifyOnFail, cNotes)
        VALUES (src.cJobKey, src.cDisplayName, src.cOperation, src.cDatabases,
                src.cFrequency, src.nWeekdayMask, src.tStartTime, src.bUpdateStatistics,
                src.cCleanupTarget, src.nRetentionDays, src.nFullMaxHours,
                src.nLogMaxHours, src.bEnabled, src.bNotifyOnFail, src.cNotes)
    WHEN NOT MATCHED BY SOURCE THEN DELETE;   -- removed seed row => removed live row (+job, via ensure)

    EXEC maint.spEnsureMaintenanceJobs;
END
GO

-- Apply on every deploy where this file's hash changed. The ensure call itself is
-- additionally run unconditionally on EVERY deploy by permissions/260 (D29 self-heal).
EXEC maint.spApplyMaintenance;
GO
