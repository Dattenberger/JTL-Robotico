-- ============================================================================
-- Robotico.spPaypalGetAccessToken — return a valid PayPal OAuth bearer token
-- ============================================================================
-- Returns the cached PayPal bearer token (OAuth 2.0) for the active mode
-- (sandbox/production per tPaypalSettings.bDisableSandbox). Requests a fresh
-- token via Robotico.spPaypalCreateAccessToken when none exists or it expires
-- within 60 seconds.
--
-- Ported from WorkflowProcedures/PayPal/Add Procudures and Tables.sql (2026-07-10):
-- extracted from the combined tables+procs file into its own anytime file.
-- Runtime dependency: Robotico.spPaypalCreateAccessToken (same folder).
-- ============================================================================

CREATE OR ALTER PROCEDURE Robotico.spPaypalGetAccessToken @token NVARCHAR(MAX) OUTPUT
AS
BEGIN
    BEGIN TRANSACTION
        DECLARE @DisableSandbox AS BIT = (SELECT IIF(cValue = 'TRUE', 1, 0)
                                          FROM Robotico.tPaypalSettings WITH (UPDLOCK)
                                          WHERE cKey = 'bDisableSandbox');
        DECLARE @IsProduction AS BIT = @DisableSandbox;
        IF (NOT EXISTS(SELECT 1 FROM Robotico.tPaypalAccessToken WITH (UPDLOCK) WHERE bProduction = @IsProduction) OR
            (SELECT TOP 1 nExpiresInSeconds - DATEDIFF(SECOND, dTokenCreated, GETUTCDATE())
             FROM Robotico.tPaypalAccessToken WITH (UPDLOCK)
             WHERE bProduction = @IsProduction) < 60)
            EXEC Robotico.spPaypalCreateAccessToken
        SET @token =
                (SELECT cAccessToken FROM Robotico.tPaypalAccessToken WITH (UPDLOCK) WHERE bProduction = @IsProduction)
    COMMIT TRANSACTION
END
GO
