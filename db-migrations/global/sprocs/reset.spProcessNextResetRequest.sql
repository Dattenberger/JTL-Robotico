-- reset.spProcessNextResetRequest  (Ebene B / global — job body only)
--
-- Called ONLY by the Agent job "RoboticoOps - Testmandant Reset" (owner sa), so it
-- runs as the sysadmin Agent service account. That is why the pipeline steps need
-- no module signing — the privilege comes from the job owner (research/3 §3).
--
-- Loop: reclaim stale 'running' rows, then repeatedly claim the oldest 'queued'
-- request (UPDLOCK/READPAST so parallel job starts never grab the same row) and run
-- the reset pipeline. The pipeline is DATA-DRIVEN (EXT-1): the ordered, enabled steps
-- are rows in ops.tResetStep, dispatched by a whitelist-guarded loop (only deployed
-- reset.spInternal_* procs may run — see adr-reset-step-registry), each with the uniform
-- contract (@TargetDb,@RequestId,@MandantKey). Each step appends its own progress to
-- ops.tResetRequest.cStepLog via reset.spInternal_LogStep (keyed by @RequestId), and the
-- loop logs a "starting step N" line before each step, so reset.spPub_GetResetStatus shows
-- live progress and a mid-step failure is attributable. A failure marks the request
-- 'failed', leaves the clone as-is for diagnosis, ensures MULTI_USER, and moves on to
-- the next request.
--
-- NOTE: no explicit user transaction wraps the pipeline — BACKUP/RESTORE cannot run
-- inside one, and a half-done clone is intentionally kept for diagnosis.
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§3)
CREATE OR ALTER PROCEDURE reset.spProcessNextResetRequest
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Stale-reclaim window is an ops.tConfig knob (CQG-7), not a hard-coded literal, so
    -- ops can tune it without a code+re-sign deploy. ISNULL/TRY_CONVERT fall back to 4h
    -- if the key is missing or non-numeric.
    DECLARE @staleHours int =
        ISNULL((SELECT TRY_CONVERT(int, cValue) FROM ops.tConfig WHERE cKey = N'StaleRunningHours'), 4);

    -- Reclaim requests whose job died hard (else the mandant stays blocked forever).
    UPDATE ops.tResetRequest
       SET cStatus     = N'failed',
           cErrorMessage  = N'stale running request reclaimed (job likely restarted)',
           dFinished = SYSUTCDATETIME(),
           dModified = SYSUTCDATETIME()
     WHERE cStatus = N'running'
       AND dStarted < DATEADD(HOUR, - @staleHours, SYSUTCDATETIME());

    DECLARE @claimed TABLE (kResetRequest int, cMandantKey sysname, cTargetDb sysname);
    DECLARE @RequestId int, @MandantKey sysname, @TargetDb sysname, @err nvarchar(max);
    -- Step-loop locals (EXT-1). Declared once here — T-SQL variable scope is the whole
    -- proc, not the block, so they must not be re-declared inside the request loop.
    DECLARE @stepNo int, @stepProc sysname, @isCritical bit, @stepExec nvarchar(300),
            @log nvarchar(max), @ddl nvarchar(max);

    WHILE (1 = 1)
    BEGIN
        DELETE FROM @claimed;
        SET @RequestId = NULL;   -- reset so an empty claim below terminates the loop

        ;WITH nxt AS (
            SELECT TOP (1) *
            FROM ops.tResetRequest WITH (UPDLOCK, READPAST)
            WHERE cStatus = N'queued'
            ORDER BY kResetRequest
        )
        UPDATE nxt
           SET cStatus     = N'running',
               dStarted  = SYSUTCDATETIME(),
               dModified = SYSUTCDATETIME()
        OUTPUT inserted.kResetRequest, inserted.cMandantKey, inserted.cTargetDb
        INTO @claimed (kResetRequest, cMandantKey, cTargetDb);

        SELECT @RequestId = kResetRequest, @MandantKey = cMandantKey, @TargetDb = cTargetDb
        FROM @claimed;

        IF @RequestId IS NULL
            BREAK;   -- nothing left to do

        -- Re-validation (defense in depth, D6): never touch prod, honour the registry.
        IF @TargetDb = N'eazybusiness'
           OR @TargetDb NOT LIKE N'eazybusiness[_]%'
           OR NOT EXISTS (SELECT 1 FROM ops.tMandant
                          WHERE cMandantKey = @MandantKey AND cTargetDb = @TargetDb)
        BEGIN
            UPDATE ops.tResetRequest
               SET cStatus = N'failed',
                   cErrorMessage = N're-validation failed: target is not a registered test-mandant clone',
                   dFinished = SYSUTCDATETIME(), dModified = SYSUTCDATETIME()
             WHERE kResetRequest = @RequestId;
            CONTINUE;
        END

        BEGIN TRY
            -- Data-driven pipeline (EXT-1): the ordered, enabled steps live in
            -- ops.tResetStep, not in a hard-coded EXEC list. Adding a preparation step is
            -- "deploy a new reset.spInternal_* proc + INSERT one row" — this orchestrator is
            -- not edited. Each step gets the uniform contract (@TargetDb,@RequestId,
            -- @MandantKey) and reads any further inputs from ops.tMandant itself (EXT-2).
            SET @stepNo = 0;
            DECLARE stepcur CURSOR LOCAL FAST_FORWARD FOR
                SELECT cProcName, bCritical
                FROM ops.tResetStep
                WHERE bEnabled = 1
                ORDER BY nStepOrder;
            OPEN stepcur;
            FETCH NEXT FROM stepcur INTO @stepProc, @isCritical;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                SET @stepNo += 1;

                -- WHITELIST (D6 narrowing, see adr-reset-step-registry): the step SET is
                -- data, but the EXECUTABLE set stays exactly the reset.spInternal_* procs the
                -- versioned chain deployed. A cProcName that is not a deployed reset.spInternal_
                -- proc breaks the run rather than executing anything; the name only ever
                -- reaches EXEC via QUOTENAME, so table data can neither inject nor run
                -- arbitrary code.
                IF NOT EXISTS (SELECT 1 FROM sys.procedures p
                               WHERE p.schema_id = SCHEMA_ID(N'reset')
                                 AND p.name = @stepProc
                                 AND p.name LIKE N'spInternal[_]%')
                BEGIN
                    CLOSE stepcur; DEALLOCATE stepcur;
                    THROW 51005, 'ops.tResetStep references an unknown reset.spInternal_ procedure.', 1;
                END

                -- OPS-3: log BEFORE running, so a mid-step failure is attributable — the
                -- last "starting step" line then has no matching success line from the step.
                -- (Message built into a variable — a proc argument cannot be an expression.)
                SET @log = CONCAT(N'starting step ', @stepNo, N': ', @stepProc);
                EXEC reset.spInternal_LogStep @RequestId, @log;

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
                    SET @log = CONCAT(N'WARN ', @stepProc, N': ', ERROR_MESSAGE());
                    EXEC reset.spInternal_LogStep @RequestId, @log;
                END CATCH

                FETCH NEXT FROM stepcur INTO @stepProc, @isCritical;
            END
            CLOSE stepcur; DEALLOCATE stepcur;

            UPDATE ops.tResetRequest
               SET cStatus = N'succeeded', dFinished = SYSUTCDATETIME(), dModified = SYSUTCDATETIME()
             WHERE kResetRequest = @RequestId;
        END TRY
        BEGIN CATCH
            SET @err = ERROR_MESSAGE();

            -- Best-effort: make sure a mid-clone SINGLE_USER database is reachable again.
            BEGIN TRY
                IF DB_ID(@TargetDb) IS NOT NULL
                BEGIN
                    SET @ddl = N'ALTER DATABASE ' + QUOTENAME(@TargetDb) + N' SET MULTI_USER;';
                    EXEC (@ddl);
                END
            END TRY
            BEGIN CATCH
            END CATCH

            UPDATE ops.tResetRequest
               SET cStatus = N'failed', cErrorMessage = @err, dFinished = SYSUTCDATETIME(), dModified = SYSUTCDATETIME()
             WHERE kResetRequest = @RequestId;
        END CATCH
    END
END
GO
