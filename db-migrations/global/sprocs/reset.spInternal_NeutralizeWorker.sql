-- reset.spInternal_NeutralizeWorker  (Ebene B / global — pipeline step, job-only)
--
-- NEW step (D9). Stops the JTL worker from acting on a fresh clone as if it were
-- production: lock the Amazon platform user (pf_user), clear its secret auth tokens,
-- and empty the message/print queues so nothing queued in prod gets processed against
-- test data.
--
-- pf_user secret-token clearing lives HERE (not in spInternal_AnonymizeCustomerData) on
-- purpose (D-14): credential neutralisation is worker-neutralisation, and it must run
-- UNCONDITIONALLY — never coupled to the anonymisation block's all-or-nothing column
-- guard, where a single missing PII column would otherwise skip the token wipe and leave
-- real Amazon credentials in the clone. Each secret column is guarded on its own so a
-- schema difference is a no-op, the UPDATE is idempotent (NULL) and safe on an empty table.
--
-- Worker.tTarget is DELIBERATELY NOT touched (O1) — its semantics are still under
-- investigation (see db-migrations/tests/probes/01_worker_ttarget_semantics.sql).
-- Queues are emptied with DELETE (FK-safe), never TRUNCATE. Every table and every
-- pf_user column is existence-guarded so a schema difference cannot break the reset.
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§3)
CREATE OR ALTER PROCEDURE reset.spInternal_NeutralizeWorker
    @TargetDb   sysname,
    @RequestId  int,
    @MandantKey sysname   -- uniform step contract (EXT-2); not used by this step
AS
BEGIN
    SET NOCOUNT ON;

    IF @TargetDb = N'eazybusiness' OR @TargetDb NOT LIKE N'eazybusiness[_]%'
        THROW 51040, 'spInternal_NeutralizeWorker refused: target is not a test-mandant clone.', 1;

    DECLARE @exec nvarchar(300) = QUOTENAME(@TargetDb) + N'.sys.sp_executesql';
    DECLARE @batch nvarchar(max) = N'
        -- eBay sync off (also set in InvalidateCredentials — harmless to repeat).
        UPDATE dbo.ebay_user SET nGesperrt = 1 WHERE nGesperrt = 0;

        -- Lock the Amazon platform user (column-guarded).
        IF OBJECT_ID(''dbo.pf_user'') IS NOT NULL AND COL_LENGTH(''dbo.pf_user'', ''nGesperrt'') IS NOT NULL
            UPDATE dbo.pf_user SET nGesperrt = 1;
        IF OBJECT_ID(''dbo.pf_user'') IS NOT NULL AND COL_LENGTH(''dbo.pf_user'', ''nAktiv'') IS NOT NULL
            UPDATE dbo.pf_user SET nAktiv = 0;

        -- Clear the Amazon/platform secret auth tokens (moved here from
        -- spInternal_AnonymizeCustomerData, D-14). Column names verified against
        -- A_Context/JTL 1.10.11.0/dbo.pf_user.Table.sql: cAuthToken nvarchar(255),
        -- cAmazonAuthToken nvarchar(255). Per-column guard + NULL assignment => no-op on a
        -- schema difference, idempotent, safe on an empty table.
        IF OBJECT_ID(''dbo.pf_user'') IS NOT NULL AND COL_LENGTH(''dbo.pf_user'', ''cAuthToken'') IS NOT NULL
            UPDATE dbo.pf_user SET cAuthToken = NULL;
        IF OBJECT_ID(''dbo.pf_user'') IS NOT NULL AND COL_LENGTH(''dbo.pf_user'', ''cAmazonAuthToken'') IS NOT NULL
            UPDATE dbo.pf_user SET cAmazonAuthToken = NULL;

        -- Empty the worker/message/print queues (DELETE, not TRUNCATE — FK-safe).
        -- Worker.tTarget is intentionally left alone (O1).
        IF OBJECT_ID(''dbo.tQueue'')                IS NOT NULL DELETE FROM dbo.tQueue;
        IF OBJECT_ID(''dbo.tWorkflowQueue'')        IS NOT NULL DELETE FROM dbo.tWorkflowQueue;
        IF OBJECT_ID(''dbo.ebay_usermessagequeue'') IS NOT NULL DELETE FROM dbo.ebay_usermessagequeue;
        IF OBJECT_ID(''dbo.ebay_queue_out'')        IS NOT NULL DELETE FROM dbo.ebay_queue_out;
        IF OBJECT_ID(''dbo.tGlobalsQueue'')         IS NOT NULL DELETE FROM dbo.tGlobalsQueue;
        IF OBJECT_ID(''dbo.tDruckQueue'')           IS NOT NULL DELETE FROM dbo.tDruckQueue;
    ';
    EXEC @exec @batch;

    EXEC reset.spInternal_LogStep @RequestId,
         N'worker: pf_user locked + auth tokens cleared, queues emptied (Worker.tTarget untouched)';
END
GO
