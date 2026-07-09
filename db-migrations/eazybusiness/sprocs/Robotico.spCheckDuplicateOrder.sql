-- ============================================================================
-- Robotico.spCheckDuplicateOrder — outer layer for workflow/tests
-- ============================================================================
-- Returns the duplicate truth value three ways: a single-row result set
-- (bIsDuplicate), an OUTPUT parameter, and the RETURN code. Thin wrapper over
-- Robotico.fnHasOlderDuplicateOrder.
--
-- Ported from WorkflowProcedures/Duplikaterkennung_Bestellungen.sql (2026-07-10).
-- ============================================================================

CREATE OR ALTER PROCEDURE Robotico.spCheckDuplicateOrder
    @kAuftrag     INT,
    @nWindowHours INT = 24,
    @bIsDuplicate BIT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @bIsDuplicate = Robotico.fnHasOlderDuplicateOrder(@kAuftrag, @nWindowHours);

    SELECT @bIsDuplicate AS bIsDuplicate;

    RETURN @bIsDuplicate;
END
GO
