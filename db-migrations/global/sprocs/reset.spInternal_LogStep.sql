-- reset.spInternal_LogStep  (Ebene B / global — pipeline helper, job-only)
--
-- DRY helper (EXT-3, absorbs CQG-6): owns the ONE canonical ops.tResetRequest.cStepLog
-- append format — ISO-8601 timestamp (CONVERT …, 126) + a single space + message +
-- newline — plus the dModified bump. Every reset.spInternal_* step and the orchestrator
-- call this instead of repeating the UPDATE, so the log format lives in one place and a
-- format change is one edit, not thirty.
--
-- Callers pass the message WITHOUT a leading space (the helper adds the separator) and
-- WITHOUT a trailing newline. @Message is nvarchar(max) so a WARN line carrying a full
-- ERROR_MESSAGE() is never truncated.
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§3)
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur/adrs/adr-reset-step-registry.md
CREATE OR ALTER PROCEDURE reset.spInternal_LogStep
    @RequestId int,
    @Message   nvarchar(max)
AS
BEGIN
    SET NOCOUNT ON;

    -- ISNULL on @Message is load-bearing (QG3 B9): '+' propagates NULL, so a single
    -- NULL message would otherwise set cStepLog itself to NULL and wipe the request's
    -- entire log history. Current callers build messages NULL-safely, but this helper
    -- is the SSoT for FUTURE steps too.
    UPDATE ops.tResetRequest
       SET cStepLog    = ISNULL(cStepLog, N'') + CONVERT(nvarchar(19), SYSUTCDATETIME(), 126)
                      + N' ' + ISNULL(@Message, N'(null message)') + NCHAR(10),
           dModified = SYSUTCDATETIME()
     WHERE kResetRequest = @RequestId;
END
GO
