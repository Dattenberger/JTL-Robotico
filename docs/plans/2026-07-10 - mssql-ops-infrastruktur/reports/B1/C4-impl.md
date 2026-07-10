# C4 — Architecture doc, 3 plan-scoped ADRs, rollout runbook, deprecation banners, indexes

**Chunk:** C4 · **Block:** B1 · **Timestamp:** 2026-07-10T00:57:22+02:00
**Plan sections:** §5 Doku/ADRs/Rollout/Ablösung (L421-451)

## What I did

Authored the documentation layer as an as-built snapshot (this chunk runs last, so it
reflects C1/C2/C3 code): the UDOC architecture doc, three plan-scoped ADRs
(knowledge-adr-format), the rollout runbook, the runbook and plan-archive indexes, the
Testsystem README, plus the two additive edits (NAMING-CONVENTIONS sections 8–10; a
comment-only DEPRECATED banner on `setup-test-environment.ps1`). All new docs are English.
Lint green (0 errors); the `.ps1` still parses (831 tokens, 0 errors — comment-only change).

## Files modified

**NEW:**
- `docs/SQL/MSSQL-OPS-ARCHITECTURE.md` — UDOC Architecture doc; two chains, RoboticoOps,
  reset flow (ASCII), excel_ekl boundary, and the **SSoT operating rules** (§6:
  clone-after-update, post-update smoke test, re-signing, worker-stopped gate, no-autonomous-writes).
- `docs/plans/2026-07-10 - mssql-ops-infrastruktur/adrs/adr-grate-migration-runner.md` — D1/D3.
- `.../adrs/adr-two-chain-migration-paths.md` — D2/D11.
- `.../adrs/adr-module-signing-reset.md` — D5/D6/D7/D8 (bundled security/control model).
- `docs/runbooks/rollout-mssql-ops.md` — 7-phase spine (baseline → global on test →
  validate → global on prod [gate] → seed keys → first prod reset → retire PowerShell).
- `docs/runbooks/README.md` — runbook index.
- `docs/plans/README.md` — plan-archive index (folder schema, naming, comparison logic,
  language conventions; first plan of the repo).
- `Projekte/Testsystem/README.md` — legacy-reset fallback + pointer to new reset.

**EDIT (additive only):**
- `docs/SQL/NAMING-CONVENTIONS.md` — appended §8 (journal schemas), §9 (RoboticoOps
  `ops`/`reset`), §10 (shared CustomWorkflows zone / D10) before `## References`. No
  existing line changed.
- `Projekte/Testsystem/setup-test-environment.ps1` — prepended a comment-only DEPRECATED
  banner above the `<#` help block. No functional line touched (verified by parse).

## ADR conformance

Each ADR carries the full knowledge-adr-format skeleton (Header → Research → Context →
Decision → Alternatives Considered → Consequences[Positive/Negative/Failure Modes] →
References → Decision History[Initial proposal]). Plan-scoped form: no number, `# ADR-NNNN:`
placeholder header, `Status: Proposed (plan-scoped — pending promotion)`. `## References`
link bidirectionally to the plan; the plan already links back (L21-23). Research sections
cite research/1, /1.1, /2, /3 by §-anchor and cite the C2 as-built report.

## SSoT handling

Operating rules live **only** in the architecture doc §6; the plan is referenced as
history/decisions, not duplicated. The file-level migration contract stays in
`db-migrations/README.md`; the architecture doc is the map above it and points to it rather
than restating rules. D10 boundary text is referenced (not re-copied) from the README.

## Deviations

| Deviation | Plan location | What changed | Why | Impact on later chunks | Resolved? |
|---|---|---|---|---|---|
| Architecture doc placed at `docs/SQL/` (not `docs/architecture/`) | §5 table | followed the plan's explicit path (`docs/SQL/MSSQL-OPS-ARCHITECTURE.md`), sitting next to NAMING-CONVENTIONS/JTL-CUSTOM-WORKFLOWS | plan prescribes it; keeps the SQL docs co-located | none | yes |

## Issues

| ID | Severity | Description | Status | Marker |
|---|---|---|---|---|
| — | — | none | — | — |

## Verification

- `pwsh db-migrations/tests/lint-migrations.ps1` → exit 0 (0 errors; 10 pre-existing C2
  rule-(g) warnings, unrelated to this chunk — no SQL touched here).
- `.ps1` parse: 0 errors, 831 tokens (banner is comment-only).
- All emitted relative links resolve (architecture ↔ ADRs ↔ plan ↔ research ↔ reports ↔
  runbooks ↔ db-migrations; incl. the 4-level `../../../../db-migrations/README.md`).
- Secret scan on new docs: no literal keys/passwords.
- Bidirectional plan↔ADR confirmed (plan L21-23 ↔ each ADR `## References`).

## Files outside assigned scope (drift)

none — all edits are within the §5 file list (docs/SQL, docs/runbooks, docs/plans,
plan `adrs/`, Projekte/Testsystem). No SQL/migration files touched; no server writes.
