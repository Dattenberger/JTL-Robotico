-- reset.spPub_GetResetStatus  (Ebene B / global)
--
-- Read-only status for the colleague who triggered a reset. Runs in its own DB, so
-- it needs NO signature — just EXECUTE granted to ops_reset_executor
-- (permissions/100). Deliberately selects NO secret columns (no cShopLicense).
--
--   @RequestId  — a specific request, or NULL for all.
--   @MandantKey — filter to one mandant, or NULL for all.
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§3)
CREATE OR ALTER PROCEDURE reset.spPub_GetResetStatus
    @RequestId  int     = NULL,
    @MandantKey sysname = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP (50)
        r.kResetRequest,
        r.cMandantKey,
        r.cTargetDb,
        r.cStatus,
        r.cRequestedBy,
        r.dRequested,
        r.dStarted,
        r.dFinished,
        DATEDIFF(SECOND, r.dStarted, ISNULL(r.dFinished, SYSUTCDATETIME())) AS DurationSeconds,
        r.cErrorMessage,
        r.cStepLog
    FROM ops.tResetRequest r
    WHERE (@RequestId  IS NULL OR r.kResetRequest  = @RequestId)
      AND (@MandantKey IS NULL OR r.cMandantKey = @MandantKey)
    ORDER BY r.kResetRequest DESC;
END
GO
