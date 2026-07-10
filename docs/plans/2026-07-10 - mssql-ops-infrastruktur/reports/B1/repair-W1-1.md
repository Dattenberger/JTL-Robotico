# Repair W1-1 — NAMING-CONVENTIONS §9 accuracy

**Timestamp:** 2026-07-10T00:57:22+02:00
**Cluster:** convention-B1-1 (green, Important)

## Finding

`docs/SQL/NAMING-CONVENTIONS.md` §9 (old line 178) claimed the `ops.*` / `reset.*`
objects "follow the same rules as `Robotico` (sections 2–4)" — i.e. `t<Name>` tables
and Hungarian `k/n/c/f/d/b` column/parameter prefixes. Verified against
`db-migrations/global/up/0002_ops_schema_tables.sql` and the `reset.*` sprocs: the
shipped objects do the opposite — PascalCase, unprefixed (`ops.Mandant`,
`MandantKey`/`TargetDb`/`Status`/`StepLog`, `@TargetDb`/`@RequestId`, procs like
`reset.StartTestmandantReset` with no `sp` prefix). The naming SSoT was the inaccurate
side; a maintainer following §9 literally would emit `ops.tSomething` with `cName`
columns and drift the schema.

## What I did

Rewrote §9's post-table paragraph into an explicit **Ebene-B convention** description
(admin-DB PascalCase, not the JTL Hungarian style), covering:

- **Object naming table** — Table / Column / Parameter / Procedure rows, each with the
  actual example and the §2–4 form it contrasts with, plus the rationale (RoboticoOps
  sits outside `eazybusiness`, so §3's "read like surrounding `dbo` tables" motivation
  does not apply).
- **Constraint/index naming table** — documents that constraints keep the §2 prefixed
  style but schema-qualified (`PK_ops_Mandant`, `FK_ops_ResetRequest_Mandant`,
  `UQ_ops_Mandant_TargetDb`, `CK_ops_Mandant_TargetDb`, `DF_ops_Mandant_IsActive`),
  all verified against the migration.
- **`UX_ResetRequest_Active` note** — the index that "uses neither `IX_` nor `UQ_`" is
  now documented as the deliberate `UX_<Table>_<Purpose>` convention for standalone
  filtered *unique* indexes (distinct from non-unique `IX_` and constraint-borne `UQ_`),
  with the "not schema-qualified because index names are already table-scoped" rationale.
- Kept the two existing local conventions (`internal_` prefix, secret `DENY`) and the
  "invisible to excel_ekl runner" line.

Chose the doc-fix path (not renaming the shipped index) per the finding's scope note —
the `ops.*` tables/columns are referenced across the 11 reset procs, and
`0002_ops_schema_tables.sql` is a grate one-time (hash-checked) migration, so
`UX_ResetRequest_Active` is documented in place rather than renamed. This resolves the
finding on the inaccurate (documentation) side without touching an immutable migration.

## Files modified

- `docs/SQL/NAMING-CONVENTIONS.md` — §9 rewritten (documentation only).

## Tests

`pwsh db-migrations/tests/lint-migrations.ps1` → `OK: 0 errors, 10 warning(s)`. The 10
warnings are pre-existing dynamic-SQL concatenation notices in `reset.internal_*` sprocs,
unrelated to this doc-only change.

## Skipped

none

## Drift

none
