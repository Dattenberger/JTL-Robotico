-- =====================================================================================
-- Preisrecherche Export für Excel (CTE-optimiert)
-- Erstellt: $(date)
-- Beschreibung: Ermittelt umfassende Artikelinformationen für Preisrecherche
-- =====================================================================================

WITH
-- CTE 1: Stücklisten-Beziehungen und Gruppierungs-IDs berechnen
StuecklistenGruppen AS (
    SELECT 
        a.kArtikel,
        CASE 
            WHEN a.kStueckliste > 0 OR EXISTS(SELECT 1 FROM dbo.tStueckliste s WHERE s.kArtikel = a.kArtikel) THEN 
                (SELECT MIN(alle_ids.stuecklisten_id) 
                 FROM (
                     SELECT a.kStueckliste as stuecklisten_id WHERE a.kStueckliste > 0
                     UNION
                     SELECT s.kStueckliste FROM dbo.tStueckliste s WHERE s.kArtikel = a.kArtikel
                     UNION
                     SELECT s2.kStueckliste 
                     FROM dbo.tStueckliste s1
                     INNER JOIN dbo.tStueckliste s2 ON s1.kArtikel = s2.kArtikel
                     WHERE s1.kStueckliste = a.kStueckliste AND a.kStueckliste > 0
                     UNION
                     SELECT s3.kStueckliste 
                     FROM dbo.tStueckliste s3
                     INNER JOIN dbo.tArtikel a2 ON s3.kArtikel = a2.kArtikel
                     WHERE a2.kStueckliste IN (
                         SELECT s4.kStueckliste FROM dbo.tStueckliste s4 WHERE s4.kArtikel = a.kArtikel
                     )
                 ) alle_ids)
            ELSE a.kArtikel
        END AS GruppenID
    FROM dbo.tArtikel a
    WHERE a.nDelete = 0 AND a.cAktiv = 'Y' AND a.nIstVater = 0
),

-- CTE 2: Aggregierte Daten sammeln
AggregatedData AS (
    SELECT 
        a.kArtikel,
        -- Label sammeln
        COALESCE(
            STUFF(
                (SELECT ', ' + l.cName
                 FROM dbo.tArtikelLabel al
                 INNER JOIN dbo.tLabel l ON al.kLabel = l.kLabel
                 WHERE al.kArtikel = a.kArtikel
                 FOR XML PATH('')), 1, 2, ''
            ),
            ''
        ) AS Label,

        -- Abverkauf-Attribut
        COALESCE(
            (SELECT TOP 1 aas.cWertVarchar
             FROM dbo.tArtikelAttribut aa
             INNER JOIN dbo.tAttribut attr ON aa.kAttribut = attr.kAttribut
             INNER JOIN dbo.tArtikelAttributSprache aas ON aa.kArtikelAttribut = aas.kArtikelAttribut
             INNER JOIN dbo.tAttributSprache attrs ON attr.kAttribut = attrs.kAttribut AND aas.kSprache = attrs.kSprache
             WHERE aa.kArtikel = a.kArtikel
               AND attrs.cName = 'Abverkauf'
               AND aas.kSprache = 1),
            ''
        ) AS Abverkauf,

        -- Stücklistenkomponenten
        CASE
            WHEN a.kStueckliste > 0 THEN
                COALESCE(
                    STUFF(
                        (SELECT ', ' + ko_a.cArtNr + ' (' +
                                CASE
                                    WHEN s.fAnzahl = FLOOR(s.fAnzahl) THEN CAST(CAST(s.fAnzahl AS INT) AS VARCHAR(10))
                                    ELSE LTRIM(STR(s.fAnzahl, 10, 2))
                                END + 'x)'
                         FROM dbo.tStueckliste s
                         INNER JOIN dbo.tArtikel ko_a ON s.kArtikel = ko_a.kArtikel
                         WHERE s.kStueckliste = a.kStueckliste
                           AND ko_a.nDelete = 0
                         ORDER BY s.nSort
                         FOR XML PATH('')), 1, 2, ''
                    ),
                    'Keine Komponenten gefunden'
                )
            ELSE ''
        END AS Komponenten,

        -- Verwendet in Stücklisten
        COALESCE(
            STUFF(
                (SELECT ', ' + ue_a.cArtNr + ' (' +
                        CASE
                            WHEN s2.fAnzahl = FLOOR(s2.fAnzahl) THEN CAST(CAST(s2.fAnzahl AS INT) AS VARCHAR(10))
                            ELSE LTRIM(STR(s2.fAnzahl, 10, 2))
                        END + 'x)'
                 FROM dbo.tStueckliste s2
                 INNER JOIN dbo.tArtikel ue_a ON s2.kStueckliste = ue_a.kStueckliste
                 WHERE s2.kArtikel = a.kArtikel
                   AND ue_a.nDelete = 0
                 ORDER BY ue_a.cArtNr
                 FOR XML PATH('')), 1, 2, ''
            ),
            ''
        ) AS VerwendetIn
    FROM dbo.tArtikel a
    WHERE a.nDelete = 0 AND a.cAktiv = 'Y' AND a.nIstVater = 0
),

-- CTE 3: Alle Lieferanten pro Artikel sammeln
AllelieferantenProArtikel AS (
    SELECT
        la.tArtikel_kArtikel,
        STUFF(
            (SELECT ', ' + l_inner.cFirma
             FROM dbo.tliefartikel la_inner
             INNER JOIN dbo.tlieferant l_inner ON la_inner.tLieferant_kLieferant = l_inner.kLieferant
             WHERE la_inner.tArtikel_kArtikel = la.tArtikel_kArtikel
               AND l_inner.cAktiv = 'Y'
             ORDER BY la_inner.nStandard DESC, l_inner.cFirma ASC
             FOR XML PATH('')), 1, 2, ''
        ) AS AlleLieferanten
    FROM dbo.tliefartikel la
    INNER JOIN dbo.tlieferant l ON la.tLieferant_kLieferant = l.kLieferant
    WHERE l.cAktiv = 'Y'
    GROUP BY la.tArtikel_kArtikel
),

-- CTE 4: Stücklisten-Lieferanten ermitteln
StücklistenLieferanten AS (
    SELECT
        a.kArtikel,
        CASE
            WHEN a.kStueckliste > 0 THEN
                -- Für Stücklistenartikel: Sammle alle Lieferanten aller Komponenten
                COALESCE(
                    STUFF(
                        (SELECT DISTINCT ', ' + COALESCE(alpa_komp.AlleLieferanten, '')
                         FROM dbo.tStueckliste s_lief
                         INNER JOIN dbo.tArtikel a_komp ON s_lief.kArtikel = a_komp.kArtikel
                         LEFT JOIN AllelieferantenProArtikel alpa_komp ON a_komp.kArtikel = alpa_komp.tArtikel_kArtikel
                         WHERE s_lief.kStueckliste = a.kStueckliste
                           AND a_komp.nDelete = 0
                           AND COALESCE(alpa_komp.AlleLieferanten, '') != ''
                         FOR XML PATH('')), 1, 2, ''
                    ),
                    COALESCE(alpa_eigen.AlleLieferanten, '') -- Fallback: eigene Lieferanten
                )
            ELSE
                -- Für Einzelartikel: eigene Lieferanten
                COALESCE(alpa_eigen.AlleLieferanten, '')
        END AS Lieferanten
    FROM dbo.tArtikel a
    LEFT JOIN AllelieferantenProArtikel alpa_eigen ON a.kArtikel = alpa_eigen.tArtikel_kArtikel
    WHERE a.nDelete = 0 AND a.cAktiv = 'Y' AND a.nIstVater = 0
),

-- CTE 5: Rohdaten beider Historien einlesen und Datum parsen
RohDatenHistorie AS (
    SELECT
        a.kArtikel,
        'Preis' AS HistorieTyp,
        -- Datum parsen mit TRY_CONVERT für Fehlertoleranz
        TRY_CONVERT(DATETIME,
            LTRIM(RTRIM(
                (SELECT TOP 1 LTRIM(RTRIM(s_datum.value))
                 FROM STRING_SPLIT(LTRIM(RTRIM(s.value)), ';') s_datum
                 WHERE LTRIM(RTRIM(s_datum.value)) != ''
                 ORDER BY (SELECT NULL)
                )
            )), 104) AS DatumZeit,  -- Format 104 = dd.MM.yyyy
        LTRIM(RTRIM(s.value)) AS VollstaendigeZeile,
        ROW_NUMBER() OVER (PARTITION BY a.kArtikel ORDER BY (SELECT NULL)) AS ZeilenNummer
    FROM dbo.tArtikel a
    INNER JOIN dbo.tArtikelAttribut aa_preis ON a.kArtikel = aa_preis.kArtikel
    INNER JOIN dbo.tAttribut attr_preis ON aa_preis.kAttribut = attr_preis.kAttribut
    INNER JOIN dbo.tArtikelAttributSprache aas_preis ON aa_preis.kArtikelAttribut = aas_preis.kArtikelAttribut
    INNER JOIN dbo.tAttributSprache attrs_preis ON attr_preis.kAttribut = attrs_preis.kAttribut
        AND aas_preis.kSprache = attrs_preis.kSprache
    CROSS APPLY STRING_SPLIT(REPLACE(aas_preis.cWertVarchar, CHAR(13)+CHAR(10), CHAR(10)), CHAR(10)) s
    WHERE a.nDelete = 0
      AND a.cAktiv = 'Y'
      AND a.nIstVater = 0
      AND attrs_preis.cName = 'Vergangene Preise'
      AND aas_preis.kSprache = 0
      AND LTRIM(RTRIM(s.value)) != ''

    UNION ALL

    SELECT
        a.kArtikel,
        'Label' AS HistorieTyp,
        -- Datum parsen mit TRY_CONVERT für Fehlertoleranz
        TRY_CONVERT(DATETIME,
            LTRIM(RTRIM(
                (SELECT TOP 1 LTRIM(RTRIM(s_datum.value))
                 FROM STRING_SPLIT(LTRIM(RTRIM(s.value)), ';') s_datum
                 WHERE LTRIM(RTRIM(s_datum.value)) != ''
                 ORDER BY (SELECT NULL)
                )
            )), 104) AS DatumZeit,  -- Format 104 = dd.MM.yyyy
        LTRIM(RTRIM(s.value)) AS VollstaendigeZeile,
        ROW_NUMBER() OVER (PARTITION BY a.kArtikel ORDER BY (SELECT NULL)) AS ZeilenNummer
    FROM dbo.tArtikel a
    INNER JOIN dbo.tArtikelAttribut aa_label ON a.kArtikel = aa_label.kArtikel
    INNER JOIN dbo.tAttribut attr_label ON aa_label.kAttribut = attr_label.kAttribut
    INNER JOIN dbo.tArtikelAttributSprache aas_label ON aa_label.kArtikelAttribut = aas_label.kArtikelAttribut
    INNER JOIN dbo.tAttributSprache attrs_label ON attr_label.kAttribut = attrs_label.kAttribut
        AND aas_label.kSprache = attrs_label.kSprache
    CROSS APPLY STRING_SPLIT(REPLACE(aas_label.cWertVarchar, CHAR(13)+CHAR(10), CHAR(10)), CHAR(10)) s
    WHERE a.nDelete = 0
      AND a.cAktiv = 'Y'
      AND a.nIstVater = 0
      AND attrs_label.cName = 'Vergangene Label'
      AND aas_label.kSprache = 0
      AND LTRIM(RTRIM(s.value)) != ''
),

-- CTE 6: Preishistorie parsen
PreisHistorieParsed AS (
    SELECT
        rdh.kArtikel,
        rdh.DatumZeit,
        rdh.VollstaendigeZeile,
        rdh.ZeilenNummer,
        -- Spalten aus CSV parsen
        MAX(CASE WHEN spalte_nr = 2 THEN LTRIM(RTRIM(value)) END) AS Netto,
        MAX(CASE WHEN spalte_nr = 3 THEN LTRIM(RTRIM(value)) END) AS Brutto,
        -- Vorherigen Brutto für Deduplizierung
        LAG(MAX(CASE WHEN spalte_nr = 3 THEN LTRIM(RTRIM(value)) END))
            OVER (PARTITION BY rdh.kArtikel ORDER BY rdh.ZeilenNummer) AS VorherigerBrutto
    FROM RohDatenHistorie rdh
    CROSS APPLY (
        SELECT
            ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS spalte_nr,
            LTRIM(RTRIM(s2.value)) AS value
        FROM STRING_SPLIT(rdh.VollstaendigeZeile, ';') s2
    ) spalten_split
    WHERE rdh.HistorieTyp = 'Preis'
      AND rdh.DatumZeit IS NOT NULL
    GROUP BY rdh.kArtikel, rdh.DatumZeit, rdh.VollstaendigeZeile, rdh.ZeilenNummer
),

-- CTE 7: Labelhistorie parsen
LabelHistorieParsed AS (
    SELECT
        rdh.kArtikel,
        rdh.DatumZeit,
        rdh.VollstaendigeZeile,
        rdh.ZeilenNummer,
        -- Spalten aus CSV parsen
        MAX(CASE WHEN spalte_nr = 2 THEN LTRIM(RTRIM(value)) END) AS Label,
        -- Vorherige Label für Deduplizierung
        LAG(MAX(CASE WHEN spalte_nr = 2 THEN LTRIM(RTRIM(value)) END))
            OVER (PARTITION BY rdh.kArtikel ORDER BY rdh.ZeilenNummer) AS VorherigeLabel
    FROM RohDatenHistorie rdh
    CROSS APPLY (
        SELECT
            ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS spalte_nr,
            LTRIM(RTRIM(s2.value)) AS value
        FROM STRING_SPLIT(rdh.VollstaendigeZeile, ';') s2
    ) spalten_split
    WHERE rdh.HistorieTyp = 'Label'
      AND rdh.DatumZeit IS NOT NULL
    GROUP BY rdh.kArtikel, rdh.DatumZeit, rdh.VollstaendigeZeile, rdh.ZeilenNummer
),

-- CTE 8: PreisHistorieFormatiert (für alte Spalte "Vergangene Preise")
PreisHistorieFormatiert AS (
    SELECT
        php.kArtikel,
        COALESCE(
            STUFF(
                (SELECT '; ' + LTRIM(RTRIM(php_inner.Brutto)) + ' (' +
                        CONVERT(VARCHAR(10), php_inner.DatumZeit, 104) + ')'
                 FROM PreisHistorieParsed php_inner
                 WHERE php_inner.kArtikel = php.kArtikel
                   AND (php_inner.VorherigerBrutto IS NULL
                        OR php_inner.Brutto != php_inner.VorherigerBrutto)
                 ORDER BY php_inner.ZeilenNummer DESC
                 FOR XML PATH('')
                ), 1, 2, ''
            ),
            ''
        ) AS VergangenePreise
    FROM PreisHistorieParsed php
    GROUP BY php.kArtikel
),

-- CTE 9: LabelHistorieFormatiert (für alte Spalte "Vergangene Label")
LabelHistorieFormatiert AS (
    SELECT
        lhp.kArtikel,
        COALESCE(
            STUFF(
                (SELECT '; ' + LTRIM(RTRIM(lhp_inner.Label)) + ' (' +
                        CONVERT(VARCHAR(10), lhp_inner.DatumZeit, 104) + ')'
                 FROM LabelHistorieParsed lhp_inner
                 WHERE lhp_inner.kArtikel = lhp.kArtikel
                   AND (lhp_inner.VorherigeLabel IS NULL
                        OR lhp_inner.Label != lhp_inner.VorherigeLabel)
                 ORDER BY lhp_inner.ZeilenNummer DESC
                 FOR XML PATH('')
                ), 1, 2, ''
            ),
            ''
        ) AS VergangeneLabel
    FROM LabelHistorieParsed lhp
    GROUP BY lhp.kArtikel
),

-- CTE 10: KombinierteHistorie (neue Spalte mit allen Änderungen chronologisch)
KombinierteHistorie AS (
    SELECT
        komb.kArtikel,
        COALESCE(
            STUFF(
                (SELECT CHAR(10) +
                    CASE
                        WHEN komb_inner.HistorieTyp = 'Label' THEN
                            -- Label-Format: nur die vollständige Zeile
                            komb_inner.VollstaendigeZeile
                        ELSE
                            -- Preis-Format: vollständige Zeile
                            komb_inner.VollstaendigeZeile
                    END
                 FROM (
                     -- Preis-Einträge
                     SELECT
                         php2.kArtikel,
                         'Preis' AS HistorieTyp,
                         php2.DatumZeit,
                         php2.VollstaendigeZeile,
                         php2.ZeilenNummer
                     FROM PreisHistorieParsed php2
                     WHERE php2.VorherigerBrutto IS NULL
                        OR php2.Brutto != php2.VorherigerBrutto

                     UNION ALL

                     -- Label-Einträge
                     SELECT
                         lhp2.kArtikel,
                         'Label' AS HistorieTyp,
                         lhp2.DatumZeit,
                         lhp2.VollstaendigeZeile,
                         lhp2.ZeilenNummer
                     FROM LabelHistorieParsed lhp2
                     WHERE lhp2.VorherigeLabel IS NULL
                        OR lhp2.Label != lhp2.VorherigeLabel
                 ) komb_inner
                 WHERE komb_inner.kArtikel = komb.kArtikel
                 ORDER BY
                     komb_inner.DatumZeit DESC,
                     CASE WHEN komb_inner.HistorieTyp = 'Label' THEN 0 ELSE 1 END,  -- Label vor Preis
                     komb_inner.ZeilenNummer DESC
                 FOR XML PATH(''), TYPE
                ).value('.', 'NVARCHAR(MAX)'), 1, 1, ''  -- Erstes CHAR(10) entfernen
            ),
            ''
        ) AS Historie
    FROM (
        SELECT DISTINCT kArtikel FROM PreisHistorieParsed
        UNION
        SELECT DISTINCT kArtikel FROM LabelHistorieParsed
    ) komb
),

-- CTE 11: Gruppengrößen berechnen
GruppenGroessen AS (
    SELECT
        sg.GruppenID,
        COUNT(*) as Gruppengroesse
    FROM StuecklistenGruppen sg
    GROUP BY sg.GruppenID
)

SELECT
    -- Gruppierungs-ID für zusammenhängende Stücklisten-Beziehungen
    sg.GruppenID AS [Stücklisten-Gruppen-ID],

    -- Grundlegende Artikelinformationen
    a.kArtikel AS [Interner Artikelschlüssel],
    a.cArtNr AS [Artikelnummer],
    a.cHAN AS [HAN],
    COALESCE(ab.cName, '') AS [Artikelname],

    -- Alle gesetzten Label (kommagetrennt)
    ad.Label AS [Label],

    -- Funktionsattribut "Abverkauf"
    ad.Abverkauf AS [Abverkauf],

    -- Preise
    ROUND(a.fVKNetto, 2) AS [VK],
    ROUND(a.fEKNetto, 2) AS [EK],
    ROUND(a.fUVP, 2) AS [UVP],

    -- Bestandsinformationen
    COALESCE(lb.fLagerbestand, 0) AS [Bestand],
    COALESCE(lb.fVerfuegbar, 0) AS [Verfügbar],
    COALESCE(lb.fZulauf, 0) AS [In Zulauf],
    COALESCE(lb.fAufEinkaufsliste, 0) AS [In Bestellung],

    -- Warengruppe
    a.kWarengruppe                AS [Warengruppen ID],
    COALESCE(wg.cName, '')        AS [Warengruppenname],

    -- Versandklasse
    COALESCE(a.kVersandklasse, 0) AS [Versandklassen ID],
    COALESCE(vk.cName, '')        AS [Versandklassenname],

    -- Gewichtsinformationen
    ROUND(a.fGewicht, 3)          AS [Versandgewicht (kg)],
    ROUND(a.fArtGewicht, 3)       AS [Artikelgewicht (kg)],

    -- Stücklistenkomponenten (Was enthält dieser Artikel?)
    ad.Komponenten                AS [Stücklistenkomponenten],

    -- Verwendet in Stücklisten (In welchen Stücklisten wird dieser Artikel verwendet?)
    ad.VerwendetIn                AS [Verwendet in Stücklisten],

    -- Stücklistentyp-Klassifizierung
    CASE
        WHEN a.kStueckliste > 0 AND EXISTS(SELECT 1 FROM dbo.tStueckliste s WHERE s.kArtikel = a.kArtikel) THEN
            'Stückliste + Komponente'  -- Artikel ist sowohl Stückliste als auch Komponente
        WHEN a.kStueckliste > 0 THEN
            CASE
                -- Physisch-Artikel: Stückliste online, aber Komponenten offline
                WHEN a.cInet = 'Y' AND EXISTS(SELECT 1 FROM dbo.tStueckliste s
                           INNER JOIN dbo.tArtikel ka ON s.kArtikel = ka.kArtikel
                           WHERE s.kStueckliste = a.kStueckliste
                             AND ka.cInet = 'N') THEN
                    'Online zu Physisch'
                -- Artikel mit anderem Namen: Nur eine Komponente und beide online
                WHEN a.cInet = 'Y' AND
                     (SELECT COUNT(*) FROM dbo.tStueckliste s WHERE s.kStueckliste = a.kStueckliste) = 1 AND
                     EXISTS(SELECT 1 FROM dbo.tStueckliste s
                           INNER JOIN dbo.tArtikel ka ON s.kArtikel = ka.kArtikel
                           WHERE s.kStueckliste = a.kStueckliste
                             AND ka.cInet = 'Y') THEN
                    'Artikel mit anderem Namen'
                ELSE 'Standard-Stückliste'
            END
        WHEN EXISTS(SELECT 1 FROM dbo.tStueckliste s WHERE s.kArtikel = a.kArtikel) THEN
            CASE
                WHEN a.cInet = 'N' THEN 'Physischer Artikel'
                -- Prüfe ob dieser Artikel die einzige Komponente in einer "Artikel mit anderem Namen" Stückliste ist
                WHEN EXISTS(SELECT 1 FROM dbo.tStueckliste s
                           INNER JOIN dbo.tArtikel sl_a ON s.kStueckliste = sl_a.kStueckliste
                           WHERE s.kArtikel = a.kArtikel
                             AND sl_a.cInet = 'Y' -- Stückliste online
                             AND a.cInet = 'Y'    -- Komponente online
                             AND (SELECT COUNT(*) FROM dbo.tStueckliste s2 WHERE s2.kStueckliste = s.kStueckliste) = 1) THEN
                    'Artikel unter anderem Namen'
                ELSE 'Standard-Komponente'
            END
        ELSE 'Einzelartikel'
    END                           AS [Stücklistentyp],

    -- Aktiv in Onlineshop
    CASE
        WHEN a.cInet = 'Y' THEN 'Ja'
        ELSE 'Nein'
    END AS [Aktiv in Onlineshop],

    -- Stücklistengruppengröße (Anzahl Artikel in der Gruppe)
    gg.Gruppengroesse AS [Stücklistengruppengröße],

    -- Lieferanten (alle Lieferanten, bei Stücklisten: Lieferanten der Komponenten)
    COALESCE(sl.Lieferanten, '') AS [Lieferanten],

    -- Vergangene Preise (formatiert: Bruttopreis (Datum))
    COALESCE(phf.VergangenePreise, '') AS [Vergangene Preise],

    -- Vergangene Label (formatiert: Label (Datum))
    COALESCE(lhf.VergangeneLabel, '') AS [Vergangene Label],

    -- Kombinierte Historie (alle Änderungen chronologisch sortiert)
    COALESCE(kh.Historie, '') AS [Historie],

    GETDATE() AS [Exportdatum]

FROM dbo.tArtikel a
    -- CTEs einbinden
    LEFT JOIN StuecklistenGruppen sg ON a.kArtikel = sg.kArtikel
    LEFT JOIN AggregatedData ad ON a.kArtikel = ad.kArtikel
    LEFT JOIN GruppenGroessen gg ON sg.GruppenID = gg.GruppenID
    LEFT JOIN StücklistenLieferanten sl ON a.kArtikel = sl.kArtikel
    LEFT JOIN PreisHistorieFormatiert phf ON a.kArtikel = phf.kArtikel
    LEFT JOIN LabelHistorieFormatiert lhf ON a.kArtikel = lhf.kArtikel
    LEFT JOIN KombinierteHistorie kh ON a.kArtikel = kh.kArtikel
    
    -- Artikelbeschreibung (deutsch)
    LEFT JOIN dbo.tArtikelBeschreibung ab ON a.kArtikel = ab.kArtikel 
        AND ab.kSprache = 1 -- Deutsche Sprache
    
    -- Lagerbestand
    LEFT JOIN dbo.tlagerbestand lb ON a.kArtikel = lb.kArtikel
    
    -- Warengruppe
    LEFT JOIN dbo.tWarengruppe wg ON a.kWarengruppe = wg.kWarengruppe
    
    -- Versandklasse
    LEFT JOIN dbo.tVersandklasse vk ON a.kVersandklasse = vk.kVersandklasse

WHERE
    a.nDelete = 0  -- Nicht gelöschte Artikel
    AND a.cAktiv = 'Y'  -- Aktive Artikel
    AND a.nIstVater = 0  -- Keine Vaterartikel (Variationen)
    -- Stücklistenartikel sind jetzt INKLUDIERT für kombinierte Sicht

ORDER BY 
    sg.GruppenID,  -- Primär nach Stücklisten-Gruppen-ID sortieren
    CASE WHEN a.kStueckliste > 0 THEN 0 ELSE 1 END,  -- Stücklistenartikel vor Komponenten
    a.cArtNr  -- Dann nach Artikelnummer