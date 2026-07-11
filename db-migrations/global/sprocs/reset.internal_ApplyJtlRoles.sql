-- reset.internal_ApplyJtlRoles  (Ebene B / global — pipeline step, job-only)
--
-- Ported from Berechtigungen/JTL-Rollen.sql, parameterised on the target clone. Runs
-- inside the target DB (QUOTENAME(@TargetDb).sys.sp_executesql) and ensures the
-- JTL_Reader / JTL_Writer profile roles exist, inherit db_datareader/-writer, grant
-- EXECUTE on the Robotico schema, and carry their members. Additive and idempotent;
-- missing principals are skipped.
--
-- Deviations (D4, documented):
--   * The GRANT EXECUTE ON SCHEMA::RoboticoEKL (present in the source) is OMITTED —
--     that schema is excel_ekl's territory (D10 boundary; also a lint-forbidden
--     token). A restored clone already carries whatever grants prod had; the EKL
--     runner owns re-granting its own schema.
--   * The member list mirrors Berechtigungen/JTL-Rollen.sql, which stays the single
--     source of truth for prod; keep the two in sync when the team changes.
--
-- EXT-4 (decision, no code change): the JTL_Reader/JTL_Writer membership stays a code
-- SSoT here rather than a runtime ops.RoleMember table — a runtime table would give
-- editability but split the single source of truth that JTL-Rollen.sql owns for prod.
-- Membership changes rarely; when it does, edit both mirrors and redeploy. See
-- adrs/adr-reset-step-registry.md §Alternatives.
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§3)
-- @see Berechtigungen/JTL-Rollen.sql
CREATE OR ALTER PROCEDURE reset.internal_ApplyJtlRoles
    @TargetDb   sysname,
    @RequestId  int,
    @MandantKey sysname   -- uniform step contract (EXT-2); not used by this step
AS
BEGIN
    SET NOCOUNT ON;

    IF @TargetDb = N'eazybusiness' OR @TargetDb NOT LIKE N'eazybusiness[_]%'
        THROW 51080, 'internal_ApplyJtlRoles refused: target is not a test-mandant clone.', 1;

    DECLARE @exec nvarchar(300) = QUOTENAME(@TargetDb) + N'.sys.sp_executesql';
    DECLARE @batch nvarchar(max) = N'
        IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = ''JTL_Reader'' AND type = ''R'') CREATE ROLE JTL_Reader;
        IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = ''JTL_Writer'' AND type = ''R'') CREATE ROLE JTL_Writer;

        IF NOT EXISTS (SELECT 1 FROM sys.database_role_members rm
                       JOIN sys.database_principals r ON rm.role_principal_id = r.principal_id
                       JOIN sys.database_principals m ON rm.member_principal_id = m.principal_id
                       WHERE r.name = ''db_datareader'' AND m.name = ''JTL_Reader'')
            ALTER ROLE db_datareader ADD MEMBER JTL_Reader;
        IF NOT EXISTS (SELECT 1 FROM sys.database_role_members rm
                       JOIN sys.database_principals r ON rm.role_principal_id = r.principal_id
                       JOIN sys.database_principals m ON rm.member_principal_id = m.principal_id
                       WHERE r.name = ''db_datawriter'' AND m.name = ''JTL_Writer'')
            ALTER ROLE db_datawriter ADD MEMBER JTL_Writer;

        IF EXISTS (SELECT 1 FROM sys.schemas WHERE name = ''Robotico'')
            GRANT EXECUTE ON SCHEMA::Robotico TO JTL_Reader;

        DECLARE @M TABLE (RoleName sysname, PrincipalName sysname);
        INSERT INTO @M (RoleName, PrincipalName) VALUES
            (N''JTL_Reader'', N''ZDBIKES\sql-jtl-users''),
            (N''JTL_Reader'', N''dbuser_eazybusiness_kiana''),
            (N''JTL_Reader'', N''dbuser_eazybusiness_sanda''),
            (N''JTL_Reader'', N''dbuser_eazybusiness_jtl_datawow''),
            (N''JTL_Reader'', N''dbuser_eazybusiness_powershell_read''),
            (N''JTL_Reader'', N''dbuser_eazybusiness_greyhound''),
            (N''JTL_Reader'', N''dbuser_eazybusiness_ekl_addin_readonly''),
            (N''JTL_Writer'', N''dbuser_eazybusiness_kiana'');

        DECLARE @role sysname, @p sysname, @sql nvarchar(max);
        DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT RoleName, PrincipalName FROM @M;
        OPEN c; FETCH NEXT FROM c INTO @role, @p;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @p)
               AND NOT EXISTS (SELECT 1 FROM sys.database_role_members rm
                               JOIN sys.database_principals r ON rm.role_principal_id = r.principal_id
                               JOIN sys.database_principals m ON rm.member_principal_id = m.principal_id
                               WHERE r.name = @role AND m.name = @p)
            BEGIN
                SET @sql = N''ALTER ROLE '' + QUOTENAME(@role) + N'' ADD MEMBER '' + QUOTENAME(@p) + N'';'';
                EXEC (@sql);
            END
            FETCH NEXT FROM c INTO @role, @p;
        END
        CLOSE c; DEALLOCATE c;
    ';
    EXEC @exec @batch;

    EXEC reset.internal_LogStep @RequestId,
         N'roles: JTL_Reader/JTL_Writer ensured + members applied';
END
GO
