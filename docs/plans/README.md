# Plan Archive

Implementation plans for JTL-Robotico live here, one folder per plan. A plan starts life
in the working area (`~/.claude/plans/`) and is **moved** here — with a per-plan README and
an English translation — once its implementation is complete (the "move plan to archive"
step). This index defines the folder schema, naming, comparison logic, and language rules.

## Folder schema

```
docs/plans/
└── YYYY-MM-DD - {name}/
    ├── {name}.md                     ← the plan file (working language, typically German)
    ├── {name}.en.md                  ← English translation (added at archive time)
    ├── README.md                     ← per-plan readme (what/why/outcome, added at archive time)
    ├── adrs/                         ← plan-scoped ADR drafts (no number until promoted)
    │   └── adr-{slug}.md
    ├── research/                     ← co-located research / specs (evidence for the plan)
    │   └── {topic}/{topic}.md
    └── reports/                      ← per-chunk implementation reports (impl-run artefacts)
        └── {block}/{chunk}-impl.md
```

- **`YYYY-MM-DD`** is the plan's creation date (immutable — it does not change when the
  plan is archived).
- **`{name}`** is the plan slug (kebab-case), matching the plan file's basename and the
  `archive_target:` frontmatter.
- Large plans split the English translation into
  `{name}-0-overview.en.md … {name}-N-{block}.en.md`; `research/*.md` translate in parallel
  as `research/{topic}.en.md`.

## Naming schema

| Item | Rule | Example |
|---|---|---|
| Plan folder | `YYYY-MM-DD - {name}` (spaces around the dash) | `2026-07-10 - mssql-ops-infrastruktur` |
| Plan file | `{name}.md` | `mssql-ops-infrastruktur.md` |
| EN translation | `{name}.en.md` (or split `{name}-N-{block}.en.md`) | `mssql-ops-infrastruktur.en.md` |
| Plan-scoped ADR | `adrs/adr-{slug}.md` (no number; `# ADR-NNNN:` placeholder) | `adrs/adr-grate-migration-runner.md` |

## Comparison logic (which plan is "current")

When more than one plan touches the same area, the **newer `YYYY-MM-DD`** folder is the
current intent; older folders are historical record. A plan that supersedes another names
it in its `## References`. ADRs promoted out of a plan (into `docs/decisions/`) carry the
authoritative decision forward; the plan-scoped draft in `adrs/` is the historical form.

## Language conventions

- **Plan file** (`{name}.md`) — the working language, typically **German**. Archived plans
  keep the language they were written in.
- **English translation** (`{name}.en.md`) — added after implementation completes.
- **Process documentation** (this index, per-plan READMEs) — **English**.
- **ADRs, runbooks, architecture docs, code comments** — **English** (see
  [`docs/SQL/`](../SQL/) and [`docs/runbooks/`](../runbooks/)).
- Plan-scoped ADRs and co-located research are written directly per their own conventions
  (`knowledge-adr-format` / `knowledge-doc-format`).

## Archived plans

| Date | Plan | Status | Summary |
|---|---|---|---|
| 2026-07-10 | [`mssql-ops-infrastruktur`](2026-07-10%20-%20mssql-ops-infrastruktur/mssql-ops-infrastruktur.md) | In implementation | grate migration foundation, `RoboticoOps` admin DB, server-side test-mandant reset. First plan of this repo; introduces the first three (plan-scoped) ADRs. |
| 2026-07-21 | [`mssql-wartung-ola`](2026-07-21%20-%20mssql-wartung-ola/mssql-wartung-ola.md) | Implemented 2026-07-23 | SQL-Server maintenance as code — Ola Hallengren vendored in `RoboticoOps`, declarative `ops.tMaintenanceJob` registry, backup-chain + liveness watchdogs. B1–B5 deployed + E2E-verified on test1; B6 Prod-cutover human-gated. Promotes [ADR-0001](../decisions/0001-maintenance-as-code-roboticoops.md) and [ADR-0002](../decisions/0002-backups-cbb-retained.md). |
