-- 900_resign_procedures.sql  (Ebene B / global — permissions, everytime, runs LAST)
--
-- CREATE OR ALTER strips a procedure's certificate signature, so every deploy that
-- (re)created a signed proc leaves it unsigned. This everytime script re-applies the
-- signature to each signature-required proc whose signature is currently missing.
--
-- The signature-required set is EXACTLY the procs declared WITH EXECUTE AS that need
-- the cross-DB authenticate token — currently only reset.StartTestmandantReset.
-- {{CertPassword}} is a grate deploy token (never in git); it unlocks the private key
-- of certificate RoboticoOpsSigning (up/0011) to sign with.
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§2)
-- @see db-migrations/global/up/0011_signing_certificate.sql

SET NOCOUNT ON;

IF OBJECT_ID(N'reset.StartTestmandantReset') IS NOT NULL
   AND NOT EXISTS (
        SELECT 1
        FROM sys.crypt_properties cp
        JOIN sys.certificates c ON cp.thumbprint = c.thumbprint
        WHERE cp.major_id = OBJECT_ID(N'reset.StartTestmandantReset')
          AND c.name = N'RoboticoOpsSigning')
BEGIN
    ADD SIGNATURE TO reset.StartTestmandantReset
        BY CERTIFICATE RoboticoOpsSigning
        WITH PASSWORD = '{{CertPassword}}';
    PRINT 'Re-signed reset.StartTestmandantReset with certificate RoboticoOpsSigning.';
END
GO
