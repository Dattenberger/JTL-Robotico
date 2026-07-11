-- reset.PurgeOldRequests  (Ebene B / global — admin retention helper, OPS-5)
--
-- ops.ResetRequest is an append-only audit + queue log with nvarchar(max) StepLog /
-- ErrorText columns, so it grows without bound. This admin-run SP trims the history
-- while ALWAYS keeping, per mandant, the @KeepPerMandant most recent rows and every row
-- that is not yet terminal (a 'queued'/'running' request is never deleted). It is the
-- deliberate retention knob — retention is a conscious operation, not an accident.
--
-- Runs in its own DB; no signature. EXECUTE is granted to ops_admin only (permissions/100)
-- — a reset operator (ops_reset_executor) must NOT be able to erase the audit trail. The
-- DELETE reaches ops.ResetRequest via ownership chaining (dbo-owned schemas).
--
--   @KeepPerMandant — rows to retain per MandantKey, newest first (default 20).
--   @WhatIf         — 1 = report the delete count only, delete nothing (dry run).
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§3)
CREATE OR ALTER PROCEDURE reset.PurgeOldRequests
    @KeepPerMandant int = 20,
    @WhatIf         bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @KeepPerMandant < 1
        THROW 51008, 'reset.PurgeOldRequests: @KeepPerMandant must be at least 1.', 1;

    -- Candidates: terminal rows (succeeded/failed) that fall outside the newest
    -- @KeepPerMandant per mandant. Queued/running rows are never eligible, and the
    -- most recent @KeepPerMandant rows per mandant are always retained.
    ;WITH ranked AS (
        SELECT r.RequestId,
               ROW_NUMBER() OVER (PARTITION BY r.MandantKey ORDER BY r.RequestId DESC) AS rn
        FROM ops.ResetRequest r
    )
    SELECT ranked.RequestId
    INTO #victims
    FROM ranked
    JOIN ops.ResetRequest r ON r.RequestId = ranked.RequestId
    WHERE ranked.rn > @KeepPerMandant
      AND r.Status IN (N'succeeded', N'failed');

    DECLARE @count int = (SELECT COUNT(*) FROM #victims);

    IF @WhatIf = 1
    BEGIN
        SELECT @count AS WouldDeleteRows, @KeepPerMandant AS KeepPerMandant;
        RETURN;
    END

    DELETE r
    FROM ops.ResetRequest r
    JOIN #victims v ON v.RequestId = r.RequestId;

    SELECT @count AS DeletedRows, @KeepPerMandant AS KeepPerMandant;
END
GO
