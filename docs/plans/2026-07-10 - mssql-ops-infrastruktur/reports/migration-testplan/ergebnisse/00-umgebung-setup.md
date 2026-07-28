# Ergebnis — Umgebungsaufbau (T5-Setup)

**Ausgeführt:** 2026-07-27, Lead-Agent (Opus), gegen Container `robotico-e2e-mssql` (`localhost,14330`).
**Ergebnis:** **GRÜN** — beide Ketten deployt, `eazybusiness` restauriert, `db:validate:e2e` OK.
Keine Commits, keine Server-Writes außerhalb des Containers, PayPal-Staging unangetastet.

## Schritte & Ergebnis

| Schritt | Aktion | Ergebnis |
|---|---|---|
| Vorbedingungen | docker 29.5.3, pwsh 7.6.2, sqlcmd ODBC, 519 GB frei, Port 14330 frei, Backup 1,8 GB (16.07.) | PASS |
| 1 | `npm run db:e2e:up` (frisches Volume) | PASS — healthy, **SELECT 1 / Agent Running / Collation Latin1_General_CI_AS** |
| 2 | SA-/Cert-Passwort aus `.env.local` in die Shell | PASS |
| 3 | `npm run db:deploy:e2e:global` (Ebene B) | PASS — grate „grated RoboticoOps", alle up/+sprocs+runAfter+permissions, exit 0 |
| 4a | `ops.tConfig`-Pfad-Repoint (`BackupFile`/`TargetDataDir` → `/var/opt/mssql/...`) | PASS |
| 4b | `MaintenanceSchedulesEnabled='0'` (MERGE) + Backup-Dir `/var/opt/mssql/backup` (chown mssql) | PASS |
| 5 | `RESTORE HEADERONLY` + `docker cp` + `RESTORE … WITH MOVE` als `eazybusiness` → `RECOVERY SIMPLE` | PASS — **SoftwareVersionMajor 16 / Compat 160 / Latin1_General_CI_AS / COPY_ONLY**; 1.164.914 Seiten in 16,7 s |
| 6 | `npm run db:deploy:e2e` (Ebene A) | PASS — 12 fn + 11 sprocs (inkl. `spVpeCheckLieferantenbestellung`), exit 0 |
| 7 | `EXEC maint.spEnsureMaintenanceJobs` (D34-Konvergenz) + `npm run db:validate:e2e` | PASS — **Rollout validation OK** (structure / rollout / roundtrip) |

## Verifizierter Nachzustand (`eazybusiness`)

- `dbo.tVersion.cVersion = 2.0.5.0` (JTL-DB vorhanden, Schema vollständig).
- Schema `CustomWorkflows` **vorhanden**; Schema `Robotico` vorhanden.
- **`Robotico.ScriptsRun` = 26 Zeilen** (3 one-time `up/` + 23 anytime = 12 fn + 11 sprocs). Erwartung T1-01 bestätigt.
- **PayPal-Drop `up/0003` wirkt: 0 `spPaypal*`/`tPaypal*`-Objekte** nach Deploy (T4-06a Vorabbeleg).
- 12 `Robotico.fn*`; 6 `RoboticoOps - Maint - *`-Jobs jetzt **disabled** (D34, Schalter `'0'`).

## Setup-Befunde (für die Topic-Ausführung relevant)

1. **T1-R4 bestätigt — Extra-Objekt aus dem Prod-Backup:** die restaurierte `eazybusiness` trägt
   einen **9.** `CustomWorkflows.sp*`-Proc: **`spCMArtikelGeaendert`** (EKL-Territorium, kam mit dem
   Prod-Trim). `compare-objects.sql`/der T1-16-Inventar-Diff schließt nur exakt `spCMArtikel`/
   `spCMArtikelNeu` aus → `spCMArtikelGeaendert` erscheint als „Fremdzeile" und muss im Soll-Diff
   toleriert/ausgefiltert werden. **Kein Bug unserer Kette**, sondern ein Filter-Nachzieh-Punkt für T1.
2. **T3/T5-Setup-Verfeinerung (load-bearing):** `MaintenanceSchedulesEnabled='0'` **nach** dem
   Ebene-B-Deploy zu setzen, **konvergiert die bereits erzeugten Jobs NICHT** — sie wurden beim Deploy
   (Schalter noch unset = ENABLED) enabled angelegt. `validate_rollout` fing das korrekt als 6 D34-
   Mismatches (FAIL). **Erst `EXEC maint.spEnsureMaintenanceJobs` konvergiert** (6 „drifted — recreating"
   → alle disabled), danach validate_rollout grün. → T5 §4b muss den expliziten `EXEC
   maint.spEnsureMaintenanceJobs` nach dem Schalter-Setzen als Pflichtschritt führen (nicht nur den
   Config-Wert). Das ist zugleich Live-Beleg für T3-06 (Effektivlogik) und T3-07 (Drift-Recreate).
3. **Guard `_e2e_guard.sql` scharf & korrekt:** feuert `E2E-GUARD ok: 3c2b38585482 / Developer Edition`
   (Container-MachineName = kurze Container-ID, Mixed-Mode, Developer) — Multi-Signal-Deny lässt den
   Container durch, würde `vm-sql2`/Integrated-Security/Nicht-Developer sofort abweisen (T5-Guard, G1).

## Endzustand (bereit für Topic-Ausführung)

Container läuft, Agent Running, beide Ketten deployt, `eazybusiness` (2.0.5.0) restauriert, Maint-Jobs
disabled (Phase-A-Isolation), `db:validate:e2e` grün. Bereit für T1 → T2/T3/T4.
