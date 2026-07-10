-- ============================================================================
-- 03_pf_user_in_clones.sql — Amazon/platform accounts (pf_user) per DB — Open Q O4
-- ============================================================================
-- Answers O4: "Do the tm* clones actually contain pf_user (Amazon/platform) rows,
-- so that the reset's pf_user neutralisation (nGesperrt=1, nAktiv=0) has anything
-- to act on?" The prod main DB survey found 0 pf_user rows there; the clones and
-- mandant DBs were still open. This probe enumerates every eazybusiness* database
-- on the current instance and reports its pf_user population.
--
-- STRICTLY READ-ONLY. It only SELECTs — the dynamic SQL runs SELECT/COUNT only.
-- Run against the whole instance (it iterates DBs itself, so the -d target only
-- needs to be a DB you can connect to):
--   /opt/mssql-tools18/bin/sqlcmd -S vm-sql2.zdbikes.local -E -C \
--       -d master -i db-migrations/tests/probes/03_pf_user_in_clones.sql
--
-- The prod instance (vm-sql2) is where the tm* clones live, so O4 is best answered
-- there. test1 has only eazybusiness (+ an e2e snapshot).
--
-- Recorded result — vm-sql-test1 (2026-07-10, this repo's C3 run):
--   eazybusiness                 -> pf_user = 0 rows
--   eazybusiness_e2e_r3_pre_snap -> pf_user = 0 rows
--   => On test1 there are no Amazon accounts to neutralise. The prod tm* clones
--      still need a manual run (constraint: this session may only read test1).
--      O4 note: the reset's pf_user step is IF OBJECT_ID-guarded and no-ops on an
--      empty table, so it is correct whether or not clones carry pf_user rows.
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur/mssql-ops-infrastruktur.md §4 (Validierung & Probeliste, Open Question O4)
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur/mssql-ops-infrastruktur.md §D9 (pf_user neutralisation this probe scopes)
-- ============================================================================

SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#pf') IS NOT NULL DROP TABLE #pf;
CREATE TABLE #pf (
    DatabaseName   sysname,
    HasPfUserTable bit,
    RowCountTotal  int          NULL,
    ActiveRows     int          NULL,   -- nAktiv = 1
    UnlockedRows   int          NULL    -- nGesperrt = 0
);

DECLARE @db sysname, @sql nvarchar(max);

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT name
    FROM sys.databases
    WHERE name LIKE 'eazybusiness%'
      AND state_desc = 'ONLINE'
    ORDER BY name;

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    -- QUOTENAME on the DB name is the only interpolation — no user data enters the
    -- dynamic string, so this stays a safe read-only probe.
    SET @sql = N'
        USE ' + QUOTENAME(@db) + N';
        IF OBJECT_ID(''dbo.pf_user'') IS NULL
            INSERT INTO #pf (DatabaseName, HasPfUserTable) VALUES (@d, 0);
        ELSE
            INSERT INTO #pf (DatabaseName, HasPfUserTable, RowCountTotal, ActiveRows, UnlockedRows)
            SELECT @d, 1,
                   COUNT(*),
                   SUM(CASE WHEN nAktiv = 1 THEN 1 ELSE 0 END),
                   SUM(CASE WHEN nGesperrt = 0 THEN 1 ELSE 0 END)
            FROM dbo.pf_user;';

    BEGIN TRY
        EXEC sys.sp_executesql @sql, N'@d sysname', @d = @db;
    END TRY
    BEGIN CATCH
        -- e.g. no permission on that DB; record it as "unknown" rather than aborting.
        INSERT INTO #pf (DatabaseName, HasPfUserTable) VALUES (@db, 0);
    END CATCH;

    FETCH NEXT FROM db_cur INTO @db;
END
CLOSE db_cur;
DEALLOCATE db_cur;

SELECT
    DatabaseName,
    HasPfUserTable,
    RowCountTotal,
    ActiveRows,
    UnlockedRows
FROM #pf
ORDER BY DatabaseName;

DROP TABLE #pf;
