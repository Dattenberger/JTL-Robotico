---
name: migrations-tooling-vergleich
description: Vergleich Eigenbau/Flyway/DbUp/grate/DACPAC + grate-Vertiefung mit Migrationsplan (Web-Research, 2026-07-09)
status: Research
---

# Schema-Migrations-Management für MSSQL — Vergleich, grate-Vertiefung, Empfehlung

> Quelle: Opus-Research-Agent „research-migrations", zwei Berichte (Grundvergleich + Vertiefung), Session 2026-07-09.
> **Entscheidung des Nutzers: grate** für JTL-Robotico; der EKL-Runner in excel_ekl bleibt unangetastet.

Kontext: 2-4 Entwickler, reines SQL-Repo (git), Windows-Server, kein CI, JTL-Wawi-DB `eazybusiness` mit Vendor-Schema-Koexistenz, zwei Migrationspfade (global/Admin-DB + eazybusiness-lokal), regelmäßig frisch geklonte Testmandanten.

## Teil 1 — Grundvergleich

### Kernbefunde

**1. Flyway-Lizenzlage hat sich 2025 geändert.** Seit **14. Mai 2025** ist **Flyway Teams für Neukunden abgeschafft** — nur noch **Community (frei, Apache-2.0)** oder **Enterprise (teuer, per-User)**. Community: MSSQL, versioned + repeatable + Checksums, aber **kein `undo`** (Enterprise-Plugin), Dry-Run/Drift-Check/Cherry-Pick Enterprise-only. Redgate verschiebt Wert Richtung Enterprise. ([Community](https://www.red-gate.com/products/flyway/community/), [Editions](https://www.red-gate.com/products/flyway/editions/), [Licensing FAQ](https://documentation.red-gate.com/fd/commercial-licensing-faq-181633028.html))

**2. DACPAC/state-based ist im Vendor-Koexistenz-Szenario das gefährlichste Modell.** Der State-Diff-Ansatz denkt in „Soll-Zustand der ganzen DB", und JTL besitzt dieselbe DB:
- **Drop-Verhalten:** `sqlpackage` kann Schemata nicht vom Drop ausnehmen (kein `Schema`-Wert für `/p:DoNotDropObjectTypes`); Workaround wäre ein Deployment-Contributor (`AgileSqlClub.DeploymentFilterContributor`) — fragile Fremdlösung. ([Segun Akinyemi](https://segunakinyemi.com/blog/dacpac-dropping-objects/), [DacFx #129](https://github.com/microsoft/DacFx/issues/129), [agilesql.club](https://the.agilesql.club/2015/01/howto-filter-dacpac-deployments/))
- **Modell-Drift durch JTL-Updates:** Nach jedem JTL-Update hat sich das Vendor-Schema geändert; ein DACPAC mit Cross-Schema-Referenzen auf JTL-Tabellen bricht beim Build/Publish oder will „korrigieren". → **Nicht verwenden.**

**3. Migrations-basierte Runner (Eigenbau, Flyway, DbUp, grate) sind alle „vendor-safe" by design** — sie wenden nur die eigenen Skripte an, nie einen Ist-gegen-Soll-Diff über die ganze DB.

### Vergleichstabelle

| Kriterium | Eigenbau T-SQL | Flyway Community | DbUp | grate | DACPAC |
|---|---|---|---|---|---|
| Betriebs-Abhängigkeiten | nur sqlcmd+PS | **Java-Runtime** | .NET (Host-EXE) | .NET, **self-contained EXE** | .NET/sqlpackage |
| Lernkurve | Mechanik selbst bauen/pflegen | mittel | niedrig, aber C#-Host | niedrig-mittel, Konventionen | **hoch** (SSDT/Diff) |
| Multi-DB pro Mandant | Schleife im PS | gut | Schleife im Host | `--connectionstring` je Lauf | teuer/riskant |
| Vendor-Koexistenz | exzellent | exzellent | exzellent | exzellent | **schlecht** |
| Auditierbarkeit | selbstgebaut | stark (`flyway_schema_history`) | solide (`SchemaVersions`) | stark (`ScriptsRun` inkl. Text+Hash) | schwach |
| Zukunftssicherheit/Lizenz | volle Kontrolle | Redgate-Risiko | MIT, aktiv | Apache-2.0/MIT, aktiv | MS, Modell falsch |

Eigenbau-Einschätzung: wäre ~ genau das, was DbUp/grate fertig und getestet mitbringen — lohnt nur bei hartem Null-Abhängigkeits-Ziel.

### Vendor-Schema-Koexistenz — Best Practices (toolunabhängig)

- **Eigenes Schema als harte Grenze** (Robotico, CustomWorkflows); niemals JTL-Objekte per Migration ändern.
- **Eigene Journal-Tabelle im eigenen Schema** (nie `dbo`) — kollidiert nie mit JTL, wandert beim Klonen mit.
- **JTL-Major-Update = Re-Validierungs-Gate:** eigene Objekte am Testmandanten re-kompilieren; anytime-Skripte machen das billig.
- **Idempotenz + Guard-Clauses** in jedem Skript ([MSSQLTips](https://www.mssqltips.com/sqlservertip/11638/make-deployable-sql-scripts-idempotent/), [Redgate](https://www.red-gate.com/hub/product-learning/flyway/creating-idempotent-ddl-scripts-for-database-migrations/)).
- **Zwei-Pfade-Modell: EIN Tool, zwei getrennte Ketten** (Locations + Journale) — zwei verschiedene Verfahren wären unnötige kognitive Last.

## Teil 2 — grate-Vertiefung (entscheidungsreife Details)

### Ordnerkonventionen (deterministische Reihenfolge, drei Skript-Typen)

One-time = genau einmal (Journal; nachträgliche Änderung = Fehler) · Anytime = erneut bei **Hash-Änderung** · Everytime = jeder Lauf. ([FolderConfiguration.md](https://github.com/grate-devs/grate/blob/main/docs/ConfigurationOptions/FolderConfiguration.md))

| # | Ordner | Typ |
|---|---|---|
| 1 | `dropDatabase` | Anytime (nur mit `--drop`) |
| 2 | `createDatabase` | Anytime |
| 3 | `beforeMigration` | **Everytime** |
| 4 | `alterDatabase` | Anytime |
| 5 | `runAfterCreateDatabase` | Anytime (nur bei frischer DB) |
| 6 | `runBeforeUp` | Anytime |
| 7 | **`up`** | **One-time** — Kern-Migrationen |
| 8 | `runFirstAfterUp` | One-time |
| 9 | `functions` | Anytime |
| 10 | `views` | Anytime |
| 11 | `sprocs` | Anytime |
| 12 | `triggers` | Anytime |
| 13 | `indexes` | Anytime |
| 14 | `runAfterOtherAnyTimeScripts` | Anytime |
| 15 | `permissions` | **Everytime** |
| 16 | `afterMigration` | **Everytime** |

Reihenfolge innerhalb eines Ordners: alphabetisch → Abhängigkeiten zwischen anytime-Objekten über Namensgebung oder `runAfterOtherAnyTimeScripts` sichern.

### CLI (Windows-Beispiel)

```powershell
grate `
  --connectionstring="Server=PRODSRV;Database=eazybusiness_tm1;Trusted_Connection=True;TrustServerCertificate=True" `
  --sqlfilesdirectory=".\db-migrations\eazybusiness" `
  --databasetype=sqlserver `
  --schema=Robotico `
  --environment=TEST `
  --transaction `
  --silent `
  --version=$(git describe --tags --always)
```

Wichtige Optionen: `--schema` (Journal-Schema, default `grate`), `--baseline` („mark scripts as run, but not actually run anything"), `--dryrun`, `--warnononetimescriptchanges`, `--runallanytimescripts` (Fußangel: erzwingt alle anytime), `--usertoken Key=Value`, `--silent`.

### Journal-Tabellen (RoundhousE-Erbe, im `--schema`-Schema)

- **`Version`** — pro Lauf: id, repository_path, version, entry_date, entered_by.
- **`ScriptsRun`** — pro Skript: script_name, **text_of_script**, **text_hash**, one_time_script, entry_date, entered_by. Hash = Mechanismus für „anytime nur bei Änderung".
- **`ScriptsRunErrors`** — Fehlerprotokoll inkl. erroneous_part_of_script.

`--schema=Robotico` erfüllt die Journal-in-Robotico- und Klon-Mitwander-Anforderung direkt.

### Weitere Mechanik

- **Token-Replacement:** `--ut Key=Value` → `{{Key}}` im Skript; eingebaut `{{DatabaseName}}`, `{{ServerName}}`, `{{Environment}}`. Sparsam einsetzen (Skripte bleiben sonst ohne grate nicht lauffähig).
- **Fehler/Wiederaufnahme:** mit `--transaction` Rollback bei Skriptfehler, Fehler in `ScriptsRunErrors`; nächster Lauf überspringt erfolgreiche One-time-Skripte.
- **Baseline:** `grate --baseline` gegen die bestehende prod-DB nimmt den Ist-Stand ohne Re-Run auf.
- **GO-Batches:** Statement-Splitter erkennt `GO` — **aber Repo-Gotcha: `GO;` (mit Semikolon) wird ggf. nicht erkannt → vorher normalisieren.**
- **Distribution:** `dotnet tool install --global grate`, NuGet, **self-contained EXE** (nur ICU nötig), Docker. ([NuGet](https://www.nuget.org/packages/grate))
- **Projektgesundheit:** v2.1.5 (7. Juli 2026), 45 Releases, 22 offene Issues, jüngst in Community-Org **grate-devs** überführt, 291★. ([GitHub](https://github.com/grate-devs/grate))

### DbUp im Vergleich (Kurzfassung)

.NET-Bibliothek + selbst gepflegtes C#-Hostprogramm (~40 Zeilen, `dotnet publish` self-contained). Journal `JournalToSqlTable("Robotico","SchemaJournal")` (Spalten: SchemaVersionId, ScriptName, Applied). **Kern-Schwäche für unser Szenario:** RunAlways/NullJournal-Skripte laufen bei **jedem** Deploy (kein Hash-Vergleich, kein Journal-Eintrag → kein Änderungs-Audit, längere Deploys); Baseline manuell via `MarkAsExecuted`-Code. Projekt gesund (6.1.1 Feb 2026, MIT, 2.6k★). ([GitHub](https://github.com/DbUp/DbUp), [Doku](https://dbup.readthedocs.io/), [Script Types](https://dbup.readthedocs.io/en/latest/more-info/script-types/), [Journaling](https://dbup.readthedocs.io/en/latest/more-info/journaling/))

### Punkt-für-Punkt für unser Repo

grate ergonomischer bei: CREATE-OR-ALTER-lastigem Bestand (anytime+Hash), Änderungs-Audit (`ScriptsRun.text_of_script`+Hash), kein eigener Code, `--baseline` eingebaut. DbUp ergonomischer nur bei: bestehender .NET-Deploy-Pipeline / Bedarf an programmatischer Kontrolle.

**Betriebs-Risiken grate:** (1) Konventions-Magie — Ordnername bestimmt Semantik; einmal in `up` gelaufenes, dann editiertes Skript = Fehler (PR-Review-Punkt). (2) Alphabetische anytime-Reihenfolge bei Objektabhängigkeiten. (3) `--runallanytimescripts` in prod vermeiden. **Beiden gemeinsam:** `GO;`→`GO` normalisieren; **hartcodierte `USE eazybusiness`-Zeilen entfernen** — sonst zielt ein Skript trotz Klon-Connection-String auf prod!

### Zielstruktur + Beispiel-Mapping

```
db-migrations/
  eazybusiness/                  # Pfad B (Ebene A) → Journal Robotico-Schema
    up/          V-Skripte einmalig (Tabellen, Bootstrap)
    functions/   Anytime
    views/       Anytime
    sprocs/      Anytime
  global/                        # Pfad A (Ebene B) → RoboticoOps, Journal dort
    up/  sprocs/ …
```

| Ist-Datei | Ziel | Anpassung |
|---|---|---|
| `Workflowaktion Auftrag Preise auf Null.Sql` | `eazybusiness/sprocs/spAuftragPreiseAufNull.sql` | `GO;`→`GO`; Registrierungs-EXECs (idempotent) bleiben |
| `Workflowaktion_Gebinde_Erstellen.sql` | `eazybusiness/sprocs/spGebindeErstellen.sql` | **`USE eazybusiness` entfernen** |
| `Duplikaterkennung_Bestellungen.sql` | iTVF → `functions/`, SP → `sprocs/` | in 1-Objekt-Dateien splitten |
| `*_Tests.sql`, `*_Teardown.sql` | **separater `tests/`-Ordner außerhalb `--sqlfilesdirectory`** | nie in die Deploy-Kette |
| Infra-SPs `CustomWorkflows._CheckAction`/`_SetActionDisplayName` | `up/000_bootstrap_action_infra.sql` oder `sprocs/` | zuerst deployen |

Ablauf: einmalig `--baseline` gegen prod → normaler Zyklus: Testmandant (`--environment=TEST`) → Freigabe → prod. Anytime-Hash-Tracking macht Läufe gegen frisch geklonte Mandanten folgenlos → Klon-Reproduzierbarkeit erfüllt.

### Risiken der Empfehlung

1. Konventionsdisziplin (Ordner-Semantik) — PR-Review-Pflicht.
2. `GO;`/`USE eazybusiness`-Normalisierung ist Pflicht-Vorarbeit für den Gesamtbestand.
3. anytime-Reihenfolge bei Abhängigkeiten absichern.
4. Kein eingebautes Undo (gilt für alle Migrations-Runner): Rückbau = Kompensations-Migration.
5. Instanz-Objekte (Logins/Zertifikate/Jobs) brauchen sorgfältige Guard-Clauses (`IF NOT EXISTS … sys.server_principals`).
6. grate ist kleiner als DbUp (Bus-Faktor), aber kein Lock-in: Format = SQL-Dateien in Ordnern, Runner austauschbar.
