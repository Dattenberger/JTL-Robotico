set xact_abort on

BEGIN TRANSACTION
--DELETE FROM tZahlungsabgleichLogeintrag WHERE dZeitpunkt  < DATEADD(day, -10, GETDATE())
TRUNCATE TABLE tZahlungsabgleichLogeintrag
COMMIT TRANSACTION