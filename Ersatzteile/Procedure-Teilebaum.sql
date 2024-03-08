use ersatzteile

BEGIN TRANSACTION


--Modell
DROP PROCEDURE IF EXISTS spTempAddModell;
GO;

CREATE PROCEDURE spTempAddModell @cBezeichnung NVARCHAR(510) = NULL, @kGeraeteTyp INT, @kHersteller INT, @cBeschreibung NVARCHAR(MAX) = null, @kVorgang INT, @kModell INT OUTPUT
AS

    DECLARE @tKey TABLE (kKey INT NOT NULL);

    INSERT INTO tModellTemp (kGeraeteTyp, kHersteller, cBezeichnung, cBeschreibung, kVorgang)
    OUTPUT INSERTED.kVorgang INTO @tKey
    VALUES (@kGeraeteTyp, @kHersteller, @cBezeichnung, @cBeschreibung, @kVorgang);

    SET @kModell = (SELECT kKey FROM @tKey);

    RETURN;
GO;

--Modell
DROP PROCEDURE IF EXISTS spTempAddModell;
GO;

CREATE PROCEDURE spTempAddModell @cBezeichnung NVARCHAR(510) = NULL, @kGeraeteTyp INT, @kHersteller INT, @cBeschreibung NVARCHAR(MAX) = null, @kVorgang INT, @kModell INT OUTPUT
AS

    DECLARE @tKey TABLE (kKey INT NOT NULL);

    INSERT INTO tModellTemp (kGeraeteTyp, kHersteller, cBezeichnung, cBeschreibung, kVorgang)
    OUTPUT INSERTED.kVorgang INTO @tKey
    VALUES (@kGeraeteTyp, @kHersteller, @cBezeichnung, @cBeschreibung, @kVorgang);

    SET @kModell = (SELECT kKey FROM @tKey);

    RETURN;
GO;

DECLARE @kNeuerVorgangX INT = 0;
EXEC spTempNeuerVorgang "TEST", 'Testbeschreibung', @kNeuerVorgang = @kNeuerVorgangX OUTPUT;
PRINT @kNeuerVorgangX

COMMIT TRANSACTION