# Block B1 — Convention Audit

**Topic:** convention (same operation done differently across chunks: naming, error
handling, layout) · **Block:** B1 · **Timestamp:** 2026-07-10T00:57:22+02:00
**Baseline:** 9592c99..HEAD · **Grounding:** project `CLAUDE.md`, `db-migrations/README.md`
(the conventions SSoT), `docs/SQL/NAMING-CONVENTIONS.md`, `knowledge-jtl-sql`,
`knowledge-reference`.

## Scope audited

- **C1 (Ebene A):** 12 `eazybusiness/functions/*.sql`, 13 `eazybusiness/sprocs/*.sql`,
  2 `eazybusiness/up/*.sql`.
- **C2 (Ebene B):** 6 `global/up/*.sql`, 11 `global/sprocs/*.sql`, 2 `global/permissions/*.sql`,
  1 `global/runAfterOtherAnyTimeScripts/*.sql`.
- **C4 docs:** `docs/SQL/NAMING-CONVENTIONS.md` (the naming SSoT), cross-checked against
  the C1/C2 as-built objects.
- Read but not convention-audited in depth (tests / probes / runbooks / ADRs — not the
  "same operation across chunks" surface): `tests/**`, `probes/**`, `docs/runbooks/**`,
  `adrs/**`.

Cross-checked every finding against the chunk deviation tables (C1-impl / C2-impl) so
documented, defensible D4 deviations are **not** reported.

---

## Findings

### convention-B1-1 (Important) — Naming SSoT claims a convention the Ebene-B objects do not follow

**Files:** `docs/SQL/NAMING-CONVENTIONS.md:178`, `db-migrations/global/up/0002_ops_schema_tables.sql:30-96`

`NAMING-CONVENTIONS.md` §9 (authored by C4 as an as-built snapshot) states:

> "Object naming inside `ops` / `reset` follows the same rules as `Robotico`
> (sections 2–4) …"

…with only two listed exceptions (the `internal_` step prefix and `DENY` for secret
columns). Sections 2–4 mandate `t<SingularName>` table names and **Hungarian** column /
parameter prefixes (`k`, `n`, `c`, `f`, `d`, `b`).

The C2 objects contradict this outright:

| Convention (§2–4, per the doc) | C1 `Robotico.*` (follows it) | C2 `ops.*` / `reset.*` (does not) |
|---|---|---|
| Table `t<Name>` | `Robotico.tPaypalAccessToken`, `tPaypalSettings` | `ops.Mandant`, `ops.Config`, `ops.ResetRequest` (no `t`) |
| Column Hungarian prefix | `kKey`, `cScope`, `nExpiresInSeconds`, `dTokenCreated`, `bProduction` | `MandantKey`, `TargetDb`, `DisplayName`, `RequestId`, `Status`, `StepLog` (PascalCase, none) |
| Parameter Hungarian prefix | `@kArtikel`, `@fieldName` | `@TargetDb`, `@RequestId`, `@DisplayName`, `@LoginName` |
| Index `IX_` / unique `UQ_` | `IX_Robotico_tPaypalSettings_cKey` | `UX_ResetRequest_Active` (neither prefix) |

So the same operation — naming our own tables/columns — is done one way in C1 and a
different way in C2, and the naming doc misdescribes the C2 half. The PascalCase choice
for an admin DB is a reasonable, self-consistent local convention; the defect is that the
**SSoT lies about it**. A future maintainer adding an `ops.*` table will follow §9 → §2–4
literally and produce `ops.tSomething` with `cName` columns, drifting the schema.

**Suggested fix:** correct §9 to *document* the Ebene-B convention rather than claim §2–4
apply — e.g. "the `ops`/`reset` admin schemas deliberately use PascalCase, unprefixed
identifiers (no `t`/Hungarian), matching standard admin-DB style; only the object-type
name-shapes of §2 carry over." (Renaming the shipped tables is the more expensive
alternative and not recommended — the columns are referenced across 11 reset procs.)
`UX_ResetRequest_Active` could also be renamed `UQ_ops_ResetRequest_Active` for §2
consistency, or the doc note can cover it.

### convention-B1-2 (Nice-to-have) — `SET NOCOUNT ON` applied inconsistently across the ported procs

**Files:** `db-migrations/eazybusiness/sprocs/Robotico.spPaypalGetAccessToken.sql:14`,
`Robotico.spPaypalCreateAccessToken.sql`, `Robotico.spPaypalTrackingCallApi.sql`,
`CustomWorkflows.spPaypalTrackingVersand.sql`, `CustomWorkflows.spPaypalTrackingLieferschein.sql`

Every stored procedure in the block opens with `SET NOCOUNT ON;` — **except** the five
PayPal procs, which have none. All 8 other C1 procs (history / custom-field / Gebinde /
duplicate) and all 11 C2 `reset.*` procs include it. The C1 report documents the port
normalization (`GO;`→`GO`, `DROP+CREATE`→`CREATE OR ALTER`, stripped transaction
scaffolding) but not NOCOUNT, so this is undocumented drift rather than a stated deviation:
the normalization pass harmonized every proc's scaffolding except these five. Harmless at
runtime, but it is exactly the "same operation done differently" the audit targets.

**Suggested fix:** add `SET NOCOUNT ON;` as the first body statement of the five PayPal
procs (inside `BEGIN`), matching the rest of the block.

### convention-B1-3 (Nice-to-have) — File-header comment style diverges between C1 and C2

**Files:** all `db-migrations/eazybusiness/**/*.sql` vs all `db-migrations/global/**/*.sql`

C1 files open with a boxed banner
(`-- ===…===` / `-- ObjectName — purpose` / `-- ===…===`); C2 files open with a plain
`-- object.name  (Ebene B / global — …)` one-liner and no box. Both styles are internally
consistent within their chunk, and the `@see` anchor convention appears only in some C2
`up/` files (`0002_ops_schema_tables.sql`) and not in C1. Purely cosmetic, but it is a
cross-chunk layout inconsistency a reader notices immediately.

**Suggested fix:** pick one header shape (the boxed C1 form is the richer one) and note it
in `db-migrations/README.md` §3 as the file-header convention, or leave as-is if the
divergence is accepted — low priority.

---

## Out-of-scope observations (for the consolidator)

- **Error-signaling idiom** (`RAISERROR(...,16,1)` in C1 domain validation vs
  `THROW 51xxx,…` in C2) maps cleanly to faithful-port (C1) vs new-code (C2) and CATCH
  re-raises use bare `THROW;` uniformly — this is a **documented, defensible** split
  (C1-impl deviation table), so it is *not* raised as a finding.
- **Comment typo** in `CustomWorkflows.spPaypalTrackingVersand.sql:8`: the port note reads
  `GO; -> GO;` (should be `GO; -> GO`). Doc-quality nit, belongs to a logic/doc pass.
- **`@kSprache` default** documented as `0 = German` in
  `Robotico.fnGetArticleCustomFieldValue.sql` while `knowledge-jtl-sql` §2 uses `1 = German`
  — correct for the JTL *custom-field* API (kSprache 0 = neutral/default there); noted for
  the `logic` topic, not a convention defect.

## Coverage note

All 27 C1 deploy files and 20 C2 deploy files read at HEAD and diffed. No files skipped in
the deploy chains. Test/probe/runbook/ADR files read for context only (not part of the
cross-chunk "same operation" surface). Lint (`tests/lint-migrations.ps1`) is green and does
not cover naming-doc↔object-name consistency (finding B1-1) or NOCOUNT presence
(finding B1-2), which is why these surface only in a human/convention pass.
