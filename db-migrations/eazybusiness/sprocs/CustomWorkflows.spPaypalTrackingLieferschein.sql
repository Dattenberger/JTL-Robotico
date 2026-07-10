-- ============================================================================
-- CustomWorkflows.spPaypalTrackingLieferschein — JTL action: notify PayPal (LS)
-- ============================================================================
-- Custom workflow action. Input: kLieferschein (tLieferschein). Forwards the
-- tracking number to PayPal via Robotico.spPaypalTrackingCallApi.
--
-- Ported from WorkflowProcedures/PayPal/Workflowaktion.sql (2026-07-10).
-- ============================================================================

CREATE OR ALTER PROCEDURE CustomWorkflows.spPaypalTrackingLieferschein @kLieferschein INT AS
BEGIN
    SET NOCOUNT ON;

    BEGIN
        EXECUTE Robotico.spPaypalTrackingCallApi @kLieferschein
    END
END
GO

-- Registration (see db-migrations/README.md §6). Guarded module-provided helpers.
IF OBJECT_ID('CustomWorkflows._CheckAction', 'P') IS NOT NULL
    EXEC CustomWorkflows._CheckAction @actionName = 'spPaypalTrackingLieferschein';
ELSE
    PRINT '! CustomWorkflows._CheckAction missing — Custom Workflow Actions module not booked; skipping validation.';
GO

IF OBJECT_ID('CustomWorkflows._SetActionDisplayName', 'P') IS NOT NULL
    EXEC CustomWorkflows._SetActionDisplayName @actionName = 'spPaypalTrackingLieferschein',
        @displayName = 'PayPal Trackingnummer miteilen (Lieferschein)';
ELSE
    PRINT '! CustomWorkflows._SetActionDisplayName missing — module not booked; skipping label registration.';
GO
