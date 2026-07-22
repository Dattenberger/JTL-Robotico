# C1 IMPL+TEST Report — SQL-Server-Wartung als Code (B1–B5)

**Date:** 2026-07-22 · **Chunk:** C1 (whole implementation scope B1–B5) · **Agent:** chunk-impl-test

## What was done

Implemented the complete maintenance suite: vendored Ola objects (`up/0022`), maint schema + `ops.tMaintenanceJob` registry (`up/0023`), the five `maint.*` procs (sync, runtime dispatcher, backup-chain watchdog, liveness check, MERGE reconcile wrapper), `permissions/260` (operator + guarded mail profile + unconditional ensure), both validation-gate edits, README §4-(k) THROW allocation + §7 config-knob row, the three SQL doc edits (DATA-MODEL, NAMING, ARCHITECTURE) and the B6 runbook weave (Phase 4a + Phase 4b). Deployed to test1 and executed the full B5 checklist. B6 execution (prod) untouched — human-gated, out of scope; vm-sql2 never contacted.

## Test/validation run (B5 on test1, all live)

| Check | Result |
|---|---|
| `npm run db:lint` | 0 errors (2 pre-existing warnings in `reset.spInternal_GrantAccess`) |
| `deploy.ps1 -Scope global -Environment TEST` | clean; 0022+0023 applied, sprocs + reconcile + permissions ran |
| Ola objects in `RoboticoOps.dbo`; `DatabaseBackup` absent (AC2/AC4) | ✓ (CommandLog/CommandExecute/DatabaseIntegrityCheck/IndexOptimize present, no DatabaseBackup) |
| Registry = 6 seed rows (AC1) | ✓ |
| D34 switch `'0'` set (admin-owned, one-time) → all 6 jobs exist disabled; notify_level 2 | ✓ |
| Constant dispatch step per job (D28/AC3) | ✓ (verified `sysjobsteps.command`, database RoboticoOps) |
| `EXEC maint.spEnsureMaintenanceJobs` re-run | "0 change(s)" (AC7 measuring point) |
| checkdb job run (`sp_start_job`, works despite disabled) | green, 1m36s, 5 `DBCC_CHECKDB` CommandLog rows, 0 errors |
| index-optimize job run (AC10/D13) | green, 7m35s; 8593 `UPDATE_STATISTICS` + 167 `ALTER_INDEX` rows; 0 commands with `REBUILD`; sample = `… REORGANIZE WITH (LOB_COMPACTION = ON)` |
| 3 cleanup jobs | all green |
| Watchdog stale path (no CBB chain on test1, by design) | `THROW 51100` with per-DB detail |
| Watchdog invalid target (`USER_DATABASES`) | `THROW 51100` invalid-target message (D32) |
| Watchdog fresh path (NUL full+log backups of RoboticoOps, FT-15) | silent; `>=` boundary (threshold 0 vs age 0) alarms (D27/AC5); TRIM tolerant |
| Liveness before runs (switch temporarily ≠ '0') | `THROW 51105` naming `checkdb, index-optimize` (AC13) |
| Liveness after green runs / with switch `'0'` | silent both ways (D34/D36) |
| FI-8a drift test (live `sp_update_schedule`) | ensure reports "1 change(s)", schedule restored |
| FI-8b foreign-job test (`RoboticoOps - Maint - zz-test`) | removed by ensure (AC3 removal path) |
| `spRunMaintenanceJob` unknown key | `THROW 51120` |
| Idempotency re-deploy (AC7) | grate skipped all up/anytime scripts; 260's ensure "0 change(s)"; `dModified` byte-identical before/after |
| `validate_structure.sql` / `validate_rollout.sql` (AC11/AC12) | both OK (rollout incl. new maintenance block, green with switch `'0'`) |
| No Ola objects created by our chain in `eazybusiness` (AC2) | ✓ — test1's `eazybusiness.dbo` carries LEGACY Ola objects (create_date 2024-06-24, i.e. pre-existing mirror of the old install), not ours |
| AC6 boundary | operator `RoboticoOps-Maint` exists + jobs wired; Database-Mail profile `Standard SMTP` absent on test1 → 260 printed the guarded hint (FT-16, by design); mail test is B6 |

Agent on test1 was found Running (needed for reset work) and left Running — the schedule protection hangs on the D34 switch, per plan §3.5.

## Deviations

| Deviation | Plan location | What changed | Why | Impact on later chunks | Resolved? |
|---|---|---|---|---|---|
| FT-13 wrapper not needed | §3.1 (0022) | No `IF OBJECT_ID` wrapper added around `CommandLog` CREATE TABLE | Upstream (pinned version 2026-07-22) already guards it with `IF NOT EXISTS` — the plan's assumption was outdated | none | ✓ documented in 0022 header |
| Version pin = master snapshot | §3.1 | Pinned Ola version is the master snapshot `2026-07-22 20:03:34` (tag `20260722_200334`) — GitHub releases API was unavailable, tags are timestamp-style | Version stamp is embedded in each proc (`--// Version:`), so the pin is verifiable from the file itself | none | ✓ |
| 3 documented byte-breaks in vendored files | §3.1 lint pre-check | `'1900-01-01'`-style literals → `'19000101'` (3 sites), CRLF→LF, BOMs stripped | Lint rule (h) errors on dashed date literals; exactly the plan's sanctioned deviation mechanism (commented, `@see` upstream) | none | ✓ |
| IndexOptimize passes `@FragmentationMedium` too | §3.2 matrix (only `@FragmentationHigh` named) | Both Medium and High pinned to `INDEX_REORGANIZE` | Ola's Medium default includes `INDEX_REBUILD_OFFLINE` — pinning only High would leave an offline-rebuild path open, violating D13's intent | none | ✓ |
| `260` uses `xp_instance_regread/-write` for the agent mail profile | §3.3 (mechanism unspecified) | Registry-based profile set, guarded by `sysmail_profile` existence + only-if-unset | The documented `sp_set_sqlagent_properties` has no supported mail-profile parameter; registry keys are the standard mechanism | none | ✓ |
| ARCHITECTURE §6 rule numbering shifted | §3.4 (d) | New rules inserted as §6.5/§6.6; former §6.5 ("never write autonomously") became §6.7 | Keeps thematic order; no inbound references to old §6.5 number exist | none | ✓ |

## Issues

| ID | Severity | Description | Status | Marker |
|---|---|---|---|---|
| I1 | Nice-to-have | test1's `eazybusiness.dbo` still carries the LEGACY Ola objects from 2024 (CommandLog, DatabaseBackup, DatabaseIntegrityCheck). Not created by our chain (AC2 holds); prod removal is B6 Phase 4a, but test1 has no cleanup owner. | delegated | none |

## Files modified

New: `db-migrations/global/up/0022_maintenance_ola_vendor.sql`, `up/0023_maintenance_registry.sql`, `sprocs/maint.spEnsureMaintenanceJobs.sql`, `sprocs/maint.spRunMaintenanceJob.sql`, `sprocs/maint.spCheckBackupChain.sql`, `sprocs/maint.spCheckMaintenanceLiveness.sql`, `runAfterOtherAnyTimeScripts/maint.spApplyMaintenance.sql`, `permissions/260_maintenance_operator.sql`.
Edited: `db-migrations/tests/global/validate_structure.sql`, `validate_rollout.sql`, `db-migrations/README.md`, `docs/SQL/MSSQL-OPS-DATA-MODEL.md`, `docs/SQL/NAMING-CONVENTIONS.md`, `docs/SQL/MSSQL-OPS-ARCHITECTURE.md`, `docs/runbooks/rollout-mssql-ops.md`.

**Drift (files outside assigned scope):** none. Pre-existing PayPal-removal changes in the worktree untouched.

## Primitives reused / helper decisions

`reset.spEnsureAgentJob` (job-create shape, operator-EXISTS guard, self-executing wrapper), `permissions/200_ensure_agent_job` (everytime self-heal + OBJECT_ID guard), `up/0002` (schema CREATE with AUTHORIZATION dbo), `up/0021` (registry DDL style, ops_admin grants), `250_jobstartuser_mapping` (permissions prefix ordering), validate_structure/rollout list patterns. No new shared helpers needed.

## Self-check

Walked all plan requirements of §3.1–§3.5 (✓/△ per tables above); AC1–AC13 all evidenced on test1 except prod-only ACs (AC6 mail delivery = B6). Naming per NAMING-CONVENTIONS §9 (Hungarian, `t` time prefix documented). No stubs/TODOs. Integration = call sites: constant job steps call `maint.spRunMaintenanceJob` (verified live in `sysjobsteps`); `spApplyMaintenance` L~140 calls `spEnsureMaintenanceJobs`; `260` L~95 calls it unconditionally; dispatcher calls `spCheckBackupChain` + `spCheckMaintenanceLiveness`. Findings fixed during self-check: duplicated deviation comment in 0022 (from automated insertion), stray CJK character in a spCheckBackupChain comment, ARCHITECTURE numbering conflict.
