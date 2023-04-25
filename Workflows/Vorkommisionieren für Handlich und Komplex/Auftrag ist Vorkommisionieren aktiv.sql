DECLARE @kBestellung AS INT = 78538;
--D-AU202373377

SELECT IIF(nVorkommissionieren = 1, 'TRUE', 'FALSE') FROM tBestellungWMSFreigabe tBWF WHERE tBWF.kBestellung = @kBestellung AND nAktiv = 1