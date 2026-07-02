# Prozess: Geräte-Verifizierung bei Ersatzteil-/Motorbestellung

> Status: Konzept + einsatzfertige Referenz-Implementierung
> Ziel: **Retouren vermeiden**, die entstehen, weil ein Kunde ein
> geräteabhängiges Teil (Motor, Messer, Akku, Ladegerät, Begrenzungskabel …)
> bestellt, das **nicht zu seinem konkreten Gerätemodell passt**.
>
> Business-Kontext: JTL Robotico verkauft Mähroboter/Gartengeräte und die
> passenden Ersatz- und Verschleißteile. Viele Rücksendungen sind keine
> Produktmängel, sondern **Fehlbestellungen** ("Teil passt nicht an mein
> Modell"). Dieser Prozess fängt genau diese Fälle **vor dem Versand** ab.

---

## 1. Grundidee in einem Satz

Wenn ein Auftrag ein als *geräteabhängig* markiertes Teil enthält, schickt ein
JTL-Workflow dem Kunden **automatisch eine Rückfrage-E-Mail** ("Für welches
Gerät / welches Modell benötigen Sie das Teil?") und **hält den Auftrag zurück**,
bis die Kompatibilität bestätigt ist.

---

## 2. Warum das Retouren spart (Motivation)

- Verschleiß- und Ersatzteile sind **modell-/seriennummernspezifisch**. Ein
  Mähwerk-Motor, ein Messerteller oder ein Akku, der für Modell A passt, passt
  oft **nicht** für Modell B desselben Herstellers.
- Der Kunde weiß häufig nur "mein Mähroboter von Hersteller X", nicht die
  genaue Typ-/Artikelnummer des Geräts.
- Eine falsch bestellte Position erzeugt: Retoure + Rückversandkosten +
  Wiedereinlagerung + Zweitversand + verärgerten Kunden. Eine **kurze
  Rückfrage vor Versand** kostet eine E-Mail.
- Der Prozess ist **opt-in pro Artikel** (siehe §5) – er feuert nur dort, wo
  Modellabhängigkeit tatsächlich ein Retourenrisiko ist, und erzeugt keinen
  Mail-Spam bei universellem Zubehör.

---

## 3. Prozessablauf (Ereignis → Bedingung → Aktion)

Baut auf der JTL-Workflow-Mechanik auf
(`docs/SQL/JTL-CUSTOM-WORKFLOWS.md`): **Ereignis** (Auslöser) → **Bedingung**
(erweiterte Eigenschaft, gatet) → **Aktion(en)**.

```
┌──────────────────────────────────────────────────────────────────────────┐
│ EREIGNIS:  Auftrag_Erstellt  (Workflowobjekt "Auftrag")                    │
└──────────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ BEDINGUNG (alle müssen erfüllt sein):                                      │
│  1. Erweiterte Eigenschaft "Auftrag - Braucht Geräteabfrage" == WAHR       │
│     → Auftrag enthält ≥ 1 Position mit Eigenem Feld                        │
│       GeräteVerifizierungMail = 1                                          │
│  2. (optional) Verkaufskanal ∈ {Webshop, Amazon, eBay, …}  – nicht bei     │
│     internen Aufträgen / Werkstattaufträgen                                │
│  3. (optional) Auftrag noch nicht versandt / noch stoppbar                 │
└──────────────────────────────────────────────────────────────────────────┘
                              │  WAHR
                              ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ AKTIONEN:                                                                  │
│  A. E-Mail an Kunden: "E-Mail - Geräteabfrage" (Vorlage, siehe §6)         │
│     – nennt die betroffenen Positionen, fragt nach Gerätemodell /          │
│       Seriennummer / Kaufbeleg-Foto                                        │
│  B. Auftrag zurückhalten: Status/Anmerkung "Warten auf Gerätebestätigung"  │
│     setzen (z. B. Eigenes Auftrags-Feld / cAnmerkung / Versandsperre),     │
│     damit die Pickliste den Auftrag NICHT zieht                            │
│  C. (optional) Aufgabe/Ticket fürs Team + Wiedervorlage/Frist              │
└──────────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ RÜCKKANAL (manuell/teilautomatisiert):                                     │
│  – Kunde antwortet (Modell/Seriennummer) → Team prüft Kompatibilität       │
│  – passt: Versandsperre entfernen → normaler Versand                       │
│  – passt nicht: Auftrag korrigieren (richtiges Teil) / stornieren          │
│  – keine Antwort binnen Frist: Erinnerung, danach Klärung/Storno           │
└──────────────────────────────────────────────────────────────────────────┘
```

### Wichtige Design-Entscheidung: Zurückhalten, nicht nur fragen

Eine reine Info-Mail ohne Versandsperre verhindert **keine** Retoure – der
Auftrag würde parallel normal weiterlaufen und ggf. das falsche Teil versenden,
bevor der Kunde antwortet. Kern des Prozesses ist deshalb die Kombination
**Rückfrage + Versandsperre** (Aktion A **und** B). Die Sperre wird erst nach
Bestätigung entfernt.

---

## 4. Rückkanal & Freigabe – Varianten

| Variante | Aufwand | Vorteil | Nachteil |
|---|---|---|---|
| **E-Mail-Antwort → Ticket** (empfohlen für Start) | gering | nutzt bestehende JTL-Mail/Ticket-Strecke; Team prüft Kompatibilität manuell | manuelle Prüfung pro Fall |
| **Formular/Link** (Modell aus Dropdown) | mittel | strukturierte Antwort, maschinell auswertbar | Formular + Zuordnung nötig |
| **Kundenkonto-Gerätehinterlegung** | hoch | Modell einmal hinterlegt → künftige Bestellungen ohne Rückfrage | Pflege im Kundenstamm nötig |

Empfehlung: mit der **E-Mail-Variante** starten (kleinste Änderung, sofort
retourenwirksam), später bei Bedarf auf Formular/Kundenkonto ausbauen. Bei
hinterlegtem Gerät kann Bedingung 1 später um "…und für diesen Kunden ist noch
kein passendes Gerät hinterlegt" erweitert werden, um Rückfragen zu sparen.

---

## 5. Für welche Artikel ist das sinnvoll? (Retouren-Fokus)

### Auswahl-Mechanik: Opt-in pro Artikel über ein Eigenes Feld

Empfohlen wird ein **Eigenes Feld (Attribut) am Artikel**:

- **Name:** `GeräteVerifizierungMail`  (BIT/Ganzzahl, `1` = Rückfrage aktiv)
- Gepflegt vom **Produkt-/Category-Management**.

Das ist exakt dasselbe Muster wie das bereits existierende Feld
`LieferverzögerungKeineMail` (siehe
`Workflows/Lieferverzögerung/Artikel nicht verfügbar.sql`). Vorteile gegenüber
"ganze Warengruppe pauschal":

- **Präzise** – nur wirklich modellabhängige Teile lösen aus, kein Spam bei
  universellem Zubehör.
- **Steuerbar ohne Code** – Ein-/Ausschalten je Artikel im JTL-UI.
- **Konsistent** mit dem bestehenden Lieferverzögerungs-Opt-out.

Alternativen (auch kombinierbar): Auswahl über **Warengruppe**, **Kategorie**
oder **Merkmal** (`tArtikelMerkmal`). Diese eignen sich zum **Vorbelegen** des
Flags per einmaligem SQL-Update, sind als alleiniges Live-Kriterium aber zu
grob (jede Ausnahme braucht sonst Sonderlogik).

### Priorisierung nach Retouren-Risiko

Kandidaten zuerst aktivieren, bei denen **Modellabhängigkeit × Retourenquote ×
Warenwert** am höchsten ist:

| Priorität | Artikelgruppe | Warum modellabhängig / retourenträchtig |
|---|---|---|
| **Hoch** | Mähwerk-/Antriebs-**Motoren** | teuer, exakt modellgebunden, Fehlkauf = teure Retoure |
| **Hoch** | **Messer/Klingen/Messerteller** | Aufnahme & Maße je Modell verschieden, häufiger Verschleißkauf |
| **Hoch** | **Akkus/Batterien** | Bauform, Spannung, Stecker modellspezifisch |
| **Hoch** | **Ladegeräte/Netzteile** | Stecker/Leistung modellspezifisch |
| **Mittel** | **Begrenzungskabel / Ladestation / Suchkabel** | Kompatibilität je Systemgeneration |
| **Mittel** | **Räder / Antriebsräder / Gummis** | Aufnahme/Größe modellspezifisch |
| **Mittel** | **Steuerplatinen / Elektronik / Sensoren** | Revision/Firmware-abhängig |
| **Niedrig / nein** | Universalzubehör, Reinigung, Regenschutz-Garagen (universell), Schrauben-Sets | passt modellübergreifend → Rückfrage stört nur |

Faustregel für die Aktivierung: **"Gibt es dasselbe Teil in mehreren, nicht
untereinander tauschbaren Modell-Varianten?"** → ja: Flag setzen. **"Passt es an
praktisch alles?"** → nein: kein Flag.

### Startpaket (Empfehlung)

Mit den **Hoch-Priorität**-Gruppen (Motoren, Messer, Akkus, Ladegeräte) starten,
Retourenquote dieser Artikel vor/nach der Einführung vergleichen, dann nach
Datenlage auf Mittel-Gruppen ausweiten.

---

## 6. Referenz-Implementierung (in diesem Repo)

Alle Objekte folgen `docs/SQL/NAMING-CONVENTIONS.md` (Schema `Robotico`,
`fn`-Präfix, englischer Feature-Name, JTL-Schlüssel bleiben deutsch).

| Datei | Rolle |
|---|---|
| `WorkflowProcedures/Geraete-Verifizierung.sql` | `Robotico.fnAuftragBrauchtGeraeteabfrage` (BIT, gatet) + `Robotico.fnAuftragGeraeteabfrageArtikelListe` (HTML-Liste der betroffenen Positionen für die Mail) |
| `Workflows/Geräte-Verifizierung/Auftrag - Braucht Geräteabfrage.liquid` | erweiterte Eigenschaft (Rückgabetyp **Text**), liefert `WAHR`/`FALSCH` für die **Bedingung** |
| `Workflows/Geräte-Verifizierung/E-Mail - Geräteabfrage.liquid` | E-Mail-Text (Body) für die **Aktion** |

### Einrichtung in JTL-Wawi (Kurzanleitung)

1. **Eigenes Feld anlegen:** Artikel-Attribut `GeräteVerifizierungMail`
   (Ganzzahl/BIT). Bei den relevanten Artikeln (§5) auf `1` setzen – manuell
   oder per einmaligem SQL-Update über Warengruppe/Merkmal.
2. **SQL deployen:** `WorkflowProcedures/Geraete-Verifizierung.sql` gegen
   `eazybusiness` ausführen (idempotent, transaktional).
3. **Erweiterte Eigenschaft** anlegen, Rückgabetyp **Text**, Inhalt aus
   `Auftrag - Braucht Geräteabfrage.liquid`.
4. **Workflow** auf Objekt *Auftrag*, Ereignis *Auftrag_Erstellt*:
   - Bedingung: erweiterte Eigenschaft **Gleich** `WAHR`
     (+ optionale Bedingungen aus §3).
   - Aktion A: E-Mail an Kunden (Body aus `E-Mail - Geräteabfrage.liquid`).
   - Aktion B: Versandsperre/Status "Warten auf Gerätebestätigung" setzen.

### Warum die Gating-Logik eine erweiterte Eigenschaft ist (kein Custom Action)

Eine Custom-Workflow-**Aktion** kann keinen steuernden Rückgabewert liefern –
Gating passiert immer über eine **Bedingung/erweiterte Eigenschaft**
(SELECT-only, liefert Text/BIT). Details und Belege:
`docs/SQL/JTL-CUSTOM-WORKFLOWS.md` §5.

---

## 7. Abgrenzung / Nicht-Ziele

- **Kein** automatischer Kompatibilitäts-Abgleich Teil↔Gerät (dafür fehlt eine
  gepflegte Kompatibilitätsmatrix). Der Prozess **fragt** und **hält zurück**;
  die fachliche Prüfung macht das Team. Ein späterer Ausbau zu einer
  Kompatibilitätsmatrix (`Robotico.tGeraeteKompatibilitaet`) ist möglich.
- **Kein** Blockieren bereits versandter Aufträge (die Bedingung sollte auf noch
  stoppbare Aufträge begrenzt werden).
- **Kein** Mailversand bei internen/Werkstatt-Aufträgen (über Verkaufskanal-
  Bedingung ausschließen).

---

## 8. Offene Punkte / Entscheidungen fürs Team

1. **Rückkanal:** Start mit E-Mail-Antwort oder direkt Formular? (§4)
2. **Versandsperre-Mechanik:** Welches Feld/Status hält den Auftrag zurück, ohne
   die bestehende Pickstrecke zu stören? (Eigenes Auftragsfeld vs. vorhandener
   Status)
3. **Frist:** Nach wie vielen Tagen ohne Antwort Erinnerung / Klärung / Storno?
4. **Erste Artikelmenge:** Welche Warengruppen bekommen zum Start das Flag? (§5
   Startpaket)
5. **Mehrsprachigkeit:** Mail nur DE oder auch EN (Attribut/Vorlage je Sprache)?
