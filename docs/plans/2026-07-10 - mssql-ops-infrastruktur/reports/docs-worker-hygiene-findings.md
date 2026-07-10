# Doc Worker Report — hygiene-findings (update)

**Date:** 2026-07-10T02:45:00+02:00
**Target:** `docs/runbooks/hygiene-findings.md`
**Action:** update (reconcile against final code)
**Sources:** `Berechtigungen/cleanup/01_dana_sysadmin_review.sql`,
`Berechtigungen/cleanup/02_tm2_refresh.md`, `Berechtigungen/cleanup/03_premig_db.sql`
**Outcome:** no-change-needed

## What was checked

The runbook and its three source scripts were all introduced in a single commit
(`172a280 [B1.C3] …`); repair wave 1 (`54f38fd`, current HEAD) did not touch any of
them (`git log 9592c99..HEAD -- docs/runbooks/hygiene-findings.md` and
`-- Berechtigungen/cleanup/` both show only `172a280`). So the doc has not drifted
from the code since it was written. I reconciled each finding line-by-line anyway:

| Runbook claim | Source | Match |
|---|---|---|
| Finding 1: blocks (A)–(D) enumerate server roles / sysadmin members / explicit server perms / in-DB mapping | `01_*.sql` blocks (A)–(D) | yes |
| Finding 1: three options — drop sysadmin keep dbcreator / drop both + granular / personal login + disable | `01_*.sql` Options 1–3 | yes |
| Finding 1 precondition: audit dependents (Agent job owners, app configs, Extended Events) | `01_*.sql` "Precondition for ALL options" | yes |
| Finding 2: all eazybusiness DBs on 2.0.5.0 except tm2 on 1.11.6.0; clone-after-update | `02_*.md` Finding + rationale | yes |
| Finding 3: blocks (A)–(C) existence/recovery/age, files+sizes+location, last good backup | `03_*.sql` blocks (A)–(C) | yes |
| Finding 3: KEEP (move off E:\Backup\ + SIMPLE) / ARCHIVE-THEN-DROP; O3 owner Lukas | `03_*.sql` disposition options | yes |
| Finding 3 warning: fresh full backup → RESTORE VERIFYONLY → off-box copy → drop, in that order | `03_*.sql` ARCHIVE-THEN-DROP block | yes |
| `sqlcmd -S vm-sql2.zdbikes.local -E -C -d master -i <script>`; target vm-sql2 | script headers | yes |

All four relative links (`../../Berechtigungen/cleanup/` + the three files) resolve to
existing files. No stale paths, no leftover placeholders, no false claims.

## Sections changed

None. The runbook already reflects the shipped scripts.

## Notes for final

- The runbook's `Source:` line points at the folder
  `docs/plans/2026-07-10 - mssql-ops-infrastruktur/research/2-instanz-survey` (no file
  extension) — same reference the three source scripts use. Consistent within this
  doc-set; flagging only in case the final agent normalizes research references across
  runbooks.
- Cross-doc link into `docs/runbooks/testmandant-reset-validierung.md` (referenced from
  `02_tm2_refresh.md`, not from this runbook) is that sibling runbook's concern — left
  for the final pass.
