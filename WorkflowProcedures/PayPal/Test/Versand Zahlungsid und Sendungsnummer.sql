--DECLARE @kVersand AS INTEGER = 79668 --D-AU202377628 7TX41916H14500426 00340434656094201764
DECLARE @kLieferschein AS INTEGER = 80040 --D-AU202377628 7TX41916H14500426 00340434656094201764

DECLARE @tApiRawData AS TABLE
                        (
                            cBestellnr           VARCHAR(255),
                            cSendungsnummer      VARCHAR(255),
                            cVersandartName      VARCHAR(255),
                            cPaypalCarrier       VARCHAR(255),
                            cPaypalTransactionId VARCHAR(255)
                        )
DECLARE @request AS     VARCHAR(MAX)

DECLARE @tRawDataForApi AS TABLE
                           (
                               cBestellnr           VARCHAR(255),
                               cSendungsnummer      VARCHAR(255),
                               cVersandartName      VARCHAR(255),
                               cPaypalCarrier       VARCHAR(255),
                               cPaypalTransactionId VARCHAR(255)
                           )

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


PRINT @request