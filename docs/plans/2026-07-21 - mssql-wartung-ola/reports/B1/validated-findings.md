# B1 Audit Consolidation — validated findings

**Date:** 2026-07-22T21:57:00+02:00 · **Block:** B1 · **Mode:** initial
**Sources:** audit-plan-and-api, audit-convention, audit-logic, audit-test
**Input:** 7 raw findings → **6 surviving** (1 duplicate merged, 0 false positives)

## Summary

The four parallel audits agree the block is faithful to the plan (all AC1–AC13
present, no stubs, API-consumers matched end-to-end) and lint-green. Six real
consistency/logic findings survive validation: two Important convention/test
gaps with mechanical fixes, one Important shared plan+impl logic bug (DATEDIFF
boundary), and three Nice-to-have items (two of them latent, one cosmetic). No
finding was eliminated as a false positive; the two overlapping IndexOptimize-
liveness findings were merged.

## Surviving findings

### F1 — convention-B1-1 — Important — green — up/0023 is the only German-commented file in an all-English chain

`db-migrations/global/up/0023_maintenance_registry.sql` (header L18–20, table DDL
L25, L31–102). **Validated:** per-file German-marker count is 21 for 0023 and **0
for every other `up/` script (0001–0022)**, 0 for all five `maint.*` procs and
`maint.spApplyMaintenance`. Its direct structural analog `up/0021_reset_step_registry.sql`
is English (confirmed by reading its header). This violates the binding
`language-conventions.md` rule "Code comments and identifiers: English" and is
inconsistent within its own block. **Fix:** translate the 0023 inline comments to
English (content unchanged, language only). GOTCHA: 0023 is an immutable `up/`
script; a comment-only edit re-hashes it, so land it **before the first prod apply
of 0023**.

### F2 — T-1 — Important — green — rollout gate does not assert the six canonical maintenance rows exist

`db-migrations/tests/global/validate_rollout.sql` (maint block L139–153).
**Validated:** the block drives its loop `FROM ops.tMaintenanceJob m LEFT JOIN
sysjobs` and never asserts the six seed rows (`checkdb`, `index-optimize`,
`cleanup-commandlog`, `cleanup-backuphistory`, `cleanup-jobhistory`,
`backup-watchdog`) are present — an empty/partial registry iterates zero rows and
still reports OK. This is asymmetric with the sibling **reset-step block in the
same file (L54–75)**, which drives from a named `expected` CTE precisely so a
missing row is caught. Practical probability is low (spApplyMaintenance MERGEs all
six on every deploy), but the reset block sets the convention. Not a regression
(diff only appends). **Fix:** add a named `expected` CTE of the six
`cJobKey`/`cDisplayName` pairs (SSoT = plan §3.2 / the spApplyMaintenance MERGE)
and flag any missing, mirroring L54–75. Keep the per-row job/wiring loop unchanged.

### F3 — L-B1-1 — Important — green — spCheckBackupChain age test uses DATEDIFF(HOUR) (clock-boundary, not elapsed) → false STALE alarms

`db-migrations/global/sprocs/maint.spCheckBackupChain.sql` L77 (full) and L92
(log). **Validated:** both use `DATEDIFF(HOUR, lastBackup, @dNow) >= threshold`,
which counts clock-hour boundaries crossed, not elapsed hours; two timestamps 10
min apart in different clock-hours return 1. With the seeded `nLogMaxHours = 1`,
`eazybusiness` FULL recovery, hourly CBB log backups and the hourly watchdog, a
log backup only minutes old but in the previous clock-hour yields
`DATEDIFF(HOUR)=1 >= 1` → false `THROW 51100` recurrently on the production ERP DB
(the exact cry-wolf failure the design fights). The sibling
`spCheckMaintenanceLiveness` (L59–62) already uses the correct `DATEADD` elapsed-
time cutoff, confirming the inconsistency is an oversight. **Shared plan+impl
flaw:** plan §AC5 literally specifies this DATEDIFF formula, so the fix requires a
matching AC5 plan-text correction (route the fixer as a plan-deviation, not a
silent inline change). **Fix:** mirror the liveness proc, preserving AC5's
">= threshold alarms" boundary semantics: full → `f.dLastFull <= DATEADD(HOUR,
-@FullMaxHours, @dNow)` (NULL still alarms); log → `l.dLastLog <= DATEADD(HOUR,
-@LogMaxHours, @dNow)` — or `DATEDIFF(MINUTE, …) >= threshold*60`.

### F4 — L-B1-2 — Nice-to-have — yellow (research: liveness-first-run-grace) — no grace for freshly-enabled / newly-created jobs

`db-migrations/global/sprocs/maint.spCheckMaintenanceLiveness.sql` L49–63.
**Validated:** the check alarms for any effectively-enabled IntegrityCheck/
IndexOptimize row with no CommandLog entry inside its window; a just-enabled
(bEnabled 0→1) or first-time job has no history and is indistinguishable from a
stopped job → false `51105` until its first scheduled run (e.g. enabled 10:00,
next run 02:00 → ~16 h of hourly false alarms; and at go-live CommandLog is
empty). **Muted** because at go-live `spCheckBackupChain`'s 51100 throws first in
the same step (spRunMaintenanceJob orders backup-chain before liveness), and
enabling a job is a rare supervised deploy event — hence Nice-to-have. Needs a
design decision (implement a grace gate on `dModified`/a last-enabled marker, OR
accept + add a runbook note that a first run is triggered manually via
`sp_start_job` right after enabling, as the B5 test1 checklist already did) →
classified yellow.

### F5 — L-B1-3 ∪ plan-and-api-B1-1 (merged) — Nice-to-have — yellow (research: indexoptimize-liveness-heartbeat) — IndexOptimize liveness is latently coupled to bUpdateStatistics=1

Merged: both audits flagged the same underlying issue from different angles (logic
+ plan/api); max severity Nice-to-have. `maint.spCheckMaintenanceLiveness.sql`
L57–58 treats an IndexOptimize run as alive only if an `ALTER_INDEX` **or**
`UPDATE_STATISTICS` CommandLog row exists in the window. **Validated:** `up/0023`
L51–52 + the OperationKnobs CHECK (L87–91) explicitly permit `bUpdateStatistics=0`
(D33 "parameter omitted" exception), and `spRunMaintenanceJob` then runs
IndexOptimize with no statistics maintenance. On a low-churn night with nothing
past the reorg threshold, neither ALTER_INDEX nor UPDATE_STATISTICS is logged →
false `51105` on a green job. **Latent today** (the sole `index-optimize` seed row
is `bUpdateStatistics=1`), so no live impact; surfaces only for a future stats-off
IndexOptimize row. Needs a design decision (document the coupling in the DATA-MODEL
contract + proc header, OR have the IndexOptimize dispatch log an unconditional
heartbeat row so liveness never depends on there being work) → classified yellow.

### F6 — convention-B1-2 — Nice-to-have — green — permissions/260 PRINT messages anchor on the file number, not the object

`db-migrations/global/permissions/260_maintenance_operator.sql` L45, L56, L78, L90
— prefixes `'260: …'` / `'! 260: …'`. **Validated by grep:** every other
operational PRINT anchors on the object — `200_ensure_agent_job` prints `'! Agent
job [...] missing …'`, `250_jobstartuser_mapping` prints `'! … jobstartuser was
orphaned …'`, `100_grants` prints `'! Login [...] not found …'`, `900_resign`
prints `'Re-signed … '`; 260 is the sole file-number-anchored style. Real but
cosmetic, low-confidence (the auditor itself notes it is defensible because an
everytime script does several unrelated tasks with no single proc to anchor to).
Kept (not a false positive) but lowest priority. **Fix:** re-prefix the four PRINTs
with an object anchor, e.g. `'! Maintenance operator [RoboticoOps-Maint] created.'`

## Eliminated / merged

- **plan-and-api-B1-1** — not eliminated; **merged into F5** (same underlying
  IndexOptimize-liveness ↔ bUpdateStatistics=0 coupling as L-B1-3, flagged from the
  plan/api angle). Counted once. (eliminated_count = 1)
- **No false positives.** The `DATEDIFF(HOUR)` out-of-scope note in
  audit-plan-and-api ("documented, accepted behaviour, not a defect") is superseded
  by the logic audit's F3 analysis: the runbook's "bump nLogMaxHours to 2" masks but
  does not fix the boundary artefact, and the sibling liveness proc proves the
  elapsed-time pattern is the intended one — so F3 is kept as a real bug, not
  dismissed as accepted behaviour.

## Cross-cut patterns

- **File clustering — spCheckMaintenanceLiveness.sql** carries F4 and F5 (both
  liveness-grace/coupling concerns) and is the *correct* reference pattern F3 should
  copy (its DATEADD cutoff). A fixer touching liveness should weigh F4+F5 together.
- **Convention drift is isolated, not systemic:** F1 (German comments) and F6 (PRINT
  anchor) are the only two convention deviations and each is confined to a single new
  file — no repo-wide pattern to sweep.
- **Two Important fixes (F3, F6-adjacent none) are mechanical + plan-touching:** F1
  and F2 are pure mechanical fixes; F3 additionally needs a plan §AC5 edit
  (plan-deviation routing).
