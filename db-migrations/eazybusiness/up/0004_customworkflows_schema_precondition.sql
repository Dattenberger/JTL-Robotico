-- ============================================================================
-- 0004 — CustomWorkflows schema precondition (Ebene A, one-time)
-- ============================================================================
-- Fail-fast guard: the Ebene-A chain deploys our CustomWorkflows.sp* action
-- procedures (CustomWorkflows.spGebindeErstellen, spAuftragPreiseAufNull, ...) via
-- the anytime sprocs pass. If the CustomWorkflows schema does not exist on the
-- target, every one of those CREATE OR ALTER statements fails with a bare
--   Msg 2760: The specified schema name "CustomWorkflows" ... does not exist
-- deep inside the anytime pass — an opaque error that gives the operator no hint
-- about the real, missing prerequisite.
--
-- WHY we do NOT silently CREATE the schema here: CustomWorkflows is NOT ours to
-- create. It is provided by the JTL "Custom Workflow Actions" module (bookable
-- since Wawi 1.6) together with its helper procs/views/tables, and it is a shared
-- zone co-inhabited with the excel_ekl runner (README §5/§6, D10). Auto-creating a
-- JTL-module schema would fake a prerequisite that is really "book + restart + license
-- refresh the module", and could mask a mis-targeted deploy. So we assert the
-- prerequisite and fail with a clear, actionable message instead.
--
-- Effect on already-adopted databases: this is a one-time journaled script. On prod
-- and on every existing mandant clone the module is booked, so the schema exists and
-- this script is a silent no-op that simply journals — it can never break a standing,
-- already-adopted deployment. It only bites on a target that genuinely lacks the
-- module, which is exactly where the current bare 2760 needs replacing (F4.1).
--
-- @see docs/SQL/JTL-CUSTOM-WORKFLOWS.md (booking the Custom Workflow Actions module)
-- @see db-migrations/README.md (§5 excel_ekl boundary, §6 module prerequisite)
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§1, F4.1 — fail-fast precondition)
-- ============================================================================

IF SCHEMA_ID(N'CustomWorkflows') IS NULL
    THROW 50002, 'Precondition failed: schema [CustomWorkflows] is missing. It is provided by the JTL "Custom Workflow Actions" module (not by this chain) — book the module, restart Wawi and refresh the license, then re-deploy. See docs/SQL/JTL-CUSTOM-WORKFLOWS.md.', 1;
ELSE
    PRINT '= Precondition OK: schema [CustomWorkflows] exists.';
GO
