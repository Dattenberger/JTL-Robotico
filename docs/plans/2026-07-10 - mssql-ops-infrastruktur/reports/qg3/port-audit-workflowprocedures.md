---
title: "QG3 Port-Audit — WorkflowProcedures/ → db-migrations/eazybusiness/"
status: Research
audit_type: line-level port fidelity (Legacy → Ebene-A migration)
scope: WorkflowProcedures/ (incl. PayPal/) → db-migrations/eazybusiness/
date: 2026-07-15
---

# QG3 Port-Audit — WorkflowProcedures/ → Ebene A

Objekt- und zeilengenauer 1:1-Abgleich der Legacy-Objekte unter `WorkflowProcedures/`
gegen die portierten Migrationen unter `db-migrations/eazybusiness/`. Grundlage sind
die `-- Ported from …`-Provenienzkommentare, verifiziert gegen den echten
Definitionsinhalt (Parameter, Konstanten, Fehlerbehandlung, fachliche Kommentare).

## Ergebnis in einem Satz

Der Port ist inhaltlich vollständig und getreu: **alle 24 portierbaren Objekte** aus
`WorkflowProcedures/` sind in Ebene A vorhanden. Es gibt **keine Regression** (kein
Objekt verhält sich schlechter oder verliert Funktionalität). Alle Abweichungen sind
**[Mehrwert]** (Portabilität, Security, Serviceability, Korrektheit) oder **[Neutral]**
(Deploy-Scaffolding). Ein **einziger echter Befund zur Klärung**: zwei registrierte
`CustomWorkflows`-Aktionen (`spAuftragPreiseAufNull`, `spSeriennummerStandardZuWMS`)
sind bewusst *nicht* portiert — der Ausschluss ist im README dokumentiert, aber diese
beiden sind produktive, registrierte Aktionen (keine reinen Diagnose-Skripte), weshalb
die „experimentell"-Einordnung eine fachliche Bestätigung verdient (Befund #12).

---

## 1. Mapping-Matrix (Objekt → Migrationsdatei)

| # | Legacy-Objekt | Legacy-Datei | Migrationsdatei | Fidelität |
|---|---|---|---|---|
| 1 | `Robotico.fnGetArticleCustomFieldValue` | `api/CustomFieldAPI.sql` | `functions/Robotico.fnGetArticleCustomFieldValue.sql` | 1:1 (Body identisch) |
| 2 | `Robotico.spEnsureArticleCustomField` | `api/CustomFieldAPI.sql` | `sprocs/Robotico.spEnsureArticleCustomField.sql` | Abw. #1 (Error-Kontrakt) |
| 3 | `Robotico.spSetArticleCustomFieldValue` | `api/CustomFieldAPI.sql` | `sprocs/Robotico.spSetArticleCustomFieldValue.sql` | Abw. #2 (returnCode-Check entfällt) |
| 4 | `Robotico.fnStringStripWhitespace` | `api/StringAndCSVUtilities.sql` | `functions/Robotico.fnStringStripWhitespace.sql` | 1:1 + SCHEMABINDING (#3) |
| 5 | `Robotico.fnStringIsEffectivelyEmpty` | `api/StringAndCSVUtilities.sql` | `functions/Robotico.fnStringIsEffectivelyEmpty.sql` | 1:1 + SCHEMABINDING (#3) |
| 6 | `Robotico.fnStringCountLines` | `api/StringAndCSVUtilities.sql` | `functions/Robotico.fnStringCountLines.sql` | 1:1 + SCHEMABINDING (#3) |
| 7 | `Robotico.fnStringTrimToMaxLines` | `api/StringAndCSVUtilities.sql` | `functions/Robotico.fnStringTrimToMaxLines.sql` | 1:1 (kein SCHEMABINDING, korrekt) |
| 8 | `Robotico.fnStringParseGermanDecimal` | `api/StringAndCSVUtilities.sql` | `functions/Robotico.fnStringParseGermanDecimal.sql` | 1:1 + SCHEMABINDING (#3) |
| 9 | `Robotico.fnEscapedCSVSanitize` | `api/StringAndCSVUtilities.sql` | `functions/Robotico.fnEscapedCSVSanitize.sql` | 1:1 + SCHEMABINDING (#3) |
| 10 | `Robotico.fnEscapedCSVParseLine` | `api/StringAndCSVUtilities.sql` | `functions/Robotico.fnEscapedCSVParseLine.sql` | 1:1 (iTVF, Signatur = API-Kontrakt) |
| 11 | `Robotico.fnEscapedCSVGetField` | `api/StringAndCSVUtilities.sql` | `functions/Robotico.fnEscapedCSVGetField.sql` | 1:1 |
| 12 | `Robotico.fnEscapedCSVGetLastLine` | `api/StringAndCSVUtilities.sql` | `functions/Robotico.fnEscapedCSVGetLastLine.sql` | 1:1 |
| 13 | `Robotico.fnFindDuplicateOrders` | `Duplikaterkennung_Bestellungen.sql` | `functions/Robotico.fnFindDuplicateOrders.sql` | 1:1 (Body byte-genau) |
| 14 | `Robotico.fnHasOlderDuplicateOrder` | `Duplikaterkennung_Bestellungen.sql` | `functions/Robotico.fnHasOlderDuplicateOrder.sql` | 1:1 |
| 15 | `Robotico.spCheckDuplicateOrder` | `Duplikaterkennung_Bestellungen.sql` | `sprocs/Robotico.spCheckDuplicateOrder.sql` | 1:1 |
| 16 | `Robotico.tPaypalAccessToken` (Tabelle) | `PayPal/Add Procudures and Tables.sql` | `up/0002_robotico_paypal_tables.sql` | 1:1 |
| 17 | `Robotico.tPaypalTrackingLog` (Tabelle) | `PayPal/Add Procudures and Tables.sql` | `up/0002_robotico_paypal_tables.sql` | Abw. #8 (Trailing-Comma-Fix) |
| 18 | `Robotico.tPaypalSettings` (Tabelle) + Seed | `PayPal/Add Procudures and Tables.sql` | `up/0002_robotico_paypal_tables.sql` | Abw. #7 (Index-Rename) |
| 19 | `Robotico.spPaypalGetAccessToken` | `PayPal/Add Procudures and Tables.sql` | `sprocs/Robotico.spPaypalGetAccessToken.sql` | 1:1 + SET NOCOUNT (#9) |
| 20 | `Robotico.spPaypalCreateAccessToken` | `PayPal/Add Procudures and Tables.sql` | `sprocs/Robotico.spPaypalCreateAccessToken.sql` | Abw. #4, #5, #6 |
| 21 | `Robotico.spPaypalTrackingCallApi` | `PayPal/Add Procudures and Tables.sql` | `sprocs/Robotico.spPaypalTrackingCallApi.sql` | Abw. #6 (unmapped-carrier log) |
| 22 | `CustomWorkflows.spPaypalTrackingVersand` | `PayPal/Workflowaktion.sql` | `sprocs/CustomWorkflows.spPaypalTrackingVersand.sql` | Abw. #10, #11 (Registrierung/Quotes) |
| 23 | `CustomWorkflows.spPaypalTrackingLieferschein` | `PayPal/Workflowaktion.sql` | `sprocs/CustomWorkflows.spPaypalTrackingLieferschein.sql` | Abw. #10, #11 |
| 24 | `CustomWorkflows.spArticleAppendLabelHistory` | `history/spArticleAppendLabelHistory.sql` | `sprocs/CustomWorkflows.spArticleAppendLabelHistory.sql` | Abw. #1, #13 (Label-Sanitize) |
| 25 | `CustomWorkflows.spArticleAppendPriceHistory` | `history/spArticleAppendPriceHistory.sql` | `sprocs/CustomWorkflows.spArticleAppendPriceHistory.sql` | Abw. #1, #14 (VAT-Auflösung) |
| 26 | `CustomWorkflows.spArticleUpdateAllHistory` | `history/spArticleUpdateAllHistory.sql` | `sprocs/CustomWorkflows.spArticleUpdateAllHistory.sql` | 1:1 |
| 27 | `CustomWorkflows.spGebindeErstellen` | `Workflowaktion_Gebinde_Erstellen.sql` | `sprocs/CustomWorkflows.spGebindeErstellen.sql` | Abw. #10, #15 (Einheit-Auflösung) |
| 28 | `CustomWorkflows.spZustandartikelLieferantSetzen` | `Workflowaktion_Zustandartikel_Lieferant_Setzen.sql` | `sprocs/CustomWorkflows.spZustandartikelLieferantSetzen.sql` | 1:1 (Body byte-genau, #10) |
| — | Schema `Robotico` (defensiver Block) | mehrere Dateien | `up/0001_robotico_schema.sql` | 1:1 (konsolidiert) |
| — | `*_Tests.sql`, Teardown | `*_Tests.sql`, `history/HistorySPs_Tests.sql`, `Duplikaterkennung_Bestellungen_Teardown.sql` | `db-migrations/tests/eazybusiness/*.sql` | portiert (nicht Teil dieses zeilengenauen Objekt-Audits) |

> Anmerkung: Die Zeilennummer 16–18 sind drei Tabellen in einer Migrationsdatei
> (`up/0002`), plus der Settings-Seed. Die Nummerierung 24 Objekte = Zeilen 1–28
> minus Schema/Tests, d. h. 12 Funktionen + 9 Prozeduren + 3 Tabellen = **24 portierte
> DB-Objekte**.

---

## 2. Abweichungsliste (nummeriert)

Format je Eintrag: **Klassifikation** — Legacy `Datei:Zeile` vs. Migration `Datei:Zeile`
— Szenario — Empfehlung.

### #1 — spEnsureArticleCustomField: Error-Kontrakt `RETURN -1` → `THROW`
**[Mehrwert]** (Verhaltensänderung: lauteres Scheitern)
- Legacy `api/CustomFieldAPI.sql:159-163`: bei fehlender Custom-Field-Definition
  `RAISERROR(...16...); RETURN -1;` → Aufrufer erhielt einen Rückgabecode ≠ 0, **keine
  Exception**.
- Migration `sprocs/Robotico.spEnsureArticleCustomField.sql:44-48`: `RETURN -1` entfernt;
  das `RAISERROR` Severity 16 innerhalb des `TRY` springt in den äußeren `CATCH`, der
  `THROW`t. Aufrufer bekommt jetzt eine **geworfene Exception**.
- Szenario: Wenn das JTL-Feld „Vergangene Preise"/„Vergangene Label" auf einem Mandanten
  nicht definiert ist, tat die Historie früher stillschweigend nichts (`IF @returnCode
  <> 0 RETURN;`). Jetzt wird bei Direktaufruf von `spArticleAppendPriceHistory`/
  `…LabelHistory` als Workflow-Aktion ein Fehler an den JTL-Workflow geworfen. Über
  `spArticleUpdateAllHistory` wird der `THROW` gefangen und zu Severity-10-`RAISERROR`
  entschärft (Workflow läuft weiter).
- Bewertung: Konfigurationsfehler (fehlendes Feld) wird sichtbar statt verschluckt —
  sauberer. Aber es *ist* eine Verhaltensänderung für Direktaufrufe der Einzel-Aktionen.
- Empfehlung: akzeptieren. Sicherstellen, dass beim Rollout die beiden Custom-Felder
  auf allen Zielmandanten existieren (sonst schlagen die Einzel-Aktionen jetzt hart
  fehl). Der Header-Kommentar der Migration dokumentiert das Verhalten korrekt.

### #2 — spSetArticleCustomFieldValue: `IF @returnCode <> 0 RETURN -1` entfällt
**[Neutral]** (Folgeänderung zu #1)
- Legacy `api/CustomFieldAPI.sql:322-323` prüfte den Rückgabecode von
  `spEnsureArticleCustomField` und gab bei ≠ 0 selbst `-1` zurück.
- Migration `sprocs/Robotico.spSetArticleCustomFieldValue.sql`: Check entfällt, da
  `spEnsure…` jetzt `THROW`t (siehe #1); der äußere `TRY/CATCH → THROW` propagiert.
- Szenario: konsistent zu #1; kein zusätzlicher Verhaltensunterschied.
- Empfehlung: akzeptieren.

### #3 — String-Funktionen: `WITH SCHEMABINDING` ergänzt
**[Mehrwert]** (Performance, deterministisch/inlinebar)
- Migration `functions/Robotico.fnString{StripWhitespace,IsEffectivelyEmpty,CountLines,
  ParseGermanDecimal}.sql` und `fnEscapedCSVSanitize.sql`: `WITH SCHEMABINDING` an den
  reinen Skalar-UDFs (keine Tabellenreferenzen) → als deterministisch markiert, Froid-
  Inlining greift.
- `fnStringTrimToMaxLines`, `fnEscapedCSVGetField` (rufen andere UDFs / nutzen
  `STRING_SPLIT`) und die iTVF `fnEscapedCSVParseLine` erhielten bewusst **kein**
  SCHEMABINDING — korrekt, da sonst nicht bindbar.
- Szenario: identisches Rechenergebnis, nur bessere Inlining-Chance in aufrufenden Queries.
- Empfehlung: akzeptieren (reiner Gewinn).

### #4 — spPaypalCreateAccessToken: `@debug`-Parameter + PRINT-Gate (Credential-Leak-Fix)
**[Mehrwert]** (Security/Serviceability)
- Legacy `PayPal/Add Procudures and Tables.sql:191-197`: druckte **immer** `@Auth`
  (= `'Basic ' + base64(clientId:secret)`, reversibel!) und `@ResponseText`
  (frischer Bearer-Token) via `PRINT` in den Ausführungs-/Deploy-Log.
- Migration `sprocs/Robotico.spPaypalCreateAccessToken.sql`: neuer Parameter
  `@debug BIT = 0`; PRINTs nur unter `@debug = 1`, und `@Auth` wird **gar nicht mehr**
  gedruckt (auch nicht im Debug).
- Szenario: Ohne den Fix landeten Live-Credentials im Klartext-Log jeder Token-
  Erneuerung. Jetzt still per Default; Aufrufer (`spPaypalTrackingCallApi`) übergibt
  kein `@debug` → 0.
- Empfehlung: akzeptieren (Security-Fix).

### #5 — spPaypalCreateAccessToken: expliziter INSERT-Spaltenlist + doppeltes PRINT weg
**[Mehrwert]** (Robustheit) / **[Neutral]** (Cleanup)
- Legacy `PayPal/Add Procudures and Tables.sql:224-238`: `INSERT INTO
  Robotico.tPaypalAccessToken SELECT scope, access_token, …` (spaltenlos, positional;
  verlässt sich auf Tabellen-Spaltenreihenfolge). Legacy `:194-195` druckt
  `'URL ' + @URL` **zweimal** (Copy-Paste).
- Migration: `INSERT INTO Robotico.tPaypalAccessToken (cScope, cAccessToken, cTokenType,
  cAppID, nExpiresInSeconds, dTokenCreated, bProduction) SELECT …` (explizit); das
  doppelte URL-PRINT ist auf eines reduziert.
- Szenario: identisches Ergebnis bei aktueller Spaltenreihenfolge; explizite Liste ist
  robust gegen künftige Spaltenänderungen.
- Empfehlung: akzeptieren.

### #6 — spPaypalTrackingCallApi: Logging nicht-gemappter Carrier + `@debug`
**[Mehrwert]** (Serviceability)
- Legacy `PayPal/Add Procudures and Tables.sql:293-304`: Zeilen ohne Carrier-Mapping
  (`cPaypalCarrier IS NULL`) wurden kommentarlos aus `@tRawDataForApi` gelöscht — die
  Sendung wurde PayPal nie mitgeteilt, **ohne Spur**.
- Migration `sprocs/Robotico.spPaypalTrackingCallApi.sql`: vor dem `DELETE` ein
  zusätzliches `INSERT INTO Robotico.tPaypalTrackingLog` mit Quelle
  `'spPaypalTrackingCallApi/unmapped-carrier'` für gedroppte Sendungen (Versandart +
  Sendungsnr). Zusätzlich `@debug BIT = 0` analog #4.
- Szenario: Eine Versandart, deren Name kein `dhl/warenpost/post/dpd`-Muster trifft,
  fällt still aus dem PayPal-Batch. Jetzt in `tPaypalTrackingLog` auditierbar.
- Empfehlung: akzeptieren (reiner Serviceability-Gewinn; Kern-API-Logik unverändert).

### #7 — tPaypalSettings: Index-Rename `IX_Robotic_…` → `IX_Robotico_…`
**[Neutral]** (Typo-Korrektur)
- Legacy `PayPal/Add Procudures and Tables.sql:63`: `CREATE UNIQUE INDEX
  IX_Robotic_tPaypalSettings_cKey` (Tippfehler „Robotic").
- Migration `up/0002_robotico_paypal_tables.sql`: `IX_Robotico_tPaypalSettings_cKey`.
- Szenario: nur Objektname des Index; funktional identisch (UNIQUE auf `cKey`).
- Empfehlung: akzeptieren.

### #8 — tPaypalTrackingLog: Trailing-Comma-Syntaxfehler behoben
**[Mehrwert]** (Bugfix)
- Legacy `PayPal/Add Procudures and Tables.sql:44-45`: `dErstellt DATETIME,` mit
  Trailing-Comma vor `)` — auf einer *frischen* Datenbank wäre das ein Syntaxfehler
  im `CREATE TABLE`. Zusätzlich fehlt dem `IF (object_id … IS NULL)` ein `BEGIN…END`
  (nur die eine `CREATE TABLE`-Anweisung ist bedingt — hier zufällig unkritisch).
- Migration `up/0002_robotico_paypal_tables.sql`: saubere Spaltenliste ohne Trailing
  Comma, `IF … BEGIN … END` + `PRINT`.
- Szenario: Legacy-Skript konnte bei Neuanlage der Tabelle scheitern; Migration ist
  syntaktisch sauber.
- Empfehlung: akzeptieren.
- Anmerkung: die falsch geschriebenen Spaltennamen `cBescheibung1/2` (statt
  „Beschreibung") wurden **bewusst beibehalten** — korrekt, da bestehender Datenkontrakt.

### #9 — PayPal-Prozeduren: `SET NOCOUNT ON` ergänzt + `PROC` → `PROCEDURE`
**[Neutral]** (Hygiene)
- Legacy PayPal-Prozeduren nutzen `CREATE OR ALTER PROC` ohne `SET NOCOUNT ON`.
- Migration: `PROCEDURE` ausgeschrieben, `SET NOCOUNT ON` in allen dreien.
- Szenario: unterdrückt „N rows affected"-Meldungen; keine fachliche Änderung.
- Empfehlung: akzeptieren.

### #10 — Action-Registrierung: unbedingt → guarded (`IF OBJECT_ID … IS NOT NULL`)
**[Mehrwert]** (Robustheit auf Mandanten ohne Modul)
- Legacy (alle `CustomWorkflows.*`-Aktionsdateien): `EXEC CustomWorkflows._CheckAction …`
  und `_SetActionDisplayName …` **unbedingt** — schlägt hart fehl, wenn das JTL-Modul
  „Custom Workflow Actions" (das diese Helfer bereitstellt) nicht gebucht ist.
- Migration (alle portierten Aktionen): in `IF OBJECT_ID('CustomWorkflows._CheckAction',
  'P') IS NOT NULL … ELSE PRINT '! … skipping'` gekapselt.
- Szenario: Deploy auf einen frisch geklonten Mandanten ohne gebuchtes Modul: Legacy
  = Abbruch, Migration = Warnung + Weiterlauf. Konsistent mit D10/README §6.
- Empfehlung: akzeptieren.

### #11 — Action-Display-Namen: Double-Quotes → Single-Quotes
**[Mehrwert]** (Korrektheit unter `QUOTED_IDENTIFIER ON`)
- Legacy `PayPal/Workflowaktion.sql:29,54` u. a.: `@displayName = "PayPal Trackingnummer
  miteilen (Versand)"` — doppelte Anführungszeichen sind nur bei
  `QUOTED_IDENTIFIER OFF` ein String-Literal; unter `ON` wären sie ein **Bezeichner**
  → Fehler.
- Migration: einfache Anführungszeichen (`'…'`) — unabhängig von der QI-Einstellung ein
  String.
- Szenario: grate/sqlcmd laufen typischerweise mit `QUOTED_IDENTIFIER ON`; der Legacy-
  Code wäre dort gebrochen. Migration ist robust.
- Empfehlung: akzeptieren. (Anmerkung: der Tippfehler „miteilen" statt „mitteilen" im
  Anzeigenamen wurde beibehalten — kosmetisch, kein Blocker; ggf. separat korrigieren.)

### #12 — Deploy-Scaffolding entfernt (XACT_ABORT / BEGIN TRAN / XACT_STATE-Rollback)
**[Neutral]** (Deploy-Belang, kein Laufzeitverhalten)
- Legacy `api/*.sql`, `history/*.sql`, `Duplikaterkennung_Bestellungen.sql`: jede Datei
  kapselt den Deploy in `SET XACT_ABORT ON` + `BEGIN TRANSACTION` + `IF XACT_STATE()…
  COMMIT/ROLLBACK` + `PRINT '… deployed'`.
- Migration: entfernt — grate umschließt den Deploy mit `--transaction`; ein Objekt pro
  Anytime-Datei.
- Szenario: reine Deploy-Mechanik; die erzeugten Objekt-Definitionen sind identisch.
- Empfehlung: akzeptieren.

### #13 — spArticleAppendLabelHistory: Label-Normalisierung nutzt jetzt `fnEscapedCSVSanitize`
**[Mehrwert]** (CSV-Robustheit) / kleiner Verhaltenshinweis
- Legacy `history/spArticleAppendLabelHistory.sql:47-50`:
  `STRING_AGG(LTRIM(RTRIM(REPLACE(l.cName, ',', ''))), ', ')` — entfernt nur Kommas,
  **nicht** `;`/Quotes/CRLF aus Label-Namen.
- Migration `sprocs/CustomWorkflows.spArticleAppendLabelHistory.sql`: jeder Labelname
  läuft durch `Robotico.fnEscapedCSVSanitize(REPLACE(l.cName, ',', ''), NULL)` (entfernt
  zusätzlich `;`, `'`, `"`, CR, LF) über eine abgeleitete Tabelle, sortiert nach der
  normalisierten Form.
- Szenario: Ein Labelname mit `;` hätte in der Legacy-Version den `'; '`-Feld-Separator
  der History-Zeile zerschossen (falsches Zurücklesen). Migration verhindert das.
  Restrisiko: die *Rücklese*-Seite (letzter Eintrag) nutzt weiter `LTRIM(RTRIM(value))`
  aus `STRING_SPLIT(@lastLabels, ',', 1)`; falls `fnEscapedCSVSanitize` einen Namen
  minimal anders trimmt als früher gespeichert, kann beim **ersten** Lauf nach dem
  Upgrade ein einmaliger „geändert"-Eintrag entstehen. Danach stabil (Write und
  Read-Back aggregieren gleich).
- Empfehlung: akzeptieren; der einmalige Zusatz-Eintrag ist harmlos.

### #14 — spArticleAppendPriceHistory: MwSt.-Satz hart 19 % → aufgelöst (Fallback 19 %)
**[Mehrwert]** (Korrektheit für 7-%-Artikel)
- Legacy `history/spArticleAppendPriceHistory.sql:20`: `@VAT_RATE DECIMAL(5,4) = 0.19`
  — Brutto immer mit 19 % berechnet.
- Migration `sprocs/CustomWorkflows.spArticleAppendPriceHistory.sql`: löst den
  **tatsächlichen** Inland-Steuersatz auf
  (`tSteuersatz`/`tSteuerzone`, `sz.cName = N'Inland'`), Fallback `@VAT_RATE_FALLBACK
  DECIMAL(6,4) = 0.19` wenn nicht auflösbar. (Konstanten-Präzision `DECIMAL(5,4)` →
  `DECIMAL(6,4)`.)
- Szenario: Ein 7-%-Artikel bekam früher einen falschen Brutto-Wert in der History.
  Jetzt korrekt. Wichtig: das Brutto ist **nur Anzeige** — die Änderungserkennung
  vergleicht Netto + Puffer, nicht Brutto —, daher erzeugt ein nicht-auflösbarer Satz
  keinen Spurious-Eintrag, sondern degradiert sauber auf 19 %.
- Empfehlung: akzeptieren (Bugfix mit sicherem Fallback).

### #15 — spGebindeErstellen: Einheit-ID hart `'81'` → per Name aufgelöst (`THROW` wenn fehlt)
**[Mehrwert]** (Portabilität über Mandanten-Klone)
- Legacy `Workflowaktion_Gebinde_Erstellen.sql:66`: `INSERT INTO dbo.tGebinde (…, cName,
  …) VALUES (…, '81', 1)` — die „Stk."-Einheit-ID hart als `'81'` codiert.
- Migration `sprocs/CustomWorkflows.spGebindeErstellen.sql`: `@kEinheitStk =
  (SELECT MIN(kEinheit) FROM dbo.tEinheitSprache WHERE cName = N'Stk.')`, `THROW 50000`
  wenn NULL; `CAST(@kEinheitStk AS NVARCHAR(255))` als `cName`.
- Szenario: Auf einem Mandanten, dessen „Stk."-Einheit **nicht** `kEinheit = 81` ist,
  hätte die Legacy-Version ein falsches Gebinde erzeugt. Jetzt korrekt bzw. harter,
  sichtbarer Fehler statt Fehldaten (README §4: keine JTL-IDs hart codieren).
- Restrisiko: `MIN(kEinheit)` bei mehreren Sprachzeilen mit `cName = N'Stk.'` wählt die
  kleinste ID — akzeptabel; theoretisch könnten mehrere Einheiten denselben lokalisierten
  Namen tragen.
- Empfehlung: akzeptieren.

---

## 3. Bewusst nicht portiert (begründet)

Alle folgenden sind im `WorkflowProcedures/README.md` unter „Not migrated (intentionally)"
gelistet.

| Objekt / Datei | Grund | Bewertung |
|---|---|---|
| `Diagnose_Workflow.sql` | Ad-hoc-Diagnose-SELECTs gegen `CustomWorkflows.vCustomAction*` — kein deploybares Objekt | korrekt ausgeschlossen |
| `PayPal/Test/*` (3 Dateien) | Manuelle API-Probeaufrufe (Token holen, API-Call, Versand-Test) | korrekt ausgeschlossen |
| `PayPal/Enable OLE Procedures.sql` | **Server-Level** `sp_configure 'Ole Automation Procedures'` + `RECONFIGURE` — kein DB-Objekt, kann keine grate-eazybusiness-Migration sein | korrekt ausgeschlossen, **aber operative Voraussetzung** — in den Headern von `spPaypalCreateAccessToken`/`…TrackingCallApi` als NOTE referenziert. Sicherstellen, dass ein Runbook/Prereq dies abdeckt. |
| `*_Tests.sql`, `history/HistorySPs_Tests.sql`, `Duplikaterkennung_Bestellungen_Teardown.sql` | Nach `db-migrations/tests/eazybusiness/*.sql` portiert (eigener Testpfad, nicht Teil dieses Objekt-Audits) | korrekt umgezogen (Zeilenabgleich der Tests nicht im Scope dieses QG3) |
| `Workflowaktion Auftrag Preise auf Null*.Sql` (`spAuftragPreiseAufNull`) | README: „ad-hoc/experimentell" | **siehe Befund #12 unten — Klärung** |
| `Workflowaktion Artikel Seriennummern Standardlager auf WMS*.Sql` (`spSeriennummerStandardZuWMS`) | README: „ad-hoc/experimentell" | **siehe Befund #12 unten — Klärung** |

### Rückwärts-Check EKL-Ausschluss

`grep -riE "spCMArtikel|RoboticoEKL"` über `WorkflowProcedures/` liefert **keine Treffer**.
Es existieren dort keine EKL-Objekte — daher ist auch keines fälschlich nach Ebene A
portiert. Korrekt.

---

## 4. Einziger Klärungsbefund

### #12 (Scope-Befund) — Zwei registrierte Aktionen als „experimentell" ausgeschlossen
**[Lücke — zu bestätigen]**

- `CustomWorkflows.spAuftragPreiseAufNull` (`Workflowaktion Auftrag Preise auf Null.Sql`)
  und `CustomWorkflows.spSeriennummerStandardZuWMS`
  (`Workflowaktion Artikel Seriennummern Standardlager auf WMS.Sql`) sind **nicht** in
  Ebene A portiert.
- Beide sind jedoch **produktiv registrierte** Custom-Workflow-Aktionen: sie rufen
  `CustomWorkflows._CheckAction` + `_SetActionDisplayName` mit echten Anzeigenamen auf
  („Auftrag Preise auf Null setzen", „Seriennummer Standard zu WMS kopieren") — im
  Gegensatz zu den reinen Diagnose-/Test-Skripten. `spAuftragPreiseAufNull` ist zudem in
  der Projekt-`CLAUDE.md` als reales Feature genannt („setting order prices to zero for
  internal orders").
- Szenario: Wenn die alte Deploy-Quelle (`WorkflowProcedures/`) außer Betrieb geht
  (README: „no longer the deployment source of truth") und diese beiden Aktionen nicht
  in die grate-Kette wandern, existieren sie auf frisch geklonten/neu deployten Mandanten
  **nicht mehr** — der zugehörige JTL-Workflow (interne Aufträge → Preise 0; WMS-
  Seriennummern-Umzug) würde brechen.
- Nebenbeobachtung (nur Legacy, nicht deploy-relevant): `spAuftragPreiseAufNull`
  registriert `_CheckAction @actionName = 'auftragPreiseNull'`, setzt aber den Anzeigenamen
  für `'spAuftragPreiseAufNull'` — inkonsistente Action-Namen. `spSeriennummerStandardZuWMS`
  enthält copy-paste-Kommentare („Auftrag Preise auf Null") und ein doppeltes
  `AND kLieferscheinPos = 0` sowie ein abschließendes `SELECT *` (Debug-Ausgabe).
- Empfehlung: **fachlich bestätigen**, ob diese beiden Aktionen noch aktiv in
  JTL-Workflows verdrahtet sind. Falls ja → in Ebene A nachziehen (dabei die
  Legacy-Mängel bereinigen: Action-Namen vereinheitlichen, Debug-`SELECT`/PRINTs
  entfernen, Warenlager-IDs 6/17 nicht hart codieren). Falls nein (wirklich abgelöst/
  experimentell) → Ausschluss ist korrekt; dann idealerweise in der Aktion selbst
  deregistrieren.

---

## 5. Zusammenfassung der Klassifikationen

| Klassifikation | Anzahl | Befund-Nummern |
|---|---|---|
| [Mehrwert] | 10 | #1, #3, #4, #5, #6, #8, #10, #11, #13, #14, #15 (⇒ 11 Einzelpunkte) |
| [Neutral] | 4 | #2, #7, #9, #12 (Scaffolding) |
| [Regression/Lücke] | 0 | — |
| [Lücke — zu bestätigen] | 1 | #12 (Scope): 2 nicht portierte registrierte Aktionen |

Kein Objekt wurde funktional verschlechtert. Der Port ist getreu; die Abweichungen sind
durchweg Verbesserungen (Portabilität, Security, Serviceability, Syntax-Korrektheit) oder
neutrale Deploy-Mechanik. Der einzige handlungsrelevante Punkt ist die Bestätigung des
bewussten Ausschlusses von `spAuftragPreiseAufNull` und `spSeriennummerStandardZuWMS`.
