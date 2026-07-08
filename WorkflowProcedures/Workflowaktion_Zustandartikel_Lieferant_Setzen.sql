USE eazybusiness
GO

-- QUOTED_IDENTIFIER wird zur Erstellzeit in die Prozedur eingebacken und muss
-- ON sein: tliefartikel traegt gefilterte Indizes, sonst Fehler 1934 beim UPDATE.
-- (sqlcmd hat standardmaessig OFF!)
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF EXISTS (SELECT 1 FROM sys.procedures WHERE Name = 'spZustandartikelLieferantSetzen')
    DROP PROCEDURE CustomWorkflows.spZustandartikelLieferantSetzen
GO

CREATE PROCEDURE CustomWorkflows.spZustandartikelLieferantSetzen @kArtikel INT AS
BEGIN

    SET NOCOUNT ON;

    -- =========================================================================
    -- Zweck
    -- -----
    -- Beim Einlagern in einem Nicht-Standard-Zustand (z. B. Retoure) dupliziert
    -- JTL den Hauptartikel zum Zustandsartikel und kopiert dabei den
    -- Lieferanten-Tab (dbo.tliefartikel) mit - inkl. Lieferanten-Artikelnummer.
    -- Diese Aktion ersetzt die kopierte Nummer durch eine eindeutige:
    --      HAN + Zustands-Suffix    (z. B. 531256501-G)
    --
    -- Kernbeobachtung (vereinfacht das Skript erheblich):
    -- JTL haengt den Zustands-Suffix (dbo.tZustand.cSuffix) beim Duplizieren
    -- bereits selbst an cArtNr UND cHAN des Zustandsartikels an
    -- (verifiziert an allen Zustandsartikeln im Bestand, 2026-07-08).
    -- Die eigene HAN des Zustandsartikels IST also schon "Basis-HAN + Suffix".
    -- Ein Rueckgriff auf den Hauptartikel (tArtikelZustand) ist unnoetig.
    --
    -- Regeln:
    --   * Standardzustand wird nie angefasst. Standard ist bei JTL fest
    --     kZustand = 1 (so hardcodiert JTL das selbst, siehe
    --     dbo.vArtikelZustandMitStandardZustand). Ausdruecklich NICHT ueber
    --     nLieferantenEntfernen filtern - das ist eine pro Zustand
    --     konfigurierbare Option, kein Standard-Kennzeichen.
    --   * Zustand ohne Suffix (z. B. "Defekt: Garantie") oder Artikel ohne
    --     HAN: keine eindeutige Nummer bildbar -> cLiefArtNr leeren (NULL),
    --     damit die kopierte Fremdnummer keinesfalls stehen bleibt.
    --   * Idempotent: endet die HAN wider Erwarten noch nicht auf den Suffix,
    --     wird er angehaengt; sonst wird die HAN unveraendert uebernommen.
    --     Der Suffix wird nie doppelt angehaengt.
    --   * Es werden alle Lieferanten-Zeilen des Artikels gesetzt.
    --
    -- Ein einzelnes UPDATE ist atomar - bewusst ohne Transaktions-/TRY-CATCH-
    -- Geruest; Fehler propagieren direkt an den JTL-Workflow.
    -- =========================================================================

    UPDATE la
    SET la.cLiefArtNr =
        CASE
            WHEN ISNULL(z.cSuffix, '') = '' OR ISNULL(a.cHAN, '') = ''
                THEN NULL                       -- keine eindeutige Nummer bildbar -> leeren
            WHEN RIGHT(a.cHAN, LEN(z.cSuffix)) = z.cSuffix
                THEN a.cHAN                     -- HAN traegt den Suffix bereits
            ELSE a.cHAN + z.cSuffix             -- Sonderfall: Suffix fehlt noch
        END
    FROM dbo.tliefartikel la
    JOIN dbo.tArtikel a ON a.kArtikel = la.tArtikel_kArtikel
    JOIN dbo.tZustand z ON z.kZustand = a.kZustand
    WHERE la.tArtikel_kArtikel = @kArtikel
      AND a.kZustand <> 1;                      -- Standardzustand nie anfassen

END
GO

-- Aktion registrieren
EXEC CustomWorkflows._CheckAction @actionName = 'spZustandartikelLieferantSetzen'
GO

EXEC CustomWorkflows._SetActionDisplayName @actionName = 'spZustandartikelLieferantSetzen',
     @displayName = 'Zustandsartikel: Lieferantennummer auf HAN+Zustand setzen'
GO

-- =========================================================================
-- Einmalige Bestandsbereinigung (manuell ausfuehren, NICHT Teil der Aktion):
-- korrigiert alle bereits existierenden Zustandsartikel mit kopierter oder
-- fehlender Lieferantennummer. Gleiche Logik wie oben, ohne Artikel-Filter.
-- Vorher per SELECT pruefen!
-- =========================================================================
/*
UPDATE la
SET la.cLiefArtNr =
    CASE
        WHEN ISNULL(z.cSuffix, '') = '' OR ISNULL(a.cHAN, '') = '' THEN NULL
        WHEN RIGHT(a.cHAN, LEN(z.cSuffix)) = z.cSuffix THEN a.cHAN
        ELSE a.cHAN + z.cSuffix
    END
FROM dbo.tliefartikel la
JOIN dbo.tArtikel a ON a.kArtikel = la.tArtikel_kArtikel
JOIN dbo.tZustand z ON z.kZustand = a.kZustand
WHERE a.kZustand <> 1;
*/
