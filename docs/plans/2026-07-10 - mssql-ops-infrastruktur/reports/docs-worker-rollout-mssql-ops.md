# Doc Worker Report — rollout-mssql-ops

**Date:** 2026-07-10T02:45:00+02:00
**Action:** update (reconcile against final code after repair wave 1)
**Target:** `docs/runbooks/rollout-mssql-ops.md`
**Source files:** `db-migrations/deploy.ps1`, `db-migrations/global/up/0011_signing_certificate.sql`, `db-migrations/global/permissions/900_resign_procedures.sql`
**Outcome:** no-change-needed

## What I did

Read the discovery report, the target runbook, and the three assigned source files plus
their diff against `9592c99`. All three files (and the runbook) are net-new since plan
start. The repair wave (`54f38fd`) touched **only** Ebene-A eazybusiness sprocs — none of
my three source files, and the runbook was not modified after it was authored (`66a1969`).
So the runbook and its underlying `global/` code are already in lockstep. I verified every
concrete, code-derived claim in the runbook against the final source.

## Verification (every claim held — nothing stale)

| Runbook claim | Source of truth | Result |
|---|---|---|
| Phase 2/4 command `deploy.ps1 -Scope global -Environment TEST/PROD` | `deploy.ps1` `ValidateSet` on `$Scope`/`$Environment` | matches |
| PROD gate prompts Y/N and lists exact target DBs first | `deploy.ps1` §PROD gate (`Read-Host 'Proceed? (Y/N)'`, prints server + databases) | matches |
| Cert password via `Read-Host -AsSecureString` or `GRATE_CERT_PASSWORD`, only for global scope | `deploy.ps1` §cert password token (`if ($Scope -eq 'global')`) | matches |
| `{{CertPassword}}` token lives in `up/0011` + `permissions/900`, never in git | `deploy.ps1` comment + both SQL files use `{{CertPassword}}` | matches |
| Prod server `vm-sql2.zdbikes.local` (Phase 4 CAUTION) | `targets.config.json` `PROD.server` | matches |
| Phase 2: `0001` asserts collation `Latin1_General_CI_AS`, hard-fail on mismatch | `global/up/0001_roboticoops_settings.sql` collation assert | matches |
| Certificate name `RoboticoOpsSigning` (implied by the deploy prompt) | `up/0011` `CREATE CERTIFICATE RoboticoOpsSigning`; `deploy.ps1` prompt string | matches |
| Phase 5 seed sentinel `'<SET-VIA-RUNBOOK>'` for `ShopLicense`; `tm4` mandant exists | `global/up/0020_seed_mandant_template.sql` | matches |
| Phase 6 reset entry points `reset.StartTestmandantReset` / `reset.GetResetStatus` | `global/sprocs/reset.*.sql` | matches |
| Status walks `queued → running → succeeded`; `StepLog` shows all eight steps | `reset.StartTestmandantReset.sql` states + 8 `reset.internal_*` step sprocs | matches |
| Rollback: `running` row older than 4h auto-reclaimed as `failed` | `reset.ProcessNextResetRequest.sql` (`StartedAt < DATEADD(HOUR, -4, …)`) | matches |

Note on `permissions/900`: it re-signs `reset.StartTestmandantReset` automatically on
every deploy (CREATE OR ALTER strips the signature). The runbook correctly does **not**
surface this as a manual step — it is transparent to the operator — so no addition needed.

## Sections changed

None. No stale text, no false claims, no leftover placeholders, no whole-doc reformat.

## Notes for final

- **No ADR cross-links in this runbook.** Its `## References` point only to
  `db-migrations/README.md`, `../SQL/MSSQL-OPS-ARCHITECTURE.md`, sibling runbooks, and the
  runbook index — so the discovery report's ADR-non-promotion gap (`docs/decisions/` does
  not exist yet) produces **no** dangling link here. The signing-model detail lives inline;
  once `adr-module-signing-reset` is promoted, this runbook does **not** need a link edit
  (the architecture doc owns that reference).
- All relative links in the runbook resolve to existing files
  (`../../db-migrations/README.md`, `../SQL/MSSQL-OPS-ARCHITECTURE.md`,
  `migrations-baseline.md`, `testmandant-reset-validierung.md`, `hygiene-findings.md`,
  `README.md`). Final agent may wish to confirm the runbook-index (`README.md`) row for
  this file after the sibling-runbook workers finish.
