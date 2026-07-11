-- 0021_reset_step_registry.sql  (Ebene B / global chain — runs in RoboticoOps)
--
-- EXT-1: makes the test-mandant reset pipeline DATA-DRIVEN. ops.ResetStep is the
-- ordered list of reset.internal_* steps that reset.ProcessNextResetRequest runs.
-- Adding a preparation step becomes "deploy a new reset.internal_* proc + INSERT one
-- row here" — the orchestrator is never edited again (Open/Closed; the user's explicit
-- extensibility wish).
--
-- Security (see adrs/adr-reset-step-registry.md): the orchestrator whitelists every
-- ProcName against the deployed catalog (schema reset, 'internal_' prefix) before it
-- EXECs the name via QUOTENAME. So the EXECUTABLE set stays exactly what the versioned
-- chain deployed — only step ORDER / ENABLEMENT becomes admin-only data. That narrows,
-- but does not break, the D6 "job content only via versioned deployment" guarantee.
-- Write access to ops.ResetStep is admin-only (ops_admin), like the other ops registry
-- tables — a role that is already effectively sysadmin in this threat model.
--
-- The canonical default pipeline is SEEDED here, so git — not just a live table — is
-- the source of truth for the out-of-the-box order. Idempotent: the table is guarded by
-- IF OBJECT_ID and the seed MERGEs by ProcName, so a re-run against a fresh instance is
-- harmless and never disturbs an order an admin has already tuned.
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§3)
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur/adrs/adr-reset-step-registry.md

SET NOCOUNT ON;

-- --- ops.ResetStep ---------------------------------------------------------------
-- One row per pipeline step. StepOrder is the execution order; IsEnabled toggles a
-- step without deleting it; IsCritical=1 (default) means a failure aborts the run
-- (clone quarantined 'failed'), IsCritical=0 means the failure is logged as WARN and
-- the pipeline continues. ProcName is the reset.internal_* proc NAME only (schema is
-- always 'reset'); the CHECK mirrors the orchestrator whitelist so a bad name cannot
-- even land in the table.
IF OBJECT_ID(N'ops.ResetStep', N'U') IS NULL
BEGIN
    CREATE TABLE ops.ResetStep
    (
        StepId      int IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_ops_ResetStep PRIMARY KEY,
        StepOrder   int           NOT NULL,
        ProcName    sysname       NOT NULL,
        IsEnabled   bit           NOT NULL CONSTRAINT DF_ops_ResetStep_IsEnabled  DEFAULT (1),
        IsCritical  bit           NOT NULL CONSTRAINT DF_ops_ResetStep_IsCritical DEFAULT (1),
        Notes       nvarchar(400) NULL,
        CONSTRAINT UQ_ops_ResetStep_ProcName  UNIQUE (ProcName),
        CONSTRAINT UQ_ops_ResetStep_StepOrder UNIQUE (StepOrder),
        CONSTRAINT CK_ops_ResetStep_ProcName  CHECK (ProcName LIKE N'internal[_]%')
    );

    -- ops_admin maintains the pipeline table (mirrors 0003_roles' grants on the other
    -- ops registry tables). The reset job runs as sysadmin and reaches the table via
    -- ownership chaining, so it needs no grant of its own.
    GRANT SELECT, INSERT, UPDATE, DELETE ON ops.ResetStep TO ops_admin;
END
GO

-- --- seed the canonical pipeline order -------------------------------------------
-- Matches the sequence reset.ProcessNextResetRequest ran as a hard-coded list before
-- EXT-1. MERGE by ProcName so a re-deploy adds only genuinely new steps and never
-- overwrites an order/enabled/critical value an admin has adjusted.
MERGE ops.ResetStep AS tgt
USING (VALUES
    (10, N'internal_CloneDatabase',         N'COPY_ONLY backup + restore-with-move'),
    (20, N'internal_PostRestoreSecurity',   N'owner->sa, orphan remap, TRUSTWORTHY OFF'),
    (30, N'internal_InvalidateCredentials', N'clear secrets, repoint JS-Shop to staging'),
    (40, N'internal_NeutralizeWorker',      N'lock pf_user/ebay, empty worker queues'),
    (50, N'internal_AnonymizeCustomerData', N'11 PII priority blocks'),
    (60, N'internal_GrantAccess',           N'developer login -> db_owner in the clone'),
    (70, N'internal_RegisterMandant',       N'tMandant upsert + tBenutzerFirma seed'),
    (80, N'internal_ApplyJtlRoles',         N'JTL_Reader/JTL_Writer roles + members')
) AS src (StepOrder, ProcName, Notes)
    ON tgt.ProcName = src.ProcName
WHEN NOT MATCHED BY TARGET THEN
    INSERT (StepOrder, ProcName, Notes) VALUES (src.StepOrder, src.ProcName, src.Notes);
GO
