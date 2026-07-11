# QG2 — Code-Quality Review: eazybusiness chain + tooling

**Reviewer:** Opus code-quality (deep pass)
**Scope:** `db-migrations/eazybusiness/**`, `deploy.ps1`, `targets.config.json`,
`tests/lint-migrations.ps1`, `tests/eazybusiness/**`, `tests/compare-objects.sql`,
plus README consistency for those parts.
**Method:** line-by-line read of every file in scope + diff of each ported object against
its `-- Ported from` legacy source in `WorkflowProcedures/`.

Overall: **porting fidelity is high**. The duplicate-order engine
(`fnFindDuplicateOrders` + wrappers), the PayPal table DDL/settings seed, the PayPal
API procs, and the string/CSV functions all match their legacy sources faithfully. The
grate-driven scaffolding removals (`USE`, per-file `BEGIN TRAN`/`XACT_ABORT`, `GO;`,
`IF EXISTS DROP`→`CREATE OR ALTER`, guarded registration) are applied consistently.
Findings below are mostly latent-risk / serviceability / secret-hygiene items — **no
finding blocks deployment outright** (no `critical`).

---

## CQE-1 — Signing-cert password exposed in the grate process command line
**Severity:** important **Size:** M
**File(s):** `db-migrations/deploy.ps1:129`, `:151`

**Evidence:**
```powershell
$userTokens += "CertPassword=$certPassword"
...
foreach ($t in $userTokens) { $grateArgs += "--usertokens=$t" }
...
& grate @grateArgs
```
The plaintext certificate password is passed to `grate` as a command-line argument.
On both Linux and Windows, process arguments are world-readable to any local user for
the lifetime of the `grate` process (`ps aux` / `ps -ef` / `Get-CimInstance
Win32_Process`). Reading `$env:GRATE_CERT_PASSWORD` first does not help — the value
still ends up on the child `grate` command line.

**Why it matters long-term:** the whole point of the `{{CertPassword}}` token + secure
prompt is to keep the module-signing secret out of git *and* out of casual view. Leaking
it into the process table on a shared SQL-ops host defeats that on every `-Scope global`
deploy. Signing keys are the highest-value secret in this system (they authorize `ops`
procedures).

**Proposed fix:** grate only accepts `--usertokens` on the CLI, so the exposure is partly
inherent; make the residual risk explicit and minimal:
1. Document in `deploy.ps1` .NOTES and README §7 that the host must be single-operator /
   least-privilege while a `-Scope global` deploy runs.
2. Confirm no wrapper logs `$grateArgs` (currently OK — nothing prints it).
3. Track upstream: if grate gains a file/stdin token source, switch to it. Add a
   `# @see` gotcha comment on line 151 naming this constraint so the next maintainer
   does not "improve" it by echoing `$grateArgs`.

---

## CQE-2 — PayPal procs PRINT the Basic-auth credentials and the bearer token
**Severity:** important **Size:** S
**File(s):** `eazybusiness/sprocs/Robotico.spPaypalCreateAccessToken.sql:70-76`,
`eazybusiness/sprocs/Robotico.spPaypalTrackingCallApi.sql:115-120`

**Evidence (spPaypalCreateAccessToken):**
```sql
PRINT '@Auth ' + @Auth;              -- 'Basic ' + base64(clientId:secret)
PRINT '@ResponseText ' + @ResponseText;   -- contains the fresh access_token
```
`@Auth` is `'Basic ' + base64(clientId ':' secret)` — i.e. the reversible PayPal
API credentials. `@ResponseText` carries the freshly minted bearer token. Both are
emitted via `PRINT`, which surfaces in `sqlcmd`/grate console output, SSMS messages,
and any place these procs are run manually for debugging.

**Why it matters long-term:** a versioned, deployed production proc should never echo a
reversible credential. Anyone who captures the deploy/exec log of a token refresh
obtains the live PayPal client secret. This is carried over verbatim from the legacy
file, but the migration is the right moment to stop shipping it.

**Proposed fix:** delete the `@Auth` PRINT outright; redact the token in the
`@ResponseText` PRINT (or gate all diagnostic PRINTs behind a `@debug BIT = 0` parameter
that defaults off). Keep the status-line PRINT (`Status …`) — it carries no secret.

---

## CQE-3 — `spGebindeErstellen` hard-codes JTL unit ID `'81'` (convention violation)
**Severity:** important **Size:** M
**File(s):** `eazybusiness/sprocs/CustomWorkflows.spGebindeErstellen.sql:66-71`

**Evidence:**
```sql
-- IMPORTANT: tGebinde.cName is nvarchar(255) but JTL uses it as a
-- foreign key onto tEinheit.kEinheit! The value must be the unit ID.
-- Currently: 81 = "Stk." (piece).
INSERT INTO dbo.tGebinde (kArtikel, cUPC, cEAN, cName, fAnzahl)
VALUES (@kArtikel, @cHAN, @cGTIN, '81', 1);
```
This directly contradicts README §4: *"Never hard-code JTL IDs. Resolve objects by
name; make missing prerequisites a hard FAIL."* `81` is a JTL surrogate key that is not
guaranteed identical across the eazybusiness *tmN* mandant clones (Ebene A targets
`eazybusiness`, `eazybusiness_tm2..tm4`). If any clone's `tEinheit` numbers the "Stk."
unit differently, every Gebinde it creates points at the wrong unit — a silent data-
integrity defect in a production workflow.

**Why it matters long-term:** this is the exact anti-pattern the project adopted a rule
against (the excel_ekl prod-incident lesson). It is also the one place in the chain where
the "resolve-by-name / hard-FAIL" convention is violated while the header comment
acknowledges the smell but ships it anyway.

**Proposed fix:** resolve the unit by name and fail loudly if absent:
```sql
DECLARE @kEinheitStk INT =
    (SELECT kEinheit FROM dbo.tEinheit WHERE cName = N'Stk.');   -- verify the resolve column
IF @kEinheitStk IS NULL
    THROW 50000, 'tEinheit "Stk." not found — cannot create Gebinde.', 1;
...
VALUES (@kArtikel, @cHAN, @cGTIN, CAST(@kEinheitStk AS NVARCHAR(255)), 1);
```
Trade-off: adds a name lookup on a vendor table; acceptable and exactly what the
convention prescribes. (Confirm whether `tEinheit` keys on `cName` or a localized
`tEinheitSprache` before finalizing the lookup.)

---

## CQE-4 — CustomFieldAPI test still asserts the removed `-1` return-code contract
**Severity:** important **Size:** S
**File(s):** `tests/eazybusiness/CustomFieldAPI_Tests.sql:245-248`

**Evidence:**
```sql
IF @returnCode = -1
BEGIN PRINT '  + Error code -1 for non-existing field'; SET @t6_passed += 1; END
ELSE
    PRINT '  x Unexpected return code: ' + CAST(@returnCode AS NVARCHAR(10));
```
The legacy procs returned `-1` on a missing field definition
(`WorkflowProcedures/api/CustomFieldAPI.sql:162,317`). The **ported** procs deliberately
dropped that path — `spEnsureArticleCustomField` now `RAISERROR(...,16,...)` inside `TRY`
→ `CATCH` → `THROW`, and `spSetArticleCustomFieldValue` propagates the throw (documented
in both file headers). So `@returnCode = -1` can never be true; the EXEC throws and
control jumps to the test's own `CATCH`, whose `ERROR_MESSAGE() LIKE '%Custom field
definition not found%'` check is what actually passes Test 6.

**Why it matters long-term:** the test suite is the plan's "executable spec". A green test
whose primary assertion covers a contract that no longer exists gives false confidence and
misleads the next maintainer into thinking `-1` is still a supported return value.

**Proposed fix:** replace the dead `-1` branch with an explicit "should have thrown"
failure, keeping the `CATCH` branch as the real assertion:
```sql
-- Reaching here means no throw occurred — that is the failure.
PRINT '  x Expected a thrown error for a non-existing field definition; none occurred';
```

---

## CQE-5 — EscapedCSV/string API silently requires SQL Server 2022+ (STRING_SPLIT ordinal)
**Severity:** important **Size:** S
**File(s):** `eazybusiness/functions/Robotico.fnEscapedCSVParseLine.sql:24`,
`eazybusiness/functions/Robotico.fnStringTrimToMaxLines.sql:37`
(consumers: both history procs, `fnEscapedCSVGetField`)

**Evidence:**
```sql
FROM STRING_SPLIT(@line, @separator, 1)          -- 3-arg form (enable_ordinal)
```
The 3-argument `STRING_SPLIT(..., enable_ordinal)` was introduced in **SQL Server 2022
(16.x)**. No file states this prerequisite; `fnFindDuplicateOrders` even documents a
lower floor ("Requires SQL Server 2017+"), which is correct for *itself* (STRING_AGG) but
invites the reader to assume the whole Ebene-A chain runs on 2017+. `CREATE` succeeds on
any version — the failure only appears at **runtime**, when the label/price/duplicate
workflows execute, and only on a database whose engine/compat predates the ordinal
feature. Ebene-A objects travel with mandant clones (backup+restore), and a clone can
easily carry a lower database compatibility level than its host server.

**Why it matters long-term:** a latent, no-diagnostic runtime landmine that only trips on
some clones. The whole point of versioning the copyable content per-clone is defeated if a
clone silently can't run it.

**Proposed fix:** add an explicit prerequisite note to the EscapedCSV/string function
headers and README §8 ("Requires SQL Server 2022+ / the `STRING_SPLIT` ordinal argument;
verify each target's `DATABASEPROPERTYEX(db,'Version')` / compatibility level"). Optionally
add a compat-level check to `compare-objects.sql` or the baseline runbook so a low-compat
clone is caught before the feature is relied on.

---

## CQE-6 — `spPaypalCreateAccessToken` INSERT relies on positional mapping with misleading aliases
**Severity:** nice **Size:** S
**File(s):** `eazybusiness/sprocs/Robotico.spPaypalCreateAccessToken.sql:85-101`

**Evidence:**
```sql
INSERT INTO Robotico.tPaypalAccessToken
SELECT scope         as [cScope],
       ...
       expires_in    as nExpiresIn,     -- table column is nExpiresInSeconds
       getutcdate()  as dAuthDate,      -- table column is dTokenCreated
       @IsProduction as bProduction
FROM OPENJSON(@ResponseText) WITH ( ... )
```
There is no explicit target column list, so the 7 SELECT values map **positionally** onto
the 7 non-identity columns. It happens to be correct today, but two of the SELECT aliases
(`nExpiresIn`, `dAuthDate`) name columns that do not exist — pure noise that reads as if it
were a named mapping. A future reorder of the table DDL or the SELECT would silently
mis-store the token (e.g. write the token type into `cAccessToken`).

**Why it matters long-term:** column-list-less `INSERT … SELECT` into a table you own is a
fragility the project can trivially remove; the misleading aliases make it worse by faking
intent.

**Proposed fix:** add the explicit column list and drop the fake aliases:
```sql
INSERT INTO Robotico.tPaypalAccessToken
    (cScope, cAccessToken, cTokenType, cAppID, nExpiresInSeconds, dTokenCreated, bProduction)
SELECT scope, access_token, token_type, app_id, expires_in, GETUTCDATE(), @IsProduction
FROM OPENJSON(@ResponseText) WITH ( ... );
```

---

## CQE-7 — Pure scalar functions are not `WITH SCHEMABINDING` (blocks inlining + determinism)
**Severity:** nice **Size:** S
**File(s):** `Robotico.fnStringParseGermanDecimal.sql`, `Robotico.fnStringCountLines.sql`,
`Robotico.fnStringStripWhitespace.sql`, `Robotico.fnStringIsEffectivelyEmpty.sql`,
`Robotico.fnEscapedCSVSanitize.sql`

**Evidence:** e.g. `fnStringParseGermanDecimal.sql:12`
```sql
RETURNS DECIMAL(25,13)
AS
BEGIN
```
None of these table-free scalar UDFs declare `WITH SCHEMABINDING`. SCHEMABINDING marks a
UDF deterministic/precise and is a **prerequisite for scalar-UDF inlining** (Froid, SQL
Server 2019+) and for use in computed columns / indexed views. These five functions touch
no tables, so schemabinding carries no coupling cost.

**Why it matters long-term:** these functions are called per-row inside the history procs
(`fnStringCountLines`, `fnEscapedCSVSanitize` on every label). Non-inlined scalar UDFs are
a classic hidden performance cliff; schemabinding is the cheap enabler.

**Proposed fix:** add `WITH SCHEMABINDING` after the `RETURNS` clause of the five pure
functions. **Do NOT** schemabind the table-touching functions
(`fnGetArticleCustomFieldValue`, `fnFindDuplicateOrders`, `fnHasOlderDuplicateOrder`,
`fnEscapedCSVGetField`→ depends on iTVF): binding them to `dbo.*`/`Verkauf.*` vendor
tables would let a JTL schema change break our deploy. Call this split out in the headers.

---

## CQE-8 — `deploy.ps1` leaves the plaintext cert password in unmanaged memory
**Severity:** nice **Size:** S
**File(s):** `db-migrations/deploy.ps1:125-128`

**Evidence:**
```powershell
$secure = Read-Host 'RoboticoOpsSigning certificate password' -AsSecureString
$certPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
```
`SecureStringToBSTR` allocates an unmanaged BSTR holding the plaintext; the pointer is
never captured and never zeroed/freed, so the secret lingers in process memory (and the
BSTR leaks) until GC/exit.

**Why it matters long-term:** minor but it undercuts the SecureString ceremony directly
above it. Cheap to do correctly.

**Proposed fix:**
```powershell
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try   { $certPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
```

---

## CQE-9 — `spPaypalTrackingCallApi` silently drops shipments with an unmapped carrier
**Severity:** nice **Size:** S
**File(s):** `eazybusiness/sprocs/Robotico.spPaypalTrackingCallApi.sql:56-81`

**Evidence:**
```sql
CASE
    WHEN tVA.cName LIKE '%dhl%' OR tVA.cName LIKE '%warenpost%' THEN 'DHL_DEUTSCHE_POST'
    WHEN tVA.cName LIKE '%post%' THEN 'DEUTSCHE_DE'
    WHEN tVA.cName LIKE '%dpd%' THEN 'DPD'
    END                   as cPaypalCarrier          -- no ELSE -> NULL
...
DELETE FROM @tRawDataForApi WHERE ... OR cPaypalCarrier IS NULL ...
IF (SELECT COUNT(*) FROM @tRawDataForApi) = 0
    BEGIN PRINT 'No data found ...'; RETURN END
```
A shipment on any carrier outside the three `LIKE` patterns gets `NULL`, is deleted from
the batch, and — if it was the only row — the proc returns "No data found". PayPal is
never told about that shipment, and there is no signal that a *known* shipment was dropped
for want of a carrier mapping (only the generic "no data" line).

**Why it matters long-term:** a new/renamed shipping method silently stops PayPal tracking
notification with no trace to debug from. Carried over from legacy, but the versioned proc
is where to add observability.

**Proposed fix:** before the `DELETE`, log rows that have data but an unmapped carrier into
`Robotico.tPaypalTrackingLog` (source = 'spPaypalTrackingCallApi/unmapped-carrier',
description = the `cVersandartName`), so drops are auditable.

---

## CQE-10 — `compare-objects.sql` cannot actually compare files to the DB (misleading header)
**Severity:** nice **Size:** S (doc) / M (real file-compare)
**File(s):** `tests/compare-objects.sql:5-11,53-57`

**Evidence:** header claims
```
-- compared against what db-migrations/eazybusiness/ would produce.
```
but the script only hashes the **deployed** side:
```sql
CONVERT(VARCHAR(64), HASHBYTES('SHA2_256',
    CONVERT(NVARCHAR(MAX), OBJECT_DEFINITION(o.object_id))), 2)
```
`OBJECT_DEFINITION` returns the engine-normalized module text (as stored), which never
byte-matches the file's raw `CREATE OR ALTER …` source. So a file↔DB hash comparison is
impossible with this tool; in practice it only supports **DB↔DB** drift detection (e.g.
prod vs. a clone, or before/after a JTL update — which the "post-update smoke" use
correctly describes).

**Why it matters long-term:** the "baseline pre-check … confirm the file contents match
the deployed objects" use case, as written, cannot be performed with this script — a
maintainer will try and get all-mismatches.

**Proposed fix:** reword the header to scope it to DB↔DB comparison, and describe the
baseline pre-check as "run against two databases and diff", OR add a companion step that
extracts each file's object body and normalizes it the same way before hashing.

---

## CQE-11 — Lint does not enforce `up/` number monotonicity/uniqueness
**Severity:** nice **Size:** S
**File(s):** `tests/lint-migrations.ps1:126-131`

**Evidence:**
```powershell
'one-time' {
    if ($baseName -notmatch '^[0-9]{4}_[a-z0-9_]+$') { Add-Error ... }
}
```
The rule validates the `NNNN_snake_case` *shape* only. Two files numbered `0001_*.sql`,
or a gap that reorders intent, both pass. grate runs `up/` in filename order and tracks by
hash, so a duplicate/misordered number is a real ordering hazard the "executable contract"
does not catch.

**Why it matters long-term:** the README sells the lint as the mechanical form of the
conventions; monotonic one-time numbering is a stated convention (§3) that goes unchecked.

**Proposed fix:** after the file loop, per chain collect the 4-digit prefixes of `up/`
files and `Add-Error` on any duplicate (optionally warn on gaps).

---

## CQE-12 — `spArticleAppendPriceHistory` hard-codes 19% VAT for the stored gross price
**Severity:** nice **Size:** M
**File(s):** `eazybusiness/sprocs/CustomWorkflows.spArticleAppendPriceHistory.sql:25,91`

**Evidence:**
```sql
DECLARE @VAT_RATE DECIMAL(5,4) = 0.19;
...
SET @vkBrutto = @currentVkNetto * (1 + @VAT_RATE);
```
Articles taxed at the reduced rate (7% — books, some food/agricultural goods) get a wrong
`VkBrutto` written into the price-history field. It is an informational history value (not
used for billing), so impact is display-only, but it is silently wrong for a subset of
articles.

**Why it matters long-term:** a maintainer reading the history later trusts the brutto
column. Carried over from legacy; the migration is a reasonable point to correct or drop.

**Proposed fix:** resolve the article's actual tax rate
(`dbo.tArtikel` → `tSteuersatz`/`tSteuerklasse`, or the position tax where applicable) and
compute brutto from it; or, if brutto adds no value in history, drop the derived field and
store net only.

---

## CQE-13 — `deploy.ps1` silently ignores `-Target` under `-Scope global`
**Severity:** nice **Size:** S
**File(s):** `db-migrations/deploy.ps1:96-100`

**Evidence:**
```powershell
'global' {
    $sqlFilesDirectory = Join-Path $scriptRoot 'global'
    $schema = 'ops'
    $databases = @($envConfig.global)
}
```
`-Target` is accepted by the param block but ignored here (documented in .PARAMETER, but
no runtime feedback). An operator who mistypes `-Scope` while passing `-Target
eazybusiness_tm2` gets a global deploy with no warning.

**Why it matters long-term:** cheap guardrail on a script whose whole reason to exist is
"do not fat-finger a production deploy".

**Proposed fix:**
```powershell
'global' {
    if ($Target) { Write-Warning "-Target '$Target' ignored for -Scope global (single DB)." }
    ...
}
```

---

## Reviewed clean / notable non-findings

- **Duplicate-order engine (`fnFindDuplicateOrders` + `fnHasOlderDuplicateOrder` +
  `spCheckDuplicateOrder`):** byte-faithful CTE logic vs. legacy
  `Duplikaterkennung_Bestellungen.sql`; scaffolding removal correct; tie-break + storno
  filter + fingerprint semantics intact.
- **Label-history port — deliberate, documented enhancement, not drift:** the port routes
  each label through `fnEscapedCSVSanitize` and changed the `STRING_AGG` `ORDER BY` from
  raw `l.cName` (legacy) to the sanitized `t.label`. Write and read-back both order by the
  sanitized form, so change-detection stays stable (verified against read-back at
  `spArticleAppendLabelHistory.sql:76-77`). One benign side effect worth awareness (no fix
  needed): the very first call after upgrading a DB that already has *legacy*-written
  history may re-order labels and append one spurious history entry.
- **Return-contract migration is consistent** across `spEnsureArticleCustomField` /
  `spSetArticleCustomFieldValue` (throw-based, `RETURN 0` on success); only the *test*
  lags (CQE-4).
- **Registration guarding** (`IF OBJECT_ID('CustomWorkflows._SetActionDisplayName',…)`)
  is applied uniformly across all 7 `CustomWorkflows.sp*` action files and matches README
  §6 exactly.
- **`GO;`, `USE`, `DROP SCHEMA`, forbidden `RoboticoEKL`/`spCMArtikel*` tokens:** none
  present in any in-scope file (lint rules a/b/d would catch them; manual read confirms).
- **`spZustandartikelLieferantSetzen`** correctly bakes `SET ANSI_NULLS/QUOTED_IDENTIFIER
  ON` before the `CREATE` (filtered-index requirement documented) and stays idempotent.
- **PayPal table DDL port (0002)** faithfully reproduces the legacy schema and *fixes* the
  legacy index-name typo (`IX_Robotic_` → `IX_Robotico_`); MERGE seed leaves credential
  keys empty (no secrets in git). Note the persisted column typo `cBescheibung1/2`
  ("Beschreibung") is carried over verbatim — since `0002` has not shipped to prod yet, it
  could be corrected in place now rather than needing a follow-up `up/` script later; left
  out of the numbered findings as it is cosmetic and inside an as-yet-unapplied one-time
  script.
- **`targets.config.json`** shape is clean and extensible (per-environment `server` +
  `eazybusiness[]` + `global`); no secrets; mandant clones modeled as ordinary Ebene-A
  targets per D11.
- **PROD gate** (`deploy.ps1:104-117`) lists exact target DBs, defaults to abort on empty
  input, exits non-zero on abort, and correctly skips confirmation only for `-DryRun`.
