-- reset.spPub_ListMandants  (Ebene B / global — discovery entry point, OPS-1)
--
-- Self-service discovery for a colleague: which test mandants exist, and what the last
-- reset did to each. Runs in its own DB, so it needs NO signature — just EXECUTE granted
-- to ops_reset_executor (permissions/100). Reads ops.tMandant via ownership chaining
-- (schemas are dbo-owned), so the executor role needs no table SELECT of its own.
--
-- Deliberately selects NO secret columns: neither cShopLicense (the role is even
-- column-DENYed on it, 0003_roles) nor cShopUrl. A reset operator can find their mandant
-- KEY without ever seeing a shop credential.
--
-- Why this exists: before this SP the only entry points were spPub_StartTestmandantReset and
-- spPub_GetResetStatus, so a colleague could act on a cMandantKey only if they already knew it —
-- spPub_GetResetStatus surfaces a key only after that mandant has been reset at least once.
-- There was no way to answer "which key is mine?" without ops_admin rights on ops.tMandant.
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§3)
CREATE OR ALTER PROCEDURE reset.spPub_ListMandants
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        m.cMandantKey,
        m.cDisplayName,
        m.cDeveloper,
        m.cTargetDb,
        m.bActive,
        last.cStatus     AS LastStatus,
        last.dFinished AS LastFinishedAt
    FROM ops.tMandant m
    OUTER APPLY (
        SELECT TOP (1) r.cStatus, r.dFinished
        FROM ops.tResetRequest r
        WHERE r.cMandantKey = m.cMandantKey
        ORDER BY r.kResetRequest DESC
    ) last
    ORDER BY m.cMandantKey;
END
GO
