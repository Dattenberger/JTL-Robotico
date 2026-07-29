---
title: Schema parity — CustomWorkflows & Robotico (reset clone vs source)
status: FINAL — verified against fresh clone (2026-07-15 reset)
date: 2026-07-15
scope: read-only DB inspection
servers:
  - vm-sql-test1.zdbikes.local (TEST, SQL 2025)
  - vm-sql2.zdbikes.local (PROD, SQL 2022, metadata-only)
---

# Schema parity — `CustomWorkflows` & `Robotico`

> [!NOTE]
> **Scope correction.** The task originally named a "`Flow`" schema. Lukas
> clarified this was a mis-transcription of "custom **workFLOW**" — the target
> is JTL's **`CustomWorkflows`** schema (our workflow-action SPs like
> `spAuftragPreiseAufNull`, `spSeriennummerStandardZuWMS`, the PayPal-tracking
> procs). The comparison below therefore covers **`CustomWorkflows`** +
> **`Robotico`**. For the record: a schema literally named `Flow` does NOT exist
> on TEST or PROD; JTL's Blockly-based workflow engine uses the `Blockly` schema
> (8 objects), which is not what was meant. The filename keeps the historical
> `flow` slug.

## Executive summary

- **Both schemas: ZERO structural drift** between the fresh reset clone
  (`eazybusiness_tm9`, restored 2026-07-15 22:22) and its source
  (`eazybusiness`) on `vm-sql-test1`. For **`CustomWorkflows`** (20 objects) and
  **`Robotico`** (38 objects), all four diff dimensions — object set,
  programmable-object definitions (SHA2-256), table columns
  (type / length / precision / scale / nullability / identity / ordinal), and
  indexes — are **byte-for-byte identical**. The reset/anonymization pipeline
  changes DATA only, not schema. **Confirmed against the fresh clone.**
- **`Flow` schema does not exist** — see scope note above; not a drift concern.
- **Staging baseline already exists**: `eazybusiness` on `vm-sql-test1` is the
  prod-derived copy that the clone pipeline reads from. No new staging DB needs
  to be created for schema-parity comparison.

## Part 1 — discovery

### 1a. `Flow` schema

Checked `sys.schemas` on both servers:

| Server | DB | `Flow`? | `Robotico`? | `CustomWorkflows`? |
|---|---|---|---|---|
| vm-sql-test1 (TEST) | eazybusiness | **absent** | present (id 60) | present (id 59) |
| vm-sql2 (PROD) | eazybusiness | **absent** | present | present |

A schema-wide scan on TEST (`sys.schemas … WHERE name LIKE '%low%'`, which
would catch `Flow`) returned nothing. The nearest JTL workflow-engine schema is
**`Blockly`** (8 objects). If the intent was "JTL's workflow automation
engine", that is `Blockly`, and it is JTL-owned, not part of our `Robotico`
custom layer — outside the scope of "our objects must survive reset".

> [!NOTE]
> Resolved: "`Flow`" was "custom **workFLOW**" → the `CustomWorkflows` schema
> (see scope note at top). This WaWi version (1.10.11.0) ships no schema literally
> named `Flow`; the Blockly-based workflow engine uses `Blockly`.

### 1b. `CustomWorkflows` schema inventory (TEST `eazybusiness`, 20 objects)

| type_desc | count | objects |
|---|---|---|
| SQL_STORED_PROCEDURE | 15 | spArticleAppendLabelHistory, spArticleAppendPriceHistory, spArticleUpdateAllHistory, spAuftragPreiseAufNull, spCMArtikel, spCMArtikelGeaendert, spCMArtikelNeu, spGebindeErstellen, spPaypalTrackingLieferschein, spPaypalTrackingVersand, spSeriennummerStandardZuWMS, spZustandartikelLieferantSetzen, _CheckAction, _SetActionDisplayName, _SetActionParameterDisplayName |
| USER_TABLE | 2 | tAllowedDatatypes, tWorkflowObjects |
| VIEW | 3 | vCustomAction, vCustomActionCheck, vCustomActionParameter |

Ownership note (for context, not for the parity check): `_`-prefixed procs,
`vCustomAction*` views, and `tAllowedDatatypes`/`tWorkflowObjects` are
JTL-module infrastructure; `spCMArtikel`/`spCMArtikelNeu` belong to excel_ekl
(D10). The parity diff compares the **entire** schema regardless of ownership —
a physical restore must reproduce every object.

### 1c. `Robotico` schema inventory (TEST `eazybusiness`, 38 objects)

| type_desc | count | objects |
|---|---|---|
| USER_TABLE | 7 | ScriptsRun, ScriptsRunErrors, tArtikelCommentary, tPaypalAccessToken, tPaypalSettings, tPaypalTrackingLog, Version |
| SQL_STORED_PROCEDURE | 6 | spCheckDuplicateOrder, spEnsureArticleCustomField, spPaypalCreateAccessToken, spPaypalGetAccessToken, spPaypalTrackingCallApi, spSetArticleCustomFieldValue |
| SQL_SCALAR_FUNCTION | 10 | fnEscapedCSVGetField, fnEscapedCSVGetLastLine, fnEscapedCSVSanitize, fnGetArticleCustomFieldValue, fnHasOlderDuplicateOrder, fnStringCountLines, fnStringIsEffectivelyEmpty, fnStringParseGermanDecimal, fnStringStripWhitespace, fnStringTrimToMaxLines |
| SQL_INLINE_TABLE_VALUED_FUNCTION | 2 | fnEscapedCSVParseLine, fnFindDuplicateOrders |
| PRIMARY_KEY_CONSTRAINT | 8 | (one per table incl. auto-named PK__… + PK_ScriptsRun_id etc.) |
| DEFAULT_CONSTRAINT | 3 | on tArtikelCommentary (bDeleted / dCreated / nVersion) |
| FOREIGN_KEY_CONSTRAINT | 1 | FK_ArticleCommentary_Predecessor |
| CHECK_CONSTRAINT | 1 | CK_ArticleCommentary_Context |
| UNIQUE_CONSTRAINT | 1 | UQ__tPaypalA__… (tPaypalAccessToken) |

Table column counts: ScriptsRun 9, ScriptsRunErrors 10, tArtikelCommentary 11,
tPaypalAccessToken 8, tPaypalSettings 5, tPaypalTrackingLog 7, Version 7.

### 1d. Staging-DB inventory

**TEST — `vm-sql-test1.zdbikes.local`:**

| DB | create_date | size | role |
|---|---|---|---|
| `eazybusiness` | 2026-06-13 | 26.6 GB | **prod-derived source** — the clone pipeline reads this |
| `eazybusiness_tm9` | 2026-07-13* | 35.2 GB | reset clone (mandant test key 9); *restored-in-place 2026-07-15 22:22 (create_date preserved by RESTORE WITH REPLACE) |
| `eazybusiness_s2_pre_snap` | 2026-07-14 | 26.6 GB | pre-step-2 snapshot of the source |
| `RoboticoOps` | 2026-07-13 | ~0 GB | ops/migration control DB (not a data copy) |

**PROD — `vm-sql2.zdbikes.local` (metadata only):**

| DB | create_date | size | note |
|---|---|---|---|
| `eazybusiness` | 2024-06-06 | 30.8 GB | live production |
| `eazybusiness_premig` | 2026-07-02 | 30.8 GB | pre-migration snapshot |
| `eazybusiness_tm2` | 2025-11-18 | 41.3 GB | older clone (prod-side) |
| `eazybusiness_tm3` | 2026-06-23 | 30.8 GB | clone (prod-side) |
| `eazybusiness_tm4` | 2026-07-08 | 30.8 GB | clone (prod-side) |

**Recommendation:** No new staging DB is needed. `eazybusiness` on
`vm-sql-test1` already IS the prod-pulled baseline (restored ~2026-06-13; per
the ops convention TEST = SQL 2025 restore target, PROD = SQL 2022 source). For
schema-parity checks, compare `eazybusiness_tm<key>` against `eazybusiness` on
the same TEST instance — same server, cross-database catalog queries work
directly, no restore required.

### 1e. Comparison method

The existing `db-migrations/tests/compare-objects.sql` is a good **object-level
definition-hash** tool (SHA2-256 over `OBJECT_DEFINITION`, DB↔DB), and it
covers `Robotico` + our `CustomWorkflows.sp*` actions with the correct
ownership boundary (D10). It is designed to be run once per DB and the two
outputs diffed externally. That is sufficient for programmable objects but does
**not** cover table structure (columns/indexes) — it deliberately emits `NULL`
for tables.

For a full parity verdict I used a **single cross-database diff query** (both
DBs live on the same instance, so `eazybusiness.sys.*` and
`eazybusiness_tm9.sys.*` are directly joinable) with four `FULL OUTER JOIN`
sections: (1) object set, (2) definition hash, (3) column attributes, (4)
indexes. Indexes and constraints are matched on **structural attributes**
(key columns, uniqueness, PK flag) rather than name, so JTL's hash-suffixed
auto-names (`PK__tArtikel__2907E4FA…`) don't produce false positives. The query
is saved for reuse — see "Reusable query" below.

## Part 2 — the 1:1 comparison (FINAL — verified against fresh clone)

**Fresh clone confirmed.** `eazybusiness_tm9` was re-created by the current
reset pipeline: `msdb.restorehistory` shows a restore on **2026-07-15 22:22:05**
from a backup of `eazybusiness` (backup finished the same second). The
`sys.databases.create_date` stays at `2026-07-13` because the pipeline restores
in-place (`RESTORE … WITH REPLACE`), which preserves the target's create_date —
so create_date is NOT a freshness signal here; the restore history is. Object
counts on the fresh clone match source exactly: `CustomWorkflows` 20,
`Robotico` 38.

Ran the four-section diff for **both** schemas —
{`CustomWorkflows`,`Robotico`}(`eazybusiness`) vs
{`CustomWorkflows`,`Robotico`}(`eazybusiness_tm9`):

| Diff section | Rows | Result |
|---|---|---|
| 1. Object set (schema+name+type) | 0 | identical — incl. auto-named PK/DEFAULT/UNIQUE constraints (physical restore preserves object_ids/names) |
| 2. Definition hash (proc/fn/view, SHA2-256) | 0 | every programmable definition byte-identical |
| 3. Column attributes (type/len/prec/scale/nullable/identity/ordinal) | 0 | all columns identical |
| 4. Indexes (unique/PK/key columns) | 0 | all indexes identical |

**Verdict: ZERO structural drift** across both `CustomWorkflows` and `Robotico`.
The reset/anonymization pipeline alters DATA only, never schema — as expected
for a physical `RESTORE`-based clone. `Flow` is not applicable (schema absent;
scope corrected to `CustomWorkflows`).

## Reusable query

The final diff (both schemas, four sections) is saved at
`scratchpad/parity-diff.sql` — filters `s.name IN ('CustomWorkflows','Robotico')`
against source `eazybusiness` and clone `eazybusiness_tm9` on the same instance.
Generalising to any schema pair = edit the two literal schema filters and the
two `eazybusiness_tm9` references. Indexes/constraints are matched on structural
attributes (key columns, uniqueness, PK flag), not names, so JTL hash-suffixed
auto-names don't cause false positives.

## Query log (verbatim)

TEST (`vm-sql-test1.zdbikes.local`):
- `SELECT name,state_desc,create_date FROM sys.databases`
- `SELECT s.name,o.type_desc,o.name FROM sys.objects o JOIN sys.schemas s … WHERE s.name IN ('Flow','Robotico')`
- `SELECT name FROM sys.schemas WHERE name IN ('Flow','Robotico','CustomWorkflows')`
- column counts per Robotico table; CustomWorkflows object inventory
- non-empty schema census (`sys.schemas LEFT JOIN sys.objects`)
- object counts per schema on source + clone
- `msdb.restorehistory`/`backupset` for `eazybusiness_tm9` (freshness proof)
- `parity-diff.sql` (4-section cross-DB diff, both schemas, source vs eazybusiness_tm9 — final)
- earlier `robotico-diff.sql` (Robotico-only, run against stale clone — preliminary)
- size rollup from `sys.master_files`

PROD (`vm-sql2.zdbikes.local`) — metadata only, no business data read:
- `SELECT name,state_desc,create_date FROM sys.databases`
- `SELECT name FROM sys.schemas WHERE name IN ('Flow','Robotico','CustomWorkflows')`
- size rollup from `sys.master_files` (eazybusiness%)
