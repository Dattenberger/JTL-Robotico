-- 0021_reset_step_registry.sql  (Ebene B / global chain — runs in RoboticoOps)
--
-- EXT-1: makes the test-mandant reset pipeline DATA-DRIVEN. ops.tResetStep is the
-- ordered list of reset.spInternal_* steps that reset.spProcessNextResetRequest runs.
-- Adding a preparation step becomes "deploy a new reset.spInternal_* proc + INSERT one
-- row here" — the orchestrator is never edited again (Open/Closed; the user's explicit
-- extensibility wish).
--
-- Security (see adrs/adr-reset-step-registry.md): the orchestrator whitelists every
-- cProcName against the deployed catalog (schema reset, 'spInternal_' prefix) before it
-- EXECs the name via QUOTENAME. So the EXECUTABLE set stays exactly what the versioned
-- chain deployed — only step ORDER / ENABLEMENT becomes admin-only data. That narrows,
-- but does not break, the D6 "job content only via versioned deployment" guarantee.
-- Write access to ops.tResetStep is admin-only (ops_admin), like the other ops registry
-- tables — a role that is already effectively sysadmin in this threat model.
--
-- The canonical default pipeline is SEEDED here, so git — not just a live table — is
-- the source of truth for the out-of-the-box order. Idempotent: the table is guarded by
-- IF OBJECT_ID and the seed inserts keyed by cProcName, so a re-run against a fresh
-- instance is harmless and never disturbs an order an admin has already tuned.
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§3)
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur/adrs/adr-reset-step-registry.md

SET NOCOUNT ON;

-- --- ops.tResetStep ---------------------------------------------------------------
-- One row per pipeline step. nStepOrder is the execution order; bEnabled toggles a
-- step without deleting it; bCritical=1 (default) means a failure aborts the run
-- (clone quarantined 'failed'), bCritical=0 means the failure is logged as WARN and
-- the pipeline continues. cProcName is the reset.spInternal_* proc NAME only (schema is
-- always 'reset'); the CHECK mirrors the orchestrator whitelist so a bad name cannot
-- even land in the table.
IF OBJECT_ID(N'ops.tResetStep', N'U') IS NULL
BEGIN
    CREATE TABLE ops.tResetStep
    (
        kResetStep      int IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_tResetStep PRIMARY KEY,
        nStepOrder   int           NOT NULL,
        cProcName    sysname       NOT NULL,
        bEnabled   bit           NOT NULL CONSTRAINT DF_tResetStep_bEnabled  DEFAULT (1),
        bCritical  bit           NOT NULL CONSTRAINT DF_tResetStep_bCritical DEFAULT (1),
        cNotes       nvarchar(400) NULL,
        CONSTRAINT UQ_tResetStep_cProcName  UNIQUE (cProcName),
        CONSTRAINT UQ_tResetStep_nStepOrder UNIQUE (nStepOrder),
        CONSTRAINT CK_tResetStep_cProcName  CHECK (cProcName LIKE N'spInternal[_]%')
    );

    -- ops_admin maintains the pipeline table (mirrors 0003_roles' grants on the other
    -- ops registry tables). The reset job runs as sysadmin and reaches the table via
    -- ownership chaining, so it needs no grant of its own.
    GRANT SELECT, INSERT, UPDATE, DELETE ON ops.tResetStep TO ops_admin;
END
GO

-- --- seed the canonical pipeline order -------------------------------------------
-- Matches the sequence reset.spProcessNextResetRequest ran as a hard-coded list before
-- EXT-1. Keyed by cProcName so a re-deploy adds only genuinely new steps and never
-- overwrites an order/enabled/critical value an admin has adjusted.
--
-- Seeded row-by-row instead of one MERGE (QG3 B12): if an admin re-ordered the live
-- table onto a number a LATER seed row uses, a set-based insert would break the whole
-- deploy with a UQ_tResetStep_nStepOrder violation. Per row, a taken nStepOrder falls
-- back to MAX+10 (appended at the end) — the admin's tuning wins, the new step still
-- lands, and its order can then be tuned like any other row.
DECLARE @seedOrder int, @seedProc sysname, @seedNotes nvarchar(400);
DECLARE seedcur CURSOR LOCAL FAST_FORWARD FOR
    SELECT v.nStepOrder, v.cProcName, v.cNotes FROM (VALUES
        (10, N'spInternal_CloneDatabase',         N'COPY_ONLY backup + restore-with-move'),
        (20, N'spInternal_PostRestoreSecurity',   N'owner->sa, orphan remap, TRUSTWORTHY OFF'),
        (30, N'spInternal_InvalidateCredentials', N'clear secrets, repoint JS-Shop to staging'),
        (40, N'spInternal_NeutralizeWorker',      N'lock pf_user/ebay, auth tokens cleared, empty worker queues'),
        (50, N'spInternal_AnonymizeCustomerData', N'11 PII priority blocks'),
        (60, N'spInternal_GrantAccess',           N'developer login -> db_owner in the clone'),
        (70, N'spInternal_RegisterMandant',       N'tMandant upsert + tBenutzerFirma seed'),
        (80, N'spInternal_ApplyJtlRoles',         N'JTL_Reader/JTL_Writer roles + members')
    ) v (nStepOrder, cProcName, cNotes)
    ORDER BY v.nStepOrder;
OPEN seedcur;
FETCH NEXT FROM seedcur INTO @seedOrder, @seedProc, @seedNotes;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF NOT EXISTS (SELECT 1 FROM ops.tResetStep WHERE cProcName = @seedProc)
    BEGIN
        IF EXISTS (SELECT 1 FROM ops.tResetStep WHERE nStepOrder = @seedOrder)
            SELECT @seedOrder = MAX(nStepOrder) + 10 FROM ops.tResetStep;
        INSERT INTO ops.tResetStep (nStepOrder, cProcName, cNotes)
        VALUES (@seedOrder, @seedProc, @seedNotes);
    END
    FETCH NEXT FROM seedcur INTO @seedOrder, @seedProc, @seedNotes;
END
CLOSE seedcur;
DEALLOCATE seedcur;
GO
