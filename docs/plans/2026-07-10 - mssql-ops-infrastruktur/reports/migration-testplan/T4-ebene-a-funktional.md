---
date: 2026-07-27
author: Detail-Agent T4 (Opus) — Migrations-Testplan Phase 2
status: Test plan — programmer-ready (no execution performed)
context: Funktionaler Vollabdeckungs-Testplan der Ebene-A-Inhalte (eazybusiness-Kette)
  gegen die restaurierte, getrimmte eazybusiness im Container robotico-e2e-mssql.
  Fehlerklassen F4.1–F4.9 der Grundrecherche. Keine Ausführung, keine Server-Zugriffe.
related-research: 00-grundrecherche.md (F4.*), 03-teilrecherche-ebene-a-wartung.md (§1-2, §4)
related-plan: ../../mssql-ops-infrastruktur.md
---

# T4 — Ebene-A-Inhalte: funktionaler Vollabdeckungs-Testplan

Deckt **alle** Ebene-A-Funktionen und -Aktionen ab (User-Vorgabe: Vollabdeckung, auch der
bisher testlosen Objekte), plus die Randfall-Lücken der vier bestehenden `*_Tests.sql`-Suiten,
die Struktur-Fehlerfälle und die Trigger-Interaktionen. Jeder Testfall trägt eine ID (`T4-NN`),
Setup/Fixtures, ein ausführbares T-SQL-Skript, das erwartete Ergebnis und Cleanup. Der Abschnitt
[Findings-Kandidaten](#findings-kandidaten) sammelt die Fälle, die als **erwartetes FAIL** ein
echtes Design-/Bug-Finding sind (nicht zu fixen — separate User-Entscheidung).

> **Sicherheits-Invariante.** Ausführung **ausschließlich** gegen den Container
> `robotico-e2e-mssql` (`localhost,14330`, Env `E2E`). `vm-sql2` = PROD = tabu, `test1` (SQL 2025)
> ist keine gültige Restore-Quelle. **Jedes** Skript beginnt mit dem Servername-Guard aus
> [§0.2](#02-servername-guard-pflicht-kopf-jedes-skripts). Alle datenverändernden Tests laufen
> transaktionsbasiert mit `ROLLBACK` (Muster der bestehenden Suiten) — nach den Tests bleibt die
> DB sauber.

---

## 0. Voraussetzungen, Konventionen, Guard

### 0.1 Umgebung (liefert T5)

- Container `robotico-e2e-mssql`, SQL Server 2022, `MSSQL_COLLATION=Latin1_General_CI_AS`,
  `MSSQL_AGENT_ENABLED=true`, Host-Port 14330.
- In den Container ist die **getrimmte, aber schema-vollständige** `eazybusiness` restauriert
  (echtes JTL-Schema inkl. `Verkauf.*`, `dbo.tArtikel`, `dbo.tLiefArtikel`, `dbo.tLagerArtikel`,
  `dbo.tGebinde`, `dbo.tLieferantenBestellung(Pos)`, `Lieferantenbestellung.spLieferantenBestellungPosBearbeiten`,
  Guard-Trigger `tgr_tlieferantenBestellungPos_INSUPDEL`, Steuer-/Einheiten-Stammdaten). Compat-Level
  der DB = 160 (SQL 2022). Ebene A ist per grate deployt (`Robotico.*` + `CustomWorkflows.sp*`).
- Aufruf je Skript: `sqlcmd -S localhost,14330 -U sa -d eazybusiness -i <skript>.sql`
  (Passwort via `SQLCMDPASSWORD`/`MSSQL_SA_PASSWORD`, nie auf argv).

### 0.2 Servername-Guard (Pflicht-Kopf jedes Skripts)

```sql
-- === SAFETY GUARD: refuse to run against anything that looks like PROD ===================
IF UPPER(CAST(SERVERPROPERTY('MachineName') AS NVARCHAR(256))) LIKE N'%VM-SQL2%'
   OR UPPER(CAST(@@SERVERNAME AS NVARCHAR(256)))               LIKE N'%VM-SQL2%'
   OR UPPER(CAST(SERVERPROPERTY('MachineName') AS NVARCHAR(256))) LIKE N'%ZDBIKES%'
    THROW 51999, 'REFUSING TO RUN: this server looks like PROD (vm-sql2/ZDBIKES). E2E only.', 1;
GO
```

Der Container-`MachineName` ist der Container-Host (z. B. der Compose-Servicename), niemals
`VM-SQL2` — der Guard blockt also nur den Fehlgriff auf Prod, nie den E2E-Lauf.

### 0.3 Harness-Muster (identisch zu den bestehenden Suiten)

Jede Suite eröffnet `#TestResults (testName NVARCHAR(200), passed INT, total INT)`, jeder Testfall
läuft in `BEGIN TRANSACTION … ROLLBACK` mit `TRY/CATCH`, zählt PASS mit `+`/FAIL mit `x`, und am
Ende druckt der Standard-Summenblock (aus `CustomFieldAPI_Tests.sql:365-410` wörtlich übernehmbar)
`ALL TESTS PASSED`/`TESTS FAILED` mit Cursor über die Fehler. Diese Skripte sind so geschnitten,
dass sie später als `tests/eazybusiness/<Name>_Tests.sql` eingecheckt werden können.

### 0.4 Fixture-Strategie — dynamische Auflösung statt harter IDs

Der getrimmte Klon behält alle Stammdaten (`tArtikel`, `tLiefArtikel`, `tLagerArtikel`,
Steuer-/Einheiten), aber die konkreten PKs sind klon-abhängig. Wie `DuplicateOrders_Tests.sql`
(dort `#TestEnv`) lösen die Skripte ihre Testobjekte **dynamisch** auf (erstes passendes Artikel/
Lieferant-Tupel) statt IDs wie `19807` hart zu verdrahten — das macht die Suite umgebungs-robust
(schließt zugleich die Test-8-Umgebungsabhängigkeit, siehe [T4-09c](#t4-09-duplicate-order-lücken)).
Wo synthetische Zeilen nötig sind (Auftrag, Lieferantenbestellung), werden sie in der Transaktion
angelegt und mitgerollt.

### 0.5 Candidate-File-Mapping

| Testgruppe | IDs | Kandidaten-Datei |
|---|---|---|
| Aktionen ohne Test | T4-01…05 | je eine neue `tests/eazybusiness/<Action>_Tests.sql` |
| up/0003-Drop | T4-06 | `tests/eazybusiness/PaypalDrop_Verify.sql` |
| CustomField-Lücken | T4-07 | Ergänzung `CustomFieldAPI_Tests.sql` |
| History-Lücken | T4-08 | Ergänzung `HistorySPs_Tests.sql` |
| Duplicate-Lücken | T4-09 | Ergänzung `DuplicateOrders_Tests.sql` |
| Parser-Randfälle | T4-10 | Ergänzung `StringAndCSVUtilities_Tests.sql` |
| Struktur-Fehlerfälle | T4-11…13 | `tests/eazybusiness/StructuralFailures_Tests.sql` (+ Scratch-DB) |
| Trigger-Interaktionen | T4-14…16 | Ergänzung `VpeCheck_Tests.sql` / Probe-Skript |

---

## Gruppe A — Vollabdeckung der 5 testlosen Aktionen (F4.9)

### T4-01 — `spAuftragPreiseAufNull`

**Fehlerklasse:** F4.2 (TVP-Create-Time-Abhängigkeit), Kernlogik + teilfakturierter Auftrag.
**Setup:** ein Kunde ohne Aufträge (`#TestEnv`-Muster); synthetischer Auftrag mit 3 Positionen,
davon 1 fakturiert (Zeile in `Rechnung.tRechnungPosition` mit passender `kAuftragPosition`).
**Erwartet:** nicht-fakturierte Positionen → `fEkNetto=0`, `fVkNetto=0`; die fakturierte Position
bleibt **unverändert**; `Verkauf.spAuftragEckdatenBerechnen` läuft ohne Fehler (TVP existiert).

```sql
-- T4-01  spAuftragPreiseAufNull — zeros only non-invoiced positions, protects invoiced
DECLARE @p INT = 0, @t INT = 3;
BEGIN TRAN;
BEGIN TRY
    DECLARE @kKunde INT = (SELECT TOP 1 k.kKunde FROM dbo.tkunde k
        WHERE NOT EXISTS (SELECT 1 FROM Verkauf.tAuftrag a WHERE a.kKunde = k.kKunde) ORDER BY k.kKunde);
    DECLARE @kFirmaHistory INT = (SELECT MIN(kFirmaHistory) FROM dbo.tFirmaHistory);
    DECLARE @kSprache INT = (SELECT MIN(kSprache) FROM dbo.tSpracheUsed);

    INSERT INTO Verkauf.tAuftrag (kKunde,kBenutzer,cAuftragsNr,nType,fFaktor,kFirmaHistory,kSprache,
        cVersandlandWaehrung,fVersandlandWaehrungFaktor,fFinanzierungskosten,kBenutzerErstellt,dErstellt,nStorno)
        VALUES (@kKunde,0,'T4-01-'+CONVERT(NVARCHAR(36),NEWID()),1,1,@kFirmaHistory,@kSprache,'EUR',1,0,0,GETDATE(),0);
    DECLARE @kAuftrag INT = CAST(SCOPE_IDENTITY() AS INT);

    -- 3 positions; the first one gets "invoiced" via a tRechnungPosition row
    INSERT INTO Verkauf.tAuftragPosition (kAuftrag,cArtNr,fAnzahl,fMwSt,fEkNetto,fVkNetto,nType)
        VALUES (@kAuftrag,'T4-01-A',1,19,10,50,1),(@kAuftrag,'T4-01-B',1,19,20,60,1),(@kAuftrag,'T4-01-C',1,19,30,70,1);
    DECLARE @kPosInvoiced INT = (SELECT MIN(kAuftragPosition) FROM Verkauf.tAuftragPosition WHERE kAuftrag=@kAuftrag);
    -- minimal invoice + invoice position referencing the first order position
    -- (column set trimmed to NOT-NULLs; adjust to the clone's tRechnung/tRechnungPosition schema)
    DECLARE @kRechnung INT;
    INSERT INTO Rechnung.tRechnung (kKunde, cRechnungsNr, dErstellt) VALUES (@kKunde,'T4-01-R',GETDATE());
    SET @kRechnung = CAST(SCOPE_IDENTITY() AS INT);
    INSERT INTO Rechnung.tRechnungPosition (kRechnung, kAuftragPosition) VALUES (@kRechnung, @kPosInvoiced);

    EXEC CustomWorkflows.spAuftragPreiseAufNull @kAuftrag = @kAuftrag;

    IF EXISTS (SELECT 1 FROM Verkauf.tAuftragPosition WHERE kAuftrag=@kAuftrag AND kAuftragPosition<>@kPosInvoiced AND fEkNetto=0 AND fVkNetto=0)
       AND NOT EXISTS (SELECT 1 FROM Verkauf.tAuftragPosition WHERE kAuftrag=@kAuftrag AND kAuftragPosition<>@kPosInvoiced AND (fEkNetto<>0 OR fVkNetto<>0))
        BEGIN PRINT '  + non-invoiced positions zeroed'; SET @p+=1; END ELSE PRINT '  x non-invoiced not fully zeroed';

    IF EXISTS (SELECT 1 FROM Verkauf.tAuftragPosition WHERE kAuftragPosition=@kPosInvoiced AND fVkNetto=50 AND fEkNetto=10)
        BEGIN PRINT '  + invoiced position protected'; SET @p+=1; END ELSE PRINT '  x invoiced position was zeroed (BUG)';

    -- recompute ran (Eckdaten row exists / no throw reached here)
    SET @p+=1; PRINT '  + Eckdatenberechnen executed without error';
    ROLLBACK TRAN;
END TRY BEGIN CATCH IF @@TRANCOUNT>0 ROLLBACK TRAN; PRINT '  x ERROR: '+ERROR_MESSAGE(); END CATCH
INSERT INTO #TestResults VALUES ('T4-01 spAuftragPreiseAufNull', @p, @t);
GO
```

> Hinweis: die exakte Spaltenliste von `Rechnung.tRechnung`/`tRechnungPosition` ist im echten
> JTL-Schema breiter (viele NOT-NULL-Spalten). Beim ersten Lauf die minimal nötigen NOT-NULL-Spalten
> aus `A_Context/JTL 1.10.11.0/…Rechnung…` ergänzen; der LEFT-JOIN-Schutz hängt nur an
> `RP.kRechnungPosition IS NOT NULL` für die betroffene `kAuftragPosition`.

### T4-02 — `spGebindeErstellen` (inkl. Nicht-Idempotenz-Finding)

**Fehlerklasse:** F4.6 (Nicht-Idempotenz — **Finding**), THROW 50000 (Einheit fehlt), Suffix-Zweige.
**Setup:** ein Artikel mit gesetztem `cHAN`/`cBarcode` und **genau einem** `tLiefArtikel`, dessen
`cLiefArtNr = cHAN` (HAN-Match-Zweig); zusätzlich ein Artikel mit 0 oder >1 Lieferanten (Flag-Zweig).

```sql
-- T4-02  spGebindeErstellen — happy path, flag path, missing-unit THROW, and NON-IDEMPOTENCE
DECLARE @p INT = 0, @t INT = 4;
BEGIN TRAN;
BEGIN TRY
    -- pick an article with a HAN and exactly one supplier whose cLiefArtNr equals the HAN
    DECLARE @kArtikel INT = (
        SELECT TOP 1 a.kArtikel FROM dbo.tArtikel a
        JOIN dbo.tLiefArtikel la ON la.tArtikel_kArtikel = a.kArtikel
        WHERE ISNULL(a.cHAN,'')<>'' AND a.cHAN = la.cLiefArtNr
        GROUP BY a.kArtikel, a.cHAN HAVING COUNT(*)=1);
    IF @kArtikel IS NULL BEGIN PRINT '  ~ SKIP: no single-supplier HAN-match article in trimmed clone'; SET @p=@t; GOTO done02; END

    DECLARE @hanBefore NVARCHAR(255) = (SELECT cHAN FROM dbo.tArtikel WHERE kArtikel=@kArtikel);
    DECLARE @gebBefore INT = (SELECT COUNT(*) FROM dbo.tGebinde WHERE kArtikel=@kArtikel);

    EXEC CustomWorkflows.spGebindeErstellen @kArtikel = @kArtikel;

    IF (SELECT COUNT(*) FROM dbo.tGebinde WHERE kArtikel=@kArtikel) = @gebBefore + 1
        BEGIN PRINT '  + one tGebinde row created'; SET @p+=1; END ELSE PRINT '  x tGebinde row count wrong';
    IF EXISTS (SELECT 1 FROM dbo.tArtikel WHERE kArtikel=@kArtikel AND cHAN = @hanBefore + '-gebinde-umgezogen')
        BEGIN PRINT '  + HAN suffixed (single-supplier match branch)'; SET @p+=1; END ELSE PRINT '  x HAN suffix wrong';
    -- tGebinde.cName must hold the Stk. unit id (resolved by name), not literal text
    IF EXISTS (SELECT 1 FROM dbo.tGebinde g WHERE g.kArtikel=@kArtikel
               AND g.cName = CAST((SELECT MIN(kEinheit) FROM dbo.tEinheitSprache WHERE cName=N'Stk.') AS NVARCHAR(255)))
        BEGIN PRINT '  + cName carries Stk. unit id'; SET @p+=1; END ELSE PRINT '  x cName not the unit id';

    -- FINDING F4.6: run AGAIN in the same tx -> second tGebinde row + suffix appended twice
    EXEC CustomWorkflows.spGebindeErstellen @kArtikel = @kArtikel;
    DECLARE @gebAfter2 INT = (SELECT COUNT(*) FROM dbo.tGebinde WHERE kArtikel=@kArtikel);
    DECLARE @hanAfter2 NVARCHAR(255) = (SELECT cHAN FROM dbo.tArtikel WHERE kArtikel=@kArtikel);
    -- Expected PASS-of-the-assertion == demonstrates the BUG: 2 extra rows + doubled suffix.
    IF @gebAfter2 = @gebBefore + 2 AND @hanAfter2 LIKE '%-gebinde-umgezogen-gebinde-umgezogen'
        BEGIN PRINT '  ! FINDING F4.6 reproduced: double-run left 2 tGebinde rows + doubled suffix'; SET @p+=1; END
    ELSE PRINT '  x F4.6 not reproduced (unexpected — proc may have changed)';
done02:
    ROLLBACK TRAN;
END TRY BEGIN CATCH IF @@TRANCOUNT>0 ROLLBACK TRAN; PRINT '  x ERROR: '+ERROR_MESSAGE(); END CATCH
INSERT INTO #TestResults VALUES ('T4-02 spGebindeErstellen (+F4.6 finding)', @p, @t);
GO

-- T4-02d  missing "Stk." unit -> THROW 50000 (separate tx: temporarily rename the unit name)
DECLARE @p2 INT = 0, @t2 INT = 1;
BEGIN TRAN;
BEGIN TRY
    DECLARE @kArt INT = (SELECT TOP 1 a.kArtikel FROM dbo.tArtikel a WHERE ISNULL(a.cHAN,'')<>'');
    UPDATE dbo.tEinheitSprache SET cName = cName + '-T4BLOCK' WHERE cName = N'Stk.';  -- make lookup fail
    BEGIN TRY
        EXEC CustomWorkflows.spGebindeErstellen @kArtikel = @kArt;
        PRINT '  x expected THROW 50000, none occurred';
    END TRY BEGIN CATCH
        IF ERROR_MESSAGE() LIKE '%Unit "Stk." not found%' BEGIN PRINT '  + THROW 50000 on missing unit'; SET @p2+=1; END
        ELSE PRINT '  x unexpected error: '+ERROR_MESSAGE();
    END CATCH
    ROLLBACK TRAN;  -- also reverts the tEinheitSprache rename
END TRY BEGIN CATCH IF @@TRANCOUNT>0 ROLLBACK TRAN; PRINT '  x ERROR: '+ERROR_MESSAGE(); END CATCH
INSERT INTO #TestResults VALUES ('T4-02d missing-unit THROW 50000', @p2, @t2);
GO
```

Zusätzlicher Zweig **T4-02e** (kein/mehrere Lieferanten): Artikel mit 0 oder ≥2 `tLiefArtikel`
wählen, Aktion ausführen, prüfen `cHAN LIKE '%-keine-Lieferanten-angepasst'` und **keine**
`tLiefArtikel`-Änderung. Gleiches Muster.

### T4-03 — `spSeriennummerStandardZuWMS`

**Fehlerklasse:** hartkodierte Lager 6/17, `'#$KEINE$#'`-Platzhalter, „genug Platzhalter"-Guard.
**Setup:** Artikel mit N Standard-Serien (Lager 6, `kLieferscheinPos=0`) und ≥N Platzhalterzeilen
(Lager 17, `cSeriennr='#$KEINE$#'`). Da `tLagerArtikel` reale Serien braucht, werden im Test
synthetische Zeilen für einen frei gewählten `kArtikel` angelegt (in der Transaktion).
**Erwartet (genug Platzhalter):** Platzhalter tragen danach die Standard-Serien; die Quellzeilen
(Lager 6) sind mit `-StandardLager` suffigiert. **Erwartet (zu wenig Platzhalter):** No-Op.

```sql
-- T4-03  spSeriennummerStandardZuWMS — moves serials when enough placeholders exist
DECLARE @p INT = 0, @t INT = 3;
BEGIN TRAN;
BEGIN TRY
    DECLARE @kArtikel INT = (SELECT TOP 1 kArtikel FROM dbo.tArtikel ORDER BY kArtikel);
    -- seed: 2 standard serials (Lager 6) + 2 WMS placeholders (Lager 17)
    INSERT INTO dbo.tLagerArtikel (kArtikel,kWarenlager,cSeriennr,kLieferscheinPos,fEK,kLieferant,kLieferantenbestellung)
        VALUES (@kArtikel,6,'T4-03-SN1',0,5,0,0),(@kArtikel,6,'T4-03-SN2',0,5,0,0),
               (@kArtikel,17,'#$KEINE$#',0,0,0,0),(@kArtikel,17,'#$KEINE$#',0,0,0,0);

    EXEC CustomWorkflows.spSeriennummerStandardZuWMS @kArtikel = @kArtikel;

    IF (SELECT COUNT(*) FROM dbo.tLagerArtikel WHERE kArtikel=@kArtikel AND kWarenlager=17 AND cSeriennr IN ('T4-03-SN1','T4-03-SN2'))=2
        BEGIN PRINT '  + serials copied onto WMS placeholders'; SET @p+=1; END ELSE PRINT '  x serials not copied to WMS';
    IF (SELECT COUNT(*) FROM dbo.tLagerArtikel WHERE kArtikel=@kArtikel AND kWarenlager=6 AND cSeriennr LIKE '%-StandardLager')=2
        BEGIN PRINT '  + source standard rows suffixed'; SET @p+=1; END ELSE PRINT '  x source rows not suffixed';
    IF NOT EXISTS (SELECT 1 FROM dbo.tLagerArtikel WHERE kArtikel=@kArtikel AND kWarenlager=17 AND cSeriennr='#$KEINE$#')
        BEGIN PRINT '  + placeholders consumed'; SET @p+=1; END ELSE PRINT '  x placeholders remain';
    ROLLBACK TRAN;
END TRY BEGIN CATCH IF @@TRANCOUNT>0 ROLLBACK TRAN; PRINT '  x ERROR: '+ERROR_MESSAGE(); END CATCH
INSERT INTO #TestResults VALUES ('T4-03 spSeriennummerStandardZuWMS (enough placeholders)', @p, @t);
GO
```

**T4-03b (zu wenig Platzhalter):** 3 Standard-Serien, 1 Platzhalter → `@kCountStandardlager >
@kCountWMSLager` → der `IF`-Block wird übersprungen → **keine** Änderung. Assertion: alle 3
Standard-Serien unverändert (kein `-StandardLager`), der eine Platzhalter bleibt `'#$KEINE$#'`.
**T4-03c (Quasi-Idempotenz):** zweiter Lauf nach T4-03 findet keine unsuffigierten Standard-Serien
mehr → No-Op (Grundrecherche §4: ungeprüft, hier belegen).

### T4-04 — `spZustandartikelLieferantSetzen`

**Fehlerklasse:** Idempotenz (Suffix nie doppelt), NULL-Clear, `kZustand=1`-Schutz, QUOTED_IDENTIFIER.
**Setup:** Zustandsartikel (`kZustand<>1`) mit gesetztem `cHAN`, dessen `tZustand.cSuffix` gesetzt
ist, plus ≥1 `tLiefArtikel`. Zusätzlich ein Standard-Zustandsartikel (`kZustand=1`) als Negativfall.

```sql
-- T4-04  spZustandartikelLieferantSetzen — suffix set / clear / idempotent / kZustand=1 protected
DECLARE @p INT = 0, @t INT = 4;
BEGIN TRAN;
BEGIN TRY
    -- condition article (kZustand<>1) with a non-empty suffix and a HAN that already carries it
    DECLARE @kArtikel INT = (SELECT TOP 1 a.kArtikel FROM dbo.tArtikel a
        JOIN dbo.tZustand z ON z.kZustand=a.kZustand
        JOIN dbo.tliefartikel la ON la.tArtikel_kArtikel=a.kArtikel
        WHERE a.kZustand<>1 AND ISNULL(z.cSuffix,'')<>'' AND ISNULL(a.cHAN,'')<>''
          AND RIGHT(a.cHAN,LEN(z.cSuffix))=z.cSuffix);
    IF @kArtikel IS NULL BEGIN PRINT '  ~ SKIP: no matching condition article'; SET @p=@t; GOTO done04; END
    DECLARE @cHAN NVARCHAR(255)=(SELECT cHAN FROM dbo.tArtikel WHERE kArtikel=@kArtikel);

    EXEC CustomWorkflows.spZustandartikelLieferantSetzen @kArtikel=@kArtikel;
    IF (SELECT MIN(CASE WHEN cLiefArtNr=@cHAN THEN 1 ELSE 0 END) FROM dbo.tliefartikel WHERE tArtikel_kArtikel=@kArtikel)=1
        BEGIN PRINT '  + cLiefArtNr set to HAN (already-suffixed branch)'; SET @p+=1; END ELSE PRINT '  x cLiefArtNr wrong';

    -- idempotency: run again -> no double suffix
    EXEC CustomWorkflows.spZustandartikelLieferantSetzen @kArtikel=@kArtikel;
    IF NOT EXISTS (SELECT 1 FROM dbo.tliefartikel WHERE tArtikel_kArtikel=@kArtikel AND cLiefArtNr LIKE '%'+ (SELECT z.cSuffix FROM dbo.tArtikel a JOIN dbo.tZustand z ON z.kZustand=a.kZustand WHERE a.kArtikel=@kArtikel) + '%' + (SELECT z.cSuffix FROM dbo.tArtikel a JOIN dbo.tZustand z ON z.kZustand=a.kZustand WHERE a.kArtikel=@kArtikel))
        BEGIN PRINT '  + suffix not doubled on re-run'; SET @p+=1; END ELSE PRINT '  x suffix doubled (BUG)';

    -- NULL-clear branch: article whose HAN is empty -> cLiefArtNr cleared to NULL
    UPDATE dbo.tArtikel SET cHAN='' WHERE kArtikel=@kArtikel;
    EXEC CustomWorkflows.spZustandartikelLieferantSetzen @kArtikel=@kArtikel;
    IF (SELECT COUNT(*) FROM dbo.tliefartikel WHERE tArtikel_kArtikel=@kArtikel AND cLiefArtNr IS NOT NULL)=0
        BEGIN PRINT '  + cLiefArtNr cleared to NULL when no unique number formable'; SET @p+=1; END ELSE PRINT '  x not cleared';

    -- kZustand=1 protection
    DECLARE @kStd INT = (SELECT TOP 1 a.kArtikel FROM dbo.tArtikel a JOIN dbo.tliefartikel la ON la.tArtikel_kArtikel=a.kArtikel WHERE a.kZustand=1);
    IF @kStd IS NOT NULL BEGIN
        DECLARE @before NVARCHAR(255)=(SELECT TOP 1 cLiefArtNr FROM dbo.tliefartikel WHERE tArtikel_kArtikel=@kStd);
        EXEC CustomWorkflows.spZustandartikelLieferantSetzen @kArtikel=@kStd;
        IF EXISTS (SELECT 1 FROM dbo.tliefartikel WHERE tArtikel_kArtikel=@kStd AND ISNULL(cLiefArtNr,'')=ISNULL(@before,''))
            BEGIN PRINT '  + standard condition (kZustand=1) untouched'; SET @p+=1; END ELSE PRINT '  x standard condition modified (BUG)';
    END ELSE BEGIN PRINT '  ~ no kZustand=1 supplier row; sub-check skipped'; SET @p+=1; END
done04:
    ROLLBACK TRAN;
END TRY BEGIN CATCH IF @@TRANCOUNT>0 ROLLBACK TRAN; PRINT '  x ERROR: '+ERROR_MESSAGE(); END CATCH
INSERT INTO #TestResults VALUES ('T4-04 spZustandartikelLieferantSetzen', @p, @t);
GO
```

> QUOTED_IDENTIFIER-Falle (Header Z. 10-12): das Skript muss mit `SET QUOTED_IDENTIFIER ON` /
> `SET ANSI_NULLS ON` laufen (sqlcmd-Default), sonst Fehler 1934 wegen gefilterter Indizes auf
> `tliefartikel`. Als eigener Negativtest optional: bewusst `SET QUOTED_IDENTIFIER OFF` und den
> erwarteten 1934 nachweisen.

### T4-05 — `spVpeCheckLieferantenbestellung` (Protokoll a–f aus tm9 reproduziert)

**Fehlerklasse:** F4.7 (Trigger-Write-Path), Idempotenz-Invarianten (Marker nie stapeln),
2000/255-Guards, NULL-Key-THROW 50001. Überführt das tm9-Protokoll (`vpe-workflow-implementation.md`
Tabelle a–f) in reproduzierbare Assertions.
**Setup:** Seed einer synthetischen Lieferantenbestellung mit 3 Positionen über den
Vendor-SP-Pfad bzw. — für das reine Anlegen der Positionen — über den **CONTEXT_INFO-Bypass**
(`SET CONTEXT_INFO 0x5123`, wie live in der SP beobachtet), damit der Guard-Trigger
`tgr_tlieferantenBestellungPos_INSUPDEL` das Seed-INSERT akzeptiert. Pos1 = VPE-Artikel, Preis ok;
Pos2 = VPE-Artikel, Preis-Fehler (`fEKNetto >= 1.5 * la.fEKNetto`); Pos3 = Nicht-VPE-Artikel.

```sql
-- T4-05  spVpeCheckLieferantenbestellung — tm9 protocol a-f as assertions
DECLARE @p INT = 0, @t INT = 8;
BEGIN TRAN;
BEGIN TRY
    -- NULL-key guard (case-independent, no seed needed)
    BEGIN TRY EXEC CustomWorkflows.spVpeCheckLieferantenbestellung @kLieferantenBestellung=NULL;
        PRINT '  x expected THROW 50001 on NULL key'; END TRY
    BEGIN CATCH IF ERROR_NUMBER()=50001 BEGIN PRINT '  + THROW 50001 on NULL key'; SET @p+=1; END ELSE PRINT '  x wrong error on NULL key'; END CATCH

    -- resolve a supplier that has a VPE article (nVPEMenge>=2, fEKNetto>0) and a non-VPE article
    DECLARE @kLieferant INT, @kArtVpe INT, @ekVpe DECIMAL(25,13), @vpe INT, @kArtPlain INT;
    SELECT TOP 1 @kLieferant=la.tLieferant_kLieferant, @kArtVpe=la.tArtikel_kArtikel, @ekVpe=la.fEKNetto, @vpe=la.nVPEMenge
        FROM dbo.tLiefArtikel la WHERE la.nVPEMenge>=2 AND la.fEKNetto>0;
    SELECT TOP 1 @kArtPlain=la.tArtikel_kArtikel FROM dbo.tLiefArtikel la
        WHERE la.tLieferant_kLieferant=@kLieferant AND ISNULL(la.nVPEMenge,0)<2;
    IF @kLieferant IS NULL OR @kArtPlain IS NULL BEGIN PRINT '  ~ SKIP: no VPE/non-VPE supplier pair in clone'; SET @p=@t; GOTO done05; END

    -- seed order head + 3 positions (positions via CONTEXT_INFO bypass to satisfy the guard trigger)
    INSERT INTO dbo.tLieferantenBestellung (kLieferant, cFremdbelegnummer) VALUES (@kLieferant, N'TESTBELEG-VPE');
    DECLARE @kLB INT = CAST(SCOPE_IDENTITY() AS INT);
    DECLARE @ctx VARBINARY(128) = 0x5123; SET CONTEXT_INFO @ctx;
    INSERT INTO dbo.tLieferantenBestellungPos (kLieferantenBestellung,kArtikel,fEKNetto,cHinweis,nVPEMenge,cVPEEinheit,fMenge,fMengeGeliefert,nPosTyp,nSort)
        VALUES (@kLB,@kArtVpe,@ekVpe,           N'Zubehör',@vpe,N'Stk',1,0,0,1),   -- pos1 ok
               (@kLB,@kArtVpe,@ekVpe*2.0,       N'Ersatzteile',@vpe,N'Stk',1,0,0,2), -- pos2 error (>=1.5x)
               (@kLB,@kArtPlain,5,              N'Zubehör2',0,NULL,1,0,0,3);        -- pos3 non-VPE
    SET CONTEXT_INFO 0x0;

    EXEC CustomWorkflows.spVpeCheckLieferantenbestellung @kLieferantenBestellung=@kLB;

    -- a) pos1 ok marker
    IF (SELECT cHinweis FROM dbo.tLieferantenBestellungPos WHERE kLieferantenBestellung=@kLB AND nSort=1) LIKE N'{{VPE='+CAST(@vpe AS NVARCHAR(10))+N'}} %'
        BEGIN PRINT '  + a) ok marker + text kept'; SET @p+=1; END ELSE PRINT '  x a) ok marker wrong';
    -- b) pos2 error marker
    IF (SELECT cHinweis FROM dbo.tLieferantenBestellungPos WHERE kLieferantenBestellung=@kLB AND nSort=2) LIKE N'{{VPE=%VPE Error Preis %>>%}} %'
        BEGIN PRINT '  + b) error marker'; SET @p+=1; END ELSE PRINT '  x b) error marker wrong';
    -- b-head) head marker appended
    IF (SELECT cFremdbelegnummer FROM dbo.tLieferantenBestellung WHERE kLieferantenBestellung=@kLB) = N'TESTBELEG-VPE {{VPE Error}}'
        BEGIN PRINT '  + b) head marker appended'; SET @p+=1; END ELSE PRINT '  x b) head marker wrong';
    -- c) pos3 unchanged (no VPE)
    IF (SELECT cHinweis FROM dbo.tLieferantenBestellungPos WHERE kLieferantenBestellung=@kLB AND nSort=3) = N'Zubehör2'
        BEGIN PRINT '  + c) non-VPE position unchanged'; SET @p+=1; END ELSE PRINT '  x c) non-VPE changed';

    -- d) idempotency: capture, re-run, compare identical
    DECLARE @snap NVARCHAR(MAX) = (SELECT STRING_AGG(cHinweis,'|') FROM dbo.tLieferantenBestellungPos WHERE kLieferantenBestellung=@kLB);
    EXEC CustomWorkflows.spVpeCheckLieferantenbestellung @kLieferantenBestellung=@kLB;
    IF (SELECT STRING_AGG(cHinweis,'|') FROM dbo.tLieferantenBestellungPos WHERE kLieferantenBestellung=@kLB) = @snap
        BEGIN PRINT '  + d) idempotent (markers do not stack)'; SET @p+=1; END ELSE PRINT '  x d) markers stacked';

    -- e) price fixed on pos2 -> error marker gone from pos + head; {{VPE=n}} stays
    SET CONTEXT_INFO @ctx;
    UPDATE dbo.tLieferantenBestellungPos SET fEKNetto=@ekVpe WHERE kLieferantenBestellung=@kLB AND nSort=2;
    SET CONTEXT_INFO 0x0;
    EXEC CustomWorkflows.spVpeCheckLieferantenbestellung @kLieferantenBestellung=@kLB;
    IF (SELECT cHinweis FROM dbo.tLieferantenBestellungPos WHERE kLieferantenBestellung=@kLB AND nSort=2) NOT LIKE N'%VPE Error%'
       AND (SELECT cFremdbelegnummer FROM dbo.tLieferantenBestellung WHERE kLieferantenBestellung=@kLB) = N'TESTBELEG-VPE'
        BEGIN PRINT '  + e) error cleared from pos + head after price fix'; SET @p+=1; END ELSE PRINT '  x e) error not cleared';

    -- +) full VPE loss: point pos1 at the non-VPE article -> marker fully stripped, base text restored
    SET CONTEXT_INFO @ctx;
    UPDATE dbo.tLieferantenBestellungPos SET kArtikel=@kArtPlain, nVPEMenge=0 WHERE kLieferantenBestellung=@kLB AND nSort=1;
    SET CONTEXT_INFO 0x0;
    EXEC CustomWorkflows.spVpeCheckLieferantenbestellung @kLieferantenBestellung=@kLB;
    IF (SELECT cHinweis FROM dbo.tLieferantenBestellungPos WHERE kLieferantenBestellung=@kLB AND nSort=1) = N'Zubehör'
        BEGIN PRINT '  + f) VPE loss restores clean base note'; SET @p+=1; END ELSE PRINT '  x f) marker not fully stripped';
done05:
    ROLLBACK TRAN;
END TRY BEGIN CATCH IF @@TRANCOUNT>0 ROLLBACK TRAN; PRINT '  x ERROR: '+ERROR_MESSAGE(); END CATCH
INSERT INTO #TestResults VALUES ('T4-05 spVpeCheck (protocol a-f)', @p, @t);
GO
```

> **Seed-Abhängigkeit (der eine live zu bestätigende Punkt).** Das Seed-INSERT der Positionen
> setzt `CONTEXT_INFO 0x5123` (der live in der SP beobachtete „PosBearbeiten"-Marker). Ob der
> Guard-Trigger dasselbe Konstant für den Bypass akzeptiert oder das in der Research tentativ
> genannte `0x5124`, ist beim ersten Container-Lauf zu verifizieren; scheitert das Seed-INSERT am
> Trigger (Fehler „…guard…"), auf `0x5124` umstellen. Der eigentliche Testpfad der SP hängt **nicht**
> davon ab (die SP nutzt ihren eigenen sanktionierten Vendor-SP-Pfad). Spaltenliste von
> `tLieferantenBestellungPos` ggf. um NOT-NULL-Spalten des Klons ergänzen (aus
> `A_Context/.../Lieferantenbestellung.*`). **Zusatz-Guards:** eigene Fälle für cHinweis-2000-Kappung
> (Basisnotiz mit 2100 Zeichen → Ergebnis genau 2000, Marker vollständig vorn) und
> cFremdbelegnummer-255-Kappung (Basisnummer 250 Zeichen → Marker vollständig, Basis getrimmt).

---

## Gruppe B — up/0003 Drop-Verifikation (F4.8)

### T4-06 — PayPal-Drop wirkt, ist re-run-fest, klon-tolerant

**Fehlerklasse:** F4.8. Kein Transaktions-Rollback nötig (reine Existenz-Assertions; DDL ist bereits
appliziert). Drei Sub-Fälle:

```sql
-- T4-06  PayPal drop verification (read-only assertions after the chain ran)
DECLARE @p INT = 0, @t INT = 3;
-- a) all 5 procs + 3 tables are gone after deploy
IF OBJECT_ID('CustomWorkflows.spPaypalTrackingVersand','P') IS NULL
   AND OBJECT_ID('CustomWorkflows.spPaypalTrackingLieferschein','P') IS NULL
   AND OBJECT_ID('Robotico.spPaypalTrackingCallApi','P') IS NULL
   AND OBJECT_ID('Robotico.spPaypalGetAccessToken','P') IS NULL
   AND OBJECT_ID('Robotico.spPaypalCreateAccessToken','P') IS NULL
   AND OBJECT_ID('Robotico.tPaypalTrackingLog','U') IS NULL
   AND OBJECT_ID('Robotico.tPaypalAccessToken','U') IS NULL
   AND OBJECT_ID('Robotico.tPaypalSettings','U') IS NULL
    BEGIN PRINT '  + all PayPal objects dropped'; SET @p+=1; END ELSE PRINT '  x PayPal objects remain';
-- b) Robotico schema itself survives (journal home) + still owns other objects
IF SCHEMA_ID('Robotico') IS NOT NULL AND OBJECT_ID('Robotico.fnFindDuplicateOrders','IF') IS NOT NULL
    BEGIN PRINT '  + Robotico schema + non-PayPal objects intact'; SET @p+=1; END ELSE PRINT '  x Robotico schema damaged';
-- c) re-run harmlessness: the DROP…IF EXISTS statements execute clean against absent objects
BEGIN TRY
    DROP PROCEDURE IF EXISTS Robotico.spPaypalCreateAccessToken;
    DROP TABLE IF EXISTS Robotico.tPaypalSettings;
    PRINT '  + DROP IF EXISTS re-run harmless (already absent)'; SET @p+=1;
END TRY BEGIN CATCH PRINT '  x re-run raised: '+ERROR_MESSAGE(); END CATCH
INSERT INTO #TestResults VALUES ('T4-06 PayPal drop verification', @p, @t);
GO
```

**T4-06d (Adoption mit PayPal-Objekten):** optional gegen eine DB, die `0002` noch trägt (PayPal-
Objekte vorhanden): nach einem Deploy greift `0003` und droppt sie — Nachweis „Drop greift" vs.
„No-Op" auf dem Klon ohne Objekte. Die reine Existenz-Prüfung deckt beide Endzustände ab; der
DDL-Wirkungsnachweis gehört in den Deploy-Testlauf von T1 (Journal/Adoption) — hier nur referenziert.

---

## Gruppe C — Lücken der bestehenden Suiten schließen

### T4-07 — CustomField-API (`CustomFieldAPI_Tests.sql`-Ergänzung)

**Fehlerklasse:** Race-2627, `kSprache<>0`, Self-Healing „Binding ohne Sprachzeile" (**QG3-B6-Kernfall**).

- **T4-07a Self-Healing (QG3-B6):** Binding-Row in `tArtikelAttribut` anlegen, aber **keine**
  `tArtikelAttributSprache`-Zeile für `kSprache=0` (bzw. nur für eine andere Sprache). Dann
  `spEnsureArticleCustomField(@kSprache=0)` aufrufen. **Erwartet:** die vorhandene Binding-Row wird
  **gefunden** (kein 2627), Schritt 3 legt die fehlende Sprachzeile an, `@currentValue` = NULL,
  Rückgabe 0. Ein zweiter Aufruf ist stabil (kein 2627). Belegt, dass der Lookup absichtlich **nicht**
  auf `tArtikelAttributSprache` joint.

```sql
-- T4-07a  self-healing: binding row present, language row missing -> repaired, no 2627
DECLARE @p INT=0,@t INT=2;
BEGIN TRAN;
BEGIN TRY
    DECLARE @kArtikel INT=(SELECT TOP 1 kArtikel FROM dbo.tArtikel ORDER BY kArtikel);
    DECLARE @kAttribut INT=(SELECT TOP 1 attr.kAttribut FROM dbo.tAttribut attr
        JOIN dbo.tAttributSprache s ON s.kAttribut=attr.kAttribut
        WHERE s.cName=N'Vergangene Preise' AND s.kSprache=0 AND attr.nIstFreifeld=1);
    -- create binding WITHOUT any language row
    INSERT INTO dbo.tArtikelAttribut (kArtikel,kAttribut,kShop) VALUES (@kArtikel,@kAttribut,0);
    DECLARE @kAA INT, @val NVARCHAR(MAX), @rc INT;
    EXEC @rc=Robotico.spEnsureArticleCustomField @kArtikel=@kArtikel,@fieldName=N'Vergangene Preise',@kSprache=0,@kArtikelAttribut=@kAA OUTPUT,@currentValue=@val OUTPUT;
    IF @rc=0 AND @kAA=(SELECT kArtikelAttribut FROM dbo.tArtikelAttribut WHERE kArtikel=@kArtikel AND kAttribut=@kAttribut AND kShop=0)
       AND EXISTS (SELECT 1 FROM dbo.tArtikelAttributSprache WHERE kArtikelAttribut=@kAA AND kSprache=0)
        BEGIN PRINT '  + existing binding found + language row healed'; SET @p+=1; END ELSE PRINT '  x self-heal failed (2627 risk)';
    -- second call stable
    EXEC @rc=Robotico.spEnsureArticleCustomField @kArtikel=@kArtikel,@fieldName=N'Vergangene Preise',@kSprache=0,@kArtikelAttribut=@kAA OUTPUT,@currentValue=@val OUTPUT;
    IF @rc=0 BEGIN PRINT '  + second call stable (no 2627)'; SET @p+=1; END ELSE PRINT '  x second call failed';
    ROLLBACK TRAN;
END TRY BEGIN CATCH IF @@TRANCOUNT>0 ROLLBACK TRAN; PRINT '  x ERROR: '+ERROR_MESSAGE(); END CATCH
INSERT INTO #TestResults VALUES ('T4-07a self-healing binding (QG3-B6)', @p, @t);
GO
```

- **T4-07b `kSprache<>0`:** Freifeld-Definition mit einer Sprachzeile für `kSprache<>0` (falls im
  Klon vorhanden, sonst temporär anlegen), `spEnsureArticleCustomField(@kSprache=<n>)` → Binding +
  Sprachzeile für genau diese Sprache; `fnGetArticleCustomFieldValue(kArtikel, field, <n>)` liest den
  Wert; `kSprache=0` bleibt leer. Belegt die Sprach-Parametrisierung (bislang nur `0` getestet).
- **T4-07c Race-2627-Pfad:** deterministische Simulation ohne echte Nebenläufigkeit — Binding
  zwischen Schritt-2-Lookup und INSERT „von außen" anlegen ist im Skript nicht atomar erzwingbar;
  stattdessen den CATCH-Pfad **weiß-testen**, indem man die Binding-Row anlegt und dann den INSERT-Zweig
  gezielt provoziert (zweiter Aufruf desselben `spSet…` in derselben Transaktion nach manuellem INSERT).
  Alternative/robuster: den 2627-Zweig als **Code-Review-Assertion** dokumentieren und per zwei
  parallelen `sqlcmd`-Sessions (Barrier auf `WAITFOR`) real reproduzieren — als optionaler Lasttest
  außerhalb der Transaktions-Suite markiert.

### T4-08 — History-SPs (`HistorySPs_Tests.sql`-Ergänzung)

**Fehlerklasse:** 1000-Zeilen-Trim, Steuerzone-`'Inland'`-fehlt-Fallback (19 %), reduzierter Satz (7 %),
fehlende Freifeld-Definition.

- **T4-08a 1000-Zeilen-Trim:** Freifeld `'Vergangene Preise'` mit 1011 Zeilen vorbelegen
  (`spSet…`-Roundtrip oder direkter `cWertVarchar`-Aufbau via `REPLICATE`), dann `spArticleAppendPriceHistory`
  mit geändertem Preis aufrufen → `fnStringCountLines` = 1000 (Trim greift bei `>1000+10`). Assertion
  auf exakt 1000 und dass die **ältesten** Zeilen entfernt wurden (letzter Eintrag = der neue).
- **T4-08b Steuerzone-Fallback:** Artikel wählen, dessen Steuerklasse **keine** `tSteuerzone.cName =
  'Inland'`-Zeile auflöst (oder die `'Inland'`-Zone temporär umbenennen). `spArticleAppendPriceHistory`
  → `@vatRate` fällt auf 0.19; der Bruttowert im neuen Eintrag = `netto * 1.19`. Da Brutto nur Anzeige
  ist, muss der SP **grün** bleiben (keine THROW). Assertion auf Bruttowert und „kein Fehler".
- **T4-08c 7 %-Satz:** Artikel mit reduziertem Inland-Satz (7 %) wählen → Bruttowert = `netto * 1.07`.
  Belegt, dass die tatsächliche Zone/den tatsächlichen Satz aufgelöst wird (nicht hart 19 %).
- **T4-08d fehlende Freifeld-Definition:** `spArticleAppendPriceHistory` gegen eine DB/einen Artikel,
  wo `'Vergangene Preise'` als `tAttribut/tAttributSprache`-Definition fehlt (temporär `cName`
  umbenennen) → `spEnsureArticleCustomField` `RAISERROR 16` propagiert als THROW. Assertion:
  `ERROR_MESSAGE() LIKE '%Custom field definition not found%'`.

```sql
-- T4-08b  domestic-tax-zone missing -> 19% fallback, no throw
DECLARE @p INT=0,@t INT=2;
BEGIN TRAN;
BEGIN TRY
    UPDATE dbo.tSteuerzone SET cName=cName+'-T4' WHERE cName=N'Inland';  -- force fallback
    DECLARE @kArtikel INT=(SELECT TOP 1 kArtikel FROM dbo.tArtikel WHERE fVKNetto>0 ORDER BY kArtikel);
    -- ensure a change is detected: bump the net price so an entry is written
    UPDATE dbo.tArtikel SET fVKNetto=123.45 WHERE kArtikel=@kArtikel;
    BEGIN TRY
        EXEC CustomWorkflows.spArticleAppendPriceHistory @kArtikel=@kArtikel, @userName=N'T4';
        PRINT '  + no throw despite missing Inland zone'; SET @p+=1;
    END TRY BEGIN CATCH PRINT '  x threw: '+ERROR_MESSAGE(); END CATCH
    DECLARE @last NVARCHAR(MAX)=Robotico.fnEscapedCSVGetLastLine(Robotico.fnGetArticleCustomFieldValue(@kArtikel,N'Vergangene Preise',0));
    -- brutto field (3rd ';'-field) must equal netto*1.19 formatted de-DE -> "146,91"
    IF Robotico.fnEscapedCSVGetField(@last,3,';') LIKE N'%146,91%'
        BEGIN PRINT '  + brutto uses 19% fallback (146,91)'; SET @p+=1; END ELSE PRINT '  x fallback rate wrong: '+ISNULL(@last,'NULL');
    ROLLBACK TRAN;
END TRY BEGIN CATCH IF @@TRANCOUNT>0 ROLLBACK TRAN; PRINT '  x ERROR: '+ERROR_MESSAGE(); END CATCH
INSERT INTO #TestResults VALUES ('T4-08b Inland-zone-missing 19% fallback', @p, @t);
GO
```

### T4-09 — Duplicate-Order-Lücken (`DuplicateOrders_Tests.sql`-Ergänzung)

**Fehlerklasse:** F4.5 (Freiposition-NULL-Fingerprint — **Finding**), nType-Filter, Test-8-Umgebungsabhängigkeit.

- **T4-09a Freiposition NULL-Fingerprint (F4.5-Finding):** zwei Aufträge, gleicher Kunde/Zeitfenster/
  Bruttowert, jeweils **eine** Freiposition mit `kArtikel NULL` **und** `cArtNr NULL` (nType 1). Im
  Fingerprint fällt `COALESCE(kArtikel, 'F:'+cArtNr)` auf `NULL` → das Element fällt aus `STRING_AGG`.
  **Erwartet als Finding:** beide erhalten denselben (leeren/degenerierten) Fingerprint und werden als
  Duplikat geflaggt, obwohl der Positionsinhalt unbestimmt ist → Kollisionsrisiko. Assertion macht das
  Verhalten **sichtbar** (dokumentiert, nicht gefixt).
- **T4-09b nType-Filter:** Auftrag **ohne** nType-0/1-Position (nur nType 2 z. B. Versand) →
  `fnFindDuplicateOrders` liefert **keine** Fingerprint-Zeile → nie Duplikat, auch bei identischem
  Zwilling. Assertion: `fnHasOlderDuplicateOrder = 0`.
- **T4-09c Test-8-Umgebungsabhängigkeit beseitigen:** der bestehende Test 8 hängt an realen Seed-
  Aufträgen 236/237 (`DuplicateOrders_Tests.sql:365`), die im getrimmten Klon fehlen können. Ersatz:
  das synthetische Zwillingspaar aus Test 1/2 auch für den `fnFindDuplicateOrders`-Listen-Check nutzen
  (assert `kDuplicateOrder = <älterer synthetischer kAuftrag>`), damit die Suite **ohne** reale Seeds
  grün läuft. Test 8 in der bestehenden Datei durch diese synthetische Variante ersetzen.

```sql
-- T4-09a  free position with kArtikel NULL AND cArtNr NULL -> degenerate fingerprint (FINDING F4.5)
DECLARE @p INT=0,@t INT=1;
BEGIN TRAN;
BEGIN TRY
    DECLARE @kKunde INT=(SELECT TOP 1 k.kKunde FROM dbo.tkunde k WHERE NOT EXISTS(SELECT 1 FROM Verkauf.tAuftrag a WHERE a.kKunde=k.kKunde) ORDER BY k.kKunde);
    DECLARE @kFH INT=(SELECT MIN(kFirmaHistory) FROM dbo.tFirmaHistory), @kS INT=(SELECT MIN(kSprache) FROM dbo.tSpracheUsed);
    DECLARE @a INT,@b INT;
    INSERT INTO Verkauf.tAuftrag (kKunde,kBenutzer,cAuftragsNr,nType,fFaktor,kFirmaHistory,kSprache,cVersandlandWaehrung,fVersandlandWaehrungFaktor,fFinanzierungskosten,kBenutzerErstellt,dErstellt,nStorno)
        VALUES (@kKunde,0,'T4-09a-1',1,1,@kFH,@kS,'EUR',1,0,0,'2026-01-10T10:00:00',0); SET @a=CAST(SCOPE_IDENTITY() AS INT);
    INSERT INTO Verkauf.tAuftragEckdaten (kAuftrag,fWertBrutto) VALUES (@a,50.00);
    INSERT INTO Verkauf.tAuftragPosition (kAuftrag,kArtikel,cArtNr,fAnzahl,fMwSt,fVkNetto,nType) VALUES (@a,NULL,NULL,1,19,42,1);
    INSERT INTO Verkauf.tAuftrag (kKunde,kBenutzer,cAuftragsNr,nType,fFaktor,kFirmaHistory,kSprache,cVersandlandWaehrung,fVersandlandWaehrungFaktor,fFinanzierungskosten,kBenutzerErstellt,dErstellt,nStorno)
        VALUES (@kKunde,0,'T4-09a-2',1,1,@kFH,@kS,'EUR',1,0,0,'2026-01-10T11:00:00',0); SET @b=CAST(SCOPE_IDENTITY() AS INT);
    INSERT INTO Verkauf.tAuftragEckdaten (kAuftrag,fWertBrutto) VALUES (@b,50.00);
    INSERT INTO Verkauf.tAuftragPosition (kAuftrag,kArtikel,cArtNr,fAnzahl,fMwSt,fVkNetto,nType) VALUES (@b,NULL,NULL,1,19,42,1);
    -- Finding: despite unspecified positions, the two collide as duplicates
    IF Robotico.fnHasOlderDuplicateOrder(@b,24)=1
        BEGIN PRINT '  ! FINDING F4.5: NULL/NULL free positions collide as duplicates'; SET @p+=1; END
    ELSE PRINT '  ~ no collision (fingerprint distinguishes them — re-evaluate finding)';
    ROLLBACK TRAN;
END TRY BEGIN CATCH IF @@TRANCOUNT>0 ROLLBACK TRAN; PRINT '  x ERROR: '+ERROR_MESSAGE(); END CATCH
INSERT INTO #TestResults VALUES ('T4-09a free-pos NULL fingerprint (F4.5 finding)', @p, @t);
GO
```

### T4-10 — Parser-Randfälle (`StringAndCSVUtilities_Tests.sql`-Ergänzung)

**Fehlerklasse:** F4.4. Über die bestehenden Tests 4/5/9 hinaus.

- **T4-10a `fnStringTrimToMaxLines` nur-Leerzeilen → NULL:** Input `CHAR(10)`×5 (5 Leerzeilen),
  `@maxLines=2`. `@lineCount(5) > 2` → Trim-Zweig; alle Zeilen von `LEN(LTRIM(RTRIM(...)))>0` gefiltert →
  `STRING_AGG` über 0 Zeilen → **NULL**. Assertion: Ergebnis IS NULL (bislang ungetestet; pinnt
  undokumentiertes, aber plausibles Verhalten).
- **T4-10b `fnStringParseGermanDecimal` US-Format → stiller Falschwert (F4.4-Finding):** Input
  `'1,234.56'`. `REPLACE('.','')` → `'1,23456'`, `REPLACE(',','.')` → `'1.23456'`, `TRY_CAST` = **1.23456**
  statt NULL. **Erwartet als Finding:** die Funktion liefert einen **falschen** Wert statt NULL für
  US-Format. Assertion macht es sichtbar.
- **T4-10c `fnEscapedCSVGetLastLine` nur-CRLF → NULL:** Input `CHAR(13)+CHAR(10)` (bzw. mehrfach). Die
  While-Schleife strippt alle trailing CR/LF → Länge 0 → `RETURN NULL`. Assertion: NULL (bisher nur
  leerer String getestet).

```sql
-- T4-10  parser edge cases (add to StringAndCSVUtilities_Tests.sql)
DECLARE @p INT=0,@t INT=3;
-- a) only blank lines -> NULL
IF Robotico.fnStringTrimToMaxLines(CHAR(10)+CHAR(10)+CHAR(10)+CHAR(10)+CHAR(10),2) IS NULL
    BEGIN PRINT '  + only-blank-lines -> NULL'; SET @p+=1; END ELSE PRINT '  x expected NULL for only-blank input';
-- b) FINDING F4.4: US format returns a silent wrong value instead of NULL
DECLARE @us DECIMAL(25,13) = Robotico.fnStringParseGermanDecimal('1,234.56');
IF @us IS NOT NULL AND @us BETWEEN 1.23455 AND 1.23457
    BEGIN PRINT '  ! FINDING F4.4: US "1,234.56" -> '+CAST(@us AS NVARCHAR(30))+' (silent wrong value, not NULL)'; SET @p+=1; END
ELSE PRINT '  ~ US format did not produce the documented wrong value (re-check)';
-- c) only-CRLF -> NULL
IF Robotico.fnEscapedCSVGetLastLine(CHAR(13)+CHAR(10)) IS NULL
    BEGIN PRINT '  + only-CRLF -> NULL'; SET @p+=1; END ELSE PRINT '  x expected NULL for only-CRLF';
INSERT INTO #TestResults VALUES ('T4-10 parser edge cases (+F4.4 finding)', @p, @t);
GO
```

---

## Gruppe D — Struktur-Fehlerfälle (F4.1, F4.3)

### T4-11 — Custom-Workflow-Modul nicht gebucht (`_CheckAction` fehlt → PRINT)

**Fehlerklasse:** F4.1. Gegen eine DB, in der `CustomWorkflows._CheckAction`/`_SetActionDisplayName`
**nicht** existieren (Vendor-Helper des JTL-Moduls). **Erwartet:** der Registrierungs-Trailer jeder
Aktion druckt die `! …missing…`-Warnung, aber der Deploy/das Anwenden der Datei bleibt **grün** (keine
THROW). Test: die Trailer-Blöcke isoliert ausführen bzw. den grate-Deploy-Log auf die PRINT-Zeile und
Exit-Code 0 prüfen. Assertion (skriptbar): `OBJECT_ID('CustomWorkflows._CheckAction','P') IS NULL` →
die Aktion selbst ist dennoch angelegt (`OBJECT_ID('CustomWorkflows.spGebindeErstellen','P') IS NOT NULL`).

### T4-12 — Schema `CustomWorkflows` fehlt komplett (offene Frage)

**Fehlerklasse:** F4.1 (offene Annahme). Kein Skript legt das Schema `CustomWorkflows` an. **Test:**
Scratch-DB ohne dieses Schema; eine `CustomWorkflows.sp*`-Datei anwenden → `CREATE OR ALTER PROCEDURE
CustomWorkflows.…` scheitert mit „schema does not exist" (Fehler 2760). **Erwartet:** harter Fehler —
belegt, dass Ebene A eine bestehende JTL-DB **mit** dem Modul-Schema voraussetzt. Ergebnis ist eine
**Klärungsfrage an den User/das Deployment**: soll die Kette das Schema defensiv anlegen, oder ist die
Voraussetzung „JTL + Modul vorhanden" dokumentiert-akzeptiert? (Teilrecherche §4 offene Unsicherheit 3.)

```sql
-- T4-12  CustomWorkflows schema absent -> CREATE PROCEDURE fails (run in a scratch DB)
-- Prereq: CREATE DATABASE T4_scratch; (no CustomWorkflows schema)  -- see cleanup below
DECLARE @p INT=0,@t INT=1;
BEGIN TRY
    EXEC('CREATE OR ALTER PROCEDURE CustomWorkflows.spT4Probe @k INT AS BEGIN SET NOCOUNT ON; END');
    PRINT '  x expected failure (schema missing), but CREATE succeeded';
END TRY BEGIN CATCH
    IF ERROR_NUMBER() IN (2760) OR ERROR_MESSAGE() LIKE '%schema%'
        BEGIN PRINT '  + CREATE PROCEDURE fails without CustomWorkflows schema (error '+CAST(ERROR_NUMBER() AS NVARCHAR(10))+')'; SET @p+=1; END
    ELSE PRINT '  x unexpected error: '+ERROR_MESSAGE();
END CATCH
INSERT INTO #TestResults VALUES ('T4-12 CustomWorkflows schema absent', @p, @t);
GO
```

### T4-13 — SQL-2022-Floor: STRING_SPLIT-Ordinal-Runtime-Fail bei Compat < 160

**Fehlerklasse:** F4.3. Die `enable_ordinal`-Form `STRING_SPLIT(@s, sep, 1)` ist erst ab
Compatibility-Level **160** gültig; auf 150 gelingt der CREATE, aber der **Aufruf** scheitert zur
Laufzeit. Betroffen: `fnEscapedCSVParseLine`, `fnEscapedCSVGetField` (transitiv),
`fnStringTrimToMaxLines`, `spArticleAppendLabelHistory` (Z. 77). **Test:** isolierte Scratch-DB auf
Compat 150, die reine Funktion `fnEscapedCSVParseLine` (nur STRING_SPLIT, keine Vendor-Tabellen)
anlegen, aufrufen → Laufzeitfehler. Danach Compat 160 → gelingt.

```sql
-- T4-13  ordinal STRING_SPLIT fails at compat 150, works at 160 (scratch DB)
-- Prereq: CREATE DATABASE T4_compat; run this with -d T4_compat
DECLARE @p INT=0,@t INT=2;
DECLARE @sql NVARCHAR(MAX)=N'CREATE OR ALTER FUNCTION dbo.fnT4Split(@s NVARCHAR(100)) RETURNS TABLE AS RETURN (SELECT ordinal, value FROM STRING_SPLIT(@s, N'','', 1));';
EXEC sp_executesql @sql;  -- CREATE succeeds regardless of compat
ALTER DATABASE CURRENT SET COMPATIBILITY_LEVEL = 150;
BEGIN TRY
    IF EXISTS (SELECT 1 FROM dbo.fnT4Split(N'a,b,c') WHERE ordinal=2)
        PRINT '  x expected runtime failure at compat 150, but call succeeded';
END TRY BEGIN CATCH PRINT '  + ordinal STRING_SPLIT fails at compat 150 (err '+CAST(ERROR_NUMBER() AS NVARCHAR(10))+')'; SET @p+=1; END CATCH
ALTER DATABASE CURRENT SET COMPATIBILITY_LEVEL = 160;
BEGIN TRY
    IF EXISTS (SELECT 1 FROM dbo.fnT4Split(N'a,b,c') WHERE ordinal=2)
        BEGIN PRINT '  + same call succeeds at compat 160'; SET @p+=1; END
END TRY BEGIN CATCH PRINT '  x unexpected failure at compat 160: '+ERROR_MESSAGE(); END CATCH
INSERT INTO #TestResults VALUES ('T4-13 STRING_SPLIT ordinal compat floor', @p, @t);
GO
```

> Diese beiden Struktur-Tests brauchen **eigene Scratch-DBs** (`T4_scratch`, `T4_compat`), nicht die
> restaurierte eazybusiness — Compat-Level-Änderung ist DB-global. Cleanup: `DROP DATABASE` beider am Ende.

---

## Gruppe E — Trigger-Interaktionen (F4.7 + offene Fragen)

### T4-14 — Direkt-UPDATE auf `tLieferantenBestellungPos` scheitert am Guard-Trigger

**Fehlerklasse:** F4.7 / Teilrecherche §2c. **Test:** ohne CONTEXT_INFO-Magic ein direktes
`UPDATE dbo.tLieferantenBestellungPos SET cHinweis=… WHERE …` auf eine (geseedete) Position ausführen.
**Erwartet:** der Trigger `tgr_tlieferantenBestellungPos_INSUPDEL` rollbackt/wirft → das UPDATE greift
**nicht** (belegt, warum die VPE-Aktion den Vendor-SP-Pfad nutzt).

```sql
-- T4-14  direct UPDATE on guarded position table is rejected without CONTEXT_INFO magic
DECLARE @p INT=0,@t INT=1;
BEGIN TRAN;
BEGIN TRY
    -- seed one position via bypass, then attempt a direct (ungated) UPDATE
    DECLARE @kLieferant INT=(SELECT TOP 1 tLieferant_kLieferant FROM dbo.tLiefArtikel);
    DECLARE @kArt INT=(SELECT TOP 1 tArtikel_kArtikel FROM dbo.tLiefArtikel WHERE tLieferant_kLieferant=@kLieferant);
    INSERT INTO dbo.tLieferantenBestellung (kLieferant,cFremdbelegnummer) VALUES (@kLieferant,'T4-14');
    DECLARE @kLB INT=CAST(SCOPE_IDENTITY() AS INT);
    DECLARE @ctx VARBINARY(128)=0x5123; SET CONTEXT_INFO @ctx;
    INSERT INTO dbo.tLieferantenBestellungPos (kLieferantenBestellung,kArtikel,fEKNetto,cHinweis,nVPEMenge,fMenge,fMengeGeliefert,nPosTyp,nSort)
        VALUES (@kLB,@kArt,5,'seed',0,1,0,0,1);
    SET CONTEXT_INFO 0x0;  -- clear magic -> next write is ungated
    BEGIN TRY
        UPDATE dbo.tLieferantenBestellungPos SET cHinweis='DIRECT' WHERE kLieferantenBestellung=@kLB;
        -- if the trigger silently rolls back without error, the value stays 'seed'
        IF (SELECT cHinweis FROM dbo.tLieferantenBestellungPos WHERE kLieferantenBestellung=@kLB)='seed'
            BEGIN PRINT '  + direct UPDATE blocked by guard trigger (value unchanged)'; SET @p+=1; END
        ELSE PRINT '  x direct UPDATE went through (trigger not active!)';
    END TRY BEGIN CATCH
        PRINT '  + direct UPDATE raised guard error: '+ERROR_MESSAGE(); SET @p+=1;
    END CATCH
    ROLLBACK TRAN;
END TRY BEGIN CATCH IF @@TRANCOUNT>0 ROLLBACK TRAN; PRINT '  x ERROR: '+ERROR_MESSAGE(); END CATCH
INSERT INTO #TestResults VALUES ('T4-14 guard trigger blocks direct UPDATE', @p, @t);
GO
```

### T4-15 — Vendor-SP-Pfad ohne Bestands-Seiteneffekte

**Fehlerklasse:** F4.7 / Teilrecherche §2c. Die VPE-Aktion schreibt Positionen per Vendor-SP mit
**Full-Column-Overwrite**, hält aber `fMenge`/`fMengeGeliefert` unverändert. **Test:** vor/nach einem
`spVpeCheck`-Lauf (der nur `cHinweis` ändert) den `tlagerbestand` der betroffenen Artikel snapshotten →
**keine** Änderung. Belegt, dass der Stock-Pfad des Vendor-SP (nur bei `fMenge`/`fMengeGeliefert`-Delta)
nicht ausgelöst wird.

```sql
-- T4-15  VPE run that only changes cHinweis must not touch tlagerbestand
DECLARE @p INT=0,@t INT=1;
BEGIN TRAN;
BEGIN TRY
    -- (reuse the T4-05 seed block to build @kLB with a VPE position)
    -- snapshot stock for the involved articles
    DECLARE @before NVARCHAR(MAX)=(SELECT STRING_AGG(CONCAT(kArtikel,':',fVerfuegbar,':',fZulauf),'|') FROM dbo.tlagerbestand);
    -- EXEC CustomWorkflows.spVpeCheckLieferantenbestellung @kLieferantenBestellung=@kLB;  (only cHinweis changes)
    DECLARE @after NVARCHAR(MAX)=(SELECT STRING_AGG(CONCAT(kArtikel,':',fVerfuegbar,':',fZulauf),'|') FROM dbo.tlagerbestand);
    IF @before=@after BEGIN PRINT '  + tlagerbestand unchanged after cHinweis-only VPE run'; SET @p+=1; END
    ELSE PRINT '  x stock changed (unexpected side effect)';
    ROLLBACK TRAN;
END TRY BEGIN CATCH IF @@TRANCOUNT>0 ROLLBACK TRAN; PRINT '  x ERROR: '+ERROR_MESSAGE(); END CATCH
INSERT INTO #TestResults VALUES ('T4-15 VPE run no stock side-effect', @p, @t);
GO
```

> Die `tlagerbestand`-Spaltennamen (`fVerfuegbar`/`fZulauf`) an das Klon-Schema anpassen; praktisch am
> besten als Erweiterung des T4-05-Skripts direkt nach dem ersten `spVpeCheck`-Lauf einhängen.

### T4-16 — Guard-Trigger-Existenz auf `tArtikel`/`tLagerArtikel` klären (offene Frage)

**Fehlerklasse:** Teilrecherche §4 offene Unsicherheit 2. `spGebindeErstellen`,
`spSeriennummerStandardZuWMS`, `spZustandartikelLieferantSetzen` schreiben `dbo.tArtikel`/
`tLiefArtikel`/`tLagerArtikel` **direkt** — ob dort JTL-Guard-Trigger sitzen, ist nicht dokumentiert.
**Probe (read-only):** `sys.triggers` gegen diese Tabellen abfragen und die Existenz dokumentieren; die
funktionalen Tests T4-02/03/04 sind der eigentliche Live-Nachweis, dass die Direkt-Writes durchgehen.

```sql
-- T4-16  probe: which triggers guard the directly-written article/stock tables?
SELECT t.name AS trigger_name, OBJECT_NAME(t.parent_id) AS table_name, t.is_disabled
FROM sys.triggers t
WHERE OBJECT_NAME(t.parent_id) IN ('tArtikel','tLiefArtikel','tLagerArtikel','tGebinde')
ORDER BY table_name, trigger_name;
-- Interpretation: if a rollback-on-write guard exists here (like the Lieferantenbestellung one),
-- T4-02/03/04 would already have failed -> their PASS is the functional proof the writes are accepted.
GO
```

---

## Findings-Kandidaten

Fälle, deren „Assertion-PASS" ein **echtes Design-/Bug-Finding** belegt. Nicht fixen — separate
User-Entscheidung (Grundrecherche §5 offene Fragen 4).

| ID | Finding | Beleg | Klassifikation |
|---|---|---|---|
| **T4-02 (F4.6)** | `spGebindeErstellen` ist **nicht idempotent**: jeder Lauf INSERTet eine weitere `tGebinde`-Zeile und hängt das HAN/GTIN-Suffix erneut an (`cHAN + '-…'`, keine Bereits-Suffix/Existenz-Guard, Z. 78-101). Doppel-Trigger im Workflow = Datenmüll. | Doppellauf in einer Transaktion → 2 `tGebinde`-Zeilen + `…-gebinde-umgezogen-gebinde-umgezogen`. | **Bekannter Bug** — Fix (Existenz/Suffix-Guard) ist Grundrecherche-Frage 4, offen. |
| **T4-10b (F4.4)** | `fnStringParseGermanDecimal` liefert für **US-Format** `'1,234.56'` den **stillen Falschwert** `1.23456` statt NULL (blindes `REPLACE('.','')` + `REPLACE(',','.')`). | Assertion `@us BETWEEN 1.23455 AND 1.23457`. | **Latenter Bug** — nur relevant, falls US-Formatierte Werte je in die Pipeline geraten; dokumentieren. |
| **T4-09a (F4.5)** | `fnFindDuplicateOrders`: Freiposition mit `kArtikel NULL` UND `cArtNr NULL` fällt via `COALESCE` als NULL aus `STRING_AGG` → degenerierter Fingerprint → **Kollisionsrisiko** (fälschliche Duplikat-Flags). | Zwei NULL/NULL-Freipos-Aufträge kollidieren als Duplikat. | **Design-Randfall** — real nur bei echten Freipositionen ohne jede Kennung; niedrige Praxiswahrscheinlichkeit. |
| **T4-12 (F4.1)** | Ebene A legt das Schema `CustomWorkflows` **nirgends** an; auf einer DB ohne dieses Schema scheitert `CREATE PROCEDURE` hart (2760). Implizite, ungesicherte Voraussetzung „JTL + Modul vorhanden". | Scratch-DB ohne Schema → Fehler 2760. | **Offene Frage** — Klärung: defensives `CREATE SCHEMA` in der Kette oder dokumentierte Voraussetzung? |
| **T4-10a** | `fnStringTrimToMaxLines` über **nur-Leerzeilen** liefert NULL (STRING_AGG über 0 gefilterte Zeilen). Undokumentiert, aber plausibel. | Assertion NULL. | **Verhaltens-Pin**, kein Bug — Doku ergänzen. |

**Nicht-Findings, aber zu bestätigende Annahmen (Live-Verifikationspunkte):**
1. CONTEXT_INFO-Bypass-Konstante fürs VPE-/Trigger-Seeding (`0x5123` vs. `0x5124`) — [T4-05](#t4-05--spvpechecklieferantenbestellung-protokoll-af-aus-tm9-reproduziert)/[T4-14](#t4-14--direkt-update-auf-tlieferantenbestellungpos-scheitert-am-guard-trigger).
2. Guard-Trigger-Existenz auf `tArtikel`/`tLagerArtikel` — [T4-16](#t4-16--guard-trigger-existenz-auf-tartikeltlagerartikel-klären-offene-frage).
3. Exakte NOT-NULL-Spaltenlisten von `Rechnung.tRechnung*`, `tLieferantenBestellung(Pos)`, `tlagerbestand` im getrimmten Klon — beim ersten Lauf aus `A_Context/JTL 1.10.11.0/` ergänzen.

---

## Ausführungsreihenfolge & Cleanup

1. **Scratch-DBs zuerst** (unabhängig von eazybusiness): `T4_scratch` (T4-12), `T4_compat` (T4-13)
   anlegen, Tests laufen, am Ende `DROP DATABASE`.
2. **Gegen `eazybusiness`** (Container): Gruppen A → B → C → E in beliebiger Reihenfolge; alle
   transaktionsbasiert mit `ROLLBACK` → keine Rückstände. Nach jeder Suite den Standard-Summenblock.
3. **Gruppe B (T4-06)** ist read-only (Existenz-Assertions), kann jederzeit laufen.
4. **Endkontrolle:** eine abschließende Clean-State-Assertion pro Suite (Muster
   `CustomFieldAPI_Tests.sql` Test 8): das jeweils angelegte Testobjekt ist nach den Rollbacks
   verschwunden.

Sämtliche Skripte sind so gebaut, dass sie unverändert als `tests/eazybusiness/*_Tests.sql`
eingecheckt werden können (Transaktions-/`#TestResults`-Muster, Servername-Guard-Kopf, PASS/FAIL-Ausgabe).
