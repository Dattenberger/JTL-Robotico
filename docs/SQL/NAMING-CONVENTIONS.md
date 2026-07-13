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

The `excel_ekl` repo defines a 4-layer article-orchestration apparatus in
[`SP-NAMING-CONVENTIONS.md`](#references): the `@bRunOrchestration BIT = 1`
parameter and the `spPub_` / `spApply` / `spCM` / `spCreate`/`spAppend` call
architecture.

That **orchestration apparatus** exists to control **one specific thing**:
whether the article orchestrator `RoboticoEKL.spCMArtikel` runs at the end of a
mutation, and to prevent recursion inside the article-phase system. It is bound
to that system and has **no counterpart in our use cases** — porting the
`@bRunOrchestration` recursion-control layering here would be cargo-culting.

We keep the **general** conventions (sections 2–4) and — for the Ebene-B
`RoboticoOps` procedures (§9) — the `spPub_` (public entry) / `spInternal_`
(pipeline step) **naming markers**, which cleanly express our own
public-vs-internal reset split. What we drop is only the article-phase
*orchestration mechanism* above, not the public/internal naming idea. The
Ebene-A `Robotico.*` workflow procedures stay plain `sp` (§7): single-layer,
workflow-facing, with no public/internal distinction to mark.

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
| `ops.*` | this project | registry & state: `ops.tMandant`, `ops.tConfig`, `ops.tResetRequest`, `ops.tResetStep`, grate journal |
| `reset.*` | this project | reset procedures: `reset.spPub_StartTestmandantReset`, `reset.spPub_GetResetStatus`, `reset.spProcessNextResetRequest`, `reset.spEnsureAgentJob`, `reset.spInternal_*` |

### Naming: the JTL / RoboticoEKL Hungarian convention (aligned with §2–4)

`RoboticoOps` Ebene-B objects follow the **same JTL / RoboticoEKL Hungarian convention** as
the `Robotico.*` objects in §2–4: `t`-prefixed tables, Hungarian column prefixes
(`c`/`k`/`b`/`d`/`n`), and `sp`-prefixed procedures. This aligns the admin DB with the
`RoboticoEKL` naming standard and with the tooling that expects it.

> [!NOTE]
> This **replaces** an earlier decision that gave `ops.*` / `reset.*` a plain PascalCase,
> un-prefixed "admin-DB" style (un-prefixed tables, PascalCase columns, `sp`-less procedures).
> Ebene B was renamed onto the Hungarian convention; the examples below are the current,
> binding names.

| Element | Ebene-B convention | Example |
|---|---|---|
| Table | `t<SingularName>` | `ops.tMandant`, `ops.tResetRequest`, `ops.tConfig`, `ops.tResetStep` |
| Column (string) | `c<Name>` | `cMandantKey`, `cTargetDb`, `cStatus`, `cStepLog` |
| Column (INT key) | `k<Table>` | `kResetRequest`, `kResetStep` |
| Column (BIT flag) | `b<Name>` | `bActive`, `bEnabled`, `bCritical` |
| Column (DATE/DATETIME) | `d<Name>` | `dCreated`, `dModified`, `dStarted`, `dFinished`, `dRequested` |
| Column (non-key INT) | `n<Name>` | `nStepOrder` |
| Parameter | PascalCase with `@` (marks a value, not a stored column) | `@TargetDb`, `@RequestId`, `@MandantKey` |
| Public procedure | `spPub_<ActionName>` | `reset.spPub_StartTestmandantReset`, `reset.spPub_GetResetStatus` |
| Internal pipeline step | `spInternal_<Name>` | `reset.spInternal_CloneDatabase` |
| Orchestrator / infra procedure | `sp<Name>` | `reset.spProcessNextResetRequest`, `reset.spEnsureAgentJob` |

Constraints and indexes follow the section-2 `<prefix>_<Table>_<Col>` style, keyed on the
`t`-prefixed table name (the schema qualifier is dropped — the `t`-prefixed table name is
already unambiguous):

| Constraint / index | Convention | Example |
|---|---|---|
| Primary key | `PK_<Table>` | `PK_tMandant` |
| Foreign key | `FK_<Table>_<Ref>` | `FK_tResetRequest_tMandant` |
| Unique constraint | `UQ_<Table>_<Cols>` | `UQ_tMandant_cTargetDb` |
| Check | `CK_<Table>_<Col>` | `CK_tMandant_cTargetDb` |
| Default | `DF_<Table>_<Col>` | `DF_tMandant_bActive` |
| Standalone (filtered) unique index | `IX_<Table>_<Purpose>` | `IX_tResetRequest_Active` |

> [!NOTE]
> `IX_tResetRequest_Active` — the filtered "at most one active request per `cTargetDb`" index
> on `ops.tResetRequest` — is created with `CREATE UNIQUE INDEX`. It carries the `IX_` prefix
> and is intentionally not schema-qualified because an index name is already scoped to its table.

Two further local conventions:
- reset pipeline steps are prefixed `spInternal_` (called only by the job orchestrator, e.g.
  `reset.spInternal_CloneDatabase`);
- column-level secrets (e.g. `ops.tMandant.cShopLicense`) are protected by `DENY` rather than
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
pair exists solely to counter-sign `reset.spPub_StartTestmandantReset` (via `ADD SIGNATURE …
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
