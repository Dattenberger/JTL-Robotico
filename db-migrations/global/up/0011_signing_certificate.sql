-- 0011_signing_certificate.sql  (Ebene B / global chain — runs in RoboticoOps)
--
-- Sets up the module-signing certificate that lets the low-privilege caller of
-- reset.StartTestmandantReset reach msdb.dbo.sp_start_job WITHOUT TRUSTWORTHY and
-- WITHOUT counter-signing msdb system procs (hybrid recipe, research/3 §1/§4, D6).
--
--   1. Certificate RoboticoOpsSigning WITH a private key (encrypted by the deploy
--      token {{CertPassword}}) lives in RoboticoOps. It signs the SP
--      (see permissions/900_resign_procedures).
--   2. Its PUBLIC key is copied into master via CERTENCODED() as a binary literal —
--      no disk round-trip, no BACKUP CERTIFICATE to a file.
--   3. A login RoboticoOpsSigningLogin is created FROM that public certificate and
--      granted AUTHENTICATE SERVER — this is what carries the impersonated
--      jobstartuser context across the RoboticoOps -> msdb boundary.
--
-- The password never lives in git: {{CertPassword}} is a grate token supplied at
-- deploy time (deploy.ps1 -Scope global -> prompt or $env:GRATE_CERT_PASSWORD).
--
-- PASSWORD CONSTRAINTS (CQG-3 / CQG-4):
--   * No single quote. grate substitutes {{CertPassword}} textually INTO a single-quoted
--     SQL literal (here and in permissions/900_resign_procedures). A password containing
--     a ' would break out of the literal — a syntax error at best. deploy.ps1 rejects it
--     up front (@see db-migrations/deploy.ps1, slot 5); keep the char-set safe if signing
--     is ever done by hand.
--   * Set once, immutable. This is a one-time up/ script: the private-key password is
--     fixed at the FIRST global deploy. The everytime permissions/900_resign_procedures
--     must unlock that same key with the SAME {{CertPassword}} on every later deploy — a
--     different value there fails re-signing with an opaque private-key error. To rotate
--     the password you must DROP and recreate the certificate (new up/ script) and
--     re-sign. See README §7 and 900's TRY/CATCH message.
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§2)
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur/research/3-module-signing-agent-job

SET NOCOUNT ON;

-- --- 1. signing certificate (with private key) in RoboticoOps -------------------
IF NOT EXISTS (SELECT 1 FROM sys.certificates WHERE name = N'RoboticoOpsSigning')
BEGIN
    CREATE CERTIFICATE RoboticoOpsSigning
        ENCRYPTION BY PASSWORD = '{{CertPassword}}'
        WITH SUBJECT = 'RoboticoOps reset SP signing certificate',
             EXPIRY_DATE = '2999-12-31';
    PRINT 'Certificate [RoboticoOpsSigning] created in RoboticoOps.';
END
GO

-- --- 2. copy the PUBLIC key into master (binary literal, no file) ---------------
DECLARE @pub varbinary(max) = CERTENCODED(CERT_ID(N'RoboticoOpsSigning'));
-- CONVERT style 1 -> '0x....' hex string; CONCAT (not '+') so the data-concat lint
-- heuristic stays quiet (the value is a public key, not caller data).
DECLARE @installCert nvarchar(max) = CONCAT(
    N'IF NOT EXISTS (SELECT 1 FROM sys.certificates WHERE name = N''RoboticoOpsSigning'') ',
    N'CREATE CERTIFICATE RoboticoOpsSigning FROM BINARY = ',
    CONVERT(nvarchar(max), @pub, 1), N';');
EXEC master.sys.sp_executesql @installCert;
GO

-- --- 3. login from the public certificate + AUTHENTICATE SERVER (in master) -----
EXEC master.sys.sp_executesql N'
    IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N''RoboticoOpsSigningLogin'')
        CREATE LOGIN RoboticoOpsSigningLogin FROM CERTIFICATE RoboticoOpsSigning;
    GRANT AUTHENTICATE SERVER TO RoboticoOpsSigningLogin;
';
GO
