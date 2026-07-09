---
name: jtl-wawi-spezifika
description: JTL-Wawi-Randbedingungen für Testmandanten- und Migrations-Infrastruktur — Worker, Updates, Lizenz (Research, 2026-07-09)
status: Research
---

# JTL-Wawi-Spezifika für Testmandanten- und Migrations-Infrastruktur

> Quelle: Opus-Research-Agent „research-jtl", Session 2026-07-09 (Repo + Web, Konfidenz je Punkt markiert).
> Teilweise inzwischen konkretisiert durch den Instanz-Survey (siehe `_pending-instanz-survey.md`): Worker-Flags gefunden in `ebay_user.nGesperrt`, `pf_user.nGesperrt/nAktiv`, `tShop.nGesperrt`, `Worker.tTarget`.

**Wichtigster Befund vorab:** Der JTL-Worker gleicht *alle* in `tMandant` registrierten Mandanten derselben Server-Verbindung ab ([Worker-Einstellungen](https://guide.jtl-software.com/jtl-wawi/jtl-worker/einstellungen-im-jtl-worker/)). „Klon + `register-mandant.sql`" macht den Testmandanten für einen laufenden Produktiv-Worker sichtbar und abgleichbar — das größte systemische Risiko.

## 1. JTL-Mandantenverwaltung — offizieller Weg vs. Klon-Ansatz

**Befund (Konfidenz: hoch):** Mandant = eigenständige Firma, **jeder Mandant = eigene Datenbank**; verwaltet über *Start > Datenbank*. Anlage per „Neuen Mandanten anlegen" oder BAK-Restore. ([Mandantenfähigkeit](https://guide.jtl-software.com/jtl-wawi/installation/allgemeines-zur-mandantenfaehigkeit/), [Datenbank](https://guide.jtl-software.com/jtl-wawi/datenbank/))

**Was JTL neben `tMandant`/`tBenutzerFirma` erwartet (Konfidenz: mittel):**
- Die offizielle Datenbankverwaltung spielt beim Restore ein **DB-Update auf die Client-Version** ein (Versionsangleichung), registriert Backup-Historie, pflegt die Mandantenliste. Reiner `RESTORE + INSERT tMandant` überspringt die versionsprüfende Logik.
- **Marktplatz-/Installations-Identität:** Marktplatzkonten sind an *genau einen* Mandanten gebunden. Ein Klon trägt die **identische Bindung + interne GUIDs** wie Produktion → bei parallelem Betrieb Kollision. Credential-Invalidierung deckt die *Identitäts-GUIDs* nicht ab.
- WaWi-Client hält Server-Verbindungen lokal; Mandantenauswahl im Login kommt aus `tMandant` der Instanz — DB-seitiger Upsert genügt für Sichtbarkeit.

**Risiken des Klon-Ansatzes:** Worker-Kollision (hoch); gleiche GUIDs (mittel); `kMandant`-Vergabe per `MAX+1` ist nicht der offizielle Weg (mittel).

**Einordnung:** Community-Best-Practice ist eine **separate Instanz/VM ohne Netz** ([Forum](https://forum.jtl-software.de/threads/wie-macht-ihr-euch-euch-testumgebung.224704/)); der Gleiche-Instanz-Ansatz weicht bewusst ab → muss durch harte Worker-Neutralisierung kompensiert werden.

## 2. JTL-Versionsupdates & DB-Migration

**Update-Mechanik (Konfidenz: hoch):** Client-Update → beim ersten Login pro DB **Update-Assistent** (Schema-Update pro DB); automatisches Backup vorher; Simulationsoption; Wahl „nur aktueller Mandant" oder „alle Mandanten". ([JTL-Wawi aktualisieren](https://guide.jtl-software.com/jtl-wawi/installation/jtl-wawi-aktualisieren/))

**„Alle Mandanten versionsgleich" (Konfidenz: hoch):** Jede Mandanten-DB wird einzeln migriert; Client verweigert Login an ältere DB. Konsequenz für Klone:
- **Klon-nach-Update statt Update-des-Klons:** Produktion zuerst updaten & stabilisieren, dann frisch klonen → Klone automatisch versionsgleich.
- Große Versionssprünge vermeiden (erst letzter Patch der alten Linie).

**Fremde Objekte beim Update (Konfidenz: mittel — Forum/Erfahrung):**
- Einziger gut dokumentierter harter Blocker: **Collation** (`Latin1_General_CI_AS`); Konflikt bricht das DB-Update ([Forum](https://forum.jtl-software.de/threads/fehler-beim-datenbankupdate-auf-hoehere-version.229282/)). Admin-DB + eigene Objekte müssen dieselbe Collation haben.
- Eigene Objekte in **eigenen Schemas** überstehen Updates (JTL fasst nur `dbo` an — Erfahrungskonsens, keine harte Zusage). **Riskant:** Trigger auf JTL-Tabellen, eigene Spalten/Indizes auf `dbo.t*`, Views/SPs auf JTL-`dbo`-Objekte (silent breakage).
- `CustomWorkflows`-Infrastruktur ist rein strukturell (Discovery über `vCustomAction*`-Views + `tWorkflowObjects`/`tAllowedDatatypes`). Actions überleben ein Update, **solange JTL diese Infrastruktur nicht ändert** — sonst Status `ERROR`. → **Post-Update-Smoke-Test:** `SELECT * FROM CustomWorkflows.vCustomActionCheck WHERE Status='ERROR'`.

## 3. Worker / Onlineshop-Abgleich auf Testmandanten

**Befund (Konfidenz: hoch):** Aktiv werdender Klon droht mit: eBay/Amazon-Rückabgleich (Tracking, Status), **Rechnungs-/Status-E-Mails an echte Kunden**, Shop-Abgleich (überschreibt Live-Shop-Bestände/Preise), Zahlungsdienste, WMS/POS, Cloud-/Account-Bindung. Worker muss **als Dienst gestoppt** sein — „in der Konfiguration deaktivieren reicht nicht" ([Worker-Guide](https://guide.jtl-software.com/jtl-wawi/jtl-worker/), [Forum eBay-Abgleich](https://forum.jtl-software.de/threads/jtl-wawi-testumgebung-ebay-abgleich.115275/)).

**Bereits abgedeckt (`invalidate-credentials-for-testing.sql`, inkl. Commit e6d7b2b):** SMTP, eBay-Credentials **+ eBay-Kontosperre `nGesperrt=1`**, Amazon/OAuth-Credentials, **Shop-Repoint auf Staging** (URL+Lizenz, Benutzer/Passwort bleiben), PayPal, Versand, SCX/Sync/BI-Tokens, Voucher, Fulfillment, Bankdaten, Lizenz-/Login-Token, DATEV.

**Verbleibende Lücken für den neuen Reset (Konfidenz: mittel–hoch):**
1. **Amazon-Pendant zur eBay-Sperre** — Survey-Befund: `pf_user.nGesperrt`/`nAktiv` (+ VCS-Sperren `dVcsSperreUtc`/`dVcsLiteSperreUtc`); in der Haupt-DB aktuell 0 Zeilen, in Mandanten-DBs nachprüfen.
2. **Queues leeren:** `tQueue` (~9.800), `tWorkflowQueue` (~5.300), `ebay_usermessagequeue` (~1.300), `tGlobalsQueue`, Mail-Queues — Rückstau feuert, sobald jemand Credentials testweise wieder einträgt.
3. **Worker-Abgleichsteuerung:** `Worker.tTarget` (uTargetId, kMandant, nAbgleichstyp, kZiel) — je Mandant prüfen/neutralisieren.
4. **Identitäts-/Seller-GUIDs:** bleiben = Produktion; unkritisch solange Worker aus, aber manueller Marktplatz-Abgleich im Testmandanten könnte Produktions-Bindung stören.
5. **JTL-Ameise / geplante Tasks / externe Cronjobs** auf die DB (außerhalb DB, ins Reset-Runbook).

## 4. Eigene Objekte in eazybusiness

**Befund (Konfidenz: mittel, Konsens):** Eigene Objekte in eigene Schemas (praktiziert: `Robotico`, `RoboticoEKL`, `CustomWorkflows`). **Separate Admin-DB** ist die update-sicherste Variante (überlebt WaWi-Updates unberührt, wird bei eazybusiness-Restore nicht überschrieben); Trade-off: Cross-DB-Views zerbrechen bei JTL-`dbo`-Strukturänderung → Post-Update-Smoke-Test; konsistente Collation + Berechtigungen in beiden DBs.

**Migrationsperspektive** (ergänzt `docs/SQL/JTL-CUSTOM-WORKFLOWS.md`): (a) keine Registry → Migrationen sind reine idempotente `CREATE OR ALTER` — ideal für Migrations-Runner; (b) Gültigkeit hängt an JTL-Views/Tabellen = unser Bruchpunkt bei Updates; (c) `DisplayName`/Param-Labels sind Extended Properties, die `_Set*`-Helfer sind idempotent.

## 5. Lizenz / Rechtliches (Stand 1.10.x/2.x)

**Befund (Konfidenz: mittel):**
- Zusätzliche DBs auf derselben Instanz: technisch/lizenzrechtlich unproblematisch (JTL lizenziert die Wawi, nicht SQL-Objekte; Mandanten-Anzahl technisch unbegrenzt).
- Für echte Staging-Umgebungen erwartet JTL ein **separates Kundenkonto** mit (Test-)Lizenzen; **Klonen befreit nicht von Lizenzpflicht** ([Testumgebung](https://guide.jtl-software.com/jtl-kundencenter/jtl-produkte-in-einer-testumgebung-nutzen/)). Missbrauch von Staging-Lizenzen für Produktion → Account-Sperre.
- **Praktisch:** Testklone, die nie live abgleichen (Worker aus, Sync aus), sind geduldeter Rahmen. Lizenz-riskant ist exakt der Moment, den §3 verhindert: ein Klon, der produktiv mit Marktplätzen kommuniziert = faktisch zweite produktive Nutzung derselben Lizenz.
- **Session-Update des Nutzers (2026-07-09):** Staging-Shop-Lizenzen sind eingerichtet und funktionieren („Thema Lizenz funktioniert wunderbar") — der Shop-Repoint aus Commit e6d7b2b läuft mit gültigen Staging-Connector-Keys.

## Konsequenzen für unsere Architektur

1. **Worker-Sichtbarkeit ist das Kernrisiko** — Reset muss Pro-Konto-/Pro-Mandant-Abgleich-Flags hart setzen, nicht nur Credentials leeren (eBay ✅ erledigt, Amazon/`Worker.tTarget` offen).
2. Credential-Invalidierung ≠ Abgleich-Neutralisierung — Lücken §3 schließen.
3. **Queues leeren** als fester Reset-Schritt.
4. **Klon-nach-Update statt Update-des-Klons.**
5. **Collation-Invariante** festschreiben (`Latin1_General_CI_AS` für RoboticoOps + eigene Objekte).
6. Eigene Objekte in eigenen Schemas / eigener Admin-DB; Trigger/Indizes/Spalten auf JTL-`dbo` meiden.
7. Migrationen = idempotente `CREATE OR ALTER` gegen eigenes Schema, re-applizierbar (jeder Restore setzt eazybusiness-Objekte zurück).
8. **Post-Update-Smoke-Test:** `CustomWorkflows.vCustomActionCheck WHERE Status='ERROR'` + Rekompilierbarkeit eigener Objekte/Cross-DB-Views.
9. Signierte SPs / Admin-DB in separater DB = update-sicher; bevorzugter Ort für alles, was nicht zwingend in eazybusiness leben muss.
10. **Lizenz-Leitplanke:** Testklone dürfen nie produktiv mit Marktplätzen kommunizieren — Worker-/Sync-Neutralisierung ist auch Compliance.

## Nur durch Ausprobieren auf vm-sql-test1 klärbar (Probeliste)

- ~~Welche Tabelle/Spalten die Pro-Konto-Abgleich-Flags speichern~~ → **durch Survey beantwortet**: `ebay_user.nGesperrt`, `pf_user.nGesperrt/nAktiv`, `tShop.nGesperrt`, `Worker.tTarget`. Offen: Semantik von `Worker.tTarget.nAbgleichstyp`-Werten.
- **Wie der Worker einen frisch in `tMandant` eingetragenen Klon entdeckt** (sofort? Neustart? liest er tMandant der Haupt-DB oder pro DB?).
- **Wo die Installations-/Seller-GUIDs liegen** und ob ein Klon mit identischer GUID die Produktions-Bindung stört.
- **Ob der WaWi-Client einen rein per SQL angelegten Mandanten klaglos akzeptiert** (Login/Update-Assistent).
- **Ob JTL beim DB-Update etwas in eigenen Schemas anfasst** (echtes Update mit Vorher/Nachher-Objektvergleich).
- **Ob `kMandant`-Vergabe per `MAX+1`** mit JTL-Erwartung kollidiert.
- **Vollständige Queue-Tabellen-Liste** für den Leerungs-Schritt (Survey lieferte Kandidaten + Rowcounts).
