---
name: migrations-tooling-vergleich
description: Comparison of in-house build/Flyway/DbUp/grate/DACPAC + grate deep-dive with migration plan (web research, 2026-07-09)
status: Research
---

# Schema Migration Management for MSSQL — Comparison, grate Deep-Dive, Recommendation

> Source: Opus research agent "research-migrations", two reports (base comparison + deep-dive), session 2026-07-09.
> **User's decision: grate** for JTL-Robotico; the EKL runner in excel_ekl stays untouched.

Context: 2-4 developers, pure SQL repo (git), Windows server, no CI, JTL-Wawi DB `eazybusiness` with vendor-schema coexistence, two migration paths (global/admin DB + eazybusiness-local), regularly freshly cloned test mandants.

## Part 1 — Base comparison

### Core findings

**1. Flyway's licensing situation changed in 2025.** Since **14 May 2025**, **Flyway Teams has been discontinued for new customers** — only **Community (free, Apache-2.0)** or **Enterprise (expensive, per-user)** remain. Community: MSSQL, versioned + repeatable + checksums, but **no `undo`** (Enterprise plugin), dry-run/drift check/cherry-pick are Enterprise-only. Redgate is shifting value towards Enterprise. ([Community](https://www.red-gate.com/products/flyway/community/), [Editions](https://www.red-gate.com/products/flyway/editions/), [Licensing FAQ](https://documentation.red-gate.com/fd/commercial-licensing-faq-181633028.html))

**2. DACPAC/state-based is the most dangerous model in a vendor-coexistence scenario.** The state-diff approach thinks in terms of "target state of the whole DB", and JTL owns the same DB:
- **Drop behaviour:** `sqlpackage` cannot exempt schemas from dropping (no `Schema` value for `/p:DoNotDropObjectTypes`); the workaround would be a deployment contributor (`AgileSqlClub.DeploymentFilterContributor`) — a fragile third-party solution. ([Segun Akinyemi](https://segunakinyemi.com/blog/dacpac-dropping-objects/), [DacFx #129](https://github.com/microsoft/DacFx/issues/129), [agilesql.club](https://the.agilesql.club/2015/01/howto-filter-dacpac-deployments/))
- **Model drift from JTL updates:** after every JTL update the vendor schema has changed; a DACPAC with cross-schema references to JTL tables breaks on build/publish or wants to "correct" them. → **Do not use.**

**3. Migration-based runners (in-house build, Flyway, DbUp, grate) are all "vendor-safe" by design** — they only apply their own scripts, never an is-versus-should diff across the whole DB.

### Comparison table

| Criterion | In-house T-SQL | Flyway Community | DbUp | grate | DACPAC |
|---|---|---|---|---|---|
| Runtime dependencies | sqlcmd+PS only | **Java runtime** | .NET (host EXE) | .NET, **self-contained EXE** | .NET/sqlpackage |
| Learning curve | build/maintain the mechanics yourself | medium | low, but C# host | low-medium, conventions | **high** (SSDT/diff) |
| Multi-DB per mandant | loop in PS | good | loop in the host | `--connectionstring` per run | expensive/risky |
| Vendor coexistence | excellent | excellent | excellent | excellent | **poor** |
| Auditability | self-built | strong (`flyway_schema_history`) | solid (`SchemaVersions`) | strong (`ScriptsRun` incl. text+hash) | weak |
| Future-proofing/license | full control | Redgate risk | MIT, active | Apache-2.0/MIT, active | MS, wrong model |

Assessment of the in-house build: it would be ~ exactly what DbUp/grate deliver ready-made and tested — only worth it given a hard zero-dependency goal.

### Vendor-schema coexistence — best practices (tool-independent)

- **Own schema as a hard boundary** (Robotico, CustomWorkflows); never change JTL objects via migration.
- **Own journal table in our own schema** (never `dbo`) — never collides with JTL, travels along when cloning.
- **JTL major update = re-validation gate:** recompile our own objects on the test mandant; anytime scripts make that cheap.
- **Idempotency + guard clauses** in every script ([MSSQLTips](https://www.mssqltips.com/sqlservertip/11638/make-deployable-sql-scripts-idempotent/), [Redgate](https://www.red-gate.com/hub/product-learning/flyway/creating-idempotent-ddl-scripts-for-database-migrations/)).
- **Two-path model: ONE tool, two separate chains** (locations + journals) — two different procedures would be needless cognitive load.

## Part 2 — grate deep-dive (decision-ready details)

### Folder conventions (deterministic order, three script types)

One-time = exactly once (journal; changing it afterwards = error) · Anytime = again on **hash change** · Everytime = every run. ([FolderConfiguration.md](https://github.com/grate-devs/grate/blob/main/docs/ConfigurationOptions/FolderConfiguration.md))

| # | Folder | Type |
|---|---|---|
| 1 | `dropDatabase` | Anytime (only with `--drop`) |
| 2 | `createDatabase` | Anytime |
| 3 | `beforeMigration` | **Everytime** |
| 4 | `alterDatabase` | Anytime |
| 5 | `runAfterCreateDatabase` | Anytime (only on a fresh DB) |
| 6 | `runBeforeUp` | Anytime |
| 7 | **`up`** | **One-time** — core migrations |
| 8 | `runFirstAfterUp` | One-time |
| 9 | `functions` | Anytime |
| 10 | `views` | Anytime |
| 11 | `sprocs` | Anytime |
| 12 | `triggers` | Anytime |
| 13 | `indexes` | Anytime |
| 14 | `runAfterOtherAnyTimeScripts` | Anytime |
| 15 | `permissions` | **Everytime** |
| 16 | `afterMigration` | **Everytime** |

Order within a folder: alphabetical → secure dependencies between anytime objects via naming or `runAfterOtherAnyTimeScripts`.

### CLI (Windows example)

```powershell
grate `
  --connectionstring="Server=PRODSRV;Database=eazybusiness_tm1;Trusted_Connection=True;TrustServerCertificate=True" `
  --sqlfilesdirectory=".\db-migrations\eazybusiness" `
  --databasetype=sqlserver `
  --schema=Robotico `
  --environment=TEST `
  --transaction `
  --silent `
  --version=$(git describe --tags --always)
```

Important options: `--schema` (journal schema, default `grate`), `--baseline` ("mark scripts as run, but not actually run anything"), `--dryrun`, `--warnononetimescriptchanges`, `--runallanytimescripts` (pitfall: forces all anytime scripts), `--usertoken Key=Value`, `--silent`.

### Journal tables (RoundhousE heritage, in the `--schema` schema)

- **`Version`** — per run: id, repository_path, version, entry_date, entered_by.
- **`ScriptsRun`** — per script: script_name, **text_of_script**, **text_hash**, one_time_script, entry_date, entered_by. Hash = the mechanism for "anytime only on change".
- **`ScriptsRunErrors`** — error log including erroneous_part_of_script.

`--schema=Robotico` satisfies the journal-in-Robotico and travels-with-the-clone requirements directly.

### Further mechanics

- **Token replacement:** `--ut Key=Value` → `{{Key}}` in the script; built in are `{{DatabaseName}}`, `{{ServerName}}`, `{{Environment}}`. Use sparingly (otherwise scripts are no longer runnable without grate).
- **Errors/resumption:** with `--transaction`, rollback on a script error, error recorded in `ScriptsRunErrors`; the next run skips successful one-time scripts.
- **Baseline:** `grate --baseline` against the existing prod DB records the current state without re-running it.
- **GO batches:** the statement splitter recognises `GO` — **but repo gotcha: `GO;` (with semicolon) may not be recognised → normalise beforehand.**
- **Distribution:** `dotnet tool install --global grate`, NuGet, **self-contained EXE** (only ICU required), Docker. ([NuGet](https://www.nuget.org/packages/grate))
- **Project health:** v2.1.5 (7 July 2026), 45 releases, 22 open issues, recently transferred to the community org **grate-devs**, 291★. ([GitHub](https://github.com/grate-devs/grate))

### DbUp in comparison (short form)

.NET library + a self-maintained C# host program (~40 lines, `dotnet publish` self-contained). Journal `JournalToSqlTable("Robotico","SchemaJournal")` (columns: SchemaVersionId, ScriptName, Applied). **Core weakness for our scenario:** RunAlways/NullJournal scripts run on **every** deploy (no hash comparison, no journal entry → no change audit, longer deploys); baseline is manual via `MarkAsExecuted` code. Project healthy (6.1.1 Feb 2026, MIT, 2.6k★). ([GitHub](https://github.com/DbUp/DbUp), [docs](https://dbup.readthedocs.io/), [Script Types](https://dbup.readthedocs.io/en/latest/more-info/script-types/), [Journaling](https://dbup.readthedocs.io/en/latest/more-info/journaling/))

### Point by point for our repo

grate is more ergonomic for: a CREATE-OR-ALTER-heavy existing body of scripts (anytime+hash), change auditing (`ScriptsRun.text_of_script`+hash), no code of our own, `--baseline` built in. DbUp is more ergonomic only for: an existing .NET deploy pipeline / a need for programmatic control.

**Operational risks of grate:** (1) Convention magic — the folder name determines the semantics; a script that has run in `up` and is then edited = error (PR review point). (2) Alphabetical anytime ordering where object dependencies exist. (3) Avoid `--runallanytimescripts` in prod. **Common to both:** normalise `GO;`→`GO`; **remove hard-coded `USE eazybusiness` lines** — otherwise a script targets prod despite the clone connection string!

### Target structure + example mapping

```
db-migrations/
  eazybusiness/                  # path B (level A) → journal in the Robotico schema
    up/          V scripts, one-time (tables, bootstrap)
    functions/   Anytime
    views/       Anytime
    sprocs/      Anytime
  global/                        # path A (level B) → RoboticoOps, journal there
    up/  sprocs/ …
```

| Current file | Target | Adjustment |
|---|---|---|
| `Workflowaktion Auftrag Preise auf Null.Sql` | `eazybusiness/sprocs/spAuftragPreiseAufNull.sql` | `GO;`→`GO`; registration EXECs (idempotent) stay |
| `Workflowaktion_Gebinde_Erstellen.sql` | `eazybusiness/sprocs/spGebindeErstellen.sql` | **remove `USE eazybusiness`** |
| `Duplikaterkennung_Bestellungen.sql` | iTVF → `functions/`, SP → `sprocs/` | split into single-object files |
| `*_Tests.sql`, `*_Teardown.sql` | **separate `tests/` folder outside `--sqlfilesdirectory`** | never in the deploy chain |
| Infra SPs `CustomWorkflows._CheckAction`/`_SetActionDisplayName` | `up/000_bootstrap_action_infra.sql` or `sprocs/` | deploy first |

Procedure: one-off `--baseline` against prod → normal cycle: test mandant (`--environment=TEST`) → sign-off → prod. Anytime hash tracking makes runs against freshly cloned mandants inconsequential → clone reproducibility satisfied.

### Risks of the recommendation

1. Convention discipline (folder semantics) — mandatory PR review.
2. `GO;`/`USE eazybusiness` normalisation is mandatory preparatory work for the entire existing body of scripts.
3. Secure anytime ordering where dependencies exist.
4. No built-in undo (true for all migration runners): rollback = compensating migration.
5. Instance objects (logins/certificates/jobs) need careful guard clauses (`IF NOT EXISTS … sys.server_principals`).
6. grate is smaller than DbUp (bus factor), but no lock-in: the format is SQL files in folders, the runner is replaceable.
