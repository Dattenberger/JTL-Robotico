# QG2 — Code-Quality Review: GLOBAL chain (Ebene B / RoboticoOps reset)

**Reviewer:** CODE-QUALITY (deep, line-by-line)
**Scope:** `db-migrations/global/**`, `db-migrations/tests/global/**`, `db-migrations/README.md` (global-chain sections)
**Verdict:** Security model is **sound** — no critical findings. The signed-SP / sysadmin-job split, the four-layer `eazybusiness`-target guard (CHECK constraint + Start-SP + ProcessNext re-validation + per-internal-proc guard), the catalog-derived re-signing set, and the "no caller data ever concatenated into dynamic SQL" invariant all hold up. Findings below are correctness/robustness edges, one prod-write blast-radius that must be documented, and maintainability/DRY debt that the user's "extensible" bar makes worth closing.

Grep confirms the caller-facing surface is safe: the only low-privilege input is `@MandantKey`, which is never concatenated into SQL — it is validated by a parameterised `SELECT` and otherwise only used to build an applock name. The 12 findings are ordered important → nice.

---

## CQG-1 — Hard `sp_start_job` failure orphans a `queued` row that later executes unexpectedly

**Severity:** important
**File:** `db-migrations/global/sprocs/reset.StartTestmandantReset.sql:54-72`

**Evidence:**
```sql
INSERT ops.ResetRequest (MandantKey, TargetDb, Status, RequestedBy, RequestedAt, ModifiedAt)
VALUES (@MandantKey, @TargetDb, N'queued', @caller, SYSUTCDATETIME(), SYSUTCDATETIME());
SET @RequestId = CAST(SCOPE_IDENTITY() AS int);

BEGIN TRY
    EXEC msdb.dbo.sp_start_job @job_name = N'RoboticoOps - Testmandant Reset';
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() <> 22022 THROW;   -- 22022 = already running (benign)
END CATCH
```
The inner CATCH only tolerates 22022. For **any other** `sp_start_job` failure (job missing → 14262, msdb permission error from a dropped signature, Agent stopped), the outer CATCH releases the applock and re-throws — but the `queued` row **stays**. The caller sees an error and assumes the reset failed, yet:
- the filtered unique index `UX_ResetRequest_Active` now blocks them from resubmitting (they get `51004 "already queued or running"`), and
- the next time *any* reset is started successfully, the running job's while-loop picks up this orphaned row and **executes a destructive clone the caller believed had failed**.

**Why it matters long-term:** a reset is destructive (RESTORE … WITH REPLACE over a clone). "Thought it failed, ran later anyway, and I couldn't retry in the meantime" is exactly the surprising, un-auditable behaviour this feature exists to eliminate. It will surface rarely (only on a broken job / lost signature) but at the worst time.

**Proposed fix (S):** move the `sp_start_job` CATCH so a non-22022 failure marks the just-inserted row before re-throwing:
```sql
BEGIN CATCH
    IF ERROR_NUMBER() <> 22022
    BEGIN
        UPDATE ops.ResetRequest
           SET Status = N'failed',
               ErrorText = N'sp_start_job failed: ' + ERROR_MESSAGE(),
               FinishedAt = SYSUTCDATETIME(), ModifiedAt = SYSUTCDATETIME()
         WHERE RequestId = @RequestId;
        THROW;
    END
END CATCH
```
This keeps the audit row (who tried, why it failed) and frees the mandant for an immediate retry, while preserving the benign-22022 path.

**Size:** S

---

## CQG-2 — `internal_CloneDatabase` assumes exactly one data + one log file; multi-file source breaks RESTORE

**Severity:** important
**File:** `db-migrations/global/sprocs/reset.internal_CloneDatabase.sql:36-61`

**Evidence:**
```sql
SELECT @DataLogical = name FROM sys.master_files WHERE database_id = DB_ID(@SourceDb) AND type_desc = 'ROWS';
SELECT @LogLogical  = name FROM sys.master_files WHERE database_id = DB_ID(@SourceDb) AND type_desc = 'LOG';
...
SET @sql = N'RESTORE DATABASE ' + QUOTENAME(@TargetDb)
         + N' FROM DISK = @bf WITH MOVE @dl TO @dp, MOVE @ll TO @lp, REPLACE, STATS = 10;';
```
If the source `eazybusiness` ever has **more than one** ROWS file (a second data file / filegroup) or more than one LOG file, the `SELECT @DataLogical = name` collapses multiple rows into one arbitrarily-chosen logical name, and the RESTORE emits only that one `MOVE`. SQL Server then either fails the RESTORE (unmoved file has nowhere to go) or restores the extra file to its **original prod path** — a path collision or, worse, a file written next to prod. The failure message ("logical file … is not part of database … Use WITH MOVE") does not point at "your DB has multiple files".

**Why it matters long-term:** a JTL DB is single-file *today*, so this is latent — but the whole point of the ops chain is to outlive ad-hoc assumptions. The day someone adds a filegroup, the reset breaks opaquely and the fix requires understanding RESTORE internals under pressure.

**Proposed fix (M):** enumerate all logical files and build the `MOVE` list dynamically:
```sql
DECLARE @moves nvarchar(max) = N'';
SELECT @moves = @moves + N', MOVE ' + QUOTENAME(name, '''')
              + N' TO ''' + REPLACE(@TargetDataDir + N'\' + @TargetDb + N'_' + name
                     + CASE type_desc WHEN 'LOG' THEN N'.ldf' ELSE N'.mdf' END, '''', '''''') + N''''
FROM sys.master_files WHERE database_id = DB_ID(@SourceDb);
```
then splice `@moves` (leading comma trimmed) into the RESTORE. Note this reintroduces path-string building — keep the physical path derived only from the config dir + the server-side logical name (both trusted), and QUOTENAME/escape as above. Alternatively, at minimum, add a hard FAIL when `(SELECT COUNT(*) FROM sys.master_files WHERE … type_desc='ROWS') > 1` so the assumption is asserted, not silently wrong.

**Size:** M

---

## CQG-3 — grate `{{CertPassword}}` is textually substituted into single-quoted SQL literals with no escaping

**Severity:** important
**Files:** `db-migrations/global/up/0011_signing_certificate.sql:28`, `db-migrations/global/permissions/900_resign_procedures.sql:39-41`, `db-migrations/deploy.ps1:122-130`

**Evidence:**
```sql
-- 0011
CREATE CERTIFICATE RoboticoOpsSigning
    ENCRYPTION BY PASSWORD = '{{CertPassword}}'
-- 900
SET @sql = N'ADD SIGNATURE TO ' + @procName
         + N' BY CERTIFICATE RoboticoOpsSigning'
         + N' WITH PASSWORD = ''{{CertPassword}}'';';
EXEC sys.sp_executesql @sql;
```
grate replaces `{{CertPassword}}` by raw text *inside a single-quoted string literal*. A password containing a single quote (`O'Brien2024!`) turns `PASSWORD = 'O'Brien2024!'` into a syntax error — and, in 900, the token is spliced into a **dynamic** SQL string that is then `EXEC`'d, so a quote is a classic string-break / injection surface. The password is operator-controlled at deploy (prompt or `$env:GRATE_CERT_PASSWORD`), not caller-controlled, so this is robustness-with-a-sharp-edge rather than a remote exploit — but lint rule (g) explicitly cannot see grate-token substitution, so nothing catches it.

**Why it matters long-term:** the failure is an opaque deploy break at cert-create or re-sign time, and it silently constrains what passwords are allowed. A future operator who picks a "strong" password with a quote loses an afternoon.

**Proposed fix (S):** validate in `deploy.ps1` right after reading the password — reject any `'` (and ideally any char outside a documented safe set) with a clear message; document the constraint in README §7's cert note. Cheap, and it moves the failure to a legible spot.

**Size:** S

---

## CQG-4 — No guarantee the cert-create password (0011, one-time) equals the re-sign password (900, everytime)

**Severity:** important
**Files:** `db-migrations/global/up/0011_signing_certificate.sql:27-32`, `db-migrations/global/permissions/900_resign_procedures.sql:39-42`

**Evidence:** `0011` is an `up/` **one-time** script — the cert is created once, with whatever `{{CertPassword}}` the *first* global deploy supplied. `900` runs **everytime** and unlocks that same private key via `ADD SIGNATURE … WITH PASSWORD = '{{CertPassword}}'`. Nothing ties the two passwords together across deploys. If a later `deploy.ps1 -Scope global` is run with a different `$env:GRATE_CERT_PASSWORD` (or a mistyped prompt), `900` fails with SQL Server's opaque *"The private key password of the certificate could not be used"* — and because `900` ends in a hard `THROW 50900` if any EXECUTE-AS proc is left unsigned, the whole deploy aborts with two stacked errors that don't say "wrong password".

**Why it matters long-term:** the password lives in `~/.claude-secrets.md` per the runbook, but there is no machine check that the value in hand is the one the cert was born with. This is the "single sharpest edge" the ADR already flags for signatures, compounded by a silent password-mismatch mode.

**Proposed fix (S):** (a) document the invariant prominently in the 0011 header and README §7 ("the cert password is set once at first global deploy and can never change without dropping+recreating the cert and re-signing"); (b) in `900`, wrap the `ADD SIGNATURE` `EXEC` in a TRY/CATCH that, on the private-key error, THROWs a purpose-written message naming the likely cause (password ≠ the one used in 0011). Keeps the abort, replaces the opaqueness.

**Size:** S

---

## CQG-5 — `internal_RegisterMandant` writes into prod `eazybusiness.dbo.tMandant`; non-target write failures are downgraded to a WARN while the reset still reports `succeeded`

**Severity:** important
**File:** `db-migrations/global/sprocs/reset.internal_RegisterMandant.sql:47-82`

**Evidence:**
```sql
SET @sql = N'SELECT DISTINCT cDB FROM ' + QUOTENAME(@SourceDb) + N'.dbo.tMandant WHERE cDB IS NOT NULL AND DB_ID(cDB) IS NOT NULL;';
INSERT INTO @dbs (name) EXEC sp_executesql @sql;   -- includes 'eazybusiness' itself
...
BEGIN CATCH
    IF @db = @TargetDb  BEGIN CLOSE dbcur; DEALLOCATE dbcur; THROW; END
    SET @warnings = @warnings + ... + N' register: WARN ' + @db + N': ' + ERROR_MESSAGE() + NCHAR(10);
END CATCH
```
By JTL's shared-registry design the new mandant must be upserted into **every** mandant DB so it appears in the login list — and that set includes the production `eazybusiness` DB (`kMandant=1 → cDB='eazybusiness'`). So a normal reset **writes an INSERT/UPDATE into `eazybusiness.dbo.tMandant`**. That is inherent and probably intended (it is how the source `register-mandant.sql` works), but two things make it a review flag rather than a shrug:

1. **The per-`@TargetDb` guard only validates the *target* clone** (line 20). Nothing in this proc scopes or asserts *which* DBs get written — the write set is data-driven from `tMandant`. The blast radius (a prod-DB write on every reset) is invisible from the proc header.
2. **A write failure against a non-target DB is swallowed into `@warnings`** and the step still completes; the pipeline marks the request `succeeded`. So a reset can report success while the mandant is only *partially* registered across the estate (e.g. a PK collision on `kMandant` in another mandant DB — `@k` is `MAX+1` computed from `eazybusiness` and may already be taken in `eazybusiness_tm2`).

**Why it matters long-term:** "succeeded" that isn't fully true is the exact opacity the audit trail is meant to kill. A colleague polling `GetResetStatus` sees green; the mandant may be missing from some DBs' login lists, and the prod write is undocumented at the code site.

**Proposed fix (M):**
- Add a header block documenting that this step writes `dbo.tMandant` rows into **all** mandant DBs incl. prod `eazybusiness`, and why (JTL shared registry).
- Count non-target warnings and reflect them in the StepLog summary line explicitly (e.g. `register: kMandant=42 (…); 1 non-target DB WARN — see above`) so a partial registration is visible without reading the whole log; optionally surface a distinct StepLog marker the runbook/validation can grep.
- Confirm with the owner whether a non-target write failure should really be non-fatal (current behaviour) — document the decision either way.

**Size:** M

---

## CQG-6 — StepLog append idiom duplicated ~20× (and 11× inside one proc); no single owner of the log format

**Severity:** important (maintainability / extensibility — the user's stated bar)
**Files:** every `reset.internal_*.sql` + `reset.internal_AnonymizeCustomerData.sql:158,269,306,321,356,381,410,449,487,524,532`

**Evidence (the same shape, everywhere):**
```sql
UPDATE ops.ResetRequest
   SET StepLog = ISNULL(StepLog, N'') + CONVERT(nvarchar(19), SYSUTCDATETIME(), 126)
               + N' anon.P4 amazon-sfp ok' + NCHAR(10),
       ModifiedAt = SYSUTCDATETIME()
 WHERE RequestId = @RequestId;
```
The timestamp format (`style 126`, 19 chars), the `ISNULL(…,'') + … + NCHAR(10)` framing, and the `ModifiedAt` bump are re-typed in ~30 places. Any change to the StepLog convention (e.g. add the step's elapsed seconds, switch to a structured JSON line for `GetResetStatus` to parse, or add a severity tag) is a 30-site edit — and the AnonymizeCustomerData copies already drift from the pipeline copies in phrasing.

**Why it matters long-term:** this is the observability surface of the whole feature. Centralising it is the difference between "extend the log format in one proc" and "hope you found all 30 call sites."

**Proposed fix (M):** add `reset.internal_AppendStepLog @RequestId int, @Message nvarchar(max)` that owns the timestamp + framing + `ModifiedAt`, and replace every inline UPDATE with `EXEC reset.internal_AppendStepLog @RequestId, N'anon.P4 amazon-sfp ok';`. All internal steps already run in RoboticoOps context, so the helper is a plain local proc — no cross-DB concern. Add it to `validate_structure.sql`'s required-object list. This also makes the per-block logging in AnonymizeCustomerData a one-liner and kills the phrasing drift.

**Size:** M

---

## CQG-7 — Magic 4-hour stale-reclaim threshold hard-coded in the orchestrator

**Severity:** nice
**File:** `db-migrations/global/sprocs/reset.ProcessNextResetRequest.sql:31-32`

**Evidence:**
```sql
WHERE Status = N'running'
  AND StartedAt < DATEADD(HOUR, -4, SYSUTCDATETIME());
```
The 4 h window (how long a `running` row may sit before it is assumed to be a dead job and reclaimed as `failed`) is a policy value baked into code. A 27 GB restore that legitimately runs long, or an ops decision to tune the window, requires a code redeploy (and a re-sign-safe global deploy) rather than a data change.

**Why it matters long-term:** `ops.Config` already exists precisely to lift such knobs out of code (`SourceDb`, `BackupFile`, `ReferenceMandant`). This one belongs there for consistency and serviceability.

**Proposed fix (S):** seed `ops.Config('StaleRunningHours', '4')` in `0020`, read it at the top of `ProcessNextResetRequest` with a sane fallback (`ISNULL(TRY_CONVERT(int, …), 4)`), and use it in the `DATEADD`.

**Size:** S

---

## CQG-8 — Agent-job name is a magic string repeated across 4 files

**Severity:** nice
**Files:** `reset.StartTestmandantReset.sql:61`, `runAfterOtherAnyTimeScripts/reset.EnsureAgentJob.sql:23`, `permissions/200_ensure_agent_job.sql:18`, and the job `@description`

**Evidence:** `N'RoboticoOps - Testmandant Reset'` is hard-coded in the Start SP (`sp_start_job`), in `EnsureAgentJob` (create), and in `200_ensure_agent_job` (existence check). A one-character drift in any single copy silently breaks the signed-SP → job bridge: `sp_start_job` would throw 14262 (caught only for 22022 → re-thrown per CQG-1) or the existence check would loop-recreate.

**Why it matters long-term:** three independently-maintained spellings of one identity is a classic drift trap; the coupling is invisible until it breaks at runtime in msdb.

**Proposed fix (S):** either read the name from `ops.Config('AgentJobName')` in all three procs, or (lighter) add a cross-referencing comment in each of the three files naming the other two as the co-owners of the literal. Config is the more sustainable option and matches CQG-7.

**Size:** S

---

## CQG-9 — ADR invariant "never source == target" is only enforced implicitly by the name pattern

**Severity:** nice
**File:** `db-migrations/global/sprocs/reset.internal_CloneDatabase.sql:19,27-29`

**Evidence:** the guard is `@TargetDb = N'eazybusiness' OR @TargetDb NOT LIKE N'eazybusiness[_]%'`, and `@SourceDb` is read from `ops.Config`. ADR `adr-module-signing-reset` D6 lists **"never source==target"** as a defense-in-depth invariant, but no code compares the two. Today it holds only because `SourceDb='eazybusiness'` and the target must match `eazybusiness[_]%`. If `ops.Config.SourceDb` is ever repointed to a clone (e.g. to stage from `eazybusiness_tm2`), a `BACKUP eazybusiness_tm2 … RESTORE eazybusiness_tm2 WITH REPLACE` self-clone becomes possible — wasteful and confusing, and it violates the documented invariant silently.

**Why it matters long-term:** the ADR says the guard exists; the code should make it true rather than incidentally-true, so a future config change can't quietly break it.

**Proposed fix (S):** after resolving `@SourceDb`, add `IF @TargetDb = @SourceDb THROW 51014, 'internal_CloneDatabase refused: source and target are the same database.', 1;`.

**Size:** S

---

## CQG-10 — `pf_user` guard inconsistency: column-guarded in NeutralizeWorker, only OBJECT_ID-guarded in AnonymizeCustomerData P9

**Severity:** nice
**Files:** `reset.internal_NeutralizeWorker.sql:29-32` vs `reset.internal_AnonymizeCustomerData.sql:469-477`

**Evidence:**
```sql
-- NeutralizeWorker: per-column guard
IF OBJECT_ID('dbo.pf_user') IS NOT NULL AND COL_LENGTH('dbo.pf_user','nGesperrt') IS NOT NULL
    UPDATE dbo.pf_user SET nGesperrt = 1;
-- AnonymizeCustomerData P9: table-only guard, 6 columns assumed present
IF OBJECT_ID('dbo.pf_user', 'U') IS NOT NULL
UPDATE dbo.pf_user SET cName=…, cAuthToken=NULL, cAmazonAuthToken=NULL,
    cFBAVersandmailKopie=…, cFBAKommentar=…, cAnmerkung=… WHERE kUser IS NOT NULL;
```
`pf_user`'s presence/shape in prod clones is explicitly an **open question (O4)** in the architecture doc — yet the anon block assumes six specific columns exist. On a clone where `pf_user` exists but its schema differs, this block THROWs and fails the *entire* reset (the pipeline CATCH marks it `failed`), whereas NeutralizeWorker degrades gracefully on the same table.

**Why it matters long-term:** two steps touch the same uncertain table with opposite resilience. Given O4 is unresolved, the fragile one is the liability.

**Proposed fix (S):** make P9's `pf_user` update consistent with NeutralizeWorker — either COL_LENGTH-guard each assigned column, or wrap the pf_user UPDATE in its own TRY/CATCH that logs a StepLog WARN rather than failing the reset. Keep the reset resilient to the very schema uncertainty the doc flags.

**Size:** S

---

## CQG-11 — Config path locals narrower than the column → silent truncation

**Severity:** nice
**File:** `db-migrations/global/sprocs/reset.internal_CloneDatabase.sql:22-29`

**Evidence:** `@BackupFile nvarchar(260)` and `@TargetDataDir nvarchar(260)` are populated from `ops.Config.ConfigValue`, which is `nvarchar(1000)` (`0002_ops_schema_tables.sql:61`). A path longer than 260 chars is silently truncated on assignment, producing a wrong `BACKUP TO DISK` / restore path with no error until the disk op fails on a nonsense path.

**Why it matters long-term:** cheap correctness; long UNC/data paths are plausible and the truncation is invisible.

**Proposed fix (S):** widen both locals to `nvarchar(1000)` (or `nvarchar(4000)`) to match the source column; SQL Server's `MAX_PATH` for `BACKUP`/`RESTORE` is 260 for the *final* path but the config value should round-trip without loss and fail loudly if too long.

**Size:** S

---

## CQG-12 — `StartTestmandantReset` omits `SET XACT_ABORT ON`

**Severity:** nice
**File:** `db-migrations/global/sprocs/reset.StartTestmandantReset.sql:22-23`

**Evidence:** `ProcessNextResetRequest` sets `XACT_ABORT ON` (line 23); the Start SP sets only `NOCOUNT ON`. The Start SP does an applock + INSERT + cross-DB `sp_start_job` with hand-rolled THROW handling and explicit applock release. It works today because the applock is `Session`-owned (no transaction is opened) and the CATCH cleans up — so this is hygiene, not a live bug. But the asymmetry invites a future editor to add a multi-statement transaction here without XACT_ABORT and inherit the classic "doomed transaction / orphaned lock" foot-gun.

**Why it matters long-term:** consistency across the reset procs and a safer default for the one proc a low-privilege caller invokes directly.

**Proposed fix (S):** add `SET XACT_ABORT ON;` alongside `SET NOCOUNT ON;`.

**Size:** S

---

## Reviewed clean (no findings)

- `db-migrations/global/up/0001_roboticoops_settings.sql` — collation/TRUSTWORTHY hard-fail asserts and the idempotent owner re-authorize are exactly right for a one-time settings guard.
- `db-migrations/global/up/0002_ops_schema_tables.sql` — table design is solid: the `CK_ops_Mandant_TargetDb` CHECK, the filtered `UX_ResetRequest_Active` unique index, and the FK are the correct declarative backstops; `AUTHORIZATION dbo` for ownership chaining is well-reasoned.
- `db-migrations/global/up/0003_roles.sql` — role split + column-DENY on `ShopLicense` is clean and matches D7/D8.
- `db-migrations/global/up/0010_jobstartuser_login.sql` — disabled + DENY CONNECT proxy login, msdb membership via `msdb.sys.sp_executesql`, CSPRNG password, all correct and well-commented.
- `db-migrations/global/up/0020_seed_mandant_template.sql` — sentinel-instead-of-`{{…}}` deviation is documented and correct (avoids grate-token collision); MERGE `WHEN NOT MATCHED` keeps it non-destructive to runbook-corrected values.
- `db-migrations/global/sprocs/reset.GetResetStatus.sql` — no secret columns, parameterised filters, correct NULL-safe `DurationSeconds`.
- `db-migrations/global/sprocs/reset.ProcessNextResetRequest.sql` — the `UPDLOCK, READPAST` claim, the `SET @RequestId = NULL` loop-termination, the re-validation, and the MULTI_USER best-effort in CATCH are all correct (CQG-7 is only the hard-coded threshold).
- `db-migrations/global/sprocs/reset.internal_PostRestoreSecurity.sql` — orphan remap via `ALTER USER … WITH LOGIN`, schema-owner exclusion on the drop cursor, per-user TRY/CATCH, TRUSTWORTHY assert — textbook.
- `db-migrations/global/sprocs/reset.internal_InvalidateCredentials.sql` — thorough guarded coverage; ShopUrl/ShopLicense passed only as `sp_executesql` params; `tWebshopModule` correctly left untouched.
- `db-migrations/global/sprocs/reset.internal_NeutralizeWorker.sql` — column-guarded, DELETE-not-TRUNCATE, `Worker.tTarget` correctly untouched per O1.
- `db-migrations/global/sprocs/reset.internal_GrantAccess.sql` — missing login → StepLog note (D4 deviation), `ALTER ROLE ADD MEMBER`, QUOTENAME on all identifiers.
- `db-migrations/global/sprocs/reset.internal_ApplyJtlRoles.sql` — additive/idempotent, RoboticoEKL grant correctly omitted (D10), member-list sync documented.
- `db-migrations/global/permissions/100_grants.sql` — OBJECT_ID-guarded grants, guarded AD-group membership.
- `db-migrations/global/permissions/200_ensure_agent_job.sql` — the everytime bare-existence heal complements the hash-triggered recreate without killing a running job.
- `db-migrations/global/permissions/900_resign_procedures.sql` — **exemplary**: catalog-derived signature set (`execute_as_principal_id = jobstartuser`), signature-presence check via `crypt_properties` ⋈ `certificates`, and a hard `THROW` if anything is left unsigned. This is the strongest file in the chain (its only coupling risk is CQG-3/CQG-4, which are about the password token, not this logic).
- `db-migrations/global/runAfterOtherAnyTimeScripts/reset.EnsureAgentJob.sql` — the queued/running guard before `sp_delete_job` is the right call (don't cancel a live reset); drop-if-exists/add is idempotent.
- `db-migrations/tests/global/validate_structure.sql` — covers objects, columns, the signed-proc signature, the EXECUTE-AS==signed invariant, and roles; read-only and lint-exempt as documented. (If CQG-6 lands, add `reset.internal_AppendStepLog` to its required list.)
- `db-migrations/README.md` (global sections) — the chain contract, folder semantics, and lint rules (a)–(g) are accurate to the code as built.
