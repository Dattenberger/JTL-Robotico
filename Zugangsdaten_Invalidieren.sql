-- =================================================================
-- JTL Zugangsdaten Invalidierung
-- Invalidiert SMTP, eBay, Amazon und Onlineshop Zugangsdaten
-- =================================================================

USE [eazybusiness]
GO

BEGIN TRANSACTION

BEGIN TRY
    PRINT 'Starte Invalidierung der Zugangsdaten...'
    
    -- =================================================================
    -- SMTP/Email Zugangsdaten invalidieren
    -- =================================================================
    PRINT 'Invalidiere SMTP/Email Zugangsdaten...'
    
    UPDATE dbo.tEMailEinstellung 
    SET 
        cPasswortSMTP = NULL,
        cNutzernameSmtp = NULL,
        cSigPortalPasswort = NULL,
        cSMIMEPasswort = NULL,
        kOauthToken = NULL
    WHERE cPasswortSMTP IS NOT NULL 
       OR cNutzernameSmtp IS NOT NULL 
       OR cSigPortalPasswort IS NOT NULL
       OR cSMIMEPasswort IS NOT NULL
       OR kOauthToken IS NOT NULL;
    
    PRINT 'SMTP Zugangsdaten invalidiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
    
    -- =================================================================
    -- eBay Zugangsdaten invalidieren
    -- =================================================================
    PRINT 'Invalidiere eBay Zugangsdaten...'
    
    UPDATE dbo.ebay_user 
    SET 
        Login = 'INVALIDATED',
        Passwort = 'INVALIDATED',
        cEbayUsername = 'INVALIDATED'
    WHERE Login IS NOT NULL 
       OR Passwort IS NOT NULL 
       OR cEbayUsername IS NOT NULL;
    
    PRINT 'eBay Zugangsdaten invalidiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
    
    -- =================================================================
    -- Amazon Zugangsdaten invalidieren (über OAuth Token)
    -- =================================================================
    PRINT 'Invalidiere Amazon Zugangsdaten...'
    
    -- Amazon OAuth Tokens als ungültig markieren
    UPDATE dbo.tOauthToken 
    SET 
        cAccessToken = 'INVALIDATED',
        cRefreshToken = 'INVALIDATED',
        nInvalid = 1
    WHERE EXISTS (
        SELECT 1 FROM dbo.tOauthConfig oc 
        WHERE oc.kOauthConfig = tOauthToken.kOauthConfig 
        AND (oc.cClientId LIKE '%amazon%' OR oc.cClientId LIKE '%amz%')
    );
    
    PRINT 'Amazon OAuth Tokens invalidiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
    
    -- =================================================================
    -- Onlineshop/Webshop Zugangsdaten invalidieren
    -- =================================================================
    PRINT 'Invalidiere Onlineshop Zugangsdaten...'
    
    UPDATE dbo.tShop 
    SET 
        cAPIKey = NULL,
        cPasswortWeb = NULL,
        cBenutzerWeb = NULL
    WHERE cAPIKey IS NOT NULL 
       OR cPasswortWeb IS NOT NULL 
       OR cBenutzerWeb IS NOT NULL;
    
    PRINT 'Shop Zugangsdaten invalidiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
    
    UPDATE dbo.tWebshopModule 
    SET 
        cAPIKey = NULL,
        cLizenzkey = NULL
    WHERE cAPIKey IS NOT NULL 
       OR cLizenzkey IS NOT NULL;
    
    PRINT 'Webshop Module Zugangsdaten invalidiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
    
    -- =================================================================
    -- Alle anderen OAuth Tokens invalidieren
    -- =================================================================
    PRINT 'Invalidiere alle anderen OAuth Tokens...'
    
    UPDATE dbo.tOauthToken 
    SET 
        cAccessToken = 'INVALIDATED',
        cRefreshToken = 'INVALIDATED',
        nInvalid = 1
    WHERE nInvalid = 0 OR nInvalid IS NULL;
    
    PRINT 'Alle OAuth Tokens invalidiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
    
    -- =================================================================
    -- PayPal Zugangsdaten invalidieren
    -- =================================================================
    PRINT 'Invalidiere PayPal Zugangsdaten...'
    
    IF OBJECT_ID('Robotico.tPaypalAccessToken') IS NOT NULL
    BEGIN
        UPDATE Robotico.tPaypalAccessToken 
        SET 
            cAccessToken = 'INVALIDATED',
            cAppID = 'INVALIDATED';
        
        PRINT 'PayPal Zugangsdaten invalidiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
    END
    ELSE
        PRINT 'PayPal Tabelle nicht gefunden - übersprungen'
    
    -- =================================================================
    -- Versand/Shipping Zugangsdaten invalidieren
    -- =================================================================
    PRINT 'Invalidiere Versand Zugangsdaten...'
    
    UPDATE dbo.tShipperAccount 
    SET 
        cUserName = 'INVALIDATED',
        cPassword = 'INVALIDATED',
        kOAuthToken = NULL
    WHERE cUserName IS NOT NULL 
       OR cPassword IS NOT NULL 
       OR kOAuthToken IS NOT NULL;
    
    PRINT 'Versand Zugangsdaten invalidiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
    
    -- =================================================================
    -- Weitere Token invalidieren
    -- =================================================================
    PRINT 'Invalidiere weitere Token...'
    
    UPDATE dbo.tVouchersToken 
    SET cAccessToken = 'INVALIDATED'
    WHERE cAccessToken IS NOT NULL;
    
    PRINT 'Voucher Token invalidiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
    
    IF OBJECT_ID('FulfillmentNetwork.tLogin') IS NOT NULL
    BEGIN
        UPDATE FulfillmentNetwork.tLogin 
        SET cApiToken = 'INVALIDATED'
        WHERE cApiToken IS NOT NULL;
        
        PRINT 'Fulfillment Network Token invalidiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
    END
    
    IF OBJECT_ID('SCX.tRefreshToken') IS NOT NULL
    BEGIN
        UPDATE SCX.tRefreshToken 
        SET cRefreshToken = 'INVALIDATED'
        WHERE cRefreshToken IS NOT NULL;
        
        PRINT 'SCX Refresh Token invalidiert: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
    END
    
    -- =================================================================
    -- Sensitive Einstellungen löschen (optional)
    -- =================================================================
    PRINT 'Lösche sensitive Einstellungen...'
    
    DELETE FROM dbo.tSetting 
    WHERE cKey LIKE '%password%' 
       OR cKey LIKE '%passwort%'
       OR cKey LIKE '%token%'
       OR cKey LIKE '%secret%'
       OR cKey LIKE '%key%'
       OR cKey LIKE '%api%';
    
    PRINT 'Sensitive Settings gelöscht: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Datensätze'
    
    -- =================================================================
    -- Abschluss
    -- =================================================================
    PRINT 'Zugangsdaten erfolgreich invalidiert!'
    
    -- Transaktion bestätigen
    COMMIT TRANSACTION
    
    PRINT 'Transaktion erfolgreich abgeschlossen.'

END TRY
BEGIN CATCH
    -- Rollback bei Fehler
    ROLLBACK TRANSACTION
    
    PRINT 'FEHLER beim Invalidieren der Zugangsdaten:'
    PRINT 'Fehlernummer: ' + CAST(ERROR_NUMBER() AS VARCHAR(10))
    PRINT 'Fehlermeldung: ' + ERROR_MESSAGE()
    PRINT 'Transaktion wurde rückgängig gemacht.'
    
    -- Fehler erneut auslösen
    THROW
END CATCH

GO

-- =================================================================
-- Verifikation: Prüfe invalidierte Zugangsdaten
-- =================================================================
PRINT 'Verifikation der invalidierten Zugangsdaten:'

-- SMTP
SELECT 'SMTP' AS Bereich, COUNT(*) AS AnzahlInvalidiert
FROM dbo.tEMailEinstellung 
WHERE cPasswortSMTP IS NULL AND cNutzernameSmtp IS NULL

UNION ALL

-- eBay
SELECT 'eBay' AS Bereich, COUNT(*) AS AnzahlInvalidiert
FROM dbo.ebay_user 
WHERE Login = 'INVALIDATED'

UNION ALL

-- OAuth Tokens
SELECT 'OAuth Tokens' AS Bereich, COUNT(*) AS AnzahlInvalidiert
FROM dbo.tOauthToken 
WHERE nInvalid = 1

UNION ALL

-- Shop
SELECT 'Shop' AS Bereich, COUNT(*) AS AnzahlInvalidiert
FROM dbo.tShop 
WHERE cAPIKey IS NULL AND cPasswortWeb IS NULL;

PRINT 'Invalidierung abgeschlossen!'