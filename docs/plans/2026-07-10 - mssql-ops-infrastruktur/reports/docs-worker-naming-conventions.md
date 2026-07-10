# Doc Worker Report — naming-conventions

**Date:** 2026-07-10T02:45:00+02:00
**Action:** `update` — reconcile `docs/SQL/NAMING-CONVENTIONS.md` against final code (post repair wave 1)
**Target:** `docs/SQL/NAMING-CONVENTIONS.md`
**Sources reconciled:** `db-migrations/eazybusiness/up/0001_robotico_schema.sql`,
`db-migrations/global/up/0002_ops_schema_tables.sql`, `db-migrations/global/up/0003_roles.sql`
(plus corroborating reads of `up/0010`, `up/0011`, `permissions/100`, `permissions/900`,
and the `reset.*` proc inventory).

## Outcome

`augmented` — the doc was already accurate for the relational surface; two targeted
additions closed the only namespace gaps.

## Verification (no change needed)

Section 9's Ebene-B tables matched the shipped code exactly — every claim checked against
`0002_ops_schema_tables.sql`:

- Tables: `ops.Mandant`, `ops.Config`, `ops.ResetRequest` (PascalCase, no `t` prefix) ✓
- Columns: `MandantKey`, `TargetDb`, `Status`, `StepLog` (PascalCase, no Hungarian prefix) ✓
- Constraints: `PK_ops_Mandant`, `FK_ops_ResetRequest_Mandant`, `UQ_ops_Mandant_TargetDb`,
  `CK_ops_Mandant_TargetDb`, `DF_ops_Mandant_IsActive` — all follow the documented
  `<kind>_<schema>_<Table>[_<Col>]` form ✓
- Standalone filtered unique index `UX_ResetRequest_Active` (unqualified) ✓
- `ops.Mandant.ShopLicense` protected by `DENY` (0003_roles.sql line 33) ✓

Sections 1–8 (Robotico schema, JTL Hungarian prefixes, worked duplicate-order example,
journal schemas) were untouched by this plan's code and needed no change.

## Changes applied

| Section | Change |
|---|---|
| §9 `reset.*` row | Added `reset.EnsureAgentJob` to the reset-procedure enumeration — it is a public (non-`internal_`) proc created in `runAfterOtherAnyTimeScripts` and was missing from the list. |
| §9 (new subsection "Principals: roles and signing objects") | Added the principal namespace the ownership tables did not yet cover: database roles (`ops_reset_executor`, `ops_admin` — lowercase `snake_case`, capability-named), the signing certificate (`RoboticoOpsSigning`), its certificate-login (`RoboticoOpsSigningLogin`), and the impersonation login (`jobstartuser`). Includes the do-not-rename constraint (referenced by name in `permissions/900_resign_procedures.sql`'s `ADD SIGNATURE` and by the `WITH EXECUTE AS 'jobstartuser'` proc headers) and the "role names capability, membership is data" rule (AD group added in `permissions/100_grants.sql`). |

No sections removed. No reformatting. Voice, numbered-section structure, and existing
cross-references (§10 links to `db-migrations/README.md` and `MSSQL-OPS-ARCHITECTURE.md`)
preserved.

## Deviations

| Deviation | Plan location | What changed | Why | Impact on later chunks | Resolved? |
|---|---|---|---|---|---|
| none | — | — | — | — | — |

## Issues

| ID | Severity | Description | Status | Marker |
|---|---|---|---|---|
| none | — | — | — | — |

## Files modified

- `docs/SQL/NAMING-CONVENTIONS.md` (in scope)

Drift (files outside assigned target): none.

## Notes for final

- **SSoT boundary with the architecture doc.** The new "Principals" subsection makes
  `NAMING-CONVENTIONS.md` §9 the naming SSoT for roles/certificate/login. The
  `mssql-ops-architecture` worker updates `MSSQL-OPS-ARCHITECTURE.md`'s security-model
  section (module signing + EXECUTE AS + `permissions/900`) — the final agent should confirm
  that doc describes the *mechanism* and defers naming to here, with no contradicting names.
- No new inbound links were added from sibling docs to the new subsection; if the
  architecture doc's security section wants to point at the naming rule, that cross-link is a
  final-agent call.
