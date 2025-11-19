-- =====================================================================================
-- Preisrecherche Export für Excel (Performance-optimiert)
-- Erstellt: $(date)
-- Beschreibung: Ermittelt umfassende Artikelinformationen für Preisrecherche
-- =====================================================================================

-- =====================================================================================
-- TEIL 1: Temp Tables erstellen (Performance: Materialisierung)
-- =====================================================================================

-- Temp Table: Rohdaten beider Historien (MATERIALISIERT)
-- Aufgeteilt in 3 CTEs für bessere Lesbarkeit und Fehlerbehandlung
;WITH
-- CTE 1: Attributdaten lesen (beide Historien-Typen in einer Query)
AttributDaten AS (
    SELECT
        a.kArtikel,
        CASE
            WHEN attrs.cName = 'Vergangene Preise' THEN 'Preis'
            WHEN attrs.cName = 'Vergangene Label' THEN 'Label'
        END AS HistorieTyp,
        aas.cWertVarchar AS cFeldWert
    FROM dbo.tArtikel a
    INNER JOIN dbo.tArtikelAttribut aa ON a.kArtikel = aa.kArtikel
    INNER JOIN dbo.tAttribut attr ON aa.kAttribut = attr.kAttribut
    INNER JOIN dbo.tArtikelAttributSprache aas ON aa.kArtikelAttribut = aas.kArtikelAttribut
    INNER JOIN dbo.tAttributSprache attrs ON attr.kAttribut = attrs.kAttribut
        AND aas.kSprache = attrs.kSprache
    WHERE a.nDelete = 0
      AND a.cAktiv = 'Y'
      AND a.nIstVater = 0
      AND attrs.cName IN ('Vergangene Preise', 'Vergangene Label')
      AND aas.kSprache = 0
),

-- CTE 2: CSV auf Zeilen splitten (Zeilenumbrüche)
ZeilenAufgesplittet AS (
    SELECT
        kArtikel,
        HistorieTyp,
        LTRIM(RTRIM(s.value)) AS VollstaendigeZeile,
        s.ordinal AS ZeilenNummer
    FROM AttributDaten
    CROSS APPLY STRING_SPLIT(REPLACE(cFeldWert, CHAR(13)+CHAR(10), CHAR(10)), CHAR(10), 1) s
    WHERE LTRIM(RTRIM(s.value)) != ''
),

-- CTE 3: Spalten-Split mit ordinal (separate CTE um Sortierungs-Konflikt zu vermeiden)
SpaltenMitNummer AS (
    SELECT
        kArtikel,
        HistorieTyp,
        VollstaendigeZeile,
        ZeilenNummer,
        value_split.ordinal AS spalte_nr,
        LTRIM(RTRIM(value_split.value)) AS value
    FROM ZeilenAufgesplittet
    CROSS APPLY STRING_SPLIT(VollstaendigeZeile, ';', 1) value_split
),

-- CTE 4: Pivot zu Spalten (OHNE ROW_NUMBER - nur noch MAX/GROUP BY)
SpaltenAufgesplittet AS (
    SELECT
        kArtikel,
        HistorieTyp,
        ZeilenNummer,
        MAX(VollstaendigeZeile) AS VollstaendigeZeile,  -- VollstaendigeZeile als Aggregat
        MAX(CASE WHEN spalte_nr = 1 THEN value END) AS Spalte1,
        MAX(CASE WHEN spalte_nr = 2 THEN value END) AS Spalte2,
        MAX(CASE WHEN spalte_nr = 3 THEN value END) AS Spalte3,
        MAX(CASE WHEN spalte_nr = 4 THEN value END) AS Spalte4,
        MAX(CASE WHEN spalte_nr = 5 THEN value END) AS Spalte5
    FROM SpaltenMitNummer
    GROUP BY kArtikel, HistorieTyp, ZeilenNummer  -- VollstaendigeZeile NICHT im GROUP BY
)

-- Finale SELECT INTO: Datums-Parsing hinzufügen
SELECT
    kArtikel,
    HistorieTyp,
    -- Datum aus Spalte1 parsen (nur Datumsteil vor dem Leerzeichen)
    TRY_CONVERT(DATETIME,
        LEFT(Spalte1, CASE
            WHEN CHARINDEX(' ', Spalte1) > 0
            THEN CHARINDEX(' ', Spalte1) - 1
            ELSE LEN(Spalte1)
        END),
    104) AS DatumZeit,
    Spalte1,
    Spalte2,
    Spalte3,
    Spalte4,
    Spalte5,
    VollstaendigeZeile,
    ZeilenNummer
INTO #RohDatenHistorie
FROM SpaltenAufgesplittet;

-- Index für schnellen Zugriff erstellen
CREATE CLUSTERED INDEX IX_RohDaten ON #RohDatenHistorie(kArtikel, HistorieTyp, ZeilenNummer);

-- =====================================================================================
-- TEIL 2: CTEs (verwenden Temp Tables + reguläre Tabellen)
-- =====================================================================================

;WITH
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

-- CTE 2: Aggregierte Daten sammeln (ohne Komponenten/VerwendetIn wegen Msg 8711)
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
        ) AS Abverkauf
    FROM dbo.tArtikel a
    WHERE a.nDelete = 0 AND a.cAktiv = 'Y' AND a.nIstVater = 0
),

-- CTE 3: Komponenten separat aggregieren (separater Scope für ORDER BY s.nSort)
KomponentenCTE AS (
    SELECT
        a.kArtikel,
        Komponenten =
            CASE
                WHEN a.kStueckliste > 0 THEN
                    COALESCE(
                        STRING_AGG(
                            ko_a.cArtNr + ' (' +
                            CASE WHEN s.fAnzahl = FLOOR(s.fAnzahl)
                                 THEN CAST(CAST(s.fAnzahl AS INT) AS VARCHAR(10))
                                 ELSE LTRIM(STR(s.fAnzahl, 10, 2)) END + 'x)',
                            ', '
                        ) WITHIN GROUP (ORDER BY s.nSort),
                        'Keine Komponenten gefunden'
                    )
                ELSE ''
            END
    FROM dbo.tArtikel a
    LEFT JOIN dbo.tStueckliste s   ON s.kStueckliste = a.kStueckliste
    LEFT JOIN dbo.tArtikel   ko_a  ON s.kArtikel = ko_a.kArtikel AND ko_a.nDelete = 0
    WHERE a.nDelete = 0 AND a.cAktiv = 'Y' AND a.nIstVater = 0
    GROUP BY a.kArtikel, a.kStueckliste
),

-- CTE 4: "Verwendet in Stücklisten" separat aggregieren (separater Scope für ORDER BY ue_a.cArtNr)
VerwendetInCTE AS (
    SELECT
        a.kArtikel,
        VerwendetIn =
            COALESCE(
                STRING_AGG(
                    ue_a.cArtNr + ' (' +
                    CASE WHEN s2.fAnzahl = FLOOR(s2.fAnzahl)
                         THEN CAST(CAST(s2.fAnzahl AS INT) AS VARCHAR(10))
                         ELSE LTRIM(STR(s2.fAnzahl, 10, 2)) END + 'x)',
                    ', '
                ) WITHIN GROUP (ORDER BY ue_a.cArtNr),
                ''
            )
    FROM dbo.tArtikel a
    LEFT JOIN dbo.tStueckliste s2 ON s2.kArtikel = a.kArtikel
    LEFT JOIN dbo.tArtikel ue_a   ON s2.kStueckliste = ue_a.kStueckliste AND ue_a.nDelete = 0
    WHERE a.nDelete = 0 AND a.cAktiv = 'Y' AND a.nIstVater = 0
    GROUP BY a.kArtikel
),

-- CTE 5: Alle Lieferanten pro Artikel sammeln
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

-- CTE 6: Stücklisten-Lieferanten ermitteln
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

-- CTE 7: Preishistorie parsen (nutzt #RohDatenHistorie - kein STRING_SPLIT mehr!)
PreisHistorieParsed AS (
    SELECT
        rdh.kArtikel,
        rdh.DatumZeit,
        rdh.Spalte2 AS Netto,
        rdh.Spalte3 AS Brutto,
        rdh.VollstaendigeZeile,
        rdh.ZeilenNummer,
        -- Vorherigen Brutto für Deduplizierung
        LAG(rdh.Spalte3) OVER (PARTITION BY rdh.kArtikel ORDER BY rdh.ZeilenNummer) AS VorherigerBrutto
    FROM #RohDatenHistorie rdh
    WHERE rdh.HistorieTyp = 'Preis'
      AND rdh.DatumZeit IS NOT NULL
),

-- CTE 8: Labelhistorie parsen (nutzt #RohDatenHistorie - kein STRING_SPLIT mehr!)
LabelHistorieParsed AS (
    SELECT
        rdh.kArtikel,
        rdh.DatumZeit,
        rdh.Spalte2 AS Label,
        rdh.VollstaendigeZeile,
        rdh.ZeilenNummer,
        -- Vorherige Label für Deduplizierung
        LAG(rdh.Spalte2) OVER (PARTITION BY rdh.kArtikel ORDER BY rdh.ZeilenNummer) AS VorherigeLabel
    FROM #RohDatenHistorie rdh
    WHERE rdh.HistorieTyp = 'Label'
      AND rdh.DatumZeit IS NOT NULL
),

-- CTE 9: PreisHistorieFormatiert (für alte Spalte "Vergangene Preise")
-- OPTIMIERT: STRING_AGG statt korrelierte Subquery
PreisHistorieFormatiert AS (
    SELECT
        kArtikel,
        COALESCE(
            STRING_AGG(
                LTRIM(RTRIM(Brutto)) + ' (' + CONVERT(VARCHAR(10), DatumZeit, 104) + ')',
                '; '
            ) WITHIN GROUP (ORDER BY ZeilenNummer DESC),
            ''
        ) AS VergangenePreise
    FROM PreisHistorieParsed
    WHERE VorherigerBrutto IS NULL
       OR Brutto != VorherigerBrutto
    GROUP BY kArtikel
),

-- CTE 10: LabelHistorieFormatiert (für alte Spalte "Vergangene Label")
-- OPTIMIERT: STRING_AGG statt korrelierte Subquery
LabelHistorieFormatiert AS (
    SELECT
        kArtikel,
        COALESCE(
            STRING_AGG(
                LTRIM(RTRIM(Label)) + ' (' + CONVERT(VARCHAR(10), DatumZeit, 104) + ')',
                '; '
            ) WITHIN GROUP (ORDER BY ZeilenNummer DESC),
            ''
        ) AS VergangeneLabel
    FROM LabelHistorieParsed
    WHERE VorherigeLabel IS NULL
       OR Label != VorherigeLabel
    GROUP BY kArtikel
),

-- CTE 11: KombinierteHistorie (neue Spalte mit allen Änderungen chronologisch)
-- OPTIMIERT: STRING_AGG statt korrelierte Subquery
KombinierteHistorie AS (
    SELECT
        kArtikel,
        COALESCE(
            STRING_AGG(VollstaendigeZeile, CHAR(10))
                WITHIN GROUP (
                    ORDER BY
                        DatumZeit DESC,
                        CASE WHEN HistorieTyp = 'Label' THEN 0 ELSE 1 END,  -- Label vor Preis
                        ZeilenNummer DESC
                ),
            ''
        ) AS Historie
    FROM (
        -- Preis-Einträge (nur Änderungen)
        SELECT
            kArtikel,
            'Preis' AS HistorieTyp,
            DatumZeit,
            VollstaendigeZeile,
            ZeilenNummer
        FROM PreisHistorieParsed
        WHERE VorherigerBrutto IS NULL
           OR Brutto != VorherigerBrutto

        UNION ALL

        -- Label-Einträge (nur Änderungen)
        SELECT
            kArtikel,
            'Label' AS HistorieTyp,
            DatumZeit,
            VollstaendigeZeile,
            ZeilenNummer
        FROM LabelHistorieParsed
        WHERE VorherigeLabel IS NULL
           OR Label != VorherigeLabel
    ) kombiniert
    GROUP BY kArtikel
),

-- CTE 12: Gruppengrößen berechnen
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
    kc.Komponenten                AS [Stücklistenkomponenten],

    -- Verwendet in Stücklisten (In welchen Stücklisten wird dieser Artikel verwendet?)
    vi.VerwendetIn                AS [Verwendet in Stücklisten],

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
    LEFT JOIN KomponentenCTE kc ON a.kArtikel = kc.kArtikel
    LEFT JOIN VerwendetInCTE vi ON a.kArtikel = vi.kArtikel
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
    AND cArtNr = '9008395'

ORDER BY 
    sg.GruppenID,  -- Primär nach Stücklisten-Gruppen-ID sortieren
    CASE WHEN a.kStueckliste > 0 THEN 0 ELSE 1 END,  -- Stücklistenartikel vor Komponenten
    a.cArtNr  -- Dann nach Artikelnummer