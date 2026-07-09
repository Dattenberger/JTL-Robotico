# Runbook — Instance hygiene findings (manual, production impact)

Three housekeeping items the instance survey surfaced on prod (vm-sql2). Each has
a prepared script or procedure under `Berechtigungen/cleanup/`, but **none runs
autonomously** — every production change here needs a human decision and a
reviewed session (plan D13).

> [!CAUTION]
> Everything in this runbook changes production. The prepared scripts are
> **read-only analysis with the fixes commented out**. Read the analysis, decide,
> then run the chosen statement by hand. Nothing here is a "just run it" script.

- **Applies to:** prod instance `vm-sql2.zdbikes.local`.
- **Source:** `docs/plans/2026-07-10 - mssql-ops-infrastruktur/research/2-instanz-survey`.
- **Scripts:** [`Berechtigungen/cleanup/`](../../Berechtigungen/cleanup/).

---

## Finding 1 — `dbuser_dev_dana_for_jtl` is `sysadmin` on prod

**Survey evidence (§3):** *"sysadmin: enthält SQL-Login `dbuser_dev_dana_for_jtl`
(Dev-Konto mit voller Serverhoheit!)"*. A developer SQL login with unrestricted
server authority — it can read, alter, or drop any database and change security.
Highest-severity hygiene item.

**Prepared:** [`Berechtigungen/cleanup/01_dana_sysadmin_review.sql`](../../Berechtigungen/cleanup/01_dana_sysadmin_review.sql)
— read-only blocks (A)–(D) enumerate the login's server roles, everyone in
sysadmin, its explicit server permissions, and its in-DB mapping. Three commented
remediation options: drop sysadmin/keep dbcreator; drop both + granular per-DB
grants; or replace with a personal least-privilege login and disable the old one.

**Decision needed:** which option. **Precondition:** confirm no automated job or
connection string depends on dana having sysadmin (check SQL-Agent job owners,
app configs, watch Extended Events for a day) before removing it — otherwise a
background job breaks silently.

## Finding 2 — `eazybusiness_tm2` is stuck on JTL 1.11.6.0

**Survey evidence (§6):** every eazybusiness DB is on schema version **2.0.5.0**
except *"Ausreißer: **_tm2 = 1.11.6.0**"*. The current WaWi client refuses login
to an out-of-date DB, so tm2 is dead weight until refreshed.

**Prepared:** [`Berechtigungen/cleanup/02_tm2_refresh.md`](../../Berechtigungen/cleanup/02_tm2_refresh.md)
— refresh via **clone-after-update** (re-clone tm2 from the up-to-date prod
`eazybusiness`, then run the reset), not by updating the stale DB in place.

**Decision needed:** refresh, or retire tm2 entirely (drop DB + remove its
`dbo.tMandant` row) if the mandant is obsolete. Decide before doing the work.

## Finding 3 — `eazybusiness_premig` on `E:\Backup\` (Open Question O3)

**Survey evidence (§2 + Auffälligkeiten):** *"`eazybusiness_premig` liegt physisch
in `E:\Backup\` (FULL recovery)"* — an old, prod-sized pre-migration snapshot
occupying a backup volume, in FULL recovery (so it also accrues log backups),
that nobody logs into.

**Prepared:** [`Berechtigungen/cleanup/03_premig_db.sql`](../../Berechtigungen/cleanup/03_premig_db.sql)
— read-only blocks report its existence/recovery model/age, physical files +
sizes + location, and its last known-good backup. Commented options: keep (but
move off `E:\Backup\` and/or switch to SIMPLE), or archive-then-drop (fresh
verified full backup → off-box copy → drop).

**Decision needed — this is O3, owner: Lukas:** keep or archive-and-drop.

> [!WARNING]
> If archiving-then-dropping: take a fresh full backup, run `RESTORE VERIFYONLY`,
> copy the `.bak` off-box and confirm the copy **before** the drop. The commented
> block in `03_premig_db.sql` spells out that exact order — do not reorder it.

---

## How to work an item

1. Run the script's read-only blocks against prod
   (`/opt/mssql-tools18/bin/sqlcmd -S vm-sql2.zdbikes.local -E -C -d master -i <script>`).
2. Review the output against the finding above and check the stated precondition.
3. Get the go/no-go decision (Findings 1 and 3 need Lukas; Finding 2 needs a
   keep/retire call).
4. Uncomment and run **only** the chosen remediation statement, in a reviewed
   session, worker stopped where a mandant DB is involved.
5. Re-run the read-only blocks to confirm the new state.

## Failure modes

> [!CAUTION]
> **Removing dana's sysadmin without checking dependents.** A background job or
> connection string that relied on it fails silently afterwards. Finding 1's
> precondition (audit dependents first) exists to prevent exactly this.

> [!CAUTION]
> **Dropping `eazybusiness_premig` without a verified off-box backup.** The drop
> is irreversible and the DB physically lives on the same `E:\Backup\` volume —
> a local-only backup does not protect against a volume loss. Verify + copy off
> first.
