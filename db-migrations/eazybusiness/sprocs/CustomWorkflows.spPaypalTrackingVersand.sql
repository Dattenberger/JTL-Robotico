-- ============================================================================
-- CustomWorkflows.spPaypalTrackingVersand — JTL action: notify PayPal (Versand)
-- ============================================================================
-- Custom workflow action. Input: kVersand (tVersand). Resolves the delivery note
-- and forwards the tracking number to PayPal via Robotico.spPaypalTrackingCallApi.
--
-- Ported from WorkflowProcedures/PayPal/Workflowaktion.sql (2026-07-10):
--   GO; -> GO; IF EXISTS DROP + CREATE -> CREATE OR ALTER; double-quoted display
--   name -> single-quoted; registration guarded (module-provided helper).
-- ============================================================================

CREATE OR ALTER PROCEDURE CustomWorkflows.spPaypalTrackingVersand @kVersand INT AS
BEGIN
    BEGIN
        DECLARE @kLieferschein INT;
        SELECT @kLieferschein = kLieferschein FROM tVersand WHERE kVersand = @kVersand
        EXECUTE Robotico.spPaypalTrackingCallApi @kLieferschein
    END
END
GO

-- Registration (validation + label). Helpers are provided by the JTL Custom
-- Workflow Actions module (see db-migrations/README.md §6); guarded so a machine
-- without the module gets a warning instead of a hard failure.
IF OBJECT_ID('CustomWorkflows._CheckAction', 'P') IS NOT NULL
    EXEC CustomWorkflows._CheckAction @actionName = 'spPaypalTrackingVersand';
ELSE
    PRINT '! CustomWorkflows._CheckAction missing — Custom Workflow Actions module not booked; skipping validation.';
GO

IF OBJECT_ID('CustomWorkflows._SetActionDisplayName', 'P') IS NOT NULL
    EXEC CustomWorkflows._SetActionDisplayName @actionName = 'spPaypalTrackingVersand',
        @displayName = 'PayPal Trackingnummer miteilen (Versand)';
ELSE
    PRINT '! CustomWorkflows._SetActionDisplayName missing — module not booked; skipping label registration.';
GO
