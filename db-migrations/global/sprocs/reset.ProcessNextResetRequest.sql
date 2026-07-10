-- reset.ProcessNextResetRequest  (Ebene B / global — job body only)
--
-- Called ONLY by the Agent job "RoboticoOps - Testmandant Reset" (owner sa), so it
-- runs as the sysadmin Agent service account. That is why the pipeline steps need
-- no module signing — the privilege comes from the job owner (research/3 §3).
--
-- Loop: reclaim stale 'running' rows, then repeatedly claim the oldest 'queued'
-- request (UPDLOCK/READPAST so parallel job starts never grab the same row) and run
-- the reset pipeline. Each internal step appends its own progress to
-- ops.ResetRequest.StepLog (keyed by @RequestId) as it goes, so reset.GetResetStatus
-- shows live progress and the log survives a mid-step failure. A failure marks the
-- request 'failed', leaves the clone as-is for diagnosis, ensures MULTI_USER, and
-- moves on to the next request.
--
-- NOTE: no explicit user transaction wraps the pipeline — BACKUP/RESTORE cannot run
-- inside one, and a half-done clone is intentionally kept for diagnosis.
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§3)
CREATE OR ALTER PROCEDURE reset.ProcessNextResetRequest
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Reclaim requests whose job died hard (else the mandant stays blocked forever).
    UPDATE ops.ResetRequest
       SET Status     = N'failed',
           ErrorText  = N'stale running request reclaimed (job likely restarted)',
           FinishedAt = SYSUTCDATETIME(),
           ModifiedAt = SYSUTCDATETIME()
     WHERE Status = N'running'
       AND StartedAt < DATEADD(HOUR, -4, SYSUTCDATETIME());

    DECLARE @claimed TABLE (RequestId int, MandantKey sysname, TargetDb sysname);
    DECLARE @RequestId int, @MandantKey sysname, @TargetDb sysname,
            @ShopUrl nvarchar(max), @ShopLicense nvarchar(max),
            @LoginName sysname, @DisplayName nvarchar(255), @err nvarchar(max);

    WHILE (1 = 1)
    BEGIN
        DELETE FROM @claimed;
        SET @RequestId = NULL;   -- reset so an empty claim below terminates the loop

        ;WITH nxt AS (
            SELECT TOP (1) *
            FROM ops.ResetRequest WITH (UPDLOCK, READPAST)
            WHERE Status = N'queued'
            ORDER BY RequestId
        )
        UPDATE nxt
           SET Status     = N'running',
               StartedAt  = SYSUTCDATETIME(),
               ModifiedAt = SYSUTCDATETIME()
        OUTPUT inserted.RequestId, inserted.MandantKey, inserted.TargetDb
        INTO @claimed (RequestId, MandantKey, TargetDb);

        SELECT @RequestId = RequestId, @MandantKey = MandantKey, @TargetDb = TargetDb
        FROM @claimed;

        IF @RequestId IS NULL
            BREAK;   -- nothing left to do

        SELECT @ShopUrl     = ShopUrl,
               @ShopLicense = ShopLicense,
               @LoginName   = LoginName,
               @DisplayName = DisplayName
        FROM ops.Mandant
        WHERE MandantKey = @MandantKey;

        -- Re-validation (defense in depth, D6): never touch prod, honour the registry.
        IF @TargetDb = N'eazybusiness'
           OR @TargetDb NOT LIKE N'eazybusiness[_]%'
           OR NOT EXISTS (SELECT 1 FROM ops.Mandant
                          WHERE MandantKey = @MandantKey AND TargetDb = @TargetDb)
        BEGIN
            UPDATE ops.ResetRequest
               SET Status = N'failed',
                   ErrorText = N're-validation failed: target is not a registered test-mandant clone',
                   FinishedAt = SYSUTCDATETIME(), ModifiedAt = SYSUTCDATETIME()
             WHERE RequestId = @RequestId;
            CONTINUE;
        END

        BEGIN TRY
            EXEC reset.internal_CloneDatabase         @TargetDb = @TargetDb, @RequestId = @RequestId;
            EXEC reset.internal_PostRestoreSecurity   @TargetDb = @TargetDb, @RequestId = @RequestId;
            EXEC reset.internal_InvalidateCredentials @TargetDb = @TargetDb, @RequestId = @RequestId,
                                                      @ShopUrl = @ShopUrl, @ShopLicense = @ShopLicense;
            EXEC reset.internal_NeutralizeWorker      @TargetDb = @TargetDb, @RequestId = @RequestId;
            EXEC reset.internal_AnonymizeCustomerData @TargetDb = @TargetDb, @RequestId = @RequestId;
            EXEC reset.internal_GrantAccess           @TargetDb = @TargetDb, @RequestId = @RequestId, @LoginName = @LoginName;
            EXEC reset.internal_RegisterMandant       @TargetDb = @TargetDb, @RequestId = @RequestId, @DisplayName = @DisplayName;
            EXEC reset.internal_ApplyJtlRoles         @TargetDb = @TargetDb, @RequestId = @RequestId;

            UPDATE ops.ResetRequest
               SET Status = N'succeeded', FinishedAt = SYSUTCDATETIME(), ModifiedAt = SYSUTCDATETIME()
             WHERE RequestId = @RequestId;
        END TRY
        BEGIN CATCH
            SET @err = ERROR_MESSAGE();

            -- Best-effort: make sure a mid-clone SINGLE_USER database is reachable again.
            BEGIN TRY
                IF DB_ID(@TargetDb) IS NOT NULL
                    EXEC (N'ALTER DATABASE ' + QUOTENAME(@TargetDb) + N' SET MULTI_USER;');
            END TRY
            BEGIN CATCH
            END CATCH

            UPDATE ops.ResetRequest
               SET Status = N'failed', ErrorText = @err, FinishedAt = SYSUTCDATETIME(), ModifiedAt = SYSUTCDATETIME()
             WHERE RequestId = @RequestId;
        END CATCH
    END
END
GO
