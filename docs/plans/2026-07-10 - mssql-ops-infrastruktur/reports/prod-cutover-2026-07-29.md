# PROD-Cutover-Protokoll — 2026-07-29

> Ausführung des Runbooks `docs/runbooks/rollout-mssql-ops.md` (Phasen 0/4a/4/4b/5/6)
> gegen `vm-sql2.zdbikes.local`. Bediener: Lukas (Gates + Deploys via Session-Terminal),
> Vor-/Nachprüfungen: Claude-Session. Deployter Stand: Commit `dbfc090`.

## Vorbedingungen (verifiziert 21:35–21:40)

- FULL-Backup eazybusiness 12,1 GB um 21:00, Log-Backups bis 21:30; System-DB-Fulls 21:00.
- SQL-Agent Running, Instanz-Collation `Latin1_General_CI_AS`, RoboticoOps nicht vorhanden.
- Lint 0 Fehler; nativer grate-Runner (`runner=native` in beiden Deploys bestätigt).
- Außerhalb des 00:30–03:00-Fensters (D26).
- JTL-Worker laut Bediener beendet; aktive `JTL`-Sessions als unkritisch eingestuft (User-Go).

## Phase 4a — Legacy-Ola-Cleanup (beide Instanzen)

- **Prod:** 11 Legacy-Ola-Jobs gelöscht (Inventur deckte sich exakt mit dem Runbook;
  `syspolicy_purge_history` belassen). Nach dem Ebene-B-Deploy: `dbo.CommandLog`
  (9.218 Zeilen, 2024-06-24…2025-11-27) → `RoboticoOps.dbo.CommandLog_legacy_eazybusiness`
  archiviert (D39), danach `CommandLog`/`DatabaseBackup`/`DatabaseIntegrityCheck` aus
  `eazybusiness.dbo` gedroppt. 0 Ola-Objekte übrig.
- **test1:** identisches Archiv (9.218 Zeilen) in test1-RoboticoOps, 3 dbo-Objekte gedroppt.
- Reihenfolge-Anpassung ggü. Runbook-Wortlaut: Job-Löschung vor dem Deploy (kollisionsrelevant),
  CommandLog-Archiv danach — das Archivziel RoboticoOps entsteht erst durch den Deploy.

## Phase 4 — Deploys (User-bestätigt via Y/N-Gate)

- **Ebene B** (`-Scope global -Environment PROD`): RoboticoOps angelegt, 9 up + 20 sprocs +
  2 runAfter + 6 permissions, Version `dbfc090`. Cert-Passwort Tier-3 auto-generiert,
  persistiert (`~/.robotico-ops/grate-cert.env`, `GRATE_CERT_PASSWORD_PROD`) und in
  `~/.claude-secrets.md` abgelegt. ⚠️ Wurde einmalig im Terminal-Output angezeigt.
- **Ebene A** (`-Scope eazybusiness -Environment PROD`): alle 4 DBs (eazybusiness,
  tm2, tm3, tm4) — Adoption per Normal-Deploy (bewusst keine Baseline, F1.2), up
  0001/0002/0004 journaled, 12 Funktionen + 16 Prozeduren auf Repo-Stand inkl.
  `spVpeCheckLieferantenbestellung` (CONTEXT_INFO-Pfad). PayPal-Objekte unangetastet
  (Removal geparkt auf `feature/paypal-removal`).
- **Verifikation:** `validate-rollout.ps1 -Environment PROD` komplett grün
  (Struktur, Journale, Registry, Signaturen, Agent-Job, Wartungs-Jobs, Operator,
  Consumer-Roundtrip).

## Phase 4b — Wartungs-Go-live

- 6 Maint-Jobs enabled+scheduled (Schalter `MaintenanceSchedulesEnabled` unset = enabled,
  D34-Prod-Standard); Reset-Job enabled ohne Schedule.
- 255-Grants (syssessions/sysjobs/sysjobactivity → jobstartuser) vorhanden.
- Registry `DatabaseMailProfile` = `Standard SMTP`; **SQL-Agent-Neustart 22:40:52**
  (durch Lukas via services.msc — `xp_servicecontrol` beidseitig Access-denied).
- Job-History-Limit auf 10.000/1.000 angehoben (D38, per Registry verifiziert).

## Phase 5 — Mandanten-Registry

- Seeds tm2/tm3/tm4 vorhanden; `cLoginName = dbuser_dev_dana_for_development`
  (existiert auf Prod, kein Special-Principal). `cShopLicense` bleibt vorerst
  **Sentinel** — echte Test-Shop-Keys lagen nicht in `~/.claude-secrets.md` vor;
  Wirkung: Shop-Verbindung der Klone funktionslos (sicher), Nachtrag jederzeit per
  Runbook-UPDATE möglich. `ops.tConfig`-Pfade (`E:\work…`/`E:\MSSQL\Data`) decken sich
  mit der Prod-Realität — kein Repoint nötig.

## Phase 6 — Erster Prod-Reset (tm4)

- `EXEC reset.spPub_StartTestmandantReset @MandantKey='tm4'` → Request #1,
  Agent-Job-Pfad, **succeeded nach 332 s**. Alle 8 Steps im Log; Clone 46 s;
  Anonymisierung P1–P11 komplett.
- Stichproben am Klon: Adress-Mails `mail_NNNN@test.local`, Shop repointed
  (`https://tm4.staging.local`, Sentinel-Key), GrantAccess db_owner gesetzt,
  `kMandant=5` registriert, JTL-Rollen appliziert.

## Offen nach dem Cutover

1. **RoboticoOps in CBB aufnehmen (FULL + LOG)** — bis dahin stündliche
   backup-watchdog-Mail an lukas@dattenberger.com (= gewollter Alarmpfad-Beweis;
   erste Mail binnen 1 h nach Agent-Neustart erwartet, d.h. bis ~23:40).
2. **Erste Nacht beobachten** (heute Mi→Do): checkdb 01:00, index-optimize 02:00,
   CBB-Full 03:00 — morgen früh `sysjobhistory` prüfen (Laufzeiten, Staffelung, CEST).
3. Shop-Lizenz-Keys tm2/3/4 nachtragen, sobald bekannt.
4. Restliche Post-Deployment-Checks des Runbooks: 22022/Agent-down (auf test1),
   AD-Rollen-Membership auf frischem Klon, ggf. `nLogMaxHours`-Justierung bei
   Falsch-Alarmen im 03:00-Fenster.
5. Phase 7 (PowerShell-Altpfad stilllegen) — separater, bewusster Schritt nach
   Vertrauensaufbau.
