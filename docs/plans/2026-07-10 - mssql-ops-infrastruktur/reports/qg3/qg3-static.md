# QG3 — Statik / Betriebs-Robustheit / Konsistenz (Finder-Report)

**Datum:** 2026-07-15
**Scope:** `db-migrations/` komplett (inkl. `tests/`, `tests/docker/`), npm-Oberfläche (`package.json`), lebende Docs (`db-migrations/README.md`, `docs/SQL/*`, `docs/runbooks/*`), inkl. der drei UNCOMMITTETEN Änderungen (RECOVERY FULL in `global/up/0001`, neue `docs/SQL/MSSQL-OPS-DATA-MODEL.md`, CLAUDE.md-Sektion).
**Methode:** Reine Datei-Analyse, keine SQL-Server-Verbindung, keine Fixes.
**Vorwissen (nicht wiederholt):** `reports/qg2/consolidated-findings.md`, `reports/clone-guard-audit.md`.

**Zählung: 1 Critical · 5 Important · 13 Minor** + 5 Lint-Regel-Vorschläge.

---

## Critical

### C1 — Uncommittete RECOVERY-FULL-Änderung editiert ein bereits appliziertes One-Time-Skript → nächster TEST-Deploy bricht mit Hash-Mismatch

- **Datei:** `db-migrations/global/up/0001_roboticoops_settings.sql:38-39` (Working-Tree-Diff: SIMPLE→FULL)
- **Szenario:** `0001` ist auf test1 bereits appliziert und per Hash journaliert (`reports/test1-rollout-report.md`: b.3-Deploy grün; nach der Rename-Wave Voll-Teardown + Redeploy „alle 27 Skripte, exit 0"). grate trackt `up/`-Skripte per Content-Hash — der nächste `deploy.ps1 -Scope global -Environment TEST` schlägt mit One-Time-Script-Changed fehl. Das verletzt exakt die eigene Konvention (README §2 CAUTION: *„up/ scripts are immutable after they have been applied anywhere … add a NEW up/ script"*). Selbst mit dem Notfall-Hebel `--warnandignoreononetimescriptchanges` würde das Skript **nicht** erneut ausgeführt — test1 bliebe still auf SIMPLE, während die Datei FULL behauptet.
- **Fix-Vorschlag:** `0001` auf den committeten Stand (SIMPLE) zurücksetzen und die Umstellung als **neues** idempotentes `up/0022_recovery_full.sql` (o. ä.) einführen (`IF recovery_model <> 1 ALTER DATABASE CURRENT SET RECOVERY FULL;` + Header mit Log-Backup-Voraussetzung). Der 0001-Header-PRINT bleibt dann historisch korrekt. Zusätzlich Doku nachziehen (siehe I1).

---

## Important

### I1 — RECOVERY-FULL-Umstellung ohne Doku-/Betriebs-Nachzug: zwei Docs behaupten weiter SIMPLE, kein Log-Backup-Runbook-Schritt

- **Dateien:** `docs/SQL/MSSQL-OPS-ARCHITECTURE.md:100` („recovery SIMPLE"), `docs/SQL/NAMING-CONVENTIONS.md:174` („recovery SIMPLE"), `docs/runbooks/rollout-mssql-ops.md` (Phase 2/4: kein Wort zu Log-Backups)
- **Szenario:** Der 0001-Header warnt selbst: FULL „requires the instance backup plan to include RoboticoOps log backups, or the log will grow unbounded". Genau dieses Betriebs-Muster (volllaufendes Log) ist auf test1 bereits als Hygiene-Befund dokumentiert (`docs/runbooks/hygiene-findings.md:60`). Ohne Runbook-Schritt „Log-Backup-Plan um RoboticoOps erweitern" produziert die Umstellung mittelfristig einen Incident; ohne Doc-Update widersprechen sich Code und die zwei lebenden Referenz-Dokumente.
- **Fix-Vorschlag:** Beide Doc-Stellen auf FULL korrigieren, Rollout-Runbook Phase 2 + 4 um den Log-Backup-Schritt (oder eine bewusste Verify-Zeile) ergänzen — im selben Commit wie C1. Alternativ die FULL-Entscheidung nochmal prüfen: für reine Ops-Metadaten (Queue + Audit-Log) ist SIMPLE betrieblich robuster.

### I2 — MSSQL-OPS-DATA-MODEL.md (neu) erfindet einen `cancelled`-Status, den die CHECK-Constraint verbietet

- **Datei:** `docs/SQL/MSSQL-OPS-DATA-MODEL.md:63`; Gegenstellen `db-migrations/global/up/0002_ops_schema_tables.sql:83-85` (CHECK: nur `queued/running/succeeded/failed`), `reset.spPub_CancelResetRequest.sql:61,96` (setzt `failed`, nie `cancelled`)
- **Szenario:** Ein Leser des Datenmodells baut ein Monitoring/Query auf `cStatus = 'cancelled'` — das kann nie matchen; ein manueller UPDATE auf `cancelled` würde an der CHECK-Constraint scheitern. Das Dokument ist per CLAUDE.md-Kontrakt die kanonische Spalten-Referenz, der Fehler wiegt daher schwerer als normale Prosa.
- **Fix-Vorschlag:** Zeile korrigieren: Zustandsmaschine `queued → running → succeeded | failed`; Cancel/Force-Reclaim landet als `failed` mit sprechender `cErrorMessage` („cancelled by …" / „force-reclaimed by …").

### I3 — MSSQL-OPS-DATA-MODEL.md behauptet Spalten-DENY auf `cShopUrl` — existiert nicht

- **Datei:** `docs/SQL/MSSQL-OPS-DATA-MODEL.md:30` („Secret-adjacent: column-DENY for non-admins"); Gegenstelle `db-migrations/global/up/0003_roles.sql:38` (DENY nur auf `cShopLicense`)
- **Szenario:** Das Dokument beschreibt eine Schutzschicht, die es nicht gibt. Praktisch ist die Lücke klein (Executor-Rolle hat ohnehin kein SELECT auf `ops.tMandant`; `spPub_ListMandants` gibt die Spalte nicht zurück), aber ein späterer „grant broader SELECT"-Fall — genau das Szenario, für das der `cShopLicense`-DENY als Defense-in-Depth existiert (0003-Kommentar) — würde `cShopUrl` exponieren, obwohl das Datenmodell das Gegenteil verspricht.
- **Fix-Vorschlag:** Entweder Doc korrigieren („kein DENY, nur nicht selektiert") oder — konsistenter — den DENY in `0003_roles.sql` auf `cShopUrl` erweitern und die Doc-Aussage stehen lassen. Entscheidung dokumentieren.

### I4 — Rollout-Runbook beschreibt einen Cert-Passwort-Prompt, den deploy.ps1 nicht mehr hat

- **Datei:** `docs/runbooks/rollout-mssql-ops.md:65-66` („You will be prompted for the certificate password ({{CertPassword}} → `Read-Host -AsSecureString` or `GRATE_CERT_PASSWORD`)"), analog `:91` („Enter the certificate password when prompted"); Gegenstelle `db-migrations/deploy.ps1:296-354` (3-Tier: Env-Var → persistenter Store → Auto-Generate mit Abbruch-Guards; **kein** Read-Host)
- **Szenario:** Der Operator des ersten PROD-Rollouts (Phase 4 — genau der Fall, für den das Runbook existiert) wartet auf einen Prompt, der nie kommt. Stattdessen greift Tier 3: auf einem frischen PROD wird ein Passwort **automatisch** generiert und einmalig angezeigt — oder der Deploy bricht ab, wenn die sqlcmd-Probe den Server nicht erreicht. Beides weicht vom dokumentierten Ablauf ab; die Passwort-Sicherung („in den Password-Manager") passiert dann ungeplant mitten im PROD-Deploy.
- **Fix-Vorschlag:** Phase 2 + 4 auf das 3-Tier-Modell umformulieren (Kurzfassung + Verweis auf README §7, der bereits korrekt ist); für Phase 4 explizit: vorab `GRATE_CERT_PASSWORD` setzen oder den Auto-Generate-Fall bewusst einplanen.

### I5 — Abgebrochener RESTORE hinterlässt Klon im RESTORING-State; der nächste Lauf scheitert dann an `SET SINGLE_USER` mit irreführender Meldung

- **Datei:** `db-migrations/global/sprocs/reset.spInternal_CloneDatabase.sql:69-73`; flankierend `reset.spProcessNextResetRequest.sql:156-164` (Best-effort MULTI_USER schluckt den Fehler)
- **Szenario (Betrieb, Klon-Leiche):» Bricht der RESTORE mitten im Lauf ab (Plattenplatz voll, Agent-Neustart, Kill), bleibt `eazybusiness_tmN` im State `RESTORING`. Der CATCH-MULTI_USER des Orchestrators schlägt auf einer RESTORING-DB ebenfalls fehl (leise geschluckt — korrekt). Beim **nächsten** Reset ist `DB_ID(@TargetDb)` nicht NULL → `ALTER DATABASE … SET SINGLE_USER` wirft einen State-Fehler, der Request failed mit einer Meldung, die auf SINGLE_USER zeigt statt auf die eigentliche Ursache. Jeder Folgelauf scheitert identisch, bis jemand manuell `DROP DATABASE` / `RESTORE … WITH RECOVERY` ausführt. Weder Runbook-„Failure modes" (deckt nur „Clone left behind … MULTI_USER ensured" ab) noch cStepLog führen den Leser dorthin. (.bak-Leiche ist dagegen unkritisch: fester Pfad, `WITH INIT` überschreibt beim nächsten Lauf.)
- **Fix-Vorschlag:** In `spInternal_CloneDatabase` vor dem SINGLE_USER den DB-State prüfen: `IF DB_ID(@TargetDb) IS NOT NULL AND DATABASEPROPERTYEX(@TargetDb,'Status') = 'ONLINE'` → SINGLE_USER; sonst überspringen (RESTORE … REPLACE funktioniert auch gegen eine RESTORING-DB, dort existieren keine Verbindungen). Zusätzlich einen Failure-Mode-Absatz „Klon hängt in RESTORING" im Reset-Validierungs-Runbook.

---

## Minor

### M1 — THROW-Nummern-Kollision 50001 (0001 vs. spEnsureAgentJob); Nummern-Registry im Audit-Report dadurch falsch

- **Dateien:** `db-migrations/global/up/0001_roboticoops_settings.sql:34` (50001 Collation-Assert) vs. `db-migrations/global/runAfterOtherAnyTimeScripts/reset.spEnsureAgentJob.sql:42` (50001 Running-Guard); `reports/clone-guard-audit.md` §THROW-Nummern behauptet „keine Kollision".
- **Begründung:** Beides sind Deploy-Zeit-Fehler; wer nach „50001" greppt, landet in zwei völlig verschiedenen Kontexten. 0001 ist appliziert (immutable) — daher NICHT dort renummerieren.
- **Fix:** `spEnsureAgentJob` (anytime, editierbar) auf eine freie Nummer heben (z. B. 50010) und eine kleine Nummern-Registry (Kommentarblock oder Lint, siehe L1) etablieren.

### M2 — Helper `spInternal_LogStep` passiert Whitelist + CHECK-Constraint der Step-Registry

- **Dateien:** `db-migrations/global/up/0021_reset_step_registry.sql:47` (CHECK `LIKE 'spInternal[_]%'`), `reset.spProcessNextResetRequest.sql:113-116` (Whitelist prüft nur Schema + Präfix)
- **Szenario:** Ein Admin kann `spInternal_LogStep` als Pipeline-Step registrieren; beide Guards akzeptieren es. Zur Laufzeit failt der Lauf mit „@TargetDb is not a parameter" — kein Sicherheitsproblem, aber eine vermeidbare Footgun: Helper und Steps teilen denselben Namensraum, den die Guards nicht unterscheiden können.
- **Fix:** Explizite Ausnahme in Whitelist + CHECK (`AND cProcName <> N'spInternal_LogStep'`), oder Helper-Namenskonvention trennen (z. B. `spHelper_`) — Letzteres als bewusste Konventionsentscheidung dokumentieren.

### M3 — `spPub_CancelResetRequest`: running-Zweig ohne den @@ROWCOUNT-Race-Guard des queued-Zweigs

- **Datei:** `db-migrations/global/sprocs/reset.spPub_CancelResetRequest.sql:95-103` (vgl. Guard im queued-Zweig `:65-74`)
- **Szenario:** Wechselt die Row zwischen Read und UPDATE von `running` auf `succeeded/failed` (Job endet genau jetzt), trifft der UPDATE 0 Zeilen — die SP meldet trotzdem „force-reclaimed … cStatus=failed". Der Aufrufer glaubt an einen Reclaim, der nie stattfand.
- **Fix:** Copy-Paste-Parität herstellen: `@@ROWCOUNT` prüfen, bei 0 Zeilen den echten Status zurücklesen und als „could not reclaim — request just finished" melden.

### M4 — `LIKE '%_deactivated'`: `_` ist unescaped LIKE-Wildcard (Idempotenz-Checks in InvalidateCredentials)

- **Datei:** `db-migrations/global/sprocs/reset.spInternal_InvalidateCredentials.sql:44,46,53,55,63,79,90,109,120-122,131,134,141,150` (Muster durchgängig)
- **Begründung:** `NOT LIKE '%_deactivated'` matcht jedes Zeichen vor „deactivated" — ein Bestandswert `…Xdeactivated` gälte fälschlich als schon deaktiviert und würde übersprungen. Praktisch unwahrscheinlich, aber das Muster ist 15-fach kopiert und suggeriert eine Exaktheit, die es nicht hat.
- **Fix:** `'%[_]deactivated'` (wie im Clone-Guard bereits praktiziert) — eine mechanische Ersetzung.

### M5 — Doppel-Behandlung von `dbo.tEMailEinstellung` in Step 30 und Step 50/P9 mit widersprüchlichen Endzuständen

- **Dateien:** `reset.spInternal_InvalidateCredentials.sql:42-48` (hängt `_deactivated` an, leert Passwörter) vs. `reset.spInternal_AnonymizeCustomerData.sql:463-471` (P9: überschreibt dieselben Spalten mit `User_SMTP_<NEWID>` / `smtp_<NEWID>.test.local`)
- **Begründung:** Der Endzustand hängt von der Registry-Reihenfolge ab (heute 30 vor 50 → NEWID gewinnt, die `_deactivated`-Arbeit von Step 30 ist tot). Deaktiviert ein Admin einen der beiden Steps, ändert sich unbemerkt die Semantik. Copy-Paste-Erbe der zwei Legacy-Quellskripte.
- **Fix:** Zuständigkeit einem Step zuschlagen (SMTP-Kredentiale gehören inhaltlich zu InvalidateCredentials; P9 dann auf die restlichen Auth-Tabellen reduzieren) und die Deviation im jeweils anderen Header dokumentieren — wie beim Banking-Block bereits vorbildlich gelöst (`InvalidateCredentials`-Header, D4-Absatz).

### M6 — README §7 npm-Tabelle: `db:validate*`-Trio fehlt

- **Dateien:** `db-migrations/README.md:254-266` (Tabelle) vs. `package.json` (`db:validate`, `db:validate:test`, `db:validate:e2e`)
- **Begründung:** Die Rollout-Gate-Skripte (validate-rollout.ps1) sind die wichtigste Verifikations-Oberfläche und fehlen ausgerechnet in der als vollständig deklarierten Tabelle („exposes the whole infrastructure surface").
- **Fix:** Drei Zeilen ergänzen.

### M7 — „Rules (a)–(g)"-Restbestände + „grate on PATH"-Aussage veraltet

- **Dateien:** `db-migrations/README.md:281` („requires grate on the PATH" — deploy.ps1 hat seit dem E2E-Umbau einen Docker-Fallback, `deploy.ps1:71-83`), `db-migrations/README.md:356` (Test-Tabelle: „rules (a)–(g)"), `docs/SQL/MSSQL-OPS-ARCHITECTURE.md:192` (Lint-Zeile „(a)–(g)"), `db-migrations/tests/lint-migrations.ps1:8` (.DESCRIPTION „(a)-(g)")
- **Begründung:** Regel (h) und der Duplicate-Prefix-Check existieren seit dem test1-Incident; drei Stellen zählen noch bis (g). Die PATH-Aussage widerspricht dem dokumentierten Docker-Runner (tests/docker/README §4).
- **Fix:** Vier Ein-Zeilen-Korrekturen („(a)–(h) + up/-Nummern-Eindeutigkeit"; „grate on PATH oder Docker-Fallback").

### M8 — tests/docker/README §6 Datei-Tabelle unvollständig; E2E-Fixtures nirgends lebend dokumentiert

- **Dateien:** `db-migrations/tests/docker/README.md:149-158` (Tabelle nennt weder `copy-logins.ps1` noch `validate.ps1` noch `fixtures/`); `tests/docker/fixtures/{up/9900_e2e_probe_table.sql, functions/Robotico.fnE2EProbe.sql}` sind ausschließlich im QG2-Report referenziert.
- **Begründung:** Die Fixtures sind aus lebender Doku unauffindbar — ein späterer Aufräumer hält sie für tote Dateien (oder umgekehrt: weiß nicht, dass sie beim Anytime-/One-Time-Verhaltenstest ins Chain-Verzeichnis kopiert werden müssen).
- **Fix:** Tabelle um die drei Einträge ergänzen; 2-Zeilen-Absatz „fixtures/ — Probe-Objekte für den grate-Verhaltens-E2E (Nutzung: reports/qg2/e2e-docker-report.md §A)".

### M9 — sqlcmd-Resolver dreifach dupliziert mit abweichender Präferenz-Reihenfolge

- **Dateien:** `db-migrations/lib/targets.ps1:64-77` (SSoT, ODBC zuerst — ausdrücklich wegen der 2026-07-13-Kerberos-Regression) vs. `tests/docker/setup.ps1:44-49`, `tests/docker/validate.ps1:28-30` (beide `/usr/local/bin/sqlcmd` = go-sqlcmd ZUERST) vs. `tests/docker/copy-logins.ps1:60-63` (ODBC zuerst)
- **Begründung:** Für die reinen SQL-Auth-Container-Fälle funktioniert go-sqlcmd — aber `copy-logins.ps1` liest die QUELLE per Kerberos `-E` und hat nur zufällig die richtige Reihenfolge. Der Kommentar in targets.ps1 nennt sich „SSoT for every tool here"; drei Kopien mit divergenter Ordnung sind exakt die Drift-Klasse, die die Regression verursachte.
- **Fix:** Docker-Skripte auf `. ../../lib/targets.ps1` + `Get-RoboticoSqlcmd` umstellen (oder mindestens die Reihenfolge angleichen und den SSoT-Kommentar präzisieren).

### M10 — Datenmodell-Detailfehler: Reclaim nutzt `dStarted`, nicht `dModified`; „PK-like" statt echter PK

- **Datei:** `docs/SQL/MSSQL-OPS-DATA-MODEL.md:70` („dModified … used with StaleRunningHours to reclaim") vs. `reset.spProcessNextResetRequest.sql:41-42` (`WHERE … dStarted < DATEADD(...)`); außerdem `:25,:48` („PK-like (UNIQUE, NOT NULL)" — `cMandantKey`/`cKey` sind echte PRIMARY KEYs, `0002:37-38,62-63`)
- **Fix:** Beide Formulierungen korrigieren (Doc-only).

### M11 — Cleanup-Anleitungen unvollständig: `DELETE ops.tMandant` scheitert an FK, ops-Seite fehlt in validate-rollout.ps1

- **Dateien:** `docs/runbooks/testmandant-reset-validierung.md:212` („Set … bActive = 0 (or delete it)" — ein DELETE wirft FK `FK_tResetRequest_tMandant`, solange Historie existiert; die nötige Reihenfolge Purge→Delete steht nicht da); `db-migrations/tests/validate-rollout.ps1:199-202` (Cleanup-Hinweis nennt nur Clone-DROP + `dbo.tMandant` in der Quelle, nicht die `ops.tMandant`-/`ops.tResetRequest`-Reste des Throwaway-Mandanten)
- **Szenario:** Der Operator folgt der Anleitung, der DELETE failt mit FK-Fehler bzw. der tm9-Registry-Rest bleibt liegen und erzwingt beim nächsten `-FullReset` das `-ReuseExisting`-Flag.
- **Fix:** Runbook Step 6: Reihenfolge explizit (`spPub_PurgeOldRequests @KeepPerMandant`-Weg deckt den Fall nicht — er behält immer ≥1 Row; also: bevorzugt `bActive = 0`, DELETE nur nach manuellem Request-Cleanup). validate-rollout.ps1-Ausgabe um die zwei ops-Zeilen ergänzen.

### M12 — PayPal-Debug: Header verspricht „never prints the credentials", `@ResponseText` des Token-Endpoints IST das Credential

- **Datei:** `db-migrations/eazybusiness/sprocs/Robotico.spPaypalCreateAccessToken.sql:16` (Kommentar) vs. `:80` (`PRINT '@ResponseText ' + @ResponseText` — die Response des `/oauth2/token`-Calls enthält den Access-Token)
- **Begründung:** Debug-only (Default `@debug = 0`), also kein Live-Leak — aber der Header-Claim ist falsch und verleitet dazu, `@debug = 1` sorglos in Workflows zu lassen.
- **Fix:** Entweder `access_token` im Debug-PRINT redigieren (`JSON_MODIFY`/String-Ersatz) oder den Header ehrlich machen („prints the raw token response — debug only, never enable in a persistent workflow").

### M13 — Rollout-Runbook: Deploy-Guard-Warnung nennt den Dead-Job-Ausweg nicht

- **Datei:** `docs/runbooks/rollout-mssql-ops.md:93-98` (WARNING: „wait for the reset to finish … and rerun")
- **Szenario:** Der 50001-Guard in `spEnsureAgentJob` blockiert den Global-Deploy auch, wenn die `running`-Row von einem **toten** Job stammt — „warten" hilft dann erst nach `StaleRunningHours`, und der Stale-Reclaim läuft überhaupt erst beim nächsten Job-Start. Der schnellere sanktionierte Weg (`spPub_CancelResetRequest`) steht nur im Reset-Validierungs-Runbook.
- **Fix:** Einen Halbsatz + Cross-Ref ergänzen („hängt die Row von einem toten Job: `EXEC reset.spPub_CancelResetRequest @RequestId = …` — siehe testmandant-reset-validierung §Failure modes").

---

## Lint-Abdeckung — Regel-Vorschläge (Regeln a–h decken NICHT ab)

Referenz: `db-migrations/tests/lint-migrations.ps1`. Sortiert nach Nutzen/Aufwand.

### L1 — (i) `up/`-Immutabilität gegen git prüfen — **hätte C1 gefangen**

Working-Tree-/Index-Änderung an einem `up/`-Skript, das im HEAD (oder auf origin/master) bereits existiert → ERROR „up/ scripts are immutable once applied; add a new NNNN script". Implementierung: `git diff HEAD --name-only` (+ optional `git diff origin/master...`) gegen `*/up/*.sql` schneiden; Guard falls git fehlt.
**Aufwand: ~15 Zeilen PS, niedrig.** Falsch-Positive nur bei legitimen Edits VOR erstem Apply — dafür ein `-AllowUpEdits`-Schalter oder Hinweis-Text genügt.

### L2 — (h erweitern) Datums-/Sprachklasse über das exakte `'YYYY-MM-DD'`-Literal hinaus

Die (h)-Regex `'(\d{4})-(\d{2})-(\d{2})'` verlangt das schließende Quote direkt nach dem Tag — `'2026-01-01 12:00'` (datetime-Literal, gleiche DATEFORMAT-Falle) rutscht durch. Ebenso ungeprüft: `SET LANGUAGE`, `SET DATEFORMAT`, `FORMAT(...)`-Kultur-Abhängigkeit, `CONVERT(datetime, '<string>')` ohne Style-Argument.
**Aufwand:** Regex-Erweiterung auf `'(\d{4})-(\d{2})-(\d{2})[^']*'` = 1 Zeile (trivial); `SET LANGUAGE/DATEFORMAT`-Verbot + style-loses CONVERT als Warning je ~5 Zeilen. **Niedrig.**

### L3 — (j) Guard-Pflicht + Uniform-Contract für neue `spInternal_*`-Steps

Jede Datei `global/sprocs/reset.spInternal_*.sql` (Ausnahmeliste: `spInternal_LogStep`) MUSS enthalten: (1) die Signatur `@TargetDb sysname, @RequestId int, @MandantKey sysname`, (2) das Guard-Muster `NOT LIKE N'eazybusiness[_]%'` mit `THROW 51###` **vor** dem ersten EXEC/UPDATE/DELETE. Das README-§9-Rezept verlangt beides, nichts erzwingt es — ein neuer Step ohne Guard wäre heute lint-grün und liefe mit Job-Sysadmin-Rechten. Direkter Schutz der D6-Invariante.
**Aufwand: ~30 Zeilen PS (Datei-Filter + zwei Regex + Positionsvergleich), niedrig-mittel.**

### L4 — (k) THROW-Nummern-Eindeutigkeit je Chain

Alle `THROW 5####`-Literale je Chain einsammeln, Duplikate = ERROR (Ausnahme: mehrfaches Vorkommen derselben Nummer in EINER Datei zulassen). Hätte M1 (50001-Kollision) beim Einchecken gefangen und ersetzt die manuell gepflegte (bereits falsche) Nummern-Registry im Audit-Report.
**Aufwand: ~15 Zeilen PS, niedrig.**

### L5 — (l) validate_structure-Registrierungspflicht

Für jede Datei unter `global/sprocs/` prüfen, dass `tests/global/validate_structure.sql` den Objektnamen in der required-Liste führt (README §9 Schritt 3 — heute reine Disziplin). Simple Text-Suche nach `N'reset.<Name>'` genügt.
**Aufwand: ~15 Zeilen PS, niedrig.** (Kein Pendant für die 0021-Seed-Zeile nötig — die deckt `validate_rollout.sql` zur Laufzeit ab.)

---

## Positiv (bewusst festgehalten, keine Aktion)

- **Naming-Wave sauber:** Grep über alle lebenden Dateien (`db-migrations/`, `docs/SQL/`, `docs/runbooks/`, `CLAUDE.md`) findet **kein** einziges Alt-Token (`ops.Mandant`, `reset.internal_*`, `reset.StartTestmandantReset`, `internal_LogStep`, …). Die Hungarian-Umbenennung ist in Code UND Doku vollständig nachgezogen.
- **Guard-/LogStep-/Fehler-Muster der 8 Steps:** durchgängig kongruent (Guard als erste Anweisung, einheitliche THROW-Texte, LogStep-Aufrufe mit Variablen-Zwischenschritt, per-Step-TRY/CATCH nur wo WARN-Semantik dokumentiert ist). Einzige echte Kopier-Drifts sind M4/M5.
- **Fehlermeldungs-Qualität überdurchschnittlich:** 900_resign (Passwort-Mismatch benennt Ursache + Fundort), deploy.ps1 Tier-3-Guards, spEnsureAgentJob-Deploy-Guard, 0001-Collation-Assert — alle führen den Leser zur Lösung. Gegenbeispiele sind nur I5 (RESTORING) und M3.
- **StepLog-Vollständigkeit:** „starting step N"-Zeile vor jedem Step + Erfolgs-/WARN-Zeilen je Step; ein Mid-Step-Abbruch ist im cStepLog attributierbar. Kein Step schreibt am LogStep-Helper vorbei.
