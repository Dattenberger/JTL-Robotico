---
title: VPE-Check Warenbestellung — Implementation Report
status: Implemented
date: 2026-07-23
subsystem: JTL SQL Migrations
audience: team-lead / orchestrator (commit pending user review)
---

# VPE-Check Warenbestellung — Implementation Report

Implementation of the custom workflow action
`CustomWorkflows.spVpeCheckLieferantenbestellung`, live-verified on test mandant
`eazybusiness_tm9` (vm-sql-test1). Faktenbasis: `vpe-workflow-research.md`.

## What was built

A single anytime sproc (`CREATE OR ALTER`, hand-idempotent) that JTL-Wawi calls as a
custom workflow action with the order PK `@kLieferantenBestellung INT`. Per position it:

1. Looks up the **supplier-specific** VPE on `tLiefArtikel`
   (`tArtikel_kArtikel = pos.kArtikel AND tLieferant_kLieferant = order.kLieferant`);
   VPE present when `nVPEMenge >= 2`.
2. Writes a marker to the **left** of `tLieferantenBestellungPos.cHinweis`:
   - VPE ok: `{{VPE=10}}`
   - VPE + price error: `{{VPE=10, VPE Error Preis 110>>2.27}}`
     (left = `pos.fEKNetto` imported, right = `tLiefArtikel.fEKNetto`).
   - Price error := `pos.fEKNetto >= 1.5 * tLiefArtikel.fEKNetto AND tLiefArtikel.fEKNetto > 0`
     (VPE positions only). Volume-tier prices (`tLiefArtikelPreis`) are deliberately
     ignored in v1 (documented in the file header).
3. Aggregates to the head: if ≥1 position has a price error, appends ` {{VPE Error}}` to
   `tLieferantenBestellung.cFremdbelegnummer` (suffix → original number stays
   prefix-searchable); removes it again when no error remains.

**Number format (chosen, documented in header):** decimal **point** separator, 2 decimals
with trailing zero-decimals stripped, via `FORMAT(x,'0.##','en-US')` (locale-independent —
test1 runs a German locale). So `110.00 → 110`, `2.2733 → 2.27`, `10.0 → 10`.

**Idempotency:** a leading `{{VPE…}}` marker is parsed off (up to the first `}}` + one
space) before a new one is prepended; the head marker is stripped via `REPLACE` before
re-append. Repeated runs never stack. Field limits guarded: cHinweis via `LEFT(marker+note,
2000)` (marker sits at front → only the note tail is ever trimmed), cFremdbelegnummer by
trimming the base number, never the appended marker.

## Update path chosen — sanctioned JTL SP via XML batch (path A)

Positions are written through `Lieferantenbestellung.spLieferantenBestellungPosBearbeiten`
using its **XML batch parameter** `@xLieferantenbestellungPos`, not a direct UPDATE.

Why (over the CONTEXT_INFO-bypass fallback B): `tLieferantenBestellungPos` carries the
guard trigger `tgr_tlieferantenBestellungPos_INSUPDEL` that rolls back any direct write
unless `CONTEXT_INFO()` holds a JTL magic value. The SP sets that context itself
(verified live: it does `SET CONTEXT_INFO 0x5123` — note the research's tentative `0x5124`
was for the raw bypass; path A sidesteps the magic constant entirely). The XML form
updates **all changed positions in one set-based call**, is JTL-sanctioned (survives Wawi
updates), and is side-effect-free here: the SP only touches stock (`tlagerbestand`) when
`fMenge`/`fMengeGeliefert` actually change, and we round-trip those columns unchanged.
This makes path A cleaner *and* more maintainable than B — no undocumented constant, no
per-row cursor. `cFremdbelegnummer` is **not** in the head trigger's guard-column list
(verified live against `tgr_tlieferantenBestellung_INSUPDEL`), so the head marker is a
plain direct UPDATE.

Consistency: the two writes are intentionally not wrapped in one outer transaction (the SP
owns its own and self-rolls-back on error); the action's full idempotency repairs any
partially-applied run on the next execution.

THROW allocation: `50001` (Ebene A) for the NULL-key guard — documented in
`db-migrations/README.md` §4 rule (k).

## Test protocol (live, `eazybusiness_tm9`, supplier 2, order 4064 — cleaned up after)

Seed: VPE article 569 (`6123037`, nVPEMenge=10, tLiefArtikel.fEKNetto=2.2733) and non-VPE
article 48 (`6120001`, nVPEMenge=0). Test order + positions created via CONTEXT_INFO bypass
(test-harness only), deleted at the end.

| # | Case | Before | After (verified) |
|---|---|---|---|
| a | VPE, price ok (pos1: EK 2.27) | `Rasenroboter Zubehör; Unhandlich` | `{{VPE=10}} Rasenroboter Zubehör; Unhandlich` ✓ |
| b | VPE, price error (pos2: EK 110) | `Rasenroboter Ersatzteile` | `{{VPE=10, VPE Error Preis 110>>2.27}} Rasenroboter Ersatzteile` ✓ |
| b (head) | error present | `TESTBELEG-VPE` | `TESTBELEG-VPE {{VPE Error}}` ✓ |
| c | no VPE (pos3: art 48) | `Gartengeräte Zubehör` | `Gartengeräte Zubehör` (unchanged) ✓ |
| d | idempotency (2nd run) | markers present | **identical** — no stacking ✓ |
| e | price fixed (pos2 EK→2.27), 3rd run | error markers present | pos2 → `{{VPE=10} } Rasenroboter Ersatzteile`; head → `TESTBELEG-VPE` (error marker gone from **both**, `{{VPE=10}}` stays) ✓ |
| f | existing text preserved | — | base note kept behind marker in a/b/e ✓ |
| + | full VPE loss (pos1 → non-VPE art), re-run | `{{VPE=10}} Rasenroboter Zubehör; Unhandlich` | `Rasenroboter Zubehör; Unhandlich` (marker fully stripped, base clean) ✓ |

Trigger acceptance confirmed live: the position SP path and the direct
`cFremdbelegnummer` UPDATE both succeeded against the active guard triggers.

Lint: `npm run db:lint` → **0 errors** (2 pre-existing warnings in
`reset.spInternal_GrantAccess.sql`, unrelated).

## Chain embedding (Ebene A audit)

Systematic check that the action sits fully inside the normal MSSQL-Ops infrastructure.

**Already correct (no change needed):**
- **Location / naming.** `db-migrations/eazybusiness/sprocs/CustomWorkflows.spVpeCheckLieferantenbestellung.sql`
  — anytime `sprocs/` script, `CREATE OR ALTER`, filename == object identity (lint rule e).
  Name follows `NAMING-CONVENTIONS.md` §2 (`sp<ActionName>`) and §4 (English feature verb +
  German JTL object) — the doc is a convention reference, not a per-action catalog, so nothing
  to add there.
- **Registration.** Byte-for-byte the same guarded trailer as the other action procs
  (`spGebindeErstellen`, `spZustandartikelLieferantSetzen`): `IF OBJECT_ID('CustomWorkflows._CheckAction')…`
  + `_SetActionDisplayName`, each with the module-not-booked `PRINT` fallback (README §6). The
  helpers are vendor objects; the chain never creates them.
- **`MSSQL-OPS-ARCHITECTURE.md`.** Its component table lists infrastructure generically
  ("Ebene-A tree … our own CustomWorkflows.* action procs"); it does **not** enumerate
  individual action procs (none of the existing ones are listed either), so adding a row would
  break that convention — left unchanged.
- **`JTL-CUSTOM-WORKFLOWS.md`.** A [DB]-verified research snapshot, not a maintained registry —
  left unchanged.
- **`MSSQL-OPS-DATA-MODEL.md`.** Column-level reference for `ops.*` tables only; no table DDL
  touched — out of scope.

**Added:**
- **`db-migrations/README.md`** §4 rule (k): THROW `50001` allocated to this proc (Ebene A).
- **`WorkflowProcedures/README.md`**: "New actions" section (Wawi linkage hint) — kept out of
  the ported-provenance table since this is a greenfield object with no legacy source.

**Does not exist at Ebene A (nothing invented):**
- There is **no** `validate_structure.sql` / `validate_rollout.sql` gate for the eazybusiness
  chain — those are Ebene-B-only (`tests/global/`), driven by the RoboticoOps rollout gate.
  The eazybusiness chain's test layer is the ported functional `tests/eazybusiness/*_Tests.sql`
  scripts, which cover the `Robotico.*` utility functions and history sprocs; **no
  CustomWorkflows action proc has a committed test script** (spGebinde/spZustand/spAuftragPreise/
  spSeriennummer all ship without one). This action follows that established pattern — it was
  verified live on tm9 instead (protocol a–f above). If the team later wants committed coverage
  for the action procs, a `tests/eazybusiness/VpeCheck_Tests.sql` in the existing `*_Tests.sql`
  style would be the place; that is a new convention decision, not part of this task.

**Commenting pass (task 2).** The proc header + inline comments were expanded to the style of
the recent chain files (the `maint.*` sprocs' dense "why"-first blocks; English per the repo
convention, German only in the literal marker strings): purpose + Wawi call context, marker
formats with worked examples, the decimal-point / 2-decimal-trim format decision, the 1.5x
threshold with its `fEKNetto > 0` guard, the v1 volume-tier exclusion, the trigger write-path
rationale (JTL SP vs. the CONTEXT_INFO bypass, with the live `0x5123` finding and why no direct
UPDATE), the idempotent marker parsing, and the 2000 / 255 truncation guards. This is a
comment-only change (no behaviour change); the proc was re-applied to tm9 by hand (single-file
sqlcmd, **not** a grate run) so the deployed definition matches the file.

## Files changed / added

- **NEW** `db-migrations/eazybusiness/sprocs/CustomWorkflows.spVpeCheckLieferantenbestellung.sql`
- **EDIT** `db-migrations/README.md` — THROW `50001` allocation (Ebene A, rule k).
- **EDIT** `WorkflowProcedures/README.md` — new "New actions" section (Wawi linkage hint).
- **NEW** `docs/plans/2026-07-10 - mssql-ops-infrastruktur/reports/vpe-workflow-implementation.md` (this file).

## Open points

1. **Wawi event availability (blocking, per research open point 1).** It is still unverified
   in the Wawi UI whether a workflow event exists on the *Lieferantenbestellung/Warenbestellung*
   object and that it passes `kLieferantenBestellung` (not `…Pos`). Must be confirmed before
   the action can actually be wired. The proc is correct regardless of that answer.
2. **Volume-tier EK (`tLiefArtikelPreis`)** ignored in v1 — may cause false price-error flags
   for tiered articles; revisit if false positives appear.
3. **Number rounding mode** follows .NET `FORMAT` (round-half-to-even at the 2-decimal
   boundary). Price-error *detection* uses raw values, so display rounding never affects the
   flag; only the shown digits.
4. **Proc left deployed on `eazybusiness_tm9`** (throwaway clone). No production deploy was
   run (the working copy carries the not-yet-released PayPal-drop migration; the full grate
   chain must NOT run — the proc was applied to tm9 manually per the task).
