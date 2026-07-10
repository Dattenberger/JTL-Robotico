# SQL Naming Conventions (Robotico schema)

**Status:** Binding for all new SQL objects in the `Robotico` schema of this
repository (JTL-Robotico / `eazybusiness`).
**Scope:** Naming and prefix conventions for tables, views, functions and
stored procedures that we own. Adapted from the JTL-Wawi / RoboticoEKL
conventions in the `excel_ekl` repository (see [References](#references)).

---

## 1. Schema separation

The `eazybusiness` database carries three relevant schemas. Ownership decides
who may write where:

| Schema | Owner | Read | Write |
|---|---|---|---|
| `dbo.*` | JTL-Wawi standard | ✅ | ❌ never (overwritten by JTL updates) |
| `Robotico.*` | **this project (JTL-Robotico)** | ✅ | ✅ |
| `RoboticoEKL.*` | Excel-EKL AddIn (`excel_ekl` repo) | ✅ | ❌ not from here |
| `CustomWorkflows.*` | JTL custom-workflow action layer | ✅ | ✅ (registered actions only) |

Separate schemas keep our objects safe from JTL updates and make ownership
obvious (`SELECT * FROM sys.objects WHERE schema_id = SCHEMA_ID('Robotico')`).

> [!NOTE]
> From the `excel_ekl` repo's perspective, `Robotico.*` is "do not touch".
> The reverse holds here: we own `Robotico.*` and treat `RoboticoEKL.*` as
> read-only foreign territory.

---

## 2. Object naming by type

| Type | Convention | Example |
|---|---|---|
| Schema | PascalCase | `Robotico` |
| Table | `t<SingularName>` | `tPaypalTrackingLog` |
| View | `v<PurposeName>` | `vDuplicateOrders` |
| Scalar function | `fn<Name>` | `fnHasOlderDuplicateOrder` |
| Inline TVF | `fn<Name>` (same `fn` prefix as scalar) | `fnFindDuplicateOrders` |
| Stored procedure | `sp<ActionName>` | `spCheckDuplicateOrder` |
| Index | `IX_<Table>_<Purpose>` | `IX_Verkauf_tAuftrag_kKunde` |
| Primary key | `PK_<Table>` | `PK_tPaypalTrackingLog` |
| Foreign key | `FK_<Table>_<RefTable/Purpose>` | `FK_Verkauf_tAuftrag_kKunde` |
| Unique | `UQ_<Table>_<Columns>` | `UQ_tSalesCache_Artikel_Period` |
| Check | `CK_<Table>_<Column>` | `CK_tArtikelCommentary_Context` |

> [!IMPORTANT]
> Table-valued functions use the **same `fn` prefix** as scalar functions
> (not `tvf`, not `if`). The return type, not the name, distinguishes them.

The name after the prefix is PascalCase: `fnComputeArticlePhasePreview`, not
`fnComputeArticlephasepreview`.

---

## 3. Column and parameter prefixes (Hungarian, JTL standard)

`Robotico` objects follow the JTL-Wawi column convention so they read like the
surrounding `dbo` tables:

| Prefix | Type | Examples |
|---|---|---|
| `k` | INT key (PK/FK) | `kArtikel`, `kAuftrag`, `kKunde` |
| `n` | INT (non-key number) | `nMinutesApart`, `nWindowHours`, `nPuffer` |
| `c` | string (NVARCHAR/VARCHAR/CHAR) | `cAuftragsNr`, `cName` |
| `f` | DECIMAL/FLOAT | `fWertBrutto`, `fGrossValue` |
| `d` | DATE/DATETIME | `dCreated`, `dErstellt` |
| `b` | BIT (boolean flag) | `bIsOlderThanInput`, `bIsDuplicate`, `@bEnabled` |

The `b` prefix applies to BIT **columns, parameters and result-set columns**
alike — it marks the type, independent of language.

---

## 4. Language: English vs. German

- **Feature / public names are English:** `fnFindDuplicateOrders`,
  `spCheckDuplicateOrder`, `vDuplicateOrders`.
- **JTL-table-near names stay German**, because they sit next to JTL tables and
  columns: `Auftrag`, `Artikel`, `Kunde`, `Puffer`. Keeping the actual JTL
  column name (e.g. `cAuftragsNr`) inside an otherwise-English result set is
  correct — it is the real column.
- Parameters bound to a JTL key keep the JTL name even in English objects:
  `@kAuftrag`, not `@kOrder`.

Rule of thumb: the JTL key/column stays German; the surrounding verb + subject
that describes *our* feature is English.

---

## 5. What we deliberately do NOT adopt from RoboticoEKL

The `excel_ekl` repo defines an additional layer in
[`SP-NAMING-CONVENTIONS.md`](#references): the `spPub_` prefix, the
`@bRunOrchestration BIT = 1` parameter and a 4-layer call architecture
(`spPub_` / `spApply` / `spCM` / `spCreate`/`spAppend`).

That apparatus exists to control **one specific thing**: whether the article
orchestrator `RoboticoEKL.spCMArtikel` runs at the end of a mutation, and to
prevent recursion inside the article-phase system. It is bound to that system
and is **not used in the `Robotico` schema here** — applying it would be
cargo-culting a mechanism with no counterpart in our use cases.

We keep only the **general** conventions (sections 2–4), which `excel_ekl`
documents in [`SCHEMA-ARCHITECTURE.md`](#references).

---

## 6. Idempotency pattern for deployment scripts

Deployment scripts are re-runnable and transactional (see the history SPs and
`WorkflowProcedures/Duplikaterkennung_Bestellungen.sql` for the pattern):

```sql
SET XACT_ABORT ON
GO
BEGIN TRANSACTION
GO
-- defensive existence checks for tables
IF NOT EXISTS (SELECT 1 FROM sys.tables
               WHERE name = 'tMyTable' AND schema_id = SCHEMA_ID('Robotico'))
    CREATE TABLE Robotico.tMyTable ( ... );
GO
-- functions / procedures
CREATE OR ALTER FUNCTION Robotico.fnMyFunction ( ... ) ...
GO
IF XACT_STATE() = 1 COMMIT TRANSACTION; ELSE ROLLBACK TRANSACTION;
GO
```

---

## 7. Worked example — duplicate order detection

The three objects in `WorkflowProcedures/Duplikaterkennung_Bestellungen.sql`
illustrate the conventions end to end:

| Object | Type | Convention applied |
|---|---|---|
| `Robotico.fnFindDuplicateOrders` | inline TVF | `fn` prefix; output column `bIsOlderThanInput` (`b` = BIT); `@kAuftrag` keeps the JTL key name |
| `Robotico.fnHasOlderDuplicateOrder` | scalar fn (BIT) | `fn` prefix; predicate style `Has…`; English feature name |
| `Robotico.spCheckDuplicateOrder` | stored procedure | `sp` prefix; result-set column `bIsDuplicate` (`b` = BIT); plain `sp` (no `spPub_`) |

---

## 8. Migration journal schemas (Ebene A / Ebene B)

Objects are deployed with [grate](https://github.com/grate-devs/grate) via
[`db-migrations/`](../../db-migrations/README.md), which keeps a **journal** of what ran.
The journal never sits in `dbo` or grate's default `grate` schema — it lives in our own
schema so it respects the vendor boundary and (for Ebene A) travels with a mandant clone:

| Chain | Deploy folder | Journal schema | Journal lives in |
|---|---|---|---|
| **Ebene A** (eazybusiness content) | `db-migrations/eazybusiness/` | `Robotico` | every eazybusiness copy (incl. clones) |
| **Ebene B** (instance uniques) | `db-migrations/global/` | `ops` | the `RoboticoOps` DB of that instance |

The `Robotico` journal tables (`ScriptsRun`, `ScriptsRunErrors`, `Version`) therefore sit
**alongside** our own `Robotico.*` objects. Do not create objects named like grate's
journal tables in `Robotico`.

---

## 9. The `RoboticoOps` admin database (Ebene B)

Instance administration lives in a **separate database**, `RoboticoOps` (collation
`Latin1_General_CI_AS`, recovery SIMPLE, owner `sa`) — deliberately outside the
`eazybusiness_*` namespace so it can never be confused with a mandant clone. It carries two
schemas we own:

| Schema | Owner | Purpose |
|---|---|---|
| `ops.*` | this project | registry & state: `ops.Mandant`, `ops.Config`, `ops.ResetRequest`, grate journal |
| `reset.*` | this project | reset procedures: `reset.StartTestmandantReset`, `reset.GetResetStatus`, `reset.ProcessNextResetRequest`, `reset.EnsureAgentJob`, `reset.internal_*` |

### Naming: admin-DB style, **not** the JTL Hungarian convention

`RoboticoOps` sits **outside** `eazybusiness` and never reads alongside `dbo` JTL tables, so
it deliberately does **not** carry the JTL table/column prefixes of sections 2–4. The reason
those prefixes exist (§3) — "so `Robotico` objects read like the surrounding `dbo` tables" —
does not apply here, because there are no surrounding JTL tables. `ops.*` / `reset.*` use a
plain PascalCase, admin-database style instead:

| Element | Ebene-B convention | Example | Contrast with §2–4 |
|---|---|---|---|
| Table | PascalCase, **no `t` prefix**, singular | `ops.Mandant`, `ops.ResetRequest` | not `ops.tMandant` |
| Column | PascalCase, **no Hungarian prefix** | `MandantKey`, `TargetDb`, `Status`, `StepLog` | not `cName`, `kMandant`, `bIsActive` |
| Parameter | PascalCase with `@` | `@TargetDb`, `@RequestId` | not `@cTargetDb` |
| Procedure | PascalCase, **no `sp` prefix** | `reset.StartTestmandantReset`, `reset.GetResetStatus` | not `reset.spStart…` |

Constraints keep the section-2 prefixed style, but **schema-qualified** so the name stays
globally unambiguous inside the admin DB (`PK_<schema>_<Table>`, not `PK_<Table>`):

| Constraint / index | Convention | Example |
|---|---|---|
| Primary key | `PK_<schema>_<Table>` | `PK_ops_Mandant` |
| Foreign key | `FK_<schema>_<Table>_<Ref>` | `FK_ops_ResetRequest_Mandant` |
| Unique constraint | `UQ_<schema>_<Table>_<Cols>` | `UQ_ops_Mandant_TargetDb` |
| Check | `CK_<schema>_<Table>_<Col>` | `CK_ops_Mandant_TargetDb` |
| Default | `DF_<schema>_<Table>_<Col>` | `DF_ops_Mandant_IsActive` |
| Standalone (filtered) unique index | `UX_<Table>_<Purpose>` | `UX_ResetRequest_Active` |

> [!NOTE]
> Standalone unique indexes created with `CREATE UNIQUE INDEX` (as opposed to an inline
> `UNIQUE` constraint) use the `UX_` prefix to mark them as *unique* indexes, distinct from
> both the non-unique `IX_` and the constraint-borne `UQ_` of §2. `UX_ResetRequest_Active`
> — the filtered "at most one active request per `TargetDb`" index on `ops.ResetRequest` —
> is the sole current example. It is intentionally not schema-qualified because an index name
> is already scoped to its table.

Two further local conventions:
- reset pipeline steps are prefixed `internal_` (called only by the job orchestrator, e.g.
  `reset.internal_CloneDatabase`);
- column-level secrets (e.g. `ops.Mandant.ShopLicense`) are protected by `DENY` rather than
  renamed.

### Principals: roles and signing objects

`RoboticoOps` also introduces server- and database-level **principals** that carry no schema
prefix. They follow admin-DB conventions distinct from §2:

| Element | Convention | Example |
|---|---|---|
| Database role | lowercase `snake_case`, `<area>_<capability>` | `ops_reset_executor`, `ops_admin` |
| Signing certificate | PascalCase, DB name + purpose | `RoboticoOpsSigning` |
| Certificate login | certificate name + `Login` suffix | `RoboticoOpsSigningLogin` |
| Impersonation login | lowercase functional name | `jobstartuser` (disabled + `DENY CONNECT SQL`) |

Roles name the **capability, not the person** — membership is data (the AD group is added in
`permissions/100_grants.sql`, individuals out of band). The certificate / certificate-login
pair exists solely to counter-sign `reset.StartTestmandantReset` (via `ADD SIGNATURE …
BY CERTIFICATE RoboticoOpsSigning` in `permissions/900_resign_procedures.sql`) so the
impersonated `jobstartuser` can cross the `RoboticoOps → msdb` boundary; **do not rename**
either — the signing step and the `WITH EXECUTE AS 'jobstartuser'` proc headers reference
them by name.

`RoboticoOps` is invisible to the excel_ekl runner.

---

## 10. Shared `CustomWorkflows` zone (excel_ekl boundary, D10)

`CustomWorkflows` is **co-inhabited** by our Ebene-A chain and the excel_ekl migration
runner (`RoboticoEKL`). Ownership is a hard, additive contract — each side creates or
alters **only its own named objects**:

- **We own** our `CustomWorkflows.sp*` action procedures. Names/signatures that excel_ekl
  consumes (`Robotico.fnEscapedCSVParseLine`, `_CheckAction`, `_SetActionDisplayName`,
  `vCustomAction`) are a backward-compatibility contract — do not change them.
- **excel_ekl owns** (never touch from here): `spCMArtikel`, `spCMArtikelNeu`, the
  `RoboticoEKL` schema, and `dbo.tWorkflow` rows whose `cName` starts with `EKL …`.
- **Never** `DROP SCHEMA CustomWorkflows` or delete a foreign object; schema creation is
  idempotent (`IF NOT EXISTS`) and compatible on both sides.

The `_CheckAction` / `_SetActionDisplayName` helpers and the `vCustomAction*` views are
**vendor objects** provided by the JTL "Custom Workflow Actions" module — not created by
this repo. Full verbatim contract: [`db-migrations/README.md`](../../db-migrations/README.md)
§5–§6; architecture map: [`MSSQL-OPS-ARCHITECTURE.md`](MSSQL-OPS-ARCHITECTURE.md) §4.

---

## References

Source documents in the `excel_ekl` repository
(`/home/lukas/WebStorm/excel_ekl/docs/SQL/`):

- `SCHEMA-ARCHITECTURE.md` — schema separation + general naming conventions
  (basis for sections 1–4).
- `SP-NAMING-CONVENTIONS.md` — RoboticoEKL-specific `spPub_` / orchestration
  layer (explicitly **not** adopted here, see section 5).
