-- ============================================================================
-- Robotico.fnHasOlderDuplicateOrder — truth value: older identical order exists?
-- ============================================================================
-- Returns BIT 1 iff an OLDER identical order exists for @kAuftrag (i.e. the order
-- is an accidental duplicate of an earlier one). The first order of a duplicate
-- group is therefore 0; every later one is 1.
--
-- Consumed by the DotLiquid workflow condition "Auftrag - Ist Duplikat" (returns
-- WAHR/FALSCH) — see docs/SQL/JTL-CUSTOM-WORKFLOWS.md.
--
-- Dependency: uses Robotico.fnFindDuplicateOrders (same folder; deployed first
-- alphabetically).
--
-- Ported from WorkflowProcedures/Duplikaterkennung_Bestellungen.sql (2026-07-10).
-- ============================================================================

CREATE OR ALTER FUNCTION Robotico.fnHasOlderDuplicateOrder
(
    @kAuftrag    INT,
    @nWindowHours INT = 24
)
RETURNS BIT
AS
BEGIN
    RETURN CASE
        WHEN EXISTS (
            SELECT 1
            FROM Robotico.fnFindDuplicateOrders(@kAuftrag, @nWindowHours)
            WHERE bIsOlderThanInput = 1
        ) THEN 1
        ELSE 0
    END;
END
GO
