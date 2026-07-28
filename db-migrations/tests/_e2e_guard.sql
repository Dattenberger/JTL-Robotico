-- ============================================================================
-- E2E-GUARD  — an den KOPF jedes Testskripts. Bricht ab, BEVOR ein Write laeuft,
-- sobald die Verbindung auf einen realen Server (PROD/TEST) deutet.
--
-- Verwendung (nur im sqlcmd-Mode):   :r ./_e2e_guard.sql
--   (aus einem Unterordner entsprechend  :r ../_e2e_guard.sql  o. ae.)
-- Fuer SSMS/GUI-Skripte den Block stattdessen an den Kopf kopieren.
--
-- Multi-Signal-Deny (defense-in-depth): schlaegt zu, sobald IRGENDein Merkmal auf
-- einen realen Server deutet — kein positiver @@SERVERNAME=Container-Match, weil
-- @@SERVERNAME im Container die kurze Container-ID zur Install-Zeit ist (nicht
-- vorhersagbar). Drei unabhaengige Signale:
--   (1) Deny-Liste realer Hostnamen (MachineName UND @@SERVERNAME),
--   (2) reale Server sind Windows-Auth-only (IsIntegratedSecurityOnly=1); der
--       E2E-Container laeuft Mixed-Mode (SA-SQL-Login) => 0,
--   (3) der E2E-Container ist Developer Edition.
--
-- THROW-Nummern 59001-59003 (und 59010 im G4-Scharf-Test) liegen bewusst
-- ausserhalb des Migrations-Bereichs (50xxx/51xxx), damit sie nicht mit der
-- Lint-Regel (k) "eindeutige THROW-Nummern" der grate-Ketten kollidieren.
--
-- Diese Datei ist KEINE Migration: sie liegt ausserhalb db-migrations/{eazybusiness,
-- global} (wird nicht gelintet) und in keinem grate-Ordner (wird nicht deployt).
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur/reports/migration-testplan/T5-umgebung-guards.md (G1)
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
