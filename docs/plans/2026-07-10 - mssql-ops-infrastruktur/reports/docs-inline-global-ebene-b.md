# Inline-Anchor Worker Report — `global-ebene-b`

**Date:** 2026-07-10T02:45:00+02:00
**Scope:** 5 Ebene-B / `db-migrations/global/` source files (permissions + `up/` scripts)
**Outcome:** no-change-needed (all three anchors already correct after C2 impl commit `ff9141c`)

## What I did

Verified the three sanctioned inline anchors (module header / `@see` plan-ADR / gotcha)
against the plan (`§2 — RoboticoOps-DB + globale Kette (Ebene B)`), the research doc, and
the file diffs for the five assigned files. All anchors are present, resolve, and carry
no restate-the-code noise. **No source edits applied** — the anchors are already correct.

## Stale discovery-inventory finding

The discovery report (`docs-discovery.md` §Inline-anchor inventory) states these five files
"have `@see` but **no module header block** — add a one-line header." This is **stale**: the
C2 implementation commit `ff9141c` (the only commit touching these files since plan start)
gave every one of them a full multi-line module header. The gap the discovery flagged is
already closed. Nothing to add.

## Per-file verification

| File | Module header | `@see` anchors | Gotcha comments | Action |
|---|---|---|---|---|
| `permissions/100_grants.sql` | Present (responsibility + 2 bullets, L1–10) | `(§2)` → resolves | AD-group guard rationale (PRINT-not-fail) | none |
| `up/0003_roles.sql` | Present (both roles + membership-is-data invariant, L1–13) | `(§2)` → resolves | column-level DENY = defense-in-depth (L30–32) | none |
| `up/0010_jobstartuser_login.sql` | Present (3 principals + SQLAgentOperatorRole "why", L1–21) | `(§2)` + `research/3-module-signing-agent-job` → both resolve | CSPRNG/`CHECK_POLICY OFF` + CONCAT-lint gotchas | none |
| `up/0011_signing_certificate.sql` | Present (3-step hybrid recipe, token-not-in-git, L1–18) | `(§2)` + `research/3-module-signing-agent-job` → both resolve | `CONVERT` style-1 + CONCAT-lint gotchas | none |
| `up/0020_seed_mandant_template.sql` | Present (seed intent + secrets-never-in-git, L1–21) | `(§2)` → resolves | `{{ShopLicense}}`-vs-grate-token deviation NOTE | none |

## Anchor-target resolution checks

- `docs/plans/2026-07-10 - mssql-ops-infrastruktur (§2)` — plan §2 exists and is exactly the
  Ebene-B / global-chain section these files implement. Correct for all five.
- `docs/plans/2026-07-10 - mssql-ops-infrastruktur/research/3-module-signing-agent-job` —
  directory exists, holds the single `3-module-signing-agent-job.md`. This directory form is
  used identically by every sibling in `db-migrations/global/` (`up/0002`,
  `sprocs/reset.internal_PostRestoreSecurity`). **Kept as-is** for cross-file consistency —
  sharpening only these two to the `.md` file would diverge from the established local
  convention for no reader benefit.

## Comment-noise scan

No comment restates code. The section-divider comments (`--- server login ---` etc.) are
navigational and stay; every WHY/gotcha comment carries non-derivable knowledge (lint
heuristic, disabled-login rationale, defense-in-depth DENY, grate-token collision). Nothing
removed.

## Self-check

Re-read all five files end to end: every `@see` path/section resolves, no code logic /
formatting / imports touched (zero edits), no TODO/FIXME introduced, no plan content
paraphrased. Findings list is empty as a considered verdict, not a skipped step.

## Notes for final

- Discovery inline-anchor inventory row for Ebene-B is stale (headers already present post-`ff9141c`); future doc passes can trust the files as-is.

## Files outside assigned scope (drift)

none
