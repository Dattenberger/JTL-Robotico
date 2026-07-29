# JTL-Testmandanten (YouTrack-Artikel JTL-A-20)

> Quelldatei für den YouTrack-Knowledge-Base-Artikel **JTL-A-20**
> (https://dattenberger.youtrack.cloud/articles/JTL-A-20).
> **Pflege:** hier editieren, dann den GESAMTEN Inhalt (ab der H1 unten) per
> YouTrack-MCP `update_article` hochladen — die API kann nur Voll-Überschreiben
> oder Anhängen, kein Teil-Edit und keinen Datei-Upload.
> **Bei Mandanten-Änderungen** (neue Mandanten, Umzuordnung): Tabelle inkl.
> Stand-Datum aktualisieren UND `ops.tMandant.cDeveloper` nachziehen — siehe
> Querverweis in `docs/SQL/MSSQL-OPS-ARCHITECTURE.md`.
> Stil: Hausschrift der JTL-Knowledge-Base (Du-Form, Schritt-Überschriften,
> Frage-Antwort-Hinweise — Vorbild JTL-A-9/JTL-A-16).

---

# JTL-Testmandanten

> 🇬🇧 English version: [JTL Test Mandants](https://dattenberger.youtrack.cloud/articles/JTL-A-21)

Testmandanten sind vollwertige Wawi-Mandanten mit einer **Kopie der Produktionsdaten** — zum gefahrlosen Ausprobieren, Testen und Schulen. Diese Seite erklärt, welche es gibt, wie du sie benutzt, zurücksetzt und neue bekommst.

## Übersicht: Welche Testmandanten gibt es?

**Zuordnung, Stand: 29.07.2026** *(spätere Änderungen bitte hier nachziehen — aktuelle Wahrheit liefert jederzeit `EXEC reset.spPub_ListMandants;`)*

| Mandant | Name in der Wawi | Zugeordnet an | Staging-Shop |
| --- | --- | --- | --- |
| `tm2` | Testmandant 2 | **Dana** | `https://shop-staging-dana.ison-musical.ts.net` |
| `tm3` | Testmandant 3 | **Sanda** | `https://shop-staging-sanda.ison-musical.ts.net` |
| `tm4` | Testmandant 4 | **Lukas** | `https://shop-staging-lukas.ison-musical.ts.net` |

Nutze bevorzugt **deinen** Mandanten. Brauchst du einen fremden, sprich dich kurz mit der Person ab — ein Reset löscht alles, was dort gerade liegt.

## Zugang: Wie komme ich an meinen Testmandanten?

* **In der Wawi:** Beim Anmelden einfach den Mandanten auswählen (z. B. „Testmandant 3") — die Testmandanten stehen dort automatisch in der Auswahl.
* **Direkt auf die Datenbank** (für SQL-Abfragen und die Befehle unten): SQL Server Management Studio (SSMS), **Windows-Anmeldung**:
  * **Server:** `mssql-prod1.ison-musical.ts.net` (Tailscale-Adresse)
  * **Datenbank für die Befehle unten:** `RoboticoOps`
  * Deine normale Windows-Anmeldung reicht — alle Wawi-Nutzer haben die nötige Berechtigung automatisch.

**Tipp:** In SSMS oben links im Dropdown die Datenbank `RoboticoOps` wählen, neues Abfragefenster öffnen, Befehl eintippen, `F5`.

## Zurücksetzen: Frischen Datenstand holen

Ein Reset setzt den Testmandanten **komplett neu auf** — als anonymisierte Kopie der Produktivdaten von genau jetzt. Dauer: **ca. 5–6 Minuten**.

> ⚠️ Alles, was vorher auf dem Testmandanten war, ist danach **weg**. Testmandanten sind Wegwerf-Umgebungen — leg dort nichts ab, das du behalten willst.

**Starten** (Mandant-Kürzel aus der Tabelle oben einsetzen):

```sql
EXEC reset.spPub_StartTestmandantReset @MandantKey = N'tm3';
```

Du bekommst eine **Requestnummer** und Status `queued` — ab jetzt läuft alles automatisch im Hintergrund, du kannst das Fenster schließen. **Aus Versehen doppelt gestartet?** Kein Problem — du bekommst einfach dieselbe Requestnummer nochmal, es laufen nie zwei Resets gleichzeitig.

**Fortschritt ansehen** (optional, beliebig oft):

```sql
EXEC reset.spPub_GetResetStatus @MandantKey = N'tm3';
```

| Spalte | Bedeutung |
| --- | --- |
| `cStatus` | `queued` → `running` → **`succeeded`** (fertig!) oder `failed` |
| `cStepLog` | Protokoll der 8 Arbeitsschritte mit Uhrzeiten — die **unterste Zeile** ist der aktuelle Schritt |
| `cErrorMessage` | Nur bei `failed`: was schiefging |

Die Anonymisierung (Schritt 5) ist der längste Teil — wenn es dort ein paar Minuten „hängt", ist das normal. Sobald `cStatus = succeeded`: Wawi starten, Mandanten auswählen, loslegen. **Während des Resets den Mandanten nicht benutzen** (die Datenbank wird ausgetauscht).

**Wenn etwas hakt:**

* `failed`? → In `cErrorMessage`/`cStepLog` steht warum. Einfach nochmal starten — immer gefahrlos, der Reset räumt selbst auf. Bleibt es rot: Lukas.
* Über eine Stunde `running`? → Abbrechen mit `EXEC reset.spPub_CancelResetRequest @RequestId = <Requestnummer>;` (verweigert sich, solange wirklich noch gearbeitet wird).
* Das Produktivsystem wird beim Reset **nur gelesen, nie verändert** — du kannst hier nichts kaputt machen.

## Was ein Testmandant genau ist

* Eine **Kopie der Produktionsdaten**, bereinigt um Protokolle/Historien und **anonymisiert**: Kundendaten (Namen, Adressen, Mails) werden unkenntlich gemacht (`mail_12345@test.local`).
* **Entschärft:** E-Mail-Versand, Marktplatz-Anbindungen und Zugangsdaten werden abgeklemmt — vom Testmandanten geht nichts versehentlich nach draußen.
* **Mit einem Staging-JTL-Shop verknüpft** (siehe Tabelle oben) statt mit dem echten Shop.
* Die Infrastruktur kümmert sich automatisch um die Formalitäten — Lizenz-/Shop-Zuordnung, Benutzerrechte, Mandanten-Registrierung in der Wawi.

## Neuen Testmandanten bekommen

Testmandanten können von allen Mitarbeitenden **angefordert werden — bei Lukas**. Das Anlegen selbst ist ein Admin-Schritt (Prozedur `reset.spPub_CreateTestmandant`, vergibt Kürzel, Namen und Datenbank automatisch und stößt direkt den ersten Reset an). Dabei zu beachten:

* Für den verknüpften Staging-Shop müssen die **Lizenzinformationen nachgepflegt** werden (Shop-URL + Lizenz-Key in der Mandanten-Registry) — bis dahin ist die Shop-Anbindung des Testmandanten schlicht funktionslos.
* Neue Mandanten anschließend **in der Tabelle oben ergänzen** (inkl. neuem Stand-Datum).

## Wie die Infrastruktur grob funktioniert

Hinter den Befehlen steckt eine eigene Verwaltungs-Datenbank (`RoboticoOps`) auf dem SQL-Server: Dein Start-Befehl legt einen Auftrag in eine Warteschlange, ein Hintergrund-Job des SQL-Servers arbeitet ihn in **8 Schritten** ab — Produktions-DB kopieren, Sicherheit härten, Zugangsdaten entwerten, Hintergrunddienste neutralisieren, Kundendaten anonymisieren, Rechte setzen, Mandanten in der Wawi registrieren, Rollen anwenden. Jeder Schritt protokolliert sich; genau das siehst du in `cStepLog`.

---

> 🔧 **Technische Dokumentation (für Entwickler):** Die vollständige technische Beschreibung der Testmandanten-Infrastruktur liegt im Git-Repository: [`docs/SQL/MSSQL-OPS-ARCHITECTURE.md`](https://github.com/Dattenberger/JTL-Robotico/blob/master/docs/SQL/MSSQL-OPS-ARCHITECTURE.md) (JTL-Robotico). Dieser YouTrack-Artikel ist die Bedien-Anleitung und wird bei Änderungen an der Infrastruktur mit aktualisiert — die Quelldatei dazu liegt ebenfalls im Repository (`docs/plans/2026-07-10 - mssql-ops-infrastruktur/reports/youtrack-testmandant-reset-kurzanleitung.md`).
