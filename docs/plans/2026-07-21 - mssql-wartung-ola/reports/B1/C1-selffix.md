# C1 Self-Fix Report — fresh-eyes review of wave 923b6c7

**Date:** 2026-07-22T21:57:00+02:00 · **Chunk:** C1 · **Agent:** chunk-self-fix

## What was done

Fresh-eyes review of the full C1 diff (`git show 923b6c7`, all 15 CHUNK_FILES) against plan §2 (AC1–AC13), §3.1–§3.5 and §4, with the three lenses (plan correctness / code quality / test quality). Re-ran the executable gates. **No fixes were required** — zero edits made.

## Review findings per lens

**Plan correctness** — every §3.1–§3.5 requirement is present and traceable:
- 0022: pinned version + tag in header, DatabaseBackup absent, 3 `VENDOR-DEVIATION` comments at the exact byte-break sites (L345, L1519, L4925), FT-13 deviation correctly documented (upstream now guards CommandLog itself).
- 0023: DDL byte-faithful to the plan's SQL block incl. all CHECKs, `GRANT SELECT`-only for ops_admin.
- spEnsureMaintenanceJobs: closed D31 comparison surface exactly as enumerated (job enabled/notify, step command/database/subsystem, all 6 schedule facets + schedule enabled), every column `IS DISTINCT FROM`, session-scoped running-job guard (`MAX(session_id)`), operator-EXISTS guard, prefix-window removal pass, weekly `freq_recurrence_factor = 1`, hourly subday 8/1, HHMMSS conversion. Jobs with 0/≠1 steps or schedules fall out of the NOT-EXISTS and correctly count as drift.
- spRunMaintenanceJob: command matrix 1:1 (incl. runtime cleanup cutoffs, D33 `@UpdateStatistics` mapping, REORGANIZE-only pinning, watchdog→liveness chaining, 51120 both for unknown key and missing CASE branch).
- spCheckBackupChain: TRIM + ONLINE target validation with token in message, `is_copy_only=0`, `<> 'SIMPLE'`, `>=` boundary, `SYSDATETIME()` local base + gotcha comment.
- spCheckMaintenanceLiveness: D34 effective-enabled gate, 26 h/8 d derivation, correct CommandType pairs per operation.
- spApplyMaintenance: 6 seed rows matching the §3.2 SSoT table exactly (keys, databases, masks — Sun+Wed=9, times, knobs, watchdog 26/1), all 14 desired columns in the `IS DISTINCT FROM` guard and in the UPDATE, `NOT MATCHED BY SOURCE THEN DELETE`, explicit `dModified` only on real change.
- 260: operator hard-coded (documented R2/D34 policy), FT-16 sysmail guard + only-if-unset, unconditional ensure with OBJECT_ID belt-and-braces.
- Docs: DATA-MODEL five-tables header + 0023 in contract box + full 17-column section; NAMING §9 maint row + `t`-time micro-convention (the DATA-MODEL "§9" cross-reference resolves correctly); ARCHITECTURE three schemas + inventory rows + §6.5/§6.6 new standing rules (renumber to §6.7 documented as deviation); README (k) table + FT-14 guidance sentence (reset from 51130) + §7 `MaintenanceSchedulesEnabled` row; runbook Phase 4a before the deploy block and Phase 4b after, CAUTION with the D26 time-window rule and the emergency lever.

**Deviations check:** all 6 deviations in the impl report verified against the diff — each is a defensible D4 call, none silent. Notably `@FragmentationMedium` pinning (Ola's Medium default includes `INDEX_REBUILD_OFFLINE`) closes a real hole the plan's shorthand left open.

**Code quality** — naming per NAMING-CONVENTIONS §9 throughout, comments carry WHY (gotchas, D-references), no dead code/TODOs, primitives (`reset.spEnsureAgentJob` shape, `200_ensure_agent_job` self-heal, `up/0002` schema pattern) genuinely reused. One consciously-accepted non-finding: `cNotes`/job description is outside the D31 closed comparison list, so a notes-only seed edit updates the registry but not the live job description until another facet drifts — this is exactly the plan's enumerated closed surface, not drift.

**Test quality** — validation gates cover AC11/AC12 as specified (all 5 procs + table + 14 key columns in structure; rollout asserts the D34 *equation*, not blanket "enabled", so it is green on test1 switch `'0'` and prod alike). B5 live evidence in the impl report covers every checklist row incl. the FI-8a/8b sync-path tests and the FT-15 fresh-chain path.

## Test runs (after review, all green)

| Gate | Result |
|---|---|
| `npm run db:lint` | 0 errors (2 pre-existing warnings in `reset.spInternal_GrantAccess`, untouched) |
| `validate_structure.sql` on test1 | OK |
| `validate_rollout.sql` on test1 | OK (incl. new maintenance block) |

## Issues

| ID | Severity | Description | Status | Marker |
|---|---|---|---|---|
| — | — | none | — | — |

## Files modified

None (0 fixes applied).

**Drift (files outside CHUNK_FILES):** none.
