# QG3 — Bugs & Logikfehler (Korrektheits-Review)

**Datum:** 2026-07-15
**Scope:** `db-migrations/` komplett (global/ + eazybusiness/, deploy.ps1, mandant.ps1,
lib/targets.ps1, tests/validate-rollout.ps1, tests/lint-migrations.ps1, tests/docker/)
inkl. der drei uncommitteten Änderungen (RECOVERY FULL in global/up/0001,
docs/SQL/MSSQL-OPS-DATA-MODEL.md, CLAUDE.md-Sektion).
**Methode:** Reine Datei-Analyse, keine SQL-Server-Verbindung, keine Edits.
**Vorwissen ausgeklammert:** QG2 (CQG/CQE/PAR/EXT/OPS — verifiziert als umgesetzt),
clone-guard-audit.md, test1-rollout-report (Bugs A/B/C).

Severity-Skala: **HIGH** = bricht Deploy/Betrieb in realistischem Szenario ·
**MEDIUM** = konkreter Fehlpfad, braucht bestimmte (aber plausible) Bedingungen ·
**LOW** = Randfall / Defensive-Lücke · **INFO** = zur Kenntnis.

---

## HIGH

### B1 — Uncommittete RECOVERY-FULL-Änderung editiert ein bereits journaltes One-Time-Skript → nächster Global-Deploy auf test1 bricht, und die Änderung kommt dort nie an

**Datei:** `db-migrations/global/up/0001_roboticoops_settings.sql:38-39` (Working-Tree-Diff)

**Szenario:** `up/` ist grates One-Time-Klasse; 0001 ist auf test1 (Rollout 2026-07-13)
bereits gelaufen und im `ops.ScriptsRun`-Journal mit Hash verbucht. Grate **failt per
Default, wenn sich ein bereits gelaufenes One-Time-Skript ändert** (nur
`--warnononetimescriptchanges` / `--warnandignoreononetimescriptchanges` unterdrücken das;
`deploy.ps1` setzt keins von beiden). Konsequenzen:

1. `deploy.ps1 -Scope global -Environment TEST` → grate exit ≠ 0 → `throw` — der gesamte
   Global-Deploy auf test1 ist blockiert, bis der Hash-Konflikt manuell aufgelöst wird.
2. Selbst mit Warn-Flag würde das Skript **nicht erneut ausgeführt** — test1 bliebe still
   auf RECOVERY SIMPLE. Der semantische Zweck der Änderung (FULL auf bestehenden
   Instanzen) wird über die One-Time-Kette prinzipiell nie erreicht; nur frische Instanzen
   (E2E-Container nach teardown, PROD-Erstrollout) bekämen FULL.

**Fachliche Nebenbewertungen der Änderung selbst (Auftragsfragen):**
- *Klon-Verhalten:* unberührt — `spInternal_CloneDatabase:91` setzt jeden Klon explizit
  `SET RECOVERY SIMPLE`; das COPY_ONLY-Backup der Quelle ist vom Recovery-Modell der
  RoboticoOps-DB unabhängig.
- *FULL ohne Log-Backup:* solange **kein** erstes Full-Backup von RoboticoOps existiert,
  bleibt die DB pseudo-SIMPLE (auto-truncate) — kein Log-Wachstum, aber auch **kein**
  Point-in-Time-Nutzen. Sobald der Instanz-Backup-Plan ein Full-Backup zieht, wächst das
  Log unbegrenzt, bis Log-Backups eingeplant sind. D. h. die Änderung liefert ohne
  begleitende Backup-Plan-Änderung (Runbook!) entweder nichts oder ein Log-Volllauf-Risiko.
  Der Skript-Kommentar benennt das, aber kein Runbook-/Checklisten-Anker erzwingt es.
- *Restore-Kette:* Point-in-Time-Restore setzt Full + Log-Kette voraus; nichts im Repo
  stellt die her. FULL ohne Log-Backups ist gegenüber SIMPLE strikt schlechter.

**Fix-Vorschlag:** Diff auf 0001 zurücknehmen (Datei byte-identisch zum Journal-Hash
lassen). Stattdessen neues One-Time-Skript `global/up/0012_recovery_full.sql` (o. ä.) mit
demselben idempotenten `IF recovery_model <> 1 ALTER DATABASE CURRENT SET RECOVERY FULL;`
+ Kommentar; zusätzlich Runbook-Schritt „RoboticoOps-Log-Backup in den Instanzplan
aufnehmen“. Alternativ (wenn FULL als dauerhafte Invariante gemeint ist): Assert/Set in
ein everytime-`permissions/`-Skript legen.

---

## MEDIUM

### B2 — Orchestrator: offener Cursor nach LogStep-Fehler → alle Folge-Requests failen mit irreführendem Fehler

**Datei:** `db-migrations/global/sprocs/reset.spProcessNextResetRequest.sql:96, 126, 140-141, 152-169`

**Szenario:** Innerhalb des TRY wird `stepcur` geöffnet (Z. 96-101). Wirft **nicht** der
Step selbst (dessen CATCH schließt den Cursor, Z. 137), sondern ein Aufruf von
`reset.spInternal_LogStep` (Z. 126 „starting step“ oder Z. 141 WARN-Pfad — möglich z. B.
durch Deadlock/Lock-Timeout auf `ops.tResetRequest`), springt die Ausführung in den
äußeren CATCH, **ohne** `CLOSE/DEALLOCATE stepcur`. Der CATCH markiert den Request
'failed' und `CONTINUE`t zur nächsten Queue-Zeile — dort schlägt `DECLARE stepcur CURSOR`
mit Fehler 16915 („cursor with the name 'stepcur' already exists“) fehl, landet wieder im
CATCH, und **jeder weitere queued Request** wird mit dieser irreführenden Cursor-Meldung
'failed' markiert, bis die Prozedur endet.

**Fix-Vorschlag:** Im äußeren CATCH vor der Fehlerbehandlung:
```sql
IF CURSOR_STATUS('local', N'stepcur') >= -1
BEGIN
    IF CURSOR_STATUS('local', N'stepcur') >= 0 CLOSE stepcur;
    DEALLOCATE stepcur;
END
```

### B3 — Pipeline ist NICHT gegen parallele Ausführung serialisiert; der eine `BackupFile`-Pfad kollidiert (Antwort auf die Auftragsfrage: der Applock serialisiert das nicht)

**Dateien:** `reset.spProcessNextResetRequest.sql:51-73`, `reset.spInternal_CloneDatabase.sql:79-89`, `global/up/0020_seed_mandant_template.sql:29`

**Szenario:** Der Applock in `spPub_StartTestmandantReset` (`'reset:' + @MandantKey`)
dedupliziert nur die **Submission je Mandant**. Die Pipeline selbst wird ausschließlich
dadurch serialisiert, dass der SQL-Agent denselben Job nicht zweimal parallel startet
(22022). Läuft `reset.spProcessNextResetRequest` zusätzlich **manuell** (sysadmin —
naheliegend genau in Hänger-/Diagnose-Situationen) oder über einen zweiten Job, dann:
UPDLOCK/READPAST lässt beide Instanzen **verschiedene** queued Requests claimen (READPAST
überspringt die gesperrte Zeile) → zwei `spInternal_CloneDatabase` gleichzeitig →
`BACKUP … TO DISK = @bf WITH INIT` überschreibt/kollidiert mit dem Backup-File, aus dem
die andere Instanz gerade RESTOREt → Restore-Fehler oder (schlimmer) Klon aus dem
falschen, halb überschriebenen Backup. Der `cNotes`-Text im Seed („single path -> resets
serialize“) suggeriert eine Serialisierung, die nirgendwo im Code erzwungen wird.
Zweitschaden: die manuelle Instanz führt den Stale-Reclaim aus und kann dabei den Request
des laufenden Jobs 'failed' markieren (siehe B4).

**Fix-Vorschlag:** Am Anfang von `spProcessNextResetRequest` einen exklusiven
Session-Applock `'reset:pipeline'` mit `@LockTimeout = 0` nehmen; bei `@rc < 0` sofort
still RETURN (eine zweite Instanz ist per Definition überflüssig — die laufende arbeitet
die Queue ab). Damit ist auch der eine `BackupFile`-Pfad wirklich sicher.

### B4 — Terminal-Updates des Orchestrators ohne Status-Guard: „failed → succeeded“-Resurrection nach Cancel/Reclaim-Race

**Datei:** `reset.spProcessNextResetRequest.sql:148-150, 166-168`; Gegenstelle `reset.spPub_CancelResetRequest.sql:80-100`

**Szenario:** Die abschließenden UPDATEs setzen `succeeded`/`failed` nur per
`WHERE kResetRequest = @RequestId` — ohne `AND cStatus = N'running'`. Der Cancel-Pfad
für 'running' prüft zwar die Agent-Job-Aktivität, aber (a) bei **manueller** Ausführung
des Orchestrators (B3) sagt `sysjobactivity` „Job läuft nicht“ → Force-Reclaim setzt die
Zeile mitten im Lauf auf 'failed' → am Pipeline-Ende überschreibt der Orchestrator sie
bedingungslos mit 'succeeded' (der Audit-Trail „force-reclaimed by …“ ist weg); (b)
dasselbe Fenster existiert zwischen der `sysjobactivity`-Prüfung und dem UPDATE des
Cancels, wenn der Job in genau diesem Moment startet. Der Queued-Pfad des Cancels macht
es vor (Guard `AND cStatus = N'queued'` + `@@ROWCOUNT`-Auswertung, Z. 58-74); der
Running-Pfad und der Orchestrator lassen den Guard weg.

**Fix-Vorschlag:** Beide Terminal-UPDATEs im Orchestrator um `AND cStatus = N'running'`
ergänzen; bei 0 Zeilen eine LogStep-WARN-Zeile („terminal state raced — row was already
<status>“) schreiben statt still weiterzumachen.

### B5 — copy-logins.ps1: sqlcmd-Ausgabe wird bei 256 Zeichen abgeschnitten → Passwort-Hash verstümmelt

**Datei:** `db-migrations/tests/docker/copy-logins.ps1:117`

**Szenario:** Die Quelle wird als **eine** konkatenierte varchar(max)-Spalte gelesen
(`name|type|sid|disabled|hash`). ODBC-sqlcmd begrenzt variable-length-Spalten per Default
auf **256 Anzeigezeichen** (`-y`-Default). Ein SQL-2022-Passwort-Hash ist alleine ~140
Hex-Zeichen; mit SID (34) + Pipes + Typ liegt eine Zeile ab ~70 Zeichen Login-Name über
der Grenze. Ergebnis je nach Länge: `parts.Count -lt 5` → Login wird still übersprungen,
oder ein **abgeschnittener** `0x…`-Hash erreicht `CREATE LOGIN … HASHED` → Fehler bricht
mit `-b` den ganzen Batch ab (kein Login wird angelegt). Auf test1 hat es mit den
aktuellen (kurzen) Namen funktioniert — das ist Glück, keine Korrektheit.

**Fix-Vorschlag:** `-y 0` (unbegrenzt) in das Lese-Kommando aufnehmen; optional eine
Plausibilitätsprüfung „Hash endet nicht mitten im Byte / Zeilenlänge < Limit“.

### B6 — spEnsureArticleCustomField: nicht-atomare Doppel-INSERTs + Sprach-Lücke → permanenter 2627-Wedge für das Feld

**Datei:** `db-migrations/eazybusiness/sprocs/Robotico.spEnsureArticleCustomField.sql:60-99` (Konsumenten: `Robotico.spSetArticleCustomFieldValue.sql:29-40`, beide History-Actions)

**Szenario:** Der Header behauptet, das TRAN-Scaffolding sei durch „grate --transaction“
ersetzt — das wickelt aber nur den **Deploy**, nicht den **Runtime-Aufruf**. Zwei Wege in
denselben kaputten Zustand „`tArtikelAttribut`-Zeile existiert, aber keine
`tArtikelAttributSprache`-Zeile für @kSprache“:
1. Crash/Fehler zwischen INSERT 1 (Z. 61) und INSERT 2 (Z. 66) — keine Transaktion, die
   erste Zeile bleibt stehen.
2. Binding existiert bereits, aber nur mit einer **anderen** Sprache (mehrsprachige
   Freifelder; der Lookup joint auf `aas.kSprache = @kSprache`).

Danach gilt für **jeden** weiteren Aufruf: Step-2-Lookup NULL → INSERT → 2627 (UNIQUE
kArtikel/kAttribut/kShop) → Re-Query (joint wieder die fehlende Sprachzeile) → immer noch
NULL → `THROW`. Das Feld ist für diesen Artikel dauerhaft kaputt, bis jemand die Zeile
manuell repariert; die Workflow-Actions (Preis-/Label-Historie) schlagen ab dann bei
jedem Trigger fehl (bzw. werden in `spArticleUpdateAllHistory` zu Severity-10-Rauschen).

**Fix-Vorschlag:** Beide INSERTs in `BEGIN TRAN … COMMIT` (+ `XACT_ABORT ON`); im
2627-Zweig nach dem Re-Query bei „Binding da, Sprachzeile fehlt“ die fehlende
`tArtikelAttributSprache`-Zeile nachlegen statt zu THROWen.

### B7 — MSSQL-OPS-DATA-MODEL.md (uncommittet): drei faktische Fehler gegenüber dem realen Verhalten

**Datei:** `docs/SQL/MSSQL-OPS-DATA-MODEL.md:63, 30-31, 70`

1. **Z. 63 (`cStatus`):** behauptet „plus `cancelled` (via spPub_CancelResetRequest).
   CHECK-constrained.“ — Der CHECK (`0002_ops_schema_tables.sql:84-85`) erlaubt nur
   `queued/running/succeeded/failed`; Cancel schreibt `failed` (mit Erklärtext in
   `cErrorMessage`). Ein Leser, der auf `cStatus = 'cancelled'` filtert oder den Wert in
   Tooling erwartet, geht leer aus.
2. **Z. 30 (`cShopUrl`):** behauptet „column-DENY for non-admins“ — der DENY existiert nur
   auf `cShopLicense` (`0003_roles.sql:38`). Die Doku erzeugt ein falsches
   Sicherheitsgefühl (wobei `spPub_ListMandants` die Spalte tatsächlich nicht ausgibt).
3. **Z. 70 (`dModified`):** behauptet, `dModified` werde mit `StaleRunningHours` für den
   Reclaim benutzt — der Reclaim prüft `dStarted` (`spProcessNextResetRequest.sql:42`).
   Für Ops-Diagnose („warum wurde reclaimed?“) ist das die falsche Spalte.

**Fix-Vorschlag:** Alle drei Stellen an das reale Verhalten angleichen (oder — falls
`cancelled` gewollt ist — CHECK + Cancel-Proc + Doku gemeinsam ändern; dann auch die
`IX_tResetRequest_Active`-Filterliste prüfen).

### B8 — PayPal-Token-Procs: Transaktions-Leak und permanent „vergifteter“ Token nach einem fehlgeschlagenen Auth-Call

> **Status: deferred — superseded by PayPal removal.** Entscheidung Team-Lead/Lukas
> (2026-07-15): die PayPal-Mechanik wird als nächster Schritt komplett ausgebaut; ein
> Fix hier wäre Wegwerfarbeit. Kein Code-Fix in QG3.

**Dateien:** `Robotico.spPaypalGetAccessToken.sql:19-31`, `Robotico.spPaypalCreateAccessToken.sql:21-109`

**Szenario (a) — TRAN-Leak:** Beide Procs machen `BEGIN TRANSACTION … COMMIT` ohne
TRY/CATCH und ohne `XACT_ABORT ON`. Wirft irgendetwas dazwischen (OLE deaktiviert,
OPENJSON-Fehler, Constraint), bleibt `@@TRANCOUNT = 1` in der Session des JTL-Workers
hängen — inklusive UPDLOCK auf `tPaypalSettings`/`tPaypalAccessToken`, der parallele
Token-Leser blockiert, bis die Session zurückgesetzt wird.

**Szenario (b) — vergifteter Token:** Liefert die Auth-API einen Fehler (z. B. 401 mit
`{"error": …}`), löscht `spPaypalCreateAccessToken` erst die alte Token-Zeile (Z. 89) und
`OPENJSON … WITH` mappt das Fehler-JSON auf **eine Zeile voller NULLs** → es wird eine
Zeile mit `cAccessToken = NULL, nExpiresInSeconds = NULL` eingefügt. In
`spPaypalGetAccessToken` ist danach `NOT EXISTS(…)` falsch und
`(nExpiresInSeconds - DATEDIFF(…)) < 60` **UNKNOWN** → es wird nie wieder ein Refresh
ausgelöst; `@token` bleibt dauerhaft NULL (alle Tracking-Calls laufen mit
`Authorization: NULL` ins Leere), bis jemand die Zeile manuell löscht.

**Fix-Vorschlag:** (a) TRY/CATCH + `XACT_ABORT ON` + Rollback im CATCH. (b) Refresh-
Bedingung erweitern: auch bei `cAccessToken IS NULL OR nExpiresInSeconds IS NULL`
erneuern; besser: nur bei HTTP-Status 200/valide `access_token`-Antwort DELETE+INSERT
ausführen. (Ported-Legacy — aber beide Fehlpfade sind real erreichbar; QG2/CQE deckte nur
die Debug-PRINT-Leaks ab.)

---

## LOW

### B9 — spInternal_LogStep: NULL-@Message löscht das komplette Step-Log

**Datei:** `reset.spInternal_LogStep.sql:22-26` — `cStepLog = ISNULL(cStepLog,'') + … + @Message + …`
propagiert NULL: ein einziger Aufruf mit `@Message = NULL` setzt `cStepLog` auf NULL und
vernichtet die gesamte bisherige Historie des Requests. Aktuelle Aufrufer bauen ihre
Messages NULL-sicher (CONCAT/ISNULL), aber der Helper ist der SSoT für **künftige** Steps.
**Fix:** `+ ISNULL(@Message, N'(null message)') +`.

### B10 — Stale-Reclaim und Cancel lassen einen mid-clone SINGLE_USER-Klon stehen

**Dateien:** `reset.spProcessNextResetRequest.sql:36-42` (Reclaim), `reset.spPub_CancelResetRequest.sql:95-100` (Force-Reclaim)

Nur der In-Run-CATCH (Z. 155-164) stellt MULTI_USER wieder her. Stirbt der Job hart
zwischen `SET SINGLE_USER` und `RESTORE`/`SET MULTI_USER`, markieren Reclaim/Cancel die
Zeile 'failed', aber die Klon-DB bleibt SINGLE_USER — für die Diagnose („leave the clone
as-is“) sogar unzugänglich, bis der nächste Reset sie überschreibt. **Fix:** Best-effort
`SET MULTI_USER` (wie im CATCH) auch im Reclaim-Pfad für die betroffenen `cTargetDb`s und
im Cancel-Running-Pfad.

### B11 — Lint-Regel (h) erkennt nur reine Datums-Literale, keine Datetime-Literale

**Datei:** `db-migrations/tests/lint-migrations.ps1:186` — Regex `'(\d{4})-(\d{2})-(\d{2})'`
matcht nur, wenn das schließende Quote direkt folgt. `'2026-01-01 10:00:00'` (dieselbe
DATEFORMAT-dmy-Fehlklasse wie Bug A, Fehler 242 unter deutscher Login-Language) passiert
den Lint unbemerkt. **Fix:** Regex auf `'(\d{4})-(\d{2})-(\d{2})[^']*'` erweitern und für
Datetime-Formen die `T`-ISO8601-Form (`'YYYY-MM-DDThh:mm:ss'`, sprachneutral) als erlaubte
Ausnahme behandeln.

### B12 — 0021-Seed: künftiger neuer Step kann mit admin-getunter nStepOrder kollidieren

**Datei:** `global/up/0021_reset_step_registry.sql:46, 61-74` — Der MERGE inserted neue
Steps mit fester Seed-Order; hat ein Admin eine bestehende Zeile auf genau diese Nummer
umsortiert, bricht `UQ_tResetStep_nStepOrder` den Deploy der gesamten Global-Kette.
Kein akuter Bug (aktuell 8 Steps, Lücken 10er-Raster), aber eine dokumentationswürdige
Falle für den ersten „Step hinzufügen“-PR. **Fix-Idee:** Seed-Insert mit
`nStepOrder = (SELECT MAX+10 …)`-Fallback bei Kollision, oder Kommentar im Skript.

### B13 — deploy.ps1 Tier-3: paralleles Erst-Deploy kann den persistierten Cert-Passwort-Store mit dem falschen Passwort hinterlassen

**Datei:** `db-migrations/deploy.ps1:312-344` — Zwei gleichzeitige Global-Deploys gegen
eine Greenfield-Instanz sehen beide `certExists = $false`, minten **verschiedene**
Passwörter und persistieren nacheinander (last-writer-wins, kein Locking um
`grate-cert.env`). Das Zertifikat wird mit dem Passwort des Gewinners von `CREATE
CERTIFICATE` erstellt; steht im Store das des Verlierers, schlägt jeder künftige Re-Sign
mit der (korrekten, aber hier irreführenden) CQG-4-Meldung fehl, bis der Store manuell
korrigiert wird. Nur Erst-Deploy-Fenster, daher LOW. **Fix-Idee:** nach
Tier-3-Persistierung den Wert re-lesen und mit dem gemint­eten vergleichen; bei Differenz
abbrechen.

---

## INFO

- **I1 — validate-rollout.ps1 inkonsistentes Quoting:** `$MandantKey` wird in Z. 145
  escaped, in Z. 154/169/178/195 aber roh interpoliert. Operator-Input, kein
  Angriffsvektor — aber ein `'` im Key erzeugt dort verwirrende Syntax-Fehler statt der
  sauberen Meldung. Einheitlich über eine `Q()`-Helferfunktion ziehen (wie mandant.ps1).
- **I2 — fnFindDuplicateOrders Fingerprint-Randfall:** Positionen mit `kArtikel IS NULL
  AND cArtNr IS NULL` ergeben einen NULL-Beitrag, den `STRING_AGG` still verwirft — zwei
  Aufträge, die sich nur in solchen Positionen unterscheiden, gelten als Duplikate
  (`Robotico.fnFindDuplicateOrders.sql:70-77`). Zusammen mit dem Brutto-Vergleich sehr
  unwahrscheinlich; ggf. `COALESCE(…, 'F:' + p.cArtNr, '?')`.
- **I3 — fnEscapedCSVSanitize:** `@defaultValue` wird ungeprüft zurückgegeben — ein
  Default mit `;`/CR/LF würde das CSV-Format brechen. Alle heutigen Aufrufer übergeben
  Literale ohne Sonderzeichen (`Robotico.fnEscapedCSVSanitize.sql:35-39`).
- **I4 — teardown.ps1 Session-Pollution:** setzt bei fehlendem .env.local
  `$env:MSSQL_SA_PASSWORD = 'unused_for_down'` und räumt es nicht wieder ab — ein danach
  im selben Prozess laufender E2E-Deploy nimmt den Dummy als echtes Passwort
  (`tests/docker/teardown.ps1:46`). `try/finally` mit Restore des alten Werts.
- **Positivbefunde zu den Auftragsfragen:**
  - `900_resign_procedures` handhabt teilsignierte Zustände korrekt: Katalog-getrieben,
    per-Proc-`NOT EXISTS`-Prüfung auf die aktuelle Cert-Thumbprint — Signaturen alter,
    gedroppter Zertifikate blockieren das Nachsignieren nicht; der End-Assert (Z. 70-87)
    schließt die Lücke „EXECUTE-AS-Proc weiterhin unsigniert“.
  - Idempotenz der Ketten: alle `up/`-Skripte guarded (IF NOT EXISTS / MERGE WHEN NOT
    MATCHED), alle anytime-Objekte CREATE OR ALTER, permissions re-grant-fest; die
    einzige echte Idempotenz-Falle ist B12 (Zukunftsfall) und B1 (Änderung statt neuem
    Skript).
  - Claim-Mechanik (UPDLOCK/READPAST als Single-Statement-UPDATE mit OUTPUT) ist gegen
    Doppel-Claim **derselben** Zeile korrekt; die Restlücken sind Cross-Instanz-Parallelität
    (B3) und die ungeguardeten Terminal-Updates (B4).
  - Kultur-/SET-Options-Scan über die EXPIRY_DATE-Klasse hinaus: `FORMAT(…,'de-DE')` +
    `fnStringParseGermanDecimal` sind Write/Read-symmetrisch; `CONVERT(…,126)`-Timestamps
    sprachneutral; `spZustandartikelLieferantSetzen` bakes QUOTED_IDENTIFIER korrekt in
    die Proc (gefilterte Indizes). Einzige gefundene Restlücke ist die Lint-Blindstelle
    B11.
