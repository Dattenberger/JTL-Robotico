-- reset.internal_InvalidateCredentials  (Ebene B / global — pipeline step, job-only)
--
-- Ported from Projekte/Testsystem/invalidate-credentials-for-testing.sql (state
-- e6d7b2b). Clears secrets and repoints the JS-Shop to the developer's staging shop.
-- ShopUrl / ShopLicense are read from ops.Mandant by @MandantKey (uniform step
-- contract, EXT-2) and passed on as sp_executesql PARAMETERS — never concatenated into
-- SQL, D6 — instead of the source's SQLCMD $(...) variables.
--
-- Deviations from the source (documented, D4):
--   * The banking-anonymization blocks (tkontodaten / tinetzahlungsinfo) are NOT
--     ported here — they are fully covered by internal_AnonymizeCustomerData block 8,
--     which runs later in the pipeline (single source of truth, avoids drift).
--   * Per-statement PRINTs and the trailing verification SELECT are dropped (noise in
--     an automated job); progress is summarised into @StepLog / GetResetStatus.
--   * No wrapping transaction: each UPDATE auto-commits; a failure THROWs and the
--     orchestrator quarantines the clone as 'failed' for diagnosis.
--
-- @see docs/plans/2026-07-10 - mssql-ops-infrastruktur (§3)
CREATE OR ALTER PROCEDURE reset.internal_InvalidateCredentials
    @TargetDb   sysname,
    @RequestId  int,
    @MandantKey sysname
AS
BEGIN
    SET NOCOUNT ON;

    IF @TargetDb = N'eazybusiness' OR @TargetDb NOT LIKE N'eazybusiness[_]%'
        THROW 51030, 'internal_InvalidateCredentials refused: target is not a test-mandant clone.', 1;

    -- Each step reads its own inputs from ops.Mandant (EXT-2) — the orchestrator no
    -- longer routes per-step parameters.
    DECLARE @ShopUrl nvarchar(max), @ShopLicense nvarchar(max);
    SELECT @ShopUrl = ShopUrl, @ShopLicense = ShopLicense
    FROM ops.Mandant WHERE MandantKey = @MandantKey;

    -- Rows hit by the JS-Shop repoint; 0 => no matching shop row (PAR-4).
    DECLARE @ShopRepointRows int;

    DECLARE @exec nvarchar(300) = QUOTENAME(@TargetDb) + N'.sys.sp_executesql';
    DECLARE @batch nvarchar(max) = N'
        -- SMTP / e-mail
        UPDATE dbo.tEMailEinstellung
        SET cPasswortSMTP = '''',
            cNutzernameSmtp = CASE WHEN cNutzernameSmtp IS NOT NULL AND cNutzernameSmtp NOT LIKE ''%_deactivated''
                                   THEN cNutzernameSmtp + ''_deactivated'' ELSE cNutzernameSmtp END,
            cServerSMTP = CASE WHEN cServerSMTP IS NOT NULL AND cServerSMTP NOT LIKE ''%_deactivated''
                               THEN cServerSMTP + ''_deactivated'' ELSE cServerSMTP END,
            cSigPortalPasswort = '''', cSMIMEPasswort = '''';

        -- eBay
        UPDATE dbo.ebay_user
        SET Passwort = '''',
            Login = CASE WHEN Login IS NOT NULL AND Login NOT LIKE ''%_deactivated''
                         THEN Login + ''_deactivated'' ELSE Login END,
            cEbayUsername = CASE WHEN cEbayUsername IS NOT NULL AND cEbayUsername NOT LIKE ''%_deactivated''
                                 THEN cEbayUsername + ''_deactivated'' ELSE cEbayUsername END;
        -- eBay sync off (gesperrt accounts are skipped by the JTL worker).
        UPDATE dbo.ebay_user SET nGesperrt = 1 WHERE nGesperrt = 0;

        -- Amazon / OAuth
        UPDATE dbo.tOauthConfig
        SET cClientSecret = '''',
            cClientId = CASE WHEN cClientId IS NOT NULL AND cClientId NOT LIKE ''%_deactivated''
                             THEN cClientId + ''_deactivated'' ELSE cClientId END;
        UPDATE dbo.tOauthToken SET cAccessToken = '''', cRefreshToken = '''', nInvalid = 1;

        -- Repoint the real JS-Shop (nTyp=0, http URL) to the staging shop. Username /
        -- password are kept so colleagues need not re-enter them. Other platform rows
        -- (unicorn2 / Check24) are left untouched.
        UPDATE dbo.tShop
        SET cServerWeb = @ShopUrl, cAPIKey = @ShopLicense
        WHERE nTyp = 0 AND cServerWeb LIKE ''http%'';
        SET @ShopRepointRows = @@ROWCOUNT;   -- captured immediately (PAR-4)

        -- PayPal (Robotico schema, guarded)
        IF OBJECT_ID(''Robotico.tPaypalAccessToken'') IS NOT NULL
            UPDATE Robotico.tPaypalAccessToken
            SET cAccessToken = '''',
                cAppID = CASE WHEN cAppID IS NOT NULL AND cAppID NOT LIKE ''%_deactivated''
                              THEN cAppID + ''_deactivated'' ELSE cAppID END;
        IF OBJECT_ID(''Robotico.tPaypalSettings'') IS NOT NULL
            UPDATE Robotico.tPaypalSettings SET cValue = ''''
            WHERE cValue IS NOT NULL AND LEN(TRIM(cValue)) > 0
              AND (cKey LIKE ''%password%'' OR cKey LIKE ''%secret%'' OR cKey LIKE ''%token%''
                   OR cKey LIKE ''%key%'' OR cKey LIKE ''%credential%'');

        -- Shipping accounts
        UPDATE dbo.tShipperAccount
        SET cPassword = '''',
            cUserName = CASE WHEN cUserName IS NOT NULL AND cUserName NOT LIKE ''%_deactivated''
                             THEN cUserName + ''_deactivated'' ELSE cUserName END,
            cIban = '''', cBic = '''', kOAuthToken = NULL;

        -- Marketplace / sync tokens (guarded)
        IF OBJECT_ID(''SCX.tRefreshToken'') IS NOT NULL
            UPDATE SCX.tRefreshToken SET cRefreshToken = '''', cSessionToken = '''';
        IF OBJECT_ID(''Sync.tAuthCode'') IS NOT NULL
            UPDATE Sync.tAuthCode SET cAuthToken = '''' WHERE cAuthToken IS NOT NULL AND LEN(TRIM(cAuthToken)) > 0;
        IF OBJECT_ID(''BI.tAbgleichToken'') IS NOT NULL
            UPDATE BI.tAbgleichToken SET cAbgleichToken = '''' WHERE cAbgleichToken IS NOT NULL AND LEN(TRIM(cAbgleichToken)) > 0;

        -- Vouchers / fulfilment (guarded)
        IF OBJECT_ID(''dbo.tVouchersToken'') IS NOT NULL
            UPDATE dbo.tVouchersToken SET cAccessToken = ''''
            WHERE cAccessToken IS NOT NULL AND cAccessToken <> ''NULL'' AND LEN(TRIM(cAccessToken)) > 0;
        IF OBJECT_ID(''FulfillmentNetwork.tLogin'') IS NOT NULL
            UPDATE FulfillmentNetwork.tLogin
            SET cApiToken = '''',
                cUserId = CASE WHEN cUserId IS NOT NULL AND cUserId NOT LIKE ''%_deactivated''
                               THEN cUserId + ''_deactivated'' ELSE cUserId END;

        -- Shipping-platform user data (guarded)
        IF OBJECT_ID(''Shipping.tVersandplattformUserData'') IS NOT NULL
        BEGIN
            UPDATE Shipping.tVersandplattformUserData SET cValue = ''''
            WHERE cValue IS NOT NULL AND LEN(TRIM(cValue)) > 0
              AND (cField LIKE ''%password%'' OR cField LIKE ''%passwort%'' OR cField LIKE ''%secret%''
                   OR cField LIKE ''%token%'' OR cField LIKE ''%key%'');
            UPDATE Shipping.tVersandplattformUserData
            SET cValue = CASE WHEN cValue IS NOT NULL AND cValue NOT LIKE ''%_deactivated''
                              THEN cValue + ''_deactivated'' ELSE cValue END
            WHERE cValue IS NOT NULL AND LEN(TRIM(cValue)) > 0 AND cValue NOT LIKE ''%_deactivated''
              AND (cField LIKE ''%user%'' OR cField LIKE ''%benutzer%'' OR cField LIKE ''%login%'' OR cField LIKE ''%username%'');
        END

        -- Web / FTP shipping (guarded). tWebshopModule is intentionally NOT touched
        -- (plugin-module licenses, not shop connection credentials).
        IF OBJECT_ID(''dbo.twebversand'') IS NOT NULL
            UPDATE dbo.twebversand
            SET cPasswortWeb = '''',
                cBenutzerWeb = CASE WHEN cBenutzerWeb IS NOT NULL AND cBenutzerWeb NOT LIKE ''%_deactivated''
                                    THEN cBenutzerWeb + ''_deactivated'' ELSE cBenutzerWeb END,
                cPasswortFtp = '''',
                cBenutzerFtp = CASE WHEN cBenutzerFtp IS NOT NULL AND cBenutzerFtp NOT LIKE ''%_deactivated''
                                    THEN cBenutzerFtp + ''_deactivated'' ELSE cBenutzerFtp END,
                cAPIKEY = '''';

        -- License / auth (guarded)
        IF OBJECT_ID(''dbo.tLizenz'') IS NOT NULL
            UPDATE dbo.tLizenz
            SET cAuthId = CASE WHEN cAuthId IS NOT NULL AND cAuthId NOT LIKE ''%_deactivated''
                               THEN LEFT(cAuthId, 15) + ''_deactivated'' ELSE cAuthId END,
                cAuthToken = '''';
        IF OBJECT_ID(''dbo.tBenutzerLogin'') IS NOT NULL
            UPDATE dbo.tBenutzerLogin SET cToken = '''' WHERE cToken IS NOT NULL AND LEN(TRIM(cToken)) > 0;

        -- DATEV (guarded)
        IF OBJECT_ID(''dbo.tDatevConfig'') IS NOT NULL
            UPDATE dbo.tDatevConfig
            SET tOauthConfig_cId = CASE WHEN tOauthConfig_cId IS NOT NULL AND tOauthConfig_cId NOT LIKE ''%_deactivated''
                                        THEN tOauthConfig_cId + ''_deactivated'' ELSE tOauthConfig_cId END
            WHERE tOauthConfig_cId IS NOT NULL AND LEN(TRIM(tOauthConfig_cId)) > 0;
    ';
    EXEC @exec @batch,
         N'@ShopUrl nvarchar(max), @ShopLicense nvarchar(max), @ShopRepointRows int OUTPUT',
         @ShopUrl = @ShopUrl, @ShopLicense = @ShopLicense, @ShopRepointRows = @ShopRepointRows OUTPUT;

    -- No THROW: 0 matching shop rows is legitimate for some clones, but must be
    -- visible in GetResetStatus so a silently un-repointed shop is not mistaken for
    -- a staging repoint (PAR-4).
    IF ISNULL(@ShopRepointRows, 0) = 0
        EXEC reset.internal_LogStep @RequestId,
             N'WARN shop-repoint: no matching JS-Shop row (nTyp=0 + http URL) — shop NOT repointed to staging';

    DECLARE @credMsg nvarchar(200) =
        N'credentials: cleared + JS-Shop repointed to staging ('
        + CAST(ISNULL(@ShopRepointRows, 0) AS nvarchar(10)) + N' row(s))';
    EXEC reset.internal_LogStep @RequestId, @credMsg;
END
GO
