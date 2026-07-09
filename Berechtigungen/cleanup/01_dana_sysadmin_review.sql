-- ############################################################################
-- #  MANUAL EXECUTION ONLY — PRODUCTION IMPACT                                #
-- #  01_dana_sysadmin_review.sql                                             #
-- #                                                                          #
-- #  The SELECT/catalog blocks below are READ-ONLY and safe to run against   #
-- #  prod (vm-sql2) to review the finding. Every REMEDIATION statement is    #
-- #  COMMENTED OUT on purpose — read the analysis, decide, then run the      #
-- #  chosen fix by hand in a reviewed session. Nothing here runs a write.    #
-- ############################################################################
--
-- FINDING (research/2-instanz-survey §3): the SQL login `dbuser_dev_dana_for_jtl`
-- is a member of the server role `sysadmin` on prod (vm-sql2) — a developer login
-- with unrestricted server authority (can read/alter/drop ANY database, change
-- security, disable auditing). It is also in `dbcreator`. This is far more than a
-- JTL dev login needs and is the highest-severity hygiene item in the survey.
--
-- Run read-only against prod:
--   /opt/mssql-tools18/bin/sqlcmd -S vm-sql2.zdbikes.local -E -C \
--       -d master -i Berechtigungen/cleanup/01_dana_sysadmin_review.sql

SET NOCOUNT ON;

-- ---------------------------------------------------------------------------
-- (A) Server-role memberships of the dana logins (which fixed roles they hold)
-- ---------------------------------------------------------------------------
SELECT
    r.name              AS ServerRole,
    m.name              AS MemberLogin,
    m.type_desc         AS LoginType,
    m.is_disabled       AS IsDisabled,
    m.create_date       AS CreatedUtc,
    m.modify_date       AS ModifiedUtc
FROM sys.server_role_members srm
JOIN sys.server_principals r ON r.principal_id = srm.role_principal_id
JOIN sys.server_principals m ON m.principal_id = srm.member_principal_id
WHERE m.name LIKE 'dbuser_dev_dana%'
ORDER BY m.name, r.name;

-- ---------------------------------------------------------------------------
-- (B) Everyone currently in sysadmin (context: how exposed is the instance?)
-- ---------------------------------------------------------------------------
SELECT
    m.name              AS SysadminMember,
    m.type_desc         AS LoginType,
    m.is_disabled       AS IsDisabled
FROM sys.server_role_members srm
JOIN sys.server_principals r ON r.principal_id = srm.role_principal_id
JOIN sys.server_principals m ON m.principal_id = srm.member_principal_id
WHERE r.name = 'sysadmin'
ORDER BY m.name;

-- ---------------------------------------------------------------------------
-- (C) Explicit server-level permissions granted to the dana login (beyond roles)
-- ---------------------------------------------------------------------------
SELECT
    p.name              AS LoginName,
    sp.permission_name  AS Permission,
    sp.state_desc       AS State
FROM sys.server_principals p
LEFT JOIN sys.server_permissions sp ON sp.grantee_principal_id = p.principal_id
WHERE p.name = 'dbuser_dev_dana_for_jtl'
ORDER BY sp.permission_name;

-- ---------------------------------------------------------------------------
-- (D) What does the login actually map to inside eazybusiness? Run this block
--     with -d eazybusiness to see its DB user, DB roles and object permissions —
--     this is the evidence for the "granular grant" alternative below.
-- ---------------------------------------------------------------------------
--   SELECT dp.name AS DbUser, r.name AS DbRole
--   FROM sys.database_role_members drm
--   JOIN sys.database_principals r  ON r.principal_id  = drm.role_principal_id
--   JOIN sys.database_principals dp ON dp.principal_id = drm.member_principal_id
--   WHERE dp.name IN (SELECT name FROM sys.database_principals
--                     WHERE sid = SUSER_SID('dbuser_dev_dana_for_jtl'))
--   ORDER BY r.name;

-- ===========================================================================
-- REMEDIATION OPTIONS — COMMENTED OUT. Choose one, review, run by hand.
-- ===========================================================================
--
-- Precondition for ALL options: confirm no automated job / connection string
-- relies on dana having sysadmin (grep app configs; check SQL Agent job owners;
-- watch Extended Events for a day). Removing sysadmin from a login an unattended
-- job depends on will break that job.
--
-- Option 1 — Drop sysadmin, keep dbcreator (least disruptive first step):
--   ALTER SERVER ROLE sysadmin DROP MEMBER [dbuser_dev_dana_for_jtl];
--   -- dbcreator stays, so dana can still create/restore DBs for JTL dev work but
--   -- can no longer alter security or touch unrelated databases.
--
-- Option 2 — Drop sysadmin AND dbcreator, grant only what JTL dev needs:
--   ALTER SERVER ROLE sysadmin  DROP MEMBER [dbuser_dev_dana_for_jtl];
--   ALTER SERVER ROLE dbcreator DROP MEMBER [dbuser_dev_dana_for_jtl];
--   -- then, per database that dana must administer (run in that DB context):
--   -- ALTER ROLE db_owner ADD MEMBER [<dana-db-user>];
--
-- Option 3 — Replace the shared dev login with a personal, least-privilege one
--   and disable the old login rather than deleting it (keeps an audit trail):
--   -- ALTER LOGIN [dbuser_dev_dana_for_jtl] DISABLE;
--
-- After applying any option, re-run blocks (A)-(C) to confirm the new state.
