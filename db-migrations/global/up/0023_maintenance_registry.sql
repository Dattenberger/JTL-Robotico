-- 0023_maintenance_registry.sql  (Ebene B / global chain — runs in RoboticoOps)
--
-- Maintenance-as-code foundation: the maint schema (our maintenance procedures) and
-- ops.tMaintenanceJob, the declarative registry of every SQL-Agent maintenance job.
-- One row = one job; maint.spEnsureMaintenanceJobs synchronizes msdb from it.
--
-- The DDL here is one-time (up/, immutable). The DESIRED ROWS are deliberately NOT
-- seeded here — they are reconciled by the value-guarded MERGE in
-- runAfterOtherAnyTimeScripts/maint.spApplyMaintenance.sql on every hash change, so
-- schedule tuning stays in git without breaking the grate hash chain.
--
-- @see docs/plans/2026-07-21 - mssql-wartung-ola (§3.1)
-- @see docs/plans/2026-07-21 - mssql-wartung-ola/adrs/adr-maintenance-as-code-roboticoops.md
-- @see docs/SQL/MSSQL-OPS-DATA-MODEL.md (column-level reference — same-commit contract)

SET NOCOUNT ON;

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
        cDatabases     nvarchar(400) NOT NULL,  -- ZWEI Grammatiken je cOperation (Doku in MSSQL-OPS-DATA-MODEL.md):
                                                -- Ola-@Databases-Ausdruck (IntegrityCheck/IndexOptimize/Cleanup)
                                                -- bzw. LITERALE Komma-Liste (BackupWatchdog — Ola-Token dort
                                                -- ungültig, Laufzeit-THROW 51100); Werte erreichen Ola zur
                                                -- Laufzeit als echte Proc-Parameter des Dispatchers (D28),
                                                -- nie als Step-Text-Literal
        -- Zeitplan: typisiert statt Cron-String (gleiche Logik wie bei den Stellschrauben — kein Parsen im
        -- Sync-Proc; nur die drei genutzten Muster, Sync mappt 1:1 auf msdb.dbo.sysschedules):
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
