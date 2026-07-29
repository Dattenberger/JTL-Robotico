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

> [!IMPORTANT]
> **Addendum 2026-07-29 — Write-path revised to CONTEXT_INFO (path B).** The position write
> was changed from the vendor SP `spLieferantenBestellungPosBearbeiten` (XML batch, "path A")
> to a **direct set-based `UPDATE cHinweis` under `CONTEXT_INFO 0x5123`**, with the caller's
> context saved and restored (error path included). New fact (live at the e2e container +
> tm9): `tgr_tlieferantenBestellungPos_INSUPDEL` has **no column list** — it rolls back every
> direct write and only checks `CONTEXT_INFO()` against a whitelist
> (`0x5123, 0x5124, 0x5125, 0x5129, HASHBYTES('SHA1','spUpdateLieferantenBestellungPosToFreiPosForStuecklistenVaeter')`).
> **Why B over A:** the failure mode. If a Wawi update ever changed the whitelist constants,
> path B fails **loud and harmless** (the `UPDATE` is rolled back, the action errors, the log
> shows it), whereas path A round-trips every position column through the vendor SP and could
> **silently drift/corrupt** row data on a future SP-signature/behaviour change. A single
> `cHinweis` UPDATE also avoids the SP's stock-recalc side effects entirely. The head marker
> stays a plain direct `UPDATE` (head trigger does not gate `cFremdbelegnummer`). Re-verified
> a–f on both environments (see Test protocol), plus CONTEXT_INFO restoration and a negative
> probe (direct write without the marker stays blocked). The sections below describe the
> current (path B) implementation; the earlier "Update path chosen" text is kept as history
> with a pointer to this addendum.

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

## Update path chosen — CONTEXT_INFO direct write (path B, revised 2026-07-29)

> Superseded decision below. Until 2026-07-29 positions were written via the vendor SP
> `spLieferantenBestellungPosBearbeiten` (XML batch, "path A"); see the addendum at the top
> for why that was revised. This section describes the **current** path B.

Positions are written by a **single set-based `UPDATE` of `cHinweis`** wrapped in
`SET CONTEXT_INFO 0x5123` (save caller's context → set marker → UPDATE → restore, restore on
the CATCH path too). `tLieferantenBestellungPos` carries the guard trigger
`tgr_tlieferantenBestellungPos_INSUPDEL`, which — verified live (e2e container + tm9,
2026-07-29) — has **no column list**: it rolls back every direct write and only checks
`CONTEXT_INFO()` against its whitelist (`0x5123, 0x5124, 0x5125, 0x5129, HASHBYTES('SHA1',
'spUpdateLieferantenBestellungPosToFreiPosForStuecklistenVaeter')`). `0x5123` is the marker
JTL's own PosBearbeiten SP uses.

Why B over A: the failure mode (full rationale in the top addendum). A single-column
`cHinweis` UPDATE cannot silently corrupt other row data and skips the vendor SP's stock
side effects; if a Wawi update ever changed the whitelist constants, the effect is a loud,
harmless rollback rather than silent column drift. `cFremdbelegnummer` is **not** in the head
trigger's guard-column list (verified live against `tgr_tlieferantenBestellung_INSUPDEL`), so
the head marker is a plain direct UPDATE with no context change.

Consistency: the two writes (positions, head) are intentionally not wrapped in one outer
transaction; the action's full idempotency repairs any partially-applied run on the next
execution. The CATCH re-raises with a bare `THROW;` (preserves number/severity/line).

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

Trigger acceptance confirmed live: the position write and the direct `cFremdbelegnummer`
UPDATE both succeeded against the active guard triggers.

**Re-verification 2026-07-29 (path B, both environments).** The full a–f protocol above was
re-run after the CONTEXT_INFO refactor on **two** servers, each seeded and cleaned up (marker
`cEigeneBestellnummer = 'CLAUDE-VPE-TEST'`):
- **e2e container** `robotico-e2e-mssql` (localhost,14330, SQL auth), supplier 2 / article 268
  (nVPEMenge=100, liefEK=1.0864): a–f all green, e.g. `{{VPE=100, VPE Error Preis 110>>1.09}}`.
- **test1** `eazybusiness_tm9` (Kerberos), supplier 2 / article 569 (nVPEMenge=10, liefEK=2.2733):
  a–f all green, `{{VPE=10, VPE Error Preis 110>>2.27}}`.
- Both: **CONTEXT_INFO restoration** verified (a sentinel value set before EXEC is byte-identical
  after EXEC → "RESTORED OK"), and a **negative probe** (direct `UPDATE cHinweis` with
  `CONTEXT_INFO 0x0`) is rolled back by the trigger with the JTL error, cHinweis unchanged.
- vm-sql2/PROD not touched.

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
rationale (the CONTEXT_INFO whitelist and the path-B-over-A decision, both re-verified live),
the idempotent marker parsing, and the 2000 / 255 truncation guards. (Header updated again in
the 2026-07-29 path-B refactor; see the top addendum.) The proc was re-applied to the e2e
container and tm9 by hand (single-file sqlcmd, **not** a grate run) so both deployed definitions
match the file.

## Files changed / added

- **NEW** `db-migrations/eazybusiness/sprocs/CustomWorkflows.spVpeCheckLieferantenbestellung.sql`
  (refactored 2026-07-29 to the CONTEXT_INFO direct write, path B).
- **EDIT** `db-migrations/README.md` — THROW `50001` allocation (Ebene A, rule k).
- **EDIT** `WorkflowProcedures/README.md` — new "New actions" section (Wawi linkage hint).
- **EDIT** `docs/SQL/JTL-CUSTOM-WORKFLOWS.md` §4.4 — full position-trigger whitelist + VPE
  write-path updated to the CONTEXT_INFO direct write (2026-07-29).
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
