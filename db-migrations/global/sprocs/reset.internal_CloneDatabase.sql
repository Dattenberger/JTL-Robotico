-- reset.internal_CloneDatabase  (Ebene B / global — pipeline step, job-only)
--
-- Ported from Projekte/Testsystem/copy_test_db.sql. Clones the source DB into the
-- target clone via a COPY_ONLY backup + restore-with-move. Paths come from
-- ops.Config (BackupFile, TargetDataDir, SourceDb) instead of hard-coded literals.
--
-- Security: only the target DB NAME is concatenated (via QUOTENAME); every path /
-- logical-file value is passed as an sp_executesql parameter — no data string is
-- concatenated into the executed SQL (D6). Guarded against @TargetDb='eazybusiness'.
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§3)
CREATE OR ALTER PROCEDURE reset.internal_CloneDatabase
    @TargetDb   sysname,
    @RequestId  int,
    @MandantKey sysname   -- uniform step contract (EXT-2); not used by this step
AS
BEGIN
    SET NOCOUNT ON;

    IF @TargetDb = N'eazybusiness' OR @TargetDb NOT LIKE N'eazybusiness[_]%'
        THROW 51010, 'internal_CloneDatabase refused: target is not a test-mandant clone.', 1;

    DECLARE @SourceDb sysname, @BackupFile nvarchar(260), @TargetDataDir nvarchar(260),
            @DataLogical sysname, @LogLogical sysname,
            @DataPhysical nvarchar(400), @LogPhysical nvarchar(400),
            @sql nvarchar(max);

    SELECT @SourceDb      = ConfigValue FROM ops.Config WHERE ConfigKey = N'SourceDb';
    SELECT @BackupFile    = ConfigValue FROM ops.Config WHERE ConfigKey = N'BackupFile';
    SELECT @TargetDataDir = ConfigValue FROM ops.Config WHERE ConfigKey = N'TargetDataDir';

    IF @SourceDb IS NULL OR @BackupFile IS NULL OR @TargetDataDir IS NULL
        THROW 51011, 'internal_CloneDatabase: ops.Config is missing SourceDb/BackupFile/TargetDataDir.', 1;
    IF DB_ID(@SourceDb) IS NULL
        THROW 51012, 'internal_CloneDatabase: source database does not exist.', 1;

    SELECT @DataLogical = name FROM sys.master_files WHERE database_id = DB_ID(@SourceDb) AND type_desc = 'ROWS';
    SELECT @LogLogical  = name FROM sys.master_files WHERE database_id = DB_ID(@SourceDb) AND type_desc = 'LOG';
    IF @DataLogical IS NULL OR @LogLogical IS NULL
        THROW 51013, 'internal_CloneDatabase: could not determine source logical file names.', 1;

    SET @DataPhysical = @TargetDataDir + N'\' + @TargetDb + N'.mdf';
    SET @LogPhysical  = @TargetDataDir + N'\' + @TargetDb + N'.ldf';

    -- Kick out any users so RESTORE ... REPLACE can proceed.
    IF DB_ID(@TargetDb) IS NOT NULL
        EXEC (N'ALTER DATABASE ' + QUOTENAME(@TargetDb) + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE;');

    -- Ensure the data directory exists (RESTORE creates no folders).
    EXEC master.dbo.xp_create_subdir @TargetDataDir;

    -- COPY_ONLY backup of the source.
    SET @sql = N'BACKUP DATABASE ' + QUOTENAME(@SourceDb)
             + N' TO DISK = @bf WITH INIT, COPY_ONLY, STATS = 10;';
    EXEC sp_executesql @sql, N'@bf nvarchar(260)', @bf = @BackupFile;

    -- Restore as the target clone, moving files into the dedicated data dir.
    SET @sql = N'RESTORE DATABASE ' + QUOTENAME(@TargetDb)
             + N' FROM DISK = @bf WITH MOVE @dl TO @dp, MOVE @ll TO @lp, REPLACE, STATS = 10;';
    EXEC sp_executesql @sql,
         N'@bf nvarchar(260), @dl sysname, @dp nvarchar(400), @ll sysname, @lp nvarchar(400)',
         @bf = @BackupFile, @dl = @DataLogical, @dp = @DataPhysical, @ll = @LogLogical, @lp = @LogPhysical;

    EXEC (N'ALTER DATABASE ' + QUOTENAME(@TargetDb) + N' SET RECOVERY SIMPLE;');
    EXEC (N'ALTER DATABASE ' + QUOTENAME(@TargetDb) + N' SET MULTI_USER;');

    EXEC reset.internal_LogStep @RequestId,
         N'clone: backup+restore ' + @SourceDb + N' -> ' + @TargetDb + N' ok';
END
GO
