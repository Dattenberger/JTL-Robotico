# `Projekte/Testsystem/` — DEPRECATED test-mandant reset (PowerShell)

> [!WARNING]
> **This is the old, PowerShell-based test-mandant reset. It is kept as a working
> fallback only.** The new reset is server-side, audited, and needs no personal admin
> rights on production. New resets go through it — see below. Decision **D12** in
> `docs/plans/2026-07-10 - mssql-ops-infrastruktur/`.

## What this folder is

`setup-test-environment.ps1` orchestrates the legacy reset by running these SQL scripts in
order against a target `eazybusiness_tmN` database:

1. `copy_test_db.sql` — clone the source DB to the target
2. `invalidate-credentials-for-testing.sql` — deactivate passwords/emails, disable eBay
   sync, repoint the shop to a staging URL/licence
3. `clear-customer-fields.sql` — anonymize customer data
4. `grant-database-access.sql` — grant `db_owner` to the developer login
5. `../../Berechtigungen/JTL-Rollen.sql` — apply the standard JTL reader/writer roles

It requires the operator to hold **personal admin rights on the production server**, reads
its config from the git-ignored `test-environment.config.json`, and has no audit trail.

## Use the new reset instead

The server-side reset replaces this entire folder's function. A colleague triggers it with
a single `EXECUTE`; a signed SP enqueues the request and a SQL-Agent job runs the whole
pipeline (clone + all post-processing, incl. extended worker neutralisation), with full
audit in `ops.ResetRequest`:

```sql
EXEC RoboticoOps.reset.StartTestmandantReset @MandantKey = N'tm4';
EXEC RoboticoOps.reset.GetResetStatus        @MandantKey = N'tm4';   -- poll
```

Where each legacy script now lives (ported into the Ebene-B reset pipeline):

| Legacy script here | Now deployed as |
|---|---|
| `copy_test_db.sql` | `db-migrations/global/sprocs/reset.internal_CloneDatabase.sql` |
| `invalidate-credentials-for-testing.sql` | `reset.internal_InvalidateCredentials.sql` |
| `clear-customer-fields.sql` | `reset.internal_AnonymizeCustomerData.sql` |
| `grant-database-access.sql` | `reset.internal_GrantAccess.sql` |
| `register-mandant.sql` | `reset.internal_RegisterMandant.sql` |
| `Berechtigungen/JTL-Rollen.sql` | `reset.internal_ApplyJtlRoles.sql` |
| — (new, D9) | `reset.internal_NeutralizeWorker.sql` (eBay+Amazon lock, drain queues) |
| `test-environment.config.json` | `ops.Mandant` / `ops.Config` (column-protected licence) |

## Read next

- **Architecture:** [`../../docs/SQL/MSSQL-OPS-ARCHITECTURE.md`](../../docs/SQL/MSSQL-OPS-ARCHITECTURE.md)
- **Validate the new reset:** [`../../docs/runbooks/testmandant-reset-validierung.md`](../../docs/runbooks/testmandant-reset-validierung.md)
- **Full rollout:** [`../../docs/runbooks/rollout-mssql-ops.md`](../../docs/runbooks/rollout-mssql-ops.md)

> [!NOTE]
> Do not delete this folder yet. Physical removal is a separate, conscious step after the
> new reset has run cleanly for real mandants (rollout Phase 7). Until then, this stays as
> the rollback path.
