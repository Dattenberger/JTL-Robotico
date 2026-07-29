---
title: History-Read-Mechanik — funktioniert die Leseseite nach der Ebene-A-Portierung?
status: Research
date: 2026-07-29
subsystem: JTL SQL Migrations
---

# History-Read-Mechanik der Preis-/Label-Freifelder — Kompatibilität nach der Schreibseiten-Überarbeitung

## Kurzantwort

**Ja, die komplette Read-Mechanik funktioniert weiterhin.** Das geschriebene
CSV-Format hat sich bei der Ebene-A-Portierung **nicht** geändert (der
`CONCAT_WS`-Block ist gegenüber der Alt-Fassung byte-identisch), und alle
Reader greifen exakt auf die ordinalen Feldpositionen zu, die die Schreibseite
emittiert. Der F4.4-Fix an `fnStringParseGermanDecimal` hat **keinen** Einfluss
auf reale Daten.

**Den vom User vermuteten View gibt es — er liegt im excel_ekl-Repo:**
`RoboticoEKL.vArtikelPreisHistory_V1` und `RoboticoEKL.vArtikelLabelHistory_V1`
(definiert in `excel_ekl/backend/migrations/jtl/012_article_history_views/up.sql`).

## 1. Schreibformat (fixiert)

Beide Writer-SPs liegen in **diesem** Repo:
`db-migrations/eazybusiness/sprocs/CustomWorkflows.spArticleAppendPriceHistory.sql`
und `…spArticleAppendLabelHistory.sql`.

Eine Zeile pro Änderung, Zeilen per **CRLF** getrennt, Feldseparator **`'; '`**
(Semikolon + Space), älteste Zeile zuerst. `FORMAT(…, 'de-DE')` ⇒ deutsche
Zahl (`N2`, z.B. `99,99` / `1.234,56`) und deutsches Datum
`dd.MM.yyyy HH:mm:ss`.

**Vergangene Preise** (`spArticleAppendPriceHistory.sql:112-117`):

| Ordinal | Feld | Beispiel |
|---|---|---|
| 1 | Datum + Zeit | `29.07.2026 14:30:00` |
| 2 | VK Netto (de-DE, N2) | `99,99` |
| 3 | VK Brutto (de-DE, N2) | `118,99` |
| 4 | `Puffer ` + Zahl | `Puffer 3` |
| 5 | Benutzer | `kiana` |

Beispielzeile: `29.07.2026 14:30:00; 99,99; 118,99; Puffer 3; kiana`

**Vergangene Label** (`spArticleAppendLabelHistory.sql:90-93`):

| Ordinal | Feld | Beispiel |
|---|---|---|
| 1 | Datum + Zeit | `29.07.2026 14:30:00` |
| 2 | Label-Liste (`', '`-getrennt, kommabereinigt + sanitized) | `Abverkauf, BW nachteilig` |
| 3 | Benutzer | `kiana` |

Beispielzeile: `29.07.2026 14:30:00; Abverkauf, BW nachteilig; kiana`

### Kein Formatwechsel bei der Portierung

`diff` der `CONCAT_WS`-Blöcke Alt (`WorkflowProcedures/history/…`) vs.
Ebene A (`db-migrations/eazybusiness/sprocs/…`): **identisch** für Preis
**und** Label. Geändert wurde bei der Portierung nur:
Transaktions-/Registrierungs-Gerüst, und beim Preis-SP die
MwSt-Auflösung (früher hart `0.19`, jetzt echter Steuersatz via `tSteuersatz`
/ `Inland`). Brutto ist Anzeigewert; die Änderungserkennung vergleicht
Netto + Puffer, nicht Brutto — das Feldlayout bleibt gleich.

## 2. Read-Mechanik — alle Konsumenten

### A) Dieses Repo — Preisrecherche-Excel-Export (ad-hoc-Skript, KEIN DB-Objekt)

`Projekte/PreisRechercheExcel/PreisRecherche_Optimiert.sql` (aktiv) und
`…_Legacy.sql` (Vorgänger). Kein `CREATE VIEW`, sondern eine
Excel-Export-Abfrage (per SSMS/Excel ausgeführt) — taucht daher **nicht** in
`sys.sql_modules` auf, ist aber ein realer Reader.

- Preis-Pipeline `#PreisRoh` (`:88-92`): `Robotico.fnEscapedCSVParseLine(zeile, ';')`,
  Ordinal 1 = Datum, 2 = Netto, 3 = Brutto. Header-Doku (`:50-57`) beschreibt
  exakt das obige Schreibschema.
- Label-Pipeline `#LabelRoh` (`:125-128`): Ordinal 1 = Datum, 2 = Label-Liste.
- Datum: `TRY_CONVERT(DATETIME, LEFT(DatumRoh, …vor dem Space…), 104)`.
- Zahl: `#PreisTrend` (`:219`) ruft **`Robotico.fnStringParseGermanDecimal(Brutto)`**
  auf — **einziger Live-Reader, der die F4.4-gefixte Funktion konsumiert.**

### B) excel_ekl-Repo — die Views (der vom User vermutete View)

`excel_ekl/backend/migrations/jtl/012_article_history_views/up.sql`:

- **`RoboticoEKL.vArtikelPreisHistory_V1`** (`:162-218`): parst die CSV
  „Vergangene Preise". `RawFields`-CTE mit `fnEscapedCSVParseLine(lines.value, ';')`,
  Ordinal 1=sDate, 2=sNetto, 3=sBrutto, 4=sPuffer, 5=sUser — **deckungsgleich**
  mit der Schreibseite. Puffer: `sPuffer LIKE 'Puffer %' → SUBSTRING(…,8,…)`
  (Prefix „Puffer " = 7 Zeichen). Zahl-Parsing **inline** kopiert
  (`REPLACE/REPLACE/TRY_CAST`), **nicht** über `fnStringParseGermanDecimal`
  (Performance-Grund, Kommentar `:148-154`).
- **`RoboticoEKL.vArtikelLabelHistory_V1`** (`:53-85`): Ordinal 1=Datum,
  2=cLabels, 3=cBenutzerName — deckungsgleich.
- `…_V2`-Views lesen die **normalisierten Tabellen**
  (`RoboticoEKL.tArtikelPreisHistory` / `tArtikelLabelHistory`); die
  API-Views (`vArtikelPreisHistory` / `vArtikelLabelHistory`) delegieren an V2.
  **Das Backend liest im Normalbetrieb V2, nicht die CSV.** Die V1-Views sind
  heute primär Migrations-/Backfill-/Parity-Werkzeug (Mig 013 Import, Mig 028
  Backfill der V1-App-Preisänderungen, V1↔V2-Paritätstests).

Gemeinsame Abhängigkeit beider Reader: **`Robotico.fnEscapedCSVParseLine`**
(dieses Repo). Deren Header markiert die Signatur explizit als
Rückwärtskompatibilitäts-Kontrakt mit excel_ekl (**D10** — „Do not change the
parameter list"). Beide Seiten dokumentieren den Kontrakt.

### C) Live-Verifikation (Container `robotico-e2e-mssql`, `localhost,14330`)

In `eazybusiness` vorhanden und bestätigt:
- `Robotico.fnEscapedCSVParseLine` (INLINE_TVF), `Robotico.fnStringParseGermanDecimal`.
- `RoboticoEKL.vArtikelPreisHistory_V1` / `_V2` / API, `vArtikelLabelHistory_V1` / `_V2` / API.
- Writer `CustomWorkflows.spArticleAppendPriceHistory` **und**
  `spArticleAppendLabelHistory`; zusätzlich ein **zweiter** Writer
  `RoboticoEKL.spArticleAppendPriceHistory` (excel-ekl-eigener Pfad; Mig 028
  erwähnt zudem den Dual-Write in `RoboticoEKL.spCMArtikel`, der CSV **und**
  V2-Tabelle schreibt).
- `sys.sql_modules` bestätigt: `vArtikelPreisHistory_V1` und
  `vArtikelLabelHistory_V1` referenzieren live `fnEscapedCSVParseLine` + die
  CSV-Feldnamen. Kein Drift zur Repo-Definition.

## 3. Kompatibilitäts-Matrix (Reader × Schreibformat-Aspekt)

| Aspekt | Schreibseite (Ebene A) | Preisrecherche (Repo) | excel_ekl V1-View | Bricht? |
|---|---|---|---|---|
| Feld-Reihenfolge / Ordinals | fix 1..5 (Preis) / 1..3 (Label) | Ordinal 1/2/3 | Ordinal 1..5 / 1..3 | **Nein** — identisch |
| Feldseparator | `'; '` | `fnEscapedCSVParseLine(…, ';')` + Trim | dito | **Nein** |
| Zeilenseparator | CRLF | `REPLACE(CRLF→LF)` + Split `CHAR(10)` | dito | **Nein** |
| Datumsformat | `dd.MM.yyyy HH:mm:ss` de-DE | `CONVERT(…,104)` auf Datumsteil | `TRY_CONVERT(DATETIME2,…,104)` | **Nein** |
| Dezimalformat | `N2` de-DE (`99,99`) | `fnStringParseGermanDecimal` (F4.4) | inline-Kopie (ohne F4.4-Guard) | **Nein** (s.u.) |
| Puffer-Prefix | `'Puffer '` + Zahl | (nicht geparst) | `LIKE 'Puffer %'`, `SUBSTRING(…,8)` | **Nein** |
| Sanitizing (`;`/Quotes/CR/LF, Komma-Strip Label) | Schreibseite | robust ggü. bereinigten Werten | dito | **Nein** |

### F4.4-Fix — kein Effekt auf reale Daten

`fnStringParseGermanDecimal` liefert seit F4.4 für **US-Format** (`1,234.56`)
`NULL` statt eines stillen Falschwerts. Die Schreibseite emittiert aber
**ausschließlich** deutsches `N2`-Format — US-Format kommt in der CSV nie vor.
Damit liefern die gefixte Funktion (Preisrecherche) **und** die inline-Kopie im
excel_ekl-View auf realen Daten identische Ergebnisse. Der Fix ist folgenlos
für den Datenfluss.

## 4. Verantwortung

| Artefakt | Repo / Ort | Wer pflegt bei Formatänderung |
|---|---|---|
| CSV-**Schreibformat** (`spArticleAppend{Price,Label}History`) | **JTL-Robotico** (`db-migrations/eazybusiness/sprocs/`) | JTL-Robotico |
| `Robotico.fnEscapedCSV*` / `fnString*` (geteilter Kontrakt, D10) | **JTL-Robotico** (`db-migrations/eazybusiness/functions/`) | JTL-Robotico (Signatur stabil halten) |
| Reader **Preisrecherche-Export** | **JTL-Robotico** (`Projekte/PreisRechercheExcel/`) | JTL-Robotico |
| **Views** `vArtikelPreisHistory_V1` / `vArtikelLabelHistory_V1` | **excel_ekl** (`backend/migrations/jtl/012_…`) | excel_ekl |
| Zweiter Writer `RoboticoEKL.spArticleAppendPriceHistory` / Dual-Write `spCMArtikel` | **excel_ekl** | excel_ekl |

Eine Änderung am CSV-Format in JTL-Robotico muss **beide** Reader nachziehen:
den Preisrecherche-Export (dieses Repo) **und** die V1-Views (excel_ekl).

## 5. Risiken / Empfehlungen

1. **Latente Parse-Divergenz (minor):** Der excel_ekl-V1-View trägt eine
   **inline-Kopie** der Dezimal-Parse-Logik **ohne** F4.4-US-Format-Guard.
   Bei realem de-DE-Format irrelevant, aber sollte je US-formatierter Müll in
   die CSV geraten, würden die beiden Reader auseinanderlaufen (Preisrecherche
   → NULL, View → stiller Falschwert). Empfehlung: Kommentar/Notiz im
   excel_ekl-View, dass die Inline-Logik bewusst von `fnStringParseGermanDecimal`
   abweicht (F4.4).
2. **Veralteter Rationale in excel_ekl Mig 028 (kosmetisch):** Der Header von
   `028_backfill_v1_app_price_history/up.sql` begründet die Brutto-Neuberechnung
   für Steuersätze ≠ 19 % damit, dass die Legacy-SP „hart 19 %" rechne. Der
   **portierte** SP löst den echten Steuersatz auf und schreibt Brutto bereits
   korrekt — der Recompute-Zweig ist redundant (liefert denselben Wert), die
   dokumentierte Begründung ist überholt. Kein Datenrisiko.
3. **STRING_SPLIT ordinal (Kontext-Caveat, kein Regress):**
   `fnEscapedCSVParseLine` nutzt die 3-arg-`STRING_SPLIT(@line, sep, 1)`-Form
   (SQL Server 2022+). Beide Reader hängen daran. Auf Mandant-Clones mit
   niedrigerem DB-Compat-Level schlägt das zur Laufzeit fehl — dokumentiert im
   Funktions-Header, unabhängig von der Schreibseiten-Überarbeitung.

## Belege (Datei:Zeile)

- Schreibseite Preis: `db-migrations/eazybusiness/sprocs/CustomWorkflows.spArticleAppendPriceHistory.sql:112-117`
- Schreibseite Label: `…/CustomWorkflows.spArticleAppendLabelHistory.sql:90-93`
- Alt-Fassung (byte-identischer CONCAT_WS): `WorkflowProcedures/history/spArticleAppend{Price,Label}History.sql`
- Reader Preisrecherche: `Projekte/PreisRechercheExcel/PreisRecherche_Optimiert.sql:50-57, 88-92, 125-128, 219`
- excel_ekl Views: `excel_ekl/backend/migrations/jtl/012_article_history_views/up.sql:53-85, 162-218`
- excel_ekl Backfill (CSV-Konsument): `excel_ekl/backend/migrations/jtl/028_backfill_v1_app_price_history/up.sql`
- F4.4-Fix: `db-migrations/eazybusiness/functions/Robotico.fnStringParseGermanDecimal.sql:24-43`
- D10-Kontrakt: `db-migrations/eazybusiness/functions/Robotico.fnEscapedCSVParseLine.sql:8-19`

---

# Abschnitt A — E2E-Nachweis: in welchem Rahmen wurde die Portierung abgesichert?

## A.0 Kurzfassung

Die portierten Objekte und die Migrations-/Reset-Infrastruktur wurden in **drei
Stufen** gegen echte SQL-Server-Container/Instanzen abgesichert: (1) vier
committete Tier-3-Testsuiten, (2) die Migrations-Testkampagne 2026-07-27/28
(T4 funktionale Vollabdeckung + T6 Fix-Verifikation), (3) die Docker-Voll-E2E
2026-07-11 (47 PASS). **Alle Läufe endeten GRÜN, 0 echte FAILs.** Ehrlich
ausgewiesen (A.4): der **Wawi-seitige Workflow-Aufruf** der Aktionen, der
**Preisrecherche-Excel-Reader** und die **excel_ekl-Leseseite** sind durch
**keine** dieser Kampagnen automatisiert abgedeckt.

## A.1 Committete Tier-3-Testsuiten (`db-migrations/tests/eazybusiness/`)

Transaktions-basiert (BEGIN TRAN → Test → ROLLBACK), gegen einen Testmandanten
(`eazybusiness_tm2`, feste Fixture-Artikel) laufend, self-cleaning. Fallzahlen
über die `#TestResults`-Zeilen ausgezählt:

| Suite | Fälle | Prüft (Read-Mechanik-relevant fett) | Zuletzt voll ausgeführt |
|---|---|---|---|
| `HistorySPs_Tests.sql` | **14** | spArticleAppend{Price,Label}History + UpdateAll: **Erstanlage + exaktes CSV-Format**, Change-Detection (Preis/Puffer/Label), **Doppelaufruf-Reparse (schreibt-liest eigenes Format)**, Username-/Komma-Sanitization, Default-Username | siehe A.1-Hinweis |
| `StringAndCSVUtilities_Tests.sql` | 10 Sektionen / **57 Checks** | alle `fnString*` + `fnEscapedCSV*` inkl. **`fnEscapedCSVParseLine` (Ordinal-Parsing)** und **`fnStringParseGermanDecimal` (F4.4)** | **2026-07-28, PASS 57/57** (T6) |
| `DuplicateOrders_Tests.sql` | 8 | fnFindDuplicateOrders / fnHasOlderDuplicateOrder / spCheckDuplicateOrder | Kampagne via T4-09 (live-Ergänzung) |
| `CustomFieldAPI_Tests.sql` | 8 | fnGetArticleCustomFieldValue / spEnsureArticleCustomField / spSetArticleCustomFieldValue | Kampagne via T4-07 (live-Ergänzung) |
| `GebindeErstellen_Tests.sql` | 4 (2 Sekt.) | spGebindeErstellen (F4.6-Idempotenz) | **2026-07-28, PASS 4/4** (T6) |
| `CustomWorkflowsSchemaPrecondition_Tests.sql` | 4 (3 Sekt.) | up/0004 Schema-Precondition (F4.1) | **2026-07-28, PASS 4/4** (T6) |

**A.1-Hinweis (ehrlich):** Die Kampagne 2026-07-27/28 war als **Lücken-Ergänzung**
zu den vier bestehenden Suiten angelegt — T4-07/08/09/10 sind ausdrücklich
„Ergänzung `<Suite>`" (`T4-ebene-a-funktional.md:82-85`). Das heißt: die
Kern-`StringAndCSVUtilities_Tests.sql` wurde **verbatim voll ausgeführt** (57/57,
`T6:34`); die **`HistorySPs_Tests.sql` (14) / `CustomFieldAPI_Tests.sql` (8) /
`DuplicateOrders_Tests.sql` (8)** wurden in dieser Kampagne **nicht verbatim
neu ausgeführt**, sondern (a) als Coverage-Baseline vorab analysiert
(`03-teilrecherche-ebene-a-wartung.md:84-87`) und (b) durch **live-Ad-hoc-Proben**
gegen den Container in den Lücken erweitert (T4-07/08/09/10, s. A.2). Ihre
Fixture-Bindung an `eazybusiness_tm2` (kArtikel 19807/73/234) bzw. reale
Seed-Aufträge 236/237 macht sie im getrimmten E2E-Klon nicht 1:1 lauffähig —
deshalb der Ad-hoc-Ersatz. Ihr letzter dokumentierter Volllauf ist der
Ursprungs-Stand (Autor-Datum 2026-02-24, vor der Portierung); die Portierung
selbst wurde funktional über T4 + StringAndCSV abgesichert, nicht über einen
erneuten Verbatim-Lauf dieser drei Suiten.

## A.2 Migrations-Testkampagne 2026-07-27/28 — History-Mechanik konkret

**T4 (funktionale Vollabdeckung, 2026-07-27**, Container `robotico-e2e-mssql`,
`eazybusiness` tVersion 2.0.5.0, `T4-ebene-a-funktional.md`): **PASS 21 · THROW-OK 3 ·
EXPECTED-FAIL-reproduziert 3 · SKIP 3 · echte FAIL 0.** Die History-Schreib-/
Leseprimitive direkt:

- **T4-08a — 1000-Zeilen-Trim (PASS):** Freifeld mit 1010 Zeilen vorbelegt,
  Preis geändert → 1011 → Trim auf exakt 1000; jüngster Eintrag erhalten
  (`T4-…:152-154`). Beweist den Round-Trip Schreiben→Zählen→Trimmen.
- **T4-08b — Steuerzone-Fallback (PASS) + Live-Beleg des Schreibformats:**
  geschriebener Eintrag `27.07.2026 …; 123,45; 146,91; Puffer 0; T4` — Brutto =
  netto·1.19 (`T4-…:156-158`). **Das ist der Live-Nachweis, dass das in
  Abschnitt 1 fixierte CSV-Format exakt so emittiert wird** (Ordinal 1..5,
  Separator `'; '`, de-DE-Dezimal/Datum).
- **T4-08d — fehlende Freifeld-Definition → THROW-OK** (`… Custom field
  definition not found …`, `T4-…:164-166`).
- **T4-10b — F4.4 REPRODUZIERT (vor Fix):** `fnStringParseGermanDecimal('1,234.56')`
  → stiller Falschwert `1.2345600000000` (`T4-…:187-190`).

**T6 (Fix-Verifikation, 2026-07-28**, `T6-fix-verifikation.md`): **70/70 Checks PASS**,
5 Fixes VERIFIED-FIXED, beide Ketten idempotent, `db:validate:e2e` grün. Für die
Read-Mechanik entscheidend:

- **F4.4 VERIFIED-FIXED:** `'1,234.56'` (US) → **NULL**; `'1.234,56'` → 1234.56;
  `'1.234.567,89'` → 1234567.89 (`T6:20`). Der **Preisrecherche-Reader** ist der
  einzige Live-Konsument der gefixten Funktion (Abschnitt 2A) — sein
  `#PreisTrend`-Zweig profitiert vom Fix, ohne dass reale de-DE-Daten betroffen
  sind.
- **StringAndCSVUtilities_Tests.sql 57/57** (`T6:34`) — deckt das
  Ordinal-Parsing (`fnEscapedCSVParseLine`), die Feld-Extraktion
  (`fnEscapedCSVGetField/GetLastLine`) und die Zeilen-/Trim-Logik ab, d.h. die
  **Bausteine beider Reader**.

## A.3 Docker-Voll-E2E 2026-07-11 (`qg2/e2e-docker-report.md`) — 47 PASS / 0 FAIL / 1 SKIP

Voll-Durchlauf beider Migrationsketten **und** der Reset-Pipeline gegen eine
echte getrimmte `eazybusiness`-Kopie:

- **Abschnitt A (Baseline-Adopt, 4/4):** Der **A2b-Realitätstest** deployte alle
  **25 Anytime-Objekte** (12 `Robotico.fn*`, 6 `Robotico.sp*`, 7
  `CustomWorkflows.sp*`) via `CREATE OR ALTER` gegen ein echtes JTL-`eazybusiness`
  — **alle grün**, kein Syntax-/SCHEMABINDING-/Missing-Column-Fehler
  (`e2e-docker-report.md:69-80`). Das ist der Compile-/Bind-Nachweis der
  portierten CSV-/String-Funktionen (Slot-5 SCHEMABINDING) gegen echtes Schema.
- **Abschnitt B (One-time-vs-Anytime, 6/6):** Hash-Redeploy-Semantik der
  grate-Kette bewiesen.
- **Abschnitt C (Reset-E2E, 34/34 inkl. 25 Paritäts-Assertions, 1 SKIP):** voller
  Reset über die Low-Priv-Signing-Kette, 3× end-to-end wiederholt (404/451/499 s).
- **Gesamt GREEN, keine Bugs.** Der einzige SKIP ist der Live-„running-cancel"
  (per Design abgelehnt; deterministischer queued-Pfad getestet).

## A.4 NICHT durch E2E abgedeckt (ehrlich)

1. **Wawi-seitiger Workflow-Aufruf.** Alle Tests rufen die
   `CustomWorkflows.sp*`-Aktionen **direkt** per `EXEC` auf. Der Aufruf über die
   **JTL-Blockly-/`tWorkflowAktion`-Engine** (das reale Auslösen der Aktion im
   Wawi-Betrieb) ist in **keiner** Kampagne getestet — nur die guarded
   Registrierung (`_CheckAction`/`_SetActionDisplayName`) wird geprüft, nicht die
   Trigger-Kette der Engine.
2. **Preisrecherche-Excel-Reader** (`Projekte/PreisRechercheExcel/*.sql`): **kein
   automatisierter Test, in keiner Suite/Kampagne**. Absicherung ausschließlich
   über den Format-Kontrakt (Abschnitt 3) + eine **manuelle** Einmal-Verifikation
   (Header: „0 Mismatches, 24.014 Zeilen gegen `eazybusiness_tm2`",
   `PreisRecherche_Optimiert.sql:5-7`).
3. **excel_ekl-Leseseite** (`vArtikelPreisHistory_V1`/`vArtikelLabelHistory_V1`):
   getestet in der **excel_ekl-eigenen** Suite
   (`012_article_history_views/tests/*`), **außerhalb** dieses Repos und seiner
   Kampagnen. Aus JTL-Robotico-Sicht ungetestet.
4. **Fixture-Lücken im getrimmten Klon** (als SKIP dokumentiert, nicht als FAIL):
   `kSprache<>0`-Freifelder (T4-07b), echter 7 %-Steuersatz (T4-08c),
   Race-2627-Nebenläufigkeit (T4-07c). Diese Pfade sind **nicht** live verifiziert.

---

# Abschnitt B — Paritätsprüfung der Übernahme

## B.0 Wichtig: drei verschiedene „Paritäts"-Begriffe sauber getrennt

Die Nachweise adressieren **drei unterschiedliche** Paritätsfragen — sie zu
vermengen wäre irreführend:

| # | Paritätsbegriff | Frage | Nachweis | Verdikt |
|---|---|---|---|---|
| P1 | **Reset-Klon-Parität** | Reproduziert ein Restore-Klon die **aktuell deployten** Objekte byte-genau? | `schema-parity-flow-robotico.md` (4-Sektionen-Diff) | **byte-genau, 0 Drift** |
| P2 | **Port-Treue** | Entsprechen die Ebene-A-Objekte dem **Alt-Bestand** `WorkflowProcedures/`? | `qg3/port-audit-workflowprocedures.md` (zeilengenau) + Testsuiten | **REFACTOR** — teils 1:1, teils bewusst überarbeitet |
| P3 | **Reset-Daten/Security-Parität** | Garantiert die Reset-Pipeline die richtigen **Daten**-Endzustände? | Docker-E2E „25 Paritäts-Assertions" | **25/25 PASS** |

**Die „Bit-Gleichheit" der Übernahme (P2) gilt bewusst NICHT flächendeckend** —
die Portierung war ein Refactor, kein Byte-Copy. Byte-genau ist die
**Klon-Parität P1** (Klon == aktuell deployte Objekte).

## B.1 P1 — Reset-Klon-Parität (`schema-parity-flow-robotico.md`, 2026-07-15)

Cross-DB-Diff `eazybusiness` vs. frischer Klon `eazybusiness_tm9` (gleiche
Instanz `vm-sql-test1`), Schemata `CustomWorkflows` (20 Objekte) + `Robotico`
(38 Objekte), **vier Sektionen**:

| Sektion | Zeilen | Ergebnis |
|---|---|---|
| 1. Objekt-Set (Schema+Name+Typ) | 0 | identisch |
| 2. Definitions-Hash (Proc/Fn/View, SHA2-256) | 0 | jede Definition byte-identisch |
| 3. Spalten-Attribute (Typ/Länge/Präz/Scale/Null/Identity/Ordinal) | 0 | identisch |
| 4. Indizes (Unique/PK/Key-Spalten, strukturell gematcht) | 0 | identisch |

**Verdikt: ZERO Drift** (`schema-parity-flow-robotico.md:154-164`). Die
Reset-/Anonymisierungs-Pipeline ändert **nur Daten, nie Schema** — ein
physischer `RESTORE` reproduziert alle Objekte exakt. **Das ist der Beleg, dass
ein zurückgesetzter Testmandant die History-SPs + CSV-Funktionen identisch
trägt.**

## B.2 P2 — Port-Treue Legacy → Ebene A (der eigentliche „saubere-Übernahme"-Nachweis)

Das zeilengenaue Port-Audit (`qg3/port-audit-workflowprocedures.md`, 2026-07-15)
gleicht **27 gemappte Objekte** (24 portierbar + PayPal-Tabellen) gegen ihre
`-- Ported from …`-Quelle ab. **Verdikt in einem Satz:** „Der Port ist inhaltlich
vollständig und getreu … keine Regression … alle Abweichungen sind [Mehrwert]
oder [Neutral]" (`:26-33`).

**Ehrliche Klassifizierung je Objektgruppe** (Übernahmeart / Prüfmechanismus /
Fundstelle) — für die History-Read-Mechanik relevante Zeilen fett:

| Objekt(-gruppe) | Übernahmeart | Prüfmechanismus | Fundstelle |
|---|---|---|---|
| **`fnEscapedCSVParseLine`** (Ordinal-Parser, D10) | **1:1** (Body + Signatur unverändert) | StringAndCSV-Suite 57/57, T4-10, A2b-Bind | `port-audit:Zeile 10` |
| `fnEscapedCSVGetField` / `GetLastLine` | **1:1** | dito | `port-audit:11-12` |
| `fnEscapedCSVSanitize` | 1:1 **+ SCHEMABINDING** (Verhalten gleich, Def-Text +Klausel) | StringAndCSV-Suite | `port-audit:9` |
| `fnStringStripWhitespace` / `IsEffectivelyEmpty` / `CountLines` | 1:1 **+ SCHEMABINDING** | StringAndCSV-Suite 57/57 | `port-audit:4-6` |
| `fnStringTrimToMaxLines` | **1:1** (bewusst **kein** SCHEMABINDING) | T4-10a (nur-Leerzeilen→NULL) | `port-audit:7` |
| **`fnStringParseGermanDecimal`** | 1:1 + SCHEMABINDING **+ BEWUSST REFAKTORIERT (F4.4: US-Format→NULL)** | **funktional** T4-10b + T6 (US→NULL) | `port-audit:8`, `fn…:24-43` |
| **`spArticleAppendPriceHistory`** | **REFAKTORIERT** (Scaffolding raus, VAT dynamisch) — **CSV-Output-Block aber byte-identisch** | HistorySPs-Suite (Format) + T4-08b live | `port-audit:25 (Abw.#1,#14)` |
| **`spArticleAppendLabelHistory`** | **REFAKTORIERT** (Scaffolding raus, Label-Sanitize) — CSV-Output-Block byte-identisch | HistorySPs-Suite + T4-08 | `port-audit:24 (Abw.#1,#13)` |
| `spArticleUpdateAllHistory` | **1:1** | HistorySPs-Suite (UpdateAll-Fall) | `port-audit:26` |
| `fnGetArticleCustomFieldValue` | **1:1** (Body identisch) | CustomFieldAPI-Suite | `port-audit:1` |
| `spEnsureArticleCustomField` / `spSetArticleCustomFieldValue` | REFAKTORIERT (Error-Kontrakt: returnCode→THROW) | CustomFieldAPI-Suite + T4-07 | `port-audit:2-3 (Abw.#1,#2)` |
| `fnFindDuplicateOrders` / `fnHasOlderDuplicateOrder` / `spCheckDuplicateOrder` | **1:1 (Body byte-genau)** | DuplicateOrders-Suite + T4-09 | `port-audit:13-15` |
| PayPal-Tabellen + `spPaypal*` | 1:1 bzw. leicht refakt. — **danach via up/0003 GEDROPPT** | T4-06 (Drop verifiziert) | `port-audit:16-23` |
| `spGebindeErstellen` / `spZustandartikelLieferantSetzen` | REFAKTORIERT (Einheit-Auflösung, Idempotenz-Fix F4.6) | GebindeErstellen-Suite + T4-02/04 | `port-audit:27` |

**Kernaussage für die Read-Mechanik:** Der **Ordinal-Parser
`fnEscapedCSVParseLine` ist 1:1** portiert (nicht „komplett überarbeitet"); die
einzige **bewusste Verhaltensänderung** im Parse-Pfad ist der **F4.4-Fix** an
`fnStringParseGermanDecimal`. Die History-SPs sind zwar als SP refaktoriert
(Transaktions-Scaffolding entfernt, VAT-/Sanitize-Logik verbessert), ihr
**geschriebener CSV-Block ist jedoch byte-identisch** (in Abschnitt 1 per `diff`
belegt). Damit ist die Format-Kompatibilität der Leseseite **nicht** über
Byte-Gleichheit der SPs, sondern über **(a) Byte-Gleichheit des Output-Blocks +
(b) funktionale Suiten** abgesichert — sauber differenziert.

## B.3 Prüfmechanik `compare-objects.sql` (T1-16 / Adopt-Szenario)

`db-migrations/tests/compare-objects.sql` ist das **Definitions-Hash-Werkzeug**
(SHA2-256 über `OBJECT_DEFINITION`, DB↔DB) für `Robotico` +
`CustomWorkflows.sp*`-Aktionen mit korrekter D10-Eigentumsgrenze
(`schema-parity-flow-robotico.md:120-128`). Es deckt **programmierbare Objekte**
ab, **nicht** Tabellenstruktur (emittiert dort `NULL` — deshalb der ergänzende
4-Sektionen-Diff in B.1). Im Docker-E2E lieferte derselbe Ansatz den
**Definitions-Fingerprint** `0xD243… → 0xAD3A…` beim A2b-Refresh und bewies damit,
dass die **Repo-Objekte dem Jul-08-Prod-Backup 7 Objekte VORAUS** waren
(`e2e-docker-report.md:69-80`) — d.h. die Ebene-A-Definitionen sind die
aktuelleren, refaktorierten Fassungen (konsistent mit B.2, gegen eine reine
Byte-Copy-Erwartung).

## B.4 P3 — Reset-Daten/Security-Parität (25 Assertions, `e2e-docker-report.md:193-219`)

Orthogonal zur Objekt-Parität: **25/25 PASS** über Anonymisierung,
Credential-Löschung, Shop-Repoint, JTL-Rollen, Register-Mandant, Idempotenz
(2. Reset) **und** Quell-Unversehrtheit (S1-S4: `tkunde`/`tAdresse`/eBay/`tQueue`
der Quelle unverändert). Belegt die **Daten**-Garantien der Pipeline, nicht die
Objekt-Treue der Portierung.

## B.5 Ehrliche Paritäts-Lücken

1. **Kein automatisierter Definitions-Diff Alt↔Neu im CI.** Die Port-Treue (P2)
   ist per **manuellem** zeilengenauem Audit (2026-07-15) belegt, nicht durch
   einen wiederholbaren Test — ein späteres Abdriften einer Ebene-A-Datei von
   ihrer dokumentierten Absicht würde nicht automatisch auffallen.
2. **Zwei registrierte Aktionen NICHT portiert** (`spAuftragPreiseAufNull`,
   `spSeriennummerStandardZuWMS`) — als „ad-hoc/experimental" ausgeschlossen,
   obwohl benannte, registrierte Actions. **[Regression/Lücke]**, Live-Status
   read-only nicht klärbar (`qg3/port-coverage.md:93-131, 176-181`). Betrifft
   nicht die History-Read-Mechanik, ist aber die einzige offene Port-Frage.
3. **P1-Klon-Parität an einem Klon** (`tm9`, 2026-07-15) verifiziert — als
   Struktur-Beweis des `RESTORE`-Prinzips ausreichend, aber kein Dauer-Monitoring.
4. **Reihenfolge-Nachweis der Leseseite** ruht auf dem **Format-Kontrakt**, nicht
   auf einem Reader×Writer-Integrationstest, der SP-Schreiben und View-/Reader-
   Lesen in einem Lauf verkettet (der wäre der stärkste Regressionsschutz und
   fehlt — s. Empfehlung).

## B.6 Empfehlung (Absicherung härten)

- **Reader×Writer-Integrationstest** ergänzen: `spArticleAppendPriceHistory` gegen
  einen Fixture-Artikel ausführen, dann `RoboticoEKL.vArtikelPreisHistory_V1`
  **und** die Preisrecherche-Parse-Pipeline lesen und Feld-für-Feld gegen die
  geschriebenen Werte prüfen — schließt Lücke A.4/B.5-4 in einem Lauf.
- **Definitions-Hash Alt↔Neu** als einmaligen Lint/Snapshot einfrieren, damit
  P2-Drift künftig auffällt (B.5-1).
