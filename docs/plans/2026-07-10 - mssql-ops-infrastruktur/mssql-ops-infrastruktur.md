# Infrastruktur: MSSQL-Ops — Migrationsfundament, RoboticoOps-DB, Testmandanten-Reset

**Status:** Detailed
**Created:** 2026-07-10
**Repo:** JTL-Robotico
**Branch / Worktree:** feature/mssql-ops-infrastruktur (in worktrees/feature/mssql-ops-infrastruktur)
**Complexity:** Large
**Estimated Plan Size:** ~1400 lines
**Modular?:** No — Detail flach in §1–§7; die Research-Subspecs unter `research/` sind Evidenz, nicht Architektur-Auslagerung
**archive_target:** 2026-07-10 - mssql-ops-infrastruktur

**Research Outputs:**
- [research/1-migrations-tooling/1-migrations-tooling.md](research/1-migrations-tooling/1-migrations-tooling.md) — Tooling-Vergleich (grate/DbUp/Flyway/DACPAC) + grate-Vertiefung inkl. Migrationsplan der Bestandsdateien
- [research/1.1-ekl-runner-grenze/1.1-ekl-runner-grenze.md](research/1.1-ekl-runner-grenze/1.1-ekl-runner-grenze.md) — Grenzanalyse EKL-Runner (excel_ekl): geteilte CustomWorkflows-Zone, konsumierte APIs, Lessons
- [research/2-instanz-survey/2-instanz-survey.md](research/2-instanz-survey/2-instanz-survey.md) — Ist-Zustand vm-sql-test1 (SQL 2025) / vm-sql2 (SQL 2022): DBs, Prinzipale, Jobs, Worker-Flags, Queues
- [research/3-module-signing-agent-job/3-module-signing-agent-job.md](research/3-module-signing-agent-job/3-module-signing-agent-job.md) — Module Signing + Agent-Job-Pattern (Hybrid, Queue-Tabelle, Audit)
- [research/4-jtl-spezifika/4-jtl-spezifika.md](research/4-jtl-spezifika/4-jtl-spezifika.md) — JTL-Wawi-Randbedingungen: Worker-Sichtbarkeit, Updates, Lizenz, Probeliste
- [research/5-repo-inventar/5-repo-inventar.md](research/5-repo-inventar/5-repo-inventar.md) — Bestandsaufnahme Ist-Reset-Prozess + eigene Objekte in eazybusiness

**Related ADRs:**
- [adrs/adr-grate-migration-runner.md](adrs/adr-grate-migration-runner.md) — plan-scoped, wird in §5 erstellt
- [adrs/adr-two-chain-migration-paths.md](adrs/adr-two-chain-migration-paths.md) — plan-scoped, wird in §5 erstellt
- [adrs/adr-module-signing-reset.md](adrs/adr-module-signing-reset.md) — plan-scoped, wird in §5 erstellt

**Cross-References:**
- `docs/SQL/NAMING-CONVENTIONS.md` — Schema-Eigentümer-Tabelle (wird in §5 um RoboticoOps + geteilte CW-Zone ergänzt)
- `docs/SQL/JTL-CUSTOM-WORKFLOWS.md` — Custom-Action-Registrierungsmechanik
- excel_ekl-Repo: `backend/migrations/jtl/` + `docs/SQL/Migration/` — der EKL-Runner (bleibt unangetastet, Grenze siehe research/1.1)
- Skills: `knowledge-sql`, `knowledge-jtl-sql` (für alle SQL-Implementierungen laden)

---

## Decision Log

### D1 — grate als Migrations-Runner für JTL-Robotico

**Trigger:** Anforderung „Migrationen versionierbar + wartbar"; Vergleichsrecherche (research/1); Nutzer-Entscheid 2026-07-09.
**Decision:** grate (self-contained CLI, https://github.com/grate-devs/grate) ist der Migrations-Runner dieses Repos. Der EKL-Runner in excel_ekl bleibt unverändert bestehen.
**Rationale:** Objektbestand ist CREATE-OR-ALTER-lastig → grates anytime-Ordner mit Hash-Tracking passen exakt; kein eigener Host-Code; `--baseline` für Bestandsaufnahme; Journal-Schema konfigurierbar. DACPAC scheidet wegen Vendor-Koexistenz aus, Flyway wegen Lizenz-/Java-Lage, DbUp wegen Host-Programm + fehlendem Hash-Tracking.
**Alternatives Considered:**
- DbUp: C#-Host nötig, RunAlways ohne Change-Detection/Audit — abgelehnt.
- Eigenbau T-SQL: wäre Nachbau dessen, was grate fertig mitbringt — abgelehnt.
- EKL-Runner-Muster übernehmen: TS-Toolchain-gebunden, für SQL-only-Repo ungeeignet (Nutzer-Entscheid) — abgelehnt.

### D2 — Zwei Migrationsketten, ein Verfahren (Ebene A / Ebene B)

**Trigger:** Nutzer-Anforderung „Datenbank global vs. eazybusiness sauber trennen".
**Decision:** Eine logische Kette **`eazybusiness/`** (Ebene A: kopierbare Inhalte, die in jeder eazybusiness-Kopie leben — Schemas `Robotico` + eigene `CustomWorkflows`-Objekte; Journal dezentral **pro DB** im Schema `Robotico`) und eine Kette **`global/`** (Ebene B: Instanz-Unikate — RoboticoOps-DB, Logins, Zertifikate, Agent-Jobs, Server-Grants; Journal in der **RoboticoOps**-DB der jeweiligen Instanz). Trennlinie: *Ebene A versioniert Inhalte, die mitkopiert werden; Ebene B versioniert Unikate, die nie kopiert werden. Nichts ist beides.*
**Rationale:** Journal-in-DB wandert beim Mandantenklon automatisch mit (frischer Klon kennt seinen Stand); Instanz-Objekte haben keinen Klon-Mechanismus und brauchen Guard-Clause-Idempotenz. Ein Tool für beide Ketten minimiert kognitive Last.
**Alternatives Considered:**
- Zentrale Zustandsverwaltung für alle DBs in RoboticoOps: bricht beim Klonen (Stand wandert nicht mit) — abgelehnt.
- Zwei verschiedene Tools je Pfad: unnötige Komplexität — abgelehnt.

### D3 — Journal-Schema `Robotico` (Ebene A) bzw. `ops` in RoboticoOps (Ebene B)

**Trigger:** grate-Default-Schema `grate`; Naming-Conventions des Repos.
**Decision:** Ebene A: `grate --schema=Robotico` (Journal-Tabellen Version/ScriptsRun/ScriptsRunErrors in `Robotico`). Ebene B: `grate --schema=ops` in RoboticoOps.
**Rationale:** Journal muss im eigenen Schema liegen (nie `dbo`, Vendor-Koexistenz) und beim Klonen mitwandern; `RoboticoEKL` ist tabu (Fremd-Eigentum EKL-Runner).
**Alternatives Considered:**
- Default-Schema `grate`: drittes Fremd-Schema in der JTL-DB, widerspricht Naming-Conventions — abgelehnt.
- Journal in CustomWorkflows: geteilte Zone mit EKL, dort nur Actions — abgelehnt.

### D4 — Admin-DB heißt `RoboticoOps`

**Trigger:** Nutzer-Entscheid 2026-07-09; Survey: Name auf beiden Instanzen kollisionsfrei.
**Decision:** Die Admin-/Ops-DB heißt `RoboticoOps`, Collation explizit `Latin1_General_CI_AS`, Recovery SIMPLE, Owner `sa`. Schemas darin: `ops` (Registry/Config/Journal), `reset` (Reset-SPs).
**Rationale:** Klar außerhalb des `eazybusiness_*`-Namensraums (nie mit Mandanten-Klonen verwechselbar); Collation-Gleichheit mit eazybusiness ist Pflicht (JTL-Update-Blocker + Cross-DB-Joins).
**Alternatives Considered:** `eazybusiness_ops`: kollidiert mit Klon-Namensmuster `eazybusiness_*` und würde von Skript-Safety-Checks/Registry-Pattern erfasst — abgelehnt.

### D5 — Reset asynchron: signierte SP startet Agent-Job, Queue-Tabelle als Übergabe

**Trigger:** Backup+Restore dauert Minuten (Client-Timeout); Kollegen ohne Server-Rechte; Nutzer-Entscheid.
**Decision:** `reset.StartTestmandantReset` (nur EXECUTE-Grant) validiert, schreibt Request-Zeile (`ops.ResetRequest`, Status-Machine queued→running→succeeded/failed) und startet den Agent-Job `RoboticoOps - Testmandant Reset` via `msdb.dbo.sp_start_job`. Der Job verarbeitet die älteste queued-Zeile.
**Rationale:** Agent-Jobs nehmen keine Parameter → Queue-Tabelle ist das robuste, auditierbare Muster; asynchron = kein Client-Timeout; Tabelle = einsehbarer State.
**Alternatives Considered:**
- Synchron in der SP: Minuten-Wartezeit, Verbindungsabbruch = unklarer Zustand — abgelehnt.
- Service Broker: overkill für seriellen, seltenen Prozess — abgelehnt.
- `sp_update_jobstep` dynamisch: Race Conditions, Anti-Pattern — abgelehnt.

### D6 — Rechte-Modell: Hybrid-Signing für die Start-SP, sysadmin-Owner für den Job

**Trigger:** Research/3 (Sommarskog); Nutzer-Entscheid 2026-07-09.
**Decision:** Start-SP läuft `WITH EXECUTE AS 'jobstartuser'` (dedizierter, deaktivierter Login mit `DENY CONNECT SQL`; in msdb User + `SQLAgentOperatorRole` + EXECUTE auf sp_start_job) und wird mit Zertifikat `RoboticoOpsSigning` signiert (Zertifikat in RoboticoOps mit Private Key, in master nur Public Key → `CREATE LOGIN ... FROM CERTIFICATE` → `GRANT AUTHENTICATE SERVER`). Der Agent-Job gehört `sa` → T-SQL-Step läuft als Agent-Dienstkonto (sysadmin), **kein** Signing im Job. `TRUSTWORTHY` bleibt überall OFF.
**Rationale:** Hybrid vermeidet Countersignatures auf msdb-Systemprozeduren (gehen bei jedem CU verloren); sysadmin-Owner macht BACKUP/RESTORE/xp_create_subdir/ALTER AUTHORIZATION ohne fragile Grant-Ketten möglich. Sicherheit über drei Schichten: Job-Inhalt nur via versioniertes Deployment; Start nur via signierte SP; Job re-validiert die Request-Zeile selbst (Defense in Depth).
**Alternatives Considered:**
- Reiner Zertifikatsweg inkl. msdb-Countersignatures: CU-fragil — abgelehnt.
- Least-privilege-Job-Owner: viele Server-Update-anfällige Stellschrauben, kleiner Gewinn (Job muss prod ohnehin lesen) — abgelehnt.

### D7 — Status-Rückkanal: signierte Status-SP, keine Tabellen-Grants

**Trigger:** Nutzer-Entscheid 2026-07-09.
**Decision:** `reset.GetResetStatus` (+ optional `@RequestId`/`@MandantKey`-Filter) ist der einzige Lesezugang für Kollegen; RoboticoOps bleibt für sie sonst unsichtbar. Reine Lese-SP auf die eigene DB → braucht kein Signing, nur EXECUTE-Grant an die Rolle `ops_reset_executor`.
**Rationale:** „Die SP ist die Schnittstelle" konsistent durchgezogen; Secret-Spalten der Registry automatisch geschützt.
**Alternatives Considered:** SELECT-Grant auf View: öffnet die DB als benutzbare Fläche, Dauerprüfpflicht bei Schemaerweiterungen — abgelehnt.

### D8 — Mandanten-Config inkl. Lizenz-Keys in `ops.Mandant`, spaltenrechtsgeschützt

**Trigger:** Ablösung der gitignorierten `test-environment.config.json` (Google-Drive-Sync); Nutzer-Entscheid.
**Decision:** `ops.Mandant` trägt MandantKey (tmN), TargetDb, Developer, DisplayName, LoginName, ShopUrl, ShopLicense, IsActive. `ShopLicense` (+ ggf. weitere Secret-Spalten) per Spalten-DENY für alle außer den reset-internen Prozeduren/Admins. Seeds mit echten Keys laufen NIE über git — Seed-Template mit Platzhaltern + Runbook-Schritt.
**Rationale:** Ein Pflegeort, versionierbares Schema, kein Datei-Sync; Rechte-basiertes Schutzniveau genügt (Zugriff hat ohnehin nur die signierte SP-Kette + Admins).
**Alternatives Considered:** ENCRYPTBYKEY-Verschlüsselung: Key-Management-Komplexität ohne relevanten Zugewinn im Admin-only-Kontext — abgelehnt (nachrüstbar).

### D9 — Worker-Neutralisierung wird fester Reset-Bestandteil (über Credential-Invalidierung hinaus)

**Trigger:** Research/4 (Worker gleicht alle tMandant-Einträge ab; Lizenz-Leitplanke); Survey-Funde der konkreten Flags.
**Decision:** Der Reset-Job neutralisiert im Zielklon zusätzlich: `dbo.ebay_user.nGesperrt=1` (bereits in e6d7b2b), `dbo.pf_user`: `nGesperrt=1, nAktiv=0` (Amazon-Pendant, guarded — Tabelle kann leer sein), Queue-Leerung (`dbo.tQueue`, `dbo.tWorkflowQueue`, `dbo.ebay_usermessagequeue`, `dbo.ebay_queue_out`, `dbo.tGlobalsQueue`, `dbo.tDruckQueue`; jeweils `IF OBJECT_ID`-guarded DELETE/TRUNCATE), Shop-Repoint auf Staging (aus ops.Mandant statt SQLCMD-Var). `Worker.tTarget` wird NICHT verändert (Semantik von nAbgleichstyp ungeklärt → Probeliste §4; konservativ: Sperren wirken auf Konto-/Shop-Ebene).
**Rationale:** Credentials leeren ≠ Abgleich verhindern; Queue-Rückstau feuert, sobald jemand testweise Credentials setzt; Lizenz-Compliance (Klon darf nie produktiv abgleichen).
**Alternatives Considered:** Nur Credential-Invalidierung (Ist-Stand): nachgewiesene Lücken — abgelehnt.

### D10 — CustomWorkflows ist additiv geteilte Zone; CW-Registrierungs-Framework + `Robotico.*` sind stabile APIs

**Trigger:** research/1.1: EKL-Runner legt `CustomWorkflows.spCMArtikel`/`spCMArtikelNeu` an und konsumiert `_CheckAction`/`_SetActionDisplayName`/`vCustomAction` sowie `Robotico.fnEscapedCSVParseLine`.
**Decision:** Die Ebene-A-Kette behandelt `CustomWorkflows` strikt additiv: nur eigene, namentlich bekannte Objekte anlegen/ändern; NIE `spCMArtikel`/`spCMArtikelNeu` oder `dbo.tWorkflow`-Zeilen mit cName `EKL …` anfassen; kein DROP SCHEMA. Signaturen/Namen von `_CheckAction`, `_SetActionDisplayName`, `vCustomAction` und `Robotico.fnEscapedCSVParseLine` sind abwärtskompatibel zu halten (API-Vertrag mit excel_ekl).
**Rationale:** Zwei Migrationsketten bewohnen dasselbe Schema — nur eine explizite Eigentums-/Additivitätsregel verhindert gegenseitige Zerstörung.
**Alternatives Considered:** CW-Objekte des EKL „mit übernehmen": doppelte Verantwortung, Drift zwischen Repos — abgelehnt.

### D11 — Promotion ausschließlich skriptbasiert; test1 ist reguläres Ebene-A-Ziel

**Trigger:** Survey: test1 = SQL 2025, prod = SQL 2022 → Restore nur alt→neu; Nutzer-Entscheid F3.
**Decision:** Kein Rollout-Schritt darf je ein auf test1 erzeugtes DB-Abbild voraussetzen; Richtung prod fließen nur versionierte Skripte. test1/eazybusiness wird reguläres Ziel der Ebene-A-Kette (Deploy-Reihenfolge: test1 und/oder Testmandant → prod); Testdaten-Refresh auf test1 weiterhin per prod-Backup-Restore (alt→neu erlaubt).
**Rationale:** Engine-Versionslücke erzwingt es; entspricht dem etablierten EKL-Fluss (025 auf test1, 024 auf prod).
**Alternatives Considered:** test1 nur als EKL-System belassen: unsere Objekte dort veralten, Vorlauf-Tests unmöglich — abgelehnt.

### D12 — Alt-Skripte bleiben, neue SSoT ist `db-migrations/`; PowerShell-Prozess wird erst nach Validierung abgelöst

**Trigger:** Übergangssicherheit — der Ist-Prozess funktioniert und wird täglich gebraucht.
**Decision:** `WorkflowProcedures/*` und `Projekte/Testsystem/*` bleiben unverändert lauffähig; sie erhalten Deprecation-Hinweise (Kommentar-Banner + README), die auf `db-migrations/` bzw. den neuen Reset verweisen. Physische Löschung/Archivierung erst nach erfolgreicher E2E-Validierung des neuen Wegs (Runbook §5, manueller Gate).
**Rationale:** Kein Big-Bang; Rollback-Fähigkeit bleibt vollständig erhalten.
**Alternatives Considered:** Alte Skripte sofort löschen: Risiko ohne Not — abgelehnt.

### D13 — Hygiene-Funde als eigener Baustein mit ausschließlich manueller Ausführung

**Trigger:** Survey-Nebenfunde; Nutzer-Entscheid F4.
**Decision:** §6 liefert Prüf-/Fix-Skripte + Runbook für: (a) `dbuser_dev_dana_for_jtl` sysadmin-Entzug (Ersatz-Grants dokumentieren), (b) tm2-Refresh via neuem Reset (JTL 1.11.6.0 → aktuell), (c) `eazybusiness_premig`-Behandlung (Backup + Drop oder Verschieben; Entscheidung Lukas). **Kein Skript aus §6 wird autonom gegen prod ausgeführt.**
**Rationale:** Sicherheits-/Aufräumthemen gehören dokumentiert und vorbereitet, aber prod-Änderungen brauchen den Menschen.
**Alternatives Considered:** Außerhalb des Plans behandeln: ginge verloren — abgelehnt (Nutzer wollte sie im Plan).

---

## Open Questions

- **O1**: Semantik der `Worker.tTarget.nAbgleichstyp`-Werte (0,2,3,4,5,7,8,13,17,18) — affected: §3/§4, owner: Research (Probeliste auf test1). Bis zur Klärung: tTarget nicht anfassen (D9).
- **O2**: Entdeckt der Worker einen frischen tMandant-Eintrag sofort oder erst nach Neustart? — affected: §4-Probeliste, owner: Research (test1).
- **O3**: `eazybusiness_premig` — Backup+Drop oder behalten? — affected: §6, owner: User.
- **O4**: Amazon-Konten (`pf_user`) in den tm-Klonen vorhanden? — affected: §3 (Neutralisierung ist guarded, funktioniert so oder so), owner: Research (test1/Klone).
- **O5**: Zertifikats-Passwort-Ablage: `~/.claude-secrets.md`-Eintrag + Deploy-Prompt — bestätigen — affected: §2/§5-Runbook, owner: User.

---

## Context

### Problem

Der Testmandanten-Reset ist ein PowerShell-Skript, das persönliche Admin-Rechte auf dem **Produktivserver** voraussetzt (`-E`, BACKUP/RESTORE, db_owner-Vergabe). Es gibt kein Audit, keine zentrale Config (gitignorierte JSON via Google Drive), kein Migrations-Journal für die eigenen Objekte in eazybusiness (Deploy ad hoc per SSMS), und hart codierte Annahmen (Server, Pfade, Logins, AD-Gruppe) streuen über Skripte. Es existiert kein definierter Weg, DB-Features erst auf Test (vm-sql-test1 / Testmandant) und dann auf prod auszurollen.

### Goals

1. **Migrationsfundament:** Versionierte, journalisierte, idempotente Migrationen via grate — eine Kette für eazybusiness-Inhalte (Ebene A), eine für Instanz-Unikate (Ebene B) — mit Baseline des Bestands.
2. **RoboticoOps-DB:** Mandanten-Registry (inkl. Secrets, spaltenrechtsgeschützt), Request-/Run-Log, Journal Ebene B, Rollen.
3. **Reset neu:** Kollegen lösen den Testmandanten-Reset per `EXECUTE` auf eine signierte SP aus; ein Agent-Job macht Klon + alle Nacharbeiten (inkl. erweiterter Worker-Neutralisierung); Status via Status-SP; vollständiges Audit.
4. **Test→Prod-Workflow:** Ebene B über vm-sql-test1, Ebene A über test1/Testmandanten — Promotion ausschließlich skriptbasiert.
5. **Doku:** Architektur-Doku, drei ADRs, Runbooks (Baseline, Rollout, Validierung, Hygiene).

### Non-Goals / Out of Scope

- Kein Umbau des EKL-Runners oder seiner Migrationen (excel_ekl-Repo, D10-Grenze).
- Keine autonome Ausführung gegen **prod** (vm-sql2) in diesem Plan — prod-Rollout ist Runbook mit manuellem Gate. Read-only-Katalogabfragen sind erlaubt.
- Keine Änderung an JTL-`dbo`-Objekten (Vendor).
- Keine Ablösung der JTL-eigenen Update-Mechanik; Klon-nach-Update-Regel wird dokumentiert, nicht automatisiert.
- Kein UI/Frontend — Schnittstelle ist SQL (SSMS/sqlcmd).

---

## Architectural Skeleton

### Building Blocks

| # | Building Block | Description | Detail-Location | Status |
|---|----------------|-------------|-----------------|--------|
| 1 | Migrationsfundament grate (Ebene A) | `db-migrations/`-Struktur, Konventionen, Bestands-Portierung (normalisiert), Deploy-Wrapper, Baseline | §1 below (flat) | ✅ User-Approved |
| 2 | RoboticoOps-DB + globale Kette (Ebene B) | DB, Schemas ops/reset, Registry/Request-Tabellen, Rollen, Instanz-Objekte (Login, Zertifikat, Job-Hülle), Signing-Mechanik | §2 below (flat) | ✅ User-Approved |
| 3 | Reset-SP + Agent-Job-Logik | Start-SP, Status-SP, Job-Prozedur (Klon + Nacharbeiten-Pipeline, portiert aus Projekte/Testsystem, erweitert um D9) | §3 below (flat) | ✅ User-Approved |
| 4 | Validierung & Probeliste vm-sql-test1 | Read-only-Probe-Skripte, Validierungs-Runbook, offene JTL-Fragen (O1/O2/O4) | §4 below (flat) | ✅ User-Approved |
| 5 | Doku, ADRs, Rollout-Runbook, Ablösung | Architektur-Doku, 3 plan-scoped ADRs, Rollout-Runbook, Deprecation-Banner, Naming-Conventions-Update | §5 below (flat) | ✅ User-Approved |
| 6 | Hygiene/Cleanup (nur vorbereitend) | Skripte + Runbook für Dana-sysadmin, tm2-Altstand, premig-DB | §6 below (flat) | ✅ User-Approved |
| 7 | Tests | Statische Konventions-Lints + SQL-Testdateien | §7 below (flat) | ✅ User-Approved |

### Data Flow / Component Interaction

```
Kollege (nur EXECUTE)                          Admin/Deployer (Lukas)
  |                                              |
  | EXEC RoboticoOps.reset.StartTestmandantReset | deploy.ps1 (grate)
  v                                              v
+---------------- RoboticoOps (Ebene B) ------------------+
| reset.StartTestmandantReset  [signiert, EXECUTE AS      |
|   jobstartuser] -> validiert gegen ops.Mandant,         |
|   applock, INSERT ops.ResetRequest(queued),             |
|   msdb.dbo.sp_start_job                                 |
| reset.GetResetStatus  [nur EXECUTE-Grant]               |
| ops.Mandant / ops.Config / ops.ResetRequest             |
| ops.ScriptsRun (grate-Journal Ebene B)                  |
+----------------------------------------------------------+
  | Agent-Job "RoboticoOps - Testmandant Reset" (Owner sa)
  v
reset.ProcessNextResetRequest  [laeuft als Agent-Dienstkonto]
  1. aelteste queued-Zeile -> running (Re-Validierung!)
  2. COPY_ONLY-Backup eazybusiness -> Restore Ziel-Klon
  3. Owner/Orphans/TRUSTWORTHY-Sequenz
  4. Nacharbeiten im Klon (dynamisches SQL, USE [Ziel]):
     Credentials invalidieren -> Shop-Repoint (aus ops.Mandant)
     -> Worker-Neutralisierung (eBay+Amazon-Sperre, Queues leeren)
     -> Anonymisierung -> Grants -> tMandant/tBenutzerFirma
     -> JTL-Rollen
  5. succeeded/failed + ErrorText -> ops.ResetRequest

eazybusiness / eazybusiness_tmN / test1-eazybusiness (Ebene A)
  Robotico.* (Objekte + grate-Journal Robotico.ScriptsRun)
  CustomWorkflows.* (nur eigene Objekte; additiv geteilte
  Zone mit EKL-Runner — D10)
```

### Affected Subsystems

- **DB / Migrations**: neu `db-migrations/` (beide Ketten), Baseline gegen Bestand
- **RoboticoOps**: neue DB (nur via Ebene-B-Kette erzeugt)
- **Repo-Skripte**: `WorkflowProcedures/`, `Projekte/Testsystem/`, `Berechtigungen/` (Quellmaterial + Deprecation-Banner; keine funktionale Änderung)
- **Doku**: `docs/SQL/`, `docs/runbooks/` (neu), `docs/plans/` (dieser Plan), plan-scoped `adrs/`
- **Server (read-only in diesem Plan)**: vm-sql-test1 für Probe-Skripte; vm-sql2 nur Katalog-Lesen

---

## §1 — Migrationsfundament grate (Ebene A)

**Status:** ✅ User-Approved
**Detail Location:** n/a — flat

### Files to Create / Modify

| Path | Action | Notes |
|---|---|---|
| `db-migrations/README.md` | NEW | Konventionen-SSoT (siehe unten); Deutsch-Verbot beachten: englisch |
| `db-migrations/targets.config.json` | NEW | Zielkatalog ohne Secrets (Windows-Auth): envs TEST/PROD, Server, DB-Listen |
| `db-migrations/deploy.ps1` | NEW | Wrapper: `-Scope eazybusiness|global -Environment TEST|PROD [-Target <db>] [-Baseline] [-DryRun]` |
| `db-migrations/eazybusiness/up/0001_robotico_schema.sql` | NEW | `IF NOT EXISTS … CREATE SCHEMA Robotico` (guarded, einmalig) |
| `db-migrations/eazybusiness/up/0002_robotico_paypal_tables.sql` | NEW | tPaypalAccessToken/tPaypalSettings/tPaypalTrackingLog aus `WorkflowProcedures/PayPal/Add Procudures and Tables.sql`, guarded |
| `db-migrations/eazybusiness/functions/Robotico.fn*.sql` | NEW (×~13) | je 1 Objekt/Datei: fnFindDuplicateOrders, fnHasOlderDuplicateOrder, fnGetArticleCustomFieldValue, fnEscapedCSV* (4), fnString* (6) — `CREATE OR ALTER` |
| `db-migrations/eazybusiness/sprocs/CustomWorkflows._CheckAction.sql` | NEW | Registrierungs-Infra zuerst (Unterstrich sortiert vor `sp`); Quelle: bestehende Definition aus WorkflowProcedures-Dateien extrahieren |
| `db-migrations/eazybusiness/sprocs/CustomWorkflows._SetActionDisplayName.sql` | NEW | dito; **API-Vertrag D10: Signatur nicht ändern** |
| `db-migrations/eazybusiness/sprocs/Robotico.sp*.sql` | NEW (×~4) | spCheckDuplicateOrder, spEnsureArticleCustomField, spSetArticleCustomFieldValue u. a. |
| `db-migrations/eazybusiness/sprocs/CustomWorkflows.sp*.sql` | NEW (×~7) | spPaypalTrackingLieferschein/-Versand, spArticleAppendPriceHistory/-LabelHistory, spArticleUpdateAllHistory, spGebindeErstellen, spZustandartikelLieferantSetzen — je inkl. `_SetActionDisplayName`-Registrierung am Ende (idempotent) |
| `db-migrations/tests/eazybusiness/*.sql` | NEW | verschobene/portierte `*_Tests.sql` + Teardown (außerhalb der Deploy-Ordner!) |
| `docs/runbooks/migrations-baseline.md` | NEW | Baseline-Runbook: Reihenfolge prod/test1/tm-Klone, grate-Kommandos |
| `WorkflowProcedures/README.md` | NEW | Deprecation-Hinweis: Deployment jetzt via db-migrations (D12); Alt-Dateien bleiben als Referenz |

### Implementation Approach

1. **Konventionen-README zuerst** (ist der Vertrag für alle weiteren Chunks): Ordner-Semantik (up = one-time, functions/views/sprocs = anytime bei Hash-Änderung, permissions = everytime), **Verbote**: kein `USE`, kein `GO;` (nur `GO` allein auf Zeile), genau ein Objekt pro anytime-Datei, keine hardcodierten JTL-IDs (by-Name auflösen, Pre-Checks als hard FAIL — Lesson research/1.1), Dateinamen = `Schema.Objektname.sql` (anytime) bzw. `NNNN_snake_case.sql` (up). EKL-Grenzregeln aus D10 wörtlich aufnehmen. One-time-Skripte werden nach Anwendung NIE editiert (grate-Hash!); Korrektur = neues up-Skript.
2. **Portierung:** Jede Quelle aus `WorkflowProcedures/` in Zieldateien überführen: `USE eazybusiness` entfernen, `GO;`→`GO`, `IF EXISTS DROP + CREATE` → `CREATE OR ALTER` wo möglich (Procs/Functions/Views; für Inline-TVF mit abhängigen Objekten Reihenfolge über functions→sprocs), Extended-Property-Registrierung (`_SetActionDisplayName`) bleibt Teil derselben Datei wie die Action-Proc (Einheit!). Kommentare/Header der Originale erhalten (Provenienz-Zeile ergänzen: `-- Ported from WorkflowProcedures/... (2026-07-10)`).
3. **`_CheckAction`/`_SetActionDisplayName` extrahieren:** Definitionen aus den bestehenden Workflowaktion-Dateien (dort inline definiert) in eigene Dateien heben; Duplikate zwischen Quelldateien deduplizieren (neueste Version gewinnt; per Diff prüfen).
4. **deploy.ps1:** dünn halten — Auflösen von targets.config.json (Environment→Server, Scope→sqlfilesdirectory+Schema+DB-Liste), Schleife über Ziel-DBs, grate-Aufruf mit `--connectionstring "Server=…;Database=…;Trusted_Connection=True;TrustServerCertificate=True"`, `--schema=Robotico` (Scope eazybusiness) bzw. `--schema=ops` (Scope global), `--environment=$Environment`, `--transaction`, `--silent`, `--version=$(git describe --tags --always 2>$null)`; `-Baseline`→`--baseline`, `-DryRun`→`--dryrun`. grate-Verfügbarkeit prüfen (`Get-Command grate`), sonst Installationshinweis (`dotnet tool install --global grate`). PROD-Environment: interaktive Bestätigung (Y/N-Prompt mit Ziel-Auflistung) — Lesson 5 aus research/1.1.
5. **targets.config.json:** `{"environments": {"TEST": {"server": "vm-sql-test1.zdbikes.local", "eazybusiness": ["eazybusiness"], "global": "RoboticoOps"}, "PROD": {"server": "vm-sql2.zdbikes.local", "eazybusiness": ["eazybusiness", "eazybusiness_tm2", "eazybusiness_tm3", "eazybusiness_tm4"], "global": "RoboticoOps"}}}` — Klone sind reguläre Ebene-A-Ziele (D11; Deploy dorthin normalerweise unnötig, weil Klonen den Stand mitbringt, aber nötig für „Migration erst am Testmandanten testen").
6. **Baseline-Runbook:** Schrittfolge, um den Bestand aufzunehmen: (a) auf prod-eazybusiness `deploy.ps1 -Scope eazybusiness -Environment PROD -Target eazybusiness -Baseline` — markiert alle up/anytime-Skripte als gelaufen ohne Ausführung; (b) danach normaler Zyklus. Warnhinweis: Baseline setzt voraus, dass Dateiinhalt == deployter Stand; vorher Objektvergleich (Skript in §7-Tests) laufen lassen.

### Edge Cases & Risks

- **Duplikat-Definitionen** von `_CheckAction` in mehreren Quelldateien mit Drift → Diff-Vergleich, neueste gewinnt, Abweichungen im Chunk-Report dokumentieren.
- **Anytime-Reihenfolge**: alphabetisch; `CustomWorkflows._*` sortiert vor `CustomWorkflows.sp*` und `Robotico.*` — Abhängigkeit Registrierungs-Infra→Actions damit erfüllt. functions/ läuft vor sprocs/ (grate-Ordnerreihenfolge).
- **grate nicht installiert** auf Ziel-Workstation → deploy.ps1 bricht mit Anleitung ab; keine stille Teilausführung.
- **`--runallanytimescripts` nie in PROD** — im README als Verbot dokumentieren.
- Klon-Journal-Drift: One-time-Skripte nie editieren; falls doch nötig → `--warnandignoreononetimescriptchanges` NUR dokumentiert als Notventil im Runbook, nie im deploy.ps1-Default.

### Acceptance

- `db-migrations/`-Baum vollständig; **jede** Datei besteht den Konventions-Lint (§7): kein `USE `, kein `GO;`, 1 CREATE pro anytime-Datei, kein DROP fremder Objekte, keine EKL-Objektnamen (`spCMArtikel`, `spCMArtikelNeu`, `RoboticoEKL`).
- Inhaltlicher Abgleich: jedes deployte Objekt aus research/5 §3 hat genau eine Zieldatei (Mapping-Tabelle im Chunk-Report).
- `deploy.ps1 -DryRun` ist syntaktisch valide (PowerShell-Parse-Check `[System.Management.Automation.PSParser]` oder `pwsh -NoProfile -Command "…" -WhatIf`-artiger Trockenlauf ohne Server).

---

## §2 — RoboticoOps-DB + globale Kette (Ebene B)

**Status:** ✅ User-Approved
**Detail Location:** n/a — flat

### Files to Create / Modify

| Path | Action | Notes |
|---|---|---|
| `db-migrations/global/up/0001_roboticoops_settings.sql` | NEW | DB-Settings absichern: Collation-Assert (`Latin1_General_CI_AS`, hard FAIL bei Mismatch), `ALTER DATABASE … SET RECOVERY SIMPLE`, `ALTER AUTHORIZATION … TO sa`, TRUSTWORTHY-OFF-Assert |
| `db-migrations/global/up/0002_ops_schema_tables.sql` | NEW | Schemas `ops`, `reset`; Tabellen `ops.Mandant`, `ops.Config`, `ops.ResetRequest` (inkl. gefiltertem Unique-Index) |
| `db-migrations/global/up/0003_roles.sql` | NEW | DB-Rollen `ops_reset_executor`, `ops_admin`; Spalten-DENY auf `ops.Mandant.ShopLicense` für ops_reset_executor |
| `db-migrations/global/up/0010_jobstartuser_login.sql` | NEW | Guarded: `CREATE LOGIN jobstartuser` (random PW via CRYPT_GEN_RANDOM-Konstruktion im Skript), `ALTER LOGIN … DISABLE`, `DENY CONNECT SQL`; msdb-User + `SQLAgentOperatorRole` + GRANT EXECUTE sp_start_job |
| `db-migrations/global/up/0011_signing_certificate.sql` | NEW | Guarded: `CREATE CERTIFICATE RoboticoOpsSigning` in RoboticoOps (Passwort via grate-Token `{{CertPassword}}`), Public-Key-Export nach master via `certencoded()`, `CREATE LOGIN RoboticoOpsSigningLogin FROM CERTIFICATE`, `GRANT AUTHENTICATE SERVER TO RoboticoOpsSigningLogin` |
| `db-migrations/global/sprocs/reset.StartTestmandantReset.sql` | NEW | §3-Detail; `WITH EXECUTE AS 'jobstartuser'` |
| `db-migrations/global/sprocs/reset.GetResetStatus.sql` | NEW | §3-Detail |
| `db-migrations/global/sprocs/reset.ProcessNextResetRequest.sql` | NEW | §3-Detail (Job-Körper) + interne Helfer-Procs (siehe §3) |
| `db-migrations/global/runAfterOtherAnyTimeScripts/agent_job_testmandant_reset.sql` | NEW | Idempotent: `sp_delete_job` IF EXISTS → `sp_add_job` (Owner `sa`) + 1 T-SQL-Step `EXEC RoboticoOps.reset.ProcessNextResetRequest` + `sp_add_jobserver`; enabled, kein Schedule (nur On-Demand via sp_start_job) |
| `db-migrations/global/permissions/100_grants.sql` | NEW | Everytime: EXECUTE auf Start-/Status-SP an `ops_reset_executor`; Rollen-Membership für AD-Gruppe `ZDBIKES\sql-jtl-users` (guarded CREATE USER FROM LOGIN) |
| `db-migrations/global/permissions/900_resign_procedures.sql` | NEW | Everytime: prüft je signierpflichtiger SP `sys.crypt_properties`; fehlt die Signatur (z. B. nach CREATE OR ALTER) → `ADD SIGNATURE … BY CERTIFICATE RoboticoOpsSigning WITH PASSWORD = '{{CertPassword}}'` |
| `db-migrations/global/up/0020_seed_mandant_template.sql` | NEW | Seed für ops.Config (BackupFile-Pfad, TargetDataDir aus copy_test_db.sql) + ops.Mandant-Zeilen tm2/tm3/tm4 mit `{{…}}`-Platzhaltern NUR für ShopLicense (Runbook-Schritt trägt echte Keys nach — nie in git) |

### Implementation Approach

1. **DB-Erzeugung:** grate legt die Ziel-DB automatisch an, wenn sie fehlt (Connection auf `RoboticoOps`). 0001 validiert danach die Invarianten (Collation!) und bricht hart ab, wenn der Server-Default abweicht — mit Anleitung (`CREATE DATABASE … COLLATE Latin1_General_CI_AS` manuell).
2. **Tabellen:**
   - `ops.Mandant`: `MandantKey` (PK, z. B. 'tm4', CHECK `^tm[0-9]+$`-artig via LIKE), `TargetDb` (UNIQUE, CHECK `<> 'eazybusiness'` AND LIKE 'eazybusiness[_]%'), `DisplayName`, `Developer`, `LoginName`, `ShopUrl`, `ShopLicense`, `IsActive BIT`, Audit-Spalten (CreatedAt/ModifiedAt).
   - `ops.Config`: Key/Value (`BackupFile`, `TargetDataDir`, `SourceDb`='eazybusiness', `ReferenceMandant`=1) — löst die hart codierten Pfade aus copy_test_db.sql ab.
   - `ops.ResetRequest`: `RequestId INT IDENTITY PK`, `MandantKey FK`, `TargetDb`, `Status` (CHECK IN queued/running/succeeded/failed), `RequestedBy` (ORIGINAL_LOGIN), `RequestedAt/StartedAt/FinishedAt`, `ErrorText NVARCHAR(MAX)`, `StepLog NVARCHAR(MAX)` (append-only Fortschrittstext). Gefilterter Unique-Index: `CREATE UNIQUE INDEX UX_ResetRequest_Active ON ops.ResetRequest(TargetDb) WHERE Status IN ('queued','running')`.
3. **Signing-Kette (D6):** Zertifikat mit Private Key nur in RoboticoOps; master bekommt Public-only via `certencoded()`-Binärliteral-Trick in dynamischem SQL (kein Datei-Roundtrip, kein BACKUP CERTIFICATE auf Platte). `GRANT AUTHENTICATE SERVER` genügt für die Kontext-Weitergabe des EXECUTE-AS über DB-Grenzen (Sommarskog-Rezept); der eigentliche msdb-Zugriff läuft über die jobstartuser-Rechte.
4. **Token-Handling:** `{{CertPassword}}` kommt via `deploy.ps1 -Scope global` → Prompt (`Read-Host -AsSecureString`) oder Env-Var `GRATE_CERT_PASSWORD`; deploy.ps1 reicht ihn als `--usertoken CertPassword=…` durch. Ablage des Passworts: `~/.claude-secrets.md` (Runbook-Schritt, O5).
5. **Idempotenz-Muster Instanz-Objekte:** jedes up-Skript prüft `sys.server_principals`/`sys.certificates`/`msdb.dbo.sysjobs` per `IF NOT EXISTS`; Doppellauf ist folgenlos (Ebene B hat keinen Klon-Mechanismus — D2).

### Edge Cases & Risks

- **Server-Collation ≠ Latin1_General_CI_AS** → 0001 bricht ab (hard FAIL, Anleitung); niemals stillschweigend andere Collation akzeptieren.
- **CREATE OR ALTER auf signierte SPs entfernt Signaturen** → 900_resign läuft everytime und heilt das im selben Deploy-Lauf; Reihenfolge garantiert (permissions/ läuft nach sprocs/).
- **jobstartuser-Passwort:** wird nie benötigt (Login disabled, DENY CONNECT) — Random-Wert im Skript erzeugt, nicht geloggt.
- **SQL Agent auf test1 gestoppt** (Survey) → Runbook-Schritt „Agent-Dienst auf Automatic + Start" vor der Job-Validierung.
- AD-Gruppen-Grant (`ZDBIKES\sql-jtl-users`) auf test1 vorhanden, generisch guarded (falls Login fehlt → PRINT-Warnung statt Fehler).

### Acceptance

- Kompletter `global/`-Baum vorhanden, Konventions-Lint grün.
- Logische Prüfung (Chunk-Self-Check): jede Referenz der SPs auf Tabellen/Spalten existiert in 0002; Rollen-Grants decken genau Start-/Status-SP ab; Re-Sign-Skript listet exakt die SPs mit EXECUTE AS.
- Trockentest-Skript `db-migrations/tests/global/validate_structure.sql` (reines Parsing/Referenz-Review, siehe §7).

---

## §3 — Reset-SP + Agent-Job-Logik

**Status:** ✅ User-Approved
**Detail Location:** n/a — flat

### Files to Create / Modify

| Path | Action | Notes |
|---|---|---|
| `db-migrations/global/sprocs/reset.StartTestmandantReset.sql` | NEW | siehe §2-Tabelle; Logik hier |
| `db-migrations/global/sprocs/reset.GetResetStatus.sql` | NEW | dito |
| `db-migrations/global/sprocs/reset.ProcessNextResetRequest.sql` | NEW | Orchestrator des Jobs |
| `db-migrations/global/sprocs/reset.internal_CloneDatabase.sql` | NEW | Backup+Restore (aus copy_test_db.sql portiert, Pfade aus ops.Config) |
| `db-migrations/global/sprocs/reset.internal_PostRestoreSecurity.sql` | NEW | Owner→sa, Orphan-Remap (`ALTER USER … WITH LOGIN`), User-Cleanup, TRUSTWORTHY-OFF-Check |
| `db-migrations/global/sprocs/reset.internal_InvalidateCredentials.sql` | NEW | aus invalidate-credentials-for-testing.sql (Stand e6d7b2b) portiert; ShopUrl/ShopLicense aus ops.Mandant statt SQLCMD-Vars |
| `db-migrations/global/sprocs/reset.internal_NeutralizeWorker.sql` | NEW | NEU (D9): pf_user-Sperre, Queue-Leerung (guarded Liste) |
| `db-migrations/global/sprocs/reset.internal_AnonymizeCustomerData.sql` | NEW | aus clear-customer-fields.sql portiert (inkl. CONTEXT_INFO-Trigger-Bypass); Blöcke in TRY/CATCH mit StepLog |
| `db-migrations/global/sprocs/reset.internal_GrantAccess.sql` | NEW | aus grant-database-access.sql (LoginName aus ops.Mandant) |
| `db-migrations/global/sprocs/reset.internal_RegisterMandant.sql` | NEW | aus register-mandant.sql (DisplayName aus ops.Mandant; Upsert in alle Mandanten-DBs) |
| `db-migrations/global/sprocs/reset.internal_ApplyJtlRoles.sql` | NEW | aus Berechtigungen/JTL-Rollen.sql portiert, parametrisiert auf Ziel-DB |

### Implementation Approach

1. **`reset.StartTestmandantReset(@MandantKey sysname)`** (signiert, EXECUTE AS jobstartuser):
   - `sp_getapplock` Exclusive auf `'reset:' + @MandantKey` (Session-Owner, kurz).
   - Validierung: Zeile in `ops.Mandant` mit `IsActive=1` vorhanden; `TargetDb <> 'eazybusiness'` (redundant zum CHECK — Defense in Depth); keine aktive Anfrage (gefilterter Unique-Index fängt Races zusätzlich ab).
   - `INSERT ops.ResetRequest (…, RequestedBy = ORIGINAL_LOGIN(), Status='queued')`.
   - `EXEC msdb.dbo.sp_start_job @job_name = N'RoboticoOps - Testmandant Reset'`; wenn Job bereits läuft (Fehler 22022) → kein Fehler an den Aufrufer, Request bleibt queued (der laufende Job nimmt ihn im Anschluss — While-Schleife in ProcessNext).
   - RETURN `RequestId` als Resultset (`SELECT RequestId, 'queued' AS Status`).
2. **`reset.GetResetStatus(@RequestId INT = NULL, @MandantKey sysname = NULL)`**: letzte N Requests bzw. gefiltert; Spalten ohne Secrets (RequestId, MandantKey, TargetDb, Status, RequestedBy, RequestedAt, StartedAt, FinishedAt, DATEDIFF-Dauer, ErrorText, StepLog). Kein Signing nötig (eigene DB), EXECUTE-Grant an ops_reset_executor.
3. **`reset.ProcessNextResetRequest`** (nur vom Job aufgerufen; läuft als Agent-Dienstkonto):
   - While-Schleife: älteste `queued`-Zeile mit `UPDLOCK, READPAST` claimen → `running` + StartedAt; keine Zeile → Ende.
   - **Re-Validierung (Defense in Depth, D6):** TargetDb matcht ops.Mandant-Registry, Pattern `eazybusiness[_]%`, nie Quelle==Ziel.
   - Pipeline in TRY/CATCH, jeder Schritt appended an `StepLog` (`step=clone ok (137s)` …): internal_CloneDatabase → internal_PostRestoreSecurity → internal_InvalidateCredentials → internal_NeutralizeWorker → internal_AnonymizeCustomerData → internal_GrantAccess → internal_RegisterMandant → internal_ApplyJtlRoles.
   - CATCH: `failed` + `ERROR_MESSAGE()` + StepLog; Klon-DB bleibt liegen wie sie ist (für Diagnose), MULTI_USER sicherstellen.
   - Erfolg: `succeeded` + FinishedAt.
4. **Portierungs-Muster für die internal-Procs:** Ziel-DB-Kontext via dynamischem SQL: `SET @sql = N'USE ' + QUOTENAME(@TargetDb) + N'; ' + <Batch>; EXEC (@sql);` — Batches aus den Quellskripten übernehmen, `$(TargetDb)`/`$(LoginName)`/`$(ShopUrl)`/`$(ShopLicense)`/`$(MandantName)`-SQLCMD-Vars durch sp_executesql-Parameter bzw. QUOTENAME-Injektion ersetzen (String-Werte NUR parametrisiert — kein Konkatenieren von Nutzdaten in elevated SQL; DB-/Objekt-Namen NUR via QUOTENAME).
   - `internal_AnonymizeCustomerData`: die 11 Prioritätsblöcke des Quellskripts als nummerierte Sub-Batches; CONTEXT_INFO-Bypass beibehalten; abweichend vom Original: gesamter Proc-Lauf protokolliert pro Block in StepLog, Fehler in einem Block bricht die Pipeline (CATCH) — kein „halb anonymisiert, still weiter".
   - `internal_NeutralizeWorker` (NEU): `ebay_user.nGesperrt=1` (aus e6d7b2b übernommen — bleibt auch in InvalidateCredentials-Portierung, doppelt schadet nicht), `pf_user SET nGesperrt=1, nAktiv=0` (IF OBJECT_ID-guarded), Queue-Leerung: DELETE (nicht TRUNCATE — FK-sicher) auf `tQueue`, `tWorkflowQueue`, `ebay_usermessagequeue`, `ebay_queue_out`, `tGlobalsQueue`, `tDruckQueue` — jede guarded; `Worker.tTarget` NICHT anfassen (O1).
   - `internal_RegisterMandant`: Logik aus register-mandant.sql 1:1 (kMandant-Wiederverwendung per cDB, MAX+1, tBenutzerFirma-Seed aus Referenz-Mandant `ops.Config.ReferenceMandant`).
5. **Keine PowerShell mehr im Reset-Pfad** — der gesamte Ablauf ist serverseitig; `setup-test-environment.ps1` bleibt als Fallback bis zur Validierung (D12).

### Edge Cases & Risks

- **Gleichzeitige Requests für verschiedene Mandanten:** Job arbeitet seriell (While-Schleife) — gewollt (Backup-Datei `ops.Config.BackupFile` ist ein Single-Pfad; Klon-Backups serialisieren).
- **Job stirbt hart** (Agent-Neustart): Zeile bleibt `running` → Start-SP erlaubt für diesen Mandanten keinen neuen Request. Lösung: `reset.ProcessNextResetRequest` re-claimt beim Start `running`-Zeilen älter als 4h als `failed` (`ErrorText='stale running request reclaimed'`).
- **Restore einer 27-GB-DB**: Dauer ~Minuten; StepLog + GetResetStatus zeigen Fortschritt grob (kein STATS-Streaming in Tabellen — akzeptiert).
- **eazybusiness als Ziel:** dreifach verhindert (CHECK-Constraint, SP-Validierung, Job-Re-Validierung).
- **`tShop`-Repoint-Selektivität** (nur nTyp=0 + http-URL) aus e6d7b2b beibehalten — Check24/unicorn2 unangetastet.

### Acceptance

- Alle reset.*-Dateien vorhanden, Lint grün, jede Quell-Funktionalität aus `Projekte/Testsystem/` hat eine Ziel-Proc (Mapping-Tabelle im Chunk-Report; clear-customer-fields blockweise nachgewiesen).
- Statische Sicherheits-Review-Checks (§7-Lint): kein Nutzdaten-String in dynamisches SQL konkateniert (nur QUOTENAME/Parameter); jede internal-Proc guarded gegen `@TargetDb = 'eazybusiness'`.

---

## §4 — Validierung & Probeliste vm-sql-test1

**Status:** ✅ User-Approved
**Detail Location:** n/a — flat

### Files to Create / Modify

| Path | Action | Notes |
|---|---|---|
| `db-migrations/tests/probes/01_worker_ttarget_semantics.sql` | NEW | Read-only: Worker.tTarget + zugehörige JTL-Doku-Queries; Anleitung zur nAbgleichstyp-Deutung (O1) |
| `db-migrations/tests/probes/02_worker_discovery.md` | NEW | Probe-ANLEITUNG (manuell, test1): Worker-Dienst + frischer tMandant-Eintrag → Verhalten beobachten (O2) |
| `db-migrations/tests/probes/03_pf_user_in_clones.sql` | NEW | Read-only über alle eazybusiness*-DBs: pf_user-Zeilen (O4) |
| `db-migrations/tests/probes/04_queue_inventory.sql` | NEW | Read-only: alle Tabellen LIKE '%queue%' + Rowcounts je DB — vollständige Leerungs-Liste verifizieren |
| `docs/runbooks/testmandant-reset-validierung.md` | NEW | E2E-Validierungs-Runbook auf test1: global-Kette deployen → Agent starten → Fake-Mandant-Registry-Eintrag → Reset via SP → Prüfschritte (Status, Klon-Inhalt, Neutralisierung, Anonymisierung) |

### Implementation Approach

1. Probe-Skripte sind **strikt read-only** (SELECT/Katalog) und gegen test1 gedacht; Kopfkommentar mit Aufruf (`sqlcmd -S vm-sql-test1.zdbikes.local -E -C -i …`). Implementierende Agents DÜRFEN sie read-only gegen test1 ausführen und Ergebnisse im Chunk-Report festhalten (Zugriff via `/opt/mssql-tools*/bin/sqlcmd -E -C` besteht); Schreib-Probes (02) bleiben Anleitung für Lukas.
2. Validierungs-Runbook nummeriert die manuelle E2E-Sequenz inkl. Rollback (Klon droppen) und verweist auf O1/O2/O4 mit Erwartungswerten.

### Edge Cases & Risks

- test1 hat nur 1 Mandant + keinen tm-Klon → Runbook legt Registry-Eintrag `tmv` (Validierungs-Mandant) mit TargetDb `eazybusiness_tmv` an; Klon-Quelle ist test1s eazybusiness.
- Agent-Dienst auf test1 gestoppt → Runbook-Vorbedingung.

### Acceptance

- 4 Probe-Artefakte + Runbook vorhanden; Read-only-Probes wurden (wo Verbindung möglich) einmal ausgeführt und Ergebnisse im Report dokumentiert; O1/O2/O4 im Plan aktualisiert oder als „braucht manuellen Lauf" markiert.

---

## §5 — Doku, ADRs, Rollout-Runbook, Ablösung

**Status:** ✅ User-Approved
**Detail Location:** n/a — flat

### Files to Create / Modify

| Path | Action | Notes |
|---|---|---|
| `docs/SQL/MSSQL-OPS-ARCHITECTURE.md` | NEW | Architektur-Doku (englisch): Ebenen A/B, RoboticoOps, Reset-Fluss (Diagramm aus diesem Plan), EKL-Grenze, Betriebsregeln (Klon-nach-Update, Post-Update-Smoke-Test, Re-Signing) |
| `adrs/adr-grate-migration-runner.md` | NEW (plan-scoped) | D1/D3; Format per knowledge-adr-format, Status `Proposed (plan-scoped — pending promotion)` |
| `adrs/adr-two-chain-migration-paths.md` | NEW (plan-scoped) | D2/D11 |
| `adrs/adr-module-signing-reset.md` | NEW (plan-scoped) | D5/D6/D7/D8 |
| `docs/runbooks/rollout-mssql-ops.md` | NEW | Reihenfolge: (1) Baseline Ebene A prod+test1, (2) global-Kette auf test1, (3) Validierung (§4-Runbook), (4) global-Kette auf prod [manueller Gate + Prompt], (5) Seeds mit echten Keys, (6) erster prod-Reset tm4, (7) PowerShell-Ablösung |
| `docs/SQL/NAMING-CONVENTIONS.md` | EDIT | Ergänzen: RoboticoOps-DB (`ops`/`reset`-Schemas), Journal-Tabellen in Robotico, geteilte CW-Zone (D10-Regeln), Verweis auf db-migrations/README |
| `Projekte/Testsystem/setup-test-environment.ps1` | EDIT | Nur Kommentar-Banner oben: DEPRECATED-Hinweis auf neuen Reset + Runbook (Funktion unverändert, D12) |
| `Projekte/Testsystem/README.md` | NEW | Kurz: Ist-Prozess (Fallback) + Verweis auf Neu-Prozess und Runbooks |
| `docs/plans/README.md` | NEW | Plan-Archiv-Index gemäß Konvention (erster Plan dieses Repos) — Ordnerschema, Vergleichslogik, Sprachregeln |
| `docs/runbooks/README.md` | NEW | Runbook-Index |

### Implementation Approach

ADRs strikt nach `knowledge-adr-format`-Skill + `~/.claude/templates/adr.md` (Agent lädt beides); NNNN-Platzhalter, plan-scoped Status; `## References` bidirektional auf diesen Plan. Architektur-Doku nach `knowledge-doc-format` (UDOC), englisch (Sprachkonvention: Doku englisch, Plan deutsch). Alle Runbooks englisch.

### Edge Cases & Risks

- Doku-Drift-Gefahr Plan↔Architektur-Doku: Architektur-Doku ist post-Implementation-Snapshot, verweist auf den Plan als Historie (SSoT-Regel: Betriebsregeln leben in der Architektur-Doku, nicht doppelt im Plan).

### Acceptance

- Alle Dateien vorhanden; ADRs bestehen knowledge-adr-format-Pflichtsektionen; NAMING-CONVENTIONS-Edit minimal-invasiv (nur Ergänzung); Deprecation-Banner ändert keine Funktionszeile.

---

## §6 — Hygiene/Cleanup (nur vorbereitend — NIE autonom gegen prod)

**Status:** ✅ User-Approved
**Detail Location:** n/a — flat

### Files to Create / Modify

| Path | Action | Notes |
|---|---|---|
| `Berechtigungen/cleanup/01_dana_sysadmin_review.sql` | NEW | Read-only-Analyse: effektive Rechte von `dbuser_dev_dana_for_jtl`; + auskommentierter Fix (sysadmin-Entzug, Ersatz: dbcreator bleibt? granulare Grants) |
| `Berechtigungen/cleanup/02_tm2_refresh.md` | NEW | Anleitung: tm2 (JTL 1.11.6.0) via neuem Reset auf aktuellen Stand bringen |
| `Berechtigungen/cleanup/03_premig_db.sql` | NEW | Read-only-Info (Größe/Alter) + auskommentierte Optionen (Backup nach E:\Backup + DROP; O3) |
| `docs/runbooks/hygiene-findings.md` | NEW | Runbook, das die drei Punkte mit Kontext (Survey-Zitate) und Entscheidungsbedarf (O3) bündelt |

### Implementation Approach

Skripte tragen prominente Kopfwarnung („manual execution only, production impact"); die auszuführenden Statements sind auskommentiert und einzeln beschrieben. Keinerlei autonome Ausführung (D13).

### Acceptance

- 4 Artefakte vorhanden; kein unauskommentiertes schreibendes Statement in den cleanup-Skripten (Lint prüft das).

---

## §7 — Tests

**Status:** ✅ User-Approved

### Test Strategy

Kein Test-Framework im Repo (reines SQL-Repo) → drei statische/halb-statische Ebenen:

1. **Konventions-Lint** (`db-migrations/tests/lint-migrations.ps1`, pwsh-kompatibel, läuft unter Linux `pwsh` UND Windows): prüft rekursiv `db-migrations/{eazybusiness,global}`: (a) kein `^USE\s`-Statement, (b) kein `GO;`, (c) anytime-Dateien enthalten genau ein `CREATE OR ALTER`/`CREATE`-Hauptobjekt und der Dateiname matcht `Schema.Objekt.sql`, (d) verbotene Bezüge: `spCMArtikel`, `spCMArtikelNeu`, `RoboticoEKL` (außer Kommentaren), `DROP SCHEMA`, `TRUNCATE TABLE dbo.` , (e) up-Dateien: Namensmuster `NNNN_…`, (f) cleanup-Skripte (§6): keine unauskommentierten Writes, (g) dynamisches SQL: heuristische Prüfung auf `+ @` -Konkatenation von Nicht-QUOTENAME-Variablen in EXEC-Strings (Warnung). Exit-Code ≠ 0 bei Verstoß.
2. **Objekt-Abgleich** (`db-migrations/tests/compare-objects.sql`): listet je eazybusiness-DB die Robotico/CustomWorkflows-Objekte mit `OBJECT_DEFINITION`-Hash — für den Baseline-Vorab-Check (Datei==DB) und Post-Update-Smoke.
3. **SQL-Testdateien** (portiert aus `WorkflowProcedures/*_Tests.sql` nach `db-migrations/tests/eazybusiness/`): dokumentierter manueller Lauf gegen Testmandant; Kopfkommentar mit Aufruf + Erwartung.

### Test Files

| File | Type | Topic |
|---|---|---|
| `db-migrations/tests/lint-migrations.ps1` | static lint | Konventionen (a)–(g), CI-fähig |
| `db-migrations/tests/compare-objects.sql` | integration (read-only) | Datei↔DB-Objektabgleich für Baseline/Post-Update |
| `db-migrations/tests/eazybusiness/*.sql` | manual integration | portierte Bestandstests + Teardown |
| `db-migrations/tests/global/validate_structure.sql` | static | Referenz-Konsistenz reset.*/ops.* |
| `db-migrations/tests/probes/*.sql` | read-only probes | §4 |

---

## Verification

1. `pwsh db-migrations/tests/lint-migrations.ps1` → Exit 0.
2. Vollständigkeits-Mapping: jedes Objekt aus research/5 §3 ↔ genau eine Datei in `db-migrations/eazybusiness/` (Tabelle im Implementation-Report).
3. Jede Funktionalität der 6 Ist-Reset-Skripte ↔ eine reset.internal_*-Proc (Tabelle im Report).
4. Read-only-Probes gegen test1 gelaufen (soweit Verbindung im Implementationskontext verfügbar), Ergebnisse dokumentiert.
5. ADR-Format-Check gegen knowledge-adr-format-Pflichtsektionen.
6. Git: alle Commits nach Konvention `[<Phase>.<Chunk>] … (mssql-ops-infrastruktur)`.

---

## Critical Files

| Path | Action |
|---|---|
| `db-migrations/README.md` | NEW |
| `db-migrations/deploy.ps1` | NEW |
| `db-migrations/targets.config.json` | NEW |
| `db-migrations/eazybusiness/**` (up/functions/sprocs) | NEW (~28 Dateien) |
| `db-migrations/global/**` (up/sprocs/runAfterOtherAnyTimeScripts/permissions) | NEW (~15 Dateien) |
| `db-migrations/tests/**` | NEW (Lint, Vergleich, Tests, Probes) |
| `docs/SQL/MSSQL-OPS-ARCHITECTURE.md` | NEW |
| `docs/runbooks/{migrations-baseline,rollout-mssql-ops,testmandant-reset-validierung,hygiene-findings,README}.md` | NEW |
| `adrs/adr-{grate-migration-runner,two-chain-migration-paths,module-signing-reset}.md` | NEW (plan-scoped) |
| `docs/SQL/NAMING-CONVENTIONS.md` | EDIT (Ergänzung) |
| `Projekte/Testsystem/setup-test-environment.ps1` | EDIT (nur Banner) |
| `Projekte/Testsystem/README.md`, `WorkflowProcedures/README.md`, `docs/plans/README.md`, `docs/runbooks/README.md` | NEW |
| `Berechtigungen/cleanup/**` | NEW (3 Dateien) |

---

## Implementation Notes

- **Worktree:** ausschließlich in `worktrees/feature/mssql-ops-infrastruktur` arbeiten; Edit-Scope an alle Agents kommunizieren. Git-Befehle: `cd worktrees/feature/mssql-ops-infrastruktur; git …`.
- **Skills laden:** SQL-Chunks → `knowledge-sql` + `knowledge-jtl-sql`; ADR-Chunk → `knowledge-adr-format`; Doku-Chunk → `knowledge-doc-format`.
- **Server-Zugriff:** Read-only gegen test1/prod via `/opt/mssql-tools*/bin/sqlcmd -S <host> -E -C` erlaubt (Kerberos-Ticket des Users); **keinerlei Writes gegen irgendeinen Server** in diesem Plan — Deployment ist Runbook-Sache.
- **Sprachen:** Plan deutsch; alle neuen Doku-/README-/Runbook-Dateien englisch; SQL-Kommentare englisch (Neucode) — portierte Bestands-Kommentare dürfen deutsch bleiben (Provenienz).
- **Quell-Treue:** Portierungen ändern Verhalten NICHT stillschweigend; jede bewusste Abweichung (z. B. Anonymisierung bricht jetzt bei Blockfehler ab) ist im Code kommentiert und im Chunk-Report gelistet.
- **Secrets:** niemals echte ShopLicense-Keys, Cert-Passwörter o. ä. in Dateien; Platzhalter `{{…}}` + Runbook.

---

## Plan Conventions (Compatibility-Block for implement-long-plan)

**Plan-Type:** Greenfield-Implementation (mit Portierungsanteilen)
**Implementation Skill:** implement-long-plan-v3
**Block-Mode-Vorbereitung:** Chunks correspond to §1–§7 (Vorschlag: Block 1 = §1; Block 2 = §2+§3; Block 3 = §4+§6; Block 4 = §5+§7 — Analysis-Agent darf anpassen)
**Test-Position:** Tests in §7, Lint läuft je Chunk-Self-Check ab Verfügbarkeit

<!-- EXECUTION-PLAN -->
<!-- /EXECUTION-PLAN -->

---

## Iteration Log

### 2026-07-09 — Intent + Research (Phasen 1–2)
- Intent bestätigt (Annahmen 1–5); 6 Research-Berichte erstellt (4 Themen-Agents + Instanz-Survey + EKL-Grenze)
- Richtungsentscheidungen des Nutzers: grate, sysadmin-Job-Owner, Status-SP, Secrets in DB, Reset asynchron, RoboticoOps, F3/F4 = ja

### 2026-07-10 — Skeleton + Detailed (Phasen 3–4, komprimiert)
- Nutzer-Freigabe „alles Standards, komplett implementieren": Phase-4-Iteration mit empfohlenen Defaults komprimiert durchgeführt
- Building Blocks §1–§7 detailliert; D1–D13 festgeschrieben; O1–O5 offen markiert
- Complexity-Triage: Large; flat (Research-Subspecs als Evidenz)
- Status → Detailed; Übergabe an implement-long-plan-v3
