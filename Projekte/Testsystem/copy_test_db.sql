------------------------------------------------------------
-- Clone_EazyBusiness_To_Test.sql
-- Klont eazybusiness -> eazybusiness_testmandant2
-- Nur: COPY_ONLY-Backup
-- Login muss bereits existieren und bekommt in der Test-DB db_owner
------------------------------------------------------------

USE master;
GO

------------------------------------------------------------
-- 0. Settings – bei Bedarf anpassen
------------------------------------------------------------
DECLARE @SourceDb   sysname       = N'eazybusiness';          -- Quell-DB
DECLARE @TargetDb   sysname       = N'eazybusiness_tm2';     -- Ziel-DB
DECLARE @BackupFile nvarchar(260) = N'C:\work\eazybusiness_to_test.bak';  -- Pfad zum Backup
DECLARE @LoginName  sysname       = N'dbuser_dev_dana';          -- EXISTIERENDER Server-Login

------------------------------------------------------------
-- 1. Prüfen, ob Quell-DB sowie der User existiert
------------------------------------------------------------
IF DB_ID(@SourceDb) IS NULL
    BEGIN
        RAISERROR('Quell-Datenbank %s existiert nicht.', 16, 1, @SourceDb);
        RETURN;
    END

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = @LoginName)
    BEGIN
        RAISERROR('Der Login %s existiert nicht auf dem Server. Bitte zuerst anlegen.', 16, 1, @LoginName);
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
-- 2. Wenn Test-DB noch NICHT existiert: COPY_ONLY-Backup + Restore
------------------------------------------------------------
IF DB_ID(@TargetDb) IS NULL
    BEGIN
        PRINT 'Test-Datenbank existiert noch nicht. Erstelle Copy-Only-Backup und stelle neue DB her...';

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
        -- 2.3 Restore als neue Test-DB
        --------------------------------------------------------
        PRINT 'Stelle Test-Datenbank aus Copy-Only-Backup wieder her...';

        SET @Sql = N'
        RESTORE DATABASE [' + @TargetDb + N']
        FROM DISK = N''' + @BackupFile + N'''
        WITH
          MOVE N''' + @DataSourceLogicalName + N''' TO N''' + @DataRestorePhysical + N''',
          MOVE N''' + @LogSourceLogicalName + N''' TO N''' + @LogRestorePhysical  + N''',
          STATS = 10;
    ';

        PRINT @Sql;  -- Debug-Ausgabe, damit du siehst, was wirklich ausgeführt wird

        EXEC (@Sql);

    END
ELSE
    BEGIN
        PRINT 'Test-Datenbank [' + @TargetDb + '] existiert bereits – es wird KEIN Restore durchgeführt.';
    END

------------------------------------------------------------
-- 4. Benutzer in Test-DB anlegen (falls nötig) + db_owner vergeben
------------------------------------------------------------

IF DB_ID(@TargetDb) IS NULL
    BEGIN
        RAISERROR('Zieldatenbank %s existiert nicht – Nutzer kann nicht angelegt werden.', 16, 1, @TargetDb);
        RETURN;
    END

DECLARE @UserSql    nvarchar(max);

SET @UserSql = N'
USE [' + @TargetDb + N'];

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N''' + @LoginName + N''')
BEGIN
    CREATE USER [' + @LoginName + N'] FOR LOGIN [' + @LoginName + N'];
END;

IF NOT EXISTS (
    SELECT 1
    FROM sys.database_role_members rm
    JOIN sys.database_principals r ON rm.role_principal_id = r.principal_id
    JOIN sys.database_principals u ON rm.member_principal_id = u.principal_id
    WHERE r.name = N''db_owner'' AND u.name = N''' + @LoginName + N'''
)
BEGIN
    EXEC sp_addrolemember N''db_owner'', N''' + @LoginName + N''';
END;
';

PRINT @UserSql;  -- Debug-Ausgabe, damit du siehst, was wirklich ausgeführt wird

EXEC (@UserSql);

PRINT 'Fertig: Test-Datenbank [' + @TargetDb + '] ist vorhanden und Login [' + @LoginName + '] hat db_owner-Rechte.';
GO
