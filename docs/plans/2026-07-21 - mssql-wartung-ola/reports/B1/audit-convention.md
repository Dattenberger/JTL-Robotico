# Block Audit — convention — B1

**Date:** 2026-07-22T21:57:00+02:00 · **Block:** B1 · **Topic:** convention
**Base:** `d722993ae64b0a7e0dbcb5fd37fa8c6a7e7180a9..HEAD` (file-scoped to BLOCK_FILES)
**Grounding loaded:** project `CLAUDE.md`, user `language-conventions.md`, `docs/SQL/NAMING-CONVENTIONS.md`, `knowledge-sql`

## Verdict

The maintenance suite is, in almost every dimension the convention lens cares about,
consistent with the established Ebene-B (`RoboticoOps`) codebase: proc-header shape
(`-- name (Ebene B / global — …)` + `@see` plan/ADR tags), Hungarian column/parameter
naming per NAMING-CONVENTIONS §9, the `IS DISTINCT FROM` NULL-safe comparison idiom
used identically in the sync proc and the MERGE, THROW-number allocation matching
README §4(k) (51100/51105/51110/51120), and the two validation-gate edits mirror the
existing `@problems`-table assertion style verbatim. Two consistency defects stand out,
one of them affecting a whole file.

## Findings

### convention-B1-1 — up/0023 is the only German-commented file in an all-English chain (Important)

`db-migrations/global/up/0023_maintenance_registry.sql` — inline comments throughout
(header block L18–20, and the table DDL L25, L31–102: "Registry ist repo-owned",
"Zeitplan: typisiert statt Cron-String", "maint-Schema: idempotent", "Anlegen UND
Entfernen hängen am Namenspräfix", …).

**What's wrong / why it matters:** A per-file marker count over the whole `up/` folder
returns 0 German-marker lines for every script 0001–0022 and 14 for 0023; every one of
the block's own five `maint.*` procs, `permissions/260`, `runAfterOtherAnyTimeScripts/
maint.spApplyMaintenance`, and both validation files are 0. So 0023 is a single German
file inside an otherwise uniformly English db-migrations infrastructure — and, more
jarringly, inside its OWN block, whose sibling procs (and the direct structural analog
`up/0021_reset_step_registry.sql`, the reset-step registry) are English. This
contradicts the binding user convention *"Code comments and identifiers: English"*
(`language-conventions.md`) and the established repo pattern. The DATA-MODEL doc that
0023 must stay in sync with, and the DDL's own `@see` tags, are English — a reader
cross-referencing table→doc switches language mid-thought.

**Expected instead:** English inline comments, matching 0021 and the five maint procs.

**Suggested fix:** Translate the 0023 inline comments to English (content is fine, only
the language differs). Mechanical; no DDL/behaviour change, no grate-hash concern beyond
the comment bytes (0023 is an immutable up/ script — verify it has not yet been applied
to prod before rewriting; on test1 a comment-only change re-hashes the script, so this
should land before the first prod apply or be accompanied by the usual immutable-script
handling).

### convention-B1-2 — permissions/260 PRINT messages anchor on the file number, not the object (Nice-to-have)

`db-migrations/global/permissions/260_maintenance_operator.sql` L45, L56, L78, L90 —
PRINT prefixes `'260: …'` / `'! 260: …'`.

**What's wrong / why it matters:** The codebase anchors operational PRINT messages on
the object/proc they concern: `permissions/200_ensure_agent_job.sql` prints
`'! Agent job [...] missing — recreating …'`, `250_jobstartuser_mapping.sql` prints
`'! … jobstartuser was orphaned …'`, and every maint proc prints
`'maint.spEnsureMaintenanceJobs: …'`. 260 introduces a third style (the migration file
number) that no other script uses — a minor logging inconsistency that makes 260's
output harder to grep alongside the rest.

**Expected instead:** Anchor on the object, e.g. `'! Maintenance operator
[RoboticoOps-Maint] created.'` / `'! Agent mail profile [Standard SMTP] not set …'`.

**Suggested fix:** Re-prefix the four PRINTs with an object-oriented anchor. Purely
cosmetic; low confidence — defensible as-is because an everytime permissions script
performs several unrelated tasks with no single proc to anchor to, so the reviewer may
reasonably keep the file-number anchor. Flagged for the consolidator to weigh.

## Non-findings (checked, deliberately not flagged)

- **N-prefix on string literals** — `bs.type = 'D'`/`'L'` and the Ola params
  (`@LogToTable='Y'`, `@UpdateStatistics='ALL'`, `@FragmentationHigh='INDEX_REORGANIZE'`)
  are N-less while `recovery_model_desc <> N'SIMPLE'`, `state_desc = N'ONLINE'` carry N.
  This is type-correct, not sloppy: `bs.type` is `char(1)` and the Ola parameters are
  `varchar`, so N-less is idiomatic and matches how Ola is invoked; the nvarchar
  comparisons correctly keep N. Consistent by type, not a convention defect.
- **SYSDATETIME vs SYSUTCDATETIME split** — the watchdog/liveness procs use local
  `SYSDATETIME()` while the registry defaults use `SYSUTCDATETIME()`. This is a
  heavily-documented deliberate D32 gotcha (backupset/CommandLog store local time), not
  drift. (Correctness of that split is a `logic`-topic concern, out of scope here.)
- **Validation-gate edits** — `validate_structure.sql` / `validate_rollout.sql`
  additions match the existing `@problems`-INSERT idiom, English comments, and
  `IS DISTINCT FROM` NULL-safety exactly. Fully consistent.
- **Proc headers / `@see` tags / THROW allocation** — uniform with the reset suite and
  README §4(k).

## Out-of-scope observations (for the consolidator)

- `logic` topic: `maint.spCheckMaintenanceLiveness` L57–58 builds the CommandType
  `IN (…)` list with two `CASE`s that each emit a fallback token (`DBCC_CHECKDB` /
  `UPDATE_STATISTICS`) on the non-matching branch — worth a logic reviewer confirming
  the fallback tokens can't produce a false-fresh match for the other operation kind.
  Not a convention issue.

## Coverage

- **Audited (convention lens):** all five `maint.*` procs, `up/0023`, `permissions/260`,
  `runAfterOtherAnyTimeScripts/maint.spApplyMaintenance`, `validate_structure.sql`,
  `validate_rollout.sql`, plus the two chunk reports (C1-impl, C1-selffix). Compared
  against `up/0021`, `up/0002`, `permissions/200`, `permissions/250`, and the reset
  sprocs as the convention baseline.
- **Skipped:** `up/0022_maintenance_ola_vendor.sql` (5350 lines) — vendored Ola
  Hallengren code, upstream-owned; its style is upstream's and out of scope for our
  convention lens (the 3 sanctioned byte-breaks are documented VENDOR-DEVIATION markers).
  Docs (DATA-MODEL, NAMING, ARCHITECTURE, runbook) and README skimmed for language
  consistency only — all English, consistent; no findings.
