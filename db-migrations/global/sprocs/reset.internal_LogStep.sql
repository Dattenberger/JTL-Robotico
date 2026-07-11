-- reset.internal_LogStep  (Ebene B / global — pipeline helper, job-only)
--
-- DRY helper (EXT-3, absorbs CQG-6): owns the ONE canonical ops.ResetRequest.StepLog
-- append format — ISO-8601 timestamp (CONVERT …, 126) + a single space + message +
-- newline — plus the ModifiedAt bump. Every reset.internal_* step and the orchestrator
-- call this instead of repeating the UPDATE, so the log format lives in one place and a
-- format change is one edit, not thirty.
--
-- Callers pass the message WITHOUT a leading space (the helper adds the separator) and
-- WITHOUT a trailing newline. @Message is nvarchar(max) so a WARN line carrying a full
-- ERROR_MESSAGE() is never truncated.
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§3)
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur/adrs/adr-reset-step-registry.md
CREATE OR ALTER PROCEDURE reset.internal_LogStep
    @RequestId int,
    @Message   nvarchar(max)
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE ops.ResetRequest
       SET StepLog    = ISNULL(StepLog, N'') + CONVERT(nvarchar(19), SYSUTCDATETIME(), 126)
                      + N' ' + @Message + NCHAR(10),
           ModifiedAt = SYSUTCDATETIME()
     WHERE RequestId = @RequestId;
END
GO
