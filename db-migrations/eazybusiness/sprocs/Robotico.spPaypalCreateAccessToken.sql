-- ============================================================================
-- Robotico.spPaypalCreateAccessToken — request a fresh PayPal OAuth token
-- ============================================================================
-- Requests a new PayPal bearer token (OAuth 2.0) via HTTP (sp_OA* / MSXML2),
-- using the client-id/secret from tPaypalSettings for the active mode, and
-- stores it in tPaypalAccessToken. Logs the call to tPaypalTrackingLog and
-- purges log rows older than 30 days.
--
-- NOTE: requires OLE Automation Procedures enabled on the server (see
-- WorkflowProcedures/PayPal/Enable OLE Procedures.sql).
--
-- Ported from WorkflowProcedures/PayPal/Add Procudures and Tables.sql (2026-07-10).
-- ============================================================================

CREATE OR ALTER PROCEDURE Robotico.spPaypalCreateAccessToken
    @debug BIT = 0   -- 1 = PRINT diagnostics (never prints the credentials)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRANSACTION
        DECLARE @DisableSandbox AS BIT = (SELECT IIF(cValue = 'TRUE', 1, 0)
                                          FROM Robotico.tPaypalSettings
                                          WHERE cKey = 'bDisableSandbox');
        DECLARE @IsProduction AS BIT = @DisableSandbox;

        DECLARE @BaseUrl AS VARCHAR(MAX) = (SELECT cValue
                                            FROM Robotico.tPaypalSettings
                                            WHERE cKey =
                                                  IIF(@DisableSandbox = 0, 'cPaypalBaseUrlSandbox', 'cPaypalBaseUrl'));
        DECLARE @URL NVARCHAR(MAX) = @BaseUrl +
                                     (SELECT cValue
                                      FROM Robotico.tPaypalSettings
                                      WHERE cKey = 'cPaypalAuthUrlPath'); -- our URL for post request
        DECLARE @User AS NVARCHAR(MAX) = (SELECT cValue
                                          FROM Robotico.tPaypalSettings
                                          WHERE cKey =
                                                IIF(@DisableSandbox = 0, 'cPaypalClientIdSandbox', 'cPaypalClientId'))
        DECLARE @Pass AS NVARCHAR(MAX) = (SELECT cValue
                                          FROM Robotico.tPaypalSettings
                                          WHERE cKey = IIF(@DisableSandbox = 0, 'cPaypalSecretSandbox', 'cPaypalSecret'))

        DECLARE @ResponseStatus AS VARCHAR(8000), @ResponseStatusText AS VARCHAR(8000), @ResponseText AS VARCHAR(8000);
        DECLARE @credentials AS VARCHAR(8000) = @User + ':' + @Pass
        DECLARE @credentialsBinary AS VARCHAR(8000);
        SELECT @credentialsBinary = CAST(N'' AS XML).value(
                'xs:base64Binary(xs:hexBinary(sql:column("bin")))'
            , 'VARCHAR(MAX)'
            )
        FROM (SELECT CAST(@credentials AS VARBINARY(MAX)) AS bin) AS RetVal;

        DECLARE @Auth AS VARCHAR(8000) = 'Basic ' + @credentialsBinary

        BEGIN
            DECLARE @HttpObject AS INT; -- object declaration

            EXEC sp_OACreate 'MSXML2.XMLHTTP', @HttpObject OUT;

            EXEC sp_OAMethod @HttpObject, 'open', NULL, 'post', @URL, 'false'
            EXEC sp_OAMethod @HttpObject, 'setRequestHeader', null, 'Content-Type', 'application/x-www-form-urlencoded'
            EXEC sp_OAMethod @HttpObject, 'setRequestHeader', null, 'Accept', 'application/json'
            EXEC sp_OAMethod @HttpObject, 'setRequestHeader', null, 'Accept-Language', 'en_US'
            EXEC sp_OAMethod @HttpObject, 'setRequestHeader', null, 'Authorization', @Auth
            EXEC sp_OAMethod @HttpObject, 'send', null, 'grant_type=client_credentials'

            EXEC sp_OAMethod @HttpObject, 'status', @ResponseStatus OUTPUT
            EXEC sp_OAMethod @HttpObject, 'statusText', @ResponseStatusText OUTPUT
            EXEC sp_OAMethod @HttpObject, 'responseText', @ResponseText OUTPUT

            EXEC sp_OADestroy @HttpObject

            -- @Auth is deliberately NEVER printed: it is 'Basic ' + base64(clientId:secret),
            -- a reversible credential. @ResponseText carries the fresh bearer token, so it
            -- only prints under @debug. Both would otherwise leak into deploy/exec logs.
            IF @debug = 1
            BEGIN
                PRINT 'RESULTS FOR spPaypalCreateAccessToken'
                PRINT 'URL ' + @URL;
                PRINT 'Status ' + @ResponseStatus + ' ' + @ResponseStatusText;
                PRINT '@ResponseText ' + @ResponseText;
                PRINT 'END RESULTS FOR spPaypalCreateAccessToken'
            END
        END

        INSERT INTO Robotico.tPaypalTrackingLog (cQuelle, bProduction, kInputKey, cBescheibung1, cBescheibung2, dErstellt)
        VALUES ('spPaypalCreateAccessToken', @DisableSandbox, NULL, 'Status ' + @ResponseStatus, @ResponseText, GETUTCDATE())
        DELETE FROM [Robotico].[tPaypalTrackingLog] WHERE dErstellt < DATEADD(day, -30, GETDATE())

        DELETE FROM Robotico.tPaypalAccessToken WHERE bProduction = @IsProduction

        INSERT INTO Robotico.tPaypalAccessToken
            (cScope, cAccessToken, cTokenType, cAppID, nExpiresInSeconds, dTokenCreated, bProduction)
        SELECT scope,
               access_token,
               token_type,
               app_id,
               expires_in,
               GETUTCDATE(),
               @IsProduction
        FROM OPENJSON(@ResponseText)
                      WITH (
                          scope NVARCHAR(MAX) '$.scope',
                          access_token NVARCHAR(MAX) '$.access_token',
                          token_type NVARCHAR(MAX) '$.token_type',
                          app_id NVARCHAR(MAX) '$.app_id',
                          expires_in INTEGER '$.expires_in',
                          nonce NVARCHAR(MAX) '$.nonce'
                          )
    COMMIT TRANSACTION
END
GO
