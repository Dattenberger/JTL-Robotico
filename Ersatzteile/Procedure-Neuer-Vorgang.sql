use ersatzteile

BEGIN TRANSACTION
DROP PROCEDURE IF EXISTS spTempNeuerVorgang;
GO;

CREATE PROCEDURE spTempNeuerVorgang @cBezeichnung NVARCHAR(510) = NULL, @cBeschreibung NVARCHAR(MAX) = null, @bUseDate BIT = 1, @kNeuerVorgang INT OUTPUT
AS
    IF(@cBezeichnung IS NULL)
        SET @cBezeichnung = (SELECT CONCAT('Keine Bezeichnung ', convert(varchar, getdate(), 29)));
    ELSE
        SET @cBezeichnung = (SELECT CONCAT(@cBezeichnung, IIF(@bUseDate = 1, CONCAT(' ', convert(varchar, getdate(), 29)), '')));

    DECLARE @tNewVorgang TABLE (kNewVorgang INT NOT NULL);

    INSERT INTO tTempVorgang (cBezeichnung, cBeschreibung)
    OUTPUT INSERTED.kVorgang INTO @tNewVorgang
    VALUES (@cBezeichnung, @cBeschreibung);

    SET @kNeuerVorgang = (SELECT kNewVorgang FROM @tNewVorgang);

    RETURN;
GO;

DECLARE @kNeuerVorgangX INT = 0;
EXEC spTempNeuerVorgang "TEST", 'Testbeschreibung', @kNeuerVorgang = @kNeuerVorgangX OUTPUT;
PRINT @kNeuerVorgangX

COMMIT TRANSACTION