-- ============================================================================
-- Backfill: Versandklasse nach Gewicht - Bestandskorrektur fuer EINE Warengruppe
-- ============================================================================
--
-- Author:  Sanda Gilca
-- Date:    2026-07-01
--
-- Zieht die Versandklasse bestehender Artikel EINER Warengruppe einmalig nach
-- (der Workflow selbst greift nur bei erstellten/geaenderten Artikeln). Nutzt
-- exakt dieselbe Logik + dasselbe Audit-Log wie die Aktion, indem es
-- CustomWorkflows.spArtikelVersandklasseNachGewicht pro Artikel aufruft.
--
-- ABLAUF:
--   1. Erst NUR ausfuehren -> zeigt die VORSCHAU (was wuerde sich aendern?).
--   2. Vorschau pruefen.
--   3. @bApply auf 1 setzen und erneut ausfuehren -> wendet die Aenderung an.
--
-- Voraussetzung: Artikel_Versandklasse_NachGewicht.sql wurde deployt.
-- Gegen eazybusiness ausfuehren.
-- ============================================================================

USE [eazybusiness]
GO

SET NOCOUNT ON;

-- ---- Konfiguration --------------------------------------------------------
DECLARE @fSchwelleKg DECIMAL(18,3) = 31.5;   -- gleiche Schwelle wie im Workflow
DECLARE @bApply      BIT           = 0;      -- 0 = nur Vorschau, 1 = anwenden

-- Pilot-Warengruppe. Das '_' matcht das Umlaut-Zeichen encoding-sicher
-- ("Gartenger_te" trifft "Gartengeraete"). Alternativ die ID direkt setzen.
DECLARE @kWarengruppe INT =
    (SELECT kWarengruppe FROM dbo.tWarengruppe
     WHERE cName LIKE 'Gartenger_te - Werkstattpflichtig');

IF @kWarengruppe IS NULL
BEGIN
    RAISERROR('Warengruppe nicht gefunden - Namen/ID in dbo.tWarengruppe pruefen.', 16, 1);
    RETURN;
END

-- ---- VORSCHAU: welche Artikel wuerde der Backfill aendern? -----------------
PRINT CONCAT('Warengruppe kWarengruppe=', @kWarengruppe, ' | Schwelle=', @fSchwelleKg, ' kg | Modus=',
             IIF(@bApply = 1, 'ANWENDEN', 'NUR VORSCHAU'));

SELECT a.kArtikel,
       a.cArtNr,
       a.fGewicht,
       vk.cName                                                                   AS VersandklasseAktuell,
       Robotico.fnVersandklasseNachGewicht(a.fGewicht, @fSchwelleKg, vk.cName)    AS VersandklasseNeu
FROM dbo.tArtikel a
         LEFT JOIN dbo.tVersandklasse vk ON vk.kVersandklasse = a.kVersandklasse
WHERE a.kWarengruppe = @kWarengruppe
  AND Robotico.fnVersandklasseNachGewicht(a.fGewicht, @fSchwelleKg, vk.cName) IS NOT NULL
ORDER BY a.fGewicht DESC;

-- ---- ANWENDEN (nur wenn @bApply = 1) --------------------------------------
IF @bApply = 1
BEGIN
    BEGIN TRANSACTION;

    DECLARE @k INT;
    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT kArtikel FROM dbo.tArtikel WHERE kWarengruppe = @kWarengruppe;
    OPEN cur;
    FETCH NEXT FROM cur INTO @k;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC CustomWorkflows.spArtikelVersandklasseNachGewicht
             @kArtikel     = @k,
             @fSchwelleKg  = @fSchwelleKg,
             @kWarengruppe = @kWarengruppe,   -- doppelte Sicherheitsgrenze
             @cBenutzer    = 'Backfill';
        FETCH NEXT FROM cur INTO @k;
    END
    CLOSE cur;
    DEALLOCATE cur;

    COMMIT TRANSACTION;

    -- Ergebnis aus dem Audit-Log dieser Gruppe zeigen
    SELECT * FROM Robotico.vVersandklassenLog
    WHERE cBenutzer = 'Backfill'
    ORDER BY dErstellt DESC;

    PRINT 'Backfill angewendet - siehe Log oben.';
END
ELSE
    PRINT 'Nur Vorschau. Zum Anwenden @bApply = 1 setzen und erneut ausfuehren.';
GO
