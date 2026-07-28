# T6 — Nachtestlauf (Fix-Verifikation)

- **Datum:** 2026-07-28
- **Ziel-Container:** `robotico-e2e-mssql` @ `localhost,14330` (SQL2022 CU26, Developer Edition, Mixed-Mode, SA-Auth)
- **Server-ID (E2E-Guard):** `3c2b38585482`
- **Stand:** alle 5 Kategorie-A-Fixes deployt; Umgebung vor Lauf GRÜN.
- **E2E-Guard:** in jedem schreibenden Skript aktiv (`E2E-GUARD ok … Developer Edition — write erlaubt`). PROD/`vm-sql-test1` nicht berührt.

Bewertung: jeder Fix-Fall muss GRÜN sein; erwartete THROWs zählen bei korrekter Nummer als PASS.

---

## 1. Fix-Verifikation je Bug

| Bug | Status | Kern-Evidenz (nach Fix) |
|-----|--------|--------------------------|
| **F-1** — Cancel-running Force-Reclaim / msdb-Grants | **VERIFIED-FIXED** | `spPub_CancelResetRequest` unter EXECUTE-AS `jobstartuser` liest `msdb.dbo.syssessions/sysjobs/sysjobactivity` ohne **Msg 229**; running-Request wird `running → failed` (Note: „force-reclaimed (was running, no active job)"). Kein Permission-Fehler. |
| **F-2** — GrantAccess Special-Principal-Skip | **VERIFIED-FIXED** | `cLoginName='sa'`: GrantAccess läuft fehlerfrei (kein **Msg 15405/15063**), `cStepLog` enthält `WARN access-skipped … sysadmin`, **kein** DB-User `[sa]` im Klon angelegt. Reset succeeded, sa NICHT db_owner. |
| **F4.6** — spGebindeErstellen idempotent | **VERIFIED-FIXED** | Doppellauf → genau **1** `tGebinde`-Zeile, Suffix nicht verdoppelt (`…-keine-Lieferanten-angepasst`, einfach). Alles in Transaktion, rollback → DB CLEAN. |
| **F4.4** — fnStringParseGermanDecimal US-Format→NULL | **VERIFIED-FIXED** | `'1,234.56'` (US) → **NULL** (abgelehnt); `'1.234,56'` → 1234.56; `'1.234.567,89'` → 1234567.89. Deutsches Format weiter korrekt. |
| **F4.1** — CustomWorkflows-Schema-Precondition (up/0004) | **VERIFIED-FIXED** | DB ohne Schema: nacktes **Msg 2760** reproduziert; Precondition wandelt es in klaren **THROW 50002** (nennt fehlendes JTL-Modul). up/0004 gegen DB *mit* Schema = No-Op (PRINT OK + journaled, kein THROW). |

---

## 2. Regressionstest-Dateien (5)

Ebene-A gegen `-d eazybusiness`, global gegen `-d RoboticoOps`. Alle self-cleaning.

| Datei | DB | Ergebnis |
|-------|----|----------|
| `global/ResetCancelRunning_Tests.sql` (F-1) | RoboticoOps | **PASS 2/2** |
| `global/GrantAccessSpecialPrincipal_Tests.sql` (F-2) | RoboticoOps | **PASS 3/3** |
| `eazybusiness/GebindeErstellen_Tests.sql` (F4.6) | eazybusiness | **PASS 4/4** (2 Sektionen) |
| `eazybusiness/StringAndCSVUtilities_Tests.sql` (F4.4 + Rest) | eazybusiness | **PASS 57/57** (10 Sektionen) |
| `eazybusiness/CustomWorkflowsSchemaPrecondition_Tests.sql` (F4.1) | eazybusiness | **PASS 4/4** (3 Sektionen); Scratch-DB `robotico_f41_precond_test` angelegt+entfernt |

**Summe: 70/70 Checks PASS.**

---

## 3. Gezielte Szenario-Checks (Gesamttestplan)

| Fall | Ergebnis | Evidenz |
|------|----------|---------|
| **T2-32** Reset mit echtem Nicht-Special-Login | **PASS 2/2** | Wegwerf-Login `dbuser_t6` (CSPRNG-Passwort via `CRYPT_GEN_RANDOM`, nie persistiert) → GrantAccess macht ihn **db_owner** im Klon; `cStepLog` = positive `access: … is db_owner`-Note. Login+Klon+ops-Rows danach entfernt. |
| **T2-54** Cancel-running Force-Reclaim (F-1) | **PASS** | siehe F-1 oben — statt Msg 229 nun sauberer `running → failed`. |
| **T2-55** Cancel-Refusal bei aktivem Job | **PASS 2/2** | Aktiv laufender Job deterministisch simuliert (bestehende `sysjobactivity`-Zeile der aktuellen Agent-Session auf started/not-stopped gesetzt, Original danach exakt restauriert) → Cancel wirft **THROW 51007** (nicht Msg 229), Request bleibt `running`. Beweist zugleich, dass der msdb-Read den 51007-Guard *erreicht*. |
| **T4-02** spGebinde Doppellauf | **PASS** | = F4.6 (1 Zeile, einfaches Suffix). |
| **T4-10b** fnStringParseGermanDecimal | **PASS** | = F4.4 (US → NULL, DE korrekt). |
| **T4-12** CREATE gegen DB ohne CustomWorkflows-Schema | **PASS** | = F4.1 (THROW 50002 statt nacktem 2760). |

---

## 4. Idempotenz-Re-Run beider Ketten

Zweiter kompletter Deploy (native grate v1.6.0, `-Environment E2E`), Reihenfolge global → eazybusiness.

| Kette | Version | Ausgeführte Skripte |
|-------|---------|---------------------|
| **global** (RoboticoOps) | `0ed9691 → 0ed9691` (unverändert) | nur `permissions/*` (EveryTime, idempotent): 100/200/250/**255**/260/900. **Keine** `up/`-, **keine** sproc-/anytime-Skripte. |
| **eazybusiness** | `0ed9691 → 0ed9691` (unverändert) | **0 Skripte** — kompletter No-Op. |

- **up/0004 auf adoptierter eazybusiness:** journaled (Robotico.ScriptsRun id 54, entry `2026-07-27 21:53`) → lief **NICHT erneut**, **THROWte NICHT**; nach Re-Run weiterhin genau 1 Journal-Zeile.
- **permissions/255:** läuft everytime, idempotenter GRANT → Laufzähler 2 → 3 (ops.ScriptsRun), fehlerfrei.
- **ScriptsRunErrors:** eazy=1 / ops=5 Zeilen, **alle historisch** (2026-07-27, frühere Fault-Injection-Skripte `zzz_T111_fail.sql`/`0002a_fail.sql` etc.); **0** Fehler mit `entry_date >= 2026-07-28` → Re-Run erzeugte keine Fehler.

**Befund: beide Ketten sind idempotent (No-Op bis auf beabsichtigte EveryTime-Permissions).**

---

## 5. Abschluss-Validierung

`npm run db:validate:e2e` → **Rollout validation OK**:
- `validate_structure.sql`: PASS (alle reset.*/maint.*/ops.*-Objekte, Spalten, Signatur, Rollen vorhanden).
- `validate_rollout.sql`: PASS (Journals gefüllt, Reset-Step-Registry seeded, Entry-Procs signiert, Agent-Job enabled, Signing/Impersonation-Principals korrekt, Maintenance-Jobs/Operator verdrahtet).
- Consumer-Roundtrip `spPub_ListMandants` + `spPub_GetResetStatus`: PASS.

---

## 6. Endzustand Umgebung (sauber)

- **Klon-/Scratch-DBs:** keine (`eazybusiness_tm%`, `robotico_f41%` = 0).
- **Wegwerf-Login `dbuser_t6`:** entfernt.
- **Test-ops-Rows** (tm94–tm97 Mandanten/Requests): 0.
- **Aktive Reset-Requests** (queued/running): 0.
- **Schalter `MaintenanceSchedulesEnabled`:** `0`.
- **Maintenance-Agent-Jobs** (6× `RoboticoOps - Maint - *`): alle **disabled**; `RoboticoOps - Testmandant Reset`: enabled (erwarteter Steady-State, deckt sich mit validate).
- **msdb.sysjobactivity:** T2-55-Zeile exakt auf Originalwerte restauriert.

**Gesamtergebnis: alle 5 Fixes VERIFIED-FIXED, 70/70 Regressionschecks + 6 Szenarien PASS, beide Ketten idempotent, validate:e2e grün, Umgebung sauber.**
