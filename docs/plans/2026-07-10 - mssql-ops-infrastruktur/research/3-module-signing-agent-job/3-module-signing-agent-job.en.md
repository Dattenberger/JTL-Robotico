---
name: module-signing-agent-job
description: Security architecture signed SP → Agent job for the test-mandant reset (web research, 2026-07-09)
status: Research
---

# SQL Server Security Architecture: Signed SP → Agent Job for the Test-Mandant Reset

> Source: Opus research agent "research-signing-jobs", session 2026-07-09. Web research with primary sources (linked inline).

Core statement up front: separate the two security problems cleanly. (A) The colleague without permissions should be allowed to **trigger** the reset → module signing on the SP solves that. (B) The job must **execute** BACKUP/RESTORE/`xp_create_subdir`/`ALTER AUTHORIZATION` → the simplest solution for that is **job owner = sysadmin** (no module signing needed inside the job). For the SP→job handover, use the **queue-table pattern**, not dynamic rewriting of job steps.

## 1. Signed SP → `sp_start_job`: exact permissions + the clean path

**Permission rules of `sp_start_job`** ([MS Learn](https://learn.microsoft.com/en-us/sql/relational-databases/system-stored-procedures/sp-start-job-transact-sql)): `SQLAgentUserRole`/`SQLAgentReaderRole` may start **only their own jobs** (job owner = the login); `SQLAgentOperatorRole` may start **all local jobs**; only `sysadmin` may do everything, including multiserver. A non-sysadmin who is to start a *foreign* job therefore needs `SQLAgentOperatorRole`.

**Recommendation — a hybrid of certificate + impersonation** (Sommarskog's explicit recommendation, [grantperm-appendix #startjobs](https://www.sommarskog.se/grantperm-appendix.html#startjobs)). Not the pure certificate path (see the pitfall). Setup:

1. A dedicated proxy login in `master`, disabled, no interactive login:
   ```sql
   CREATE LOGIN jobstartuser WITH PASSWORD = '<random-guid>';
   ALTER LOGIN jobstartuser DISABLE;
   DENY CONNECT SQL TO jobstartuser;
   ```
2. Create it as a user in `msdb`, with minimal permissions:
   ```sql
   USE msdb;
   CREATE USER jobstartuser FROM LOGIN jobstartuser;
   GRANT EXECUTE ON dbo.sp_start_job TO jobstartuser;
   ALTER ROLE SQLAgentOperatorRole ADD MEMBER jobstartuser;
   ```
3. Create a certificate in `msdb`, export it with its private key into the ops DB (`certencoded`/`certprivatekey` → `CREATE CERTIFICATE ... FROM BINARY ... WITH PRIVATE KEY`).
4. A signed SP in the ops DB with `WITH EXECUTE AS 'jobstartuser'`, then signed with the certificate:
   ```sql
   CREATE PROCEDURE reset.StartResetJob WITH EXECUTE AS 'jobstartuser' AS
     EXEC msdb.dbo.sp_start_job @job_name = N'TestMandant_Reset';
   ADD SIGNATURE TO reset.StartResetJob BY CERTIFICATE [SIGN_ResetJob] WITH PASSWORD = '<certpwd>';
   ```

**Why the hybrid and not pure certificate:** with a pure certificate, `sp_start_job`, `sp_verify_job_identifiers` **and** `sp_sqlagent_notify` in `msdb` would all have to be countersigned (`ADD COUNTER SIGNATURE`), because `sp_start_job` internally calls further procedures. The `EXECUTE AS 'jobstartuser'` context lets the internal permission checks run against a genuinely privileged principal → **no countersignatures needed**. The certificate carries only the cross-DB authentication, so that **no `TRUSTWORTHY`** is required.

**Pitfalls:**
- Countersignatures on `msdb` system procedures are **lost with every service pack / CU** ([MS Q&A](https://learn.microsoft.com/en-us/answers/questions/146608/execute-sp-start-job-using-certificate)) — hence the hybrid, which avoids them.
- `EXECUTE AS`+`sp_start_job`: the job appears in `sysjobhistory` as started by `jobstartuser` → for auditing, the real caller must be logged separately (see §6, `ORIGINAL_LOGIN()`).
- **Leaner alternative to `SQLAgentOperatorRole`:** make `jobstartuser` the **owner of the reset job** → `SQLAgentUserRole` suffices (least privilege). But that collides with "job owner = sysadmin" from §3 → decision: sysadmin owner (confirmed by the user), hence `SQLAgentOperatorRole`.

## 2. Passing parameters to the Agent job

Agent jobs take **no call parameters**. Options:

- **Queue/request table (recommendation, confirmed by the user):** the SP validates the input, writes a request row (target mandant, requester, timestamp, status `queued`) into the admin DB, **then** `sp_start_job`. The job reads the next open row. Robust, trivial to debug (the table is the state), well auditable.
- **Rewriting `sp_update_jobstep` dynamically — an anti-pattern.** Race conditions with parallel requests, no history, hard to test.
- **Service Broker with internal activation** ([SQLPerformance](https://sqlperformance.com/2014/03/sql-performance/intro-to-service-broker), [MS Learn](https://learn.microsoft.com/en-us/sql/database-engine/service-broker/creating-service-broker-queues)): technically the "more serious" asynchronous solution, but with considerably more moving parts (queue/service/contract/message type, activation debugging, poison-message handling). Overkill for a small team and an infrequent reset that deliberately runs **serially**.

## 3. Execution context of the job step (the most important simplifier)

For a **T-SQL job step** ([MS Learn, Manage Job Steps](https://learn.microsoft.com/en-us/ssms/agent/manage-job-steps)): the step runs as the **job owner** via `EXECUTE AS` — **unless** the job owner is a member of `sysadmin`, in which case the step runs as the **SQL Server Agent service account** (usually itself a sysadmin).

**Recommendation (confirmed by the user):** assign the reset job **to a sysadmin login**. Then `BACKUP`/`RESTORE`/`xp_create_subdir`/`ALTER AUTHORIZATION` work **without any module signing inside the job** — considerably lower-maintenance than granular grants or signatures in the job.

**Pitfalls:**
- A **proxy/credential** is only needed for non-T-SQL subsystems (CmdExec, PowerShell, SSIS). If everything stays T-SQL → **no proxy needed**. `xp_create_subdir` runs in the context of the **Agent service account** — that Windows account needs NTFS write permissions on the backup target path (verify!).
- Consequence for §1: because the job is owned by someone *else* (a sysadmin), `jobstartuser` must be in `SQLAgentOperatorRole`.

## 4. Module-signing mechanics across DB boundaries

([Sommarskog grantperm](https://www.sommarskog.se/grantperm.html), [SQLSkills](https://www.sqlskills.com/blogs/jonathan/certificate-signing-stored-procedures-in-multiple-databases/))

- **Server-level grant recipe:** create the certificate in the ops DB → sign the SP → drop the private key from the certificate → copy the certificate (public key only) to `master` → there `CREATE LOGIN ... FROM CERTIFICATE` → granular server grant to the cert login. The certificate exists in **both** DBs (ops DB for signing, `master` for login+grant).
- **Granular instead of sysadmin/dbcreator:** targeted grants such as `CREATE ANY DATABASE`, `ALTER ANY DATABASE`, `VIEW SERVER STATE` are possible. Not needed for the reset job (the sysadmin-owner route); module signing only for the *triggering* SP.
- **`ALTER PROCEDURE` removes the signature** — "If the procedure is changed, the signature is removed and the procedure must be signed anew." → **Re-signing must be a fixed part of the deployment.** A useful side effect: nobody changes the privileged SP unnoticed without the permissions falling away.
- **Nested SPs:** countersignatures are needed when internal checks have to see the cert login — the reason why the pure certificate path fails with `sp_start_job` and the hybrid is preferable.
- **Avoid `TRUSTWORTHY`:** using `EXECUTE AS` for server permissions would require `TRUSTWORTHY ON` → a DB-wide privilege-escalation vector (any db_owner can escalate server-wide). A certificate signature is the explicitly auditable, DB-bound replacement. **`TRUSTWORTHY` stays OFF everywhere.**

## 5. After the restore — best-practice order

1. **Set the DB owner:** `ALTER AUTHORIZATION ON DATABASE::[Zielmandant] TO [sa]` (or a dedicated service account). The restored backup brings the old owner SID with it ([MS Learn, Orphaned Users](https://learn.microsoft.com/en-us/sql/sql-server/failover-clusters/troubleshoot-orphaned-users-sql-server)).
2. **Remap orphaned users** — the modern way with `ALTER USER [x] WITH LOGIN = [x]`, **not** the deprecated `sp_change_users_login`.
3. **Clean up DB users that are no longer wanted/were inherited** (`DROP USER`).
4. **Check `TRUSTWORTHY` is explicitly OFF** — a RESTORE can carry the property over from the backup.
5. Afterwards grants/registry entries/JTL follow-up work.

Mnemonic: **owner first, then user remap, then cleanup, then verify `TRUSTWORTHY OFF`, then grants.**

## 6. Audit/status pattern

**Minimal schema — one request/run table** in the admin DB (queue + log in one):

| Column | Purpose |
|---|---|
| `RequestId` (PK, IDENTITY/GUID) | unique request |
| `TargetMandant` | what |
| `RequestedBy` = `ORIGINAL_LOGIN()` | the **real** caller (not `jobstartuser`!) |
| `RequestedAt` / `StartedAt` / `FinishedAt` | when |
| `Status` | state machine: `queued → running → succeeded / failed` |
| `ErrorText` | error message on `failed` |

- **Audit:** log `ORIGINAL_LOGIN()` in the signed SP (not `SUSER_SNAME()`/`USER_NAME()`), otherwise `EXECUTE AS` puts `jobstartuser` everywhere.
- **State machine:** the SP writes `queued`; the job sets `running` (+`StartedAt`) when it picks the row up, and `succeeded`/`failed` (+`FinishedAt`/`ErrorText`) at the end via `TRY…CATCH`.
- **Concurrency/dedup:** `sp_getapplock` (Exclusive, resource `'reset:' + @TargetMandant`) in the SP ([mssqltips](https://www.mssqltips.com/sqlservertip/3202/prevent-multiple-users-from-running-the-same-sql-server-stored-procedure-at-the-same-time/)) + a filtered unique index on `TargetMandant WHERE Status IN ('queued','running')` as a declarative safeguard.

## Recommended overall flow (sequence)

1. The colleague calls `EXEC reset.StartResetJob @TargetMandant = N'…'` — they have only `EXECUTE` on this SP.
2. The SP takes `sp_getapplock`; validates the input against the admin DB; rejects it if something is already `queued`/`running`.
3. The SP writes the request row (`queued`, `RequestedBy=ORIGINAL_LOGIN()`, `RequestedAt=SYSDATETIME()`).
4. The SP (`WITH EXECUTE AS 'jobstartuser'` + certificate signature) calls `msdb.dbo.sp_start_job @job_name='TestMandant_Reset'`; returns the `RequestId`.
5. The Agent job (owner = sysadmin → the step runs as the Agent service account) picks up the oldest `queued` row and sets `running`.
6. The job in `TRY…CATCH`: `xp_create_subdir` → `BACKUP`/`RESTORE` → `ALTER AUTHORIZATION` → `ALTER USER … WITH LOGIN` → user cleanup → verify `TRUSTWORTHY OFF` → grants/registry/JTL follow-up work. **For defence in depth, the job itself validates the request row once more against the registry (target name ≠ eazybusiness, present in the registry).**
7. Success → `succeeded`; error → CATCH writes `failed` + `ErrorText`.
8. The colleague reads the status via a signed status SP (user's decision; a pure read SP against their own DB needs no signature, only an EXECUTE grant).

**Deployment rule:** after every `ALTER`/redeploy of the signed SP → **re-sign it**. After every SQL Server CU → cross-check the cert setups (with the hybrid, the countersignature risk does not apply).

## Decisions made (user, 2026-07-09)

1. **Job owner: sysadmin** (instead of a least-privilege construction).
2. **Parameter passing: request table** (no Service Broker).
3. **Status return channel: signed status SP** (no SELECT grant).
4. Remaining open operationally: verify the Agent service account's NTFS permissions on the backup target path; certificate-password handling in the deployment (belongs in `~/.claude-secrets.md`, never in checked-in SQL files); backup source (a fixed "golden" backup vs. freshly taken from the reference DB).

**Sources:** [Sommarskog – Packaging Permissions](https://www.sommarskog.se/grantperm.html) · [Appendix #startjobs](https://www.sommarskog.se/grantperm-appendix.html#startjobs) · [MS Learn – sp_start_job](https://learn.microsoft.com/en-us/sql/relational-databases/system-stored-procedures/sp-start-job-transact-sql) · [MS Q&A – sp_start_job via Certificate](https://learn.microsoft.com/en-us/answers/questions/146608/execute-sp-start-job-using-certificate) · [MS Learn – Manage Job Steps](https://learn.microsoft.com/en-us/ssms/agent/manage-job-steps) · [SQLSkills – Cert Signing Multiple DBs](https://www.sqlskills.com/blogs/jonathan/certificate-signing-stored-procedures-in-multiple-databases/) · [MS Learn – Orphaned Users](https://learn.microsoft.com/en-us/sql/sql-server/failover-clusters/troubleshoot-orphaned-users-sql-server) · [SQLPerformance – Service Broker](https://sqlperformance.com/2014/03/sql-performance/intro-to-service-broker) · [mssqltips – Prevent concurrent SP execution](https://www.mssqltips.com/sqlservertip/3202/prevent-multiple-users-from-running-the-same-sql-server-stored-procedure-at-the-same-time/)
