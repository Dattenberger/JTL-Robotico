---
name: jtl-wawi-spezifika
description: JTL-Wawi constraints for test-mandant and migration infrastructure — Worker, updates, license (Research, 2026-07-09)
status: Research
---

# JTL-Wawi Specifics for Test-Mandant and Migration Infrastructure

> Source: Opus research agent “research-jtl”, session 2026-07-09 (repo + web, confidence marked per item).
> Partly made concrete in the meantime by the instance survey (see `_pending-instanz-survey.md`): Worker flags found in `ebay_user.nGesperrt`, `pf_user.nGesperrt/nAktiv`, `tShop.nGesperrt`, `Worker.tTarget`.

**Most important finding up front:** the JTL Worker synchronizes *all* mandants registered in `tMandant` of the same server connection ([Worker settings](https://guide.jtl-software.com/jtl-wawi/jtl-worker/einstellungen-im-jtl-worker/)). “Clone + `register-mandant.sql`” makes the test mandant visible and syncable for a running production Worker — the single biggest systemic risk.

## 1. JTL mandant management — official path vs. clone approach

**Finding (confidence: high):** a mandant = an independent company, **each mandant = its own database**; managed via *Start > Datenbank*. Created via “Neuen Mandanten anlegen” or a BAK restore. ([Multi-mandant capability](https://guide.jtl-software.com/jtl-wawi/installation/allgemeines-zur-mandantenfaehigkeit/), [Database](https://guide.jtl-software.com/jtl-wawi/datenbank/))

**What JTL expects beyond `tMandant`/`tBenutzerFirma` (confidence: medium):**
- On restore, the official database management applies a **DB update to the client version** (version alignment), registers backup history, and maintains the mandant list. A plain `RESTORE + INSERT tMandant` skips the version-checking logic.
- **Marketplace/installation identity:** marketplace accounts are bound to *exactly one* mandant. A clone carries the **identical binding + internal GUIDs** as production → collision when both run in parallel. Credential invalidation does not cover the *identity GUIDs*.
- The Wawi client keeps server connections locally; the mandant selection at login comes from the instance's `tMandant` — a DB-side upsert is sufficient for visibility.

**Risks of the clone approach:** Worker collision (high); identical GUIDs (medium); `kMandant` assignment via `MAX+1` is not the official path (medium).

**Assessment:** community best practice is a **separate instance/VM without network access** ([forum](https://forum.jtl-software.de/threads/wie-macht-ihr-euch-euch-testumgebung.224704/)); the same-instance approach deliberately deviates from it → must be compensated by hard Worker neutralization.

## 2. JTL version updates & DB migration

**Update mechanics (confidence: high):** client update → on the first login per DB, an **update wizard** runs (schema update per DB); automatic backup beforehand; simulation option; choice of “current mandant only” or “all mandants”. ([Updating JTL-Wawi](https://guide.jtl-software.com/jtl-wawi/installation/jtl-wawi-aktualisieren/))

**“All mandants on the same version” (confidence: high):** every mandant DB is migrated individually; the client refuses to log in against an older DB. Consequence for clones:
- **Clone-after-update instead of update-the-clone:** update and stabilize production first, then clone freshly → clones are automatically on the same version.
- Avoid large version jumps (apply the last patch of the old line first).

**Foreign objects during the update (confidence: medium — forum/experience):**
- The only well-documented hard blocker: **collation** (`Latin1_General_CI_AS`); a conflict aborts the DB update ([forum](https://forum.jtl-software.de/threads/fehler-beim-datenbankupdate-auf-hoehere-version.229282/)). The admin DB plus our own objects must share the same collation.
- Own objects in **own schemas** survive updates (JTL only touches `dbo` — consensus from experience, not a hard commitment). **Risky:** triggers on JTL tables, own columns/indexes on `dbo.t*`, views/SPs over JTL `dbo` objects (silent breakage).
- The `CustomWorkflows` infrastructure is purely structural (discovery via `vCustomAction*` views + `tWorkflowObjects`/`tAllowedDatatypes`). Actions survive an update **as long as JTL does not change this infrastructure** — otherwise status `ERROR`. → **Post-update smoke test:** `SELECT * FROM CustomWorkflows.vCustomActionCheck WHERE Status='ERROR'`.

## 3. Worker / online-shop sync on test mandants

**Finding (confidence: high):** a clone that becomes active threatens: eBay/Amazon write-back sync (tracking, status), **invoice/status emails to real customers**, shop sync (overwrites live-shop stock levels/prices), payment services, WMS/POS, cloud/account binding. The Worker must be **stopped as a service** — “disabling it in the configuration is not enough” ([Worker guide](https://guide.jtl-software.com/jtl-wawi/jtl-worker/), [forum eBay sync](https://forum.jtl-software.de/threads/jtl-wawi-testumgebung-ebay-abgleich.115275/)).

**Already covered (`invalidate-credentials-for-testing.sql`, incl. commit e6d7b2b):** SMTP, eBay credentials **+ eBay account lock `nGesperrt=1`**, Amazon/OAuth credentials, **shop repoint to staging** (URL + license, user/password are retained), PayPal, shipping, SCX/Sync/BI tokens, voucher, fulfillment, bank details, license/login tokens, DATEV.

**Remaining gaps for the new reset (confidence: medium–high):**
1. **Amazon counterpart to the eBay lock** — survey finding: `pf_user.nGesperrt`/`nAktiv` (+ VCS locks `dVcsSperreUtc`/`dVcsLiteSperreUtc`); currently 0 rows in the main DB, to be re-checked in the mandant DBs.
2. **Drain the queues:** `tQueue` (~9,800), `tWorkflowQueue` (~5,300), `ebay_usermessagequeue` (~1,300), `tGlobalsQueue`, mail queues — the backlog fires the moment someone re-enters credentials for a test.
3. **Worker sync control:** `Worker.tTarget` (uTargetId, kMandant, nAbgleichstyp, kZiel) — check/neutralize per mandant.
4. **Identity/seller GUIDs:** remain identical to production; harmless as long as the Worker is off, but a manual marketplace sync inside the test mandant could disturb the production binding.
5. **JTL-Ameise / scheduled tasks / external cron jobs** against the DB (outside the DB, belongs in the reset runbook).

## 4. Own objects in eazybusiness

**Finding (confidence: medium, consensus):** own objects go into own schemas (in practice: `Robotico`, `RoboticoEKL`, `CustomWorkflows`). A **separate admin DB** is the most update-safe variant (survives Wawi updates untouched, is not overwritten by an eazybusiness restore); trade-off: cross-DB views break when JTL changes `dbo` structures → post-update smoke test; consistent collation + permissions in both DBs.

**Migration perspective** (complements `docs/SQL/JTL-CUSTOM-WORKFLOWS.md`): (a) no registry → migrations are plain idempotent `CREATE OR ALTER` — ideal for a migration runner; (b) validity hinges on JTL views/tables = our breaking point on updates; (c) `DisplayName`/param labels are extended properties, and the `_Set*` helpers are idempotent.

## 5. License / legal (as of 1.10.x/2.x)

**Finding (confidence: medium):**
- Additional DBs on the same instance: unproblematic both technically and in licensing terms (JTL licenses the Wawi, not SQL objects; the number of mandants is technically unlimited).
- For genuine staging environments JTL expects a **separate customer account** with (test) licenses; **cloning does not exempt you from the licensing obligation** ([test environment](https://guide.jtl-software.com/jtl-kundencenter/jtl-produkte-in-einer-testumgebung-nutzen/)). Misusing staging licenses for production → account suspension.
- **In practice:** test clones that never sync live (Worker off, sync off) are within tolerated bounds. What is license-risky is exactly the moment §3 prevents: a clone that communicates productively with marketplaces = de facto a second productive use of the same license.
- **Session update from the user (2026-07-09):** staging shop licenses are set up and working (“the license side works wonderfully”) — the shop repoint from commit e6d7b2b runs with valid staging connector keys.

## Consequences for our architecture

1. **Worker visibility is the core risk** — the reset must hard-set the per-account/per-mandant sync flags, not merely blank the credentials (eBay ✅ done, Amazon/`Worker.tTarget` open).
2. Credential invalidation ≠ sync neutralization — close the gaps from §3.
3. **Draining the queues** as a fixed reset step.
4. **Clone-after-update instead of update-the-clone.**
5. Pin down the **collation invariant** (`Latin1_General_CI_AS` for RoboticoOps + own objects).
6. Own objects in own schemas / an own admin DB; avoid triggers/indexes/columns on JTL `dbo`.
7. Migrations = idempotent `CREATE OR ALTER` against an own schema, re-appliable (every restore resets the eazybusiness objects).
8. **Post-update smoke test:** `CustomWorkflows.vCustomActionCheck WHERE Status='ERROR'` + recompilability of own objects/cross-DB views.
9. Signed SPs / admin DB in a separate database = update-safe; the preferred home for everything that does not strictly have to live inside eazybusiness.
10. **License guardrail:** test clones must never communicate productively with marketplaces — Worker/sync neutralization is also compliance.

## Only resolvable by hands-on testing on vm-sql-test1 (probe list)

- ~~Which table/columns store the per-account sync flags~~ → **answered by the survey**: `ebay_user.nGesperrt`, `pf_user.nGesperrt/nAktiv`, `tShop.nGesperrt`, `Worker.tTarget`. Open: the semantics of the `Worker.tTarget.nAbgleichstyp` values.
- **How the Worker discovers a clone freshly registered in `tMandant`** (immediately? on restart? does it read `tMandant` of the main DB or per DB?).
- **Where the installation/seller GUIDs live** and whether a clone with an identical GUID disturbs the production binding.
- **Whether the Wawi client accepts a mandant created purely via SQL without complaint** (login/update wizard).
- **Whether JTL touches anything in own schemas during a DB update** (a real update with a before/after object comparison).
- **Whether `kMandant` assignment via `MAX+1`** collides with JTL's expectations.
- **A complete list of queue tables** for the draining step (the survey delivered candidates + row counts).
