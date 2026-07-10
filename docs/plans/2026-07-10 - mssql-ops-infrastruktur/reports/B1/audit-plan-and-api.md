# Block B1 Audit — Topic: plan-and-api

**Block:** B1 · **Chunks:** C1–C4 · **Timestamp:** 2026-07-10T00:57:22+02:00
**Diff base:** 9592c99..HEAD (file-scoped to BLOCK_FILES)
**Grounding loaded:** knowledge-sql, knowledge-jtl-sql (this is a SQL/PowerShell repo;
the topic-catalog TS/reference skills carry no applicable patterns here).

## Verdict

**No Critical, Important, or Nice-to-have plan-and-api findings survive verification.**
The block is exceptionally consistent across chunks: every cross-chunk API contract I
traced (proc signatures, table columns, job name, grants, deploy flags) matches, there
are no stubs / placeholder returns / not-implemented paths, and the one plan-and-api
issue that chunks routed to this audit (C1-1, the D10 framing) is fully resolved in the
documentation layer.

## What was audited (a / b / c per topic definition)

### (a) Plan fidelity — implementation vs. plan spec, cross-checked against deviation tables

- **§1 object completeness:** C1's object→file mapping covers every research/5 §3
  deployed object with exactly one target file. Documented deviations
  (`_CheckAction`/`_SetActionDisplayName` not created; +3 PayPal API procs; 12 vs "~13"
  functions; stripped deploy scaffolding; tightened lint rule g) are all D4-defensible
  and independently confirmed against the sources.
- **§2/§3 chain:** Every §2 up-script (0001–0020), role/login/cert/seed file, and every
  §3 `reset.*` proc is present. Documented deviations (StepLog-direct vs `@StepLog OUTPUT`,
  `QUOTENAME(db).sys.sp_executesql` vs `USE`, `reset.EnsureAgentJob` wrapper vs bare
  `agent_job_*.sql`, `<SET-VIA-RUNBOOK>` sentinel vs `{{ShopLicense}}` token, dropped
  `RoboticoEKL` grant, `DELETE` vs `TRUNCATE`) are all documented and correct.
- **§5 docs:** 3 plan-scoped ADRs, architecture doc, rollout runbook, indexes, additive
  NAMING-CONVENTIONS/banner edits all present per the §5 file table.

### (b) Stubs / placeholder returns / not-implemented

- None. Every ported proc/function carries a complete body; the `internal_*` pipeline
  steps all contain real DDL/DML. `reset.EnsureAgentJob` is not just a proc definition —
  it **self-executes** (`EXEC reset.EnsureAgentJob;`, line 51) so the Agent job is
  actually (re)created on hash change. The module-registration `ELSE PRINT` fallbacks are
  intentional graceful-degradation guards (module prerequisite), not stubs.

### (c) API-consumer match across chunks

Verified caller/callee agreement on every boundary:

- **`reset.ProcessNextResetRequest` → 8 internal procs:** each `EXEC … @TargetDb, @RequestId
  [, extra]` matches the callee's declared signature exactly
  (`internal_InvalidateCredentials` +`@ShopUrl`/`@ShopLicense`, `internal_GrantAccess`
  +`@LoginName`, `internal_RegisterMandant` +`@DisplayName`; all others 2-param). Param
  types line up (`@DisplayName nvarchar(255)` both sides, etc.).
- **`reset.StartTestmandantReset` / `GetResetStatus`** signatures + result-set shape match
  plan §3 (`@MandantKey sysname`; `@RequestId int=NULL, @MandantKey sysname=NULL`;
  `SELECT @RequestId AS RequestId, N'queued' AS Status`). `GetResetStatus` selects no
  secret columns (D7 honoured).
- **Agent job name** `N'RoboticoOps - Testmandant Reset'` is identical in the producer
  (`EnsureAgentJob`), the starter (`StartTestmandantReset` → `sp_start_job`), and the
  consumer comment (`ProcessNextResetRequest`).
- **`ops.Config` / `ops.Mandant` / `ops.ResetRequest` columns:** every column referenced
  by the reset procs, the 0020 seed, and `tests/global/validate_structure.sql` exists in
  the 0002 table definitions (`ConfigKey/ConfigValue`; `MandantKey/TargetDb/LoginName/
  ShopUrl/ShopLicense/DisplayName/IsActive`; `RequestId/Status/RequestedBy/StartedAt/
  FinishedAt/ErrorText/StepLog`). No column-name drift between definition and consumers.
- **PayPal call chain** (`CustomWorkflows.spPaypalTracking{Versand,Lieferschein}` →
  `Robotico.spPaypalTrackingCallApi(@kLieferschein int)` → `spPaypalGetAccessToken(@token
  OUTPUT)` → `spPaypalCreateAccessToken()`): argument arity/direction match; Versand
  correctly resolves `@kVersand`→`@kLieferschein` via `tVersand`. Faithful to the source
  (`WorkflowProcedures/PayPal/Workflowaktion.sql`).
- **Permissions ↔ API surface:** `100_grants` grants EXECUTE on exactly Start+Status to
  `ops_reset_executor`; `900_resign` re-signs exactly `StartTestmandantReset` (the sole
  `EXECUTE AS`+signed proc); `validate_structure` asserts the signed-set == EXECUTE-AS-set
  invariant. deploy.ps1 flag surface (`-Scope/-Environment/-Target/-Baseline/-DryRun` →
  grate `--baseline/--dryrun/--schema/--transaction/--silent`) matches plan §1 pt4.

## C1-1 (D10 framing) — routed here, confirmed RESOLVED

C1 flagged that the plan (D10, §1) treats `CustomWorkflows._CheckAction` /
`_SetActionDisplayName` / `vCustomAction*` as "our stable API for excel_ekl", when they
are in fact JTL "Custom Workflow Actions" **module (vendor)** objects that both excel_ekl
and this repo merely consume. The docs now frame this correctly and consistently:
- `db-migrations/README.md` §6 — "module prerequisite (not ours to create)", guarded
  registration pattern documented.
- `docs/SQL/NAMING-CONVENTIONS.md` §10 (L200-201) — "**vendor objects** provided by the
  JTL 'Custom Workflow Actions' module — not created by [us]".
- `docs/SQL/MSSQL-OPS-ARCHITECTURE.md` (L190-191) — same framing.
No object files were created for these helpers; all 7 action registrations are guarded
(`IF OBJECT_ID(...) IS NOT NULL … ELSE PRINT`). Nothing left to do.

## Out-of-scope observations (for the consolidator)

- **[logic] StartSP↔Job liveness window.** `StartTestmandantReset` swallows `sp_start_job`
  error 22022 ("job already running") assuming the running `ProcessNextResetRequest`
  while-loop will pick up the freshly-inserted `queued` row. There is a narrow race: if
  the job has just executed its final `IF @RequestId IS NULL BREAK` but msdb still reports
  the step as running when StartSP fires, the new row can be left `queued` until the next
  reset. This is the plan's explicit design (§3 pt1), so it is *plan-faithful* and not a
  plan-and-api finding — flagging for the `logic` topic to judge severity.
- **[convention/logic] `--usertokens` repetition.** deploy.ps1 emits one repeated
  `--usertokens=key=val` flag per token; only `CertPassword` exists today so it works, but
  whether grate merges repeated `--usertokens` flags vs. requires a single `;`-joined value
  is a grate-runtime detail worth a note if more tokens are added. Not plan-and-api.

## Coverage note

- **Audited in full:** all `db-migrations/global/**` sprocs + up + permissions +
  EnsureAgentJob; `reset.*` signature graph; `ops.*` table/consumer column graph;
  PayPal proc chain; deploy.ps1 flag surface; validate_structure references; the D10
  framing across README/NAMING-CONVENTIONS/architecture doc; all four chunk impl reports
  + self-fix reports.
- **Spot-checked (not line-by-line):** the 12 `Robotico.fn*` function bodies and the
  history/Gebinde/Zustandartikel action bodies (C1 self-fix already verified port
  fidelity; no cross-chunk API surface). The 534-line `internal_AnonymizeCustomerData`
  block bodies were checked for the StepLog/@RequestId contract and guard, not per-block
  DML semantics (that is the `logic` topic's remit).
- **Not runnable:** no SQL was executed (read-only hard constraint; RoboticoOps is not
  deployed on test1). Runtime behaviour of the signing/cross-DB chain is necessarily
  deferred to the §4 validation runbook + E2E, as the chunks documented.
