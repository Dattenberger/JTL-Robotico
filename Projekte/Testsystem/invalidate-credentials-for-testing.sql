-- =================================================================
-- JTL credential invalidation for test system (CORRECTED)
-- Clears passwords and adds "_deactivated" to usernames/server names
-- =================================================================

USE [eazybusiness]
GO

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
        kOAuthToken = NULL
    WHERE (cUserName IS NOT NULL AND LEN(TRIM(cUserName)) > 0) 
       OR (cPassword IS NOT NULL AND LEN(TRIM(cPassword)) > 0)
       OR (kOAuthToken IS NOT NULL);
    
    PRINT 'Shipping credentials deactivated: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' records'
    
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
WHERE cServerWeb IS NOT NULL;

PRINT 'Deactivation for test system completed!'