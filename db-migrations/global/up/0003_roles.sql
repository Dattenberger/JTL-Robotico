-- 0003_roles.sql  (Ebene B / global chain — runs in RoboticoOps)
--
-- Database roles for RoboticoOps:
--   ops_reset_executor — colleagues who may TRIGGER a reset and READ its status.
--                        They get EXECUTE on reset.StartTestmandantReset /
--                        reset.GetResetStatus (granted in permissions/100_grants).
--                        They are DENIED the ShopLicense column so a reset operator
--                        can never read a mandant's shop license key.
--   ops_admin          — full control of the ops registry (maintain ops.Mandant /
--                        ops.Config). Membership is assigned by a human, out of band.
--
-- Roles carry the permissions; membership is data (assigned in permissions/100 for
-- the AD group, and manually for individuals). Idempotent.
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§2)

SET NOCOUNT ON;

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'ops_reset_executor' AND type = 'R')
    CREATE ROLE ops_reset_executor AUTHORIZATION dbo;

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'ops_admin' AND type = 'R')
    CREATE ROLE ops_admin AUTHORIZATION dbo;

-- ops_admin maintains the registry tables.
GRANT SELECT, INSERT, UPDATE, DELETE ON ops.Mandant TO ops_admin;
GRANT SELECT, INSERT, UPDATE, DELETE ON ops.Config  TO ops_admin;
-- ResetRequest is written by the reset pipeline, not hand-maintained, so ops_admin gets
-- SELECT + UPDATE (not INSERT/DELETE): UPDATE lets an admin hand-fix a stuck row (the
-- recovery path the runbook documents — OPS-2) without raw sysadmin. Bulk deletion goes
-- exclusively through reset.PurgeOldRequests (ownership-chained), so no direct DELETE is
-- granted — the audit trail cannot be casually erased.
GRANT SELECT, UPDATE ON ops.ResetRequest TO ops_admin;

-- Reset operators must never see license keys. GetResetStatus already omits the
-- column; this column-level DENY is defense in depth in case someone grants the
-- role broader SELECT later.
DENY SELECT ON ops.Mandant (ShopLicense) TO ops_reset_executor;
GO
