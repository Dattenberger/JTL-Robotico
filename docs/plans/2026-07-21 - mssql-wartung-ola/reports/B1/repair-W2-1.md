# Repair Wave 2 — `convention-B1-1` (up/0023 German comments)

**Date:** 2026-07-22T21:57:00+02:00
**Finding:** `convention-B1-1` [yellow / Important] — `up/0023_maintenance_registry.sql` carries
German comments, violating the English-comment convention.
**Resolution:** RESOLVED as won't-fix-in-place + recurrence-prevention (research-directed).

## What the finding really is

Research (`research/up-0023-immutable-german-comments.md`) established the decision: `up/0023` was
**already applied to test1** (grate ledger `ops.ScriptsRun`, 2026-07-22 20:04:59), making it an
immutable one-time script. Any byte change (a comment-only translation) re-hashes it and would
(a) ERROR the next `deploy.ps1 -Scope global` (grate hash mismatch; no `--warn-on-one-time-script-changes`
in the invocation) and (b) ERROR lint rule (i), whose acknowledge hatch requires the script to be
provably never-applied — now false. Two conventions collide: **English comments (soft *should*)** vs.
**up/ immutable-once-applied (hard, tooling-enforced *must*)**. On an already-applied file, the *must*
wins. So 0023 must not be edited; its German comments are a permanent, documented exception.

## What I did (per research Implementation Hints, items 1–3)

### Item 1 — Leave 0023 verbatim
No edit. Verified `git status --porcelain -- db-migrations/global/up/0023*` is empty (clean/committed).
Not one byte changed.

### Item 2 — Record the exception (durable in-repo marker)
Documented the frozen exception in `db-migrations/README.md` §4 as part of the new rule (m): both
grandfathered files named with their applied dates and the reason (immutable ⇒ uncorrectable by a new
`NNNN_` script ⇒ convention permanently waived). The same set is encoded in the lint's
`$germanCommentGrandfathered` with per-entry applied-date comments. Deliberately did **not** add 0023
to `$upEditAcknowledged` — that map is the different "edit to a never-applied script" axis and its
precondition is false here.

### Item 3 — Recurrence prevention (the sustainable D4 fix)
Root cause: no lint rule checked comment language, so a German `up/` script reached apply. Added lint
**rule (m)** to `db-migrations/tests/lint-migrations.ps1`:
- New `Get-SqlCommentText` helper (inverse of `Remove-SqlComments`) extracts only comment text, so
  German *data* in string literals (`N'…'`) is not flagged — only comment language.
- Rule (m) ERRORs on German umlauts `[äöüßÄÖÜ]` in the comments of a `one-time` (`up/`) script.
  Umlaut detection is zero-false-positive (no English/SQL token carries them) — chosen over a
  German-stopword heuristic, which would false-positive on English/SQL and need constant tuning.
- Grandfather set (verified applied via grate ledgers): `eazybusiness/up/0002_robotico_paypal_tables.sql`
  (Robotico.ScriptsRun, 2026-07-13) and `global/up/0023_maintenance_registry.sql` (2026-07-22). These
  are the only applied `up/` scripts whose comments contain umlauts; both immutable, both grandfathered.
- `.SYNOPSIS`/`.DESCRIPTION` rule range updated `(a)-(l)` → `(a)-(m)`; README §4 gains the rule (m) entry.

This converts the English-comment convention from an unenforced *should* into a gate that stops the
**next** German `up/` script *before* apply — the one window in which it is still fixable.

**Scope discipline:** `eazybusiness/up/0003_drop_paypal_mechanic.sql` is staged-new (untracked, NOT in
the ledger) and umlaut-free — correctly **not** grandfathered; if it ever gains German comments it must
be fixed in place (belongs to the PayPal-removal work, out of this finding's scope). The pre-existing
`0001` German script has 0 umlauts, so rule (m) does not catch it and it needs no grandfathering.

## Verification
- Full lint green: `pwsh db-migrations/tests/lint-migrations.ps1` → **OK: 0 errors, 2 warning(s)**
  (both warnings are pre-existing rule-g heuristics on `reset.spInternal_GrantAccess.sql`, unrelated).
- Red-test: a temporary `0099_ruleM_probe.sql` with German comments produced
  `ERROR [m] … (7 umlaut/ß marker(s))` and `FAIL: 1 error(s)`; removed after the test — no residue.
- 0023 confirmed clean/verbatim after all work.

## Skipped
None.

## New issues discovered (not fixed — out of scope, logged for re-audit)
- `eazybusiness/up/0003_drop_paypal_mechanic.sql` is staged-new and English-clean today, but it is the
  one un-applied `up/` script in flight; if PayPal-removal work adds German comments to it, rule (m)
  will (correctly) block it — the fix then is to write English, not to grandfather. No action now.

## Files modified
- `db-migrations/tests/lint-migrations.ps1` — new `Get-SqlCommentText` helper, `$germanCommentGrandfathered`
  set, rule (m) check, docstring rule-range bump.
- `db-migrations/README.md` — §4 rule (m) entry documenting the gate + the two frozen exceptions.

## Drift (files outside the finding's named file)
The finding named `db-migrations/global/up/0023_maintenance_registry.sql`; per research the resolution is
explicitly *not to touch it*. The applied edits land in `lint-migrations.ps1` + `README.md` instead —
research-directed recurrence-prevention (item 3) and exception-recording (item 2), which are the
sanctioned resolution of this yellow finding. No other files touched.
