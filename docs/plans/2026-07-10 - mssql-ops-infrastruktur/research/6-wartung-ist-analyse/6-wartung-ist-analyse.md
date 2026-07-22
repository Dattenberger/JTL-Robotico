---
date: 2026-07-21
author: Lukas + Claude Code
status: Research
context: Live-IST-Analyse der SQL-Server-Wartung auf vm-sql2 (PROD) — was von Ola Hallengren installiert ist vs. was tatsächlich läuft, als Grundlage für eine nachhaltige, versionierte Wartungsinfrastruktur.
related-plan: ../../mssql-ops-infrastruktur.md
related-adrs: —
---

Diese Research-Datei hält den **tatsächlichen** Wartungszustand der Produktions-Instanz `vm-sql2` fest — read-only live erhoben am 2026-07-21. Sie korrigiert die Aussage aus [`2-instanz-survey`](../2-instanz-survey/2-instanz-survey.md) §4 („Prod hat eine funktionierende Backup-Kette / 11 Ola-Hallengren-Jobs"), die **Job-Existenz mit Job-Ausführung verwechselt** hat. Sie beschreibt den IST-Zustand und die daraus folgenden Konsequenzen fürs Zielbild — das konkrete Zielbild (Maintenance-as-Code in RoboticoOps) gehört in einen ADR + Umsetzungsplan, nicht hierher.

## 1. Vision and Motivation

### 1.1 Warum diese Analyse existiert

Die Frage „Sollen wir Reindizierung/CHECKDB als regelmäßige Jobs aufsetzen?" (aus einer Parallel-Session) setzte voraus, dass auf Prod noch keine Wartung existiert. Der Instanz-Survey behauptete das Gegenteil („11 Ola-Hallengren-Jobs, funktionierende Backup-Kette"). **Beide Annahmen sind teilweise falsch** — und der Unterschied entscheidet, ob wir etwas *neu bauen* oder etwas *bestehendes reparieren und in unsere Infrastruktur heben*. Diese Datei stellt den verifizierten IST-Zustand her.

### 1.2 Welches Problem das löst

- Verhindert, dass wir auf Basis der falschen Survey-Zeile planen (etwas neu bauen, das teilweise existiert — oder annehmen, etwas laufe, das seit Monaten fehlschlägt).
- Macht die **stille Wartungslücke** sichtbar: ein täglich fehlschlagender Job, den seit ~8 Monaten niemand bemerkt hat, und eine Integritätsprüfung, die seit ~2 Jahren nicht lief.
- Liefert die Messdaten (Fragmentierung, DB-Größen, Recovery-Modelle), auf denen die Schwellen- und Scope-Entscheidungen des Zielbilds fundiert getroffen werden können.

### 1.3 Verworfene Deutungen

- **„Prod läuft 11 Ola-Jobs" (Survey §4)** — verworfen: zählt Einträge in `msdb.dbo.sysjobs`, nicht Schedules/Historie. Von 11 Jobs hat genau **einer** einen Schedule, und der schlägt fehl.
- **„Die Ola-Tools sind hinterlegt, werden aber noch nicht genutzt" (Lukas' Vermutung)** — fast korrekt: sie sind hinterlegt und *ein* Job ist sogar geplant — er ist nur seit ~2025-11-27 kaputt. Präziser: hinterlegt, überwiegend ungenutzt, der eine genutzte Teil defekt.

## 2. Findings + Conclusions

Nummerierte Kernbefunde (Belege in §3.2):

1. **F1 — Backups sind gesund, aber NICHT über Ola.** Die Sicherungskette läuft extern (CBB): `eazybusiness` Full täglich 03:00, Diff, T-Log alle ~15 min (letztes T-Log 2026-07-21 11:45). Die Ola-`DatabaseBackup`-Jobs haben **keinen Schedule** und sind **nie gelaufen**. → Backups sind **keine** Lücke.
2. **F2 — Indexpflege ist defekt.** `IndexOptimize - USER_DATABASES` ist als einziger Wartungsjob täglich (04:00) geplant, **schlägt aber seit ~2025-11-27 jeden Tag fehl** mit `Fehler 2812: gespeicherte Prozedur "dbo.IndexOptimize" wurde nicht gefunden`. Die Prozedur existiert **nirgends auf der Instanz** mehr.
3. **F3 — CHECKDB läuft praktisch nie.** `DatabaseIntegrityCheck` (Proc + Jobs) ist installiert, aber **ohne Schedule**. Letzter tatsächlicher Lauf: **2024-06-24** (ein einziges Mal, vermutlich Install-Test). System-DBs (inkl. `msdb` — Heimat unserer Job-/Signatur-Infrastruktur): **nie**. → ~2 Jahre ohne Konsistenzprüfung.
4. **F4 — Cleanups laufen nie.** `CommandLog Cleanup`, `Output File Cleanup`, `sp_delete_backuphistory`, `sp_purge_jobhistory`: alle ungeplant, nie gelaufen.
5. **F5 — Falscher Installationsort ist die wahrscheinliche Ursache von F2.** Die Ola-Objekte liegen in **`eazybusiness.dbo`** (JTL-Vendor-DB), nicht in einer dedizierten Ops-DB. Ein DB-Refresh / (Teil-)Reinstall um den 27.11.2025 hat `IndexOptimize` + `CommandExecute` mitgerissen; `CommandLog`/`DatabaseBackup`/`DatabaseIntegrityCheck` blieben zurück. Objekte in der Vendor-DB sind durch Vendor-Vorgänge zerstörbar.
6. **F6 — Keine Fehler-Alarmierung.** Kein Operator/Database-Mail an den Jobs → der tägliche Fehlschlag aus F2 blieb ~8 Monate unbemerkt. Deckt sich mit der offenen OPS-4-Lücke (`NotifyOperator`) der Reset-Infrastruktur.
7. **F7 — Indexpflege ist hier ohnehin Low-ROI.** `eazybusiness` (22,8 GB) hat **keinen** Index >30 % Fragmentierung (>1.000 Seiten): 92 Indizes 5–30 % (5,8 GB), 48 <5 % (4,8 GB) — und das **nach** ~8 Monaten ohne Indexpflege. Der eigentliche Hebel sind **CHECKDB + Statistiken**, nicht Defragmentierung.
8. **F8 — Selbst die (defekte) Indexpflege pflegte keine Statistiken.** Der Job-Step ruft `IndexOptimize @Databases='USER_DATABASES', @LogToTable='Y'` ohne `@UpdateStatistics` → Statistik-Update war nie Teil des Laufs.
9. **F9 — RoboticoOps existiert auf Prod (noch) nicht.** Die Ops-DB ist nur auf test1. „Wartung in RoboticoOps" setzt den globalen Prod-Cutover voraus — derselbe Meilenstein, den die gesamte Ops-Infrastruktur ohnehin braucht.

**Schlussfolgerung:** Der Survey-Satz „funktionierende Wartung" ist für alles außer den (externen) Backups falsch. Wirksame Wartung auf vm-sql2 besteht heute aus **nichts** — ein Job scheitert täglich, CHECKDB schweigt seit zwei Jahren, und niemand wird alarmiert. Die drei zu behebenden Grundfehler: **falscher Ort** (Vendor-DB), **unversioniert/nicht reproduzierbar** (Klick-Ops), **keine Alarmierung**.

## 3. Body

### 3.1 Methodik

Alle Abfragen read-only, nur Metadaten, gegen `vm-sql2.zdbikes.local` über Kerberos-ODBC-sqlcmd (`/opt/mssql-tools18/bin/sqlcmd -E -C`), am 2026-07-21. Keine Nutzdaten gelesen, keine Änderungen. Geprüfte Quellen: `sys.dm_server_services`, `msdb.dbo.sysjobs` / `sysjobsteps` / `sysjobschedules` / `sysschedules` / `sysjobhistory`, `sys.databases` / `sys.master_files`, `<db>.sys.objects`, `msdb.dbo.backupset`, `sys.dm_db_index_physical_stats(..., 'LIMITED')`, `eazybusiness.dbo.CommandLog`.

Reproduktion (Beispiel — Job-/Schedule-Status):

```sql
SELECT j.name, j.enabled, s.name AS schedule, s.enabled AS sch_on
FROM msdb.dbo.sysjobs j
LEFT JOIN msdb.dbo.sysjobschedules js ON j.job_id = js.job_id
LEFT JOIN msdb.dbo.sysschedules   s  ON js.schedule_id = s.schedule_id
ORDER BY j.name;
```

### 3.2 Daten

**Instanz:** `VM-SQL2`, SQL Server 2022 `16.0.4225.2`, **Standard Edition**. SQL-Server-Agent: **Running / Automatic**.

**Agent-Jobs — Schedule + tatsächliche Ausführung:**

| Job | enabled | Schedule | Letzter Lauf | Ausgang |
|---|:---:|---|---|---|
| `IndexOptimize - USER_DATABASES` | 1 | **täglich 04:00** | 2026-07-21 04:00 | ❌ **Fehler 2812** (täglich) |
| `DatabaseIntegrityCheck - USER_DATABASES` | 1 | — keine — | 2024-06-24 (1×) | (einmalig) |
| `DatabaseIntegrityCheck - SYSTEM_DATABASES` | 1 | — keine — | nie | — |
| `DatabaseBackup - USER_DATABASES - FULL/DIFF/LOG` | 1 | — keine — | nie | — |
| `DatabaseBackup - SYSTEM_DATABASES - FULL` | 1 | — keine — | nie | — |
| `CommandLog Cleanup` | 1 | — keine — | nie | — |
| `Output File Cleanup` | 1 | — keine — | nie | — |
| `sp_delete_backuphistory` / `sp_purge_jobhistory` | 1 | — keine — | nie | — |
| `syspolicy_purge_history` (System) | 1 | täglich 02:00 | 2026-07-21 02:00 | ✅ |

> [!CAUTION]
> `IndexOptimize` läuft täglich ins Leere. Vollständige Meldung des letzten Laufs:
> `Ausgeführt als Benutzer: 'NT SERVICE\SQLSERVERAGENT'. Die gespeicherte Prozedur "dbo.IndexOptimize" wurde nicht gefunden. [SQLSTATE 42000] (Fehler 2812). Fehler bei Schritt.`
> Instanzweite Gegenprobe (alle DBs): `IndexOptimize` und `CommandExecute` existieren **nirgends**.

**Ola-Objekte (Ist-Bestand in `eazybusiness.dbo`, `create_date 2024-06-24`):**

| Objekt | Typ | vorhanden? |
|---|---|:---:|
| `CommandLog` | Tabelle | ✅ |
| `DatabaseBackup` | Proc | ✅ |
| `DatabaseIntegrityCheck` | Proc | ✅ |
| `IndexOptimize` | Proc | ❌ **fehlt** |
| `CommandExecute` | Proc | ❌ **fehlt** (von IndexOptimize benötigt) |

`CommandLog`: 9.218 Zeilen, ältester Eintrag 2024-06-24, **jüngster Eintrag 2025-11-27 04:01** → seit diesem Datum keine protokollierte Ola-Operation mehr (deckt sich mit dem Verschwinden von `IndexOptimize`).

**Backup-Realität `eazybusiness` (letzte 14 Tage, extern via CBB):**

| Typ | Letzte Sicherung | Anzahl/14 T |
|---|---|---:|
| D (Full) | 2026-07-21 03:00 | 41 |
| I (Diff) | 2026-07-21 09:00 | 140 |
| L (Log) | 2026-07-21 11:45 | 881 (~alle 15 min) |

**DB-Inventar (User-DBs, `USER_DATABASES`-Scope):**

| DB | Recovery | Größe (MB) |
|---|---|---:|
| `eazybusiness` | FULL | 22.800,8 |
| `eazybusiness_tm2` / `_tm3` / `_tm4` | SIMPLE | 20.100 / 16.100 / 16.100 |
| `EKL` / `EKL_preRebuild` | FULL | 1.552 / 272 |
| `ersatzteile_prod` / `_latest` | FULL | 1.424 / 6.480 |
| `ersatzteile_prod_old_bis_2026_…` | SIMPLE | 912 |
| `HbDat001` | FULL | 1.616 |

**`RoboticoOps`:** auf vm-sql2 **nicht vorhanden** (nur test1).

**Fragmentierung `eazybusiness` (`sys.dm_db_index_physical_stats` LIMITED, >1.000 Seiten, `index_id>0`):**

| Fragmentierung | Indizes | Datenvolumen |
|---|---:|---:|
| > 30 % | **0** | — |
| 5–30 % | 92 | 5.783 MB |
| < 5 % | 48 | 4.773 MB |

**Job-Owner:** alle Wartungsjobs `sa`.

### 3.3 Konsequenzen fürs Zielbild (Kurz — Detail in ADR/Plan)

- **Ort:** Ola-Objekte gehören in **`RoboticoOps`** (Ebene B), nicht in `eazybusiness` (F5). Setzt Prod-Cutover von RoboticoOps voraus (F9) — selber Meilenstein wie der Rest der Ops-Kette.
- **Reproduzierbarkeit:** Ola als **gepinnte Vendor-Version im `up/`-Script**; Jobs idempotent per Migration (`spEnsureMaintenanceJobs` analog `reset.spEnsureAgentJob`), **mit Schedule**.
- **Parameter:** CHECKDB wöchentlich für User **und System** (F3); IndexOptimize schwellenbasiert **inkl. `@UpdateStatistics='ALL'`** (F7/F8) — wöchentlich reicht, Statistiken sind der Hebel; Cleanups aktivieren (F4).
- **Alarmierung:** Fehlschlag-Mail über die bereits verdrahtete `NotifyOperator`/Database-Mail-Schiene (F6).
- **Scope:** `RoboticoOps` selbst in Backup + CHECKDB aufnehmen (hält Config + Secrets). Bewusst entscheiden, ob die `_tm*`-Klone in den CHECKDB-Scope sollen.

## 4. Information Gaps

1. **Ola-Version** — aus den vorhandenen Objekten nicht ausgelesen (Versionsstring nicht am erwarteten Ort; `IndexOptimize` als üblicher Träger fehlt). *Owner:* Umsetzungsplan — wir pinnen ohnehin eine eigene vendored Version, daher unkritisch.
2. **Root-Cause des 2025-11-27-Bruchs** — „DB-Refresh/Teil-Reinstall" ist die plausibelste Erklärung, aber nicht bewiesen (kein Change-Log geprüft). *Owner:* optional; für die Lösung irrelevant, da der neue Ort (RoboticoOps) das Wiederauftreten strukturell verhindert. *Fallback:* als Hypothese markiert.
3. **`ersatzteile_prod*` / `HbDat001` / `EKL` Wartungsanspruch** — diese Fremd-DBs fielen bisher nicht in unseren Scope; ob sie mitgewartet werden sollen, ist eine Produkt-/Ownership-Frage. *Owner:* Lukas. *Fallback:* Zielbild startet mit `eazybusiness` + `RoboticoOps` + System-DBs.

## 5. Change History

### 2026-07-21 — Erstfassung

- **Trigger:** Lukas' Zweifel an der Aussage „Prod läuft Ola-Hallengren-Jobs" (Session mssql-ops-infrastruktur).
- **Reasoning:** Live-read-only-Erhebung gegen vm-sql2 zeigte, dass Job-Existenz ≠ -Ausführung; ein täglich fehlschlagender IndexOptimize + seit 2024 kein CHECKDB.
- **What changed:** Neue Research-Datei; korrigiert [`2-instanz-survey`](../2-instanz-survey/2-instanz-survey.md) §4/§4-Fazit.

## 6. References

- Plan: [`mssql-ops-infrastruktur.md`](../../mssql-ops-infrastruktur.md)
- Korrigiert: [`2-instanz-survey/2-instanz-survey.md`](../2-instanz-survey/2-instanz-survey.md) §4 (SQL Agent)
- Verwandt: [`3-module-signing-agent-job`](../3-module-signing-agent-job/3-module-signing-agent-job.md) (Muster für signierte, sa-owned Agent-Jobs — Vorbild für `spEnsureMaintenanceJobs`)
- OPS-4 / `NotifyOperator`: `db-migrations/README.md` §Config; `db-migrations/global/runAfterOtherAnyTimeScripts/reset.spEnsureAgentJob.sql`
- Ola Hallengren Maintenance Solution: https://ola.hallengren.com/
