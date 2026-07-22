# Research: up/0023 German comments vs. one-time-script immutability

**Date:** 2026-07-22T21:57:00+02:00
**Triggered by:** Repair finding `convention-B1-1` [Important] — `up/0023_maintenance_registry.sql`
carries ~19–25 German comment markers, violating the repo-wide English-comment convention.
Repair wave 1 correctly skipped + escalated (re-classified green→yellow: the residual is an
architectural/operational decision, not a mechanical fixer edit).
**Agent-ID:** repair-research (up-0023-immutable-german-comments)

## Problem in one line

`up/0023` should have English comments (all its sibling global `up/` scripts do), **but it was
already applied to test1**, and every sanctioned mechanism for changing an applied one-time
script is either forbidden here or cannot touch comments at all. The two conventions collide;
this note decides which wins and what the fix agent actually does.

## Sources

1. **`db-migrations/README.md` §2 CAUTION + §4 rule i** (lines 60–64, 147–151) — the immutability
   doctrine: "`up/` scripts are immutable after they have been applied **anywhere**. grate tracks
   them by content hash; editing an applied `up/` script makes grate fail with a hash mismatch…
   To correct an applied one-time script, add a **new** `up/` script with the next number." Rule i's
   escape hatch is explicitly "for a script that has provably never been applied."
2. **`db-migrations/tests/lint-migrations.ps1`** — rule (i) implementation (lines ~280–318) plus
   the `$upEditAcknowledged` map (lines 83–90). Editing a tracked `up/` file emits an **ERROR**
   ("tracked up/ script has uncommitted modifications … up/ scripts are immutable once applied");
   the acknowledge hatch downgrades to WARNING **only** for scripts that "have provably never been
   applied anywhere."
3. **`db-migrations/deploy.ps1`** — `$grateArgs` assembly (lines 409–427). The grate invocation
   carries `--connectionstring/--schema/--environment/--version/--silent` (+ `--transaction` for
   eazybusiness, `--baseline/--dryrun/--usertokens` conditionally). It does **NOT** pass
   `--warn-on-one-time-script-changes`, so grate's default (error + stop on a one-time hash change)
   applies. deploy.ps1's own docstring (line 13): "It applies changes only via grate — **no ad-hoc
   T-SQL**."
4. **Live query, RoboticoOps.ops.ScriptsRun on vm-sql-test1.zdbikes.local** (2026-07-22):
   `0023_maintenance_registry.sql | 2026-07-22 20:04:59.230 | hash YI/pHClE3a8lty4q1Tf3…` — the
   script is recorded as applied, with a content hash. The finding's factual premise is confirmed.
5. **`~/.claude/snippets/docs/language-conventions.md`** — "Code comments and identifiers: English."
   This is the convention `convention-B1-1` measures against.
6. **Plan `mssql-wartung-ola.md` D35 (line 362)** — the plan authors already state "`up/0023` ist
   nach dem Apply immutable" as a design premise (they even pulled the `hourly` schedule decision
   forward *because* the DDL freezes on apply). Post-apply editing was never in the plan's design.

## Findings

### 1. The finding is legitimate — 0023 is the outlier, not the rule

German-marker scan across all `up/` scripts (ä/ö/ü/ß + German stopword heuristic):

| Script | German markers |
|---|---|
| `global/up/0023_maintenance_registry.sql` | **25** (the finding) |
| `eazybusiness/up/0001_robotico_schema.sql` | 8 (pre-existing, already applied) |
| `eazybusiness/up/0002_robotico_paypal_tables.sql` | 4 (pre-existing) |
| `global/up/0021_reset_step_registry.sql` | 2 |
| `eazybusiness/up/0003_drop_paypal_mechanic.sql` | 2 (staged-new, **not** yet applied) |
| `global/up/0022_maintenance_ola_vendor.sql` … `0001` | **0** (English — the convention) |

The entire modern global chain (`0001`–`0022`) is English. `0023` is a fresh regression that
slipped to *apply* because no lint rule catches comment language.

### 2. The convention violation is structurally unfixable through the sanctioned path

- **Comments are source-only, and they are part of the hashed bytes.** grate hashes the whole file.
  So "just translate the comments" is a byte change → hash change on a one-time script.
- **The prescribed correction — "add a new `NNNN_` script" — cannot retro-edit an old file's
  comment text.** A new script can add/alter DDL; it cannot change what `0023`'s source says. There
  is no sanctioned operation that rewrites an applied one-time script's comments.

### 3. Every path that *would* change 0023's text is blocked or corrosive

| Path | Why it fails / harms |
|---|---|
| In-place edit, rely on lint `$upEditAcknowledged` hatch | The hatch's stated precondition is "provably never applied anywhere." `0023` **is** applied (Source 4). Using it here is a documented lie, and the WARNING it produces would ship a false record. |
| In-place edit + `LINT_ALLOW_UP_EDITS=1` | Same underlying problem; only silences lint, does nothing about grate. |
| In-place edit + clear/patch the test1 `ops.ScriptsRun` row so grate re-hashes | Requires **ad-hoc T-SQL** against the grate ledger — deploy.ps1 explicitly forbids this ("no ad-hoc T-SQL", Source 3). It also normalizes editing an applied one-time script, the exact QG3-C1 anti-pattern the guardrails exist to stop. Note README's immutability is "applied **anywhere**" — test1 counts; "it's only test1" does not exempt it. |
| Add `--warn-on-one-time-script-changes` to deploy.ps1 | Weakens the deploy for the whole chain, permanently, to launder one cosmetic edit. Directly reverses the QG3-C1 hardening. Net-negative. |
| Full test1 reset to drop the ledger, then edit + redeploy | Heavy operation for a comment change; still violates "immutable after applied anywhere"; still sets the "edit-if-only-on-test1" precedent that erodes the invariant. |

### 4. Convention precedence: immutability (must) beats English-comments (should)

Two repo conventions conflict on this file:
- **(A) English comments/identifiers** — a readability/hygiene convention, **zero runtime effect**.
- **(B) `up/` immutable once applied** — a **tooling-enforced, incident-backed invariant**
  (lint rule i ERROR + grate default error + README §2 CAUTION §4 rule i), protecting deploy
  integrity against a real incident class (QG3-C1).

When a soft *should* (A) collides with a hard, enforced *must* (B) **on a script that has already
been applied**, (B) wins. The plan itself already treats `0023` as frozen-on-apply (Source 6).
Therefore `0023` must not be edited; its German comments become a permanent, documented exception.

## Implementation Hints (concrete — for the fix agent)

**Primary decision: close `convention-B1-1` as won't-fix (immutability wins). Do NOT modify
`db-migrations/global/up/0023_maintenance_registry.sql` — not one byte.** Any edit re-hashes an
applied one-time script and (a) errors the next `deploy.ps1 -Scope global` (grate hash mismatch,
no `--warn-on-one-time-script-changes` present) and (b) errors lint rule i (the acknowledge hatch
is invalid — its "never applied" precondition is provably false: `ops.ScriptsRun` on test1,
2026-07-22 20:04:59). Verified live.

Do these three things instead:

1. **Leave 0023 verbatim.** Confirm `git status --porcelain -- db-migrations/global/up/0023*` is
   empty at the end (it must stay clean/committed).

2. **Record the exception so the next reader isn't puzzled.** Add one short note (no code change to
   0023). Recommended home: a one-line entry in the plan's implementation report / `## References`
   and, if a durable in-repo marker is wanted, a comment beside README §4 rule i, e.g.:
   "*Known frozen exception: `global/up/0023` carries German comments (authored 2026-07-22, applied
   to test1 same day). Immutability (§2 CAUTION) freezes it; comments cannot be corrected by a new
   `NNNN_` script, so the English-comment convention is waived for this one applied file.*"
   Do **not** put 0023 into `$upEditAcknowledged` — that map is a different axis (edit-acknowledgement
   for *never-applied* scripts) and its precondition is false here.

3. **Prevent recurrence — the actual sustainable fix (D4).** The root cause is that no lint rule
   catches non-English comments, so a German `up/` script reached apply. Add a **new lint rule**
   (next free letter, e.g. rule `m`) to `lint-migrations.ps1` that flags German-language markers
   (`[äöüßÄÖÜ]` and/or a small German-stopword set — reuse the `Remove-SqlComments`-stripped `$raw`
   comment text, i.e. run it on comments, not `$code`) in **`up/` scripts**, and **grandfather the
   already-applied German scripts** so it never retro-errors on files that cannot be fixed:

   ```powershell
   # Rule (m): up/ comments must be English. Already-applied German scripts are
   # grandfathered — they are immutable (§2 CAUTION) and therefore uncorrectable.
   $germanCommentGrandfathered = @(
       'db-migrations/global/up/0023_maintenance_registry.sql',
       'db-migrations/eazybusiness/up/0001_robotico_schema.sql',
       'db-migrations/eazybusiness/up/0002_robotico_paypal_tables.sql',
       'db-migrations/global/up/0021_reset_step_registry.sql'
   )
   ```
   Scope the check to `$dirClass -eq 'one-time'`, skip paths in the grandfather set, and emit an
   ERROR otherwise. This converts the English-comment convention from an unenforced "should" into a
   gate that stops the **next** German `up/` script *before* it is applied (while it is still
   freely editable) — which is exactly the window in which the convention is fixable. Membership of
   the grandfather set should be verified against `ops.ScriptsRun` / apply history by the fixer; the
   list above is the current applied-German set (note `eazybusiness/up/0003_drop_paypal_mechanic.sql`
   is staged-new and **not** yet applied, so it should be *fixed to English now*, not grandfathered —
   but that belongs to the PayPal-removal work, out of this finding's scope).

   Add the rule to README §4's rule list and, if a lint test fixture exists, a red/green case.

**Scope note for the fixer:** items 1–2 fully resolve `convention-B1-1`. Item 3 is the
recurrence-prevention that makes the resolution durable rather than a one-off shrug; implement it in
the same pass unless the orchestration scopes it out. Do not expand into re-translating the
pre-existing eazybusiness German scripts (0001/0002) — they are equally frozen; only staged-new,
never-applied scripts should be translated in place.

## References

- `db-migrations/README.md` §2 CAUTION (L60–64), §4 rule i (L147–151)
- `db-migrations/tests/lint-migrations.ps1` — rule (i) L280–318, `$upEditAcknowledged` L83–90
- `db-migrations/deploy.ps1` — `$grateArgs` L409–427 (no `--warn-on-one-time-script-changes`),
  docstring "no ad-hoc T-SQL" L13
- `db-migrations/global/up/0023_maintenance_registry.sql` (the frozen file)
- `~/.claude/snippets/docs/language-conventions.md` (English-comment convention)
- Plan `mssql-wartung-ola.md` D35 (L362) — "up/0023 ist nach dem Apply immutable"
- Live: `RoboticoOps.ops.ScriptsRun` on vm-sql-test1.zdbikes.local (0023 applied 2026-07-22 20:04:59)
