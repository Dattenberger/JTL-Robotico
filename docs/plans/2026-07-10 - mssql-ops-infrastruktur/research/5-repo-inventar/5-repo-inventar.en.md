---
name: repo-inventar-testsystem
description: Inventory of the as-is reset process, own objects in eazybusiness and existing documentation (research agent, 2026-07-09)
status: Research
---

# Inventory: Test-Mandant Reset & Own Objects (JTL-Robotico)

> Source: Opus research agent “repo-inventar”, session 2026-07-09.
> State BEFORE commit e6d7b2b (shop repoint + eBay lock) — the deviation in §1
> (`invalidate-credentials-for-testing.sql`) has been fixed by e6d7b2b, see the note.

## 1. `Projekte/Testsystem/` — the current reset process

A PowerShell orchestrator that runs SQLCMD scripts sequentially against the SQL Server. No global transaction wrapping across the whole run, but `-b` (abort on error) per script.

**`setup-test-environment.ps1`** (orchestrator)
- Parameters: `-EasyBusinessMandant` (mandatory, e.g. `tm4`), `-LoginName` (default `dbuser_dev_dana_for_development`), `-ServerInstance` (**hard-coded default `VM-SQL2` = the production server!**).
- Target DB naming: `eazybusiness_` + suffix (e.g. `eazybusiness_tm4`).
- Registry: reads `test-environment.config.json` (gitignored). No entry → safe abort.
- Sequence: `copy_test_db.sql` → `invalidate-credentials-for-testing.sql` → `clear-customer-fields.sql` → `grant-database-access.sql` → `register-mandant.sql` → `../../Berechtigungen/JTL-Rollen.sql` (with `-d $TargetDb`).
- Gotcha (documented): `ShopUrl`/`ShopLicense`/`MandantName` are passed via OS environment variables instead of `-v` (the SQLCMD `-v` parser trips over the `:` in the URL and over spaces/parentheses). `TargetDb`/`LoginName` go through `-v`.
- Auth: `-E` (Windows trusted connection) → presupposes a personal Windows login with server privileges on VM-SQL2.

**`copy_test_db.sql`** — clone via a COPY_ONLY backup + RESTORE WITH REPLACE. Hard-coded: backup path `E:\work\eazybusiness_to_test.bak`, target data folder `E:\MSSQL\Data`. Safety: aborts if TargetDb=`eazybusiness`. Sets `RECOVERY SIMPLE`+`MULTI_USER`. Assumed privileges: BACKUP/RESTORE, `xp_create_subdir`, write permission for the SQL service account on E:.

**`invalidate-credentials-for-testing.sql`** — a single `BEGIN TRAN`/TRY-CATCH bracket with ROLLBACK+THROW. Sets passwords/tokens to `''`, appends `_deactivated` to names. Affected (mostly `IF OBJECT_ID`-guarded): `dbo.tEMailEinstellung, ebay_user, tOauthConfig, tOauthToken, tShop, Robotico.tPaypalAccessToken/tPaypalSettings, tShipperAccount, SCX.tRefreshToken, Sync.tAuthCode, BI.tAbgleichToken, tVouchersToken, FulfillmentNetwork.tLogin, Shipping.tVersandplattformUserData, twebversand, tWebshopModule, tkontodaten, tinetzahlungsinfo, tLizenz, tBenutzerLogin, tDatevConfig`.
- **Note (drift, fixed in the meantime):** at the time of analysis, the PS/config documentation claimed that `tShop.cServerWeb`/`cAPIKey` were being repointed to the staging shop URL here — but the script only blanked them / set `_deactivated` and did NOT read `$(ShopUrl)`/`$(ShopLicense)`. **Commit e6d7b2b** implements the repoint (JS shop `nTyp=0` with an http URL → `cServerWeb=$(ShopUrl)`, `cAPIKey=$(ShopLicense)`, user/password are retained; `tWebshopModule` deliberately untouched — plugin licenses) and additionally locks all eBay accounts (`ebay_user.nGesperrt=1`).

**`clear-customer-fields.sql`** (~1009 lines, v2.0) — GDPR anonymization of 100+ tables in 11 priority blocks, pattern `Feldname_<PK>` / `mail_<PK>@test.local`. Gotcha: `dbo.tkunde` and `dbo.tAdresse` are trigger-protected → bypassed via `SET CONTEXT_INFO HASHBYTES('SHA1','Kunde.spKundeUpdate')` resp. `'dbo.spAdresseUpdate'`. Runs in independent `GO` batches WITHOUT an overall rollback (only tkunde/tAdresse have their own TRY/CATCH transactions). `tfirma`/`tlieferant` deliberately commented out (not anonymized).

**`grant-database-access.sql`** — SQLCMD vars `$(TargetDb)`/`$(LoginName)`; creates the DB user and makes it **db_owner** in the target DB. Idempotent, with a safety guard against `eazybusiness`.

**`grant-database-access-partial.sql`** (NOT part of the PS sequence) — hard-codes `eazybusiness_tm2` + Dana's login; granular `GRANT SELECT/UPDATE` on ~40 tables of the source DB + db_owner on tm2. Legacy tool.

**`revoke-database-access.sql`** (NOT part of the PS sequence) — hard-codes `eazybusiness` + Dana's login; cursors over `sys.database_permissions`, generates REVOKEs, removes roles, `DROP USER`. Manual cleanup of the source DB.

**`register-mandant.sql`** — registers the mandant in `dbo.tMandant` (kMandant = the existing one found via cDB, otherwise MAX+1), upserting into ALL existing mandant DBs + the target DB. Seeds `dbo.tBenutzerFirma` for the new kMandant from the default mandant (kMandant 1) in `eazybusiness`+the target DB. Idempotent, FK-safe. **Cross-DB:** references `eazybusiness.dbo.*` directly → presupposes source+target on one instance.

**`force-error.sql`** — RAISERROR sev 20, a test aid (commented out in the array).

**Config/ignore:** `test-environment.config.example.json` (version-controlled) = registry `environments.<tmN>`={Developer,ShopUrl,ShopLicense}; the real `test-environment.config.json` is gitignored and shared via Google Drive (real connector keys). Currently tm2/dana, tm3/sanda, tm4/lukas with `shop-staging-<dev>.ison-musical.ts.net`. `.gitignore` ignores only the config. `package.json` (root) carries the npm scripts `Deploy Test Environment:tm2-dana`/`tm3-sanda`.

## 2. `Berechtigungen/JTL-Rollen.sql` (role SSoT)

- Two user-defined DB roles: **`JTL_Reader`** (member of `db_datareader` + `GRANT EXECUTE ON SCHEMA::Robotico`/`::RoboticoEKL`), **`JTL_Writer`** (member of `db_datawriter`). Rationale documented (Msg 4617: no extra permissions may be granted to fixed roles).
- Idempotent, additive (revokes nothing), operates on the connected DB (no `USE` → hence `-d $TargetDb`).
- Members hard-coded: AD group `ZDBIKES\sql-jtl-users` (reader); SQL users `dbuser_eazybusiness_kiana` (reader+writer), `_sanda` (reader); services `_jtl_datawow`, `_powershell_read`, `_greyhound`, `_ekl_addin_readonly` (reader).
- Optional commented-out cleanup block (removing direct memberships). Invocation documented as: `sqlcmd -S VM-SQL2 -d eazybusiness …`.

## 3. Own objects in `eazybusiness` (the EB-local migration path)

All deployed objects live under **`WorkflowProcedures/`**. Schemas: **`Robotico`** (owned by us) + **`CustomWorkflows`** (the JTL custom-action layer). `Robotico` is created defensively via `IF NOT EXISTS … EXEC('CREATE SCHEMA Robotico')` (in CustomFieldAPI.sql, StringAndCSVUtilities.sql, PayPal/Add Procudures and Tables.sql).

Deployed objects:
- `Robotico.fnFindDuplicateOrders` (TVF), `fnHasOlderDuplicateOrder` (scalar), `spCheckDuplicateOrder` — `Duplikaterkennung_Bestellungen.sql`
- `Robotico.fnGetArticleCustomFieldValue`, `spEnsureArticleCustomField`, `spSetArticleCustomFieldValue` — `api/CustomFieldAPI.sql`
- `Robotico.fnEscapedCSV*` (4), `fnString*` (6) — `api/StringAndCSVUtilities.sql`
- `Robotico.tPaypalAccessToken`, `tPaypalSettings`, `tPaypalTrackingLog` (tables) — `PayPal/Add Procudures and Tables.sql`
- `CustomWorkflows.spPaypalTrackingLieferschein`, `spPaypalTrackingVersand` — `PayPal/Workflowaktion.sql`
- `CustomWorkflows.spArticleAppendPriceHistory`, `spArticleAppendLabelHistory`, `spArticleUpdateAllHistory` — `history/*.sql`
- `CustomWorkflows.spGebindeErstellen` — `Workflowaktion_Gebinde_Erstellen.sql`
- `CustomWorkflows.spZustandartikelLieferantSetzen` — `Workflowaktion_Zustandartikel_Lieferant_Setzen.sql`

Also in `WorkflowProcedures/`: `Diagnose_Workflow.sql` (ad hoc), `*_Tests.sql`, `Duplikaterkennung_Bestellungen_Teardown.sql` (drops all feature objects including v1 legacy leftovers, idempotent+transactional), assorted “Auftrag Preise auf Null” / “Seriennummern Standardlager auf WMS” scripts (partly tests/variants).

**Registration mechanics:** custom actions have NO registry table — discovery is purely structural via `CustomWorkflows.vCustomAction`. The UI name = the extended property `DisplayName` on the proc. The EB-local migration path must deploy the proc definition + the extended property as one unit; `DROP PROCEDURE` removes the property, but references in `dbo.tWorkflowAktion` are left orphaned.

**Query directories = ad hoc only, NO deployment:** `Auswertungen/`, `EigenÜbersichten/`, `Druckvorlagen/`, `Alt/`, `Workflows/` and the remaining `Projekte/` contain no CREATE deployments (the 2 hits in `Projekte/Kategoriebilder` + `Projekte/Speicherplatz` are `CREATE TABLE #temp`). `Workflows/*.{sql,liquid}` are JTL workflow conditions/extended properties (SELECT-only/DotLiquid) that go into the Wawi UI by copy-paste rather than being deployed via SQLCMD. `PayPal/` (root) is empty.

## 4. Existing documentation / research

- **`docs/SQL/JTL-CUSTOM-WORKFLOWS.md`** (commit c7886e3, separated into [DB]/[WEB]/[INFER]): where own objects are allowed to live → `CustomWorkflows.*` (registered actions, against `eazybusiness`, NOT `master`) + `Robotico.*`. “Custom Workflow Actions” is a separately licensable JTL module (since 1.6) and needs a restart + license refresh. No registry — 3 rules (schema + name, PK-first `int` param named like `cPkColumn`, allowed types + ≤7 params). Gating belongs in the condition/extended property, not in the action.
- **`docs/SQL/NAMING-CONVENTIONS.md`**: the (central) schema-ownership table: `dbo.*`=JTL, NEVER write (overwritten by updates); `Robotico.*`=ours, survives updates; `RoboticoEKL.*`=the Excel-EKL add-in (foreign, read-only); `CustomWorkflows.*`=JTL layer, registered actions only. Contains the idempotency/deployment pattern (`SET XACT_ABORT ON`+`BEGIN TRAN`+existence checks+`CREATE OR ALTER`+`XACT_STATE` commit).
- **Duplicate order detection (5bc87ff..8936278):** the feature lives in `Robotico.*` plus a (removed) CustomWorkflows wrapper. The teardown demonstrates a clean drop pattern including legacy leftovers plus a note on the orphaned `tWorkflowAktion` reference.

**“Survives JTL updates”:** only `Robotico.*` (+ `RoboticoEKL.*`) are update-safe; the `CustomWorkflows.*` procs are ours but sit inside the JTL layer; `dbo.*` is off limits.

## 5. Test/production server

- **`VM-SQL2`** is the ONLY server referenced (the PS default + the JTL-roles documentation) = production. **`VM-Test1` does NOT appear anywhere in the repo.** By default, the reset currently runs against the production server (cloning source→target on the same instance).
- **Note (session):** the test server does exist in reality as `vm-sql-test1.zdbikes.local` (SQL Server 2025 Developer) — see the survey report.
- Staging shops over Tailscale (`*.ison-musical.ts.net`), one per developer. No server/instance documentation, no README in the Testsystem folder.

## 6. `Alt/`

No predecessor versions of the Testsystem process — only old business-domain ad-hoc queries (article purchase prices, interval comparison, stock levels, demand-driven ordering). The only trace of evolution is in the duplicate-teardown v1/v2 comment and the `grant-partial`/`revoke` legacy tools.

## Implications for the new architecture

1. **Everything runs against VM-SQL2 (PROD).** The ServerInstance default, the backup/restore paths (`E:\work`, `E:\MSSQL\Data`) and `register-mandant.sql`'s cross-DB access to `eazybusiness.dbo.*` all presuppose source+target on one instance → separating PROD from test requires backup transport or a changed cloning strategy.
2. **Personal Windows admin privileges are implicitly assumed** (`-E`, BACKUP/RESTORE, granting db_owner, `xp_create_subdir`, `CREATE USER`) — precisely what module signing is meant to replace.
3. **No audit, no migration journal** — only `PRINT`. The planned audit/journal DB is a pure greenfield build with no predecessor.
4. **Hard-coded assumptions are scattered everywhere:** the paths `E:\work`/`E:\MSSQL\Data`, the login `dbuser_dev_dana_for_development`, the server `VM-SQL2`, the prefix `eazybusiness_`, the reference mandant `kMandant=1`, the AD group `ZDBIKES\sql-jtl-users`, the service-account names in JTL-Rollen.sql → these belong in a central config/registry.
5. **Inconsistent idempotency/transactionality:** register-mandant/grant/JTL-Rollen/teardown are clean; `clear-customer-fields` runs in independent GO batches without an overall rollback (a partial abort = a half-anonymized DB).
6. **Two migration paths confirmed in practice:** instance-global = `JTL-Rollen.sql` + `grant/revoke-database-access` (server principals/roles); EB-local = the `Robotico.*`/`CustomWorkflows.*` objects under `WorkflowProcedures/`.
7. **Custom-action registration without a registry table** → the EB path must deploy the proc definition + the `DisplayName` extended property as one unit; `dbo.tWorkflowAktion` references are orphaned on drop.
8. **Only `Robotico.*` survives JTL updates**; `CustomWorkflows.*` depends on the module license (restart + refresh). The journal must know the schema ownership per object in order to trigger a re-deploy after updates.
9. **Secrets are file-based rather than DB-based** (gitignored config via Google Drive). An ops DB could host the registry — mind the secret policy.
10. **Documentation drift around the staging-shop repoint** — fixed by commit e6d7b2b (see §1).

**Key paths:** `Projekte/Testsystem/{setup-test-environment.ps1, copy_test_db.sql, invalidate-credentials-for-testing.sql, clear-customer-fields.sql, grant-database-access.sql, grant-database-access-partial.sql, revoke-database-access.sql, register-mandant.sql, force-error.sql, test-environment.config.example.json, .gitignore}`, `Berechtigungen/JTL-Rollen.sql`, `WorkflowProcedures/**`, `docs/SQL/{JTL-CUSTOM-WORKFLOWS.md, NAMING-CONVENTIONS.md}`.
