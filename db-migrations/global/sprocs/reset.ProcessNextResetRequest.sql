-- reset.ProcessNextResetRequest  (Ebene B / global — job body only)
--
-- Called ONLY by the Agent job "RoboticoOps - Testmandant Reset" (owner sa), so it
-- runs as the sysadmin Agent service account. That is why the pipeline steps need
-- no module signing — the privilege comes from the job owner (research/3 §3).
--
-- Loop: reclaim stale 'running' rows, then repeatedly claim the oldest 'queued'
-- request (UPDLOCK/READPAST so parallel job starts never grab the same row) and run
-- the reset pipeline. The pipeline is DATA-DRIVEN (EXT-1): the ordered, enabled steps
-- are rows in ops.ResetStep, dispatched by a whitelist-guarded loop (only deployed
-- reset.internal_* procs may run — see adr-reset-step-registry), each with the uniform
-- contract (@TargetDb,@RequestId,@MandantKey). Each step appends its own progress to
-- ops.ResetRequest.StepLog via reset.internal_LogStep (keyed by @RequestId), and the
-- loop logs a "starting step N" line before each step, so reset.GetResetStatus shows
-- live progress and a mid-step failure is attributable. A failure marks the request
-- 'failed', leaves the clone as-is for diagnosis, ensures MULTI_USER, and moves on to
-- the next request.
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
    DECLARE @RequestId int, @MandantKey sysname, @TargetDb sysname, @err nvarchar(max);
    -- Step-loop locals (EXT-1). Declared once here — T-SQL variable scope is the whole
    -- proc, not the block, so they must not be re-declared inside the request loop.
    DECLARE @stepNo int, @stepProc sysname, @isCritical bit, @stepExec nvarchar(300);

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
            -- Data-driven pipeline (EXT-1): the ordered, enabled steps live in
            -- ops.ResetStep, not in a hard-coded EXEC list. Adding a preparation step is
            -- "deploy a new reset.internal_* proc + INSERT one row" — this orchestrator is
            -- not edited. Each step gets the uniform contract (@TargetDb,@RequestId,
            -- @MandantKey) and reads any further inputs from ops.Mandant itself (EXT-2).
            SET @stepNo = 0;
            DECLARE stepcur CURSOR LOCAL FAST_FORWARD FOR
                SELECT ProcName, IsCritical
                FROM ops.ResetStep
                WHERE IsEnabled = 1
                ORDER BY StepOrder;
            OPEN stepcur;
            FETCH NEXT FROM stepcur INTO @stepProc, @isCritical;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                SET @stepNo += 1;

                -- WHITELIST (D6 narrowing, see adr-reset-step-registry): the step SET is
                -- data, but the EXECUTABLE set stays exactly the reset.internal_* procs the
                -- versioned chain deployed. A ProcName that is not a deployed reset.internal_
                -- proc breaks the run rather than executing anything; the name only ever
                -- reaches EXEC via QUOTENAME, so table data can neither inject nor run
                -- arbitrary code.
                IF NOT EXISTS (SELECT 1 FROM sys.procedures p
                               WHERE p.schema_id = SCHEMA_ID(N'reset')
                                 AND p.name = @stepProc
                                 AND p.name LIKE N'internal[_]%')
                BEGIN
                    CLOSE stepcur; DEALLOCATE stepcur;
                    THROW 51005, 'ops.ResetStep references an unknown reset.internal_ procedure.', 1;
                END

                -- OPS-3: log BEFORE running, so a mid-step failure is attributable — the
                -- last "starting step" line then has no matching success line from the step.
                EXEC reset.internal_LogStep @RequestId,
                     N'starting step ' + CAST(@stepNo AS nvarchar(10)) + N': ' + @stepProc;

                SET @stepExec = N'reset.' + QUOTENAME(@stepProc);
                BEGIN TRY
                    EXEC @stepExec @TargetDb = @TargetDb, @RequestId = @RequestId, @MandantKey = @MandantKey;
                END TRY
                BEGIN CATCH
                    -- Critical step (default): abort the pipeline → outer CATCH quarantines
                    -- the clone as 'failed'. Non-critical step: log a WARN and carry on.
                    IF @isCritical = 1
                    BEGIN
                        CLOSE stepcur; DEALLOCATE stepcur;
                        THROW;
                    END
                    EXEC reset.internal_LogStep @RequestId,
                         N'WARN ' + @stepProc + N': ' + ERROR_MESSAGE();
                END CATCH

                FETCH NEXT FROM stepcur INTO @stepProc, @isCritical;
            END
            CLOSE stepcur; DEALLOCATE stepcur;

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
