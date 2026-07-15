# QG3 — Security Review: MSSQL-Ops-Infrastruktur

Read-only Sicherheits-Review der `db-migrations/`-Infrastruktur (global/ + eazybusiness/
Ketten, deploy.ps1, mandant.ps1, lib/targets.ps1, tests/validate-rollout.ps1,
tests/docker/). Reviewed gegen den aktuellen Working-Tree-Stand (inkl. der drei
uncommitteten Änderungen: RECOVERY FULL in global/up/0001, MSSQL-OPS-DATA-MODEL.md,
CLAUDE.md-Sektion).

Vorwissen (Clone-Guard-Audit sauber, QG2-Fixes drin) wurde vorausgesetzt und nicht
wiederholt. Fokus: SQL-Injection, Privilege-Escalation über die Signing-/EXECUTE-AS-Kette,
Grant/DENY-Vollständigkeit, Secrets-Hygiene, Cert-/Signing-Robustheit.

## Zusammenfassung

| Severity | Anzahl |
|----------|--------|
| Critical | 0 |
| Important | 2 |
| Minor | 4 |

Kein Critical-Befund. Die Injection-Oberfläche der Reset-Pipeline ist durchgehend sauber
(QUOTENAME für Identifier, `sp_executesql`-Parameter für Werte, Whitelist + CHECK auf
`ops.tResetStep`). Die zwei Important-Befunde betreffen (1) einen Informations-Leak-Pfad,
der das explizite Spalten-DENY auf `cShopLicense` über die Fehlermeldung umgeht, und
(2) Secrets in Prozessargumenten von `mandant.ps1`.

---

## Important-1 — cShopLicense-Leak über Truncation-Fehlermeldung in cErrorMessage

**Datei:** `db-migrations/global/sprocs/reset.spInternal_InvalidateCredentials.sql:70-72`
zusammen mit `reset.spProcessNextResetRequest.sql:152-168` und
`reset.spPub_GetResetStatus.sql:18-33`.

**Szenario:** Die Reset-Pipeline liest `cShopLicense` (`ops.tMandant`, `nvarchar(500)`)
und schreibt sie ins Klon-Ziel:

```sql
UPDATE dbo.tShop SET cServerWeb = @ShopUrl, cAPIKey = @ShopLicense
WHERE nTyp = 0 AND cServerWeb LIKE 'http%';
```

`dbo.tShop.cAPIKey` ist laut JTL-Schema (`A_Context/JTL 1.10.11.0/dbo.tShop.Table.sql:10`)
nur **`nvarchar(64)`**. Ein Shop-Lizenz-/API-Key länger als 64 Zeichen (bei PayPal/Shop-
Keys üblich) löst beim UPDATE einen Truncation-Fehler aus. Auf SQL Server 2019+ (PROD =
2022, TEST/test1 = 2025) enthält die Standard-Fehlermeldung **den abgeschnittenen Wert**:

> `String or binary data would be truncated in table '...', column 'cAPIKey'. Truncated value: '<Lizenz…>'.`

`spInternal_InvalidateCredentials` hat kein eigenes TRY/CATCH → der Fehler propagiert in den
CATCH von `spProcessNextResetRequest`, der `cErrorMessage = ERROR_MESSAGE()` setzt.
`reset.spPub_GetResetStatus` gibt `cErrorMessage` (und `cStepLog`) **an die Rolle
`ops_reset_executor` zurück** — exakt die Rolle, die in `0003_roles.sql:38` per
`DENY SELECT ON ops.tMandant (cShopLicense)` das Lizenzlesen verboten bekommt. Das
Spalten-DENY (laut Kommentar "Reset operators must never see license keys") wird damit
über die Fehlermeldung umgangen. Da `GetResetStatus` ohne Filter alle Requests liefert,
sieht **jeder** Reset-Operator die geleakte Lizenz eines beliebigen Mandanten.

Derselbe Pfad kann grundsätzlich auch `@ShopUrl` (weniger geheim) oder andere
Parameterwerte in `cErrorMessage` durchreichen; die Lizenz ist der sicherheitsrelevante Fall.

**Fix-Vorschlag:**
- Den Shop-Repoint in `spInternal_InvalidateCredentials` in ein eigenes `BEGIN TRY/CATCH`
  legen und im CATCH eine **sanitisierte** Meldung loggen/werfen, die niemals den
  Parameterwert enthält (z. B. nur Tabelle/Spalte + `LEN(@ShopLicense)`), bevor der Fehler
  die Pipeline erreicht.
- Zusätzlich/alternativ Länge vor dem UPDATE prüfen (`IF LEN(@ShopLicense) > 64 THROW …`
  mit generischer Meldung), damit gar kein Truncation-Fehler mit Wert entsteht.
- Defense-in-depth: `cErrorMessage` in `spProcessNextResetRequest` vor dem Persistieren
  gegen die bekannten Secret-Werte des Mandanten (`cShopLicense`) prüfen und ggf.
  redigieren. Das Spalten-DENY allein schützt nicht, solange Fehlertexte ungefiltert an
  die Executor-Rolle zurückgehen.

---

## Important-2 — Shop-Lizenz/-URL als Klartext in Prozessargumenten (mandant.ps1)

**Datei:** `db-migrations/mandant.ps1:127-138`

`mandant.ps1 -Create` baut den EXEC-String inkl. `@ShopLicense = N'…'` / `@ShopUrl = N'…'`
und übergibt ihn an sqlcmd per **`-Q` (Kommandozeilen-Argument)**:

```powershell
$params += "@ShopLicense = N'$(Q $ShopLicense)'"
...
$exec = "SET NOCOUNT ON; EXEC reset.spPub_CreateTestmandant " + ($params -join ', ') + ';'
$result = Invoke-OpsSql $exec -NoHeader   # -> & $sqlcmdPath ... -Q $exec
```

Die Shop-Lizenz ist ein Credential. Als `-Q`-Argument ist sie im Prozess-Table des Hosts
(`ps -ef` / `/proc/<pid>/cmdline`, Windows-Prozessliste) sichtbar, solange sqlcmd läuft,
und landet je nach Shell in der History. `Q()` escapt nur SQL-Quotes (kein
Injection-Problem, `sysname`/`nvarchar`-Parameter), löst aber die Sichtbarkeit nicht.

Auffällig ist die **Inkonsistenz** im selben Repo: `deploy.ps1:181-184` dokumentiert genau
diese Prozessargument-Exposition für das Cert-Passwort ausdrücklich als Gotcha, und
`tests/docker/copy-logins.ps1:184-187` reicht Secrets bewusst über **STDIN** statt argv
durch. `mandant.ps1` nutzt diese Technik nicht und warnt auch nicht.

**Fix-Vorschlag:** Den EXEC über sqlcmd-**STDIN** (Pipe in `& $sqlcmdPath …` ohne `-Q`)
oder eine `-i`-Tempdatei mit `chmod 600` ausführen, analog zu `copy-logins.ps1`.
Mindestens denselben Gotcha-Kommentar wie in `deploy.ps1` ergänzen und auf Single-Operator-
Host hinweisen. Betrifft nur den `-Create`-Pfad mit gesetzter `-ShopLicense`.

---

## Minor-1 — jobstartuser hat instanzweite Agent-Job-Kontrolle (SQLAgentOperatorRole)

**Datei:** `db-migrations/global/up/0010_jobstartuser_login.sql:64-68`

`jobstartuser` ist Mitglied von `SQLAgentOperatorRole` in msdb. Diese Rolle erlaubt
Start/Stop/Enable/Disable **aller** Agent-Jobs der Instanz und Lesen aller Job-Historie —
deutlich mehr als das eine Reset-Job-Start, das gebraucht wird. Der Kommentar begründet
Operator (statt User) korrekt damit, dass der sa-owned Job sonst nicht startbar wäre
(msdb kennt kein per-Job-Start-Grant für Nicht-Owner).

Heute nicht direkt ausnutzbar: der Login ist `DISABLE` + `DENY CONNECT SQL` und nur als
EXECUTE-AS-Ziel zweier signierter, auditierter Procs (`spPub_StartTestmandantReset`,
`spPub_CancelResetRequest`) erreichbar — ein Aufrufer kann nur tun, was der Proc-Körper
tut. **Risiko liegt in der Zukunft:** `900_resign_procedures` signiert *automatisch* jeden
neuen `EXECUTE AS 'jobstartuser'`-Proc; ein künftiger solcher Proc erbt implizit die
instanzweite Agent-Kontrolle. Least-Privilege-Abweichung, Defense-in-depth-Hinweis.

**Fix-Vorschlag:** So belassen ist vertretbar (Design-Trade-off ist dokumentiert), aber
in der ADR/Runbook explizit festhalten, dass jeder neue `EXECUTE AS 'jobstartuser'`-Proc
instanzweite Agent-Rechte erbt und daher review-pflichtig ist. Falls SQL-Server-Version es
zulässt, granularere Rechte statt SQLAgentOperatorRole prüfen.

---

## Minor-2 — copy-logins.ps1 kopiert echte Login-Passwort-Hashes in den Dev-Container

**Datei:** `db-migrations/tests/docker/copy-logins.ps1:100-101,150-152,187`

Das Skript liest `LOGINPROPERTY(name,'PasswordHash')` von der realen Quelle (PROD/test1)
und legt die Logins im Container mit `WITH PASSWORD = <hash> HASHED` an. Die Hashes werden
korrekt über **STDIN** angewendet (nicht auf Disk/argv — sauber). Trotzdem werden reale
Passwort-Hashes aus einer höher eingestuften Umgebung in einen Developer-Edition-Container
mit schwächerem Schutz (sa-Passwort in gitignored `.env.local`, Port auf localhost
veröffentlicht) exportiert. Ein Angreifer mit sysadmin im Container kann die Hashes aus
`sys.sql_logins` lesen und offline knacken.

Begrenzt: Container bindet nur `localhost,14330`, ist ephemer, `.env.local` ist gitignored
und die Hashes gehen nie in git/argv. Aber Hash-Transfer PROD→Dev ist grundsätzlich ein
Credential-Handling-Thema.

**Fix-Vorschlag:** Erwägen, standardmäßig **immer** Zufallspasswörter zu setzen
(SID bleibt für die Orphan-Remap-Tests erhalten — das ist der eigentliche Zweck) und die
Hash-Kopie hinter ein explizites Opt-in-Flag zu legen. Der `sql-random-pw`-Pfad zeigt, dass
SID-Mapping auch ohne echten Hash funktioniert.

---

## Minor-3 — SQL-Auth-Passwort im grate-Connection-String-Argument (E2E)

**Datei:** `db-migrations/deploy.ps1:131,363,367-385`

Für SQL-Auth (nur E2E-Container) baut `deploy.ps1`
`User ID=$sqlUser;Password=$sqlPassword` in `$connectionString` und übergibt es als
`--connectionstring=`-CLI-Argument an grate → im Prozess-Table sichtbar. Betrifft
ausschließlich den `sa`-Login eines ephemeren Wegwerf-Containers (localhost), daher gering.
`$grateArgs` wird korrekt nicht geloggt (nur eine Summary-Zeile). Für TEST/PROD
(Windows/Kerberos, `Trusted_Connection=True`) besteht das Problem nicht.

**Fix-Vorschlag:** Akzeptabel für E2E. Falls SQL-Auth je über den Wegwerf-Container hinaus
genutzt wird, grate-Env-Var- statt CLI-Übergabe des Connection-Strings prüfen.

---

## Minor-4 — PayPal-SPs benötigen OLE Automation Procedures (Ebene A, portiert)

**Datei:** `db-migrations/eazybusiness/sprocs/Robotico.spPaypalCreateAccessToken.sql`,
`Robotico.spPaypalTrackingCallApi.sql` (`sp_OACreate`/`sp_OAMethod`)

Die portierten PayPal-SPs machen HTTP über OLE Automation (`sp_OACreate 'MSXML2.XMLHTTP'`).
Das setzt die instanzweite Option **OLE Automation Procedures = 1** voraus — eine bekannte
Angriffsflächen-Erweiterung (OLE läuft im SQL-Server-Prozesskontext). Kein
Injection-Problem: Credentials kommen aus `Robotico.tPaypalSettings`, keine
Nutzereingabe-Konkatenation, und `@Auth`/Bearer-Token werden bewusst nur unter `@debug`
geprintet (Kommentar bei `spPaypalCreateAccessToken`). Dies ist **vorbestehender**
portierter Code, kein Teil der Ops-Infrastruktur i. e. S.; hier nur zur Vollständigkeit.

**Fix-Vorschlag:** Kein Handlungsbedarf im Rahmen dieses Reviews. Grundsätzlich beim
Enablen von OLE Automation die Ausführung dieser SPs auf einen dedizierten,
least-privilege-Kontext beschränken und die Option nur dort aktiv halten, wo nötig.

---

## Explizit geprüft und sauber

- **Injection in der Reset-Pipeline:** `spProcessNextResetRequest` führt Step-Procs nur über
  `EXEC (N'reset.' + QUOTENAME(@stepProc))` nach einer Katalog-Whitelist
  (`schema_id = SCHEMA_ID('reset')` + `name LIKE 'spInternal[_]%'`) aus; `ops.tResetStep`
  hat zusätzlich `CK_tResetStep_cProcName`. Table-Daten können weder injizieren noch
  beliebigen Code ausführen. `@TargetDb`/`@MandantKey`/Pfade gehen durchgängig via
  `QUOTENAME` (Identifier) bzw. `sp_executesql`-Parameter (Werte). Kein ausnutzbarer Pfad.
- **`spInternal_CloneDatabase`:** MOVE-Liste aus `sys.master_files` + `QUOTENAME(…,'''')`,
  `@BackupFile` als Parameter, `@TargetDb`-Guards gegen `eazybusiness`/Source==Target.
- **Signing-Kette:** `jobstartuser` disabled + DENY CONNECT SQL; nur EXECUTE-AS-Ziel.
  `RoboticoOpsSigningLogin` FROM CERTIFICATE + AUTHENTICATE SERVER ist der Standard-
  Module-Signing-Pfad; Public-Key via `CERTENCODED()` ohne Disk-Roundtrip. `900_resign`
  ist katalog-getrieben und hard-failt bei unsigniertem EXECUTE-AS-Proc.
- **Grant/DENY:** `ops_reset_executor` erhält **nur** EXECUTE auf die vier Pub-Procs — kein
  direktes SELECT auf `ops.tMandant`. `cShopUrl` ist daher nicht exponiert; die Pub-Procs
  selektieren keine Secret-Spalten. Purge/Create sind admin-only. (Einzige Lücke: der
  cErrorMessage-Pfad, Important-1.)
- **Cert-Passwort-Store (deploy.ps1 3-Tier):** Tier-3-Auto-Generate ist hart gegen ein
  bereits existierendes Zertifikat geguarded (kein blindes Neu-Minten); Single-Quote-Reject
  vor grate; `chmod 600` auf den Linux-Store. Robuste Store-Rewrite-Logik gegen den
  2026-07-13-Korruptionsbug.
- **`.env.local`** ist per `.gitignore` ausgeschlossen und nicht getrackt (verifiziert).
- **`ORIGINAL_LOGIN()`/@caller** wird nur in String-Spalten-Zuweisungen genutzt, nie in
  dynamischem SQL.
- Die uncommittete **RECOVERY FULL**-Änderung (0001) ist sicherheitsneutral.
