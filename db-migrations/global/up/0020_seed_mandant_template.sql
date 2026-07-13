-- 0020_seed_mandant_template.sql  (Ebene B / global chain — runs in RoboticoOps)
--
-- Seeds ops.tConfig (replacing the hard-coded paths from Projekte/Testsystem/
-- copy_test_db.sql) and a TEMPLATE set of ops.tMandant rows (tm2/tm3/tm4).
--
-- Secrets never live in git:
--   * cShopLicense is seeded with the sentinel '<SET-VIA-RUNBOOK>'. The rollout
--     runbook (docs/runbooks/rollout-mssql-ops.md) fills the real per-mandant shop
--     license keys via UPDATE, straight into ops.tMandant — never into a committed
--     file. A reset run against an unfilled mandant repoints the shop to that
--     sentinel, which is harmless (it is not a working license).
--   * cShopUrl / cLoginName / cDeveloper are operational template values; the runbook
--     confirms/corrects them before the first real reset.
--
-- NOTE (deviation from the plan's literal "{{cShopLicense}}" placeholder): a
-- '{{...}}' string would collide with grate's own token syntax and be substituted
-- (or error) at deploy. A plain sentinel value avoids that and reads unambiguously.
--
-- Idempotent: guarded by key so a re-run against a fresh instance is harmless; it
-- never overwrites values a runbook step has already corrected.
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§2)

SET NOCOUNT ON;

-- --- ops.tConfig ------------------------------------------------------------------
MERGE ops.tConfig AS tgt
USING (VALUES
    (N'BackupFile',        N'E:\work\eazybusiness_to_test.bak', N'COPY_ONLY backup staging path (single path -> resets serialize)'),
    (N'TargetDataDir',     N'E:\MSSQL\Data',                    N'Data dir for clone .mdf/.ldf (E: — never the small C: that holds PROD)'),
    (N'SourceDb',          N'eazybusiness',                     N'Clone source database'),
    (N'ReferenceMandant',  N'1',                                N'kMandant used as tBenutzerFirma seed template in register-mandant'),
    (N'StaleRunningHours', N'4',                                N'Age (hours) after which reset.spProcessNextResetRequest reclaims a still-running request as failed (CQG-7)'),
    (N'AgentJobName',      N'RoboticoOps - Testmandant Reset',  N'SQL Agent job name; single-sourced for Start/spEnsureAgentJob/200_ensure_agent_job (CQG-8)'),
    (N'NotifyOperator',    N'',                                 N'Optional SQL-Agent operator emailed on reset-job failure (OPS-4). Empty = silent/pull-only. Requires Database Mail + an existing operator; wired by reset.spEnsureAgentJob.')
) AS src (cKey, cValue, cNotes)
    ON tgt.cKey = src.cKey
WHEN NOT MATCHED BY TARGET THEN
    INSERT (cKey, cValue, cNotes) VALUES (src.cKey, src.cValue, src.cNotes);

-- --- ops.tMandant (template rows) -------------------------------------------------
-- cLoginName is seeded with the REAL shared developer login
-- 'dbuser_dev_dana_for_development' — the legacy setup-test-environment.ps1 default
-- (and the login used by grant-database-access.sql). Seeding the actually-existing
-- login instead of a per-mandant placeholder makes the DEFAULT reset deliver the
-- legacy result out-of-the-box: the developer is db_owner on the fresh clone (PAR-1).
-- Without this, spInternal_GrantAccess would skip a non-existent 'dbuser_dev_tmN' login
-- (D4) and the reset would report 'succeeded' with nobody able to open the mandant.
-- A per-mandant login can still be set later via the runbook.
--
-- Login name VERIFIED 2026-07-13 via a read-only catalog query against PROD (VM-SQL2):
--   SELECT name FROM sys.server_principals WHERE name LIKE 'dbuser_dev%'
-- returned dbuser_dev_dana_for_development, dbuser_dev_dana_for_jtl and
-- dbuser_dev_lukas_claude. This seed uses the first — confirmed correct and matching the
-- legacy setup-test-environment.ps1 default. Caveat: the login exists on PROD out of the
-- box but is NOT present on a bare vm-sql-test1 instance, so a reset THERE must override
-- @LoginName (or the login be created first) for spInternal_GrantAccess to grant db_owner;
-- otherwise the grant is skipped (D4) and the clone opens for nobody.
MERGE ops.tMandant AS tgt
USING (VALUES
    (N'tm2', N'eazybusiness_tm2', N'Testmandant 2', N'(confirm in runbook)', N'dbuser_dev_dana_for_development', N'https://tm2.staging.local', N'<SET-VIA-RUNBOOK>'),
    (N'tm3', N'eazybusiness_tm3', N'Testmandant 3', N'(confirm in runbook)', N'dbuser_dev_dana_for_development', N'https://tm3.staging.local', N'<SET-VIA-RUNBOOK>'),
    (N'tm4', N'eazybusiness_tm4', N'Testmandant 4', N'(confirm in runbook)', N'dbuser_dev_dana_for_development', N'https://tm4.staging.local', N'<SET-VIA-RUNBOOK>')
) AS src (cMandantKey, cTargetDb, cDisplayName, cDeveloper, cLoginName, cShopUrl, cShopLicense)
    ON tgt.cMandantKey = src.cMandantKey
WHEN NOT MATCHED BY TARGET THEN
    INSERT (cMandantKey, cTargetDb, cDisplayName, cDeveloper, cLoginName, cShopUrl, cShopLicense, bActive)
    VALUES (src.cMandantKey, src.cTargetDb, src.cDisplayName, src.cDeveloper, src.cLoginName, src.cShopUrl, src.cShopLicense, 1);
GO
