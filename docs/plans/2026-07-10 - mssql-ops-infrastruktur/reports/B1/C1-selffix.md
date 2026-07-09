# C1 — Migration foundation (Ebene A) — SELF-FIX report (fresh eyes)

**Chunk:** C1 (Block B1) · **Plan sections:** §1, §7 · **Wave commit:** cf02f1a · **Timestamp:** 2026-07-10T00:57:22+02:00

## What I did

Fresh-eyes review of the committed C1 diff (37 files) across three lenses (plan
correctness, code quality, test quality). Loaded `knowledge-sql` + `knowledge-jtl-sql`.
The chunk is high quality: lint green (27 files, 0 errors / 0 warnings), both PowerShell
scripts parse clean, the object mapping is complete against research/5 §3, and the ports
are faithful. One inline readability fix applied; one dangling forward-reference noted
(cross-chunk, not fixed).

## Inline fixes applied

- **`db-migrations/deploy.ps1`** — renamed the local `$env` variable to `$envConfig`
  (3 usages + declaration). `$env` visually collides with PowerShell's well-known
  `$env:` environment-variable drive, which the same script reads a few lines later
  (`$env:GRATE_CERT_PASSWORD`). Not a bug (the two namespaces are distinct), but a
  readability trap for the next maintainer. Added a one-line comment explaining the
  choice. Re-verified: `Parser::ParseFile` OK, lint still 0/0.

## Verification performed (no defects found)

- **Plan §1/§7 completeness** — every file-table row maps to a created file; deviations
  in the impl report (missing `_CheckAction`/`_SetActionDisplayName` = vendor objects;
  +3 PayPal API procs; 12 not ~13 functions; stripped deploy scaffolding; tightened lint
  rule g) are all documented and defensible (D4). research/5 §3 confirms the un-ported
  "Auftrag Preise auf Null" / "Seriennummern Standardlager auf WMS" scripts are
  tests/variants, correctly out of scope.
- **PayPal IDENTITY-insert check** — `INSERT INTO Robotico.tPaypalAccessToken SELECT …`
  (no column list) against a table whose first column is `kKey INTEGER IDENTITY`: the
  identity column is auto-skipped, so the 7 SELECT columns map positionally onto the 7
  non-identity columns exactly. Correct, and a faithful port of the original. (The
  `as nExpiresIn`/`as dAuthDate` aliases are cosmetic in a column-list-less insert.)
- **Registration guards** — all 7 `CustomWorkflows.sp*` action files call the
  module-provided `_CheckAction` / `_SetActionDisplayName` under an
  `IF OBJECT_ID(…) IS NOT NULL` guard with an `ELSE PRINT` fallback. No unguarded helper
  calls.
- **Lint boundary tokens** in `compare-objects.sql` / `lint-migrations.ps1`
  (`spCMArtikel`, `RoboticoEKL`) are intentional exclusion logic in test files (outside
  the deploy folders the lint scans), not violations.
- **Ports** — spZustandartikelLieferantSetzen keeps the SET ANSI_NULLS/QUOTED_IDENTIFIER
  ON gotcha (filtered-index error 1934); duplicate-order engine (iTVF + scalar + sproc)
  and history/PayPal procs match their sources.

## Issues

| ID | Severity | Description (what + file:line) | Status | Marker |
|---|---|---|---|---|
| C1-SF-1 | Nice-to-have | `db-migrations/README.md:217` forward-references `docs/runbooks/rollout-mssql-ops.md`, which does not exist yet. It is a **later-chunk deliverable** (plan L431), so the link resolves when that chunk lands. Left as-is — creating/altering it is cross-chunk scope; churning it now would only be reverted. | delegated | none |

Note: the impl's delegated issue **C1-1** (§5 ADR/NAMING-CONVENTIONS should frame the
`CustomWorkflows._*` helpers as a *JTL-module-provided API both sides consume*, not
"our API for excel_ekl") stands and is correctly routed to the block audit. No code
action here.

## Files modified

- `db-migrations/deploy.ps1` (readability rename `$env` → `$envConfig`)

## Drift (files outside CHUNK_FILES)

- none.

## Final test result

`pwsh db-migrations/tests/lint-migrations.ps1` → **0 errors, 0 warnings, exit 0** (27
files). `deploy.ps1` passes `[Parser]::ParseFile`.
