# Doc-worker report — db-migrations-readme

**Date:** 2026-07-10T02:45:00+02:00
**Action:** update (reconcile against final code, HEAD `54f38fd`)
**Target:** `db-migrations/README.md`
**Sources reconciled against:** `db-migrations/deploy.ps1`, `db-migrations/tests/lint-migrations.ps1`, `db-migrations/targets.config.json`

## Outcome

`augmented` — one substantive addition to §7, no restructuring. The doc was already accurate against the shipped lint and config; the single reconcile gap was an omitted operational detail in the deploy section. Small in-place edit (<5% of the doc); respected the existing Code-Pattern-README convention (numbered sections + GitHub alerts), no UDOC reshaping.

## Verification pass (no change needed)

- **§4 rules (a)–(g) ↔ `lint-migrations.ps1`** — all seven match exactly: (a) `^\s*USE` (line 96), (b) `GO;` (101), (c) single anytime `CREATE` + filename match (132–145), (d) forbidden tokens `spCMArtikel[Neu]`/`RoboticoEKL` + `DROP SCHEMA` + `TRUNCATE TABLE dbo.` (106–117), (e) `NNNN_snake_case` / `Schema.Object` (123–151), (f) cleanup no un-commented write verb (179–190), (g) dynamic-SQL `+ @var` heuristic (154–173). No drift.
- **§7 examples ↔ `deploy.ps1` params + `targets.config.json`** — `-Scope {eazybusiness|global}`, `-Environment {TEST|PROD}`, `-Target`, `-Baseline`, `-DryRun` all present and correctly used; `eazybusiness_tm2` is a valid PROD target in the config. Grate-on-PATH check and PROD Y/N gate match.
- **§1 journal schemas** — `Robotico` (Ebene A) / `ops` in `RoboticoOps` (Ebene B) match `deploy.ps1` scope switch and the config `global: "RoboticoOps"`.

## Change applied — §7 Deploying

Added a `[!NOTE]` documenting that `-Scope global` (Ebene B) prompts for the `RoboticoOpsSigning` module-signing certificate password (`{{CertPassword}}` token in `global/up/0011_signing_certificate.sql` + `global/permissions/900_resign_procedures.sql`), sourced from `$env:GRATE_CERT_PASSWORD` or interactive secure input, and that `-Scope eazybusiness` needs no such token. This was the one operationally load-bearing behaviour a maintainer running the Ebene-B deploy would otherwise hit unannounced. Verified against `deploy.ps1` lines 117–128 and confirmed both token-bearing files exist.

Also refined the PROD-gate sentence to note that `-DryRun` against PROD skips the confirmation prompt (matches `deploy.ps1` line 104: `$Environment -eq 'PROD' -and -not $DryRun`).

## Notes for final

- **§8 Testing table is a subset of the actual test surface.** It lists `lint-migrations.ps1`, `compare-objects.sql`, and `tests/eazybusiness/*.sql`, but the harness also contains `tests/global/validate_structure.sql`, `tests/probes/01–04`, and a new `tests/eazybusiness/DuplicateOrders_Teardown.sql`. Out of scope for this worker (my sources are deploy/lint/config, not the test suite), and the discovery report already flags "`db-migrations/tests/` has no dedicated README" as a standalone gap. If a `tests/README.md` is created, the §8 table should either point to it or be completed — a cross-doc decision for the final agent / architecture doc.
- **`lint-migrations.ps1` `Get-FolderClass` recognises a `runAfterCreateDatabase` anytime folder** (line 67) that README §2 does not list. No such folder exists yet, so §2 ("the folders we use") is not wrong — but if that folder is ever added, §2's folder table and the fixed anytime-order line need a row. Flagging only; no edit made.
