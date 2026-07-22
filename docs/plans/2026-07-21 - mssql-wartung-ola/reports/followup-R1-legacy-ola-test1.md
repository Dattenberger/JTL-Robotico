# Follow-up R1 — Ownerless Legacy-Ola on test1 `eazybusiness.dbo`

> Read-only research for the 🔴 R1 entry in `reports/implementation-report.md`.
> Nothing was changed. All findings are from read-only `sqlcmd` against
> **vm-sql-test1** (SQL 2025) and **vm-sql2** (PROD, SQL 2022), plus the plan
> and reset-infrastructure sources in this repo.

## TL;DR — Empfehlung

**Follow-up needed → Option (b): den test1-Cleanup als zweiten Instanz-Ziel in
denselben B6-Phase-4a-Runbook-Schritt aufnehmen (ein Removal-Skript für beide
Instanzen, je Instanz mit CommandLog-Archivierung).**

- Option **(a)** (jetzt per Ad-hoc-Skript droppen) ist *technisch* wirksam — der
  Reset überschreibt die Basis-`eazybusiness` nicht, ein Drop bliebe also stehen —
  aber sie dupliziert die B6-Phase-4a-Prozedur **ohne** die dort vorgeschriebene
  D39-Archivierung und hätte weiterhin keinen sauberen Owner.
- Option **(c)** in ihrer wörtlichen Form (*„Reset baut eazybusiness ohnehin neu
  auf, also nichts tun"*) ist **falsch**: die Reset-/Restore-Mechanik klont die
  Basis-`eazybusiness` in Wegwerf-Klone `eazybusiness_tmN` — sie **überschreibt die
  Basis nie**. Die Legacy verschwindet also nicht von selbst.

Kernargument für (b): test1s Basis-`eazybusiness` ist ein **einmaliger Klon aus
einem Prod-Backup** und trägt exakt dieselbe Legacy wie Prod. B6 Phase 4a hat
bereits die passende, geprüfte Entfernungsprozedur (Inventar → CommandLog
archivieren → droppen). Diese Prozedur zusätzlich gegen test1 laufen zu lassen
schließt R1 mit **einem** Owner und **einer** Prozedur, statt einen zweiten,
ungeprüften Ad-hoc-Pfad zu erfinden.

---

## Was hinter dem 🔴-Marker steht

R1 sagt: test1s `eazybusiness.dbo` trägt noch die 2024-06-24-Legacy-Ola-Installation
(`CommandLog`, `DatabaseBackup`, `DatabaseIntegrityCheck`) ohne Cleanup-Owner. AC2
hält (unsere Kette hat davon nichts angelegt), Prod wird in B6 Phase 4a entfernt,
test1 hat keinen Owner. Das ist ein **Ownership-/Hygiene-Loose-End**, kein
Code-Defekt. Die Research klärt drei Dinge: (1) exaktes Inventar, (2) hängt etwas
davon ab, (3) Empfehlung mit Trade-offs — insbesondere ob der Reset test1 ohnehin
neu aufbaut.

## 1 — Exaktes Inventar (test1, read-only)

Legacy-Ola in `eazybusiness.dbo`, alle `create_date = 2024-06-24 23:01:48`:

| Objekt | Typ | Bemerkung |
|---|---|---|
| `dbo.CommandLog` | USER_TABLE | **9.218 Zeilen**, `StartTime` 2024-06-24 → **2025-11-27 04:01:05** (letzter Schreibvorgang, `ALTER INDEX … REORGANIZE` auf `dbo.Umsätze`) |
| `dbo.DatabaseBackup` | SQL_STORED_PROCEDURE | referenziert `dbo.CommandExecute` |
| `dbo.DatabaseIntegrityCheck` | SQL_STORED_PROCEDURE | referenziert `dbo.CommandExecute` **und** `dbo.CommandLog` |

**Wichtige Nuance — die Installation ist bereits halb demontiert:** `dbo.CommandExecute`
und `dbo.IndexOptimize` **existieren nicht (mehr)**. Beide Rest-Procs
(`DatabaseBackup`, `DatabaseIntegrityCheck`) zeigen damit auf einen **nicht
existierenden** `dbo.CommandExecute` — sie sind funktional **kaputt / nicht
ausführbar**. Der Drop ist also reine Aufräumarbeit ohne jeden Funktionsverlust.

**Keine Agent-Jobs auf test1** referenzieren diese Objekte. Die einzigen Jobs, die
die Namen `CommandLog`/`IndexOptimize` etc. erwähnen, sind **unsere eigenen**
`RoboticoOps - Maint - *`-Jobs (create_date 2026-07-22, **alle disabled**). Die
„11 alten Ola-Jobs", die die Plan-B6-Phase-4a für Prod entfernt, gibt es auf test1
**gar nicht** (der Basis-Klon war DB-Level, ohne `msdb`) — test1 ist damit ein
**leichterer** Fall als Prod: nur 3 verwaiste `dbo`-Objekte, keine Jobs.

**Abgrenzung — nicht Teil von R1:** Es existiert eine **separate** Ola-artige
Installation in `eazybusiness.DBA.*` (`spOlaCommandExecute`, `spOlaCreateTables`,
`spOlaDatabaseBackup`, `spOlaDatabaseIntegrityCheck`, `spOlaIndexOptimize`,
create_date 2026-06-13). Diese Procs referenzieren `dbo.CommandLog` **nicht** (per
Moduldefinition geprüft), sind selbstständig und gehören nicht zum 2024er-Legacy-Set.
Auch unsere Kette lebt sauber getrennt in `RoboticoOps.dbo` (create_date 2026-07-22).
R1 betrifft ausschließlich die 3 `dbo`-Objekte oben.

## 2 — Hängt etwas davon ab?

- **Referenzen (`sys.sql_expression_dependencies`, gleiche DB):** nur die beiden
  Legacy-Procs untereinander bzw. auf `CommandLog`/das fehlende `CommandExecute`.
  **Kein** Business-/EKL-/Robotico-Objekt referenziert die Legacy.
- **`DBA.spOla*`:** referenzieren `dbo.CommandLog` nicht → unabhängig.
- **Unsere maint-Suite:** liest/schreibt `RoboticoOps.dbo.CommandLog`, nicht
  `eazybusiness.dbo.CommandLog` (Plan §3.2, `spCheckMaintenanceLiveness`) → unabhängig.
- **Agent-Jobs:** keine (s. o.).

Ergebnis: die Objekte sind **dormant und ohne Abnehmer**. (Cross-DB-Referenzen aus
anderen Datenbanken wurden nicht erschöpfend gesweept; angesichts eines
Standard-JTL/Ola-Sets ohne Business-Bezug und ohne Schreibaktivität seit 2025-11
ist ein externer Abnehmer praktisch ausgeschlossen.)

## 3 — Baut der Reset test1s eazybusiness neu auf? (Prüfung zu Option c)

**Nein — nicht die Basis-DB.** Die Reset-Mechanik
(`reset.spPub_StartTestmandantReset` → Agent-Job → `reset.spInternal_*`, s.
`docs/runbooks/testmandant-reset-validierung.md`, `Projekte/Testsystem/copy_test_db.sql`)
**klont** die Basis-`eazybusiness` per COPY_ONLY-Backup in **Wegwerf-Klone**
`eazybusiness_tmN` (Ziel-DB `≠ eazybusiness`, hart abgesichert per SAFETY CHECK).
Die Basis-`eazybusiness` ist **Quelle**, nie Ziel eines Restores.

Restore-/Create-Historie (test1, read-only):

| DB | create_date | Herkunft |
|---|---|---|
| `eazybusiness` (Basis) | 2026-06-13 22:53:39 | **einmaliger** Restore aus `eazybusiness_excel_ekl_copy` (Backup 2026-06-10) |
| `eazybusiness_tm9` | 2026-07-13 / -15 | Klon **aus** Basis-`eazybusiness` |

Damit: die literale Option (c) („der Reset überschreibt es sowieso") **trifft nicht
zu** — ein manueller Drop auf der Basis bliebe stehen und käme durch Resets **nicht**
zurück. Die Klone `tmN` erben die Legacy nur, solange die Basis sie trägt; das ist
folgenlos (Klone sind Wegwerf).

**Der eigentliche Reintroduktions-Pfad ist ein anderer:** test1s Basis ist ein
**einmaliger Klon aus Prod** (2026-06-13). Prod trägt die **byte-identische**
Legacy — read-only auf **vm-sql2** bestätigt: dieselben 3 Objekte, `create_date`
2024-06-24, `dbo.CommandLog` mit **9.218 Zeilen**, letzter Schreibvorgang
**2025-11-27 04:01:05** (deshalb nennt die Plan-D39-Archivierung exakt „9.218
Zeilen" — beide Instanzen sind hier identisch). Würde test1s Basis künftig erneut
aus einem Prod-Backup neu aufgesetzt (genau der Weg, über den sie 2026-06 entstand),
käme die Legacy **nur zurück, solange Prod sie trägt**. Nach B6 Phase 4a ist Prod
sauber → jeder künftige Re-Klon ist sauber.

Das ist das starke Argument für (b): test1 **jetzt** allein zu putzen, während Prod
die Quelle noch trägt, ist gegen einen möglichen Re-Seed nicht robust — beide
Instanzen im **selben** B6-Phase-4a-Schritt zu bereinigen schon.

## 4 — Wave-/Knock-on-Bezug

R1 ist eine **delegierte** Ownership-Frage (I1), kein Repair mit Wave-Commit — es
gibt keinen Fix-Diff zu inspizieren. Die Implementierung hat R1 korrekt als
„open, ownerless" markiert; E2E TC-2 wurde bewusst zu einem *Provenance-Beweis*
(AC2 hält) statt zu einem blinden Fehlschlag geschärft (Report O8.2). Keine
späteren Änderungen bauen darauf auf oder umgehen es. Der Marker ist sauber.

## Empfehlung & konkrete User-Optionen

**Empfehlung: Option (b) — follow-up needed.**

Konkret in `docs/runbooks/rollout-mssql-ops.md`, B6 **Phase 4a** (der Schritt
existiert bereits für Prod, D16/D39):

1. Den bestehenden Entfernungsschritt so formulieren, dass er **gegen beide
   Instanzen** läuft (vm-sql2 **und** vm-sql-test1) — ein Skript, zwei Targets.
2. Je Instanz **vor dem Drop** das `CommandLog` gemäß D39 archivieren
   (`SELECT * INTO RoboticoOps.dbo.CommandLog_legacy_eazybusiness FROM eazybusiness.dbo.CommandLog`).
   Kein Namenskonflikt: jede Instanz hat ihre eigene `RoboticoOps`-DB.
3. **test1-Vereinfachung explizit machen:** dort nur die 3 `dbo`-Objekte droppen —
   **keine** Alt-Job-Löschung nötig (existieren dort nicht), und die kaputten Procs
   (dangling `CommandExecute`) bestätigen den Null-Funktionsverlust.
4. Owner = derselbe Cutover-Owner wie B6 (Lukas / Prod-Cutover-Fahrer). Damit ist
   R1 owned und nicht länger „ownerless".

Alternativen, bewusst benannt:

- **(a) Jetzt ad-hoc auf test1 droppen:** wirksam (bliebe stehen), aber dupliziert
  die B6-Prozedur ohne die D39-Archivierung und ohne den B6-Owner — nur wählen,
  wenn test1 *vor* dem Prod-Cutover verifikationssauber sein muss (kein aktueller
  Bedarf; die Legacy stört die maint-Suite nicht).
- **(c) Bewusst belassen:** risikoseitig vertretbar — dormant seit 2025-11,
  an keinen Job gehängt, Procs bereits kaputt, unsere Suite in `RoboticoOps`. Aber
  ein Hygiene-Loose-End; die Grenzkosten, es in B6 mitzunehmen, sind ~null. **Nicht**
  mit der falschen Begründung „Reset räumt es weg" rechtfertigen — das tut er nicht.

---

**Recommendation:** follow-up needed → **Option (b)** (test1 in denselben
B6-Phase-4a-Removal-Schritt aufnehmen, ein Skript für beide Instanzen, je Instanz
mit CommandLog-Archivierung).
**File:** `docs/plans/2026-07-21 - mssql-wartung-ola/reports/followup-R1-legacy-ola-test1.md`
