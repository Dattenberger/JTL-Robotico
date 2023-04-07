use eazybusiness

-- Create Schema if not exists
BEGIN
    IF NOT EXISTS(SELECT *
                  FROM sys.schemas
                  WHERE name = N'Robotico')
        BEGIN
            -- Dieses Schema umfasst alle Tabellen und Stored Procedures, die nicht direkt von JTL sondern von robotico (also uns) erstellt wurden.
            EXEC ('CREATE SCHEMA Robotico')
        END
END

BEGIN
    IF (object_id('Robotico.tPaypalAccessToken', 'U') is null)
        BEGIN
            -- Diese Tabelle speichert den Token, der für die Kommunikation mit Paypal benötigt wird. Es werden maximal zwei Token gespeichert, einer für den Produktivmodus und einer für den Sandboxmodus.
            CREATE TABLE Robotico.tPaypalAccessToken
            (
                kKey              INTEGER IDENTITY (1,1) PRIMARY KEY,
                cScope            NVARCHAR(MAX),
                cAccessToken      NVARCHAR(MAX),
                cTokenType        NVARCHAR(MAX),
                cAppID            NVARCHAR(MAX),
                nExpiresInSeconds INTEGER,
                dTokenCreated     DATETIME,
                bProduction       BIT UNIQUE NOT NULL
            )
        end
END

BEGIN
    IF (object_id('Robotico.tPaypalTrackingLog', 'U') is null)
            -- Diese Tabelle speichert ein Log für alle Tracking API Calls. Die Daten werden nach 30 Tagen gelöscht.
            CREATE TABLE Robotico.tPaypalTrackingLog
            (
                kPaypalTrackingLog INTEGER IDENTITY (1,1) PRIMARY KEY,
                bProduction         BIT,
                cQuelle            NVARCHAR(255),
                kInputKey          INTEGER,
                cBescheibung1      NVARCHAR(MAX),
                cBescheibung2      NVARCHAR(MAX),
                dErstellt          DATETIME,
            );
END

BEGIN
    -- Create Table if not exists
-- The table is meant to store only one token at a time.
    IF (object_id('Robotico.tPaypalSettings', 'U') is null)
        BEGIN
            -- Diese Tabelle speichert die Einstellungen, die für die Kommunikation mit Paypal benötigt werden.
            CREATE TABLE Robotico.tPaypalSettings
            (
                kSetting         INTEGER IDENTITY (1,1) PRIMARY KEY,
                cKey             NVARCHAR(100) NOT NULL,
                cValue           NVARCHAR(MAX),
                cEigeneBemerkung NVARCHAR(MAX),
                cDokumentation         NVARCHAR(MAX)
            )
            CREATE UNIQUE INDEX IX_Robotic_tPaypalSettings_cKey ON Robotico.tPaypalSettings (cKey)
        END
END


DECLARE @tDefaultSettings TABLE
                          (
                              cKey             NVARCHAR(MAX),
                              cValue           NVARCHAR(MAX),
                              cDokumentation   NVARCHAR(MAX)
                          );

INSERT INTO @tDefaultSettings (cKey, cValue, cDokumentation)
VALUES ('bDisableSandbox', 'FALSE',
        'Wenn der Wert auf TRUE (Grossbuchstaben) gesetzt ist, wird der Produktivmodus verwendet. Ansonsten der Sandboxmodus.'),
       ('cPaypalBaseUrl', 'https://api-m.paypal.com',
        N'Url der PayPal Pruduktiv API. Format: https://url.tdl (ohne Slash am Ende).'),
       ('cPaypalBaseUrlSandbox', 'https://api-m.sandbox.paypal.com',
        N'Url der PayPal Sandbox API. Format: https://url.tdl (ohne Slash am Ende).'),
       ('cPaypalAuthUrlPath', '/v1/oauth2/token',
        'URL Pfad die Auth API. Mit dieser kann ein Token angefordert werden. Format: /path/path (Mit Slash am Anfang)'),
       ('cPaypalTrackingUrlPath', '/v1/shipping/trackers-batch',
        'URL Pfad die Tracking API. Format: /path/path (Mit Slash am Anfang)'),
       ('cPaypalClientId', '',
        N'Produktiv Client ID für die PayPal API. Kann im PayPal Developer Portal unter "Apps & Credentials" gefunden werden.'),
       ('cPaypalSecret', '',
        N'Produktiv Secret für die PayPal API. Kann im PayPal Developer Portal unter "Apps & Credentials" gefunden werden.'),
       ('cPaypalClientIdSandbox', '',
        N'Sandbox Client ID für die PayPal API. Kann im PayPal Developer Portal unter "Apps & Credentials" gefunden werden.'),
       ('cPaypalSecretSandbox', '',
        N'Sandbox Secret für die PayPal API. Kann im PayPal Developer Portal unter "Apps & Credentials" gefunden werden.');

MERGE INTO Robotico.tPaypalSettings AS Target
USING @tDefaultSettings AS Source
ON Target.cKey = Source.cKey
WHEN NOT MATCHED BY TARGET THEN
    INSERT (cKey, cValue, cDokumentation)
    VALUES (Source.cKey, Source.cValue, Source.cDokumentation);
GO

-- Diese Prozedur wird verwendet um den Paypal Bearer Token (OAuth 2.0) zu holen. Wenn der Token abgelaufen ist, wird ein neuer angefordert.
CREATE OR ALTER PROC Robotico.spPaypalGetAccessToken @token NVARCHAR(MAX) OUTPUT
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


-- Diese Prozedur wird verwendet um den Paypal Bearer Token (OAuth 2.0) bei PayPal mittels API Call anzufordern. Hierfür werden die korrekten Credentials in der tPaypalSettings Tabelle benötigt. Holt sich die Crententials entweder für den Sandbox- oder Pruduktimodus. Je nachdem ob in der tPaypalSettings Tabelle der Sandboxmodus deaktiviert wurde..
CREATE OR ALTER PROC Robotico.spPaypalCreateAccessToken AS
BEGIN
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

            PRINT 'RESULTS FOR spPaypalCreateAccessToken'
            PRINT 'URL ' + @URL;
            PRINT 'URL ' + @URL;
            PRINT 'Status ' + @ResponseStatus + ' ' + @ResponseStatusText;
            PRINT '@Auth ' + @Auth;
            PRINT '@ResponseText ' + @ResponseText;
            PRINT 'END RESULTS FOR spPaypalCreateAccessToken'
        END

        INSERT INTO Robotico.tPaypalTrackingLog (cQuelle, bProduction, kInputKey, cBescheibung1, cBescheibung2, dErstellt)
        VALUES ('spPaypalCreateAccessToken', @DisableSandbox, NULL, 'Status ' + @ResponseStatus, @ResponseText, GETUTCDATE())
        DELETE FROM [Robotico].[tPaypalTrackingLog] WHERE dErstellt < DATEADD(day, -30, GETDATE())

        DELETE FROM Robotico.tPaypalAccessToken WHERE bProduction = @IsProduction

        INSERT INTO Robotico.tPaypalAccessToken
        SELECT scope         as [cScope],
               access_token  as cAccessToken,
               token_type    as cTokenType,
               app_id        as cAppID,
               expires_in    as nExpiresIn,
               getutcdate()  as dAuthDate,
               @IsProduction as bProduction
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

-- Diese Prozedur gibt die Tracking IDs für den Lieferschein an Paypal weiter. Dies erfolgt mittels API Call. Sie holt sich den Access Token aus der mittels der Prozedur spPaypalGetAccessToken.
CREATE OR ALTER PROC Robotico.spPaypalTrackingCallApi @kLieferschein AS INT
AS
BEGIN
    -- Vorbereitungen: Auth, URL, DisableSandbox, etc.
    DECLARE @DisableSandbox AS BIT = (SELECT IIF(cValue = 'TRUE', 1, 0)
                                      FROM Robotico.tPaypalSettings
                                      WHERE cKey = 'bDisableSandbox');
    DECLARE @BaseUrl AS VARCHAR(MAX) = (SELECT cValue
                                        FROM Robotico.tPaypalSettings
                                        WHERE cKey =
                                              IIF(@DisableSandbox = 0, 'cPaypalBaseUrlSandbox', 'cPaypalBaseUrl'));
    DECLARE @URL NVARCHAR(MAX) = @BaseUrl +
                                 (SELECT cValue FROM Robotico.tPaypalSettings WHERE cKey = 'cPaypalTrackingUrlPath');

    DECLARE @token AS NVARCHAR(MAX);
    EXEC Robotico.spPaypalGetAccessToken @token OUTPUT
    DECLARE @Auth as NVARCHAR(MAX) = 'Bearer ' + @token;

    DECLARE @ResponseStatus AS VARCHAR(8000),
        @ResponseStatusText AS VARCHAR(8000),
        @ResponseText AS VARCHAR(8000)

    DECLARE @tRawDataForApi AS TABLE
                               (
                                   cBestellnr           VARCHAR(255),
                                   cSendungsnummer      VARCHAR(255),
                                   cVersandartName      VARCHAR(255),
                                   cPaypalCarrier       VARCHAR(255),
                                   cPaypalTransactionId VARCHAR(255)
                               )
    DECLARE @request AS VARCHAR(MAX)

    -- Get data for the API request Versand for the given kVersand. Limit is 20 entries.
    BEGIN
        INSERT INTO @tRawDataForApi
        SELECT tB.cBestellNr             as cBestellnr,
               tV.cIdentCode             as cSendungsnummer,
               tVA.cName                 as cVersandartName,
               CASE
                   WHEN tVA.cName LIKE '%dhl%' OR tVA.cName LIKE '%warenpost%' THEN 'DHL_DEUTSCHE_POST'
                   WHEN tVA.cName LIKE '%post%' THEN 'DEUTSCHE_DE'
                   WHEN tVA.cName LIKE '%dpd%' THEN 'DPD'
                   END                   as cPaypalCarrier,
               tZ.cExternalTransactionId as cPaypalTransactionId
        FROM tLieferschein tL
                 INNER JOIN tVersand tV ON tL.kLieferschein = tV.kLieferschein
                 INNER JOIN tversandart tVA ON tVA.kVersandArt = tV.kVersandArt
                 INNER JOIN tBestellung tB on tB.kBestellung = tL.kBestellung
                 INNER JOIN tZahlung tZ on tZ.kBestellung = tB.kBestellung
        WHERE tL.kLieferschein = @kLieferschein
          AND tZ.cName LIKE '%paypal%'

        DELETE
        FROM @tRawDataForApi
        WHERE cBestellnr IS NULL
           OR cSendungsnummer IS NULL
           OR cPaypalCarrier IS NULL
           OR cPaypalTransactionId IS NULL

        IF (SELECT COUNT(*) FROM @tRawDataForApi) = 0
            BEGIN
                PRINT 'No data found for kLieferschein ' + CAST(@kLieferschein AS VARCHAR(255))
                RETURN
            END

        SET @request =
                (SELECT TOP (20) cPaypalTransactionID as transaction_id,
                                 cSendungsnummer      as tracking_number,
                                 'SHIPPED'            as status,
                                 cPaypalCarrier       as carrier
                 FROM @tRawDataForApi tData
                 FOR JSON PATH, ROOT ('trackers'))
    END

    -- Make the API call
    BEGIN
        DECLARE @HttpObject AS INT;
        EXEC sp_OACreate 'MSXML2.XMLHTTP', @HttpObject OUT;

        EXEC sp_OAMethod @HttpObject, 'open', NULL, 'post', @URL, 'false'
        EXEC sp_OAMethod @HttpObject, 'setRequestHeader', null, 'Content-Type', 'application/json'
        EXEC sp_OAMethod @HttpObject, 'setRequestHeader', null, 'Accept', 'application/json'
        EXEC sp_OAMethod @HttpObject, 'setRequestHeader', null, 'Authorization', @Auth
        EXEC sp_OAMethod @HttpObject, 'send', null, @request

        EXEC sp_OAMethod @HttpObject, 'status', @ResponseStatus OUTPUT
        EXEC sp_OAMethod @HttpObject, 'statusText', @ResponseStatusText OUTPUT
        EXEC sp_OAMethod @HttpObject, 'responseText', @ResponseText OUTPUT
        EXEC sp_OADestroy @HttpObject
    END

    BEGIN TRAN
        INSERT INTO Robotico.tPaypalTrackingLog (cQuelle, bProduction, kInputKey, cBescheibung1, cBescheibung2, dErstellt)
        VALUES ('spPaypalTrackingCallApi', @DisableSandbox, @kLieferschein, 'Status ' + @ResponseStatus, @ResponseText, GETUTCDATE())
        DELETE FROM [Robotico].[tPaypalTrackingLog] WHERE dErstellt < DATEADD(day, -30, GETDATE())
    COMMIT TRAN

    PRINT 'RESULTS FOR spPaypalTrackingCallApi'
    PRINT 'URL ' + @URL;
    PRINT '@request ' + @request;
    PRINT 'Status ' + @ResponseStatus + ' ' + @ResponseStatusText;
    PRINT '@ResponseText ' + @ResponseText;
    PRINT 'END RESULTS FOR spPaypalTrackingCallApi'

END
GO

--EXEC Robotico.spPaypalTrackingCallApi 80040 --D-AU202377628 7TX41916H14500426 00340434656094201764
--GO

-- SELECT dTokenCreated,
--        nExpiresInSeconds,
--        (DATEDIFF(SECOND, dTokenCreated, GETUTCDATE())),
--        IIF(nExpiresInSeconds - DATEDIFF(SECOND, dTokenCreated, GETUTCDATE()) < 120, 'TRUE', 'FALSE')
-- FROM Robotico.tPaypalAccessToken
-- GO