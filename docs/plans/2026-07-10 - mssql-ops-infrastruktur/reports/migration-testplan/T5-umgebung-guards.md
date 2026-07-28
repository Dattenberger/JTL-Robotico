---
date: 2026-07-27
author: Detail-Agent T5 (Umgebung/Guards) — Migrations-Testplan Phase 2
status: Research — ausführbares Setup-Fundament für T1–T4
context: Enabler-Report für den Migrations-Testplan. Liefert das Container-/Backup-/grate-Setup-Runbook, die wiederverwendbaren Sicherheits-Guards, die Plattform-Matrix und die Teardown-Strategie, auf denen T1–T4 laufen. KEINE Tests ausgeführt, kein Container gestartet, keine Server-Schreibzugriffe. Einziger Zugriff außerhalb des Repos war lesendes `ls` auf das excel_ekl-Backup-Verzeichnis.
related: ./00-grundrecherche.md
related-2: ./01-teilrecherche-excel-ekl-transfer.md
---

# T5 — Umgebungsaufbau, Plattform-Matrix & Sicherheits-Guards

> **Sicherheits-Invariante (aus 00-Grundrecherche, gilt für ALLES hier):** Migrationen
> und Tests laufen **ausschließlich gegen den lokalen Container** `localhost,14330`
> (Env `E2E`) bzw. dokumentierte read-only test1-Teile. **`vm-sql2.zdbikes.local` =
> PRODUKTION = absolut tabu.** Einziger — optionaler, als User-Schritt ausgewiesener —
> Prod-Kontakt ist die read-only COPY_ONLY-Backup-Beschaffung (§2.3, Fallback B).

## 0. Ergebnis auf einen Blick

- **Harness-Änderungen nach dem Naming-Rename: KEINE Datei-Edits nötig.** Der Harness
  unter `db-migrations/tests/docker/` ist **content-agnostisch** (referenziert nur
  Container, Port, Collation, Fixtures — keine `ops.*`-Objektnamen). Grep über den
  ganzen Ordner findet keine veralteten Namen. Das „down/up fällig" aus der
  Grundrecherche ist **rein ein frischer Volume-Zyklus** (`teardown -v` + `setup`):
  das alte Volume trägt vor-Rename-Journal-Hashes von `0011`/`0002` und kennt weder
  Wartungssuite noch PayPal-Drop. Ein sauberer Neuaufbau löst das ohne Code-Eingriff.
- **eazybusiness-Backup ist brauchbar:** `eazybusiness_excel_ekl_copy_trimmed.bak`,
  **1,86 GB, Stand 2026-07-16** (11 Tage alt), schema-vollständig (nur Zeilen getrimmt,
  Schema = Prod-Stand). Restore-Richtung SQL 2022 (Quelle) → SQL 2022 (Container) = ok.
- **grate-Runner:** Docker `erikbra/grate:1.6.0`, Host-Network, SQL-Auth — `deploy.ps1`
  wählt ihn automatisch (kein `dotnet` auf PATH). Token-Übergabe secret-frei über
  Env/persistenten Store.
- **Guards:** vier wiederverwendbare Bausteine unten (§3) — Prod-Kontakt technisch
  ausgeschlossen, nicht nur per Konvention. Die eingebauten Clone-Guards sind scharf
  (verifiziert, §3.4).
- **Setup-Reihenfolge (bestätigt mit T3):** Ebene B (RoboticoOps) lässt sich **ohne
  Backup zuerst** deployen (grate legt die DB an); der eazybusiness-Restore ist ein
  **separater Schritt für Ebene A** und wird von T2/T4 sowie T3-14/15/23 gebraucht,
  vom T3-Kern nicht. → §2 fährt Ebene B vor dem Restore.
- **Achtung Wartungs-Jobs (Befund T3):** `MaintenanceSchedulesEnabled` ist **nirgends
  geseedet**, und die Effektiv-Logik ist `bEnabled=1 AND cValue<>'0'` → **fehlender Key
  = ENABLED**. Im **frischen Container** kommen die 6 Wartungs-Jobs beim Ebene-B-Erstdeploy
  also ENABLED (mit Schedules) hoch — anders als test1, wo `'0'` explizit gesetzt war.
  Der Key muss darum **direkt nach dem Ebene-B-Deploy kontrolliert gesetzt werden**
  (`'0'` für Phase-A-Tests T1–T4, unset nur für den bewusst prod-nahen Fall), sonst
  stören ungewollte Hintergrund-Jobläufe die Testfälle (§2 Schritt 4).
- **Ressourcen:** Container-RAM-Limit 3,5 GB (Compose), Disk-Bedarf pro Vollszenario
  inkl. 1–2 tm-Klonen ~15–20 GB — bei 519 GB frei unkritisch.

---

## 1. Vorbedingungen (einmalig prüfen)

| Prüfung | Kommando | Erwartung |
|---|---|---|
| Docker da | `docker version --format '{{.Server.Version}}'` | ≥ 20 (real: 29.5.3) |
| pwsh da | `pwsh -v` | 7.x (real: 7.6.2) |
| sqlcmd (ODBC-Build) | `ls /opt/mssql-tools18/bin/sqlcmd` | vorhanden |
| Disk frei | `df -h /var/lib/docker` | ≥ 25 GB frei (real: 519 GB) |
| Port 14330 frei | `ss -ltnp \| grep 14330` | leer (kein Fremd-Listener) |
| Backup vorhanden | `ls -lh ~/WebStorm/excel_ekl/docker/mssql/backups/eazybusiness_excel_ekl_copy_trimmed.bak` | ~1,86 GB, Datum ≤ ~2 Wochen |

> `dotnet` ist **absichtlich nicht** auf PATH → `deploy.ps1` nutzt automatisch den
> Docker-grate-Runner. Nichts zu tun. Wer nativen grate will: `~/.dotnet/tools` in PATH
> (nicht empfohlen, PATH-Persistenz-Falle — siehe Grundrecherche Frage 5).

---

## 2. Setup-Runbook (nummerierte Schritte)

Alle `npm run …` laufen aus dem **Repo-Root** (`db-migrations/` ist relativ dazu).
Die `pwsh …`-Rohformen funktionieren identisch.

### Schritt 1 — Container hochfahren (frischer Volume-Zyklus)

```bash
# Falls ein altes Volume existiert (vor-Rename-Stand): erst komplett wegräumen.
npm run db:e2e:down        # docker compose down -v  (Container + Volume weg)

# Frisch hoch: generiert .env.local (Secrets, chmod 600), up -d, wartet healthy (≤4 min),
# verifiziert SELECT 1 + SQL-Agent Running (Hard-Fail) + Collation Latin1_General_CI_AS.
npm run db:e2e:up
```

Was `setup.ps1` garantiert (aus dem Skript verifiziert):
- Image `mcr.microsoft.com/mssql/server:2022-latest`, Container `robotico-e2e-mssql`,
  Compose-Projekt `robotico-e2e`, Port **14330**→1433.
- `MSSQL_AGENT_ENABLED=true` (Reset-E2E braucht den Agent) — **Hard-Fail**, wenn Agent
  nicht `Running`.
- `MSSQL_COLLATION=Latin1_General_CI_AS` — greift **nur bei First-Volume-Init**; darum
  ist der `down -v` oben Pflicht, wenn ein altes Volume mit falscher Collation existiert
  (sonst nur Warn+Weiterlauf).
- `MSSQL_MEMORY_LIMIT_MB=3584`, Deploy-Limit 6 GB / Reservation 2 GB.

### Schritt 2 — SA-Passwort in die Shell laden

Die SQL-Auth-Deploys (`-Environment E2E`) lesen das Passwort aus `$env:MSSQL_SA_PASSWORD`.

```bash
# bash/zsh — lädt MSSQL_SA_PASSWORD (und GRATE_CERT_PASSWORD) aus der generierten .env.local:
set -a; source db-migrations/tests/docker/.env.local; set +a
```

Cert-Passwort für Ebene B (`-Scope global`): zwei Wege, beide E2E-tauglich —
(a) `GRATE_CERT_PASSWORD` aus `.env.local` mitexportieren (Tier 1), **oder**
(b) `GRATE_CERT_PASSWORD` *nicht* setzen → `deploy.ps1` generiert auf frischem Container
(kein `RoboticoOpsSigning`-Cert) ein 100-Zeichen-Passwort und persistiert es nach
`~/.robotico-ops/grate-cert.env` unter `GRATE_CERT_PASSWORD_E2E`. **Empfehlung: (a)** —
deterministisch, reproduzierbar über Teardown-Zyklen.

### Schritt 3 — Ebene B (RoboticoOps) deployen (kein Backup nötig)

Ebene B kommt **vor** dem eazybusiness-Restore: grate legt `RoboticoOps` selbst an, und
die Nachkonfiguration in Schritt 4 (Pfad-Repoint, Wartungs-Knopf) braucht das
`ops.tConfig`, das erst dieser Deploy anlegt.

```bash
npm run db:deploy:e2e:global      # legt RoboticoOps + ops.*/reset.*/maint.* an
```
> Der T3-Kern (Ola-Platzierung, Registry, Watchdog-Logik, Signaturkette) läuft bereits
> ab hier — **ohne** restaurierte eazybusiness. Erst T2/T4 sowie T3-14/15/23 (die eine
> reale DB als Wartungs-/Reset-Ziel brauchen) benötigen den Restore aus Schritt 5.

### Schritt 4 — Ebene-B-Nachkonfiguration (VOR Ebene A / vor dem ersten Reset)

Zwei kontrollierte `ops.tConfig`-Eingriffe, beide gegen `localhost,14330 / RoboticoOps`
(SQL-Auth sa). Guard-Header (§3, G1) voranstellen.

**(a) Windows-Pfade auf Linux umbiegen (F2.5).** Die Seeds in `global/up/0020` tragen
`E:\work\…` / `E:\MSSQL\Data` — im Linux-Container ungültig:
```sql
UPDATE ops.tConfig SET cValue = N'/var/opt/mssql/backups/eazybusiness_to_test.bak' WHERE cKey = N'BackupFile';
UPDATE ops.tConfig SET cValue = N'/var/opt/mssql/data'                              WHERE cKey = N'TargetDataDir';
```
> `CloneDatabase` baut den MOVE-Zielpfad mit `\` als Trenner (`@TargetDataDir + '\' + …`).
> Auf Linux ist `\` ein normales Pfadzeichen im Dateinamen (kein Separator) — im
> 2026-07-11-Lauf tolerant, aber **im aktuellen Container-Lauf explizit verifizieren**
> (T2). Bei Problemen `TargetDataDir` ohne Trailing-Slash lassen und den `\` im Proc
> beobachten.

**(b) Wartungs-Schedules kontrolliert setzen (Befund T3 — WICHTIG).**
`MaintenanceSchedulesEnabled` ist **nicht geseedet**; Effektiv-Logik `bEnabled=1 AND
cValue<>'0'` → **fehlender Key = ENABLED**. Im frischen Container kämen die 6
Wartungs-Jobs also mit Schedules hoch und könnten die Testfälle von T1–T4 durch
Hintergrund-Läufe stören. Darum den Key **direkt hier** explizit auf `'0'` setzen:
```sql
-- Phase-A-Default: Wartungs-Schedules AUS, damit keine Hintergrund-Jobs die Tests stören.
-- (spEnsureMaintenanceJobs legt die Jobs disabled an; sp_start_job geht für gezielte
--  T3-Läufe trotzdem — D34. Den Key NUR für den bewussten prod-nahen Fall unset lassen.)
MERGE ops.tConfig AS tgt
USING (VALUES (N'MaintenanceSchedulesEnabled', N'0', N'E2E Phase-A: Schedules aus, damit Hintergrund-Jobs die T1-T4-Tests nicht stören')) AS src(cKey, cValue, cNotes)
    ON tgt.cKey = src.cKey
WHEN MATCHED THEN UPDATE SET cValue = src.cValue
WHEN NOT MATCHED THEN INSERT (cKey, cValue, cNotes) VALUES (src.cKey, src.cValue, src.cNotes);
```
> **Zwei Zustände, beide von T3 gewollt:** `'0'` (Default für T1–T4, oben) vs. **unset**
> (den Key wieder löschen → ENABLED) für den bewusst prod-nahen T3-Fall (F3.6 „unset vs.
> `'0'`"). Der Enabler-Default ist `'0'`; T3 hebt ihn für seinen spezifischen Testfall
> gezielt auf.

### Schritt 5 — eazybusiness-Backup in den Container bringen + restoren

**Brauchbarkeits-Check zuerst** (nicht-destruktiv, gegen die lokale `.bak`):

```bash
BAK=~/WebStorm/excel_ekl/docker/mssql/backups/eazybusiness_excel_ekl_copy_trimmed.bak
ls -lh "$BAK"                          # Datum/Größe plausibel? (Ziel: ≤ ~2 Wochen alt)
```

SQL-Version der Quelle prüfen (Restore nur alt→neu; Container = 2022):
```bash
docker cp "$BAK" robotico-e2e-mssql:/var/opt/mssql/backups/eb.bak
docker exec robotico-e2e-mssql /opt/mssql-tools18/bin/sqlcmd -S 127.0.0.1 -U sa \
  -P "$MSSQL_SA_PASSWORD" -C -h -1 \
  -Q "RESTORE HEADERONLY FROM DISK='/var/opt/mssql/backups/eb.bak'"
# In der Ausgabe: SoftwareVersionMajor muss <= 16 sein (16 = SQL 2022). 17 (=2025) => STOP,
# das Backup stammt aus einer neueren Engine und darf NICHT in den 2022-Container.
```

> **Herkunft der `.bak`:** Die excel_ekl-Pipeline trimmt/exportiert die Kopie auf
> `vm-sql2` (PROD, SQL 2022) → SoftwareVersionMajor 16 erwartet. Falls jemals von test1
> (SQL 2025) erzeugt: SoftwareVersionMajor 17 → unbrauchbar für den 2022-Container.

Restore mit dynamischer MOVE-Liste (robust gegen unbekannte logische Dateinamen):

```bash
docker exec robotico-e2e-mssql /opt/mssql-tools18/bin/sqlcmd -S 127.0.0.1 -U sa \
  -P "$MSSQL_SA_PASSWORD" -C -b -Q "
SET NOCOUNT ON;
IF DB_ID('eazybusiness') IS NOT NULL
BEGIN
    ALTER DATABASE [eazybusiness] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE [eazybusiness];
END
DECLARE @data sysname, @log sysname;
DECLARE @fl TABLE (LogicalName sysname, PhysicalName nvarchar(260), Type char(1),
    FileGroupName sysname NULL, Size numeric(20,0), MaxSize numeric(20,0), FileId int,
    CreateLSN numeric(25,0), DropLSN numeric(25,0), UniqueId uniqueidentifier,
    ReadOnlyLSN numeric(25,0), ReadWriteLSN numeric(25,0), BackupSizeInBytes bigint,
    SourceBlockSize int, FileGroupId int, LogGroupGUID uniqueidentifier,
    DifferentialBaseLSN numeric(25,0), DifferentialBaseGUID uniqueidentifier,
    IsReadOnly bit, IsPresent bit, TDEThumbprint varbinary(32), SnapshotUrl nvarchar(360));
INSERT INTO @fl EXEC('RESTORE FILELISTONLY FROM DISK=''/var/opt/mssql/backups/eb.bak''');
SELECT @data = LogicalName FROM @fl WHERE Type='D';
SELECT @log  = LogicalName FROM @fl WHERE Type='L';
DECLARE @sql nvarchar(max) = N'
RESTORE DATABASE [eazybusiness] FROM DISK=''/var/opt/mssql/backups/eb.bak''
WITH MOVE ' + QUOTENAME(@data,'''') + N' TO ''/var/opt/mssql/data/eazybusiness.mdf'',
     MOVE ' + QUOTENAME(@log ,'''') + N' TO ''/var/opt/mssql/data/eazybusiness_log.ldf'',
     REPLACE, RECOVERY, STATS=5;';
EXEC(@sql);
ALTER DATABASE [eazybusiness] SET RECOVERY SIMPLE;
PRINT 'eazybusiness restored + RECOVERY SIMPLE';"
```

Schema-/JTL-Stand nach Restore verifizieren (optional, gegen JTL 1.10-Erwartung):
```bash
docker exec robotico-e2e-mssql /opt/mssql-tools18/bin/sqlcmd -S 127.0.0.1 -U sa \
  -P "$MSSQL_SA_PASSWORD" -C -d eazybusiness -h -1 \
  -Q "SET NOCOUNT ON; SELECT TOP 1 nVersion FROM dbo.tVersion ORDER BY nVersion DESC;
      SELECT COUNT(*) AS CustomWorkflowsSchemaVorhanden FROM sys.schemas WHERE name='CustomWorkflows';"
```
> Nur *voller* Restore (Schema komplett) ist brauchbar — Minimal-Fixtures reichen NICHT:
> `InvalidateCredentials`/`NeutralizeWorker`/`AnonymizeCustomerData` referenzieren
> `tEMailEinstellung`/`ebay_user`/`tOauthConfig`/`tShop`/`tkunde`/`tAdresse` **ungeguardet**
> (Grundrecherche §3.3). Die getrimmte, schema-vollständige Kopie ist genau richtig.

**Fallback A (kein Prod-Kontakt, bevorzugt):** Ist die vorhandene `.bak` unbrauchbar
(zu alt / falsche SQL-Version), zunächst die **bereits im excel_ekl-Container
`jtl-test-db` (Port 1434) restaurierte `eazybusiness`** als Quelle nehmen: dort ein
lokales `BACKUP … WITH COPY_ONLY` ziehen und dieselbe `.bak` verwenden. Kein Prod-Kontakt.

**Fallback B (manueller User-Schritt, nur falls A ausscheidet):** frische getrimmte
Kopie über die excel_ekl-Pipeline erzeugen:
```bash
cd ~/WebStorm/excel_ekl && npm run test-db-jtl -- full     # NUR vom User auszuführen
```
Das fährt read-only `BACKUP … COPY_ONLY` gegen **PROD `vm-sql2`** (stört keine
Backup-Chain), trimmt, transferiert per `smbclient --use-kerberos=required` (benötigt
`kinit lukas@ZDBIKES.LOCAL`) nach `docker/mssql/backups/`. Danach dieselbe `.bak` wie
oben in den robotico-Container `docker cp`en. **Diesen Schritt nie autonom fahren —
er berührt Produktion (read-only).**

### Schritt 6 — Ebene A (eazybusiness-Objekte) deployen

Braucht die restaurierte DB aus Schritt 5.

```bash
npm run db:deploy:e2e
```

grate-Runner-Mechanik (aus `deploy.ps1` verifiziert): Docker-Runner mit
`--network host`, `--entrypoint /app/grate`, SQL-Ordner read-only unter `/db` gemountet,
Connection-String `Server=localhost,14330;…;User ID=sa;Password=…` (SQL-Auth aus
`$env:MSSQL_SA_PASSWORD`). Ebene A wird in `--transaction` gewrappt, Ebene B (Schritt 3)
**nicht** (msdb-/ALTER-DATABASE-/sp_add_job-Statements sind nicht transaktionsfähig;
jedes `up/` ist selbst-idempotent). Cert-Token wird als `--usertokens=CertPassword=…`
übergeben — briefly in der Prozessliste sichtbar (dokumentierte GOTCHA), aber nie in
Repo-Dateien.

### Schritt 7 — Verifikation

```bash
npm run db:e2e:validate           # validate_structure.sql gegen RoboticoOps (read-only)
npm run db:validate:e2e           # umgebungs-agnostische Rollout-Validierung (beide Ketten)
```

Optional für SID-genaue Orphan-/Grant-Tests (T2): reale **SQL**-Logins von test1
spiegeln — **read-only gegen test1** (dokumentierter Fallback-Zugriff, keine Writes):
```bash
npm run db:e2e:copy-logins -- -WhatIf    # Preview; -WhatIf entfernen zum Anwenden
```

---

## 3. Sicherheits-Guards (vollständiger Code, wiederverwendbar)

Ziel: **Prod-Kontakt technisch ausgeschlossen**, nicht nur per Konvention. Vier Ebenen,
defense-in-depth. G1 kommt in **jedes** Testskript (T1–T4), G2 in jeden Shell-Wrapper.

### G1 — T-SQL-Guard-Header (Prod-Deny-Assertion)

**Design-Entscheidung:** Ein naiver `@@SERVERNAME = 'robotico-e2e-mssql'`-Check ist
**unzuverlässig** — `@@SERVERNAME` im Container ist der Hostname zum Zeitpunkt der
SQL-Installation (per Default die kurze Container-ID, **nicht** `container_name`), also
nicht vorhersagbar. Robuster ist eine **Multi-Signal-Deny-Assertion**: sie schlägt zu,
sobald *irgendein* Merkmal auf einen realen Server deutet. Drei unabhängige Signale:

1. **Deny-Liste** realer Servernamen (`vm-sql2`, `vm-sql-test1`) über
   `SERVERPROPERTY('MachineName')` **und** `@@SERVERNAME`.
2. **Auth-Modus:** reale Server sind Windows-Auth-only
   (`SERVERPROPERTY('IsIntegratedSecurityOnly') = 1`); der Container läuft Mixed-Mode
   (SA-SQL-Login) → `= 0`. Starkes strukturelles Unterscheidungsmerkmal.
3. **Edition:** Container = `Developer Edition`; Prod/Test = Standard/Enterprise.

Als Copy-Paste-Header **und** als `:r`-Include verwendbar (Datei unten):

```sql
-- ============================================================================
-- E2E-GUARD  — an den KOPF jedes Testskripts. Bricht ab, BEVOR ein Write läuft,
-- sobald die Verbindung auf einen realen Server (PROD/TEST) deutet.
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur/reports/migration-testplan/T5-umgebung-guards.md
-- ============================================================================
SET NOCOUNT ON;
DECLARE @machine sysname = CONVERT(sysname, SERVERPROPERTY('MachineName'));
DECLARE @srv     sysname = CONVERT(sysname, @@SERVERNAME);
DECLARE @intonly int     = CONVERT(int,     SERVERPROPERTY('IsIntegratedSecurityOnly'));
DECLARE @edition nvarchar(128) = CONVERT(nvarchar(128), SERVERPROPERTY('Edition'));

-- (1) Deny-Liste bekannter realer Hosts (case-insensitiv via Collation der DB).
IF @machine LIKE N'vm-sql2%' OR @srv LIKE N'vm-sql2%'
   OR @machine LIKE N'vm-sql-test1%' OR @srv LIKE N'vm-sql-test1%'
   OR @machine LIKE N'%zdbikes%' OR @srv LIKE N'%zdbikes%'
    THROW 59001, N'E2E-GUARD: Ziel sieht aus wie ein realer Server (MachineName/@@SERVERNAME). Abbruch.', 1;

-- (2) Reale Server sind Windows-Auth-only; der E2E-Container ist Mixed-Mode.
IF @intonly = 1
    THROW 59002, N'E2E-GUARD: Instanz ist Integrated-Security-only (= realer Server, nicht der Mixed-Mode-Container). Abbruch.', 1;

-- (3) Der E2E-Container ist Developer Edition.
IF @edition NOT LIKE N'Developer%'
    THROW 59003, N'E2E-GUARD: Instanz ist keine Developer Edition (= vermutlich realer Server). Abbruch.', 1;

PRINT CONCAT(N'E2E-GUARD ok: ', @srv, N' / ', @edition, N' — write erlaubt.');
GO
```

Als Include-Datei ablegen (z. B. `db-migrations/tests/_e2e_guard.sql`) und in jedem
Testskript zuerst laden:
```sql
:r ./_e2e_guard.sql
-- ab hier der eigentliche Test …
```
> `:r` funktioniert nur in `sqlcmd`-Mode. Für Skripte, die auch im SSMS-GUI laufen
> sollen, den Block copy-pasten. THROW-Nummern **59001–59003** sind bewusst außerhalb
> des Migrations-Bereichs (50xxx/51xxx) gewählt, damit sie nicht mit der Lint-Regel (k)
> „eindeutige THROW-Nummern" der Ketten kollidieren.

### G2 — Bash/pwsh-Host-Whitelist-Wrapper

Ein dünner Wrapper, durch den **jeder** `sqlcmd`-/`deploy`-Aufruf der Testsuite läuft.
Er lässt nur `localhost,14330` (bzw. `127.0.0.1,14330`) zu und verweigert alles andere,
bevor überhaupt eine Verbindung aufgebaut wird.

```bash
#!/usr/bin/env bash
# e2e-guard.sh — Host-Whitelist für E2E. Beispiel:
#   ./e2e-guard.sh /opt/mssql-tools18/bin/sqlcmd -S localhost,14330 -U sa -C -i test.sql
set -euo pipefail
ALLOWED_RE='^(localhost|127\.0\.0\.1),14330$'
target=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  if [[ "${args[i]}" == "-S" ]]; then target="${args[i+1]:-}"; fi
  # deploy.ps1-Form: -Environment PROD/TEST hart ablehnen
  if [[ "${args[i]}" == "-Environment" && "${args[i+1]:-}" != "E2E" ]]; then
    echo "E2E-GUARD (shell): -Environment '${args[i+1]:-}' verweigert — nur E2E erlaubt." >&2; exit 3
  fi
done
if [[ -n "$target" && ! "$target" =~ $ALLOWED_RE ]]; then
  echo "E2E-GUARD (shell): -S '$target' nicht auf der Whitelist (nur localhost,14330)." >&2; exit 3
fi
exec "${args[@]}"
```

pwsh-Äquivalent (für die `.ps1`-Wrapper der Suite):
```powershell
function Assert-E2ETarget {
    param([string] $ServerArg, [string] $Environment)
    if ($Environment -and $Environment -ne 'E2E') {
        throw "E2E-GUARD: -Environment '$Environment' verweigert — nur E2E erlaubt."
    }
    if ($ServerArg -and $ServerArg -notmatch '^(localhost|127\.0\.0\.1),14330$') {
        throw "E2E-GUARD: Ziel '$ServerArg' nicht auf der Whitelist (nur localhost,14330)."
    }
}
```

### G3 — Deploy nur mit explizitem `-Environment E2E`

Struktureller Guard, bereits im Repo — **hier nur die Nutzungsregel**:
- `targets.config.json` zeigt `E2E` auf `localhost,14330` (SQL-Auth sa), `TEST` auf
  `vm-sql-test1`, `PROD` auf `vm-sql2`. Für die gesamte Testsuite **ausschließlich**
  `-Environment E2E` bzw. die `db:*:e2e`-npm-Scripts verwenden.
- `deploy.ps1`/`mandant.ps1` haben zusätzlich ein interaktives **PROD-Y/N-Gate**
  (verifiziert: `deploy.ps1:160-173`, `mandant.ps1:115-131`) — ein versehentliches
  `-Environment PROD` bricht ohne Bestätigung ab und liefert Exit 1.
- **Nie** `TEST`/`PROD`-Credentials in die Test-Shell exportieren. Für E2E genügen
  `MSSQL_SA_PASSWORD` (+ optional `GRATE_CERT_PASSWORD`) aus `.env.local`.

### G4 — Verifikation, dass die eingebauten Clone-Guards scharf sind

Die Reset-Pipeline hat mehrschichtige Clone-Guards. **Verifiziert** an den Quellen:

| Guard | Ort | Bedingung → THROW |
|---|---|---|
| Entry-Start | `spProcessNextResetRequest.sql:102-103` | `@TargetDb = 'eazybusiness' OR NOT LIKE 'eazybusiness[_]%'` |
| Step-Whitelist | `spProcessNextResetRequest.sql:133-145` | Step-Proc nicht `reset.spInternal_*` → THROW 51005 |
| CloneDatabase | `spInternal_CloneDatabase.sql:27-28` | dito → THROW 51010 |
| Source≠Target | `spInternal_CloneDatabase.sql:47-48` | `@TargetDb = @SourceDb` → THROW 51014 |
| DB-Constraint | `up/0002` | `CK_tMandant_cTargetDb` (Backstop auf Tabellenebene) |

**Scharf-Test (gehört als PASS-Nachweis in T2, hier als Guard-Beleg):** direkter Aufruf
mit verbotenem Ziel muss THROWen, kein Write darf durchgehen:
```sql
:r ./_e2e_guard.sql
BEGIN TRY
    EXEC reset.spInternal_CloneDatabase @TargetDb = N'eazybusiness', @RequestId = 0, @MandantKey = N'x';
    THROW 59010, N'FAIL: CloneDatabase hätte gegen Ziel ''eazybusiness'' THROWen müssen.', 1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() <> 51010 THROW;
    PRINT 'PASS: Clone-Guard 51010 scharf (Ziel eazybusiness verweigert).';
END CATCH
```
Analog für `NOT LIKE 'eazybusiness[_]%'` (z. B. `@TargetDb = N'RoboticoOps'` → 51010)
und Source=Target.

---

## 4. Plattform-Matrix

### 4.1 Locale / German-Default-Language (Datumsliteral-Falle, F2.6)

Im Container einen Login mit deutscher Default-Language anlegen und darunter die
datumsliteral-tragenden Pfade fahren (`EXPIRY_DATE '29991231'` in `up/0011`; Cert-Deploy):
```sql
:r ./_e2e_guard.sql
IF SUSER_ID('e2e_de_login') IS NULL
    CREATE LOGIN [e2e_de_login] WITH PASSWORD = N'Str0ng!Passw0rd_e2e', DEFAULT_LANGUAGE = [Deutsch], CHECK_POLICY = OFF;
-- Erwartung: 'YYYYMMDD' (Basic-ISO, sprachneutral) parst unter DATEFORMAT dmy korrekt;
-- ein gestrichdatiertes 'YYYY-MM-DD' würde hier scheitern (genau darum Lint-Regel h).
```
> Der Datumsliteral-Bug wurde auf test1 (deutsches Locale) gefunden und per Lint-Regel
> (h) gefixt. Der Container ist per Default englisch — der German-Login reproduziert die
> Locale-Bedingung **im Container**, ohne test1 zu brauchen.

### 4.2 Collation-Negativtest (F2.9 → erwarteter THROW 50001)

`global/up/0001` asserted `Latin1_General_CI_AS` hart. Negativfall: ein **naiver
Container ohne `MSSQL_COLLATION`** bekommt Default `SQL_Latin1_General_CP1_CI_AS` → der
Ebene-B-Deploy muss mit **THROW 50001** abbrechen (dokumentierter, *erwarteter* Fehler).

```bash
# Wegwerf-Instanz OHNE Collation-Env, anderer Port, um den Assert scharf zu sehen:
docker run -d --name e2e-collation-neg -e ACCEPT_EULA=Y -e MSSQL_PID=Developer \
  -e 'MSSQL_SA_PASSWORD='"$MSSQL_SA_PASSWORD" -p 14331:1433 \
  mcr.microsoft.com/mssql/server:2022-latest
# ... healthy abwarten, dann global-Deploy dagegen -> ERWARTET: THROW 50001 (collation).
docker rm -f e2e-collation-neg     # danach wegräumen
```
> Der reguläre Harness setzt die Collation korrekt; dieser Negativtest belegt nur, dass
> der Guard scharf ist. Nicht mit dem Haupt-Container vermischen.

### 4.3 UTC-vs-CEST-Grenze (Container-Grenze)

Der Container läuft per Default **UTC** (`SYSDATETIME()` = UTC). Zeitbasierte
Wartungs-Watchdogs (`spCheckBackupChain` Freshness `:66`, Liveness-Grace `:82-86`)
rechnen gegen `SYSDATETIME`. **Im Container testbar:** die Grace-/Staleness-Logik über
*relatives* Zurückdatieren von `dModified` (unabhängig von der absoluten TZ).
**NICHT container-testbar:** ob die realen Agent-Job-Schedules zur erwarteten *lokalen*
(CEST-)Wanduhrzeit feuern — das hängt an der TZ des realen Servers. → test1-Fallback (§4.5).

Optional den Container auf CEST stellen, wenn ein absoluter Zeitbezug nötig wird:
`docker run … -e TZ=Europe/Berlin` (Agent-Schedules folgen der Container-TZ).

### 4.4 Compat-Level-Absenkung (SQL-2022-Floor, Schnittstelle zu T4)

F4.3: mehrere Ebene-A-Funktionen nutzen das 3-Argument-`STRING_SPLIT(…, 1)`
(enable_ordinal). CREATE gelingt auf älterem Compat-Level, **FAIL erst zur Laufzeit**.
Der Container ist SQL 2022 (Engine-Floor korrekt); um den *unter*-Floor-Fall zu
simulieren, den **Compat-Level der eazybusiness-Kopie absenken**:

```sql
:r ./_e2e_guard.sql
ALTER DATABASE [eazybusiness] SET COMPATIBILITY_LEVEL = 150;   -- 150 = SQL 2019-Verhalten
-- T4 fährt dann die STRING_SPLIT-3-arg-Pfade -> ERWARTET Laufzeitfehler.
-- Danach zurück auf 160 (SQL 2022):
ALTER DATABASE [eazybusiness] SET COMPATIBILITY_LEVEL = 160;
```
> **Schnittstelle T4:** T5 stellt Mechanik + Container bereit; die konkrete
> Funktions-/Fehlermatrix (welche `fn*`/`sp*` bei 150 wie failen) gehört zu T4. Exaktes
> Laufzeitverhalten des 3-arg-`STRING_SPLIT` unter Compat 150 dort empirisch feststellen,
> nicht hier vorwegnehmen.

### 4.5 Was der Container NICHT kann → dokumentierte test1-Fallback-Liste

| Nicht im Container testbar | Warum | Fallback |
|---|---|---|
| AD/Windows-Auth, `ZDBIKES\…`-Gruppen, Kerberos | keine Domäne im Container | **test1** (read-only Login-Katalog; `copy-logins.ps1` spiegelt SQL-Logins SID-genau) |
| Echter Database-Mail-Versand (SMTP) | kein Mail-Profil/SMTP im Container (nur PRINT-Pfad) | test1 hat ebenfalls kein aktives Profil → Mail-Versand bleibt **prod-only (B6)**; im Container nur Struktur/Operator-Verdrahtung |
| `xp_instance_regread/regwrite`-Wirkung auf Agent-Mail-Profil | Linux-Registry-Emulation, Lesewirkung unsicher (F3.1) | im Container *Verhalten* dokumentieren (regread leer? regwrite Fehler?); die *reale* Wirkung → test1/Prod |
| Absolute lokale Wanduhr-Schedules (CEST) | Container-Default UTC (§4.3) | test1 (echte Server-TZ) oder `-e TZ=Europe/Berlin` |
| JTL-Worker/WaWi-Client-Interaktion, echter RegisterMandant-Blast-Radius | kein WaWi-Client, kein Prod-Mandantenkontext | manueller Prüfschritt außerhalb SQL / Prod |

> test1 = **SQL 2025**, nur **lesend** und nur für die obigen container-untestbaren Fälle.
> **Nie test1 als Backup-Quelle** (2025 > 2022, Restore-Richtung verletzt).

---

## 5. Teardown-/Reset-Strategie zwischen Testläufen

Drei Granularitäten, nach Zeitkosten gestaffelt. Empfehlung: **je nach Testklasse die
billigste ausreichende Stufe**.

| Stufe | Kommando | Was wird zurückgesetzt | Zeitkosten (Schätzung) |
|---|---|---|---|
| **A — Klon-intern** | (nichts) | Reset-Pipeline dropt+restauriert ihren `eazybusiness_tmN`-Klon selbst bei jedem Lauf | 0 Zusatzaufwand; ~1–2 min/Reset (Restore der getrimmten DB) |
| **B — eazybusiness neu** | `docker exec … DROP + RESTORE` (Schritt-3-Skript) | frische `eazybusiness` aus der `.bak` im Container, Ketten-Journal bleibt | ~2–3 min |
| **C — Voll-Wipe** | `npm run db:e2e:down` + `db:e2e:up` + Schritt 3–5 | komplette Engine (Volume weg), beide Ketten + DB neu | ~10–12 min (up ~2–3, Restore ~2–3, 2× Deploy ~3–5) |

**Wann welche Stufe:**
- **A** genügt für wiederholte Reset-/Wartungs-Läufe (T2/T3) — der Klon ist ohnehin
  ephemer; die geteilte `eazybusiness`-Quelle bleibt sauber.
- **B** zwischen T1-Adoptions-/Drift-Fällen (F1.x), die die `eazybusiness` selbst
  mutieren (Journal trimmen, up/-Hash brechen). Ketten-DB `RoboticoOps` bleibt stehen.
- **C** einmal am Anfang (Pflicht wegen vor-Rename-Volume) und immer, wenn Ebene B /
  Collation / Signaturkette in den Ausgangszustand müssen.

**Snapshot-Option (nur wenn Iteration eng wird):** SQL-Server-DB-Snapshots
(`CREATE DATABASE eazybusiness_snap ON (…) AS SNAPSHOT OF eazybusiness` +
`RESTORE DATABASE eazybusiness FROM DATABASE_SNAPSHOT='eazybusiness_snap'`) geben
**<10-s-Reverts** — analog zum excel_ekl-Snapshot-Mechanismus. **Bewusst nicht als
Default:** die Harness bringt das nicht mit, es ist Zusatz-Tooling, und Stufe B ist mit
2–3 min für die erwartete Testkadenz ausreichend. Nur einführen, wenn ein Testblock
sehr viele `eazybusiness`-Resets in Folge braucht.

---

## 6. Blocker-Risiken fürs Setup

| # | Risiko | Wirkung | Mitigation / Vorab-Check |
|---|---|---|---|
| B1 | **Collation nur bei First-Init** | Reuse eines alten Volumes hält falsche Collation → `up/0001` THROW 50001, alle T2/T3 blockiert | `db:e2e:down` (down -v) VOR `up`; `setup.ps1` warnt bereits — Warnung als Hard-Stop behandeln |
| B2 | **Vor-Rename-Volume** | alte one-time-Hashes (`0011`/`0002`) journaled → grate Hash-Mismatch beim Redeploy | frischer Voll-Wipe (Stufe C) zu Beginn — kein Datei-Edit am Harness nötig |
| B3 | **`.bak` aus SQL 2025** | Restore alt→neu verletzt, RESTORE scheitert | `RESTORE HEADERONLY` → SoftwareVersionMajor ≤ 16 prüfen (Schritt 3); Herkunft = vm-sql2 (2022) erwartet |
| B4 | **Windows-Pfade in ops.tConfig** | `xp_create_subdir`/BACKUP im Container scheitern → CloneDatabase failt | Schritt 4 (Pfad-Repoint) VOR erstem Reset; `\`-Separator-Verhalten auf Linux verifizieren (F2.5) |
| B5 | **SQL Agent nicht Running** | Reset-Job-Pfad (T2) und Wartungs-Jobs (T3) tot | `setup.ps1` Hard-Fail deckt das ab; bei Reuse-Container `sys.dm_server_services` erneut prüfen |
| B6 | **docker cp Ownership** | `.bak` als root kopiert, mssql-User kann nicht lesen → RESTORE „Operating system error 5" | Ziel `/var/opt/mssql/backups` (mssql-lesbar); notfalls `docker exec -u root … chown mssql:root /var/opt/mssql/backups/eb.bak` |
| B7 | **CustomWorkflows-Schema fehlt** | falls die restaurierte DB das Schema nicht trägt, failen CW-`sp*` beim CREATE (F4.1) | Schritt-3-Verifikation prüft `sys.schemas` auf `CustomWorkflows`; getrimmte Prod-Kopie trägt es |
| B8 | **Cert-Passwort-Drift über Teardown** | nach `down -v` neuer Container, aber alter persistenter Store-Key → Auto-Gen greift nicht/fehl | Weg (a) nutzen (`GRATE_CERT_PASSWORD` aus `.env.local` exportieren); frischer Cert nimmt das Passwort ohnehin an (README §3) |
| B9 | **Disk unter Last** | mehrere tm-Klone à ~5 GB + eazybusiness + Engine | ~15–20 GB/Vollszenario; bei 519 GB frei unkritisch, aber `df` bei Langläufen im Blick behalten |
| B10 | **Port-14330-Kollision** | Fremd-Listener (z. B. alter Container-Rest) → `up` scheitert oder verbindet falsch | Vorbedingungs-Check `ss -ltnp \| grep 14330`; excel_ekl-`jtl-test-db` liegt auf 1434, kollidiert nicht |
| B11 | **Wartungs-Jobs default ENABLED** (Befund T3) | `MaintenanceSchedulesEnabled` unset ⇒ ENABLED ⇒ 6 Jobs feuern mit Schedules und stören T1–T4 durch Hintergrund-Läufe | Schritt 4(b): Key direkt nach Ebene-B-Deploy auf `'0'` setzen (Phase-A-Default); unset nur für den bewussten prod-nahen T3-Fall |

---

## 7. Übergaben an T1–T4

- **T1/T2/T3/T4:** `db-migrations/tests/_e2e_guard.sql` (G1) an den Kopf jedes neuen
  Testskripts; THROW-Range 59001–59003/59010 reserviert (kollidiert nicht mit
  Lint-Regel k).
- **T2:** Schritt 4 (Pfad-Repoint) ist Pipeline-Vorbedingung; G4-Scharf-Tests als
  PASS-Nachweis in die Reset-Suite übernehmen; `copy-logins` (read-only test1) für
  SID-genaue Orphan-/Grant-Fälle.
- **T3:** UTC-Zeitbasis (§4.3) → Grace/Staleness nur *relativ* testen; Mail-Versand
  bleibt prod-only, im Container nur Struktur/Operator. **Wartungs-Schedules:** Setup
  setzt `MaintenanceSchedulesEnabled='0'` als Phase-A-Default (Schritt 4b) — für den
  ENABLED-Fall (F3.6) den Key gezielt löschen. T3-Kern läuft ohne Restore; T3-14/15/23
  brauchen die eazybusiness aus Schritt 5.
- **T4:** Compat-Level-Absenkung (§4.4) als Floor-Simulations-Mechanik; die konkrete
  `STRING_SPLIT`-Fehlermatrix gehört zu T4.
