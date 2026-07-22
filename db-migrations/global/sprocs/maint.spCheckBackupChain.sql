-- maint.spCheckBackupChain  (Ebene B / global — sprocs, anytime; read-only watchdog)
--
-- Backup-chain freshness watchdog over msdb.dbo.backupset (ADR-B: backups stay with
-- CBB — this proc only WATCHES the chain, it never takes a backup). Called hourly by
-- the backup-watchdog job via maint.spRunMaintenanceJob (D35).
--
-- "Alarm" = THROW 51100 -> the job step fails -> NotifyOperator mail (the same
-- reporting path as every maintenance job). Threshold semantics: alarm at
-- age >= threshold (the boundary case alarms, AC5).
--
-- @Databases is a LITERAL comma list (STRING_SPLIT + TRIM) — NOT an Ola @Databases
-- expression. Target validation (D32): every token without an ONLINE match in
-- sys.databases (typo, whitespace rest, OFFLINE/RESTORING db, an accidental Ola token
-- like USER_DATABASES) also THROWs 51100 with the token in the message — an unknown
-- watch target is an ALARM, never a silent skip (otherwise an unwatched production DB
-- would be indistinguishable from a green job — the watchdog variant of the F2
-- pattern).
--
-- GOTCHA — local time base (D32): backupset.backup_finish_date stores LOCAL server
-- time, so age comparisons use SYSDATETIME(), NEVER SYSUTCDATETIME() — even though
-- the rest of this design uses SYSUTCDATETIME() throughout. At CEST/UTC+2 the UTC
-- grab would silently widen the 1-hour log threshold to ~3 hours.
--
-- Log freshness is checked for ALL log-based recovery models:
-- recovery_model_desc <> 'SIMPLE' covers FULL and BULK_LOGGED (D27; SIMPLE dbs have
-- no log chain by construction — checking them would be a permanent false alarm).
-- Fulls are filtered is_copy_only = 0 (a copy-only full does not anchor the chain).
--
-- THROW allocation (README §4 (k)): 51100 = stale chain AND invalid watch target.
--
-- @see docs/plans/2026-07-21 - mssql-wartung-ola (§3.2)
-- @see docs/decisions/0002-backups-cbb-retained.md
CREATE OR ALTER PROCEDURE maint.spCheckBackupChain
    @Databases    nvarchar(400),
    @FullMaxHours int,
    @LogMaxHours  int
AS
BEGIN
    SET NOCOUNT ON;

    -- Parse the literal comma list; TRIM each token (D32).
    DECLARE @tTarget TABLE (cDbName sysname NOT NULL PRIMARY KEY);
    INSERT INTO @tTarget (cDbName)
    SELECT DISTINCT TRIM(value)
    FROM STRING_SPLIT(@Databases, N',')
    WHERE TRIM(value) <> N'';

    -- Target validation (D32): unknown / non-ONLINE targets are an alarm, not a skip.
    DECLARE @cBadTargets nvarchar(1000) =
        (SELECT STRING_AGG(t.cDbName, N', ')
         FROM @tTarget t
         WHERE NOT EXISTS (SELECT 1 FROM sys.databases d
                           WHERE d.name = t.cDbName AND d.state_desc = N'ONLINE'));
    IF @cBadTargets IS NOT NULL
    BEGIN
        DECLARE @cMsgTargets nvarchar(2000) = N'maint.spCheckBackupChain: invalid watch target(s) — no ONLINE database match for: '
            + @cBadTargets + N'. Ola tokens (e.g. USER_DATABASES) are invalid here; the watchdog takes a literal comma list.';
        THROW 51100, @cMsgTargets, 1;
    END

    -- Freshness (local time base, D32; age >= threshold alarms, boundary included, D27/AC5).
    -- Age test is an ELAPSED-time cutoff (dLast <= now - threshold), NOT DATEDIFF(HOUR, ...):
    -- DATEDIFF(HOUR) counts clock-hour boundaries crossed, not elapsed hours, so a log backup
    -- only minutes old but in the previous clock-hour would score 1 >= 1 and false-alarm on the
    -- hourly cadence (nLogMaxHours=1). Mirrors the DATEADD cutoff in spCheckMaintenanceLiveness.
    DECLARE @dNow datetime2(0) = SYSDATETIME();
    DECLARE @tProblem TABLE (cProblem nvarchar(300) NOT NULL);

    -- Full: newest non-copy-only full per target.
    INSERT INTO @tProblem (cProblem)
    SELECT t.cDbName + N': last FULL '
         + ISNULL(CONVERT(nvarchar(19), f.dLastFull, 120), N'NEVER')
         + N' (max ' + CONVERT(nvarchar(10), @FullMaxHours) + N'h)'
    FROM @tTarget t
    OUTER APPLY (SELECT MAX(bs.backup_finish_date) AS dLastFull
                 FROM msdb.dbo.backupset bs
                 WHERE bs.database_name = t.cDbName
                   AND bs.type = 'D'
                   AND bs.is_copy_only = 0) f
    WHERE f.dLastFull IS NULL
       OR f.dLastFull <= DATEADD(HOUR, -@FullMaxHours, @dNow);

    -- Log: only log-based recovery models (<> SIMPLE covers FULL + BULK_LOGGED, D27).
    INSERT INTO @tProblem (cProblem)
    SELECT t.cDbName + N': last LOG '
         + ISNULL(CONVERT(nvarchar(19), l.dLastLog, 120), N'NEVER')
         + N' (max ' + CONVERT(nvarchar(10), @LogMaxHours) + N'h)'
    FROM @tTarget t
    JOIN sys.databases d ON d.name = t.cDbName
    OUTER APPLY (SELECT MAX(bs.backup_finish_date) AS dLastLog
                 FROM msdb.dbo.backupset bs
                 WHERE bs.database_name = t.cDbName
                   AND bs.type = 'L') l
    WHERE d.recovery_model_desc <> N'SIMPLE'
      AND (l.dLastLog IS NULL
           OR l.dLastLog <= DATEADD(HOUR, -@LogMaxHours, @dNow));

    IF EXISTS (SELECT 1 FROM @tProblem)
    BEGIN
        DECLARE @cMsg nvarchar(2000) = N'maint.spCheckBackupChain: STALE backup chain — '
            + (SELECT STRING_AGG(cProblem, N'; ') FROM @tProblem);
        THROW 51100, @cMsg, 1;
    END
END
GO
