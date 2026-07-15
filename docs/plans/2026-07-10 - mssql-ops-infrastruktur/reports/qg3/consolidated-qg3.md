# QG3 — Consolidated Findings (review round 3 + port audits)

Consolidates six read-only reviews (2026-07-15):
`qg3-security.md` (Fable-Medium), `qg3-bugs.md` (Fable-Medium), `qg3-static.md`
(Fable-Medium), `port-audit-testsystem.md`, `port-audit-workflowprocedures.md`,
`port-coverage.md` (all Opus-Medium). Duplicates merged; severities normalized.
Nothing has been fixed yet except three factual errors in the (uncommitted)
`MSSQL-OPS-DATA-MODEL.md` (B7/I2/I3 — fixed inline during consolidation).

## Verdict in one line

No exploitable-injection or broken-security-chain findings; the substance is
**1 deploy blocker (uncommitted edit), 3 port gaps, and a cluster of
concurrency/robustness fixes** in the orchestrator.

---

## Group A — Blocker / High (fix before the next deploy)

| # | Finding | Source | Recommendation |
|---|---|---|---|
| A1 | **Uncommitted RECOVERY-FULL edit of `global/up/0001` is not deployable**: 0001 is hash-journaled on test1; next TEST global deploy fails on the one-time-hash mismatch, and even with a warn flag the script would never re-run (test1 would silently stay SIMPLE). FULL without log backups is strictly worse than SIMPLE. | qg3-bugs B1 (HIGH) = qg3-static C1 (CRITICAL) | Revert the 0001 edit; introduce FULL as a **new** `up/0022_recovery_full.sql`; add a log-backup step to the rollout runbook; update the two docs that still say SIMPLE (qg3-static I1). |
| A2 | **pf_user token clearing can be skipped**: the P9 guard in `spInternal_AnonymizeCustomerData` is an all-or-nothing condition over 7 columns, and `cAuthToken`/`cAmazonAuthToken` are cleared only there; `spInternal_NeutralizeWorker` only locks the user. On PROD (pf_user populated, column drift possible) tokens could survive a reset. | port-testsystem D-14 (only port regression in that area) | Move the security-critical token clearing into `spInternal_NeutralizeWorker` (unconditional, column-existence-guarded per column), keep P9 as belt-and-braces. |
| A3 | **Two live-registered workflow SPs were never ported**: `CustomWorkflows.spAuftragPreiseAufNull` and `CustomWorkflows.spSeriennummerStandardZuWMS` are registered JTL workflow actions but absent from the eazybusiness chain — on a freshly migrated instance those actions break. | port-coverage §3.1/§3.2 | Port both into `db-migrations/eazybusiness/sprocs/` with provenance headers. |
| A4 | **Pipeline not serialized against manual orchestrator runs**: the applock only dedupes submissions per mandant; a manual `EXEC spProcessNextResetRequest` next to the agent job claims a different request via READPAST → two parallel `CloneDatabase` on the same `BackupFile` path. | qg3-bugs B3 | Exclusive `reset:pipeline` applock at orchestrator start. |
| A5 | **Cursor leak in orchestrator CATCH**: if `spInternal_LogStep` throws while `stepcur` is open, the outer CATCH lacks DEALLOCATE → every following request fails with error 16915. | qg3-bugs B2 | `IF CURSOR_STATUS(...) >= -1 DEALLOCATE` in the outer CATCH. |
| A6 | **Terminal-state race**: succeeded/failed updates lack a `cStatus='running'` guard → cancel/reclaim race can resurrect `failed → succeeded`, audit trail lost. | qg3-bugs B4 | Add `AND cStatus = N'running'` to both terminal UPDATEs (+ @@ROWCOUNT handling). |
| A7 | **cShopLicense leak via truncation error**: license value can surface in `cErrorMessage`/StepLog (readable by `ops_reset_executor`), bypassing the column DENY. | qg3-security Important-1 | Sanitize/shorten the license-bearing statement errors (e.g. wrap the tShop UPDATE, never interpolate the value into messages). |
| A8 | **Secrets in process args of `mandant.ps1`** (visible via `ps`/command-line logging). | qg3-security Important-2 | Pass via env var / stdin instead of argv. |

## Group B — Medium (fix in the same wave, order after A)

- B5: `copy-logins.ps1` without `-y 0` → sqlcmd 256-char truncation can corrupt password hashes (qg3-bugs).
- B6: `Robotico.spEnsureArticleCustomField` double-INSERT without runtime transaction + multi-language gap → permanent 2627 wedge (qg3-bugs).
- B8: PayPal token procs — TRAN leak + poisoned NULL token after a 401 (qg3-bugs). **Likely moot: PayPal mechanic is slated for complete removal (Lukas, 2026-07-15); fix only if removal is deferred.**
- B9: `spInternal_LogStep` with NULL message wipes the whole step log (qg3-bugs).
- B10: reclaim/cancel leaves clone in SINGLE_USER (qg3-bugs) / I5: aborted RESTORE leaves clone in RESTORING; next reset fails with misleading error (qg3-static) → add ONLINE/state handling in `spInternal_CloneDatabase` + runbook failure modes.
- THROW-50001 collision `0001` ↔ `spEnsureAgentJob` (qg3-static; THROW-number registry now wrong in one spot).
- `spInternal_LogStep` passes the step-registry whitelist/CHECK (footgun; qg3-static).
- Unescaped `LIKE '%_deactivated'`