-- =====================================================================================
-- Preisrecherche Export für Excel  (optimiert, Msg-8711-sicher)
-- Erstellt: $(date)
-- Beschreibung: Ermittelt umfassende Artikelinformationen für Preisrecherche.
--
-- Optimierungen ggü. PreisRecherche.sql:
--   1) PARAMETER @cArtNr oben: leer = alle Artikel, sonst Filter auf genau diese
--      Artikelnummer (ersetzt den fest verdrahteten Debug-Filter).
--   2) Jede SORTIERTE Aggregation (STRING_AGG ... WITHIN GROUP) wird in einem
--      EIGENEN Statement in eine Temp-Table materialisiert. Dadurch trifft in
--      keinem Scope mehr als eine Sortierung aufeinander
--      -> kein "Msg 8711: inkompatible Sortierungen" mehr.
--   3) CSV-Parsing der Historie über die projektweite Read-Primitive
--      Robotico.fnEscapedCSVParseLine (statt handgebautem STRING_SPLIT-Pivot).
--   4) DROP TABLE IF EXISTS vor jeder Temp-Table -> in derselben Session
--      wiederholt lauffähig.
--   5) NVARCHAR(MAX)-Schutz in STRING_AGG -> keine 8000-Zeichen-Abschneidung
--      bei langen Historien.
-- =====================================================================================

-- =====================================================================================
-- PARAMETER
-- =====================================================================================
DECLARE @cArtNr NVARCHAR(50) = N'';   -- <<< Artikelnummer hier eingeben (leer = alle Artikel)


-- =====================================================================================
-- TEIL 1: Historie-Rohdaten materialisieren (#RohDatenHistorie)
--   Parst beide Historien-Typen ("Vergangene Preise" + "Vergangene Label") in einem
--   Durchlauf. Spalten-Split über Robotico.fnEscapedCSVParseLine (EscapedCSV-Format:
--   Datum; Netto; Brutto; Puffer X; User).
-- =====================================================================================
DROP TABLE IF EXISTS #RohDatenHistorie;

;WITH
-- CTE 1: Attributdaten lesen (beide Historien-Typen in einer Query)
AttributDaten AS (
    SELECT
        a.kArtikel,
        CASE
            WHEN attrs.cName = 'Vergangene Preise' THEN 'Preis'
            WHEN attrs.cName = 'Vergangene Label'  THEN 'Label'
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
      AND (@cArtNr = N'' OR a.cArtNr = @cArtNr)
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

-- CTE 3: Spalten-Pivot über Robotico.fnEscapedCSVParseLine (projektweite Read-Primitive)
SpaltenPivot AS (
    SELECT
        z.kArtikel,
        z.HistorieTyp,
        z.ZeilenNummer,
        z.VollstaendigeZeile,
        MAX(CASE WHEN p.ordinal = 1 THEN p.value END) AS Spalte1,  -- Datum + Zeit
        MAX(CASE WHEN p.ordinal = 2 THEN p.value END) AS Spalte2,  -- Netto / Label
        MAX(CASE WHEN p.ordinal = 3 THEN p.value END) AS Spalte3,  -- Brutto
        MAX(CASE WHEN p.ordinal = 4 THEN p.value END) AS Spalte4,  -- Puffer
        MAX(CASE WHEN p.ordinal = 5 THEN p.value END) AS Spalte5   -- User
    FROM ZeilenAufgesplittet z
    CROSS APPLY Robotico.fnEscapedCSVParseLine(z.VollstaendigeZeile, ';') p
    GROUP BY z.kArtikel, z.HistorieTyp, z.ZeilenNummer, z.VollstaendigeZeile
)
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
FROM SpaltenPivot;

CREATE CLUSTERED INDEX IX_RohDaten ON #RohDatenHistorie(kArtikel, HistorieTyp, ZeilenNummer);


-- =====================================================================================
-- TEIL 2: Sortierte Aggregate je in eigener Temp-Table (vermeidet Msg 8711)
--   Jede STRING_AGG ... WITHIN GROUP (ORDER BY ...) lebt in einem eigenen Scope.
-- =====================================================================================

-- ---------------------------------------------------------------------------
-- #Komponenten  (ORDER BY s.nSort)  -- Was enthält dieser Stücklistenartikel?
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS #Komponenten;

SELECT
    a.kArtikel,
    Komponenten =
        CASE
            WHEN a.kStueckliste > 0 THEN
                ISNULL(  -- ISNULL statt COALESCE: COALESCE würde die STRING_AGG doppeln -> Msg 8711
                    STRING_AGG(
                        CONVERT(NVARCHAR(MAX),
                            ko_a.cArtNr + ' (' +
                            CASE WHEN s.fAnzahl = FLOOR(s.fAnzahl)
                                 THEN CAST(CAST(s.fAnzahl AS INT) AS VARCHAR(10))
                                 ELSE LTRIM(STR(s.fAnzahl, 10, 2)) END + 'x)'),
                        ', '
                    ) WITHIN GROUP (ORDER BY s.nSort),
                    'Keine Komponenten gefunden'
                )
            ELSE ''
        END
INTO #Komponenten
FROM dbo.tArtikel a
LEFT JOIN dbo.tStueckliste s  ON s.kStueckliste = a.kStueckliste
LEFT JOIN dbo.tArtikel  ko_a  ON s.kArtikel = ko_a.kArtikel AND ko_a.nDelete = 0
WHERE a.nDelete = 0 AND a.cAktiv = 'Y' AND a.nIstVater = 0
  AND (@cArtNr = N'' OR a.cArtNr = @cArtNr)
GROUP BY a.kArtikel, a.kStueckliste;

CREATE CLUSTERED INDEX IX_Komponenten ON #Komponenten(kArtikel);

-- ---------------------------------------------------------------------------
-- #VerwendetIn  (ORDER BY ue_a.cArtNr)  -- In welchen Stücklisten kommt der Artikel vor?
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS #VerwendetIn;

SELECT
    a.kArtikel,
    VerwendetIn =
        ISNULL(  -- ISNULL statt COALESCE: vermeidet Doppelung der STRING_AGG -> Msg 8711
            STRING_AGG(
                CONVERT(NVARCHAR(MAX),
                    ue_a.cArtNr + ' (' +
                    CASE WHEN s2.fAnzahl = FLOOR(s2.fAnzahl)
                         THEN CAST(CAST(s2.fAnzahl AS INT) AS VARCHAR(10))
                         ELSE LTRIM(STR(s2.fAnzahl, 10, 2)) END + 'x)'),
                ', '
            ) WITHIN GROUP (ORDER BY ue_a.cArtNr),
            ''
        )
INTO #VerwendetIn
FROM dbo.tArtikel a
LEFT JOIN dbo.tStueckliste s2 ON s2.kArtikel = a.kArtikel
LEFT JOIN dbo.tArtikel  ue_a  ON s2.kStueckliste = ue_a.kStueckliste AND ue_a.nDelete = 0
WHERE a.nDelete = 0 AND a.cAktiv = 'Y' AND a.nIstVater = 0
  AND (@cArtNr = N'' OR a.cArtNr = @cArtNr)
GROUP BY a.kArtikel;

CREATE CLUSTERED INDEX IX_VerwendetIn ON #VerwendetIn(kArtikel);

-- ---------------------------------------------------------------------------
-- #HistDedup  -- geparste Historie mit Änderungs-Flag (LAG je Artikel + Typ)
--   IstAenderung = 1, wenn der relevante Wert (Preis: Brutto/Spalte3,
--   Label: Spalte2) sich gegenüber dem Vorgänger geändert hat.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS #HistDedup;

SELECT
    kArtikel,
    HistorieTyp,
    DatumZeit,
    ZeilenNummer,
    VollstaendigeZeile,
    Spalte2,
    Spalte3,
    CASE
        WHEN HistorieTyp = 'Preis' THEN
            CASE WHEN LAG(Spalte3) OVER (PARTITION BY kArtikel, HistorieTyp ORDER BY ZeilenNummer) IS NULL
                      OR Spalte3 <> LAG(Spalte3) OVER (PARTITION BY kArtikel, HistorieTyp ORDER BY ZeilenNummer)
                 THEN 1 ELSE 0 END
        ELSE
            CASE WHEN LAG(Spalte2) OVER (PARTITION BY kArtikel, HistorieTyp ORDER BY ZeilenNummer) IS NULL
                      OR Spalte2 <> LAG(Spalte2) OVER (PARTITION BY kArtikel, HistorieTyp ORDER BY ZeilenNummer)
                 THEN 1 ELSE 0 END
    END AS IstAenderung
INTO #HistDedup
FROM #RohDatenHistorie
WHERE DatumZeit IS NOT NULL;

CREATE CLUSTERED INDEX IX_HistDedup ON #HistDedup(kArtikel, HistorieTyp, ZeilenNummer);

-- ---------------------------------------------------------------------------
-- #PreisHist  (ORDER BY ZeilenNummer DESC)  -- Spalte "Vergangene Preise"
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS #PreisHist;

SELECT
    kArtikel,
    VergangenePreise =
        ISNULL(  -- ISNULL statt COALESCE: vermeidet Doppelung der STRING_AGG -> Msg 8711
            STRING_AGG(
                CONVERT(NVARCHAR(MAX),
                    LTRIM(RTRIM(Spalte3)) + ' (' + CONVERT(VARCHAR(10), DatumZeit, 104) + ')'),
                '; '
            ) WITHIN GROUP (ORDER BY ZeilenNummer DESC),
            ''
        )
INTO #PreisHist
FROM #HistDedup
WHERE HistorieTyp = 'Preis' AND IstAenderung = 1
GROUP BY kArtikel;

CREATE CLUSTERED INDEX IX_PreisHist ON #PreisHist(kArtikel);

-- ---------------------------------------------------------------------------
-- #LabelHist  (ORDER BY ZeilenNummer DESC)  -- Spalte "Vergangene Label"
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS #LabelHist;

SELECT
    kArtikel,
    VergangeneLabel =
        ISNULL(  -- ISNULL statt COALESCE: vermeidet Doppelung der STRING_AGG -> Msg 8711
            STRING_AGG(
                CONVERT(NVARCHAR(MAX),
                    LTRIM(RTRIM(Spalte2)) + ' (' + CONVERT(VARCHAR(10), DatumZeit, 104) + ')'),
                '; '
            ) WITHIN GROUP (ORDER BY ZeilenNummer DESC),
            ''
        )
INTO #LabelHist
FROM #HistDedup
WHERE HistorieTyp = 'Label' AND IstAenderung = 1
GROUP BY kArtikel;

CREATE CLUSTERED INDEX IX_LabelHist ON #LabelHist(kArtikel);

-- ---------------------------------------------------------------------------
-- #KombiHist  (ORDER BY DatumZeit DESC, Typ, ZeilenNummer DESC)
--   Neue Spalte "Historie": alle Änderungen (Preis + Label) chronologisch.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS #KombiHist;

SELECT
    kArtikel,
    Historie =
        ISNULL(  -- ISNULL statt COALESCE: COALESCE würde die STRING_AGG doppeln -> Msg 8711
            STRING_AGG(CONVERT(NVARCHAR(MAX), VollstaendigeZeile), CHAR(10))
                WITHIN GROUP (
                    ORDER BY
                        DatumZeit DESC,
                        CASE WHEN HistorieTyp = 'Label' THEN 0 ELSE 1 END,  -- Label vor Preis
                        ZeilenNummer DESC
                ),
            ''
        )
INTO #KombiHist
FROM #HistDedup
WHERE IstAenderung = 1
GROUP BY kArtikel;

CREATE CLUSTERED INDEX IX_KombiHist ON #KombiHist(kArtikel);


-- =====================================================================================
-- TEIL 3: Finale Abfrage
--   Nur noch nicht-sortierte Aggregate (FOR XML PATH / Subqueries) im Scope,
--   sortierte Aggregate kommen fertig aus den Temp-Tables -> kein Msg 8711.
-- =====================================================================================

;WITH
-- CTE: Stücklisten-Beziehungen und Gruppierungs-IDs berechnen
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
      AND (@cArtNr = N'' OR a.cArtNr = @cArtNr)
),

-- CTE: Aggregierte Daten sammeln (Label via FOR XML PATH + Abverkauf-Attribut)
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
      AND (@cArtNr = N'' OR a.cArtNr = @cArtNr)
),

-- CTE: Alle Lieferanten pro Artikel sammeln
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

-- CTE: Stücklisten-Lieferanten ermitteln
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
      AND (@cArtNr = N'' OR a.cArtNr = @cArtNr)
),

-- CTE: Gruppengrößen berechnen
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
    COALESCE(kc.Komponenten, '')  AS [Stücklistenkomponenten],

    -- Verwendet in Stücklisten (In welchen Stücklisten wird dieser Artikel verwendet?)
    COALESCE(vi.VerwendetIn, '')  AS [Verwendet in Stücklisten],

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
    -- CTEs / Temp-Tables einbinden
    LEFT JOIN StuecklistenGruppen sg ON a.kArtikel = sg.kArtikel
    LEFT JOIN AggregatedData ad ON a.kArtikel = ad.kArtikel
    LEFT JOIN #Komponenten kc ON a.kArtikel = kc.kArtikel
    LEFT JOIN #VerwendetIn vi ON a.kArtikel = vi.kArtikel
    LEFT JOIN GruppenGroessen gg ON sg.GruppenID = gg.GruppenID
    LEFT JOIN StücklistenLieferanten sl ON a.kArtikel = sl.kArtikel
    LEFT JOIN #PreisHist phf ON a.kArtikel = phf.kArtikel
    LEFT JOIN #LabelHist lhf ON a.kArtikel = lhf.kArtikel
    LEFT JOIN #KombiHist kh ON a.kArtikel = kh.kArtikel

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
    AND (@cArtNr = N'' OR a.cArtNr = @cArtNr)  -- Optionaler Artikelnummer-Filter (leer = alle)

ORDER BY
    sg.GruppenID,  -- Primär nach Stücklisten-Gruppen-ID sortieren
    CASE WHEN a.kStueckliste > 0 THEN 0 ELSE 1 END,  -- Stücklistenartikel vor Komponenten
    a.cArtNr;  -- Dann nach Artikelnummer
