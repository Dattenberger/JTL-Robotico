-- ============================================================================
-- compare-objects.sql — file <-> deployed-object comparison (read-only)
-- ============================================================================
-- Lists this business's own objects (schema Robotico + our CustomWorkflows.sp*
-- actions) with a hash of their definition, so a deployed database can be
-- compared against what db-migrations/eazybusiness/ would produce. Two uses:
--   1. Baseline pre-check — before `deploy.ps1 -Baseline`, confirm the file
--      contents match the currently deployed objects (baseline assumes equality).
--   2. Post-update smoke — after a JTL update, spot which of our objects a JTL
--      update may have dropped/overwritten.
--
-- STRICTLY READ-ONLY. Run per eazybusiness database:
--   /opt/mssql-tools*/bin/sqlcmd -S vm-sql-test1.zdbikes.local -E -C \
--       -d eazybusiness -i db-migrations/tests/compare-objects.sql
--
-- Ownership boundary (D10): excludes excel_ekl objects (spCMArtikel/spCMArtikelNeu)
-- and the JTL-module-provided CustomWorkflows infrastructure (underscore helpers,
-- vCustomAction* views, tWorkflowObjects/tAllowedDatatypes) — those are not ours.
-- ============================================================================

SET NOCOUNT ON;

;WITH OwnedObjects AS
(
    SELECT
        s.name  AS SchemaName,
        o.name  AS ObjectName,
        o.type_desc AS ObjectType,
        o.object_id
    FROM sys.objects o
    JOIN sys.schemas s ON s.schema_id = o.schema_id
    WHERE o.is_ms_shipped = 0
      AND o.type IN ('P', 'FN', 'IF', 'TF', 'V', 'U')   -- proc, scalar/inline/table fn, view, table
      AND (
            s.name = 'Robotico'
            OR (
                s.name = 'CustomWorkflows'
                AND o.type = 'P'                         -- only our action procs
                AND o.name NOT LIKE '\_%' ESCAPE '\'     -- exclude module helpers (_CheckAction, …)
                AND o.name NOT IN ('spCMArtikel', 'spCMArtikelNeu')  -- excel_ekl (D10)
            )
      )
)
SELECT
    o.SchemaName,
    o.ObjectName,
    o.ObjectType,
    -- Programmable objects: hash of the module definition. Tables: NULL (compare
    -- structure separately) — listed so the inventory is complete.
    CASE
        WHEN o.ObjectType = 'USER_TABLE' THEN NULL
        ELSE CONVERT(VARCHAR(64), HASHBYTES('SHA2_256',
                 CONVERT(NVARCHAR(MAX), OBJECT_DEFINITION(o.object_id))), 2)
    END AS DefinitionHash
FROM OwnedObjects o
ORDER BY o.SchemaName, o.ObjectType, o.ObjectName;
