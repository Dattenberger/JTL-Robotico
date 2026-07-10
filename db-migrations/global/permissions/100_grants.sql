-- 100_grants.sql  (Ebene B / global — permissions, everytime)
--
-- Runtime grants for the reset entry points, plus the reset-operator membership for
-- the JTL Windows AD group. Runs every deploy (permissions are grate's last stage),
-- after sprocs, so the procedures exist.
--
--   * EXECUTE on reset.StartTestmandantReset + reset.GetResetStatus -> ops_reset_executor.
--   * The AD group ZDBIKES\sql-jtl-users becomes a RoboticoOps user (guarded — a
--     missing login is a PRINT warning, not a failure) and joins ops_reset_executor.
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§2)

SET NOCOUNT ON;

IF OBJECT_ID(N'reset.StartTestmandantReset') IS NOT NULL
    GRANT EXECUTE ON OBJECT::reset.StartTestmandantReset TO ops_reset_executor;
IF OBJECT_ID(N'reset.GetResetStatus') IS NOT NULL
    GRANT EXECUTE ON OBJECT::reset.GetResetStatus TO ops_reset_executor;

DECLARE @adGroup sysname = N'ZDBIKES\sql-jtl-users';

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = @adGroup)
BEGIN
    PRINT '! Login [' + @adGroup + '] not found — skipping RoboticoOps user + ops_reset_executor membership.';
END
ELSE
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @adGroup)
        EXEC (N'CREATE USER ' + QUOTENAME(@adGroup) + N' FOR LOGIN ' + QUOTENAME(@adGroup) + N';');

    IF NOT EXISTS (
        SELECT 1 FROM sys.database_role_members rm
        JOIN sys.database_principals r ON rm.role_principal_id = r.principal_id
        JOIN sys.database_principals m ON rm.member_principal_id = m.principal_id
        WHERE r.name = N'ops_reset_executor' AND m.name = @adGroup)
        EXEC (N'ALTER ROLE ops_reset_executor ADD MEMBER ' + QUOTENAME(@adGroup) + N';');
END
GO
