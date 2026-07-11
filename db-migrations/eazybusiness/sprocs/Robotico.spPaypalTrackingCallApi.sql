-- ============================================================================
-- Robotico.spPaypalTrackingCallApi — push tracking numbers to PayPal
-- ============================================================================
-- Sends the tracking number(s) for a delivery note (@kLieferschein) to the PayPal
-- tracking API. Reads the shipment data from the JTL tables, gets a token via
-- Robotico.spPaypalGetAccessToken, POSTs the batch (max 20), and logs the call.
--
-- Runtime dependency: Robotico.spPaypalGetAccessToken. Requires OLE Automation
-- Procedures enabled on the server.
--
-- Ported from WorkflowProcedures/PayPal/Add Procudures and Tables.sql (2026-07-10).
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§1 — Ebene-A port; the
--      PayPal tracking API entry point behind the CustomWorkflows actions)
-- ============================================================================

CREATE OR ALTER PROCEDURE Robotico.spPaypalTrackingCallApi
    @kLieferschein INT,
    @debug         BIT = 0   -- 1 = PRINT diagnostics
AS
BEGIN
    SET NOCOUNT ON;

    -- Preparation: Auth, URL, DisableSandbox, etc.
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

    -- Get data for the API request for the given kLieferschein. Limit is 20 entries.
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

        -- Serviceability: a shipment whose Versandart matches no carrier pattern gets
        -- cPaypalCarrier = NULL and is dropped below — PayPal is then never told about
        -- it. Log those rows first (they have a tracking number but no carrier mapping)
        -- so a silently unreported shipment is auditable in tPaypalTrackingLog.
        INSERT INTO Robotico.tPaypalTrackingLog (cQuelle, bProduction, kInputKey, cBescheibung1, cBescheibung2, dErstellt)
        SELECT 'spPaypalTrackingCallApi/unmapped-carrier', @DisableSandbox, @kLieferschein,
               'Unmapped carrier — shipment dropped from PayPal batch',
               'Versandart: ' + ISNULL(cVersandartName, '(null)')
                   + ' | Sendungsnr: ' + ISNULL(cSendungsnummer, '(null)'),
               GETUTCDATE()
        FROM @tRawDataForApi
        WHERE cPaypalCarrier IS NULL
          AND cSendungsnummer IS NOT NULL;

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

    IF @debug = 1
    BEGIN
        PRINT 'RESULTS FOR spPaypalTrackingCallApi'
        PRINT 'URL ' + @URL;
        PRINT '@request ' + @request;
        PRINT 'Status ' + @ResponseStatus + ' ' + @ResponseStatusText;
        PRINT '@ResponseText ' + @ResponseText;
        PRINT 'END RESULTS FOR spPaypalTrackingCallApi'
    END

END
GO
