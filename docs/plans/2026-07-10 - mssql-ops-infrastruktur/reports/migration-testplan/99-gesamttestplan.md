---
date: 2026-07-27
author: Migrations-Testplan Lead-Agent (Opus) — Phase 3 Konsolidierung
status: Gesamttestplan — Ausführungsspezifikation + Ergebnis-Log-Index
context: Konsolidiert die fünf Detailpläne T1–T5 zu einer ausführbaren Gesamtspezifikation für den Migrations-E2E gegen den Container robotico-e2e-mssql. Enthält Ausführungsreihenfolge, Gesamt-Testfallliste mit Klassifikation, PASS/FAIL/EXPECTED-FAIL-Kriterien, Live-Vorabklärungen und den Index der Ergebnisdateien.
related: ./00-grundrecherche.md, ./T1-runner-journal-baseline.md, ./T2-reset-pipeline.md, ./T3-wartungssuite-container.md, ./T4-ebene-a-funktional.md, ./T5-umgebung-guards.md
---

# Gesamttestplan — MSSQL-Ops-Migrationen E2E

Ausführungsspezifikation für die Container-E2E aller im Rahmen der MSSQL-Ops-Infrastruktur
erarbeiteten Migrationen und Runner. Die fünf Detailpläne (T1–T5) sind die kanonischen Quellen
der Testfall-SQL; dieses Dokument ist der **Fahrplan + das Ergebnis-Register**.

> **Sicherheits-Invariante (bindend):** Alle Tests laufen **ausschließlich** gegen den Container
> `robotico-e2e-mssql` (`localhost,14330`, Env `E2E`, SQL-Auth `sa`). **`vm-sql2` = PRODUKTION =
> absolut tabu** (auch lesend). `vm-sql-test1` nur für die dokumentierten Fallback-Fälle
> (AD-Auth/Mail/`regwrite`/CEST) und dort **nur lesend / tm-Klone**. Jedes schreibende Testskript
> beginnt mit dem Guard `db-migrations/tests/_e2e_guard.sql` (`:r ./_e2e_guard.sql`, Multi-Signal-Deny,
> THROW 59001–59003). Keine Commits. PayPal-Staging unangetastet. Keine Secrets in Dateien.

---

## 1. Ausführungsreihenfolge & Abhängigkeiten

**Makro-Reihenfolge (von T3/T5 bestätigt):** `T5-Setup → T1 → {T2, T3, T4}`.

- **T5 ist Enabler** für alles: Container hoch, beide Ketten deployt, `ops.tConfig`-Repoint,
  restaurierte `eazybusiness`. Ohne T5 läuft kein anderer Fall.
- **T3-Kern läuft ohne Restore** (reine RoboticoOps-Instanz); nur **T3-14/15/23** (Watchdog gegen
  `eazybusiness`-Ziel, Reset↔Maint-Koexistenz) brauchen die restaurierte `eazybusiness`.
- **T1, T2, T4 brauchen** die restaurierte `eazybusiness`.
- **T4-Scratch-Fälle (T4-12, T4-13)** brauchen eigene Wegwerf-DBs (`T4_scratch`, `T4_compat`),
  **nicht** die `eazybusiness` — jederzeit isoliert lauffähig.

**Container-Setup nach T5 (7 Schritte, `T5-umgebung-guards.md` §2):**

1. `npm run db:e2e:down` (`-v`, altes Vor-Rename-Volume weg) → `npm run db:e2e:up` (frisch, Agent+Collation assertiert).
2. `set -a; source db-migrations/tests/docker/.env.local; set +a` (SA-Passwort in die Shell).
3. `npm run db:deploy:e2e:global` (Ebene B; legt `RoboticoOps` + `ops.tConfig` an, kein Backup nötig).
4. Ebene-B-Nachkonfiguration gegen `RoboticoOps` (Guard-Kopf): (a) `ops.tConfig`-Pfad-Repoint auf
   `/var/opt/mssql/...` (F2.5); (b) `MaintenanceSchedulesEnabled = '0'` **kontrolliert setzen**
   (Phase-A-Default — sonst kommen die Maint-Jobs im frischen Container ENABLED hoch, T3-Befund).
5. `eazybusiness_excel_ekl_copy_trimmed.bak` per `docker cp` + `RESTORE … WITH MOVE, RECOVERY, REPLACE`
   → `RECOVERY SIMPLE`. Vorab `RESTORE HEADERONLY` (`SoftwareVersionMajor ≤ 16`).
6. `npm run db:deploy:e2e` (Ebene A gegen die restaurierte `eazybusiness`).
7. `npm run db:e2e:validate` + `npm run db:validate:e2e` (beide Ketten grün).

**Teardown-Stufen zwischen Fällen (`T5` §5):** A = Klon-intern (Reset baut seinen tmN-Klon selbst neu,
~1–2 min); B = `eazybusiness` DROP+RESTORE (~2–3 min, für T1-Fälle, die die DB mutieren); C = Voll-Wipe
`down -v` + `up` + Setup (~10–12 min, für Ebene-B/Collation/Signaturketten-Reset).

**Reihenfolge-Feinschnitt je Topic** (aus den Detailplänen):

- **T1:** statisch zuerst (T1-07 Lint, T1-13 Gate) → Ebene-B-Genese (T1-01) → Cert-Tiers (T1-14) →
  Adoption (T1-02a/b) → Vollständigkeit (T1-16/17) → No-Op (T1-09) → Baseline/Maskierung (T1-03/04/05)
  → Hash (T1-06/08) → Teilfehlschlag (T1-10/11/12, je frische DB) → Reihenfolge/Journal-Reise (T1-15/18).
  Destruktive Fälle (02b, 04, 10–12) verlangen davor Stufe B/C.
- **T2:** Setup S1/S2 → Vollreset beide Pfade (T2-01/02) → Guard/THROW-Matrix (T2-10..30) →
  Permission (T2-31..33) → Teilfehlschlag (T2-40..44) → Stale/Cancel/Dedup (T2-50..57) →
  Agent-down (T2-60) → Signatur/Remap/Datum (T2-70..74) → Koexistenz (T2-80..82). Zwischen
  Reset-Fällen Stufe A + Cleanup C1.
- **T3:** Deploy/Ola/Registry (T3-01..03) → D29-Konvergenz (T3-04/05) → Idempotenz (T3-07/08) →
  xp_instance_reg* (T3-09) → Jobläufe (T3-10..12) → Watchdog-Matrix (T3-13..16) → Liveness
  (T3-17..20) → Running-Guard (T3-22) → Koexistenz (T3-23, an T2 abgestimmt).
- **T4:** Scratch-DBs zuerst (T4-12/13) → gegen `eazybusiness` Gruppen A→B→C→E (alle
  transaktions-gerollt, keine Rückstände).

---

## 2. Gesamt-Testfallliste mit Klassifikation

**Klassifikations-Legende:**
- **PASS-erwartet** — grüner Normalfall; FAIL = echter Regressionsbefund.
- **THROW-erwartet** — der Fall ist *dann* PASS, wenn die spezifizierte THROW-/Fehlernummer
  fällt (Guard-/Negativtest); Ausbleiben = FAIL.
- **EXPECTED-FAIL (Finding)** — die Assertion belegt bewusst einen Design-/Bug-Befund; „grün"
  heißt „Befund reproduziert". Nicht zu fixen ohne User-Entscheidung.
- **RUNTIME-OPEN** — Erwartung dokumentiert, aber erst der Live-Lauf klärt sie endgültig
  (Befund offen).

### 2.1 T1 — Runner / Journal / Baseline (18 Fälle)

| ID | Titel | Klasse |
|---|---|---|
| T1-01 | Ebene-B Greenfield: Journal-Genese, Zeilen==Dateien | PASS-erwartet |
| T1-02a | Adoption mit mitgereistem Ebene-A-Journal (Restore) | PASS-erwartet |
| T1-02b | Adoption ohne Journal (normaler Deploy, idempotente up/) | PASS-erwartet |
| T1-03 | `--baseline` markiert ohne Ausführung (Fingerprint vor==nach) | PASS-erwartet |
| T1-04 | F1.2 Baseline maskiert Rückstand + Remediation-Nachweis | PASS-erwartet (Maskierung *sichtbar*) |
| T1-05 | `compare-objects.sql` fängt Drift vor Baseline | PASS-erwartet |
| T1-06 | up/-Hash-Mismatch bricht grate hart ab | THROW-erwartet (hash-mismatch, exit≠0) |
| T1-07 | Lint-Regel (i) als vorgelagertes Gate (statisch) | PASS-erwartet |
| T1-08 | anytime-Hash-Änderung: nur das eine Objekt läuft neu | PASS-erwartet |
| T1-09 | Zweiter Lauf beider Ketten = No-Op (+ 50010-Ausnahme) | PASS-erwartet |
| T1-10 | Ebene-A up/-Fehler → `--transaction`-Rollback | RUNTIME-OPEN (R1: TX-Granularität) |
| T1-11 | Ebene-A anytime-Fehler unter `--transaction` | RUNTIME-OPEN (R1) |
| T1-12 | Ebene-B up/-Fehler ohne TX → committer Halbzustand + Wiederanlauf | PASS-erwartet |
| T1-13 | E2E-Environment-Auflösung + PROD-Gate (exit 1 bei N) | THROW/Gate-erwartet |
| T1-14 | Cert-Passwort-Token-Resolution (Tiers + CQG-4-Abbruch 50901) | THROW-erwartet (50901) |
| T1-15 | Ketten-Reihenfolge global↔eazybusiness + Unabhängigkeit | PASS-erwartet |
| T1-16 | Datei↔DB-Inventar-Parität nach Deploy (Soll-Bestand) | PASS-erwartet |
| T1-17 | PayPal-Drop-Vollständigkeit in beide Adoptions-Richtungen | PASS-erwartet |
| T1-18 | Journal-Reise: Klon trägt Ebene-A-Journal, RoboticoOps greenfield | PASS-erwartet |

### 2.2 T2 — Reset-Pipeline (Vollreset, Guard-Matrix, Teilfehlschlag, Stale/Cancel, Signatur, Koexistenz)

| ID | Titel | Klasse |
|---|---|---|
| T2-01 | Vollreset Agent-Job-Pfad (sp_start_job, Agent AN) | PASS-erwartet |
| T2-02 | Vollreset synchron (`EXEC spProcessNextResetRequest`, ohne Agent) | PASS-erwartet |
| T2-10..21 | Guard/THROW je Step (51010/11/12/14, 51020, 51030, 51040, 51050, 51060, 51070/71, 51080) | THROW-erwartet |
| T2-22/23 | Start-SP-Guard (51003 via CHECK vorverlagert; 51002 unbekannter Key) | THROW-erwartet |
| T2-24 | Orchestrator-Whitelist unbekannter spInternal_ → 51005 | THROW-erwartet |
| T2-25 | Orchestrator-Re-Validierung → Row `failed` ohne THROW, kein Prod-Touch | PASS-erwartet |
| T2-26..29 | Deklarative Backstops (CK_tMandant ×2, CK_tResetStep, IX_tResetRequest_Active) | THROW/Constraint-erwartet |
| T2-30 | CreateTestmandant-Guards (51090–51094) | THROW-erwartet |
| T2-31 | Reset mit fehlendem Login → `succeeded` + WARN, kein db_owner (PAR-1) | PASS-erwartet |
| T2-32 | Reset mit `cLoginName='sa'` → sa db_owner im Klon | PASS-erwartet |
| T2-33 | ApplyJtlRoles: fehlende AD-Member übersprungen, Rollen entstehen | PASS-erwartet |
| T2-40 | bCritical=0-Pfad: WARN statt Abbruch, Request `succeeded` | PASS-erwartet |
| T2-41 | Secret-Scrubbing (`cShopLicense` nie in cErrorMessage/cStepLog) | RUNTIME-OPEN (echtes Data-Echo nötig) |
| T2-42 | tConfig NICHT repointet → sauberer `failed`-Request, kein Halbschaden | PASS-erwartet |
| T2-43 | Mid-RESTORE-Kill → RESTORING-Leiche → Selbstheilung (Drop+Neu) | PASS-erwartet |
| T2-44 | Cursor-Cleanup-Regression (kein Fehler 16915 im Folgerequest) | PASS-erwartet |
| T2-50 | Stale-Reclaim (zurückdatierte running-Row → `failed`) | PASS-erwartet |
| T2-51 | Stale-Fallback bei fehlendem/nicht-numerischem Knob (→4h) | PASS-erwartet |
| T2-52 | Cancel eines queued Requests (queued→failed) | PASS-erwartet |
| T2-53 | Cancel-Race (queued→running zwischen Read/Write) | RUNTIME-OPEN (schwer deterministisch) |
| T2-54 | Cancel running bei inaktivem Job (Force-Reclaim; frische-Instanz-syssessions-leer) | PASS-erwartet |
| T2-55 | Cancel-Refusal bei aktivem Job → THROW 51007 | THROW-erwartet (Zeitfenster, RUNTIME-OPEN) |
| T2-56 | Unbekannter Request 51006 / Purge-Param 51008 / Dry-Run | THROW-erwartet |
| T2-57 | Dedup laufender Requests (OPS-6, gleiche kResetRequest) | PASS-erwartet |
| T2-60 | sp_start_job bei gestopptem Agent (22022-Schluckverhalten) | RUNTIME-OPEN (Kernbefund) |
| T2-70 | Signatur-Überleben über Re-Deploy (900 re-signiert) | PASS-erwartet |
| T2-71 | Falsches {{CertPassword}} beim Re-Deploy → 50901 | THROW-erwartet |
| T2-72 | 250 Orphan-Remap (jobstartuser-SID divergiert) + No-Op-Gegenprobe | PASS-erwartet |
| T2-73 | Deploy-Guard 50010 bei aktivem Request | THROW-erwartet |
| T2-74 | Deutsche Login-Default-Language beim Deploy (Datumsliteral, kein 190) | PASS-erwartet |
| T2-80 | Beide Job-Familien koexistieren nach Deploy; Re-Deploy 0 Änderungen | PASS-erwartet |
| T2-81 | 50010-Guard während aktivem Reset blockiert auch Wartungs-Änderung | THROW-erwartet |
| T2-82 | Reset läuft parallel zu Wartungsjob (Phase B) — keine Verklemmung | PASS-erwartet |

### 2.3 T3 — Wartungssuite im Container (23 Fälle)

| ID | Titel | Klasse |
|---|---|---|
| T3-01 | Deploy grün, up/ unverändert re-run | PASS-erwartet |
| T3-02 | Ola-Platzierung in RoboticoOps.dbo (kein DatabaseBackup) | PASS-erwartet |
| T3-03 | Registry 6 Zeilen exakt §3.2 | PASS-erwartet |
| T3-04 | D29-Konvergenz End-State (Operator + Notify verdrahtet) | PASS-erwartet |
| T3-05 | D29-Zwischenzustand: Operator-drop→Ensure NotifyLevel 0→260→2 | PASS-erwartet |
| T3-06 | Schalter-Effektivlogik: frischer Container = Jobs ENABLED (unset), '0' = disabled | PASS-erwartet |
| T3-07 | AC7 0-change-Redeploy (Ensure „0 change(s)") | PASS-erwartet |
| T3-08 | MERGE Removal NOT MATCHED BY SOURCE (Registry-Zeile entfernt → Job weg) | PASS-erwartet |
| T3-09 | xp_instance_regread/regwrite unter Linux — Verhalten | RUNTIME-OPEN |
| T3-10 | Reale Job-Läufe via sp_start_job trotz disabled | PASS-erwartet |
| T3-11 | Ola-Procs real (CommandLog-Einträge) | PASS-erwartet |
| T3-12 | UpdateStatistics=ALL / REORGANIZE-only (D13) | PASS-erwartet |
| T3-13 | Watchdog: leere Backup-History → THROW 51100 | THROW-erwartet |
| T3-14 | Watchdog: Invalid-Target + USER_DATABASES-Token → 51100 (braucht eazybusiness) | THROW-erwartet |
| T3-15 | Watchdog: SIMPLE-Blindheit + FULL-Log-Fall (braucht eazybusiness auf FULL) | PASS-erwartet |
| T3-16 | Watchdog: Grenzwert inklusiv (`@FullMaxHours=0` → 51100) | THROW-erwartet |
| T3-17 | Liveness: Schalter '0' → sofort RETURN (SILENT) | PASS-erwartet |
| T3-18 | Liveness: First-Run-Grace (frische Rows alarmieren nicht) | PASS-erwartet |
| T3-19 | Liveness: zurückdatiertes dModified → THROW 51105 | THROW-erwartet |
| T3-20 | Liveness: bUpdateStatistics-Heartbeat-Kopplung | PASS-erwartet |
| T3-22 | Running-Job-Guard Skip + Konvergenz beim nächsten Deploy | PASS-erwartet |
| T3-23 | Koexistenz Reset+Maint im geteilten Agent (an T2-82 abgestimmt) | PASS-erwartet |

### 2.4 T4 — Ebene-A funktional (16 Fälle, inkl. 4 Findings)

| ID | Titel | Klasse |
|---|---|---|
| T4-01 | `spAuftragPreiseAufNull` (nicht-fakturiert=0, fakturiert geschützt, TVP-Create) | PASS-erwartet |
| T4-02 | `spGebindeErstellen` (happy/flag/50000) **+ F4.6 Nicht-Idempotenz** | PASS-erwartet **+ EXPECTED-FAIL (F4.6)** |
| T4-03 | `spSeriennummerStandardZuWMS` (genug/zu wenig Platzhalter, Quasi-Idempotenz) | PASS-erwartet |
| T4-04 | `spZustandartikelLieferantSetzen` (set/clear/idempotent/kZustand=1-Schutz) | PASS-erwartet |
| T4-05 | `spVpeCheckLieferantenbestellung` (Protokoll a–f, 50001 NULL-Key, 2000/255-Guards) | PASS-erwartet |
| T4-06 | up/0003 PayPal-Drop wirkt, re-run-fest, klon-tolerant | PASS-erwartet |
| T4-07 | CustomField-API: Self-Healing QG3-B6, kSprache<>0, Race-2627 | PASS-erwartet |
| T4-08 | History-SPs: 1000-Trim, Inland-Fallback 19%, 7%-Satz, fehlende Definition | PASS-erwartet |
| T4-09 | Duplicate-Order: **F4.5 NULL-Fingerprint**, nType-Filter, Test-8-Ersatz | PASS-erwartet **+ EXPECTED-FAIL (F4.5)** |
| T4-10 | Parser-Randfälle: Nur-Leerzeilen→NULL, **F4.4 US-Format**, Nur-CRLF→NULL | PASS-erwartet **+ EXPECTED-FAIL (F4.4)** |
| T4-11 | Modul nicht gebucht (`_CheckAction` fehlt → PRINT, Aktion trotzdem angelegt) | PASS-erwartet |
| T4-12 | Schema `CustomWorkflows` fehlt → CREATE 2760 (**F4.1 offene Frage**) | THROW-erwartet **+ Klärungsfrage (F4.1)** |
| T4-13 | SQL-2022-Floor: STRING_SPLIT-Ordinal Runtime-Fail bei Compat 150 | THROW-erwartet (Laufzeit) |
| T4-14 | Direkt-UPDATE auf tLieferantenBestellungPos scheitert am Guard-Trigger | THROW/Block-erwartet |
| T4-15 | VPE-Lauf ändert nur cHinweis → `tlagerbestand` unverändert | PASS-erwartet |
| T4-16 | Guard-Trigger-Existenz auf tArtikel/tLagerArtikel (read-only Probe) | PASS-erwartet (Doku) |

### 2.5 T5 — Umgebung/Guards (Enabler, mit eigenen Negativ-/Matrix-Fällen)

| ID | Titel | Klasse |
|---|---|---|
| T5-Setup | 7-Schritte-Container-Aufbau (beide Ketten grün, validate OK) | PASS-erwartet (Gate für alles) |
| T5-Coll-Neg | Naiver Container ohne Collation-Env → Ebene-B-Deploy THROW 50001 | THROW-erwartet |
| T5-Locale | German-Default-Language-Login: `EXPIRY_DATE '29991231'` kein Fehler 190 | PASS-erwartet |
| T5-Guard | `_e2e_guard.sql` scharf (G1) + Clone-Guard-Scharf-Test (G4, 51010) | THROW-erwartet |

---

## 3. EXPECTED-FAIL / Findings-Register

Diese Fälle sind „grün" = **Befund reproduziert**. Sie werden **nicht gefixt** — die Fix-Entscheidung
ist eine offene User-Frage (Grundrecherche §5 Frage 4). Im Ergebnis-Log als `EXPECTED-FAIL (reproduziert)`
oder `EXPECTED-FAIL (nicht reproduziert — nachprüfen)` geführt.

| ID | Finding | Klassifikation |
|---|---|---|
| T4-02 / F4.6 | `spGebindeErstellen` nicht idempotent (Doppellauf → 2 `tGebinde`-Zeilen + doppeltes Suffix) | Bekannter Bug — Fix offen (Frage 4) |
| T4-10b / F4.4 | `fnStringParseGermanDecimal('1,234.56')` → stiller Falschwert `1.23456` statt NULL | Latenter Bug — dokumentieren |
| T4-09a / F4.5 | `fnFindDuplicateOrders`: NULL/NULL-Freiposition → degenerierter Fingerprint, Kollisionsrisiko | Design-Randfall — niedrige Praxiswahrscheinlichkeit |
| T4-12 / F4.1 | Ebene A legt Schema `CustomWorkflows` nirgends an → CREATE 2760 auf DB ohne Schema | Offene Frage — defensives CREATE SCHEMA vs. dokumentierte Voraussetzung |
| T4-10a | `fnStringTrimToMaxLines` über Nur-Leerzeilen → NULL | Verhaltens-Pin (kein Bug) |

**Status nach T4-Ausführung (2026-07-27):** **T4-02/F4.6 reproduziert** (Doppellauf → 2 `tGebinde`-Zeilen
+ doppeltes Suffix), **T4-10b/F4.4 reproduziert** (US-`'1,234.56'` → `1.23456` statt NULL),
**T4-12/F4.1 reproduziert** (CREATE 2760 ohne `CustomWorkflows`-Schema), **T4-10a reproduziert**
(Nur-Leerzeilen → NULL). **T4-09a/F4.5 NICHT reproduziert** — die ANSI-NULL-Semantik verhindert den
befürchteten Falsch-Positiv (zwei NULL/NULL-Freipos-Aufträge kollidieren NICHT als Duplikat); das
Restrisiko ist damit nur ein **Falsch-Negativ** (ein echtes Duplikat wird evtl. nicht erkannt), nicht ein
Falsch-Positiv → Schweregrad heruntergestuft.

### 3.1 Spec-Präzisierungen aus der T1-Ausführung (2026-07-27)

Keine Bugs — Klarstellungen der grate-/Deploy-Semantik, die den Testplan schärfen:

| Nr | Präzisierung | Konsequenz |
|---|---|---|
| SP-1 | **`--transaction` (Ebene A) = EINE Transaktion über den ganzen Lauf** (all-or-nothing). Beleg: ein anytime-Fehler rollte den `up/0003`-PayPal-Drop **desselben Laufs** mit zurück (R1 geklärt). Ebene B committet **per Skript** (keine umschließende TX). | Ein Ebene-A-Teilfehlschlag ist wirklich „alles-oder-nichts"; T1-10/11 = PASS. |
| SP-2 | **grate-Docker-Runner propagiert SQL-Fehler zuverlässig als exit 1** (R2 geklärt). | Alle Fehler-Erwartungen (T1-06/10/11/14, T2-71/73) sind über den exit-Code robust prüfbar. |
| SP-3 | **`permissions/`-Skripte erzeugen `ScriptsRun`-Zeilen** (everytime, +5/Lauf) — anders als in T1-R3 vermutet. | Journal-Zeilenzahl-Erwartung (T1-01) entsprechend: anytime-Dateizeilen **plus** everytime-Permissions-Zeilen. |
| SP-4 | **`ScriptsRunErrors`-Zeile überlebt den Ebene-A-`--transaction`-Rollback** (grate schreibt sie in eigener Transaktion/nach Rollback). | Fehlerprotokoll bleibt nach einem gerollten Lauf lesbar. |
| SP-5 | **Falsches Cert-Passwort beim Re-Deploy wird als `OneTimeScriptChanged` gefangen, NICHT via THROW 50901.** Der 0011-Pfad ist one-time-journaled → grate meldet Hash-/One-Time-Änderung, bevor 900 den 50901-Pfad erreicht. | **Erwartung für T1-14/CQG-4 und T2-71 anpassen:** primärer Fehlermodus ist die OneTimeScriptChanged-Meldung (exit≠0), 50901 ist der nachgelagerte 900-Pfad. T2-71 im Container entsprechend werten. |
| SP-6 | **Compat-Floor-These WIDERLEGT (T4-13):** der 3-Argument-`STRING_SPLIT(…, 1)` (enable_ordinal) läuft bereits **ab Compatibility-Level 130**, nicht erst ab 160. Der in `db-migrations/README.md:420-427` behauptete „SQL-2022-Floor" für die Ebene-A-String/CSV-API stimmt für `STRING_SPLIT` **nicht** (der echte Engine-Floor liegt bei SQL 2016/Compat 130). | **Doku-Korrektur:** README §8-Engine-Floor-Aussage präzisieren (der ordinal-`STRING_SPLIT`-Teil ist kein 2022-Floor). Betrifft nur die Doku-These, nicht den Code; die Objekte laufen im 2022-Container ohnehin. |
| SP-7 | **Guard-Trigger-Landschaft (T4-14/16 empirisch):** `tLieferantenBestellung` (Kopf) trägt einen **eigenen** Guard-Trigger — das Seed braucht `CONTEXT_INFO 0x5121` (nicht nur `0x5123` für die Pos-Tabelle). `tLagerArtikel` hat **keine** Rollback-Guards; ein `tArtikel`-Direktwrite geht **trotz** Validator-Trigger durch. | Dokumentiert die reale Trigger-Situation; erklärt, warum `spGebinde`/`spSeriennummer`/`spZustandartikel` direkt schreiben dürfen (T4-02/03/04-PASS = funktionaler Beleg). CONTEXT_INFO-Konstante fürs VPE-Seeding: Kopf `0x5121`, Pos `0x5123`. |

### 3.2 ECHTE BEFUNDE aus der Ausführung — nicht geplant, nicht gefixt (User entscheidet)

Regressionsbefunde/Setup-Lücken, die während PASS-erwarteter Fälle aufgedeckt wurden. **Keine Fixes
implementiert** (User-Entscheidung am Ende). Fix-Kandidaten sind nur Vorschläge.

| ID | Herkunft | Befund | Schweregrad | Fix-Kandidat |
|---|---|---|---|---|
| **F-1** | T2 (Cancel) | `spPub_CancelResetRequest` **running-Branch unbenutzbar**: `jobstartuser` fehlt `SELECT` auf `msdb.dbo.syssessions` → Cancel scheitert mit **Msg 229** *vor* dem 51007-Guard. Der Force-Reclaim-Pfad (OPS-2) ist damit im signierten Kontext tot. | **ECHTER BUG, prod-relevant** | `GRANT SELECT ON msdb.dbo.syssessions` an `jobstartuser` in einem `up/0010`-Nachfolger bzw. `permissions/`-Skript |
| **F-2** | T2 (GrantAccess) | `spInternal_GrantAccess` **bricht bei `cLoginName='sa'`** (Special-Principal: `CREATE USER [sa]`/db_owner-Add scheitert, sa=dbo) → Reset endet `failed`. | **ECHTER BUG** | WARN-Skip für Spezial-Prinzipale (`sa`/`dbo`/…) analog zum Fehlender-Login-Skip (PAR-1) |
| **F-3** | T2 (Signaturkette) | **master-Zertifikat wird bei RoboticoOps-Rebuild nicht nachgezogen**: `up/0011` ist one-time-journaled und `900` fasst `master` nicht an → nach `DROP DATABASE RoboticoOps` + Redeploy fehlt der master-Public-Key/Login, die msdb-Signaturkette ist gebrochen. | **Setup-Lücke** | T5-Runbook-Pflichtschritt: bei Ebene-B-Rebuild master-Cert+Login mit droppen/neu ziehen (analog test1-Teardown-Notiz) |

> **F-2-Kontext:** In §0/S2 wurde `@LoginName='sa'` bewusst als container-vorhandener Login gewählt.
> Der Befund heißt: der Vollreset gelingt zwar über den regulären Pfad, aber `GrantAccess` selbst kann
> `sa` nicht als db_owner setzen — für einen sauberen tm-Klon-Zugriff braucht es einen **echten**
> Nicht-Special-Login. Die T2-Vollreset-PASS nutzten das entsprechend.

---

## 4. Live-Vorabklärungen (vor bzw. beim ersten Container-Lauf zu bestätigen)

Diese Punkte sind **keine** Findings, sondern Annahmen, die der erste Lauf verifiziert; sie fließen in
das jeweilige Setup ein.

1. **CONTEXT_INFO-Bypass-Konstante** fürs VPE-/Trigger-Seeding: `0x5123` (live beobachtet) vs. `0x5124`
   (Research tentativ). Betrifft T4-05/T4-14-Seed. Scheitert das Seed-INSERT am Guard-Trigger → auf
   `0x5124` umstellen. Der eigentliche SP-Testpfad hängt nicht davon ab.
2. **Guard-Trigger-Existenz** auf `tArtikel`/`tLiefArtikel`/`tLagerArtikel`/`tGebinde` (T4-16 read-only
   Probe); wenn ein Rollback-Guard existierte, wären T4-02/03/04 bereits gescheitert → deren PASS ist
   der funktionale Beweis.
3. **Exakte NOT-NULL-Spaltenlisten** von `Rechnung.tRechnung(Position)`, `tLieferantenBestellung(Pos)`,
   `tlagerbestand` im getrimmten Klon — beim ersten Lauf aus `A_Context/JTL 1.10.11.0/` ergänzen
   (T4-01/05/15 Seed-Blöcke).
4. **Backslash-in-Linux-Pfad** von `RESTORE … WITH MOVE` (`TargetDataDir + '\' + …`, T2-01/CloneDatabase):
   im 2026-07-11-Lauf tolerant — im aktuellen Lauf explizit verifizieren.
5. **22022 bei gestopptem Agent** (T2-60): ob `sp_start_job` bei Agent-down 22022 liefert und vom
   Start-SP als „already running" geschluckt wird → Row bliebe still `queued`. Kernbefund, im Container
   festhalten; falls bestätigt → Folge-Ticket.
6. **`RESTORE HEADERONLY` SoftwareVersionMajor ≤ 16** des vorhandenen Backups (T5-Setup Schritt 5) —
   Gate, bevor das Backup in den 2022-Container geht.
7. **grate-Docker-Runner exit-Propagation** (T1-R2): ob interne SQL-Fehler zuverlässig als
   Container-exit≠0 durchschlagen — betrifft alle Fehler-Erwartungen (T1-06/10/11/12/14, T2-71/73).

---

## 5. PASS / FAIL / EXPECTED-FAIL — Bewertungsregeln

- **PASS-erwartet-Fall** → **PASS**, wenn die spezifizierte Assertion grün ist; sonst **FAIL** (echter
  Regressionsbefund, sofort an den Lead melden).
- **THROW-erwartet-Fall** → **PASS**, wenn genau die spezifizierte THROW-/Fehlernummer fällt und **kein
  Write** durchging; **FAIL**, wenn kein Fehler oder eine andere Nummer fällt.
- **EXPECTED-FAIL (Finding)** → **PASS des Testplans** = Befund reproduziert (Assertion grün). Wird als
  `EXPECTED-FAIL (reproduziert)` protokolliert, **nicht** als Bug behandelt. Reproduziert der Fall den
  Befund NICHT, ist das ein `EXPECTED-FAIL (nicht reproduziert)` → nachprüfen (Proc könnte sich geändert
  haben).
- **RUNTIME-OPEN** → das Ergebnis wird protokolliert (PASS/FAIL/inconclusive) **plus** der Befund
  festgehalten; ein „inconclusive" ist zulässig und wird als solches gemeldet, nicht geraten.
- **Blocker** (Backup unbrauchbar, Docker-/Restore-Fehler, Collation, Port) → **nicht raten**, sofort an
  den Lead melden (Grundrecherche/T5 §6 Blocker-Tabelle B1–B11).

---

## 6. Ergebnis-Log-Index (`ergebnisse/`)

Je Themengebiet eine Ergebnisdatei mit PASS/FAIL/EXPECTED-FAIL/Detail je Fall-ID; am Ende dieses
Dokument um die Ergebnis-Summary ergänzen.

| Datei | Inhalt | Status |
|---|---|---|
| `ergebnisse/00-umgebung-setup.md` | T5-Setup-Ausführung (Container, Restore, Deploys, validate) + Blocker | **GRÜN** (2026-07-27) |
| `ergebnisse/T1-runner-journal-baseline.md` | T1-01…18 | **18/18 PASS** (2026-07-27) |
| `ergebnisse/T2-reset-pipeline.md` | T2-01…82 | **44 PASS, 2 Bugs (F-1/F-2), 1 Setup-Lücke (F-3), 2 RUNTIME-OPEN** (2026-07-27) |
| `ergebnisse/T3-wartungssuite.md` | T3-01…23 | **18 PASS, 4 THROW-OK, 1 dok., 1 SKIP — 0 Findings** (2026-07-27) |
| `ergebnisse/T4-ebene-a-funktional.md` | T4-01…16 | **21 PASS, 3 THROW-OK, 3 EXPECTED-FAIL reprod., 2 nicht reprod., 3 SKIP — 0 echte FAILs** (2026-07-27) |
| `ergebnisse/T6-fix-verifikation.md` | Fix-Verifikation F-1/F-2/F4.6/F4.4/F4.1 (Phase 4) | **alle 5 VERIFIED-FIXED, 70/70 Regressionstests PASS, Idempotenz beider Ketten sauber, validate:e2e grün** (2026-07-28) |

---

## 7. Ergebnis-Summary

> Wird nach Abschluss der Ausführung je Themengebiet fortgeschrieben (PASS/FAIL/EXPECTED-FAIL/RUNTIME-OPEN
> je Topic, plus die reproduzierten Findings und offenen Befunde).

| Topic | Ergebnis | Details |
|---|---|---|
| **Umgebung (T5-Setup)** | GRÜN | beide Ketten deployt, `eazybusiness` restauriert, `db:validate:e2e` OK; 2 Setup-Befunde (EKL-Fremdproc, Maint-Konvergenz) |
| **T1** | **18/18 PASS** | R1 geklärt (Ebene-A `--transaction` all-or-nothing), R2 geklärt (exit 1 zuverlässig), 5 Spec-Präzisierungen (§3.1). Umgebung sauber grün hinterlassen. |
| **T2** | **44 PASS, 3 FINDINGS, 2 RUNTIME-OPEN** | Komplette THROW-Matrix getroffen, beide Vollreset-Pfade `succeeded`, Backslash-Linux-Pfad RESOLVED (tolerant). **2 echte Bugs (F-1 syssessions-GRANT, F-2 sa-GrantAccess), 1 Setup-Lücke (F-3 master-Cert-Rebuild)** — §3.2. T2-60 (Agent-down) + T2-41/53/55-Timing RUNTIME-OPEN. |
| **T3** | **18 PASS, 4 THROW-OK, 1 dok., 1 SKIP — 0 Findings** | Watchdog/Liveness-THROWs by design getroffen; Effektiv-Gleichung live bestätigt (unset=enabled); reale Jobläufe grün inkl. IndexOptimize gegen die große eazybusiness (~8 min, REORGANIZE-only, 4335 Statistik-Updates). Phase-A-Baseline sauber zurückgesetzt. **1 Plattform-Anmerkung (P-1).** |
| **T4** | **21 PASS, 3 THROW-OK, 3 EXPECTED-FAIL reprod., 2 nicht reprod., 3 SKIP — 0 echte FAILs** | Alle 5 testlosen Aktionen + Vpe abgedeckt. **F4.6/F4.4/F4.1 reproduziert** (echte Bugs, §8-A). **F4.5 NICHT reproduziert** (ANSI-NULL verhindert den Falsch-Positiv — Restrisiko nur Falsch-Negativ). **F4.3 Compat-Floor WIDERLEGT** (ordinaler `STRING_SPLIT` läuft ab Compat 130, nicht erst 160 → README-These korrigieren, SP-6). 3 SKIP = Fixture-Lücken im getrimmten Klon. Zusatzbefunde zu Guard-Triggern (§8). |

**Plattform-Anmerkung P-1 (T3, kein Bug):** `xp_instance_regwrite` läuft auf **Linux fehlerfrei, ist aber
wirkungslos** — der geschriebene Wert ist nicht zurücklesbar; das Agent-Mail-Profil ist im Container nur
über `mssql-conf set sqlagent.databasemailprofile` setzbar. Auf **Windows-Prod bleibt der Registry-Pfad
(`permissions/260`) der richtige** — reiner Plattform-Unterschied, im Container erwartbar. Echter
Mailversand war out of scope (nur Struktur/Operator/PRINT-Pfad geprüft).

Offene Vorabklärungen (§4) — Endstand: **#1 CONTEXT_INFO-Konstante geklärt** (Kopf `0x5121`, Pos `0x5123`,
SP-7); **#2 Guard-Trigger-Landschaft geklärt** (SP-7); **#3 NOT-NULL-Spalten** beim Lauf ergänzt (3 SKIP
wo Fixtures im Trimm fehlten); **#4 Backslash-Linux-Pfad RESOLVED** (tolerant, T2); **#6 Backup-Version-Gate
bestanden** (SoftwareVersionMajor 16); **#7 / R1 geklärt** (SP-1/SP-2); **xp_instance_reg*-Linux geklärt**
(P-1); **Compat-Floor geklärt/widerlegt** (SP-6). **Einzig #5 (22022 bei Agent-down, T2-60) bleibt offen** —
bewusst nicht provoziert (Container-Agent-Risiko).

---

## 8. Gesamtabschluss & Entscheidungsvorlage

### 8.1 Gesamtergebnis

| Gebiet | PASS | THROW-OK | EXPECTED-FAIL | RUNTIME-OPEN / SKIP | echte FAILs |
|---|---|---|---|---|---|
| Umgebung (T5-Setup) | GRÜN | — | — | — | 0 |
| T1 Runner/Journal/Baseline | 18 | (in PASS) | — | 0 | 0 |
| T2 Reset-Pipeline | 44 | (in PASS) | — | 2 RUNTIME-OPEN | 0* |
| T3 Wartungssuite | 18 | 4 | — | 1 dok. + 1 SKIP | 0 |
| T4 Ebene-A funktional | 21 | 3 | 3 reprod. / 2 nicht | 3 SKIP | 0 |

\*T2 = 0 FAILs im Sinne „Testfall rot", aber **2 echte Bugs** über die Ausführung aufgedeckt (F-1/F-2, §8.2-A).

**Gesamturteil:** Die Migrationsinfrastruktur ist **funktional tragfähig** — beide grate-Ketten
deployen/adoptieren/re-deployen sauber (all-or-nothing Ebene A, idempotentes Ebene B), der
Testmandanten-Reset läuft E2E über die Signaturkette, die Wartungssuite arbeitet inkl. realer Ola-Läufe,
und die Ebene-A-Objekte funktionieren gegen echtes JTL-Schema. **Kein Testfall deckte einen
funktionsverhindernden Defekt auf.** Aufgedeckt wurden **5 echte Bugs/Design-Fragen**, mehrere
Doku-Präzisierungen und drei Setup-Pflichtschritte (unten). Alle bekannten EXPECTED-FAIL-Findings sind
wie erwartet reproduziert (bis auf F4.5, das sich als ungefährlicher herausstellte).

### 8.2 Konsolidierte Findings — Entscheidungsvorlage (KEINE Fixes implementiert)

#### (A) Echte Bugs / Design-Fragen — Fix-Kandidaten

| ID | Befund | Empfehlung | Aufwand |
|---|---|---|---|
| **F-1** | `spPub_CancelResetRequest` running-Branch tot: `jobstartuser` fehlt `SELECT` auf `msdb.dbo.syssessions` → Msg 229 vor 51007 (Force-Reclaim im signierten Kontext unbenutzbar). **Prod-relevant.** | **✅ GEFIXT** — `permissions/255_reset_cancel_msdb_grants.sql` (everytime, idempotent). **Empirische Fix-Realität:** es braucht `GRANT SELECT` auf **DREI** msdb-Tabellen (`syssessions` + `sysjobs` + `sysjobactivity`) **direkt** an `jobstartuser`; die `SQLAgentOperatorRole`-Mitgliedschaft trägt nicht über den signierten Cross-DB-`EXECUTE AS`-Hop (nur direkte Objekt-Grants). Regressionstest `tests/global/ResetCancelRunning_Tests.sql`. | S — erledigt |
| **F-2** | `spInternal_GrantAccess` bricht bei `cLoginName='sa'`/Special-Principals (CREATE USER/db_owner-Add scheitert) → Reset `failed`. | **✅ GEFIXT** — WARN-Skip für Special-Prinzipale in `sprocs/reset.spInternal_GrantAccess.sql` (CREATE-OR-ALTER). Regressionstest `tests/global/GrantAccessSpecialPrincipal_Tests.sql`. | S — erledigt |
| **F4.6** | `spGebindeErstellen` nicht idempotent (Doppellauf → 2 `tGebinde`-Zeilen + doppeltes HAN-Suffix). Doppel-Trigger im Workflow = Datenmüll. | **✅ GEFIXT** — Bereits-Suffix-/Bereits-Gebinde-Guard in `sprocs/CustomWorkflows.spGebindeErstellen.sql`, Re-Run = No-Op. Regressionstest `tests/eazybusiness/GebindeErstellen_Tests.sql`. | S–M — erledigt |
| **F4.4** | `fnStringParseGermanDecimal('1,234.56')` → stiller Falschwert `1.23456` statt NULL. | **✅ GEFIXT** — US-Format-Erkennung → NULL in `functions/Robotico.fnStringParseGermanDecimal.sql`, Grenzfälle im Header dokumentiert; DE-Format unverändert. Regressionstest in `tests/eazybusiness/StringAndCSVUtilities_Tests.sql`. | S — erledigt |
| **F4.1** | Ebene A legt Schema `CustomWorkflows` nirgends an → CREATE 2760 auf DB ohne Schema. Implizite Voraussetzung „JTL + Custom-Workflow-Modul vorhanden". | **✅ GEFIXT (Fail-Fast, kein stilles CREATE)** — neues `up/0004_customworkflows_schema_precondition.sql` prüft am Ketten-Anfang und wirft **THROW 50002** mit klarer Meldung (statt nacktem 2760); begründet, warum das Schema NICHT auto-erzeugt wird (JTL-Modul-Objekt, D10). README §4(k) um 50002 ergänzt. Regressionstest `tests/eazybusiness/CustomWorkflowsSchemaPrecondition_Tests.sql`. | S — erledigt |

**F4.5 (herabgestuft, kein Fix):** kein Falsch-Positiv-Risiko (ANSI-NULL); Restrisiko nur Falsch-Negativ bei
Freipositionen ganz ohne Kennung — niedrige Praxiswahrscheinlichkeit, **kein Fix empfohlen**, nur Doku-Pin.

> **Fix-Status (Phase 4, 2026-07-28) — ABGESCHLOSSEN & VERIFIZIERT:** Alle 5 Kategorie-A-Bugs
> **test-first behoben** (ROT auf ungefixtem Stand nachgewiesen → Fix → GRÜN) und im **T6-Nachtestlauf
> konsolidiert verifiziert: alle 5 VERIFIED-FIXED, 70/70 Regressionstests PASS**, Szenarien
> T2-32/54/55 + T4-02/10b/12 bestätigt (51007-Refusal jetzt deterministisch belegt), **Idempotenz-Re-Run
> beider Ketten sauber** (eazybusiness kompletter No-Op, `up/0004` journaled und nicht erneut gelaufen),
> Lint 0 Fehler, `db:validate:e2e` grün (`ergebnisse/T6-fix-verifikation.md`). Kategorie-B-Doku eingearbeitet
> (SP-6 README §8, SP-1..5 README §7, SP-7 `JTL-CUSTOM-WORKFLOWS.md` §4.4, P-1 `MSSQL-OPS-ARCHITECTURE.md` §6.7).
> Kategorie C (Setup-/Runbook-Pflichtschritte) → in `docs/runbooks/rollout-mssql-ops.md` eingearbeitet.

#### (B) Doku-/Spec-Präzisierungen (kein Code-Fix, nur Doku-Nachzug)

| ID | Präzisierung | Empfehlung | Aufwand |
|---|---|---|---|
| SP-1..SP-5 | grate-Semantik-Klarstellungen (Ebene-A `--transaction` all-or-nothing; exit-1-Propagation; permissions journalen; ScriptsRunErrors überlebt Rollback; falsches Cert-PW = OneTimeScriptChanged) | In `db-migrations/README.md`/Runbook als „verifiziertes Verhalten" nachziehen | S |
| **SP-6** | **Compat-Floor-Korrektur:** ordinaler `STRING_SPLIT` läuft ab Compat 130, nicht erst 160 → die „SQL-2022-Floor"-These in `README.md:420-427` ist für `STRING_SPLIT` falsch. | README §8 präzisieren (echter Floor = SQL 2016/Compat 130 für `STRING_SPLIT`) | S |
| SP-7 | Guard-Trigger-Landschaft dokumentiert (Kopf `0x5121`, Pos `0x5123`, `tLagerArtikel` ungeguardet, `tArtikel`-Direktwrite geht durch) | Als Kommentar/Doku bei den VPE-/Direct-Write-Aktionen | S |
| P-1 | `xp_instance_regwrite` unter Linux wirkungslos (nur `mssql-conf`); Windows-Prod-Registry-Pfad korrekt | Plattform-Notiz bei `permissions/260` | S |

#### (C) Setup-/Runbook-Pflichtschritte (T5-Runbook ergänzen)

| ID | Pflichtschritt | Empfehlung | Aufwand |
|---|---|---|---|
| **F-3** | Bei RoboticoOps-Rebuild wird das **master-Zertifikat + Signing-Login nicht nachgezogen** (`up/0011` journaled, `900` fasst master nicht an) → Signaturkette gebrochen. | T5-Runbook + Rollout-Runbook: bei jedem Ebene-B-Teardown master-Cert (`RoboticoOpsSigning`) + `RoboticoOpsSigningLogin` **mit** droppen, damit der Redeploy sie frisch zieht (test1-Teardown-Notiz verallgemeinern). | S (Doku) |
| Setup-2 | Nach `MaintenanceSchedulesEnabled`-Set/Unset muss **`EXEC maint.spEnsureMaintenanceJobs`** laufen, sonst konvergieren bestehende Jobs nicht (Setup-Befund 2, live belegt). | T5 §4b als Pflicht-EXEC führen (nicht nur Config-Wert setzen) | S (Doku) |
| Setup-3 | `ops.tConfig`-Pfad-Repoint (`BackupFile`/`TargetDataDir`) auf Linux-Pfade **vor dem ersten Reset** (sonst `failed`, F2.5) | Bereits im T5-Runbook Schritt 4 — als bindend markieren | — |

### 8.3 Offene Punkte — Restliste für test1-/Prod-Abnahme (nicht container-testbar)

Ehrlich ausgewiesen; diese Punkte kann der Container prinzipiell nicht abschließend klären:

1. **T2-60 (22022 bei gestopptem Agent)** — bewusst nicht provoziert (Container-Agent-Risiko). Hypothese:
   `sp_start_job` bei Agent-down wirft 22022, das Start-SP schluckt es als „already running" → Row bleibt
   still `queued`. **Auf test1 mit kontrolliertem Agent-Stopp verifizieren**; falls bestätigt → Folge-Ticket.
2. **Echter Database-Mail-Versand** (Operator-Alarm, Watchdog-51100-Mail) — im Container out of scope (nur
   Struktur/PRINT). **Auf Prod mit aktivem Mail-Profil abnehmen** (Rollout-Runbook Phase 4b — der natürliche
   backup-watchdog-Alarm ist der Abnahmepfad).
3. **CEST-Zeitbasis** der Wartungs-Schedules/Watchdogs — Container läuft UTC; absolute Wanduhr-Schedules nur
   auf dem realen Server prüfbar. Relative Grace/Staleness ist im Container belegt (T3-18/19).
4. **AD-/Windows-Auth-Pfade** (`ZDBIKES\sql-jtl-users`-Membership in ApplyJtlRoles, Kerberos-Logins) — keine
   Domäne im Container; der Skip-Pfad ist belegt (T2-33), die reale Member-Auflösung ist test1/Prod.
5. **`xp_instance_regwrite`-Wirkung** aufs Agent-Mail-Profil unter **Windows-Prod** (unter Linux wirkungslos,
   P-1) — auf Prod verifizieren.

### 8.4 Umgebungs-Ist & Empfehlung

- **Container `robotico-e2e-mssql` läuft weiter** (`localhost,14330`), Endzustand **grün** auf Phase-A-Baseline:
  beide Ketten deployt, `eazybusiness` (2.0.5.0) restauriert, `MaintenanceSchedulesEnabled='0'` + 6 Maint-Jobs
  disabled, 0 offene Reset-Requests, Agent Running, `db:validate:e2e` grün.
- **Empfehlung:** Container **stehen lassen**, bis der User die Findings gesichtet hat (erlaubt Nach-Verifikation
  einzelner Fälle / Fix-Regressionstests). Danach `npm run db:e2e:down:full` (Container + Volume + `.env.local`).
  Alle Test-Artefakte sind wegwerfbar; **keine** Änderung an einem realen Server erfolgt.
- **Repo-Status:** keine Commits; einzige neue Datei ist `db-migrations/tests/_e2e_guard.sql` (Guard-Include) plus
  die Report-/Ergebnisdateien unter `reports/migration-testplan/`. PayPal-Staging unangetastet.
