# Doc Worker Report — runbooks-index

**Slug:** runbooks-index
**Action:** update
**Target:** `docs/runbooks/README.md`
**Timestamp:** 2026-07-10T02:45:00+02:00
**Outcome:** no-change-needed

## What I did

Reconciled the runbook index against the four runbooks it indexes
(`rollout-mssql-ops.md`, `migrations-baseline.md`,
`testmandant-reset-validierung.md`, `hygiene-findings.md`) after repair
wave 1. Verified every index row, the scope column, the fit-together
diagram, and the Related links against the final runbook content. The
index is accurate and complete; no edit was warranted.

## Verification (per index element)

| Index element | Verified against | Verdict |
|---|---|---|
| Row `rollout-mssql-ops` — "baseline, stand up RoboticoOps, validate, gate onto prod, seed keys, first prod reset, retire old path" | runbook Phases 0–7 | Matches 1:1 |
| Row `migrations-baseline` — "adopt already-populated eazybusiness … without re-running (Ebene A); file-vs-deployed pre-check" | runbook intro + Step 2 | Matches |
| Row `testmandant-reset-validierung` — "`StartTestmandantReset` → agent job → `internal_*` → `GetResetStatus`, test1 only" | runbook intro + Steps 3–4 | Matches (index omits `reset.` schema prefix — acceptable summary) |
| Row `hygiene-findings` — "Dana sysadmin, tm2 backlog, `eazybusiness_premig`; read-only, fixes commented out" | runbook Findings 1–3 | Matches |
| Scope column (prod+test1 / prod+test1 / test1 only / prod) | each runbook's "Applies to" + `targets.config.json` | Matches |
| Fit-together diagram (Phase 1→baseline, Phase 3→validation, Phase 7→hygiene "separate, manual") | rollout runbook phase pointers | Matches; the "separate, manual" annotation correctly reflects that the rollout runbook explicitly states hygiene is **not** part of the rollout |
| Related links (architecture map, migration contract, origin plan) | filesystem | All three targets exist |
| Runbook set completeness | `ls docs/runbooks/` = exactly the 4 indexed + README | No missing/extra runbook |

## Provenance note

The index (`README.md`) and all four runbooks were authored together in
commit `66a1969` and none changed afterward (`git diff 66a1969..HEAD --
docs/runbooks/` is empty), so no drift could have been introduced by
repair wave 1.

## Sections changed

None.

## Notes for final

- Minor, non-blocking: the fit-together diagram labels the hygiene arrow
  "Phase 7", while the rollout runbook states hygiene is *not* part of
  the rollout (the pointer merely lives in the Phase 7 section). The
  "(separate, manual)" annotation already disambiguates this; flagging
  only in case the final agent wants to sharpen wording (e.g. "after
  Phase 7") for cross-doc consistency. Not a false claim as written.
- The index's "Related" block points at `../SQL/MSSQL-OPS-ARCHITECTURE.md`.
  If a sibling doc worker relocates the architecture doc into
  `docs/architecture/`, this link must move with it.
