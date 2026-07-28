# Teilrecherche: excel_ekl „Transfer command" / lokaler MSSQL-Container

> Rohbefund eines delegierten Research-Agenten (2026-07-27), unverändert übernommen.
> Eingang für `00-grundrecherche.md` (Konsolidierung durch den Lead-Agenten).

## Zusammenfassung

Der gesuchte Mechanismus ist das CLI-Tool **`test-db-jtl`** (npm-Script `test-db-jtl` → `npx tsx scripts/test-db-jtl.ts`). Es baut aus der produktiven JTL-`eazybusiness`-Datenbank auf einem remote SQL Server eine **getrimmte** (verkleinerte) Kopie, transferiert diese per SMB auf die lokale Maschine und restored sie in einen lokalen **`jtl-test-db`** MSSQL-2022-Docker-Container. Das ist kein einzelner Shell-„Transfer command", sondern eine 9-stufige, deklarative Pipeline.

## Zentrale Dateien (absolut)

- CLI-Einstieg: `/home/lukas/WebStorm/excel_ekl/scripts/test-db-jtl.ts`
- Modul-Bibliothek: `/home/lukas/WebStorm/excel_ekl/scripts/lib/test-db-jtl/`
  - `backup.ts` — server-seitiges COPY_ONLY-Backup
  - `restore.ts` — Restore als Test-DB (remote) + `restoreInDocker` + `cloneDatabaseInDocker`
  - `trim.ts` — Trimmen/Verkleinern + `exportTrimmedBackup`
  - `transfer.ts` — SMB-Transfer (Robocopy / smbclient)
  - `docker.ts` — Container-Lifecycle + Rebuild + lokaler Shrink
  - `snapshot.ts` / `snapshot-commands.ts` — schnelle Snapshot-Resets
  - `pipeline/full-pipeline.ts` + `pipeline/context.ts` + `pipeline/node-deps.ts` — deklarative Pipeline
  - `pipeline/README.md` — Architektur-Referenz
  - `types.ts` — Config-/Fehlertypen
  - `safety.ts` — Schutzschichten (`_copy`-Suffix-Pflicht, Blacklist, Runtime-DB-Check)
- SQL-Builder: `/home/lukas/WebStorm/excel_ekl/shared/sql/backup-sql.ts` (+ `shared/sql/sanitize.ts`)
- Docker-Setup: `/home/lukas/WebStorm/excel_ekl/docker/mssql/docker-compose.yml`, `entrypoint.sh`, `docker/mssql-init/01-create-database.sql`
- Config-Defaults: `/home/lukas/WebStorm/excel_ekl/backend/config/default.ts` (Zeilen ~1955–2065)
- Doku: `/home/lukas/WebStorm/excel_ekl/docs/architecture/cli-tooling.md`, `CLAUDE.md` (Z. 258, 274, 814–859)
- Lokale Backups liegen in: `/home/lukas/WebStorm/excel_ekl/docker/mssql/backups/` (dort aktuell u.a. `eazybusiness_excel_ekl_copy_trimmed.bak`, ~1,86 GB)

## Der „Transfer command" — genauer Ablauf

Dokumentierter Standardbefehl (CLAUDE.md): `npm run test-db-jtl -- transfer` bzw. die komplette Pipeline `npm run test-db-jtl -- full`.

Die `full`-Pipeline (`buildFullPipeline` in `pipeline/full-pipeline.ts`) läuft in dieser Reihenfolge:

`check-docker → backup → restore → trim → export → transfer → docker-rebuild → snapshot-create → verify-transfer`

Commit-Point ist `docker-rebuild` (Ersetzen des Container-Volumes = Point of no Return; danach nur noch Hand-Instruktionen, kein Rollback). `full` läuft non-interaktiv (`yes: true`), schreibt aber das Destructive-Audit-Event. Nach der Pipeline läuft immer ein `runFinalCleanup` (löscht remote Backup + Export + droppt remote Test-DB), außer bei `--no-cleanup`.

Einzelschritte im Detail:

**1. Backup (`backup.ts` → `createBackup`)** — auf dem Quell-SQL-Server:
- `EXEC xp_create_subdir` (Backup-Verzeichnis sicherstellen)
- `BACKUP DATABASE [eazybusiness] TO DISK = N'<backupPath>\eazybusiness_excel_ekl_copy.bak' WITH COPY_ONLY, COMPRESSION, INIT, STATS = 5, NAME = N'...'` (SQL aus `shared/sql/backup-sql.ts::buildBackupSql`). **COPY_ONLY** ist bewusst gewählt, um die Backup-Chain der Prod-DB nicht zu stören.
- Fortschritt via `sys.dm_exec_requests`-Polling; Größe aus `msdb.dbo.backupset`.
- Zielpfad (default): `D:\Backups`; in der lokalen Config `E:\Work\EKL-TestDB\Backups`.

**2. Restore (`restore.ts` → `restoreAsTestDb`)** — auf dem Server, als **separate** Test-DB `eazybusiness_excel_ekl_copy`:
- Safety: Zielname muss auf `_copy`-Suffix enden (`REQUIRED_SUFFIX`), Blacklist-Check.
- `RESTORE FILELISTONLY`, dann `RESTORE DATABASE [..._copy] FROM DISK WITH MOVE ..., REPLACE, STATS = 5` (MDF/LDF nach `dataFilePath`, default `D:\SQLData`).
- Danach `xp_delete_file` (Backup wird wieder gelöscht), `ALTER DATABASE ... SET RECOVERY SIMPLE`, ggf. Trim-User anlegen (nur bei SQL-Auth; bei NTLM übersprungen).

**3. Trim (`trim.ts` → `trimDatabase`)** — Verkleinerung (siehe unten).

**4. Export (`trim.ts` → `exportTrimmedBackup`)**:
- `BACKUP DATABASE [..._copy] TO DISK = N'<backupPath>\eazybusiness_excel_ekl_copy_trimmed.bak' WITH COPY_ONLY, COMPRESSION, STATS = 5, NAME = N'...'`.

**5. Transfer (`transfer.ts` → `transferFromRemote`)** — der eigentliche „Transfer command":
- Plattform-abhängige Strategie (`detectStrategy`):
  - **Windows** → **Robocopy**: `robocopy <smbShare> <localDir> <filename> /R:3 /W:10 /MT:8 /NP /NFL /NDL` (Erfolg = Exit-Codes 0–7).
  - **Linux/macOS** → **smbclient mit Kerberos**: `smbclient //server/share --use-kerberos=required --no-pass -c 'get "<remoteFile>" "<localFile>"'`. Voraussetzung: gültiges Kerberos-Ticket (`kinit lukas@ZDBIKES.LOCAL`) und installiertes `smbclient`. Kein Mount/sudo nötig.
- Ziel lokal: `config.docker.backupDir` = `docker/mssql/backups` (Pfad wird bei Bedarf angelegt).
- Verifikation: Größenabgleich + optional SHA256 (`--verify`) — **nur unter Windows/Robocopy**; unter Linux ist die SHA256-Verifikation eine bewusst sichtbare Lücke (`verifyTransferGap`, Schritt `verify-transfer` wird als SKIPPED markiert, nicht still verworfen).
- SMB-Share (aus lokaler Config): `\\vm-sql2.zdbikes.local\work\EKL-TestDB\Backups`.

**6. Docker-Rebuild (`docker.ts` → `rebuildContainer`)** — lokaler Container-Restore (siehe unten).

**7. Snapshot-Create** — legt eine Clean-Baseline für schnelle `<10s`-Resets an.

Standalone: Der einzelne `transfer`-Command (`runTransfer` in `test-db-jtl.ts`) prüft SMB-Erreichbarkeit, sucht via `getLatestRemoteBackup` das neueste `.bak` auf dem Share und ruft `transferFromRemote` auf.

## Lokaler MSSQL-Container-Restore — existiert vollständig

`docker/mssql/docker-compose.yml`:
- Image: `mcr.microsoft.com/mssql/server:2022-latest` (**SQL Server 2022**, kein 2025), Container-Name **`jtl-test-db`**.
- Port `1434:1433` (um lokale 1433-SQL-Server-Instanzen nicht zu kollidieren).
- Named Volume `jtl-test-mssql-data`; Backups als read-only Bind-Mount `./backups:/backups:ro`.
- `MSSQL_PID=Developer`, `MSSQL_MEMORY_LIMIT_MB=3584`, `MSSQL_COLLATION=Latin1_General_CI_AS` (Match zur JTL-Wawi-Collation — wichtig, sonst tempdb-Collation-Konflikte).
- Custom `entrypoint.sh` (Volume-Permissions fixen, dann auf `mssql`-User droppen); Healthcheck via `sqlcmd SELECT 1`.

Restore-Fluss (`docker.ts`):
- `rebuildContainer`: `docker compose down -v` (Volume + Daten weg) → `ensureVolumeRemoved` → `startContainer` (`pull` + `up -d` + Healthcheck-Wait bis 5 min) → `restoreInDocker` → `shrinkLocalDatabase`.
- `restoreInDocker` (`restore.ts`): `RESTORE FILELISTONLY` + `RESTORE DATABASE [eazybusiness] FROM DISK = N'/backups/<file>' WITH MOVE ... TO '/var/opt/mssql/data/...', REPLACE, STATS = 5`, danach `SET RECOVERY SIMPLE`. Docker nutzt immer SQL-Auth (`sa`). Existierende DB nur mit `--force` (killt aktive Sessions).
- `refreshDatabase`: Restore ohne Container-Rebuild (droppt vorher alle Snapshots).
- `shrinkLocalDatabase`: `DBCC SHRINKDATABASE (..., 10)` + `DBCC SHRINKFILE (log, 64)` — reclaimt die durch das Trimmen frei gewordene Allokation lokal. Bewusst non-fatal, invalidiert bei Fehler den Pool.

Zusätzlich `cloneDatabaseInDocker` (`docker clone --target-db`): In-Container-Klon einer DB in eine zweite unabhängige DB (z.B. `eazybusiness_edit_testing`) via lokalem `COPY_ONLY`-Backup → Restore, ohne jeden Prod-Kontakt.

## Trimmen / Verkleinern — vollständig implementiert (`trim.ts::trimDatabase`)

6-Phasen-Ablauf, idempotent, verifiziert vor jeder Phase die Ziel-DB (Defense-in-Depth):
1. Validierung (richtige DB + RECOVERY SIMPLE).
2. **Mandant-Branding**: `dbo.tMandant.cName` bekommt Präfix `TEST-DB:` (Markierung, damit die Kopie erkennbar ist).
3. **Bild-Konsolidierung**: alle `dbo.tBild` auf einen einzigen Survivor reduzieren (Trigger disable, Plattform-Referenztabellen dedupen + auf Survivor umbiegen, FK-safe `TRUNCATE` + Survivor re-insert via IDENTITY_INSERT).
4. **BLOB-Tabellen leeren** (`BLOB_TABLES`): u.a. `dbo.tFile`, `dbo.tWebCache`, `Report.tFile`, `SCX.tUploadData` — via FK-safe `TRUNCATE`.
5. **Log-/History-Tabellen leeren** (`LOG_TABLES`): u.a. `dbo.tLog`, `dbo.tArtikelHistory`, `Verkauf.tAuftrag*_Log` (~1,4 GB / ~5,7 Mio Zeilen), `Shipping.tTrackingLogs`, `Kunde.tHistorie`, `Amazon.tVcs*History` usw.
6. **Integritätscheck**: `DBCC CHECKDB WITH PHYSICAL_ONLY, NO_INFOMSGS, TABLOCK`.

FK-Handling (`fkSafeScripts`): eingehende FKs sichern → droppen → FK-Spalten in 50k-Batches auf NULL setzen (bounded Log/tempdb bei SIMPLE Recovery) → `TRUNCATE` → FKs `WITH NOCHECK` neu anlegen. Ziel-DB-Größe laut docker-compose-Kommentar: ~2–5 GB (getrimmt). Teil-Restore im Sinne von „nur einzelne Tabellen wiederherstellen" gibt es nicht — die Verkleinerung erfolgt durch Leeren/Truncaten nach vollem Restore. Machbarkeit weiterer Trimmung: Tabellenlisten (`BLOB_TABLES`/`LOG_TABLES`) sind einfach erweiterbare Konstanten in `trim.ts`.

## Server-Namen, Pfade, Container, Versionen

- Quell-/Prod-SQL-Server: **`vm-sql2.zdbikes.local`** (Admin-Connection, NTLM/Kerberos, Domain `ZDBIKES`, Port 1433). Alternativer Tailscale-Alias `mssql-prod1.ison-musical.ts.net` (in der lokalen Config als Trim-Connection-Server). Quell-DB: **`eazybusiness`**.
- Test-DB-Name (remote, Zwischenkopie): **`eazybusiness_excel_ekl_copy`** (Pflicht-Suffix `_copy`).
- Remote-Pfade: Backup `E:\Work\EKL-TestDB\Backups` (default `D:\Backups`), MDF/LDF `E:\Work\EKL-TestDB\SQLData` (default `D:\SQLData`).
- SMB-Share: `\\vm-sql2.zdbikes.local\work\EKL-TestDB\Backups`.
- Lokaler Container: **`jtl-test-db`**, SQL Server **2022** (`mcr.microsoft.com/mssql/server:2022-latest`), Host `localhost:1434`, Volume `jtl-test-mssql-data`, DB-Name lokal `eazybusiness`, Backup-Dir `docker/mssql/backups`.
- Trim-Login (remote, nur SQL-Auth-Pfad): `dbuser_eazybusiness_ekl_addin_testdb`.
- Retention: 7 Tage (`retentionDays`), Registry als SQLite unter `docker/mssql/test-db-registry.sqlite`.

## Hinweis zu Secrets

In `backend/config/default.ts` stehen nur leere Platzhalter (`password: ''`, „OVERRIDE IN local.ts"). Reale Passwörter/Tokens liegen in `backend/config/local.ts` bzw. den `*.v1.bak`-Sicherungen in `backend/config/` — eingesehen, aber keine Secret-Werte zitiert. Für einen produktiven Lauf braucht es das `local.ts`-Override (SA-Passwort des Containers, Windows-/Trim-Credentials) und ein gültiges Kerberos-Ticket für den SMB-Transfer unter Linux.
