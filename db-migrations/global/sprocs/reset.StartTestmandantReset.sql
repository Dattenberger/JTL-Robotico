-- reset.StartTestmandantReset  (Ebene B / global — signed, EXECUTE AS jobstartuser)
--
-- The ONLY entry point a colleague needs: validate, enqueue a reset request, and
-- kick the Agent job. EXECUTE granted to role ops_reset_executor (permissions/100).
--
-- Security model (research/3, D6):
--   * WITH EXECUTE AS 'jobstartuser' + a certificate signature (added every deploy
--     by permissions/900_resign_procedures) let this proc call
--     msdb.dbo.sp_start_job across the DB boundary WITHOUT TRUSTWORTHY.
--   * Access to ops.* inside the body works via ownership chaining (schemas are
--     dbo-owned), so jobstartuser needs no table grants.
--   * ORIGINAL_LOGIN() records the REAL caller (EXECUTE AS would otherwise mask it).
--
-- CREATE OR ALTER strips the signature — permissions/900 re-applies it every deploy.
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§3)
-- @see db-migrations/global/permissions/900_resign_procedures.sql
CREATE OR ALTER PROCEDURE reset.StartTestmandantReset
    @MandantKey sysname
WITH EXECUTE AS 'jobstartuser'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;   -- CQG-12: consistent hardening with the other reset procs.

    DECLARE @TargetDb sysname,
            @RequestId int,
            @rc int,
            @existingId int,
            @existingStatus nvarchar(20),
            @lockRes nvarchar(255) = N'reset:' + @MandantKey,
            @caller sysname = ORIGINAL_LOGIN(),
            -- Job name is a single-sourced ops.Config knob (CQG-8): the same literal is
            -- read here, in reset.EnsureAgentJob, and in permissions/200_ensure_agent_job.
            -- The ISNULL keeps a pre-config instance working with the built-in default.
            @jobName sysname = ISNULL(
                (SELECT ConfigValue FROM ops.Config WHERE ConfigKey = N'AgentJobName'),
                N'RoboticoOps - Testmandant Reset');

    -- Short exclusive applock dedups concurrent submissions for the same mandant
    -- (the filtered unique index on ops.ResetRequest is the declarative backstop).
    EXEC @rc = sp_getapplock @Resource = @lockRes, @LockMode = 'Exclusive',
                             @LockOwner = 'Session', @LockTimeout = 5000;
    IF @rc < 0
        THROW 51001, 'Could not acquire the submission lock for this mandant; try again.', 1;

    BEGIN TRY
        SELECT @TargetDb = TargetDb
        FROM ops.Mandant
        WHERE MandantKey = @MandantKey AND IsActive = 1;

        IF @TargetDb IS NULL
            THROW 51002, 'Unknown or inactive mandant key.', 1;

        -- Defense in depth (redundant to the CK_ops_Mandant_TargetDb constraint).
        IF @TargetDb = N'eazybusiness' OR @TargetDb NOT LIKE N'eazybusiness[_]%'
            THROW 51003, 'Refusing: target database is not a test-mandant clone.', 1;

        -- OPS-6: a reset already in flight for this mandant is NOT an error. Return the
        -- existing request (same {RequestId, Status} shape as the success path) so a
        -- caller who submitted twice transparently keeps polling GetResetStatus for the
        -- SAME RequestId instead of getting an exception. Release the applock first, since
        -- this early RETURN bypasses the normal release at the end of the TRY.
        SELECT TOP (1) @existingId = RequestId, @existingStatus = Status
        FROM ops.ResetRequest
        WHERE TargetDb = @TargetDb AND Status IN (N'queued', N'running')
        ORDER BY RequestId DESC;

        IF @existingId IS NOT NULL
        BEGIN
            EXEC sp_releaseapplock @Resource = @lockRes, @LockOwner = 'Session';
            SELECT @existingId AS RequestId, @existingStatus AS Status;
            RETURN;
        END

        INSERT ops.ResetRequest (MandantKey, TargetDb, Status, RequestedBy, RequestedAt, ModifiedAt)
        VALUES (@MandantKey, @TargetDb, N'queued', @caller, SYSUTCDATETIME(), SYSUTCDATETIME());
        SET @RequestId = CAST(SCOPE_IDENTITY() AS int);

        -- Start the job. Error 22022 = "job already running": harmless — the request
        -- stays queued and the running job's while-loop picks it up. Any OTHER start
        -- failure (job missing, or an msdb permission error from a dropped signature)
        -- must NOT leave the row silently 'queued': the filtered unique index would then
        -- block the caller from resubmitting while the next successful start executes the
        -- reset they believed had failed. So mark the row 'failed' before re-throwing (CQG-1).
        BEGIN TRY
            EXEC msdb.dbo.sp_start_job @job_name = @jobName;
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() <> 22022
            BEGIN
                UPDATE ops.ResetRequest
                   SET Status     = N'failed',
                       ErrorText  = N'sp_start_job failed: ' + ERROR_MESSAGE(),
                       FinishedAt = SYSUTCDATETIME(),
                       ModifiedAt = SYSUTCDATETIME()
                 WHERE RequestId = @RequestId;
                THROW;
            END
        END CATCH

        EXEC sp_releaseapplock @Resource = @lockRes, @LockOwner = 'Session';
    END TRY
    BEGIN CATCH
        EXEC sp_releaseapplock @Resource = @lockRes, @LockOwner = 'Session';
        THROW;
    END CATCH

    SELECT @RequestId AS RequestId, N'queued' AS Status;
END
GO
