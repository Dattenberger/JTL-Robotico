DECLARE @kVersand AS INT = 79668,
    @ResponseStatus AS VARCHAR(8000),
    @ResponseStatusText AS VARCHAR(8000),
    @ResponseText AS VARCHAR(8000)

BEGIN
    DECLARE @URL NVARCHAR(MAX) = (SELECT cValue FROM Robotico.tPaypalSettings WHERE cKey = 'cPaypalBaseUrl') +
                                 (SELECT cValue
                                  FROM Robotico.tPaypalSettings
                                  WHERE cKey = 'cPaypalTrackingUrlPath');
    DECLARE @token AS NVARCHAR(MAX);
    EXEC Robotico.spPaypalGetAccessToken @token OUTPUT
    DECLARE @Auth as NVARCHAR(MAX) = 'Bearer ' + @token;

    DECLARE @HttpObject AS INT;
    -- object declaration;

    -- Get data for the API request Versand for the given kVersand. Limit is 20 entries.
    DECLARE @request AS VARCHAR(MAX) =
        (SELECT TOP (20) cPaypalTransactionID as transaction_id,
                         cSendungsnummer      as tracking_number,
                         'SHIPPED'            as status,
                         cPaypalCarrier       as carrier,
                         'FORWARD'            as shipment_direction
         FROM (SELECT tB.cBestellNr             as cBestellnr,
                      tV.cIdentCode             as cSendungsnummer,
                      tVA.cName                 as cVersandartName,
                      CASE
                          WHEN tVA.cName LIKE '%dhl%' OR tVA.cName LIKE '%warenpost%' THEN 'DHL_DEUTSCHE_POST'
                          WHEN tVA.cName LIKE '%post%' THEN 'DEUTSCHE_DE'
                          WHEN tVA.cName LIKE '%dpd%' THEN 'DPD'
                          END                   as cPaypalCarrier,
                      tZ.cExternalTransactionId as cPaypalTransactionId
               FROM tVersand tV
                        INNER JOIN tLieferschein tL ON tL.kLieferschein = tV.kLieferschein
                        INNER JOIN tversandart tVA ON tVA.kVersandArt = tV.kVersandArt
                        INNER JOIN tBestellung tB on tB.kBestellung = tL.kBestellung
                        INNER JOIN tZahlung tZ on tZ.kBestellung = tB.kBestellung
               WHERE tV.kVersand = @kVersand
                 AND tZ.cName LIKE '%paypal%') tData
         WHERE cBestellnr IS NOT NULL
           AND cSendungsnummer IS NOT NULL
           AND cPaypalCarrier IS NOT NULL
           AND cPaypalTransactionId IS NOT NULL
         FOR JSON PATH, ROOT ('trackers'))

    EXEC sp_OACreate 'MSXML2.XMLHTTP', @HttpObject OUT;

    EXEC sp_OAMethod @HttpObject, 'open', NULL, 'post', @URL, 'false'
    EXEC sp_OAMethod @HttpObject, 'setRequestHeader', null, 'Content-Type', 'application/json'
    EXEC sp_OAMethod @HttpObject, 'setRequestHeader', null, 'Accept', 'application/json'
    EXEC sp_OAMethod @HttpObject, 'setRequestHeader', null, 'Authorization', @Auth

    EXEC sp_OAMethod @HttpObject, 'send', null, @request

    EXEC sp_OAMethod @HttpObject, 'status', @ResponseStatus OUTPUT
    EXEC sp_OAMethod @HttpObject, 'statusText', @ResponseStatusText OUTPUT
    EXEC sp_OAMethod @HttpObject, 'responseText', @ResponseText OUTPUT

    PRINT 'URL ' + @URL;
    PRINT '@request ' + @request;
    PRINT 'Status ' + @ResponseStatus + ' ' + @ResponseStatusText;
    PRINT '@ResponseText ' + @ResponseText;

    EXEC sp_OADestroy @HttpObject
END