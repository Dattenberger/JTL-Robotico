-- reset.spPub_CreateTestmandant  (Ebene B / global — admin entry point, grant-only)
--
-- One-call creation of a NEW test mandant: register it in ops.tMandant and (by default)
-- kick its first reset. That first reset is what physically CREATES the clone database —
-- reset.spInternal_CloneDatabase RESTOREs eazybusiness_<key> from a COPY_ONLY backup, so the
-- target DB need not exist beforehand. This is the sanctioned alternative to a manual
-- INSERT into ops.tMandant + separate spPub_StartTestmandantReset.
--
-- Admin-only (EXECUTE → ops_admin, permissions/100): defining a new database on the instance
-- is an administrative act. Triggering resets of ALREADY-registered mandants stays a
-- consumer action (ops_reset_executor). No signing / EXECUTE AS here: this proc runs in
-- RoboticoOps and delegates the msdb crossing to reset.spPub_StartTestmandantReset, which carries
-- its own certificate signature. The caller therefore needs EXECUTE on BOTH procs — both are
-- granted to ops_admin in permissions/100_grants (explicit, independent of EXECUTE
-- ownership-chaining nuances).
--
-- No silent upsert: an existing cMandantKey (or cTargetDb) is a hard THROW — corrections to an
-- existing mandant go through an admin UPDATE on ops.tMandant, not through this create path.
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§3)
-- @see db-migrations/global/sprocs/reset.spPub_StartTestmandantReset.sql
CREATE OR ALTER PROCEDURE reset.spPub_CreateTestmandant
    @MandantKey  sysname,
    @DisplayName nvarchar(255),
    @LoginName   sysname       = NULL,   -- default: the shared dev login the template seeds
    @TargetDb    sysname       = NULL,   -- default: eazybusiness_<cMandantKey>
    @ShopUrl     nvarchar(500) = NULL,
    @ShopLicense nvarchar(500) = NULL,   -- NULL -> the 0020 runbook sentinel
    @StartReset  bit           = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- --- defaults ----------------------------------------------------------------
    IF @TargetDb IS NULL
        SET @TargetDb = N'eazybusiness_' + @MandantKey;
    IF @LoginName IS NULL
        SET @LoginName = N'dbuser_dev_dana_for_development';   -- matches 0020 template seed
    IF @ShopLicense IS NULL
        SET @ShopLicense = N'<SET-VIA-RUNBOOK>';               -- sentinel, identical to 0020

    -- --- validation (clear errors mirroring the CHECK constraints) ----------------
    IF NULLIF(LTRIM(RTRIM(@DisplayName)), N'') IS NULL
        THROW 51090, 'reset.spPub_CreateTestmandant: @DisplayName must not be empty.', 1;

    IF @MandantKey NOT LIKE N'tm[0-9]%'
        THROW 51091, 'reset.spPub_CreateTestmandant: @MandantKey must match tm<number> (e.g. tm5) — CK_tMandant_cMandantKey.', 1;

    IF @TargetDb = N'eazybusiness' OR @TargetDb NOT LIKE N'eazybusiness[_]%'
        THROW 51092, 'reset.spPub_CreateTestmandant: @TargetDb must be a test-mandant clone name (eazybusiness_<...>), never the production eazybusiness.', 1;

    -- No silent upsert: an existing key/DB is an explicit error.
    IF EXISTS (SELECT 1 FROM ops.tMandant WHERE cMandantKey = @MandantKey)
        THROW 51093, 'reset.spPub_CreateTestmandant: this cMandantKey already exists. Change an existing mandant via an admin UPDATE on ops.tMandant, or pick a new key.', 1;
    IF EXISTS (SELECT 1 FROM ops.tMandant WHERE cTargetDb = @TargetDb)
        THROW 51094, 'reset.spPub_CreateTestmandant: this cTargetDb is already registered to another mandant.', 1;

    -- --- register (CHECK constraints are the declarative backstop) -----------------
    INSERT ops.tMandant (cMandantKey, cTargetDb, cDisplayName, cDeveloper, cLoginName, cShopUrl, cShopLicense, bActive)
    VALUES (@MandantKey, @TargetDb, @DisplayName, NULL, @LoginName, @ShopUrl, @ShopLicense, 1);

    -- --- optionally kick the first reset (this CREATES the clone DB) ---------------
    IF @StartReset = 1
    BEGIN
        -- spPub_StartTestmandantReset enqueues + starts the Agent job and returns {kResetRequest, cStatus}.
        EXEC reset.spPub_StartTestmandantReset @MandantKey = @MandantKey;
        RETURN;
    END

    SELECT CAST(NULL AS int) AS kResetRequest,
           N'registered (no reset requested — pass @StartReset = 1 or run reset.spPub_StartTestmandantReset to build the clone)' AS cStatus;
END
GO
