-- reset.ListMandants  (Ebene B / global — discovery entry point, OPS-1)
--
-- Self-service discovery for a colleague: which test mandants exist, and what the last
-- reset did to each. Runs in its own DB, so it needs NO signature — just EXECUTE granted
-- to ops_reset_executor (permissions/100). Reads ops.Mandant via ownership chaining
-- (schemas are dbo-owned), so the executor role needs no table SELECT of its own.
--
-- Deliberately selects NO secret columns: neither ShopLicense (the role is even
-- column-DENYed on it, 0003_roles) nor ShopUrl. A reset operator can find their mandant
-- KEY without ever seeing a shop credential.
--
-- Why this exists: before this SP the only entry points were StartTestmandantReset and
-- GetResetStatus, so a colleague could act on a MandantKey only if they already knew it —
-- GetResetStatus surfaces a key only after that mandant has been reset at least once.
-- There was no way to answer "which key is mine?" without ops_admin rights on ops.Mandant.
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§3)
CREATE OR ALTER PROCEDURE reset.ListMandants
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        m.MandantKey,
        m.DisplayName,
        m.Developer,
        m.TargetDb,
        m.IsActive,
        last.Status     AS LastStatus,
        last.FinishedAt AS LastFinishedAt
    FROM ops.Mandant m
    OUTER APPLY (
        SELECT TOP (1) r.Status, r.FinishedAt
        FROM ops.ResetRequest r
        WHERE r.MandantKey = m.MandantKey
        ORDER BY r.RequestId DESC
    ) last
    ORDER BY m.MandantKey;
END
GO
