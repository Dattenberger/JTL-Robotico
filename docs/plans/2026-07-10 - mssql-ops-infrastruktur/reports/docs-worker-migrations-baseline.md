# Doc-worker report — migrations-baseline

**Date:** 2026-07-10T02:45:00+02:00
**Action:** update
**Target:** `docs/runbooks/migrations-baseline.md`
**Sources reconciled:** `db-migrations/targets.config.json`,
`db-migrations/tests/compare-objects.sql`, `db-migrations/eazybusiness/up/0001_robotico_schema.sql`
(plus `db-migrations/deploy.ps1` for flag verification)

## Verification result — doc already matched final code

Reconciled every operational claim against the shipped code after repair wave 1
(`54f38fd`). All accurate, no stale content:

- **Step 1 target table** — server + DB lists match `targets.config.json` exactly:
  PROD `vm-sql2.zdbikes.local` → `eazybusiness`, `_tm2`, `_tm3`, `_tm4`;
  TEST `vm-sql-test1.zdbikes.local` → `eazybusiness`.
- **Deploy flags** (Steps 4–5) — `-Scope eazybusiness`, `-Environment PROD|TEST`,
  `-Target`, `-Baseline`, `-DryRun` all match `deploy.ps1` `param()` block; `-Baseline`
  → `--baseline`, `-DryRun` → `--dryrun`.
- **PROD Y/N gate** — confirmed by the `-Environment PROD -and -not $DryRun` block; it
  prints the DB list and the BASELINE mode line as the runbook states.
- **`-Target` validation** — `deploy.ps1` throws if `-Target` is not in the env's
  eazybusiness list; runbook's per-clone repetition is correct.
- **Failure modes** — `--warnandignoreononetimescriptchanges` is genuinely not a
  `deploy.ps1` default (grate flag only). Accurate.

## Change applied — Step 2 sharpening (only edit)

Discovery framed this as "reconcile-and-**sharpen**." The single edit tightens Step 2:
`compare-objects.sql` emits `SHA2_256` definition hashes (tables NULL). The prior
wording ("dump the hashes and eyeball them against the files") glossed the concrete
comparison mechanism. Rewrote to spell out the two read paths the hash actually enables:

- Prod = the truth → check object **presence** only (nothing to diff against).
- test1 / directly-baselined clones → compare their hash list **against prod's**;
  differing hash = drift.

Also aligned the object-scope phrasing with the script's real filter ("our
`CustomWorkflows` action procs", not the looser `CustomWorkflows.sp*`). In-place edit,
well under 30%, existing voice/structure/callouts preserved. Non-UDOC skill load not
required for a small in-place edit on an established runbook.

## Deviations

| Deviation | Plan location | What changed | Why | Impact on later chunks | Resolved? |
|---|---|---|---|---|---|
| none | — | — | — | — | — |

## Issues

| ID | Severity | Description | Status | Marker |
|---|---|---|---|---|
| none | — | — | — | — |

## Files modified

- `docs/runbooks/migrations-baseline.md` (Step 2 only)

## Files outside assigned scope (drift)

none

## Notes for final

- **Cross-doc consistency (no action taken, flag only):** Step 2's object-ownership
  boundary (Robotico + our CustomWorkflows action procs, excluding `_`-helpers and
  `spCMArtikel`/`spCMArtikelNeu`) mirrors the D10 boundary documented in
  `compare-objects.sql` and `NAMING-CONVENTIONS.md`. If the naming-conventions worker
  changes the ownership wording, keep this runbook's Step 2 phrasing in step.
- **Gap carried from discovery (not this doc's job):** `db-migrations/tests/` has no
  dedicated README; `compare-objects.sql` is only described from the architecture doc
  and inline. A `db-migrations/tests/README.md` would make the pre-check surface
  self-describing. The final/index agent may want to note this.
