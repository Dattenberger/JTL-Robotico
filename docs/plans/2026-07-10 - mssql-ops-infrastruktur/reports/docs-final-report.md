# Docs Final — cross-doc sanity, link resolution, aggregation

**Date:** 2026-07-10T02:45:00+02:00
**Plan:** `docs/plans/2026-07-10 - mssql-ops-infrastruktur/mssql-ops-infrastruktur.md`
**Scope:** 11 doc-worker targets + 4 inline-anchor groups (16 worker reports)
**Auto-fixes applied:** 0 · **Flagged:** 5 · **Gaps:** 1 (+1 dependent) · **ADR flags:** 1

## 1. What was updated / converted

No spec conversions (no research file carried a `## Specification` section). All 11
doc targets were **reconcile-against-final-code** passes on docs authored *during*
implementation; the four inline-anchor groups were **verify** passes (repair wave 1
had already added most anchors). Net doc edits were small and surgical:

| Target | Worker outcome | Edit summary |
|---|---|---|
| `docs/SQL/MSSQL-OPS-ARCHITECTURE.md` | augmented | §6.3 narrowed "any reset.* SP" → the single signed proc `reset.StartTestmandantReset`; fixed the broken "run `900_resign_procedures.sql`" fallback (carries `{{CertPassword}}` token, not runnable as raw SQL) to a hand `ADD SIGNATURE`; added the cert-password mechanism. |
| `db-migrations/README.md` | augmented | §7 `[!NOTE]` on the `RoboticoOpsSigning` cert-password prompt for `-Scope global` (`{{CertPassword}}` / `$env:GRATE_CERT_PASSWORD`); PROD-gate refinement (`-DryRun` skips prompt). |
| `docs/SQL/NAMING-CONVENTIONS.md` | augmented | §9: added `reset.EnsureAgentJob` to the reset-proc list; new "Principals: roles and signing objects" subsection (roles, cert, cert-login, `jobstartuser`) — now the naming SSoT for principals. |
| `Projekte/Testsystem/README.md` | augmented | Added `register-mandant.sql` (step 5) to the numbered script order; renumbered `JTL-Rollen.sql`. |
| `docs/runbooks/migrations-baseline.md` | augmented | Step 2 sharpened: `compare-objects.sql` `SHA2_256` hash-compare mechanism (prod = presence-only; clones = diff against prod). |
| `docs/runbooks/testmandant-reset-validierung.md` | augmented (substantive) | Runbook seeded validation mandant as `tmv`, which **violates the shipped `CK_ops_Mandant_MandantKey CHECK (MandantKey LIKE 'tm[0-9]%')`** — the happy path could never run. Renamed `tmv`→`tm9` throughout; expanded the `[!NOTE]` to cover both shape constraints. |
| `WorkflowProcedures/README.md` | no-change-needed | Source→destination mapping table verified exact against 27 shipped Ebene-A files. |
| `docs/SQL/JTL-CUSTOM-WORKFLOWS.md` | no-change-needed | Ported CW sprocs contradict none of the registration mechanics; SSoT rule kept the guarded-registration pattern in README §6 (not duplicated here). |
| `docs/runbooks/README.md` | no-change-needed | Index rows, scope column, fit-together diagram, Related links all verified. |
| `docs/runbooks/rollout-mssql-ops.md` | no-change-needed | Every code-derived claim (deploy flags, PROD gate, cert token, reset entry points, state machine, 4h reclaim) verified. |
| `docs/runbooks/hygiene-findings.md` | no-change-needed | Three findings verified line-by-line against `Berechtigungen/cleanup/0{1,3}.sql` + `02.md`. |

**Inline anchors** (4 groups): `eazybusiness-ebene-a` added the missing `@see (§1, Dn)`
plan/Decision-Log anchors to 14 of 27 files (comment-only, +28/-0). The other three
groups (`global-ebene-b`, `tests-harness`, `peripheral-hygiene-legacy`) were
**no-change-needed** — repair wave 1 (`ff9141c`) had already added headers/`@see`; the
discovery inventory's "no module header on Ebene-B" row is **stale**.

## 2. Cross-doc sanity (Job 1)

Verified consistent — **no contradiction** on the two highest-risk cross-doc surfaces:

- **Re-signing / signed-SP guidance.** After the architecture §6.3 narrowing, no sibling
  doc still says "any reset.* SP". `db-migrations/README.md` §7 and
  `docs/runbooks/rollout-mssql-ops.md` both reference re-signing `reset.StartTestmandantReset`
  specifically. Consistent.
- **Principal names.** `RoboticoOpsSigning`, `RoboticoOpsSigningLogin`, `jobstartuser`,
  `ops_reset_executor`, `ops_admin` are identical across `NAMING-CONVENTIONS.md` §9
  (naming SSoT), `MSSQL-OPS-ARCHITECTURE.md` (mechanism), and `db-migrations/README.md`.
  The architecture doc describes the *mechanism* and defers naming — no contradicting names.
- **Cert-password mechanism** (`{{CertPassword}}` / `$env:GRATE_CERT_PASSWORD`, never in git)
  is stated identically in architecture §6.3, README §7, and the rollout runbook.

## 3. Link resolution (Job 2)

**Auto-fixes applied: 0.** No doc was relocated (the architecture doc stayed in
`docs/SQL/`, not `docs/architecture/`) and no anchor was renamed, so no "moved within the
touched set" or "unambiguous rename" case arose. Every relative link in all 11 touched
docs resolves on disk (the initial `%20`-encoded plan/ADR links were verified as
false-positives — they decode and resolve). External URLs not probed per policy.

## 4. Flagged for user (no auto-resolve — domain/lifecycle judgment)

1. **`tmv` → `tm9` drift into non-touched artifacts.** The reset-validation runbook now
   uses `tm9` (constraint fix), but two artifacts still say `tmv`:
   - `mssql-ops-infrastruktur.md` §L412 (plan body) — *historical plan record; keep as-is.*
     The plan predates the discovery that `tm[0-9]%` rejects `tmv`. Recommend a one-line
     "implementation uses `tm9`; see runbook" note only if you touch the plan before archival.
   - `reports/e2e-runbook.md` §L147 (E2E case description) — describes executing the runbook
     with a `tmv` seed row, now invalid. **Recommend:** update this line to `tm9` when the
     E2E report is next revised (transient orchestration artifact; low urgency).
2. **`JTL-CUSTOM-WORKFLOWS.md` has no back-link to its version-controlled ports.**
   `db-migrations/README.md` §6 links *to* this doc, but the doc has no pointer back to
   `db-migrations/eazybusiness/sprocs/CustomWorkflows.*` (the guarded-registration ports).
   **Recommend:** a one-line navigability pointer near §8's recipe or the §3 licensing block.
   Not a correctness issue.
3. **Runbook-index fit-together diagram labels the hygiene arrow "Phase 7"**, while
   `rollout-mssql-ops.md` states hygiene is *not* part of the rollout (the pointer merely
   lives in the Phase 7 section). The "(separate, manual)" annotation already disambiguates.
   **Recommend:** optional wording sharpen ("after Phase 7") — not a false claim as written.
4. **Optional cross-link:** the architecture security section could point at
   `NAMING-CONVENTIONS.md` §9 "Principals" (the naming SSoT). Navigability only; left to you.
5. **`db-migrations/README.md` §8 Testing table is a subset of the actual test surface**
   (omits `tests/global/validate_structure.sql`, `tests/probes/01–04`, and the
   `DuplicateOrders_Teardown.sql`). This resolves itself once the tests README below exists;
   until then, the §8 table under-describes the harness.

## 5. Documentation gaps

- **`db-migrations/tests/` has no dedicated README** (flagged by discovery + 3 workers).
  The harness — lint rules, how to run the `*_Tests.sql`, `compare-objects.sql` drift check,
  `validate_structure.sql` gate, and the four `probes/` (what each proves) — is only
  described from the architecture doc and inline anchors. A short `db-migrations/tests/README.md`
  would make the test surface self-describing and would let README §8 (flag 5) point at it.
  **Recommendation:** follow-up doc plan via feature-planning — **default: no** (not
  auto-generated here; content is judgment).

## 6. ADR flags

- **`docs/decisions/` does not exist; three plan-scoped ADR drafts are unpromoted.**
  `adr-grate-migration-runner.md` (D1), `adr-two-chain-migration-paths.md` (D2/D3),
  `adr-module-signing-reset.md` (D5/D6) are all
  `Status: Proposed (plan-scoped — pending promotion)` under the plan's `adrs/`. They must
  be promoted (assign `NNNN`, move to `docs/decisions/`, add index row, rewrite cross-refs)
  **before the plan is archived** — a plan-lifecycle obligation, out of scope for doc workers.
  Note: `MSSQL-OPS-ARCHITECTURE.md` links directly to the three draft ADR paths (they resolve
  now); those links must be rewritten to `docs/decisions/NNNN-*` at promotion. The source-file
  `@see` anchors deliberately point at plan §/D (not ADR paths) to avoid this churn.

## 7. Knowledge-skill flags

None. No worker surfaced a missing or drifted `knowledge-*` pattern.
