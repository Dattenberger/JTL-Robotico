---
name: module-signing-agent-job
description: Sicherheitsarchitektur signierte SP → Agent-Job für den Testmandanten-Reset (Web-Research, 2026-07-09)
status: Research
---

# SQL-Server-Sicherheitsarchitektur: Signierte SP → Agent-Job für Testmandanten-Reset

> Quelle: Opus-Research-Agent „research-signing-jobs", Session 2026-07-09. Web-Recherche mit Primärquellen (inline verlinkt).

Kernaussage vorab: Trenne die zwei Sicherheitsprobleme sauber. (A) Der Kollege ohne Rechte soll den Reset **auslösen** dürfen → das löst Module Signing auf der SP. (B) Der Job muss BACKUP/RESTORE/`xp_create_subdir`/`ALTER AUTHORIZATION` **ausführen** → das löst am einfachsten der **Job-Owner = sysadmin** (kein Module Signing im Job nötig). Für die Übergabe SP→Job das **Queue-Tabellen-Pattern**, nicht das dynamische Umschreiben von Job-Steps.

## 1. Signierte SP → `sp_start_job`: exakte Rechte + sauberer Weg

**Rechteregeln von `sp_start_job`** ([MS Learn](https://learn.microsoft.com/en-us/sql/relational-databases/system-stored-procedures/sp-start-job-transact-sql)): `SQLAgentUserRole`/`SQLAgentReaderRole` dürfen **nur eigene Jobs** starten (Job-Owner = der Login); `SQLAgentOperatorRole` darf **alle lokalen Jobs** starten; nur `sysadmin` darf alles inkl. Multiserver. Ein Nicht-sysadmin, der einen *fremden* Job starten soll, braucht also `SQLAgentOperatorRole`.

**Empfehlung — Hybrid aus Zertifikat + Impersonation** (Sommarskogs ausdrückliche Empfehlung, [grantperm-appendix #startjobs](https://www.sommarskog.se/grantperm-appendix.html#startjobs)). Nicht der reine Zertifikatsweg (siehe Fallstrick). Aufbau:

1. Dedizierter Proxy-Login in `master`, deaktiviert, kein interaktiver Login:
   ```sql
   CREATE LOGIN jobstartuser WITH PASSWORD = '<random-guid>';
   ALTER LOGIN jobstartuser DISABLE;
   DENY CONNECT SQL TO jobstartuser;
   ```
2. In `msdb` als User anlegen, minimale Rechte:
   ```sql
   USE msdb;
   CREATE USER jobstartuser FROM LOGIN jobstartuser;
   GRANT EXECUTE ON dbo.sp_start_job TO jobstartuser;
   ALTER ROLE SQLAgentOperatorRole ADD MEMBER jobstartuser;
   ```
3. Zertifikat in `msdb` erzeugen, mit Private Key in die Ops-DB exportieren (`certencoded`/`certprivatekey` → `CREATE CERTIFICATE ... FROM BINARY ... WITH PRIVATE KEY`).
4. Signierte SP in der Ops-DB mit `WITH EXECUTE AS 'jobstartuser'`, danach mit dem Zertifikat signieren:
   ```sql
   CREATE PROCEDURE reset.StartResetJob WITH EXECUTE AS 'jobstartuser' AS
     EXEC msdb.dbo.sp_start_job @job_name = N'TestMandant_Reset';
   ADD SIGNATURE TO reset.StartResetJob BY CERTIFICATE [SIGN_ResetJob] WITH PASSWORD = '<certpwd>';
   ```

**Warum Hybrid und nicht rein-Zertifikat:** Bei reinem Zertifikat müssten `sp_start_job`, `sp_verify_job_identifiers` **und** `sp_sqlagent_notify` in `msdb` gegensigniert werden (`ADD COUNTER SIGNATURE`), weil `sp_start_job` intern weitere Prozeduren aufruft. Der `EXECUTE AS 'jobstartuser'`-Kontext lässt die internen Rechteprüfungen gegen einen echten privilegierten Principal laufen → **keine Gegensignaturen nötig**. Das Zertifikat trägt nur die DB-übergreifende Authentifizierung, sodass **kein `TRUSTWORTHY`** nötig ist.

**Fallstricke:**
- Gegensignaturen auf `msdb`-Systemprozeduren gehen bei **jedem Service Pack / CU verloren** ([MS Q&A](https://learn.microsoft.com/en-us/answers/questions/146608/execute-sp-start-job-using-certificate)) — deshalb der Hybrid, der sie vermeidet.
- `EXECUTE AS`+`sp_start_job`: der Job erscheint in `sysjobhistory` als von `jobstartuser` gestartet → für Audit muss der echte Aufrufer separat protokolliert werden (siehe §6, `ORIGINAL_LOGIN()`).
- **Leaner-Alternative zu `SQLAgentOperatorRole`:** `jobstartuser` als **Owner des Reset-Jobs** → `SQLAgentUserRole` genügt (least privilege). Kollidiert aber mit „Job-Owner = sysadmin" aus §3 → Entscheidung: sysadmin-Owner (vom Nutzer bestätigt), also `SQLAgentOperatorRole`.

## 2. Parameterübergabe an den Agent-Job

Agent-Jobs nehmen **keine Aufrufparameter**. Optionen:

- **Queue-/Request-Tabelle (Empfehlung, vom Nutzer bestätigt):** SP validiert Eingaben, schreibt Request-Zeile (Zielmandant, Anforderer, Zeitstempel, Status `queued`) in die Admin-DB, **dann** `sp_start_job`. Der Job liest die nächste offene Zeile. Robust, trivial zu debuggen (die Tabelle ist der State), gut auditierbar.
- **`sp_update_jobstep` dynamisch umschreiben — Anti-Pattern.** Race Conditions bei parallelen Requests, keine Historie, schwer zu testen.
- **Service Broker mit Internal Activation** ([SQLPerformance](https://sqlperformance.com/2014/03/sql-performance/intro-to-service-broker), [MS Learn](https://learn.microsoft.com/en-us/sql/database-engine/service-broker/creating-service-broker-queues)): technisch die „seriösere" asynchrone Lösung, aber deutlich mehr bewegliche Teile (Queue/Service/Contract/Message-Type, Activation-Debugging, Poison-Message-Handling). Für ein kleines Team und einen seltenen, bewusst **seriell** laufenden Reset overkill.

## 3. Ausführungskontext des Job-Steps (der wichtigste Vereinfacher)

Für einen **T-SQL-Job-Step** ([MS Learn, Manage Job Steps](https://learn.microsoft.com/en-us/ssms/agent/manage-job-steps)): der Step läuft als **Job-Owner** via `EXECUTE AS` — **außer** der Job-Owner ist Mitglied von `sysadmin`, dann läuft der Step als **SQL-Server-Agent-Dienstkonto** (üblicherweise selbst sysadmin).

**Empfehlung (vom Nutzer bestätigt):** Reset-Job **einem sysadmin-Login zuweisen**. Dann funktionieren `BACKUP`/`RESTORE`/`xp_create_subdir`/`ALTER AUTHORIZATION` **ohne jegliches Module Signing im Job** — deutlich wartungsärmer als granulare Grants oder Signaturen im Job.

**Fallstricke:**
- Ein **Proxy/Credential** ist nur für Nicht-T-SQL-Subsysteme nötig (CmdExec, PowerShell, SSIS). Bleibt alles T-SQL → **kein Proxy nötig**. `xp_create_subdir` läuft im Kontext des **Agent-Dienstkontos** — dieses Windows-Konto braucht NTFS-Schreibrechte auf dem Backup-Zielpfad (verifizieren!).
- Konsequenz für §1: Weil der Job *fremd* (sysadmin) owned ist, muss `jobstartuser` in `SQLAgentOperatorRole` sein.

## 4. Module-Signing-Mechanik über DB-Grenzen

([Sommarskog grantperm](https://www.sommarskog.se/grantperm.html), [SQLSkills](https://www.sqlskills.com/blogs/jonathan/certificate-signing-stored-procedures-in-multiple-databases/))

- **Server-Level-Grant-Rezept:** Zertifikat in Ops-DB erstellen → SP signieren → Private Key aus Zertifikat droppen → Zertifikat (nur Public Key) nach `master` kopieren → dort `CREATE LOGIN ... FROM CERTIFICATE` → granularen Server-Grant an Cert-Login. Zertifikat liegt in **beiden** DBs (Ops-DB zum Signieren, `master` für Login+Grant).
- **Granular statt sysadmin/dbcreator:** Gezielte Grants wie `CREATE ANY DATABASE`, `ALTER ANY DATABASE`, `VIEW SERVER STATE` möglich. Für den Reset-Job nicht nötig (sysadmin-Owner-Weg); Module Signing nur für die *auslösende* SP.
- **`ALTER PROCEDURE` entfernt die Signatur** — „If the procedure is changed, the signature is removed and the procedure must be signed anew." → **Re-Signing muss fester Bestandteil des Deployments sein.** Nützlicher Nebeneffekt: Niemand ändert die privilegierte SP unbemerkt, ohne dass die Rechte wegfallen.
- **Geschachtelte SPs:** Countersignatures nötig, wenn interne Prüfungen den Cert-Login sehen müssen — der Grund, warum der reine Zertifikatsweg bei `sp_start_job` scheitert und der Hybrid vorzuziehen ist.
- **`TRUSTWORTHY` vermeiden:** `EXECUTE AS` für Server-Rechte würde `TRUSTWORTHY ON` verlangen → DB-weiter Privilege-Escalation-Vektor (jeder db_owner kann server-weit eskalieren). Zertifikatssignatur ist der explizit auditierbare, DB-gebundene Ersatz. **`TRUSTWORTHY` bleibt überall OFF.**

## 5. Nach dem Restore — Best-Practice-Reihenfolge

1. **DB-Owner setzen:** `ALTER AUTHORIZATION ON DATABASE::[Zielmandant] TO [sa]` (oder dediziertes Service-Konto). Das restaurierte Backup bringt den alten Owner-SID mit ([MS Learn, Orphaned Users](https://learn.microsoft.com/en-us/sql/sql-server/failover-clusters/troubleshoot-orphaned-users-sql-server)).
2. **Verwaiste User remappen** — modern mit `ALTER USER [x] WITH LOGIN = [x]`, **nicht** das deprecatete `sp_change_users_login`.
3. **Nicht mehr gewünschte/geerbte DB-User bereinigen** (`DROP USER`).
4. **`TRUSTWORTHY` explizit OFF prüfen** — ein RESTORE kann die Eigenschaft aus dem Backup mitbringen.
5. Danach Grants/Registry-Einträge/JTL-Nacharbeiten.

Merksatz: **erst Owner, dann User-Remap, dann Cleanup, dann `TRUSTWORTHY OFF` verifizieren, dann Grants.**

## 6. Audit/Status-Pattern

**Minimalschema — eine Request/Run-Tabelle** in der Admin-DB (Queue + Log in einem):

| Spalte | Zweck |
|---|---|
| `RequestId` (PK, IDENTITY/GUID) | eindeutige Anforderung |
| `TargetMandant` | Was |
| `RequestedBy` = `ORIGINAL_LOGIN()` | **echter** Aufrufer (nicht `jobstartuser`!) |
| `RequestedAt` / `StartedAt` / `FinishedAt` | Wann |
| `Status` | State Machine: `queued → running → succeeded / failed` |
| `ErrorText` | Fehlermeldung bei `failed` |

- **Audit:** In der signierten SP `ORIGINAL_LOGIN()` protokollieren (nicht `SUSER_SNAME()`/`USER_NAME()`), sonst steht durch `EXECUTE AS` überall `jobstartuser`.
- **State-Machine:** SP schreibt `queued`; der Job setzt beim Aufnehmen `running` (+`StartedAt`), am Ende `succeeded`/`failed` (+`FinishedAt`/`ErrorText`) via `TRY…CATCH`.
- **Nebenläufigkeit/Dedup:** `sp_getapplock` (Exclusive, Ressource `'reset:' + @TargetMandant`) in der SP ([mssqltips](https://www.mssqltips.com/sqlservertip/3202/prevent-multiple-users-from-running-the-same-sql-server-stored-procedure-at-the-same-time/)) + gefilterter Unique-Index auf `TargetMandant WHERE Status IN ('queued','running')` als deklarative Absicherung.

## Empfohlener Gesamtablauf (Sequenz)

1. Kollege ruft `EXEC reset.StartResetJob @TargetMandant = N'…'` — hat nur `EXECUTE` auf diese SP.
2. SP nimmt `sp_getapplock`; prüft Eingaben gegen die Admin-DB; lehnt ab, falls bereits `queued`/`running`.
3. SP schreibt Request-Zeile (`queued`, `RequestedBy=ORIGINAL_LOGIN()`, `RequestedAt=SYSDATETIME()`).
4. SP (`WITH EXECUTE AS 'jobstartuser'` + Zertifikatssignatur) ruft `msdb.dbo.sp_start_job @job_name='TestMandant_Reset'`; gibt `RequestId` zurück.
5. Agent-Job (Owner = sysadmin → Step läuft als Agent-Dienstkonto) nimmt die älteste `queued`-Zeile, setzt `running`.
6. Job in `TRY…CATCH`: `xp_create_subdir` → `BACKUP`/`RESTORE` → `ALTER AUTHORIZATION` → `ALTER USER … WITH LOGIN` → User-Cleanup → `TRUSTWORTHY OFF` verifizieren → Grants/Registry/JTL-Nacharbeiten. **Zur Verteidigung in der Tiefe validiert der Job die Request-Zeile selbst nochmals gegen die Registry (Zielname ≠ eazybusiness, in Registry vorhanden).**
7. Erfolg → `succeeded`; Fehler → CATCH schreibt `failed` + `ErrorText`.
8. Kollege liest Status über signierte Status-SP (Entscheidung des Nutzers; reine Lese-SP auf die eigene DB braucht keine Signatur, nur EXECUTE-Grant).

**Deployment-Regel:** Nach jedem `ALTER`/Redeploy der signierten SP → **neu signieren**. Nach jedem SQL-Server-CU → Cert-Setups gegenchecken (beim Hybrid entfällt das Gegensignatur-Risiko).

## Getroffene Entscheidungen (Nutzer, 2026-07-09)

1. **Job-Owner: sysadmin** (statt least-privilege-Konstruktion).
2. **Parameterübergabe: Request-Tabelle** (kein Service Broker).
3. **Status-Rückkanal: signierte Status-SP** (kein SELECT-Grant).
4. Offen bleibt operativ: Agent-Dienstkonto-NTFS-Rechte auf Backup-Zielpfad verifizieren; Zertifikats-Passwort-Handling im Deployment (gehört in `~/.claude-secrets.md`, nie in eingecheckte SQL-Dateien); Backup-Quelle (fixes „Golden"-Backup vs. frisch von Referenz-DB).

**Quellen:** [Sommarskog – Packaging Permissions](https://www.sommarskog.se/grantperm.html) · [Appendix #startjobs](https://www.sommarskog.se/grantperm-appendix.html#startjobs) · [MS Learn – sp_start_job](https://learn.microsoft.com/en-us/sql/relational-databases/system-stored-procedures/sp-start-job-transact-sql) · [MS Q&A – sp_start_job via Certificate](https://learn.microsoft.com/en-us/answers/questions/146608/execute-sp-start-job-using-certificate) · [MS Learn – Manage Job Steps](https://learn.microsoft.com/en-us/ssms/agent/manage-job-steps) · [SQLSkills – Cert Signing Multiple DBs](https://www.sqlskills.com/blogs/jonathan/certificate-signing-stored-procedures-in-multiple-databases/) · [MS Learn – Orphaned Users](https://learn.microsoft.com/en-us/sql/sql-server/failover-clusters/troubleshoot-orphaned-users-sql-server) · [SQLPerformance – Service Broker](https://sqlperformance.com/2014/03/sql-performance/intro-to-service-broker) · [mssqltips – Prevent concurrent SP execution](https://www.mssqltips.com/sqlservertip/3202/prevent-multiple-users-from-running-the-same-sql-server-stored-procedure-at-the-same-time/)
