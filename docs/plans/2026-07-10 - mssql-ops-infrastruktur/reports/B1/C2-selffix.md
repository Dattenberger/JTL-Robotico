# C2 — Self-Fix (fresh eyes, diff-based)

**Chunk:** C2 (block B1) · **Timestamp:** 2026-07-10T00:57:22+02:00
**Reviewer role:** fresh eyes on wave commit `ff9141c` (scope = C2 CHUNK_FILES only)

## What I did

Read the implementer report, the full C2 diff (20 global files + 1 structure test),
plan §2/§3/§7, and both legacy sources the port draws on
(`Projekte/Testsystem/register-mandant.sql`, `clear-customer-fields.sql`). Ran the
lint (`pwsh db-migrations/tests/lint-migrations.ps1`) → **exit 0**, 10 rule-(g)
warnings, all re-verified safe. Loaded `knowledge-sql` + `knowledge-jtl-sql`.

**No fixes were required** — the chunk is plan-correct, the ports are faithful, the
security posture holds, and every rule-(g) warning is a false positive I independently
confirmed.

## Review — three lenses

### Plan correctness
- Every §2 file present (0001–0020 up scripts, roles, jobstartuser, cert, seed) and
  every §3 reset.* proc present; object→file mapping in the impl report matches the
  actual diff. Structure test (§7) references only objects/columns that 0002 creates.
- Deviations (StepLog-direct vs OUTPUT param, cross-DB `QUOTENAME(db).sys.sp_executesql`
  vs `USE`, agent-job wrapper proc, `<SET-VIA-RUNBOOK>` sentinel, dropped RoboticoEKL
  grant, `DELETE` vs `TRUNCATE`) are all documented and defensible (D4). The
  AnonymizeCustomerData "per-block TRY/CATCH" wording in the §3 file-table is satisfied
  by the outer ProcessNext CATCH + per-block StepLog-on-success — matches the §3
  Implementation-Approach intent ("Fehler in einem Block bricht die Pipeline (CATCH)",
  "kein halb anonymisiert still weiter").

### Code quality / security
- Dynamic-SQL discipline verified end to end: DB/object names only via `QUOTENAME`,
  all data values (paths, ShopUrl/ShopLicense, LoginName, DisplayName) passed as
  `sp_executesql` parameters. Quote-nesting parity checked in every ported batch
  (level-1 `''`, the nested `EXEC(N''...'')` in PostRestoreSecurity/GrantAccess doubled
  correctly).
- Triple-guard `@TargetDb='eazybusiness' OR NOT LIKE 'eazybusiness[_]%'` present on all
  8 internal procs + Start + ProcessNext re-validation (defense in depth, D6).
- Ownership-chaining model coherent: `ops`/`reset` schemas AUTHORIZATION dbo, only
  `StartTestmandantReset` is `EXECUTE AS` + signed, and 900_resign / validate_structure
  both assert the signed-set == EXECUTE-AS-set invariant.
- `internal_RegisterMandant` writes registration metadata into the source
  (`eazybusiness`) tMandant + tBenutzerFirma — confirmed this is the faithful, intended
  behaviour of the source script (JTL keeps tMandant consistent across all mandant DBs;
  the tBenutzerFirma DELETE/INSERT is scoped to the NEW `@k`, so it never disturbs prod
  mandant 1). CONTEXT_INFO trigger-bypass hashes (`Kunde.spKundeUpdate`,
  `dbo.spAdresseUpdate`) match the source exactly.
- Concurrency reasoning holds: session applock + filtered unique index dedup same-mandant
  submissions; serial job while-loop with `UPDLOCK, READPAST`; stale-`running` reclaim
  (>4h) at entry cannot self-reclaim the in-flight row (single-threaded job, 22022 on
  re-start). `SET @RequestId = NULL` at loop top (impl's own fix) correctly terminates
  an empty claim.

### Test quality
- No unit-test framework in this SQL repo (per CONVENTIONS). `validate_structure.sql`
  is the static structural gate; its required-object / required-column / signature /
  role lists are consistent with what the chunk creates. Runtime behaviour is
  necessarily deferred to the §4 validation runbook + E2E (documented, unavoidable
  under the read-only hard constraint — RoboticoOps is not deployed on test1 yet).

## Issues

| ID | Severity | Description | Status | Marker |
|---|---|---|---|---|
| (none new) | — | Pre-existing C2-1 (lint anytime-folder classification) and C2-2 (ApplyJtlRoles member-list duplication) remain delegated by the implementer; I confirm both are accurately scoped and neither is a defect in this chunk. | — | — |

## Files modified

none — no fix was necessary.

## Files outside my scope (drift)

none.

## Final test result

`pwsh db-migrations/tests/lint-migrations.ps1` → **exit 0**, 0 errors, 10 rule-(g)
warnings (all confirmed false positives).
