---
name: qg3-port-coverage
description: QG3 Rückwärts-/Gesamtabdeckungs-Audit — welche Legacy-Artefakte hätten in die db-migrations-Infrastruktur übernommen werden sollen und fehlen komplett (read-only, keine SQL-Verbindungen)
status: Research
---

# QG3 — Port-Abdeckung (Rückwärts / Gesamt)

> Read-only Audit, 2026-07-15. Keine Edits, keine SQL-Server-Verbindungen.
> Fragestellung: **Was hätte aus den Legacy-Bereichen in `db-migrations/`
> übernommen werden sollen und fehlt komplett bzw. ist nur schwach begründet
> ausgeschlossen?** (Der zeilengenaue Vorwärts-Abgleich pro portierter Datei
> läuft in den Schwester-Reports.)

## 1. Methodik

Inventarisiert: `Projekte/Testsystem/` (12 Dateien), `WorkflowProcedures/`
(inkl. `api/`, `history/`, `PayPal/`), `Workflows/`, `Berechtigungen/`,
`Alt/`, Root-`package.json` (npm-Skripte), sowie die im Plan/Research
genannten Quellen (`research/5-repo-inventar`, Plan §1/§3, D9–D12).
Abgeglichen gegen den `db-migrations/`-Baum, die beiden Legacy-`README.md`
Deprecation-Banner und `db-migrations/README.md` §6.

Bewertungsschlüssel je echter Lücke:
- **[Mehrwert]** — bewusst besser/anders gelöst
- **[Neutral]** — obsolet geworden, kein Nachfolger nötig
- **[Regression/Lücke]** — fehlt und würde beim Umstieg fehlen (mit Szenario)

## 2. Abdeckungs-Matrix

### 2.1 `Projekte/Testsystem/` (Reset-Pipeline → Ebene-B)

| Legacy-Artefakt | Status | Ziel / Begründung |
|---|---|---|
| `setup-test-environment.ps1` | ersetzt | Orchestrator-Funktion → `reset.spProcessNextResetRequest` + `spPub_StartTestmandantReset` (server-side, auditiert). Deprecation-Banner vorhanden. |
| `copy_test_db.sql` | portiert | `reset.spInternal_CloneDatabase` |
| `invalidate-credentials-for-testing.sql` | portiert | `reset.spInternal_InvalidateCredentials` — **inkl. Shop-Repoint + eBay-Sperre aus Commit e6d7b2b** (verifiziert: `cShopUrl`/`cShopLicense` aus `ops.tMandant`, parametrisiert) |
| `clear-customer-fields.sql` | portiert | `reset.spInternal_AnonymizeCustomerData` |
| `grant-database-access.sql` | portiert | `reset.spInternal_GrantAccess` |
| `register-mandant.sql` | portiert | `reset.spInternal_RegisterMandant` |
| `test-environment.config(.example).json` | portiert | `ops.tMandant` / `ops.Config` (spaltengeschützte Lizenz) |
| `grant-database-access-partial.sql` | ausgeschlossen (begründet) | Standalone-Helfer (granularer PROD-Read), nie Teil der Pipeline. Explizit als „deliberate non-port" in `Testsystem/README.md` dokumentiert. **[Neutral]** |
| `revoke-database-access.sql` | ausgeschlossen (begründet) | Standalone-Helfer (Dev-Deprovisioning), nie Teil der Pipeline. Ebenda dokumentiert. **[Neutral]** |
| `force-error.sql` | ausgeschlossen (**ohne** Begründung) | Test-Hilfe (`RAISERROR` sev 20), im Legacy-Array auskommentiert. Nirgends im „non-ports"-Vermerk gelistet. Obsolet. **[Neutral]** (Doku-Mikrolücke) |
| `.gitignore` | n/a | Config-Schutz jetzt über `ops`-Schema statt Dateiablage |
| `README.md` | ersetzt | Deprecation-Banner + Mapping-Tabelle |

### 2.2 `Berechtigungen/`

| Legacy-Artefakt | Status | Ziel / Begründung |
|---|---|---|
| `JTL-Rollen.sql` | portiert | `reset.spInternal_ApplyJtlRoles` + `global/up/0003_roles.sql` — **alle** Mitglieder übernommen (ZDBIKES\sql-jtl-users, kiana, sanda, jtl_datawow, powershell_read, greyhound, ekl_addin_readonly) verifiziert |
| `cleanup/*` (01/02/03) | n/a | Neue Peripherie-Hygiene (kein Legacy-zu-Portieren) |

### 2.3 `WorkflowProcedures/` — portierte Deploy-Quellen (Ebene-A)

| Legacy-Quelle | Ziel |
|---|---|
| `api/CustomFieldAPI.sql` | `Robotico.fnGetArticleCustomFieldValue` + `spEnsureArticleCustomField` + `spSetArticleCustomFieldValue` |
| `api/StringAndCSVUtilities.sql` | `Robotico.fnString*` (6) + `fnEscapedCSV*` (4) |
| `Duplikaterkennung_Bestellungen.sql` | `fnFindDuplicateOrders` + `fnHasOlderDuplicateOrder` + `spCheckDuplicateOrder` |
| `PayPal/Add Procudures and Tables.sql` | `up/0002_robotico_paypal_tables.sql` + `Robotico.spPaypal{Get,Create}AccessToken` + `spPaypalTrackingCallApi` |
| `PayPal/Workflowaktion.sql` | `CustomWorkflows.spPaypalTracking{Versand,Lieferschein}` |
| `history/spArticle*.sql` (3) | `CustomWorkflows.spArticleAppend{Price,Label}History` + `spArticleUpdateAllHistory` |
| `Workflowaktion_Gebinde_Erstellen.sql` | `CustomWorkflows.spGebindeErstellen` |
| `Workflowaktion_Zustandartikel_Lieferant_Setzen.sql` | `CustomWorkflows.spZustandartikelLieferantSetzen` |
| `*_Tests.sql` (4) + `Duplikaterkennung…_Teardown.sql` | `db-migrations/tests/eazybusiness/*.sql` |

### 2.4 `WorkflowProcedures/` — NICHT portiert

| Legacy-Artefakt | Status | Bewertung |
|---|---|---|
| `Diagnose_Workflow.sql` | ausgeschlossen (begründet) | Echtes Ad-hoc-Diagnose-Skript (SELECT auf `vCustomActionCheck`). **[Neutral]** |
| `PayPal/Test/*` (3) | ausgeschlossen (begründet) | Manuelle API-Testskripte. **[Neutral]** |
| `PayPal/Enable OLE Procedures.sql` | ausgeschlossen (teilbegründet) | Server-`sp_configure 'Ole Automation Procedures'`. Als **Runtime-Vorbedingung** im Kopf von `Robotico.spPaypalTrackingCallApi` dokumentiert, aber kein automatisierter Migrationsschritt aktiviert sie. Vertretbar (security-sensitives Server-Setting gehört nicht in App-Migration), aber nur als Code-Kommentar, nicht im Rollout-Runbook als Vorbedingung. **[Neutral]** (siehe §3.3) |
| `_CheckAction` / `_SetActionDisplayName` (Aufrufe) | ausgeschlossen (gut begründet) | Vendor-Objekte des JTL-„Custom Workflow Actions"-Moduls, nicht unser Eigentum. Portierte Sprocs rufen sie **guarded** auf. Dokumentiert in `db-migrations/README.md` §6. **[Neutral]** — der Plan-§1-Entwurf sah `_CheckAction.sql`/`_SetActionDisplayName.sql` noch als NEW-Dateien vor; diese Absicht wurde in der Umsetzung bewusst verworfen. |
| **`Workflowaktion Auftrag Preise auf Null*.Sql` (4)** | ausgeschlossen (**schwach/falsch begründet**) | Registriert `CustomWorkflows.spAuftragPreiseAufNull` (DisplayName „Auftrag Preise auf Null setzen"). **[Regression/Lücke]** — siehe §3.1 |
| **`Workflowaktion Artikel Seriennummern Standardlager auf WMS*.Sql` (4)** | ausgeschlossen (**schwach begründet**) | Registriert `CustomWorkflows.spSeriennummerStandardZuWMS` (DisplayName „Seriennummer Standard zu WMS kopieren"). **[Regression/Lücke]** — siehe §3.2 |

### 2.5 `Workflows/`, `Alt/`, npm, Agent-Job

| Bereich | Status | Begründung |
|---|---|---|
| `Workflows/*.{sql,liquid}` (7) | n/a | Keine Deployment-Artefakte — SELECT-only-Bedingungen / DotLiquid, die per Copy-Paste in die WaWi-UI gehen (Research §3). Kein SQLCMD-Deployment, daher kein Portierungsziel. |
| `Alt/*` (6) | n/a | Nur alte fachliche Ad-hoc-Queries, keine Testsystem-/Infrastruktur-Abstammung (Research §6). |
| EKL-Objekte (`spCMArtikel*`, `RoboticoEKL.*`, „EKL"-Workflows) | ausgeschlossen (begründet) | Fremd-Eigentum excel_ekl-Repo (D10). Ebene-A behandelt `CustomWorkflows` strikt additiv. |
| npm `Deploy Test Environment:tm2/tm3` | teil-ersetzt | Re-Reset-Funktion → `EXEC RoboticoOps.reset.StartTestmandantReset` (kein npm/`mandant.ps1`-Wrapper). Siehe §3.4 |
| SQL-Agent-Job | n/a (Neubau) | Kein Agent-Job im Legacy (`grep` leer) — `200_ensure_agent_job` ist reiner Neubau, keine Portierung. |
| Windows-Task / schtasks | n/a | Keine im Legacy vorhanden. |

## 3. Lückenliste mit Bewertung

### 3.1 [Regression/Lücke] `CustomWorkflows.spAuftragPreiseAufNull` fehlt in der Migrations-Kette

`WorkflowProcedures/Workflowaktion Auftrag Preise auf Null.Sql` legt
`CustomWorkflows.spAuftragPreiseAufNull @kAuftrag INT` an und **registriert sie
als benannte Custom-Action** (`_CheckAction @actionName='auftragPreiseNull'`,
`_SetActionDisplayName … @displayName="Auftrag Preise auf Null setzen"`). Die
Aktion ist **strukturell identisch** zu den portierten `spGebindeErstellen` /
`spZustandartikelLieferantSetzen` (PK-first `int`-Param, Registrierung am
Dateiende). Sie wird in der Projekt-`CLAUDE.md` sogar als lebendes Beispiel
genannt („setting order prices to zero for internal orders").

`WorkflowProcedures/README.md` listet sie unter „Not migrated (intentionally)"
mit der Begründung **„Ad-hoc / experimental scripts"** — diese Einordnung ist
für eine registrierte, mit DisplayName versehene Action **sachlich fragwürdig**.

**Szenario (welcher Handgriff verliert den Nachfolger):** Nach einem
JTL-Wawi-Update, das den `CustomWorkflows`-Layer überschreibt, oder beim
Aufbau einer frischen Instanz stellt die grate-Kette alle unsere
`CustomWorkflows.sp*` wieder her — **außer dieser beiden**. Ist die Action in
`dbo.tWorkflowAktion` referenziert, verwaist die Referenz (genau das
Failure-Muster, das der Duplikat-Teardown dokumentiert). Der alte Prozess
hatte die Datei; der neue hat keinen Wiederherstellungspfad.

**Empfehlung:** Entweder portieren (analog `spGebindeErstellen`, inkl.
guarded Registrierung) **oder** — falls die Action nachweislich tot ist —
die Begründung im README von „ad-hoc/experimental" auf eine belastbare
Aussage ändern („außer Betrieb, nicht mehr in `tWorkflowAktion` referenziert,
Stand JJJJ-MM-TT"). Der Live-Status ist read-only nicht verifizierbar und
muss vom Team am Server geklärt werden.

### 3.2 [Regression/Lücke] `CustomWorkflows.spSeriennummerStandardZuWMS` fehlt in der Migrations-Kette

Identische Lage wie §3.1: `WorkflowProcedures/Workflowaktion Artikel
Seriennummern Standardlager auf WMS.Sql` legt
`CustomWorkflows.spSeriennummerStandardZuWMS @kArtikel INT` an und registriert
sie (`_SetActionDisplayName … "Seriennummer Standard zu WMS kopieren"`).
Ebenfalls als „ad-hoc/experimental" ausgeschlossen, obwohl registrierte
Action. Gleiches Verwaisungs-Szenario, gleiche Empfehlung (portieren **oder**
Begründung mit Live-Status-Nachweis härten).

> Hinweis: Beide (§3.1/§3.2) haben je 3 Test-Varianten (`*-Test.Sql`,
> `*Test2/3`). Die Tests müssen nur mitwandern, falls die Haupt-Action portiert
> wird.

### 3.3 [Neutral] OLE-Automation-Vorbedingung nur als Code-Kommentar

`PayPal/Enable OLE Procedures.sql` aktivierte serverseitig `Ole Automation
Procedures`. Die portierten `Robotico.spPaypal{TrackingCallApi,…}` nutzen
`sp_OACreate`/`sp_OAMethod` und dokumentieren die Abhängigkeit im
Header-Kommentar, aber kein Rollout-Runbook führt sie als explizite
Server-Vorbedingung. Kein funktionaler Verlust (bewusst nicht in App-Migration),
aber die Vorbedingung sollte im Rollout-Runbook als Checklisten-Punkt stehen,
sonst schlägt PayPal-Tracking auf einem frisch aufgesetzten Server stumm fehl.

### 3.4 [Neutral] Kein npm/`mandant.ps1`-Wrapper für Re-Reset bestehender Mandanten

Die Legacy-npm-Skripte `Deploy Test Environment:tm2/tm3` lösten einen
**vollständigen Reset eines bestehenden Mandanten** aus. `mandant.ps1` bietet
`-Create` (registriert NEUEN Mandant + kickt dessen ersten Reset) und `-List`
— **aber keinen** Re-Reset-Schalter für einen bestehenden Mandanten. Diese
Funktion ist in `EXEC RoboticoOps.reset.StartTestmandantReset @MandantKey`
gewandert (im Testsystem-README dokumentiert). Funktional abgedeckt, aber:
(a) kein npm-Convenience-Wrapper, (b) die beiden Legacy-npm-Einträge zeigen
weiterhin ungekennzeichnet auf das deprecated `setup-test-environment.ps1`.
**Empfehlung:** npm-Skripte entweder auf einen dünnen Reset-Wrapper umbiegen
oder mit `echo`-Deprecation-Hinweis versehen, damit `npm run` nicht in den
Alt-Pfad führt.

### 3.5 [Neutral] `force-error.sql` nirgends im „non-ports"-Vermerk

Reine Test-Hilfe, im Legacy auskommentiert — obsolet. Nur der Vollständigkeit
halber: nicht in der `Testsystem/README.md`-Auflistung der bewussten
Nicht-Ports genannt. Kein Handlungsbedarf außer optionaler Erwähnung.

## 4. Abdeckungs-Quote & Empfehlung

**Pipeline-/Deploy-Kern (das, was übernommen werden MUSSTE): vollständig
abgedeckt.** Alle 6 Reset-Pipeline-Schritte, JTL-Rollen (inkl. aller
Mitglieder), Config→`ops`, der Shop-Repoint/eBay-Sperre aus e6d7b2b und alle
9 WorkflowProcedures-Deploy-Quellen + Tests sind portiert. Die bewussten
Ausschlüsse (grant-partial, revoke, Diagnose, PayPal/Test, Vendor-Helfer,
Workflows/, Alt/, EKL) sind sauber begründet.

**Zwei echte [Regression/Lücke]-Befunde:** die registrierten Custom-Actions
`spAuftragPreiseAufNull` und `spSeriennummerStandardZuWMS` sind als
„ad-hoc/experimental" ausgeschlossen, obwohl es benannte, strukturell zu den
portierten Actions identische Objekte sind. Wenn sie in Produktion aktiv
sind, reproduziert die neue Kette sie nicht — Verwaisungsrisiko nach
JTL-Update / Frisch-Aufbau.

**Empfehlung gesamt:**
1. Live-Status der beiden Actions am Server klären (read-only hier nicht
   möglich). Aktiv → portieren (analog `spGebindeErstellen`); tot → README-
   Begründung von „ad-hoc/experimental" auf datierten Außer-Betrieb-Nachweis
   ändern.
2. OLE-Automation als Vorbedingung ins Rollout-Runbook aufnehmen (§3.3).
3. Legacy-npm-Skripte kennzeichnen/umbiegen (§3.4).

Von diesen ist nur (1) potenziell umstiegsrelevant; (2)/(3)/§3.5 sind
Doku-/Ergonomie-Feinschliff.
