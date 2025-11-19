------------------------------------------------------------
-- grant-database-access.sql
-- Grants database access to a login for both source and test databases
-- Provides SELECT permissions on specific administrative tables
------------------------------------------------------------

USE master;
GO

------------------------------------------------------------
-- Settings – adjust as needed
------------------------------------------------------------
DECLARE @SourceDb   sysname = N'eazybusiness';        -- Source database
DECLARE @TargetDb   sysname = N'eazybusiness_tm2';    -- Test database
DECLARE @LoginName  sysname = N'dbuser_dev_dana';     -- Login to grant access to

------------------------------------------------------------
-- Validate that login exists
------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = @LoginName)
BEGIN
    RAISERROR('Login %s does not exist on the server. Please create it first.', 16, 1, @LoginName);
    RETURN;
END

------------------------------------------------------------
-- Grant access to SOURCE database (eazybusiness)
------------------------------------------------------------
PRINT 'Granting access to source database [' + @SourceDb + ']...';

IF DB_ID(@SourceDb) IS NULL
BEGIN
    RAISERROR('Source database %s does not exist.', 16, 1, @SourceDb);
    RETURN;
END

DECLARE @SourceSql nvarchar(max);

SET @SourceSql = N'
USE [' + @SourceDb + N'];

-- Create user if not exists
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N''' + @LoginName + N''')
BEGIN
    CREATE USER [' + @LoginName + N'] FOR LOGIN [' + @LoginName + N'];
    PRINT ''User [' + @LoginName + N'] created in [' + @SourceDb + N']'';
END
ELSE
BEGIN
    PRINT ''User [' + @LoginName + N'] already exists in [' + @SourceDb + N']'';
END

-- Grant SELECT on specific administrative tables
GRANT SELECT ON dbo.tRechtBenutzerGruppenZuordnung TO [' + @LoginName + N'];
GRANT SELECT ON dbo.tRechtBenutzerGruppe TO [' + @LoginName + N'];
GRANT SELECT ON dbo.tversion TO [' + @LoginName + N'];
GRANT SELECT ON dbo.tMandant TO [' + @LoginName + N'];

-- Grant EXECUTE on sp_executesql (system stored procedure, already granted by default)
-- User can execute dynamic SQL if needed

PRINT ''Granted SELECT permissions on administrative tables in [' + @SourceDb + N']'';
';

EXEC (@SourceSql);

------------------------------------------------------------
-- Grant access to TARGET database (eazybusiness_tm2)
------------------------------------------------------------
PRINT '';
PRINT 'Granting access to target database [' + @TargetDb + ']...';

IF DB_ID(@TargetDb) IS NULL
BEGIN
    RAISERROR('Target database %s does not exist.', 16, 1, @TargetDb);
    RETURN;
END

DECLARE @TargetSql nvarchar(max);

SET @TargetSql = N'
USE [' + @TargetDb + N'];

-- Create user if not exists
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N''' + @LoginName + N''')
BEGIN
    CREATE USER [' + @LoginName + N'] FOR LOGIN [' + @LoginName + N'];
    PRINT ''User [' + @LoginName + N'] created in [' + @TargetDb + N']'';
END
ELSE
BEGIN
    PRINT ''User [' + @LoginName + N'] already exists in [' + @TargetDb + N']'';
END

-- Add user to db_owner role (full permissions on test database)
IF NOT EXISTS (
    SELECT 1
    FROM sys.database_role_members rm
    JOIN sys.database_principals r ON rm.role_principal_id = r.principal_id
    JOIN sys.database_principals u ON rm.member_principal_id = u.principal_id
    WHERE r.name = N''db_owner'' AND u.name = N''' + @LoginName + N'''
)
BEGIN
    EXEC sp_addrolemember N''db_owner'', N''' + @LoginName + N''';
    PRINT ''Added [' + @LoginName + N'] to db_owner role in [' + @TargetDb + N']'';
END
ELSE
BEGIN
    PRINT ''User [' + @LoginName + N'] already has db_owner role in [' + @TargetDb + N']'';
END
';

EXEC (@TargetSql);

------------------------------------------------------------
-- Summary
------------------------------------------------------------
PRINT '';
PRINT '========================================';
PRINT 'Access grant completed successfully!';
PRINT '========================================';
PRINT '';
PRINT 'Login: [' + @LoginName + ']';
PRINT '';
PRINT 'Source Database [' + @SourceDb + ']:';
PRINT '  - User created (if not exists)';
PRINT '  - SELECT on dbo.tRechtBenutzerGruppenZuordnung';
PRINT '  - SELECT on dbo.tRechtBenutzerGruppe';
PRINT '  - SELECT on dbo.tversion';
PRINT '  - SELECT on dbo.tMandant';
PRINT '';
PRINT 'Target Database [' + @TargetDb + ']:';
PRINT '  - User created (if not exists)';
PRINT '  - db_owner role (full permissions)';
PRINT '';
GO
