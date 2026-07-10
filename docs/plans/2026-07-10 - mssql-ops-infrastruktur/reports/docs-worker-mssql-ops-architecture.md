# Doc Worker Report — mssql-ops-architecture

**Date:** 2026-07-10T02:45:00+02:00
**Action:** update
**Target:** `docs/SQL/MSSQL-OPS-ARCHITECTURE.md`
**Source files reconciled against:** `db-migrations/deploy.ps1`,
`db-migrations/global/permissions/900_resign_procedures.sql`,
`db-migrations/global/runAfterOtherAnyTimeScripts/reset.EnsureAgentJob.sql`,
`db-migrations/tests/lint-migrations.ps1`

## What I did

Reconciled the post-implementation architecture snapshot against the four final
source files. The doc was authored during implementation and already matched
reality on almost every point; I verified the flagged claims and made one
targeted accuracy fix to §6.3.

## Verification (matched — no change needed)

| Doc location | Claim | Source | Verdict |
|---|---|---|---|
| §3 Deploy wrapper | flags `-Scope`, `-Environment`, `-Target`, `-Baseline`, `-DryRun` | `deploy.ps1` param block | match |
| §1a.0 / §1a.1-2 / deploy loop | Ebene A → schema `Robotico`, Ebene B → schema `ops` | `deploy.ps1` scope switch (`$schema`) | match |
| §1a.3 diagram + §3 Agent-job row | job `RoboticoOps - Testmandant Reset`, owner `sa`, single step `EXEC reset.ProcessNextResetRequest`, no in-job signing, idempotent drop-then-add | `reset.EnsureAgentJob.sql` | match |
| §3 Lint row | rules (a)–(g) | `lint-migrations.ps1` (rules a,b,c,d,e,f,g present) | match |
| §2 item 4 / §1a.3 note | signing confined to one entry SP | `900_resign_procedures.sql` (set = only `reset.StartTestmandantReset`) | match |
| §6.5 | PROD deploys prompt interactive Y/N and list target DBs | `deploy.ps1` PROD gate | match |

## Section changes applied

- **§6.3 "Re-signing after any SP redeploy" → "…after a signed-SP redeploy":**
  Sharpened for accuracy against `900_resign_procedures.sql` and `deploy.ps1`:
  1. Narrowed "a `reset.*` SP" to the actual single signed proc
     `reset.StartTestmandantReset` (the 900 signature-required set is exactly
     that one proc).
  2. Corrected the broken fallback. The old text said "run
     `900_resign_procedures.sql` immediately afterwards" — but that script
     carries the `{{CertPassword}}` grate token and is not runnable as raw SQL
     (the literal token would be used as the private-key password). Replaced
     with the hand re-sign statement (`ADD SIGNATURE TO reset.StartTestmandantReset
     BY CERTIFICATE RoboticoOpsSigning WITH PASSWORD = '<real cert password>'`,
     verbatim keyword order from source line 25).
  3. Added the cert-password mechanism from `deploy.ps1` (prompts for the
     `RoboticoOpsSigning` password or reads `$env:GRATE_CERT_PASSWORD`, passes
     it as the `{{CertPassword}}` token, never in git) so §6.3 is
     self-contained.

## Deviations

| Deviation | Plan location | What changed | Why | Impact on later chunks | Resolved? |
|---|---|---|---|---|---|
| none | — | — | — | — | — |

## Files modified

- `docs/SQL/MSSQL-OPS-ARCHITECTURE.md` (§6.3 only)

## Files outside assigned scope (drift)

none

## Notes for final

- **§6.3 broad-vs-narrow claim, cross-doc:** the sibling runbook
  `docs/runbooks/rollout-mssql-ops.md` and `db-migrations/README.md` (§ re-signing,
  if present) may echo the same "never `CREATE OR ALTER` a signed SP" guidance.
  If they phrase it as "any `reset.*` SP" they carry the same imprecision I
  narrowed here (only `reset.StartTestmandantReset` is signed). The
  `db-migrations-readme` and `rollout-mssql-ops` workers own those docs — worth a
  consistency check.
- The `$env:GRATE_CERT_PASSWORD` / `{{CertPassword}}` mechanism now appears in
  §6.3; verify it does not contradict how `db-migrations/README.md` documents the
  deploy-token flow (single source of truth for the file-level contract).
