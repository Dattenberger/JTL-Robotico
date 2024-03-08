--This Parameter is the input. The query will return ony newer rows than the row with this id.
--This line needs to be removed in the project:
DECLARE @lastDeliveryNodeID INT = 138357;

--This is the id of the relevant manufacturer since only Husqvarna products need to be registered:
--Hersteller -> manufacturer
--ID 3 -> Husqvarna
DECLARE @producerID INT = 3;

--Get the delivery node data, serial number and customer address
SELECT tL.kLieferschein as deliveryNodeID,
       tL.cLieferscheinNr as deliveryNoteNumber,
       tLA.cSeriennr as serialNumber,
       tL.dErstellt as deliveryNodeDate,
       tB.cBestellNr as oderNumber,
       tBP.cString as article,
       tA.cHAN as arcticlePNC,
       tAddr.cFirma as company,
       tAddr.cStrasse as street,
       tAddr.cAdressZusatz as adressExtra,
       tAddr.cOrt as city,
       tAddr.cPLZ as zip,
       tAddr.cISO as countryISO,
       tAddr.cMail as mail,
       tAddr.cTel as phone,
       tAddr.cVorname as firstName,
       tAddr.cName as lastName
FROM (SELECT * FROM dbo.tLieferschein WHERE kLieferschein > @lastDeliveryNodeID) tL
         INNER JOIN dbo.tLieferscheinPos tLP ON tL.kLieferschein = tLP.kLieferschein
         INNER JOIN dbo.tBestellpos tBP ON tLP.kBestellPos = tBP.kBestellPos
         INNER JOIN (SELECT * FROM dbo.tArtikel tA WHERE tA.kHersteller = @producerID) tA
                    ON tBP.tArtikel_kArtikel = tA.kArtikel
         INNER JOIN dbo.tLagerArtikel tLA ON tLP.kLieferscheinPos = tLA.kLieferscheinPos
         LEFT JOIN dbo.tBestellung tB ON tL.kBestellung = tB.kBestellung
         LEFT JOIN (SELECT * FROM Verkauf.tAuftragAdresse tAddr WHERE tAddr.nTyp = 1) tAddr
                   ON tB.kRechnungsadresse = tAddr.kAuftrag
ORDER BY tL.dErstellt DESC
