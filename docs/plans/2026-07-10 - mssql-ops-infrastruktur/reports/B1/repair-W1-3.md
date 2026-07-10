# Repair report — cluster W1-3

**Timestamp:** 2026-07-10T00:57:22+02:00
**Agent role:** repair-fix

## Finding fixed

### convention-B1-3 (green / Nice-to-have) — cross-chunk file-header divergence

**What the finding was.** C1 files (`eazybusiness/`, 25 files) use a boxed banner
header (`-- ===` / `-- Schema.Object — purpose` / `-- ===`); C2 files (`global/`,
20 files) use a compact one-liner (`-- object  (Ebene B / global — role)`) plus an
`@see` plan anchor on every file. Both styles are internally consistent per chunk;
the gap was that the convention was **undefined** in the "contract" README.

**What I did.** Recorded the convention in `db-migrations/README.md` §3 (the primary
action the suggested fix calls for). Added a "File-header convention" paragraph that:

- States every migration file opens with a header block (identity + one-line purpose
  + `@see` anchor for ported/plan-driven objects), per the repo's inline-anchor
  convention.
- Documents the **two sanctioned shapes by layer** with a worked example each:
  - **Ebene A (`eazybusiness/`)** → boxed banner (self-contained objects; header just
    needs to stand out).
  - **Ebene B (`global/`)** → compact identity line carrying the chain + runtime-role
    classification the reset infra needs, followed by an `@see` plan anchor (expected
    on every Ebene-B file; optional on Ebene-A).
- Explains *why* the two shapes are legitimate (Ebene-B files must announce their
  chain / job-only / signed / everytime role; Ebene-A objects don't), so it is a
  rationalized convention, not silent drift.

File pointer: `db-migrations/README.md` §3, inserted between the file-naming table
paragraph and the `---` before §4.

**Why not mass-reformat the 45 `.sql` files.** Disproportionate churn/risk for a
green cosmetic finding against recently-written, internally-consistent files, and it
would either destroy the Ebene-B classification/`@see` information or force it onto
Ebene-A files that don't need it. Reformatting only the two cited exemplar files was
rejected too — it would create a *third* style. The README calls itself "the
contract," so the documented convention was written to match current reality
(defining the sanctioned per-layer variation) rather than describe an unmet
aspiration. The two `.sql` files named in the finding are now the canonical
exemplars the README cites (`reset.internal_CloneDatabase.sql` = the Ebene-B example;
a `Robotico.fn*` = the Ebene-A example); they were reviewed, left unchanged.

## Tests

`pwsh db-migrations/tests/lint-migrations.ps1` → **0 errors, exit 0** (10 pre-existing
rule-(g) heuristic warnings on SQL bodies, unrelated to this doc-only change).

## Files modified

- `db-migrations/README.md` — added the File-header convention to §3.

## Drift

- `db-migrations/README.md` — not in the finding's `files` array, but the suggested
  fix explicitly directs recording the convention there; this is the fix target, not
  scope creep. The two `.sql` files listed in the finding were left unmodified (see
  rationale above).
