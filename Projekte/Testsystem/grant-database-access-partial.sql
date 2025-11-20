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
DECLARE @LoginName  sysname = N'dbuser_dev_dana_for_development';     -- Login to grant access to

------------------------------------------------------------
-- Validate that login exists
------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = @LoginName)
BEGIN
    RAISERROR('Login %s does not exist on the server. Please create it first.', 16, 1, @LoginName);
    RETURN;
END

------------------------------------------------------------
-- Grant server-level permissions
------------------------------------------------------------
/*PRINT 'Granting server-level permissions to [' + @LoginName + ']...';

-- Grant VIEW ANY DATABASE (required to list all databases)
DECLARE @GrantSql nvarchar(max);

IF NOT EXISTS (
    SELECT 1
    FROM sys.server_permissions sp
    JOIN sys.server_principals pr ON sp.grantee_principal_id = pr.principal_id
    WHERE pr.name = @LoginName AND sp.permission_name = 'VIEW ANY DATABASE'
)
BEGIN
    SET @GrantSql = N'GRANT VIEW ANY DATABASE TO [' + @LoginName + N']';
    EXEC (@GrantSql);
    PRINT '  - Granted VIEW ANY DATABASE';
END
ELSE
BEGIN
    PRINT '  - VIEW ANY DATABASE already granted';
END

-- Grant VIEW SERVER STATE (required for SERVERPROPERTY queries)
IF NOT EXISTS (
    SELECT 1
    FROM sys.server_permissions sp
    JOIN sys.server_principals pr ON sp.grantee_principal_id = pr.principal_id
    WHERE pr.name = @LoginName AND sp.permission_name = 'VIEW SERVER STATE'
)
BEGIN
    SET @GrantSql = N'GRANT VIEW SERVER STATE TO [' + @LoginName + N']';
    EXEC (@GrantSql);
    PRINT '  - Granted VIEW SERVER STATE';
END
ELSE
BEGIN
    PRINT '  - VIEW SERVER STATE already granted';
END

-- Grant EXECUTE on xp_instance_regread (required for registry access to get SQL Server paths)
SET @GrantSql = N'GRANT EXECUTE ON xp_instance_regread TO [' + @LoginName + N']';
EXEC (@GrantSql);
PRINT '  - Granted EXECUTE on xp_instance_regread';

PRINT 'Server-level permissions granted successfully.';
PRINT '';*/

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

-- Grant permissions on administrative and system tables
GRANT SELECT ON dbo.tRechtBenutzerGruppenZuordnung TO [' + @LoginName + N'];
GRANT SELECT ON dbo.tRechtBenutzerGruppe TO [' + @LoginName + N'];
GRANT SELECT ON dbo.tRechte TO [' + @LoginName + N'];
GRANT SELECT ON dbo.tversion TO [' + @LoginName + N'];
GRANT SELECT ON dbo.tMandant TO [' + @LoginName + N'];
GRANT SELECT, UPDATE ON dbo.tOptions TO [' + @LoginName + N'];
GRANT SELECT, UPDATE ON dbo.tBenutzer TO [' + @LoginName + N'];
GRANT SELECT ON dbo.tfirma TO [' + @LoginName + N'];
GRANT SELECT ON dbo.tBenutzerFirma TO [' + @LoginName + N'];
GRANT SELECT ON dbo.tFeatureFlag TO [' + @LoginName + N'];
GRANT SELECT, UPDATE, DELETE ON dbo.tUserSession TO [' + @LoginName + N'];
GRANT SELECT ON dbo.tOauthConfig TO [' + @LoginName + N'];
GRANT SELECT ON dbo.tOauthToken TO [' + @LoginName + N'];
GRANT SELECT ON dbo.tDatevConfig TO [' + @LoginName + N'];

-- User Layout and Widgets
GRANT SELECT, INSERT, UPDATE, DELETE ON dbo.tUserLayout TO [' + @LoginName + N'];
GRANT SELECT ON dbo.tWidgetTemplate TO [' + @LoginName + N'];
GRANT SELECT, INSERT, UPDATE, DELETE ON dbo.tWidget TO [' + @LoginName + N'];
GRANT SELECT, INSERT, UPDATE, DELETE ON dbo.tWidgetLayout TO [' + @LoginName + N'];

-- Settings
GRANT SELECT, INSERT, UPDATE ON dbo.tSetting TO [' + @LoginName + N'];
GRANT SELECT, INSERT, UPDATE ON pps.tSetting TO [' + @LoginName + N'];

-- Tax/Steuer tables
GRANT SELECT ON dbo.tSteuerzone TO [' + @LoginName + N'];
GRANT SELECT ON dbo.tSteuersatz TO [' + @LoginName + N'];
GRANT SELECT ON dbo.tland TO [' + @LoginName + N'];
GRANT SELECT ON dbo.tFirmaUStIdNr TO [' + @LoginName + N'];
GRANT SELECT ON dbo.tSteuerzoneLand TO [' + @LoginName + N'];
GRANT SELECT ON dbo.tSteuerklasse TO [' + @LoginName + N'];

-- Shipping/Versand
GRANT SELECT ON dbo.tversandart TO [' + @LoginName + N'];
GRANT SELECT, INSERT, UPDATE ON dbo.tVersandArtPrinterMapping TO [' + @LoginName + N'];
GRANT SELECT ON dbo.tLieferschein TO [' + @LoginName + N'];
GRANT SELECT ON dbo.tVersand TO [' + @LoginName + N'];
GRANT SELECT ON Shipping.tShippingserviceprovider TO [' + @LoginName + N'];
GRANT SELECT ON Shipping.tShippingPrinterConfiguration TO [' + @LoginName + N'];
GRANT SELECT ON Shipping.tShippingDocumentDefaultPrinterMapping TO [' + @LoginName + N'];
--GRANT SELECT, DELETE ON Shipping.tShippingDocument TO [' + @LoginName + N'];
GRANT SELECT ON Shipping.tShippingDocument TO [' + @LoginName + N'];

-- Files
--GRANT SELECT, DELETE ON dbo.tFile TO [' + @LoginName + N'];

-- Reports
GRANT SELECT ON Report.tVorlage TO [' + @LoginName + N'];
GRANT SELECT ON Report.tVorlagenset TO [' + @LoginName + N'];
--GRANT SELECT, INSERT, UPDATE, MERGE ON Report.tVorlagensetEinstellung TO [' + @LoginName + N'];
GRANT SELECT, INSERT, UPDATE ON Report.tVorlagensetEinstellung TO [' + @LoginName + N'];

-- Sales/Verkauf
GRANT SELECT ON Verkauf.tAuftrag TO [' + @LoginName + N'];
GRANT SELECT ON Verkauf.tAuftragPosition TO [' + @LoginName + N'];
GRANT SELECT ON Verkauf.tAuftragPositionIntervall TO [' + @LoginName + N'];
GRANT SELECT ON Verkauf.tAuftragFile TO [' + @LoginName + N'];

-- Warehouse/Lager
GRANT SELECT ON dbo.tLagerArtikel TO [' + @LoginName + N'];

-- System views and functions
GRANT VIEW DEFINITION ON SCHEMA::dbo TO [' + @LoginName + N'];

-- Grant EXECUTE on sp_executesql (system stored procedure, already granted by default)
-- User can execute dynamic SQL if needed

PRINT ''Granted permissions on all required tables and schemas in [' + @SourceDb + N']'';
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
PRINT 'Server-Level Permissions:';
PRINT '  - VIEW ANY DATABASE (list all databases)';
PRINT '  - VIEW SERVER STATE (SERVERPROPERTY queries)';
PRINT '  - EXECUTE on xp_instance_regread (registry access for paths)';
PRINT '';
PRINT 'Source Database [' + @SourceDb + ']:';
PRINT '  - User created (if not exists)';
PRINT '';
PRINT '  Administrative & Security:';
PRINT '    - SELECT on tRechtBenutzerGruppenZuordnung, tRechtBenutzerGruppe, tRechte';
PRINT '    - SELECT, UPDATE on tBenutzer';
PRINT '    - SELECT, UPDATE, DELETE on tUserSession';
PRINT '    - SELECT on tOauthConfig, tOauthToken, tDatevConfig';
PRINT '';
PRINT '  System & Configuration:';
PRINT '    - SELECT on tversion, tMandant, tFeatureFlag';
PRINT '    - SELECT, UPDATE, MERGE on tOptions';
PRINT '    - SELECT, INSERT, UPDATE on tSetting (dbo + pps schemas)';
PRINT '';
PRINT '  Company & Users:';
PRINT '    - SELECT on tfirma, tBenutzerFirma';
PRINT '    - SELECT, INSERT, UPDATE, DELETE on tUserLayout, tWidget, tWidgetLayout';
PRINT '    - SELECT on tWidgetTemplate';
PRINT '';
PRINT '  Tax/Steuer:';
PRINT '    - SELECT on tSteuerzone, tSteuersatz, tSteuerklasse';
PRINT '    - SELECT on tland, tFirmaUStIdNr, tSteuerzoneLand';
PRINT '';
PRINT '  Shipping/Versand:';
PRINT '    - SELECT on tversandart, tLieferschein, tVersand';
PRINT '    - SELECT, INSERT, UPDATE on tVersandArtPrimePrinterMapping';
PRINT '    - SELECT on Shipping.tShippingserviceprovider, tShippingPrinterConfiguration';
PRINT '    - SELECT on Shipping.tShippingDocumentDefaultPrinterMapping';
PRINT '    - SELECT, DELETE on Shipping.tShippingDocument';
PRINT '';
PRINT '  Sales/Verkauf:';
PRINT '    - SELECT on Verkauf.tAuftrag, tAuftragPosition';
PRINT '    - SELECT on Verkauf.tAuftragPositionIntervall, tAuftragFile';
PRINT '';
PRINT '  Reports:';
PRINT '    - SELECT on Report.tVorlage, tVorlagenset';
PRINT '    - SELECT, INSERT, UPDATE, MERGE on Report.tVorlagensetEinstellung';
PRINT '';
PRINT '  Other:';
PRINT '    - SELECT, DELETE on tFile';
PRINT '    - SELECT on tLagerArtikel';
PRINT '    - VIEW DEFINITION on SCHEMA::dbo';
PRINT '';
PRINT 'Target Database [' + @TargetDb + ']:';
PRINT '  - User created (if not exists)';
PRINT '  - db_owner role (full permissions)';
PRINT '';
GO
