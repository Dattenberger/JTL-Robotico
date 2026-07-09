-- ============================================================================
-- 04_queue_inventory.sql — full queue-table inventory per DB (read-only)
-- ============================================================================
-- Verifies the reset's queue-drain list is COMPLETE: enumerates every table whose
-- name contains 'queue' in each eazybusiness* database, with its row count, so no
-- backlog table is missed. A queue left full re-fires marketplace/mail traffic the
-- moment someone re-enters credentials on a test clone (see research/4-jtl-spezifika).
--
-- The reset (§3, internal_NeutralizeWorker) drains these, each IF OBJECT_ID-guarded:
--   dbo.tQueue, dbo.tWorkflowQueue, dbo.ebay_usermessagequeue, dbo.ebay_queue_out,
--   dbo.tGlobalsQueue, dbo.tDruckQueue.
-- Use this probe's output to confirm every NON-empty queue is covered by that list
-- (empty queues need no drain but are listed here for completeness).
--
-- STRICTLY READ-ONLY (catalog + partition stats). Iterates DBs itself:
--   /opt/mssql-tools18/bin/sqlcmd -S vm-sql2.zdbikes.local -E -C \
--       -d master -i db-migrations/tests/probes/04_queue_inventory.sql
--
-- Recorded result — vm-sql-test1.eazybusiness (2026-07-10, this repo's C3 run):
--   23 queue tables total. NON-empty ones:
--     dbo.tQueue               9765
--     dbo.ebay_usermessagequeue 1469
--     dbo.tGlobalsQueue         1221
--     dbo.tWorkflowQueue        1209
--     dbo.tDruckQueue             33
--     dbo.ebay_queue_out           4
--   All other 17 (Amazon.*, FulfillmentNetwork.*, Pos.*, SCX.*, dbo.pf_amazon_queue,
--   dbo.tEazyShippingVerpackQueue, dbo.tInteropQueue) = 0 rows.
--   => Every NON-empty queue on test1 is in the reset drain list. COMPLETE. ✅
--   (Row counts here are sys.partitions estimates — exact enough for coverage.)
-- ============================================================================

SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#q') IS NOT NULL DROP TABLE #q;
CREATE TABLE #q (
    DatabaseName sysname,
    QueueTable   nvarchar(300),
    RowCountEst  bigint
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
    -- Only the DB name is interpolated (via QUOTENAME) — read-only catalog query.
    SET @sql = N'
        USE ' + QUOTENAME(@db) + N';
        INSERT INTO #q (DatabaseName, QueueTable, RowCountEst)
        SELECT @d,
               s.name + ''.'' + t.name,
               SUM(p.rows)
        FROM sys.tables t
        JOIN sys.schemas s    ON s.schema_id = t.schema_id
        JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0, 1)
        WHERE t.name LIKE ''%queue%''
        GROUP BY s.name, t.name;';

    BEGIN TRY
        EXEC sys.sp_executesql @sql, N'@d sysname', @d = @db;
    END TRY
    BEGIN CATCH
        INSERT INTO #q (DatabaseName, QueueTable, RowCountEst)
        VALUES (@db, N'<error reading database: ' + ERROR_MESSAGE() + N'>', NULL);
    END CATCH;

    FETCH NEXT FROM db_cur INTO @db;
END
CLOSE db_cur;
DEALLOCATE db_cur;

-- Non-empty first (the ones that MUST be in the drain list), then the rest.
SELECT
    DatabaseName,
    QueueTable,
    RowCountEst
FROM #q
ORDER BY DatabaseName,
         CASE WHEN RowCountEst > 0 THEN 0 ELSE 1 END,
         RowCountEst DESC,
         QueueTable;

DROP TABLE #q;
