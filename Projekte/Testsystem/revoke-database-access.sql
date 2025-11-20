------------------------------------------------------------
-- revoke-database-access.sql
-- Dynamically revokes ALL database access from a login for the source database
-- Automatically detects and removes all granted permissions, then drops the user
------------------------------------------------------------

USE master;
GO

------------------------------------------------------------
-- Settings – adjust as needed
------------------------------------------------------------
DECLARE @SourceDb   sysname = N'eazybusiness';        -- Source database
DECLARE @LoginName  sysname = N'dbuser_dev_dana';     -- Login to revoke access from

------------------------------------------------------------
-- Validate that database exists
------------------------------------------------------------
IF DB_ID(@SourceDb) IS NULL
BEGIN
    RAISERROR('Source database %s does not exist.', 16, 1, @SourceDb);
    RETURN;
END

------------------------------------------------------------
-- Dynamically revoke ALL access from SOURCE database
------------------------------------------------------------
PRINT 'Dynamically revoking ALL access from source database [' + @SourceDb + ']...';
PRINT '';

DECLARE @SourceSql nvarchar(max);

SET @SourceSql = N'
USE [' + @SourceDb + N'];

-- Check if user exists
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N''' + @LoginName + N''')
BEGIN
    PRINT ''User [' + @LoginName + N'] does not exist in [' + @SourceDb + N']'';
END
ELSE
BEGIN
    DECLARE @RevokeCmd nvarchar(max);
    DECLARE @PermissionCount int = 0;

    PRINT ''Found user [' + @LoginName + N'] in [' + @SourceDb + N']'';
    PRINT ''Analyzing and revoking permissions...'';
    PRINT '''';

    -- Create cursor for all object-level permissions
    DECLARE permission_cursor CURSOR FOR
    SELECT
        CASE
            WHEN dp.state_desc = ''GRANT_WITH_GRANT_OPTION'' THEN
                ''REVOKE GRANT OPTION FOR '' + dp.permission_name + '' ON '' +
                CASE dp.class
                    WHEN 0 THEN ''DATABASE::'' + DB_NAME()
                    WHEN 1 THEN QUOTENAME(OBJECT_SCHEMA_NAME(dp.major_id)) + ''.'' + QUOTENAME(OBJECT_NAME(dp.major_id))
                    WHEN 3 THEN ''SCHEMA::'' + QUOTENAME(SCHEMA_NAME(dp.major_id))
                    WHEN 6 THEN ''TYPE::'' + QUOTENAME(SCHEMA_NAME(t.schema_id)) + ''.'' + QUOTENAME(t.name)
                    ELSE ''[Unknown]''
                END + '' FROM ['' + dpr.name + '']''
            ELSE
                ''REVOKE '' + dp.permission_name + '' ON '' +
                CASE dp.class
                    WHEN 0 THEN ''DATABASE::'' + DB_NAME()
                    WHEN 1 THEN QUOTENAME(OBJECT_SCHEMA_NAME(dp.major_id)) + ''.'' + QUOTENAME(OBJECT_NAME(dp.major_id))
                    WHEN 3 THEN ''SCHEMA::'' + QUOTENAME(SCHEMA_NAME(dp.major_id))
                    WHEN 6 THEN ''TYPE::'' + QUOTENAME(SCHEMA_NAME(t.schema_id)) + ''.'' + QUOTENAME(t.name)
                    ELSE ''[Unknown]''
                END + '' FROM ['' + dpr.name + '']''
        END as revoke_command
    FROM sys.database_permissions dp
    INNER JOIN sys.database_principals dpr ON dp.grantee_principal_id = dpr.principal_id
    LEFT JOIN sys.types t ON dp.major_id = t.user_type_id AND dp.class = 6
    WHERE dpr.name = N''' + @LoginName + N'''
        AND dp.class IN (0, 1, 3, 6)  -- Database, Object, Schema, Type
    ORDER BY dp.class, dp.permission_name;

    OPEN permission_cursor;
    FETCH NEXT FROM permission_cursor INTO @RevokeCmd;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            EXEC sp_executesql @RevokeCmd;
            SET @PermissionCount = @PermissionCount + 1;
            PRINT ''  ✓ '' + @RevokeCmd;
        END TRY
        BEGIN CATCH
            PRINT ''  ✗ Error revoking: '' + @RevokeCmd;
            PRINT ''    Error: '' + ERROR_MESSAGE();
        END CATCH

        FETCH NEXT FROM permission_cursor INTO @RevokeCmd;
    END

    CLOSE permission_cursor;
    DEALLOCATE permission_cursor;

    PRINT '''';
    PRINT ''Revoked '' + CAST(@PermissionCount as nvarchar(10)) + '' permission(s)'';
    PRINT '''';

    -- Remove from database roles
    DECLARE @RoleName sysname;
    DECLARE @RoleCount int = 0;

    DECLARE role_cursor CURSOR FOR
    SELECT r.name
    FROM sys.database_role_members rm
    INNER JOIN sys.database_principals r ON rm.role_principal_id = r.principal_id
    INNER JOIN sys.database_principals u ON rm.member_principal_id = u.principal_id
    WHERE u.name = N''' + @LoginName + N'''
        AND r.name NOT IN (''public'');  -- Cannot remove from public role

    OPEN role_cursor;
    FETCH NEXT FROM role_cursor INTO @RoleName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            EXEC sp_droprolemember @RoleName, N''' + @LoginName + N''';
            SET @RoleCount = @RoleCount + 1;
            PRINT ''  ✓ Removed from role: '' + @RoleName;
        END TRY
        BEGIN CATCH
            PRINT ''  ✗ Error removing from role '' + @RoleName + '': '' + ERROR_MESSAGE();
        END CATCH

        FETCH NEXT FROM role_cursor INTO @RoleName;
    END

    CLOSE role_cursor;
    DEALLOCATE role_cursor;

    IF @RoleCount > 0
    BEGIN
        PRINT '''';
        PRINT ''Removed from '' + CAST(@RoleCount as nvarchar(10)) + '' role(s)'';
        PRINT '''';
    END

    -- Drop user from database
    BEGIN TRY
        DROP USER [' + @LoginName + N'];
        PRINT ''✓ Dropped user [' + @LoginName + N'] from [' + @SourceDb + N']'';
    END TRY
    BEGIN CATCH
        PRINT ''✗ Error dropping user [' + @LoginName + N']: '' + ERROR_MESSAGE();
    END CATCH
END
';

EXEC (@SourceSql);

------------------------------------------------------------
-- Summary
------------------------------------------------------------
PRINT '';
PRINT '========================================';
PRINT 'Access revocation completed!';
PRINT '========================================';
PRINT '';
PRINT 'Login: [' + @LoginName + ']';
PRINT 'Database: [' + @SourceDb + ']';
PRINT '';
PRINT 'All permissions and role memberships have been dynamically detected and revoked.';
PRINT 'The database user has been dropped.';
PRINT '';
GO
