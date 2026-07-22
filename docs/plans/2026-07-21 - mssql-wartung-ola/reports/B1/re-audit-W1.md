# B1 Re-Audit — Repair Wave 1

**Date:** 2026-07-22T21:57:00+02:00 · **Block:** B1 · **Mode:** re-audit
**Repair commit:** `2a420d6878f84bf76557aa5e623f51d6254037a7` ([B1] repair wave 1)
**Input:** 6 findings the wave was meant to fix → **5 resolved (dropped), 1 kept (re-classified)**

## Verdict

The wave resolved five of six findings cleanly and introduced no new problems. The
sixth (convention-B1-1, German comments in `up/0023`) was **deliberately not fixed** and
correctly escalated: a comment-only edit is impossible without breaking one-time-script
immutability, so it now needs a human/orchestrator decision rather than another code fix.
It is kept and **re-classified green → yellow** (research/decision required), because the
originally-assumed mechanical fix has been proven unsafe.

## Resolved (dropped)

### F2 — T-1 — RESOLVED

`validate_rollout.sql` now carries a named `expected` CTE of the six canonical
`cJobKey`/`cDisplayName` pairs and flags any missing from `ops.tMaintenanceJob` via
LEFT JOIN — mirroring the reset-step block (L54–75) as requested. **Verified the six
display names match the SSoT exactly** (`spApplyMaintenance` MERGE VALUES, L42–47:
`RoboticoOps - Maint - checkdb`, `… - index-optimize`, `… - cleanup-commandlog`,
`… - cleanup-backuphistory`, `… - cleanup-jobhistory`, `… - backup-watchdog`). The
per-row job/wiring loop below is unchanged. Append-only, no regression.

### F3 — L-B1-1 — RESOLVED

`spCheckBackupChain` L77/L92 replaced `DATEDIFF(HOUR, lastBackup, @dNow) >= threshold`
with the elapsed-time cutoff `dLast <= DATEADD(HOUR, -threshold, @dNow)` for both full
and log (NULL still alarms), matching the sibling liveness proc. A four-line comment
explains why DATEDIFF(HOUR) was wrong. **Plan §AC5 was correspondingly corrected**
(the DATEDIFF formula in the plan text is now the DATEADD elapsed-cutoff formula), so the
plan-deviation routing is closed with SSoT and code in sync.

### F4 — L-B1-2 — RESOLVED

`spCheckMaintenanceLiveness` now gates on a first-run grace: `j.dModified <=
DATEADD(HOUR, -w.nWindowHours, @dNowUtc)` skips any row enabled for less than one
schedule window, so a freshly-enabled/newly-created job cannot false-fire 51105 before
its first scheduled run. The window is DRY'd into a `CROSS APPLY` and reused by both the
grace floor and the CommandLog staleness floor. The dModified anchor is the correct
choice (value-guarded MERGE bumps it on the `bEnabled 0→1` flip but leaves it on no-op
deploys, so long-running jobs keep being watched). The deliberate two-clock split
(`@dNowUtc` for UTC dModified, `@dNow` for local CommandLog.StartTime) is documented in a
new gotcha comment. Verified correct.

### F5 — L-B1-3 ∪ plan-and-api-B1-1 — RESOLVED

The assigned fix option was "document the coupling", which was done in all three surfaces:
`spCheckMaintenanceLiveness` header (stats-off IndexOptimize is a documented liveness
blind spot, revisit before enabling), the `spRunMaintenanceJob` stats-off branch (NB
comment), and `MSSQL-OPS-DATA-MODEL.md` (`bUpdateStatistics` and `dModified` rows both
gained the liveness dependency). No live impact today (sole seed row is
`bUpdateStatistics=1`); the latent coupling is now visible to whoever adds a stats-off row.

### F6 — convention-B1-2 — RESOLVED

`permissions/260` — all four PRINTs re-prefixed from the file-number anchor (`260:` /
`! 260:`) to object anchors (`Created SQL-Agent operator [RoboticoOps-Maint].`,
`! Database-Mail profile …`, `! Agent mail profile set …`, `! maint.spEnsureMaintenanceJobs
missing …`), matching the repo convention (`200_`, `250_`, `100_`, `900_`).

## Kept (re-classified)

### F1 — convention-B1-1 — Important → **yellow** (research: `up-0023-immutable-german-comments`)

**Not resolved — deliberately skipped, correctly escalated.** `up/0023` still carries 19
German markers (header L18–20, table comments L25–26, L36…); the repair-W1-1 agent edited
then reverted it. The skip is well-founded and verified: `up/0023` was applied to **test1
on 2026-07-22 20:04:59** (`RoboticoOps.ops.ScriptsRun`), so it is now an immutable
one-time script. A comment-only re-hash would (a) make the next global grate deploy error
and stop (deploy.ps1 runs without `--warn-on-one-time-script-changes`, the QG3-C1 incident
shape) and (b) hard-ERROR the lint gate (`lint-migrations.ps1` rule i), whose acknowledge
hatch `$upEditAcknowledged` is gated on the script "provably never applied anywhere" —
now verifiably false.

**Why re-classified:** the original consolidation assumed a green mechanical
comment-translation fix. That fix is now proven unsafe. The residual decision — accept the
German comments as a frozen historical artifact (recommended, zero risk) **vs.** a
deliberate deploy-tooling action (deploy once with `--warn-on-one-time-script-changes` or a
controlled test1 rebaseline, plus a truthful `$upEditAcknowledged` entry) — is an
architectural/operational decision, not a fixer edit. Yellow routes it to a decision-maker
instead of back to a code-fixer who would only skip it again (loop risk).

## New problems introduced by the wave

None. The liveness rewrite preserves the weekly window (previous `DATEADD(DAY,-8)` = 192 h
= new `nWindowHours=192`), keeps the hourly defensive branch unreachable (BackupWatchdog is
not in the IntegrityCheck/IndexOptimize filter), and the added grace clause is a strict
narrowing (fewer false alarms, no new blind spot beyond the documented F5 one). All added
comments are English. `up/0023` working tree is clean (edit fully reverted).
