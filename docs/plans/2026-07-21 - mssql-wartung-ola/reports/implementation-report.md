# Implementation Report — mssql-wartung-ola

**Date:** 2026-07-23 · **Plan:** [→ mssql-wartung-ola.md](../mssql-wartung-ola.md) · **Aggregator:** Phase 4.7 (read-only)
**Run shape:** 1 Block (B1) · 1 Chunk (C1, user-fixed) · 1 audit round · 2 repair waves · E2E 13/13 PASS
**Impl agent:** fable-low · **planStartCommit:** `d722993` → **HEAD:** `3c579be`

## Counters

| Metric | Value |
|---|---|
| Blocks / Chunks / Waves | 1 / 1 / 2 repair waves (W1: 4 fixers, W2: 1 fixer) |
| Commits (plan-start..HEAD) | 5 — `923b6c7` impl · `217314a` self-fix (0 fixes) · `2a420d6` repair W1 · `fc508ad` repair W2 · `3c579be` docs |
| Audit findings | 7 raw → **6 validated** (1 merged, 0 false positives) |
| Findings resolved / open | 6 / 0 (all dropped by re-audit W2; convergence reached) |
| Deviations (documented) | 6 (all defensible D4 calls, none silent) |
| E2E | 13/13 auto PASS · 0 issues · 0 escalations |
| Research files produced | 3 (repair-wave-driven) |
| Docs | 1 updated (ARCHITECTURE) · 5 verified no-change · 8 inline-anchor files verified |
| Classified: 🔴 / 🟠 / 🟢 | 2 / 8 / 5 |

**Overall:** the block passed four internal/external review passes (impl self-check → fresh-eyes self-fix → 4-topic block audit → 2 re-audits) plus a full live E2E on test1, and converged clean. No Critical issue, no user escalation, no repair wave with ≥5-file drift, no re-audit that surfaced a new issue. The two 🔴 items below are **operational/ownership** follow-ups, not code defects.

---

## 🔴 needs-research

### R1 — Delegated issue I1: ownerless Legacy-Ola on test1 `eazybusiness.dbo`

- **Source:** C1-impl (issue I1, delegated) · E2E TC-2 · **Severity:** Nice-to-have, but **open with no owner**
- **What:** test1's `eazybusiness.dbo` still carries the 2024-06-24 Legacy-Ola install (CommandLog, DatabaseBackup, DatabaseIntegrityCheck). AC2 holds — our chain created **none** of these (our Ola-4 live in `RoboticoOps.dbo`, create_date 2026-07-22). Prod removal is the B6 Phase-4a runbook step, but **test1 has no cleanup owner** and B6 is out of this run's scope.
- **To verify / decide:** who removes the test1 legacy objects (or is the residue acceptable indefinitely)? It does not affect the maintenance suite; it is a hygiene loose end on the test estate. Not code-fixable from this run.

### R2 — Teardown caveat: SQL-Agent left Running on test1 (baseline not restored)

- **Source:** state file `teardown_caveat` · E2E-report §Teardown · **Severity:** operational, design-mitigated
- **What:** the planned Stopped-baseline teardown could **not** be executed — `xp_servicecontrol STOP` fails with "access denied" (error 5): the Kerberos SQL login is sysadmin in SQL but has no Windows service-control rights. The agent was already Running before the session (needed for reset work) and was left Running.
- **Why it is folgenlos:** the durable schedule guard hangs on the `MaintenanceSchedulesEnabled = '0'` switch (D34), **not** on the agent's service status — with the switch at `'0'` no maintenance job fires even while the agent runs (exactly the switch's purpose, so the shared agent stays available for reset work). `validate_rollout` asserts the D34 equation and is green.
- **To verify:** if a Stopped-baseline is desired on test1, it is a manual step for someone with Windows/service rights. Otherwise no action — the switch is the load-bearing safeguard.

---

## 🟠 review-recommended

### O1 — F3 (L-B1-1): backup-chain age test was a boundary bug; fixed **with a plan §AC5 correction** (plan-deviation)

- **Source:** audit-logic L-B1-1 (Important) → repair-W1-3 · **Commit:** `2a420d6`
- `maint.spCheckBackupChain` used `DATEDIFF(HOUR, lastBackup, @dNow) >= threshold`, which counts clock-hour **boundaries crossed**, not elapsed hours. With the seeded `nLogMaxHours = 1`, hourly CBB log backups and the hourly watchdog, a log backup minutes old but in the previous clock-hour scored `1 >= 1` → recurrent false `THROW 51100` on the production ERP DB (the exact "cry-wolf" failure the design fights). Fixed to `dLast <= DATEADD(HOUR, -threshold, @dNow)` (NULL still alarms), mirroring the sibling liveness proc.
- **Why review-worthy:** the plan literally prescribed the flawed formula in **§AC5**, so the plan text was corrected in lockstep (`mssql-wartung-ola.md` §AC5, line 42) — a genuine plan-deviation, not a silent inline change. Verify the AC5 edit reads as intended.

### O2 — convention-B1-1 / up-0023: permanent convention waiver + new lint gate (2-wave, architecture decision)

- **Source:** audit-convention convention-B1-1 (Important) → repair-W1-1 (skipped+escalated) → repair-W2-1 (resolved) · **Commit:** `fc508ad` · **Research:** `research/up-0023-immutable-german-comments.md`
- `up/0023_maintenance_registry.sql` carries ~19 German comment markers in an otherwise all-English `up/` chain. It was **already applied to test1** (grate ledger `ops.ScriptsRun`, 2026-07-22 20:04:59), so any comment-only re-hash would (a) ERROR the next `deploy.ps1 -Scope global` (no `--warn-on-one-time-script-changes`) and (b) hard-ERROR lint rule (i). Immutability (hard *must*) beats English-comments (soft *should*) → resolved **won't-fix-in-place**.
- **What was actually changed instead of 0023:** new lint **rule (m)** (`Get-SqlCommentText` helper + umlaut detection on `up/` comments) added to `lint-migrations.ps1`; a `$germanCommentGrandfathered` set (0002 + 0023, both applied); README §4 rule (m) documenting the two frozen exceptions. This converts an unenforced convention into a gate that stops the **next** German `up/` script before apply.
- **Why review-worthy:** a repo convention was permanently waived for an applied file and a new lint rule + grandfather set was introduced — an architecture/tooling decision worth a conscious sign-off. Spanned two repair waves (W1 correctly skipped it, re-classified green→yellow; W2 resolved it via the recommended zero-risk option).

### O3 — F4 (L-B1-2): liveness first-run-grace — real behavioral change to the watchdog

- **Source:** audit-logic L-B1-2 (Nice-to-have) → repair-W1-1 · **Commit:** `2a420d6` · **Research:** `research/liveness-first-run-grace.md`
- `spCheckMaintenanceLiveness` false-fired `THROW 51105` for a freshly-enabled/first-created job with no `CommandLog` history yet (e.g. enabled 10:00, next run 02:00 → ~16 h of hourly false alarms; empty at go-live). Fix adds a grace predicate `j.dModified <= DATEADD(HOUR, -w.nWindowHours, @dNowUtc)`, a `CROSS APPLY` deriving the schedule window once (DRY, drives both grace + staleness floor), and a **second UTC clock** (`@dNowUtc`) because `dModified` is stored UTC while `CommandLog.StartTime` is local (documented two-clock gotcha).
- **Why review-worthy:** not a mechanical fix — it changes when the watchdog stays silent (validated live in E2E TC-8, first-run-grace confirmed). The `dModified` anchor was chosen because the value-guarded MERGE bumps it on the `bEnabled 0→1` flip but not on no-op deploys.

### O4 — F5 (L-B1-3 ∪ plan-and-api-B1-1): latent IndexOptimize liveness coupling (doc-only resolution)

- **Source:** audit-logic L-B1-3 + audit-plan-and-api plan-and-api-B1-1 (merged, Nice-to-have) → repair-W1-1 · **Commit:** `2a420d6` · **Research:** `research/indexoptimize-liveness-heartbeat.md`
- Liveness treats an IndexOptimize run "alive" only if an `ALTER_INDEX` **or** `UPDATE_STATISTICS` CommandLog row exists in-window. `up/0023` permits `bUpdateStatistics = 0` (D33), and on a low-churn night such a row logs neither → false `51105`. **Latent** — the sole seed row is `bUpdateStatistics = 1`. Resolved by **documenting the coupling** at three surfaces (liveness header, spRunMaintenanceJob stats-off branch NB, DATA-MODEL `bUpdateStatistics`/`dModified` rows); no behavior change.
- **Why review-worthy:** a future maintainer adding a stats-off IndexOptimize row must revisit the liveness scan; the guard is documentation, not code enforcement.

### O5 — Six documented impl deviations (all defensible, verified)

- **Source:** C1-impl §Deviations, confirmed by C1-selffix + audit-plan-and-api
1. **Ola version pin = master snapshot** `20260722_200334` (GitHub releases API unavailable; version stamp embedded per-proc, verifiable from the file).
2. **3 byte-breaks in vendored files** — dashed date literals `'1900-01-01'` → `'19000101'` (3 sites), CRLF→LF, BOM stripped; the plan's sanctioned VENDOR-DEVIATION mechanism (lint rule h).
3. **IndexOptimize pins `@FragmentationMedium` too** — Ola's Medium default includes `INDEX_REBUILD_OFFLINE`; pinning only High (per plan shorthand) would leave an offline-rebuild path open. Audit confirmed this **necessary** (closes a real D13 hole).
4. **260 uses `xp_instance_regread/-write`** for the agent mail profile — `sp_set_sqlagent_properties` has no supported mail-profile parameter; registry keys are the standard mechanism.
5. **FT-13 CommandLog wrapper not needed** — pinned upstream already guards it with `IF NOT EXISTS`; the plan's assumption was outdated.
6. **ARCHITECTURE §6 renumber** — new §6.5/§6.6 inserted; former §6.5 became §6.7 (no inbound refs to the old number).

### O6 — ADR promotion pending → link rewrites owed at plan closure

- **Source:** docs-discovery §6 · docs-final §Flagged #1 · state file `flagged: 1`
- Two plan-scoped ADRs (`adr-maintenance-as-code-roboticoops` = ADR-A, `adr-backups-cbb-retained` = ADR-B) are still `Proposed (plan-scoped)`; this repo has **no `docs/decisions/` yet** (promotion establishes it). At closure they must be promoted to `docs/decisions/NNNN-…` and the qualifiers dropped; **link sites to rewrite:** ARCHITECTURE frontmatter `related-adrs` + §8 (both the 2 new and the 4 older mssql-ops ADRs), NAMING §9 symbolic `ADR-A §D-A2`, and the **8 `@see` ADR anchors** in the new SQL files. Plan §6 also declares two promotion-time follow-ups: a Decision-History back-ref on `adr-ebene-b-hungarian-naming` (D20 `t`=time), and a "Subsystems" table in `CLAUDE.md`.

### O7 — F2 (T-1): rollout gate hardened against a silently-empty registry

- **Source:** audit-test T-1 (Important) → repair-W1-2 · **Commit:** `2a420d6`
- `validate_rollout.sql`'s maint block drove its loop `FROM ops.tMaintenanceJob` and never asserted the six canonical seed rows exist — an empty/partial registry iterated zero rows and still reported OK (the exact F3/F4 "job silently not there" failure the plan fights), asymmetric with the sibling reset-step block. Fixed with a named `expected` CTE of the six `cJobKey`/`cDisplayName` pairs (SSoT = spApplyMaintenance MERGE). Low live probability (MERGE seeds all six every deploy) but restores the convention. Listed here (not 🟢) because it closes a real defense-in-depth gap.

### O8 — Two environment drifts on test1 (E2E-adapted, no code change)

- **Source:** e2e-report §Drift-Research
1. **test1 has a real backup regime** but only `is_copy_only=1` fulls and **no** log backups (eazybusiness/master/msdb SIMPLE, only RoboticoOps FULL). Prereq-2 isolation check was sharpened to exclude NUL-device + copy_only so `BACKUP … TO NUL` stays folgenlos. (Same fact as R1's sibling.)
2. **test1 carries the Legacy-Ola install** (see R1) — TC-2 was sharpened to a provenance proof rather than failing blindly.

---

## 🟢 informational (fully resolved / mechanical)

- **convention-B1-2 (260 PRINT anchor):** four PRINTs re-prefixed from file-number (`260:`) to object anchors, matching `200_/250_/100_/900_`. Cosmetic, no behavior change. Wave 1 (`2a420d6`).
- **C1 impl self-check inline fixes:** duplicated deviation comment in 0022, stray CJK character in a spCheckBackupChain comment, ARCHITECTURE numbering conflict — all fixed before commit `923b6c7`.
- **C1 self-fix:** fresh-eyes review of the full diff, all gates re-run, **0 edits required** (`217314a`).
- **Docs:** ARCHITECTURE gained the two navigable ADR-A/ADR-B links (frontmatter + §8) that inline labels previously dangled at — the single doc edit (`3c579be`); DATA-MODEL, NAMING, README, rollout-runbook + 8 inline-anchor files all `no-change-needed` (docs authored inline during impl). 0 cross-doc contradictions.
- **Lint / gates:** `npm run db:lint` green throughout (0 errors; the only 2 warnings are pre-existing in the untouched `reset.spInternal_GrantAccess.sql`). `validate_structure` + `validate_rollout` green on test1 with switch `'0'`.

---

## Full issue list (chronological, all sources)

| # | ID | Source | Severity | Status | Commit | Classified |
|---|---|---|---|---|---|---|
| 1 | I1 | C1-impl (delegated) | Nice-to-have | **open, ownerless** | — | 🔴 R1 |
| 2 | — | C1 impl self-check | — | fixed inline (3×) | 923b6c7 | 🟢 |
| 3 | — | C1 self-fix | — | 0 fixes | 217314a | 🟢 |
| 4 | plan-and-api-B1-1 | audit-plan-and-api | Nice-to-have | merged into F5 | 2a420d6 | 🟠 O4 |
| 5 | convention-B1-1 (F1) | audit-convention | Important | resolved (won't-fix + gate), 2 waves | fc508ad | 🟠 O2 |
| 6 | convention-B1-2 (F6) | audit-convention | Nice-to-have | resolved | 2a420d6 | 🟢 |
| 7 | L-B1-1 (F3) | audit-logic | Important | resolved (+plan §AC5) | 2a420d6 | 🟠 O1 |
| 8 | L-B1-2 (F4) | audit-logic | Nice-to-have | resolved (query change) | 2a420d6 | 🟠 O3 |
| 9 | L-B1-3 (F5) | audit-logic | Nice-to-have | resolved (doc-only) | 2a420d6 | 🟠 O4 |
| 10 | T-1 (F2) | audit-test | Important | resolved | 2a420d6 | 🟠 O7 |
| 11 | teardown caveat | E2E / state | operational | not executable (design-mitigated) | — | 🔴 R2 |

E2E: 0 issues across 13 cases.

## Full drift list (deviations + wave drift)

| Origin | Files outside named scope | Nature | Sanctioned? |
|---|---|---|---|
| repair-W1-1 | `docs/SQL/MSSQL-OPS-DATA-MODEL.md` (2 rows) | doc update for L-B1-3/L-B1-2 coupling | yes — L-B1-3 fix explicitly names the DATA-MODEL contract; CLAUDE.md same-commit doc rule |
| repair-W2-1 | `lint-migrations.ps1` + `db-migrations/README.md` (instead of `up/0023`) | recurrence-prevention gate + exception record | yes — research-directed; 0023 deliberately untouched |
| C1 impl | none | 6 plan↔impl deviations (see O5) | yes — all documented, none silent |

No wave had ≥1-file **unsanctioned** drift; no source/test code touched outside assigned scope. Pre-existing PayPal-removal changes in the worktree were never included in any maintenance commit (file-scoped commits throughout).

## Full fix list by family

- **inline-impl (self-check, in `923b6c7`):** duplicated deviation comment (0022), stray CJK char (spCheckBackupChain), ARCHITECTURE numbering.
- **self-fix (`217314a`):** none (0 fixes).
- **mid-repair:** none (no mid-chunk triage; single chunk).
- **block-repair wave 1 (`2a420d6`, 5 fixes / 1 skip):** F2 rollout expected-CTE · F3 backup-chain DATEADD + plan §AC5 · F4 liveness first-run-grace · F5 IndexOptimize coupling docs · F6 260 PRINT anchors. Skipped: convention-B1-1 (escalated).
- **block-repair wave 2 (`fc508ad`, 1 fix):** convention-B1-1 resolution — lint rule (m) + `Get-SqlCommentText` helper + grandfather set + README §4 entry.
- **integration-repair:** n/a (1 block).
- **e2e-repair:** none (13/13 first pass).
- **docs (`3c579be`):** ARCHITECTURE dangling ADR-A/ADR-B reference completed (frontmatter + §8).

## Research files produced

| File | Trigger | Outcome |
|---|---|---|
| `research/liveness-first-run-grace.md` | L-B1-2 (F4) | chose `dModified`-anchored grace (rejected alternatives documented) → query change applied |
| `research/indexoptimize-liveness-heartbeat.md` | L-B1-3 ∪ plan-and-api-B1-1 (F5) | chose fix A (visibility/doc-only over machinery); optional heartbeat escalation left as future team/ADR decision |
| `research/up-0023-immutable-german-comments.md` | convention-B1-1 (F1) | immutability beats English-comments; won't-fix + lint rule (m) recurrence-prevention |

All three are Research genre (no `## Specification`) — not spec-conversion candidates.

## Block timeline

```
923b6c7  C1 impl+test (B1–B5), full live B5 checklist on test1, 6 deviations, I1 delegated
217314a  C1 self-fix — fresh-eyes, 0 fixes
   ↓     4-topic block audit (plan-and-api / convention / logic / test): 7 raw findings
   ↓     consolidation → 6 validated (1 merged, 0 false positives)
2a420d6  repair wave 1 — 5 fixes applied, convention-B1-1 skipped+escalated
   ↓     re-audit W1 — 5 dropped, convention-B1-1 kept & re-classified green→yellow
fc508ad  repair wave 2 — convention-B1-1 resolved (Option 1, zero-risk)
   ↓     re-audit W2 — CONVERGED, 0 remaining, 0 introduced
   ↓     wave-verify — CLEAN (all 15 files in HEAD, lint exit 0)
   ↓     E2E — 13/13 auto PASS on test1, 0 issues, 0 escalations
3c579be  documentation update — 1 doc edit, 5 no-change, 8 inline anchors verified
```

## Eliminated audit findings (audit of the audit)

- **7 raw → 6 validated.** `plan-and-api-B1-1` **merged** into F5 (same IndexOptimize-liveness ↔ `bUpdateStatistics=0` coupling from the plan/api angle; counted once). `eliminated_count = 1` (merge).
- **0 false positives.** Notably the audit-plan-and-api out-of-scope note calling the DATEDIFF behavior "documented/accepted" was **overruled** by the logic audit's F3: the runbook's "bump nLogMaxHours to 2" only masks the boundary artefact, and the sibling liveness proc proves the elapsed-time pattern is the intended one → F3 kept as a real bug (correctly).
- Re-audit W1 dropped 5, kept 1 (re-classified). Re-audit W2 dropped the last → convergence, no new issues introduced by either wave.

## Source coverage (self-check)

All report files under `reports/` were read: C1-impl, C1-selffix, the 4 B1 audits, validated-findings, repair-W1-1..4, repair-W2-1, re-audit-W1, re-audit-W2, wave-verify, e2e-report, e2e-runbook, docs-discovery, docs-final, the 6 docs-worker/inline reports; plus the 3 `research/*.md` and the state file. No report left unaccounted. Counters are consistent between this header and the full lists.
