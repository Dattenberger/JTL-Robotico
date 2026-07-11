-- 0002_ops_schema_tables.sql  (Ebene B / global chain — runs in RoboticoOps)
--
-- Creates the two RoboticoOps schemas and the three registry/queue tables the
-- test-mandant reset is built on. Both schemas are AUTHORIZATION dbo so that
-- ownership chaining covers cross-object access inside the signed / EXECUTE-AS
-- procedures (the reset.* procs read ops.* without needing explicit grants to the
-- impersonated jobstartuser — see reset.StartTestmandantReset).
--
--   ops.Mandant       — registry of test mandants (which clone belongs to whom).
--   ops.Config        — key/value config that replaces the hard-coded paths from
--                       the legacy Projekte/Testsystem scripts.
--   ops.ResetRequest  — request queue + run log (state machine, audit trail).
--
-- The reset PIPELINE definition (ops.ResetStep — the ordered reset.internal_* steps)
-- is a later addition and lives in up/0021_reset_step_registry.sql (EXT-1).
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§2, §3)
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur/research/3-module-signing-agent-job

SET NOCOUNT ON;

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'ops')
    EXEC (N'CREATE SCHEMA ops AUTHORIZATION dbo;');
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'reset')
    EXEC (N'CREATE SCHEMA reset AUTHORIZATION dbo;');
GO

-- --- ops.Mandant -----------------------------------------------------------------
-- One row per test mandant. TargetDb is guarded three ways against ever pointing at
-- the production DB: a CHECK here, plus SP-level and job-level re-validation (D6).
IF OBJECT_ID(N'ops.Mandant', N'U') IS NULL
BEGIN
    CREATE TABLE ops.Mandant
    (
        MandantKey   sysname       NOT NULL
            CONSTRAINT PK_ops_Mandant PRIMARY KEY,
        TargetDb     sysname       NOT NULL,
        DisplayName  nvarchar(255) NOT NULL,
        Developer    nvarchar(255) NULL,
        LoginName    sysname       NULL,
        ShopUrl      nvarchar(500) NULL,
        ShopLicense  nvarchar(500) NULL,
        IsActive     bit           NOT NULL CONSTRAINT DF_ops_Mandant_IsActive DEFAULT (1),
        CreatedAt    datetime2(0)  NOT NULL CONSTRAINT DF_ops_Mandant_CreatedAt DEFAULT (SYSUTCDATETIME()),
        ModifiedAt   datetime2(0)  NOT NULL CONSTRAINT DF_ops_Mandant_ModifiedAt DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT CK_ops_Mandant_MandantKey CHECK (MandantKey LIKE 'tm[0-9]%'),
        CONSTRAINT CK_ops_Mandant_TargetDb   CHECK (TargetDb <> N'eazybusiness'
                                                    AND TargetDb LIKE N'eazybusiness[_]%'),
        CONSTRAINT UQ_ops_Mandant_TargetDb   UNIQUE (TargetDb)
    );
END
GO

-- --- ops.Config ------------------------------------------------------------------
-- Key/value config (BackupFile, TargetDataDir, SourceDb, ReferenceMandant, ...).
IF OBJECT_ID(N'ops.Config', N'U') IS NULL
BEGIN
    CREATE TABLE ops.Config
    (
        ConfigKey    sysname        NOT NULL
            CONSTRAINT PK_ops_Config PRIMARY KEY,
        ConfigValue  nvarchar(1000) NULL,
        Notes        nvarchar(500)  NULL
    );
END
GO

-- --- ops.ResetRequest ------------------------------------------------------------
-- Queue + run log. State machine: queued -> running -> succeeded | failed.
-- The filtered UNIQUE index enforces "at most one active request per TargetDb"
-- declaratively, on top of the SP-level applock (belt and braces).
IF OBJECT_ID(N'ops.ResetRequest', N'U') IS NULL
BEGIN
    CREATE TABLE ops.ResetRequest
    (
        RequestId    int IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_ops_ResetRequest PRIMARY KEY,
        MandantKey   sysname       NOT NULL
            CONSTRAINT FK_ops_ResetRequest_Mandant REFERENCES ops.Mandant (MandantKey),
        TargetDb     sysname       NOT NULL,
        Status       nvarchar(20)  NOT NULL
            CONSTRAINT CK_ops_ResetRequest_Status
                CHECK (Status IN (N'queued', N'running', N'succeeded', N'failed')),
        RequestedBy  sysname       NOT NULL,
        RequestedAt  datetime2(0)  NOT NULL CONSTRAINT DF_ops_ResetRequest_RequestedAt DEFAULT (SYSUTCDATETIME()),
        StartedAt    datetime2(0)  NULL,
        FinishedAt   datetime2(0)  NULL,
        ErrorText    nvarchar(max) NULL,
        StepLog      nvarchar(max) NULL,
        ModifiedAt   datetime2(0)  NOT NULL CONSTRAINT DF_ops_ResetRequest_ModifiedAt DEFAULT (SYSUTCDATETIME())
    );

    CREATE UNIQUE INDEX UX_ResetRequest_Active
        ON ops.ResetRequest (TargetDb)
        WHERE Status IN (N'queued', N'running');
END
GO
