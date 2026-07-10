# Inline-Anchor Worker Report — peripheral-hygiene-legacy

**Date:** 2026-07-10T02:45:00+02:00
**Slug:** peripheral-hygiene-legacy
**Files:** `Berechtigungen/cleanup/01_dana_sysadmin_review.sql`,
`Berechtigungen/cleanup/03_premig_db.sql`,
`Projekte/Testsystem/setup-test-environment.ps1`

## Summary

All three files already carry complete, accurate inline anchors (added wholly within
`9592c99..HEAD` — the two SQL files are net-new, the PS1 gained a 17-line deprecation
banner). This worker **verified** them against the final post-repair code and plan;
**no edits were required**. The discovery report's "peripheral/legacy — light touch"
assessment holds.

These are SQL / PowerShell files, so the three-anchor convention adapts to the
comment syntax of each language:

- **Module/file header** → the top-of-file banner (`-- ###…` / `# ===…`) stating the
  file's responsibility plus the non-derivable invariants (the D13 manual-execution
  mandate; the deprecation-until-rollout-Phase-7 rationale).
- **Plan/ADR `@see` anchor** → the `-- See:` / `# See:` block pointing to plan §/runbooks.
- **Gotcha comment** → inline constraint notes (the "commented out by mandate" reason,
  the sqlcmd `-v` colon-parsing quirk).

## Anchors verified per file

| File | Anchor targets | Verdict |
|---|---|---|
| `01_dana_sysadmin_review.sql` | `docs/runbooks/hygiene-findings.md` **Finding 1**; plan **§D13** | resolve ✓ — Finding 1 = dana sysadmin; §D13 = hygiene manual-only |
| `03_premig_db.sql` | `hygiene-findings.md` **Finding 3**; plan **§D13**; Open Question **O3** | resolve ✓ — Finding 3 = `eazybusiness_premig` on `E:\Backup\`; O3 = keep-vs-archive/drop |
| `setup-test-environment.ps1` | plan **§D12**; `Projekte/Testsystem/README.md`; `docs/runbooks/testmandant-reset-validierung.md`; `docs/SQL/MSSQL-OPS-ARCHITECTURE.md` | resolve ✓ — §D12 = alt-scripts stay, superseded after validation |

### Cross-checks against final code

- **Reset entry points** named in the PS1 banner (`RoboticoOps.reset.StartTestmandantReset
  @MandantKey`, `reset.GetResetStatus @MandantKey`) match the actual signatures in
  `db-migrations/global/sprocs/reset.StartTestmandantReset.sql` (`@MandantKey sysname`)
  and `reset.GetResetStatus.sql` (`@MandantKey sysname = NULL`). ✓
- **"rollout Phase 7"** referenced by the PS1 banner exists:
  `docs/runbooks/rollout-mssql-ops.md` §"Phase 7 — Retire the PowerShell path (D12)". ✓
- **sqlcmd invocations** the anchors describe (env-var passing for `ShopUrl`/`ShopLicense`/
  `MandantName` because of the `-v` colon/space quirk) match the actual `& sqlcmd` calls
  in the script body. ✓

## Anchors added / updated / removed

None. All anchors were already present and correct.

## Comment-noise removed

None. Every comment in the three files carries non-derivable "why" (the D13 manual-only
mandate, the O3 open decision, the sqlcmd `-v` parser quirk, the deprecation rationale);
none merely restate code.

## Skips (with reasons)

- No module-header additions: the banners already exist and are complete.
- No `@see` additions: the `See:` blocks already point to plan §/runbooks and resolve.
- No gotcha additions: the existing gotchas cover the two non-guessable quirks
  (D13 mandate, sqlcmd env-var workaround).

## Drift (edits outside assigned scope)

None.

## Notes for final

- All three files' anchors are fully in sync with final code — no reconciliation debt on
  this peripheral/legacy surface.
