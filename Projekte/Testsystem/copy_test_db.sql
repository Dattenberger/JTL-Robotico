------------------------------------------------------------
-- Clone_EazyBusiness_To_Test.sql
-- Klont eazybusiness -> eazybusiness_testmandant2
-- Nur: COPY_ONLY-Backup
-- Login muss bereits existieren und bekommt in der Test-DB db_owner
------------------------------------------------------------

USE master;
GO

------------------------------------------------------------
------------------------------------------------------------
-- 0. Settings – bei Bedarf anpassen
------------------------------------------------------------
DECLARE @SourceDb   sysname       = N'eazybusiness';          -- Quell-DB
DECLARE @TargetDb   sysname       = N'$(TargetDb)';          -- Ziel-DB via SQLCMD
DECLARE @BackupFile nvarchar(260) = N'C:\work\eazybusiness_to_test.bak';  -- Pfad zum Backup

------------------------------------------------------------
-- 1. Prüfen, ob Quell-DB sowie der User existiert
------------------------------------------------------------
-- SAFETY CHECK: Ensure Target Database is NOT eazybusiness
IF @TargetDb = 'eazybusiness'
BEGIN
    RAISERROR('CRITICAL ERROR: Target database cannot be [eazybusiness]! Operation aborted.', 20, 1) WITH LOG;
    RETURN;
END

IF DB_ID(@SourceDb) IS NULL
    BEGIN
        RAISERROR('Quell-Datenbank %s existiert nicht.', 16, 1, @SourceDb);
        RETURN;
    END

DECLARE
    @DataSourceLogicalName sysname,
    @LogSourceLogicalName  sysname,
    @DataSourcePhysical    nvarchar(260),
    @LogSourcePhysical     nvarchar(260),
    @DataRestorePhysical    nvarchar(260),
    @LogRestorePhysical     nvarchar(260),
    @Sql             nvarchar(max);

------------------------------------------------------------
-- 2. COPY_ONLY-Backup + Restore (Overwrite if exists)
------------------------------------------------------------

-- If Target DB exists, kick out users and drop it (or just replace, but drop is cleaner for full reset)
IF DB_ID(@TargetDb) IS NOT NULL
BEGIN
    PRINT 'Test-Datenbank [' + @TargetDb + '] existiert bereits. Trenne Verbindungen und bereite Überschreiben vor...';
    
    SET @Sql = N'ALTER DATABASE [' + @TargetDb + N'] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;';
    EXEC (@Sql);
    
    -- We can either DROP or just RESTORE WITH REPLACE. 
    -- RESTORE WITH REPLACE is safer if we want to keep file locations, but here we calculate them anyway.
    -- Let's use RESTORE WITH REPLACE logic below implicitly, but setting SINGLE_USER ensures no locks.
END
ELSE
BEGIN
    PRINT 'Test-Datenbank existiert noch nicht. Erstelle neu...';
END

--------------------------------------------------------
-- 2.1 Dateiinformationen der Quell-DB ermitteln
--------------------------------------------------------
SELECT
    @DataSourceLogicalName = mf.name,
    @DataSourcePhysical    = mf.physical_name
FROM sys.master_files mf
WHERE mf.database_id = DB_ID(@SourceDb)
  AND mf.type_desc = 'ROWS';

SELECT
    @LogSourceLogicalName = mf.name,
    @LogSourcePhysical    = mf.physical_name
FROM sys.master_files mf
WHERE mf.database_id = DB_ID(@SourceDb)
  AND mf.type_desc = 'LOG';

IF @DataSourceLogicalName IS NULL OR @LogSourceLogicalName IS NULL
    BEGIN
        RAISERROR('Konnte Dateiinformationen der Quell-Datenbank nicht ermitteln.', 16, 1);
        RETURN;
    END

-- Annahme: der DB-Name steckt im Pfad. Falls nicht, hier ggf. hart anpassen.
SET @DataRestorePhysical = REPLACE(@DataSourcePhysical, @SourceDb, @TargetDb);
SET @LogRestorePhysical  = REPLACE(@LogSourcePhysical,  @SourceDb, @TargetDb);

PRINT 'Quelldatei (Daten): ' + @DataSourcePhysical;
PRINT 'Quelldatei (Log):   ' + @LogSourcePhysical;
PRINT 'Zieldatei (Daten): ' + @DataRestorePhysical;
PRINT 'Zieldatei (Log):   ' + @LogRestorePhysical;

--------------------------------------------------------
-- 2.2 COPY_ONLY-Backup erzeugen
--------------------------------------------------------
PRINT 'Erzeuge COPY_ONLY-Backup der Quell-Datenbank...';

SET @Sql = N'
BACKUP DATABASE [' + @SourceDb + N']
TO DISK = N''' + @BackupFile + N'''
WITH INIT, COPY_ONLY, STATS = 10;
';

PRINT @Sql;  -- Debug-Ausgabe, damit du siehst, was wirklich ausgeführt wird
EXEC (@Sql);

--------------------------------------------------------
-- 2.3 Restore als neue Test-DB (WITH REPLACE)
--------------------------------------------------------
PRINT 'Stelle Test-Datenbank aus Copy-Only-Backup wieder her (Overwrite)...';

SET @Sql = N'
RESTORE DATABASE [' + @TargetDb + N']
FROM DISK = N''' + @BackupFile + N'''
WITH
  MOVE N''' + @DataSourceLogicalName + N''' TO N''' + @DataRestorePhysical + N''',
  MOVE N''' + @LogSourceLogicalName + N''' TO N''' + @LogRestorePhysical  + N''',
  REPLACE,
  STATS = 10;
';

PRINT @Sql;  -- Debug-Ausgabe, damit du siehst, was wirklich ausgeführt wird

EXEC (@Sql);

--------------------------------------------------------
-- 2.4 Recovery Model auf SIMPLE setzen (Platz sparen)
--------------------------------------------------------
PRINT 'Setze Recovery Model auf SIMPLE...';
SET @Sql = N'ALTER DATABASE [' + @TargetDb + N'] SET RECOVERY SIMPLE;';
EXEC (@Sql);

--------------------------------------------------------
-- 2.5 Datenbank auf MULTI_USER setzen (Zugriff erlauben)
--------------------------------------------------------
PRINT 'Setze Datenbank auf MULTI_USER...';
SET @Sql = N'ALTER DATABASE [' + @TargetDb + N'] SET MULTI_USER;';
EXEC (@Sql);

PRINT 'Fertig: Test-Datenbank [' + @TargetDb + '] ist vorhanden.';
GO
