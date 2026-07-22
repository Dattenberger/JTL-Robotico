# Research: indexoptimize-liveness-heartbeat

**Date:** 2026-07-22T21:57:00+02:00
**Triggered by:** Finding L-B1-3 ∪ plan-and-api-B1-1 (Nice-to-have, merged) —
`maint.spCheckMaintenanceLiveness` treats an `IndexOptimize` row as alive only if an
`ALTER_INDEX` **or** `UPDATE_STATISTICS` `CommandLog` row exists in its window. `up/0023`
+ the `OperationKnobs` CHECK permit `bUpdateStatistics = 0` (D33 "parameter-omitted"
exception), and `spRunMaintenanceJob` then runs Ola `IndexOptimize` with no statistics
maintenance. On a low-churn night with nothing past the reorg threshold, neither row is
logged → false `THROW 51105` on a green job. Latent today (the sole `index-optimize` seed
row is `bUpdateStatistics = 1`); surfaces only for a future stats-off `IndexOptimize` row.
**Agent-ID:** repair-research (implement-long-plan-v3)

## Problem statement

The liveness check (D36, AC13) infers **"the job ran"** from **"the job did loggable
work"**. For its two watched operations that inference holds today only by accident of the
current registry:

- **`IntegrityCheck`** — `DatabaseIntegrityCheck @LogToTable='Y'` writes a `DBCC_CHECKDB`
  `CommandLog` row **per database, every run**, unconditionally. Reliable heartbeat.
- **`IndexOptimize`** — `CommandLog` rows are written **only per command actually
  executed** (`dbo.CommandExecute` is the sole INSERT site; it fires once per index
  reorganize and once per statistic update — `up/0022` l.292–295). With
  `bUpdateStatistics = 1` → `@UpdateStatistics='ALL'` and Ola's default
  `@OnlyModifiedStatistics='N'`, **every** statistic is updated every run → a guaranteed
  per-run `UPDATE_STATISTICS` heartbeat. The proc header already leans on exactly this.
  With `bUpdateStatistics = 0` the `@UpdateStatistics` parameter is omitted entirely
  (`spRunMaintenanceJob` l.71–78) → **no `UPDATE_STATISTICS` rows ever**, and `ALTER_INDEX`
  rows appear **only when an index crosses the 30 % fragmentation threshold**. On a
  low-churn night (and eazybusiness measured **0 indexes >30 %** after 8 months — ADR-A
  §Research/F7), Ola writes **zero** `CommandLog` rows for a fully successful run.

So a `bUpdateStatistics = 0` `IndexOptimize` row that runs green on a quiet night looks
identical to a job that has silently stopped → the watchdog raises a false `THROW 51105`
(and, because the watchdog is hourly, keeps raising it until the next night that happens to
produce fragmentation work). This is the cry-wolf alarm-fatigue failure the whole design
fights, inverted onto the watchdog itself.

**Latent, not live:** the only `IndexOptimize` seed row (`index-optimize`) is
`bUpdateStatistics = 1`, so the guaranteed `UPDATE_STATISTICS` heartbeat is present and the
check is correct today. The gap is armed only if someone later adds — or flips an existing
row to — a stats-off `IndexOptimize` registry entry.

## Sources

1. `db-migrations/global/sprocs/maint.spCheckMaintenanceLiveness.sql` (l.54–63) — the
   `CommandType IN ('ALTER_INDEX','UPDATE_STATISTICS')` match and the schedule-derived
   window; header l.15–17 already states the `UPDATE_STATISTICS`-every-run assumption.
2. `db-migrations/global/sprocs/maint.spRunMaintenanceJob.sql` (l.62–79) — the two
   `IndexOptimize` dispatch branches: `bUpdateStatistics = 1` passes `@UpdateStatistics='ALL'`;
   `= 0` omits the parameter (Ola default = no statistics maintenance).
3. `db-migrations/global/up/0023_maintenance_registry.sql` (l.51–52, CHECK l.87–91) —
   `bUpdateStatistics IS NOT NULL` for `IndexOptimize` (permits **both** 0 and 1); the
   inline comment ties the omitted-parameter reading to F8.
4. `db-migrations/global/up/0022_maintenance_ola_vendor.sql` (l.292–295) — the **only**
   `CommandLog` INSERT is inside `dbo.CommandExecute`, called once per executed command;
   no command list ⇒ no INSERT ⇒ no run marker. Confirms the empty-work-no-row behaviour.
5. `docs/decisions/0001-maintenance-as-code-roboticoops.md`
   (§Research/F7–F8, §Consequences liveness guard, D-A2/D-A5 decision history) — the
   project's whole reason for existing is that the **old broken job ran index optimize
   *without* `@UpdateStatistics` (F8)**; `bUpdateStatistics = 0` reproduces exactly that.
6. `docs/SQL/MSSQL-OPS-DATA-MODEL.md` (`bUpdateStatistics` row) — the same-commit column
   contract; currently documents the 1/0 mapping but not the liveness coupling.
7. Sibling research `research/liveness-first-run-grace.md` (finding L-B1-2) — independently
   records "IndexOptimize with `@UpdateStatistics='ALL'` + Ola default logs
   `UPDATE_STATISTICS` even when nothing is fragmented → `CommandLog` is reliable run-
   evidence"; that reliability is precisely what a stats-off row removes.

## Findings

### The coupling is real, but it is *aligned* with the design's intent — not a design bug

`bUpdateStatistics = 0` is not a neutral configuration. Per source 5 it **is** the F8
anti-pattern (`IndexOptimize` without statistics maintenance) that this entire plan was
built to eliminate — AC10 exists to make "statistics are finally maintained
(`@UpdateStatistics='ALL'`)" true and enforced. The liveness check's implicit premise
"a watched `IndexOptimize` row maintains statistics, so it emits a per-run heartbeat" is
therefore **consistent with the plan's core intent**, not an accident to be engineered
around. The single defect is that this premise is **implicit** — a maintainer adding a
stats-off row gets no signal that they are simultaneously (a) reintroducing F8 and
(b) blinding the liveness heartbeat, until 2 a.m. false pages appear.

### Weighing the resolution — visibility over machinery (D4)

Three families of fix were considered, ranked by long-term maintainability:

- **A — Make the coupling explicit (document at the three maintainer touch-points).**
  Zero behaviour change; keeps the plan's deliberate "infer liveness from `CommandLog`"
  design (D36) and its accepted "enforce by doc, not CHECK" precedent (the `cDatabases`
  two-grammar column is already doc-enforced, plan §3.1 NOTE). The residual failure mode is
  a **loud** false alarm on an unusual config — strictly safer than any silent outcome, and
  the alarm itself points the maintainer at the doc. **Recommended.**

- **B — Emit an unconditional heartbeat row from the dispatcher.** `spRunMaintenanceJob`
  would INSERT a synthetic marker into `dbo.CommandLog` after each `IndexOptimize`, and
  liveness would key off it. This decouples liveness from work, but **pollutes a vendored
  third-party table** with non-Ola rows (a maintainability smell that couples us to Ola's
  pinned `CommandLog` schema and confuses Ola-native reporting), and adds real behaviour to
  a green, live-validated block for a latent Nice-to-have. A dedicated `maint`-owned run-
  history table is the clean version of B but is a genuine architectural addition,
  disproportionate here and arguably an ADR-level change. **Rejected as over-engineering**
  while every watched `IndexOptimize` row is stats-on.

- **C — Structurally forbid stats-off `IndexOptimize`** (tighten the `OperationKnobs` CHECK
  from `bUpdateStatistics IS NOT NULL` to `= 1`). One-line change; makes the heartbeat
  always reliable *and* makes AC10 structural; only possible while `up/0023` is still
  pre-first-prod-apply (finding F1's window). **But** it reverses a deliberately accepted
  ADR decision (D33 / D-A2 chose to *permit* `0` as an escape hatch), which belongs in an
  ADR Decision-History entry, not a silent Nice-to-have repair, and it removes a (rarely
  legitimate: defrag with statistics owned by a separate mechanism) capability. **Not the
  primary fix**, but a defensible *stricter* posture the team may adopt via ADR — see the
  optional escalation in Implementation Hints.

Rejected outright: **excluding `bUpdateStatistics = 0` rows from the liveness scan** silences
the false alarm by making that row a **silent** liveness blind spot — reintroducing the exact
F3/F4 "never ran" gap D36 exists to close. A visible false alarm beats an invisible outage.
It is offered only as the maintainer's *documented, opt-in* escape (mirroring the Cleanup
exemption) at the moment they actually add such a row and can weigh it — not baked in now.

### Interaction with the sibling liveness fix (L-B1-2)

`research/liveness-first-run-grace.md` also edits this proc (a `dModified` grace predicate
and a per-row window `CROSS APPLY`). This finding's fix is **doc-only in the same header
block plus two other files** and does not touch the query logic, so the two fixes compose
without conflict. If both land together, fold this note into the same header rewrite.

## Implementation Hints

Apply fix **A**. No code-behaviour change; three documentation edits making the (intended)
coupling explicit at every place a maintainer looks when adding an `IndexOptimize` row.

1. **`db-migrations/global/sprocs/maint.spCheckMaintenanceLiveness.sql`** — extend the
   existing `CommandType mapping` paragraph in the header (l.15–17) with:

   > `IndexOptimize` liveness relies on the per-run `UPDATE_STATISTICS` heartbeat that
   > `@UpdateStatistics='ALL'` (registry `bUpdateStatistics = 1`) guarantees. A
   > `bUpdateStatistics = 0` row (Ola runs with no statistics maintenance — itself the F8
   > anti-pattern this suite exists to remove, ADR-A §F8/AC10) has **no reliable per-run
   > heartbeat**: `ALTER_INDEX` is logged only when an index crosses the reorg threshold, so
   > a green run on a low-churn night logs nothing and this check would false-fire `51105`.
   > Before enabling a stats-off `IndexOptimize` row, revisit this scan — either add a
   > run-marker, or exempt that row here as a *documented* liveness blind spot (mirroring the
   > Cleanup exemption). Do not silently exclude it.

   Leave the `WHERE`/`CommandType` predicate unchanged: keeping `ALTER_INDEX` in the OR is
   harmless (it can only *reduce* false alarms for a hypothetical stats-off busy night), and
   removing it buys nothing.

2. **`docs/SQL/MSSQL-OPS-DATA-MODEL.md`** — append to the `bUpdateStatistics` row (after the
   existing `1`/`0` mapping):

   > Liveness (D36) depends on this: value `1` guarantees a per-run `UPDATE_STATISTICS`
   > `CommandLog` heartbeat, so `spCheckMaintenanceLiveness` can see the run. Value `0`
   > removes that heartbeat (and reintroduces F8) — a stats-off `IndexOptimize` row is a
   > liveness blind edge; `spCheckMaintenanceLiveness` must be revisited before one is added.

3. **`db-migrations/global/sprocs/maint.spRunMaintenanceJob.sql`** — one line on the
   `bUpdateStatistics = 0` branch comment (l.72–73), e.g.:

   > `-- NB: a stats-off IndexOptimize has no guaranteed per-run CommandLog heartbeat —`
   > `-- see maint.spCheckMaintenanceLiveness header before enabling such a row.`

**Optional escalation (team decision, out of scope for this repair — do NOT bundle it in
silently):** if the team decides the F8 escape hatch is not worth its foot-gun, tighten the
`CK_tMaintenanceJob_OperationKnobs` CHECK in `up/0023` from `bUpdateStatistics IS NOT NULL`
to `bUpdateStatistics = 1` for the `IndexOptimize` arm (available cheaply only while `0023`
is pre-first-prod-apply — same immutability window as F1). This makes AC10 structural and
the heartbeat unconditionally reliable, but it **reverses D33/D-A2** and must be recorded as
an ADR Decision-History entry with the reciprocal plan §3.1/AC10 edit — not applied as a
Nice-to-have side effect.

**Testing note:** on test1 the proc early-`RETURN`s (`MaintenanceSchedulesEnabled = '0'`,
D34), so this behaviour is not reachable through the effective-enabled entry point there and
needs no live B5 step. Since fix A is doc-only, no regression test is required; if the team
later takes escalation C, add a CHECK-violation assertion (an `IndexOptimize` row with
`bUpdateStatistics = 0` must fail to insert).

## References

- Plan: `docs/plans/2026-07-21 - mssql-wartung-ola/mssql-wartung-ola.md` — §3.2 (D36),
  §3.1 (D33 `OperationKnobs` CHECK + the doc-enforced `cDatabases` grammar precedent),
  AC10, AC13.
- ADR: `docs/decisions/0001-maintenance-as-code-roboticoops.md`
  — §Research (F7/F8, 0 indexes >30 %), §Consequences (liveness guard), D-A2/D-A5 history.
- Code: `db-migrations/global/sprocs/maint.spCheckMaintenanceLiveness.sql`,
  `db-migrations/global/sprocs/maint.spRunMaintenanceJob.sql`,
  `db-migrations/global/up/0023_maintenance_registry.sql`,
  `db-migrations/global/up/0022_maintenance_ola_vendor.sql` (l.292–295).
- Docs: `docs/SQL/MSSQL-OPS-DATA-MODEL.md` (`bUpdateStatistics` row).
- Sibling research (same proc, compose together): `research/liveness-first-run-grace.md`.
