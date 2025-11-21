-- =================================================================
-- JTL credential invalidation for test system (CORRECTED)
-- Clears passwords and adds "_deactivated" to usernames/server names
-- =================================================================

USE [$(TargetDb)]
GO

-- SAFETY CHECK: Ensure Target Database is NOT eazybusiness
IF DB_NAME() = 'eazybusiness' OR '$(TargetDb)' = 'eazybusiness'
    BEGIN
        RAISERROR('CRITICAL ERROR: Target database cannot be [eazybusiness]! Operation aborted.', 20, 1) WITH LOG;
        RETURN;
    END

BEGIN TRANSACTION

BEGIN TRY
    PRINT 'Starting credential deactivation for test system...'
    
    -- =================================================================
    -- Deactivate SMTP/Email credentials
    -- =================================================================
    PRINT 'Deactivating SMTP/Email credentials...'
    
    UPDATE dbo.tEMailEinstellung
    SET 
        cPasswortSMTP = '',
        cNutzernameSmtp = CASE 
            WHEN cNutzernameSmtp IS NOT NULL AND cNutzernameSmtp NOT LIKE '%_deactivated' 
            THEN cNutzernameSmtp + '_deactivated'
            ELSE cNutzernameSmtp
        END,
        cServerSMTP = CASE 
            WHEN cServerSMTP IS NOT NULL AND cServerSMTP NOT LIKE '%_deactivated' 
            THEN cServerSMTP + '_deactivated'
            ELSE cServerSMTP
        END,
        cSigPortalPasswort = '',
        cSMIMEPasswort = ''
    WHERE (cPasswortSMTP IS NOT NULL AND LEN(TRIM(cPasswortSMTP)) > 0)
       OR (cNutzernameSmtp IS NOT NULL AND LEN(TRIM(cNutzernameSmtp)) > 0)
       OR (cServerSMTP IS NOT NULL AND LEN(TRIM(cServerSMTP)) > 0)
       OR (cSigPortalPasswort IS NOT NULL AND LEN(TRIM(cSigPortalPasswort)) > 0)
       OR (cSMIMEPasswort IS NOT NULL AND LEN(TRIM(cSMIMEPasswort)) > 0);
    
    PRINT 'SMTP credentials deactivated: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' records'
    
    -- =================================================================
    -- Deactivate eBay credentials
    -- =================================================================
    PRINT 'Deactivating eBay credentials...'
    
    UPDATE dbo.ebay_user 
    SET 
        Passwort = '',
        Login = CASE 
            WHEN Login IS NOT NULL AND Login NOT LIKE '%_deactivated' 
            THEN Login + '_deactivated'
            ELSE Login
        END,
        cEbayUsername = CASE 
            WHEN cEbayUsername IS NOT NULL AND cEbayUsername NOT LIKE '%_deactivated' 
            THEN cEbayUsername + '_deactivated'
            ELSE cEbayUsername
        END
    WHERE (Login IS NOT NULL AND LEN(TRIM(Login)) > 0)
       OR (Passwort IS NOT NULL AND LEN(TRIM(Passwort)) > 0)
       OR (cEbayUsername IS NOT NULL AND LEN(TRIM(cEbayUsername)) > 0);
    
    PRINT 'eBay credentials deactivated: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' records'
    
    -- =================================================================
    -- Deactivate Amazon/OAuth credentials
    -- =================================================================
    PRINT 'Deactivating Amazon/OAuth credentials...'
    
    -- Clear OAuth Client Secrets and deactivate Client IDs
    UPDATE dbo.tOauthConfig 
    SET 
        cClientSecret = '',
        cClientId = CASE 
            WHEN cClientId IS NOT NULL AND cClientId NOT LIKE '%_deactivated' 
            THEN cClientId + '_deactivated'
            ELSE cClientId
        END
    WHERE (cClientSecret IS NOT NULL AND LEN(TRIM(cClientSecret)) > 0) 
       OR (cClientId IS NOT NULL AND LEN(TRIM(cClientId)) > 0);
    
    PRINT 'OAuth Config deactivated: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' records'
    
    -- Clear OAuth Tokens and mark as invalid
    UPDATE dbo.tOauthToken 
    SET 
        cAccessToken = '',
        cRefreshToken = '',
        nInvalid = 1
    WHERE (cAccessToken IS NOT NULL AND LEN(TRIM(cAccessToken)) > 0) 
       OR (cRefreshToken IS NOT NULL AND LEN(TRIM(cRefreshToken)) > 0);
    
    PRINT 'OAuth Tokens deactivated: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' records'
    
    -- =================================================================
    -- Deactivate Online shop/Webshop credentials
    -- =================================================================
    PRINT 'Deactivating Online shop credentials...'
    
    UPDATE dbo.tShop 
    SET 
        cAPIKey = '',
        cPasswortWeb = '',
        cBenutzerWeb = CASE 
            WHEN cBenutzerWeb IS NOT NULL AND cBenutzerWeb NOT LIKE '%_deactivated' 
            THEN cBenutzerWeb + '_deactivated'
            ELSE cBenutzerWeb
        END,
        cServerWeb = CASE 
            WHEN cServerWeb IS NOT NULL AND cServerWeb NOT LIKE '%_deactivated' 
            THEN cServerWeb + '_deactivated'
            ELSE cServerWeb
        END
    WHERE (cAPIKey IS NOT NULL AND LEN(TRIM(cAPIKey)) > 0)
       OR (cPasswortWeb IS NOT NULL AND LEN(TRIM(cPasswortWeb)) > 0)
       OR (cBenutzerWeb IS NOT NULL AND LEN(TRIM(cBenutzerWeb)) > 0)
       OR (cServerWeb IS NOT NULL AND LEN(TRIM(cServerWeb)) > 0);
    
    PRINT 'Shop credentials deactivated: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' records'

    
    -- =================================================================
    -- Deactivate PayPal credentials
    -- =================================================================
    PRINT 'Deactivating PayPal credentials...'
    
    IF OBJECT_ID('Robotico.tPaypalAccessToken') IS NOT NULL
    BEGIN
        UPDATE Robotico.tPaypalAccessToken
        SET
            cAccessToken = '',
            cAppID = CASE
                WHEN cAppID IS NOT NULL AND cAppID NOT LIKE '%_deactivated'
                THEN cAppID + '_deactivated'
                ELSE cAppID
            END
        WHERE (cAccessToken IS NOT NULL AND LEN(TRIM(cAccessToken)) > 0)
           OR (cAppID IS NOT NULL AND LEN(TRIM(cAppID)) > 0);

        PRINT 'PayPal credentials deactivated: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' records'
    END
    ELSE
        PRINT 'PayPal table not found - skipped'

    -- Clear PayPal Settings
    IF OBJECT_ID('Robotico.tPaypalSettings') IS NOT NULL
    BEGIN
        UPDATE Robotico.tPaypalSettings
        SET cValue = ''
        WHERE cValue IS NOT NULL
          AND LEN(TRIM(cValue)) > 0
          AND (cKey LIKE '%password%'
               OR cKey LIKE '%secret%'
               OR cKey LIKE '%token%'
               OR cKey LIKE '%key%'
               OR cKey LIKE '%credential%');

        PRINT 'PayPal settings cleared: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' records'
    END
    ELSE
        PRINT 'Robotico.tPaypalSettings table not found - skipped'
    
    -- =================================================================
    -- Deactivate Shipping credentials
    -- =================================================================
    PRINT 'Deactivating Shipping credentials...'
    
    UPDATE dbo.tShipperAccount
    SET
        cPassword = '',
        cUserName = CASE
            WHEN cUserName IS NOT NULL AND cUserName NOT LIKE '%_deactivated'
            THEN cUserName + '_deactivated'
            ELSE cUserName
        END,
        cIban = '',
        cBic = '',
        kOAuthToken = NULL
    WHERE (cUserName IS NOT NULL AND LEN(TRIM(cUserName)) > 0)
       OR (cPassword IS NOT NULL AND LEN(TRIM(cPassword)) > 0)
       OR (cIban IS NOT NULL AND LEN(TRIM(cIban)) > 0)
       OR (cBic IS NOT NULL AND LEN(TRIM(cBic)) > 0)
       OR (kOAuthToken IS NOT NULL);

    PRINT 'Shipping credentials deactivated: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' records'
    
    -- =================================================================
    -- Deactivate additional OAuth & authentication tokens
    -- =================================================================
    PRINT 'Deactivating additional OAuth & authentication tokens...'

    -- Clear SCX Marketplace Refresh Tokens
    IF OBJECT_ID('SCX.tRefreshToken') IS NOT NULL
    BEGIN
        UPDATE SCX.tRefreshToken
        SET
            cRefreshToken = '',
            cSessionToken = ''
        WHERE (cRefreshToken IS NOT NULL AND LEN(TRIM(cRefreshToken)) > 0)
           OR (cSessionToken IS NOT NULL AND LEN(TRIM(cSessionToken)) > 0);

        PRINT 'SCX Refresh Tokens cleared: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' records'
    END
    ELSE
        PRINT 'SCX.tRefreshToken table not found - skipped'

    -- Clear Sync Authentication Codes
    IF OBJECT_ID('Sync.tAuthCode') IS NOT NULL
    BEGIN
        UPDATE Sync.tAuthCode
        SET cAuthToken = ''
        WHERE cAuthToken IS NOT NULL
          AND LEN(TRIM(cAuthToken)) > 0;

        PRINT 'Sync Auth Tokens cleared: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' records'
    END
    ELSE
        PRINT 'Sync.tAuthCode table not found - skipped'

    -- Clear BI Synchronization Tokens
    IF OBJECT_ID('BI.tAbgleichToken') IS NOT NULL
    BEGIN
        UPDATE BI.tAbgleichToken
        SET cAbgleichToken = ''
        WHERE cAbgleichToken IS NOT NULL
          AND LEN(TRIM(cAbgleichToken)) > 0;

        PRINT 'BI Sync Tokens cleared: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' records'
    END
    ELSE
        PRINT 'BI.tAbgleichToken table not found - skipped'

    -- =================================================================
    -- Deactivate additional tokens (if present)
    -- =================================================================
    PRINT 'Deactivating additional tokens...'
    
    IF OBJECT_ID('dbo.tVouchersToken') IS NOT NULL
    BEGIN
        UPDATE dbo.tVouchersToken 
        SET cAccessToken = ''
        WHERE cAccessToken IS NOT NULL 
          AND cAccessToken != 'NULL' 
          AND LEN(TRIM(cAccessToken)) > 0;
        
        PRINT 'Voucher Token deactivated: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' records'
    END
    ELSE
        PRINT 'tVouchersToken table not found - skipped'
    
    IF OBJECT_ID('FulfillmentNetwork.tLogin') IS NOT NULL
    BEGIN
        UPDATE FulfillmentNetwork.tLogin 
        SET 
            cApiToken = '',
            cUserId = CASE 
                WHEN cUserId IS NOT NULL AND cUserId NOT LIKE '%_deactivated' 
                THEN cUserId + '_deactivated'
                ELSE cUserId
            END
        WHERE (cApiToken IS NOT NULL AND LEN(TRIM(cApiToken)) > 0) 
           OR (cUserId IS NOT NULL AND LEN(TRIM(cUserId)) > 0);
        
        PRINT 'Fulfillment Network deactivated: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' records'
    END
    ELSE
        PRINT 'FulfillmentNetwork.tLogin table not found - skipped'
    
    -- =================================================================
    -- Deactivate shipping platform data (if present)
    -- =================================================================
    PRINT 'Deactivating shipping platform data...'
    
    IF OBJECT_ID('Shipping.tVersandplattformUserData') IS NOT NULL
    BEGIN
        -- Clear password-like fields
        UPDATE Shipping.tVersandplattformUserData 
        SET cValue = ''
        WHERE cValue IS NOT NULL 
          AND LEN(TRIM(cValue)) > 0
          AND (cField LIKE '%password%' 
               OR cField LIKE '%passwort%' 
               OR cField LIKE '%secret%' 
               OR cField LIKE '%token%'
               OR cField LIKE '%key%');
        
        DECLARE @passwordDeleted INT = @@ROWCOUNT;
        
        -- Deactivate usernames
        UPDATE Shipping.tVersandplattformUserData 
        SET cValue = CASE 
            WHEN cValue IS NOT NULL AND cValue NOT LIKE '%_deactivated' 
            THEN cValue + '_deactivated'
            ELSE cValue
        END
        WHERE cValue IS NOT NULL 
          AND LEN(TRIM(cValue)) > 0
          AND cValue NOT LIKE '%_deactivated'
          AND (cField LIKE '%user%' 
               OR cField LIKE '%benutzer%' 
               OR cField LIKE '%login%'
               OR cField LIKE '%username%');
        
        PRINT 'Shipping platform passwords cleared: ' + CAST(@passwordDeleted AS VARCHAR(10)) + ' records'
        PRINT 'Shipping platform usernames deactivated: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' records'
    END
    ELSE
        PRINT 'Shipping.tVersandplattformUserData table not found - skipped'

    -- =================================================================
    -- Deactivate FTP & Web credentials
    -- =================================================================
    PRINT 'Deactivating FTP & Web credentials...'

    -- Clear Web/FTP shipping credentials (twebversand)
    IF OBJECT_ID('dbo.twebversand') IS NOT NULL
    BEGIN
        UPDATE dbo.twebversand
        SET
            cPasswortWeb = '',
            cBenutzerWeb = CASE
                WHEN cBenutzerWeb IS NOT NULL AND cBenutzerWeb NOT LIKE '%_deactivated'
                THEN cBenutzerWeb + '_deactivated'
                ELSE cBenutzerWeb
            END,
            cPasswortFtp = '',
            cBenutzerFtp = CASE
                WHEN cBenutzerFtp IS NOT NULL AND cBenutzerFtp NOT LIKE '%_deactivated'
                THEN cBenutzerFtp + '_deactivated'
                ELSE cBenutzerFtp
            END,
            cAPIKEY = ''
        WHERE (cPasswortWeb IS NOT NULL AND LEN(TRIM(cPasswortWeb)) > 0)
           OR (cBenutzerWeb IS NOT NULL AND LEN(TRIM(cBenutzerWeb)) > 0)
           OR (cPasswortFtp IS NOT NULL AND LEN(TRIM(cPasswortFtp)) > 0)
           OR (cBenutzerFtp IS NOT NULL AND LEN(TRIM(cBenutzerFtp)) > 0)
           OR (cAPIKEY IS NOT NULL AND LEN(TRIM(cAPIKEY)) > 0);

        PRINT 'Web/FTP shipping credentials cleared: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' records'
    END
    ELSE
        PRINT 'dbo.twebversand table not found - skipped'

    -- Clear Webshop Module credentials (tWebshopModule)
    IF OBJECT_ID('dbo.tWebshopModule') IS NOT NULL
    BEGIN
        UPDATE dbo.tWebshopModule
        SET
            cAPIKey = CASE 
                WHEN cAPIKey IS NOT NULL AND cAPIKey NOT LIKE '%_deactivated' 
                THEN cAPIKey + '_deactivated'
                ELSE cAPIKey
            END,
            cLizenzkey = CASE 
                WHEN cLizenzkey IS NOT NULL AND cLizenzkey NOT LIKE '%_deactivated' 
                THEN cLizenzkey + '_deactivated'
                ELSE cLizenzkey
            END
        WHERE (cAPIKey IS NOT NULL AND LEN(TRIM(cAPIKey)) > 0)
           OR (cLizenzkey IS NOT NULL AND LEN(TRIM(cLizenzkey)) > 0);

        PRINT 'Webshop module credentials cleared: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' records'
    END
    ELSE
        PRINT 'dbo.tWebshopModule table not found - skipped'

    -- =================================================================
    -- Deactivate Banking/Payment credentials
    -- =================================================================
    PRINT 'Deactivating Banking and Payment credentials...'

    -- Clear customer and supplier account data (tkontodaten)
    -- Using anonymized bank names (Bank_ID_1, Bank_ID_2, ...)
    ;WITH BankNameMapping AS (
        SELECT
            kKontoDaten,
            'Bank_ID_' + CAST(ROW_NUMBER() OVER (ORDER BY kKontoDaten) AS VARCHAR(10)) AS NewBankName
        FROM dbo.tkontodaten
        WHERE cBankName IS NOT NULL AND LEN(TRIM(cBankName)) > 0
    )
    UPDATE t
    SET
        cBankName = m.NewBankName,
        cBLZ = '',
        cKontoNr = '',
        cKartenNr = '',
        cGueltigkeit = '',
        cCVV = '',
        cKartenTyp = '',
        cInhaber = '',
        cIBAN = '',
        cBIC = ''
    FROM dbo.tkontodaten t
    INNER JOIN BankNameMapping m ON t.kKontoDaten = m.kKontoDaten;

    -- Clear additional fields for records without bank name
    UPDATE dbo.tkontodaten
    SET
        cBLZ = '',
        cKontoNr = '',
        cKartenNr = '',
        cGueltigkeit = '',
        cCVV = '',
        cKartenTyp = '',
        cInhaber = '',
        cIBAN = '',
        cBIC = ''
    WHERE (cBankName IS NULL OR LEN(TRIM(cBankName)) = 0)
      AND ((cBLZ IS NOT NULL AND LEN(TRIM(cBLZ)) > 0)
       OR (cKontoNr IS NOT NULL AND LEN(TRIM(cKontoNr)) > 0)
       OR (cKartenNr IS NOT NULL AND LEN(TRIM(cKartenNr)) > 0)
       OR (cGueltigkeit IS NOT NULL AND LEN(TRIM(cGueltigkeit)) > 0)
       OR (cCVV IS NOT NULL AND LEN(TRIM(cCVV)) > 0)
       OR (cKartenTyp IS NOT NULL AND LEN(TRIM(cKartenTyp)) > 0)
       OR (cInhaber IS NOT NULL AND LEN(TRIM(cInhaber)) > 0)
       OR (cIBAN IS NOT NULL AND LEN(TRIM(cIBAN)) > 0)
       OR (cBIC IS NOT NULL AND LEN(TRIM(cBIC)) > 0));

    PRINT 'Account data (tkontodaten) anonymized: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' records'

    -- Clear online order payment information (tinetzahlungsinfo)
    -- Using anonymized bank names (Bank_ID_1, Bank_ID_2, ...)
    ;WITH BankNameMapping AS (
        SELECT
            kInetZahlungsInfo,
            'Bank_ID_' + CAST(ROW_NUMBER() OVER (ORDER BY kInetZahlungsInfo) AS VARCHAR(10)) AS NewBankName
        FROM dbo.tinetzahlungsinfo
        WHERE cBankName IS NOT NULL AND LEN(TRIM(cBankName)) > 0
    )
    UPDATE t
    SET
        cBankName = m.NewBankName,
        cBLZ = '',
        cKontoNr = '',
        cKartenNr = '',
        cGueltigkeit = '',
        cCVV = '',
        cKartenTyp = '',
        cInhaber = '',
        cIBAN = '',
        cBIC = ''
    FROM dbo.tinetzahlungsinfo t
    INNER JOIN BankNameMapping m ON t.kInetZahlungsInfo = m.kInetZahlungsInfo;

    -- Clear additional fields for records without bank name
    UPDATE dbo.tinetzahlungsinfo
    SET
        cBLZ = '',
        cKontoNr = '',
        cKartenNr = '',
        cGueltigkeit = '',
        cCVV = '',
        cKartenTyp = '',
        cInhaber = '',
        cIBAN = '',
        cBIC = ''
    WHERE (cBankName IS NULL OR LEN(TRIM(cBankName)) = 0)
      AND ((cBLZ IS NOT NULL AND LEN(TRIM(cBLZ)) > 0)
       OR (cKontoNr IS NOT NULL AND LEN(TRIM(cKontoNr)) > 0)
       OR (cKartenNr IS NOT NULL AND LEN(TRIM(cKartenNr)) > 0)
       OR (cGueltigkeit IS NOT NULL AND LEN(TRIM(cGueltigkeit)) > 0)
       OR (cCVV IS NOT NULL AND LEN(TRIM(cCVV)) > 0)
       OR (cKartenTyp IS NOT NULL AND LEN(TRIM(cKartenTyp)) > 0)
       OR (cInhaber IS NOT NULL AND LEN(TRIM(cInhaber)) > 0)
       OR (cIBAN IS NOT NULL AND LEN(TRIM(cIBAN)) > 0)
       OR (cBIC IS NOT NULL AND LEN(TRIM(cBIC)) > 0));

    PRINT 'Online payment info (tinetzahlungsinfo) anonymized: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' records'

    -- =================================================================
    -- Deactivate License & Authentication credentials
    -- =================================================================
    PRINT 'Deactivating License & Authentication credentials...'

    -- Clear License Authentication
    IF OBJECT_ID('dbo.tLizenz') IS NOT NULL
    BEGIN
        UPDATE dbo.tLizenz
        SET
            cAuthId = CASE
                WHEN cAuthId IS NOT NULL AND cAuthId NOT LIKE '%_deactivated'
                THEN LEFT(cAuthId, 15) + '_deactivated'
                ELSE cAuthId
            END,
            cAuthToken = ''
        WHERE (cAuthId IS NOT NULL AND LEN(TRIM(cAuthId)) > 0)
           OR (cAuthToken IS NOT NULL AND LEN(TRIM(cAuthToken)) > 0);

        PRINT 'License credentials cleared: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' records'
    END
    ELSE
        PRINT 'dbo.tLizenz table not found - skipped'

    -- Clear User Login Tokens
    IF OBJECT_ID('dbo.tBenutzerLogin') IS NOT NULL
    BEGIN
        UPDATE dbo.tBenutzerLogin
        SET cToken = ''
        WHERE cToken IS NOT NULL
          AND LEN(TRIM(cToken)) > 0;

        PRINT 'User login tokens cleared: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' records'
    END
    ELSE
        PRINT 'dbo.tBenutzerLogin table not found - skipped'

    -- =================================================================
    -- Deactivate DATEV Integration (German Accounting)
    -- =================================================================
    PRINT 'Deactivating DATEV Integration...'

    -- Deactivate DATEV OAuth Config
    IF OBJECT_ID('dbo.tDatevConfig') IS NOT NULL
    BEGIN
        UPDATE dbo.tDatevConfig
        SET tOauthConfig_cId = CASE
                WHEN tOauthConfig_cId IS NOT NULL AND tOauthConfig_cId NOT LIKE '%_deactivated'
                THEN tOauthConfig_cId + '_deactivated'
                ELSE tOauthConfig_cId
            END
        WHERE tOauthConfig_cId IS NOT NULL
          AND LEN(TRIM(tOauthConfig_cId)) > 0;

        PRINT 'DATEV OAuth config deactivated: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' records'
    END
    ELSE
        PRINT 'dbo.tDatevConfig table not found - skipped'

    -- =================================================================
    -- Completion
    -- =================================================================
    PRINT 'Credentials successfully deactivated for test system!'
    
    -- Commit transaction
    COMMIT TRANSACTION
    
    PRINT 'Transaction completed successfully.'

END TRY
BEGIN CATCH
    -- Rollback on error
    ROLLBACK TRANSACTION
    
    PRINT 'ERROR while deactivating credentials:'
    PRINT 'Error number: ' + CAST(ERROR_NUMBER() AS VARCHAR(10))
    PRINT 'Error message: ' + ERROR_MESSAGE()
    PRINT 'Transaction has been rolled back.';
    
    -- Re-throw error
    THROW 50000, 'Error occurred while deactivating credentials.', 1;
END CATCH

GO

-- =================================================================
-- Verification: Show all credentials (deactivated and active)
-- =================================================================
PRINT 'Verifying credentials:'

SELECT 'SMTP User' AS Type, cNutzernameSmtp AS Value, 
       CASE WHEN cPasswortSMTP = '' THEN 'Password cleared' ELSE 'Password present' END AS Status
FROM dbo.tEMailEinstellung 
WHERE cNutzernameSmtp IS NOT NULL

UNION ALL

SELECT 'SMTP Server' AS Type, cServerSMTP AS Value,
       CASE WHEN cPasswortSMTP = '' THEN 'Password cleared' ELSE 'Password present' END AS Status
FROM dbo.tEMailEinstellung 
WHERE cServerSMTP IS NOT NULL

UNION ALL

SELECT 'eBay Login' AS Type, Login AS Value,
       CASE WHEN Passwort = '' THEN 'Password cleared' ELSE 'Password present' END AS Status
FROM dbo.ebay_user 
WHERE Login IS NOT NULL

UNION ALL

SELECT 'OAuth Client' AS Type, cClientId AS Value,
       CASE WHEN cClientSecret = '' THEN 'Secret cleared' ELSE 'Secret present' END AS Status
FROM dbo.tOauthConfig 
WHERE cClientId IS NOT NULL

UNION ALL

SELECT 'Shop User' AS Type, cBenutzerWeb AS Value,
       CASE WHEN cPasswortWeb = '' THEN 'Password cleared' ELSE 'Password present' END AS Status
FROM dbo.tShop 
WHERE cBenutzerWeb IS NOT NULL

UNION ALL

SELECT 'Shop Server' AS Type, cServerWeb AS Value,
       CASE WHEN cPasswortWeb = '' THEN 'Password cleared' ELSE 'Password present' END AS Status
FROM dbo.tShop
WHERE cServerWeb IS NOT NULL

UNION ALL

SELECT 'Banking (tkontodaten)' AS Type,
       'Records with data: ' + CAST(COUNT(*) AS VARCHAR(10)) AS Value,
       CASE WHEN SUM(CASE WHEN cIBAN = '' AND cBIC = '' AND cKontoNr = '' AND cKartenNr = '' AND cCVV = '' THEN 1 ELSE 0 END) = COUNT(*)
            THEN 'All cleared'
            ELSE 'Data present'
       END AS Status
FROM dbo.tkontodaten
WHERE kKontoDaten IS NOT NULL

UNION ALL

SELECT 'Banking (tinetzahlungsinfo)' AS Type,
       'Records with data: ' + CAST(COUNT(*) AS VARCHAR(10)) AS Value,
       CASE WHEN SUM(CASE WHEN cIBAN = '' AND cBIC = '' AND cKontoNr = '' AND cKartenNr = '' AND cCVV = '' THEN 1 ELSE 0 END) = COUNT(*)
            THEN 'All cleared'
            ELSE 'Data present'
       END AS Status
FROM dbo.tinetzahlungsinfo
WHERE kInetZahlungsInfo IS NOT NULL

UNION ALL

SELECT 'Shipper IBAN/BIC' AS Type,
       CASE WHEN EXISTS(SELECT 1 FROM dbo.tShipperAccount WHERE cIban IS NOT NULL AND LEN(TRIM(cIban)) > 0)
            THEN 'Data present'
            ELSE 'All cleared'
       END AS Value,
       'Check' AS Status
FROM (SELECT 1 AS dummy) AS d

UNION ALL

SELECT 'PayPal Settings' AS Type,
       CASE WHEN EXISTS(SELECT 1 FROM Robotico.tPaypalSettings WHERE cValue IS NOT NULL AND LEN(TRIM(cValue)) > 0
                        AND (cKey LIKE '%password%' OR cKey LIKE '%secret%' OR cKey LIKE '%token%' OR cKey LIKE '%key%'))
            THEN 'Sensitive data present'
            ELSE 'All cleared'
       END AS Value,
       'Check' AS Status
FROM (SELECT 1 AS dummy) AS d
WHERE OBJECT_ID('Robotico.tPaypalSettings') IS NOT NULL

UNION ALL

SELECT 'OAuth Tokens (Additional)' AS Type,
       CASE WHEN EXISTS(SELECT 1 FROM SCX.tRefreshToken WHERE cRefreshToken IS NOT NULL AND LEN(TRIM(cRefreshToken)) > 0)
                 OR EXISTS(SELECT 1 FROM Sync.tAuthCode WHERE cAuthToken IS NOT NULL AND LEN(TRIM(cAuthToken)) > 0)
                 OR EXISTS(SELECT 1 FROM BI.tAbgleichToken WHERE cAbgleichToken IS NOT NULL AND LEN(TRIM(cAbgleichToken)) > 0)
            THEN 'Tokens present'
            ELSE 'All cleared'
       END AS Value,
       'Check' AS Status
FROM (SELECT 1 AS dummy) AS d
WHERE OBJECT_ID('SCX.tRefreshToken') IS NOT NULL
   OR OBJECT_ID('Sync.tAuthCode') IS NOT NULL
   OR OBJECT_ID('BI.tAbgleichToken') IS NOT NULL

UNION ALL

SELECT 'FTP/Web Credentials' AS Type,
       CASE WHEN EXISTS(SELECT 1 FROM dbo.twebversand WHERE cPasswortFtp IS NOT NULL AND LEN(TRIM(cPasswortFtp)) > 0)
                 OR EXISTS(SELECT 1 FROM dbo.tWebshopModule WHERE cAPIKey IS NOT NULL AND LEN(TRIM(cAPIKey)) > 0)
            THEN 'Credentials present'
            ELSE 'All cleared'
       END AS Value,
       'Check' AS Status
FROM (SELECT 1 AS dummy) AS d
WHERE OBJECT_ID('dbo.twebversand') IS NOT NULL
   OR OBJECT_ID('dbo.tWebshopModule') IS NOT NULL

UNION ALL

SELECT 'License & Auth' AS Type,
       CASE WHEN EXISTS(SELECT 1 FROM dbo.tLizenz WHERE cAuthToken IS NOT NULL AND LEN(TRIM(cAuthToken)) > 0)
                 OR EXISTS(SELECT 1 FROM dbo.tBenutzerLogin WHERE cToken IS NOT NULL AND LEN(TRIM(cToken)) > 0)
            THEN 'Tokens present'
            ELSE 'All cleared'
       END AS Value,
       'Check' AS Status
FROM (SELECT 1 AS dummy) AS d
WHERE OBJECT_ID('dbo.tLizenz') IS NOT NULL
   OR OBJECT_ID('dbo.tBenutzerLogin') IS NOT NULL

UNION ALL

SELECT 'DATEV OAuth' AS Type,
       CASE WHEN EXISTS(SELECT 1 FROM dbo.tDatevConfig WHERE tOauthConfig_cId IS NOT NULL
                        AND LEN(TRIM(tOauthConfig_cId)) > 0
                        AND tOauthConfig_cId NOT LIKE '%_deactivated')
            THEN 'Active OAuth config'
            ELSE 'All deactivated'
       END AS Value,
       'Check' AS Status
FROM (SELECT 1 AS dummy) AS d
WHERE OBJECT_ID('dbo.tDatevConfig') IS NOT NULL;

PRINT 'Deactivation for test system completed!'