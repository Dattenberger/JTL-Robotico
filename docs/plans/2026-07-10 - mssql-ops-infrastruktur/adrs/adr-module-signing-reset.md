# ADR-NNNN: Hybrid module-signing + async agent-job for the test-mandant reset

**Status:** Proposed (plan-scoped — pending promotion)
**Subsystem:** RoboticoOps, Testmandant Reset
**Date:** 2026-07-10
**Supersedes:** —
**Author:** Lukas + Claude Code

> **Cooperates with** the two-chain ADR (`adr-two-chain-migration-paths.md`): the objects
> this ADR describes (`RoboticoOps`, the signing certificate, the reset SPs, the agent
> job) are all Ebene-B instance uniques, deployed by the `global/` chain.

This ADR bundles four decisions that only make sense together — they are the security and
control model of the reset feature: **how the reset runs (D5)**, **which rights the SP and
the job hold (D6)**, **how colleagues read status back (D7)**, and **where mandant config
incl. licence keys is stored (D8)**.

## Research

The security architecture is taken from
[`research/3-module-signing-agent-job/3-module-signing-agent-job.md`](../research/3-module-signing-agent-job/3-module-signing-agent-job.md)
(itself grounded in Erland Sommarskog's module-signing writing):

- **Signed SP → `sp_start_job`, exact rights** (§1, L13): a non-privileged caller can
  start a SQL-Agent job if the SP is signed by a certificate whose derived login holds the
  msdb rights — without granting the caller anything on msdb directly.
- **The job step's execution context is the big simplifier** (§3, L55): a job owned by a
  sysadmin login runs its T-SQL step *as the Agent service account* (sysadmin). So the
  heavy work (BACKUP/RESTORE, `xp_create_subdir`, `ALTER AUTHORIZATION`) needs **no**
  signing inside the job — only the *entry point* SP does.
- **Module signing across DB boundaries** (§4, L65): certificate with private key lives in
  the DB that holds the SP; `master` gets the **public** key only, via a
  `CREATE LOGIN … FROM CERTIFICATE` + `GRANT AUTHENTICATE SERVER`. `TRUSTWORTHY` stays OFF.
- **Post-restore best-practice order** (§5, L75): owner→`sa`, orphan remap, TRUSTWORTHY
  re-assert — the sequence the clone pipeline follows.
- **Audit/status pattern** (§6, L85): a request/run table as the durable state and hand-off.

The **as-built** confirmation is in the C2 implementation report
[`reports/B1/C2-impl.md`](../reports/B1/C2-impl.md): the signed entry point, the queue
table, the eight internal pipeline steps, and the cross-DB `EXEC QUOTENAME(@TargetDb).
sys.sp_executesql` pattern with data passed only as parameters.

## Context

The old reset is a PowerShell script that requires the operator to hold **personal admin
rights on the production server** (`sqlcmd -E`, BACKUP/RESTORE, `db_owner` granting). It
has no audit trail, its config is a git-ignored JSON synced via Google Drive, and it
takes minutes (a 27 GB restore) — long enough that a client connection would time out if
it were done synchronously in a stored procedure. Colleagues who need a reset do **not**
have (and should not have) server-level rights. The reset also touches licence-bearing
config that must never live in git.

## Decision

### D5 — Asynchronous: a signed SP enqueues, an agent job executes

Colleagues call one stored procedure, `reset.StartTestmandantReset(@MandantKey)`. It
validates against the `ops.Mandant` registry, takes an applock, inserts a row into
`ops.ResetRequest` with `Status='queued'` (state machine
`queued → running → succeeded/failed`), and starts the SQL-Agent job
`RoboticoOps - Testmandant Reset` via `msdb.dbo.sp_start_job`. The job runs
`reset.ProcessNextResetRequest`, which claims the oldest `queued` row, flips it to
`running`, and executes the pipeline. Because SQL-Agent jobs take **no parameters**, the
queue table *is* the parameter-passing and audit mechanism. Async means no client timeout;
the table means the state is always inspectable.

### D6 — Rights: hybrid signing for the entry SP, sysadmin owner for the job

The **entry SP** `reset.StartTestmandantReset` runs `WITH EXECUTE AS 'jobstartuser'` — a
dedicated login that is **DISABLE**d and carries `DENY CONNECT SQL` (nobody can log in as
it), but exists in msdb as a user in `SQLAgentOperatorRole` with EXECUTE on `sp_start_job`.
The SP is **signed** by the certificate `RoboticoOpsSigning`: private key in `RoboticoOps`,
public key exported to `master` as a login with `GRANT AUTHENTICATE SERVER`, so the
`EXECUTE AS` context carries across the DB boundary into msdb.

The **agent job is owned by `sa`**, so its single T-SQL step runs as the Agent service
account (sysadmin) and can BACKUP/RESTORE, create subdirectories, and `ALTER
AUTHORIZATION` without fragile grant chains. **No signing inside the job.** `TRUSTWORTHY`
stays OFF everywhere.

Defence in depth, three layers: (1) the job's content only ever changes through the
versioned Ebene-B deployment; (2) the job can only be *started* through the signed SP;
(3) `reset.ProcessNextResetRequest` **re-validates** the claimed request row itself
(target matches the registry, pattern `eazybusiness[_]%`, never source==target) before
doing any work.

### D7 — Status read-back: a signed-free status SP, no table grants

`reset.GetResetStatus(@RequestId = NULL, @MandantKey = NULL)` is the **only** read access
colleagues get; `RoboticoOps` is otherwise invisible to them. It is a plain read SP on its
own DB, so it needs **no** signing — only an EXECUTE grant to the role
`ops_reset_executor`. It returns everything a caller needs (status, timings, `ErrorText`,
`StepLog`) and **nothing secret** — the secret columns of `ops.Mandant` are simply not in
its projection.

### D8 — Mandant config incl. licence keys in `ops.Mandant`, column-protected

`ops.Mandant` holds `MandantKey`, `TargetDb`, `Developer`, `DisplayName`, `LoginName`,
`ShopUrl`, `ShopLicense`, `IsActive`. `ShopLicense` (and any future secret column) is
protected by a **column-level DENY** against everyone except the reset-internal procedures
and admins. Seeds with real keys **never** go through git: the Ebene-B seed ships a
sentinel placeholder and a runbook step UPDATEs the real key in place. This replaces the
git-ignored `test-environment.config.json` with one versioned, single-home config.

## Alternatives Considered

1. **Synchronous reset inside the SP.** Do the backup/restore in the calling SP.
   Rejected: minutes-long work under the caller's connection; a dropped connection leaves
   an unclear state and no audit. (D5)
2. **Service Broker for the queue.** Rejected: overkill for a serial, infrequent process;
   a request table is simpler and directly inspectable. (D5)
3. **`sp_update_jobstep` to inject parameters dynamically.** Rejected: a race-prone
   anti-pattern; the queue table passes the parameter safely. (D5)
4. **Pure certificate path including msdb countersignatures.** Sign the msdb system
   procedures too, avoiding a privileged job owner. Rejected: countersignatures on msdb
   system objects are **lost at every SQL Server CU**, making the reset silently break
   after routine patching (research/3 §1/§3). The hybrid confines signing to *our* SP. (D6)
5. **Least-privilege job owner.** Grant the job owner exactly the rights the pipeline
   needs. Rejected: many server-update-fragile grant surfaces for little gain — the job
   must read prod and write the clone regardless, so a sysadmin owner is both simpler and
   more robust. (D6)
6. **SELECT grant on a status view instead of a status SP.** Rejected: opens `RoboticoOps`
   as a browsable surface and creates a standing obligation to re-check column exposure
   every time the schema grows. "The SP is the interface" is carried through consistently.
   (D7)
7. **`ENCRYPTBYKEY` for the licence column.** Rejected: key-management complexity with no
   real gain in an admin-only context — the only readers are the signed SP chain and
   admins anyway. Retrofittable later if the threat model changes. (D8)
8. **Keep the git-ignored JSON config.** Rejected: no versioning, brittle Google-Drive
   sync, and it is the very thing D8 exists to replace. (D8)

## Consequences

**Positive:**
- Colleagues need **only an EXECUTE grant** — no server rights, no personal admin on prod.
- Full audit: every request is a row with who/when/status/error/step-log.
- The reset survives SQL Server CUs — no msdb countersignatures to lose.
- One versioned config home; licence keys never touch git.
- The heavy pipeline needs no signing (job runs as sysadmin), so only one small SP is the
  signed attack surface.

**Negative:**
- More moving parts than a script: a certificate, a proxy login, a queue table, a job, a
  re-signing step. The setup is a one-time cost carried by the Ebene-B chain and its
  runbook, but it is genuinely more than "one .ps1".
- Async means the caller does not get a synchronous success/fail — they poll
  `GetResetStatus`. Acceptable for a minutes-long operation, but a behaviour change.
- A sysadmin-owned job is a powerful object; its safety rests on "content only via
  versioned deploy + start only via signed SP", not on the owner being least-privileged.

**Failure Modes:**
- **`CREATE OR ALTER` on a signed SP drops its signature.** Any redeploy of
  `reset.StartTestmandantReset` silently removes the signature, and the next non-privileged
  caller fails with a permissions error that does *not* obviously point at "missing
  signature". The everytime `permissions/900_resign_procedures.sql` re-applies the
  signature in the **same** deploy run (permissions folder runs after sprocs) — but a
  manual `CREATE OR ALTER` in SSMS outside a deploy leaves the SP unsigned until the next
  deploy. This is the single sharpest edge of the whole feature.
- **A job left `running` after a hard Agent crash** blocks new requests for that mandant
  (the filtered unique index forbids a second active request). `ProcessNextResetRequest`
  reclaims `running` rows older than 4h as `failed` on its next start — but a crash within
  that window looks like a stuck queue.
- **The proxy login `jobstartuser` is DISABLEd with `DENY CONNECT SQL`.** Its password is
  a random value the script never logs and never needs; anyone "fixing" the login by
  enabling it or resetting a known password widens the surface the design deliberately
  closed.
- **Column-DENY is a coarse guard, not encryption.** An admin or the reset chain reads
  `ShopLicense` in clear; the protection is "only these principals", not "encrypted at
  rest". A new SP that SELECTs `ops.Mandant.*` and is granted too broadly would leak the
  key — every projection over `ops.Mandant` must stay explicit about columns.
- **Dynamic SQL in the pipeline** targets other DBs via `EXEC QUOTENAME(@TargetDb).
  sys.sp_executesql`. The invariant "object/DB names via `QUOTENAME`, all data values as
  `sp_executesql` parameters, every internal proc guarded against `@TargetDb='eazybusiness'`"
  is what keeps an elevated (sysadmin) context from being an injection vector. Lint rule
  (g) flags concatenation heuristically; it is a warning, so a reviewer must confirm each.

## References

- **Related Plan (motivated + implements this ADR):**
  [mssql-ops-infrastruktur](../mssql-ops-infrastruktur.md) — decisions **D5** (async
  SP+job+queue), **D6** (hybrid signing / sysadmin job owner), **D7** (status SP), **D8**
  (`ops.Mandant` config incl. column-protected licence). §2 builds the objects, §3 the
  pipeline.
- **Related ADRs:**
  - `adr-two-chain-migration-paths.md` — these objects are the Ebene-B chain's payload.
  - `adr-grate-migration-runner.md` — the everytime `permissions/` re-signing relies on
    grate's folder-order guarantee.
- Research: [`research/3-module-signing-agent-job`](../research/3-module-signing-agent-job/3-module-signing-agent-job.md)
  (Sommarskog module-signing recipe).
- Implementation (as-built): [`reports/B1/C2-impl.md`](../reports/B1/C2-impl.md);
  `db-migrations/global/sprocs/reset.*.sql`,
  `db-migrations/global/up/{0010_jobstartuser_login,0011_signing_certificate,0020_seed_mandant_template}.sql`,
  `db-migrations/global/permissions/900_resign_procedures.sql`,
  `db-migrations/global/runAfterOtherAnyTimeScripts/reset.EnsureAgentJob.sql`.
- Validation: [`docs/runbooks/testmandant-reset-validierung.md`](../../../runbooks/testmandant-reset-validierung.md).
- External: Erland Sommarskog — "Giving Permissions through Stored Procedures"
  (module signing), https://www.sommarskog.se/grantperm.html.

## Decision History

### 2026-07-10 — Initial proposal

**Trigger:** The old PowerShell reset requires personal prod-admin rights, has no audit,
and its minutes-long restore cannot run synchronously; research/3 (Sommarskog); user
decisions 2026-07-09.

**Before:** A PowerShell script run by a privileged operator, config in a git-ignored
JSON synced over Google Drive, no request log, credentials cleared but the worker not
fully neutralised.

**After:** Colleagues call one signed SP (`EXECUTE AS jobstartuser`, certificate-signed)
that enqueues into `ops.ResetRequest`; a sysadmin-owned agent job runs the eight-step
pipeline as the Agent service account (no in-job signing); status comes back through a
signing-free `reset.GetResetStatus`; mandant config incl. the column-protected
`ShopLicense` lives in `ops.Mandant`, seeded by placeholder + runbook, never via git.

**Reasoning:** The hybrid confines signing to our one entry SP and keeps the job robust
against CUs (no msdb countersignatures to lose), while the sysadmin job owner removes
fragile grant chains for the heavy work. The queue table is the natural
parameter-and-audit mechanism for a parameterless agent job. "The SP is the interface" is
applied uniformly to both starting and reading, so `RoboticoOps` never becomes a browsable
surface. Column-DENY is sufficient in an admin-only context and is retrofittable to
encryption if the threat model changes.

### 2026-07-11 — Second signed entry point: `reset.CancelResetRequest` (QG2 / OPS-2)

**Trigger:** The QG2 consumer/ops review found a stuck-`running` request unrecoverable by
a colleague: the stale-reclaim only fires on the next job start, and the runbook's manual
`UPDATE` needed raw sysadmin (`ops_admin` had `SELECT`-only on `ops.ResetRequest`).

**Before:** Exactly one signed SP (`reset.StartTestmandantReset`). Recovery from a dead job
required either the `StaleRunningHours` wait or a sysadmin hand-edit.

**After:** A **second** signed `EXECUTE AS 'jobstartuser'` entry point,
`reset.CancelResetRequest`, cancels a `queued` request and force-reclaims a `running` one —
but only after reading `msdb.dbo.sysjobactivity` to confirm the reset job is **not**
actually executing, so a live clone is never yanked. That msdb read is the same cross-DB
boundary D6 already authorises, so the SP reuses the identical recipe. `ops_admin` also
gains `UPDATE` on `ops.ResetRequest` for a manual hand-fix without sysadmin. So D6's "one
entry SP" is now **two**; the signed set is no longer hard-coded — `permissions/900` derives
it from the catalog (every `EXECUTE AS 'jobstartuser'` proc), so this SP is signed
automatically and `validate_structure.sql` asserts the whole set is signed.

**Reasoning:** Recovery is part of a serviceable self-service reset (the quality bar: a
non-expert must be able to unblock a mandant at 9am). Reusing the existing signing recipe —
rather than inventing a new privilege path — keeps the security model single-shaped and the
D6 defence-in-depth intact (the msdb-activity gate replaces "trust the caller" with "trust
the engine's job state").
