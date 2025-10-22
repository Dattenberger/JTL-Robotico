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

-- CTE 5: Preishistorie aus Attribut parsen
PreisHistorie AS (
    SELECT
        a.kArtikel,
        -- Formatierte Version
        COALESCE(
            STUFF(
                (SELECT '; ' + bruttopreis_formatiert.FormatierterPreis
                 FROM (
                     SELECT
                         -- Bruttopreis (Position 3) + Datum (Position 1, nur Datumsteil)
                         LTRIM(RTRIM(spalten.Bruttopreis)) + ' (' +
                         LTRIM(RTRIM(datum_split.DatumTeil)) + ')' AS FormatierterPreis,
                         zeilen.ZeilenNummer,
                         spalten.Bruttopreis,
                         -- Vorherigen Bruttopreis für Deduplizierung
                         LAG(spalten.Bruttopreis) OVER (ORDER BY zeilen.ZeilenNummer) AS VorherigerBruttopreis
                     FROM (
                         -- Level 1: Zeilen splitten
                         SELECT
                             ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS ZeilenNummer,
                             LTRIM(RTRIM(s.value)) AS ZeileText
                         FROM dbo.tArtikelAttribut aa_hist
                         INNER JOIN dbo.tAttribut attr_hist ON aa_hist.kAttribut = attr_hist.kAttribut
                         INNER JOIN dbo.tArtikelAttributSprache aas_hist ON aa_hist.kArtikelAttribut = aas_hist.kArtikelAttribut
                         INNER JOIN dbo.tAttributSprache attrs_hist ON attr_hist.kAttribut = attrs_hist.kAttribut AND aas_hist.kSprache = attrs_hist.kSprache
                         CROSS APPLY STRING_SPLIT(REPLACE(aas_hist.cWertVarchar, CHAR(13)+CHAR(10), CHAR(10)), CHAR(10)) s
                         WHERE aa_hist.kArtikel = a.kArtikel
                           AND attrs_hist.cName = 'Vergangene Preise'
                           AND aas_hist.kSprache = 0
                           AND LTRIM(RTRIM(s.value)) != ''
                     ) zeilen
                     CROSS APPLY (
                         -- Level 2: Spalten splitten (Position 1=Datum+Zeit, Position 3=Bruttopreis)
                         SELECT
                             MAX(CASE WHEN spalte_nr = 1 THEN LTRIM(RTRIM(value)) END) AS DatumZeit,
                             MAX(CASE WHEN spalte_nr = 3 THEN LTRIM(RTRIM(value)) END) AS Bruttopreis
                         FROM (
                             SELECT
                                 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS spalte_nr,
                                 LTRIM(RTRIM(s2.value)) AS value
                             FROM STRING_SPLIT(zeilen.ZeileText, ';') s2
                         ) spalten_split
                     ) spalten
                     CROSS APPLY (
                         -- Level 3: Datum splitten (nur Datumsteil vor dem Leerzeichen)
                         SELECT TOP 1
                             LTRIM(RTRIM(s3.value)) AS DatumTeil
                         FROM STRING_SPLIT(spalten.DatumZeit, ' ') s3
                     ) datum_split
                     WHERE spalten.Bruttopreis IS NOT NULL
                       AND spalten.DatumZeit IS NOT NULL
                 ) bruttopreis_formatiert
                 WHERE bruttopreis_formatiert.VorherigerBruttopreis IS NULL -- Erster Eintrag (kein Vorgänger)
                    OR bruttopreis_formatiert.Bruttopreis != bruttopreis_formatiert.VorherigerBruttopreis -- Preis hat sich geändert
                 ORDER BY bruttopreis_formatiert.ZeilenNummer DESC -- Umgekehrte Reihenfolge: Neueste zuerst
                 FOR XML PATH('')
                ), 1, 2, ''
            ),
            ''
        ) AS VergangenePreise
    FROM dbo.tArtikel a
    WHERE a.nDelete = 0 AND a.cAktiv = 'Y' AND a.nIstVater = 0
),

-- CTE 6: Labelhistorie aus Attribut parsen
LabelHistorie AS (
    SELECT
        a.kArtikel,
        -- Formatierte Version
        COALESCE(
            STUFF(
                (SELECT '; ' + labels_formatiert.FormatierteLabel
                 FROM (
                     SELECT
                         -- Label (Position 2) + Datum (Position 1, nur Datumsteil)
                         LTRIM(RTRIM(spalten.Label)) + ' (' +
                         LTRIM(RTRIM(datum_split.DatumTeil)) + ')' AS FormatierteLabel,
                         zeilen.ZeilenNummer,
                         spalten.Label,
                         -- Vorherige Label für Deduplizierung
                         LAG(spalten.Label) OVER (ORDER BY zeilen.ZeilenNummer) AS VorherigeLabel
                     FROM (
                         -- Level 1: Zeilen splitten
                         SELECT
                             ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS ZeilenNummer,
                             LTRIM(RTRIM(s.value)) AS ZeileText
                         FROM dbo.tArtikelAttribut aa_Label
                         INNER JOIN dbo.tAttribut attr_Label ON aa_Label.kAttribut = attr_Label.kAttribut
                         INNER JOIN dbo.tArtikelAttributSprache aas_Label ON aa_Label.kArtikelAttribut = aas_Label.kArtikelAttribut
                         INNER JOIN dbo.tAttributSprache attrs_Label ON attr_Label.kAttribut = attrs_Label.kAttribut AND aas_Label.kSprache = attrs_Label.kSprache
                         CROSS APPLY STRING_SPLIT(REPLACE(aas_Label.cWertVarchar, CHAR(13)+CHAR(10), CHAR(10)), CHAR(10)) s
                         WHERE aa_Label.kArtikel = a.kArtikel
                           AND attrs_Label.cName = 'Vergangene Label'
                           AND aas_Label.kSprache = 0
                           AND LTRIM(RTRIM(s.value)) != ''
                     ) zeilen
                     CROSS APPLY (
                         -- Level 2: Spalten splitten (Position 1=Datum+Zeit, Position 2=Label)
                         SELECT
                             MAX(CASE WHEN spalte_nr = 1 THEN LTRIM(RTRIM(value)) END) AS DatumZeit,
                             MAX(CASE WHEN spalte_nr = 2 THEN LTRIM(RTRIM(value)) END) AS Label
                         FROM (
                             SELECT
                                 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS spalte_nr,
                                 LTRIM(RTRIM(s2.value)) AS value
                             FROM STRING_SPLIT(zeilen.ZeileText, ';') s2
                         ) spalten_split
                     ) spalten
                     CROSS APPLY (
                         -- Level 3: Datum splitten (nur Datumsteil vor dem Leerzeichen)
                         SELECT TOP 1
                             LTRIM(RTRIM(s3.value)) AS DatumTeil
                         FROM STRING_SPLIT(spalten.DatumZeit, ' ') s3
                     ) datum_split
                     WHERE spalten.Label IS NOT NULL
                       AND spalten.DatumZeit IS NOT NULL
                 ) labels_formatiert
                 WHERE labels_formatiert.VorherigeLabel IS NULL -- Erster Eintrag (kein Vorgänger)
                    OR labels_formatiert.Label != labels_formatiert.VorherigeLabel -- Label haben sich geändert
                 ORDER BY labels_formatiert.ZeilenNummer DESC -- Umgekehrte Reihenfolge: Neueste zuerst
                 FOR XML PATH('')
                ), 1, 2, ''
            ),
            ''
        ) AS VergangeneLabel
    FROM dbo.tArtikel a
    WHERE a.nDelete = 0 AND a.cAktiv = 'Y' AND a.nIstVater = 0
),

-- CTE 7: Gruppengrößen berechnen
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
    a.kWarengruppe AS [Warengruppen ID],
    COALESCE(wg.cName, '') AS [Warengruppenname],

    -- Versandklasse
    COALESCE(a.kVersandklasse, 0) AS [Versandklassen ID],
    COALESCE(vk.cName, '') AS [Versandklassenname],

    -- Gewichtsinformationen
    ROUND(COALESCE(a.fGewicht, 0), 3) AS [Versandgewicht (kg)],
    ROUND(COALESCE(a.fArtGewicht, 0), 3) AS [Artikelgewicht (kg)],

    -- Stücklistenkomponenten (Was enthält dieser Artikel?)
    ad.Komponenten AS [Stücklistenkomponenten],

    -- Verwendet in Stücklisten (In welchen Stücklisten wird dieser Artikel verwendet?)
    ad.VerwendetIn AS [Verwendet in Stücklisten],

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
    END AS [Stücklistentyp],

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
    COALESCE(ph.VergangenePreise, '') AS [Vergangene Preise],

    -- Vergangene Label (formatiert: Label (Datum))
    COALESCE(lh.VergangeneLabel, '') AS [Vergangene Label],

    GETDATE() AS [Exportdatum]

FROM dbo.tArtikel a
    -- CTEs einbinden
    LEFT JOIN StuecklistenGruppen sg ON a.kArtikel = sg.kArtikel
    LEFT JOIN AggregatedData ad ON a.kArtikel = ad.kArtikel
    LEFT JOIN GruppenGroessen gg ON sg.GruppenID = gg.GruppenID
    LEFT JOIN StücklistenLieferanten sl ON a.kArtikel = sl.kArtikel
    LEFT JOIN PreisHistorie ph ON a.kArtikel = ph.kArtikel
    LEFT JOIN LabelHistorie lh ON a.kArtikel = lh.kArtikel
    
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
AND cArtNr = '9008395'

ORDER BY 
    sg.GruppenID,  -- Primär nach Stücklisten-Gruppen-ID sortieren
    CASE WHEN a.kStueckliste > 0 THEN 0 ELSE 1 END,  -- Stücklistenartikel vor Komponenten
    a.cArtNr  -- Dann nach Artikelnummer