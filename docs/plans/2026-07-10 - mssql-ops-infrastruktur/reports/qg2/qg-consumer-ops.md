# QG2 — Consumer & Operations Review (Fable-Lens)

Reviewer perspective: (1) the colleague (Dana/Sanda) who triggers a reset with
nothing but the two `EXECUTE` grants, and (2) the operator who has to diagnose a
failed reset at 9am following only the docs. Read-only analysis of the
`feature/mssql-ops-infrastruktur` worktree.

Quality bar under test: *a failed reset must be diagnosable by a non-expert
following the runbooks; a colleague must be able to self-serve the whole happy
path without server rights.*

Bottom line: the **happy path** is clean and the audit trail (ORIGINAL_LOGIN in
`RequestedBy`, durable `ops.ResetRequest` row per run) is genuinely good. The
gaps are all on the **discovery** and **recovery** edges — a colleague cannot
find out which mandant keys exist, cannot get out of a stuck-`running` state,
and the live-progress/failure-step story the docs promise is not what the code
delivers.

---

## OPS-1 — A colleague has no way to discover which mandant keys exist — important

**Evidence (walked scenario).** Dana wants to reset "her" test mandant but does
not remember the key. Her entire granted surface is `EXECUTE` on
`reset.StartTestmandantReset` and `reset.GetResetStatus`
(`db-migrations/global/permissions/100_grants.sql:15-18`). `ops.Mandant` — the
registry that maps `MandantKey` → developer/display-name/target-db — is readable
only by `ops_admin` (`db-migrations/global/up/0003_roles.sql:26`, plus a
column-DENY on `ShopLicense` for the executor role at `:33`). There is **no**
`reset.ListMandants` SP. `GetResetStatus` with no params returns only *request*
history (`reset.GetResetStatus.sql:18-33`), so it surfaces a key **only after it
has already been reset at least once** — useless for a first-timer or for a
mandant that has never run through the new path.

Result: onboarding a new colleague requires an admin to tell them their key out
of band. The self-service story ("a colleague needs only EXECUTE on two SPs",
architecture §2 item 3) is incomplete without a discovery entry point.

**Proposed fix.** Add `reset.ListMandants` (own DB, no signature — same shape as
`GetResetStatus`) that `SELECT`s `MandantKey, DisplayName, Developer, TargetDb,
IsActive` and the latest request `Status`/`FinishedAt` per mandant, deliberately
**excluding** `ShopLicense`/`ShopUrl`. Grant `EXECUTE` to `ops_reset_executor`
in `100_grants.sql`. Ownership chaining covers the `ops.Mandant` read, so no new
table grant (and the `ShopLicense` DENY stays intact).

**Size:** S

---

## OPS-2 — A stuck `running` request is a dead-end the consumer (and even ops_admin) cannot clear — important

**Evidence (walked scenario + code).** The Agent job dies mid-clone (host
reboot, service restart). `tm4`'s request is left `running`
(`reset.ProcessNextResetRequest.sql` has no user transaction by design, header
:15-16). Now:

1. Dana re-runs `StartTestmandantReset @MandantKey='tm4'`. The duplicate guard
   `THROW 51004` fires (`reset.StartTestmandantReset.sql:50-52`) **before** the
   `INSERT` and **before** `sp_start_job` (:54-61). So the job is *not* started.
2. The 4h stale-reclaim only runs at the **top of the job body**
   (`ProcessNextResetRequest.sql:26-32`), and the job has **no schedule** —
   on-demand only (`reset.EnsureAgentJob.sql:6`). So the reclaim never fires
   unless *some other* mandant's reset happens to start the job, and even then
   only after the row is >4h old.
3. The documented manual escape — "mark the row `failed` by hand and re-trigger"
   (`docs/runbooks/testmandant-reset-validierung.md:186-192`; rollback note in
   `rollout-mssql-ops.md:145-146`) — requires `UPDATE` on `ops.ResetRequest`.
   But `ops_admin` is granted **`SELECT` only** on that table
   (`0003_roles.sql:28`), and `ops_reset_executor` nothing at all. So the
   recovery step is not executable by *either* role — it silently requires a raw
   sysadmin. The runbook does not say this.

Net: for up to 4 hours a single mandant can be un-resettable by anyone short of
a sysadmin, and the runbook's recovery instruction is not grantable to the roles
that exist. This is exactly the "9am, non-expert, blocked" case the quality bar
targets.

**Proposed fix.** Add a signed/EXECUTE-AS `reset.CancelResetRequest @RequestId`
(mirrors the Start-SP security model) that (a) transitions a **`queued`** row to
`failed` with `ErrorText = 'cancelled by ' + ORIGINAL_LOGIN()`, and (b)
force-reclaims a **`running`** row for the same mandant *only after confirming
the job is not actually executing* (e.g. no active `msdb` job run), bypassing
the 4h gate. Grant `EXECUTE` to `ops_reset_executor`. Then rewrite the runbook
failure-mode block to call this SP instead of the raw `UPDATE`, and either fix
the `ops_admin` grant to include `UPDATE ON ops.ResetRequest` or explicitly
state the manual path needs sysadmin.

**Size:** M

---

## OPS-3 — StepLog shows no live progress and omits the failing step; the docs claim otherwise — important

**Evidence (code vs docs).** Every internal step writes its StepLog line **once,
at the very end, after the work succeeded** — e.g. `internal_CloneDatabase.sql:66-70`
(the line is appended only after the multi-minute BACKUP+RESTORE finishes) and
`internal_NeutralizeWorker.sql:45-49`. Consequences a polling consumer/operator
actually sees:

- During the clone (the longest step, minutes) `GetResetStatus` shows
  `Status='running'` with **StepLog still empty** — no indication anything is
  happening or which step is in flight.
- On a mid-step failure, the CATCH records `ErrorText = ERROR_MESSAGE()`
  (`ProcessNextResetRequest.sql:100,110-112`) but the **failed step never wrote a
  StepLog line**. So StepLog ends at the last *successful* step and the operator
  must infer "the next one failed" and pair it with a possibly cryptic raw SQL
  error (e.g. a `RESTORE` path error) to know where they are.

This directly contradicts the code header — "Each internal step appends its own
progress to StepLog **as it goes**, so GetResetStatus shows **live progress** and
the log survives a mid-step failure" (`ProcessNextResetRequest.sql:9-12`) — and
the runbook's "watch Status + StepLog: clone -> ..."
(`testmandant-reset-validierung.md:86-88`) and architecture §1a.3. The promise is
"live"; the delivery is "on completion".

**Proposed fix.** In `ProcessNextResetRequest`, write a
`'... starting step N/8: <name>'` StepLog line **before** each `EXEC` in the
pipeline (single place, keeps the internal steps as-is, DRY). That makes the
in-flight step visible during long operations and makes the failed step explicit
on CATCH (last "starting" line = the step that threw). Alternatively add a start
line inside each `internal_*`. Either way, reconcile the header/architecture text
with the actual behaviour.

**Size:** S

---

## OPS-4 — Silent failures: no alerting on a failed or stale-reclaimed request — nice

**Evidence.** The Agent job is created with `@on_fail_action = 2` (quit
reporting failure) but **no** `@notify_email_operator`/operator wiring
(`reset.EnsureAgentJob.sql:36-51`). A stale-reclaim marks the row `failed`
entirely inside SQL with no notification (`ProcessNextResetRequest.sql:26-32`).
So the only way anyone learns a reset failed is by actively polling
`GetResetStatus`. For a reset a colleague triggered and is watching, that is
acceptable; for an **async death that gets stale-reclaimed hours later**, nobody
is told at all.

**Proposed fix.** Either wire a job-failure operator notification
(`sp_add_job @notify_level_email = 2`, `@notify_email_operator_name = ...`) so
DB Mail alerts on the job step failing, or — minimally — document in the runbook
that failures are pull-only and the reclaim path is silent, so operators know to
poll after an unexpected host restart.

**Size:** S

---

## OPS-5 — No retention/cleanup of ops.ResetRequest; StepLog/ErrorText grow unbounded — nice

**Evidence.** `ops.ResetRequest` rows are never purged — no retention SP or job
exists (`0002_ops_schema_tables.sql:71-95`; nothing in the file tree does
cleanup). Each row carries `nvarchar(max)` `StepLog` and `ErrorText`. Good for
audit; but over years the queue table grows without bound and there is no defined
policy. `GetResetStatus` masks this with `TOP (50)`
(`reset.GetResetStatus.sql:18`), which keeps the read usable but also means old
history is only reachable by explicit `@RequestId`.

**Proposed fix.** Add an admin-run `reset.PurgeOldRequests` (keep last N per
mandant, or delete `succeeded`/`failed` rows older than X months, always keeping
the most recent per mandant) and mention it in a runbook, or explicitly document
"retain forever, audit table" as the accepted decision. Low urgency; flagged so
the choice is conscious rather than accidental.

**Size:** S

---

## OPS-6 — Re-submitting an already-queued mandant errors instead of returning the in-flight request — nice

**Evidence (walked scenario).** Dana clicks twice / a colleague re-runs Start for
a mandant that is already `queued`/`running`. She gets `THROW 51004 'A reset for
this mandant is already queued or running.'` (`reset.StartTestmandantReset.sql:50-52`)
— an *error*, not the `RequestId`/`Status` she needs to keep polling. The happy
path returns `SELECT @RequestId, 'queued'` (:74); the "already in flight" path
returns an exception, so a simple client that expects a result set breaks and the
message doesn't tell her *which* request to poll.

**Proposed fix.** On the duplicate case, instead of (or in addition to) throwing,
`SELECT` the existing active `RequestId` + `Status` for that `TargetDb` so the
caller transparently continues polling the in-flight run. Keep it friendly:
"already running as request N" is more useful than an exception.

**Size:** S

---

## Confirmed-good (no action)

- **Audit "who/when":** `ORIGINAL_LOGIN()` is captured into `RequestedBy` under
  EXECUTE-AS masking (`StartTestmandantReset.sql:29,54`) — the real caller is
  recorded, not `jobstartuser`. Solid.
- **Grants are exactly minimal:** the executor gets `EXECUTE` on precisely the
  two SPs and nothing on the tables; `GetResetStatus` reads `ops.ResetRequest`
  via ownership chaining, so no table grant is missing for the granted surface
  (`GetResetStatus.sql:18-33` + `100_grants.sql`). The `ShopLicense` column-DENY
  (`0003_roles.sql:33`) is correct defense-in-depth. The only "missing" surface
  is a *feature* (list-mandants, OPS-1), not an under-grant.
- **Error messages on the Start path** (51001–51004) are human-readable, not raw
  engine errors. The raw-error concern is confined to the pipeline CATCH, covered
  by OPS-3.
- **Half-done clone on failure:** intentionally left MULTI_USER for diagnosis
  (`ProcessNextResetRequest.sql:102-108`) and the runbook cleanup (Step 6,
  failure-modes block) is correct — drop the stale clone before re-running.
