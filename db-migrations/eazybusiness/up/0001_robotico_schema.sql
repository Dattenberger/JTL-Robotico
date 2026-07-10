-- ============================================================================
-- 0001 — Robotico schema (Ebene A, one-time)
-- ============================================================================
-- Creates the Robotico schema that owns all of this business's own objects in
-- an eazybusiness database. Guarded and idempotent so a re-run (or a run against
-- a mandant clone that already has it) is harmless.
--
-- The grate journal (schema Robotico, tables ScriptsRun/Version) also lives in
-- this schema — grate creates the journal itself; this script only guarantees
-- the schema exists before any Robotico.* object is deployed.
--
-- Ported from: the defensive `IF NOT EXISTS … CREATE SCHEMA Robotico` block
-- present in WorkflowProcedures/api/CustomFieldAPI.sql,
-- WorkflowProcedures/api/StringAndCSVUtilities.sql and
-- WorkflowProcedures/PayPal/Add Procudures and Tables.sql (2026-07-10).
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§1, D2, D3 — the Robotico
--      schema is the Ebene-A journal home; the two-chain split versions its contents)
-- ============================================================================

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'Robotico')
BEGIN
    -- This schema holds every table / function / procedure that is ours (Robotico),
    -- not JTL's. Objects here survive JTL updates (unlike dbo.*).
    EXEC (N'CREATE SCHEMA Robotico');
    PRINT '+ Schema Robotico created';
END
ELSE
    PRINT '= Schema Robotico already exists';
GO
