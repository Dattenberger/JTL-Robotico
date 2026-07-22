---
name: instanz-survey-test1-prod
description: Read-only-Survey der Instanzen vm-sql-test1 (SQL 2025) und vm-sql2 (SQL 2022) — Versionen, DBs, Prinzipale, Jobs, Worker-Flags (2026-07-09)
status: Research
---

# Ist-Zustand SQL-Instanzen — Survey für Migrationsdesign

> Quelle: Opus-Agent „sql-survey", Session 2026-07-09, per sqlcmd/Kerberos (`/opt/mssql-tools*/bin/sqlcmd -S <host> -E -C`), strikt read-only.
> Zugriffs-Gotcha: das go-sqlcmd unter `/usr/local/bin/sqlcmd` kann KEIN Kerberos — ODBC-sqlcmd verwenden.

Beide Instanzen erreichbar: `vm-sql-test1.zdbikes.local`, `vm-sql2.zdbikes.local` (auch `VM-SQL2`/`vm-sql2`).

## 1. Instanz-Basis

| | **vm-sql-test1** (Test) | **vm-sql2** (Prod) |
|---|---|---|
| ProductVersion | **17.0.1000.7 → SQL Server 2025** | **16.0.4225.2 → SQL Server 2022** |
| Edition | Developer | Standard |
| ProductLevel | RTM | RTM (CU/GDR-Stand) |
| Collation | Latin1_General_CI_AS | Latin1_General_CI_AS |
| @@SERVERNAME | VM-SQL-TEST1 | VM-SQL2 |
| Auth | Mixed | Mixed |

**test1 ist die NEUERE Version — zentrale Restriktion, siehe Bewertung.**

## 2. Datenbanken

**test1** (Instanzverzeichnis `MSSQL17.MSSQLSERVER`, alles SIMPLE):
| DB | Recovery | Compat | Größe ROWS/LOG | Owner |
|---|---|---|---|---|
| eazybusiness | SIMPLE | **170** | 27.240 / 1 MB | WIN-UHHQ6G7KDOG\Administrator |
| eazybusiness_e2e_r3_pre_snap | SIMPLE | 170 | 27.240 MB | dito |

**prod** (`MSSQL16.MSSQLSERVER`; produktive DBs FULL):
| DB | Recovery | Compat | Größe | Owner |
|---|---|---|---|---|
| eazybusiness | **FULL** | **160** | 27.240 / 4.301 MB | ZDBIKES\lukas |
| eazybusiness_premig | FULL | 160 | wie prod (in `E:\Backup\`!) | ZDBIKES\lukas |
| eazybusiness_tm2 | SIMPLE | 160 | 36.740 MB | ZDBIKES\lukas |
| eazybusiness_tm3 | SIMPLE | 160 | 27.240 MB | ZDBIKES\sanda |
| eazybusiness_tm4 | SIMPLE | 160 | 27.240 MB | ZDBIKES\lukas |
| ersatzteile_prod / _latest / _old_bis_2026_03_03 | FULL/SIMPLE | 150 | ~1 GB je | lukas / dana-Login |
| HbDat001 | FULL | 150 | 1.352 MB | ZDBIKES\lukas |

## 3. Server-Prinzipale & Rollen

**test1** — schlank: SQL-Logins nur `sa` + `ekl_testmssql_app` (2026-06-23). Windows: ZDBIKES\lukas, Gruppen `sql-admins`, `sql-jtl-users`, lokaler Admin, Dienstkonten. sysadmin: sa, lukas, sql-admins, lokaler Admin, Dienstkonten.

**prod** — 16 SQL-Logins (`dbuser_eazybusiness_jtl`, `_jtl_cli`, `_greyhound`, `_powershell`, `_docker1`, `_datawow`, `dbuser_eazybusiness_ekl_addin_*` [backend/readonly/testdb], `dbuser_dev_*`, `dbuser_ersatzteile_prod_scraper`, `dbuser_HbDat001_alfbanco`). Windows: lukas, aylin, kiana, sanda + Gruppen. **sysadmin: enthält SQL-Login `dbuser_dev_dana_for_jtl` (Dev-Konto mit voller Serverhoheit!)**. dbcreator: dbuser_dev_dana_for_development, dbuser_dev_dana_for_jtl, dbuser_eazybusiness_jtl, ZDBIKES\sanda.

## 4. SQL Agent

| | test1 | prod |
|---|---|---|
| Dienst | **Stopped / Manual** | Running / Automatic |
| Jobs | nur syspolicy_purge_history | 11 Ola-Hallengren-Jobs *installiert* (DatabaseBackup FULL/DIFF/LOG USER+SYSTEM, IndexOptimize, IntegrityCheck, Cleanups) |
| Proxies | keine | keine |

> [!WARNING]
> **Korrektur 2026-07-21 (Live-Nachprüfung):** Die obige Zeile zählt Job-*Existenz*, nicht -Ausführung. Tatsächlich hat von den 11 Ola-Jobs **genau einer** einen Schedule (`IndexOptimize`, täglich 04:00) — und der **schlägt seit ~2025-11-27 täglich fehl** (`dbo.IndexOptimize` existiert nicht mehr). `DatabaseIntegrityCheck`/CHECKDB lief zuletzt **2024-06-24** (einmalig), Backups laufen extern via CBB (nicht Ola). Vollständige IST-Analyse: [`6-wartung-ist-analyse`](../6-wartung-ist-analyse/6-wartung-ist-analyse.md).

→ Backups auf Prod laufen (extern via CBB); **wirksame SQL-Wartung existiert faktisch nicht** (s. Korrektur oben). test1 hat keinerlei Wartung/Backups.

## 5. Zertifikate (master)

Beide: nur MS-System-Zertifikate (`##MS_*##`). **Keine anwendungseigenen Zertifikate** — Modul-Signing baut auf grüner Wiese.

## 6. eazybusiness-DBs im Detail

**JTL-Schema-Version (dbo.tVersion):** durchgängig **2.0.5.0** (test1, prod, _premig, _tm3, _tm4). Ausreißer: **_tm2 = 1.11.6.0**.

**Mandanten (dbo.tMandant):** test1: 1 Mandant („TEST-DB: eB-Standard"). prod: 4 — 1 eB-Standard→eazybusiness, 3 Testmandant2(Dana)→_tm2, 4 Testmandant3(Sanda/Lukas)→_tm3, 5 Testmandant4(Lukas)→_tm4.

**Eigene Schemas** (beide Instanzen): Robotico, RoboticoEKL, CustomWorkflows. Objekt-Divergenz (test1 führt): RoboticoEKL 18/17/14 (Tab/Proc/View) vs. prod 17/16/13; zusätzliche Tabelle nur test1: `RoboticoEKL.tArticleLabelCategory`. CustomWorkflows: 14 (test1) vs. 15 (prod) Procs. Robotico identisch (4 Tab / 10 Fn / 6 Proc). Schema-Owner RoboticoEKL: test1=`ekl_testmssql_app`, prod=`dbuser_eazybusiness_ekl_addin_backend`; Robotico/CustomWorkflows=dbo.

**Migrations-Journal gefunden: `RoboticoEKL.tMigrationHistory`** (kMigration, nVersion, cFileName, cChecksum, dApplied, nDurationMs, cAppliedBy, bSuccess, cErrorMessage) — der Runner des excel_ekl-Repos:
- test1: **25 Migrationen**, höchste `025_label_family_and_delta` (2026-07-05), alle bSuccess=1.
- prod: **24 Migrationen**, höchste `024_workflow_kbenutzer_string` (2026-07-02).
- → test1 läuft genau eine Migration vor prod; erklärt die Objekt-Divergenz. **Skriptbasierter test1→prod-Fluss ist im Haus etabliert.** Robotico und CustomWorkflows haben KEIN eigenes Journal.

## 7. Worker-/Abgleich-Konfiguration (prod/eazybusiness)

**Pro-Konto-Sperr-/Abgleich-Flags:**
- **`dbo.ebay_user`**: `nGesperrt`, `dLetzerEbayAbgleich`, `dLetzterBestellabgleich`, `nOutOfStockControl`, `nLagerbestaendeAendern` — 1 Konto, nGesperrt=0.
- **`dbo.pf_user`** (Amazon/Plattform): `nGesperrt`, `nAktiv`, `dVcsSperreUtc`/`dVcsLiteSperreUtc`, `nIsTerminated` — **0 Zeilen in der Haupt-DB** (Amazon-Konten evtl. nur in Mandanten-DBs oder nicht eingerichtet).
- **`dbo.tShop`**: `nAktiv`, `nGesperrt` — 2 Shops: „robotico" (aktiv, offen), „unicorn 2: Check24" (aktiv, **gesperrt**).
- **`Worker.tTarget`** (Abgleich-Ziele): uTargetId, kMandant, nAbgleichstyp, kZiel — 10 Zeilen, alle kMandant=1, nAbgleichstyp ∈ {0,2,3,4,5,7,8,13,17,18}, kZiel meist -1 (Wildcard). JTL-seitige Steuerung, welche Abgleichstypen je Mandant laufen.

**Queue-Rowcounts (partition_stats):** tQueue 9.759, tWorkflowQueue 5.266, ebay_usermessagequeue 1.337, tGlobalsQueue 1.221, tDruckQueue 33, ebay_queue_out 4; Amazon-/FulfillmentNetwork-/SCX-/Pos-Queues = 0.

## 8. RoboticoOps-Vorprüfung

**Sauberes Feld** — keine DB/Schema/Objekte namens RoboticoOps/Ops/Admin auf beiden Instanzen.

## Bewertung für das Migrationsdesign

**Versionsparität (kritisch):** Restore nur alt→neu:
- prod (2022) → test1 (2025): **funktioniert** (Testdaten-Refresh möglich; Compat bleibt 160 bis manuell angehoben).
- test1 (2025) → prod (2022): **unmöglich** (kein Downgrade-Restore/Attach).
- **Konsequenz:** „Auf test1 testen, dann prod" ist NUR skript-/migrationsbasiert tragfähig (genau das etablierte RoboticoEKL-Muster). Kein Rollout darf je ein test1-DB-Abbild voraussetzen.

**Was auf test1 fehlt/abweicht:** kein laufender Agent, keine Backups/Wartung, 1 statt 4 Mandanten, kein tm-Setup, schlanke Prinzipale. test1 wirkt als reines RoboticoEKL-Vorlauf-/E2E-System.

**Auffälligkeiten (Hygiene):**
- SQL-Login `dbuser_dev_dana_for_jtl` ist **sysadmin auf prod**.
- `eazybusiness_tm2` auf altem JTL-Stand 1.11.6.0.
- `eazybusiness_premig` liegt physisch in `E:\Backup\` (FULL recovery).
- Fremd-DBs (ersatzteile_prod*, HbDat001) auf der prod-Instanz — Ressourcen-/Wartungsplanung.

## Offene Punkte

- Exakter prod-CU-Stand vs. test1-RTM bei Bedarf; Grundaussage alt→neu bleibt.
- `pf_user` leer: Amazon-Konten in `_tm*`-DBs nachprüfen.
- `_tm*`-DBs nicht auf RoboticoEKL-Migrationsstände geprüft.
- `cAppliedBy`/Checksummen der EKL-Migrationen nicht ausgelesen.
- Semantik der `Worker.tTarget.nAbgleichstyp`-Werte klären (Probeliste).
