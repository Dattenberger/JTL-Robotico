# Ergebnis — T1: Runner / Journal / Baseline-Semantik

**Ausgeführt:** 2026-07-27, Topic-Agent T1 (Opus), gegen Container `robotico-e2e-mssql` (`localhost,14330`, Env E2E, SQL 2022 Developer, Collation Latin1_General_CI_AS).
**Gesamtergebnis:** **GRÜN** — 18/18 Fälle bestanden (kein Regressionsbefund). Mehrere Spec-Präzisierungen (Findings, keine Code-Bugs). R1 + R2 empirisch abschließend geklärt.
**Sicherheit:** Alle Writes ausschließlich gegen den Container (Guard feuerte in jedem Skript `E2E-GUARD ok`). Kein PROD/TEST-Kontakt, keine Commits, PayPal-Staging unangetastet, `up/0001` per `git checkout` wiederhergestellt.

## Gesamtergebnis-Tabelle

| Fall | Status | Kern-Evidenz |
|---|---|---|
| T1-01 | PASS | ops.ScriptsRun: one_time=1 → **9** (=up-Dateien), one_time=0 → **27**; ops.Version=1 |
| T1-02a | PASS | Adoption m. behind-Journal: grate lief **nur 0003 + spVpe**, 0001/0002 übersprungen; PayPal 8→0, spVpe erstellt, exit 0 |
| T1-02b | PASS | Adoption ohne Journal: alle 3 up/ liefen, PayPal 8→0, **keine** CREATE-Fehler, Journal neu (3+23), exit 0 → `--baseline` nicht zwingend |
| T1-03 | PASS | `-Baseline`: „No sql run" (3 Ordner), Fingerprint (compare-objects) **vor==nach**, Journal repopuliert (3+23), exit 0 |
| T1-04 | PASS | Maskierung: Rückstand (fnCountLines fehlt, fnIsEmpty('')=0) überlebt Baseline **und** Normal-Re-Run; Remediation (anytime-Journal trimmen + redeploy) heilt beide |
| T1-05 | PASS | compare-objects diff zeigt genau: fnStringCountLines fehlt in `behind`, fnStringIsEffectivelyEmpty-Hash abweichend |
| T1-06 | THROW-OK | up/-Hash-Edit → grate exit 1 `OneTimeScriptChanged: 0001`; ScriptsRun unverändert (26, 0001=1 Zeile) |
| T1-07 | PASS | Lint clean exit 0; dirty exit 1 Regel-(i)-ERROR; `LINT_ALLOW_UP_EDITS=1` → Warning exit 0; Datei per `git checkout` restauriert |
| T1-08 | PASS | anytime-Hash-Änderung: Deploy2 lief **nur** fnE2EProbe (up/9900 „No sql run"), 42→63, tE2EProbe 1 Zeile, 9900-Journal 1 |
| T1-09 | PASS | Funktionaler No-Op: tResetStep=8, tMaintenanceJob=6, tMandant=3, Agent-job_id stabil, crypt_properties stabil; Sub-Check 50010 THROW-OK |
| T1-10 | PASS (R1) | up/-Fehler mittig unter `--transaction`: **Marker-Tabelle weg, 0 ScriptsRun-Zeilen** → Ganz-Lauf-Rollback; Clean-Restart exit 0 |
| T1-11 | PASS (R1) | anytime-Fehler unter `--transaction`: **up/0003-PayPal-Drop rollte zurück (PayPal 8 wieder)**, Marker weg, 0 ScriptsRun → Ganz-Lauf atomar |
| T1-12 | PASS | Ebene B ohne Tx: 0002a-Fehler lässt 0001/0002 **committed** (ops.tConfig da, ops.tResetStep NULL); Deploy #2 setzt fort, exit 0 |
| T1-13 | PASS | E2E-DryRun exit 0, resolved `localhost,14330` env=E2E runner=docker, änderte nichts. PROD-Gate: statisch verifiziert (s.u.) |
| T1-14 | PASS | Tier-1 (session env) bestätigt; Tier-3-Refuse-Guard exit 1 „Refusing to auto-generate"; CQG-4 Immutabilität erzwungen (Finding: via 0011-Hash, nicht 50901); Tier-3-Autogen-Happy-Path deferred |
| T1-15 | PASS | Ketten-Unabhängigkeit belegt (T1-18: Ebene A ohne RoboticoOps; T1-12: Ebene B greenfield ohne eazybusiness; Setup: B vor Restore); validate_rollout cross-DB grün |
| T1-16 | PASS | compare-objects: **saubere Parität** (23 Datei-Objekte == DB, leerer Diff nach Filterung); harte Negativ-Assertion: 0 PayPal-Objekte |
| T1-17 | PASS | Richtung 1: 0 PayPal-Objekte. Richtung 2: 0003 re-run gegen PayPal-freie DB → exit 0, 0 ScriptsRunErrors (DROP IF EXISTS idempotent) |
| T1-18 | PASS | Klon-Journal **byte-identisch** (leerer diff); Ebene B reist NICHT (0 ops-Schema); Ebene-A-Deploy auf Klon „No sql run" exit 0 |

**Zähler:** PASS 16 · THROW-OK 1 (T1-06) · PASS-mit-Nuance 1 (T1-14) · FAIL 0 · RUNTIME-OPEN 0 (R1/R2 geklärt) · SKIP 0.
(T1-13b PROD-Gate empirisch nicht ausgeführt — statisch verifiziert, s.u.)

---

## R1 — grate `--transaction`-Granularität (kritischster Punkt) — GEKLÄRT

**Befund: `--transaction` klammert den GESAMTEN Ebene-A-Lauf in EINE Transaktion, über alle `GO`-Batches und alle Ordner (up + functions + sprocs) hinweg. Ein Fehler an beliebiger Stelle rollt ALLES zurück — „alles-oder-nichts".**

Zwei unabhängige, harte Belege:
- **T1-10 (up/-Fehler):** injiziertes `up/0000a_marker.sql` (CREATE TABLE `Robotico.tT110Marker`) lief VOR dem mittigen `up/0002a` (`THROW 51999`). Nach dem Abbruch (grate exit 1): **Marker-Tabelle ABWESEND**, `Robotico.ScriptsRun` = **0 Zeilen**. Die Vor-Fehler-Writes wurden zurückgerollt.
- **T1-11 (anytime-Fehler):** stärkster Beleg. up/ lief komplett (0003 droppte PayPal 8→0), dann anytime `fnT111Marker`, dann `zzz_T111_fail` (`THROW 51998`). Nach Abbruch: **PayPal = 8 wieder da** (0003s Drop rückgängig!), anytime-Marker weg, 0 ScriptsRun-Zeilen. Ein anytime-Fehler rollt also erfolgreiche up/ **desselben Laufs** zurück.

Einzige Ausnahme von der Atomarität: grate schreibt die **`ScriptsRunErrors`-Fehlerzeile committed außerhalb** der zurückgerollten Transaktion (T1-06: 0→1, T1-10: 2 Zeilen). Serviceability-Feature, kein Datenverlust.
Clean-Restart nach Entfernen des Fehler-Skripts läuft idempotent von vorn (T1-10 Deploy #2 exit 0).

## R2 — Docker-Runner exit-Propagation — GEKLÄRT

**Befund: grate-interne SQL-Fehler schlagen zuverlässig als Container-Exit 1 durch; Erfolg = exit 0. Der Docker-Runner (`Invoke-Grate`) gibt `$LASTEXITCODE` des `docker run` korrekt weiter.**

Exit-1-Fälle (jeweils mit passender Fehlermeldung im Log): T1-06 (`OneTimeScriptChanged`), T1-09-Sub (`THROW 50010`), T1-10 (`THROW 51999`), T1-11 (`THROW 51998`), T1-12-d1 (`THROW 51997`), T1-14a (`OneTimeScriptChanged 0011`).
Exit-0-Fälle: T1-09 (No-Op), T1-18 (Klon-Deploy), alle Adoptions-/Baseline-Deploys. Kein „exit 0 mit verstecktem Fehler" beobachtet.

---

## Findings (Spec-Präzisierungen — keine Code-Regressionen)

1. **`permissions/`-Skripte JOURNALEN (R3 geklärt).** Entgegen der T1-01/T1-09-Erwartung („permissions erzeugen keine ScriptsRun-Zeile") schreibt grate für jedes `permissions/`-Skript eine `ScriptsRun`-Zeile mit `one_time_script=0` (Everytime-Semantik). Ebene B: one_time=0 = **27** = 22 anytime (20 sprocs + 2 runAfter) + **5 permissions**. Bei jedem erneuten Ebene-B-Deploy wächst `ops.ScriptsRun` um genau diese 5 Zeilen (T1-09: 36→41), `ops.Version` um 1/Lauf. → Erwartungswert in T1-01/T1-09 anpassen: `ops.ScriptsRun`-Count ist **nicht** stabil über Re-Runs; stabil sind die funktionalen Invarianten (tResetStep/tMaintenanceJob/tMandant/Agent-job_id/crypt_properties). Ebene A hat keine permissions/ → dort bleibt es bei 3+23.

2. **`ScriptsRunErrors` committet außerhalb der `--transaction`** (T1-06, T1-10) — s. R1. Die Fehler-Journalzeile überlebt den Rollback (gewollt, Serviceability).

3. **CQG-4 falsches Cert-Passwort wird an `up/0011` gefangen, nicht an 900/50901** (T1-14a). Der `{{CertPassword}}`-Token wird TEXTUELL in `up/0011` substituiert → dessen one-time-Hash ist passwortabhängig. Ein falsches Passwort trippt daher auf jedem journalten Re-Deploy zuerst `OneTimeScriptChanged: 0011` (grate exit 1), BEVOR die `900`-Re-Sign-THROW-50901 erreicht wird. Immutabilität ist erzwungen — der 50901-Backstop ist im journalten Re-Deploy-Pfad durch den 0011-Hash-Guard beschattet und würde nur im Erstsignatur-Pfad (frisches Cert) greifen (den `deploy.ps1` per Tier-3-Refuse-Guard ohnehin absichert, T1-14b).

## Nicht-empirisch / Abgrenzungen

- **T1-13b (PROD-Gate):** bewusst NICHT gegen PROD ausgeführt (Sicherheits-Invariante „nie `-Environment PROD`"). Statisch verifiziert aus `deploy.ps1:160-173`: das Y/N-Gate liest die Antwort und beendet bei ≠Y mit `exit 1` — VOR Cert-Auflösung (Z.297+) und VOR jeder grate-/DB-Verbindung; DryRun überspringt das Gate (`-and -not $DryRun`). Kein PROD-Kontakt möglich.
- **T1-14 Tier-3-Autogen-Happy-Path (Passwort-Neu-Generierung auf cert-absenter Instanz):** nicht ausgeführt, da ein cert-freier Frisch-Container (Voll-Wipe) nötig wäre und der persistente Store (`~/.robotico-ops/grate-cert.env`) berührt würde. Tier-1 (session env) empirisch bestätigt, Tier-3-Refuse-Guard empirisch bestätigt (T1-14b, Store temporär ohne E2E-Key → `deploy.ps1` exit 1 „Refusing to auto-generate"; Store danach wiederhergestellt). Tier-2/Tier-3-Autogen aus dem gut kommentierten `deploy.ps1`-Code abgeleitet.
- **T1-16 tolerierte Extras:** `spCMArtikelGeaendert` (EKL-Fremdproc aus Prod-Trim, Setup-Befund 1) + `tArtikelCommentary` (Legacy, R4) + 3 grate-Journal-Tabellen — herausgefiltert, danach leerer Diff.

## Endzustand der Umgebung

**GRÜN.** Container up, Agent Running. Beide Ketten voll deployt (eazybusiness Journal 3+23, PayPal=0; RoboticoOps 8 Reset-Steps, 6 Maint-Jobs disabled). `ops.tConfig`-Pfade auf `/var/opt/mssql` repointet, `MaintenanceSchedulesEnabled='0'`. `npm run db:e2e:validate` + `npm run db:validate:e2e` **beide OK** (structure + rollout + roundtrip). Leftover-Klone (`eazybusiness_tm9`/`_behind`) + Backup-Dateien entfernt; nur `eazybusiness` + `RoboticoOps` verbleiben. Store `~/.robotico-ops/grate-cert.env` mit beiden Keys (E2E/TEST) wiederhergestellt. Keine git-Änderungen aus dieser Ausführung (nur vorbestehendes PayPal-Staging).
