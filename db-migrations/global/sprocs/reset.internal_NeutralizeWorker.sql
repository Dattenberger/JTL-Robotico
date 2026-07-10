-- reset.internal_NeutralizeWorker  (Ebene B / global — pipeline step, job-only)
--
-- NEW step (D9). Stops the JTL worker from acting on a fresh clone as if it were
-- production: lock the Amazon platform user (pf_user), and empty the message/print
-- queues so nothing queued in prod gets processed against test data.
--
-- Worker.tTarget is DELIBERATELY NOT touched (O1) — its semantics are still under
-- investigation (see db-migrations/tests/probes/01_worker_ttarget_semantics.sql).
-- Queues are emptied with DELETE (FK-safe), never TRUNCATE. Every table and every
-- pf_user column is existence-guarded so a schema difference cannot break the reset.
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§3)
CREATE OR ALTER PROCEDURE reset.internal_NeutralizeWorker
    @TargetDb  sysname,
    @RequestId int
AS
BEGIN
    SET NOCOUNT ON;

    IF @TargetDb = N'eazybusiness' OR @TargetDb NOT LIKE N'eazybusiness[_]%'
        THROW 51040, 'internal_NeutralizeWorker refused: target is not a test-mandant clone.', 1;

    DECLARE @exec nvarchar(300) = QUOTENAME(@TargetDb) + N'.sys.sp_executesql';
    DECLARE @batch nvarchar(max) = N'
        -- eBay sync off (also set in InvalidateCredentials — harmless to repeat).
        UPDATE dbo.ebay_user SET nGesperrt = 1 WHERE nGesperrt = 0;

        -- Lock the Amazon platform user (column-guarded).
        IF OBJECT_ID(''dbo.pf_user'') IS NOT NULL AND COL_LENGTH(''dbo.pf_user'', ''nGesperrt'') IS NOT NULL
            UPDATE dbo.pf_user SET nGesperrt = 1;
        IF OBJECT_ID(''dbo.pf_user'') IS NOT NULL AND COL_LENGTH(''dbo.pf_user'', ''nAktiv'') IS NOT NULL
            UPDATE dbo.pf_user SET nAktiv = 0;

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

    UPDATE ops.ResetRequest
       SET StepLog = ISNULL(StepLog, N'') + CONVERT(nvarchar(19), SYSUTCDATETIME(), 126)
                   + N' worker: pf_user locked, queues emptied (Worker.tTarget untouched)' + NCHAR(10),
           ModifiedAt = SYSUTCDATETIME()
     WHERE RequestId = @RequestId;
END
GO
