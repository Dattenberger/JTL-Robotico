-- 0001_roboticoops_settings.sql  (Ebene B / global chain — runs in RoboticoOps)
--
-- Asserts the invariants the RoboticoOps admin DB must satisfy and hardens its
-- settings. grate creates the database itself if it is missing (connection targets
-- RoboticoOps); this one-time script runs once, right after, to make the DB safe.
--
-- Invariants (a mismatch is a HARD FAIL — never silently accepted):
--   * Collation = Latin1_General_CI_AS  (must match the eazybusiness family so that
--     cross-DB joins / string comparisons in the reset pipeline do not throw
--     collation-conflict errors).
--   * TRUSTWORTHY = OFF  (the reset security model uses module signing, never
--     TRUSTWORTHY — see adr-module-signing-reset / research/3).
-- Hardening:
--   * RECOVERY FULL  (transactional/point-in-time recovery for the ops metadata —
--     requires the instance backup plan to include RoboticoOps log backups, or the
--     log will grow unbounded).
--   * Owner = sa        (stable, well-known owner; avoids an accidental personal owner).
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§2)

SET NOCOUNT ON;

DECLARE @db sysname = DB_NAME();

-- --- Collation assert (hard fail) ------------------------------------------------
DECLARE @collation sysname = CONVERT(sysname, DATABASEPROPERTYEX(@db, 'Collation'));
IF @collation IS NULL OR @collation <> N'Latin1_General_CI_AS'
BEGIN
    DECLARE @msgC nvarchar(2000) =
        N'RoboticoOps has collation ''' + ISNULL(@collation, N'(unknown)')
        + N''' but Latin1_General_CI_AS is required. Recreate the database with '
        + N'CREATE DATABASE [RoboticoOps] COLLATE Latin1_General_CI_AS; (or ALTER '
        + N'DATABASE ... COLLATE ...) and re-deploy. Aborting to avoid collation drift.';
    THROW 50001, @msgC, 1;
END

-- --- Recovery model --------------------------------------------------------------
IF (SELECT recovery_model FROM sys.databases WHERE name = @db) <> 1  -- 1 = FULL
    ALTER DATABASE CURRENT SET RECOVERY FULL;

-- --- Owner = sa ------------------------------------------------------------------
-- Only re-authorize if the current owner is not already sa (idempotent, avoids noise).
IF NOT EXISTS (
    SELECT 1
    FROM sys.databases d
    JOIN sys.server_principals sp ON d.owner_sid = sp.sid
    WHERE d.name = @db AND sp.name = N'sa'
)
BEGIN
    DECLARE @auth nvarchar(400) =
        N'ALTER AUTHORIZATION ON DATABASE::' + QUOTENAME(@db) + N' TO [sa];';
    EXEC (@auth);
END

-- --- TRUSTWORTHY OFF (hardening + assert) ---------------------------------------
IF (SELECT is_trustworthy_on FROM sys.databases WHERE name = @db) = 1
    ALTER DATABASE CURRENT SET TRUSTWORTHY OFF;

IF (SELECT is_trustworthy_on FROM sys.databases WHERE name = @db) = 1
    THROW 50002, N'RoboticoOps is still TRUSTWORTHY ON after ALTER — aborting.', 1;

PRINT 'RoboticoOps settings verified: collation OK, RECOVERY FULL, owner sa, TRUSTWORTHY OFF.';
GO
