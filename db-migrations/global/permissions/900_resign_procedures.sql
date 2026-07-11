-- 900_resign_procedures.sql  (Ebene B / global — permissions, everytime, runs LAST)
--
-- CREATE OR ALTER strips a procedure's certificate signature, so every deploy that
-- (re)created a signed proc leaves it unsigned. This everytime script re-applies the
-- signature to each signature-required proc whose signature is currently missing.
--
-- The signature-required set is EXACTLY the procs declared WITH EXECUTE AS
-- 'jobstartuser' that need the cross-DB authenticate token (currently only
-- reset.StartTestmandantReset). Instead of hard-coding that list, the set is derived
-- from the catalog (sys.procedures.execute_as_principal_id = jobstartuser), so a
-- future EXECUTE-AS-'jobstartuser' entry point is signed automatically — it can never
-- deploy green through grate and then fail unsigned at first runtime call in msdb.
-- {{CertPassword}} is a grate deploy token (never in git); it unlocks the private key
-- of certificate RoboticoOpsSigning (up/0011) to sign with.
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§2)
-- @see db-migrations/global/up/0011_signing_certificate.sql

SET NOCOUNT ON;

DECLARE @procId INT, @procName NVARCHAR(300), @sql NVARCHAR(MAX), @signErr NVARCHAR(MAX);

DECLARE unsigned_procs CURSOR LOCAL FAST_FORWARD FOR
    SELECT p.object_id,
           QUOTENAME(SCHEMA_NAME(p.schema_id)) + N'.' + QUOTENAME(p.name)
    FROM sys.procedures p
    JOIN sys.sql_modules m ON m.object_id = p.object_id   -- execute_as_principal_id lives here, not on sys.procedures
    WHERE m.execute_as_principal_id = DATABASE_PRINCIPAL_ID(N'jobstartuser')
      AND NOT EXISTS (
            SELECT 1
            FROM sys.crypt_properties cp
            JOIN sys.certificates c ON cp.thumbprint = c.thumbprint
            WHERE cp.major_id = p.object_id
              AND c.name = N'RoboticoOpsSigning');

OPEN unsigned_procs;
FETCH NEXT FROM unsigned_procs INTO @procId, @procName;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'ADD SIGNATURE TO ' + @procName
             + N' BY CERTIFICATE RoboticoOpsSigning'
             + N' WITH PASSWORD = ''{{CertPassword}}'';';
    BEGIN TRY
        EXEC sys.sp_executesql @sql;
    END TRY
    BEGIN CATCH
        -- SQL Server reports a wrong cert password only as an opaque decryption error.
        -- The dominant cause here is a deploy-time {{CertPassword}} that differs from the
        -- password RoboticoOpsSigning was CREATED with in up/0011 (CQG-4), so name it.
        -- CONCAT (not '+') keeps the data-concat lint heuristic quiet.
        SET @signErr = CONCAT(
            N'900_resign_procedures: ADD SIGNATURE to ', @procName, N' failed (',
            ERROR_MESSAGE(),
            N'). Most likely the deploy-time {{CertPassword}} does not match the password ',
            N'RoboticoOpsSigning was created with in up/0011 — the certificate private key ',
            N'could not be unlocked. Supply the original cert password (see README §7 / ',
            N'~/.claude-secrets.md).');
        CLOSE unsigned_procs; DEALLOCATE unsigned_procs;
        THROW 50901, @signErr, 1;
    END CATCH
    PRINT 'Re-signed ' + @procName + ' with certificate RoboticoOpsSigning.';
    FETCH NEXT FROM unsigned_procs INTO @procId, @procName;
END
CLOSE unsigned_procs;
DEALLOCATE unsigned_procs;

-- Hard FAIL (chain convention) if any EXECUTE-AS-'jobstartuser' proc is still
-- unsigned after the loop — an unsigned entry point must break the deploy here,
-- not surface as an opaque msdb permission error in production.
DECLARE @stillUnsigned NVARCHAR(MAX) =
    (SELECT STRING_AGG(QUOTENAME(SCHEMA_NAME(p.schema_id)) + N'.' + QUOTENAME(p.name), N', ')
     FROM sys.procedures p
     JOIN sys.sql_modules m ON m.object_id = p.object_id   -- execute_as_principal_id lives here, not on sys.procedures
     WHERE m.execute_as_principal_id = DATABASE_PRINCIPAL_ID(N'jobstartuser')
       AND NOT EXISTS (
             SELECT 1
             FROM sys.crypt_properties cp
             JOIN sys.certificates c ON cp.thumbprint = c.thumbprint
             WHERE cp.major_id = p.object_id
               AND c.name = N'RoboticoOpsSigning'));
IF @stillUnsigned IS NOT NULL
BEGIN
    DECLARE @msg NVARCHAR(MAX) =
        N'900_resign_procedures: EXECUTE AS ''jobstartuser'' procedure(s) without '
        + N'RoboticoOpsSigning signature after re-sign pass: ' + @stillUnsigned;
    THROW 50900, @msg, 1;
END
GO
