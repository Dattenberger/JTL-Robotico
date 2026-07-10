# C4 — Self-Fix (fresh eyes)

**Chunk:** C4 · **Block:** B1 · **Reviewer:** fresh-eyes self-fix agent
**Wave commit:** 66a19695a3132aefc5952d2ff6d48340f1723732
**Timestamp:** 2026-07-10T00:57:22+02:00

## What I did

Reviewed the C4 documentation layer (architecture doc, 3 plan-scoped ADRs, rollout
runbook, runbook/plan indexes, Testsystem README, NAMING additive edit, `.ps1` banner)
with the three lenses (plan-correctness, doc quality per knowledge-adr-format /
knowledge-doc-format, and — since this is a docs chunk — link/code-pointer integrity).
The implementation is high quality; one minor accuracy fix applied.

## Fixes applied

1. **Component-table file count** (`docs/SQL/MSSQL-OPS-ARCHITECTURE.md` §3): the Ebene-B
   tree was described as `~15 files` but `db-migrations/global/` actually holds **20**
   `.sql` files. Corrected to `~20 files`. (Ebene-A `~28` for the 27 actual files is
   within the `~` tolerance and left as-is.)

## Verification performed (no defects found)

- **ADR conformance** — all three ADRs carry every knowledge-adr-format mandatory section
  in exact order (Header → optional Cooperates-with → Research → Context → Decision →
  Alternatives Considered → Consequences[Positive/Negative/Failure Modes] → References →
  Decision History[Initial proposal]). Plan-scoped form correct: `# ADR-NNNN:` placeholder,
  `Status: Proposed (plan-scoped — pending promotion)`.
- **Bidirectional plan↔ADR** — each ADR `## References` links the plan; plan L21–23 links
  back to all three ADRs. Confirmed.
- **Link integrity** — every relative link in all C4 files resolves: the 4-level
  `../../../../db-migrations/README.md` from `adrs/`, the `%20`-encoded plan-folder links,
  `../research/…`, `../reports/B1/C2-impl.md`, `../../../runbooks/…`, and the cross-doc
  links between architecture ↔ runbooks ↔ NAMING ↔ Testsystem README. All targets exist
  (db-migrations/README.md, migrations-baseline.md, testmandant-reset-validierung.md,
  hygiene-findings.md, compare-objects.sql, probes/02_worker_discovery.md, all research dirs).
- **Code pointers** — every file path cited in the architecture §3 component table and the
  ADRs resolves to a real as-built file (`0002_ops_schema_tables.sql`,
  `0010_jobstartuser_login.sql`, `0011_signing_certificate.sql`, all `reset.*` sprocs,
  `reset.EnsureAgentJob.sql`, `900_resign_procedures.sql`, `lint-migrations.ps1`,
  `targets.config.json`, `deploy.ps1`).
- **Additive-edit discipline** — NAMING-CONVENTIONS §8–§10 appended before `## References`,
  no existing line touched; `setup-test-environment.ps1` banner is comment-only above the
  `<#` help block (no functional line changed).
- **SSoT** — standing operating rules live only in architecture §6; the plan is referenced
  as history, not duplicated. D10 boundary text is referenced from db-migrations/README.md,
  not re-copied.
- **Language** — all new docs English per convention.
- **Secrets** — no literal keys/passwords; licence handling is placeholder + runbook UPDATE.

## Issues

| ID | Severity | Description | Status | Marker |
|---|---|---|---|---|
| — | — | none | — | — |

## Files modified

- `docs/SQL/MSSQL-OPS-ARCHITECTURE.md` — one-word count correction (`~15` → `~20`).

## Files outside assigned scope (drift)

none.

## Final test result

`pwsh db-migrations/tests/lint-migrations.ps1` → exit 0 (0 errors; 10 pre-existing rule-(g)
warnings in C2's `reset.internal_*` SQL — outside this docs chunk, unchanged by C4).
