# Deploy-Anleitung: „Versandklasse nach Gewicht" (Pilot)

> Kurzanleitung zum Ausrollen des Workflows. Kann selbst ausgeführt oder an
> die IT / den JTL-Betreuer weitergegeben werden. Dauer: ~10 Minuten.

## Ziel
Ein JTL-Workflow, der die **Versandklasse** eines Artikels automatisch auf
**„Spedition"** setzt, sobald das Versandgewicht **> 31,5 kg** ist. Pilot
zunächst nur für die Warengruppe **„Gartengeräte - Werkstattpflichtig"**.

## WICHTIG – nur Testumgebung!
- Ausführen **nur** auf dem **Test-Server `VM-SQL2`**, Datenbank `eazybusiness`.
- **NICHT** auf `mssql-prod1...` (Produktion).
- Benötigt: SQL-Zugang zur Test-DB (z. B. Benutzer `dbuser_eazybusiness_jtl`)
  mit Rechten, in den Schemas `Robotico` und `CustomWorkflows` Objekte
  anzulegen (CREATE PROCEDURE/FUNCTION/TABLE/VIEW). Ggf. Admin-Login nutzen.
- Voraussetzung in JTL: Modul **„Custom Workflow Actions"** lizenziert.

## Dateien (im Git-Branch `claude/jtl-workflow-structure-g8kq6v`, Ordner `WorkflowProcedures/`)
1. `Artikel_Versandklasse_NachGewicht.sql` — legt Funktion, Aktion, Log-Tabelle, View an
2. `Artikel_Versandklasse_NachGewicht_Tests.sql` — Testsuite (ändert keine echten Daten)
3. `Artikel_Versandklasse_NachGewicht_Backfill.sql` — Bestandskorrektur der Pilotgruppe
4. `Artikel_Versandklasse_NachGewicht_Teardown.sql` — nur Notfall/Rückbau

## Schritt A — SQL ausführen (SSMS)
1. SSMS öffnen → verbinden mit **Server `VM-SQL2`**, Authentifizierung
   **SQL Server Authentication**, Benutzer + Passwort der Test-DB.
2. Oben als Datenbank **`eazybusiness`** wählen (NICHT `master`).
3. Datei 1 öffnen → **F5**. Erwartung: „Commands completed successfully".
4. Datei 2 öffnen → **F5**. Erwartung im Reiter *Messages*: **`Tests: 16/16 bestanden.`**
   - Bei FEHLGESCHLAGEN: Meldung sichern, nicht weitermachen.

## Schritt B — Warengruppen-ID ermitteln
```sql
SELECT kWarengruppe, cName FROM dbo.tWarengruppe
WHERE cName LIKE 'Gartenger_te - Werkstattpflichtig';
```
Die Zahl unter `kWarengruppe` notieren (für Schritt C).

## Schritt C — Workflow in JTL-Wawi (Test) anlegen
1. JTL-Wawi (Test) → **Admin → Workflows** → **Neu**.
2. Workflowobjekt **Artikel**; Auslöser **Artikel erstellt** *und* **Artikel geändert**.
3. Name z. B. „Versandklasse nach Gewicht (Pilot Werkstattpflichtig)".
4. (Empfohlen) Bedingung: **Warengruppe = Gartengeräte - Werkstattpflichtig**.
5. Aktion **„Artikel: Versandklasse nach Gewicht setzen"** hinzufügen, Parameter:
   - `fSchwelleKg` = `31.5`
   - `kWarengruppe` = die ID aus Schritt B
   - `cBenutzer` = `{{ AktuellerBenutzer.Login }}`
   - „Bei Fehler Workflow abbrechen" = **aus**
6. Speichern & **aktivieren**.

## Schritt D — Bestand nachziehen (Backfill)
1. Datei 3 in SSMS öffnen (DB `eazybusiness`) → **F5**: zeigt zuerst eine
   **Vorschau** der Artikel, die sich ändern würden (nichts wird verändert).
2. Vorschau prüfen (erwartet ~5 Artikel).
3. Im Skript `DECLARE @bApply BIT = 0;` auf `= 1;` ändern → erneut **F5**.

## Schritt E — Kontrolle (Änderungsprotokoll)
```sql
SELECT * FROM Robotico.vVersandklassenLog ORDER BY dErstellt DESC;
```
Zeigt jede automatische Änderung: Artikel, alt → neu, Gewicht, Zeit, Benutzer.

## Notaus
- Workflow in JTL auf **inaktiv** setzen → stoppt sofort.
- Rückbau der SQL-Objekte: Datei 4 (`..._Teardown.sql`). Das Protokoll bleibt.

## Später: Voll-Rollout
Gleiches Deploy auf Produktion, Workflow-Parameter `kWarengruppe` **leer lassen**
(NULL = alle Warengruppen). Vorher Pilot auswerten.
