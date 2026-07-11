-- 100_grants.sql  (Ebene B / global — permissions, everytime)
--
-- Runtime grants for the reset entry points, plus the reset-operator membership for
-- the JTL Windows AD group. Runs every deploy (permissions are grate's last stage),
-- after sprocs, so the procedures exist.
--
--   * EXECUTE on the four colleague-facing reset SPs (start / status / discover / cancel)
--     -> ops_reset_executor.
--   * EXECUTE on reset.PurgeOldRequests (audit retention) -> ops_admin only, so a reset
--     operator can never erase the audit trail (OPS-5).
--   * The AD group ZDBIKES\sql-jtl-users becomes a RoboticoOps user (guarded — a
--     missing login is a PRINT warning, not a failure) and joins ops_reset_executor.
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§2)

SET NOCOUNT ON;

-- Colleague self-service surface (trigger / poll / discover / recover) -> ops_reset_executor.
IF OBJECT_ID(N'reset.StartTestmandantReset') IS NOT NULL
    GRANT EXECUTE ON OBJECT::reset.StartTestmandantReset TO ops_reset_executor;
IF OBJECT_ID(N'reset.GetResetStatus') IS NOT NULL
    GRANT EXECUTE ON OBJECT::reset.GetResetStatus TO ops_reset_executor;
IF OBJECT_ID(N'reset.ListMandants') IS NOT NULL
    GRANT EXECUTE ON OBJECT::reset.ListMandants TO ops_reset_executor;
IF OBJECT_ID(N'reset.CancelResetRequest') IS NOT NULL
    GRANT EXECUTE ON OBJECT::reset.CancelResetRequest TO ops_reset_executor;

-- Audit-retention purge is admin-only (never an operator right).
IF OBJECT_ID(N'reset.PurgeOldRequests') IS NOT NULL
    GRANT EXECUTE ON OBJECT::reset.PurgeOldRequests TO ops_admin;

DECLARE @adGroup sysname = N'ZDBIKES\sql-jtl-users';

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = @adGroup)
BEGIN
    PRINT '! Login [' + @adGroup + '] not found — skipping RoboticoOps user + ops_reset_executor membership.';
END
ELSE
BEGIN
    -- EXEC() does not accept a function call (QUOTENAME) inside its concatenated argument
    -- ("Incorrect syntax near 'QUOTENAME'"); build the statement in a variable first.
    DECLARE @sql nvarchar(400);

    IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @adGroup)
    BEGIN
        SET @sql = N'CREATE USER ' + QUOTENAME(@adGroup) + N' FOR LOGIN ' + QUOTENAME(@adGroup) + N';';
        EXEC (@sql);
    END

    IF NOT EXISTS (
        SELECT 1 FROM sys.database_role_members rm
        JOIN sys.database_principals r ON rm.role_principal_id = r.principal_id
        JOIN sys.database_principals m ON rm.member_principal_id = m.principal_id
        WHERE r.name = N'ops_reset_executor' AND m.name = @adGroup)
    BEGIN
        SET @sql = N'ALTER ROLE ops_reset_executor ADD MEMBER ' + QUOTENAME(@adGroup) + N';';
        EXEC (@sql);
    END
END
GO
