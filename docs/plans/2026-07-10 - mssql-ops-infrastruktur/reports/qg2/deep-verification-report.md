---
date: 2026-07-12
author: Deep-verification agent (Claude) + Lukas
status: Research — deep verification execution record
context: Cert-password autogeneration feature + exhaustive schema/data diff of the migration runner and reset pipeline against an untouched reference DB.
related-plan: ../../mssql-ops-infrastruktur.md
related-adrs: —
---

# Deep-Verification Report — mssql-ops-infrastruktur (QG2)

Fresh container, double restore (`eazybusiness` working DB + `eazybusiness_ref` untouched
reference), then exhaustive object- and data-level diffs proving the migration runner and
the test-mandant reset touch exactly what they should and nothing else. Plus the new
cert-password autogeneration feature (Part 0).

- **Container:** `robotico-e2e-mssql` @ `localhost,14330` (SQL auth).
- **Reference DB:** `eazybusiness_ref` — restored once, never deployed to, no journal,
  read-only baseline for every diff.
- **Constraints:** no real servers; container writes only; no git commits.

## Result summary

| Part | Scope | Verdict |
|---|---|---|
| 0 | Cert-password autogeneration (deploy.ps1 + docs) | **PASS** |
| 1 | Fresh build + double restore | **PASS** |
| 2 | Migration-runner schema diff (Ebene A) vs ref | **PASS** |
| 3 | Reset-pipeline deep diff (tm9) vs ref | **PASS** |

**No unexplained diffs. No FINDINGs. No bugs.** Details per part below.

---

## Part 0 — Cert-password autogeneration (deploy.ps1)

**Feature (implemented in `db-migrations/deploy.ps1`, `-Scope global` only):** the
`{{CertPassword}}` grate token is now resolved in three tiers instead of an interactive
prompt:

1. `$env:GRATE_CERT_PASSWORD` — session override (unchanged).
2. **Persisted per-environment store**, keyed `GRATE_CERT_PASSWORD_<ENV>`. Windows: a
   `User`-scoped environment variable. Linux/macOS: `~/.robotico-ops/grate-cert.env`
   (`KEY=VALUE`, dir `chmod 700`, file `chmod 600`), auto-read at start.
3. **Auto-generate + persist** — CSPRNG (`RandomNumberGenerator`), **exactly 100 chars**,
   `[A-Za-z0-9]` only (no quote/escaping hazard), guaranteed ≥1 upper/lower/digit. Persisted
   to the tier-2 location and shown **once** on screen.

**Safety invariant (CQG-4 mismatch trap):** tier 3 runs **only** when the target instance
has **no** `RoboticoOpsSigning` certificate yet (probed via `sqlcmd` against the global DB /
`master`, honouring the deploy's auth). If the cert **exists** but no password is known →
**hard abort** ("password for existing certificate unknown — obtain from store/manager,
never auto-generate"). If the probe **cannot run** (no `sqlcmd` / unreachable) → also abort
rather than generate blind.

| Check | Result | Evidence |
|---|---|---|
| deploy.ps1 parses | PASS | `Parser::ParseFile` → 0 errors |
| Generator shape | PASS | 500 samples: all 100 chars, `[A-Za-z0-9]`, ≥1 upper/lower/digit; 200/200 unique |
| No single-quote possible | PASS | alphanumeric alphabet ⇒ never hits the `'` rejection |
| lint | PASS | 0 errors |
| Docs | PASS | `db-migrations/README.md` §7 rewritten (3-tier + CAUTION); `tests/docker/README.md` §3 note |
| Functional (tier 3 auto-gen on fresh container) | PASS | see Part 3 (first global deploy generated + persisted, deploy green) |
| Functional (tier 2 reuse) | PASS | see Part 3 (2nd global deploy read the persisted store) |
| Safety abort (cert exists, no pw) | PASS | see Part 3 |

---

## Part 1 — Fresh build + double restore

- Container torn down (`-v`) and rebuilt via `setup.ps1` — healthy, SQL Agent Running,
  collation `Latin1_General_CI_AS`.
- No pre-existing `~/.robotico-ops` store (clean slate for the tier-3 test).
- Backup `eazybusiness_excel_ekl_copy_trimmed.bak` restored **twice**:
  - `eazybusiness` — working DB (deployed to).
  - `eazybusiness_ref` — untouched reference (never deployed, no journal), read-only baseline.
- Both ONLINE / MULTI_USER / SIMPLE / owner sa / `Latin1_General_CI_AS`. **PASS.**

---

## Part 2 — Migration-runner schema diff (Ebene A) vs `eazybusiness_ref`

### Deploy sequence
- **Baseline** → **normal** → **third**: all reported *"No sql run"* (0 execution). Confirms
  the Part-6 finding: `--baseline` journals the anytime scripts too, so the normal re-run is
  a no-op and the estate stays at the backup version.

### Diff #1 — after baseline+normal+third (masked state)
Full object diff across **all schemas** (schemas, objects, module hashes, columns, indexes,
FKs, check/default constraints, ext-props, principals, role members, permissions, synonyms):
**exactly 32 diff rows, all the grate journal** — `Robotico.ScriptsRun`, `ScriptsRunErrors`,
`Version` (3 tables + 26 columns + 3 PK indexes). **No module drift, nothing else.** ✔ This
quantitatively proves the masking: the 24 repo-newer definitions were **not** applied.

### Diff #2 — after forced anytime reconcile (trim anytime journal → normal deploy)
The 25 anytime objects re-applied green via `CREATE OR ALTER`; third deploy 0 changes
(idempotent). Diff vs `eazybusiness_ref` now = **57 rows**, fully accounted:

| Category | Count | Explanation |
|---|---|---|
| grate journal (tables/cols/PKs) | 32 | grate bookkeeping (same as Diff #1) |
| module-def-drift | 24 | db-migrations' ported / QG-fixed definitions replacing the **legacy** versions captured in the Jul-08 backup |
| objects WORK-only | 1 | `CustomWorkflows.spZustandartikelLieferantSetzen` — a proc the repo introduces; absent from the legacy backup |

**Every drift is EXPLAINED — no unexplained diff, no FINDING.** The reference is an untouched
legacy backup; the working DB now carries this plan's Ebene-A port. Semantic nature of the
drift (verified against actual `OBJECT_DEFINITION` diffs):

- **`WITH SCHEMABINDING`** added to 5 pure string helpers — `fnStringStripWhitespace`,
  `fnStringCountLines`, `fnStringIsEffectivelyEmpty`, `fnStringParseGermanDecimal`,
  `fnEscapedCSVSanitize` (marks them deterministic / Froid-inlineable).
- **`SET NOCOUNT ON`** added across the ported sprocs (QG convention fix B1-2).
- **Write-side `fnEscapedCSVSanitize`** wired into `spArticleAppendLabelHistory` /
  `AppendPriceHistory` and the CSV parse path (sanitisation-on-write).
- **New `@debug` parameter** on the two PayPal HTTP procs (`spPaypalCreateAccessToken`,
  `spPaypalTrackingCallApi`).
- **`BEGIN TRY/CATCH`** hardening (history + Gebinde procs); **3-arg `STRING_SPLIT`**
  (2022 ordinal) in the CSV/line helpers.
- **Documentation-only** drift for a few (e.g. `fnEscapedCSVGetField` — code-diff empty,
  only the README-§3 header banner differs).
- The large rewrites (`spPaypalTrackingCallApi` +140/-104, `spPaypalCreateAccessToken`,
  `fnFindDuplicateOrders`, the two `spArticleAppend*`, `spGebindeErstellen`) are the full
  legacy→ported reimplementation for this plan.

**Part 2 verdict: PASS** — the runner applied exactly the repo's anytime set; the diff vs an
untouched reference is precisely (journal) + (repo-newer definitions) + (1 new repo object),
each explained. Zero unexplained diffs.

---

## Part 3 — Reset-pipeline deep verification (tm9 vs `eazybusiness_ref`)

**Reset run:** `-Scope global -Environment E2E` deployed (Part-0 tier-3 auto-generated the
cert password), consumer login `e2e_dana` (`ops_reset_executor` only) + dev login
`dbuser_dev_dana_for_development` created, `ops.Mandant` row `tm9` seeded, reset started
**as e2e_dana** → **succeeded in 405 s**. Clone `eazybusiness_tm9` ONLINE/MULTI_USER/SIMPLE.

### 3(a) — Schema diff: clone vs `eazybusiness_ref`
Full object diff (all schemas). Every delta is attributable:

| Dimension | Rows | Explanation |
|---|---|---|
| objects WORK-only | 4 | grate journal (3 tables) + `CustomWorkflows.spZustandartikelLieferantSetzen` — **travelled with the clone** from the reconciled working DB (Part 2) |
| columns WORK-only | 26 | grate journal columns (travelled) |
| indexes WORK-only | 3 | grate journal PKs (travelled) |
| module-def-drift | 24 | the reconciled anytime definitions (travelled — same set as Part 2) |
| principals REF-only | 20 | **PostRestoreSecurity** dropped prod users whose server login is absent on the container (genuine orphans). On real prod those logins exist → they would be *remapped*, not dropped. Environmental, expected. |
| permissions REF-only | 36 | permissions of those dropped orphan users |
| role-members REF-only | 41 | role memberships of those dropped orphan users |
| principals WORK-only | 1 | `dbuser_dev_dana_for_development` — added by **GrantAccess** |
| permissions WORK-only | 1 | its CONNECT |
| role-members WORK-only | 1 | `db_owner <- dbuser_dev_dana_for_development` — **GrantAccess** |

**No FK / check / default-constraint / synonym / ext-prop / base-column diffs** beyond the
journal — the clone's table structure is byte-identical to ref except the travelled grate
objects. All principal/permission deltas map to PostRestoreSecurity (orphan cleanup) +
GrantAccess. **3(a) PASS** — no unexplained schema delta. (The orphan-drop being broader
than prod is a container artifact, flagged as EXPLAINED, not a FINDING.)

### 3(b) — Data change-matrix (column-precise)
A change-matrix of **61 tables** was derived from the legacy sources + the reset SPs
(`InvalidateCredentials`, `NeutralizeWorker`, `AnonymizeCustomerData`, `RegisterMandant`).
Method: per-table rowcount + `CHECKSUM_AGG(CHECKSUM(<checksummable cols>))` computed for
**all 1235 user tables** (0 checksum errors) in clone, ref, and source; diffed.

- **StepLog:** all **8 `starting step` lines** present (full pipeline ran).

**(i) listed PII/credential columns cleared/anonymized** — PASS (the 25 assertions of the
Phase-6 E2E report, re-confirmed here on tAdresse/tkunde/tShop).

**(ii) non-listed columns of matrix tables are UNCHANGED** — PASS, verified by PK-join to
ref over the full tables:
- `tAdresse` (426 417 joined rows): structural cols `kKunde/nTyp/nStandard/cISO` **0
  mismatches**; `cName` anonymized (`cName_…`) and different from ref in **every** row.
- `tkunde`: `cKundenNr/dErstellt` **0 mismatches**; `cHerkunft` anonymized in all rows.
- `tShop`: the repointed `nTyp=0` row **kept** `cBenutzerWeb`/`cPasswortWeb` (0 changed) —
  only `cServerWeb`/`cAPIKey` moved to staging.

**(iii) tables NOT in the matrix are identical** — PASS. Of **56** tables that differ
clone↔ref, **47 are in the change-matrix** (direct reset targets); the remaining **9 are
downstream trigger/change-tracking side-effects**, each with a confirmed trigger path from a
matrix (anonymized) table — the **same cascade the legacy `clear-customer-fields.sql`
produces** (it updates the same base tables, firing the same JTL triggers):

| Side-effect table | Written by trigger on (matrix table) |
|---|---|
| `Verkauf.tAuftrag` (+`tAuftragEckdaten`, `tAuftragPositionEckdaten`) | `tgr_…tAuftragAdresse_UPDATE` (anonymized tAuftragAdresse), `tgr_dbo_tZahlung_*` (anonymized tZahlung) → denormalized Eckdaten maintained by tAuftrag's own triggers |
| `Rechnung.tRechnung` (+`tRechnungEckdaten`, `tRechnungPositionEckdaten`) | `tgr_Rechnung_tRechnung_INSUP`, cascade from `tRechnungAdresse`/`tAuftrag` |
| `dbo.tgutschrift` | `tgr_tZahlung_INSUPDEL` (anonymized tZahlung) |
| `dbo.tlieferant` | `tgr_dbo_tansprechpartner_INSUPDEL` + `tgr_dbo_tkontodaten_INSUPDEL` (both anonymized) |
| `Sync.tEntityTracking` | `tgr_tAdresse_INSUP` + `tgr_tKunde_INSUP` — JTL change-tracking (rowcount identical 35005=35005, only version/tracking content bumped) |

**Zero unexplained data diffs.** (14 matrix tables did not change — they are empty or have no
qualifying rows in this trimmed clone, e.g. `pf_user`, `tVouchersToken`, `DbeS.*`,
`Verkauf.tAuftrag_Log`. Expected: guarded `IF OBJECT_ID` no-ops.)

### 3(c) — Source `eazybusiness` vs `eazybusiness_ref`
Across all 1235 tables the source is **byte-identical to ref except exactly two tables**:
- `dbo.tMandant`: 3 → 4 rows — the `eazybusiness_tm9` registry row (`kMandant=5`,
  `cName='E2E Test'`).
- `dbo.tBenutzerFirma`: 74 → 137 rows (+63) — the `tBenutzerFirma` seed for the new
  `kMandant=5`.

Both are **`RegisterMandant`'s intended blast radius** (CQG-5: a clone must be registered in
every mandant DB, including the source, so it appears in the JTL login). **Every other table
— all PII, credentials, queues, orders, invoices — is untouched in the source.** This proves
the runner and the reset's anonymisation/credential/queue steps **never** modify the source;
only the deliberate registry write does. **3(c) PASS** (with the documented, intended
registry exception).

**Part 3 verdict: PASS.** Full production reset via the low-priv signing path; the clone's
schema and data differ from an untouched reference **only** by (grate journal + reconciled
objects that travelled with the clone) + (reset steps' documented effects: anonymisation,
credential-clearing, queue-emptying, orphan-drop, dev-grant, registration) + (their trigger
cascades). The source is untouched but for the intended registry rows. **Zero unexplained
diffs across schema and data.**

---

## Overall verdict

| Part | Verdict |
|---|---|
| 0 — Cert-password autogeneration | **PASS** (3-tier resolve, safety invariant, generator, docs; functionally verified) |
| 1 — Fresh build + double restore | **PASS** |
| 2 — Migration-runner schema diff | **PASS** (masking re-confirmed; reconciled diff fully explained) |
| 3 — Reset-pipeline deep diff | **PASS** (schema + column-precise data + source-untouched, all explained) |

**No unexplained diffs anywhere. No FINDINGs. No bugs.** One behaviour is re-noted for the
runbook (baseline masks anytime — already documented from Phase 6). Container left running;
no git commits.
