-- ============================================================================
-- CustomWorkflows.spAuftragPreiseAufNull — JTL action: zero an order's prices
-- ============================================================================
-- Custom workflow action. Sets net purchase and net sales price to 0 on all order
-- positions that are not yet invoiced (used e.g. for internal orders), then recomputes
-- the order totals via Verkauf.spAuftragEckdatenBerechnen.
--
-- Ported from WorkflowProcedures/Workflowaktion Auftrag Preise auf Null.Sql (2026-07-15):
--   IF EXISTS DROP + CREATE -> CREATE OR ALTER; `GO;` -> `GO`; SET NOCOUNT ON added;
--   registration guarded (module-provided helpers). Deviation: the source's
--   `_CheckAction @actionName = 'auftragPreiseNull'` did not match the procedure name
--   (its `_SetActionDisplayName` already used 'spAuftragPreiseAufNull') — a legacy
--   copy-paste slip; the validation call is aligned to the procedure name here.
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§1, D10 — CustomWorkflows is
--      an additive shared zone co-inhabited by excel_ekl; only touch our own objects)
-- ============================================================================

CREATE OR ALTER PROCEDURE CustomWorkflows.spAuftragPreiseAufNull @kAuftrag INT AS
BEGIN

    SET NOCOUNT ON;

    BEGIN
        Update AP
        SET fEkNetto = 0,
            fVkNetto= 0
        From Verkauf.tAuftragPosition AP
                 LEFT JOIN Rechnung.tRechnungPosition RP ON AP  .kAuftragPosition = RP.kAuftragPosition
        WHERE AP.kAuftrag = @kAuftrag
          AND RP.kRechnungPosition IS NULL
    END

    BEGIN
        declare @auftrag Verkauf.TYPE_spAuftragEckdatenBerechnen
        insert into @auftrag values (@kAuftrag)
        exec Verkauf.spAuftragEckdatenBerechnen @auftrag
    END
END
GO

-- Registration (see db-migrations/README.md §6). Guarded module-provided helpers.
IF OBJECT_ID('CustomWorkflows._CheckAction', 'P') IS NOT NULL
    EXEC CustomWorkflows._CheckAction @actionName = 'spAuftragPreiseAufNull';
ELSE
    PRINT '! CustomWorkflows._CheckAction missing — Custom Workflow Actions module not booked; skipping validation.';
GO

IF OBJECT_ID('CustomWorkflows._SetActionDisplayName', 'P') IS NOT NULL
    EXEC CustomWorkflows._SetActionDisplayName @actionName = 'spAuftragPreiseAufNull',
        @displayName = 'Auftrag Preise auf Null setzen';
ELSE
    PRINT '! CustomWorkflows._SetActionDisplayName missing — module not booked; skipping label registration.';
GO
