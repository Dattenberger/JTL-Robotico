# Clone-Guard-Audit — Testmandant-Reset-Pipeline

**Datum:** 2026-07-15
**Scope:** `db-migrations/global/sprocs/` (17 SPs), `runAfterOtherAnyTimeScripts/reset.spEnsureAgentJob.sql`, `mandant.ps1`, relevante `up/`-Skripte (0002 Tabellen, 0003 Rollen, 0021 Registry) und `permissions/100_grants.sql`.
**Fragestellung:** Ist der Clone-Guard (`IF @TargetDb = N'eazybusiness' OR @TargetDb NOT LIKE N'eazybusiness[_]%' THROW …`) in jeder Datei sauber, konsistent und vollständig inkludiert?
**Methode:** Reine Datei-Analyse, keine SQL-Server-Verbindung.

## Gesamturteil

**Sauber.** Der Guard ist in allen Objekten vorhanden, in denen er gehört, konsistent formuliert (identisches `[_]`-Escape, eindeutige THROW-Nummern im 51xxx-Schema, korrekte — nach der Rename-Wave `72f8c17` aktuelle — Proc-Namen im Meldungstext), sitzt immer VOR dem ersten Write/EXEC, und die dynamische SQL-Einbettung von `@TargetDb` läuft ausnahmslos über `QUOTENAME`. Es gibt **keine kritischen und keine echten inkonsistenten Befunde** — nur einige dokumentierende Hinweise. Die Angriffsfläche „manipulierter `ops.tMandant`-Eintrag" ist durch eine `CHECK`-Constraint auf Tabellenebene plus zwei SP-/Job-Ebenen dreifach abgesichert.

## Matrix

Legende: Guard = LIKE/`=`-Clone-Guard vorhanden · Nr = THROW-Nummer · Text = Meldungstext nennt korrekten Proc-Namen · Pos = Guard vor erstem Write/EXEC · QN = `@TargetDb` nur via `QUOTENAME` in dyn. SQL · n/a = trifft für diese SP nicht zu (Begründung in Spalte).

| SP / Datei | Nimmt @TargetDb + Writes? | Guard | Nr | Text korrekt | Pos | QUOTENAME | Bewertung |
|---|---|---|---|---|---|---|---|
| spInternal_CloneDatabase | ja (RESTORE→Klon) | ✅ | 51010 (+51014 src=tgt) | ✅ | ✅ | ✅ | ok |
| spInternal_PostRestoreSecurity | ja (DDL/User) | ✅ | 51020 (+51021 TRUSTWORTHY) | ✅ | ✅ | ✅ | ok |
| spInternal_InvalidateCredentials | ja (UPDATEs) | ✅ | 51030 | ✅ | ✅ | ✅ | ok |
| spInternal_NeutralizeWorker | ja (UPDATE/DELETE) | ✅ | 51040 | ✅ | ✅ | ✅ | ok |
| spInternal_AnonymizeCustomerData | ja (11 PII-Blöcke) | ✅ | 51050 | ✅ | ✅ | ✅ | ok |
| spInternal_GrantAccess | ja (CREATE USER/Rolle) | ✅ | 51060 | ✅ | ✅ | ✅ | ok |
| spInternal_RegisterMandant | ja (schreibt bewusst auch PROD-Registry) | ✅ | 51070 (+51071 DisplayName) | ✅ | ✅ | ✅ | ok — Sonderfall, s. u. |
| spInternal_ApplyJtlRoles | ja (Rollen/Grants) | ✅ | 51080 | ✅ | ✅ | ✅ | ok |
| spInternal_LogStep | nein (nur `ops.tResetRequest`) | n/a | – | – | – | n/a | ok — kein @TargetDb, keine dyn. SQL |
| spProcessNextResetRequest (Orchestrator) | dispatcht, MULTI_USER-DDL | ✅ +Registry-Check | (51005 Whitelist) | ✅ | ✅ | ✅ | ok — stärkster Guard (Defense in Depth) |
| spEnsureAgentJob | nein (msdb-Job) | n/a | (50001 running-guard) | ✅ | n/a | n/a | ok — kein Ziel-DB-Write |
| spPub_CreateTestmandant | validiert @TargetDb vor INSERT | ✅ | 51092 | ✅ | n/a | n/a | ok — delegiert DDL an Pipeline |
| spPub_StartTestmandantReset | liest cTargetDb, re-validiert | ✅ | 51003 | ✅ (generisch) | ✅ | n/a | ok |
| spPub_CancelResetRequest | nein (ops.* + msdb-Read) | n/a | 51006/51007 | – | – | n/a | ok — kein Ziel-DB-Write |
| spPub_GetResetStatus | nein (Read ops.*) | n/a | – | – | – | n/a | ok |
| spPub_ListMandants | nein (Read ops.*) | n/a | – | – | – | n/a | ok |
| spPub_PurgeOldRequests | nein (DELETE ops.tResetRequest) | n/a | 51008 | – | – | n/a | ok |
| mandant.ps1 | nein (sqlcmd-Wrapper) | n/a (T-SQL-Quote via `Q()`) | – | – | – | n/a | ok — ruft nur spPub_* |

**THROW-Nummern-Vergabe (eindeutig, blockweise):** Pub/Orchestrator 51001–51008 · Clone 51010–51014 · PostRestore 51020–51021 · Invalidate 51030 · Neutralize 51040 · Anonymize 51050 · Grant 51060 · Register 51070–51071 · ApplyRoles 51080 · CreateTestmandant 51090–51094 · EnsureAgentJob 50001. Keine Kollision.

## Befunde

### Kritisch
Keine.

### Inkonsistent
Keine echten Inkonsistenzen. Der Guard ist zeichengleich in allen 8 Internal-Steps + CloneDatabase + Orchestrator + CreateTestmandant. Einziger stilistischer Unterschied (kein Korrektheitsproblem): Internal-Steps melden `'spInternal_X refused: …'` (bloßer Proc-Name), die Pub-Steps melden teils generisch (`'Refusing: …'`, 51003) oder mit `reset.`-Präfix (51092). Innerhalb der Internal-Familie ist der Text durchgängig einheitlich.

### Hinweise (informativ, kein Handlungszwang)

**H1 — `= N'eazybusiness'`-Clause ist logisch redundant.** `'eazybusiness'` matcht `eazybusiness[_]%` ohnehin nicht (kein Zeichen `_x` dahinter), d. h. `NOT LIKE` liefert bereits TRUE. Die explizite Gleichheitsprüfung ist bewusste Belt-and-Braces-Dokumentation, kein Bug. Kein Handlungsbedarf.

**H2 — Asymmetrie: Internal-Steps prüfen nur die Namens-Heuristik, der Orchestrator zusätzlich die Registry.** `spProcessNextResetRequest` validiert `@TargetDb` zusätzlich gegen `ops.tMandant` (`NOT EXISTS (… cMandantKey=@MandantKey AND cTargetDb=@TargetDb)` → fail). Die einzelnen Internal-Steps kennen nur das `LIKE`-Muster. Würde je eine reale, **nicht** als Testklon vorgesehene DB dem Schema `eazybusiness_<x>` folgen (z. B. eine zweite Produktiv-/Mandanten-DB), behandelte ein Direktaufruf eines Internal-Steps sie als Klon. **Bereits vorhandene Mitigation:** Internal-Steps haben KEINE EXECUTE-Grants (job-/sysadmin-only), und alle regulären Pfade sind durch Orchestrator + `CHECK`-Constraint + `spPub`-Validierung gedeckt. Optionale Härtung (niedrige Prio): den Registry-Check auch in die Internal-Steps ziehen; kostet einen Lookup je Step, schließt die Restlücke „Direktaufruf mit fremdem `eazybusiness_`-Namen".

**H3 — `LIKE`-Muster ist tolerant.** `eazybusiness[_]%` matcht auch `eazybusiness_` (leerer Suffix, `%` = 0+ Zeichen) und ist unter der JTL-Default-Collation case-insensitive (`EAZYBUSINESS_X` matcht). Beides ist kein reales Risiko (nie die Prod-DB), daher kein Handlungsbedarf — nur zur Kenntnis.

## Bewertung der Sonderfälle (Auftragspunkt 3)

- **spInternal_CloneDatabase** — Liest die Quelle `eazybusiness` legitim (COPY_ONLY-Backup) und restored **garantiert nur auf Klon-Namen**: Guard 51010 erzwingt `@TargetDb LIKE eazybusiness[_]%`, zusätzlich verhindert 51014 (`@TargetDb = @SourceDb`) ein versehentliches Restore der Quelle auf sich selbst bei fehlkonfiguriertem `ops.tConfig.SourceDb`. `RESTORE DATABASE QUOTENAME(@TargetDb)` — nie die Quelle als Ziel. **Korrekt.**

- **spInternal_RegisterMandant** — Schreibt **absichtlich** in die Quelle/Prod (`eazybusiness.dbo.tMandant`), damit der Klon im JTL-Login auftaucht (dokumentiert: CQG-5 Blast Radius). Der Guard schützt hier den **Klon** (`@TargetDb`), nicht die Menge der beschriebenen DBs — das ist die richtige Semantik: In Prod wird ausschließlich die **Registry-Zeile des Klons** (`WHERE cDB=@TargetDb`) angelegt/aktualisiert, nie Prod-Nutzdaten. Ein Fehler gegen `@TargetDb` selbst ist fatal (`THROW`), gegen jede andere Mandanten-DB nur `WARN`. Zusätzlich geprüft: Das `DELETE FROM …tBenutzerFirma WHERE kMandant=@k` auf der Quelle ist ungefährlich, weil `@k` immer entweder die klon-eigene `kMandant`-Nummer (Reuse per `cDB=@TargetDb`) oder eine frische `MAX+1`-Nummer ist — nie die Nummer eines fremden bestehenden Mandanten (`IF @k <> @refMandant`-Guard schützt zusätzlich die Referenz-Mandant-1). **Korrekt und durchdacht.**

- **spPub_*-SPs** — Arbeiten NICHT direkt auf `@TargetDb`: Start/Cancel/Status/List/Purge operieren auf `ops.*` (lokal in RoboticoOps) bzw. lesend auf `msdb`. `CreateTestmandant` validiert `@TargetDb` vor dem `INSERT` (51092) und delegiert alle Ziel-DB-DDL an die Pipeline. **Guard dort korrekt, wo er nötig ist.**

- **spProcessNextResetRequest (Orchestrator)** — Validiert `@TargetDb` **redundant zu den Steps** (Defense in Depth, D6): `= 'eazybusiness'` OR `NOT LIKE` OR **nicht in Registry** → `failed`, bevor die Pipeline startet. Damit ist es kein Single Point, sondern die äußerste von mehreren Schichten. **Korrekt.**

## Angriffsfläche „manipulierter ops.tMandant-Eintrag" (Auftragspunkt 4)

**Ergebnis: dreifach blockiert.**

1. **Tabellen-Constraint (deklarativ, härteste Schicht):** `CK_tMandant_cTargetDb CHECK (cTargetDb <> N'eazybusiness' AND cTargetDb LIKE N'eazybusiness[_]%')` in `0002_ops_schema_tables.sql`. Ein `INSERT` **oder** `UPDATE` mit `cTargetDb='eazybusiness'`, `'master'` oder irgendeinem Nicht-`eazybusiness_`-Namen wird von der Engine abgelehnt — die Manipulation kann gar nicht erst persistiert werden.
2. **spPub_CreateTestmandant:** wirft 51092 mit identischem Muster vor dem INSERT.
3. **Orchestrator-Re-Validierung:** Selbst eine von Hand (unter Umgehung der SPs) eingeschleuste `ops.tResetRequest`-Zeile mit `cTargetDb='eazybusiness'` scheitert an der `= 'eazybusiness'`-Clause UND am Registry-`NOT EXISTS`.

**Wer darf `cTargetDb` setzen?** Nur `ops_admin` — `0003_roles.sql` grantet `INSERT/UPDATE/DELETE ON ops.tMandant` ausschließlich an `ops_admin`; `ops_reset_executor` hat keinerlei Schreibrecht (nur `spPub_*`-EXECUTE, plus Spalten-`DENY` auf `cShopLicense`). `ops_admin` ist im Threat-Model bereits faktisch sysadmin — nur diese Rolle könnte die `CHECK`-Constraint droppen; das liegt außerhalb des betrachteten Angriffsmodells.

## Stärken (bewusst dokumentiert)

- **QUOTENAME/Parametrisierung durchgängig korrekt:** Keine Caller-Daten werden je in dynamische SQL konkateniert (D6). `@TargetDb` → immer `QUOTENAME`; Pfade/Shop-URLs/Login-Namen → immer `sp_executesql`-Parameter bzw. `QUOTENAME(…, '''')`-Literale aus vertrauenswürdigen Quellen. Der Orchestrator-Dispatch (`N'reset.' + QUOTENAME(@stepProc)`) + `spInternal[_]%`-Whitelist (51005) verhindert Code-Injection über die Registry-Tabelle.
- **Guard-Position invariant:** In jedem Internal-Step ist der Guard die erste ausführbare Anweisung nach `SET NOCOUNT ON`; kein Write/EXEC läuft davor.
- **Rename-Wave `72f8c17` sauber nachgezogen:** Kein Meldungstext nennt einen veralteten Proc-Namen; alle `refused:`-Texte tragen den aktuellen `spInternal_`-Namen.

## Fix-Empfehlungen (NICHT umgesetzt)

Es besteht **kein zwingender Fix-Bedarf.** Optionale, priorisierte Härtungen:

1. **(Niedrig) H2 schließen:** Registry-Existenzprüfung (`EXISTS(SELECT 1 FROM ops.tMandant WHERE cTargetDb=@TargetDb)`) zusätzlich in die 8 Internal-Steps aufnehmen — macht die Steps auch bei Direktaufruf gegen die Registry robust, nicht nur gegen die Namenskonvention. Kosten: ein Lookup je Step; Nutzen: eliminiert die theoretische „reale `eazybusiness_`-DB ohne Registry-Eintrag"-Restlücke.
2. **(Kosmetisch) Meldungsstil vereinheitlichen:** Pub-Steps optional auf `'reset.spPub_X refused: …'` normalisieren, damit alle Refuse-Texte demselben `<voller Procname> refused:`-Schema folgen. Rein diagnostischer Komfort.
