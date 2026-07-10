# Runbooks

Operator-facing, step-by-step procedures for running the JTL-Robotico SQL estate. Each
runbook is self-contained and names its own preconditions; this file is only the index.

> [!CAUTION]
> No runbook here is a "just run it" script. Every step that touches **production**
> (`vm-sql2.zdbikes.local`) is human-gated — read, decide, then run. Nothing in this repo
> writes to a SQL Server autonomously.

## Index

| Runbook | Purpose | Scope |
|---|---|---|
| [`rollout-mssql-ops.md`](rollout-mssql-ops.md) | The full test→prod rollout spine — baseline, stand up RoboticoOps on test, validate the reset, gate onto prod, seed keys, first prod reset, retire the old path. Points at the focused runbooks below. | prod + test1 |
| [`migrations-baseline.md`](migrations-baseline.md) | Adopt an already-populated `eazybusiness` into the grate journal without re-running deployed objects (Ebene A). Includes the mandatory file-vs-deployed pre-check. | prod + test1 |
| [`testmandant-reset-validierung.md`](testmandant-reset-validierung.md) | Prove the server-side reset (`StartTestmandantReset` → agent job → `internal_*` pipeline → `GetResetStatus`) end-to-end on the safe instance before trusting it on prod. | test1 only |
| [`hygiene-findings.md`](hygiene-findings.md) | Three prepared-but-manual production housekeeping items the instance survey surfaced (Dana `sysadmin`, tm2 backlog, `eazybusiness_premig`). Read-only analysis with fixes commented out. | prod |

## How they fit together

```
rollout-mssql-ops.md  (the spine)
   ├─ Phase 1  →  migrations-baseline.md
   ├─ Phase 3  →  testmandant-reset-validierung.md
   └─ Phase 7  →  hygiene-findings.md  (separate, manual)
```

## Related

- **Architecture map:** [`../SQL/MSSQL-OPS-ARCHITECTURE.md`](../SQL/MSSQL-OPS-ARCHITECTURE.md)
  — how the pieces fit and the standing operating rules (§6).
- **Migration contract:** [`../../db-migrations/README.md`](../../db-migrations/README.md)
  — the file-level rules every migration obeys.
- **Origin plan:** [`../plans/2026-07-10 - mssql-ops-infrastruktur/`](../plans/2026-07-10%20-%20mssql-ops-infrastruktur/mssql-ops-infrastruktur.md).
