-- ############################################################################
-- #  MANUAL EXECUTION ONLY — PRODUCTION IMPACT                                #
-- #  03_premig_db.sql                                                        #
-- #                                                                          #
-- #  The SELECT/catalog blocks are READ-ONLY. The BACKUP and DROP options at #
-- #  the bottom are COMMENTED OUT — they are destructive and need a human    #
-- #  decision (Open Question O3). Nothing here runs a write.                 #
-- ############################################################################
--
-- FINDING (research/2-instanz-survey §2 + "Auffälligkeiten"): the prod instance
-- (vm-sql2) carries a database `eazybusiness_premig` — a pre-migration snapshot of
-- eazybusiness — in FULL recovery, whose data files physically live under
-- `E:\Backup\`. It is old, large (~prod size), and consumes a backup volume with a
-- production DB nobody logs into. Open Question O3 (owner: User): keep it, or back
-- it up off-box and drop it?
--
-- Run read-only against prod:
--   /opt/mssql-tools18/bin/sqlcmd -S vm-sql2.zdbikes.local -E -C \
--       -d master -i Berechtigungen/cleanup/03_premig_db.sql
--
-- See: docs/runbooks/hygiene-findings.md — Finding 3 (operator context, O3 tracking)
--      docs/plans/2026-07-10 - mssql-ops-infrastruktur/mssql-ops-infrastruktur.md §D13 —
--      the destructive options below are commented out by mandate: manual, reviewed
--      execution only, never autonomously.

SET NOCOUNT ON;

-- ---------------------------------------------------------------------------
-- (A) Existence, recovery model, age of eazybusiness_premig
-- ---------------------------------------------------------------------------
SELECT
    d.name              AS DatabaseName,
    d.state_desc        AS State,
    d.recovery_model_desc AS RecoveryModel,
    d.compatibility_level AS CompatLevel,
    d.create_date       AS CreatedUtc,
    DATEDIFF(DAY, d.create_date, SYSUTCDATETIME()) AS AgeDays
FROM sys.databases d
WHERE d.name = 'eazybusiness_premig';

-- ---------------------------------------------------------------------------
-- (B) Physical files + sizes + location (confirms the E:\Backup\ placement)
-- ---------------------------------------------------------------------------
SELECT
    DB_NAME(mf.database_id) AS DatabaseName,
    mf.type_desc            AS FileType,
    mf.name                 AS LogicalName,
    mf.physical_name        AS PhysicalPath,
    CAST(mf.size * 8.0 / 1024 AS decimal(18,1)) AS SizeMB
FROM sys.master_files mf
WHERE mf.database_id = DB_ID('eazybusiness_premig')
ORDER BY mf.type_desc, mf.name;

-- ---------------------------------------------------------------------------
-- (C) Last known good backup of it (is an off-box copy already safe?)
-- ---------------------------------------------------------------------------
SELECT TOP 5
    bs.database_name,
    bs.type            AS BackupType,   -- D=full, I=diff, L=log
    bs.backup_finish_date,
    CAST(bs.backup_size / 1024.0 / 1024 AS decimal(18,1)) AS BackupSizeMB,
    bmf.physical_device_name
FROM msdb.dbo.backupset bs
JOIN msdb.dbo.backupmediafamily bmf ON bmf.media_set_id = bs.media_set_id
WHERE bs.database_name = 'eazybusiness_premig'
ORDER BY bs.backup_finish_date DESC;

-- ===========================================================================
-- DISPOSITION OPTIONS (O3) — COMMENTED OUT. Decide, review, run by hand.
-- ===========================================================================
--
-- Option KEEP: leave it, but move it OFF the E:\Backup\ volume and/or switch to
--   SIMPLE recovery so it stops accruing log backups. (Still costs space.)
--
-- Option ARCHIVE-THEN-DROP (frees the volume; recommended if nobody needs live
--   access). Take a fresh full backup to durable storage FIRST, verify it, THEN
--   drop. Do NOT drop without a verified backup.
--
--   BACKUP DATABASE [eazybusiness_premig]
--       TO DISK = N'E:\Backup\archive\eazybusiness_premig_final.bak'
--       WITH COPY_ONLY, CHECKSUM, COMPRESSION, STATS = 5;
--   -- verify the backup is restorable before dropping:
--   RESTORE VERIFYONLY FROM DISK = N'E:\Backup\archive\eazybusiness_premig_final.bak' WITH CHECKSUM;
--   -- move the .bak off-box (copy to NAS/object storage), confirm the copy, THEN:
--   ALTER DATABASE [eazybusiness_premig] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
--   DROP DATABASE [eazybusiness_premig];
--
-- After a drop, re-run block (A): it should return 0 rows.
