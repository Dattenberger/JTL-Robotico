# QG3 — Port-Audit: Legacy `Projekte/Testsystem/` → Reset-Pipeline

**Art:** Quelltext-seitiger 1:1-Abgleich (Legacy-SQL/PS1 vs. `db-migrations/global/**`).
**Datum:** 2026-07-15
**Scope:** Read-only, keine SQL-Server-Verbindung. Komplementär zu
`reports/qg2/deep-verification-report.md` (der DB-seitig Klon vs. Quelle verglich).

Legende Klassifikation:
- **[Mehrwert]** — bewusste Verbesserung im Projektrahmen (Guards, Idempotenz, Multi-File, Audit).
- **[Neutral]** — äquivalent umformuliert; Endzustand identisch.
- **[Regression/Lücke]** — Inhalt fehlt oder Verhalten schlechter; mit Szenario.

---

## 1. Mapping-Matrix (Datei/Sektion → Ziel)

| Legacy | Ziel | Status |
|---|---|---|
| `copy_test_db.sql` | `reset.spInternal_CloneDatabase` | portiert, erweitert |
| `invalidate-credentials-for-testing.sql` (Blöcke SMTP/eBay/OAuth/Shop/PayPal/Shipping/SCX/Sync/BI/Vouchers/FN/Versandplattform/twebversand/Lizenz/DATEV) | `reset.spInternal_InvalidateCredentials` | portiert |
| `invalidate-…` Banking-Blöcke (tkontodaten/tinetzahlungsinfo) | **verschoben** nach `spInternal_AnonymizeCustomerData` P8 | portiert (anderswo) |
| `clear-customer-fields.sql` (Prio 1–11) | `reset.spInternal_AnonymizeCustomerData` (P1–P11) | portiert |
| `grant-database-access.sql` | `reset.spInternal_GrantAccess` | portiert |
| `register-mandant.sql` | `reset.spInternal_RegisterMandant` | portiert, erweitert |
| `../../Berechtigungen/JTL-Rollen.sql` | `reset.spInternal_ApplyJtlRoles` | portiert (1 Grant weggelassen) |
| `setup-test-environment.ps1` (Orchestrierung, Reihenfolge) | `reset.spProcessNextResetRequest` + `ops.tResetStep` (0021) | portiert, datengetrieben |
| `test-environment.config.example.json` (ShopUrl/License/Developer/Login) | `ops.tMandant` + `ops.tConfig` (Seed 0020) | portiert |
| — (neu, D9) | `reset.spInternal_NeutralizeWorker` | Neu |
| — (neu, Post-Restore-Härtung) | `reset.spInternal_PostRestoreSecurity` | Neu |
| `revoke-database-access.sql` | — | **bewusster Nicht-Port** (Standalone-Helper) |
| `grant-database-access-partial.sql` | — | **bewusster Nicht-Port** (granularer PROD-Read) |
| `force-error.sql` | — | Test-Helper, kein Port nötig |

**Reihenfolge:** Legacy (copy → invalidate → clear → grant → register → JTL-Rollen) bleibt in der
neuen Pipeline erhalten (Steps 10→30→50→60→70→80); die zwei neuen Steps (20 PostRestoreSecurity,
40 NeutralizeWorker) sind additiv eingeschoben. **[Neutral]** — relative Ordnung der portierten
Schritte unverändert.

---

## 2. Abweichungsliste (nummeriert)

### D-01 · `copy_test_db.sql` → `CloneDatabase` · MOVE für ALLE Dateien statt genau 1 Daten-/1 Log-Datei · **[Mehrwert]**
- Legacy `copy_test_db.sql:73–91`: ermittelt via `SELECT @…=…` **nur je eine** ROWS- und LOG-Datei;
  eine zweite Datendatei/Filegroup würde stillschweigend aus der MOVE-Liste fallen.
- Neu `CloneDatabase.sql:55–64`: baut je Quelldatei eine `MOVE`-Klausel aus `sys.master_files`.
- Zusätzlich: Physischer Zielname `…\<Klon>_<logischerName>.mdf/.ldf` (Legacy: `…\<Klon>.mdf/.ldf`).
  Auf frischem Klon irrelevant (REPLACE), verhindert aber Kollision bei Mehr-Datei-Layout. Kein Regressionsrisiko.

### D-02 · `copy_test_db.sql` → `CloneDatabase` · stärkere Safety-Guards · **[Mehrwert]**
- Legacy: nur `IF @TargetDb = 'eazybusiness'` (Zeile 28) + Quelle existiert.
- Neu: `@TargetDb NOT LIKE 'eazybusiness[_]%'` (51010), Config-Vollständigkeit (51011), Quelle existiert
  (51012), ROWS+LOG vorhanden (51013), **source≠target** (51014). Härter, kein weggelassener Fall.

### D-03 · Pfade hart-codiert → `ops.tConfig` · **[Neutral]**
- `BackupFile`=`E:\work\eazybusiness_to_test.bak`, `TargetDataDir`=`E:\MSSQL\Data`, `SourceDb`=`eazybusiness`
  sind in Seed `0020` **wertgleich** zu `copy_test_db.sql:15–22`. Locals `nvarchar(1000)` = `cValue`-Länge,
  keine Truncation.

### D-04 · Banking-Anonymisierung nur noch EINMAL (in Anonymize P8) · **[Neutral]**
- Legacy führte tkontodaten/tinetzahlungsinfo **doppelt** aus: `invalidate-…:372–468` (leere Strings,
  Bank_ID_N-Mapping via ROW_NUMBER) **und** `clear-customer:677–723` (Platzhalter `BLZ_<id>` etc.).
- Neu: nur `AnonymizeCustomerData.sql:424–450`. Endzustand: alle realen Bankdaten ersetzt (Platzhalter
  statt Leerstring bei BLZ/KontoNr — Feldinhalt egal, PII entfernt). `cGueltigkeit`/`cCVV` → NULL (wie Legacy clear).
  Keine PII-Lücke.

### D-05 · `InvalidateCredentials` · `WHERE`-Filter der UPDATEs entfallen · **[Neutral]**
- Legacy filterte jeden UPDATE per `WHERE (feld IS NOT NULL AND LEN>0) OR …`; neu laufen die UPDATEs
  ohne WHERE über alle Zeilen. Die `CASE …_deactivated`-Idempotenzguards bleiben, daher identischer
  Endzustand (nur potenziell mehr berührte Zeilen). Verifikations-`SELECT` und Per-Statement-`PRINT`
  bewusst entfernt (D4-Deviation im Header dokumentiert).

### D-06 · `InvalidateCredentials` · Shop-Repoint-Warnung bei 0 Treffern · **[Mehrwert]**
- Neu `InvalidateCredentials.sql:73,161–163`: `@@ROWCOUNT` des Shop-Repoints wird erfasst; 0 Treffer →
  `WARN shop-repoint …` in `cStepLog` (PAR-4). Legacy meldete das nur im Verifikations-SELECT (verworfen).

### D-07 · Shop-Parameter via `ops.tMandant`-Parameter statt SQLCMD-`$( )` · **[Mehrwert]**
- Legacy: `$(ShopUrl)`/`$(ShopLicense)` als Literal in den SQL-Text substituiert.
- Neu: aus `ops.tMandant` gelesen, als `sp_executesql`-Parameter (`@ShopUrl`/`@ShopLicense`) übergeben —
  keine SQL-Injection-Fläche (D6). `@…nvarchar(max)` ≥ Spalte `nvarchar(500)`, keine Truncation.

### D-08 · `AnonymizeCustomerData` · CONTEXT_INFO-Handling ohne Transaktion · **[Neutral]**
- Legacy setzte tkunde (`clear-customer:43–77`) und tAdresse (`124–164`) je in **eigener** `BEGIN TRAN`
  mit Rollback-Reset des CONTEXT_INFO.
- Neu (`AnonymizeCustomerData.sql:33–166`): ein Batch, `BEGIN TRY … BEGIN CATCH SET CONTEXT_INFO 0x0; THROW`.
  Trigger-Bypass wird nur um tkunde/tAdresse gesetzt und davor/danach auf `0x0` gestellt (tinetkunde und
  Folge-UPDATEs laufen ohne Bypass — wie Legacy). CONTEXT_INFO-Leak bei Fehler ausgeschlossen. Kein
  Wrapping-TRAN (dokumentiert): halb-anonymisierter Klon wird vom Orchestrator als `failed` quarantänt.
  Gleichwertige Garantie.

### D-09 · `AnonymizeCustomerData` · `tKunde_suche` DELETE statt TRUNCATE · **[Mehrwert]**
- Legacy `clear-customer:85` TRUNCATE; neu `:48` DELETE (Vendor-Tabellen-Regel, FK-sicher). Endzustand gleich.

### D-10 · Auskommentierte/geskippte Legacy-Blöcke korrekt NICHT portiert · **[Neutral]**
- `tfirma` (1.8) und `tlieferant` (1.9) sind im Legacy auskommentiert (Lukas 21.11.2025, „don't anonymize"),
  `Kunde.tUmsatzSteuerPruefung` (10.2) und `tBemerkungen` (9.1) als „structure unknown" geskippt.
  Alle vier fehlen im neuen SP — **korrekt** (bewusst nicht anonymisiert). Kein Befund.

### D-11 · `ApplyJtlRoles` · `GRANT EXECUTE ON SCHEMA::RoboticoEKL` weggelassen · **[Neutral]** (mit Caveat)
- Legacy `JTL-Rollen.sql:61–62` grantet EXECUTE auf **Robotico UND RoboticoEKL** an JTL_Reader.
- Neu `ApplyJtlRoles.sql:52–53`: **nur Robotico**; RoboticoEKL bewusst weggelassen (D10-Schema-Grenze,
  Lint-Verbot). Begründung: RESTORE trägt vorhandene Prod-Grants mit; der EKL-Runner grantet sein Schema selbst.
- **Caveat-Szenario:** Existiert `RoboticoEKL` auf dem Klon, hatte aber in PROD **noch keinen** JTL_Reader-Grant,
  bleibt der Grant auf dem Klon aus → JTL_Reader kann RoboticoEKL-SPs nicht ausführen. Im Normal-Klon-von-PROD-Fluss
  ist der Grant bereits vorhanden; Impact gering. Beobachtungspunkt, keine harte Regression.
- Mitgliederliste (8 Einträge) und db_datareader/-writer-Vererbung **zeichengenau identisch** zur Legacy-Quelle.

### D-12 · `GrantAccess`/`RegisterMandant` · fehlender Login/DB → WARN statt RAISERROR · **[Mehrwert]**
- Legacy `grant-database-access.sql:28–32` RAISERROR bei fehlendem Login (harter Abbruch).
- Neu `GrantAccess.sql:31–37`: `WARN access-skipped …` in `cStepLog`, Reset läuft weiter (Klon ist gültig,
  Grant nachträglich möglich). `sp_addrolemember` → `ALTER ROLE ADD MEMBER`. `RegisterMandant` fügt WARN-Zählung
  + THROW-nur-bei-Ziel-DB hinzu (Blast-Radius-Doku CQG-5). Verhalten bewusst robuster.

### D-13 · Seed `cLoginName = dbuser_dev_dana_for_development` · **[Neutral/Mehrwert]**
- `0020` seedet für tm2/tm3/tm4 den real existierenden Shared-Dev-Login (Legacy-`ps1`-Default), damit der
  Default-Reset out-of-the-box db_owner vergibt (PAR-1). Login am 2026-07-13 gegen PROD verifiziert (Kommentar
  im Seed). Auf `vm-sql-test1` existiert er nicht → dort muss `@LoginName` überschrieben werden (dokumentiert).

### ⚠️ D-14 · `AnonymizeCustomerData` P9 · pf_user-Guard über 7 Spalten + falscher Kommentar · **[Regression/Lücke]**
- Legacy `clear-customer:792–808`: guardet **nur** `IF OBJECT_ID('dbo.pf_user') IS NOT NULL`, dann UPDATE mit
  `cAuthToken=NULL, cAmazonAuthToken=NULL, …`. Existiert pf_user → Tokens werden geleert (oder Batch schlägt
  laut fehl, falls eine Spalte fehlt).
- Neu `AnonymizeCustomerData.sql:483–498`: guardet OBJECT_ID **UND** `COL_LENGTH` von **7** Spalten
  (kUser, cName, cAuthToken, cAmazonAuthToken, cFBAVersandmailKopie, cFBAKommentar, cAnmerkung). Fehlt **eine
  einzige** dieser Spalten, wird der **gesamte** pf_user-UPDATE übersprungen — inklusive
  `cAuthToken`/`cAmazonAuthToken`.
- **Verschärfend:** Der Code-Kommentar Zeile 482 behauptet: „(Token columns are additionally cleared
  server-side elsewhere.)". Das ist **faktisch falsch** — Repo-weite Suche zeigt: nichts sonst leert
  `pf_user.cAuthToken`/`cAmazonAuthToken`. `NeutralizeWorker` setzt nur `nGesperrt=1`/`nAktiv=0` (kein
  Token-Clear), `InvalidateCredentials` fasst pf_user gar nicht an.
- **Szenario:** Auf einem Klon, dessen pf_user z. B. `cFBAKommentar` nicht besitzt (Schema-Drift zwischen
  JTL-Versionen), aber gültige Amazon-Auth-Tokens enthält, bleiben `cAuthToken`/`cAmazonAuthToken`
  **unmaskiert** in der Test-DB stehen — echte Amazon-Zugangsdaten im Testmandanten. Legacy hätte in demselben
  Fall entweder die Tokens geleert oder den Reset laut abbrechen lassen.
- **Empfehlung:** Token-Clear vom Rest entkoppeln — `cAuthToken`/`cAmazonAuthToken` je Spalte einzeln guarden
  (`IF COL_LENGTH(...) IS NOT NULL UPDATE … SET cAuthToken=NULL`), statt alle 7 Spalten als eine
  Alles-oder-nichts-Bedingung. Alternativ das sicherheitskritische Token-Clearing in `NeutralizeWorker` (das
  ohnehin pf_user anfasst) mit Einzelspalten-Guard aufnehmen. In jedem Fall den irreführenden Kommentar Zeile 482
  korrigieren.

### D-15 · Feld-für-Feld-Abgleich der Anonymisierungs-UPDATEs · **[Neutral]**
- Spaltenlisten je Tabelle zeichengenau abgeglichen (P1 tkunde/tinetkunde/tAdresse/trechnungsadresse/tBenutzer/
  tansprechpartner; P2 tAuftragAdresse/tRechnungAdresse/tLieferadresse/tRechnungadresse/tinetbestellung/
  tAddress; P3 ebay_checkout; P4 tSFPVersand; P5 Logs+tNotiz; P6 Ticket; P7 Retoure; P8 Zahlung; P9 SMTP/
  Inkasso/pf_user/WMS; P10 Eingangsrechnung/tmahnung/tRechnungText/tContact; P11 POS). **Keine** fehlende
  Spalte, kein geänderter Platzhalter, keine geänderte WHERE-Bedingung außer den bereits genannten Punkten.
  Guards (`IF OBJECT_ID … 'U'`) je Tabelle spiegeln die Legacy-Guards (dort wo Legacy ungeguardet war —
  tinetkunde, trechnungsadresse, tAdresse — ist auch neu ungeguardet, innerhalb des P1-TRY).

### D-16 · Credential-Blanking Feld-für-Feld (InvalidateCredentials) · **[Neutral]**
- Alle 13 Legacy-Blöcke feldgenau vorhanden: SMTP (5 Felder), eBay (3 + nGesperrt), OAuth (config+token,
  nInvalid=1), Shop-Repoint (cServerWeb/cAPIKey, nTyp=0+http), PayPal (AccessToken/tPaypalSettings mit
  LIKE-Filtern), tShipperAccount (cPassword/cUserName/cIban/cBic/kOAuthToken=NULL), SCX/Sync/BI-Tokens,
  tVouchersToken (inkl. `<> 'NULL'`-Sonderfall), FulfillmentNetwork, Versandplattform (password- + user-LIKE-
  Sets), twebversand (5 Felder), tLizenz (`LEFT(15)+_deactivated`), tBenutzerLogin, tDatevConfig. Alle
  `OBJECT_ID`-Guards und `LIKE`-Muster identisch übernommen. SMTP-Username erhält in Invalidate zunächst
  `_deactivated`, wird aber in Anonymize P9 durch `NEWID` überschrieben → realer Username final entfernt (wie
  Legacy-Reihenfolge invalidate→clear).

---

## 3. Zusammenfassung

| Klassifikation | Anzahl |
|---|---|
| [Mehrwert] | 6 (D-01, D-02, D-06, D-07, D-09, D-12) |
| [Neutral] | 8 (D-03, D-04, D-05, D-08, D-10, D-11, D-15, D-16) + D-13 |
| [Regression/Lücke] | **1 (D-14)** |

Der Port ist inhaltlich sehr vollständig: alle Anonymisierungs- und Credential-Blanking-Felder sind zeichengenau
übernommen, die Schrittreihenfolge stimmt, und die meisten Abweichungen sind bewusste Härtungen. Der einzige
echte Befund ist **D-14** (pf_user-Alles-oder-nichts-Guard + falscher Kommentar): unter Schema-Drift bleiben
Amazon-Auth-Tokens im Testmandanten unmaskiert stehen, entgegen der Kommentar-Zusage. Empfehlung: Token-Clear
per Einzelspalten-Guard entkoppeln und Kommentar Zeile 482 korrigieren.
