# Cleanup 02 — Refresh `eazybusiness_tm2` off its stale JTL version

**Type:** manual procedure. No SQL file — the actual work is a clone-and-reset
operation driven by the tools built in this plan, not a standalone script.

> [!WARNING]
> Production impact. This drops and recreates a mandant database on prod
> (vm-sql2). Do it in a reviewed session, with the JTL-Worker stopped, following
> the full reset runbook — not ad hoc.

## Finding

From `research/2-instanz-survey` §6: every eazybusiness database on prod is on
JTL schema version **2.0.5.0**, except **`eazybusiness_tm2`, which is stuck at
1.11.6.0**. A mandant on an old schema version cannot be logged into by the
current WaWi client (JTL refuses login to an out-of-date DB) and diverges from
the objects the migration chain expects. tm2 is effectively dead weight until
refreshed.

## Why "refresh via the new reset" rather than "run the JTL update assistant"

The plan's design is **clone-after-update, not update-of-the-clone** (see
`research/4-jtl-spezifika` §2). Prod's `eazybusiness` is already on 2.0.5.0, so
the clean way to bring tm2 current is to **re-clone it from the up-to-date prod
`eazybusiness`** and re-run the reset, rather than trying to update the stale
tm2 in place. The fresh clone is version-correct by construction.

## Procedure (summary — the authoritative steps live in the reset runbook)

1. **Confirm you still need tm2.** If the mandant is obsolete, the cheaper fix is
   to retire it (drop the DB + remove its `dbo.tMandant` row) instead of
   refreshing. Decide first.
2. **Stop the JTL-Worker service** on the prod host (not just "disable in
   config"). This is the hard precondition for any clone/reset.
3. **Re-clone** `eazybusiness_tm2` from the current prod `eazybusiness`
   (`Projekte/Testsystem/copy_test_db.sql` flow / the RoboticoOps reset clone
   step). The new clone inherits schema version 2.0.5.0 automatically.
4. **Deploy the Ebene-A migration chain** to the fresh clone so our
   Robotico/CustomWorkflows objects are present
   (`deploy.ps1 -Scope eazybusiness -Target eazybusiness_tm2`).
5. **Run the reset / neutralisation** (worker/account/shop neutralisation + queue
   drain + customer-field clear) exactly as for any other test mandant — see
   [`docs/runbooks/testmandant-reset-validierung.md`](../../docs/runbooks/testmandant-reset-validierung.md).
6. **Verify version + objects:** `dbo.tVersion` = 2.0.5.0, and the post-update
   smoke check (`CustomWorkflows.vCustomActionCheck WHERE Status='ERROR'` returns
   nothing).
7. **Restart the worker** only after neutralisation is verified.

## Cross-reference

- Finding source: `docs/plans/2026-07-10 - mssql-ops-infrastruktur/research/2-instanz-survey`
- Bundled with the other hygiene items in
  [`docs/runbooks/hygiene-findings.md`](../../docs/runbooks/hygiene-findings.md).
