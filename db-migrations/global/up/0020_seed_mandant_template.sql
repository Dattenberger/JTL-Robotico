-- 0020_seed_mandant_template.sql  (Ebene B / global chain — runs in RoboticoOps)
--
-- Seeds ops.Config (replacing the hard-coded paths from Projekte/Testsystem/
-- copy_test_db.sql) and a TEMPLATE set of ops.Mandant rows (tm2/tm3/tm4).
--
-- Secrets never live in git:
--   * ShopLicense is seeded with the sentinel '<SET-VIA-RUNBOOK>'. The rollout
--     runbook (docs/runbooks/rollout-mssql-ops.md) fills the real per-mandant shop
--     license keys via UPDATE, straight into ops.Mandant — never into a committed
--     file. A reset run against an unfilled mandant repoints the shop to that
--     sentinel, which is harmless (it is not a working license).
--   * ShopUrl / LoginName / Developer are operational template values; the runbook
--     confirms/corrects them before the first real reset.
--
-- NOTE (deviation from the plan's literal "{{ShopLicense}}" placeholder): a
-- '{{...}}' string would collide with grate's own token syntax and be substituted
-- (or error) at deploy. A plain sentinel value avoids that and reads unambiguously.
--
-- Idempotent: guarded by key so a re-run against a fresh instance is harmless; it
-- never overwrites values a runbook step has already corrected.
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§2)

SET NOCOUNT ON;

-- --- ops.Config ------------------------------------------------------------------
MERGE ops.Config AS tgt
USING (VALUES
    (N'BackupFile',        N'E:\work\eazybusiness_to_test.bak', N'COPY_ONLY backup staging path (single path -> resets serialize)'),
    (N'TargetDataDir',     N'E:\MSSQL\Data',                    N'Data dir for clone .mdf/.ldf (E: — never the small C: that holds PROD)'),
    (N'SourceDb',          N'eazybusiness',                     N'Clone source database'),
    (N'ReferenceMandant',  N'1',                                N'kMandant used as tBenutzerFirma seed template in register-mandant'),
    (N'StaleRunningHours', N'4',                                N'Age (hours) after which reset.ProcessNextResetRequest reclaims a still-running request as failed (CQG-7)'),
    (N'AgentJobName',      N'RoboticoOps - Testmandant Reset',  N'SQL Agent job name; single-sourced for Start/EnsureAgentJob/200_ensure_agent_job (CQG-8)')
) AS src (ConfigKey, ConfigValue, Notes)
    ON tgt.ConfigKey = src.ConfigKey
WHEN NOT MATCHED BY TARGET THEN
    INSERT (ConfigKey, ConfigValue, Notes) VALUES (src.ConfigKey, src.ConfigValue, src.Notes);

-- --- ops.Mandant (template rows) -------------------------------------------------
MERGE ops.Mandant AS tgt
USING (VALUES
    (N'tm2', N'eazybusiness_tm2', N'Testmandant 2', N'(confirm in runbook)', N'dbuser_dev_tm2', N'https://tm2.staging.local', N'<SET-VIA-RUNBOOK>'),
    (N'tm3', N'eazybusiness_tm3', N'Testmandant 3', N'(confirm in runbook)', N'dbuser_dev_tm3', N'https://tm3.staging.local', N'<SET-VIA-RUNBOOK>'),
    (N'tm4', N'eazybusiness_tm4', N'Testmandant 4', N'(confirm in runbook)', N'dbuser_dev_tm4', N'https://tm4.staging.local', N'<SET-VIA-RUNBOOK>')
) AS src (MandantKey, TargetDb, DisplayName, Developer, LoginName, ShopUrl, ShopLicense)
    ON tgt.MandantKey = src.MandantKey
WHEN NOT MATCHED BY TARGET THEN
    INSERT (MandantKey, TargetDb, DisplayName, Developer, LoginName, ShopUrl, ShopLicense, IsActive)
    VALUES (src.MandantKey, src.TargetDb, src.DisplayName, src.Developer, src.LoginName, src.ShopUrl, src.ShopLicense, 1);
GO
