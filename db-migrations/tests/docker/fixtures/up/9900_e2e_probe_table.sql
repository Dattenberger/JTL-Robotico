-- ============================================================================
-- Robotico.tE2EProbe — E2E fixture: one-time probe table (grate up/ semantics)
-- ============================================================================
-- FIXTURE, NOT part of either migration chain. Lives under
-- db-migrations/tests/docker/fixtures/ and is copied into eazybusiness/up/ only
-- for the duration of the Docker E2E (Section B of e2e-docker-report.md), then
-- removed again. It proves grate's one-time semantics: an up/ script runs exactly
-- once (tracked by hash) and is NOT re-run when an anytime sibling changes.
--
-- Idempotent guard so a re-copy against an instance that already has it is inert.
SET NOCOUNT ON;

IF OBJECT_ID(N'Robotico.tE2EProbe', N'U') IS NULL
BEGIN
    CREATE TABLE Robotico.tE2EProbe
    (
        kProbe   int IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_Robotico_tE2EProbe PRIMARY KEY,
        cLabel   nvarchar(100)     NOT NULL,
        dCreated datetime2(0)      NOT NULL
            CONSTRAINT DF_Robotico_tE2EProbe_dCreated DEFAULT (SYSUTCDATETIME())
    );

    INSERT INTO Robotico.tE2EProbe (cLabel) VALUES (N'seeded-by-up-9900');
END
GO
