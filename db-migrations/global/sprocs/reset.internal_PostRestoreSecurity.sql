-- reset.internal_PostRestoreSecurity  (Ebene B / global — pipeline step, job-only)
--
-- The best-practice post-restore sequence (research/3 §5): set owner -> sa, remap
-- orphaned users to matching server logins (ALTER USER WITH LOGIN — never the
-- deprecated sp_change_users_login), best-effort drop of the remaining true orphans,
-- then verify TRUSTWORTHY is OFF (a restore can carry it in from the backup).
--
-- Runs the per-user work inside the TARGET database via
-- QUOTENAME(@TargetDb).sys.sp_executesql — no USE, object/DB names via QUOTENAME.
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§3)
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur/research/3-module-signing-agent-job
CREATE OR ALTER PROCEDURE reset.internal_PostRestoreSecurity
    @TargetDb   sysname,
    @RequestId  int,
    @MandantKey sysname   -- uniform step contract (EXT-2); not used by this step
AS
BEGIN
    SET NOCOUNT ON;

    IF @TargetDb = N'eazybusiness' OR @TargetDb NOT LIKE N'eazybusiness[_]%'
        THROW 51020, 'internal_PostRestoreSecurity refused: target is not a test-mandant clone.', 1;

    -- 1. Owner -> sa (the restored backup carries the old owner SID).
    EXEC (N'ALTER AUTHORIZATION ON DATABASE::' + QUOTENAME(@TargetDb) + N' TO [sa];');

    -- 2. + 3. Orphan remap and cleanup, inside the target DB.
    DECLARE @exec nvarchar(300) = QUOTENAME(@TargetDb) + N'.sys.sp_executesql';
    DECLARE @batch nvarchar(max) = N'
        DECLARE @u sysname, @sql nvarchar(max);

        -- Remap users whose SID no longer matches but whose login exists by name.
        DECLARE remap CURSOR LOCAL FAST_FORWARD FOR
            SELECT dp.name
            FROM sys.database_principals dp
            WHERE dp.type IN (''S'',''U'',''G'')
              AND dp.sid IS NOT NULL
              AND dp.authentication_type_desc IN (''INSTANCE'',''WINDOWS'')
              AND dp.name NOT IN (''dbo'',''guest'')
              AND NOT EXISTS (SELECT 1 FROM sys.server_principals sp  WHERE sp.sid  = dp.sid)
              AND EXISTS     (SELECT 1 FROM sys.server_principals sp2 WHERE sp2.name = dp.name);
        OPEN remap;
        FETCH NEXT FROM remap INTO @u;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                SET @sql = N''ALTER USER '' + QUOTENAME(@u) + N'' WITH LOGIN = '' + QUOTENAME(@u) + N'';'';
                EXEC (@sql);
            END TRY BEGIN CATCH END CATCH
            FETCH NEXT FROM remap INTO @u;
        END
        CLOSE remap; DEALLOCATE remap;

        -- Best-effort drop of genuine orphans (no matching login by SID or name) that
        -- do not own a schema. Per-user TRY/CATCH so an undroppable user never breaks
        -- the reset — orphaned users in a throwaway clone are harmless if left.
        DECLARE dead CURSOR LOCAL FAST_FORWARD FOR
            SELECT dp.name
            FROM sys.database_principals dp
            WHERE dp.type IN (''S'',''U'',''G'')
              AND dp.sid IS NOT NULL
              AND dp.authentication_type_desc IN (''INSTANCE'',''WINDOWS'')
              AND dp.name NOT IN (''dbo'',''guest'')
              AND NOT EXISTS (SELECT 1 FROM sys.server_principals sp  WHERE sp.sid  = dp.sid)
              AND NOT EXISTS (SELECT 1 FROM sys.server_principals sp2 WHERE sp2.name = dp.name)
              AND NOT EXISTS (SELECT 1 FROM sys.schemas s WHERE s.principal_id = dp.principal_id);
        OPEN dead;
        FETCH NEXT FROM dead INTO @u;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                SET @sql = N''DROP USER '' + QUOTENAME(@u) + N'';'';
                EXEC (@sql);
            END TRY BEGIN CATCH END CATCH
            FETCH NEXT FROM dead INTO @u;
        END
        CLOSE dead; DEALLOCATE dead;
    ';
    EXEC @exec @batch;

    -- 4. TRUSTWORTHY OFF + assert.
    EXEC (N'ALTER DATABASE ' + QUOTENAME(@TargetDb) + N' SET TRUSTWORTHY OFF;');
    IF (SELECT is_trustworthy_on FROM sys.databases WHERE name = @TargetDb) = 1
        THROW 51021, 'internal_PostRestoreSecurity: TRUSTWORTHY is still ON after ALTER.', 1;

    EXEC reset.internal_LogStep @RequestId,
         N'security: owner=sa, orphans remapped/cleaned, TRUSTWORTHY OFF';
END
GO
