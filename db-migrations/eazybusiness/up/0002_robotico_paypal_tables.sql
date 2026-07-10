-- ============================================================================
-- 0002 — PayPal tables + settings seed (Ebene A, one-time)
-- ============================================================================
-- Creates the three Robotico PayPal tables and seeds the default settings rows.
-- Guarded (IF OBJECT_ID … IS NULL) so a re-run is harmless; the settings seed
-- uses MERGE WHEN NOT MATCHED so it only inserts missing keys and never
-- overwrites values a human has filled in (credentials stay empty here — never
-- seeded with real secrets).
--
-- Ported from WorkflowProcedures/PayPal/Add Procudures and Tables.sql (2026-07-10):
--   - removed `use eazybusiness` (grate selects the DB)
--   - kept only the DDL + settings seed; the PayPal API procedures from that file
--     moved to their own anytime files (sprocs/Robotico.spPaypal*.sql).
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§1 — Ebene-A port of the
--      PayPal table DDL + settings seed)
-- ============================================================================

-- ---- tPaypalAccessToken ----------------------------------------------------
-- Stores the OAuth token for PayPal communication. At most two rows: one for
-- production, one for sandbox (enforced by the UNIQUE bProduction column).
IF OBJECT_ID(N'Robotico.tPaypalAccessToken', N'U') IS NULL
BEGIN
    CREATE TABLE Robotico.tPaypalAccessToken
    (
        kKey              INTEGER IDENTITY (1, 1) PRIMARY KEY,
        cScope            NVARCHAR(MAX),
        cAccessToken      NVARCHAR(MAX),
        cTokenType        NVARCHAR(MAX),
        cAppID            NVARCHAR(MAX),
        nExpiresInSeconds INTEGER,
        dTokenCreated     DATETIME,
        bProduction       BIT UNIQUE NOT NULL
    );
    PRINT '+ Table Robotico.tPaypalAccessToken created';
END
GO

-- ---- tPaypalTrackingLog ----------------------------------------------------
-- Logs every tracking API call. Rows are purged after 30 days by the API procs.
IF OBJECT_ID(N'Robotico.tPaypalTrackingLog', N'U') IS NULL
BEGIN
    CREATE TABLE Robotico.tPaypalTrackingLog
    (
        kPaypalTrackingLog INTEGER IDENTITY (1, 1) PRIMARY KEY,
        bProduction        BIT,
        cQuelle            NVARCHAR(255),
        kInputKey          INTEGER,
        cBescheibung1      NVARCHAR(MAX),
        cBescheibung2      NVARCHAR(MAX),
        dErstellt          DATETIME
    );
    PRINT '+ Table Robotico.tPaypalTrackingLog created';
END
GO

-- ---- tPaypalSettings -------------------------------------------------------
-- Key/value configuration for the PayPal integration.
IF OBJECT_ID(N'Robotico.tPaypalSettings', N'U') IS NULL
BEGIN
    CREATE TABLE Robotico.tPaypalSettings
    (
        kSetting         INTEGER IDENTITY (1, 1) PRIMARY KEY,
        cKey             NVARCHAR(100) NOT NULL,
        cValue           NVARCHAR(MAX),
        cEigeneBemerkung NVARCHAR(MAX),
        cDokumentation   NVARCHAR(MAX)
    );
    CREATE UNIQUE INDEX IX_Robotico_tPaypalSettings_cKey ON Robotico.tPaypalSettings (cKey);
    PRINT '+ Table Robotico.tPaypalSettings created';
END
GO

-- ---- default settings seed (idempotent) ------------------------------------
-- Only inserts keys that are missing. Credential keys are seeded EMPTY — real
-- client-ids/secrets are entered by a human directly in the table, never in git.
DECLARE @tDefaultSettings TABLE
(
    cKey           NVARCHAR(MAX),
    cValue         NVARCHAR(MAX),
    cDokumentation NVARCHAR(MAX)
);

INSERT INTO @tDefaultSettings (cKey, cValue, cDokumentation)
VALUES ('bDisableSandbox', 'FALSE',
        'Wenn der Wert auf TRUE (Grossbuchstaben) gesetzt ist, wird der Produktivmodus verwendet. Ansonsten der Sandboxmodus.'),
       ('cPaypalBaseUrl', 'https://api-m.paypal.com',
        N'Url der PayPal Pruduktiv API. Format: https://url.tdl (ohne Slash am Ende).'),
       ('cPaypalBaseUrlSandbox', 'https://api-m.sandbox.paypal.com',
        N'Url der PayPal Sandbox API. Format: https://url.tdl (ohne Slash am Ende).'),
       ('cPaypalAuthUrlPath', '/v1/oauth2/token',
        'URL Pfad die Auth API. Mit dieser kann ein Token angefordert werden. Format: /path/path (Mit Slash am Anfang)'),
       ('cPaypalTrackingUrlPath', '/v1/shipping/trackers-batch',
        'URL Pfad die Tracking API. Format: /path/path (Mit Slash am Anfang)'),
       ('cPaypalClientId', '',
        N'Produktiv Client ID für die PayPal API. Kann im PayPal Developer Portal unter "Apps & Credentials" gefunden werden.'),
       ('cPaypalSecret', '',
        N'Produktiv Secret für die PayPal API. Kann im PayPal Developer Portal unter "Apps & Credentials" gefunden werden.'),
       ('cPaypalClientIdSandbox', '',
        N'Sandbox Client ID für die PayPal API. Kann im PayPal Developer Portal unter "Apps & Credentials" gefunden werden.'),
       ('cPaypalSecretSandbox', '',
        N'Sandbox Secret für die PayPal API. Kann im PayPal Developer Portal unter "Apps & Credentials" gefunden werden.');

MERGE INTO Robotico.tPaypalSettings AS Target
USING @tDefaultSettings AS Source
    ON Target.cKey = Source.cKey
WHEN NOT MATCHED BY TARGET THEN
    INSERT (cKey, cValue, cDokumentation)
    VALUES (Source.cKey, Source.cValue, Source.cDokumentation);
GO
