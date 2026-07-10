-- reset.internal_GrantAccess  (Ebene B / global — pipeline step, job-only)
--
-- Ported from Projekte/Testsystem/grant-database-access.sql. Ensures the mandant's
-- developer login (@LoginName from ops.Mandant) has a user in the clone and is a
-- db_owner there. Runs inside the target DB via QUOTENAME(@TargetDb).sys.sp_executesql;
-- the login name is passed as a parameter and only ever placed into DDL via QUOTENAME.
--
-- Deviations (D4): a missing login is a StepLog note, not a hard error (the clone is
-- valid; access can be granted later) — the source RAISERROR'd. Uses ALTER ROLE ...
-- ADD MEMBER instead of the deprecated sp_addrolemember.
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§3)
CREATE OR ALTER PROCEDURE reset.internal_GrantAccess
    @TargetDb  sysname,
    @RequestId int,
    @LoginName sysname
AS
BEGIN
    SET NOCOUNT ON;

    IF @TargetDb = N'eazybusiness' OR @TargetDb NOT LIKE N'eazybusiness[_]%'
        THROW 51060, 'internal_GrantAccess refused: target is not a test-mandant clone.', 1;

    DECLARE @note nvarchar(200);

    IF @LoginName IS NULL OR NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = @LoginName)
    BEGIN
        SET @note = N' access: login ' + ISNULL(@LoginName, N'(none)') + N' not found on server — skipped';
    END
    ELSE
    BEGIN
        DECLARE @exec nvarchar(300) = QUOTENAME(@TargetDb) + N'.sys.sp_executesql';
        DECLARE @batch nvarchar(max) = N'
            IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @ln)
                EXEC(N''CREATE USER '' + QUOTENAME(@ln) + N'' FOR LOGIN '' + QUOTENAME(@ln) + N'';'');
            IF NOT EXISTS (
                SELECT 1 FROM sys.database_role_members rm
                JOIN sys.database_principals r ON rm.role_principal_id = r.principal_id
                JOIN sys.database_principals u ON rm.member_principal_id = u.principal_id
                WHERE r.name = N''db_owner'' AND u.name = @ln)
                EXEC(N''ALTER ROLE db_owner ADD MEMBER '' + QUOTENAME(@ln) + N'';'');
        ';
        EXEC @exec @batch, N'@ln sysname', @ln = @LoginName;
        SET @note = N' access: ' + @LoginName + N' is db_owner on ' + @TargetDb;
    END

    UPDATE ops.ResetRequest
       SET StepLog = ISNULL(StepLog, N'') + CONVERT(nvarchar(19), SYSUTCDATETIME(), 126) + @note + NCHAR(10),
           ModifiedAt = SYSUTCDATETIME()
     WHERE RequestId = @RequestId;
END
GO
