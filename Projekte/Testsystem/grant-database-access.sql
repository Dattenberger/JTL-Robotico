------------------------------------------------------------
-- grant-database-access.sql
-- Grants database access to a login for the target database
-- Adds the user to the db_owner role
------------------------------------------------------------

USE master;
GO

------------------------------------------------------------
-- Settings – adjust as needed
------------------------------------------------------------
-- DECLARE @TargetDb   sysname = N'eazybusiness_tm2';    -- Target database (REPLACED BY SQLCMD VARIABLE)
DECLARE @TargetDb   sysname = N'$(TargetDb)';    -- Target database via SQLCMD
-- DECLARE @LoginName  sysname = N'dbuser_dev_dana_for_development';     -- Login to grant access to (REPLACED BY SQLCMD VARIABLE)
DECLARE @LoginName  sysname = N'$(LoginName)';     -- Login via SQLCMD

------------------------------------------------------------
-- Validate that login exists
------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = @LoginName)
BEGIN
    RAISERROR('Login %s does not exist on the server. Please create it first.', 16, 1, @LoginName);
    RETURN;
END

------------------------------------------------------------
-- Grant access to TARGET database
------------------------------------------------------------
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

-- Add user to db_owner role (full permissions on target database)
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
PRINT 'Database: [' + @TargetDb + ']';
PRINT 'Role: db_owner';
PRINT '';
GO
