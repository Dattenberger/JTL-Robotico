# Plan: SQL-Server maintenance as code (Ola Hallengren in RoboticoOps)

**Status:** Implemented 2026-07-23 (B1–B5 on test1; B6 Prod-Cutover deferred, human-gated)
**Plan file:** [mssql-wartung-ola.md](mssql-wartung-ola.md) · **EN:** [mssql-wartung-ola.en.md](mssql-wartung-ola.en.md)
**Created:** 2026-07-21 · **Branch:** feature/mssql-ops-infrastruktur

## Summary

This plan replaces vm-sql2's broken, `eazybusiness.dbo`-scattered Ola-Hallengren
installation with a versioned, registry-driven maintenance suite in `RoboticoOps`,
deployed through the existing global-grate chain. A single declarative registry
(`ops.tMaintenanceJob`, 6 rows) is the source of truth; `maint.spEnsureMaintenanceJobs`
syncs it to exactly one SQL-Agent job per operation (`RoboticoOps - Maint - …`),
each dispatching through `maint.spRunMaintenanceJob`. Integrity checks (CHECKDB),
index/statistics maintenance, and CommandLog cleanup run again on a schedule, while
two watchdogs — `maint.spCheckBackupChain` (backup-chain freshness) and
`maint.spCheckMaintenanceLiveness` (the historically dominant "job never runs" gap) —
raise `THROW 51100/51105` alerts to the `RoboticoOps-Maint` operator. The suite was
deployed and E2E-verified against test1 (13/13 auto cases PASS, 0 escalations); the
Prod cutover (B6) stays human-gated and outside this run.

## What changed vs. before

- **Before:** vm-sql2 had no effective maintenance — the only scheduled job (`IndexOptimize`)
  failed nightly since ~2025-11-27, CHECKDB last ran 2024-06-24, and nobody was alerted.
  Root causes: wrong place (vendor DB), click-ops (unversioned), no alerting.
- **After:** maintenance lives in `RoboticoOps` as one deployable registry table; CHECKDB
  runs twice weekly before the 03:00 full, statistics are refreshed (`@UpdateStatistics=ALL`),
  and both silent-failure (`bNotifyOnFail`) and silent-non-run (liveness) paths alert.

## Deliberate non-changes / scope boundaries

- **Backups stay with CBB** (ADR-0002): no `DatabaseBackup` is vendored into `RoboticoOps.dbo`
  and no backup job is registered — the chain is *monitored*, not owned. This is a binary
  guarantee, verified by AC4/AC2.
- **This run covers B1–B5 against test1 only.** vm-sql2 was strictly read-only throughout.
- **B6 (Prod cutover)** — removing the legacy Ola objects/jobs on vm-sql2 and activating the
  new suite — is deferred and **human-gated**; it is not part of this implementation run.
- Test-mandant clones (`tm…`) are intentionally excluded from CHECKDB and chain-watching.

## Reports

Per-run implementation artefacts live in [`./reports/`](reports/): the aggregated
[implementation report](reports/implementation-report.md), the [E2E report](reports/e2e-report.md)
and [runbook](reports/e2e-runbook.md), the B1 block audit + repair-wave reports
([`reports/B1/`](reports/B1/)), and the documentation-run reports. Repair-wave research
sits in [`./research/`](research/).

## Related ADRs

- [ADR-0001 — SQL-Server maintenance as code](../../decisions/0001-maintenance-as-code-roboticoops.md):
  Ola vendored in RoboticoOps, declarative registry `ops.tMaintenanceJob`,
  `maint.spEnsureMaintenanceJobs` sync, one job per operation, alerting.
- [ADR-0002 — Backups stay with CBB](../../decisions/0002-backups-cbb-retained.md):
  no Ola backup; read-only backup-chain watchdog.

Both ADRs were promoted from plan-scoped drafts to `docs/decisions/` at plan completion
and cross-reference this plan bidirectionally.
