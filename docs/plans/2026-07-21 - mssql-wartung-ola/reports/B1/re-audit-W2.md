# B1 Re-Audit — Repair Wave 2

**Date:** 2026-07-22T21:57:00+02:00 · **Block:** B1 · **Mode:** re-audit
**Repair commit:** `fc508ad8c1dfbc0c8e5b4e64e9b5da7b0bfce193` — `[B1] repair wave 2`
**Input:** 1 finding to verify (`convention-B1-1`, yellow/Important)
**Verdict:** CONVERGED — finding resolved, 0 introduced problems, 0 remaining.

## Finding verified

### `convention-B1-1` — up/0023 German comments — RESOLVED → dropped

**Original finding:** `up/0023_maintenance_registry.sql` carries 19 German comment
markers in an otherwise all-English `up/` chain (0001–0022 clean). Re-classified
green→yellow in wave 1 because research proved the naive mechanical translation
**unsafe**: 0023 was already applied to test1 (grate ledger `ops.ScriptsRun`,
2026-07-22 20:04:59), so any byte change re-hashes an immutable one-time script and
would (a) ERROR the next `deploy.ps1 -Scope global` (grate hash mismatch, no
`--warn-on-one-time-script-changes` in the invocation) and (b) ERROR lint rule (i),
whose `$upEditAcknowledged` hatch requires the script to be provably never-applied.
The finding therefore escalated to a human/orchestrator decision: **Option 1**
(recommended, zero-risk) accept + document the frozen exception; **Option 2** a
deliberate deploy-tooling re-hash action.

**How wave 2 resolved it (research-directed, Option 1 — the recommended zero-risk
path):**

1. **0023 left verbatim.** `git status --porcelain -- .../up/0023_*` is empty —
   not one byte changed. Confirmed the correct treatment of an immutable applied
   file (the *must* of up/-immutability wins over the *should* of English comments).
2. **Exception recorded durably** in two places:
   - `db-migrations/README.md` §4 new rule (m) entry names both frozen exceptions
     with applied dates + the reason (immutable ⇒ uncorrectable by a new `NNNN_`
     script ⇒ convention permanently waived).
   - lint `$germanCommentGrandfathered` set encodes the same two files with
     per-entry applied-date comments.
3. **Recurrence prevention (the sustainable D4 fix):** new lint **rule (m)** ERRORs
   on German umlauts `[äöüßÄÖÜ]` in the *comments* of any un-grandfathered `up/`
   script — catching the **next** German one-time script in the one window it is
   still fixable (before first apply). A new `Get-SqlCommentText` helper (inverse of
   `Remove-SqlComments`) restricts the check to comment text so legitimately-German
   `N'…'` string-literal data is never flagged.

**Validation performed this re-audit:**

| Check | Result |
|---|---|
| Full lint green | `OK: 0 errors, 2 warning(s)` — both warnings pre-existing rule-g heuristics on `reset.spInternal_GrantAccess.sql`, unrelated |
| Rule (m) integration | `$dirClass`/`$raw`/`$rel` all defined (L142/139/138) before use at L253; `'up' → 'one-time'` (L87) is the correct class string |
| 0023 verbatim | `git status --porcelain` empty; 19 umlaut markers present → would trip rule (m) if not grandfathered |
| Grandfather exclusion works | lint green **despite** 0023's 19 umlauts → the `$germanCommentGrandfathered` skip is what suppresses it (path-separator normalized via `$rel -replace '\\','/'`) |
| Both grandfathered files exist | `eazybusiness/up/0002_robotico_paypal_tables.sql`, `global/up/0023_maintenance_registry.sql` present |
| Red-test | temp `up/0099` probe with German comments → `ERROR [m] … (4 umlaut/ß marker(s))`, `FAIL: 1 error(s)`; probe removed, tree clean |

The actionable portion of the yellow finding is fully closed: the residual German
comments in 0023 are now a **sanctioned, documented, tooling-enforced exception**
rather than an unaddressed inconsistency, and the root cause (no lint gate on
comment language) is fixed. Dropped.

## New problems introduced by the wave

**None.** The lint change is clean and does not regress:

- `Get-SqlCommentText` line-comment extraction takes text from the first `--` in a
  line, so a `--` inside a string literal could in theory be read as a comment — but
  this is the *same* pragmatic string-literal-unaware stance as the existing
  `Remove-SqlComments`, is explicitly documented as a vanishingly-rare grandfatherable
  case, and is consistent with repo convention (not a new defect).
- Grandfather set is correctly closed to *already-applied* files (a NEW `up/` file
  must ship English comments) and normalizes Windows path separators.
- Scope discipline held: `eazybusiness/up/0003_drop_paypal_mechanic.sql` (staged-new,
  un-applied, umlaut-free) was correctly **not** grandfathered.

## Convergence

- Findings still needing a fix: **0** — converged.
- `eliminated_count = 1` — `convention-B1-1` resolved by the wave and dropped.
