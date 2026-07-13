-- 0002_ops_schema_tables.sql  (Ebene B / global chain — runs in RoboticoOps)
--
-- Creates the two RoboticoOps schemas and the three registry/queue tables the
-- test-mandant reset is built on. Both schemas are AUTHORIZATION dbo so that
-- ownership chaining covers cross-object access inside the signed / EXECUTE-AS
-- procedures (the reset.* procs read ops.* without needing explicit grants to the
-- impersonated jobstartuser — see reset.spPub_StartTestmandantReset).
--
--   ops.tMandant       — registry of test mandants (which clone belongs to whom).
--   ops.tConfig        — key/value config that replaces the hard-coded paths from
--                       the legacy Projekte/Testsystem scripts.
--   ops.tResetRequest  — request queue + run log (state machine, audit trail).
--
-- The reset PIPELINE definition (ops.tResetStep — the ordered reset.spInternal_* steps)
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

-- --- ops.tMandant -----------------------------------------------------------------
-- One row per test mandant. cTargetDb is guarded three ways against ever pointing at
-- the production DB: a CHECK here, plus SP-level and job-level re-validation (D6).
IF OBJECT_ID(N'ops.tMandant', N'U') IS NULL
BEGIN
    CREATE TABLE ops.tMandant
    (
        cMandantKey   sysname       NOT NULL
            CONSTRAINT PK_tMandant PRIMARY KEY,
        cTargetDb     sysname       NOT NULL,
        cDisplayName  nvarchar(255) NOT NULL,
        cDeveloper    nvarchar(255) NULL,
        cLoginName    sysname       NULL,
        cShopUrl      nvarchar(500) NULL,
        cShopLicense  nvarchar(500) NULL,
        bActive     bit           NOT NULL CONSTRAINT DF_tMandant_bActive DEFAULT (1),
        dCreated    datetime2(0)  NOT NULL CONSTRAINT DF_tMandant_dCreated DEFAULT (SYSUTCDATETIME()),
        dModified   datetime2(0)  NOT NULL CONSTRAINT DF_tMandant_dModified DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT CK_tMandant_cMandantKey CHECK (cMandantKey LIKE 'tm[0-9]%'),
        CONSTRAINT CK_tMandant_cTargetDb   CHECK (cTargetDb <> N'eazybusiness'
                                                    AND cTargetDb LIKE N'eazybusiness[_]%'),
        CONSTRAINT UQ_tMandant_cTargetDb   UNIQUE (cTargetDb)
    );
END
GO

-- --- ops.tConfig ------------------------------------------------------------------
-- Key/value config (BackupFile, TargetDataDir, SourceDb, ReferenceMandant, ...).
IF OBJECT_ID(N'ops.tConfig', N'U') IS NULL
BEGIN
    CREATE TABLE ops.tConfig
    (
        cKey    sysname        NOT NULL
            CONSTRAINT PK_tConfig PRIMARY KEY,
        cValue  nvarchar(1000) NULL,
        cNotes        nvarchar(500)  NULL
    );
END
GO

-- --- ops.tResetRequest ------------------------------------------------------------
-- Queue + run log. State machine: queued -> running -> succeeded | failed.
-- The filtered UNIQUE index enforces "at most one active request per cTargetDb"
-- declaratively, on top of the SP-level applock (belt and braces).
IF OBJECT_ID(N'ops.tResetRequest', N'U') IS NULL
BEGIN
    CREATE TABLE ops.tResetRequest
    (
        kResetRequest    int IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_tResetRequest PRIMARY KEY,
        cMandantKey   sysname       NOT NULL
            CONSTRAINT FK_tResetRequest_tMandant REFERENCES ops.tMandant (cMandantKey),
        cTargetDb     sysname       NOT NULL,
        cStatus       nvarchar(20)  NOT NULL
            CONSTRAINT CK_tResetRequest_cStatus
                CHECK (cStatus IN (N'queued', N'running', N'succeeded', N'failed')),
        cRequestedBy  sysname       NOT NULL,
        dRequested  datetime2(0)  NOT NULL CONSTRAINT DF_tResetRequest_dRequested DEFAULT (SYSUTCDATETIME()),
        dStarted    datetime2(0)  NULL,
        dFinished   datetime2(0)  NULL,
        cErrorMessage    nvarchar(max) NULL,
        cStepLog      nvarchar(max) NULL,
        dModified   datetime2(0)  NOT NULL CONSTRAINT DF_tResetRequest_dModified DEFAULT (SYSUTCDATETIME())
    );

    CREATE UNIQUE INDEX IX_tResetRequest_Active
        ON ops.tResetRequest (cTargetDb)
        WHERE cStatus IN (N'queued', N'running');
END
GO
