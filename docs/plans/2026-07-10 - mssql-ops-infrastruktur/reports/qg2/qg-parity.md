# QG2 — Feature-Parity-Audit: Legacy PowerShell-Reset vs. neue reset-Pipeline

**Reviewer:** Feature-Parity (Fable-Lens)
**Scope:** `Projekte/Testsystem/*` (Legacy) vs. `db-migrations/global/*` (neu)
**Datum:** 2026-07-11
**Verbatim-Requirement:** „Die Testmandantenerstellung muss technisch das gleiche Ergebnis liefern wie aktuell, nur dass sie durch SPs gesteuert werden kann – auch durch Konsumenten, die keine oder nicht die nötigen Datenbankrechte haben."

## Zusammenfassung

Die Portierung ist **inhaltlich sehr treu**. Die Anonymisierung (`clear-customer-fields.sql` → `reset.internal_AnonymizeCustomerData`) wurde **1:1 über alle 11 Prioritätsblöcke** übernommen — jede aktive Tabelle und jede Spalte stimmt überein (auskommentierte Blöcke `tfirma`/`tlieferant`/`tUmsatzSteuerPruefung`/`tBemerkungen` sind auch neu weggelassen). Die Credential-Invalidierung (`invalidate-credentials-for-testing.sql` → `reset.internal_InvalidateCredentials`) deckt **alle** Quell-Tabellen ab; die Banking-Blöcke sind bewusst nach `AnonymizeCustomerData` P8 verschoben (dokumentiert, gleiches Endergebnis). Klon, Register-Mandant, Grant, JTL-Rollen sind faithful portiert; `PostRestoreSecurity` + `NeutralizeWorker` sind additive Neuerungen (D9). Die **Reverse-Parität ist sauber**: alle Versprechen aus Plan §3/§D8/§D9 sind implementiert (Pipeline-Reihenfolge, guarded Queue-Liste, Agent-Job Owner `sa` ohne Schedule, ShopLicense-Spalten-DENY).

Die verbleibenden Funde sind **operativer** Natur (nicht in der SQL-Logik): der wichtigste ist, dass der Entwickler-Zugriff auf den Klon out-of-the-box **anders** ausfällt als beim Legacy-Weg.

## Inventar Legacy-Pfad → Klassifikation

| # | Legacy-Feature / Side-effect | Quelle | Neu (wo) | Klassifikation |
|---|---|---|---|---|
| 1 | COPY_ONLY-Backup + Restore-with-move, RECOVERY SIMPLE, MULTI_USER, SINGLE_USER-Kick, xp_create_subdir | copy_test_db.sql | `internal_CloneDatabase` | PORTED (Pfade aus `ops.Config`) |
| 2 | Safety-Guard `@TargetDb <> eazybusiness` | alle Skripte | THROW + `LIKE eazybusiness[_]%` in jedem internal_* + Start + Process | PORTED (verschärft) |
| 3 | Credential-Invalidierung: tEMailEinstellung, ebay_user (+nGesperrt=1), tOauthConfig/Token, tShipperAccount, SCX/Sync/BI-Token, tVouchersToken, FulfillmentNetwork.tLogin, Shipping.tVersandplattformUserData, twebversand, tLizenz, tBenutzerLogin, tDatevConfig, Robotico.tPaypal* | invalidate-credentials-for-testing.sql | `internal_InvalidateCredentials` | PORTED (alle Tabellen) |
| 4 | Shop-Repoint nur `nTyp=0 AND cServerWeb LIKE 'http%'`; Zugangsdaten bleiben; tWebshopModule unberührt | invalidate…sql:131-135 / e6d7b2b | `internal_InvalidateCredentials`:61-63 | PORTED |
| 5 | Banking-Anonymisierung tkontodaten/tinetzahlungsinfo (=''-Variante) | invalidate…sql:374-468 | verschoben → `AnonymizeCustomerData` P8 (Platzhalter-Variante) | PORTED (dokumentiert, gleiches Endergebnis) |
| 6 | PII-Anonymisierung 11 Prioritätsblöcke, ~40 Tabellen, CONTEXT_INFO-Trigger-Bypass (tkunde/tAdresse) | clear-customer-fields.sql | `internal_AnonymizeCustomerData` | PORTED (1:1 Spalten-Parität) |
| 7 | tKunde_suche leeren | clear-customer-fields.sql:82-92 (TRUNCATE) | `AnonymizeCustomerData` P1 (DELETE) | PORTED (Vendor-Table-Regel, gleiches Endergebnis) |
| 8 | Grant: db-User + db_owner auf Ziel-DB | grant-database-access.sql | `internal_GrantAccess` | PORTED (ALTER ROLE statt sp_addrolemember; fehlender Login = Skip statt Fehler, D4) |
| 9 | Register: tMandant-Upsert in alle Mandanten-DBs + tBenutzerFirma-Seed aus Ref-Mandant | register-mandant.sql | `internal_RegisterMandant` | PORTED |
| 10 | JTL-Rollen (JTL_Reader/Writer + 8 Member) | Berechtigungen/JTL-Rollen.sql | `internal_ApplyJtlRoles` | PORTED (GRANT auf RoboticoEKL-Schema weggelassen, D4/D10 dokumentiert) |
| 11 | Config-Quelle (Developer/ShopUrl/ShopLicense pro Mandant) | test-environment.config.json | `ops.Mandant` (+ Spalten-DENY ShopLicense) | PORTED (D8) |
| 12 | Hardcodierte Pfade `E:\work\…bak`, `E:\MSSQL\Data`, SourceDb | copy_test_db.sql | `ops.Config` (0020-Seed) | PORTED |
| 13 | MandantName-Berechnung „Testmandant`<N>` (`<Dev>`)" | setup-…ps1:118-123 | `ops.Mandant.DisplayName` (gespeichert statt berechnet) | PORTED (Konvention wandert in Seed/Runbook) |
| 14 | LoginName = **1 geteilter** Dev-Login (`dbuser_dev_dana_for_development`) für ALLE Mandanten | setup-…ps1:62 | `ops.Mandant.LoginName` **pro Mandant** (`dbuser_dev_tmN`) | **→ PAR-1** (Verhaltensänderung, silent no-access) |
| 15 | eBay nGesperrt=1 + Shop-Repoint (e6d7b2b) | invalidate…sql | `InvalidateCredentials` + `NeutralizeWorker` (nGesperrt doppelt) | PORTED |
| 16 | Fail-fast: `-b` bricht bei erstem Fehler ab | setup-…ps1:169 | Pipeline in TRY/CATCH, Request→'failed', Klon bleibt für Diagnose | PORTED (async-Variante) |
| 17 | Verifikations-SELECTs / Per-Statement-PRINTs | invalidate…/clear-… | ersetzt durch StepLog + GetResetStatus | DROPPED (dokumentiert) |
| 18 | pf_user-Sperre + Queue-Leerung | — (nicht im Legacy) | `internal_NeutralizeWorker` | NEU (D9) |
| 19 | Post-Restore-Security (owner→sa, Orphan-Remap, TRUSTWORTHY OFF) | — (nicht im Legacy) | `internal_PostRestoreSecurity` | NEU |
| 20 | `grant-database-access-partial.sql` (granulare SELECTs auf Quell-/PROD-DB) | Datei vorhanden, **nicht** im PS-Pipeline-Aufruf | kein Pendant | **→ PAR-2** (Non-Port undokumentiert) |
| 21 | `revoke-database-access.sql` (Rechte-Entzug + DROP USER auf Quell-DB) | Datei vorhanden, standalone | kein Pendant | **→ PAR-2** (Non-Port undokumentiert) |
| 22 | CONTEXT_INFO-Reset auch im Fehlerfall (CATCH → `SET CONTEXT_INFO 0x0`) | clear-…:68-77, 158-164 | Batch ohne CATCH-Reset in `AnonymizeCustomerData` P1 | **→ PAR-3** (Robustheits-Regression) |

## Findings

### PAR-1 — Entwickler-Zugriff auf den Klon fällt out-of-the-box anders aus als beim Legacy-Weg (silent no-access)
**Severity:** important
**Evidence:**
- Legacy: `setup-test-environment.ps1:62` — `LoginName` default `dbuser_dev_dana_for_development`, ein **existierender, geteilter** Server-Login, der auf **jedem** Testmandanten `db_owner` bekommt (`grant-database-access.sql`).
- Neu: `0020_seed_mandant_template.sql:41-43` seedet `LoginName = dbuser_dev_tm2/tm3/tm4` — **Platzhalter, die als Server-Logins nicht existieren**. `reset.internal_GrantAccess.sql:26-29` überspringt bei fehlendem Login **bewusst** (D4) und schreibt nur eine StepLog-Notiz; der Request wird trotzdem `succeeded`.
- Folge: Wird der Runbook-Schritt „echten LoginName eintragen" vergessen, meldet der Reset **Erfolg**, aber **kein** Entwickler hat Zugriff auf den frischen Klon. Der auslösende Kollege sieht in `GetResetStatus` nur `Status=succeeded` — die Skip-Notiz steht im StepLog, ist aber leicht zu übersehen. Das ist eine konkrete Abweichung vom „technisch gleichen Ergebnis".
**Proposed fix (implementierbar):**
1. `0020_seed_mandant_template.sql`: `LoginName` der drei Template-Zeilen auf den bekannten, existierenden Shared-Login `dbuser_dev_dana_for_development` setzen (statt der nicht-existenten `dbuser_dev_tmN`), damit der Default-Reset out-of-the-box das Legacy-Ergebnis liefert; Runbook-Schritt bleibt als „pro-Entwickler verfeinern" optional.
2. Optional (Serviceability): in `reset.internal_GrantAccess` den Skip-Fall zusätzlich als eigenständiges Feld / auffälligeres StepLog-Präfix (`WARN access-skipped`) markieren, damit er in `GetResetStatus` sofort auffällt.
**Size:** S

### PAR-2 — Non-Port von `revoke-database-access.sql` und `grant-database-access-partial.sql` ist nirgends dokumentiert
**Severity:** nice
**Evidence:** Beide Dateien liegen weiter in `Projekte/Testsystem/`, gehören aber **nicht** zum PS-Reset-Pipeline-Aufruf (`setup-…ps1:134-140` ruft nur `grant-database-access.sql`, die einfache Ziel-DB-Variante). Die README-Mapping-Tabelle (`Projekte/Testsystem/README.md:40-49`) listet nur die Pipeline-Skripte; ein Leser kann nicht erkennen, ob `partial`/`revoke` absichtlich nicht portiert wurden oder vergessen. Fachlich sind sie out-of-scope (granularer PROD-Lesezugriff bzw. Deprovisioning — kein Teil der Testmandant-Erstellung).
**Proposed fix:** In `Projekte/Testsystem/README.md` eine Zeile ergänzen: „`grant-database-access-partial.sql` und `revoke-database-access.sql` sind Standalone-Hilfsskripte (granularer PROD-Lesezugriff / Rechte-Entzug), **nicht** Teil des Reset-Pipelines und daher bewusst nicht in `db-migrations/` portiert."
**Size:** S

### PAR-3 — `AnonymizeCustomerData` setzt CONTEXT_INFO im Fehlerfall nicht zurück (Robustheits-Regression ggü. Legacy)
**Severity:** nice
**Evidence:** Legacy `clear-customer-fields.sql:68-77` und `:158-164` setzen `SET CONTEXT_INFO 0x0` explizit auch im CATCH-Zweig, damit der Trigger-Bypass niemals „hängen bleibt". Der neue Block `reset.internal_AnonymizeCustomerData.sql:29-91` (P1) setzt CONTEXT_INFO für `tkunde`/`tAdresse`, hat aber **keinen** CATCH-Reset — wirft z.B. das `tAdresse`-UPDATE, bleibt der Bypass-Hash für die Session gesetzt. Praktische Auswirkung gering (der Agent-Job-Step endet ohnehin, und die nächste Anon-P1 setzt ihren eigenen Hash), aber es ist eine bewusste Sicherheits-/Aufräum-Konvention der Quelle, die verloren ging.
**Proposed fix:** P1-Batch in `AnonymizeCustomerData` in `BEGIN TRY … BEGIN CATCH SET CONTEXT_INFO 0x0; THROW; END CATCH` kapseln (analog zur Quelle), damit der Trigger-Bypass bei jedem Fehler garantiert zurückgesetzt wird.
**Size:** S

### PAR-4 — Shop-Repoint meldet Erfolg auch bei 0 getroffenen Zeilen (Verifikation der Quelle entfällt)
**Severity:** nice
**Evidence:** Legacy `invalidate-credentials-for-testing.sql:555-613` enthielt eine Verifikations-SELECT, die prüft, dass `cServerWeb`/`cAPIKey` tatsächlich auf die Staging-Werte umgebogen wurden. Neu (`reset.internal_InvalidateCredentials.sql:61-63`) wird der Repoint ausgeführt und der StepLog schreibt unbedingt „JS-Shop repointed to staging" — **ohne** zu prüfen, ob überhaupt eine `nTyp=0`-http-Zeile getroffen wurde. Existiert keine passende Shop-Zeile (oder eine mit ShopLicense-Sentinel `<SET-VIA-RUNBOOK>`), bleibt das unbemerkt.
**Proposed fix:** Nach dem `tShop`-UPDATE `@@ROWCOUNT` prüfen und bei 0 eine `WARN shop-repoint: no matching JS-Shop row` in den StepLog schreiben (kein THROW — 0 Zeilen ist bei manchen Klonen legitim). Primär aber als E2E-Assertion abfangen (siehe unten).
**Size:** S

## E2E parity assertions

Für den geplanten Docker-basierten E2E-Vergleich (voller Reset gegen einen restaurierten Klon). Jede Assertion vergleicht den Klon-Endzustand mit der Legacy-Erwartung:

1. **Anonymisierungs-Spaltenparität:** Für jede der 11 Prioritätsblock-Tabellen (`tkunde`, `tinetkunde`, `tAdresse`, `tinetadress`, `trechnungsadresse`, `tBenutzer`, `tansprechpartner`, `Verkauf.tAuftragAdresse`, `Rechnung.tRechnungAdresse`, `DbeS.tLieferadresse`, `DbeS.tRechnungadresse`, `tinetbestellung`, `Contact.tAddress`, `ebay_checkout`, `Amazon.tSFPVersand`, `Verkauf.tAuftrag_Log`, `Verkauf.tAuftragAdresse_Log`, `Kunde.tNotiz`, `Ticketsystem.tNachricht`/`tEingangskanalEmail`/`tAusgangskanalEmail`, `tRMRetoure`/`tRMRetoureAbholAdresse`, `tkontodaten`, `tinetzahlungsinfo`, `tZahlung`, `tEMailEinstellung`, `tInkassoUser`, `pf_user`, `WMS.tMobileBenutzer`, `tEingangsrechnung`, `tmahnung`, `Rechnung.tRechnungText`, `Contact.tContact`, `POS_Benutzer`) assert `0 Zeilen`, in denen ein anonymisiertes Feld noch ein Klartext-Muster (z.B. `%@`-Mail außerhalb `@test.local`, echte IBAN-Präfixe) enthält. Konkret: gleiche Menge neutralisierter Spalten wie `clear-customer-fields.sql`.
2. **CONTEXT_INFO-Trigger-Bypass wirkt:** `tkunde` und `tAdresse` wurden tatsächlich verändert (`cName LIKE 'cName_%'`), d.h. die Trigger-Sperre wurde umgangen und nicht still verworfen.
3. **Keine Klartext-Credentials mehr:** `tEMailEinstellung.cPasswortSMTP`/`cSMIMEPasswort`/`cSigPortalPasswort = ''`; `ebay_user.Passwort=''` UND `nGesperrt=1` für alle vormals aktiven; `tOauthToken.nInvalid=1` + Tokens leer; `tShipperAccount.cIban/cBic=''`, `kOAuthToken IS NULL`; `tLizenz.cAuthToken=''`.
4. **Shop-Repoint (PAR-4):** genau die `nTyp=0 AND cServerWeb LIKE 'http%'`-Zeile(n) haben `cServerWeb = ops.Mandant.ShopUrl` und `cAPIKey = ops.Mandant.ShopLicense`; `cBenutzerWeb`/`cPasswortWeb` unverändert; Check24/unicorn2-Zeilen (`cServerWeb='unicorn2'`) unverändert; `@@ROWCOUNT > 0`.
5. **Worker-Neutralisierung (D9):** `pf_user.nGesperrt=1` UND `nAktiv=0`; `tQueue`, `tWorkflowQueue`, `ebay_usermessagequeue`, `ebay_queue_out`, `tGlobalsQueue`, `tDruckQueue` sind leer; `Worker.tTarget` **unverändert** (Zeilenzahl == Restore-Zustand).
6. **Post-Restore-Security:** DB-Owner == `sa`; `is_trustworthy_on = 0`; keine verwaisten Trigger-schützenden Orphan-User mit ownership auf Schemas.
7. **Grant / Zugriff (PAR-1):** Der in `ops.Mandant.LoginName` hinterlegte Login **existiert** als Server-Principal UND ist `db_owner` im Klon. (Fängt den silent-skip aus PAR-1 ab: wenn übersprungen → Assertion rot.)
8. **JTL-Rollen:** `JTL_Reader` und `JTL_Writer` existieren im Klon, sind Member von `db_datareader` bzw. `db_datawriter`, `JTL_Reader` hat EXECUTE auf `Robotico`-Schema; die 8 Member aus `JTL-Rollen.sql` sind (soweit als Principal existent) zugeordnet.
9. **Register-Mandant:** `eazybusiness.dbo.tMandant` enthält genau eine Zeile mit `cDB = <TargetDb>` und `cName = ops.Mandant.DisplayName`; `tBenutzerFirma` für den neuen `kMandant` hat dieselbe Zuordnungszahl wie der Referenz-Mandant (kMandant=1), gefiltert auf existierende Benutzer/Firmen.
10. **Recovery/Zustand des Klons:** Klon-DB ist `MULTI_USER`, `RECOVERY SIMPLE`.
11. **Banking-Endzustand-Äquivalenz (Item 5):** Nach vollem Lauf sind `tkontodaten`/`tinetzahlungsinfo` im Platzhalter-Zustand (`cIBAN LIKE 'IBAN_%'`, `cCVV IS NULL`, `cGueltigkeit IS NULL`) — d.h. das spätere `AnonymizeCustomerData` P8 hat die frühere `InvalidateCredentials`-Behandlung korrekt überschrieben (kein Reihenfolge-Regress).
12. **Idempotenz:** Zweiter Reset desselben Mandanten liefert denselben Endzustand (keine `_deactivated_deactivated`-Doppelsuffixe; `NOT LIKE '%_deactivated'`-Guards greifen).
13. **Status-Kanal ohne Secrets:** `reset.GetResetStatus` liefert **keine** `ShopLicense`-Spalte; ein `ops_reset_executor`-Principal bekommt beim direkten `SELECT ShopLicense FROM ops.Mandant` ein DENY.
