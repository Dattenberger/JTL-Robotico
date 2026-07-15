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
-- SERIALIZATION (QG3 B3): the whole run holds the exclusive session applock
-- 'reset:pipeline'. The Agent job alone never runs twice concurrently, but a MANUAL
-- `EXEC reset.spProcessNextResetRequest` next to a running job would: UPDLOCK/READPAST
-- hands each instance a DIFFERENT queued request, and two concurrent
-- spInternal_CloneDatabase runs collide on the single ops.tConfig BackupFile path
-- (BACKUP WITH INIT vs. a RESTORE reading the same file). A second instance is by
-- definition redundant — the holder drains the whole queue — so on a busy lock this
-- proc silently does nothing.
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

    -- B3: pipeline-wide mutual exclusion (see header). @LockTimeout = 0: don't queue up
    -- behind the holder — it processes every queued request anyway.
    DECLARE @lockRc int;
    EXEC @lockRc = sp_getapplock @Resource = N'reset:pipeline', @LockMode = 'Exclusive',
                                 @LockOwner = 'Session', @LockTimeout = 0;
    IF @lockRc < 0
        RETURN;   -- another pipeline instance is already draining the queue

    BEGIN TRY
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
                @log nvarchar(max), @ddl nvarchar(max),
                -- Sec-I1: the mandant's shop license, scrubbed out of persisted error
                -- texts below. SQL Server error messages can echo DATA (e.g. truncation
                -- error 2628 quotes the offending value), so a failing statement that
                -- carries cShopLicense would otherwise leak it into cErrorMessage /
                -- cStepLog — both readable by ops_reset_executor.
                @secret nvarchar(500);

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

            SET @secret = (SELECT cShopLicense FROM ops.tMandant WHERE cMandantKey = @MandantKey);

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
                 WHERE kResetRequest = @RequestId AND cStatus = N'running';
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
                        -- Sec-I1: never persist the shop license, even when an engine error
                        -- text echoes it (see @secret declaration).
                        IF @secret IS NOT NULL AND LEN(@secret) > 0
                            SET @log = REPLACE(@log, @secret, N'***');
                        EXEC reset.spInternal_LogStep @RequestId, @log;
                    END CATCH

                    FETCH NEXT FROM stepcur INTO @stepProc, @isCritical;
                END
                CLOSE stepcur; DEALLOCATE stepcur;

                -- B4: guard on the expected source state. Without it, a request that a
                -- concurrent reset.spPub_CancelResetRequest force-reclaimed to 'failed'
                -- mid-run would be silently resurrected to 'succeeded' here, erasing the
                -- cancel audit trail.
                UPDATE ops.tResetRequest
                   SET cStatus = N'succeeded', dFinished = SYSUTCDATETIME(), dModified = SYSUTCDATETIME()
                 WHERE kResetRequest = @RequestId AND cStatus = N'running';
                IF @@ROWCOUNT = 0
                    EXEC reset.spInternal_LogStep @RequestId,
                         N'WARN terminal-state race: request was no longer ''running'' when the pipeline finished — its status (likely a concurrent cancel/reclaim) is left untouched';
            END TRY
            BEGIN CATCH
                SET @err = ERROR_MESSAGE();

                -- B2: a failure inside the TRY that is NOT a step failure (e.g. a
                -- reset.spInternal_LogStep deadlock) reaches this CATCH with stepcur still
                -- open. Without cleanup, the next iteration's DECLARE stepcur would fail
                -- with error 16915 and every remaining queued request would be marked
                -- failed with that misleading cursor error. CURSOR_STATUS: >= 0 open,
                -- -1 closed-but-allocated, <= -2 not allocated.
                IF CURSOR_STATUS('local', N'stepcur') >= -1
                BEGIN
                    IF CURSOR_STATUS('local', N'stepcur') >= 0
                        CLOSE stepcur;
                    DEALLOCATE stepcur;
                END

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

                -- Sec-I1: scrub the shop license out of the persisted error text (see
                -- @secret declaration — engine error texts can echo data values).
                IF @secret IS NOT NULL AND LEN(@secret) > 0
                    SET @err = REPLACE(@err, @secret, N'***');

                -- B4: same guard as the success path — never overwrite a state a
                -- concurrent cancel/reclaim already made terminal.
                UPDATE ops.tResetRequest
                   SET cStatus = N'failed', cErrorMessage = @err, dFinished = SYSUTCDATETIME(), dModified = SYSUTCDATETIME()
                 WHERE kResetRequest = @RequestId AND cStatus = N'running';
                IF @@ROWCOUNT = 0
                BEGIN
                    SET @log = CONCAT(N'WARN terminal-state race: pipeline failed (', @err,
                                      N') but the request was no longer ''running'' — its status is left untouched');
                    EXEC reset.spInternal_LogStep @RequestId, @log;
                END
            END CATCH
        END

        EXEC sp_releaseapplock @Resource = N'reset:pipeline', @LockOwner = 'Session';
    END TRY
    BEGIN CATCH
        -- Release-then-rethrow: without this, an error outside the per-request CATCH
        -- (claim UPDATE, stale reclaim, DELETE @claimed) would leave the session applock
        -- held until the session ends — harmless for the Agent job (its session closes),
        -- but a manual operator session would silently block every later job run.
        EXEC sp_releaseapplock @Resource = N'reset:pipeline', @LockOwner = 'Session';
        THROW;
    END CATCH
END
GO
