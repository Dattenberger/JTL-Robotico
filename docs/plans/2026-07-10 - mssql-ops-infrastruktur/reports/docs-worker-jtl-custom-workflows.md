# Doc-Worker Report — jtl-custom-workflows

**Date:** 2026-07-10T02:45:00+02:00
**Action:** `update`
**Target:** `docs/SQL/JTL-CUSTOM-WORKFLOWS.md`
**Outcome:** `no-change-needed`

## Sources reconciled against

Three newly-ported CustomWorkflows action sprocs (all *added* at `cf02f1a`, one
touched again at `54f38fd` repair wave 1 — none pre-existed plan start `9592c99`,
so the diff is pure additions):

- `db-migrations/eazybusiness/sprocs/CustomWorkflows.spPaypalTrackingVersand.sql`
- `db-migrations/eazybusiness/sprocs/CustomWorkflows.spArticleUpdateAllHistory.sql`
- `db-migrations/eazybusiness/sprocs/CustomWorkflows.spZustandartikelLieferantSetzen.sql`

## Verification — doc vs. shipped code

The discovery report classified this as low-priority "verify the ported CW sprocs
don't contradict the registration mechanics described (likely no-change)."
Confirmed no-change. Point-by-point:

| Doc claim | Shipped code | Verdict |
|---|---|---|
| §4.3 live example: `spArticleUpdateAllHistory` has `@kArtikel int` + `userName nvarchar` | `@kArtikel INT, @userName NVARCHAR(100) = NULL` | matches exactly |
| §7 PK-first rule: Versand → `kVersand` (nObjekt 16) | `spPaypalTrackingVersand @kVersand INT` | matches |
| §4.2 PK-first `int` rule for Artikel → `kArtikel` | `spZustandartikelLieferantSetzen @kArtikel INT` | matches |
| §4.1 NOTE: "no registration step; `_CheckAction`/`_SetActionDisplayName` are convenience/validation/labelling helpers, not a registry" | ported files call these helpers exactly as convenience validation/labelling, guarded | confirmed, not contradicted |
| §3 licensing: module must be booked; helpers are module-provided | ported files guard the helper EXECs (`IF OBJECT_ID(...) IS NOT NULL … ELSE PRINT '… module not booked …'`) | consistent — the guard operationalises this exact licensing reality |

No claim became false; no example went stale; no diagram/table needs updating.
The doc is a JTL-mechanics reference (framed against the live test DB where the
module is booked); the port changed no JTL mechanics.

## Sections added / removed

None. Considered adding a gotcha to §8 (its recipe shows *unguarded* `_CheckAction`
/ `_SetActionDisplayName` EXECs, whereas the shipped migration files guard them
against a machine where the module is not booked). Rejected on the **SSoT rule**:
that guarded-registration pattern already has its single source of truth in
`db-migrations/README.md §6` ("Registration pattern in our action files"), which
also carries the reciprocal cross-reference back to this doc. Duplicating it here
would create two homes for the same content. §8's unguarded form is correct for
its own framing (the minimal skeleton JTL recognises, on a DB where the module is
present).

## Files outside assigned scope (drift)

none

## Notes for final

- **Reciprocal cross-reference gap (cross-doc — for the final agent).**
  `db-migrations/README.md §6` links *to* this doc ("Booking the module … is a
  documented prerequisite — see `docs/SQL/JTL-CUSTOM-WORKFLOWS.md`"), but this doc
  has no link *back*. Consider a one-line pointer (e.g. near §8's recipe or the §3
  licensing block) noting that this repo's version-controlled ports of these
  actions live in `db-migrations/eazybusiness/sprocs/CustomWorkflows.*` and use a
  **guarded** registration pattern (`db-migrations/README.md §6`) precisely because
  the module helpers may be absent. Left to final so the link direction and sibling
  wording stay consistent across the doc set. Not a correctness issue — purely a
  navigability improvement.
