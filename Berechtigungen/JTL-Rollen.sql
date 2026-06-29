-- =====================================================================================
-- JTL-Rollen.sql   (Single Source of Truth fuer die Zugriffsprofile)
-- =====================================================================================
-- Definiert die Standard-Rollen fuer den Zugriff auf die JTL-DB eazybusiness und verwaltet
-- ihre Mitglieder. Statt jedem User einzeln Rechte zu geben, gibt es zwei Profile:
--
--   JTL_Reader  = Lesen (Mitglied von db_datareader)
--                 + EXECUTE auf unsere Custom-Schemas (Robotico, RoboticoEKL)
--   JTL_Writer  = Schreiben (Mitglied von db_datawriter)
--                 -> Lesen/Execute kommt aus JTL_Reader; Lese+Schreib-User bekommen BEIDE.
--
-- Warum eigene Rollen: An die festen Rollen (db_datareader/-writer) darf man KEINE
-- zusaetzlichen Rechte haengen (Msg 4617). Eine benutzerdefinierte Rolle darf man frei
-- bestuecken; sie wird als MITGLIED der festen Rolle gefuehrt und erbt deren Rechte.
--
-- Eigenschaften:
--   * Single Source of Truth: gepflegt wird nur die @Members-Liste unten.
--   * Idempotent / beliebig wiederholbar; nicht existierende Schemas/Principals werden
--     uebersprungen (z.B. RoboticoEKL bevor es angelegt ist).
--   * Additiv & sicher: vergibt nur, entzieht nichts. Das Aufraeumen der bisherigen
--     direkten Mitgliedschaften ist als optionaler, auskommentierter Block am Ende.
--
-- Ausfuehren (legt Rollen an / setzt Mitgliedschaften; nur als db_owner/db_securityadmin/sa):
--   sqlcmd -S VM-SQL2 -d eazybusiness -C -W -i "Berechtigungen/JTL-Rollen.sql"
-- =====================================================================================

SET NOCOUNT ON;
PRINT '== Datenbank: [' + DB_NAME() + '] ==';
PRINT '';

-- -------------------------------------------------------------------------------------
-- 1) Rollen anlegen
-- -------------------------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'JTL_Reader' AND type = 'R')
BEGIN CREATE ROLE JTL_Reader; PRINT 'Rolle [JTL_Reader] angelegt.'; END
ELSE PRINT 'Rolle [JTL_Reader] besteht bereits.';

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'JTL_Writer' AND type = 'R')
BEGIN CREATE ROLE JTL_Writer; PRINT 'Rolle [JTL_Writer] angelegt.'; END
ELSE PRINT 'Rolle [JTL_Writer] besteht bereits.';

-- -------------------------------------------------------------------------------------
-- 2) Basis-Rechte der Rollen
--    a) Lesen/Schreiben durch Mitgliedschaft in den festen Rollen erben
--    b) EXECUTE auf die Custom-Schemas fuer JTL_Reader
-- -------------------------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.database_role_members rm
               JOIN sys.database_principals r ON rm.role_principal_id = r.principal_id
               JOIN sys.database_principals m ON rm.member_principal_id = m.principal_id
               WHERE r.name = 'db_datareader' AND m.name = 'JTL_Reader')
    ALTER ROLE db_datareader ADD MEMBER JTL_Reader;

IF NOT EXISTS (SELECT 1 FROM sys.database_role_members rm
               JOIN sys.database_principals r ON rm.role_principal_id = r.principal_id
               JOIN sys.database_principals m ON rm.member_principal_id = m.principal_id
               WHERE r.name = 'db_datawriter' AND m.name = 'JTL_Writer')
    ALTER ROLE db_datawriter ADD MEMBER JTL_Writer;

IF EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'Robotico')
    GRANT EXECUTE ON SCHEMA::Robotico TO JTL_Reader;
IF EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'RoboticoEKL')
    GRANT EXECUTE ON SCHEMA::RoboticoEKL TO JTL_Reader;

PRINT 'Basis-Rechte gesetzt (Vererbung + EXECUTE auf vorhandene Custom-Schemas).';
PRINT '';

-- -------------------------------------------------------------------------------------
-- 3) Mitglieder   <<< HIER pflegen
--    AD-Gruppe deckt die Windows-Mitarbeiter zentral ab; reine SQL-User einzeln.
--    Lese+Schreib-User in BEIDE Rollen eintragen.
-- -------------------------------------------------------------------------------------
DECLARE @Members TABLE (RoleName sysname, PrincipalName sysname, PRIMARY KEY (RoleName, PrincipalName));
INSERT INTO @Members (RoleName, PrincipalName) VALUES
    (N'JTL_Reader', N'ZDBIKES\sql-jtl-users'),               -- AD-Gruppe: alle Windows-Mitarbeiter
    (N'JTL_Reader', N'dbuser_eazybusiness_kiana'),           -- SQL-User Kiana
    (N'JTL_Reader', N'dbuser_eazybusiness_sanda'),           -- SQL-User Sanda
    (N'JTL_Reader', N'dbuser_eazybusiness_jtl_datawow'),     -- Service: DataWow
    (N'JTL_Reader', N'dbuser_eazybusiness_powershell_read'), -- Service: PowerShell-Read
    (N'JTL_Reader', N'dbuser_eazybusiness_greyhound'),       -- Service: Greyhound
    (N'JTL_Reader', N'dbuser_eazybusiness_ekl_addin_readonly'), -- Service: EKL-AddIn (readonly)
    (N'JTL_Writer', N'dbuser_eazybusiness_kiana');           -- Kiana darf zusaetzlich schreiben

-- Anwenden: nur existierende Principals, nur wenn noch nicht Mitglied (idempotent)
DECLARE @role sysname, @p sysname, @sql nvarchar(max);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT RoleName, PrincipalName FROM @Members;
OPEN c;
FETCH NEXT FROM c INTO @role, @p;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @p)
        PRINT 'UEBERSPRUNGEN : Principal [' + @p + '] existiert nicht in dieser DB.';
    ELSE IF EXISTS (SELECT 1 FROM sys.database_role_members rm
                    JOIN sys.database_principals r ON rm.role_principal_id = r.principal_id
                    JOIN sys.database_principals m ON rm.member_principal_id = m.principal_id
                    WHERE r.name = @role AND m.name = @p)
        PRINT 'OK (bestand)  : [' + @p + '] ist bereits in [' + @role + '].';
    ELSE
    BEGIN
        SET @sql = N'ALTER ROLE ' + QUOTENAME(@role) + N' ADD MEMBER ' + QUOTENAME(@p) + N';';
        EXEC sp_executesql @sql;
        PRINT 'HINZUGEFUEGT  : [' + @p + '] -> [' + @role + '].';
    END
    FETCH NEXT FROM c INTO @role, @p;
END
CLOSE c;
DEALLOCATE c;

-- =====================================================================================
-- 4) OPTIONAL – Migration abschliessen (erst aktivieren, wenn oben verifiziert!)
--    Entfernt die bisherigen DIREKTEN Mitgliedschaften in db_datareader/db_datawriter
--    von den migrierten Principals, damit kuenftig allein JTL_Reader/JTL_Writer die
--    Quelle ist. Bewusst auskommentiert - zuerst additiv setzen + testen, dann aufraeumen.
--    JTL-System-/Service-Accounts (jtl1, dbuser_eazybusiness_jtl, docker1, ...) NICHT anfassen.
-- =====================================================================================
-- ALTER ROLE db_datareader DROP MEMBER [ZDBIKES\sql-jtl-users];
-- ALTER ROLE db_datareader DROP MEMBER [dbuser_eazybusiness_kiana];
-- ALTER ROLE db_datawriter DROP MEMBER [dbuser_eazybusiness_kiana];
-- ALTER ROLE db_datareader DROP MEMBER [dbuser_eazybusiness_sanda];
