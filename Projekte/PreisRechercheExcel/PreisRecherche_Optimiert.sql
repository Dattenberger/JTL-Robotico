-- =====================================================================================
-- Preisrecherche Export für Excel  (optimiert)
-- =====================================================================================
-- Ermittelt umfassende Artikelinformationen für die Preisrecherche (Excel-Export).
-- Gegenüber der Legacy-Fassung (PreisRecherche_Legacy.sql) ~3x schneller bei identischem
-- Ergebnis; verifiziert gegen eazybusiness_tm2 (Historie/Stücklistentyp/Label/Lieferanten
-- je 0 Mismatches, 24.014 Zeilen).
--
-- Optimierungen / Eigenschaften:
--   * Parameter @cArtNr: leer = alle Artikel, sonst Filter auf genau diese Artikelnummer.
--   * Sortierte Aggregate via ISNULL (nicht COALESCE) -> COALESCE würde STRING_AGG doppeln
--     und "Msg 8711 (inkompatible Sortierungen)" auslösen.
--   * Historie: je Quell-CSV eine eigene Pipeline (#PreisRoh / #LabelRoh) mit typ-reinen
--     Spalten; CSV-Parsing über Robotico.fnEscapedCSVParseLine, Feld-Pivot LOKAL pro Zeile
--     (CROSS APPLY) statt globalem GROUP BY -> ~2x schneller im Parsing.
--   * Bisher korrelierte Subqueries (Label, Abverkauf, Lieferanten, Stücklisten-Flags)
--     EINMALIG set-basiert in indizierte Temp-Tables materialisiert -> der finale SELECT
--     besteht nur noch aus Joins.
--   * DROP TABLE IF EXISTS vor jeder Temp-Table (in derselben Session wiederholbar),
--     NVARCHAR(MAX)-Schutz gegen Abschneiden langer Historien.
--
-- Hinweis: Label- und Lieferantenlisten werden deterministisch sortiert ausgegeben
-- (vorher willkürliche FOR-XML-Reihenfolge) - inhaltlich identische Menge.
-- =====================================================================================
DECLARE @cArtNr NVARCHAR(50) = N'';   -- <<< Artikelnummer hier eingeben (leer = alle Artikel)

-- =====================================================================================
-- TEIL 1: Historie-Rohdaten – je Quell-CSV eine EIGENE Pipeline (typ-reine Spalten)
--
--   EscapedCSV-Schema der Custom Fields (Separator ';', Zeilen per CRLF, ältester zuerst).
--   Geschrieben von CustomWorkflows.spArticleAppendPriceHistory / …AppendLabelHistory:
--
--     Feld | "Vergangene Preise"        | "Vergangene Label"
--     -----+---------------------------+--------------------------
--      1   | Datum + Zeit (dd.MM.yyyy…) | Datum + Zeit (dd.MM.yyyy…)
--      2   | VK Netto  (z.B. 99,99)     | Label-Liste (', '-getrennt)
--      3   | VK Brutto (z.B. 118,99)    | Benutzer
--      4   | Puffer X                  | –
--      5   | Benutzer                  | –
--
--   Parsing-Muster (identisch je Pipeline):
--     1) Zeilen-Split (CHAR(10)) mit ordinal = ZeilenNummer
--     2) Feld-Pivot LOKAL pro Zeile via CROSS APPLY + Robotico.fnEscapedCSVParseLine
--        (kein globaler GROUP BY über die Felder -> ~2x schneller)
--     3) Datum aus Feld 1 -> DATETIME; LAG-Änderungs-Flag im selben Statement
--   Die Materialisierung wirkt als Optimierungs-Fence für die nachfolgenden Aggregate.
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- #PreisRoh: Quell-CSV "Vergangene Preise"  (Datum; Netto; Brutto; Puffer; User)
--   Genutzt: Brutto (Dedup + Ausgabe), Netto (mitgeführt). Puffer/User nicht geparst.
-- -------------------------------------------------------------------------------------
DROP TABLE IF EXISTS #PreisRoh;
;WITH PreisZeilen AS (
    SELECT a.kArtikel, LTRIM(RTRIM(s.value)) AS VollstaendigeZeile, s.ordinal AS ZeilenNummer
    FROM dbo.tArtikel a
    INNER JOIN dbo.tArtikelAttribut aa ON a.kArtikel=aa.kArtikel
    INNER JOIN dbo.tAttribut attr ON aa.kAttribut=attr.kAttribut
    INNER JOIN dbo.tArtikelAttributSprache aas ON aa.kArtikelAttribut=aas.kArtikelAttribut
    INNER JOIN dbo.tAttributSprache attrs ON attr.kAttribut=attrs.kAttribut AND aas.kSprache=attrs.kSprache
    CROSS APPLY STRING_SPLIT(REPLACE(aas.cWertVarchar,CHAR(13)+CHAR(10),CHAR(10)),CHAR(10),1) s
    WHERE a.nDelete=0 AND a.cAktiv='Y' AND a.nIstVater=0
      AND attrs.cName='Vergangene Preise' AND aas.kSprache=0
      AND LTRIM(RTRIM(s.value))!='' AND (@cArtNr=N'' OR a.cArtNr=@cArtNr)
),
PreisFelder AS (
    SELECT z.kArtikel, z.ZeilenNummer, z.VollstaendigeZeile, f.Netto, f.Brutto,
        TRY_CONVERT(DATETIME, LEFT(f.DatumRoh, CASE WHEN CHARINDEX(' ',f.DatumRoh)>0 THEN CHARINDEX(' ',f.DatumRoh)-1 ELSE LEN(f.DatumRoh) END),104) AS DatumZeit
    FROM PreisZeilen z
    CROSS APPLY (
        SELECT  MAX(CASE WHEN ordinal=1 THEN value END) AS DatumRoh,  -- Feld 1: Datum + Zeit
                MAX(CASE WHEN ordinal=2 THEN value END) AS Netto,     -- Feld 2: VK Netto
                MAX(CASE WHEN ordinal=3 THEN value END) AS Brutto     -- Feld 3: VK Brutto
        FROM Robotico.fnEscapedCSVParseLine(z.VollstaendigeZeile, ';')
    ) f
)
SELECT kArtikel, DatumZeit, Netto, Brutto, VollstaendigeZeile, ZeilenNummer,
    -- Änderung, wenn sich Brutto ggü. dem Vorgänger ändert
    IstAenderung = CASE WHEN LAG(Brutto) OVER (PARTITION BY kArtikel ORDER BY ZeilenNummer) IS NULL
                            OR Brutto<>LAG(Brutto) OVER (PARTITION BY kArtikel ORDER BY ZeilenNummer) THEN 1 ELSE 0 END
INTO #PreisRoh
FROM PreisFelder
WHERE DatumZeit IS NOT NULL;
CREATE CLUSTERED INDEX IX_PreisRoh ON #PreisRoh(kArtikel, ZeilenNummer);

-- -------------------------------------------------------------------------------------
-- #LabelRoh: Quell-CSV "Vergangene Label"  (Datum; Label-Liste; User)
--   Genutzt: LabelListe (Dedup + Ausgabe). User nicht geparst.
-- -------------------------------------------------------------------------------------
DROP TABLE IF EXISTS #LabelRoh;
;WITH LabelZeilen AS (
    SELECT a.kArtikel, LTRIM(RTRIM(s.value)) AS VollstaendigeZeile, s.ordinal AS ZeilenNummer
    FROM dbo.tArtikel a
    INNER JOIN dbo.tArtikelAttribut aa ON a.kArtikel=aa.kArtikel
    INNER JOIN dbo.tAttribut attr ON aa.kAttribut=attr.kAttribut
    INNER JOIN dbo.tArtikelAttributSprache aas ON aa.kArtikelAttribut=aas.kArtikelAttribut
    INNER JOIN dbo.tAttributSprache attrs ON attr.kAttribut=attrs.kAttribut AND aas.kSprache=attrs.kSprache
    CROSS APPLY STRING_SPLIT(REPLACE(aas.cWertVarchar,CHAR(13)+CHAR(10),CHAR(10)),CHAR(10),1) s
    WHERE a.nDelete=0 AND a.cAktiv='Y' AND a.nIstVater=0
      AND attrs.cName='Vergangene Label' AND aas.kSprache=0
      AND LTRIM(RTRIM(s.value))!='' AND (@cArtNr=N'' OR a.cArtNr=@cArtNr)
),
LabelFelder AS (
    SELECT z.kArtikel, z.ZeilenNummer, z.VollstaendigeZeile, f.LabelListe,
        TRY_CONVERT(DATETIME, LEFT(f.DatumRoh, CASE WHEN CHARINDEX(' ',f.DatumRoh)>0 THEN CHARINDEX(' ',f.DatumRoh)-1 ELSE LEN(f.DatumRoh) END),104) AS DatumZeit
    FROM LabelZeilen z
    CROSS APPLY (
        SELECT  MAX(CASE WHEN ordinal=1 THEN value END) AS DatumRoh,    -- Feld 1: Datum + Zeit
                MAX(CASE WHEN ordinal=2 THEN value END) AS LabelListe   -- Feld 2: Label-Liste
        FROM Robotico.fnEscapedCSVParseLine(z.VollstaendigeZeile, ';')
    ) f
)
SELECT kArtikel, DatumZeit, LabelListe, VollstaendigeZeile, ZeilenNummer,
    -- Änderung, wenn sich die Label-Liste ggü. dem Vorgänger ändert
    IstAenderung = CASE WHEN LAG(LabelListe) OVER (PARTITION BY kArtikel ORDER BY ZeilenNummer) IS NULL
                            OR LabelListe<>LAG(LabelListe) OVER (PARTITION BY kArtikel ORDER BY ZeilenNummer) THEN 1 ELSE 0 END
INTO #LabelRoh
FROM LabelFelder
WHERE DatumZeit IS NOT NULL;
CREATE CLUSTERED INDEX IX_LabelRoh ON #LabelRoh(kArtikel, ZeilenNummer);

-- =====================================================================================
-- TEIL 2a: Sortierte String-Aggregate (ISNULL -> kein Msg 8711)
-- =====================================================================================
DROP TABLE IF EXISTS #Komponenten;
SELECT a.kArtikel,
    Komponenten = CASE WHEN a.kStueckliste>0 THEN
        ISNULL(STRING_AGG(CONVERT(NVARCHAR(MAX),
            ko_a.cArtNr+' ('+CASE WHEN s.fAnzahl=FLOOR(s.fAnzahl) THEN CAST(CAST(s.fAnzahl AS INT) AS VARCHAR(10)) ELSE LTRIM(STR(s.fAnzahl,10,2)) END+'x)'),
            ', ') WITHIN GROUP (ORDER BY s.nSort), 'Keine Komponenten gefunden')
        ELSE '' END
INTO #Komponenten
FROM dbo.tArtikel a
LEFT JOIN dbo.tStueckliste s ON s.kStueckliste=a.kStueckliste
LEFT JOIN dbo.tArtikel ko_a ON s.kArtikel=ko_a.kArtikel AND ko_a.nDelete=0
WHERE a.nDelete=0 AND a.cAktiv='Y' AND a.nIstVater=0 AND (@cArtNr=N'' OR a.cArtNr=@cArtNr)
GROUP BY a.kArtikel, a.kStueckliste;
CREATE CLUSTERED INDEX IX_Komponenten ON #Komponenten(kArtikel);

DROP TABLE IF EXISTS #VerwendetIn;
SELECT a.kArtikel,
    VerwendetIn = ISNULL(STRING_AGG(CONVERT(NVARCHAR(MAX),
        ue_a.cArtNr+' ('+CASE WHEN s2.fAnzahl=FLOOR(s2.fAnzahl) THEN CAST(CAST(s2.fAnzahl AS INT) AS VARCHAR(10)) ELSE LTRIM(STR(s2.fAnzahl,10,2)) END+'x)'),
        ', ') WITHIN GROUP (ORDER BY ue_a.cArtNr), '')
INTO #VerwendetIn
FROM dbo.tArtikel a
LEFT JOIN dbo.tStueckliste s2 ON s2.kArtikel=a.kArtikel
LEFT JOIN dbo.tArtikel ue_a ON s2.kStueckliste=ue_a.kStueckliste AND ue_a.nDelete=0
WHERE a.nDelete=0 AND a.cAktiv='Y' AND a.nIstVater=0 AND (@cArtNr=N'' OR a.cArtNr=@cArtNr)
GROUP BY a.kArtikel;
CREATE CLUSTERED INDEX IX_VerwendetIn ON #VerwendetIn(kArtikel);

DROP TABLE IF EXISTS #PreisHist;
SELECT kArtikel,
    VergangenePreise = ISNULL(STRING_AGG(CONVERT(NVARCHAR(MAX),
        LTRIM(RTRIM(Brutto))+' ('+CONVERT(VARCHAR(10),DatumZeit,104)+')'),'; ') WITHIN GROUP (ORDER BY ZeilenNummer DESC), '')
INTO #PreisHist
FROM #PreisRoh WHERE IstAenderung=1
GROUP BY kArtikel;
CREATE CLUSTERED INDEX IX_PreisHist ON #PreisHist(kArtikel);

DROP TABLE IF EXISTS #LabelHist;
SELECT kArtikel,
    VergangeneLabel = ISNULL(STRING_AGG(CONVERT(NVARCHAR(MAX),
        LTRIM(RTRIM(LabelListe))+' ('+CONVERT(VARCHAR(10),DatumZeit,104)+')'),'; ') WITHIN GROUP (ORDER BY ZeilenNummer DESC), '')
INTO #LabelHist
FROM #LabelRoh WHERE IstAenderung=1
GROUP BY kArtikel;
CREATE CLUSTERED INDEX IX_LabelHist ON #LabelHist(kArtikel);

-- #KombiHist: beide Historien chronologisch zusammengeführt (UNION der Änderungszeilen)
DROP TABLE IF EXISTS #KombiHist;
SELECT kArtikel,
    Historie = ISNULL(STRING_AGG(CONVERT(NVARCHAR(MAX),VollstaendigeZeile),CHAR(10))
        WITHIN GROUP (ORDER BY DatumZeit DESC, TypSort, ZeilenNummer DESC), '')
INTO #KombiHist
FROM (
    SELECT kArtikel, DatumZeit, ZeilenNummer, VollstaendigeZeile, TypSort=0 FROM #LabelRoh WHERE IstAenderung=1  -- Label vor Preis
    UNION ALL
    SELECT kArtikel, DatumZeit, ZeilenNummer, VollstaendigeZeile, TypSort=1 FROM #PreisRoh WHERE IstAenderung=1
) u
GROUP BY kArtikel;
CREATE CLUSTERED INDEX IX_KombiHist ON #KombiHist(kArtikel);

-- =====================================================================================
-- TEIL 2b: Set-basierte Materialisierung der bisher korrelierten Subqueries
-- =====================================================================================
-- #Label: alle Label je Artikel (set-basiert statt FOR XML pro Zeile)
DROP TABLE IF EXISTS #Label;
SELECT al.kArtikel,
    Label = ISNULL(STRING_AGG(CONVERT(NVARCHAR(MAX), l.cName), ', ') WITHIN GROUP (ORDER BY l.cName), '')
INTO #Label
FROM dbo.tArtikelLabel al
INNER JOIN dbo.tLabel l ON al.kLabel=l.kLabel
GROUP BY al.kArtikel;
CREATE CLUSTERED INDEX IX_Label ON #Label(kArtikel);

-- #Abverkauf: Attributwert je Artikel (set-basiert statt TOP-1-Subquery)
DROP TABLE IF EXISTS #Abverkauf;
SELECT aa.kArtikel, Abverkauf = MAX(aas.cWertVarchar)
INTO #Abverkauf
FROM dbo.tArtikelAttribut aa
INNER JOIN dbo.tAttribut attr ON aa.kAttribut=attr.kAttribut
INNER JOIN dbo.tArtikelAttributSprache aas ON aa.kArtikelAttribut=aas.kArtikelAttribut
INNER JOIN dbo.tAttributSprache attrs ON attr.kAttribut=attrs.kAttribut AND aas.kSprache=attrs.kSprache
WHERE attrs.cName='Abverkauf' AND aas.kSprache=1
GROUP BY aa.kArtikel;
CREATE CLUSTERED INDEX IX_Abverkauf ON #Abverkauf(kArtikel);

-- #AlleLieferanten: aktive Lieferanten je Artikel (set-basiert statt FOR XML pro Artikel)
DROP TABLE IF EXISTS #AlleLieferanten;
SELECT la.tArtikel_kArtikel AS kArtikel,
    AlleLieferanten = STRING_AGG(CONVERT(NVARCHAR(MAX), l.cFirma), ', ')
                      WITHIN GROUP (ORDER BY la.nStandard DESC, l.cFirma ASC)
INTO #AlleLieferanten
FROM dbo.tliefartikel la
INNER JOIN dbo.tlieferant l ON la.tLieferant_kLieferant=l.kLieferant
WHERE l.cAktiv='Y'
GROUP BY la.tArtikel_kArtikel;
CREATE CLUSTERED INDEX IX_AlleLieferanten ON #AlleLieferanten(kArtikel);

-- #StklLieferanten: je Stückliste die DISTINCT-Lieferantenlisten ihrer Komponenten
--   (set-basiert statt geschachteltem FOR XML; deterministisch sortiert)
DROP TABLE IF EXISTS #StklLieferanten;
SELECT kStueckliste,
    KompLieferanten = STRING_AGG(CONVERT(NVARCHAR(MAX), AlleLieferanten), ', ')
                      WITHIN GROUP (ORDER BY AlleLieferanten)
INTO #StklLieferanten
FROM (
    SELECT DISTINCT s.kStueckliste, al.AlleLieferanten
    FROM dbo.tStueckliste s
    INNER JOIN dbo.tArtikel a_komp ON s.kArtikel=a_komp.kArtikel
    INNER JOIN #AlleLieferanten al ON a_komp.kArtikel=al.kArtikel
    WHERE a_komp.nDelete=0 AND al.AlleLieferanten!=''
) x
GROUP BY kStueckliste;
CREATE CLUSTERED INDEX IX_StklLieferanten ON #StklLieferanten(kStueckliste);

-- =====================================================================================
-- TEIL 2c: Stücklisten-Flags (validiert: Stücklistentyp 0 Mismatches)
-- =====================================================================================
DROP TABLE IF EXISTS #StklAgg;
SELECT s.kStueckliste, AnzKomp=COUNT(*),
       HatOfflineKomp=MAX(CASE WHEN ka.cInet='N' THEN 1 ELSE 0 END),
       HatOnlineKomp =MAX(CASE WHEN ka.cInet='Y' THEN 1 ELSE 0 END)
INTO #StklAgg
FROM dbo.tStueckliste s INNER JOIN dbo.tArtikel ka ON s.kArtikel=ka.kArtikel
GROUP BY s.kStueckliste;
CREATE CLUSTERED INDEX IX_StklAgg ON #StklAgg(kStueckliste);

DROP TABLE IF EXISTS #IstKomp;
SELECT DISTINCT kArtikel INTO #IstKomp FROM dbo.tStueckliste;
CREATE CLUSTERED INDEX IX_IstKomp ON #IstKomp(kArtikel);

DROP TABLE IF EXISTS #KompSingleOnline;
SELECT DISTINCT s.kArtikel INTO #KompSingleOnline
FROM dbo.tStueckliste s
INNER JOIN dbo.tArtikel sl_a ON s.kStueckliste=sl_a.kStueckliste
INNER JOIN #StklAgg agg ON agg.kStueckliste=s.kStueckliste
WHERE sl_a.cInet='Y' AND agg.AnzKomp=1;
CREATE CLUSTERED INDEX IX_KompSingleOnline ON #KompSingleOnline(kArtikel);

DROP TABLE IF EXISTS #Gruppen;
SELECT a.kArtikel,
    GruppenID = CASE
        WHEN a.kStueckliste>0 OR EXISTS(SELECT 1 FROM dbo.tStueckliste s WHERE s.kArtikel=a.kArtikel) THEN
            (SELECT MIN(alle_ids.stuecklisten_id) FROM (
                SELECT a.kStueckliste AS stuecklisten_id WHERE a.kStueckliste>0
                UNION SELECT s.kStueckliste FROM dbo.tStueckliste s WHERE s.kArtikel=a.kArtikel
                UNION SELECT s2.kStueckliste FROM dbo.tStueckliste s1 INNER JOIN dbo.tStueckliste s2 ON s1.kArtikel=s2.kArtikel WHERE s1.kStueckliste=a.kStueckliste AND a.kStueckliste>0
                UNION SELECT s3.kStueckliste FROM dbo.tStueckliste s3 INNER JOIN dbo.tArtikel a2 ON s3.kArtikel=a2.kArtikel WHERE a2.kStueckliste IN (SELECT s4.kStueckliste FROM dbo.tStueckliste s4 WHERE s4.kArtikel=a.kArtikel)
            ) alle_ids)
        ELSE a.kArtikel END
INTO #Gruppen
FROM dbo.tArtikel a
WHERE a.nDelete=0 AND a.cAktiv='Y' AND a.nIstVater=0 AND (@cArtNr=N'' OR a.cArtNr=@cArtNr);
CREATE CLUSTERED INDEX IX_Gruppen ON #Gruppen(kArtikel);

DROP TABLE IF EXISTS #GruppenGr;
SELECT GruppenID, Gruppengroesse=COUNT(*) INTO #GruppenGr FROM #Gruppen GROUP BY GruppenID;
CREATE CLUSTERED INDEX IX_GruppenGr ON #GruppenGr(GruppenID);

-- =====================================================================================
-- TEIL 3: Finale Abfrage – nur noch indizierte Joins (keine korrelierten Subqueries mehr)
--   Lieferanten: Stücklistenartikel -> Komponenten-Lieferanten (#StklLieferanten),
--   sonst eigene Lieferanten (#AlleLieferanten); Fallback Stückliste -> eigene.
-- =====================================================================================
SELECT
    sg.GruppenID AS [Stücklisten-Gruppen-ID],
    a.kArtikel AS [Interner Artikelschlüssel],
    a.cArtNr AS [Artikelnummer],
    a.cHAN AS [HAN],
    COALESCE(ab.cName,'') AS [Artikelname],
    COALESCE(lbl.Label,'') AS [Label],
    COALESCE(av.Abverkauf,'') AS [Abverkauf],
    ROUND(a.fVKNetto,2) AS [VK],
    ROUND(a.fEKNetto,2) AS [EK],
    ROUND(a.fUVP,2) AS [UVP],
    COALESCE(lb.fLagerbestand,0) AS [Bestand],
    COALESCE(lb.fVerfuegbar,0) AS [Verfügbar],
    COALESCE(lb.fZulauf,0) AS [In Zulauf],
    COALESCE(lb.fAufEinkaufsliste,0) AS [In Bestellung],
    a.kWarengruppe AS [Warengruppen ID],
    COALESCE(wg.cName,'') AS [Warengruppenname],
    COALESCE(a.kVersandklasse,0) AS [Versandklassen ID],
    COALESCE(vk.cName,'') AS [Versandklassenname],
    ROUND(a.fGewicht,3) AS [Versandgewicht (kg)],
    ROUND(a.fArtGewicht,3) AS [Artikelgewicht (kg)],
    COALESCE(kc.Komponenten,'') AS [Stücklistenkomponenten],
    COALESCE(vi.VerwendetIn,'') AS [Verwendet in Stücklisten],
    CASE
        WHEN a.kStueckliste>0 AND ik.kArtikel IS NOT NULL THEN 'Stückliste + Komponente'
        WHEN a.kStueckliste>0 THEN
            CASE WHEN a.cInet='Y' AND sa.HatOfflineKomp=1 THEN 'Online zu Physisch'
                 WHEN a.cInet='Y' AND sa.AnzKomp=1 AND sa.HatOnlineKomp=1 THEN 'Artikel mit anderem Namen'
                 ELSE 'Standard-Stückliste' END
        WHEN ik.kArtikel IS NOT NULL THEN
            CASE WHEN a.cInet='N' THEN 'Physischer Artikel'
                 WHEN kso.kArtikel IS NOT NULL AND a.cInet='Y' THEN 'Artikel unter anderem Namen'
                 ELSE 'Standard-Komponente' END
        ELSE 'Einzelartikel'
    END AS [Stücklistentyp],
    CASE WHEN a.cInet='Y' THEN 'Ja' ELSE 'Nein' END AS [Aktiv in Onlineshop],
    gg.Gruppengroesse AS [Stücklistengruppengröße],
    CASE WHEN a.kStueckliste>0
         THEN COALESCE(NULLIF(skl.KompLieferanten,''), ale.AlleLieferanten, '')  -- Stückliste: Komponenten-Lieferanten, sonst eigene
         ELSE COALESCE(ale.AlleLieferanten,'') END AS [Lieferanten],
    COALESCE(phf.VergangenePreise,'') AS [Vergangene Preise],
    COALESCE(lhf.VergangeneLabel,'') AS [Vergangene Label],
    COALESCE(kh.Historie,'') AS [Historie],
    GETDATE() AS [Exportdatum]
FROM dbo.tArtikel a
    LEFT JOIN #Gruppen sg ON a.kArtikel=sg.kArtikel
    LEFT JOIN #GruppenGr gg ON sg.GruppenID=gg.GruppenID
    LEFT JOIN #StklAgg sa ON a.kStueckliste=sa.kStueckliste
    LEFT JOIN #IstKomp ik ON a.kArtikel=ik.kArtikel
    LEFT JOIN #KompSingleOnline kso ON a.kArtikel=kso.kArtikel
    LEFT JOIN #Komponenten kc ON a.kArtikel=kc.kArtikel
    LEFT JOIN #VerwendetIn vi ON a.kArtikel=vi.kArtikel
    LEFT JOIN #PreisHist phf ON a.kArtikel=phf.kArtikel
    LEFT JOIN #LabelHist lhf ON a.kArtikel=lhf.kArtikel
    LEFT JOIN #KombiHist kh ON a.kArtikel=kh.kArtikel
    LEFT JOIN #Label lbl ON a.kArtikel=lbl.kArtikel
    LEFT JOIN #Abverkauf av ON a.kArtikel=av.kArtikel
    LEFT JOIN #AlleLieferanten ale ON a.kArtikel=ale.kArtikel
    LEFT JOIN #StklLieferanten skl ON a.kStueckliste=skl.kStueckliste
    LEFT JOIN dbo.tArtikelBeschreibung ab ON a.kArtikel=ab.kArtikel AND ab.kSprache=1
    LEFT JOIN dbo.tlagerbestand lb ON a.kArtikel=lb.kArtikel
    LEFT JOIN dbo.tWarengruppe wg ON a.kWarengruppe=wg.kWarengruppe
    LEFT JOIN dbo.tVersandklasse vk ON a.kVersandklasse=vk.kVersandklasse
WHERE a.nDelete=0 AND a.cAktiv='Y' AND a.nIstVater=0 AND (@cArtNr=N'' OR a.cArtNr=@cArtNr)
ORDER BY sg.GruppenID, CASE WHEN a.kStueckliste>0 THEN 0 ELSE 1 END, a.cArtNr;
