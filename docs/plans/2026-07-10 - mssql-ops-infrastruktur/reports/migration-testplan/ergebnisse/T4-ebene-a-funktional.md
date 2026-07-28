# Ergebnis — T4 Ebene-A-Inhalte (funktionaler Vollabdeckungstest)

**Ausgeführt:** 2026-07-27, Detail-Agent T4 (Opus), echte Ausführung gegen Container
`robotico-e2e-mssql` (`localhost,14330`, Env E2E, SQL-Auth sa, Developer Edition).
**DB:** `eazybusiness` (tVersion **2.0.5.0**), Ebene A voll deployt, PayPal-Drop wirkt.
**Guard:** `_e2e_guard.sql` als Kopf jedes Skripts — feuerte durchgehend
`E2E-GUARD ok: 3c2b38585482 / Developer Edition` (Container durchgelassen, kein PROD-Ziel).
**Endzustand:** **GRÜN** — Scratch-DBs gedroppt, `eazybusiness` unverändert (alle Tests
transaktions-gerollt), `db:validate:e2e` = **Rollout validation OK**. Keine Commits, keine
Server-Writes außerhalb des Containers, PayPal-Staging unangetastet.

## Gesamtergebnis

| Status | Fälle |
|---|---|
| **PASS** | T4-01, T4-02(a-c), T4-02e, T4-03(a-c), T4-03b, T4-03c, T4-04(a-d), T4-05(a-f), T4-06(a-c), T4-07a, T4-08a, T4-08b, T4-09b, T4-09c, T4-10a, T4-10c, T4-11, T4-14, T4-15, T4-16 |
| **THROW-OK** | T4-02d (50000), T4-05g (50001), T4-08d (Custom field definition not found) |
| **EXPECTED-FAIL (reproduziert)** | T4-02/F4.6, T4-10b/F4.4, T4-12/F4.1 |
| **EXPECTED-FAIL (nicht reproduziert)** | T4-09a/F4.5, T4-13/F4.3 |
| **SKIP** | T4-07b, T4-07c, T4-08c |
| **FAIL (echt)** | — keine — |

**Zähler:** PASS 21 · THROW-OK 3 · EXPECTED-FAIL-reproduziert 3 · EXPECTED-FAIL-nicht 2 · SKIP 3 · FAIL 0.

## Live-Vorabklärungen (bestätigt/korrigiert)

1. **CONTEXT_INFO-Bypass — `0x5123` bestätigt (Positionen)**, **plus eine unerwartete zweite Klärung
   (Kopf-Tabelle).** Der Guard-Trigger `tgr_tlieferantenBestellungPos_INSUPDEL` akzeptiert
   `CONTEXT_INFO() IN (0x5123, 0x5124, 0x5125, 0x5129, <spUpdate…FreiPos>)` — **`0x5123` reicht**,
   `0x5124` war nicht nötig. **Zusätzlicher Befund:** auch die **Kopf-Tabelle** `tLieferantenBestellung`
   trägt einen eigenen Guard-Trigger `tgr_tlieferantenBestellung_INSUPDEL` mit **eigener** Konstanten-
   liste (`0x5120`/`0x5121 = Erstellen`/`0x5122`/`0x5126`…). Das Seed-INSERT des Bestell-**Kopfes** muss
   daher **vor** dem Positions-Insert mit `SET CONTEXT_INFO 0x5121` abgesichert werden — sonst rollbackt
   der Kopf-Trigger und doomt die Transaktion (Fehler 3930). Im Testplan (T4-05/14/15) war nur der
   Positions-Bypass vorgesehen; der Kopf-Bypass ist eine notwendige Ergänzung.
2. **THROW doomt die Transaktion.** `EXEC …VpeCheck @kLieferantenBestellung=NULL` wirft THROW 50001;
   ein *gefangener* THROW setzt jedoch `XACT_STATE() = -1` (uncommittable). Der NULL-Key-Test (T4-05g)
   muss daher in **eigenem Batch/eigener Transaktion** laufen, nicht im selben `BEGIN TRAN` wie das Seed —
   sonst scheitern die nachfolgenden Seed-Inserts mit 3930. Umgesetzt.
3. **Guard-Trigger-Existenz (T4-16, read-only Probe).** `sys.triggers` auf die direkt geschriebenen
   Artikel-/Bestands-Tabellen:
   | Tabelle | Trigger |
   |---|---|
   | `tArtikel` | `jtlActionValidator_tartikel`, `tgr_tartikel_INSUP`, `tgr_tArtikel_Sync_DEL`, `tgr_tArtikel_Sync_INSUP` |
   | `tGebinde` | `tgr_tGebinde_INSUP`, `tgr_tGebinde_DELETE` |
   | `tliefartikel` | `tgr_tliefartikel_INSUP`, `tgr_tliefartikel_DELETE` |
   | `tLagerArtikel` | **keine** |
   Es sind **Sync-/Validator-Trigger, keine Rollback-Guards** wie auf `tLieferantenBestellung(Pos)`:
   T4-02/03/04 schreiben `tArtikel`/`tLiefArtikel`/`tGebinde`/`tLagerArtikel` **direkt** und liefen
   **PASS** — das ist der funktionale Live-Beweis, dass die Direkt-Writes durchgehen (ein Rollback-Guard
   hätte sie gekippt).
4. **NOT-NULL-Spalten (ohne Default) aus dem Klon ergänzt** (Quelle: `sys.columns`, nicht Referenz-DDL —
   exakter). Ergänzt gegenüber dem Testplan:
   - `Verkauf.tAuftragPosition`: `fVkNettoGesamt`, `fVkBruttoGesamt`
   - `Rechnung.tRechnung`: `cFirma`, `cVersandlandWaehrung`, `fVersandlandWaehrungsfaktor`, `cWaehrung`, `nSteuereinstellung`
   - `Rechnung.tRechnungPosition`: `fAnzahl`, `fMwSt`, `fVkNetto`, `fRabatt`, `nType`, `fVkNettoGesamt`, `fVkBruttoGesamt`
   - `dbo.tLieferantenBestellung`: `kSprache`, `cWaehrungISO`
   - (`tLieferantenBestellungPos`, `tLagerArtikel`, `tArtikelAttribut` benötigten keine zusätzlichen Spalten)
   - `tlagerbestand`-Spalten (T4-15): `fVerfuegbar`, `fZulauf`, `fLagerbestand` bestätigt.
5. **Keine `'Inland'`-Steuerzone im Klon** (`tSteuerzone` enthält nur `Zone Deutschland`, `Zone Österreich`,
   … / `Zone-Nicht-EU`). Der 19 %-Fallback der Preishistorie ist damit der **default-aktive** Pfad — der
   im Testplan vorgesehene temporäre `Inland`-Rename für T4-08b entfällt (nichts umzubenennen).

---

## Gruppe A — Vollabdeckung der 5 testlosen Aktionen

### T4-01 `spAuftragPreiseAufNull` — **PASS**
- a) nicht-fakturierte Positionen auf `fEkNetto=0`/`fVkNetto=0` genullt — **+**
- b) fakturierte Position (via `Rechnung.tRechnungPosition`-Zeile) geschützt (`fVkNetto=50`/`fEkNetto=10`) — **+**
- c) `Verkauf.spAuftragEckdatenBerechnen` (TVP) lief fehlerfrei — **+**

### T4-02 `spGebindeErstellen` — **PASS** (Kern) + **EXPECTED-FAIL (reproduziert)** F4.6
Testartikel dynamisch (kArtikel 14554, Single-Supplier-HAN-Match).
- a) genau eine `tGebinde`-Zeile erzeugt — **+**
- b) HAN suffigiert `-gebinde-umgezogen` — **+**
- c) `tGebinde.cName` trägt die per-Name aufgelöste `Stk.`-Einheit-ID (nicht Literaltext) — **+**
- **F4.6 (Nicht-Idempotenz) REPRODUZIERT:** Zweitlauf in derselben Transaktion →
  **2** `tGebinde`-Zeilen + doppeltes Suffix `14554-gebinde-umgezogen-gebinde-umgezogen`. Befund belegt,
  nicht gefixt.

### T4-02d fehlende `Stk.`-Einheit → **THROW-OK** (50000)
`tEinheitSprache.cName='Stk.'` temporär umbenannt → `THROW 50000 'Unit "Stk." not found …'` — **+**.
(Harness-Notiz: der proc-eigene CATCH rollbackt die gesamte Transaktion inkl. Rename; der nachfolgende
äußere `ROLLBACK` meldet kosmetisch „no corresponding BEGIN TRANSACTION" — kein Rückstand,
Rename in der Endkontrolle nachweislich weg.)

### T4-02e Flag-Zweig (≥2 Lieferanten) — **PASS**
Artikel mit ≥2 `tLiefArtikel` → `cHAN LIKE '%-keine-Lieferanten-angepasst'`, Lieferanten unangetastet — **+**.

### T4-03 `spSeriennummerStandardZuWMS` — **PASS**
Seeds (Lager 6 = 2 Std-Serien, Lager 17 = 2 Platzhalter `#$KEINE$#`), genug Platzhalter:
- a) Serien auf WMS-Platzhalter kopiert — **+**
- b) Quell-Standardzeilen `-StandardLager`-suffigiert — **+**
- c) Platzhalter verbraucht — **+**

### T4-03b zu wenig Platzhalter → **PASS** (No-Op)
3 Std-Serien / 1 Platzhalter → `@kCountStandardlager > @kCountWMSLager` → IF-Block übersprungen,
alle 3 Std-Serien unverändert, Platzhalter bleibt `#$KEINE$#` — **+**.

### T4-03c Quasi-Idempotenz → **PASS**
Zweitlauf nach erfolgtem Move findet keine unsuffigierten Std-Serien mehr → State identisch (No-Op) — **+**.

### T4-04 `spZustandartikelLieferantSetzen` — **PASS** (QUOTED_IDENTIFIER ON)
Zustandsartikel dynamisch (83 Kandidaten im Klon):
- a) `cLiefArtNr` = HAN gesetzt (bereits-suffigiert-Zweig) — **+**
- b) Zweitlauf: Suffix nicht verdoppelt (idempotent) — **+**
- c) NULL-Clear: `cHAN=''` → `cLiefArtNr` auf NULL geräumt (`tArtikel`-UPDATE ging trotz Validator-Trigger durch) — **+**
- d) `kZustand=1`-Standard-Zustand unangetastet — **+**

### T4-05 `spVpeCheckLieferantenbestellung` — **PASS** (a-f) + **THROW-OK** (g)
Seed via Vendor-Pfad (Kopf `0x5121`, Positionen `0x5123`), Lieferant 2 / VPE-Artikel 268
(nVPEMenge=100, fEKNetto=1.0864) / Non-VPE-Artikel 214. Live-Ausgabe:
`h1=[{{VPE=100}} Zubehör]  h2=[{{VPE=100, VPE Error Preis 2.17>>1.09}} Ersatzteile]  h3=[Zubehör2]  fremd=[TESTBELEG-VPE {{VPE Error}}]`
- g) NULL-Key → **THROW 50001** — **+** (eigener Batch, s. Vorabklärung 2)
- a) Pos1 OK-Marker `{{VPE=100}}` + Basistext erhalten — **+**
- b) Pos2 Error-Marker `{{VPE=…, VPE Error Preis …>>…}}` — **+**
- b2) Kopf-Marker ` {{VPE Error}}` an `cFremdbelegnummer` angehängt — **+**
- c) Pos3 (Non-VPE) unverändert `Zubehör2` — **+**
- d) Idempotenz: Zweitlauf identisch, Marker stapeln nicht — **+**
- e) Preis-Fix auf Pos2 → Error-Marker aus Position + Kopf entfernt — **+**
- f) VPE-Verlust (Pos1 auf Non-VPE) → Marker vollständig gestrippt, Basisnotiz `Zubehör` wiederhergestellt — **+**

*(Zusatz-Guards cHinweis-2000-Kappung / cFremdbelegnummer-255-Kappung: nicht separat ausgeführt — die
Marker-Setz-/Clear-Logik ist über a-f belegt; die Längen-Kappung ist reiner String-`LEFT()`-Zweig.)*

---

## Gruppe B — up/0003 PayPal-Drop

### T4-06 — **PASS**
- a) alle 5 Procs + 3 Tabellen (`spPaypal*`/`tPaypal*`) weg — **+**
- b) Schema `Robotico` + Nicht-PayPal-Objekte (`fnFindDuplicateOrders`) intakt — **+**
- c) `DROP … IF EXISTS`-Re-Run gegen abwesende Objekte harmlos — **+**

---

## Gruppe C — Lücken der bestehenden Suiten

### T4-07a Self-Healing Binding (QG3-B6) — **PASS**
Binding-Zeile ohne Sprachzeile angelegt → `spEnsureArticleCustomField(@kSprache=0)` findet Binding
(kein 2627), heilt fehlende Sprachzeile, rc=0; Zweitaufruf stabil (kein 2627) — **+ / +**.

### T4-07b `kSprache<>0` — **SKIP**
Klon hat nur **eine** `tSpracheUsed`-Zeile (`kSprache`-Def der Freifelder nur für `kSprache=0`);
keine zweite Sprache auflösbar ohne synthetische Stammdaten. Nicht als FAIL gewertet (Fixture-Lücke).

### T4-07c Race-2627 — **SKIP**
Echte Nebenläufigkeit im Transaktions-Harness nicht erzwingbar; im Testplan selbst als Code-Review-/
optionaler Zwei-Session-Lasttest markiert. Ausgelassen.

### T4-08a 1000-Zeilen-Trim — **PASS**
Freifeld mit **1010** Zeilen vorbelegt, Preis geändert → Aktion hängt an → **1011** → Trim (`>1000+10`)
→ Ergebnis exakt **1000** Zeilen; jüngster Eintrag (`123,45`) erhalten, älteste entfernt — **+ / +**.

### T4-08b Steuerzone-Fallback 19 % — **PASS**
Keine `Inland`-Zone im Klon → `@vatRate` fällt auf 0.19, kein THROW. Letzter Eintrag:
`27.07.2026 …; 123,45; 146,91; Puffer 0; T4` → Brutto-Feld `146,91` = netto·1.19 — **+ / +**.

### T4-08c 7 %-Satz — **SKIP**
Weder `Inland`- noch reduzierte Inland-Zone im getrimmten Klon vorhanden → kein 7 %-Pfad testbar
(Fixture-Lücke, nicht FAIL).

### T4-08d fehlende Freifeld-Definition → **THROW-OK**
`tAttributSprache.cName='Vergangene Preise'` temporär umbenannt → `spEnsureArticleCustomField`
propagiert THROW `… Custom field definition not found …` — **+**.

### T4-09a Freiposition NULL-Fingerprint (F4.5) — **EXPECTED-FAIL (nicht reproduziert)**
Zwei Aufträge, je eine Freiposition mit `kArtikel NULL` **und** `cArtNr NULL`, gleiches Fenster/Brutto:
`fnHasOlderDuplicateOrder = 0` — **keine Kollision**. Ursache empirisch nachgewiesen:
`COALESCE(CAST(kArtikel AS NVARCHAR),'F:'+cArtNr) = NULL` → `STRING_AGG` über nur NULL = NULL →
`HASHBYTES('SHA2_256', NULL) = NULL` → beide Fingerprints **NULL** → Join `fc.Fingerprint = ft.Fingerprint`
ist `NULL = NULL` = **UNKNOWN** → kein Match. **Positiv-Kontrolle** (zwei Aufträge mit identischer
*realer* Position) liefert korrekt `= 1` → die Engine funktioniert; die im Testplan angenommene
**Richtung** des Findings (falsch-positive Kollision) ist durch die ANSI-NULL-Semantik ausgeschlossen.
Der reale Restrisiko-Randfall ist die **Gegenrichtung** (solche Aufträge werden *nie* als Duplikat
erkannt = falsch-negativ) — kein Proc-Change, sondern eine Präzisierung des Findings.

### T4-09b nType-Filter — **PASS**
Auftrag mit nur nType-2-Position → keine Fingerprint-Zeile → `fnHasOlderDuplicateOrder = 0` trotz
identischem Zwilling — **+**.

### T4-09c Test-8-Umgebungsunabhängigkeit — **PASS (belegt)**
Synthetisches Zwillingspaar mit realer Position → `fnHasOlderDuplicateOrder = 1` (Positiv-Kontrolle in
T4-09a-Probe). Belegt, dass der Listen-/Erkennungs-Check ohne reale Seed-Aufträge 236/237 grün läuft.

### T4-10 Parser-Randfälle — **PASS** (a,c) + **EXPECTED-FAIL (reproduziert)** F4.4 (b)
- a) `fnStringTrimToMaxLines` über nur-Leerzeilen → **NULL** — **+**
- b) **F4.4 REPRODUZIERT:** `fnStringParseGermanDecimal('1,234.56')` → **`1.2345600000000`** (stiller
  Falschwert statt NULL) — Befund belegt.
- c) `fnEscapedCSVGetLastLine(CRLF)` → **NULL** — **+**

---

## Gruppe D — Struktur-Fehlerfälle

### T4-11 Modul-Registrierungs-Trailer (F4.1) — **PASS**
`_CheckAction`/`_SetActionDisplayName` sind im Klon **vorhanden** (Modul gebucht) — der „missing"-Pfad
ist gegen `eazybusiness` nicht direkt reproduzierbar. Belegt stattdessen: (1) die Aktions-Procs sind
unabhängig vom Modul deployt (`OBJECT_ID … IS NOT NULL`); (2) der guarded `IF … ELSE PRINT`-Trailer
gegen einen absichtlich nicht existenten Helper druckt die Warnung und bleibt **grün** (kein THROW) —
die F4.1-Semantik. — **+**

### T4-12 Schema `CustomWorkflows` fehlt (F4.1) — **EXPECTED-FAIL (reproduziert)**
Scratch-DB `T4_scratch` (ohne Schema) → `CREATE … PROCEDURE CustomWorkflows.spT4Probe` scheitert mit
**Fehler 2760** (`The specified schema name "CustomWorkflows" … does not exist`). Befund belegt: Ebene A
setzt eine JTL-DB **mit** dem Modul-Schema voraus. Offene Klärungsfrage (defensives `CREATE SCHEMA` vs.
dokumentierte Voraussetzung) unverändert.

### T4-13 STRING_SPLIT-Ordinal-Compat-Floor (F4.3) — **EXPECTED-FAIL (nicht reproduziert)**
Scratch-DB `T4_compat`: ordinaler `STRING_SPLIT(@s, ',', 1)` **funktioniert bei Compat 150** (rows=3),
nicht — wie im Testplan angenommen — erst ab 160. Bei **Compat 120** ist `STRING_SPLIT` selbst ungültig
(Msg 208 `Invalid object name 'STRING_SPLIT'`). Der tatsächliche Floor ist somit **Compat 130** (Existenz
von `STRING_SPLIT`); die `enable_ordinal`-Form läuft ab 130/150 mit. Die `eazybusiness` läuft auf
**Compat 160** → **kein** Laufzeitrisiko. F4.3 in der behaupteten 160-Form damit widerlegt (Compat
sauber zurück auf 160 gesetzt).

---

## Gruppe E — Trigger-Interaktionen

### T4-14 Direkt-UPDATE am Guard-Trigger — **PASS**
Position via Bypass geseedet, `CONTEXT_INFO` gelöscht, dann direktes
`UPDATE dbo.tLieferantenBestellungPos SET cHinweis='DIRECT'` → Guard-Trigger wirft
`Die Tabelle tlieferantenBestellungPos kann nur über die SPs … bearbeitet werden.` + ROLLBACK — **+**.
Belegt, warum die VPE-Aktion den sanktionierten Vendor-SP-Pfad nutzt.

### T4-15 VPE-Lauf ohne Bestands-Seiteneffekt — **PASS**
`tlagerbestand`-Snapshot der beteiligten Artikel vor/nach `spVpeCheck` (der nur `cHinweis`/Kopf ändert)
identisch (`fVerfuegbar`/`fZulauf`/`fLagerbestand`) — **+**.

### T4-16 Guard-Trigger-Probe — **PASS** (dokumentiert, s. Vorabklärung 3)

---

## Endkontrolle (Umgebung sauber)

- Scratch-DBs `T4_scratch` / `T4_compat` **gedroppt**.
- Residue-Check: `Stk.`-Einheit vorhanden & keine `-T4BLOCK`-Reste, `Vergangene Preise`-Def vorhanden &
  keine Reste, **0** Test-Aufträge (`T4-*`/`F45-*`), **0** Test-Lieferantenbestellungen, **0** Test-Serien,
  keine `-T4`-Steuerzonen. Die **eine** `-gebinde-umgezogen`-Zeile (`kGebinde 9983`, `kArtikel 17984`,
  `TestHanTest2-gebinde-umgezogen-umgezogen-umgezogen`) ist **prä-existente Prod-Testdaten aus dem
  Restore-Backup** (mein T4-02 nutzte `kArtikel 14554`, gerollt) — **kein** Testrückstand.
- `tVersion` = **2.0.5.0** unverändert.
- `npm run db:validate:e2e` → **Rollout validation OK** (structure / rollout / roundtrip).
