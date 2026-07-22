# Follow-up Research — 🔴 R2: SQL-Agent auf test1 blieb Running (Stopped-Baseline nicht wiederhergestellt)

**Plan:** [mssql-wartung-ola.md](../mssql-wartung-ola.md) · **Quelle:** implementation-report.md §R2 · **Modus:** read-only Research, nichts verändert · **test1:** nur lesend geprüft · **vm-sql2:** nicht angefasst.

**Empfehlung in einem Satz:** **accept + kleiner Doku-Follow-up.** Der Running-Zustand ist kein Defekt, sondern der faktisch bessere Dauerzustand für test1 — der D34-Schalter `'0'` ist das lastragende Gate. Die zwei Runbook-Stellen, die „Agent zurück in Stopped" als Soll-Teardown nennen, sind vestigial (aus der Zeit vor D34) und sollten auf „Running mit Schalter `'0'` ist die test1-Baseline" umgestellt werden. **Kein manueller Stopp nötig.**

---

## Was hinter dem 🔴-Marker steckt

R2 ist **kein Code-Fehler und kein fehlgeschlagener Fix** — es hat keinen Wave-Commit (Issue-Tabelle Zeile 11: Commit „—"). Es ist eine **Teardown-Beobachtung** aus dem E2E: der geplante „Agent zurück in Stopped"-Schritt ließ sich nicht ausführen.

- **Mechanik des Fehlschlags:** `EXEC master.dbo.xp_servicecontrol N'STOP', N'SQLServerAGENT'` scheitert mit „Zugriff verweigert" (Fehler 5). Das Kerberos-SQL-Login ist zwar sysadmin *in* SQL, besitzt aber keine **Windows-Dienststeuerungs-Rechte** — Dienst-Start/-Stopp läuft über den Windows Service Control Manager, nicht über die SQL-Engine. (Symmetrisch schlägt auch der START via `xp_servicecontrol` fehl; der Agent lief bereits **vor** der Session, vom Reset-Betrieb gestartet, und wurde nicht vom E2E-Agenten gestartet.)
- **Warum folgenlos:** Der Dauer-Schedule-Schutz hängt per Design (D34) am Instanz-Schalter `ops.tConfig('MaintenanceSchedulesEnabled') = '0'`, **nicht** am Dienststatus. Effektiver Job-Enabled-Zustand = `bEnabled = 1` UND Schalter ≠ `'0'`. Bei `'0'` feuert **kein** Wartungsjob, auch bei laufendem Agent. `validate_rollout.sql` prüft genau diese Gleichung und ist grün. `spCheckMaintenanceLiveness` ist auf test1 konstruktionsbedingt No-op (zählt nur effektiv-enablte Zeilen).

Der 🔴-Marker steht also nicht für „etwas ist kaputt", sondern für „ein geplanter Aufräumschritt konnte nicht ausgeführt werden — bitte entscheiden, ob er überhaupt noch gewollt ist".

## Forschungsfrage 1 — Ist Stopped noch der dokumentierte Soll-Zustand?

**Nein, nicht mehr lastragend — der Soll-Zustand ist über D34 auf den Schalter gewandert; „Stopped" ist nur noch eine Höflichkeit ohne Funktion.** Belege:

- **ADR-A §D-A6 wurde per D34 explizit revidiert** (`adr-…-roboticoops.md:92-94`, Decision-History `:202-208`): „Realised by an instance switch, **not by the Agent service state**. The Agent service state **cannot serve as the gate**: the test-mandant reset requires a running test1 Agent (`sp_start_job` path)." Der Reasoning-Absatz (`:208`) benennt es wörtlich: der Schalter „replaces an **unenforceable operational assertion** (Agent stays stopped) with a mechanism that survives the reset subsystem's documented need for a running Agent." FT-11 (`:202`) hatte den Widerspruch „‚no permanent schedule' relied on the stopped Agent that the reset subsystem requires running" aufgedeckt.
- **Der Plan selbst nennt Stopped nur noch als Zusatz, nicht als Gate.** §AC9 (`mssql-wartung-ola.md:46`): „kein Dauer-Schedule … erzwungen durch den Instanz-Schalter … der Agent bleibt **zusätzlich** in seiner Stopped-Baseline, **taugt aber nicht als Gate** (Reset-Arbeit braucht ihn laufend)." §3.5 (`:268`): „Danach Agent wieder Stopped — der Dauer-Schedule-Schutz hängt **aber** am Instanz-Schalter …, **nicht** am Dienststatus: der Agent darf für Reset-Arbeit jederzeit (auch über Nacht) laufen."
- **Das Rollout-Runbook verlangt den Agent laufend** und verlangt an keiner Stelle, ihn danach zu stoppen (`rollout-mssql-ops.md:78-79`: „make sure the SQL-Agent service is running on test1 … the agent job needs it"). Es ist bereits mit Running konsistent.

**Warum Running der faktisch bessere Dauerzustand ist (Reset-Pipeline braucht ihn):**

1. **Self-Service-Reset für Kollegen.** `reset.spPub_StartTestmandantReset` startet den Reset über `msdb.dbo.sp_start_job` — das setzt einen **laufenden Agent-Dienst** voraus. Bei gestopptem Agent scheitert `sp_start_job`. Ein Stopped-Baseline macht test1-Resets nur als Admin-assistierter Vorgang möglich (Admin startet Dienst → Test → Admin stoppt), statt on-demand durch Kollegen.
2. **Ein gestoppter Agent ist sogar aktiv schädlich für die Reset-Infra.** `qg-code-global.md:29-33` dokumentiert: schlägt `sp_start_job` fehl (u. a. „Agent stopped"), bleibt die `queued`-Zeile stehen; der `UX_ResetRequest_Active`-Index blockiert das erneute Absenden, und der **nächste** erfolgreiche Reset arbeitet die verwaiste Zeile ab — „thought it failed, ran later anyway". Der Zustand, den die Reset-Feature gerade eliminieren soll.
3. **Der einzige historische Grund für Stopp ist mit D34 weg.** Vor D34 hätte ein laufender test1-Agent über Nacht die volle Prod-Wartung inkl. täglich-rotem Watchdog gefeuert (Alarm-Abstumpfung, ADR-B-Anti-Goal). Genau das verhindert jetzt der Schalter `'0'`. Der Reset-Betrieb liefe ohnehin nachts mit laufendem Agent — der Schalter ist die Absicherung, nicht der Dienststopp.
4. **Prod-Parität.** Der Survey (`6-wartung-ist-analyse.md:63`) zeigt prod = „Running / Automatic". test1 dauerhaft Running (Dienst Automatic) spiegelt prod; „Stopped/Manual" war ein test1-Zufallszustand, den der Survey vorfand — keine Anforderung.

Der einzige theoretische Vorteil eines gestoppten test1-Agenten wäre „Defense-in-depth, falls jemand den Schalter versehentlich flippt". Der greift aber auf test1 ins Leere: die DBs sind Wegwerf-Klone, es gibt nichts Schützenswertes, und ein gestoppter Agent verstummt mitsamt Watchdog/Liveness (die auf test1 per `'0'` ohnehin No-op sind). Die Kosten (Reset-Self-Service kaputt, nicht per SQL ausführbar) überwiegen klar.

## Forschungsfrage 2 — Falls Stopped doch gewünscht bleibt: wer/wo?

- **Wer hat die Rechte:** Dienststeuerung auf test1 braucht **Windows-Rechte auf dem Host** (SCM), die das Kerberos-SQL-Login nicht hat. Weg: **ZDBIKES-Administrator per RDP → `services.msc` → SQL Server Agent stoppen** (oder eine PowerShell-Session mit Windows-Admin: `Stop-Service SQLSERVERAGENT`). *(Reiner Hinweis — nicht ausgeführt.)* `xp_servicecontrol` aus einer SQL-Session heraus funktioniert nur, wenn dem Dienstkonto/Login die Windows-Dienststeuerung gestattet ist, was hier nicht der Fall ist.
- **Wo dokumentieren, falls beibehalten:** Die Stelle existiert bereits, ihr fehlt nur der Rechte-Hinweis: `testmandant-reset-validierung.md:220` („Stop the SQL-Agent again if test1 should return to its Stopped/Manual baseline.") sollte ergänzt werden um „— erfordert Windows-Dienstrechte (ZDBIKES-Admin via RDP/`services.msc`); aus der SQL-Session (nur sysadmin) nicht möglich; **optional**, da der D34-Schalter `'0'` das Gate ist."

## Forschungsfrage 3 — Konsistenz-Check: widerspricht ein Dokument dem Running-Zustand?

**Kein Dokument fordert Stopped als harte Invariante oder Gate.** Es gibt keine Assertion, kein Precondition-Check und kein Runbook-Schritt, den Running verletzen würde. Was bleibt, sind **vestigiale „zurück nach Stopped"-Höflichkeiten** aus der Zeit vor D34:

| Stelle | Aussage | Bewertung |
|---|---|---|
| `docs/runbooks/rollout-mssql-ops.md:78` | „make sure the SQL-Agent service is running … the agent job needs it"; kein Stopp danach | ✅ bereits Running-konsistent |
| `docs/runbooks/testmandant-reset-validierung.md:84` | „test1's SQL-Agent is Stopped/Manual by default (survey)" | ⚠️ beschreibt Ist von damals als „Baseline" |
| `docs/runbooks/testmandant-reset-validierung.md:220` | „Stop the SQL-Agent again if test1 should return to its Stopped/Manual baseline" | ⚠️ soft („if … should"), aber rahmt Stopped als Ziel; Rechte-Hinweis fehlt |
| `mssql-wartung-ola.md:46,268` (Plan §AC9/§3.5) | „Agent bleibt zusätzlich in Stopped-Baseline … taugt aber nicht als Gate" | ⚠️ Plan sagt selbst „kein Gate"; archiv-gebunden |
| `.../2026-07-10 - …/reports/test1-rollout-plan.md:253` | „Stop the SQL Agent again if test1 should return to its Stopped/Manual baseline" | ⚠️ Report-Artefakt des Vorgänger-Plans (historisch, nicht laufend) |
| `e2e-runbook.md:205`, `e2e-report.md` | Teardown-Schritt „Agent zurück Stopped" bzw. dessen Fehlschlag | ℹ️ Run-Artefakte, historisch — nicht anfassen |

**Wichtige Abgrenzung (kein Widerspruch):** Der „**worker stopped**"-Hard-Gate in `testmandant-reset-validierung.md:26-30` betrifft den **JTL-Worker-Dienst**, nicht den SQL-Server-Agent — zwei verschiedene Dienste. Der Worker muss beim Reset gestoppt sein; das hat mit dem Agent-Dienststatus nichts zu tun und steht Running nicht entgegen.

**Fazit F3:** Keine Blockade, nur zwei laufende Runbook-Stellen (`testmandant-reset-validierung.md:84,220`) formulieren Stopped noch als Baseline. Das ist die einzige Drift.

## Empfehlung: accept (Running behalten) + kleiner Doku-Follow-up

**accept** für den Zustand selbst: der Agent bleibt Running, kein manueller Stopp. Der D34-Schalter `'0'` ist geprüft (validate_rollout grün) und ist das lastragende Gate. Ein Stopp brächte keinen funktionalen Gewinn, wäre per SQL nicht ausführbar und würde Reset-Self-Service verschlechtern.

**follow-up needed** nur als kleiner Doku-Angleich (kein Code, keine Migration), damit künftige Operatoren nicht einem nicht-ausführbaren Stopped-Teardown hinterherlaufen:

- `docs/runbooks/testmandant-reset-validierung.md` §Teardown (`:220`) und die „Stopped/Manual by default"-Notiz (`:84`): auf „**Running mit Schalter `'0'` ist die test1-Baseline**; der D34-Schalter ist das Gate; ein Dienststopp ist optional und erfordert Windows-Rechte (ZDBIKES-Admin via RDP/`services.msc`)" umstellen.
- Optional, beim Plan-Archivieren: §AC9/§3.5-Wortlaut „Agent wieder Stopped" auf „Running zulässig, Schalter ist das Gate" schärfen (Plan sagt inhaltlich bereits „kein Gate" — nur der Ton suggeriert noch Stopp). Report-Artefakte (`e2e-*`, `test1-rollout-plan.md`) bleiben als historischer Stand unangetastet.

### Konkrete Optionen für dich

1. **Empfohlen — accept + Doku angleichen.** Running als test1-Baseline dokumentieren, die zwei `testmandant-reset-validierung.md`-Stellen anpassen, R2 schließen. Ergebnis: konsistente Docs, Reset-Self-Service funktioniert, keine test1-Aktion nötig.
2. **accept ohne Doku-Änderung.** R2 als „design-mitigated, folgenlos" schließen und die vestigialen Stopp-Hinweise stehen lassen. Risiko: der nächste Operator versucht den nicht-ausführbaren Stopp erneut und rätselt über Fehler 5.
3. **Stopped tatsächlich herstellen.** Nur wenn du die Stopped-Baseline aus anderen Gründen willst: ZDBIKES-Admin stoppt den Agent per RDP/`services.msc`. Nachteil: test1-Resets sind dann bis zum nächsten manuellen Start nicht self-service, und ein Kollegen-Reset in der Zwischenzeit läuft in den `qg-code-global.md:29`-Fehlerpfad. Nicht empfohlen.

Es gibt **keinen revisit-decision-Bedarf**: der zugrundeliegende Entwurf (D34/D-A6) ist bewusst und korrekt in Richtung Schalter-als-Gate gefallen; R2 bestätigt genau diese Entscheidung, statt sie in Frage zu stellen.
