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
| `CustomWorkflows.spCheckDuplicateOrder` | stored procedure (registered action) | thin wrapper; lives in `CustomWorkflows`; first parameter is the workflow object PK `@kAuftrag` |

---

## References

Source documents in the `excel_ekl` repository
(`/home/lukas/WebStorm/excel_ekl/docs/SQL/`):

- `SCHEMA-ARCHITECTURE.md` — schema separation + general naming conventions
  (basis for sections 1–4).
- `SP-NAMING-CONVENTIONS.md` — RoboticoEKL-specific `spPub_` / orchestration
  layer (explicitly **not** adopted here, see section 5).
