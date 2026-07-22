# Umsetzungsplan: SQL-Server-Wartung als Code (Ola Hallengren in RoboticoOps)

**Status:** Detailed
**Created:** 2026-07-21
**Repo:** JTL-Robotico
**Branch / Worktree:** feature/mssql-ops-infrastruktur (in worktrees/feature/mssql-ops-infrastruktur)
**Complexity:** Small–Medium
**Modular?:** Nein — Detail flach in §3; die Architektur-Entscheidungen liegen in den beiden plan-scoped ADRs
**archive_target:** 2026-07-21 - mssql-wartung-ola

**Zugehörige ADRs (plan-scoped, pending promotion):**
- [adrs/adr-maintenance-as-code-roboticoops.md](adrs/adr-maintenance-as-code-roboticoops.md) — Kern: Ola vendored in RoboticoOps, deklarative Registry `ops.tMaintenanceJob`, `maint.spEnsureMaintenanceJobs`-Sync, ein Job pro Operation, Alarmierung.
- [adrs/adr-backups-cbb-retained.md](adrs/adr-backups-cbb-retained.md) — Backups bleiben bei CBB; kein Ola-Backup; read-only Backup-Ketten-Watchdog.

**Grundlage:** [research/6-wartung-ist-analyse](../2026-07-10 - mssql-ops-infrastruktur/research/6-wartung-ist-analyse/6-wartung-ist-analyse.md) (Live-IST der vm-sql2-Wartung).

Dieser Plan setzt die beiden ADRs um: er ersetzt die kaputte, in `eazybusiness.dbo` verstreute Ola-Installation durch eine versionierte, registry-getriebene Wartungssuite in RoboticoOps, die über die bestehende global-grate-Kette deployt wird. Kein neuer Architektur-Inhalt — der lebt in den ADRs; hier stehen Akzeptanzkriterien, Bausteine, Dateilayout und der Cutover-Ablauf.

## 1. Vision and Motivation

### 1.1 Warum dieser Plan existiert

vm-sql2 hat faktisch **keine** wirksame Wartung: der einzige geplante Job (`IndexOptimize`) schlägt seit ~2025-11-27 nächtlich fehl, CHECKDB lief zuletzt 2024-06-24, und niemand wird alarmiert (Belege: [6-wartung-ist-analyse §2, F1–F9](../2026-07-10 - mssql-ops-infrastruktur/research/6-wartung-ist-analyse/6-wartung-ist-analyse.md)). Ursache sind drei strukturelle Fehler — falscher Ort (Vendor-DB), Klick-Ops (unversioniert), keine Alarmierung. Dieser Plan behebt alle drei über die vorhandene RoboticoOps-Infrastruktur.

### 1.2 Welches Problem das löst

- CHECKDB (alle DBs inkl. `msdb`, ohne tm-Klone) läuft wieder — 2× wöchentlich, jeweils **vor** dem 03:00-Full → Korruption wird innerhalb weniger Tage (vor dem jeweiligen So/Mi-Full) erkannt, statt monatelang unbemerkt in die Aufbewahrungskette zu wandern.
- Statistiken werden endlich gepflegt (`@UpdateStatistics=ALL`).
- Die gesamte Wartungslandschaft ist **eine Tabelle** (`ops.tMaintenanceJob`) — nachvollziehbar und reproduzierbar per `deploy.ps1 -Scope global`.
- Ein still fehlschlagender Job wird sofort gemeldet — und ein still **nicht laufender** Job (das historisch dominante F3/F4-Muster) wird vom Liveness-Check erkannt (D36).

### 1.3 Verworfene Alternativen

Siehe ADR-A §Alternatives (In-place-Reparatur, verstreute Job-Skripte, Config-Keys, Sammel-Job, Ola-`@CreateJobs`, eigene Wartungs-DB) und ADR-B §Alternatives (Backups in Ola konsolidieren, kein Monitoring, tm-Klone mitwachen).

## 2. Acceptance Criteria

1. **Registry existiert:** `ops.tMaintenanceJob` ist nach global-Deploy in RoboticoOps vorhanden und enthält die Soll-Zeilen aus §3.2 (aktuell **6** — die §3.2-Tabelle ist SSoT für Anzahl und Inhalt). Datei-Evidenz: Tabelle in `up/0023`, Zeilen via MERGE in `runAfterOtherAnyTimeScripts/maint.spApplyMaintenance.sql` (B3) — **nicht** im `up/`-Skript (das legt nur die DDL an, s. §3.1-NOTE).
2. **Ola am richtigen Ort:** `IndexOptimize`, `CommandExecute`, `DatabaseIntegrityCheck`, `CommandLog` existieren nach Deploy in **`RoboticoOps.dbo`**; **`RoboticoOps.dbo.DatabaseBackup` existiert NICHT** (der binäre Nachweis der ADR-B-Garantie „nicht vendored = nicht schedulbar"); unsere Kette legt in `eazybusiness` **keine** Ola-Objekte an.
3. **Jobs = Registry:** `maint.spEnsureMaintenanceJobs` erzeugt exakt die registry-deklarierten Agent-Jobs (Namenspräfix `RoboticoOps - Maint - `) — für **jede** Registry-Zeile einen Job, je mit deklariertem Schedule, **konstantem Dispatch-Step** `EXECUTE RoboticoOps.maint.spRunMaintenanceJob @cJobKey = N'<key>';` (D28 — die operationsspezifischen Kommandos leben zur Laufzeit in der Kommando-Matrix von `spRunMaintenanceJob`, §3.2) und `@notify_email_operator` bei `bNotifyOnFail=1`; `bEnabled` + Instanz-Schalter mappen auf den Job-Enabled-Zustand (D34). Jobs nicht in der Registry (mit diesem Präfix) werden entfernt; **das Entfernen einer Soll-Zeile aus dem Seed entfernt beim nächsten Deploy Registry-Zeile UND Job** (MERGE-Delete-Zweig, D30).
4. **Kein Backup-Job:** Es wird **kein** `DatabaseBackup`-Job registriert/erzeugt (ADR-B).
5. **Watchdog funktioniert:** `maint.spCheckBackupChain` alarmiert bei veralteter Kette (Alarm, wenn `letztes_full <= DATEADD(HOUR, -nFullMaxHours, now)` **oder** `letztes_log <= DATEADD(HOUR, -nLogMaxHours, now)` — **Elapsed-Zeit-Cutoff** analog `spCheckMaintenanceLiveness`, NICHT `DATEDIFF(HOUR, …)` — Grenzfall „genau 26 h/1 h" alarmiert also; `DATEDIFF(HOUR)` zählt überschrittene Kalenderstunden-Grenzen statt vergangener Stunden und würde bei der stündlichen Kadenz ein nur Minuten altes, aber in der Vorstunde gelandetes Log-Backup fälschlich als stale melden (L-B1-1); `is_copy_only=0` gefiltert; Log-Check für alle log-basierten Recovery-Modelle, d. h. `recovery_model_desc <> N'SIMPLE'` — deckt FULL **und** BULK_LOGGED ab, D27) und schweigt bei frischer — verifiziert über Schwellen-Test. Altersvergleiche rechnen in **lokaler Serverzeit** (`backupset` speichert lokal, D32); unbekannte, nicht-ONLINE oder per Ola-Token angegebene Watch-Ziele werfen ebenfalls `51100` (Ziel-Validierung, D32 — ein stiller Skip wäre die Watchdog-Variante des F2-Musters). **Kadenz: stündlich** (D35, Anker 00:00) — die Erkennungslatenz einer gerissenen Log-Kette ist damit ≤ ~2 h; eine Tages-Stichprobe hätte die „Log < 1 h"-Zusage real auf bis zu 24 h Latenz gedehnt.
6. **Alarmierung verdrahtet:** Operator `RoboticoOps-Maint` (E-Mail `lukas@dattenberger.com`) existiert; Agent-Mailprofil = `Standard SMTP` (wirksam erst nach Agent-Neustart, s. §3.6 Nr. 4); nach vollständigem Deploy tragen alle `bNotifyOnFail=1`-Jobs die Operator-Verdrahtung (Erst-Deploy-Konvergenz via `260`, s. §3.3).
7. **Idempotenz:** Erneuter global-Deploy ist ein No-op. **Messmechanik (D18, präzisiert D29/D31):** grate überspringt `spApplyMaintenance` (Hash unverändert); das everytime-Skript `260` ruft `maint.spEnsureMaintenanceJobs` **unbedingt** auf (D29) und der Sync meldet **0 Änderungen** (per-Job-Vergleich in kanonischer Normalform, s. §3.2); der value-guarded MERGE (NULL-sicher via `IS DISTINCT FROM`, D30) lässt `dModified` unangetastet.
8. **Doku-Vertrag:** `docs/SQL/MSSQL-OPS-DATA-MODEL.md` dokumentiert jede Spalte von `ops.tMaintenanceJob` (CLAUDE.md ops-Tabellen-Vertrag); Umfang inkl. Kopf/Vertrags-Box s. §3.4.
9. **test1:** Suite deployt sauber; je ein manueller Lauf **aller Ola-/Cleanup-Jobs (alle Registry-Zeilen außer `backup-watchdog`; §3.2 = SSoT für die Anzahl)** erfolgreich; der `backup-watchdog` wird per Logik-Test abgenommen (auf test1 mangels CBB-Kette **erwartet rot**, s. §3.5); **kein** Dauer-Schedule aktiv — erzwungen durch den Instanz-Schalter `ops.tConfig('MaintenanceSchedulesEnabled') = '0'` (Jobs existieren, sind aber disabled; manuelle Läufe via `sp_start_job` funktionieren trotzdem — D34); der Agent bleibt zusätzlich in seiner Stopped-Baseline, taugt aber nicht als Gate (Reset-Arbeit braucht ihn laufend).
10. **Statistikpflege nachweisbar:** Der `index-optimize`-Lauf übergibt real `@UpdateStatistics = 'ALL'` an Ola — nachweisbar am `CommandLog`-Eintrag des B5-Laufs (Ola protokolliert das ausgeführte Kommando inkl. Parametern; der Job-Step selbst ist seit D28 ein konstanter Dispatch und trägt die Parameter nicht mehr). (Der Kernhebel aus F7/F8 darf nicht nur Registry-Input bleiben: der alte defekte Job lief genau ohne diesen Parameter — deshalb erzwingt der CHECK jetzt `bUpdateStatistics IS NOT NULL`, D33.)
11. **Repo-Verträge erfüllt:** Die fünf `maint.*`-Procs und `ops.tMaintenanceJob` (+ Schlüsselspalten) sind in `db-migrations/tests/global/validate_structure.sql` registriert (Lint-Regel (l)); die THROW-Nummern `51100`/`51105`/`51110`/`51120` sind in der README-§4-(k)-Tabelle alloziert (inkl. mitgezogenem Guidance-Satz, s. §3.2-NOTE); `npm run db:lint` ist grün — inkl. der vendorten Ola-Dateien (Vorab-Check, s. §3.1).
12. **Operability-Gate erweitert (D23):** `db-migrations/tests/global/validate_rollout.sql` prüft die Wartung analog zum bestehenden Reset-Job-Block: zu **jeder** Registry-Zeile existiert der passende `RoboticoOps - Maint - `-Agent-Job (D34: der Sync legt auch `bEnabled=0`-Zeilen als disabled Job an), jeder `bNotifyOnFail=1`-Job trägt die Operator-Verdrahtung, und der Operator `RoboticoOps-Maint` existiert. Damit ist Operability auf Prod-Redeploys wiederholbar geprüft, nicht nur per manueller B5-Prüfliste (die Registry-Zeilen sind auf test1 und prod identisch, s. ADR-A §D-A6). **Assertions gemäß D34-Semantik:** je Registry-Zeile (unabhängig von `bEnabled`) existiert der Job; Job-Enabled-Zustand = `bEnabled = 1` UND `ops.tConfig('MaintenanceSchedulesEnabled')` ≠ `'0'` — die Assertion prüft die Gleichung, nicht pauschal „enabled", und ist damit auf test1 (Schalter `'0'`) wie prod (kein Eintrag) grün.
13. **Wartungs-Liveness überwacht (D36):** `maint.spCheckMaintenanceLiveness` (zweiter EXEC im Watchdog-Job-Step, s. §3.2) alarmiert per `THROW 51105`, wenn für eine **effektiv enablte** Registry-Zeile mit `cOperation IN (IntegrityCheck, IndexOptimize)` kein hinreichend frischer `CommandLog`-Eintrag existiert (Soll-Alter aus dem deklarierten Schedule abgeleitet: daily → 26 h, weekly → 8 Tage) — damit ist auch der historische **„läuft nie"-Pfad** (F3/F4: Schedule live getrennt, Job live disabled) selbst überwacht, nicht nur der „läuft und scheitert"-Pfad (F2), den `bNotifyOnFail` abdeckt. Verifiziert per Direkt-`EXEC` auf test1 (B5).

> [!NOTE]
> Die §1.2-Zusage „CHECKDB endet vor dem 03:00-Full" hat bewusst **kein** eigenes AC: sie ist per Startzeit behauptet, nicht erzwungen, und wird beim ersten Prod-Nachtlauf gemessen und abgenommen (B6 Nr. 6, Gap 5) — dort ist ihr benannter Abnahme-Anker.

> [!NOTE]
> Auch die **Kollisionsfreiheit des Cutovers** (Alt-Ola-Jobs/-Objekte entfernt, bevor der Deploy die neuen Jobs aktiv anlegt) hat bewusst kein test1-AC: sie ist Prod-Cutover-Verifikation und wird in B6 Schritt 1 (Inventar-Query + Löschung) und Schritt 5 (Step-/Notify-Verifikation) abgenommen — dort ist ihr benannter Abnahme-Anker (gleiches Muster wie oben).

## 3. Building Blocks

Querschnitt für alle Bausteine: Jede neue Ebene-B-Datei erhält den kompakten Datei-Header + `@see`-Anker (README §3) auf diesen Plan (`docs/plans/2026-07-21 - mssql-wartung-ola`, §3.x) und die jeweils tragende ADR — wie die bestehenden Reset-Dateien.

### §3.1 — B1: Vendor + Schema + Registry (up/)

Neue Einmal-Skripte in `db-migrations/global/up/` (nach 0021):

- `0022_maintenance_ola_vendor.sql` — die **gepinnten Ola-Einzelskripte** (`CommandLog.sql`, `CommandExecute.sql`, `DatabaseIntegrityCheck.sql`, `IndexOptimize.sql`) nach `RoboticoOps.dbo`. Bewusst die Einzeldateien statt der Sammel-`MaintenanceSolution.sql`: die Einzeldateien sind objekte-only und damit wirklich **byte-unverändert** vendorbar (die Sammeldatei müsste am `@CreateJobs`-Header editiert werden — genau der Eingriff, den „unverändert gepinnt" verbietet). Version im Kopfkommentar festhalten; Upgrade = neues `up/`. **`DatabaseBackup.sql` wird absichtlich NICHT vendored** (ADR-B: kein Ola-Backup — was nicht deployt ist, kann auch niemand versehentlich schedulen). **Lint-Vorab-Check (Pflicht, vor dem ersten Apply):** `npm run db:lint` gegen die vendorten Dateien — `up/` ist danach immutable, ein Regelverstoß (a: `USE`, b: `GO;`, h: Datums-Literale) darf nicht erst beim Deploy auffallen. Schlägt eine Regel an, wird eine minimal-invasive, kommentierte Abweichung mit `@see` auf die gepinnte Upstream-Version dokumentiert — dann ist „byte-unverändert" bewusst gebrochen, nicht still. **Bekannte Abweichung von vornherein (FT-13):** Olas Proc-Einzelskripte sind `CREATE OR ALTER` (idempotent), `CommandLog.sql` ist aber ein ungeguardetes `CREATE TABLE` — Kollision mit der Ebene-B-Regel „jedes `up/` ist hand-idempotent" (README §1-NOTE). Auflösung nach demselben Mechanismus: minimal-invasiver, kommentierter `IF OBJECT_ID(N'dbo.CommandLog', N'U') IS NULL`-Wrapper um genau diese eine Datei (bewusster, dokumentierter Byte-Bruch mit `@see` Upstream).
- `0023_maintenance_registry.sql` — idempotentes `CREATE SCHEMA maint AUTHORIZATION dbo` (eigener Batch, wörtlich nach dem Muster `up/0002`); Tabelle `ops.tMaintenanceJob` (DDL unten, `ops.*`-Hungarian-Stil analog `ops.tResetStep`).

```sql
-- maint-Schema: idempotent + AUTHORIZATION dbo (Muster up/0002) — CREATE SCHEMA muss allein
-- im Batch stehen (daher EXEC-Wrapper + eigener GO-Batch), und das unten zugesicherte
-- Ownership-Chaining maint.* -> ops.tMaintenanceJob setzt den gemeinsamen Owner dbo voraus.
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'maint')
    EXEC (N'CREATE SCHEMA maint AUTHORIZATION dbo;');
GO

-- ops.tMaintenanceJob — deklarative Registry: eine Zeile = ein Wartungsjob.
-- maint.spEnsureMaintenanceJobs synchronisiert daraus die SQL-Agent-Jobs.
IF OBJECT_ID(N'ops.tMaintenanceJob', N'U') IS NULL
BEGIN
    CREATE TABLE ops.tMaintenanceJob
    (
        cJobKey        sysname       NOT NULL   -- stabiler Schlüssel: 'checkdb', 'index-optimize', …
            CONSTRAINT PK_tMaintenanceJob PRIMARY KEY,
        cDisplayName   nvarchar(128) NOT NULL,  -- Agent-Jobname, Präfix 'RoboticoOps - Maint - '
        cOperation     nvarchar(20)  NOT NULL,  -- IntegrityCheck | IndexOptimize | Cleanup | BackupWatchdog
        cDatabases     nvarchar(400) NOT NULL,  -- ZWEI Grammatiken je cOperation (Doku in B4): Ola-@Databases-Ausdruck
                                                -- (IntegrityCheck/IndexOptimize/Cleanup) bzw. LITERALE Komma-Liste
                                                -- (BackupWatchdog, s. §3.2 — Ola-Token dort ungültig, Laufzeit-THROW);
                                                -- Werte erreichen Ola zur Laufzeit als echte Proc-Parameter des
                                                -- Dispatchers (D28), nie als Step-Text-Literal
        -- Zeitplan: typisiert statt Cron-String (gleiche Logik wie bei den Stellschrauben — kein Parsen im Sync-Proc;
        -- nur die drei genutzten Muster, Sync mappt 1:1 auf msdb.dbo.sysschedules):
        cFrequency     nvarchar(10)  NOT NULL   -- 'daily' | 'weekly' | 'hourly' (hourly: stündlich ab tStartTime-Anker, D35)
            CONSTRAINT CK_tMaintenanceJob_cFrequency CHECK (cFrequency IN (N'daily', N'weekly', N'hourly')),
        nWeekdayMask   tinyint       NULL       -- nur bei weekly: Bitmaske 1=So,2=Mo,4=Di,8=Mi,16=Do,32=Fr,64=Sa
                                                -- (mehrere Tage ODER-bar, z. B. So+Mi = 9; identisch zu sysschedules.freq_interval)
            CONSTRAINT CK_tMaintenanceJob_nWeekdayMask CHECK (nWeekdayMask BETWEEN 1 AND 127),
        tStartTime     time(0)       NOT NULL,  -- lokale Serverzeit; bei 'hourly' der Tagesanker des ersten Laufs
                                                -- (Watchdog: 00:00 -> stündlich rund um die Uhr)
        -- operationsspezifische Stellschrauben (NULL, wenn n/a) — typisiert + CHECK-validiert statt Freitext:
        bUpdateStatistics bit          NULL,    -- IndexOptimize (Pflicht dort, s. OperationKnobs-CHECK):
                                                -- 1 -> @UpdateStatistics='ALL', 0 -> Parameter entfällt (bewusster Ausnahmefall)
        cCleanupTarget    nvarchar(20) NULL     -- Cleanup: Ziel-Log
            CONSTRAINT CK_tMaintenanceJob_cCleanupTarget
                CHECK (cCleanupTarget IN (N'CommandLog', N'BackupHistory', N'JobHistory')),
        nRetentionDays    int          NULL     -- Cleanup: Aufbewahrung (Tage)
            CONSTRAINT CK_tMaintenanceJob_nRetentionDays CHECK (nRetentionDays > 0),
        nFullMaxHours     int          NULL     -- BackupWatchdog: max. Alter letztes Full (h)
            CONSTRAINT CK_tMaintenanceJob_nFullMaxHours  CHECK (nFullMaxHours > 0),
        nLogMaxHours      int          NULL     -- BackupWatchdog: max. Alter letztes Log (h)
            CONSTRAINT CK_tMaintenanceJob_nLogMaxHours   CHECK (nLogMaxHours > 0),
        bEnabled       bit           NOT NULL
            CONSTRAINT DF_tMaintenanceJob_bEnabled DEFAULT (1),
        bNotifyOnFail  bit           NOT NULL
            CONSTRAINT DF_tMaintenanceJob_bNotifyOnFail DEFAULT (1),
        cNotes         nvarchar(400) NULL,
        dCreated       datetime2(0)  NOT NULL
            CONSTRAINT DF_tMaintenanceJob_dCreated  DEFAULT (SYSUTCDATETIME()),
        dModified      datetime2(0)  NOT NULL
            CONSTRAINT DF_tMaintenanceJob_dModified DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT UQ_tMaintenanceJob_cDisplayName UNIQUE (cDisplayName),
        -- Anlegen UND Entfernen hängen am Namenspräfix — eine präfixlose Zeile erzeugte einen
        -- Geisterjob außerhalb des verwalteten Fensters (D33; Vorbild: CK_tResetStep_cProcName):
        CONSTRAINT CK_tMaintenanceJob_cDisplayName
            CHECK (cDisplayName LIKE N'RoboticoOps - Maint - _%'),
        CONSTRAINT CK_tMaintenanceJob_cOperation
            CHECK (cOperation IN (N'IntegrityCheck', N'IndexOptimize', N'Cleanup', N'BackupWatchdog')),
        -- weekly braucht einen Wochentag, daily/hourly verbieten ihn:
        CONSTRAINT CK_tMaintenanceJob_Schedule CHECK (
               (cFrequency IN (N'daily', N'hourly') AND nWeekdayMask IS NULL)
            OR (cFrequency = N'weekly' AND nWeekdayMask IS NOT NULL)
        ),
        -- jede Operation trägt ihre Pflicht-Stellschrauben UND lässt fremde leer → die Registry ist selbst-validierend:
        CONSTRAINT CK_tMaintenanceJob_OperationKnobs CHECK (
               (cOperation = N'IntegrityCheck' AND bUpdateStatistics IS NULL AND cCleanupTarget IS NULL
                    AND nRetentionDays IS NULL AND nFullMaxHours IS NULL AND nLogMaxHours IS NULL)
            OR (cOperation = N'IndexOptimize'  AND bUpdateStatistics IS NOT NULL  -- Pflicht-Knob (D33):
                    -- NULL wäre "Sync entscheidet" — die naheliegende Lesart "Parameter weglassen"
                    -- reproduzierte exakt F8 (IndexOptimize ohne Statistikpflege)
                    AND cCleanupTarget IS NULL AND nRetentionDays IS NULL
                    AND nFullMaxHours IS NULL AND nLogMaxHours IS NULL)
            OR (cOperation = N'Cleanup'        AND cCleanupTarget IS NOT NULL AND nRetentionDays IS NOT NULL
                    AND bUpdateStatistics IS NULL AND nFullMaxHours IS NULL AND nLogMaxHours IS NULL)
            OR (cOperation = N'BackupWatchdog' AND nFullMaxHours IS NOT NULL AND nLogMaxHours IS NOT NULL
                    AND bUpdateStatistics IS NULL AND cCleanupTarget IS NULL AND nRetentionDays IS NULL)
        )
    );

    -- Registry ist repo-owned (D11/D19): Live-Schreibzugriffe würden beim nächsten Deploy
    -- vom MERGE überschrieben — daher nur SELECT für ops_admin (bewusste Abweichung von den
    -- übrigen ops.*-Tabellen, deren Write-Grants echtes Admin-Tuning tragen).
    -- Der sa-owned Agent-Job erreicht die Tabelle über Ownership-Chaining (maint/ops: AUTHORIZATION dbo).
    GRANT SELECT ON ops.tMaintenanceJob TO ops_admin;
END
GO
```

> [!NOTE]
> DDL der Tabelle ist einmalig (`up/`, immutable). Die **Soll-Zeilen** werden nicht hier fest verdrahtet, sondern in B3 per MERGE reconciled (Repo bleibt SSoT, Schedule-Änderungen brechen nicht die grate-Hashkette).

> [!NOTE]
> **Bewusster Trade-off — eine `cDatabases`-Spalte mit zwei Grammatiken:** Die Spalte trägt je nach `cOperation` einen Ola-`@Databases`-Ausdruck oder eine literale Komma-Liste (Watchdog) — die einzige Stelle, an der die Grammatik per Doku statt per CHECK erzwungen wird (alle Knob-Spalten sind schema-validiert). Ein Split in zwei Spalten (`cOlaDatabases`/`cWatchdogDatabases` + CHECK-Erweiterung) wurde erwogen und bei aktuell 6 repo-owned Zeilen als nicht lohnend verworfen; stattdessen validiert der Watchdog seine Ziel-Liste zur Laufzeit selbst (`TRIM` + `THROW 51100` bei unbekanntem/nicht-ONLINE Ziel, s. §3.2/D32). Wächst die Registry oder kommt eine dritte Grammatik, ist der Spalten-Split die vorgesehene Eskalation.

### §3.2 — B2: Sync-Prozeduren (anytime)

`db-migrations/global/sprocs/` (`CREATE OR ALTER`, RoboticoEKL-Hungarian):

- `maint.spEnsureMaintenanceJobs.sql` — liest `ops.tMaintenanceJob`, **synchronisiert** die Agent-Jobs (anlegen/aktualisieren/entfernen per Namenspräfix), sa-owned. Jeder Job erhält den **konstanten Dispatch-Step** `EXECUTE RoboticoOps.maint.spRunMaintenanceJob @cJobKey = N'<key>';` (voll qualifiziert — ADR-A-Failure-Mode „wrong DB context"/F2; einzige Sync-Zeit-Substitution ist das `cJobKey`-Literal, D28) und den Schedule aus `cFrequency`/`nWeekdayMask`/`tStartTime` gemäß der **Schedule-Mapping-Tabelle** (unten, D31). Der Job existiert für **jede** Registry-Zeile; `bEnabled` + Instanz-Schalter (D34, NOTE unten) mappen auf den Job-Enabled-Zustand — pausieren = disablen, nie löschen (Historie bleibt, Pause in SSMS sichtbar). **Sync-Mechanik (D17/D18, präzisiert D29/D31) — Muster `reset.spEnsureAgentJob`, aber an drei Stellen bewusst anders:**
  - **Per-Job-Vergleich statt Pauschal-Drop — in kanonischer Normalform (D31):** fehlt ein Job → anlegen; weicht die Soll-Definition ab → Drop/Recreate genau dieses Jobs (`sp_delete_job … @delete_unused_schedule = 1`, sonst akkumulieren verwaiste Schedules in msdb); sonst No-op. Die Vergleichsfläche ist eine **geschlossene Liste**: Job (`enabled`, `notify_level_email`, `notify_email_operator`), Step (Kommando-Text — seit D28 konstant —, `database_name`, `subsystem`), Schedule (`freq_type`, `freq_interval`, `freq_recurrence_factor`, `freq_subday_type`, `freq_subday_interval` (D35), `active_start_time`, `enabled`). Alle Spaltenvergleiche NULL-sicher via `IS DISTINCT FROM` (D30); Registry-Werte werden VOR dem Vergleich in die msdb-Repräsentation konvertiert (Mapping-Tabelle) — jede Facette außerhalb der Liste wäre unsichtbarer Drift, jeder unnormalisierte Vergleich (z. B. `time(0)` gegen int-HHMMSS) ein Dauer-Drop/Recreate mit dauerhaft rotem AC7. So meldet der Proc „0 Änderungen" (AC7-Messpunkt) und ist von `260` bei jedem Deploy gefahrlos aufrufbar. **Bewusst akzeptiert:** ein gewollter Drop/Recreate kostet die Agent-Job-Historie genau dieses Jobs.
  - **Running-Job-Guard:** konzeptionell wie beim Vorbild, mechanisch anders — dort applikationsseitig (`ops.tResetRequest`), hier je Job gegen `msdb.dbo.sysjobactivity`, **gescoped auf die aktuelle Agent-Session** (`session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions)`, D31 — ohne das Scoping gälte ein Job nach Agent-Stopp/-Crash mit offener `stop_execution_date IS NULL`-Zeile für immer als „läuft"; auf test1 wird der Agent planmäßig gestartet/gestoppt, der False-Positive wäre dort Betriebsnormalität; bei gestopptem Agent läuft nichts): ein gerade laufender Job wird **übersprungen und gemeldet**, kein globales THROW (ein laufender Nacht-CHECKDB darf weder gedroppt werden noch den Deploy abbrechen). Ein Skip **konvergiert beim nächsten Deploy**, weil `260` den Sync unbedingt aufruft (D29).
  - **Operator-EXISTS-Guard:** `@notify_email_operator` wird nur verdrahtet, wenn der Operator in `msdb.dbo.sysoperators` existiert (sonst `NULL`, exakt wie `reset.spEnsureAgentJob`) — der Deploy schlägt nie an einem fehlenden Operator fehl; die Erst-Deploy-Konvergenz übernimmt `260` (§3.3).
  > [!IMPORTANT]
  > **Sicherheitsregel (Fix A — aufgelöst per Runtime-Dispatch, D28):** Ein persistierter Agent-Job-Step ist ein statischer T-SQL-String in `msdb.dbo.sysjobsteps` — Registry-Werte in Step-Texte einzubetten hieße zwangsläufig konkatenieren (die ursprüngliche Regel-Formulierung „nur `sp_executesql`-Parameter" war dafür unimplementierbar, FT-1). Deshalb werden die Werte gar nicht erst in Steps gerendert: der Step ist **konstant**, und `maint.spRunMaintenanceJob` liest die Registry-Zeile **zur Laufzeit** und übergibt `cDatabases` + Stellschrauben als **echte T-SQL-Parameter** an die Ola-/System-Prozeduren — ganz ohne dynamisches SQL. Daten werden nie zu Code; die Regel gilt damit wörtlich (gleiche Logik wie die Whitelist in `ops.tResetStep`, und dasselbe Muster wie der parameterlose Reset-Step `EXEC reset.spProcessNextResetRequest`). Einzige Sync-Zeit-Substitution ist das `cJobKey`-Literal im Dispatch-Aufruf — quote-verdoppelt eingebettet (`REPLACE(@cJobKey, N'''', N'''''')`), obwohl repo-owned (Belt-and-Braces, Lint-Regel (g)). *Aktiv verworfen (FT-1-Alternative a):* die Regel nur zu re-scopen („escapte Literale beim Step-Bau erlaubt") hätte Parameter-tragende, driftanfällige Step-Texte behalten und den Frozen-Date-/Vergleichs-Problemen (FT-3, FT-7) nur kuriert statt sie strukturell zu beseitigen.

  **Schedule-Mapping (D31)** — Registry → `msdb.dbo.sysschedules`, inklusive der Pflichtwerte, ohne die `sp_add_jobschedule` fehlschlägt bzw. der Normalform-Vergleich nie konvergiert:

  | Registry | `sysschedules` |
  |---|---|
  | `cFrequency = 'daily'` | `freq_type = 4`, `freq_interval = 1` (Pflicht ≥ 1), `freq_subday_type = 1` (einmal zur Startzeit), `freq_subday_interval = 0` |
  | `cFrequency = 'weekly'` | `freq_type = 8`, `freq_interval = nWeekdayMask`, **`freq_recurrence_factor = 1`** (Pflicht ≥ 1 — weggelassen wirft `sp_add_jobschedule` Fehler 14266, der Erst-Deploy der weekly-Jobs scheitert), `freq_subday_type = 1`, `freq_subday_interval = 0` |
  | `cFrequency = 'hourly'` (D35) | `freq_type = 4`, `freq_interval = 1`, **`freq_subday_type = 8`, `freq_subday_interval = 1`** (stündlich ab `active_start_time` bis Tagesende; Anker 00:00 → rund um die Uhr) |
  | `tStartTime` | `active_start_time = DATEPART(HOUR, …) * 10000 + DATEPART(MINUTE, …) * 100 + DATEPART(SECOND, …)` (int HHMMSS) |

  Die Subday-Spalten gehören seit D35 zur D31-Vergleichsfläche (additive Erweiterung der kanonischen Normalform — genau der Erweiterungspfad, für den die Tabelle gebaut wurde).

- `maint.spRunMaintenanceJob.sql` — **Laufzeit-Dispatcher (D28, vierter `maint.*`-Proc):** nimmt `@cJobKey`, liest die Registry-Zeile (unbekannter Key → `THROW 51120`) und führt die Operation gemäß der **Kommando-Matrix** aus — der Kommando-Bau hat genau eine Heimat, einen kommentierten `CASE`-Block in diesem Proc. Cleanup-Cutoffs werden **zur Laufzeit** berechnet (`DATEADD(DAY, -@nRetentionDays, SYSDATETIME())` aus der Registry-Spalte — nie ein zur Sync-Zeit eingefrorenes Datum, das den Cleanup über die Jahre still zum No-op verkommen ließe); `bUpdateStatistics` wird konsumiert (`1 → @UpdateStatistics = 'ALL'`, `0 →` Parameter entfällt, D33). Registry-Änderungen an Scope/Stellschrauben wirken damit **sofort nach dem MERGE**, ohne Job-Drop/Recreate — nur Schedule-/Notify-/Namens-Änderungen berühren msdb.

  | Operation (+Target) | Laufzeit-Kommando in `spRunMaintenanceJob` |
  |---|---|
  | `IntegrityCheck` | `EXECUTE RoboticoOps.dbo.DatabaseIntegrityCheck @Databases = @cDatabases, @LogToTable = 'Y'` |
  | `IndexOptimize` | `EXECUTE RoboticoOps.dbo.IndexOptimize @Databases = @cDatabases, @UpdateStatistics = <Mapping D33>, @FragmentationHigh = … (REORGANIZE-only, s. NOTE), @LogToTable = 'Y'` |
  | `Cleanup` + `CommandLog` | `DELETE RoboticoOps.dbo.CommandLog WHERE StartTime < DATEADD(DAY, -@nRetentionDays, SYSDATETIME())` (kein Ola-Proc) |
  | `Cleanup` + `BackupHistory` | `DECLARE @cutoff datetime = DATEADD(DAY, -@nRetentionDays, SYSDATETIME()); EXECUTE msdb.dbo.sp_delete_backuphistory @oldest_date = @cutoff` |
  | `Cleanup` + `JobHistory` | analog: `EXECUTE msdb.dbo.sp_purge_jobhistory @oldest_date = @cutoff` |
  | `BackupWatchdog` | `EXECUTE RoboticoOps.maint.spCheckBackupChain @Databases = @cDatabases, @FullMaxHours = @nFullMaxHours, @LogMaxHours = @nLogMaxHours;` danach `EXECUTE RoboticoOps.maint.spCheckMaintenanceLiveness;` (D36 — ein THROW des ersten Checks beendet den Step: ein Alarm pro Lauf, der nächste stündliche Lauf meldet den Rest) |

  > [!NOTE]
  > Eine **neue Operationsart** ist bewusst **kein** „nur eine Registry-Zeile": neuer `CK_…_cOperation`-Wert, ggf. neue Knob-Spalten (neues `up/`), neuer `CASE`-Zweig in `spRunMaintenanceJob`, Doku-Zeilen (B4). „Zeile ergänzen" gilt für neue Instanzen **bestehender** Operationsarten. Das Rezept dafür steht im Header von `spRunMaintenanceJob` (analog README §9 für Reset-Steps).

> [!NOTE]
> **Instanz-Schalter `ops.tConfig('MaintenanceSchedulesEnabled')` (D34):** effektiver Job-Enabled-Zustand = `bEnabled = 1` UND Schalter ≠ `'0'` (fehlender Key = enabled — prod braucht keinen Eintrag). test1 setzt `'0'`: die Jobs existieren dort vollständig (Struktur- und Rollout-Gate greifen), sind aber disabled — **`sp_start_job` startet auch disabled Jobs**, die manuelle B5-Validierung funktioniert unverändert. Damit ist „kein Dauer-Schedule auf test1" (AC9, ADR-A §D-A6) **erzwungen statt behauptet**: der test1-Agent MUSS für Reset-Arbeit laufen (Reset via `sp_start_job`, s. `reset.spPub_StartTestmandantReset`), der Dienststatus taugt also nicht als Gate — sonst feuerte jede über Nacht laufende Reset-Session die volle Prod-Wartung inkl. täglich rotem Watchdog auf test1 (Alarm-Abstumpfung, exakt der ADR-B-Anti-Goal). Der Schalter ist admin-owned Instanz-**Zustand** wie `AgentJobName`/`NotifyOperator` (README §7-Tabelle); die Registry-Zeilen bleiben auf allen Instanzen identisch (D-A6).
- `maint.spCheckBackupChain.sql` — read-only Frische-Check über `msdb.dbo.backupset` (Filter `is_copy_only=0` für Full), Schwellen als Proc-Parameter vom Dispatcher (`nFullMaxHours`/`nLogMaxHours`). **Zeitbasis lokal (D32):** `backupset.backup_finish_date` ist **lokale Serverzeit** — Altersvergleiche rechnen mit `SYSDATETIME()`, NIE `SYSUTCDATETIME()` (bei CEST/UTC+2 weitete der UTC-Griff die 1-h-Log-Schwelle real auf ~3 h; als Gotcha-Kommentar in den Proc-Header, gerade WEIL das übrige Design durchgängig `SYSUTCDATETIME()` verwendet). Interpretiert `cDatabases` als **literale Komma-Liste** (`STRING_SPLIT`; Recovery-Modell je DB aus `sys.databases`) — Ola-Sammel-Token wie `USER_DATABASES` sind für Watchdog-Zeilen **ungültig**. **Ziel-Validierung (D32):** Tokens werden `TRIM()`t; jedes Token ohne ONLINE-Match in `sys.databases` (Tippfehler, Leerzeichen-Rest, OFFLINE/RESTORING-DB, versehentliches Ola-Token) → `THROW 51100` mit dem Token im Fehlertext — ein unbekanntes Watch-Ziel ist ein **Alarm, kein stiller Skip** (sonst wäre eine unbewachte Produktions-DB von einem grünen Job nicht unterscheidbar — die Watchdog-Variante des F2-Musters). Doku in B4 + Proc-Header. **Log-Frische wird für alle log-basierten Recovery-Modelle geprüft** — Filter `recovery_model_desc <> N'SIMPLE'`, deckt FULL **und** BULK_LOGGED ab (D27; SIMPLE-DBs haben konstruktionsbedingt keine Log-Kette → sonst Dauer-Fehlalarm). Schwellen-Semantik: Alarm bei `Alter >= Schwelle` (Grenzfall alarmiert, s. AC5). „Alarmieren" = der Job-Step wirft bei veralteter Kette **`THROW 51100`** → Job schlägt fehl → `NotifyOperator`-Mail (derselbe Meldeweg wie bei allen Wartungsjobs).
- `maint.spCheckMaintenanceLiveness.sql` — **Wartungs-Liveness-Check (D36, fünfter `maint.*`-Proc, parameterlos):** `bNotifyOnFail` fängt nur Jobs, die **laufen und scheitern** (F2) — der historisch dominante Schaden war aber das **„läuft nie"-Muster** (F3/F4: 2 Jahre kein CHECKDB bei existierenden Jobs), und das bleibt für Notify unsichtbar (Schedule live getrennt, Job live disabled; der `260`-Self-Heal greift erst beim nächsten Deploy, der Wochen entfernt sein kann). Der Proc schließt die Lücke **selbst-konfigurierend aus der Registry**: für jede effektiv enablte Zeile (`bEnabled = 1` UND Instanz-Schalter ≠ `'0'`, D34 — auf test1 damit konstruktionsbedingt No-op) mit `cOperation IN (N'IntegrityCheck', N'IndexOptimize')` leitet er das maximal zulässige Alter des jüngsten passenden `dbo.CommandLog`-Eintrags aus dem deklarierten Schedule ab (`daily` → 26 h, `weekly` → 8 Tage; `CommandType`-Mapping: IntegrityCheck → `DBCC_CHECKDB`, IndexOptimize → `ALTER_INDEX`/`UPDATE_STATISTICS` — letzteres loggt bei `@UpdateStatistics='ALL'` mit Ola-Default `@OnlyModifiedStatistics='N'` in jedem Lauf) und wirft sonst **`THROW 51105`** mit den stalen `cJobKey`s im Fehlertext. Cleanups sind bewusst ausgenommen (loggen nicht nach CommandLog; Ausfall-Folge unkritisch), der Watchdog überwacht sich über seinen eigenen Meldeweg. `CommandLog.StartTime` ist **lokale Zeit** (Ola loggt `GETDATE()`) — gleiche `SYSDATETIME()`-Zeitbasis wie D32, gleicher Gotcha-Kommentar. **Rest-Blindfleck bewusst:** ein gestoppter Agent-Dienst verstummt mitsamt Watchdog — aus Agent-Jobs heraus prinzipbedingt nicht selbst überwachbar; als ADR-A-Failure-Mode dokumentiert und dem externen Monitoring-Folge-Task (Gap 2) zugeschlagen.

> [!NOTE]
> **THROW-Allokation (Lint-Regel (k), D21 + D28 + D36):** `51100` = `spCheckBackupChain` (stale-chain UND ungültiges Watch-Ziel, D32), `51105` = `spCheckMaintenanceLiveness` (stale Wartung, D36), `51110` = `spEnsureMaintenanceJobs` (Guard-/Fehlerpfad, reserviert), `51120` = `spRunMaintenanceJob` (unbekannter `cJobKey`). Alle im selben Commit in die README-§4-(k)-Tabelle eintragen ([EDIT] `db-migrations/README.md`) — und dabei den (k)-Guidance-Satz „New steps take the next free `510x0` block" **mitziehen** (FT-14): der nächste freie Block nach der Reset-Allokation (bis `51094`) wäre sonst exakt `51100`; neue Fassung: `51100–51129` sind maint-reserviert, neue Reset-Steps starten ab `51130`. Ebenso im selben Commit: die fünf `maint.*`-Procs (Typ `P`) + `ops.tMaintenanceJob` (Typ `U`, inkl. Schlüsselspalten) in `db-migrations/tests/global/validate_structure.sql` registrieren (Lint-Regel (l), [EDIT]) — sonst scheitert der Lint bzw. entgeht der Proc dem Rollout-Gate.

> [!NOTE]
> **IndexOptimize auf Standard Edition: REORGANIZE-only.** Der Sync übergibt `@FragmentationHigh` ohne `INDEX_REBUILD_OFFLINE`-Aktion: Standard Edition kann nicht ONLINE rebuilden, und ein Offline-Rebuild um 02:00 würde Tabellen eines 24/7-ERP sperren. Bei aktuell 0 Indizes >30 % ([6-wartung-ist-analyse F7](../2026-07-10 - mssql-ops-infrastruktur/research/6-wartung-ist-analyse/6-wartung-ist-analyse.md)) kostet der Verzicht nichts; sollte je ein Index dauerhaft >30 % bleiben, ist ein manueller Rebuild im Wartungsfenster der bewusste Ausnahmefall.

Soll-Registry (Seed-Ziel für B3, materialisiert die ADR-A-§D-A4-Matrix):

| `cJobKey` | `cOperation` | `cDatabases` | Stellschrauben (typisierte Spalten) | Zeitplan (`cFrequency`/`nWeekdayMask`/`tStartTime`) |
|---|---|---|---|---|
| `checkdb` | IntegrityCheck | `ALL_DATABASES, -eazybusiness_tm%` | — | weekly **So+Mi** (Maske 9) 01:00 |
| `index-optimize` | IndexOptimize | `USER_DATABASES` | `bUpdateStatistics=1` | daily 02:00 |
| `cleanup-commandlog` | Cleanup | `RoboticoOps` | `cCleanupTarget=CommandLog, nRetentionDays=365` | weekly So 00:30 |
| `cleanup-backuphistory` | Cleanup | `msdb` | `cCleanupTarget=BackupHistory, nRetentionDays=365` | weekly So 00:35 |
| `cleanup-jobhistory` | Cleanup | `msdb` | `cCleanupTarget=JobHistory, nRetentionDays=365` | weekly So 00:40 |
| `backup-watchdog` | BackupWatchdog | `eazybusiness,RoboticoOps,msdb` | `nFullMaxHours=26, nLogMaxHours=1` | **hourly** (Anker 00:00, D35) |

**CHECKDB-Zuschnitt (Lukas, 2026-07-21):** 2× wöchentlich (So+Mi, jeweils vor dem 03:00-Full) über **einen** Job mit `ALL_DATABASES, -eazybusiness_tm%` — Olas Exclusion-Syntax erfasst User- **und** System-DBs (inkl. `msdb`) in einem Lauf und nimmt die tm-Klone aus: das sind Wegwerf-Kopien, die per Reset regelmäßig frisch aus der integritätsgeprüften Quelle entstehen — sie mitzuprüfen wäre reiner Mehraufwand. Der frühere System/User-Split entfällt (ein Job weniger). **IndexOptimize behält dagegen die tm-Klone** (dort wird interaktiv gearbeitet → Defrag + frische Statistiken erwünscht).

> [!NOTE]
> **Keine Job-Output-Dateien** (bewusst): der Sync-Proc setzt kein `@output_file_name` an den Job-Steps — die Historie liegt vollständig in `dbo.CommandLog` (`@LogToTable='Y'`) + der Agent-Job-Historie. Damit entfallen der `OutputFiles`-Cleanup, der einzige Dateisystem-Sonderfall und jede CmdExec-Abhängigkeit.

### §3.3 — B3: Reconcile + Ensure + Alerting (everytime / runAfter)

- `db-migrations/global/runAfterOtherAnyTimeScripts/maint.spApplyMaintenance.sql` — self-executing Wrapper (Muster `reset.spEnsureAgentJob`): (a) **value-guarded MERGE** der Soll-Zeilen aus §3.2 in `ops.tMaintenanceJob` — `WHEN MATCHED AND (mindestens eine Soll-Spalte weicht ab) THEN UPDATE` und setzt dann explizit `dModified = SYSUTCDATETIME()` mit (SQL Server hat keinen ON-UPDATE-Default); der Spaltenvergleich im Guard ist **NULL-sicher via `IS DISTINCT FROM`** (D30 — sechs Soll-Spalten sind NULLable, mit `<>` würde jede reine NULL↔Wert-Änderung still verschluckt: Deploy meldet No-op, git und Live-Stand divergieren); unveränderte Zeilen werden **nicht** angefasst → kein `dModified`-Churn, echtes No-op für AC7, und `dModified` bleibt als Audit-Signal brauchbar. Zusätzlich **`WHEN NOT MATCHED BY SOURCE THEN DELETE`** (D30): aus dem Seed entfernte Zeilen verschwinden aus der Live-Registry, und der nachfolgende Ensure entfernt den zugehörigen Job im selben Deploy — ohne den Delete-Zweig gälte D11 („Repo ist SSoT") nur für Updates, nie für Löschungen, und der AC3-Entfernungspfad griffe nie (die Zeile bliebe ja Soll). Gefahrlos, weil die Registry vollständig repo-owned ist — es gibt keine schützenswerten Fremd-Zeilen (genau die B12-Abgrenzung). — (b) `EXEC maint.spEnsureMaintenanceJobs`. Läuft in grates letzter anytime-Stufe, nachdem alle Sprocs existieren — aber **vor `permissions/`**: die Operator-Verdrahtung des Erst-Deploys zieht deshalb `260` nach (unten).

> [!IMPORTANT]
> **Die Wartungs-Registry ist repo-owned — bewusste Abweichung von `ops.tResetStep`.** Der MERGE setzt bei jedem Deploy **alle** Soll-Spalten durch (auch `bEnabled`, Zeiten, Schwellen): Live-Änderungen an der Tabelle werden beim nächsten Deploy überschrieben. Wartungs-Tuning geht **ausschließlich über git + Deploy** — das ist hier gewollt (volle Nachvollziehbarkeit war die Anforderung), während `ops.tResetStep` Admin-Tuning bewusst gewinnen lässt (Seed nur insert-neu, QG3 B12). Der Unterschied ist im Proc-Header dokumentiert. **Warum MERGE, obwohl `up/0021` bewusst row-by-row seedet (QG3 B12)?** Die B12-Kollision entstand aus Live-Umsortierung admin-owned Zeilen unter einem UNIQUE-Constraint; diese Registry ist repo-owned mit stabilen Schlüsseln (`cJobKey`, `cDisplayName`) und ohne Admin-Umordnung — die Kollisionslage existiert hier nicht. Diese Begründung gehört ebenfalls in den Proc-Header (bewusste, dokumentierte Abweichung von der 0021-Entscheidung).
- `db-migrations/global/permissions/260_maintenance_operator.sql` — everytime, idempotent, **drei Aufgaben in einem Skript** (D17, Aufgabe 3 präzisiert durch D29; Präfix `260` ordnet sich nach `250_jobstartuser_mapping` und vor `900_resign` ein). Hintergrund: grate führt `permissions/` **nach** `runAfterOtherAnyTimeScripts/` aus — beim Erst-Deploy existiert der Operator noch nicht, wenn der Sync läuft, und weil der Sync hash-gegated ist, würde die Notify-Verdrahtung ohne dieses Skript auf einem sauberen Redeploy **nie** nachgezogen (QG-Critical SEC-3-1):
  1. Operator `RoboticoOps-Maint` (E-Mail `lukas@dattenberger.com`) anlegen, falls fehlend. **Bewusste Abweichung vom Reset-Muster (im `260`-Header dokumentieren):** die Reset-Infra externalisiert ihren Operator in `ops.tConfig('NotifyOperator')` (instanz-tunbar); die Wartung kodiert Name + Empfänger hart im committeten Skript — konsistent mit der repo-owned-Haltung der gesamten Wartungs-Registry (Empfänger-Änderung = git + Deploy, gleiche Nachvollziehbarkeit wie jedes andere Tuning). Kein Versehen, sondern dieselbe D11-Logik. *(Entschieden in R2, D34: die Operator-E-Mail bleibt hart kodiert, obwohl der `ops.tConfig`-Schalter `MaintenanceSchedulesEnabled` nun existiert — der Schalter trägt Instanz-**Zustand** (wie `AgentJobName`), die Operator-Identität ist repo-owned **Policy**; kein Nachzug in `ops.tConfig`.)*
  2. Agent-Mailprofil `Standard SMTP` setzen (nur wenn nicht gesetzt; kein Neustart erzwingen) — und **nur, wenn das Profil in `msdb.dbo.sysmail_profile` existiert** (FT-16): sonst deutlicher PRINT-Hinweis statt Schreiben eines Phantom-Profilnamens, den der „nur wenn nicht gesetzt"-Guard anschließend zementieren würde (auf test1 ist Database Mail ggf. nicht konfiguriert; kein THROW — gleiche Philosophie wie der Operator-EXISTS-Guard). **Gotcha:** die Profil-Zuweisung wird erst nach einem **Agent-Neustart** wirksam — das Skript druckt in dem Fall einen deutlichen Hinweis; der Neustart selbst ist Cutover-Runbook-Schritt (§3.6 Nr. 4), nie Deploy-Nebenwirkung.
  3. **Unbedingter Ensure-Aufruf + everytime-Self-Heal (D29 — ersetzt den bedingten Re-Trigger; weitergedachtes Muster `permissions/200_ensure_agent_job.sql`):** `EXEC maint.spEnsureMaintenanceJobs` läuft bei **jedem** Deploy. Eine Trigger-Vorbedingung („Job fehlt / Notify fehlt") würde das Nachhol-Loch wieder öffnen: Hash-Gating + Skip-and-Report + bedingter Trigger hieße, dass eine bei laufendem Job übersprungene Definitions-Änderung NIE appliziert würde (grate ruft `spApplyMaintenance` nur bei Hash-Änderung, und Definitions-Drift wäre keine Trigger-Bedingung — git und Live-Stand divergierten still bei grünem Deploy). Der per-Job-Vergleich (D31) macht den unbedingten Aufruf im gesunden Zustand ohnehin zum No-op — die Bedingung war eine Optimierung ohne Ersparnis, aber mit Lücke. Das (a) zieht beim Erst-Deploy die Notify-Verdrahtung nach der Operator-Anlage nach (Konvergenz für AC6), (b) heilt bei jedem Deploy manuell gelöschte Jobs bzw. ein restauriertes `msdb` — dieselbe Selbstheilungs-Garantie, die die Reset-Infra mit dem 200er bewusst eingezogen hat —, und (c) appliziert jeden zuvor gemeldeten Running-Skip beim nächsten Deploy. Kein Drop/Recreate pro Deploy (Normalform-Vergleich), ein laufender Job wird nie angefasst (Guards s. §3.2).

### §3.4 — B4: Doku-Verträge (Datenmodell + Naming-SSoT)

Mehr als „eine Spalten-Sektion anhängen" — drei Stellen in `docs/SQL/MSSQL-OPS-DATA-MODEL.md` [EDIT] plus die Naming-SSoT:

- **Kopf:** „four registry tables" → „five"; Scope-Formulierung um die Wartungs-Infrastruktur erweitern (die Tabelle gehört zur Wartung, nicht zum Test-Mandant-Reset).
- **`[!IMPORTANT]`-Wartungsvertrags-Box:** `up/0023_maintenance_registry.sql` ergänzen (die Box listet bislang nur `0002`/`0021` — ohne Ergänzung greift der Same-Commit-Vertrag für die neue Tabelle formal ins Leere). Optional zur Parität: die CLAUDE.md-Vertragsliste um `0023` ergänzen (generisch durch „any future `up/` script" abgedeckt).
- **Neue Spalten-Sektion `ops.tMaintenanceJob`** (jede Spalte; inkl. der **Doppel-Grammatik von `cDatabases`**, s. §3.1/§3.2).
- **`docs/SQL/NAMING-CONVENTIONS.md` [EDIT]:** (a) §„schemas we own" um eine `maint.*`-Zeile erweitern (drittes eigenes Schema: `maint.spEnsureMaintenanceJobs`, `maint.spRunMaintenanceJob`, `maint.spCheckBackupChain`, `maint.spCheckMaintenanceLiveness`, `maint.spApplyMaintenance`); (b) Typ-Präfix **`t` = `time`-Spalte** als dokumentierte Mikro-Konvention aufnehmen (D20 — bewusste Zweitbelegung des Buchstabens neben dem Tabellen-Präfix `t<Singular>`, damit `tStartTime` nicht als Tippfehler gelesen wird; s. ADR-A §D-A2).
- **`docs/SQL/MSSQL-OPS-ARCHITECTURE.md` [EDIT] (D25):** Die Architektur-Doku ist die deklarierte SSoT der Standing Operating Rules (§6) und wird durch dieses Paket faktisch falsch — sie sagt wörtlich „holds two schemas (ops, reset)" und führt ein Ebene-B-Datei-Inventar. Bestands-Update (kein neuer Architektur-Inhalt — der lebt in den ADRs): (a) „two schemas" → „three schemas" inkl. `maint`-Zeile in der §5-Ownership-Tabelle; (b) kurzer `maint`-Subsystem-Absatz in §1a.2/§3 (Registry `ops.tMaintenanceJob`, 5 `maint.*`-Procs, vendorte Ola-Objekte in `RoboticoOps.dbo`, 6 Agent-Jobs, Watchdog inkl. Liveness-Check); (c) Inventar-Tabelle um die 6 neuen Dateien + `ops.tMaintenanceJob` ergänzen; (d) **zwei neue §6-Standing-Rules**: „Backups bleiben bei CBB — die Wartungssuite erzeugt nie einen Backup-Job, niemand faltet Backups ‚der Ordnung halber' in Ola" (ADR-B-Grenze) und „Wartungs-Tuning ausschließlich via git + Deploy — die Registry ist repo-owned, Live-Edits werden überschrieben" (D11).

Pflicht im selben Commit wie B1 (CLAUDE.md-Vertrag).

### §3.5 — B5: test1-Deploy + Validierung

`deploy.ps1 -Scope global` gegen test1; Agent temporär starten oder Jobs per `sp_start_job` manuell auslösen (startet auch disabled Jobs — die D34-Schalterstellung stört die manuelle Validierung nicht). Prüfliste:

- **Einmalig (admin-owned, direkt nach dem Erst-Deploy):** `ops.tConfig`-Eintrag `MaintenanceSchedulesEnabled = '0'` auf test1 setzen; der nächste `260`-Lauf bzw. ein manueller `EXEC maint.spEnsureMaintenanceJobs` zieht den Disabled-Zustand aller Jobs nach (D34). Danach prüfen: alle `RoboticoOps - Maint - `-Jobs existieren und sind disabled.

- Ola-Objekte in `RoboticoOps.dbo`; **`RoboticoOps.dbo.DatabaseBackup` existiert nicht** (AC2/AC4); keine `eazybusiness.dbo`-Ola-Objekte durch unsere Kette.
- Registry enthält die Soll-Zeilen aus §3.2 (aktuell **6** — §3.2 ist SSoT, Zahl hier nicht separat pflegen).
- Jobs angelegt; **je ein grüner Lauf aller Ola-/Cleanup-Jobs (alle Registry-Zeilen außer `backup-watchdog`; §3.2 = SSoT)**; CommandLog-Einträge vorhanden.
- **`backup-watchdog`: auf test1 ist KEIN grüner Job-Lauf erreichbar** (keine CBB-Kette → Stale-Alarm ist by design, vgl. ADR-B). Stattdessen Logik-Test: `EXEC maint.spCheckBackupChain` direkt — wirft `51100` bei fehlender/veralteter Kette und bei ungültigem Watch-Ziel (D32), schweigt bei frischer Kette. **Testweg für „frisch" (FT-15):** ein direkter `INSERT` in `backupset` scheitert an den media-set-FKs — stattdessen echte Einträge erzeugen via `BACKUP DATABASE … TO DISK = 'NUL'` + `BACKUP LOG … TO DISK = 'NUL'` (test1-only; **nie auf CBB-gesicherten Instanzen** — ein non-copy-only Full verschiebt dort die Diff-Basis). Das deckt zugleich den AC5-Schwellen-Test ab; dabei auch einen Randfall knapp jenseits der Schwelle prüfen (`>=`-Grenzsemantik D27, lokale Zeitbasis D32).
- **Liveness-Logik-Test (AC13, D36):** `EXEC maint.spCheckMaintenanceLiveness` direkt — vor den manuellen Job-Läufen (leeres/staltes CommandLog) wirft er `51105` mit den stalen `cJobKey`s; nach den grünen B5-Läufen von `checkdb` + `index-optimize` schweigt er. Zusätzlich D34-Pfad prüfen: mit Instanz-Schalter `'0'` und `bEnabled=0`-simulierter Zeile alarmiert er **nicht** (nur effektiv enablte Zeilen zählen).
- **Sync-Pfad-Tests (FI-8) — die beiden bislang ungetesteten Kernversprechen des Ensure:** (a) **Drift-Korrektur:** einen Job-Schedule live in msdb verstellen → `EXEC maint.spEnsureMaintenanceJobs` meldet **„1 Änderung"** (Normalform-Vergleich D31) und stellt den Registry-Stand wieder her; (b) **Fremd-Job-Entfernung:** Dummy-Job `RoboticoOps - Maint - zz-test` per `sp_add_job` anlegen → Re-Sync entfernt ihn (AC3-Entfernungspfad).
- `index-optimize`: Job-Step ist der konstante Dispatch (D28); der `CommandLog`-Eintrag des Laufs zeigt `@UpdateStatistics = 'ALL'` (AC10) und **keine** `*_REBUILD_OFFLINE`-Aktion (D13).
- **Idempotenz-Re-Deploy (AC7):** zweiter `deploy.ps1 -Scope global` → grate No-op, `260` ruft den Sync und dieser meldet **0 Änderungen**, keine Job-Neuanlage, `dModified` unverändert.
- `npm run db:lint` + `validate_structure.sql` grün (AC11).
- **AC6-Grenze auf test1:** Mail-Versand wird erst nach Agent-Neustart wirksam — hier nur Operator-/Profil-Existenz und Job-Verdrahtung prüfen, kein Mail-Test (der ist B6 Nr. 6).

Danach Agent wieder Stopped — der Dauer-Schedule-Schutz hängt aber am Instanz-Schalter `MaintenanceSchedulesEnabled = '0'` (D34), nicht am Dienststatus: der Agent darf für Reset-Arbeit jederzeit (auch über Nacht) laufen, ohne dass Wartungsjobs feuern.

### §3.6 — B6: Prod-Cutover (human-gated Runbook)

Die B6-Schritte werden in `docs/runbooks/rollout-mssql-ops.md` **verwoben, nicht als monolithische Phase angehängt** ([EDIT], D22/D26 — die Prod-Aktivierung ist Teil des RoboticoOps-Prod-Cutovers, dessen Spine dieses Runbook ist; ein separates Wartungs-Runbook würde die Aktivierung an zwei Stellen beschreiben). **Verwebungs-Regel (D26):** Der Deploy, den B6 umgibt, ist kein neuer — die Wartungs-Dateien liegen in `db-migrations/global/` und deployen im **bestehenden Phase-4-Deploy** des Runbooks (`deploy.ps1 -Scope global -Environment PROD`; einen separaten „nur Wartung"-Deploy gibt es nicht). Deshalb: **Schritt 1 wird als Vorbedingungs-Sub-Schritt „Phase 4a — Alt-Ola entfernen" VOR dem `deploy.ps1`-Aufruf in Phase 4 verankert; die Schritte 3–6 werden als Nachlauf-Schritte/Phase NACH Phase 4 eingehängt.** B6 darf ausdrücklich NICHT als „Phase 8" hinter Phase 7 gehängt werden — dann liefe Schritt 1 nach dem Deploy, der die neuen Jobs bereits aktiv angelegt hat (genau die Verletzung, die die CAUTION unten verbietet).

**Vorbedingungen (vor Phase 4a):**
- **Gap 5.1 ist entschieden ✅ (Lukas, 2026-07-22, D40):** Die Fremd-Prod-DBs bleiben **bewusst im aktiven Wartungs-Scope** — der erste Nachtlauf führt CHECKDB/IndexOptimize planmäßig auch gegen sie aus (klein, ~1 GB; Kosten trivial; Korruptionserkennung gewollt). Keine Exclusion-Ausdrücke.
- **Gap 5.3** (RoboticoOps-Prod-Cutover) wie bisher: harte Vorbedingung.

Ausführung **nur mit ausdrücklicher Freigabe**:

1. **Alt-Install entfernen — VOR dem Deploy** (Runbook, keine Migration; D16): zuerst per Inventar-Query alle Ola-Objekte in `eazybusiness.dbo` bestätigen; **vor dem Drop das alte `CommandLog` archivieren** (D39: `SELECT * INTO RoboticoOps.dbo.CommandLog_legacy_eazybusiness FROM eazybusiness.dbo.CommandLog` — 9.218 Zeilen, der einzige Primärbeleg des 2025-11-27-Ausfallmusters und der letzten realen Wartungsläufe; Sekundenaufwand, danach unwiederbringlich); dann die 11 alten Ola-Jobs löschen und `CommandLog`, `CommandExecute`, `DatabaseIntegrityCheck` sowie etwaige Reste von `IndexOptimize`/`DatabaseBackup` und Ola-Tabellen aus `eazybusiness.dbo` droppen (respektiert „dbo nie per Migration"). **Kein Abdeckungsverlust:** die Alt-Jobs sind seit ~2025-11 wirkungslos (IndexOptimize failt nächtlich, CHECKDB lief zuletzt 2024).
2. Global-Kette deployt RoboticoOps + Wartungssuite auf vm-sql2 (Teil des RoboticoOps-Prod-Cutovers). Die neuen Jobs entstehen dabei **sofort enabled + scheduled** (`bEnabled`-Default 1) — wegen Schritt 1 kollisionsfrei.
3. **RoboticoOps in die CBB-Sicherung aufnehmen** — kein neuer Arbeitsschritt, sondern der **Verweis auf den bestehenden Phase-2/4-Backup-Schritt des Runbooks** (dort steht die Anweisung „add RoboticoOps LOG backups" bereits; die Aktion nicht doppelt beschreiben, SSoT bleibt der Phase-2/4-Schritt). Beim Runbook-[EDIT] dort ergänzen: **„diese LOG-Backup-Aktivierung beendet den stündlichen `backup-watchdog`-Alarm für RoboticoOps."** Bis sie geschieht, schlägt der Watchdog **stündlich** (D35) für RoboticoOps an — das ist gewollt: der Alarm IST der Detektor für die fehlende Abdeckung; die Kadenz macht ihn unignorierbar, also Schritt 3 am Cutover-Tag selbst abschließen. **Dabei außerdem (D37): CBB-Abdeckung der System-DBs verifizieren** — F1 belegt die gesunde Kette nur für `eazybusiness`, und genau dieser Plan macht `msdb` wertvoll (Jobs, Schedules, Operator, `backupset`-Historie = Datengrundlage des Watchdogs), während Schritt 1 die alten — nie gelaufenen — `SYSTEM_DATABASES`-Backup-Jobs ersatzlos entfernt. Query: jüngstes `backupset`-Full je System-DB (`msdb`, `master`). **Vorab bereits verifiziert (2026-07-22, D41):** beide hängen in der echten Kette (Full 03:00 `copy_only=0`) → `msdb` steht seitdem in der `backup-watchdog`-Zeile (§3.2; Log-Check überspringt sie als SIMPLE per D27). Dieser Schritt ist damit eine **Re-Verifikation** am Cutover-Tag (CBB-Konfiguration kann sich bis dahin geändert haben); weicht das Ergebnis ab → §5 Gap 6 wieder öffnen.
4. **SQL-Agent einmal neu starten**, damit das frisch zugewiesene Mail-Profil im Alert-System greift (die Zuweisung wird erst nach Agent-Neustart wirksam). Vorher keinen Alarm-Test werten. **Guard vor dem Neustart:** prüfen, dass kein Agent-Job gerade läuft — der Neustart killt laufende Jobs, und der Agent ist mit der Reset-Infra geteilt (Reset via `reset.spPub_GetResetStatus`/`sysjobactivity`, Wartung via `sysjobactivity`); analog zum Deploy-Guard des Parent-Runbooks („kein global-Deploy während eines laufenden Resets").
5. **Verifikation (reine Prüfung — die Jobs existieren seit Schritt 2):** Schedules korrekt; je Job der konstante, voll qualifizierte Dispatch-Step `EXECUTE RoboticoOps.maint.spRunMaintenanceJob @cJobKey = …` (D28; ADR-A-Failure-Mode „wrong DB context"/F2); Notify-Verdrahtung auf allen `bNotifyOnFail=1`-Jobs vorhanden (`260` hat sie nach der Operator-Anlage nachgezogen); `MaintenanceSchedulesEnabled` auf prod **nicht** gesetzt (Jobs enabled, D34). **Agent-Job-History-Limit prüfen und anheben (D38):** der Agent-Default (1.000 Zeilen gesamt / 100 pro Job) rolliert `sysjobhistory` weit vor der deklarierten 365-Tage-Retention — Job-Ausgänge inkl. Fehlertexten (die F2-Forensik-Quelle) leben nur dort. Via `msdb.dbo.sp_set_sqlagent_properties @jobhistory_max_rows = 10000, @jobhistory_max_rows_per_job = 1000` (Instanz-Zustand, admin-owned — analog Schalter/Operator kein Migrations-Gegenstand); erst damit ist die `cleanup-jobhistory`-Retention die tatsächliche.
6. Ersten Nachtlauf beobachten — **dabei Laufzeiten messen** (CHECKDB So/Mi 01:00 + IndexOptimize 02:00 müssen real vor dem 03:00-Full fertig sein; die Staffelung ist per Startzeit behauptet, nicht erzwungen — bei Überlappung Zeiten in der Registry justieren). **Alarmweg-Abnahme über den natürlichen Alarm aus Schritt 3:** solange RoboticoOps noch nicht in CBB ist, MUSS die stündliche `backup-watchdog`-Stale-Mail (THROW 51100 → Operator) real bei `lukas@dattenberger.com` eintreffen — seit D35 binnen einer Stunde nach dem Agent-Neustart, das ist der nebenwirkungsfreie Beleg, dass der Meldeweg funktioniert. Kein künstlich erzwungener Job-Fehlschlag auf Prod nötig. **Dabei auf Fehlalarme im 03:00-Full-Fenster achten:** serialisiert CBB die Log-Backups während des großen eazybusiness-Fulls, kann der stündliche Log-Check dort knapp über die 1-h-Schwelle rutschen — in dem Fall `nLogMaxHours` auf 2 justieren (repo-owned, ein Deploy).

> [!CAUTION]
> Reihenfolge ist bindend: Alt-Jobs **vor** dem Deploy entfernen (Schritt 1 = Phase 4a vor Schritt 2 = Phase-4-Deploy) — der Deploy legt die neuen Jobs sofort aktiv an; andernfalls laufen zwei IndexOptimize-Jobs gegen verschiedene Objektmengen (ADR-A Failure Mode). **Zeitfenster-Regel (D26):** Die Schritte 1–5 werden **außerhalb des Fensters 00:30–03:00** ausgeführt, sodass Alarmweg (Schritt 4) und Verifikation (Schritt 5) nachweislich VOR dem ersten scheduled Lauf abgeschlossen sind — sonst feuern unverifizierte Jobs ohne funktionierenden Meldeweg (z. B. Deploy So 00:45 → checkdb 01:00). Erst danach den ersten Nachtlauf (Schritt 6) natürlich laufen lassen. *(Entschieden in R2, D34: der Instanz-Schalter `MaintenanceSchedulesEnabled` existiert nun, die **Zeitfenster-Regel bleibt trotzdem die primäre Cutover-Absicherung** — auf prod bleibt der Schalter ungesetzt (= enabled), damit der Standard-Cutover ohne zusätzlichen manuellen Umschalt-Schritt auskommt und kein vergessener `'0'`-Eintrag die Wartung still tot legt. „Disabled deployen → verifizieren → Schalter löschen + `EXEC maint.spEnsureMaintenanceJobs`" wird im Runbook als dokumentierter Notfall-Hebel erwähnt, ist aber nicht der Standardweg.)*

**Rollback/Abbruch (analog `rollout-mssql-ops.md` §Rollback):** Bleibt ein neuer Job nach dem Cutover rot, ist kein Rückbau nötig — es geht keine Abdeckung verloren (der Alt-Stand war ohnehin wirkungslos). Ein fehlerhafter Sync/Step wird per korrigiertem Deploy geheilt (Registry + Procs idempotent); manueller CHECKDB / manuelles Statistik-Update bleibt jederzeit als Notnagel möglich. **Bricht der Phase-4-Deploy (Schritt 2) ab, NACHDEM Schritt 1 die Alt-Install bereits entfernt hat:** ebenfalls kein Rückbau — der Alt-Stand war wirkungslos, es geht nichts verloren; Deploy-Ursache beheben (Phase-4-CAUTION des Runbooks: Cert-Passwort, Erreichbarkeit) und erneut fahren; bis dahin gilt der manuelle Notnagel.

**Runbook-Vermerk (Gap 2, Deliverable):** In der eingehängten Nachlauf-Phase wird explizit vermerkt: **„Database-Mail-Gesundheit ist vorerst unmonitored** — fällt Database Mail aus, verstummen Wartungs- und Watchdog-Alarme gemeinsam (Owner: Folge-Task im übergeordneten mssql-ops-Programm)." Damit hat der §5-Gap-2-Fallback („im Runbook vermerkt") ein produzierendes Deliverable.

## 4. Directory Layout

```
db-migrations/global/
├── up/
│   ├── 0022_maintenance_ola_vendor.sql      [NEW]  gepinnte Ola-Objekte → RoboticoOps.dbo
│   └── 0023_maintenance_registry.sql        [NEW]  maint-Schema + ops.tMaintenanceJob (DDL)
├── sprocs/
│   ├── maint.spEnsureMaintenanceJobs.sql    [NEW]  Registry → Agent-Jobs (Sync, konstanter Dispatch-Step)
│   ├── maint.spRunMaintenanceJob.sql        [NEW]  Laufzeit-Dispatcher: Registry-Zeile → Ola-/System-Aufruf (D28)
│   ├── maint.spCheckBackupChain.sql         [NEW]  read-only Backup-Frische-Watchdog (lokale Zeitbasis, Ziel-Validierung)
│   └── maint.spCheckMaintenanceLiveness.sql [NEW]  read-only Wartungs-Liveness-Check: Registry-Soll vs. CommandLog-Frische (D36)
├── runAfterOtherAnyTimeScripts/
│   └── maint.spApplyMaintenance.sql         [NEW]  MERGE Soll-Zeilen + EXEC ensure
└── permissions/
    └── 260_maintenance_operator.sql         [NEW]  Operator + Mailprofil (guarded) + unbedingter Ensure-Aufruf/Self-Heal (everytime, D29)

db-migrations/tests/global/validate_structure.sql  [EDIT] 5 maint.*-Procs (P) + ops.tMaintenanceJob (U) + Schlüsselspalten (Lint (l))
db-migrations/tests/global/validate_rollout.sql    [EDIT] Maintenance-Operability-Block: Registry↔Agent-Jobs, Notify-Verdrahtung, Operator (AC12, D23)
db-migrations/README.md                      [EDIT] §4-(k)-Tabelle: THROW 51100/51105/51110/51120 allozieren + Guidance-Satz (Reset ab 51130, FT-14)
docs/SQL/MSSQL-OPS-DATA-MODEL.md             [EDIT] Kopf (four→five, Scope) + Vertrags-Box (0023) + ops.tMaintenanceJob-Sektion
docs/SQL/NAMING-CONVENTIONS.md               [EDIT] maint.*-Ownership-Zeile + t-Präfix (time) Mikro-Konvention
docs/SQL/MSSQL-OPS-ARCHITECTURE.md           [EDIT] three schemas + maint-Absatz + Inventar + 2 neue §6-Standing-Rules (D25, s. §3.4)
docs/runbooks/rollout-mssql-ops.md           [EDIT] B6 verwoben: Phase 4a (Alt-Ola-Entfernung) + Nachlauf-Phase nach Phase 4 (D22/D26, s. §3.6)
```

**Datei-Delta:** 8 neue Migrations-Dateien, 7 [EDIT]s (2× Tests, README, 3× SQL-Doku, Runbook).

## Decision Log

Die tragenden Entscheidungen liegen in den ADRs; hier die Session-Festlegungen als Kurzverweis:

| # | Entscheidung | Quelle |
|---|---|---|
| D1 | Ola vendored in RoboticoOps.dbo; unsere Objekte in `maint.*` + Registry in `ops.*` | ADR-A §D-A1 |
| D2 | Deklarative Registry `ops.tMaintenanceJob` als SSoT | ADR-A §D-A2 |
| D3 | Idempotenter Sync `maint.spEnsureMaintenanceJobs` (Muster `reset.spEnsureAgentJob`), sa-owned | ADR-A §D-A3 |
| D4 | Ein Job pro Operation, nächtlich gestaffelt, CHECKDB vor dem 03:00-Full | ADR-A §D-A4 |
| D5 | `USER_DATABASES` inkl. `eazybusiness_tm*` für Index/Statistik (dort wird gearbeitet) | ADR-A §D-A4 |
| D6 | Alarmierung voll verdrahtet, Mail an `lukas@dattenberger.com` | ADR-A §D-A5 |
| D7 | Backups bleiben CBB; kein Ola-Backup; Watchdog ohne tm-Klone | ADR-B |
| D8 | Cleanup-Retention 365 Tage (später reduzierbar) | Session 2026-07-21 |
| D9 | test1 = Deploy-/Testziel ohne Dauer-Schedule | ADR-A §D-A6 |
| D10 | Zeitplan als typisierte Spalten (`cFrequency`/`nWeekdayMask`/`tStartTime`) statt Cron-String — gleiche Typisierungs-Logik wie bei den Stellschrauben | Review 2026-07-21 |
| D11 | Registry ist **repo-owned**: Seed-MERGE überschreibt Live-Änderungen; Tuning nur via git+Deploy (bewusste Abweichung von `ops.tResetStep`) | Review 2026-07-21, §3.3 |
| D12 | Keine Job-Output-Dateien → kein OutputFiles-Cleanup, kein CmdExec (Registry-Zeilenzahl: s. §3.2-Tabelle als SSoT — nach D15 = 6) | Review 2026-07-21, §3.2 |
| D13 | IndexOptimize REORGANIZE-only (Standard Edition: kein Online-Rebuild; Offline-Rebuild nachts inakzeptabel) | Review 2026-07-21, §3.2 |
| D14 | Watchdog-Log-Check nur für FULL-Recovery-DBs; Ola-Einzelskripte vendored (byte-unverändert), `DatabaseBackup.sql` nicht deployt | Review 2026-07-21, §3.1/§3.2 |
| D15 | CHECKDB **2× wöchentlich (So+Mi 01:00)** als EIN Job über `ALL_DATABASES, -eazybusiness_tm%` (tm-Klone ausgenommen; ersetzt tägliche Kadenz + System/User-Split); Zeitplan-Modell dafür auf `nWeekdayMask`-Bitmaske erweitert | Lukas 2026-07-21, §3.2 |
| D16 | Prod-Cutover: Alt-Jobs/Alt-Objekte werden **vor** dem Deploy entfernt (Alt-Stand ohnehin wirkungslos → kein Abdeckungsverlust); B6-Schritt 5 ist reine Verifikation | QG 2026-07-21 (SEC-4-1/SEC-4-6), §3.6 |
| D17 | `260_maintenance_operator.sql` (everytime): Operator + Mailprofil + **bedingter** `EXEC maint.spEnsureMaintenanceJobs`-Re-Trigger (Muster `200_ensure_agent_job`) — löst die grate-Stufen-Reihenfolge (Operator entsteht nach dem Sync) und liefert zugleich den everytime-Self-Heal; der Sync trägt den Operator-EXISTS-Guard | QG 2026-07-21 (SEC-3-1, SA-4/SEC-4-4), §3.3 |
| D18 | AC7-Mechanik: grate-Hash-Gating + value-guarded MERGE (`dModified` nur bei echter Änderung) + No-op-`260`; Sync = per-Job-Vergleich, Drop/Recreate nur bei Abweichung, `sysjobactivity`-Guard (Skip + Report, kein globales THROW) | QG 2026-07-21 (CA-4/SEC-3-8), §3.2/§3.3 |
| D19 | `ops_admin` erhält nur **SELECT** auf `ops.tMaintenanceJob` (repo-owned: Write-Grants wären wirkungslos und irreführend) | QG 2026-07-21 (ADR-4), §3.1 |
| D20 | Typ-Präfix `t` = `time`-Spalte als dokumentierte Mikro-Konvention (bewusste Zweitbelegung neben dem Tabellen-Präfix); [EDIT] NAMING-CONVENTIONS | QG 2026-07-21 (ADR-2/SA-7), §3.4 |
| D21 | THROW-Allokation: `51100` (spCheckBackupChain stale-chain), `51110` (spEnsureMaintenanceJobs, reserviert); [EDIT] README §4 (k) | QG 2026-07-21 (SEC-3-3/SA-2), §3.2 |
| D22 | B6-Cutover wird Phase in `docs/runbooks/rollout-mssql-ops.md` (kein separates Runbook); MERGE bleibt trotz QG3 B12 (repo-owned, stabile Keys, keine Admin-Umordnung — Begründung im Proc-Header) | QG 2026-07-21 (SEC-4-7, CA-6), §3.3/§3.6 |
| D23 | `validate_rollout.sql` erhält einen Maintenance-Operability-Block (Registry↔Jobs, Notify, Operator) — das zweite Rollout-Gate der Reset-Infra gilt auch für die Wartung | QG R2 2026-07-21 (SA-1), AC12/§4 |
| D24 | IndexOptimize↔Reset-Seam über die `eazybusiness_tm*`-Klone: Kollision wird akzeptiert — der Reset gewinnt konstruktionsbedingt (`SINGLE_USER WITH ROLLBACK IMMEDIATE` killt die IndexOptimize-Session, Job meldet rot = ein Alarm; Klon in RESTORING wird von Ola still übersprungen); dokumentiert als ADR-A Failure Mode statt Scope-Änderung (D5 bleibt) | QG R2 2026-07-21 (SA-2), ADR-A |
| D25 | `docs/SQL/MSSQL-OPS-ARCHITECTURE.md` wird [EDIT]-Deliverable: Bestands-Update (three schemas, maint-Absatz, Inventar) + zwei neue §6-Standing-Rules (ADR-B-Backup-Grenze; git-only-Tuning) | QG R2 2026-07-21 (SA-3/SEC-6-2), §3.4/§4 |
| D26 | B6 wird in die Runbook-Phasen **verwoben** (präzisiert D22): Schritt 1 = Phase 4a vor `deploy.ps1`, Schritte 3–6 = Nachlauf nach Phase 4; Zeitfenster-Regel (Schritte 1–5 außerhalb 00:30–03:00); Gap-5.1-Entscheidung ist Cutover-Vorbedingung; Alarmweg-Abnahme über den natürlichen Watchdog-Stale-Alarm statt erzwungenem Fehlschlag | QG R2 2026-07-21 (SEC-6-1/SA-5, SEC-6-4, SEC-6-5, SEC-6-7), §3.6 |
| D27 | Watchdog-Log-Check gilt für alle log-basierten Recovery-Modelle (`recovery_model_desc <> 'SIMPLE'`, d. h. FULL + BULK_LOGGED — präzisiert D14); Schwellen-Semantik festgenagelt: Alarm bei `Alter >= Schwelle` | QG R2 2026-07-21 (SEC-3-6, SEC-1-3), AC5/§3.2 |
| D28 | **Fix-A-Auflösung = Runtime-Dispatch** (CA-1 übernommen, Re-Scope-Variante aktiv verworfen): konstanter Job-Step `EXEC RoboticoOps.maint.spRunMaintenanceJob @cJobKey = …`; vierter `maint.*`-Proc mit der Kommando-Matrix als Laufzeit-`CASE`, Werte als echte T-SQL-Parameter (kein dynamisches SQL); Cleanup-Cutoffs zur Laufzeit (keine Frozen-Date-Falle); THROW `51120`; Registry-Änderungen an Scope/Knobs wirken ohne Job-Recreate; folgt dem Reset-Präzedenzfall (konstanter Step `EXEC reset.spProcessNextResetRequest`) | QG R2 Deep 2026-07-21 (FT-1/CA-1/SEC-3-4, FT-3), §3.2 |
| D29 | `260` ruft `maint.spEnsureMaintenanceJobs` **unbedingt** bei jedem Deploy auf (ersetzt den bedingten Re-Trigger aus D17) — schließt das Nachhol-Loch aus Hash-Gating + Running-Skip + bedingtem Trigger; Skips konvergieren beim nächsten Deploy | QG R2 Deep 2026-07-21 (FT-2/SEC-3-2), §3.3/AC7 |
| D30 | MERGE-Lebenszyklus vollständig: `WHEN NOT MATCHED BY SOURCE THEN DELETE` (aus git entfernte Zeilen entfernen Registry-Zeile + Job) und NULL-sichere Vergleiche via `IS DISTINCT FROM` (Value-Guard des MERGE UND Drift-Vergleich des Sync) | QG R2 Deep 2026-07-21 (FT-5/FT-6/SEC-3-3a), §3.3 |
| D31 | Sync-Vergleich in kanonischer Normalform: geschlossene Vergleichsfläche (Job/Step/Schedule), Registry→msdb-Konvertierung vor dem Vergleich, Schedule-Pflichtwerte (`freq_recurrence_factor=1` weekly, `freq_interval=1` daily, `active_start_time` HHMMSS), `sp_delete_job … @delete_unused_schedule=1`; Running-Guard auf die aktuelle Agent-Session gescoped (`MAX(session_id)` aus `syssessions`) | QG R2 Deep 2026-07-21 (FT-7/FT-8/CA-4), §3.2 |
| D32 | Watchdog-Härtung: Altersvergleiche in **lokaler Serverzeit** (`SYSDATETIME()` — `backupset` speichert lokal, UTC-Griff weitete die 1-h-Schwelle auf ~3 h) + **Ziel-Validierung** (`TRIM`, `THROW 51100` bei Token ohne ONLINE-Match — Alarm statt stiller Skip) | QG R2 Deep 2026-07-21 (FT-4/FT-9), §3.2/AC5 |
| D33 | DDL-Invarianten nachgeschärft: `bUpdateStatistics IS NOT NULL` im IndexOptimize-CHECK-Zweig + definiertes Mapping (1→`'ALL'`, 0→Parameter entfällt); `CK_tMaintenanceJob_cDisplayName` erzwingt das Job-Präfix (kein Geisterjob außerhalb des Präfix-Fensters) | QG R2 Deep 2026-07-21 (FT-10/FT-12/SEC-3-1/SEC-3-5), §3.1 |
| D34 | `bEnabled` mappt auf Job-`@enabled` (Job existiert für jede Registry-Zeile, pausieren = disablen); Instanz-Schalter `ops.tConfig('MaintenanceSchedulesEnabled')` (test1 `'0'`, prod ohne Eintrag = enabled) erzwingt D-A6 statt es zu behaupten (test1-Agent muss für Resets laufen); Operator-E-Mail bleibt hart kodiert (Policy vs. Instanz-Zustand); Zeitfenster-Regel bleibt primäre Cutover-Absicherung, Schalter nur Notfall-Hebel | QG R2 Deep 2026-07-21 (FT-11/FI-4/FI-5/SEC-3-3b), §3.2/§3.3/§3.5/§3.6 |
| D35 | `cFrequency` um `'hourly'` erweitert (Mapping `freq_type=4` + `freq_subday_type=8`/`freq_subday_interval=1`; Subday-Spalten in der D31-Vergleichsfläche); `backup-watchdog` läuft stündlich (Anker 00:00) statt daily 08:00 — Erkennungslatenz der Log-Kette ≤ ~2 h statt bis 24 h; entschieden JETZT, weil `up/0023` nach dem Apply immutable ist | QG R2 Deep 2026-07-22 (FI-3), §3.1/§3.2/AC5 |
| D36 | Wartungs-Liveness-Check `maint.spCheckMaintenanceLiveness` (fünfter Proc, parameterlos, THROW `51105`) als zweiter EXEC im Watchdog-Step: leitet je effektiv enablter Ola-Zeile das zulässige CommandLog-Alter aus dem Schedule ab (daily → 26 h, weekly → 8 d) — deckt den „läuft nie"-Pfad (F3/F4) ab, den `bNotifyOnFail` nicht sieht; Rest-Blindfleck „Agent-Dienst steht" als ADR-A-Failure-Mode dokumentiert und Gap 2 zugeschlagen | QG R2 Deep 2026-07-22 (FI-1), §3.2/AC13 |
| D37 | CBB-Abdeckung der System-DBs (`msdb`, `master`) ist Cutover-Prüfschritt (B6 Nr. 3): belegt ist die Kette nur für `eazybusiness` (F1), während der Plan `msdb` wertvoll macht und die alten SYSTEM_DATABASES-Backup-Jobs entfernt; falls gesichert → `msdb` in die Watchdog-Zeile, sonst Entscheidung Lukas (§5 Gap 6) | QG R2 Deep 2026-07-22 (FI-2), §3.6 |
| D38 | Agent-Job-History-Limit wird im Cutover angehoben (`sp_set_sqlagent_properties @jobhistory_max_rows=10000/@…_per_job=1000`, admin-owned Instanz-Zustand) — sonst rolliert `sysjobhistory` weit vor der deklarierten 365-d-Retention | QG R2 Deep 2026-07-22 (FI-6), §3.6 Nr. 5 |
| D39 | Altes `eazybusiness.dbo.CommandLog` (9.218 Zeilen, 2024→2025-11-27) wird vor dem Drop nach `RoboticoOps.dbo.CommandLog_legacy_eazybusiness` archiviert — Forensik der Ausfall-Historie bleibt erhalten | QG R2 Deep 2026-07-22 (FI-7), §3.6 Nr. 1 |
| D40 | Fremd-Prod-DBs (`ersatzteile_prod*`, `EKL*`, `HbDat001`) bleiben im dynamischen Wartungs-Scope (CHECKDB + IndexOptimize) — klein (~1 GB), Kosten trivial, Korruptionserkennung auf der Instanz gewollt; keine Exclusion-Ausdrücke. Watchdog-Aufnahme (Gap 1a) bleibt separater Folge-Task | Lukas 2026-07-22, §5 Gap 1 |
| D41 | `msdb` in die `backup-watchdog`-Zeile: CBB-Abdeckung der System-DBs read-only verifiziert (Full 03:00 `copy_only=0` für `msdb`/`master`/`model`, Stand 2026-07-22) — Gap 6 geschlossen per D37-Fallback; B6 Nr. 3 wird zur Re-Verifikation | Verifikation vm-sql2 2026-07-22, §3.2/§5 Gap 6 |

## Iteration Log

### 2026-07-21 — Quality-Gate-Einarbeitung (Consolidator)

Alle 29 konsolidierten QG-Findings (2 Critical, 13 Important, 14 Nice-to-have; aus 53 Roh-Findings von 7 Review-Agents) eingearbeitet. Kern:

- **Critical SEC-4-1:** Cutover-Reihenfolge gedreht — Alt-Install-Entfernung **vor** den Deploy (B6 Schritt 1), Schritt 5 zur reinen Verifikation umformuliert (D16).
- **Critical SEC-3-1 (+ SA-4/SEC-4-4):** grate-Stufen-Reihenfolge Operator↔Sync gelöst über `260_maintenance_operator.sql` mit bedingtem Ensure-Re-Trigger + Operator-EXISTS-Guard im Sync — deckt zugleich den everytime-Self-Heal ab (D17).
- Repo-Verträge verankert: `validate_structure.sql` (Lint (l)), THROW `51100`/`51110` (Lint (k), D21), Lint-Vorab-Check der Ola-Vendor-Dateien (SA-9) — als [EDIT]-Deliverables in §4 + neues AC11.
- Zeilenzahl-Drift 6/7/8 bereinigt (§3.2-Tabelle = SSoT; D12/§3.5 korrigiert), AC1-Dateiverweis korrigiert, AC3 durch die Kommando-Matrix ersetzt, neue ACs 10/11, AC7-Mechanik festgelegt (D18), B5-Prüfliste überarbeitet (Watchdog-Logik-Test statt grünem Lauf), B4-Umfang präzisiert (inkl. NAMING-CONVENTIONS, D20), `ops_admin` auf SELECT verengt (D19), Gaps ergänzt/geschärft (aktiver Wartungs-Scope auf Fremd-DBs), Referenzen vervollständigt. Neue Entscheidungen: D16–D22; ADRs mit je einem Decision-History-Eintrag nachgezogen.

### 2026-07-21 — Quality-Gate Runde 2 (Deep) — Consolidator-Einarbeitung

21 der 43 konsolidierten R2-Findings (Einarbeitungs-Owner „Consolidator-Pfad"; aus 59 Roh-Findings von 9 Agents, 0 Critical) eingearbeitet — die 22 Special-Agent-Findings (FT-*/FI-*) folgen in eigenen Runden durch ihre Autoren. Kern:

- **Rollout-Gate (SA-1/D23):** `validate_rollout.sql` wird um den Maintenance-Operability-Block erweitert — neues AC12 + [EDIT] in §4.
- **tm-Klon-Seam (SA-2/D24):** IndexOptimize↔Reset-Kollision über die Klone explizit entschieden (Reset gewinnt per `SINGLE_USER WITH ROLLBACK IMMEDIATE`; akzeptiert + als ADR-A Failure Mode dokumentiert).
- **Architektur-Doku (SA-3+SEC-6-2/D25):** `MSSQL-OPS-ARCHITECTURE.md` als 7. [EDIT] verankert (three schemas, Inventar, 2 neue §6-Standing-Rules).
- **Cutover-Präzisierung (SEC-6-1+SA-5, SEC-6-4, SEC-6-5, SEC-6-3, SEC-6-6, SEC-6-7, SEC-6-8 / D26):** B6 wird in Phase 4 verwoben (Phase 4a + Nachlauf) statt angehängt; Zeitfenster-Regel; Gap-5.1-Vorbedingung; CBB-Schritt als Verweis statt Duplikat; Abbruch-nach-Schritt-1-Fall im Rollback; Alarmweg-Abnahme über den natürlichen Stale-Alarm; Agent-Neustart-Guard.
- **Watchdog-Ränder (SEC-3-6, SEC-1-3 / D27):** Log-Check `<> SIMPLE` statt „nur FULL"; Schwellen-Operator `>=` festgenagelt.
- **AC-/Prosa-Konsistenz (SEC-1-1, SEC-1-2, SEC-1-4):** §1.2-Korruptionszusage auf die ADR-Formulierung („innerhalb weniger Tage") zurückgenommen; zweite §2-NOTE als Abnahme-Anker für die Alt-Install-Entfernung; „5 Jobs" in AC9/§3.5 durch SSoT-relative Formulierung ersetzt.
- **Kohärenz/Referenzen (SA-4, CA-2, SEC-5-2, ADR-1/2/3):** 260er-Operator-Hardcoding als bewusste Abweichung dokumentiert; `cDatabases`-Doppel-Grammatik als bewusster Trade-off in §3.1 festgehalten; Gap-2-Runbook-Vermerk als Deliverable in §3.6; Naming- + grate-ADR in §6 verlinkt, Promotions-Aufgaben (Naming-ADR-Rückverweis, CLAUDE.md-Subsystems-Tabelle) notiert.

Nähte zu den Special-Agent-Runden sind im Plan neutral formuliert („sofern die weitere QG-Einarbeitung … einführt/präzisiert"): bEnabled-/Instanz-Schalter-Semantik, Fix-A-Auflösung, Watchdog-Token-Validierung und -Zeitbasis bleiben deren Autoren überlassen. Neue Entscheidungen: D23–D27.

### 2026-07-21 — Quality-Gate Runde 2 (Deep) — Fable-Tech-Einarbeitung

Alle 16 Fable-Tech-Findings (FT-1..FT-16; 11 Important, 5 Nice-to-have) eingearbeitet; die vom Consolidator offen gelassenen Nähte (AC12-Konditionierung, §3.6-CAUTION-Alternative, §3.3-Operator-Nachzug, CA-2-Laufzeit-Validierung) aufgelöst. Kern:

- **FT-1 entschieden — Runtime-Dispatch (D28), CA-1 übernommen, Re-Scope aktiv verworfen:** Job-Steps werden konstant (`EXEC maint.spRunMaintenanceJob @cJobKey = …`), ein vierter `maint.*`-Proc trägt die Kommando-Matrix als Laufzeit-`CASE` und übergibt Registry-Werte als echte T-SQL-Parameter — Fix A gilt wörtlich, und das Muster folgt dem Reset-Präzedenzfall (konstanter parameterloser Step). Löst FT-3 (Frozen-Date) strukturell mit und entfernt die Step-Text-Facette aus FT-7; AC3/AC10/AC11, Kommando-Matrix, §4 (7. Migrations-Datei, `51120`) umgestellt.
- **Sync-Lebenszyklus geschlossen:** unbedingter `260`-Ensure-Aufruf (FT-2/D29), MERGE-Delete-Zweig + `IS DISTINCT FROM` (FT-5/FT-6/D30), kanonische Vergleichs-Normalform + Schedule-Pflichtwerte + `@delete_unused_schedule` (FT-7/D31), Session-gescopter `sysjobactivity`-Guard (FT-8/D31).
- **Watchdog gehärtet (D32):** lokale Zeitbasis (`SYSDATETIME()` statt `SYSUTCDATETIME()` — 1-h-Schwelle wäre sonst real ~3 h) und Ziel-Validierung (TRIM + `THROW 51100` bei unbekanntem/nicht-ONLINE Ziel) — löst zugleich die CA-2-NOTE-Naht in §3.1 auf.
- **DDL-Invarianten (D33):** `bUpdateStatistics IS NOT NULL` (IndexOptimize-Zweig, F8-Regressionsschutz) + definiertes 1/0-Mapping im Dispatcher (FT-10); `cDisplayName`-Präfix-CHECK (FT-12).
- **test1/Enabled-Semantik (D34, FT-11):** `bEnabled` → Job-`@enabled`; neuer Instanz-Schalter `ops.tConfig('MaintenanceSchedulesEnabled')` (test1 `'0'`) ersetzt „Agent Stopped" als Gate (der Agent muss für Resets laufen); AC9/AC12/§3.5/§3.6 umgestellt. Nähte final entschieden: Operator-E-Mail bleibt hart kodiert (§3.3 Nr. 1); Zeitfenster-Regel bleibt primäre Cutover-Absicherung, Schalter nur dokumentierter Notfall-Hebel (§3.6-CAUTION); AC12-Assertions auf die D34-Gleichung konditioniert.
- **Nice-to-have:** Ola-`CommandLog.sql`-Idempotenz-Wrapper als dokumentierte Abweichung (FT-13, §3.1); README-(k)-Guidance-Satz mitgezogen — maint reserviert `51100–51129`, Reset ab `51130` (FT-14); B5-Testweg `BACKUP … TO DISK='NUL'` (FT-15); `sysmail_profile`-Existenz-Guard in `260` (FT-16).

Nicht angefasst (Owner Fable-Intent): ADR-A-„becomes impossible"-Satz (FI-1), System-DB-Watched-Set (FI-2), Watchdog-Kadenz/`cFrequency='hourly'` (FI-3), FI-6/7/8. Nahtstellen dorthin: die `cFrequency`-CHECK/`CK_Schedule`-Zeilen in §3.1 und die D31-Schedule-Mapping-Tabelle sind so formuliert, dass eine `'hourly'`-Erweiterung (FI-3) additiv möglich bleibt (neuer CHECK-Wert + Mapping-Zeile `freq_subday_type`); die B5-Prüfliste lässt Raum für FI-8-Sync-Pfad-Tests. Neue Entscheidungen: D28–D34.

### 2026-07-22 — Quality-Gate Runde 2 (Deep) — Fable-Intent-Einarbeitung

Die 6 verbliebenen Fable-Intent-Findings (FI-1/FI-2/FI-3 Important, FI-6/FI-7/FI-8 Nice-to-have; FI-4/FI-5 waren bereits in FT-11/D34 aufgegangen) eingearbeitet — additiv auf den D28–D34-Konstrukten, kein Umbau:

- **FI-3 entschieden — `'hourly'` (D35), Variante (b):** `cFrequency` um `'hourly'` erweitert (CHECK + `CK_Schedule` + Mapping-Zeile `freq_subday_type=8`; Subday-Spalten additiv in die D31-Vergleichsfläche aufgenommen — exakt der vorbereitete Erweiterungspfad); `backup-watchdog` stündlich (Anker 00:00). Begründung: der Watchdog ist der einzige Detektor der Kette, „Log < 1 h" mit Tages-Stichprobe wäre real eine bis-zu-24-h-Garantie gewesen, und nach dem Apply von `up/0023` wäre die Schema-Erweiterung ein neues `up/`. Folgeänderungen: AC5-Kadenz, §3.6 Nr. 3/6 (stündliche Stale-Mail = schnellere Alarmweg-Abnahme; Hinweis auf mögliche 03:00-Fenster-Fehlalarme mit `nLogMaxHours`-Justage).
- **FI-1 — Liveness-Check (D36):** fünfter Proc `maint.spCheckMaintenanceLiveness` (parameterlos, `THROW 51105`, zweiter EXEC im Watchdog-Step) prüft selbst-konfigurierend aus der Registry, ob CHECKDB/IndexOptimize laut CommandLog tatsächlich gelaufen sind — schließt den „läuft nie"-Pfad (F3/F4), den `bNotifyOnFail` strukturell nicht sieht. Neues AC13, B5-Logik-Test, THROW-/validate_structure-/§4-Nachzüge (8 Migrations-Dateien, 5 Procs); ADR-A: „becomes impossible" präzisiert + neuer Failure Mode „Agent-Dienst gestoppt" (→ Gap 2).
- **FI-2 — System-DB-Backups (D37):** B6 Nr. 3 verifiziert die CBB-Abdeckung von `msdb`/`master` (F1 belegt nur `eazybusiness`; Schritt 1 entfernt die alten SYSTEM_DATABASES-Jobs ersatzlos); Ergebnispfade: `msdb` in die Watchdog-Zeile ODER neues §5 Gap 6 (Owner Lukas).
- **FI-6 (D38):** Agent-History-Limit-Anhebung als B6-Nr.-5-Prüfpunkt (Default 1.000 Zeilen unterläuft die 365-d-Retention). **FI-7 (D39):** CommandLog-Archivierung vor dem Drop (B6 Nr. 1). **FI-8:** B5-Prüfliste um die zwei ungetesteten Sync-Kernpfade ergänzt (Drift-Korrektur = „1 Änderung", Präfix-Dummy-Entfernung).

Neue Entscheidungen: D35–D39; beide ADRs mit je einem Decision-History-Eintrag nachgezogen.

### 2026-07-22 — Gap-Schließung (Lukas + Live-Verifikation)

Die zwei nach der QG-Runde-2-Einarbeitung offenen Punkte geschlossen:

- **Gap 5.1 / Gap 1b entschieden (Lukas, D40):** Fremd-Prod-DBs bleiben im dynamischen Wartungs-Scope — keine Exclusion-Ausdrücke; die Cutover-Vorbedingung in §3.6 ist erfüllt. Gap 1a (Watchdog-Aufnahme der Fremd-DBs) bleibt als Folge-Task offen, jetzt mit Datenbasis: `ersatzteile_prod` + `HbDat001` hängen in der echten CBB-Kette, `EKL`/`ersatzteile_prod_latest` nicht.
- **Gap 6 geschlossen (Live-Verifikation vm-sql2, read-only, D41):** `msdb`/`master`/`model` sind in der echten CBB-Kette (Full 03:00 `copy_only=0`, Stand 2026-07-22) → `msdb` per D37-Fallback in die `backup-watchdog`-Registry-Zeile aufgenommen (§3.2); B6 Nr. 3 wird zur Re-Verifikation am Cutover-Tag. ADR-B-Watched-Set entsprechend aktualisiert.

## 5. Information Gaps

1. **Fremd-DBs in Watchdog UND aktiver Wartung — (b) ENTSCHIEDEN (Lukas, 2026-07-22, D40):** Die Fremd-DBs (`ersatzteile_prod*`, `EKL*`, `HbDat001`) **bleiben im dynamischen Wartungs-Scope** (CHECKDB + IndexOptimize): alle klein (~1 GB, CHECKDB-Kosten trivial), Korruption auf derselben Instanz soll erkannt statt ignoriert werden, und der Scope erfasst damit bewusst auch jede künftige neue DB (ADR-A Failure Mode „dynamic scope" bleibt als Dokumentation des Verhaltens bestehen). Keine Exclusion-Ausdrücke nötig. — (a) Watchdog-Aufnahme der Fremd-DBs bleibt offen: `ersatzteile_prod` + `HbDat001` hängen nachweislich in der echten CBB-Kette (Full 03:00 `copy_only=0` + Logs, verifiziert 2026-07-22), `EKL`/`ersatzteile_prod_latest` dagegen nicht (nur copy_only 18:00) — Aufnahme erst nach geklärter Backup-Ownership. *Owner (a):* Lukas, Folge-Task. *Fallback (a):* Watched-Set bleibt `eazybusiness,RoboticoOps,msdb` (§3.2 = SSoT).
2. **Database-Mail-Gesundheit** — wer wacht über den Wächter? Fällt Database Mail aus, verstummen Wartungs- und Watchdog-Alarme gemeinsam. *Owner:* Lukas — Folge-Task im übergeordneten mssql-ops-Programm. *Fallback:* vorerst unmonitored, im Runbook vermerkt.
3. **RoboticoOps-Prod-Cutover-Zeitpunkt** — der Wartungs-Prod-Rollout hängt daran (RoboticoOps existiert auf vm-sql2 noch nicht). *Owner:* übergeordnetes mssql-ops-Programm. *Fallback:* keiner — harte Vorbedingung.
4. **Zu pinnende Ola-Version** — bei Umsetzung die aktuelle stabile Version wählen und im Vendor-Skript-Kopf festhalten. *Owner:* Umsetzung B1. *Fallback:* aktuelle stabile Release-Version (kein Blocker).
5. **Laufzeit des Nachtfensters** — ob CHECKDB (So/Mi 01:00, alle DBs außer tm ≈ 35 GB) + IndexOptimize (02:00) real vor dem 03:00-Full fertig sind, ist Annahme, nicht Messung; die Staffelung ist nur per Startzeit behauptet. *Owner:* test1-Validierung (B5) + erster Prod-Nachtlauf (B6 Nr. 6). *Fallback:* Zeiten in der Registry justieren (repo-owned, ein Deploy).
6. **CBB-Abdeckung der System-DBs (`msdb`, `master`) — GESCHLOSSEN (verifiziert 2026-07-22, D41):** Read-only-Query gegen `msdb.dbo.backupset` auf vm-sql2 belegt: `msdb`, `master` (und `model`) sind in der **echten** CBB-Kette — tägliches Full 03:00 mit `is_copy_only=0` (jüngstes: 2026-07-22 03:00:30). Konsequenz per D37-Fallback umgesetzt: `msdb` ist in die `backup-watchdog`-Zeile aufgenommen (§3.2; Log-Check überspringt sie als SIMPLE per D27). B6 Nr. 3 behält die Query als Cutover-Re-Verifikation (CBB-Konfiguration kann sich bis dahin ändern).

## 6. References

- **ADRs:** [adr-maintenance-as-code-roboticoops](adrs/adr-maintenance-as-code-roboticoops.md), [adr-backups-cbb-retained](adrs/adr-backups-cbb-retained.md)
- **Research:** [6-wartung-ist-analyse](../2026-07-10 - mssql-ops-infrastruktur/research/6-wartung-ist-analyse/6-wartung-ist-analyse.md)
- **Muster-Vorbild:** `db-migrations/global/runAfterOtherAnyTimeScripts/reset.spEnsureAgentJob.sql` + `permissions/200_ensure_agent_job.sql` (sa-owned Job-Ensure + everytime-Self-Heal), [adr-reset-step-registry](../2026-07-10 - mssql-ops-infrastruktur/adrs/adr-reset-step-registry.md) (Registry-Muster), [adr-module-signing-reset](../2026-07-10 - mssql-ops-infrastruktur/adrs/adr-module-signing-reset.md) (sa-owned-Agent-Job-Muster, Begründung von D3), [adr-two-chain-migration-paths](../2026-07-10 - mssql-ops-infrastruktur/adrs/adr-two-chain-migration-paths.md) (Ebene-B-Platzierung + hand-idempotente `up/`-Regel), [adr-ebene-b-hungarian-naming](../2026-07-10 - mssql-ops-infrastruktur/adrs/adr-ebene-b-hungarian-naming.md) (Naming-Konvention adoptiert; `t`=time ist eine dokumentierte Mikro-Erweiterung, D20), [adr-grate-migration-runner](../2026-07-10 - mssql-ops-infrastruktur/adrs/adr-grate-migration-runner.md) (Stufen-/Folder-Order-Garantie, auf der die `260`-Erst-Deploy-Konvergenz beruht, D17)
- **Promotions-Aufgaben (bei ADR-Promotion dieses Plans):** (a) Rückverweis/Decision-History-Notiz auf `adr-ebene-b-hungarian-naming` zur `t`=time-Mikro-Erweiterung (macht den Link bidirektional; Enumeration der ADR bleibt sonst still unvollständig); (b) „Subsystems"-Tabelle in `CLAUDE.md` ergänzen (`RoboticoOps`, `Testmandant Reset`, `JTL SQL Migrations`, `DB / Migrations`), damit die `Subsystem:`-Header aller sechs ADRs der Kohorte kanonisch verankert sind.
- **Übergeordnetes Programm:** [mssql-ops-infrastruktur](../2026-07-10 - mssql-ops-infrastruktur/mssql-ops-infrastruktur.md)
- **Datenmodell-Vertrag:** `docs/SQL/MSSQL-OPS-DATA-MODEL.md`; CLAUDE.md §„Database Object Documentation"
- **Extern:** [Ola Hallengren Maintenance Solution](https://ola.hallengren.com/)
