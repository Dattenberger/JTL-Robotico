-- 255_reset_cancel_msdb_grants.sql  (Ebene B / global — permissions, everytime)
--
-- Grants the msdb read rights the reset.spPub_CancelResetRequest 'running' branch needs
-- for its "is the reset Agent job executing right now?" probe (F-1, dress-rehearsal T2-54).
-- That probe joins msdb.dbo.sysjobactivity + sysjobs + syssessions; without these grants
-- it fails with Msg 229 (SELECT denied on 'syssessions') BEFORE the 51007 job-running
-- guard, so the cancel is dead for every 'running' request.
--
-- WHY all THREE tables must be granted DIRECTLY to jobstartuser (not just syssessions):
--   jobstartuser is a member of msdb's SQLAgentOperatorRole (up/0010), which normally grants
--   read on the sysjob* surface. BUT reset.spPub_CancelResetRequest is `WITH EXECUTE AS
--   'jobstartuser'` + signed, and when that impersonated context crosses the RoboticoOps ->
--   msdb boundary, the engine honours jobstartuser's DIRECT object grants but NOT its ROLE
--   memberships — the module signature (RoboticoOpsSigning + AUTHENTICATE SERVER) authenticates
--   the crossing enough for direct grants to apply, yet role-derived permissions do not carry.
--   Empirically verified during F-1: with only the role, the probe is denied on syssessions;
--   granting syssessions alone then moves the denial to sysjobs; granting all three directly to
--   jobstartuser makes the probe succeed. So the role is not enough — grant the three tables
--   explicitly. (sp_start_job in the Start proc is unaffected: it is reached via the direct
--   EXECUTE grant + ownership chaining inside sp_start_job, not by reading these tables.)
--
-- WHY a new everytime permissions script (not up/0010, not folded into 250): up/0010 is a
-- one-time journaled script, immutable once applied (README §2 CAUTION) — it cannot be
-- edited to add grants on standing instances. 250_jobstartuser_mapping has a single, other
-- responsibility (self-healing the orphaned-user SID re-map); bolting an unrelated GRANT onto
-- it would blur that SRP. A GRANT is naturally idempotent (re-granting is a no-op) and belongs
-- in the everytime tier, exactly like 200/250: an assert on top of the one-time up/0010 setup.
-- Ordered 255 so the 250 SID re-map heals the user first; grants key on principal_id, which
-- survives an orphan re-map.
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§2, §3 — signed cancel entry point)
-- @see db-migrations/global/up/0010_jobstartuser_login.sql
-- @see db-migrations/global/sprocs/reset.spPub_CancelResetRequest.sql

SET NOCOUNT ON;

-- msdb: grant SELECT on the three SQL-Agent catalog tables the cancel probe reads, directly to
-- jobstartuser (role membership does not carry cross-DB — see header). Guarded on the user
-- existing so a pre-0010 instance does not error. Idempotent: re-granting is a harmless no-op.
EXEC msdb.sys.sp_executesql N'
    IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N''jobstartuser'')
    BEGIN
        GRANT SELECT ON dbo.syssessions    TO [jobstartuser];
        GRANT SELECT ON dbo.sysjobs        TO [jobstartuser];
        GRANT SELECT ON dbo.sysjobactivity TO [jobstartuser];
        PRINT ''= msdb jobstartuser: SELECT on syssessions/sysjobs/sysjobactivity ensured (reset-cancel job-running probe).'';
    END
';
GO
