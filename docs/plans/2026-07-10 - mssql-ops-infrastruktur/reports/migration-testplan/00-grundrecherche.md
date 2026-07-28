---
date: 2026-07-27
author: Phase-1 Grundrecherche (Opus, Lead-Agent) + 3 Detail-Agents (excel_ekl-Transfer, Reset-Pipeline, Ebene-A/Wartung)
status: Research — Grundlage für den Migrations-Testplan
context: Phase-1-Grundrecherche für einen belastbaren Testplan der gesamten MSSQL-Ops-Migrationsinfrastruktur (beide grate-Ketten + Runner) und deren Ausführung gegen einen dedizierten Test-Container. Keine Tests ausgeführt, keine Server-Schreibzugriffe.
related-plan: ../../mssql-ops-infrastruktur.md
related-plan-2: ../../../2026-07-21 - mssql-wartung-ola/mssql-wartung-ola.md
---

# Migrations-Testplan — Phase 1: Grundrecherche & Herangehensweise

Stand des zu testenden Codes = **Arbeitskopie dieses Worktrees inkl. uncommitteter Dateien**
(PayPal-Drop `0003`, `spVpeCheckLieferantenbestellung`, `250_jobstartuser_mapping`). Der Lint
läuft auf genau diesem Stand **grün** (0 Fehler, 2 bekannte (g)-Warnungen, 62 Dateien).

Rohbefunde der drei delegierten Teilrecherchen (unverändert, mit vollen Datei:Zeile-Belegen):
`01-teilrecherche-excel-ekl-transfer.md`, `02-teilrecherche-reset-pipeline.md`,
`03-teilrecherche-ebene-a-wartung.md` (dieser Ordner). Dieses Dokument konsolidiert + dedupliziert sie.

> **Sicherheits-Invariante (gilt für ALLE nachfolgenden Phasen):** Migrationen und Tests
> laufen **ausschließlich gegen den lokalen Test-Container** (`localhost,14330`, Env `E2E`)
> bzw. dokumentierte, read-only test1-Teile. **`vm-sql2.zdbikes.local` = PRODUKTION = absolut
> tabu.** Einziger — optionaler — Prod-Kontakt ist die read-only COPY_ONLY-Backup-Beschaffung
> über die etablierte excel_ekl-Pipeline (§3.3), und auch die ist vermeidbar (§5, Frage 1).

---

## 1. Inventar der Infrastruktur

### 1.1 Die zwei grate-Ketten (`db-migrations/`)

| Scope | Ordner | Journal-Schema | Ziel-DB(s) | Inhalt |
|---|---|---|---|---|
| **Ebene A** `eazybusiness` | `eazybusiness/` | `Robotico` | jede eazybusiness-Kopie **inkl. `eazybusiness_tmN`-Klone** | `Robotico.*` + eigene `CustomWorkflows.sp*`-Aktionen |
| **Ebene B** `global` | `global/` | `ops` (in `RoboticoOps`) | genau eine Instanz-DB `RoboticoOps` | Instanz-Uniques: Logins, Zertifikat, Agent-Jobs, `ops`/`reset`/`maint`-Schemata |

Kern-Asymmetrie: **Ebene A reist mit dem Klon** (Backup+Restore trägt das `Robotico`-Journal
mit → frischer Klon kennt seinen Migrationsstand). **Ebene B ist greenfield** und hat kein
Klon-Mechanismus → jedes `up/`-Skript ist per `IF NOT EXISTS` selbst-idempotent
(`README.md:36-39`). Konsequenz für Transaktionen: `deploy.ps1` wrappt **nur Ebene A** in
`--transaction` (sauberer Rollback bei DDL-Fehler); **Ebene B läuft ohne umschließende
Transaktion**, weil `ALTER DATABASE SET`, `ALTER AUTHORIZATION`, Cross-DB-Cert- und
msdb-Writes sowie `sp_add_job` nicht in einer Multi-Statement-Transaktion erlaubt sind
(grate-Error 226; `deploy.ps1:416-424`).

### 1.2 grate-Ordnersemantik (Laufmodell)

`up/` = **einmalig**, hash-getrackt, **immutable nach erstem Apply**; `functions/`→`views/`→
`sprocs/`→`runAfterOtherAnyTimeScripts/` = **anytime** (re-run bei Hash-Änderung, `CREATE OR
ALTER`); `permissions/` = **everytime** (jeder Lauf, zuletzt). Innerhalb eines Ordners
alphabetisch (`README.md:43-66`).

### 1.3 Funktionsbereiche

- **`ops.*`-Registries** (`global/up/0001-0002`, `0020-0021`, `0023`): `tConfig` (Runtime-Knobs),
  `tMandant`, `tResetRequest`/`tResetStep`, `tMaintenanceJob`. Doku-Kontrakt:
  `docs/SQL/MSSQL-OPS-DATA-MODEL.md` muss bei DDL-Änderung mitgezogen werden (CLAUDE.md).
- **`reset.*`-Pipeline** (Testmandanten-Reset): 8 datengetriebene Steps (CloneDatabase →
  PostRestoreSecurity → InvalidateCredentials → NeutralizeWorker → AnonymizeCustomerData →
  GrantAccess → RegisterMandant → ApplyJtlRoles), gestartet über sa-owned Agent-Job, orchestriert
  von `reset.spProcessNextResetRequest`; Zertifikatssignatur + `EXECUTE AS jobstartuser`.
- **`maint.*`-Wartungssuite** (Plan `2026-07-21 - mssql-wartung-ola`): Ola Hallengren
  **4 Objekte vendored** nach `RoboticoOps.dbo` (`CommandLog`, `CommandExecute`,
  `DatabaseIntegrityCheck`, `IndexOptimize` — **kein** `DatabaseBackup`, ADR-0002/CBB), Registry
  `ops.tMaintenanceJob`, Prozeduren `spEnsureMaintenanceJobs`/`spRunMaintenanceJob`/
  `spCheckBackupChain`/`spCheckMaintenanceLiveness`/`spApplyMaintenance`, `permissions/260`
  (Operator + Agent-Mail-Profil via `xp_instance_regwrite`).
- **`permissions/250_jobstartuser_mapping`** (uncommitted, everytime): selbstheilender
  SID-Remap für verwaiste `jobstartuser`-DB-User in msdb + RoboticoOps (sonst `sp_start_job`
  DENIED nach Login-Teardown/Redeploy).
- **Ebene-A-Inhalte**: 12 `Robotico.fn*` (String/CSV-Utilities, Duplicate-Order, CustomField),
  3 `Robotico.sp*`, 8 `CustomWorkflows.sp*`-Aktionen inkl. **neuer `spVpeCheckLieferantenbestellung`**
  (uncommitted).
- **PayPal-Drop `eazybusiness/up/0003_drop_paypal_mechanic`** (uncommitted): droppt 5 Procs + 3
  Tabellen, durchgängig `DROP … IF EXISTS`, kein Clone-Guard (soll überall laufen).

### 1.4 Runner & Tooling

- **`deploy.ps1`** — grate-Wrapper: erkennt Runner automatisch (native `grate` auf PATH → sonst
  Docker `erikbra/grate:1.6.0`); Cert-Passwort 3-Tier-Resolution (Session-Env → persistenter
  Store `~/.robotico-ops/grate-cert.env` → auto-generate, hart-geguardet gegen bestehenden Cert);
  PROD-Y/N-Gate; `--transaction` nur Ebene A; `--baseline`/`--dryrun` durchreichbar.
- **`mandant.ps1`** — Wrapper um `reset.spPub_CreateTestmandant`/`ListMandants` (admin).
- **`lib/targets.ps1`** — Auth-SSoT: `Get-RoboticoSqlcmd` (bevorzugt ODBC-Build für Kerberos),
  `Invoke-RoboticoSqlcmd` (Passwort via `SQLCMDPASSWORD`, nie auf argv).
- **`targets.config.json`** — TEST=`vm-sql-test1` (SQL 2025, Windows-Auth), PROD=`vm-sql2`
  (SQL 2022, Windows-Auth, 4 DBs), **E2E=`localhost,14330`** (Container, SQL-Auth sa, Passwort
  aus `MSSQL_SA_PASSWORD`).
- **Lint** `tests/lint-migrations.ps1` — Regeln (a)–(m), exekutierbare Form des README-Kontrakts:
  kein `USE`/`GO;`, ein Objekt je anytime-Datei, verbotene Referenzen (`RoboticoEKL`,
  `spCMArtikel*`, `DROP SCHEMA`), Datei↔Objekt-Match, **kein gestrichdatiertes Datumsliteral (h)**,
  **up/ immutable (i)**, Ebene-B-Guard-Kontrakt (j), eindeutige THROW-Nummern (k),
  Struktur-Registrierung (l), englische up/-Kommentare (m).
- **Test-Skripte**: `tests/compare-objects.sql` (DB↔DB-Drift via `OBJECT_DEFINITION`-Hash),
  `tests/global/validate_structure.sql` + `validate_rollout.sql`, `tests/validate-rollout.ps1`
  (umgebungs-agnostisch, optional `-FullReset`-Roundtrip), `tests/eazybusiness/*_Tests.sql`
  (4 Suiten), `tests/probes/`, `tests/docker/` (E2E-Harness, s. §3.1).

### 1.5 Deploy-Realität auf vm-dev2 (verifiziert)

- `pwsh` 7.6.2 vorhanden; **`dotnet` NICHT auf PATH** (grate-Binary liegt zwar in
  `~/.dotnet/tools/grate`, ist aber ohne PATH-Eintrag für `deploy.ps1` unsichtbar) → E2E nutzt
  automatisch den **Docker-Runner `erikbra/grate:1.6.0`**. Für E2E ist das unkritisch (SQL-Auth,
  kein Kerberos nötig).
- `docker` 29.5.3 + `podman` 4.9.3 vorhanden; 519 GB frei.
- `sqlcmd` ODBC-Build unter `/opt/mssql-tools18/bin/sqlcmd`.
- **Bereits laufende Container**: `jtl-test-db` (excel_ekl-Dev, SQL 2022, Port 1434, mit
  `docker/mssql/backups`-Mount) — mögliche Backup-Quelle (§5). Die robotico-eigene Harness
  `robotico-e2e-mssql` (Port 14330) läuft aktuell **nicht**.

### 1.6 Bereits erfolgte Testläufe (Baseline — nicht doppeln)

| Lauf | Datum | Umfang | Grenze für diesen Testplan |
|---|---|---|---|
| **Docker-E2E** (`qg2/e2e-docker-report.md`) | 2026-07-11 | 47 PASS: Baseline-Adopt, one-time/anytime-Semantik, Reset-Pipeline 3×, 25 Paritäts-Assertions | **VOR** Naming-Rename, **ohne** Wartungssuite, **ohne** PayPal-Drop/Vpe |
| **test1-Generalprobe** (`test1-rollout-report.md`) | 2026-07-13 | beide Ketten + tm9-Reset auf realem test1; 3 Umgebungs-Bugs (Datumsliteral, Store-Korruption, sqlcmd-Resolver) gefixt | **VOR** Wartungssuite |
| **Naming-Rename** | 2026-07-13 | Ebene B auf Hungarian-Konvention (`ops.tMandant` etc.), test1 neu deployt+validiert | E2E-Container down/up seither **offen** |
| **Wartung-E2E** (`…ola/reports/e2e-report.md`) | 2026-07-22 | 13/13 auf **test1 (SQL 2025)**: Deploy, Ola-Platzierung, Registry, Jobs, Läufe, Watchdog, Liveness, Drift, Idempotenz | **NICHT im Linux-Container**; Database-Mail absent (nur PRINT); Mail-Versand = B6/prod |

**Netto-Testlücke** (nie zusammen/nie im Container mit aktuellem Baum): kompletter Container-E2E
mit **aktuellem** Stand (Rename + Wartungssuite + `0003` + Vpe + `250`), die
Wartungssuite-**Container-Spezifika**, der PayPal-Drop, `spVpeCheckLieferantenbestellung` und die
Interaktion Reset ↔ Wartung im selben (geteilten) Agent.

### 1.7 Runner-, Journal- und Baseline-Semantik (User-Bereich 1: bestehende Objekte adoptieren)

Der Kern von **Pflichtbereich 1** ("Objekte, die bereits auf einem Server vorhanden sind, werden
beim Anwenden der Ketten vollständig und korrekt übernommen") ist grates Journal- und
Baseline-Verhalten.

**Journal-Tabellen.** grate legt pro Ziel-DB im gewählten Schema drei Tabellen an: `ScriptsRun`
(jede angewandte Datei mit `text_hash`, Skript-Typ, Zeitstempel, `--version`-Stempel),
`ScriptsRunErrors`, `Version`. Ebene A journalt in Schema **`Robotico`**, Ebene B in **`ops`**
(RoboticoOps). Reale Referenz (Docker-E2E 2026-07-11): eine frisch adoptierte `eazybusiness` bekam
`Robotico.ScriptsRun` mit **27 Zeilen** (2 one-time `up/` + 25 anytime). `validate_rollout.sql`
prüft beide Journale.

**Hash-Verhalten je Klasse.** `up/` = einmal, content-hash-getrackt, **immutable** (editiertes
appliziertes up/ → Hash-Mismatch-Abbruch, Fix nur als neues `up/NNNN`); anytime = re-run **genau
bei Hash-Änderung** der Datei (`CREATE OR ALTER`; unverändert → "No sql run"); everytime = jeder
Lauf. `--runallanytimescripts` (re-run aller anytime unabhängig vom Hash) ist **PROD-verboten**,
nur Local-Dev.

**Adoption "Server hat Objekte, aber kein Journal"** (der reale PROD/test1-Fall): eine
`eazybusiness`, die unsere `Robotico.*`/`CustomWorkflows.*`-Objekte aus früheren
manuellen/PowerShell-Deploys bereits trägt, aber keine `Robotico.ScriptsRun`. Zwei Wege:
- **Baseline** (`deploy … -Baseline`): schreibt Journalzeilen für ALLE aktuellen Skripte (one-time
  **und** anytime), führt **nichts** aus. Korrekt nur wenn Datei == deployt. **Falle F1.2**: da auch
  anytime gebaselined wird, wird eine **hinter dem Repo liegende** DB still als "applied" markiert →
  alte/fehlende Objekte bleiben (real: Backup war 7 Objekte hinter Repo). Vorab-Pflichtprüfung via
  `compare-objects.sql` (DB↔DB-`OBJECT_DEFINITION`-Hash), auf Prod als Referenz-Truth.
- **Normaler Deploy** (empfohlen bei Rückstand — test1-Entscheidung D-b.2): adoptiert das Journal
  **und** versöhnt anytime-Objekte via `CREATE OR ALTER`, erzeugt Fehlende. So auf test1 gemacht
  (32→38 Objekte reconciled, 27 Journalzeilen, DryRun danach "nothing to do"). `up/` ist idempotent
  (`IF NOT EXISTS`), läuft also gefahrlos "nach".

**Restored-Database-Szenario.** Ebene A **reist mit dem Klon** — Backup+Restore trägt
`Robotico.ScriptsRun` mit; der frische Klon kennt seinen Migrationsstand ohne erneuten Deploy.
Ebene B hat **kein** Klon-Mechanismus, wird nie baselined (greenfield, jedes `up/` selbst-idempotent).
Ein restauriertes Backup, dessen mitgereistes Journal **älter** ist als der Repo-Stand, ist genau der
Adoptionstest: das Delta muss ein normaler Deploy per `CREATE OR ALTER` schließen, ohne die
immutablen `up/`-Hashes zu verletzen.

**Testfälle User-Bereich 1** (→ Agent T1): (1) restauriertes `eazybusiness` ohne Journal → normaler
Deploy adoptiert + reconciled (Journalzeilen zählen); (2) Baseline derselben DB → 0 ausgeführt,
Journal gesetzt, DryRun danach = nothing to do; (3) **A2-Maskierung reproduzieren** (anytime-Zeilen
im Journal trimmen → Objekte bleiben stale bis erzwungenem Re-Apply); (4) `compare-objects.sql` gegen
zwei DBs → Drift sichtbar; (5) editiertes appliziertes `up/` → Hash-Mismatch-Abbruch; (6) zweiter
kompletter Lauf **beider** Ketten = No-Op (außer der `spEnsureAgentJob`-Ausnahme, F1.4).

---

## 2. Fehlerklassen-Katalog

Gruppiert; jede Klasse mit Begründung/Quelle. Diese Liste ist die Rohmenge, aus der die
Detail-Agents (§4) ihre Testfälle ableiten.

### F1 — Runner / Journal / Baseline-Semantik ("bestehende Migrationen")

- **F1.1 up/-Hash-Mismatch.** Ein editiertes, bereits angewendetes `up/`-Skript → grate bricht
  beim nächsten Lauf mit Hash-Mismatch ab (QG3-C1-Incident). Lint-Regel (i) fängt uncommittete
  up/-Edits ab; Deploy-Time bleibt grate der harte Backstop (`README.md:147-155`).
- **F1.2 Baseline maskiert Rückstand.** `grate --baseline` journalt **auch die anytime-Skripte**
  → eine hinter dem Repo liegende DB wird still als "applied" markiert, die alten/fehlenden
  Objekte bleiben (real: Jul-08-Backup war 7 Objekte hinter Repo; `e2e-docker-report.md §A2`).
  Gegenmittel: normaler Deploy (`CREATE OR ALTER` versöhnt) statt Baseline, oder Vorab-Vergleich
  via `compare-objects.sql` (`migrations-baseline.md`).
- **F1.3 Journal-Reise Ebene A vs. greenfield Ebene B.** Restaurierter Klon trägt `Robotico`-Journal
  mit; RoboticoOps hat keins → Idempotenz-Guards müssen greifen.
- **F1.4 Kompletter Re-Run muss No-Op sein.** Zweiter Deploy beider Ketten = 0 Änderungen
  (up/ journaled, MERGE `WHEN NOT MATCHED`, permissions bei Bedarf). **Nicht-No-Op-Ausnahme**:
  `reset.spEnsureAgentJob` droppt/recreated den Job bei Hash-Änderung und **THROWt 50010**, wenn
  ein `queued`/`running`-Request existiert (`reset.spEnsureAgentJob.sql:43-59`).
- **F1.5 Teilfehlschlag Ebene B ohne Transaktion.** Fällt ein `up/`-Skript mitten in der Kette,
  bleiben vorherige committed → nächster Lauf muss sauber fortsetzen (Idempotenz). Ebene A rollt
  per `--transaction` zurück.

### F2 — Reset-Pipeline (Testmandanten-Reset)

Referenzen relativ `db-migrations/global/`.

- **F2.1 Clone-Guard/THROW-Matrix.** Jeder Step + Entry prüft `= 'eazybusiness'` bzw.
  `NOT LIKE 'eazybusiness[_]%'` → distinkte THROW-Codes (51003 Start:56, 51010/20/…/80 je Step,
  51005 Whitelist `spProcessNextResetRequest.sql:139-146`); Orchestrator-Re-Validierung markiert
  `failed` ohne THROW (`:102-113`); Backstop `CK_tMandant_cTargetDb` (`up/0002:48-51`).
- **F2.2 Teilfehlschlag + Transaktionsgrenzen.** **Keine** umschließende Transaktion
  (`spProcessNextResetRequest.sql:28-29`, BACKUP/RESTORE-bedingt); Steps auto-committen →
  halb-anonymisierter Klon bleibt zur Diagnose. `bCritical=1` → outer CATCH, `MULTI_USER`
  best-effort, Row `failed` (`:189-231`); `bCritical=0` → WARN in `cStepLog`, weiter (`:158-172`).
  Weitere konkrete Container-Testfälle: **Secret-Scrubbing** (`cShopLicense` wird aus persistierten
  Fehlertexten entfernt, Sec-I1 `:99,166-171,216-219` — Fehler provozieren, der den Wert echot);
  **Mid-RESTORE-Kill** (Session während RESTORE killen → Klon bleibt `RESTORING`, nächster Lauf
  droppt ihn, B10/I5 `CloneDatabase.sql:69-92`); **Cursor-Vergiftung** (Fehler außerhalb eines Steps
  darf Folge-Requests nicht mit Cursor-Fehler 16915 vergiften, B2 `:194-203`).
- **F2.3 Agent-Job/msdb-Abhängigkeit.** Container-Agent default AUS →
  **`MSSQL_AGENT_ENABLED=true` Pflicht**. **Verdacht (im Container zu verifizieren):** bei
  Agent-down wirft `sp_start_job` ebenfalls 22022, und das Start-SP schluckt 22022 als "job
  already running" (`spPub_StartTestmandantReset.sql:86-100`) → Row bliebe still `queued`.
  Umgeht der synchrone Testpfad (`EXEC reset.spProcessNextResetRequest`, durch Applock B3 gedeckt).
- **F2.4 StaleRunningHours-Reclaim.** `tConfig`-Knob, `ISNULL(TRY_CONVERT,4)`, Vergleich gegen
  `dStarted`; Reclaim erst beim nächsten Pipeline-Lauf (`:47-60`). Sofort-Weg
  `spPub_CancelResetRequest` (51007-Guard gegen aktiven Job; **`syssessions`-leer-Fall auf frischer
  Instanz testen**, `spPub_CancelResetRequest.sql:83-93`).
- **F2.5 Windows-Pfade `E:\…` im Linux-Container.** Seeds `E:\work\…` + `E:\MSSQL\Data`
  (`up/0020:29-30`) ungültig → `xp_create_subdir`/BACKUP scheitern → **Vorab `UPDATE ops.tConfig`
  auf `/var/opt/mssql/…`**. MOVE-Pfad wird mit `\` konkateniert (`CloneDatabase.sql:56`) —
  Mischpfad-Toleranz auf Linux verifizieren (im 2026-07-11-Lauf tolerant).
- **F2.6 Zertifikat/Datumsliteral/Locale.** `EXPIRY_DATE '29991231'` (Basic-ISO, sprachneutral,
  `up/0011:43-47`, Lint-Regel h nach test1-Incident) → Testfall German-Default-Language-Login.
  Falsches `{{CertPassword}}` beim Re-Deploy → THROW 50901 (`900:43-60`).
- **F2.7 Permission gegen fehlende Logins.** `ZDBIKES\sql-jtl-users` fehlt → PRINT-Skip, Deploy
  grün (`100_grants.sql:42-45`); `dbuser_dev_dana_for_development` fehlt → GrantAccess WARN-Skip,
  Reset `succeeded` **aber niemand hat db_owner** (`spInternal_GrantAccess.sql:31-37`).
- **F2.8 Signatur-Kette/`250`-Remap.** `CREATE OR ALTER` strippt Signatur → `permissions/900`
  re-signiert everytime alle EXECUTE-AS-Procs; `250` heilt verwaiste `jobstartuser`-User nach
  Login-Teardown → sonst `sp_start_job` DENIED. Signatur-Überleben über Re-Deploy prüfen (TC-M5).
- **F2.9 CloneDatabase/RESTORE + Collation-Assert.** `RESTORE … WITH MOVE` aus `sys.master_files`
  (alle Files, CQG-2, `:55-64`), REPLACE, dann RECOVERY SIMPLE; `RESTORING`-Leiche wird gedroppt.
  **Container-Blocker: `up/0001` Collation-Assert THROW 50001** — Default-Container-Collation
  `SQL_Latin1_General_CP1_CI_AS` ≠ `Latin1_General_CI_AS` → Container **mit
  `MSSQL_COLLATION=Latin1_General_CI_AS` starten** (Harness tut das).

### F3 — Wartungssuite (Container-Spezifika, bisher NUR auf test1 getestet)

Referenzen relativ `db-migrations/global/`.

- **F3.1 `xp_instance_regread`/`regwrite` unter Linux.** `260:60-77` setzt das Agent-Mail-Profil
  per Registry-XP. Linux hat eine Registry-Emulation; die XPs werfen i.d.R. keinen Fehler, aber
  ob der Agent den Wert liest ist **unsicher** — dokumentierter Linux-Weg ist
  `mssql-conf sqlagent.databasemailprofile`. **Im Container verifizieren** (regread leer? regwrite
  ok? Mail-Profil aktiv?).
- **F3.2 Database Mail unter Linux.** Profil `Standard SMTP` fehlt → `260:55-56` macht nur PRINT
  statt Phantom-Set, Deploy grün. Operator `sp_add_operator` (`260:41-44`) funktioniert überall.
- **F3.3 Operator-Notify-Konvergenz (D29).** Erster Ensure ohne Operator → NotifyLevel 0
  (`spEnsureMaintenanceJobs.sql:56-57,92-94`); `260` legt Operator an + ruft ensure unconditional
  (`260:87-88`) → Drift → Recreate mit Notify. **Kerntest.**
- **F3.4 Backup-Chain-Watchdog Falsch-Alarme.** Leere msdb-History → `'NEVER'` → THROW 51100 by
  design (`spCheckBackupChain.sql:80-81`); Watchliste `'eazybusiness,RoboticoOps,msdb'`
  (`spApplyMaintenance.sql:47`) — fehlt eine DB im Container → **Invalid-Target-51100 VOR** dem
  Freshness-Check (D32). Log-Zweig nur `recovery_model <> SIMPLE` (`:94`) → im Container oft SIMPLE
  → für Log-Test eine DB auf FULL. Zeitbasis `SYSDATETIME` (`:66`, Container meist UTC).
- **F3.5 Liveness First-Run-Grace.** Schalter `'0'` → sofort RETURN (`:61-66`); Grace 26h/192h über
  `dModified` (`:82-86`) → frisch gemergte Rows alarmieren nicht; Staleness-Test = `dModified`
  zurückdatieren → 51105 (`:94-98`).
- **F3.6 `MaintenanceSchedulesEnabled`-Schalter.** Effektiv-Gleichung: `bEnabled=1 AND cValue<>'0'`;
  der Key ist **nirgends geseedet** (`up/0001` legt ihn nicht an) → **fehlender Key = ENABLED**. Im
  frischen Container kommen die Jobs beim Erstlauf daher **enabled** hoch — anders als test1, das `'0'`
  explizit setzte (T3-Befund). `'0'` → Jobs disabled, `sp_start_job` geht trotzdem (D34). Setup-Strategie:
  Phase A `'0'` kontrolliert, Phase B unset (prod-nah) — **beide Zustände testen**.
- **F3.7 Drift-Recreate verliert Job-History**; Running-Guard über `sysjobactivity` session-scoped;
  Engine-Floor Ebene B: `IS DISTINCT FROM` = SQL 2022+.

### F4 — Ebene-A-Inhalte

Referenzen relativ `db-migrations/eazybusiness/`.

- **F4.1 Custom-Workflow-Modul nicht gebucht.** Alle 8 CW-Dateien guarden `_CheckAction`/
  `_SetActionDisplayName` (IF OBJECT_ID … ELSE PRINT) → Deploy grün. **Aber: fehlt das Schema
  `CustomWorkflows` komplett, schlägt `CREATE PROCEDURE` fehl** — kein Skript legt es an
  (ungesicherte Annahme, im Container prüfen).
- **F4.2 Create-Time-Abhängigkeiten.** Funktionen ohne deferred resolution failen beim CREATE ohne
  JTL-Schema; `spAuftragPreiseAufNull` braucht den TVP-Typ beim CREATE
  (`sprocs/CustomWorkflows.spAuftragPreiseAufNull.sql:34`); `spVpeCheck` failt erst zur Laufzeit
  (2812) ohne Vendor-SP.
- **F4.3 SQL-2022+-Floor.** `STRING_SPLIT(…, 1)` (enable_ordinal): `fnEscapedCSVParseLine:30`,
  `fnEscapedCSVGetField` (transitiv), `fnStringTrimToMaxLines:41`, `spArticleAppendLabelHistory:77`.
  CREATE gelingt auf älterer Engine, **FAIL erst zur Laufzeit** → Testfall Klon mit niedrigem
  Compat-Level. `fnFindDuplicateOrders` (STRING_AGG) nur 2017+.
- **F4.4 Parser-Randfälle (ungetestet).** US-Format `'1,234.56'` → `fnStringParseGermanDecimal`
  liefert **stillen Falschwert** statt NULL; `fnStringTrimToMaxLines` über Nur-Leerzeilen → NULL;
  `Sanitize`-`@defaultValue` >100 Zeichen wird gekappt (NVARCHAR(100)).
- **F4.5 Duplicate-Order-Lücken.** Freiposition mit `kArtikel` NULL UND `cArtNr` NULL → NULL fällt
  aus STRING_AGG → Fingerprint-Kollisionsrisiko (`functions/Robotico.fnFindDuplicateOrders.sql:72`);
  Auftrag ohne nType-0/1-Position wird nie Duplikat.
- **F4.6 `spGebindeErstellen` NICHT idempotent.** Jeder Lauf INSERTet eine weitere `tGebinde`-Zeile
  und hängt das Suffix erneut an (kein Bereits-Suffix-Guard,
  `sprocs/CustomWorkflows.spGebindeErstellen.sql:85-101`) → Doppel-Trigger = Datenmüll.
  **Entscheidung nötig (Bug vs. akzeptiert), s. Frage 5.**
- **F4.7 `spVpeCheckLieferantenbestellung` (NEU) Trigger-Interaktion.** Direkt-UPDATE auf
  `tLieferantenBestellungPos` wird vom Guard-Trigger gerollbackt → nutzt Vendor-SP
  `spLieferantenBestellungPosBearbeiten` (Full-Overwrite, darf `fMenge`/`fMengeGeliefert` nicht
  anfassen); Head-Marker `{{VPE Error}}` in `cFremdbelegnummer` per ungatetem Direkt-UPDATE.
  Fehlerregel `pos.fEKNetto >= 1.5*la.fEKNetto AND la.fEKNetto>0`.
- **F4.8 PayPal-Drop `0003`.** Droppt 5 Procs + 3 Tabellen, `DROP … IF EXISTS` durchgängig →
  idempotent und robust gegen nicht-vorhanden. Testfall: Adoption auf DB **mit** PayPal-Objekten
  (Drop greift) **und ohne** (No-Op). Pre-Flight (Workflows 127/128/129 in Wawi deaktivieren) ist
  human/außerhalb SQL.
- **F4.9 Testabdeckung Ebene A.** Gut: `StringAndCSVUtilities_Tests`, `DuplicateOrders_Tests`,
  `CustomFieldAPI_Tests`, `HistorySPs_Tests`. **Ungedeckt: KEINE Tests** für
  `spAuftragPreiseAufNull`, `spGebindeErstellen`, `spSeriennummerStandardZuWMS`,
  `spZustandartikelLieferantSetzen`, `spVpeCheck`, `0003`-Drop-Verifikation; sowie 2627-Race,
  `kSprache≠0`, Self-Healing-Kernfall (QG3-B6).

### F5 — Umgebungs-/Plattform-Matrix

- **F5.1 SQL-Version + Restore-Richtung.** Restore nur **alt→neu**. Container = **2022** (Prod-Parität,
  strengerer STRING_SPLIT-Floor). Quelle muss **≤ 2022** sein → **NIEMALS test1 (2025) als
  Backup-Quelle**; Prod `vm-sql2` (2022) oder ein bereits restauriertes 2022-Backup.
- **F5.2 Locale/Collation.** German-Login `DATEFORMAT dmy` (Datumsliteral-Falle, F2.6);
  `Latin1_General_CI_AS` (nur bei First-Volume-Init, sonst Teardown+Neubau).
- **F5.3 Linux-Container-Grenzen.** Grundsätzlich **nicht** im Container: AD/Windows-Auth (Kerberos,
  `ZDBIKES`-Gruppen), echter Database-Mail-Versand, JTL-Worker/WaWi-Client-Interaktion,
  CBB-Backup-Kette, echter Prod-Blast-Radius von RegisterMandant. **Testbar**: die komplette Reset-
  und Wartungs-Logik, alle Guards/THROWs/Idempotenz, Signaturkette (SQL-Auth), Collation/Locale
  via Env.
- **F5.4 Permission-Skripte gegen nicht existierende Logins/User** (Zusammenfassung F2.7): Deploy
  muss grün bleiben, aber die funktionalen Konsequenzen (kein db_owner) sichtbar werden.

---

## 3. Umgebungsplan (lokal, vm-dev2) — nur Konzept, noch kein Aufbau

### 3.1 Container: die vorhandene robotico-Harness (`db-migrations/tests/docker/`) — Ist-Zustand

`db-migrations/tests/docker/` ist eine **fertige, prod-paritäre E2E-Harness** und der klare
Default; sie muss nicht neu erfunden werden.

**Vorhandene Bausteine (Ist-Stand):**

| Datei | Rolle |
|---|---|
| `docker-compose.yml` | Container `robotico-e2e-mssql`, Compose-Projekt `robotico-e2e`, Image `mssql/server:2022-latest`, **Port 14330**→1433, Developer-Edition, **`MSSQL_AGENT_ENABLED=true`**, **`MSSQL_COLLATION=Latin1_General_CI_AS`**, `MSSQL_MEMORY_LIMIT_MB=3584`, Named Volume `robotico-e2e-mssql-data`, Healthcheck (`SELECT 1`) |
| `entrypoint.sh` | fixt Named-Volume-Ownership (`chown mssql:root`), dropt dann auf `mssql`-User |
| `setup.ps1` | generiert `.env.local` (Secrets `MSSQL_SA_PASSWORD`+`GRATE_CERT_PASSWORD`, `chmod 600`), `up -d`, wartet healthy (4 min), verifiziert **`SELECT 1` + Agent Running (Hard-Fail) + Collation (Warn+Fix)** |
| `teardown.ps1` | `down -v` (Container + Volume); `-PurgeSecrets` löscht auch `.env.local` |
| `validate.ps1` | `validate_structure.sql` gegen die Container-`RoboticoOps` (SQL-Auth) |
| `copy-logins.ps1` | spiegelt reale **SQL**-Logins (SID+Hash-erhaltend) von `vm-sql-test1` in den Container (AD-Logins per Design übersprungen) — für SID-genaue Orphan-/Grant-Tests |
| `fixtures/up/9900_e2e_probe_table.sql` + `fixtures/functions/Robotico.fnE2EProbe.sql` | one-time/anytime-Probe-Objekte (NICHT in der Kette) für den Hash-Redeploy-Test |
| `.env.example` / `.gitignore` | committtetes Template / hält `.env.local` aus git |

**npm-Einstiege:** `db:e2e:up`/`:down`/`:down:full`, `db:deploy:e2e`(`:global`), `db:e2e:validate`,
`db:e2e:copy-logins`, plus die generischen `db:validate:e2e` / `db:mandant:*`.

**Aktueller Laufzeitzustand (verifiziert):** Der `robotico-e2e-mssql`-Container **läuft derzeit
nicht** (auf 14330 ist nichts aktiv; der laufende `jtl-test-db` gehört excel_ekl, Port 1434). Ein
frischer `db:e2e:up` ist **ohnehin fällig**: die Harness wurde zuletzt **vor** dem Naming-Rename
gebaut (`test1-rollout-report.md`-Open-Item „E2E-Container down/up pending" — die one-time-Hashes von
`0011`/`0002` haben sich seither geändert), und Wartungssuite + PayPal-Drop kamen erst danach dazu.

**Content-Lücke by design:** Die Harness liefert **nur die leere Engine**; die `eazybusiness`-DB
kommt separat aus der excel_ekl-Pipeline (README §5). Ebene B (RoboticoOps) braucht keine
restaurierte DB (grate legt `RoboticoOps` an) — d.h. der komplette Ebene-B-Teil (inkl. Signaturkette,
Registries, Wartungssuite) ist **ohne Backup** testbar; nur Ebene A + der Reset-Klon brauchen die
restaurierte `eazybusiness` (§3.3).

### 3.2 grate-Runner lokal

Kein `dotnet` auf PATH → `deploy.ps1 -Environment E2E` nutzt automatisch den **Docker-Runner
`erikbra/grate:1.6.0`** (Host-Network, SQL-Auth). Passt; der Docker-Runner kann kein Kerberos, was
für E2E irrelevant ist. Optional native: `~/.dotnet/tools` in PATH (Frage 6).

### 3.3 Backup-Beschaffung — bevorzugt das vorhandene getrimmte Backup (prod-frei)

**Primärweg (empfohlen, kein Prod-Kontakt): das bereits vorhandene getrimmte Backup nutzen.** Unter
`/home/lukas/WebStorm/excel_ekl/…/docker/mssql/backups/` liegt bereits
`eazybusiness_excel_ekl_copy_trimmed.bak` (**~1,86 GB**, Stand **2026-07-16**, getrimmt,
schema-vollständig, SQL-2022-Quelle → 2022-Container ok; Vorab-Check `RESTORE HEADERONLY`,
`SoftwareVersionMajor ≤ 16` — T5). Damit lässt
sich der robotico-Container **ohne jeden Zugriff auf `vm-sql2` oder test1** befüllen: `.bak` per
`docker cp` in das `robotico-e2e-mssql`-Backups-Verzeichnis, dann
`RESTORE DATABASE [eazybusiness] … WITH MOVE, REPLACE` gegen `localhost,14330`. **Vorbehalt:** Alter
des Backups prüfen (Objektstand für den Adoptionstest T1 relevant — ein leicht veralteter Stand ist
für User-Bereich 1 sogar wünschenswert, weil er echtes Delta erzeugt).

**Alternativ-/Auffrischweg (nur wenn ein frischer Prod-Stand nötig ist): die excel_ekl-Pipeline.**
Einstieg `/home/lukas/WebStorm/excel_ekl/scripts/test-db-jtl.ts`
(`npm run test-db-jtl -- <cmd>`). Relevante Kommandos: `full` (End-to-End) bzw. Einzelschritte
`backup` → `trim` → `export` → `transfer`.

- **Backup**: `BACKUP DATABASE [eazybusiness] … WITH COPY_ONLY, COMPRESSION, INIT` gegen
  **`vm-sql2.zdbikes.local` (PROD, SQL ≤ 2022, read-only, COPY_ONLY** — stört keine Backup-Chain).
- **Trim**: aggressiv, **kein** Teil-Restore — voller Restore der Zwischen-DB
  `eazybusiness_excel_ekl_copy`, dann BLOB-/Log-/History-Tabellen leeren (FK-safe
  Save→Drop→Nullify→TRUNCATE→Recreate WITH NOCHECK), Bild-Konsolidierung, DBCC CHECKDB. Ergebnis
  **~2–5 GB**; Tabellenlisten sind erweiterbare Konstanten in `trim.ts`.
- **Export/Transfer**: getrimmtes `eazybusiness_excel_ekl_copy_trimmed.bak` → Staging
  `\\vm-sql2\work\EKL-TestDB\Backups`; Linux-Transfer per `smbclient --use-kerberos=required`
  (benötigt `kinit lukas@ZDBIKES.LOCAL`) nach `excel_ekl/…/docker/mssql/backups/`.
- **Übertragung in den robotico-Container**: die getrimmte `.bak` liegt danach lokal → per
  `docker cp` in das `robotico-e2e-mssql`-Backups-Verzeichnis kopieren und
  `RESTORE DATABASE [eazybusiness] … WITH MOVE, REPLACE` gegen `localhost,14330` fahren. (Die
  excel_ekl-`docker`-Kommandos restaurieren in **deren** Container `jtl-test-db`/1434; wir nutzen
  nur die erzeugte `.bak`.)

**Trim-Machbarkeit**: gegeben. Minimal-Fixtures reichen NICHT — `InvalidateCredentials`/
`NeutralizeWorker`/`AnonymizeCustomerData P1` referenzieren `tEMailEinstellung`/`ebay_user`/
`tOauthConfig`/`tShop`/`tkunde`/`tAdresse` **ungeguardet**; die getrimmte, aber schema-vollständige
Kopie ist der richtige Umfang.

### 3.4 Konkrete technische Guards (Sicherheits-Invariante)

1. **Deploy nur mit explizitem `-Environment E2E`** → `targets.config.json` zeigt E2E auf
   `localhost,14330`. Für Tests **niemals** `-Environment PROD` aufrufen.
2. **Guard-Header am Kopf jedes Testskripts** (`:r`-Include). **T5-Verfeinerung:** kein positiver
   `@@SERVERNAME=Container`-Match (unzuverlässig), sondern **Multi-Signal-Deny** — `MachineName`/
   `@@SERVERNAME`-Denylist (`vm-sql2`) **+** `IsIntegratedSecurityOnly=0` (Container nutzt SQL-Auth)
   **+** Developer-Edition; THROW-Range 59001–59003/59010 (kollisionsfrei zur Lint-Regel k). Voller
   copy-paste-fertiger Code + Bash/pwsh-Host-Whitelist-Wrapper stehen im T5-Deliverable
   (`T5-umgebung-guards.md`, Guards G1/G2).
3. **Env-Var-Whitelist**: für E2E nur `MSSQL_SA_PASSWORD` (+ optional `GRATE_CERT_PASSWORD`);
   keine PROD/TEST-Credentials in die Test-Shell exportieren.
4. **Eingebaute Guards bleiben scharf**: Reset-Clone-Guards (`NOT LIKE 'eazybusiness[_]%'` + THROW),
   PROD-Y/N-Gate in `deploy.ps1`/`mandant.ps1`, `-FullReset` verweigert PROD in
   `validate-rollout.ps1`.
5. **Backup-Quelle**: bevorzugt read-only COPY_ONLY über die etablierte excel_ekl-Pipeline —
   oder ganz ohne Prod (Frage 1).

---

## 4. Themenschnitt für Detail-Agents

Fünf Themengebiete (je: Scope · Fehlerklassen · erwartete Artefakte). T5 ist Voraussetzung für
T1–T4 (liefert Container + Backup).

**T1 — Runner/Journal/Baseline-Semantik (Bereich „bestehende Migrationen")**
- Scope: Adoption/Drift des **aktuellen** Baums (Rename + Wartung + `0003` + Vpe + `250`) auf einer
  restaurierten `eazybusiness`; `compare-objects.sql`-Vergleich; Baseline vs. normaler Deploy;
  up/-Immutabilität + Hash-Redeploy; kompletter Re-Run = No-Op (beide Ketten); Teilfehlschlag
  Ebene B ohne Transaktion; Lint als Gate.
- Fehlerklassen: F1.1–F1.5.
- Artefakte: Baseline-/Drift-Testskripte + Reproduktion des A2-Maskierungsfalls; Report.

**T2 — Reset-Pipeline E2E**
- Scope: voller 8-Step-Reset gegen getrimmten Klon; **Agent-Job-Pfad UND synchroner
  `EXEC`-Pfad**; Clone-Guard/THROW-Matrix; `bCritical`-Teilfehlschlag; StaleRunningHours-Reclaim +
  Cancel (queued/running/`syssessions`-leer); Signatur-Überleben Re-Deploy; `250`-Orphan-Remap;
  `tConfig`-Pfad-Repoint.
- Fehlerklassen: F2.1–F2.9.
- Artefakte: Reset-Testsuite + Guard-/THROW-Nachweise; Report.

**T3 — Wartungssuite E2E im Linux-Container** (höchste Neuheit)
- Scope: Ola-Vendored-Objekte + `spEnsure`/`spRun`/`spCheck*`/`spApply`; **`xp_instance_reg*` unter
  Linux**; Database-Mail-Verhalten (PRINT-Pfad); Operator-Konvergenz D29; Backup-Chain-Watchdog
  Falsch-Alarm-Matrix (leere History / Invalid-Target / SIMPLE / UTC); Liveness First-Run-Grace +
  Staleness; `MaintenanceSchedulesEnabled` `'0'` vs. unset; idempotenter Re-Deploy (0/0);
  Interaktion mit dem geteilten Agent (Reset läuft parallel).
- Fehlerklassen: F3.1–F3.7.
- Artefakte: Wartungs-Testsuite + Container-Spezifika-Report (was Linux kann/nicht kann).

**T4 — Ebene-A-Inhalte + Funktionstest**
- Scope: alle Funktionen/Procs gegen reales JTL-Schema; **Vollabdeckung der bisher ungetesteten
  4 Aktionen** + `spVpeCheck` + `0003`; Parser-/Duplicate-Order-/CustomField-Randfälle;
  `spGebinde`-Nicht-Idempotenz; Modul-nicht-gebucht-Pfad; SQL-2022-Floor bei niedrigem
  Compat-Level.
- Fehlerklassen: F4.1–F4.9.
- Artefakte: erweiterte `*_Tests.sql`; Report inkl. Bug/Design-Entscheidungen (spGebinde).

**T5 — Umgebungs-/Plattform-Matrix + Guards** (Enabler)
- Scope: Container-Aufbau (Harness down/up), Backup-Beschaffung + Trim über excel_ekl,
  `.bak`-Übertragung in den robotico-Container, Version/Locale/Collation-Matrix, die vier Guards
  aus §3.4, grate-Runner-Wahl.
- Fehlerklassen: F5.1–F5.4.
- Artefakte: Umgebungs-Runbook + Guard-Skript-Bausteine (Servername-Assertion) für T1–T4.

---

## 5. Offene Fragen an den User (echte Entscheidungen)

1. **Backup-Quelle.** Das vorhandene getrimmte `eazybusiness_excel_ekl_copy_trimmed.bak` (~1,86 GB,
   §3.3) nutzen — **Prod bleibt komplett unberührt** — **oder** die excel_ekl-Pipeline für einen
   frischen COPY_ONLY-Stand read-only gegen **PROD `vm-sql2`** laufen lassen? *(Empfehlung: das
   vorhandene `.bak` — es reicht für alle Testfälle, ein leicht veralteter Objektstand ist für den
   Adoptionstest T1 sogar nützlich; frischer Stand nur, wenn Prod-Parität des Dateninhalts zwingend
   ist.)*
2. **Umfang der Ebene-A-Funktionstests.** Nur neue/geänderte Objekte (`spVpeCheck`, `0003`),
   **oder** Vollabdeckung inkl. der 4 bisher ungetesteten Aktionen (`spAuftragPreiseAufNull`,
   `spGebindeErstellen`, `spSeriennummerStandardZuWMS`, `spZustandartikelLieferantSetzen`)?
   *(Empfehlung: Vollabdeckung — die Lücke ist real, F4.9.)*
3. **Database-Mail im Container.** Nur PRINT-Pfad + Struktur/Operator-Verdrahtung testen, **oder**
   echten SMTP-Versand mit einem Test-SMTP aufsetzen? *(Bisher war Mail-Versand B6/prod-only.)*
4. **`spGebindeErstellen`-Nicht-Idempotenz (F4.6).** Als **Bug fixen** (Bereits-Suffix-/Existenz-Guard)
   oder als dokumentiertes akzeptiertes Verhalten belassen? Der Testplan deckt es auf — Entscheidung
   nötig, bevor ein Testfall es als PASS/FAIL wertet.
5. **grate-Runner lokal.** Docker `erikbra/grate:1.6.0` (Default, kein dotnet nötig) akzeptieren,
   oder `~/.dotnet/tools` in PATH für den nativen Runner? *(Empfehlung: Docker-Runner — reproduzierbar,
   keine PATH-Persistenz-Falle.)*
6. **Reset↔Wartung-Interaktion.** Sollen beide Suiten im **selben** Container-Lauf gegeneinander
   getestet werden (geteilter Agent, Schalter `'0'` als Gate), oder je isoliert? *(Empfehlung:
   beides — der geteilte Agent ist ein realer Prod-Zustand.)*
