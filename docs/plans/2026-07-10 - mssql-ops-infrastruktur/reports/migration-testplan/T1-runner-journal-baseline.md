---
date: 2026-07-27
author: Detail-Agent T1 (Opus) — Migrations-Testplan
status: Spec — programmer-ready Testplan (Thema: Runner/Journal/Baseline-Semantik)
context: >
  Detaillierter, gegen den Harness ausführbarer Testplan für den User-Bereich
  „bestehende Migrationen" — Adoption, Baseline, Journal-Reise, No-Op-Re-Run,
  Teilfehlschlag, Vollständigkeits-Nachweis, deploy.ps1-Environment/Token-Handling.
  Fehlerklassen F1.1–F1.5. KEINE Ausführung — rein statisch aus Repo abgeleitet.
related-grundrecherche: ./00-grundrecherche.md
related-teilrecherche: ./02-teilrecherche-reset-pipeline.md
related-enabler: T5 (Umgebungs-/Guard-Bausteine — Voraussetzung für alle T1-Fälle)
---

# T1 — Testplan: Runner / Journal / Baseline-Semantik („bestehende Migrationen")

Ziel des Themas: **Sicherstellen, dass Migrationen/Objekte, die bereits auf einem
Server vorhanden sind, beim Anwenden der Ketten vollständig und korrekt übernommen
werden** — und dass ein zweiter Lauf ein echtes No-Op ist, ein Teilfehlschlag
sauber wiederaufsetzt, und der Objektbestand nach dem Lauf exakt dem Soll
entspricht.

Alle Fälle laufen **ausschließlich gegen den Container `robotico-e2e-mssql`**
(`localhost,14330`, Env `E2E`, SQL 2022, Agent an, Collation `Latin1_General_CI_AS`).
`vm-sql2` (PROD) und `vm-sql-test1` (TEST) sind für die Ausführung tabu; jeder Fall
beginnt mit dem Servername-Guard (§0.3).

---

## 0. Grundlagen, die T1 fixiert

### 0.1 grate-Laufmodell und Journal (grate 1.6.0, via Docker `erikbra/grate:1.6.0`)

grate legt **pro `--schema`** drei Journal-Tabellen an (grate-eigen, **nicht** vom
Naming-Rename betroffen):

| Tabelle | Inhalt (relevante Spalten) |
|---|---|
| `<schema>.ScriptsRun` | eine Zeile je angewandtem Skript: `script_name`, `text_of_script`, **`text_hash`**, **`one_time_script`** (bit), `entry_date`, `modified_date`, `version_id`, `entered_by` (9 Spalten) |
| `<schema>.ScriptsRunErrors` | Fehlerprotokoll inkl. `erroneous_part_of_script` (10 Spalten) |
| `<schema>.Version` | eine Zeile je Lauf: `repository_path`, `version`, `entry_date`, `entered_by` (7 Spalten) |

- **Ebene A** journalt in Schema **`Robotico`** (`Robotico.ScriptsRun` …), Ebene B in
  **`ops`** (`ops.ScriptsRun` …).
- **`up/`** = one-time: läuft **einmal**, wird per `text_hash` getrackt, ist danach
  **immutabel**. Ändert sich der Datei-Hash eines bereits angewandten `up/`-Skripts,
  bricht grate beim nächsten Lauf mit **one-time-script hash-mismatch** ab
  (Escape-Hatch `--warnandignoreononetimescriptchanges`, nur Runbook-Notfall).
- **anytime** (`functions/`→`views/`→`sprocs/`→`runAfterOtherAnyTimeScripts/`): läuft
  **nur bei Hash-Änderung** neu (`CREATE OR ALTER`), sonst „No sql run".
- **`permissions/`** = everytime: jeder Lauf, zuletzt.
- **`--baseline`**: markiert **alle** aktuellen Skripte (up/ **und** anytime) als
  „applied" **ohne Ausführung** → die F1.2-Maskierungsfalle.
- **`--transaction`**: `deploy.ps1` setzt es **nur für Ebene A**. Ebene B läuft **ohne**
  umschließende Transaktion (Fehler 226 bei `ALTER DATABASE SET`/`sp_add_job`/Cross-DB-Cert);
  daher ist jedes Ebene-B-`up/` hand-idempotent (`IF NOT EXISTS`).
- **`--version`**-Stempel: `deploy.ps1` liest ihn aus `git describe --tags --always`
  (Fallback `unknown`).

### 0.2 Idempotenz-Vorbefund (statisch verifiziert — load-bearing für Adoption)

**Alle `up/`-Skripte beider Ketten sind hand-idempotent geguardet**, nicht nur die
Ebene-B-Skripte:

- Ebene A: `up/0001` (`IF NOT EXISTS … CREATE SCHEMA`), `up/0002` (jede `CREATE TABLE`
  unter `IF OBJECT_ID(...) IS NULL`), `up/0003` (durchgängig `DROP … IF EXISTS`).
- Ebene B: `up/0001` Assert+`IF`-Hardening, `up/0002/0010/0011/0020/0021` mit
  `IF NOT EXISTS`/`MERGE WHEN NOT MATCHED`.

**Konsequenz (T1-Kernaussage):** In *diesem* Repo funktioniert **Adoption auch per
normalem Deploy ohne `--baseline`** — grate führt zwar alle noch nicht journalten
`up/`-Skripte aus, doch deren Guards machen sie gegen bestehende Objekte zu No-Ops,
und die anytime-Objekte werden per `CREATE OR ALTER` versöhnt. `--baseline` ist damit
eine **Optimierung** (überspringt Ausführung + anytime-Churn), die aber Drift
maskieren kann (F1.2). Das ist der zentrale Unterschied zu einem naiven grate-Setup,
in dem ein ungeguardetes `CREATE TABLE` gegen ein bestehendes Objekt hart failt.

### 0.3 Servername-Guard (Pflicht-Kopf jedes Testskripts)

T5 besitzt die kanonische Fassung; bis dahin diese selbst-enthaltene Variante als
erstes Statement jeder `-i`-Datei bzw. jedes `-Q`:

```sql
SET NOCOUNT ON;
IF UPPER(CONVERT(sysname, SERVERPROPERTY('MachineName'))) LIKE N'%VM-SQL2%'
   OR UPPER(CONVERT(sysname, ISNULL(@@SERVERNAME, N''))) LIKE N'%VM-SQL2%'
   OR UPPER(CONVERT(sysname, SERVERPROPERTY('MachineName'))) LIKE N'%SQL-TEST1%'
    THROW 59999, N'GUARD: not the disposable E2E container — aborting before any write.', 1;
```

Zusätzlich Defense-in-Depth: Verbindungen laufen ausschließlich über
`-S localhost,14330` (kann `vm-sql2` netzwerkseitig nicht erreichen) und
`deploy.ps1` wird **nie** mit `-Environment PROD` aufgerufen.

### 0.4 Namens-Erratum nach dem Rename (2026-07-13) — was aus der Docker-E2E noch stimmt

Der 2026-07-11-Report (`qg2/e2e-docker-report.md`) nennt **Vor-Rename-Namen**. Für T1
gilt die aktuelle Hungarian-Konvention:

| Report 2026-07-11 (alt) | Aktuell (Repo-Stand) |
|---|---|
| `ops.Config`, `ops.Mandant`, `ops.ResetStep`, `ops.ResetRequest` | `ops.tConfig`, `ops.tMandant`, `ops.tResetStep`, `ops.tResetRequest` |
| `reset.StartTestmandantReset` / `CancelResetRequest` / `GetResetStatus` / `ListMandants` / `PurgeOldRequests` | `reset.spPub_StartTestmandantReset` / `spPub_CancelResetRequest` / `spPub_GetResetStatus` / `spPub_ListMandants` / `spPub_PurgeOldRequests` |
| `reset.ProcessNextResetRequest`, `reset.internal_*` | `reset.spProcessNextResetRequest`, `reset.spInternal_*` |
| `Robotico.ScriptsRun` / `ops.ScriptsRun` (Journal) | **unverändert** (grate-eigen) |

**Abgrenzung zu den „25 Paritäts-Assertions" (C4):** Diese sind **Daten**-Assertions
(Anonymisierung, Credential-Scrubbing, Shop-Repoint) und gehören zu **T2** (Reset-Pipeline).
T1 übernimmt aus dem Parität-Themenkreis nur den **strukturellen** Nachweis:
`compare-objects.sql` (rename-agnostisch, filtert per Ownership) und den 4-Sektionen-
Cross-DB-Diff aus `schema-parity-flow-robotico.md` (§G).

### 0.5 Soll-Objektbestand des *aktuellen* Baums (für die Vollständigkeits-Assertions)

Der Baum enthält gegenüber der 2026-07-11-Aufnahme zwei Änderungen, die den
Soll-Bestand verschieben:

- **`eazybusiness/up/0003` droppt** 5 Prozeduren
  (`CustomWorkflows.spPaypalTrackingVersand`, `…TrackingLieferschein`,
  `Robotico.spPaypalTrackingCallApi`, `…GetAccessToken`, `…CreateAccessToken`)
  und 3 Tabellen (`Robotico.tPaypalTrackingLog/tPaypalAccessToken/tPaypalSettings`).
- **`CustomWorkflows.spVpeCheckLieferantenbestellung` (neu)** kommt hinzu.

Soll-„unsere" Objekte nach vollständigem Ebene-A-Deploy (das, was `compare-objects.sql`
listet), ableitbar rein aus den Dateien im Baum:

- `Robotico`: 12 Funktionen (`fn*`) + 3 sprocs (`spCheckDuplicateOrder`,
  `spEnsureArticleCustomField`, `spSetArticleCustomFieldValue`) + Tabelle
  `tArtikelCommentary` (kommt aus Legacy/JTL-Seite, nicht aus diesen up/-Skripten —
  im Container ggf. abwesend, s. Risiko R4).
- `CustomWorkflows` (nur `sp*`, ohne Modul-Helfer/`spCMArtikel*`): 8 Aktions-Procs
  (`spArticleAppendLabelHistory/PriceHistory/UpdateAllHistory`,
  `spAuftragPreiseAufNull`, `spGebindeErstellen`, `spSeriennummerStandardZuWMS`,
  `spVpeCheckLieferantenbestellung`, `spZustandartikelLieferantSetzen`).

Diese Liste == Dateiliste `eazybusiness/functions/*` + `eazybusiness/sprocs/*` ist die
prüfbare Vollständigkeits-Invariante (§G, T1-16).

### 0.6 Test-Harness — Shell-Helfer (einmal je Session)

```bash
cd /home/lukas/WebStorm/JTL-Robotico/worktrees/feature/mssql-ops-infrastruktur
set -a; source db-migrations/tests/docker/.env.local; set +a   # MSSQL_SA_PASSWORD
export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"                       # Passwort nie auf argv
SQLCMD=/opt/mssql-tools18/bin/sqlcmd

# -Q-Query gegen eine DB (mit Guard-Kopf voranstellen!):
sqlq() { local db="$1"; shift; "$SQLCMD" -S localhost,14330 -U sa -C -b -h -1 -W -d "$db" -Q "$*"; }
# -i-Datei gegen eine DB:
sqlf() { local db="$1"; local f="$2"; "$SQLCMD" -S localhost,14330 -U sa -C -b -d "$db" -i "$f"; }
```

Voraussetzung (T5): `npm run db:e2e:up` (Container healthy, Agent Running, Collation OK)
und eine restaurierte, getrimmte `eazybusiness` im Container.

---

## Testfälle

Notation je Fall: **Ziel · Setup · Schritte · Erwartet (inkl. erwartete Fehler) · Cleanup.**
Reihenfolge ist so gewählt, dass frühe Fälle die Journal-Genese für spätere herstellen.

---

### Gruppe A — Greenfield-Erstlauf & Journal-Genese (F1.3)

#### T1-01 — Ebene B Greenfield: Journal-Genese + Zeilen==Dateien
- **Ziel:** Erster `-Scope global`-Deploy erzeugt `RoboticoOps`, das `ops`-Journal, und
  genau eine `ops.ScriptsRun`-Zeile je up/anytime-Datei; permissions ohne Journal-Zeile.
- **Setup:** Frischer Container ohne `RoboticoOps` (nach `db:e2e:down:full` + `:up`).
  Cert-Passwort ungesetzt lassen (Tier-3-Autogenerate greift, s. T1-14).
- **Schritte:**
  ```bash
  npm run db:deploy:e2e:global
  sqlq RoboticoOps "$(cat <<'SQL'
  <GUARD>
  SELECT one_time_script, COUNT(*) FROM ops.ScriptsRun GROUP BY one_time_script;
  SELECT COUNT(*) AS versions FROM ops.Version;
  SQL
  )"
  # Datei-Erwartung: up/ = 9 Dateien (0001..0023), anytime = sprocs(20)+runAfter(2)+... 
  ls db-migrations/global/up | wc -l
  find db-migrations/global -path '*/sprocs/*.sql' -o -path '*/runAfterOtherAnyTimeScripts/*.sql' | wc -l
  ```
- **Erwartet:** Deploy exit 0. `ops.ScriptsRun` hat `one_time_script=1`-Zeilen == Zahl der
  `up/`-Dateien (9) und `one_time_script=0`-Zeilen == Zahl der anytime-Dateien
  (`maint.*`+`reset.*` sprocs + 2 runAfter). `ops.Version` ≥ 1. `validate_structure.sql`
  grün. **`permissions/`-Skripte erzeugen keine ScriptsRun-Zeile** (everytime).
- **Cleanup:** keiner (Journal ist Voraussetzung für T1-09/T1-14).

#### T1-02a — Adoption MIT mitgereistem Ebene-A-Journal (Restore-Fall)
- **Ziel:** Eine restaurierte `eazybusiness`, die das `Robotico`-Journal aus der Quelle
  trägt, wird per **normalem** Ebene-A-Deploy adoptiert; grate führt nur die noch nicht
  journalten neuen Skripte aus (`up/0003` + geänderte anytime wie `spVpeCheck`).
- **Setup:** Restaurierte `eazybusiness` (T5) — sie enthält `Robotico.ScriptsRun` aus der
  Quelle. **Sub-Präparation, um „hinter dem Repo" zu simulieren:** aus `Robotico.ScriptsRun`
  die Zeilen für `up/0003` und für die anytime-Datei `CustomWorkflows.spVpeCheckLieferantenbestellung`
  löschen (falls vorhanden), damit der Restore-Zustand „vor 0003/vor Vpe" abbildet:
  ```bash
  sqlq eazybusiness "<GUARD> DELETE FROM Robotico.ScriptsRun WHERE script_name LIKE '%0003_drop_paypal_mechanic%' OR script_name LIKE '%spVpeCheckLieferantenbestellung%';"
  ```
- **Schritte:**
  ```bash
  # Vorher-Bestand der PayPal-Objekte + Journal-Delta messen
  sqlq eazybusiness "<GUARD> SELECT COUNT(*) FROM sys.objects WHERE name LIKE 'spPaypal%' OR name LIKE 'tPaypal%';"
  npm run db:deploy:e2e            # Ebene A, normal, KEIN -Baseline
  sqlq eazybusiness "<GUARD> SELECT COUNT(*) FROM sys.objects WHERE name LIKE 'spPaypal%' OR name LIKE 'tPaypal%';"
  ```
- **Erwartet:** grate läuft `up/0003` (droppt PayPal → 8 Objekte weg) und die geänderten
  anytime-Objekte (mind. `spVpeCheck`) via `CREATE OR ALTER`; **bereits journalte up/
  (0001/0002) werden NICHT erneut ausgeführt** (kein Hash-Mismatch, weil unverändert).
  PayPal-Objektzahl **8 → 0**. Exit 0.
- **Cleanup:** keiner (führt zum Soll-Zustand für §G).

#### T1-02b — Adoption OHNE Journal (journal-loses Backup, Normal-Deploy)
- **Ziel:** Nachweis, dass Adoption auch ohne mitgereistes Journal per Normal-Deploy
  gelingt, weil alle `up/` idempotent geguardet sind (§0.2).
- **Setup:** Kopie des Adoptions-Szenarios, aber **ohne** Journal: `DROP TABLE
  Robotico.ScriptsRun, Robotico.ScriptsRunErrors, Robotico.Version;` (simuliert ein
  Backup aus der Zeit vor grate). PayPal-Objekte + unsere anytime-Objekte sind vorhanden.
- **Schritte:**
  ```bash
  sqlq eazybusiness "<GUARD> DROP TABLE IF EXISTS Robotico.ScriptsRun; DROP TABLE IF EXISTS Robotico.ScriptsRunErrors; DROP TABLE IF EXISTS Robotico.[Version];"
  npm run db:deploy:e2e            # normal, KEIN -Baseline
  ```
- **Erwartet:** grate hat **kein** Journal → führt **alle** `up/` aus:
  `up/0001` (Schema existiert → `PRINT '= … already exists'`, no-op),
  `up/0002` (`IF OBJECT_ID … IS NULL` → Tabellen existieren → no-op),
  `up/0003` (`DROP IF EXISTS` → droppt PayPal). **Kein** `CREATE TABLE`-Fehler trotz
  bestehender Objekte (Guards). Alle anytime via `CREATE OR ALTER` neu. Journal wird neu
  aufgebaut (Zeilen == Dateien). Exit 0. **Dies belegt: `--baseline` ist nicht zwingend.**
- **Cleanup:** Container-DB verworfen (`db:e2e:down:full`) oder frisch restauriert vor §B.

---

### Gruppe B — Baseline-Semantik & F1.2-Maskierung

#### T1-03 — `--baseline` markiert ohne Ausführung (TC-M1)
- **Ziel:** Baseline schreibt Journal-Zeilen, ändert **keine** Objektdefinition.
- **Setup:** Restaurierte `eazybusiness` **ohne** `Robotico`-Journal (wie T1-02b-Setup),
  deren Objektstand == Repo (also: erst normal deployen (T1-02b), Fingerprint aufnehmen,
  Journal droppen, dann baselinen). Alternativ direkt auf frisch restaurierter DB, deren
  Objekte == Repo sind (Vorbedingung des Runbooks).
- **Schritte:**
  ```bash
  # Fingerprint VOR Baseline
  sqlq eazybusiness "<GUARD> SELECT CONVERT(VARCHAR(64),HASHBYTES('SHA2_256',(SELECT STRING_AGG(CONVERT(NVARCHAR(MAX),OBJECT_DEFINITION(o.object_id)),'|') WITHIN GROUP (ORDER BY o.object_id) FROM sys.objects o JOIN sys.schemas s ON s.schema_id=o.schema_id WHERE s.name IN('Robotico','CustomWorkflows') AND o.type IN('P','FN','IF','TF','V'))),2);"
  npm run db:deploy:e2e -- -Baseline
  # grate-Ausgabe: "No sql run … all files run against destination previously"
  # Fingerprint NACH Baseline (muss identisch sein)
  sqlq eazybusiness "<GUARD> SELECT one_time_script, COUNT(*) FROM Robotico.ScriptsRun GROUP BY one_time_script;"
  ```
- **Erwartet:** grate meldet „No sql run"; `Robotico.ScriptsRun` neu befüllt (up/=2 bzw. 3
  Zeilen + anytime-Zeilen); **Fingerprint vor==nach** (kein DDL). Exit 0.
- **Cleanup:** Journal + DB für T1-04 wiederverwendbar.

#### T1-04 — F1.2: Baseline maskiert einen Rückstand (Kern-Reproduktion)
- **Ziel:** Beweisen, dass `--baseline` eine **hinter dem Repo liegende** DB still als
  „applied" markiert und ein späterer Normal-Lauf den fehlenden/älteren anytime-Stand
  **nicht** heilt.
- **Setup:** Restaurierte `eazybusiness` **ohne** Journal. **Rückstand künstlich
  herstellen:** ein anytime-Objekt löschen und ein zweites downgraden:
  ```bash
  sqlq eazybusiness "<GUARD> DROP FUNCTION IF EXISTS Robotico.fnStringCountLines; ALTER FUNCTION Robotico.fnStringIsEffectivelyEmpty(@s nvarchar(max)) RETURNS bit AS BEGIN RETURN 0; END;"  -- absichtlicher Falschstand
  ```
- **Schritte:**
  ```bash
  npm run db:deploy:e2e -- -Baseline            # (1) baselined den Rückstand mit
  sqlq eazybusiness "<GUARD> SELECT OBJECT_ID('Robotico.fnStringCountLines') AS still_missing;"
  npm run db:deploy:e2e                          # (2) normaler Re-Run
  sqlq eazybusiness "<GUARD> SELECT OBJECT_ID('Robotico.fnStringCountLines') AS still_missing_after_normal, Robotico.fnStringIsEffectivelyEmpty(N'') AS should_be_1;"
  ```
- **Erwartet:** Nach (1) meldet grate „No sql run"; `fnStringCountLines` bleibt **NULL**
  (fehlt), `fnStringIsEffectivelyEmpty(N'')` liefert **0** (Falschstand). Nach (2) grate
  wieder „No sql run" → **beide Defekte bestehen fort** (Journal lügt: „applied", DB
  disagreet). Das ist die sichtbar gemachte Maskierung.
- **Remediation-Nachweis (Teil des Falls):**
  ```bash
  sqlq eazybusiness "<GUARD> DELETE FROM Robotico.ScriptsRun WHERE one_time_script=0;"  # anytime-Journal trimmen
  npm run db:deploy:e2e
  sqlq eazybusiness "<GUARD> SELECT OBJECT_ID('Robotico.fnStringCountLines') AS recreated, Robotico.fnStringIsEffectivelyEmpty(N'') AS fixed_to_1;"
  ```
  → `fnStringCountLines` wieder vorhanden, `fnStringIsEffectivelyEmpty(N'')` == 1
  (CREATE OR ALTER versöhnt). Belegt das Runbook-Gegenmittel.
- **Cleanup:** DB frisch restaurieren vor T1-05.

#### T1-05 — `compare-objects.sql` als Baseline-Vor-Check fängt den Rückstand
- **Ziel:** Der vom Runbook vorgeschriebene Vor-Vergleich erkennt die Drift aus T1-04
  **vor** dem Baseline.
- **Setup:** Zwei DBs auf demselben Container: `eazybusiness` (Referenz, Objekte==Repo)
  und eine zweite `eazybusiness_behind` (kopiert, dann wie T1-04 zurückgebaut). (Zweite DB
  via `BACKUP`/`RESTORE` innerhalb des Containers oder erneutem Restore.)
- **Schritte:**
  ```bash
  sqlf eazybusiness         db-migrations/tests/compare-objects.sql > /tmp/ref.txt
  sqlf eazybusiness_behind  db-migrations/tests/compare-objects.sql > /tmp/behind.txt
  diff <(sort /tmp/ref.txt) <(sort /tmp/behind.txt)
  ```
- **Erwartet:** `diff` zeigt genau die Drift: `fnStringCountLines` fehlt in `behind`,
  `fnStringIsEffectivelyEmpty` mit abweichendem `DefinitionHash`. → Signal „NICHT blind
  baselinen". Belegt Runbook Step 2.
- **Cleanup:** `eazybusiness_behind` droppen.

---

### Gruppe C — up/-Immutabilität & Hash (F1.1)

#### T1-06 — up/-Hash-Mismatch bricht grate hart ab
- **Ziel:** Ein editiertes, **bereits angewandtes** `up/`-Skript → grate-Abbruch beim
  nächsten Lauf; DB + Journal unverändert.
- **Setup:** Ebene A vollständig deployt (Journal vorhanden). Da der Repo-Baum nicht
  editiert werden darf, wird **eine Kopie der Kette** in ein Temp-Verzeichnis gespiegelt
  und dort das bereits angewandte `up/0001` verändert:
  ```bash
  TMP=/tmp/claude-*/scratchpad/eazy-hashtest; rm -rf $TMP; cp -r db-migrations/eazybusiness $TMP
  printf '\n-- benign edit to change the hash\n' >> "$TMP/up/0001_robotico_schema.sql"
  # Deploy aus dem Temp-Verzeichnis gegen dieselbe DB (docker-Runner mountet -v $TMP:/db:ro)
  pwsh -c "docker run --rm --network host --entrypoint /app/grate -v $TMP:/db:ro erikbra/grate:1.6.0 --connectionstring='Server=localhost,14330;Database=eazybusiness;User ID=sa;Password=$MSSQL_SA_PASSWORD;TrustServerCertificate=True' --schema=Robotico --environment=E2E --version=hashtest --silent --transaction --sqlfilesdirectory=/db"
  echo "grate exit: $?"
  ```
- **Erwartet:** grate **exit ≠ 0** mit One-time-Hash-Mismatch-Meldung auf
  `0001_robotico_schema.sql`. Die umschließende `--transaction` (Ebene A) rollt zurück:
  **keine** neue `Robotico.ScriptsRun`-Zeile, Objektbestand unverändert. (Beleg des
  Deploy-Time-Backstops, den Lint-Regel (i) vorgelagert abfängt.)
- **Cleanup:** Temp-Verzeichnis löschen.

#### T1-07 — Lint-Regel (i) als vorgelagertes Gate (statisch, kein Container)
- **Ziel:** Ein uncommitteter Edit an einem getrackten `up/`-Skript wird vom Lint als
  ERROR gefangen; Escape-Hatches funktionieren.
- **Setup:** Sauberer Worktree.
- **Schritte:**
  ```bash
  pwsh db-migrations/tests/lint-migrations.ps1; echo "clean exit: $?"
  # Edit simulieren (dann sofort zurücknehmen):
  printf '\n-- x\n' >> db-migrations/eazybusiness/up/0001_robotico_schema.sql
  pwsh db-migrations/tests/lint-migrations.ps1; echo "dirty exit: $?"
  LINT_ALLOW_UP_EDITS=1 pwsh db-migrations/tests/lint-migrations.ps1; echo "override exit: $?"
  git checkout -- db-migrations/eazybusiness/up/0001_robotico_schema.sql
  ```
- **Erwartet:** sauber → exit 0. Dirty → **exit ≠ 0**, Regel-(i)-ERROR „tracked up/ script
  has uncommitted modifications". Mit `LINT_ALLOW_UP_EDITS=1` → Downgrade auf Warning,
  exit 0. Danach Datei per `git checkout` wiederhergestellt (kein Commit, keine
  git-Schreiboperation über die Wiederherstellung hinaus).
- **Cleanup:** `git checkout --` (oben enthalten). **Keine** Commits.

#### T1-08 — anytime-Hash-Änderung: nur das eine Objekt läuft neu
- **Ziel:** Bestätigen der one-time-vs-anytime-Grenze mit dem Fixture-Muster.
- **Setup:** Ebene A deployt. Fixtures `fixtures/up/9900_e2e_probe_table.sql` +
  `fixtures/functions/Robotico.fnE2EProbe.sql` in eine **Kette-Kopie** (Temp-Dir, wie
  T1-06) kopieren; Deploy 1; Funktion auf VERSION 2 editieren; Deploy 2.
- **Schritte:** Deploy 1 → `fnE2EProbe(21)`==42 prüfen; Datei auf `@n*3` ändern; Deploy 2 →
  grate läuft **nur** `Robotico.fnE2EProbe.sql`, `up/9900` meldet „No sql run".
  `fnE2EProbe(21)`==63; `Robotico.tE2EProbe` weiterhin 1 Zeile; `9900`-Journalzeile
  weiterhin genau 1.
- **Erwartet:** wie 2026-07-11 B1/B2 reproduziert, aber gegen den aktuellen Baum/Container.
- **Cleanup:** `DROP FUNCTION Robotico.fnE2EProbe; DROP TABLE Robotico.tE2EProbe;` +
  deren Journalzeilen löschen; Temp-Dir entfernen.

---

### Gruppe D — Kompletter Re-Run = No-Op (F1.4)

#### T1-09 — Zweiter Lauf beider Ketten ändert nichts
- **Ziel:** Deploy #2 von Ebene B **und** Ebene A = 0 Änderungen: Journal-Delta 0,
  `ops.*`-Zeilen stabil, Agent-`job_id` stabil, Signaturen intakt.
- **Setup:** Beide Ketten einmal vollständig deployt (T1-01 + T1-02a).
- **Schritte:**
  ```bash
  # Vorher-Snapshot
  sqlq RoboticoOps "<GUARD> SELECT (SELECT COUNT(*) FROM ops.ScriptsRun) rs,(SELECT COUNT(*) FROM ops.tResetStep) steps,(SELECT COUNT(*) FROM ops.tMaintenanceJob) mj,(SELECT COUNT(*) FROM ops.tMandant) m,(SELECT CONVERT(varchar(36),job_id) FROM msdb.dbo.sysjobs WHERE name='RoboticoOps - Testmandant Reset') job,(SELECT COUNT(*) FROM sys.crypt_properties) sig;"
  npm run db:deploy:e2e:global
  npm run db:deploy:e2e
  # Nachher-Snapshot (identische Query) + Journal-Delta
  ```
- **Erwartet:** Beide Deploys melden für up/+anytime „No sql run" (permissions laufen
  everytime, erzeugen aber keine ScriptsRun-Zeilen). `ops.ScriptsRun`-Count, `tResetStep`
  (8), `tMaintenanceJob` (6), `tMandant`, **Agent-`job_id` unverändert**, `sys.crypt_properties`
  unverändert (Signaturen intakt — `900` re-signiert nur, ändert Thumbprints nicht).
  `validate_rollout.sql` grün. Exit 0.
- **Dokumentierte Nicht-No-Op-Ausnahme (separater Sub-Check, erwartet):**
  `reset.spEnsureAgentJob` re-executet **nur bei Hash-Änderung** und **THROWt 50010**, wenn
  ein `queued`/`running`-Request existiert. Provokation: `tResetRequest`-Zeile künstlich auf
  `queued` setzen und `runAfterOtherAnyTimeScripts/reset.spEnsureAgentJob.sql` in einer
  Kette-Kopie hash-ändern → Deploy soll **50010** werfen. Beleg, dass die Ausnahme
  definiert und nicht versehentlich ist.
- **Cleanup:** künstliche `queued`-Zeile zurücksetzen.

---

### Gruppe E — Teilfehlschlag & Transaktionsgrenzen (F1.5)

#### T1-10 — Ebene A: up/-Fehler mitten in der Kette → `--transaction`-Rollback
- **Ziel:** Dokumentieren+testen, ob `deploy.ps1 --transaction` (Ebene A) den **gesamten
  Lauf** oder **pro Skript** zurückrollt, wenn ein up/-Skript mittig failt; kein
  Halbzustand, sauberer Wiederanlauf.
- **Setup:** Kette-Kopie (Temp-Dir). Ein **synthetisches** failendes up/ einschieben, das
  *nach* 0001/0002 und *vor* 0003 läuft: `up/0002a_fail.sql` mit `THROW 59001,'inject',1;`.
  Zusätzlich ein bereits erfolgreiches `up/0001`/`0002` im selben Lauf (frische DB ohne
  Journal, damit beide im selben Lauf mitlaufen).
- **Schritte:** Deploy gegen frische `eazybusiness`-Kopie; danach Journal + Objektbestand
  prüfen; failendes Skript entfernen; Re-Deploy.
- **Erwartet:** grate exit ≠ 0, Fehler in `Robotico.ScriptsRunErrors`. **Zu ermittelnde
  Kernfrage (R1):** Bei grate `--transaction` ist zu verifizieren, ob 0001/0002 nach dem
  Abbruch (a) **zurückgerollt** sind (ganze Transaktion) oder (b) **committed** bleiben
  (per-Skript-Autocommit). Der Test misst es direkt: Existiert `Robotico`-Schema/PayPal-
  Tabellen nach dem Abbruch? Existiert eine `ScriptsRun`-Zeile für 0001? Erwartung laut
  `deploy.ps1`-Kommentar + Research 1-migrations-tooling: **ganze Kette rollt zurück** →
  0 ScriptsRun-Zeilen, kein Schema. Re-Deploy ohne das failende Skript läuft dann sauber
  von vorn (idempotent).
- **Cleanup:** Temp-Dir + Container-DB verwerfen.

#### T1-11 — Ebene A: anytime-Fehler unter `--transaction`
- **Ziel:** Klären, ob ein Fehler in einem **anytime**-Skript (nach erfolgreichen up/) den
  ganzen Lauf zurückrollt — d.h. ob bereits gelaufene anytime-Objekte des *selben* Laufs
  bestehen bleiben.
- **Setup:** Kette-Kopie; eine anytime-Datei alphabetisch spät (`sprocs/Zzz.fail.sql` mit
  `CREATE OR ALTER PROCEDURE … AS BEGIN THROW 59002,'x',1; END` ist syntaktisch ok →
  besser: Datei mit **Compile-Fehler**, z.B. Referenz auf nicht existente Spalte, damit
  grate beim Ausführen failt). Frische DB ohne Journal.
- **Schritte:** Deploy; prüfen, welche Objekte/Journalzeilen nach Abbruch existieren.
- **Erwartet:** Unter `--transaction` sollte der komplette Lauf zurückrollen → **keine** der
  in diesem Lauf gebauten anytime-Objekte bleibt, kein Journal. (Falls grate stattdessen
  per-Batch committet, würde ein Teil bleiben — genau das ist der zu dokumentierende
  Grenzbefund, s. R1.)
- **Cleanup:** wie T1-10.

#### T1-12 — Ebene B: up/-Fehler OHNE Transaktion → committer Halbzustand + idempotenter Wiederanlauf
- **Ziel:** Ebene B läuft ohne umschließende Transaktion; ein mittiger up/-Fehler lässt
  vorherige up/ **committed**; der nächste Lauf setzt dank `IF NOT EXISTS`-Guards sauber
  fort.
- **Setup:** Frischer Container ohne `RoboticoOps`. Kette-Kopie mit synthetischem
  `up/0002a_fail.sql` (`THROW 59003,'inject',1;`) **nach** `0002_ops_schema_tables`.
- **Schritte:**
  ```bash
  # Deploy #1 (mit Fail-Skript) — bricht bei 0002a ab
  # Prüfen: ops-Schema + tMandant/tConfig existieren (0001/0002 committed), aber 0010+ nicht
  sqlq RoboticoOps "<GUARD> SELECT OBJECT_ID('ops.tConfig') cfg, OBJECT_ID('ops.tResetStep') step, SUSER_ID('jobstartuser') login0010;"
  # Fail-Skript entfernen, Deploy #2 — muss fortsetzen ohne Kollision
  ```
- **Erwartet:** Deploy #1 exit ≠ 0; `ops.tConfig` existiert (0002 committed), aber
  `jobstartuser` (0010) noch nicht (Kette hinter dem Fehler nicht gelaufen).
  `ops.ScriptsRun` hat Zeilen für 0001/0002, **keine** für 0002a. Deploy #2 (ohne
  Fail-Skript): 0001/0002 werden **nicht** erneut ausgeführt (journaled), 0010 ff. laufen
  erstmalig, deren `IF NOT EXISTS` kollidiert nicht mit dem Halbzustand. Exit 0. Belegt
  F1.5 + die „Ebene B ohne Transaktion, aber idempotent"-Architektur.
- **Cleanup:** `db:e2e:down:full`.

---

### Gruppe F — Environment-Handling & Ketten-Reihenfolge (deploy.ps1)

#### T1-13 — E2E-Environment-Auflösung + PROD-Gate
- **Ziel:** `-Environment E2E` zielt garantiert auf `localhost,14330`; PROD ist gated.
- **Schritte:**
  ```bash
  # Dry-Run zeigt den aufgelösten Server in der grate-Kopfzeile
  npm run db:deploy:e2e -- -DryRun     # "==> grate: … env=E2E runner=docker" gegen localhost,14330
  # PROD-Gate (interaktiv) — NICHT bestätigen; Abbruch mit exit 1
  echo "N" | pwsh db-migrations/deploy.ps1 -Scope eazybusiness -Environment PROD -Target eazybusiness
  echo "prod-gate exit: $?"
  ```
- **Erwartet:** E2E-DryRun exit 0, verbindet `localhost,14330`, ändert nichts. PROD-Aufruf
  fordert Y/N, listet Ziel-DBs, bei `N` → „Aborted by user", **exit 1**. (Reiner
  Gate-Nachweis; kein PROD-Kontakt, da Abbruch vor grate.)
- **Cleanup:** keiner.

#### T1-14 — Cert-Passwort-Token-Resolution (Tiers + CQG-4-Abbruch)
- **Ziel:** Die 3-Tier-Auflösung des `{{CertPassword}}` und der Hard-Guard gegen
  Neu-Generierung bei bestehendem Zertifikat.
- **Schritte (auf frischem Container, ohne persistierten Store):**
  ```bash
  rm -f ~/.robotico-ops/grate-cert.env             # Store leeren (nur E2E-Key!)
  unset GRATE_CERT_PASSWORD
  npm run db:deploy:e2e:global                      # Tier 3: cert absent → auto-generate + persist + Einmal-Anzeige
  grep -c GRATE_CERT_PASSWORD_E2E ~/.robotico-ops/grate-cert.env
  npm run db:deploy:e2e:global                      # Tier 2: liest persistierten Store, re-signiert erfolgreich
  # CQG-4: Store fälschen → Abbruch statt neuem Passwort
  sed -i 's/GRATE_CERT_PASSWORD_E2E=.*/GRATE_CERT_PASSWORD_E2E=WrongButAlphanumeric123/' ~/.robotico-ops/grate-cert.env
  npm run db:deploy:e2e:global; echo "mismatch exit: $?"
  ```
- **Erwartet:** (1) Deploy meldet „auto-generated (first run) + persisted", zeigt das
  Passwort **einmal**, `900` signiert grün. (2) Zweiter Deploy nutzt Tier 2, „No sql run"
  für up/anytime, `900` re-signiert grün (Passwort matcht Private Key). (3) Mit falschem
  Passwort: **`900` THROW 50901** „does not match up/0011" → grate exit ≠ 0. Belegt
  Token-Immutabilität + CQG-4. (Der *echte* Autogenerate-gegen-bestehendes-Cert-Abbruch
  aus `deploy.ps1` greift nur bei leerem Store **und** bestehendem Cert — Zusatz-Sub:
  Store leeren *ohne* Container-Neubau → „Certificate … already exists, but no password is
  known … Refusing to auto-generate", exit ≠ 0.)
- **Cleanup:** korrektes Passwort aus dem Einmal-Log zurück in den Store schreiben **oder**
  `db:e2e:down:full` + Neuaufbau (frisches Cert).

#### T1-15 — Ketten-Reihenfolge global↔eazybusiness + Unabhängigkeit
- **Ziel:** Dokumentieren+belegen, dass die Ketten **unabhängig** deploybar sind, die
  empfohlene Reihenfolge (Ebene B zuerst) aber Sinn hat (RoboticoOps ist greenfield; der
  Reset referenziert `SourceDb=eazybusiness` erst zur *Laufzeit*, nicht beim Deploy).
- **Schritte:**
  ```bash
  # Frischer Container: NUR Ebene A zuerst (ohne RoboticoOps) — muss allein durchlaufen
  npm run db:deploy:e2e            # gegen eazybusiness, kein RoboticoOps nötig
  # Dann Ebene B allein — muss ebenfalls durchlaufen (RoboticoOps greenfield)
  npm run db:deploy:e2e:global
  # validate_rollout prüft die Ebene-A-Journal-Existenz cross-DB via SourceDb
  npm run db:e2e:validate
  ```
- **Erwartet:** Beide Reihenfolgen exit 0; kein Deploy-Zeit-Cross-Dependency.
  `validate_rollout.sql` prüft `@srcDb.Robotico.ScriptsRun` cross-DB — grün nur, wenn
  Ebene A auf der `SourceDb` (= `eazybusiness`) gelaufen ist. → Reihenfolge ist für den
  *Deploy* frei, für die *validate_rollout-Grünfärbung* muss Ebene A auf der SourceDb
  vorhanden sein. Diese Nuance dokumentieren.
- **Cleanup:** keiner.

---

### Gruppe G — Vollständigkeits-Nachweis (Soll-Bestand, F1-übergreifend)

#### T1-16 — Datei↔DB-Inventar-Parität nach vollständigem Deploy
- **Ziel:** Nach Ebene-A-Lauf listet `compare-objects.sql` **exakt** die Objekte, die der
  aktuelle Baum definiert (post-0003, inkl. `spVpeCheck`, ohne PayPal) — nichts fehlt,
  nichts Fremdes.
- **Setup:** Ebene A voll deployt (T1-02a-Endzustand).
- **Schritte:**
  ```bash
  sqlf eazybusiness db-migrations/tests/compare-objects.sql > /tmp/db-inventory.txt
  # Soll aus Dateien ableiten:
  { ls db-migrations/eazybusiness/functions | sed 's/\.sql$//'
    ls db-migrations/eazybusiness/sprocs   | sed 's/\.sql$//'; } | sort > /tmp/soll.txt
  # Ist (Schema.Objekt aus compare-objects, ohne Journal-Tabellen/Header):
  awk 'NF>=3{print $1"."$2}' /tmp/db-inventory.txt | grep -v 'ScriptsRun\|Version' | sort > /tmp/ist.txt
  diff /tmp/soll.txt /tmp/ist.txt
  ```
- **Erwartet:** `diff` leer für die programmierbaren Objekte. Zusätzlich **abwesend**
  (harte Negativ-Assertion): keine `spPaypal*`/`tPaypal*`-Zeile. Der Diff toleriert die
  Tabelle `tArtikelCommentary` (kein File-Pendant, Legacy) und die grate-Journal-Tabellen
  (herausgefiltert). Belegt „Objektbestand == Soll-Bestand".
- **Cleanup:** Temp-Dateien.

#### T1-17 — PayPal-Drop-Vollständigkeit in beide Adoptions-Richtungen
- **Ziel:** `up/0003` entfernt auf einer DB **mit** PayPal die 8 Objekte vollständig und
  ist auf einer DB **ohne** PayPal ein sauberes No-Op.
- **Schritte:**
  ```bash
  # Richtung 1 (mit PayPal): auf T1-02b-Ausgangs-DB — nach Deploy 0 PayPal-Objekte (in T1-02 belegt)
  sqlq eazybusiness "<GUARD> SELECT COUNT(*) FROM sys.objects WHERE (name LIKE 'spPaypal%' OR name LIKE 'tPaypal%') AND is_ms_shipped=0;"   -- erwartet 0
  # Richtung 2 (ohne PayPal): frische DB, in der 0002 nie lief (Journal so präpariert, dass 0001+0003 laufen, 0002 als applied markiert)
  # -> 0003 DROP IF EXISTS trifft nichts, exit 0, keine Fehler
  ```
- **Erwartet:** Richtung 1 → 0 PayPal-Objekte. Richtung 2 → Deploy exit 0, `up/0003` läuft
  ohne Fehler (idempotent gegen Abwesenheit), keine `ScriptsRunErrors`-Zeile.
- **Cleanup:** keiner.

#### T1-18 — Journal-Reise: Klon trägt Ebene-A-Journal, RoboticoOps bleibt greenfield
- **Ziel:** Ein per Reset erzeugter `eazybusiness_tmN`-Klon trägt `Robotico.ScriptsRun`
  identisch zur Quelle (Ebene A reist mit); RoboticoOps (Ebene B) reist **nicht** (eigene
  DB, greenfield). Ein Ebene-A-Deploy auf den Klon ist ein No-Op.
- **Setup:** Nach einem erfolgreichen Reset (T2 erzeugt `eazybusiness_tm9`) — oder minimal
  ein `BACKUP eazybusiness` + `RESTORE AS eazybusiness_tmX` im Container.
- **Schritte:**
  ```bash
  # Journal-Parität Quelle vs. Klon
  sqlq eazybusiness      "<GUARD> SELECT script_name,text_hash FROM Robotico.ScriptsRun ORDER BY script_name;" > /tmp/src-journal.txt
  sqlq eazybusiness_tm9  "<GUARD> SELECT script_name,text_hash FROM Robotico.ScriptsRun ORDER BY script_name;" > /tmp/clone-journal.txt
  diff /tmp/src-journal.txt /tmp/clone-journal.txt
  # Ebene A auf den Klon = No-Op
  pwsh db-migrations/deploy.ps1 -Scope eazybusiness -Environment E2E -Target eazybusiness_tm9   # (nur wenn tm9 in targets E2E-Liste; sonst direkt via grate-Kopie)
  ```
- **Erwartet:** `diff` leer (Journal reist byte-genau mit, weil physischer Restore). Klon
  hat **kein** eigenes `ops`-Journal/RoboticoOps (Ebene B ist eine separate Instanz-DB,
  nicht im eazybusiness-Backup). Ebene-A-Deploy auf den Klon → „No sql run". Belegt die
  Kern-Asymmetrie (README §1 NOTE) am lebenden Objekt.
- **Hinweis:** `E2E.eazybusiness`-Liste in `targets.config.json` enthält nur
  `eazybusiness`; um direkt auf `eazybusiness_tm9` zu deployen, entweder Ziel temporär via
  grate-Kopie ansprechen (wie T1-06) oder den No-Op nur per zweitem grate-Lauf gegen tm9
  nachweisen. (targets.config.json wird **nicht** editiert.)
- **Cleanup:** `eazybusiness_tm9` droppen, falls eigens für den Fall erzeugt.

---

## Abhängigkeiten & empfohlene Ausführungsreihenfolge

1. **T5-Enabler** (Container up, Restore, Guard-Snippet) — Voraussetzung für alles.
2. **T1-07, T1-13** (statisch/gate) — jederzeit, kein DB-Zustand nötig.
3. **T1-01** (Ebene-B-Genese) → **T1-14** (Cert-Tiers, nutzt frische Ebene B).
4. **T1-02a/02b** (Adoption) → **T1-16/17** (Vollständigkeit) → **T1-09** (No-Op).
5. **T1-03/04/05** (Baseline/Maskierung) — je auf frisch restaurierter DB.
6. **T1-06/08** (Hash) — Kette-Kopien, isoliert.
7. **T1-10/11/12** (Teilfehlschlag) — je frische DB, danach `db:e2e:down:full`.
8. **T1-15** (Reihenfolge), **T1-18** (Journal-Reise) — am Ende.

Fälle, die den Journal-/Objektzustand zerstören (02b, 04, 10–12), verlangen davor einen
frischen Restore bzw. `db:e2e:down:full` + `:up` — im Ablauf so gruppiert, dass teure
Restores minimiert werden.

---

## Risiken / Unklarheiten, die nur die Ausführung klärt

- **R1 — grate `--transaction`-Granularität (T1-10/11, kritischster offener Punkt).** Ob
  `--transaction` den **gesamten** Ebene-A-Lauf in *eine* Transaktion klammert (dann rollt
  ein anytime-Fehler auch erfolgreiche up/ desselben Laufs zurück) oder pro Skript/Batch
  committet, ist aus Doku + Code **nicht** eindeutig ableitbar. `deploy.ps1`-Kommentar und
  Research legen „ganzer Lauf" nahe, aber grate splittet Skripte an `GO` in Batches — das
  Zusammenspiel mit einem einzigen Transaktions-Scope über mehrere `GO`-Batches hinweg ist
  der load-bearing Befund, den erst T1-10/11 direkt messen. **Dies ist die kritischste
  erwartete Erkenntnis** (bestimmt, ob ein Ebene-A-Teilfehlschlag wirklich „alles-oder-nichts"
  ist).
- **R2 — Verhalten des Docker-Runners bei nicht-null exit.** `Invoke-Grate` gibt
  `$LASTEXITCODE` des `docker run` zurück; ob grate-interne SQL-Fehler zuverlässig als
  Container-Exit≠0 durchschlagen (vs. exit 0 mit Fehlermeldung im Log) ist bei
  `erikbra/grate:1.6.0` über Docker zu verifizieren — betrifft alle Fehler-Erwartungen
  (T1-06/10/11/12/14).
- **R3 — Journal-Zeilenzahl vs. Dateizahl exakt (T1-01).** Die genaue Erwartung „anytime-
  Zeilen == anytime-Dateien" hängt davon ab, ob grate für `permissions/`-Skripte wirklich
  **keine** `ScriptsRun`-Zeile schreibt (everytime) — im Container zu bestätigen; falls
  doch protokolliert, Erwartungswert anpassen.
- **R4 — `tArtikelCommentary` & `CustomWorkflows`-Modultabellen im Container.** Der
  Soll-Diff (T1-16) toleriert `tArtikelCommentary` und die JTL-Modul-Infrastruktur. Ob die
  getrimmte `eazybusiness` diese trägt (und ob `compare-objects.sql`s Ownership-Filter sie
  korrekt ausblendet), zeigt erst der reale DB-Inhalt — der Diff kann sonst Fremdzeilen
  enthalten, die als Filter-Erweiterung nachzuziehen sind.
- **R5 — Deploy direkt gegen `eazybusiness_tm9` (T1-18).** `targets.config.json` listet für
  E2E nur `eazybusiness`; ein sauberer `-Target eazybusiness_tm9`-Lauf ist ohne
  Config-Edit nur über eine grate-Direktinvocation (Kette-Kopie) möglich. Ob das für den
  No-Op-Nachweis praktikabel ist oder ob der Nachweis auf reinen Journal-Diff reduziert
  wird, entscheidet die Ausführung.
- **R6 — Fingerprint-Query-Portabilität (T1-03).** Die `STRING_AGG … WITHIN GROUP (ORDER BY
  object_id)`-Fingerprint-Query setzt SQL 2022+ voraus (im Container gegeben) und muss auf
  `OBJECT_DEFINITION`-NULL (Tabellen) robust sein — ggf. auf die pro-Objekt-Hashliste aus
  `compare-objects.sql` umstellen, wenn die Aggregat-Query kantig ist.
- **R7 — `git checkout` im Lint-Fall (T1-07).** Der Fall editiert kurzzeitig ein getracktes
  File und stellt es per `git checkout --` wieder her. Das ist die einzige Stelle mit
  git-Berührung; keine Commits. Falls der Worktree-Zustand das nicht toleriert (z.B.
  paralleler Agent), stattdessen Edit an einer Kette-Kopie und Lint mit `-Path` darauf.
