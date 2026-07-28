---
title: VPE-Workflow auf Lieferantenbestellungen — Research
status: Research
date: 2026-07-23
subsystem: JTL SQL Migrations
audience: team-lead / plan author (nicht implementiert — reine Recherche)
---

# VPE-Workflow auf Lieferantenbestellungen — Research

Informationsbeschaffung für eine geplante Custom-Workflow-Aktion auf JTL
**Lieferantenbestellungen** (Warenbestellungen). Ziel der späteren Aktion:

1. Positionen, deren Artikel eine VPE (Verpackungseinheit) hat, im sichtbaren
   Positions-Textfeld mit `{VPE=10}` markieren.
2. Positionen erkennen, deren importierter EK-Preis „erheblich höher" ist als der
   in JTL hinterlegte Stück-EK (Indiz: VPE-Gesamtpreis statt Stückpreis importiert)
   → `{VPE=10, VPE Error}`.
3. Bei erkanntem Fehler die **Fremdbelegnummer** der Bestellung um `{{VPE Error}}`
   ergänzen.

> [!IMPORTANT]
> Dieser Bericht ist reine Recherche. Es wurde nichts implementiert. Alle
> Prod-Abfragen gegen `vm-sql2` waren ausschließlich lesend (SELECT / Metadaten).

---

## TL;DR — die 5 entscheidenden Befunde

1. **Aktions-Mechanik steht.** Custom-Workflow-Aktionen sind Stored Procs im Schema
   `CustomWorkflows`, die **einen einzigen INT-Parameter** (den Objekt-Key)
   entgegennehmen. Registriert über die guarded Helfer `CustomWorkflows._CheckAction`
   + `_SetActionDisplayName` (JTL-Modul „Custom Workflow Actions"). In der Wawi wird
   die Aktion als `jtlAktionCustomWorkflow` mit `<ActionName>spName</ActionName>`
   an einen Workflow gehängt — die Wawi übergibt den PK des auslösenden Objekts.
2. **VPE liegt NICHT auf `tArtikel`, sondern auf `tLiefArtikel`.** Beim Beispiel
   6123037 ist `tArtikel.nVPE=0 / fVPEWert=0`, aber `tLiefArtikel.nVPEMenge=10`,
   `cVPEEinheit='10er Pack'`. VPE ist also **lieferantenspezifisch**.
3. **Sichtbares Positions-Textfeld = `tLieferantenBestellungPos.cHinweis`**
   (nvarchar(2000)). In Prod aktuell mit Warengruppen-Text („Rasenroboter Zubehör;
   Unhandlich") befüllt — das ist der „Input", in den `{VPE=10}` geschrieben werden soll.
4. **🚨 Härtester Blocker: JTL-Schutztrigger auf den Positionen.** Ein AFTER-Trigger
   `tgr_tlieferantenBestellungPos_INSUPDEL` **rollt jedes direkte INSERT/UPDATE/DELETE
   zurück**, außer `CONTEXT_INFO()` steht auf einem JTL-Magic-Wert. cHinweis kann also
   **nicht** per einfachem `UPDATE` gesetzt werden — nur über die JTL-SP
   `Lieferantenbestellung.spLieferantenBestellungPosBearbeiten` oder durch Setzen von
   `CONTEXT_INFO`.
5. **Fremdbelegnummer ist dagegen frei änderbar.** Der Kopf-Trigger listet
   `cFremdbelegnummer` NICHT in seiner Guard-Spaltenliste — ein UPDATE, das nur
   `cFremdbelegnummer` berührt, wird vom Trigger durchgelassen (kein CONTEXT_INFO nötig).

---

## A) Repo-Konventionen

### Wo Workflow-Aktionen heute leben

`WorkflowProcedures/` ist **deprecated als Deploy-Quelle** (siehe dessen README, D12).
Deploy-SSoT ist die versionierte grate-Kette unter `db-migrations/eazybusiness/`
(Ebene A). Aktionsprozeduren liegen als `sprocs/CustomWorkflows.sp*.sql` bzw.
`sprocs/Robotico.sp*.sql`.

Bestehende Muster-Aktionen (alle nach demselben Schema):
- `db-migrations/eazybusiness/sprocs/CustomWorkflows.spGebindeErstellen.sql`
  (`@kArtikel INT`, TRY/CATCH + Transaktion, RAISERROR-Rethrow)
- `db-migrations/eazybusiness/sprocs/CustomWorkflows.spZustandartikelLieferantSetzen.sql`
  (single atomic UPDATE, `SET ANSI_NULLS/QUOTED_IDENTIFIER ON` wegen gefilterter Indizes)
- `CustomWorkflows.spSeriennummerStandardZuWMS.sql`, `spAuftragPreiseAufNull.sql`

### Aufbau einer Aktions-Datei (Muster)

```sql
CREATE OR ALTER PROCEDURE CustomWorkflows.spMeinName @kObjekt INT AS
BEGIN
    SET NOCOUNT ON;
    -- ... Logik ...
END
GO

-- Registrierung (db-migrations/README.md §6) — guarded, weil die Helfer vom
-- JTL-Modul "Custom Workflow Actions" kommen, nicht aus diesem Repo:
IF OBJECT_ID('CustomWorkflows._CheckAction', 'P') IS NOT NULL
    EXEC CustomWorkflows._CheckAction @actionName = 'spMeinName';
ELSE
    PRINT '! _CheckAction missing — Modul nicht gebucht; skipping.';
GO
IF OBJECT_ID('CustomWorkflows._SetActionDisplayName', 'P') IS NOT NULL
    EXEC CustomWorkflows._SetActionDisplayName @actionName = 'spMeinName',
        @displayName = 'Anzeigename in der Wawi-UI';
ELSE
    PRINT '! _SetActionDisplayName missing — Modul nicht gebucht; skipping.';
GO
```

Header-Konventionen: Modul-Header-Kommentar mit `@see docs/plans/...`, „Ported from"
entfällt (Neubau). Voraussetzung Modul „Custom Workflow Actions" gebucht — siehe
`docs/SQL/JTL-CUSTOM-WORKFLOWS.md` und `db-migrations/README.md §6`.

### Wie JTL-Wawi die Prozedur aufruft — verifiziert an der (Ex-)PayPal-Aktion

Die Aktion wird in `dbo.tWorkflowAktion.xXmlObjekt` als DataContract-XML abgelegt.
Volle Struktur von `kWorkflowAktion=182` (PayPal Lieferschein, noch in Prod):

```xml
<jtlAktion ... i:type="a:jtlAktionCustomWorkflow">
  <CancelOnError>false</CancelOnError>
  <WawiVersion>2.0.5.0</WawiVersion>
  <a:Parameters i:nil="true"/>
  <a:UseDotLiquidParameters>false</a:UseDotLiquidParameters>
  <a:ActionName>spPaypalTrackingLieferschein</a:ActionName>
  <a:ActionParameter .../>
</jtlAktion>
```

**Kernaussage:** Der Aktionstyp ist `jtlAktionCustomWorkflow`, referenziert die Proc
über `<ActionName>` (ohne Schema-Präfix). Die Wawi übergibt automatisch den **PK des
auslösenden Objekts** an den einzigen INT-Parameter der Proc. Für Lieferantenbestellung
wäre das `@kLieferantenBestellung`. `CancelOnError=false` ⇒ Fehler in der Proc sind
nicht-fatal, werden aber ins `tWorkflowLog` geschrieben (noisy).

> Registrierung + Modul-Buchung ist Voraussetzung, aber der eigentliche Workflow
> (Event, Bedingung, Aktion-Zuordnung) wird **in der Wawi-UI** angelegt — dieses Repo
> deployt nur die Proc, nicht `dbo.tWorkflow*` (JTL-Config-State).

---

## B) & C) JTL-Schema + Prod-Verifikation

Alle Spalten gegen Prod (`vm-sql2`, SQL Server 2022, DB `eazybusiness`) verifiziert.

### tLieferantenBestellung (Kopf)

| Spalte | Typ | Bedeutung / Hinweis |
|---|---|---|
| `kLieferantenBestellung` | int IDENTITY | PK — dies ist der an die Proc übergebene Key |
| `kLieferant` | int NOT NULL | für VPE/EK-Lookup gegen `tLiefArtikel` nötig |
| `cFremdbelegnummer` | nvarchar(255) NULL | **Ziel für `{{VPE Error}}`-Anhang** (Teil 3) |
| `cEigeneBestellnummer` | nvarchar(255) NULL | eigene Bestellnr. |
| `nStatus` | int NULL | 0/20/500 in Beispieldaten |
| `nDeleted` | tinyint NULL | Soft-Delete; auf `=0` filtern |
| `bRowversion` | timestamp | rowversion, auto |

Beispieldaten (Kopf, Lieferant 2):

```
kLB  | cFremdbelegnummer | cEigeneBestellnummer     | nStatus
4107 | 2013636185        | Herbst FD 2026_Abruf2    | 0
4106 | 2013649088        | D-BE20262292-I           | 20
4104 | (leer)            | D-BE20262291             | 500
```

→ `cFremdbelegnummer` ist eine reine Ziffern-/Belegnummer des Lieferanten; teils leer.
An diese würde `{{VPE Error}}` angehängt.

### tLieferantenBestellungPos (Positionen)

| Spalte | Typ | Bedeutung / Hinweis |
|---|---|---|
| `kLieferantenBestellungPos` | int IDENTITY | PK |
| `kLieferantenBestellung` | int NOT NULL | FK zum Kopf |
| `kArtikel` | int NOT NULL | für VPE/EK-Lookup |
| `cArtNr` | nvarchar(255) | |
| `cName` | nvarchar(255) | Positionsname |
| `cHinweis` | **nvarchar(2000)** | **sichtbares Textfeld = „Input" für `{VPE=…}`** |
| `fMenge` | decimal(25,13) | Bestellmenge |
| `fEKNetto` | decimal(25,13) | **importierter Positions-EK** (Vergleichswert Teil 2) |
| `cVPEEinheit` | nvarchar(255) NULL | pos-seitig in Prod **leer** (VPE lebt auf tLiefArtikel) |
| `nVPEMenge` | decimal(25,13) NULL | pos-seitig in Prod **0** |
| `nPosTyp` | int NULL | 1 = normale Artikelposition in Beispielen |
| `bRowversion` | timestamp | rowversion, auto |

Beispieldaten (Positionen zu Bestellung 4104), `cHinweis` heute befüllt:

```
cArtNr    | cName (gekürzt)               | cHinweis                          | fMenge | fEKNetto | nVPEMenge(pos)
9018238-M | Husqvarna Automower Garage M  | Rasenroboter Zubehör; Unhandlich  | 20     | 0.0000   | 0
8880013   | Husqvarna Pflegespray Heck    | Gartengeräte Zubehör              | 12     | 10.7554  | 0
9017066   | Dichtung f. Gardena Mähroboter| Rasenroboter Ersatzteile          | 10     | 2.7645   | 0
```

→ `cHinweis` trägt aktuell Warengruppen-/Handling-Text und ist damit klar das
UI-sichtbare Feld, in das `{VPE=10}` geschrieben werden soll. `cName` ist der
Artikelname (nicht überschreiben). Position-eigene VPE-Felder sind leer.

### Wo die VPE wirklich steckt — `tLiefArtikel` (lieferantenspezifisch)

Beispielartikel **6123037** (Husqvarna Entlüftungsmembrane, VPE=10):

```
tArtikel:    kArtikel=569  nVPE=0  fVPEWert=0.0  kVPEEinheit=0  fEKNetto=2.1553
tLiefArtikel: kLiefArtikel=669  tLieferant_kLieferant=2  cLiefArtNr=577753701
              fEKNetto=2.2733   fEKBrutto=2.7052   cVPEEinheit='10er Pack'
              nVPEMenge=10.0    nStandard=1
```

**Semantik (bestätigt):**
- Die VPE-Menge „10" steht in **`tLiefArtikel.nVPEMenge`** (decimal), der Klartext
  in `tLiefArtikel.cVPEEinheit` (`'10er Pack'`). `tArtikel.nVPE/fVPEWert` sind hier
  ungenutzt (0) — **nicht** als VPE-Quelle verwenden.
- Der **hinterlegte Stück-EK** ist `tLiefArtikel.fEKNetto` (2.2733) des jeweiligen
  Lieferanten (`nStandard=1` markiert den Standard-Lieferanten).
- Lookup-Join: `tLiefArtikel WHERE tArtikel_kArtikel = pos.kArtikel AND
  tLieferant_kLieferant = kopf.kLieferant`. Unique-Constraint
  `(tArtikel_kArtikel, tLieferant_kLieferant)` garantiert max. 1 Treffer.
- Gestaffelte EKs (mengenabhängig) liegen in `tLiefArtikelPreis` (`fAb`, `fPreisNetto`).
  Für die „Stückpreis"-Baseline reicht `tLiefArtikel.fEKNetto`; Staffelpreise sind
  ein optionaler Verfeinerungspunkt (siehe Offene Punkte).

**Regel für „VPE hinterlegt":** `tLiefArtikel.nVPEMenge > 1`.
**Heuristik für „VPE Error":** importierter `pos.fEKNetto` ≈ `nVPEMenge × tLiefArtikel.fEKNetto`
(also der Faktor zwischen Positions-EK und Stück-EK liegt nahe der VPE-Menge).

---

## 🚨 Trigger-Schutz — der zentrale Implementierungs-Constraint

Beide Bestelltabellen tragen aktive JTL-Schutztrigger. Beide verifiziert per
`OBJECT_DEFINITION`.

### Positions-Trigger `tgr_tlieferantenBestellungPos_INSUPDEL` — HART

```sql
IF CONTEXT_INFO() IN (0x5123, 0x5124, 0x5125, 0x5129, HASHBYTES('SHA1',
    'spUpdateLieferantenBestellungPosToFreiPosForStuecklistenVaeter'))
    RETURN;
ROLLBACK;
RAISERROR(N'Die Tabelle tlieferantenBestellungPos kann nur über die SPs
  spLieferantenBestellungPosBearbeiten, ...Erstellen, ...Loeschen ... bearbeitet
  werden.', 15, 1);
```

→ **Jedes** direkte `UPDATE cHinweis` wird zurückgerollt, es sei denn `CONTEXT_INFO()`
steht auf einem der Magic-Werte. Es gibt **keine** Per-Spalten-Ausnahme.

**Zwei sanktionierte Wege, `cHinweis` zu setzen:**

- **(A) sauber:** `EXEC Lieferantenbestellung.spLieferantenBestellungPosBearbeiten …`.
  Die SP nimmt **alle** Positionsspalten (Vollüberschreibung), u.a.:
  `@kLieferantenbestellungPos, @kLieferantenbestellung, @kArtikel, @cArtNr,
  @cLieferantenArtNr, @cName, @cLieferantenBezeichnung, @fUST, @fMenge,
  @cHinweis nvarchar(2000), @fEKNetto, @nPosTyp, @cNameLieferant, @nLiefertage,
  @dLieferdatum, @nSort, @kLieferscheinPos, @fMengeGeliefert, @cVPEEinheit,
  @nVPEMenge` (+ optional `@xLieferantenbestellungPos` XML). Man muss also die
  aktuellen Werte lesen und mit geändertem `@cHinweis` zurückschreiben. Setzt intern
  das korrekte CONTEXT_INFO ⇒ trigger-safe. **Wartbarster Weg**, aber verbose.
- **(B) pragmatisch:** vor dem UPDATE `SET CONTEXT_INFO 0x5124;` (der Magic-Wert für
  Pos-Bearbeiten), dann direktes `UPDATE … SET cHinweis = …`, danach CONTEXT_INFO
  zurücksetzen. Kürzer, aber **fragil**: hängt an einem undokumentierten JTL-Internum,
  das bei einem Wawi-Update brechen kann. Nur mit Kommentar + Risiko-Vermerk verwenden.

> Empfehlung: (A) bevorzugen (SOLID/serviceable, überlebt Wawi-Updates), (B) nur wenn
> die Vollüberschreibung praktisch nicht handhabbar ist. Entscheidung dem Plan-Autor
> überlassen.

### Kopf-Trigger `tgr_tlieferantenBestellung_INSUPDEL` — WEICH für Fremdbelegnummer

```sql
-- (immer) schreibt Kunde.tHistorie für Dropshipping (INSERTED-basiert)
IF CONTEXT_INFO() IN (0x5120,0x5121,0x5122,0x5126,0x5129, HASHBYTES('SHA1',
    'Kunde.spKundenZusammenfuehren')) RETURN;
IF NOT( UPDATE(kLieferantenBestellung) OR UPDATE(kLieferant) OR ... OR
        UPDATE(nStatus) OR ... OR UPDATE(kLieferschein) )
   AND EXISTS(... JOIN DELETED ...)
    RETURN;     -- <- reiner Nicht-Guard-Spalten-UPDATE ist erlaubt
ROLLBACK; RAISERROR('… nur über spLieferantenBestellungBearbeiten/…', 15, 1);
```

Die Guard-Liste umfasst `kLieferantenBestellung, kLieferant, kSprache,
kLieferantenBestellungRA, kLieferantenBestellungLA, nStatus, kFirma, kLager, kKunde,
nDropShipping, kLieferantenBestellungLieferant, kBenutzer, fFaktor, nDeleted,
nManuellAbgeschlossen, kLieferschein`. **`cFremdbelegnummer` fehlt darin** ⇒ ein
UPDATE, das ausschließlich `cFremdbelegnummer` (und andere nicht-gelistete Spalten wie
`cInternerKommentar`/`cDruckAnmerkung`) ändert, trifft den `RETURN`-Zweig und ist
**ohne CONTEXT_INFO erlaubt**. Teil 3 (Fremdbelegnummer-Anhang) ist damit per einfachem
`UPDATE dbo.tLieferantenBestellung SET cFremdbelegnummer = … WHERE kLieferantenBestellung = @k`
umsetzbar.

> [!WARNING]
> Diese Trigger-Nachsicht ist ein beobachtetes Verhalten der aktuellen Wawi-Version,
> kein dokumentierter JTL-Vertrag. Bei Wawi-Updates die Guard-Liste erneut prüfen.
> Ein Regressionstest, der den Fremdbelegnummer-UPDATE gegen den Trigger ausführt,
> ist ratsam.

---

## Registrierte Workflows auf Lieferantenbestellung

**Aktuell KEINE.** `dbo.tWorkflow` enthält Workflows für die Objekttypen
`nObjekt ∈ {1,2,3,5,6,7,8,9,10,11,15,16}` — identifiziert u.a.: 5=Kunde, 6=Auftrag
(Mehrzahl: DHL/Packstation/Vorkommissionieren), 7=Rechnung/Lieferschein, 9=Rechnungs-
korrektur, 16=Lieferschein (die Ex-PayPal-Aktionen). **Kein** Objekttyp trägt
Lieferantenbestellungs-Workflows; die Namenssuche nach „Lieferant/Bestellung/VPE"
liefert nur auftragsbezogene Treffer.

→ Diese Aktion wäre die **erste** Workflow-Automatik auf Lieferantenbestellungen. Das
wirft die Frage auf, **ob JTL-Wawi Workflow-Events auf Lieferantenbestellungen
überhaupt anbietet** (siehe Offene Punkte — der kritischste Punkt).

Die einzigen SQL-/Proc-Aktionen im System sind die `jtlAktionCustomWorkflow`-Aktionen
(PayPal, kWorkflowAktion 182/183 auf nObjekt 7). Es gibt keine Roh-„SQL ausführen"-
Aktionen — der Custom-Workflow-Proc-Weg ist der etablierte Mechanismus.

---

## Offene Punkte / Risiken

1. **🔴 Unterstützt JTL-Wawi Workflows auf Lieferantenbestellungen?** (blockierend)
   Es existiert kein einziger registrierter Workflow auf diesem Objekttyp, und die
   Custom-Workflow-Aktionen laufen bisher nur auf Auftrag/Rechnung/Lieferschein.
   **Vor jeder Implementierung** muss in der Wawi-UI geprüft werden, ob es einen
   Objekttyp „Lieferantenbestellung/Warenbestellung" mit Events (z.B. „erstellt",
   „geändert", „Import") gibt, an den eine `jtlAktionCustomWorkflow` gehängt werden
   kann, und welchen INT-Key die Wawi dann übergibt (`kLieferantenBestellung` vs.
   evtl. `kLieferantenBestellungPos`). Wenn nein, ist der ganze Ansatz hinfällig und
   es braucht einen alternativen Trigger (Import-Hook, geplanter SQL-Job, o.Ä.).

2. **Definition „erheblich höher".** Vorschlag: VPE-Fehler, wenn
   `pos.fEKNetto >= tLiefArtikel.fEKNetto × nVPEMenge × 0.5` (also der Import liegt
   näher am VPE-Gesamtpreis als am Stückpreis). Robuster wäre ein Verhältnis-Test:
   `pos.fEKNetto / NULLIF(tLiefArtikel.fEKNetto,0)` liegt nahe `nVPEMenge`
   (z.B. `>= nVPEMenge × 0.6`) statt nahe 1. Toleranz (Rundung, Rabatte, Staffel-EK)
   muss der Fachbereich festlegen. Division durch 0 abfangen (fEKNetto kann 0 sein,
   siehe Position 9018238-M).

3. **Staffelpreise (`tLiefArtikelPreis`).** Der „hinterlegte Stück-EK" kann mengen-
   abhängig sein. Für v1 reicht `tLiefArtikel.fEKNetto`; wenn Fehlalarme auftreten,
   den passenden `fPreisNetto` per `fAb <= pos.fMenge` nachziehen.

4. **cHinweis-Schutztrigger (siehe oben).** Direktes UPDATE unmöglich. Entscheidung
   sanktionierte SP (A) vs. CONTEXT_INFO-Bypass (B) ist eine Architektur-/Wartbarkeits-
   Abwägung, die der Plan treffen muss. (A) bevorzugt.

5. **Idempotenz / Doppelmarkierung.** Läuft der Workflow mehrfach (Re-Import, erneutes
   Speichern), darf `{VPE=10}` nicht doppelt in `cHinweis` und `{{VPE Error}}` nicht
   mehrfach in `cFremdbelegnummer` landen. Marker-Präsenz vor dem Anhängen prüfen
   (analog zum Suffix-Idempotenz-Muster in `spZustandartikelLieferantSetzen`).

6. **Kopf-vs-Positions-Granularität.** Teil 1+2 sind pro Position, Teil 3 pro Kopf.
   Eine kopf-getriggerte Proc (`@kLieferantenBestellung`) muss über alle Positionen
   iterieren (Set-basiert), den Kopf-Fehler aggregieren (mind. eine Position mit
   VPE-Error ⇒ Fremdbelegnummer-Anhang). Falls die Wawi nur einen Positions-Key
   liefert, ist die Kopf-Logik anders zu lösen.

7. **`cHinweis`-Überschreiben vs. Anhängen.** Das Feld trägt heute produktiv
   Warengruppen-Text. `{VPE=10}` muss **angehängt** (oder in ein separates, klar
   getrenntes Segment gesetzt) werden, nicht den Bestandsinhalt ersetzen. Länge
   nvarchar(2000) beachten.

8. **`CancelOnError=false`.** Proc-Fehler sind nicht-fatal, landen aber im
   `tWorkflowLog`. Saubere TRY/CATCH-Behandlung + aussagekräftige Meldungen wie in
   `spGebindeErstellen` einplanen, damit das Log nicht verrauscht.

---

## Verifizierte Fakten-Quellen

- Repo: `WorkflowProcedures/README.md`, `db-migrations/eazybusiness/sprocs/CustomWorkflows.spGebindeErstellen.sql`,
  `…/spZustandartikelLieferantSetzen.sql`, `up/0003_drop_paypal_mechanic.sql`,
  gelöschte `CustomWorkflows.spPaypalTrackingLieferschein.sql` (via `git show HEAD:`).
- Schema-Kontext: `A_Context/JTL 1.10.11.0/dbo.tLieferantenBestellung.Table.sql`,
  `…tLieferantenBestellungPos.Table.sql`, `…tliefartikel.Table.sql`,
  `…tLiefArtikelPreis.Table.sql`, `…tArtikel.Table.sql`.
- Prod (`vm-sql2`, nur lesend): `sys.columns`/`sys.parameters`/`OBJECT_DEFINITION`
  für beide Trigger + `spLieferantenBestellungPosBearbeiten`; Beispieldaten Artikel
  6123037 + `tLiefArtikel`; Bestellungen 4104/4106/4107; `tWorkflow`/`tWorkflowAktion`
  (Aktion 182 XML).
