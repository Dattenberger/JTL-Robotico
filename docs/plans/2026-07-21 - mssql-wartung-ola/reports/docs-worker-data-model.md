# Doc Worker Report — data-model

**Date:** 2026-07-23T00:05:00+02:00
**Item:** SLUG=`data-model` · ACTION=`update`
**Target doc:** `docs/SQL/MSSQL-OPS-DATA-MODEL.md`
**Source:** `db-migrations/global/up/0023_maintenance_registry.sql`
**Plan-start commit:** `d722993ae64b0a7e0dbcb5fd37fa8c6a7e7180a9`
**Outcome:** `no-change-needed`

## Summary

The `ops.tMaintenanceJob` section of the DATA-MODEL doc was already authored
during implementation (it appears in the plan-start..HEAD diff alongside the
`up/0023` DDL, +56 lines). This was a verification/consistency pass per the
discovery report; the doc is fully in line with the shipped DDL. No edits
applied.

## Verification performed (column-by-column, DDL vs. doc)

All 17 columns of `ops.tMaintenanceJob` present in the doc with matching
type, nullability, default, and constraint semantics:

`cJobKey` (sysname PK), `cDisplayName` (nvarchar(128) NOT NULL UNIQUE +
prefix CHECK), `cOperation` (nvarchar(20) NOT NULL + 4-value CHECK),
`cDatabases` (nvarchar(400) NOT NULL, double-grammar documented),
`cFrequency` (nvarchar(10) NOT NULL, daily/weekly/hourly), `nWeekdayMask`
(tinyint NULL), `tStartTime` (time(0) NOT NULL), `bUpdateStatistics`
(bit NULL), `cCleanupTarget` (nvarchar(20) NULL + 3-value CHECK),
`nRetentionDays` (int NULL >0), `nFullMaxHours` (int NULL >0),
`nLogMaxHours` (int NULL >0), `bEnabled` (bit NOT NULL DF 1),
`bNotifyOnFail` (bit NOT NULL DF 1), `cNotes` (nvarchar(400) NULL),
`dCreated` / `dModified` (datetime2(0) NOT NULL DF UTC).

Cross-checks that also held:
- Header count "five registry tables" = tMandant + tConfig + tResetRequest +
  tResetStep + tMaintenanceJob. Consistent.
- Same-commit contract box (`> [!IMPORTANT]`) lists `up/0023` and the
  repo-owned MERGE (`maint.spApplyMaintenance.sql`).
- `CK_tMaintenanceJob_OperationKnobs` self-validation documented.
- References block lists `up/0023` DDL + the reconcile proc.
- Six `cJobKey` values documented (checkdb, index-optimize,
  cleanup-commandlog, cleanup-backuphistory, cleanup-jobhistory,
  backup-watchdog) — matches the 6-job registry.

## Deviations

None.

## Issues

None.

## Files modified

None (`no-change-needed`).

## Files outside assigned scope (drift)

none

## Notes for final

- No cross-doc contradictions observed from this doc's side. The
  DATA-MODEL doc's inbound/outbound links (`MSSQL-OPS-ARCHITECTURE.md`,
  the Hungarian-naming ADR, NAMING-CONVENTIONS §9 for the `t`-prefix
  micro-convention) are consistent with the sibling-doc updates described
  in the discovery report; the final agent may confirm the NAMING §9
  anchor exists as referenced.
- The `nWeekdayMask` CHECK range (`BETWEEN 1 AND 127`) is enforced in DDL
  but not restated in the doc's meaning column. This is intentional under
  the doc's stated division of labour ("DDL is authoritative for
  types/constraints; this document is authoritative for meaning") and is
  not a stale claim — flagged only for awareness, no action recommended.
