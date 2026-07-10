-- reset.GetResetStatus  (Ebene B / global)
--
-- Read-only status for the colleague who triggered a reset. Runs in its own DB, so
-- it needs NO signature — just EXECUTE granted to ops_reset_executor
-- (permissions/100). Deliberately selects NO secret columns (no ShopLicense).
--
--   @RequestId  — a specific request, or NULL for all.
--   @MandantKey — filter to one mandant, or NULL for all.
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§3)
CREATE OR ALTER PROCEDURE reset.GetResetStatus
    @RequestId  int     = NULL,
    @MandantKey sysname = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP (50)
        r.RequestId,
        r.MandantKey,
        r.TargetDb,
        r.Status,
        r.RequestedBy,
        r.RequestedAt,
        r.StartedAt,
        r.FinishedAt,
        DATEDIFF(SECOND, r.StartedAt, ISNULL(r.FinishedAt, SYSUTCDATETIME())) AS DurationSeconds,
        r.ErrorText,
        r.StepLog
    FROM ops.ResetRequest r
    WHERE (@RequestId  IS NULL OR r.RequestId  = @RequestId)
      AND (@MandantKey IS NULL OR r.MandantKey = @MandantKey)
    ORDER BY r.RequestId DESC;
END
GO
