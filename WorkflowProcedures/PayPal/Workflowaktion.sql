
IF EXISTS(SELECT 1
          FROM sys.procedures
          WHERE Name = 'spPaypalTrackingVersand')
    DROP PROCEDURE CustomWorkflows.spPaypalTrackingVersand
GO;

-- Mit diesem Prozeduraufruf wird die Trackingnummer an PayPal übermittelt. Dies erfolgt über die PayPal API. Die Funktionen dafür finden sich um Robotico Schema mit dem Präfix "PaypalTracking".
-- Input ist der Schlüssel des Versandes (Tabelle tVersand). Die Trackingnummer sowie die relevanten Daten werden dann aus den entsprechenden Tabellen ausgelesen.
CREATE PROCEDURE CustomWorkflows.spPaypalTrackingVersand @kVersand INT AS
BEGIN
    BEGIN
        DECLARE @kLieferschein INT;
        SELECT @kLieferschein = kLieferschein FROM tVersand WHERE kVersand = @kVersand
        EXECUTE Robotico.spPaypalTrackingCallApi @kLieferschein
    END
END
GO;

EXEC CustomWorkflows._CheckAction @actionName = 'spPaypalTrackingVersand'
GO;

EXEC CustomWorkflows._SetActionDisplayName @actionName = 'spPaypalTrackingVersand',
     @displayName = "PayPal Trackingnummer miteilen (Versand)"
GO;


-- Mit diesem Prozeduraufruf wird die Trackingnummer an PayPal übermittelt. Dies erfolgt über die PayPal API. Die Funktionen dafür finden sich um Robotico Schema mit dem Präfix "PaypalTracking".
-- Input ist der Schlüssel des Lieferscheins (Tabelle tLieferschein). Die Trackingnummer sowie die relevanten Daten werden dann aus den entsprechenden Tabellen ausgelesen.
IF EXISTS(SELECT 1
          FROM sys.procedures
          WHERE Name = 'spPaypalTrackingLieferschein')
    DROP PROCEDURE CustomWorkflows.spPaypalTrackingLieferschein
GO;

CREATE PROCEDURE CustomWorkflows.spPaypalTrackingLieferschein @kLieferschein INT AS
BEGIN
    BEGIN
        EXECUTE Robotico.spPaypalTrackingCallApi @kLieferschein
    END
END
GO;

EXEC CustomWorkflows._CheckAction @actionName = 'spPaypalTrackingLieferschein'
GO;

EXEC CustomWorkflows._SetActionDisplayName @actionName = 'spPaypalTrackingLieferschein',
     @displayName = "PayPal Trackingnummer miteilen (Lieferschein)"
GO;