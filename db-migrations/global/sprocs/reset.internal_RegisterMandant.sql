-- reset.internal_RegisterMandant  (Ebene B / global — pipeline step, job-only)
--
-- Ported from Projekte/Testsystem/register-mandant.sql. Registers the clone so it
-- shows up in the JTL login and every user has a company: upserts dbo.tMandant
-- (keyed by cDB) across all mandant DBs, and seeds dbo.tBenutzerFirma for the new
-- kMandant from the reference mandant. SourceDb + ReferenceMandant come from
-- ops.Config; the display name is read from ops.Mandant by @MandantKey (uniform step
-- contract, EXT-2) and passed as an sp_executesql parameter (never concatenated); DB
-- names go through QUOTENAME only.
--
-- BLAST RADIUS (CQG-5): by JTL's shared-registry design a mandant must be known to
-- EVERY mandant DB, so this step upserts the clone's dbo.tMandant row into every
-- registered mandant DB — INCLUDING the production `eazybusiness` DB (kMandant=1 →
-- cDB='eazybusiness'). That prod write is intended (it is how the clone appears in the
-- JTL login) and is NOT the destructive kind guarded against elsewhere; the @TargetDb
-- guard validates the CLONE, not the set of DBs written. A write against @TargetDb
-- itself is fatal (THROW); a failure against any OTHER mandant DB is non-fatal by
-- design — it is logged as a WARN and counted into the summary line so a partial
-- registration is visible in reset.GetResetStatus rather than hidden behind 'succeeded'.
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§3)
-- @see Projekte/Testsystem/register-mandant.sql
CREATE OR ALTER PROCEDURE reset.internal_RegisterMandant
    @TargetDb   sysname,
    @RequestId  int,
    @MandantKey sysname
AS
BEGIN
    SET NOCOUNT ON;

    IF @TargetDb = N'eazybusiness' OR @TargetDb NOT LIKE N'eazybusiness[_]%'
        THROW 51070, 'internal_RegisterMandant refused: target is not a test-mandant clone.', 1;

    -- Each step reads its own inputs from ops.Mandant (EXT-2).
    DECLARE @DisplayName nvarchar(255);
    SELECT @DisplayName = DisplayName FROM ops.Mandant WHERE MandantKey = @MandantKey;
    IF NULLIF(LTRIM(RTRIM(@DisplayName)), N'') IS NULL
        THROW 51071, 'internal_RegisterMandant: DisplayName is empty.', 1;

    DECLARE @SourceDb sysname, @refMandant int, @sql nvarchar(max), @k int, @warnCount int = 0,
            @log nvarchar(max);
    -- Best-effort updates of the *other* mandant DBs log a per-DB WARN line and carry on;
    -- a failure against @TargetDb itself THROWs instead — registering the clone is this
    -- step's core purpose, silently skipping it would mark the reset succeeded while the
    -- mandant is invisible in the JTL login.

    SELECT @SourceDb   = ConfigValue FROM ops.Config WHERE ConfigKey = N'SourceDb';
    SELECT @refMandant = TRY_CONVERT(int, ConfigValue) FROM ops.Config WHERE ConfigKey = N'ReferenceMandant';
    SET @SourceDb   = ISNULL(@SourceDb, N'eazybusiness');
    SET @refMandant = ISNULL(@refMandant, 1);


    -- Reuse the existing kMandant (keyed by cDB) or take the next free number.
    SET @sql = N'SELECT @k = kMandant FROM ' + QUOTENAME(@SourceDb) + N'.dbo.tMandant WHERE cDB = @TargetDb;';
    EXEC sp_executesql @sql, N'@TargetDb sysname, @k int OUTPUT', @TargetDb = @TargetDb, @k = @k OUTPUT;
    IF @k IS NULL
    BEGIN
        SET @sql = N'SELECT @k = ISNULL(MAX(kMandant), 0) + 1 FROM ' + QUOTENAME(@SourceDb) + N'.dbo.tMandant;';
        EXEC sp_executesql @sql, N'@k int OUTPUT', @k = @k OUTPUT;
    END

    -- Target DBs: every registered, existing mandant DB + the new clone.
    DECLARE @dbs TABLE (name sysname PRIMARY KEY);
    SET @sql = N'SELECT DISTINCT cDB FROM ' + QUOTENAME(@SourceDb) + N'.dbo.tMandant WHERE cDB IS NOT NULL AND DB_ID(cDB) IS NOT NULL;';
    INSERT INTO @dbs (name) EXEC sp_executesql @sql;
    IF NOT EXISTS (SELECT 1 FROM @dbs WHERE name = @TargetDb)
        INSERT INTO @dbs (name) VALUES (@TargetDb);

    DECLARE @db sysname;
    DECLARE dbcur CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM @dbs;
    OPEN dbcur;
    FETCH NEXT FROM dbcur INTO @db;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'
            IF EXISTS (SELECT 1 FROM ' + QUOTENAME(@db) + N'.dbo.tMandant WHERE cDB = @TargetDb)
                UPDATE ' + QUOTENAME(@db) + N'.dbo.tMandant SET cName = @DisplayName WHERE cDB = @TargetDb;
            ELSE
                INSERT INTO ' + QUOTENAME(@db) + N'.dbo.tMandant (kMandant, cName, cDB)
                VALUES (@k, @DisplayName, @TargetDb);';
        BEGIN TRY
            EXEC sp_executesql @sql,
                 N'@TargetDb sysname, @DisplayName nvarchar(255), @k int',
                 @TargetDb = @TargetDb, @DisplayName = @DisplayName, @k = @k;
        END TRY
        BEGIN CATCH
            IF @db = @TargetDb
            BEGIN
                CLOSE dbcur; DEALLOCATE dbcur;
                THROW;
            END
            SET @warnCount += 1;
            SET @log = CONCAT(N'register: WARN ', @db, N': ', ERROR_MESSAGE());
            EXEC reset.internal_LogStep @RequestId, @log;
        END CATCH
        FETCH NEXT FROM dbcur INTO @db;
    END
    CLOSE dbcur; DEALLOCATE dbcur;

    -- tBenutzerFirma seed for the new kMandant (skip if it equals the reference).
    IF @k <> @refMandant
    BEGIN
        DECLARE @seedDbs TABLE (name sysname PRIMARY KEY);
        INSERT INTO @seedDbs (name) VALUES (@SourceDb);
        IF NOT EXISTS (SELECT 1 FROM @seedDbs WHERE name = @TargetDb)
            INSERT INTO @seedDbs (name) VALUES (@TargetDb);

        DECLARE @sdb sysname;
        DECLARE seedcur CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM @seedDbs;
        OPEN seedcur;
        FETCH NEXT FROM seedcur INTO @sdb;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @sql = N'
                DELETE FROM ' + QUOTENAME(@sdb) + N'.dbo.tBenutzerFirma WHERE kMandant = @k;
                INSERT INTO ' + QUOTENAME(@sdb) + N'.dbo.tBenutzerFirma (kBenutzer, kFirma, kMandant)
                SELECT bf.kBenutzer, bf.kFirma, @k
                FROM ' + QUOTENAME(@SourceDb) + N'.dbo.tBenutzerFirma bf
                WHERE bf.kMandant = @refMandant
                  AND EXISTS (SELECT 1 FROM ' + QUOTENAME(@sdb) + N'.dbo.tBenutzer b WHERE b.kBenutzer = bf.kBenutzer)
                  AND EXISTS (SELECT 1 FROM ' + QUOTENAME(@sdb) + N'.dbo.tFirma   f WHERE f.kFirma   = bf.kFirma);';
            BEGIN TRY
                EXEC sp_executesql @sql, N'@k int, @refMandant int', @k = @k, @refMandant = @refMandant;
            END TRY
            BEGIN CATCH
                IF @sdb = @TargetDb
                BEGIN
                    CLOSE seedcur; DEALLOCATE seedcur;
                    THROW;
                END
                SET @warnCount += 1;
                SET @log = CONCAT(N'register: WARN ', @sdb, N': ', ERROR_MESSAGE());
                EXEC reset.internal_LogStep @RequestId, @log;
            END CATCH
            FETCH NEXT FROM seedcur INTO @sdb;
        END
        CLOSE seedcur; DEALLOCATE seedcur;
    END

    SET @log = CONCAT(N'register: kMandant=', @k, N' (', @DisplayName, N')',
                      CASE WHEN @warnCount > 0
                           THEN CONCAT(N'; ', @warnCount, N' non-target DB WARN(s) — see above')
                           ELSE N'' END);
    EXEC reset.internal_LogStep @RequestId, @log;
END
GO
