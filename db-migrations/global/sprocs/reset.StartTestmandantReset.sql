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

    DECLARE @TargetDb sysname,
            @RequestId int,
            @rc int,
            @lockRes nvarchar(255) = N'reset:' + @MandantKey,
            @caller sysname = ORIGINAL_LOGIN();

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

        IF EXISTS (SELECT 1 FROM ops.ResetRequest
                   WHERE TargetDb = @TargetDb AND Status IN (N'queued', N'running'))
            THROW 51004, 'A reset for this mandant is already queued or running.', 1;

        INSERT ops.ResetRequest (MandantKey, TargetDb, Status, RequestedBy, RequestedAt, ModifiedAt)
        VALUES (@MandantKey, @TargetDb, N'queued', @caller, SYSUTCDATETIME(), SYSUTCDATETIME());
        SET @RequestId = CAST(SCOPE_IDENTITY() AS int);

        -- Start the job. Error 22022 = "job already running": harmless — the request
        -- stays queued and the running job's while-loop picks it up.
        BEGIN TRY
            EXEC msdb.dbo.sp_start_job @job_name = N'RoboticoOps - Testmandant Reset';
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() <> 22022 THROW;
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
