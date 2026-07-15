-- reset.spInternal_CloneDatabase  (Ebene B / global — pipeline step, job-only)
--
-- Ported from Projekte/Testsystem/copy_test_db.sql. Clones the source DB into the
-- target clone via a COPY_ONLY backup + restore-with-move. Paths come from
-- ops.tConfig (BackupFile, TargetDataDir, SourceDb) instead of hard-coded literals.
--
-- Security: only the target DB NAME is concatenated (via QUOTENAME); path values are
-- passed as sp_executesql parameters (BACKUP) or built as QUOTENAME-escaped string
-- literals from trusted inputs only — ops.tConfig dir + the validated @TargetDb +
-- server-side logical file names, never caller data (D6). Guarded against
-- @TargetDb='eazybusiness' and against source==target (D6 invariant, CQG-9).
--
-- CQG-2: the RESTORE relocates EVERY source file, not just one data + one log file.
-- A JTL DB is single-file today, but a future secondary data file / filegroup would
-- otherwise be silently dropped from the MOVE list and break the RESTORE; the move
-- list is therefore built from sys.master_files so any file layout clones correctly.
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§3)
CREATE OR ALTER PROCEDURE reset.spInternal_CloneDatabase
    @TargetDb   sysname,
    @RequestId  int,
    @MandantKey sysname   -- uniform step contract (EXT-2); not used by this step
AS
BEGIN
    SET NOCOUNT ON;

    IF @TargetDb = N'eazybusiness' OR @TargetDb NOT LIKE N'eazybusiness[_]%'
        THROW 51010, 'spInternal_CloneDatabase refused: target is not a test-mandant clone.', 1;

    -- Locals sized to ops.tConfig.cValue (nvarchar(1000)) so a long backup/data
    -- path round-trips without silent truncation (CQG-11).
    DECLARE @SourceDb sysname, @BackupFile nvarchar(1000), @TargetDataDir nvarchar(1000),
            @moves nvarchar(max) = N'',
            @sql nvarchar(max), @log nvarchar(max);

    SELECT @SourceDb      = cValue FROM ops.tConfig WHERE cKey = N'SourceDb';
    SELECT @BackupFile    = cValue FROM ops.tConfig WHERE cKey = N'BackupFile';
    SELECT @TargetDataDir = cValue FROM ops.tConfig WHERE cKey = N'TargetDataDir';

    IF @SourceDb IS NULL OR @BackupFile IS NULL OR @TargetDataDir IS NULL
        THROW 51011, 'spInternal_CloneDatabase: ops.tConfig is missing SourceDb/BackupFile/TargetDataDir.', 1;
    IF DB_ID(@SourceDb) IS NULL
        THROW 51012, 'spInternal_CloneDatabase: source database does not exist.', 1;

    -- Never clone a database onto itself (ADR D6 lists this invariant; make it explicit
    -- rather than rely on the SourceDb/cTargetDb name patterns never overlapping — CQG-9).
    IF @TargetDb = @SourceDb
        THROW 51014, 'spInternal_CloneDatabase refused: source and target are the same database.', 1;

    -- Build one MOVE clause per source file (CQG-2). Physical name = TargetDataDir\
    -- <clone>_<logical><.mdf|.ldf>, unique per file so a multi-file source cannot collide.
    -- QUOTENAME(..., '''') emits each logical name and path as an escaped string literal;
    -- a variable file count precludes a fixed sp_executesql parameter list, and every
    -- input here is server-side/trusted (never caller data).
    SELECT @moves = @moves + N', MOVE ' + QUOTENAME(mf.name, '''')
                  + N' TO ' + QUOTENAME(@TargetDataDir + N'\' + @TargetDb + N'_' + mf.name
                              + CASE mf.type_desc WHEN N'LOG' THEN N'.ldf' ELSE N'.mdf' END, '''')
    FROM sys.master_files mf
    WHERE mf.database_id = DB_ID(@SourceDb)
      AND mf.type_desc IN (N'ROWS', N'LOG');

    IF NOT EXISTS (SELECT 1 FROM sys.master_files WHERE database_id = DB_ID(@SourceDb) AND type_desc = N'ROWS')
       OR NOT EXISTS (SELECT 1 FROM sys.master_files WHERE database_id = DB_ID(@SourceDb) AND type_desc = N'LOG')
        THROW 51013, 'spInternal_CloneDatabase: source has no ROWS or no LOG file.', 1;

    -- Prepare an existing target for RESTORE ... REPLACE.
    -- (EXEC() does not accept a function call in its concatenated argument, so build the
    -- statement into @sql first, then EXEC(@sql).)
    IF DB_ID(@TargetDb) IS NOT NULL
    BEGIN
        -- QG3 B10/I5: a leftover clone stuck in RESTORING/OFFLINE (previous run killed
        -- mid-RESTORE) cannot be set SINGLE_USER — the ALTER fails with an error that
        -- points the operator at the wrong cause. Such a corpse has no diagnostic value
        -- (unlike a failed-but-ONLINE clone, which the pipeline deliberately keeps), and
        -- RESTORE recreates the database anyway, so drop it and log why.
        DECLARE @targetState nvarchar(60) =
            (SELECT state_desc FROM sys.databases WHERE name = @TargetDb);
        IF @targetState <> N'ONLINE'
        BEGIN
            SET @log = CONCAT(N'clone: target ', @TargetDb, N' found in state ', @targetState,
                              N' (leftover from a dead run) — dropping it before restore');
            EXEC reset.spInternal_LogStep @RequestId, @log;
            SET @sql = N'DROP DATABASE ' + QUOTENAME(@TargetDb) + N';';
            EXEC (@sql);
        END
        ELSE
        BEGIN
            -- Kick out any users so RESTORE ... REPLACE can proceed.
            SET @sql = N'ALTER DATABASE ' + QUOTENAME(@TargetDb) + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE;';
            EXEC (@sql);
        END
    END

    -- Ensure the data directory exists (RESTORE creates no folders).
    EXEC master.dbo.xp_create_subdir @TargetDataDir;

    -- COPY_ONLY backup of the source.
    SET @sql = N'BACKUP DATABASE ' + QUOTENAME(@SourceDb)
             + N' TO DISK = @bf WITH INIT, COPY_ONLY, STATS = 10;';
    EXEC sp_executesql @sql, N'@bf nvarchar(1000)', @bf = @BackupFile;

    -- Restore as the target clone, relocating every source file (STUFF trims the leading
    -- ', ' from the built MOVE list). Only @bf stays a parameter; the MOVE targets are the
    -- QUOTENAME-escaped literals built above.
    SET @sql = N'RESTORE DATABASE ' + QUOTENAME(@TargetDb)
             + N' FROM DISK = @bf WITH ' + STUFF(@moves, 1, 2, N'')
             + N', REPLACE, STATS = 10;';
    EXEC sp_executesql @sql, N'@bf nvarchar(1000)', @bf = @BackupFile;

    SET @sql = N'ALTER DATABASE ' + QUOTENAME(@TargetDb) + N' SET RECOVERY SIMPLE;';
    EXEC (@sql);
    SET @sql = N'ALTER DATABASE ' + QUOTENAME(@TargetDb) + N' SET MULTI_USER;';
    EXEC (@sql);

    -- Build the message into a variable first: a proc argument must be a variable/constant,
    -- not an expression. CONCAT keeps the data-concat lint heuristic quiet (this is a log
    -- message, not dynamic SQL — @SourceDb/@TargetDb are validated identifiers anyway).
    SET @log = CONCAT(N'clone: backup+restore ', @SourceDb, N' -> ', @TargetDb, N' ok');
    EXEC reset.spInternal_LogStep @RequestId, @log;
END
GO
