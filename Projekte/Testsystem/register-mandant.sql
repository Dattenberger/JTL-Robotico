------------------------------------------------------------
-- register-mandant.sql
-- Registriert einen Test-Mandanten vollstaendig, sodass er im JTL-Login
-- erscheint UND alle Benutzer (inkl. Kollegen) darin arbeiten koennen.
-- Zwei Schritte:
--
--   1) dbo.tMandant  - JTL-Mandanten-Registry (kMandant, cName, cDB).
--      Ohne Eintrag erscheint der Mandant nicht in der WaWi-Auswahl.
--      JTL haelt die Tabelle in ALLEN Mandanten-DBs konsistent -> Upsert
--      in jede registrierte Mandanten-DB + die neue Ziel-DB.
--
--   2) dbo.tBenutzerFirma  - Benutzer<->Firma-Zuordnung PRO Mandant
--      (kBenutzer, kFirma, kMandant). Fehlt sie fuer den neuen kMandant,
--      meldet JTL beim Login "keine Firma hinterlegt". Wir uebernehmen die
--      Zuordnung des Standard-Mandanten (kMandant 1) aus der Haupt-DB, damit
--      ALLE Benutzer sofort eine Firma haben. JTL verwaltet Benutzer/Firma
--      zentral in der Standard-DB [eazybusiness]; die Mandanten-DB spiegelt
--      es (Klon-Muster) -> Seed in beide.
--      (Benutzer-RECHTE sind global, nicht mandantenspezifisch -> kein Seed.)
--
-- Idempotent: tMandant keyed by cDB; tBenutzerFirma wird fuer den kMandant
-- vor dem Einfuegen geleert und neu befuellt.
--
-- Aufruf (via SQLCMD-Variablen):
--   sqlcmd -S <server> -E -b -v TargetDb="eazybusiness_tm4" \
--          -v MandantName="Testmandant4 (Lukas)" -i register-mandant.sql
------------------------------------------------------------
USE master;
GO
SET NOCOUNT ON;

DECLARE @TargetDb    sysname       = N'$(TargetDb)';
DECLARE @MandantName nvarchar(255) = N'$(MandantName)';

-- SAFETY: die Haupt-DB ist bereits als Standard-Mandant registriert und
-- darf nicht als Test-Mandant eingetragen/ueberschrieben werden.
IF @TargetDb = N'eazybusiness'
BEGIN
    RAISERROR('CRITICAL: TargetDb darf nicht [eazybusiness] sein.', 20, 1) WITH LOG;
    RETURN;
END

IF DB_ID(@TargetDb) IS NULL
BEGIN
    RAISERROR('Ziel-DB %s existiert nicht.', 16, 1, @TargetDb);
    RETURN;
END

IF NULLIF(LTRIM(RTRIM(@MandantName)), N'') IS NULL
BEGIN
    RAISERROR('MandantName ist leer.', 16, 1);
    RETURN;
END

------------------------------------------------------------
-- kMandant bestimmen: vorhandenen Eintrag (per cDB) wiederverwenden,
-- sonst naechste freie Nummer aus der Haupt-Registry (MAX+1).
------------------------------------------------------------
DECLARE @k int;
SELECT @k = kMandant FROM eazybusiness.dbo.tMandant WHERE cDB = @TargetDb;
IF @k IS NULL
    SELECT @k = ISNULL(MAX(kMandant), 0) + 1 FROM eazybusiness.dbo.tMandant;

PRINT 'Registriere Mandant: kMandant=' + CAST(@k AS varchar(10))
    + ', cName=' + @MandantName + ', cDB=' + @TargetDb;

------------------------------------------------------------
-- Ziel-DBs: alle in der Haupt-Registry gelisteten Mandanten-DBs
-- (die tatsaechlich existieren) + die neue Ziel-DB.
------------------------------------------------------------
DECLARE @dbs TABLE (name sysname PRIMARY KEY);

INSERT INTO @dbs (name)
SELECT DISTINCT m.cDB
FROM eazybusiness.dbo.tMandant m
WHERE m.cDB IS NOT NULL
  AND DB_ID(m.cDB) IS NOT NULL;

IF NOT EXISTS (SELECT 1 FROM @dbs WHERE name = @TargetDb)
    INSERT INTO @dbs (name) VALUES (@TargetDb);

------------------------------------------------------------
-- In jede Ziel-DB den Eintrag upserten (keyed by cDB).
------------------------------------------------------------
DECLARE @db sysname, @sql nvarchar(max);
DECLARE dbcur CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM @dbs;
OPEN dbcur;
FETCH NEXT FROM dbcur INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'
        IF EXISTS (SELECT 1 FROM ' + QUOTENAME(@db) + N'.dbo.tMandant WHERE cDB = @TargetDb)
            UPDATE ' + QUOTENAME(@db) + N'.dbo.tMandant
               SET cName = @MandantName
             WHERE cDB = @TargetDb;
        ELSE
            INSERT INTO ' + QUOTENAME(@db) + N'.dbo.tMandant (kMandant, cName, cDB)
            VALUES (@k, @MandantName, @TargetDb);';
    BEGIN TRY
        EXEC sp_executesql @sql,
            N'@TargetDb sysname, @MandantName nvarchar(255), @k int',
            @TargetDb = @TargetDb, @MandantName = @MandantName, @k = @k;
        PRINT '  [' + @db + '] tMandant gepflegt.';
    END TRY
    BEGIN CATCH
        PRINT '  [' + @db + '] FEHLER: ' + ERROR_MESSAGE();
    END CATCH
    FETCH NEXT FROM dbcur INTO @db;
END
CLOSE dbcur;
DEALLOCATE dbcur;

------------------------------------------------------------
-- 2) tBenutzerFirma: Benutzer<->Firma-Zuordnung fuer den neuen kMandant
--    aus dem Standard-Mandanten (kMandant 1) der Haupt-DB uebernehmen.
--    Ziel: Haupt-DB [eazybusiness] (massgeblich) + die Mandanten-Ziel-DB.
--    Idempotent: erst kMandant-Zeilen loeschen, dann neu befuellen.
------------------------------------------------------------
DECLARE @refMandant int = 1;   -- Standard-Mandant als Vorlage

IF @k = @refMandant
BEGIN
    PRINT 'HINWEIS: Ziel-kMandant = Standard-Mandant -> tBenutzerFirma-Seed uebersprungen.';
END
ELSE
BEGIN
    -- Ziel-DBs fuer den Seed: Haupt-DB + Mandanten-Ziel-DB
    DECLARE @seedDbs TABLE (name sysname PRIMARY KEY);
    INSERT INTO @seedDbs (name) VALUES (N'eazybusiness');
    IF NOT EXISTS (SELECT 1 FROM @seedDbs WHERE name = @TargetDb)
        INSERT INTO @seedDbs (name) VALUES (@TargetDb);

    DECLARE @sdb sysname, @seedSql nvarchar(max);
    DECLARE seedcur CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM @seedDbs;
    OPEN seedcur;
    FETCH NEXT FROM seedcur INTO @sdb;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        -- Nur Benutzer/Firmen uebernehmen, die in der Ziel-DB auch existieren
        -- (schuetzt vor FK-/Fremdschluessel-Problemen bei aelteren Klonen).
        SET @seedSql = N'
            DELETE FROM ' + QUOTENAME(@sdb) + N'.dbo.tBenutzerFirma
             WHERE kMandant = @k;
            INSERT INTO ' + QUOTENAME(@sdb) + N'.dbo.tBenutzerFirma (kBenutzer, kFirma, kMandant)
            SELECT bf.kBenutzer, bf.kFirma, @k
            FROM eazybusiness.dbo.tBenutzerFirma bf
            WHERE bf.kMandant = @refMandant
              AND EXISTS (SELECT 1 FROM ' + QUOTENAME(@sdb) + N'.dbo.tBenutzer b WHERE b.kBenutzer = bf.kBenutzer)
              AND EXISTS (SELECT 1 FROM ' + QUOTENAME(@sdb) + N'.dbo.tFirma   f WHERE f.kFirma   = bf.kFirma);';
        BEGIN TRY
            EXEC sp_executesql @seedSql,
                N'@k int, @refMandant int', @k = @k, @refMandant = @refMandant;
            PRINT '  [' + @sdb + '] tBenutzerFirma fuer kMandant '
                + CAST(@k AS varchar(10)) + ' aus Standard-Mandant uebernommen ('
                + CAST(@@ROWCOUNT AS varchar(10)) + ' Zuordnungen).';
        END TRY
        BEGIN CATCH
            PRINT '  [' + @sdb + '] tBenutzerFirma FEHLER: ' + ERROR_MESSAGE();
        END CATCH
        FETCH NEXT FROM seedcur INTO @sdb;
    END
    CLOSE seedcur;
    DEALLOCATE seedcur;
END

------------------------------------------------------------
-- Verifikation
------------------------------------------------------------
PRINT '--- Mandanten-Registry [eazybusiness] ---';
SELECT kMandant, cName, cDB FROM eazybusiness.dbo.tMandant ORDER BY kMandant;

PRINT '--- tBenutzerFirma je Mandant [eazybusiness] ---';
SELECT kMandant, COUNT(*) AS Zuordnungen
FROM eazybusiness.dbo.tBenutzerFirma
GROUP BY kMandant
ORDER BY kMandant;
GO
