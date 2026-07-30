# Nachtrag 2026-07-30 — Wartungs-Alarmmail trägt jetzt den echten Fehlertext

**Plan:** [mssql-wartung-ola.md](../mssql-wartung-ola.md) · **Betroffene Datei:** `db-migrations/global/sprocs/maint.spRunMaintenanceJob.sql` · **Ebene B (global)** · **test1:** deployt + live geprüft · **vm-sql2/PROD:** nicht angefasst (human-gated).

**In einem Satz:** Der Dispatcher verschickt bei einem Fehler jetzt selbst eine Detail-Mail mit Fehlernummer, Originaltext, Prozedur/Zeile und Registry-Kontext — zusätzlich zur (inhaltsleeren) Agent-Benachrichtigung — und reicht den Originalfehler danach unverändert weiter.

---

## Problem (live festgestellt 2026-07-30)

Die Alarmmails der Wartungsjobs enthielten ausschließlich die generische SQL-Agent-Standardmeldung:

> STATUS: Fehler … Zuletzt wurde Schritt 1 (Dispatch) ausgeführt

Der eigentliche `THROW`-Text unserer Prozeduren — z. B. `51100` von `maint.spCheckBackupChain` mit der Angabe, **welche** Datenbank **wie lange** ohne Backup ist — tauchte darin nie auf. Der Empfänger wusste also, **dass** etwas kaputt ist, aber nicht **was**. Die Information lag nur in der Agent-Job-Historie, also genau dort, wo man erst nachschaut, wenn man weiß, dass es sich lohnt.

Ursache ist keine Fehlkonfiguration: `@notify_email_operator` liefert konstruktionsbedingt nur den Schrittstatus, nicht die Fehlermeldung des Schritts.

## Lösung

`maint.spRunMaintenanceJob` bekommt ein `TRY/CATCH` um den kompletten Dispatch-Block (inkl. Registry-Lesezugriff und `THROW 51120`). Im `CATCH`:

1. **Fehlerfakten sofort sichern** (`ERROR_NUMBER/SEVERITY/STATE/PROCEDURE/LINE/MESSAGE` in Variablen) — alles Weitere ist Best-Effort.
2. **Detail-Mail per `sp_send_dbmail`**, in einem eigenen verschachtelten `TRY/CATCH`; jeder Mailfehler wird verworfen (nur `PRINT`).
3. **`THROW;`** — Originalfehler unverändert, damit die Job-Historie rot bleibt und die Agent-Notification zusätzlich greift. Die Doppel-Mail ist gewollt: die Agent-Mail ist der zustellungssichere Kanal (sie kommt auch dann, wenn die Prozedur gar nicht mailen kann), unsere trägt die Diagnose.

**Empfänger und Profil sind nicht hartkodiert**, sondern werden zur Laufzeit aufgelöst:

| Was | Auflösung | Fallback |
|---|---|---|
| Empfänger | `email_address` des aktivierten Operators `RoboticoOps-Maint` aus `msdb.dbo.sysoperators` (Name = Repo-Policy aus `permissions/260`, dort lebt auch die Adresse) | nicht auflösbar → Mail entfällt |
| Profil | 1. Database-Mail-Profil des Agents (Registry, nur als `sysadmin`, eigener `TRY/CATCH`), 2. Default-Profil (privat vor public), 3. das einzige Profil der Instanz | keins → Mail entfällt |
| Ob überhaupt | `bNotifyOnFail` der Registry-Zeile: `0` unterdrückt die Mail genau wie die Agent-Notification (ein Schalter, beide Kanäle); *keine* Registry-Zeile (`NULL`) mailt — eine verschwundene Zeile ist selbst der Alarm | — |

Neue THROW-Nummer war nicht nötig (der Mailpfad wirft nie).

**Bewusst in Kauf genommene Fehlermodi** (im Prozedur-Header dokumentiert): in einer „doomed transaction" (`XACT_STATE() = -1`) scheitert das Queue-`INSERT` — wir rollen keine fremde Transaktion zurück, nur um eine Mail loszuwerden; ein nicht erreichbarer SMTP-Relay lässt die Mail in `msdb.dbo.sysmail_faileditems` liegen; ein Aufrufer ohne `DatabaseMailUserRole` überspringt still.

## Testprotokoll

Regressionstest: **`db-migrations/tests/global/MaintenanceAlertMail_Tests.sql`** (12 Checks, E2E-Guard im Kopf, selbstaufräumend: legt eigenes Mailprofil + Account an, zeigt die Operator-Adresse temporär auf eine `.invalid`-Domain, stellt alles zurück).

| Check | Inhalt |
|---|---|
| T1a/T1b | Ohne Mailprofil: Originalfehler `51120` + Originaltext kommen unverändert beim Aufrufer an |
| T2 | Ohne Profil wird **keine** Mail erzeugt (stiller Skip) |
| T3a–T3e | Mit Operator + Profil: Fehler `51120` unverändert rethrown **und** Mail in `msdb.dbo.sysmail_allitems` mit Fehlernummer, Originaltext, Job-Key + Server im Betreff |
| T4a/T4b | Echter Dispatch-Fehler (`backup-watchdog` → `THROW 51100`): Fehler unverändert, Body trägt `spCheckBackupChain`-Text, Nummer und Registry-Operation |
| T5 | Erfolgsfall (`cleanup-commandlog`): kein Fehler, keine Mail |
| T6 | `bNotifyOnFail = 0`: Fehler rethrown, keine Mail |

**Läufe** (E2E-Container `robotico-e2e-mssql`, SQL Server 2022 CU26):

- **ROT gegen den ungefixten Stand: 6/12** — genau die fünf Mail-Checks (T3b–T3e, T4b) rot; die Nicht-Regressions-Wächter T1a/T1b/T2/T3a/T4a/T5 waren schon vorher grün und mussten es bleiben. (T6 war noch nicht Teil des Laufs.)
- **GRÜN nach dem Fix: 12/12.**
- **Zusatzprobe zur Rethrow-Mechanik:** verschachteltes `CATCH` (inline **und** in einer gerufenen Prozedur) lässt den Fehlerkontext des äußeren `CATCH` auf SQL Server 2022 unangetastet — `THROW;` liefert weiterhin `51120` + Originaltext. Deshalb bare `THROW;` statt Rethrow mit gemerkten Werten: Letzteres könnte Engine-Fehler < 50000 gar nicht tragen.
- **Stolperstein:** `END CATCH` muss vor einem folgenden `THROW;` mit Semikolon terminiert werden (`END CATCH;`), sonst „Incorrect syntax near 'THROW'" beim Deploy.
- `npm run db:lint`: **0 Fehler**, 2 vorbestehende Warnungen in `reset.spInternal_GrantAccess.sql` (unverändert).

**test1 (`vm-sql-test1`)**, `deploy.ps1 -Scope global -Environment TEST`, danach live:

- `EXEC maint.spRunMaintenanceJob @cJobKey='does-not-exist'` → `Msg 51120` beim Aufrufer, dazu `! … no operator address or no Database-Mail profile resolvable — detail alert skipped`. test1 hat kein Mailprofil → stiller Skip wie erwartet, `sysmail_allitems` bleibt bei 0.
- `EXEC maint.spRunMaintenanceJob @cJobKey='cleanup-commandlog'` → fehlerfrei, keine Mail.

## Was der PROD-Deploy bewirkt

Auf vm-sql2 existiert das Database-Mail-Profil (der Agent mailt darüber), der Operator `RoboticoOps-Maint` zeigt auf `lukas@dattenberger.com`. Nach `deploy.ps1 -Scope global -Environment PROD` erzeugt **jeder fehlgeschlagene Wartungslauf zwei Mails**: die bekannte Agent-Statusmail plus die neue Detailmail. Kein Job-Drop/Recreate, keine Schema-Änderung, keine neue Berechtigung — nur `CREATE OR ALTER` der einen Prozedur (Anytime-Skript, Hash geändert). Zu beachten: der Backup-Watchdog läuft **stündlich**, ein anhaltender Alarm erzeugt also 2 Mails/Stunde statt 1.

### Beispiel-Mailtext (echter Container-Lauf)

Betreff: `[RoboticoOps] Maintenance FAILED: backup-watchdog on <server>`

```
Maintenance job "backup-watchdog" failed on <server> at 2026-07-30 21:11:42 (server local time).

Error   : 51100 (severity 16, state 1)
Source  : RoboticoOps.maint.spCheckBackupChain, line 58
Message : maint.spCheckBackupChain: invalid watch target(s) — no ONLINE database match for:
          eazybusiness. Ola tokens (e.g. USER_DATABASES) are invalid here; the watchdog takes
          a literal comma list.

Registry (RoboticoOps.ops.tMaintenanceJob):
  Job key   : backup-watchdog
  Operation : BackupWatchdog
  Target(s) : eazybusiness,RoboticoOps,msdb
  Agent job : RoboticoOps - Maint - backup-watchdog

Where to look next:
  * Agent job history (step 1 "Dispatch") of the job named above
  * SELECT * FROM RoboticoOps.ops.tMaintenanceJob WHERE cJobKey = N'backup-watchdog';
  * SELECT TOP (50) * FROM RoboticoOps.dbo.CommandLog ORDER BY ID DESC;   -- Ola command log

Sent by maint.spRunMaintenanceJob. The SQL-Agent operator notification for the
same failure arrives separately and carries only the generic step status.
```

**Sprache des Mailtexts: Englisch.** Die zitierten `ERROR_MESSAGE()`-Texte der `maint.*`-Suite sind Englisch; ein deutscher Rahmen um englischen Fehlertext liest sich schlechter als eine durchgehende Sprache.

## Geänderte Dateien

- `db-migrations/global/sprocs/maint.spRunMaintenanceJob.sql` — TRY/CATCH + Alarmmail, Header-Doku
- `db-migrations/tests/global/MaintenanceAlertMail_Tests.sql` *(neu)* — Regressionstest
- `db-migrations/README.md` — §8-Testtabelle um die Zeile `tests/global/*_Tests.sql` ergänzt
