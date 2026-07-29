# JTL Test Mandants (YouTrack article, English)

> Source file for the English YouTrack knowledge-base article (child of JTL-A-20).
> Maintenance: edit here, then push the FULL content (from the H1 below) via the
> YouTrack MCP `update_article` — the API only supports full overwrite or append.
> Keep in sync with the German source
> `youtrack-testmandant-reset-kurzanleitung.md` (same structure, same as-of date).

---

# JTL Test Mandants

Test mandants are fully functional Wawi mandants holding a **copy of the production data** — for experimenting, testing and training without any risk. This page explains which ones exist, how to use them, how to reset them, and how to get a new one.

## Overview: Which test mandants exist?

**Assignment, as of: 2026-07-29** *(please update this table when things change — the live truth is always available via `EXEC reset.spPub_ListMandants;`)*

| Mandant | Name in the Wawi | Assigned to | Staging shop |
| --- | --- | --- | --- |
| `tm2` | Testmandant 2 | **Dana** | `https://tm2.staging.local` |
| `tm3` | Testmandant 3 | **Sanda** | `https://tm3.staging.local` |
| `tm4` | Testmandant 4 | **Lukas** | `https://tm4.staging.local` |

Prefer **your own** mandant. If you need someone else's, check with them first — a reset wipes everything currently on it.

## Access: How do I get to my test mandant?

* **In the Wawi:** simply pick the mandant when logging in (e.g. "Testmandant 2") — the test mandants appear in the selection automatically.
* **Directly on the database** (for SQL queries and the commands below): SQL Server Management Studio (SSMS), **Windows authentication**:
  * **Server:** `mssql-prod1.ison-musical.ts.net` (Tailscale address)
  * **Database for the commands below:** `RoboticoOps`
  * Your regular Windows login is enough — every Wawi user has the required permission automatically.

**Tip:** In SSMS, pick the `RoboticoOps` database in the dropdown at the top left, open a new query window, type the command, hit `F5`.

## Resetting: Get a fresh data state

A reset rebuilds the test mandant **from scratch** — as an anonymized copy of the production data as of right now. Duration: **about 5–6 minutes**.

> ⚠️ Everything that was on the test mandant before is **gone** afterwards. Test mandants are throwaway environments — don't store anything there you want to keep.

**Start** (insert the mandant key from the table above):

```sql
EXEC reset.spPub_StartTestmandantReset @MandantKey = N'tm2';
```

You get back a **request number** and status `queued` — from here everything runs automatically in the background, you can close the window. **Started it twice by accident?** No problem — you simply get the same request number again; two resets never run in parallel.

**Watch the progress** (optional, as often as you like):

```sql
EXEC reset.spPub_GetResetStatus @MandantKey = N'tm2';
```

| Column | Meaning |
| --- | --- |
| `cStatus` | `queued` → `running` → **`succeeded`** (done!) or `failed` |
| `cStepLog` | Log of the 8 work steps with timestamps — the **bottom line** is the current step |
| `cErrorMessage` | Only on `failed`: what went wrong |

The anonymization (step 5) is by far the longest part — if it seems to "hang" there for a few minutes, that's normal. Once `cStatus = succeeded`: start the Wawi, pick the mandant, go. **Don't use the mandant while the reset is running** (its database is being swapped out).

**If something goes wrong:**

* `failed`? → `cErrorMessage`/`cStepLog` tell you why. Just start it again — always safe, the reset cleans up after itself. If it stays red: tell Lukas.
* `running` for over an hour? → Cancel it with `EXEC reset.spPub_CancelResetRequest @RequestId = <request number>;` (it refuses while work is genuinely still in progress).
* The production system is **only read, never modified** by a reset — you cannot break anything here.

## What a test mandant actually is

* A **copy of the production data**, stripped of logs/history and **anonymized**: customer data (names, addresses, e-mails) is made unrecognizable (`mail_12345@test.local`).
* **Defused:** e-mail dispatch, marketplace connections and credentials are disconnected — nothing can accidentally leave the test mandant.
* **Linked to a staging JTL shop** (see the table above) instead of the real shop.
* The infrastructure takes care of the formalities automatically — license/shop assignment, user permissions, mandant registration in the Wawi.

## Getting a new test mandant

Any team member can **request a test mandant — from Lukas**. Creating one is an admin step (procedure `reset.spPub_CreateTestmandant`; it assigns key, name and database automatically and immediately kicks off the first reset). Two things to keep in mind:

* The **license information for the linked staging shop must be maintained afterwards** (shop URL + license key in the mandant registry) — until then, the mandant's shop connection is simply non-functional.
* New mandants must then be **added to the table above** (including a fresh as-of date).

## How the infrastructure works, roughly

Behind the commands sits a dedicated administration database (`RoboticoOps`) on the SQL server: your start command places a request in a queue, and a background job of the SQL server processes it in **8 steps** — copy the production DB, harden security, invalidate credentials, neutralize background services, anonymize customer data, set permissions, register the mandant in the Wawi, apply roles. Every step logs itself — that is exactly what you see in `cStepLog`.

---

> 🔧 **Technical documentation (for developers):** The full technical description of the test-mandant infrastructure lives in the Git repository: [`docs/SQL/MSSQL-OPS-ARCHITECTURE.md`](https://github.com/Dattenberger/JTL-Robotico/blob/master/docs/SQL/MSSQL-OPS-ARCHITECTURE.md) (JTL-Robotico). This YouTrack article is the operator manual and is updated together with infrastructure changes — its source file also lives in the repository (`docs/plans/2026-07-10 - mssql-ops-infrastruktur/reports/youtrack-testmandant-reset-kurzanleitung.en.md`).
