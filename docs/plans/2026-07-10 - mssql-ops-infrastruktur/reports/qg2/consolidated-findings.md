# QG2 — Consolidated Findings & Implementation Packages

**Consolidator:** Opus (five-perspective quality-gate)
**Inputs:** `qg-code-global.md` (CQG-1..12), `qg-code-eazy.md` (CQE-1..13),
`qg-parity.md` (PAR-1..4), `qg-extensibility.md` (EXT-1..5), `qg-consumer-ops.md` (OPS-1..6)
**Method:** every finding re-verified against the live code (files opened, quoted evidence
re-checked, taboo scan: no `dbo.*` vendor object writes outside the documented anonymization,
no EKL objects, no real-server writes). **Result: 39 ACCEPTED, 1 MERGED, 0 REJECTED.**

The finders were disciplined — no false positives surfaced. The one merge is the StepLog
helper, independently proposed by both the global code-quality lens (CQG-6) and the
extensibility lens (EXT-3).

---

## 1. Verdict table

| ID | Severity | Verdict | Evidence re-check / note |
|----|----------|---------|--------------------------|
| **CQG-1** | important | ACCEPTED | `StartTestmandantReset.sql:60-65` — inner CATCH only tolerates 22022; a non-22022 `sp_start_job` failure re-throws but the `queued` row stays. Confirmed. |
| **CQG-2** | important | ACCEPTED | `internal_CloneDatabase.sql:36-37,57-61` — single `SELECT @DataLogical=name … type_desc='ROWS'`; multi-file source collapses silently. Confirmed. |
| **CQG-3** | important | ACCEPTED | `0011:28`, `900:39-41`, `deploy.ps1:129` — `{{CertPassword}}` spliced raw into single-quoted literals; a quote breaks it (in 900 also inside a dynamic `EXEC`). Confirmed. **deploy.ps1 portion moves to the EAZY slot** (same 10-line block as CQE-1/CQE-8); SQL-side doc note stays with GLOBAL. |
| **CQG-4** | important | ACCEPTED | `0011` one-time vs `900` everytime both consume `{{CertPassword}}`; nothing ties them across deploys. Confirmed. |
| **CQG-5** | important | ACCEPTED | `internal_RegisterMandant.sql:49-52,71-79` — write set is data-driven from `tMandant` (incl. prod `eazybusiness`); non-target failures downgraded to `@warnings`, request still `succeeded`. Confirmed. Prod write is inherent to JTL shared registry (not a taboo violation — it is an UPSERT the legacy `register-mandant.sql` also does); finding is about *documentation + visibility*, correctly scoped. |
| **CQG-6** | important | **MERGED → EXT-3** | Same helper (`internal_AppendStepLog`/`internal_LogStep`) as EXT-3. ~30 inline `UPDATE … StepLog = ISNULL(…)+CONVERT(…,126)+…` sites confirmed across all `internal_*`. Survivor EXT-3 (extensibility owns it — the EXT-1 loop's WARN path assumes it). |
| **CQG-7** | nice | ACCEPTED | `ProcessNextResetRequest.sql:31-32` — `DATEADD(HOUR,-4,…)` hard-coded. Confirmed. `ops.Config` is the established knob home. |
| **CQG-8** | nice | ACCEPTED | Literal `N'RoboticoOps - Testmandant Reset'` in `200_ensure_agent_job.sql`, `StartTestmandantReset.sql`, `EnsureAgentJob.sql` (+ a header-comment copy in `ProcessNextResetRequest.sql`). Confirmed drift trap. |
| **CQG-9** | nice | ACCEPTED | `internal_CloneDatabase.sql:19,27` — no `@SourceDb = @TargetDb` compare; ADR `adr-module-signing-reset` D6 lists "never source==target". Confirmed. |
| **CQG-10** | nice | ACCEPTED | `internal_NeutralizeWorker.sql:29-32` column-guards `pf_user`; `internal_AnonymizeCustomerData.sql:469-477` only `OBJECT_ID`-guards then assumes 6 columns. Confirmed asymmetry; O4 (pf_user shape) is an open question. |
| **CQG-11** | nice | ACCEPTED | `internal_CloneDatabase.sql:22` locals `nvarchar(260)` vs `ops.Config.ConfigValue nvarchar(1000)` (`0002:61`). Silent truncation. Confirmed. |
| **CQG-12** | nice | ACCEPTED | `StartTestmandantReset.sql:23` sets only `NOCOUNT ON`; `ProcessNext` sets `XACT_ABORT ON`. Hygiene asymmetry. Confirmed. |
| **CQE-1** | important | ACCEPTED | `deploy.ps1:129,151` — `CertPassword=$certPassword` reaches grate as `--usertokens=` on the child command line (world-readable process args). Confirmed; partly inherent to grate — fix is doc + gotcha. |
| **CQE-2** | important | ACCEPTED | `spPaypalCreateAccessToken.sql:74-75` `PRINT '@Auth'` (Basic creds) + `PRINT '@ResponseText'` (bearer). Confirmed. `spPaypalTrackingCallApi` analogous. |
| **CQE-3** | important | ACCEPTED | `spGebindeErstellen.sql:70-71` — literal `'81'` as `tGebinde.cName` FK onto `tEinheit.kEinheit`; violates README §4 "never hard-code JTL IDs". Confirmed. |
| **CQE-4** | important | ACCEPTED | `CustomFieldAPI_Tests.sql:245-248` — `IF @returnCode = -1` branch is dead (ported procs throw). Confirmed. |
| **CQE-5** | important | ACCEPTED | `fnEscapedCSVParseLine.sql:24`, `fnStringTrimToMaxLines.sql:37` — 3-arg `STRING_SPLIT(...,1)` (SQL 2022+) undocumented; `CREATE` succeeds, runtime fails on low-compat clones. Confirmed. |
| **CQE-6** | nice | ACCEPTED | `spPaypalCreateAccessToken.sql:85-101` — column-list-less `INSERT … SELECT` with fake aliases `nExpiresIn`/`dAuthDate` (columns don't exist). Confirmed positional fragility. |
| **CQE-7** | nice | ACCEPTED | Five pure scalar UDFs lack `WITH SCHEMABINDING` (blocks Froid inlining). Confirmed table-free. Do NOT schemabind the table-touching functions. |
| **CQE-8** | nice | ACCEPTED | `deploy.ps1:126-127` — `PtrToStringAuto(SecureStringToBSTR(...))`, BSTR never zeroed/freed. Confirmed. |
| **CQE-9** | nice | ACCEPTED | `spPaypalTrackingCallApi.sql` carrier `CASE` with no `ELSE` → NULL → deleted → silent drop. Confirmed. |
| **CQE-10** | nice | ACCEPTED | `compare-objects.sql:5-11` header claims file↔DB; `OBJECT_DEFINITION` only supports DB↔DB. Confirmed misleading. |
| **CQE-11** | nice | ACCEPTED | `lint-migrations.ps1:126-131` validates `NNNN_snake_case` *shape* only; no monotonicity/uniqueness of `up/` numbers. Confirmed. |
| **CQE-12** | nice | ACCEPTED | `spArticleAppendPriceHistory.sql:25,91` — hard-coded `@VAT_RATE = 0.19`; wrong brutto for 7%-articles (display-only history). Confirmed. |
| **CQE-13** | nice | ACCEPTED | `deploy.ps1:96-100` — `-Target` silently ignored under `-Scope global`. Confirmed. |
| **PAR-1** | important | ACCEPTED | `0020_seed_mandant_template.sql:41-43` seeds non-existent `dbuser_dev_tm2/3/4`; `internal_GrantAccess.sql:26-29` skips missing login (D4) → reset `succeeded` with no dev access. Confirmed. (Fix direction — seed the real shared login — is a call for the implementer; the gap is real.) |
| **PAR-2** | nice | ACCEPTED | `revoke-database-access.sql` / `grant-database-access-partial.sql` are standalone, not in the reset pipeline, undocumented as deliberate non-ports. Confirmed. Doc-only, in `Projekte/Testsystem/README.md`. |
| **PAR-3** | nice | ACCEPTED | `internal_AnonymizeCustomerData.sql:29-91` (P1) sets CONTEXT_INFO for `tkunde`/`tAdresse` with no CATCH reset; legacy `clear-customer-fields.sql` reset `0x0` in CATCH. Confirmed regression (low practical impact). |
| **PAR-4** | nice | ACCEPTED | `internal_InvalidateCredentials.sql:61-63` — unconditional "repointed" StepLog, no `@@ROWCOUNT` check. Confirmed. |
| **EXT-1** | important | ACCEPTED | Main deliverable (user mandate). `ProcessNextResetRequest.sql:84-93` fixed EXEC list violates Open/Closed on the exact axis the user named. Registry+whitelist-loop design is sound and D6-preserving. **Correction: registry `up/` script must be `0021_…`, not `0003_…` (0003 = roles).** |
| **EXT-2** | important | ACCEPTED | `ProcessNext.sql:63-68,87-92` param-routing coupling confirmed. Uniform `(@TargetDb,@RequestId,@MandantKey)` contract; prerequisite of EXT-1. |
| **EXT-3** | nice | ACCEPTED (survivor of CQG-6) | `internal_LogStep` + optional `internal_AssertTestClone`. Add to `validate_structure.sql` required list. |
| **EXT-4** | nice | ACCEPTED (decision, no code) | `internal_ApplyJtlRoles.sql:49-57` VALUES literal. Finder's own recommendation: **keep in code** (single SSoT beats runtime-editability); record the decision only. |
| **EXT-5** | nice | ACCEPTED | Coherence tail: new plan-scoped ADR `adr-reset-step-registry.md`, `MSSQL-OPS-ARCHITECTURE.md` §1a.3, `README.md` "Adding a reset step", `0002`/new-`0021` header. Confirmed all four docs go stale otherwise. |
| **OPS-1** | important | ACCEPTED | `100_grants.sql:15-18` grants only Start+GetStatus; `ops.Mandant` readable by `ops_admin` only (`0003_roles.sql:26`); no `reset.ListMandants`. Confirmed discovery gap. |
| **OPS-2** | important | ACCEPTED | Stuck `running` dead-end confirmed: 4h reclaim only at job-body top (`ProcessNext.sql:26-32`), no schedule (`EnsureAgentJob.sql`), and `ops_admin` has `SELECT`-only on `ops.ResetRequest` (`0003_roles.sql:28`) so the runbook's manual `UPDATE` needs raw sysadmin. Confirmed. |
| **OPS-3** | important | ACCEPTED (split) | Every step writes its StepLog line only on success (`internal_CloneDatabase.sql:66-70` etc.); CATCH sets `ErrorText` but the failed step wrote no line. Contradicts `ProcessNext.sql:9-12` header + runbook. **Orchestrator start-line folded into EXT-1 slot 1; consumer-ops does the header/architecture reconciliation.** |
| **OPS-4** | nice | ACCEPTED | `EnsureAgentJob.sql:36-51` — `@on_fail_action=2`, no operator notification; stale-reclaim silent. Confirmed. |
| **OPS-5** | nice | ACCEPTED | `ops.ResetRequest` never purged; `nvarchar(max)` StepLog/ErrorText grow unbounded. Confirmed. Fix or document-as-decision. |
| **OPS-6** | nice | ACCEPTED | `StartTestmandantReset.sql:50-52` throws 51004 on already-queued instead of returning the in-flight `RequestId`/`Status`. Confirmed. |

**Taboo scan result:** clean. The only `dbo.*` writes are the documented anonymization
(inside test-clone-guarded `internal_*` procs, target guarded to `eazybusiness[_]%`) and the
`tMandant` shared-registry UPSERT (CQG-5, inherent + flagged). No EKL objects touched. No writes
to real servers — everything is guarded to clones or is deploy-time DDL.

---

## 2. Sequencing rationale

The conflict-heavy zone is the **reset proc set** (`ProcessNext`, `Start`, all
`internal_*`), edited by four of the five agents. The eazybusiness chain is otherwise fully
independent, and `deploy.ps1` is a second small conflict cluster.

**Ordering principle — establish the sweeping refactor FIRST, then layer targeted fixes on the
final structure.** EXT-2 (uniform signature) + EXT-3 (StepLog helper) + EXT-1 (registry loop)
mechanically rewrite every reset proc's signature and its StepLog framing. Doing them first gives
every later agent a stable base (uniform `(@TargetDb,@RequestId,@MandantKey)` signature, the
`internal_LogStep` helper, the generic loop) to edit, instead of forcing the refactor to preserve
a dozen earlier point-edits. Everything downstream then only touches proc *bodies* the refactor
did not change.

Two deliberate folds (mandate-sanctioned) to avoid double-editing:
- **OPS-3's orchestrator start-line** is implemented inside the EXT-1 loop (slot 1). Consumer-ops
  (slot 3) does only the header/architecture-doc reconciliation.
- **The `deploy.ps1` password block** (CQG-3-deploy-part + CQE-1 + CQE-8, same ~10 lines
  119-130) is owned entirely by the EAZY slot to kill a three-way conflict. GLOBAL keeps only
  CQG-3's SQL-side doc note (0011/900 headers).

Dependency chain that fixes the order 1→2→3→4→5:
- Slot 2 (GLOBAL: CQG-1/CQG-12 on `Start`) **before** slot 3 (OPS-6 on `Start`) → OPS-6 preserves.
- Slot 2 (CQG-7/CQG-8 seed `0020`) **before** slot 4 (PAR-1 seed `0020`) → PAR-1 preserves.
- Slot 1 (EXT-3 adds `internal_LogStep` to `validate_structure`) **before** slot 3 (OPS-1/OPS-2
  add SPs + widen the EXECUTE-AS==signed assertion there).
- Slot 5 (EAZY, incl. `deploy.ps1`) **after** slot 2 → EAZY preserves GLOBAL's CQG-3 SQL note
  cross-ref; EAZY owns the actual `deploy.ps1` edits.

---

## 3. Ordered implementation packages

### Slot 1 — EXTENSIBILITY (foundation refactor)
**Findings:** EXT-2, EXT-3 (absorbs CQG-6), EXT-1, EXT-4 (decision-only), EXT-5.
**Scope:** uniform step contract → StepLog helper → step-registry loop → ADR + docs.

**Implementation notes**
- **EXT-2 first:** give every `internal_*` proc the signature `(@TargetDb sysname,
  @RequestId int, @MandantKey sysname)`; each reads its own inputs from `ops.Mandant`
  (`InvalidateCredentials`→ShopUrl/ShopLicense; `GrantAccess`→LoginName;
  `RegisterMandant`→DisplayName). Drop the orchestrator's `SELECT … FROM ops.Mandant`
  param-fetch block (`ProcessNext.sql:63-68`) and its `@ShopUrl/@ShopLicense/@LoginName/
  @DisplayName` locals.
- **EXT-3:** create `reset.internal_LogStep @RequestId, @Message` owning
  `CONVERT(…,126)` + `NCHAR(10)` + `ModifiedAt`; replace the ~30 inline StepLog UPDATEs
  (incl. RegisterMandant's `@warnings` framing). Keep the per-step `THROW 510xx` guard codes
  **inline** (the number identifies the refusing step) — treat `internal_AssertTestClone` as
  optional; do not lose the code-per-step debugging aid.
- **EXT-1:** new **`up/0021_reset_step_registry.sql`** (NOT `0003` — taken by roles) with
  `ops.ResetStep` + seeded canonical order (git stays SSoT for the default pipeline). Replace the
  fixed EXEC block (`ProcessNext.sql:84-93`) with the whitelist-guarded cursor loop
  (`sys.procedures`, schema `reset`, `internal[_]%` prefix, `QUOTENAME` into `EXEC`). Outer
  structure (reclaim-stale, UPDLOCK/READPAST claim, re-validation, CATCH→failed+MULTI_USER)
  **unchanged**. **Fold OPS-3 here:** write a `'starting step N: <name>'` line via
  `internal_LogStep` *before* each step's EXEC so live progress + failed-step are visible.
- **EXT-4:** no code change — record in the ADR/README that role membership deliberately stays a
  code SSoT (`JTL-Rollen.sql` mirror).
- **EXT-5:** author `adrs/adr-reset-step-registry.md` (D6 narrowing: executable set = deployed
  procs, order/enablement = admin-only data; whitelist mechanism; a/b/c alternatives; cross-ref
  D5/D6 + `adr-module-signing-reset`). Rewrite `MSSQL-OPS-ARCHITECTURE.md` §1a.3 to the
  data-driven pipeline. Add README "Adding a reset step" recipe.

**Coherence obligations:** add `internal_LogStep` (+ `ops.ResetStep` table check) to
`tests/global/validate_structure.sql`; add an `ops.ResetStep` row to the architecture §3 component
table; `0021` gets its own README §3-conformant header; lint (`lint-migrations.ps1`) must still
pass on the new `up/` file.

**Later slots depend on:** the uniform signature, `internal_LogStep`, and the loop. Slots 2–4 must
keep them.

**Expected files:** ~18 (11 reset procs, `ProcessNext`, new `0021`, `validate_structure`, new ADR
draft, `MSSQL-OPS-ARCHITECTURE.md`, `README.md`, `0002` header note).

---

### Slot 2 — GLOBAL (robustness/logic fixes on the refactored procs + cert docs)
**Findings:** CQG-1, CQG-2, CQG-5, CQG-7, CQG-8, CQG-9, CQG-10, CQG-11, CQG-12, CQG-3 (SQL-side
only), CQG-4.

**Implementation notes**
- CQG-1: on non-22022 `sp_start_job` failure, mark the just-inserted row `failed` before re-throw
  (`Start.sql`).
- CQG-12: add `SET XACT_ABORT ON` to `Start`.
- CQG-2: enumerate all `sys.master_files` and build the `MOVE` list dynamically (or at minimum hard-
  FAIL on >1 ROWS file); keep paths param-bound/QUOTENAME-escaped (`CloneDatabase`).
- CQG-9: `IF @TargetDb = @SourceDb THROW 51014 …` after resolving `@SourceDb` (`CloneDatabase`).
- CQG-11: widen `@BackupFile`/`@TargetDataDir` locals to `nvarchar(1000)` (`CloneDatabase`).
- CQG-5: header-document the prod `tMandant` write; count non-target warnings into an explicit
  StepLog summary (via `internal_LogStep`); record the non-fatal decision.
- CQG-10: make P9's `pf_user` update column-guarded (or its own TRY/CATCH→WARN) like
  NeutralizeWorker (`AnonymizeCustomerData`).
- CQG-7: seed `ops.Config('StaleRunningHours','4')` in `0020`; read it at the top of the
  refactored `ProcessNext` with `ISNULL(TRY_CONVERT(int,…),4)`.
- CQG-8: lift the job name into `ops.Config('AgentJobName')` (read in `Start`, `EnsureAgentJob`,
  `200_ensure_agent_job`) or, lighter, cross-reference comments naming the co-owners.
- CQG-3 (SQL-side): document the no-single-quote password constraint in `0011` + `900` headers.
- CQG-4: in `900`, wrap `ADD SIGNATURE` in TRY/CATCH that THROWs a purpose-written
  "password ≠ the one used in 0011" on the private-key error; document the invariant in `0011` +
  README §7.

**Must preserve (from slot 1):** the generic loop in `ProcessNext` (CQG-7 edits its top, not the
loop); `internal_LogStep` for all new StepLog lines; uniform signatures.
**Coherence:** README §7 (cert password), README config-keys table (StaleRunningHours, AgentJobName);
`deploy.ps1` password-char validation is **EAZY's** (slot 5) — leave a `@see` pointer.
**Expected files:** ~11 (`Start`, `ProcessNext`, `CloneDatabase`, `RegisterMandant`,
`AnonymizeCustomerData`, `0020`, `EnsureAgentJob`, `200_ensure_agent_job`, `0011`, `900`, `README`).

---

### Slot 3 — CONSUMER-OPS (discovery + recovery SPs, doc reconciliation)
**Findings:** OPS-1, OPS-2, OPS-3 (docs part), OPS-4, OPS-5, OPS-6.

**Implementation notes**
- OPS-1: new `reset.ListMandants` (own DB, no signature, ownership-chained read of `ops.Mandant`;
  **exclude ShopLicense/ShopUrl**) returning `MandantKey, DisplayName, Developer, TargetDb,
  IsActive` + latest `Status`/`FinishedAt`. Grant EXECUTE to `ops_reset_executor` in `100_grants`.
- OPS-2: new `reset.CancelResetRequest @RequestId` — `queued`→`failed` needs only ownership-chained
  `UPDATE` (no signature); the `running` force-reclaim (confirm no active msdb job run) needs
  `WITH EXECUTE AS 'jobstartuser'`. **If EXECUTE-AS is used, it becomes a 2nd signed proc:** `900`
  auto-signs it (catalog-derived), but `validate_structure.sql:74` asserts "EXECUTE-AS set ==
  signed set (exactly StartTestmandantReset)" — **widen that assertion**. Grant EXECUTE to
  `ops_reset_executor`. Fix the runbook to call this SP; either grant `ops_admin`
  `UPDATE ON ops.ResetRequest` (`0003_roles`) or state the manual path needs sysadmin.
- OPS-3 (docs): reconcile the `ProcessNext` header (`:9-12`) + architecture §1a.3 + runbook wording
  with the now-implemented start-line (implemented in slot 1). Confirm the "starting step" line is
  present.
- OPS-4: wire `sp_add_job @notify_level_email=2 / @notify_email_operator_name` in `EnsureAgentJob`,
  or document failures as pull-only + silent reclaim in the runbook.
- OPS-5: new admin `reset.PurgeOldRequests` (keep last N per mandant / delete old succeeded+failed,
  always keep most recent per mandant) + runbook mention, OR document "retain forever" as accepted.
- OPS-6: on the duplicate case in `Start`, additionally `SELECT` the existing active
  `RequestId`+`Status` so the caller keeps polling.

**Must preserve:** slot-2 edits to `Start` (CQG-1, CQG-12) — OPS-6 adds to the duplicate branch
without reverting them; slot-1 loop.
**Coherence:** add `ListMandants`/`CancelResetRequest`/`PurgeOldRequests` to
`validate_structure.sql` required list + the EXECUTE-AS assertion; `100_grants`; `0003_roles`
(ops_admin UPDATE); runbooks `testmandant-reset-validierung.md` + `rollout-mssql-ops.md`; README
grant table.
**Expected files:** ~11 (3 new SPs, `100_grants`, `0003_roles`, `validate_structure`,
`EnsureAgentJob`, `Start`, `ProcessNext` header, architecture doc, 2 runbooks — count ~11).

---

### Slot 4 — PARITY (legacy-equivalence gaps)
**Findings:** PAR-1, PAR-2, PAR-3, PAR-4.

**Implementation notes**
- PAR-1: seed the three template `LoginName`s to the real existing shared login
  (`dbuser_dev_dana_for_development`) in `0020` so the default reset delivers the legacy result
  out-of-the-box; add an `access-skipped` WARN prefix (via `internal_LogStep`) in
  `internal_GrantAccess` so a skip is obvious in `GetResetStatus`. (Confirm the login name with the
  owner before finalizing.)
- PAR-2: one line in `Projekte/Testsystem/README.md` marking `revoke-…`/`…-partial.sql` as
  deliberate non-ports (out of reset scope).
- PAR-3: wrap the P1 batch of `AnonymizeCustomerData` in `TRY … CATCH SET CONTEXT_INFO 0x0; THROW`.
- PAR-4: check `@@ROWCOUNT` after the `tShop` repoint; WARN (no THROW) on 0 rows via
  `internal_LogStep` (`InvalidateCredentials`).

**Must preserve:** slot-2 `0020` config seeds (CQG-7 StaleRunningHours / CQG-8 AgentJobName) — PAR-1
edits the `ops.Mandant` MERGE block, not `ops.Config`; keep both. `internal_LogStep` for the WARN
lines. Slot-2 CQG-10 pf_user guard in `AnonymizeCustomerData` P9 (PAR-3 is P1 — different block).
**Coherence:** E2E parity assertions #4 (PAR-4 rowcount) and #7 (PAR-1 login exists + db_owner) in
the e2e runbook.
**Expected files:** ~5 (`0020`, `internal_GrantAccess`, `internal_AnonymizeCustomerData`,
`internal_InvalidateCredentials`, `Projekte/Testsystem/README.md`).

---

### Slot 5 — EAZY (independent eazybusiness chain + deploy.ps1 password cluster)
**Findings:** CQE-1..13 + the `deploy.ps1` portion of CQG-3.

**Implementation notes**
- CQE-3: resolve `tEinheit` "Stk." by name, hard-FAIL if absent (confirm `cName` vs
  `tEinheitSprache` lookup column) (`spGebindeErstellen`).
- CQE-2: delete the `@Auth` PRINT, redact/gate the `@ResponseText` PRINT (behind `@debug BIT=0`)
  in both PayPal procs.
- CQE-4: replace the dead `-1` branch with an explicit "should have thrown" failure
  (`CustomFieldAPI_Tests`).
- CQE-5: add SQL-2022 prerequisite note to the two `STRING_SPLIT`-ordinal function headers +
  README §8; optional compat-level check.
- CQE-6: explicit column list + drop fake aliases (`spPaypalCreateAccessToken`).
- CQE-7: `WITH SCHEMABINDING` on the five pure scalar UDFs only.
- CQE-9: log unmapped-carrier rows to `tPaypalTrackingLog` before the DELETE
  (`spPaypalTrackingCallApi`).
- CQE-10: reword `compare-objects.sql` header to DB↔DB scope.
- CQE-11: after the file loop, per chain, `Add-Error` on duplicate `up/` 4-digit prefixes
  (`lint-migrations.ps1`).
- CQE-12: resolve real tax rate for history brutto, or store net only
  (`spArticleAppendPriceHistory`).
- CQE-13: `Write-Warning` when `-Target` is passed under `-Scope global` (`deploy.ps1`).
- CQE-1 + CQE-8 + CQG-3(deploy): in the `deploy.ps1` password block (119-130) — reject any `'` in
  the password with a clear message (CQG-3), zero/free the BSTR via
  `PtrToStringBSTR`+`ZeroFreeBSTR` (CQE-8), and add a `# @see` gotcha naming the process-arg
  exposure constraint + README §7 single-operator note (CQE-1).

**Must preserve:** GLOBAL's slot-2 SQL-side CQG-3 note in `0011`/`900` (cross-ref it).
**Coherence:** README §8 (SQL-2022 requirement), README §7 (deploy host / password constraint);
lint must pass on any touched `up/`; new `WITH SCHEMABINDING` must not break `validate_structure`
(pure funcs aren't in its required-proc list — safe).
**Expected files:** ~15 (`spGebindeErstellen`, 2 PayPal procs, `spArticleAppendPriceHistory`,
`CustomFieldAPI_Tests`, 5 functions, `deploy.ps1`, `lint-migrations.ps1`, `compare-objects.sql`,
`README`).

---

## 4. Totals

- **Accepted:** 39 · **Merged:** 1 (CQG-6 → EXT-3) · **Rejected:** 0
- **Slots:** 5 (one resume per originating agent), order: Extensibility → Global → Consumer-Ops →
  Parity → Eazy.
