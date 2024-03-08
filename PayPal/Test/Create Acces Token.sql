BEGIN
    DECLARE @DisableSandbox AS BIT = (SELECT IIF(cValue = 'TRUE', 1, 0)
                                      FROM Robotico.tPaypalSettings
                                      WHERE cKey = 'bDisableSandbox');
    DECLARE @BaseUrl AS VARCHAR(MAX) = (SELECT cValue
                                        FROM Robotico.tPaypalSettings
                                        WHERE cKey =
                                              IIF(@DisableSandbox = 0, 'cPaypalBaseUrlSandbox', 'cPaypalBaseUrl'));
    DECLARE @URL NVARCHAR(MAX) = @BaseUrl +
                                 (SELECT cValue
                                  FROM Robotico.tPaypalSettings
                                  WHERE cKey = 'cPaypalAuthUrlPath'); -- our URL for post request
    DECLARE @User AS NVARCHAR(MAX) = (SELECT cValue FROM Robotico.tPaypalSettings
                                                    WHERE cKey = IIF(@DisableSandbox = 0, 'cPaypalClientIdSandbox', 'cPaypalClientId'))
    DECLARE @Pass AS NVARCHAR(MAX) = (SELECT cValue FROM Robotico.tPaypalSettings
                                                    WHERE cKey = IIF(@DisableSandbox = 0, 'cPaypalSecretSandbox', 'cPaypalSecret'))

    DECLARE @HttpObject AS INT; -- object declaration
    DECLARE @ResponseStatus AS VARCHAR(8000), @ResponseStatusText AS VARCHAR(8000), @ResponseText AS VARCHAR(8000);
    DECLARE @credentials AS VARCHAR(8000) = @User + ':' + @Pass
    DECLARE @credentialsBinary AS VARCHAR(8000);
    SELECT @credentialsBinary = CAST(N'' AS XML).value(
            'xs:base64Binary(xs:hexBinary(sql:column("bin")))'
        , 'VARCHAR(MAX)'
        )
    FROM (SELECT CAST(@credentials AS VARBINARY(MAX)) AS bin) AS RetVal;

    DECLARE @Auth AS VARCHAR(8000) = 'Basic ' + @credentialsBinary

    EXEC sp_OACreate 'MSXML2.XMLHTTP', @HttpObject OUT;
    -- creating OLE object and assigning it to variable @Object

-- passing the @Object created above, with our http call and handling the response with help of sp_OAMethod
    EXEC sp_OAMethod @HttpObject, 'open', NULL, 'post', @URL, 'false'
    EXEC sp_OAMethod @HttpObject, 'setRequestHeader', null, 'Content-Type', 'application/x-www-form-urlencoded'
    EXEC sp_OAMethod @HttpObject, 'setRequestHeader', null, 'Accept', 'application/json'
    EXEC sp_OAMethod @HttpObject, 'setRequestHeader', null, 'Accept-Language', 'en_US'
    EXEC sp_OAMethod @HttpObject, 'setRequestHeader', null, 'Authorization', @Auth
    EXEC sp_OAMethod @HttpObject, 'send', null, 'grant_type=client_credentials'

    EXEC sp_OAMethod @HttpObject, 'status', @ResponseStatus OUTPUT
    EXEC sp_OAMethod @HttpObject, 'statusText', @ResponseStatusText OUTPUT
    EXEC sp_OAMethod @HttpObject, 'responseText', @ResponseText OUTPUT
-- print 'responseText -> ' + @ResponseText;
    PRINT 'URL ' + @URL;
    PRINT 'Status ' + @ResponseStatus + ' ' + @ResponseStatusText;
    PRINT '@Auth ' + @Auth;
    PRINT '@ResponseText ' + @ResponseText;

    EXEC sp_OADestroy @HttpObject

    TRUNCATE TABLE Robotico.tPaypalAccessToken

    INSERT INTO Robotico.tPaypalAccessToken
    SELECT scope        as [cScope],
           access_token as cAccessToken,
           token_type   as cTokenType,
           app_id       as cAppID,
           expires_in   as nExpiresIn,
           getutcdate() as dAuthDate
    FROM OPENJSON(@ResponseText)
                  WITH (
                      scope NVARCHAR(MAX) '$.scope',
                      access_token NVARCHAR(MAX) '$.access_token',
                      token_type NVARCHAR(MAX) '$.token_type',
                      app_id NVARCHAR(MAX) '$.app_id',
                      expires_in INTEGER '$.expires_in',
                      nonce NVARCHAR(MAX) '$.nonce'
                      )
END