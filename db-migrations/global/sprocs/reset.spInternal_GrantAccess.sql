-- reset.spInternal_GrantAccess  (Ebene B / global — pipeline step, job-only)
--
-- Ported from Projekte/Testsystem/grant-database-access.sql. Ensures the mandant's
-- developer login (cLoginName, read from ops.tMandant by @MandantKey — uniform step
-- contract, EXT-2) has a user in the clone and is a db_owner there. Runs inside the
-- target DB via QUOTENAME(@TargetDb).sys.sp_executesql; the login name is passed as a
-- parameter and only ever placed into DDL via QUOTENAME.
--
-- Deviations (D4): a missing login is a cStepLog note, not a hard error (the clone is
-- valid; access can be granted later) — the source RAISERROR'd. Uses ALTER ROLE ...
-- ADD MEMBER instead of the deprecated sp_addrolemember.
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§3)
CREATE OR ALTER PROCEDURE reset.spInternal_GrantAccess
    @TargetDb   sysname,
    @RequestId  int,
    @MandantKey sysname
AS
BEGIN
    SET NOCOUNT ON;

    IF @TargetDb = N'eazybusiness' OR @TargetDb NOT LIKE N'eazybusiness[_]%'
        THROW 51060, 'spInternal_GrantAccess refused: target is not a test-mandant clone.', 1;

    -- Each step reads its own inputs from ops.tMandant (EXT-2).
    DECLARE @LoginName sysname;
    SELECT @LoginName = cLoginName FROM ops.tMandant WHERE cMandantKey = @MandantKey;

    DECLARE @note nvarchar(200);

    IF @LoginName IS NULL OR NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = @LoginName)
    BEGIN
        -- WARN prefix so a skipped grant is obvious in reset.spPub_GetResetStatus (PAR-1):
        -- the reset still 'succeeds', but no developer has db_owner on the clone.
        SET @note = N'WARN access-skipped: login ' + ISNULL(@LoginName, N'(none)')
                  + N' not found on server — developer has NO db_owner on ' + @TargetDb;
    END
    ELSE
    BEGIN
        DECLARE @exec nvarchar(300) = QUOTENAME(@TargetDb) + N'.sys.sp_executesql';
        -- Inside the target-DB batch the same EXEC() rule applies: a function call cannot
        -- sit in EXEC()'s concatenated argument, so build each statement into @s first.
        DECLARE @batch nvarchar(max) = N'
            DECLARE @s nvarchar(max);
            IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @ln)
            BEGIN
                SET @s = N''CREATE USER '' + QUOTENAME(@ln) + N'' FOR LOGIN '' + QUOTENAME(@ln) + N'';'';
                EXEC(@s);
            END
            IF NOT EXISTS (
                SELECT 1 FROM sys.database_role_members rm
                JOIN sys.database_principals r ON rm.role_principal_id = r.principal_id
                JOIN sys.database_principals u ON rm.member_principal_id = u.principal_id
                WHERE r.name = N''db_owner'' AND u.name = @ln)
            BEGIN
                SET @s = N''ALTER ROLE db_owner ADD MEMBER '' + QUOTENAME(@ln) + N'';'';
                EXEC(@s);
            END
        ';
        EXEC @exec @batch, N'@ln sysname', @ln = @LoginName;
        SET @note = N'access: ' + @LoginName + N' is db_owner on ' + @TargetDb;
    END

    EXEC reset.spInternal_LogStep @RequestId, @note;
END
GO
