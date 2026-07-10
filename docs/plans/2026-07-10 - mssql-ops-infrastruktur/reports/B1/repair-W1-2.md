# Repair Report — B1/W1-2

**Timestamp:** 2026-07-10T00:57:22+02:00
**Prompt:** repair-fix (apply validated findings)

## Findings applied

### convention-B1-2 (green / Nice-to-have) — FIXED

The five PayPal procs omitted `SET NOCOUNT ON;` while every other proc in
the block (8 remaining C1 procs, 11 C2 `reset.*` procs) opens with it.
Added `SET NOCOUNT ON;` as the first body statement inside each proc's
outer `BEGIN`, followed by a blank line to match the reference style in
`Robotico.spEnsureArticleCustomField.sql` (line 23).

Per-file placement:
- `Robotico.spPaypalGetAccessToken.sql` — before `BEGIN TRANSACTION`.
- `Robotico.spPaypalCreateAccessToken.sql` — before `BEGIN TRANSACTION`.
- `Robotico.spPaypalTrackingCallApi.sql` — before the `-- Preparation` block.
- `CustomWorkflows.spPaypalTrackingVersand.sql` — before the inner `BEGIN`.
- `CustomWorkflows.spPaypalTrackingLieferschein.sql` — before the inner `BEGIN`.

No behavioural change (finding was harmless at runtime); this is pure
scaffolding harmonization.

## Skipped findings

none

## Tests

`pwsh db-migrations/tests/lint-migrations.ps1` — OK: 0 errors, 10 warnings
(same 10 pre-existing warnings as baseline, all in unrelated
`global/sprocs/reset.internal_*` files).

## Files modified

- db-migrations/eazybusiness/sprocs/Robotico.spPaypalGetAccessToken.sql
- db-migrations/eazybusiness/sprocs/Robotico.spPaypalCreateAccessToken.sql
- db-migrations/eazybusiness/sprocs/Robotico.spPaypalTrackingCallApi.sql
- db-migrations/eazybusiness/sprocs/CustomWorkflows.spPaypalTrackingVersand.sql
- db-migrations/eazybusiness/sprocs/CustomWorkflows.spPaypalTrackingLieferschein.sql

## Drift (out-of-scope edits)

none
