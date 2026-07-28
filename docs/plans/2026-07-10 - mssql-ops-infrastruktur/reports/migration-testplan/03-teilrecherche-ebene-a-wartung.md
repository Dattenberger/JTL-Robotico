# Teilrecherche: Ebene A (eazybusiness-Kette) + Wartungssuite — Fehlerfall-Analyse

> Rohbefund eines delegierten Research-Agenten (2026-07-27), unverändert übernommen.
> Eingang für `00-grundrecherche.md` (Konsolidierung durch den Lead-Agenten).

## 1. Ebene A — Objektinventar

### up/-Kette

- **`up/0001_robotico_schema.sql:20-28`** — `IF NOT EXISTS … EXEC('CREATE SCHEMA Robotico')`. Idempotent, PRINT-Feedback.
- **`up/0002_robotico_paypal_tables.sql`** — 3 Tabellen `Robotico.tPaypalAccessToken/tPaypalTrackingLog/tPaypalSettings` (je `IF OBJECT_ID … IS NULL`, Z. 21, 40, 58) + Settings-Seed via `MERGE … WHEN NOT MATCHED` (Z. 103-108; nie Overwrite). Bleibt immutable im Journal, obwohl 0003 alles wieder droppt.
- **`up/0003_drop_paypal_mechanic.sql` (UNTRACKED)** — droppt exakt:
  - Procs (Z. 41-45): `CustomWorkflows.spPaypalTrackingVersand`, `CustomWorkflows.spPaypalTrackingLieferschein`, `Robotico.spPaypalTrackingCallApi`, `Robotico.spPaypalGetAccessToken`, `Robotico.spPaypalCreateAccessToken`
  - Tabellen (Z. 54-56): `Robotico.tPaypalTrackingLog`, `tPaypalAccessToken`, `tPaypalSettings`
  - **Idempotenz: ja** — durchgängig `DROP … IF EXISTS`; robust auch gegen bereits fehlende Objekte und Klone ohne die Objekte. Kein Clone-Guard, bewusst (Z. 15-18). Begründung für up/ statt Datei-Löschung: up läuft VOR dem anytime-Pass, sonst würden gelöschte sprocs re-created (Z. 8-11). Pre-Flight-Hinweis: Workflows kWorkflow 127/128/129 müssen vorher in der Wawi-UI deaktiviert sein, sonst nicht-fataler Workflow-Fehler je Lieferschein-Event (Z. 24-30).

### functions/ (alle `CREATE OR ALTER`, anytime-idempotent)

| Objekt | Tut | Liest/Schreibt Vendor | Engine-Anmerkung |
|---|---|---|---|
| `fnEscapedCSVSanitize` | entfernt `;`, Quotes, CR/LF; leer→Default/NULL | — (SCHEMABINDING, pur) | — |
| `fnEscapedCSVParseLine` | iTVF: Zeile → (ordinal, value), getrimmt | — | **`STRING_SPLIT(…, 1)` = SQL 2022+ Floor** (Header Z. 11-15: CREATE gelingt auf älterer Engine, **Runtime-Fail**) |
| `fnEscapedCSVGetField` | 1 Feld per ordinal (Wrapper über ParseLine) | — | erbt 2022-Floor |
| `fnEscapedCSVGetLastLine` | letzte Zeile, trailing CR/LF gestrippt | — | — |
| `fnStringCountLines` | LF-Zählung; NULL/leer=0; trailing LF zählt +1 | — | — |
| `fnStringIsEffectivelyEmpty` | NULL/Whitespace-only → 1 | — | — |
| `fnStringParseGermanDecimal` | `1.234,56` → DECIMAL(25,13), invalid→NULL (TRY_CAST) | — | — |
| `fnStringStripWhitespace` | entfernt Tab/CR/LF, Spaces bleiben | — | — |
| `fnStringTrimToMaxLines` | letzte N Zeilen, Leerzeilen gefiltert, CRLF-join | — | **`STRING_SPLIT(…,1)` Z. 41 = 2022-Floor** |
| `fnFindDuplicateOrders` | iTVF, 3-stufig: Kunde+Zeitfenster(±24h)+Bruttowert-Vorfilter, dann SHA2_256-Positions-Fingerprint (nur nType 0,1); Tie-Break bei gleichem Timestamp über kAuftrag (Z. 88-92) | liest `Verkauf.tAuftrag`, `Verkauf.tAuftragEckdaten`, `Verkauf.tAuftragPosition` | STRING_AGG/HASHBYTES = 2017+; kein ordinal-Split |
| `fnHasOlderDuplicateOrder` | BIT: existiert ÄLTERES Duplikat? (Workflow-Bedingung "Ist Duplikat") | via fnFindDuplicateOrders | — |
| `fnGetArticleCustomFieldValue` | Read Freifeld-Wert (kShop=0, kSprache, nIstFreifeld=1) | liest `dbo.tArtikelAttribut`, `tAttribut`, `tArtikelAttributSprache`, `tAttributSprache` | — |

**Engine-Floor Ebene A: SQL Server 2022+ (16.x)** — SSoT `db-migrations/README.md:420-427`; betroffen: ParseLine, GetField (transitiv), TrimToMaxLines, `spArticleAppendLabelHistory.sql:77` (`STRING_SPLIT(@lastLabels, ',', 1)`). CREATE gelingt überall, Fail erst zur Laufzeit → **Testfall: Klon mit niedrigerem Compat-Level**.

### sprocs/

| Objekt | Tut | Vendor-Objekte |
|---|---|---|
| `Robotico.spEnsureArticleCustomField` | ensured Binding+Sprachzeile selbstheilend (2 Schritte, kein Runtime-TX, Race 2627/2601 abgefangen, Z. 73-89/110-115); fehlende Freifeld-Definition → RAISERROR 16 → THROW (Z. 51-56) | schreibt `dbo.tArtikelAttribut`, `dbo.tArtikelAttributSprache`; liest `tAttribut`, `tAttributSprache` |
| `Robotico.spSetArticleCustomFieldValue` | public write: ensure + UPDATE `cWertVarchar` | schreibt `dbo.tArtikelAttributSprache` |
| `Robotico.spCheckDuplicateOrder` | Wahrheit 3-fach: ResultSet + OUTPUT + RETURN | via fn |
| `CustomWorkflows.spArticleAppendPriceHistory` | Preis/Puffer-Historie ins Freifeld 'Vergangene Preise'; MwSt per Steuerzone `'Inland'` aufgelöst, Fallback 19 % (Z. 66-75); Änderungsdetektion Netto±0.001 + Puffer; Trim auf 1000 Zeilen | liest `dbo.tArtikel`, `tSteuersatz`, `tSteuerzone`; schreibt `tArtikelAttributSprache` |
| `CustomWorkflows.spArticleAppendLabelHistory` | Label-Set-Historie 'Vergangene Label'; Kommas gestrippt, Sanitize, stabile Sortierung für Change-Detection | liest `dbo.tArtikelLabel`, `dbo.tLabel`; schreibt `tArtikelAttributSprache` |
| `CustomWorkflows.spArticleUpdateAllHistory` | ruft beide, je TRY/CATCH, Fehler als Severity-10-RAISERROR (nicht fatal) | transitiv |
| `CustomWorkflows.spAuftragPreiseAufNull` | fEkNetto/fVkNetto=0 auf nicht fakturierte Positionen, dann `Verkauf.spAuftragEckdatenBerechnen` via TVP `Verkauf.TYPE_spAuftragEckdatenBerechnen` (Z. 34-36) | schreibt `Verkauf.tAuftragPosition`; liest `Rechnung.tRechnungPosition`; EXEC Vendor-SP |
| `CustomWorkflows.spGebindeErstellen` | tGebinde-Zeile aus HAN/GTIN; Einheit 'Stk.' per Name aufgelöst, fehlend → THROW 50000 (Z. 73-76); Suffix `-gebinde-umgezogen` bzw. `-keine-Lieferanten-angepasst`; explizite TX | liest/schreibt `dbo.tArtikel`, `dbo.tLiefArtikel`; schreibt `dbo.tGebinde`; liest `dbo.tEinheitSprache` |
| `CustomWorkflows.spSeriennummerStandardZuWMS` | Seriennummern Lager 6 → WMS-Platzhalterzeilen (Lager 17, `'#$KEINE$#'`), nur wenn genug Platzhalter; Quelle suffigiert `-StandardLager`; hartkodierte Lager-IDs 6/17 (Header Z. 12-13) | liest/schreibt `dbo.tLagerArtikel` direkt |
| `CustomWorkflows.spZustandartikelLieferantSetzen` | cLiefArtNr = HAN(+Zustands-Suffix) bzw. NULL, kZustand<>1; single UPDATE, QUOTED_IDENTIFIER-Pflicht wegen gefilterter Indizes (Header Z. 10-12) | schreibt `dbo.tliefartikel`; liest `dbo.tArtikel`, `dbo.tZustand` |
| `CustomWorkflows.spVpeCheckLieferantenbestellung` (NEU/UNTRACKED) | VPE-Marker `{{VPE=n}}` / `{{VPE=n, VPE Error Preis a>>b}}` in Pos-cHinweis + Head-Marker `{{VPE Error}}` in cFremdbelegnummer; Positionsschreiben über Vendor-SP `Lieferantenbestellung.spLieferantenBestellungPosBearbeiten` (XML-Batch) wegen Guard-Trigger `tgr_tlieferantenBestellungPos_INSUPDEL` (CONTEXT_INFO-Magic, Header Z. 49-65); Head per Direkt-UPDATE (ungated) | liest `dbo.tLieferantenBestellung(Pos)`, `dbo.tLiefArtikel`; schreibt via Vendor-SP + Head-UPDATE |

**Custom-Action-Mechanik** (`docs/SQL/JTL-CUSTOM-WORKFLOWS.md`): 1. Parameter = PK des Workflowobjekts, Typ `int`; max. 7 Parameter (1 PK + 6); erlaubte Datentypen in `CustomWorkflows.tAllowedDatatypes`; Registrierung = strukturell + `_SetActionDisplayName` (Extended Property `DisplayName`); `_CheckAction` ist reiner Validator. Alle Actions erfüllen das (PK-first int; 2. Param `@userName NVARCHAR(100)` bei den History-SPs).

## 2. Ebene A — Fehlerfälle für den Testplan

**a) Custom-Workflow-Modul nicht gebucht (fehlende `_CheckAction`/`_SetActionDisplayName`):** Alle 8 CustomWorkflows-Dateien guarden beide Aufrufe per `IF OBJECT_ID(…) IS NOT NULL … ELSE PRINT '!…'` (z. B. `spAuftragPreiseAufNull.sql:42-52`, `spVpeCheck…sql:266-277`). **Erwartung: Deploy läuft grün durch, nur PRINT-Warnung.** Testfall: Deploy gegen DB ohne `CustomWorkflows._*`-Infrastruktur → kein Fehler; Deploy gegen DB ganz ohne Schema `CustomWorkflows` → **CREATE PROCEDURE schlägt fehl** (Schema wird von Ebene A nirgends angelegt — implizite Annahme "JTL + Modul-Schema existiert"; kein Skript gefunden, das `CustomWorkflows` als Schema anlegt).

**b) Fehlende JTL-Vendor-Objekte (Create-Time vs. Runtime):**
- `fnFindDuplicateOrders` referenziert `Verkauf.*` — Funktionen haben KEINE deferred name resolution → CREATE schlägt auf einer Nicht-JTL-DB fehl. Gleiches für `fnGetArticleCustomFieldValue` (dbo.tAttribut…).
- `spAuftragPreiseAufNull` deklariert den Tabellentyp `Verkauf.TYPE_spAuftragEckdatenBerechnen` (Z. 34) — Typ muss beim CREATE existieren.
- Procs mit reinen Tabellenreferenzen (deferred resolution) failen erst zur Laufzeit.
- `spVpeCheck…` EXEC-t `Lieferantenbestellung.spLieferantenBestellungPosBearbeiten` (Z. 212) — fehlt der Vendor-SP, Runtime-Fehler 2812.

**c) Trigger-/Fremdbeleg-Interaktionen:**
- `tgr_tlieferantenBestellungPos_INSUPDEL` rollbackt Direkt-Writes ohne CONTEXT_INFO-Magic — deshalb der Vendor-SP-Pfad (`spVpeCheck…sql:52-65`). Testfall: Direkt-UPDATE auf `tLieferantenBestellungPos` muss scheitern; SP-Pfad muss durchgehen; `cFremdbelegnummer`-Head-UPDATE ist ungated (Z. 64-65, live verifiziert lt. Header).
- Der Vendor-SP macht Full-Column-Overwrites — Testfall: unveränderte `fMenge`/`fMengeGeliefert` dürfen NICHT den Bestandspfad (`tlagerbestand`) anfassen (Header Z. 62-63).
- `spGebindeErstellen`/`spSeriennummerStandardZuWMS`/`spZustandartikelLieferantSetzen` schreiben `dbo.tArtikel`/`tLiefArtikel`/`tLagerArtikel` **direkt** — ob dort JTL-Guard-Trigger existieren, ist nicht dokumentiert; Testfall: je einmal live gegen Klon fahren.
- `spAuftragPreiseAufNull`: LEFT JOIN auf `Rechnung.tRechnungPosition` schützt fakturierte Positionen — Testfall teilfakturierter Auftrag.

**d) String/CSV-Parser-Randfälle (über bestehende Tests hinaus):**
- `fnStringTrimToMaxLines` bei String aus NUR Leerzeilen → `STRING_AGG` über 0 Zeilen → NULL-Ergebnis (ungetestet).
- `fnEscapedCSVGetField` mit `@separator`-Default: T-SQL erzwingt `DEFAULT`-Keyword beim Aufruf — Fehlbedienung möglich (kein Test).
- `fnStringParseGermanDecimal('1,234.56')` (US-Format) → **stiller Falschwert statt NULL** (ungetestet).
- Sanitize: `@defaultValue` > 100 Zeichen wird abgeschnitten (Param NVARCHAR(100)).
- `fnEscapedCSVGetLastLine` mit nur-CRLF-Input → NULL (getestet nur für leer).

**e) Duplicate-Order-Logik:**
- `COALESCE(CAST(kArtikel …), 'F:' + cArtNr)` (`fnFindDuplicateOrders.sql:72`): Freipositionen mit `kArtikel NULL` UND `cArtNr NULL` → Element fällt aus STRING_AGG → **Fingerprint-Kollisionsrisiko** (ungetestet).
- Auftrag ohne nType-0/1-Positionen → kein Fingerprint-Row → nie Duplikat (ungetestet).
- `@nWindowHours` negativ/0; DECIMAL(18,3)-Rundung von fAnzahl; Storno des NEUEREN statt älteren.
- Test 8 (`DuplicateOrders_Tests.sql:365-367`) hängt an realen Seed-Aufträgen 236/237 → umgebungsabhängig.

**f) Testabdeckung (vorhanden vs. fehlt):**
- `StringAndCSVUtilities_Tests.sql` (540 Z.): 9 Funktionsblöcke + Integrationstest — gut abgedeckt inkl. NULL/leer/Default. **Fehlt:** Separator-Sonderfälle, Nicht-2022-Compat-Runtime-Fail, sehr lange Strings.
- `DuplicateOrders_Tests.sql` (444 Z.): Tie-Break, Zeitfenster-Grenze, Storno, gleicher Betrag/andere Menge bzw. Artikel, 3-Wege-Rückgabe. **Fehlt:** Freiposition-NULL-Fall, nType-Filter, Fingerprint-Kollision.
- `CustomFieldAPI_Tests.sql` (410 Z.): Read leer, fehlende Definition, Auto-Create+Rollback, Update, History-Append, Clean-State. **Fehlt:** Race-2627-Pfad, `@kSprache <> 0`, Self-Healing "Binding ohne Sprachzeile" (QG3-B6-Kernfall!).
- `HistorySPs_Tests.sql` (668 Z.): 14 Tests inkl. Sanitization, Default-Username, Doppelaufruf-Reparse. **Fehlt:** 1000-Zeilen-Trim, MwSt-Zone-'Inland'-fehlt-Fallback, reduzierter Steuersatz (7 %), Fehlerpfad fehlende Freifeld-Definition.
- **KEINE Tests existieren für:** `spAuftragPreiseAufNull`, `spGebindeErstellen`, `spSeriennummerStandardZuWMS`, `spZustandartikelLieferantSetzen`, `spVpeCheckLieferantenbestellung`, `up/0003` (Drop-Verifikation). Größte Lücken; spVpe hat dokumentierte Idempotenz-Invarianten (Marker nie stapeln, 2000/255-Guards), die sich als Assertions eignen.

## 3. Wartungssuite — Fehlerfälle im Linux-Container

**Ola-Vendoring (`up/0022`, 5350 Z.):** genau 4 Objekte nach `RoboticoOps.dbo`: `CommandLog` (Z. 37-62), `CommandExecute` (Z. 72-77), `DatabaseIntegrityCheck` (Z. 384-386), `IndexOptimize` (Z. 2400-2402); Version gepinnt 2026-07-22; `DatabaseBackup` bewusst NICHT (ADR-0002). Idempotent: upstream-Guards `IF NOT EXISTS`-Stub + `ALTER PROCEDURE`. Byte-Abweichungen dokumentiert (Datumsliterale `'19000101'` wegen German DATEFORMAT). Harmlos: doppeltes `GO` Z. 62-63. Ola-Procs laufen auf Linux normal (reines T-SQL).

**xp_instance_regread/regwrite unter Linux** (`permissions/260_maintenance_operator.sql:60-77`): liest/schreibt `…\SQLServerAgent\DatabaseMailProfile`/`UseDatabaseMail`. SQL Server on Linux emuliert die Registry, die XPs existieren — **aber der dokumentierte Linux-Weg für das Agent-Mail-Profil ist `mssql-conf set sqlagent.databasemailprofile`**; ob der Agent auf Linux den per `xp_instance_regwrite` gesetzten Wert liest, ist unsicher. **Testfälle:** (1) regread liefert im Container NULL/leer ohne Fehler? (2) regwrite ohne Fehler? (3) verschickt ein failender Job danach wirklich Mail? Das Skript ist gegen "kein Profil vorhanden" geguarded: fehlt `msdb.dbo.sysmail_profile`-Zeile 'Standard SMTP' → nur PRINT (Z. 55-56), Deploy grün.

**Database Mail unter Linux:** grundsätzlich unterstützt; Container hat kein konfiguriertes Profil → PRINT-Pfad. Agent-Job-Notify (`notify_level_email`, `spEnsureMaintenanceJobs.sql:230-231`) nur verdrahtet, wenn der Operator existiert — Operator-Anlage via `sp_add_operator` (260 Z. 41-44) funktioniert überall. **Testfall (D29-Kerntest):** Ensure vor 260 (erster Deploy) → Operator fehlt → `@cOperator NULL`, NotifyLevel 0; nach 260 + zweitem Ensure-Lauf → Drift erkannt → Job-Recreate mit Notify.

**SQL-Agent-Jobs im Container:** Docker-Harness läuft mit `MSSQL_AGENT_ENABLED=true` (`db-migrations/tests/docker/README.md:27`). T-SQL-Subsystem-Jobs auf Linux unterstützt. Fehlerfälle:
- Agent aus → `@nAgentSession` NULL (`spEnsureMaintenanceJobs.sql:61`) → Running-Guard matcht nie → Ensure arbeitet trotzdem korrekt (bewusst).
- Running-Job-Skip (Z. 125-141, 204-219): Testfall langlaufender Job während Deploy → Skip + Konvergenz beim nächsten Deploy.
- Drift-Recreate verliert Job-History (dokumentiert).
- `sp_add_job @owner_login_name='sa'` (Z. 228): Container hat sa → ok; sa disabled ist egal (Ownership), umbenannt → Fehler.

**spCheckBackupChain im Container** (`maint.spCheckBackupChain.sql`):
- msdb-Backup-History leer → `dLastFull IS NULL` → 'NEVER' → **THROW 51100 by design** (Z. 80-81, 98-102). Erwartetes Rot; guter Testfall für die Alarm-Mechanik.
- Seed-Watchliste `'eazybusiness,RoboticoOps,msdb'` (`maint.spApplyMaintenance.sql:47`): fehlt `eazybusiness` im Container → **Invalid-Target-THROW 51100** (Z. 49-59) noch VOR dem Freshness-Check — Testfall Target-Validierung (D32) inkl. Ola-Token (`USER_DATABASES` → gleicher THROW).
- Lokale Zeitbasis SYSDATETIME (Z. 66): Container meist UTC → lokal==UTC, der CEST-Bug ist im Container NICHT reproduzierbar — Testlücke benennen.
- Log-Check nur `recovery_model_desc <> 'SIMPLE'` (Z. 94): Container-DBs oft SIMPLE → Log-Zweig unsichtbar; Testfall: eine DB auf FULL stellen.

**spCheckMaintenanceLiveness** (`maint.spCheckMaintenanceLiveness.sql`):
- `MaintenanceSchedulesEnabled='0'` → sofortiger RETURN (Z. 61-66) — beide Zustände testen (Key ist NICHT geseedet; setzen = manueller ops.tConfig-Insert).
- First-Run-Grace über `dModified` UTC (Z. 82-86): frische Rows → 26 h/192 h Karenz → kein 51105. Testfall Staleness: `dModified` künstlich zurückdatieren → 51105 mit cJobKeys (Z. 94-98).
- Zwei Uhren absichtlich (Z. 43-45, 68-69); CommandLog-Referenz dreiteilig `RoboticoOps.dbo.CommandLog` (Z. 89).
- IndexOptimize-Heartbeat hängt an `bUpdateStatistics=1` (Z. 19-26) — Blind-Spot-Doku.
- Blind Spot "Agent aus schweigt auch der Watchdog" — nicht containertestbar, extern gemonitort (ADR-A Gap 2).

**Operator/Registry/Schalter:** Operator-Name + Empfänger hard-coded (260 Z. 20-26, bewusste Policy). `MaintenanceSchedulesEnabled` steuert nur `enabled` der Jobs; `sp_start_job` funktioniert auch bei disabled Jobs (README:397) → Container-Validierung per manuellem `sp_start_job` je Job-Key.

**Engine-Floor Ebene B:** `IS DISTINCT FROM` (`spApplyMaintenance.sql:55-68`, `spEnsureMaintenanceJobs.sql:186-198`) = SQL Server 2022+; `TRIM`/`STRING_AGG` = 2017+. Container-Image muss ≥ 2022 sein.

## 4. Idempotenz / Re-Run

- **Ebene A up/:** 0001 `IF NOT EXISTS`; 0002 `IF OBJECT_ID`-Guards + insert-only-MERGE; 0003 komplett `DROP IF EXISTS` — alle mehrfach lauffähig (grate führt up/ ohnehin nur einmal aus; Guards schützen gegen Klone mit abweichendem Journalstand).
- **Ebene A anytime:** alle functions/sprocs `CREATE OR ALTER`; Registrierungs-Trailer `_SetActionDisplayName` droppt + re-addet die Extended Property → idempotent. `_CheckAction` read-only.
- **Runtime-Idempotenz der Actions:** spVpe ersetzt Marker statt zu stapeln und ist re-run-reparabel; spZustandartikel hängt Suffix nie doppelt an; History-SPs schreiben nur bei Änderung. **Nicht idempotent:** `spGebindeErstellen` — jeder Lauf INSERTet eine weitere tGebinde-Zeile und hängt das Suffix ERNEUT an (`cHAN = cHAN + '-…'`, Z. 85-101 ohne Bereits-Suffix-Guard) → Doppel-Trigger im Workflow = Datenmüll; Testfall + bekannte Schwäche. `spSeriennummerStandardZuWMS`: Zweitlauf findet i. d. R. keine Quell-Serien mehr (suffigiert) — quasi-idempotent, ungeprüft.
- **Wartungssuite:** 0022/0023 up-Skripte voll geguarded; `spApplyMaintenance` MERGE value-guarded (`IS DISTINCT FROM`, kein dModified-Churn) + `NOT MATCHED BY SOURCE DELETE` (Removal-Pfad AC3); `spEnsureMaintenanceJobs` per-Job-Normalform-Vergleich → "0 change(s)" auf gesundem Redeploy (AC7) — zentraler Re-Run-Testfall: zweimal deployen, zweiter Lauf muss 0/0 melden; 260 ist everytime und ruft ensure unconditional.

**Offene Unsicherheiten:** (1) xp_instance_regread/regwrite + Agent-Mail-Verhalten auf Linux — nur im Container klärbar; (2) Existenz von Guard-Triggern auf `tArtikel`/`tLagerArtikel` nicht verifiziert (nur der Lieferantenbestellungs-Trigger ist dokumentiert); (3) ob das Schema `CustomWorkflows` auf einer frischen Nicht-Modul-DB existiert (Deploy-Voraussetzung) ist nirgends abgesichert.
