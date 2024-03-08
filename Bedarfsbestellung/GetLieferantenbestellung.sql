DECLARE @cEigeneBestellnummer nvarchar(50) = 'D-BE20241745';

DECLARE @tStatusMapping TABLE (nStatus int, cStatus nvarchar(50));

INSERT INTO @tStatusMapping (nStatus, cStatus)
VALUES (500, 'Abgeschlossen'),
       (20, 'In Bearbeitung'),
       (0, 'Offen'),
       (30, 'Teilgeliefert'),
       (4, 'Abgeschlossen');

SELECT kLieferantenBestellung,
       cEigeneBestellnummer,
       tLB.nStatus,
       tSM.cStatus,
       nManuellAbgeschlossen,
       tLB.dErstellt, dLieferdatum, dInBearbeitung, dExportiert, tL.cFirma as cLieferant FROM dbo.tLieferantenBestellung tLB
         LEFT JOIN dbo.tLieferant tL ON tL.kLieferant = tLB.kLieferant
         LEFT JOIN @tStatusMapping tSM ON tSM.nStatus = tLB.nStatus
         WHERE cEigeneBestellnummer = @cEigeneBestellnummer
            ORDER BY tLB.dErstellt DESC;