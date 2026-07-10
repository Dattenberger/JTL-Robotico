-- ============================================================================
-- 01_worker_ttarget_semantics.sql — Worker.tTarget survey (read-only) — Open Q O1
-- ============================================================================
-- Answers (as far as SQL can): "What does Worker.tTarget encode, and what do the
-- nAbgleichstyp values mean?" This drives decision D9 in the plan: the reset job
-- MUST NOT touch Worker.tTarget until the nAbgleichstyp semantics are confirmed.
-- Neutralisation therefore happens at the account/shop level (ebay_user.nGesperrt,
-- pf_user.nGesperrt/nAktiv, tShop.nGesperrt) instead — those are unambiguous.
--
-- STRICTLY READ-ONLY (SELECT / catalog only). Run against a JTL database:
--   /opt/mssql-tools18/bin/sqlcmd -S vm-sql-test1.zdbikes.local -E -C \
--       -d eazybusiness -i db-migrations/tests/probes/01_worker_ttarget_semantics.sql
--
-- To interpret a production mandant, run it with -d eazybusiness (prod) and against
-- each -d eazybusiness_tm* clone; compare which nAbgleichstyp rows exist per mandant.
--
-- Recorded result — vm-sql-test1.eazybusiness (2026-07-10, this repo's C3 run):
--   Worker.tTarget = 10 rows, all kMandant = 1.
--   nAbgleichstyp ∈ {0,2,3,4,5,7,8,13,17,18} (one row each).
--   kZiel = 1 for nAbgleichstyp 0, else -1 (wildcard "all targets of that type").
--   Matches the prod survey (10 rows, same value set) — see research/2-instanz-survey.
--
-- O1 verdict: there is NO database-side lookup table that names the sync types
--   (Sync.tSyncType exists but is EMPTY on test1). The value→meaning mapping is
--   JTL-internal (worker source / JTL support), not derivable from the schema.
--   => O1 stays "needs JTL-side confirmation"; D9 (leave tTarget untouched) holds.
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur/mssql-ops-infrastruktur.md §4 (Validierung & Probeliste, Open Question O1)
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur/mssql-ops-infrastruktur.md §D9 (Worker neutralisation leaves Worker.tTarget untouched)
-- ============================================================================

SET NOCOUNT ON;

PRINT '--- Context: server / database ---';
SELECT
    @@SERVERNAME                                        AS ServerName,
    DB_NAME()                                           AS DatabaseName,
    CONVERT(varchar(32), SERVERPROPERTY('ProductVersion')) AS ProductVersion;

-- (1) Column layout of Worker.tTarget — confirm the shape before reading rows.
PRINT '--- Worker.tTarget column layout ---';
SELECT
    c.column_id       AS Ordinal,
    c.name            AS ColumnName,
    t.name            AS DataType,
    c.is_nullable     AS IsNullable
FROM sys.columns c
JOIN sys.types   t ON t.user_type_id = c.user_type_id
WHERE c.object_id = OBJECT_ID('Worker.tTarget')
ORDER BY c.column_id;

-- (2) The rows themselves, joined to tMandant so each target is attributed to a
--     named mandant. kZiel = -1 is the JTL "wildcard / all targets" marker.
PRINT '--- Worker.tTarget rows (per mandant) ---';
SELECT
    wt.kMandant,
    m.cName            AS MandantName,
    wt.nAbgleichstyp,
    wt.kZiel,
    wt.uTargetId
FROM Worker.tTarget wt
LEFT JOIN dbo.tMandant m ON m.kMandant = wt.kMandant
ORDER BY wt.kMandant, wt.nAbgleichstyp;

-- (3) Distinct nAbgleichstyp values with a count — the compact fingerprint to
--     compare across databases / clones.
PRINT '--- Distinct nAbgleichstyp (fingerprint) ---';
SELECT
    wt.nAbgleichstyp,
    COUNT(*)           AS TargetCount
FROM Worker.tTarget wt
GROUP BY wt.nAbgleichstyp
ORDER BY wt.nAbgleichstyp;

-- (4) Does a DB-side lookup name the sync types? (On test1 this returns 0 rows —
--     Sync.tSyncType is empty, so the mapping is NOT available from the schema.)
PRINT '--- Sync.tSyncType (candidate lookup — expected EMPTY) ---';
IF OBJECT_ID('Sync.tSyncType') IS NOT NULL
    SELECT * FROM Sync.tSyncType ORDER BY kSyncType;
ELSE
    PRINT 'Sync.tSyncType does not exist in this database.';

-- ============================================================================
-- Interpreting nAbgleichstyp (JTL-side, NOT from this database)
-- ----------------------------------------------------------------------------
-- The worker reads Worker.tTarget to decide which sync types run for which
-- mandant (kMandant) against which concrete target (kZiel; -1 = all). The numeric
-- nAbgleichstyp is an internal JTL enum with no shipped lookup table. To resolve
-- a specific value:
--   a) JTL-Worker settings UI groups the sync jobs by name — correlate the set of
--      enabled jobs for a mandant with the nAbgleichstyp rows present here.
--      https://guide.jtl-software.com/jtl-wawi/jtl-worker/einstellungen-im-jtl-worker/
--   b) Observe Worker.tErrorlog / Worker.tStatus while the worker runs (probe 02)
--      to see which type fires when.
--   c) Ask JTL support for the nAbgleichstyp enum if an exact per-type mapping is
--      ever required.
-- Until then the reset stays account/shop-level (D9) — safe regardless of the enum.
-- ============================================================================
