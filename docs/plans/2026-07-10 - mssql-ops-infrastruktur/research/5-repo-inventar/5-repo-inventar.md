---
name: repo-inventar-testsystem
description: Bestandsaufnahme des Ist-Reset-Prozesses, eigener Objekte in eazybusiness und vorhandener Doku (Research-Agent, 2026-07-09)
status: Research
---

# Bestandsaufnahme: Testmandanten-Reset & eigene Objekte (JTL-Robotico)

> Quelle: Opus-Research-Agent „repo-inventar", Session 2026-07-09.
> Stand VOR Commit e6d7b2b (Shop-Repoint + eBay-Sperre) — Abweichung in §1
> (`invalidate-credentials-for-testing.sql`) ist durch e6d7b2b behoben, siehe Anmerkung.

## 1. `Projekte/Testsystem/` — der aktuelle Reset-Prozess

PowerShell-Orchestrator, der sequenziell SQLCMD-Skripte gegen den SQL-Server fährt. Kein globales Transaktions-Wrapping über den Gesamtlauf, aber `-b` (Abbruch bei Fehler) pro Skript.

**`setup-test-environment.ps1`** (Orchestrator)
- Parameter: `-EasyBusinessMandant` (Pflicht, z. B. `tm4`), `-LoginName` (Default `dbuser_dev_dana_for_development`), `-ServerInstance` (**Default hart `VM-SQL2` = Produktivserver!**).
- Ziel-DB-Schema: `eazybusiness_` + Suffix (z. B. `eazybusiness_tm4`).
- Registry: liest `test-environment.config.json` (gitignored). Kein Eintrag → sicherer Abbruch.
- Ablauf: `copy_test_db.sql` → `invalidate-credentials-for-testing.sql` → `clear-customer-fields.sql` → `grant-database-access.sql` → `register-mandant.sql` → `../../Berechtigungen/JTL-Rollen.sql` (mit `-d $TargetDb`).
- Gotcha (dokumentiert): `ShopUrl`/`ShopLicense`/`MandantName` gehen über OS-Env-Vars statt `-v` (SQLCMD-`-v`-Parser scheitert an `:` in URL bzw. Leerzeichen/Klammern). `TargetDb`/`LoginName` über `-v`.
- Auth: `-E` (Windows Trusted Connection) → setzt persönlichen Windows-Login mit Serverrechten auf VM-SQL2 voraus.

**`copy_test_db.sql`** — Klon via COPY_ONLY-Backup + RESTORE WITH REPLACE. Hart codiert: Backup-Pfad `E:\work\eazybusiness_to_test.bak`, Ziel-Datenordner `E:\MSSQL\Data`. Safety: Abbruch wenn TargetDb=`eazybusiness`. Setzt `RECOVERY SIMPLE`+`MULTI_USER`. Rechte-Annahme: BACKUP/RESTORE, `xp_create_subdir`, Schreibrecht des SQL-Dienstkontos auf E:.

**`invalidate-credentials-for-testing.sql`** — eine `BEGIN TRAN`/TRY-CATCH-Klammer mit ROLLBACK+THROW. Setzt Passwörter/Tokens auf `''`, hängt `_deactivated` an Namen. Betroffen (meist `IF OBJECT_ID`-guarded): `dbo.tEMailEinstellung, ebay_user, tOauthConfig, tOauthToken, tShop, Robotico.tPaypalAccessToken/tPaypalSettings, tShipperAccount, SCX.tRefreshToken, Sync.tAuthCode, BI.tAbgleichToken, tVouchersToken, FulfillmentNetwork.tLogin, Shipping.tVersandplattformUserData, twebversand, tWebshopModule, tkontodaten, tinetzahlungsinfo, tLizenz, tBenutzerLogin, tDatevConfig`.
- **Anmerkung (Drift, inzwischen behoben):** Zum Analysezeitpunkt behauptete die PS-/Config-Doku, hier werde `tShop.cServerWeb`/`cAPIKey` auf die Staging-Shop-URL umgebogen — das Skript setzte sie aber nur leer/`_deactivated` und las `$(ShopUrl)`/`$(ShopLicense)` NICHT ein. **Commit e6d7b2b** implementiert den Repoint (JS-Shop `nTyp=0` mit http-URL → `cServerWeb=$(ShopUrl)`, `cAPIKey=$(ShopLicense)`, Benutzer/Passwort bleiben erhalten; `tWebshopModule` bewusst unangetastet — Plugin-Lizenzen) und sperrt zusätzlich alle eBay-Konten (`ebay_user.nGesperrt=1`).

**`clear-customer-fields.sql`** (~1009 Z., v2.0) — DSGVO-Anonymisierung von 100+ Tabellen in 11 Prioritätsblöcken, Muster `Feldname_<PK>` / `mail_<PK>@test.local`. Gotcha: `dbo.tkunde` und `dbo.tAdresse` sind triggergeschützt → Umgehung via `SET CONTEXT_INFO HASHBYTES('SHA1','Kunde.spKundeUpdate')` bzw. `'dbo.spAdresseUpdate'`. Läuft in unabhängigen `GO`-Batches OHNE Gesamt-Rollback (nur tkunde/tAdresse haben eigene TRY/CATCH-Trans). `tfirma`/`tlieferant` bewusst auskommentiert (nicht anonymisiert).

**`grant-database-access.sql`** — SQLCMD-Vars `$(TargetDb)`/`$(LoginName)`; legt DB-User an, macht ihn **db_owner** in Ziel-DB. Idempotent, Safety gegen `eazybusiness`.

**`grant-database-access-partial.sql`** (NICHT im PS-Ablauf) — hart codiert `eazybusiness_tm2` + Dana-Login; granulare `GRANT SELECT/UPDATE` auf ~40 Tabellen der Quell-DB + db_owner auf tm2. Altwerkzeug.

**`revoke-database-access.sql`** (NICHT im PS-Ablauf) — hart codiert `eazybusiness` + Dana-Login; cursort über `sys.database_permissions`, generiert REVOKEs, entfernt Rollen, `DROP USER`. Manuelles Cleanup der Quell-DB.

**`register-mandant.sql`** — trägt Mandant in `dbo.tMandant` (kMandant=vorhanden per cDB oder MAX+1) ein, Upsert in ALLE existierenden Mandanten-DBs + Ziel-DB. Seedet `dbo.tBenutzerFirma` für neuen kMandant aus Standard-Mandant (kMandant 1) in `eazybusiness`+Ziel-DB. Idempotent, FK-sicher. **Cross-DB:** referenziert `eazybusiness.dbo.*` direkt → Quelle+Ziel auf einer Instanz vorausgesetzt.

**`force-error.sql`** — RAISERROR sev 20, Testhilfe (im Array auskommentiert).

**Config/Ignore:** `test-environment.config.example.json` (versioniert) = Registry `environments.<tmN>`={Developer,ShopUrl,ShopLicense}; echte `test-environment.config.json` gitignored, via Google Drive geteilt (echte Connector-Keys). Aktuell tm2/dana, tm3/sanda, tm4/lukas mit `shop-staging-<dev>.ison-musical.ts.net`. `.gitignore` ignoriert nur die Config. `package.json` (Root) hat npm-Scripts `Deploy Test Environment:tm2-dana`/`tm3-sanda`.

## 2. `Berechtigungen/JTL-Rollen.sql` (Rollen-SSoT)

- Zwei benutzerdef. DB-Rollen: **`JTL_Reader`** (Mitglied `db_datareader` + `GRANT EXECUTE ON SCHEMA::Robotico`/`::RoboticoEKL`), **`JTL_Writer`** (Mitglied `db_datawriter`). Begründung dokumentiert (Msg 4617: an feste Rollen keine Extra-Rechte).
- Idempotent, additiv (entzieht nichts), operiert auf connected DB (kein `USE` → daher `-d $TargetDb`).
- Mitglieder hart codiert: AD-Gruppe `ZDBIKES\sql-jtl-users` (Reader); SQL-User `dbuser_eazybusiness_kiana` (Reader+Writer), `_sanda` (Reader); Services `_jtl_datawow`, `_powershell_read`, `_greyhound`, `_ekl_addin_readonly` (Reader).
- Optionaler auskommentierter Cleanup-Block (Direktmitgliedschaften entfernen). Aufruf-Doku: `sqlcmd -S VM-SQL2 -d eazybusiness …`.

## 3. Eigene Objekte in `eazybusiness` (EB-lokaler Migrationspfad)

Alle deployten Objekte liegen unter **`WorkflowProcedures/`**. Schemas: **`Robotico`** (unser Eigentum) + **`CustomWorkflows`** (JTL-Custom-Action-Layer). `Robotico` wird defensiv per `IF NOT EXISTS … EXEC('CREATE SCHEMA Robotico')` angelegt (in CustomFieldAPI.sql, StringAndCSVUtilities.sql, PayPal/Add Procudures and Tables.sql).

Deployte Objekte:
- `Robotico.fnFindDuplicateOrders` (TVF), `fnHasOlderDuplicateOrder` (scalar), `spCheckDuplicateOrder` — `Duplikaterkennung_Bestellungen.sql`
- `Robotico.fnGetArticleCustomFieldValue`, `spEnsureArticleCustomField`, `spSetArticleCustomFieldValue` — `api/CustomFieldAPI.sql`
- `Robotico.fnEscapedCSV*` (4), `fnString*` (6) — `api/StringAndCSVUtilities.sql`
- `Robotico.tPaypalAccessToken`, `tPaypalSettings`, `tPaypalTrackingLog` (Tables) — `PayPal/Add Procudures and Tables.sql`
- `CustomWorkflows.spPaypalTrackingLieferschein`, `spPaypalTrackingVersand` — `PayPal/Workflowaktion.sql`
- `CustomWorkflows.spArticleAppendPriceHistory`, `spArticleAppendLabelHistory`, `spArticleUpdateAllHistory` — `history/*.sql`
- `CustomWorkflows.spGebindeErstellen` — `Workflowaktion_Gebinde_Erstellen.sql`
- `CustomWorkflows.spZustandartikelLieferantSetzen` — `Workflowaktion_Zustandartikel_Lieferant_Setzen.sql`

Weiteres in `WorkflowProcedures/`: `Diagnose_Workflow.sql` (Ad-hoc), `*_Tests.sql`, `Duplikaterkennung_Bestellungen_Teardown.sql` (droppt alle Feature-Objekte inkl. v1-Altlasten, idempotent+transaktional), diverse "Auftrag Preise auf Null"-/"Seriennummern Standardlager auf WMS"-Skripte (teils Tests/Varianten).

**Registrierungs-Mechanik:** Custom Actions haben KEINE Registry-Tabelle — Discovery rein strukturell über `CustomWorkflows.vCustomAction`. UI-Name = Extended Property `DisplayName` auf der Proc. EB-lokaler Migrationspfad muss Proc-Def + Extended-Property als Einheit deployen; `DROP PROCEDURE` entfernt die Property, aber Referenzen in `dbo.tWorkflowAktion` verwaisen.

**Query-Verzeichnisse = nur Ad-hoc, KEIN Deployment:** `Auswertungen/`, `EigenÜbersichten/`, `Druckvorlagen/`, `Alt/`, `Workflows/`, restliche `Projekte/` enthalten keine CREATE-Deployments (die 2 Treffer in `Projekte/Kategoriebilder` + `Projekte/Speicherplatz` sind `CREATE TABLE #temp`). `Workflows/*.{sql,liquid}` sind JTL-Workflow-Bedingungen/erweiterte Eigenschaften (SELECT-only/DotLiquid), die per Copy-Paste in die WaWi-UI gehen, nicht per SQLCMD deployt werden. `PayPal/` (Root) ist leer.

## 4. Vorhandene Doku / Recherche

- **`docs/SQL/JTL-CUSTOM-WORKFLOWS.md`** (Commit c7886e3, [DB]/[WEB]/[INFER]-getrennt): Wo dürfen eigene Objekte leben → `CustomWorkflows.*` (registrierte Actions, gegen `eazybusiness` NICHT `master`) + `Robotico.*`. "Custom Workflow Actions" ist separat zu buchendes JTL-Modul (seit 1.6), braucht Neustart+Lizenz-Refresh. Keine Registry — 3 Regeln (Schema+Name, PK-first `int`-Param benannt wie `cPkColumn`, erlaubte Typen + ≤7 Params). Gating gehört in Bedingung/erweiterte Eigenschaft, nicht Action.
- **`docs/SQL/NAMING-CONVENTIONS.md`**: Schema-Eigentümer-Tabelle (zentral): `dbo.*`=JTL, NIE schreiben (Update-überschrieben); `Robotico.*`=unser, überlebt Updates; `RoboticoEKL.*`=Excel-EKL-AddIn (fremd, read-only); `CustomWorkflows.*`=JTL-Layer, nur registrierte Actions. Enthält Idempotenz-/Deployment-Muster (`SET XACT_ABORT ON`+`BEGIN TRAN`+Existenzprüfungen+`CREATE OR ALTER`+`XACT_STATE`-Commit).
- **Duplicate-Order-Detection (5bc87ff..8936278):** Feature in `Robotico.*` + (entfernter) CustomWorkflows-Wrapper. Teardown zeigt sauberes Drop-Muster inkl. Altlasten + Hinweis auf verwaiste `tWorkflowAktion`-Referenz.

**„Überlebt JTL-Updates":** nur `Robotico.*` (+ `RoboticoEKL.*`) update-sicher; `CustomWorkflows.*`-Procs sind unsere, liegen aber im JTL-Layer; `dbo.*` tabu.

## 5. Test-/Produktivserver

- **`VM-SQL2`** ist der EINZIGE referenzierte Server (PS-Default + JTL-Rollen-Doku) = Produktiv. **`VM-Test1` kommt im ganzen Repo NICHT vor.** Der Reset läuft aktuell standardmäßig gegen den Produktivserver (Klon Quelle→Ziel auf derselben Instanz).
- **Anmerkung (Session):** Der Testserver existiert real als `vm-sql-test1.zdbikes.local` (SQL Server 2025 Developer) — siehe Survey-Bericht.
- Staging-Shops über Tailscale (`*.ison-musical.ts.net`), pro Entwickler. Keine Server-/Instanz-Doku, kein README im Testsystem-Ordner.

## 6. `Alt/`

Keine Vorgängerversionen des Testsystem-Prozesses — nur alte fachliche Ad-hoc-Queries (Artikel-EK, Intervall-Vergleich, Lagerbestand, Bedarfsbestellung). Evolutions-Spur nur im Duplikat-Teardown-v1/v2-Kommentar und den `grant-partial`/`revoke`-Altwerkzeugen.

## Implikationen für die neue Architektur

1. **Alles gegen VM-SQL2 (PROD).** ServerInstance-Default, Backup-/Restore-Pfade (`E:\work`, `E:\MSSQL\Data`) und `register-mandant.sql`s Cross-DB-Zugriff auf `eazybusiness.dbo.*` setzen Quelle+Ziel auf einer Instanz voraus → PROD/Test-Trennung braucht Backup-Transport oder geänderte Klon-Strategie.
2. **Persönliche Windows-Admin-Rechte implizit vorausgesetzt** (`-E`, BACKUP/RESTORE, db_owner-Vergabe, `xp_create_subdir`, `CREATE USER`) — genau das soll Module Signing ablösen.
3. **Kein Audit, kein Migrations-Journal** — nur `PRINT`. Die geplante Audit-/Journal-DB ist reiner Neubau ohne Vorgänger.
4. **Hart codierte Annahmen streuen:** Pfade `E:\work`/`E:\MSSQL\Data`, Login `dbuser_dev_dana_for_development`, Server `VM-SQL2`, Präfix `eazybusiness_`, Referenz-Mandant `kMandant=1`, AD-Gruppe `ZDBIKES\sql-jtl-users`, Service-Account-Namen in JTL-Rollen.sql → gehören in zentrale Config/Registry.
5. **Uneinheitliche Idempotenz/Transaktionalität:** register-mandant/grant/JTL-Rollen/Teardown sauber; `clear-customer-fields` läuft in unabhängigen GO-Batches ohne Gesamt-Rollback (Teilabbruch = halb-anonymisierte DB).
6. **Zwei Migrationspfade real bestätigt:** instanz-global = `JTL-Rollen.sql` + `grant/revoke-database-access` (Server-Principals/Rollen); EB-lokal = `Robotico.*`/`CustomWorkflows.*`-Objekte unter `WorkflowProcedures/`.
7. **Custom-Action-Registrierung ohne Registry-Tabelle** → EB-Pfad muss Proc-Def + `DisplayName`-Extended-Property als Einheit deployen; `dbo.tWorkflowAktion`-Referenzen verwaisen beim Drop.
8. **Nur `Robotico.*` überlebt JTL-Updates**; `CustomWorkflows.*` ist Modul-lizenzabhängig (Neustart+Refresh). Journal muss Schema-Eigentum pro Objekt kennen, um Re-Deploy nach Updates zu triggern.
9. **Secrets datei- statt DB-basiert** (gitignored Config via Google Drive). Ops-DB könnte die Registry aufnehmen — Secret-Policy beachten.
10. **Doku-Drift Staging-Shop-Umbiegung** — behoben durch Commit e6d7b2b (siehe §1).

**Zentrale Pfade:** `Projekte/Testsystem/{setup-test-environment.ps1, copy_test_db.sql, invalidate-credentials-for-testing.sql, clear-customer-fields.sql, grant-database-access.sql, grant-database-access-partial.sql, revoke-database-access.sql, register-mandant.sql, force-error.sql, test-environment.config.example.json, .gitignore}`, `Berechtigungen/JTL-Rollen.sql`, `WorkflowProcedures/**`, `docs/SQL/{JTL-CUSTOM-WORKFLOWS.md, NAMING-CONVENTIONS.md}`.
