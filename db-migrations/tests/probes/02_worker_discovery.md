# Probe 02 — Does the JTL-Worker discover a freshly registered mandant? (Open Q O2)

**Type:** manual probe — requires a *running* worker service. Cannot be answered
by a read-only SQL query, so it is written up as an instruction rather than a
`.sql` file. Run it on **vm-sql-test1** only.

> [!CAUTION]
> This probe deliberately makes a test mandant **visible to a running worker**.
> Do it **only on test1**, whose worker has no live marketplace/shop credentials.
> Never run this discovery test on a machine whose worker points at production
> accounts — that is exactly the worker-collision risk the whole reset design
> guards against (see `research/4-jtl-spezifika`).

## Question

The plan's reset flow registers a clone by upserting a `dbo.tMandant` row
(`register-mandant.sql`). O2 asks: **does the worker pick up that new mandant
immediately, only after a service restart, or only after a client re-login?**
The answer decides how strong the "worker stopped" precondition in the reset
runbook has to be, and whether a just-reset clone can be briefly visible before
neutralisation completes.

## Preconditions

- test1 worker service state is known. Check the service (`JTL-Worker` /
  `JTLWorker`) on the test1 host — note whether it is Running or Stopped before
  you start.
- A throwaway mandant DB exists you are willing to have the worker touch, or you
  create one for this probe and drop it afterwards (see Cleanup).
- You can read `Worker.tStatus` / `Worker.tErrorlog` on the target DB
  (read-only) between steps.

## Steps

1. **Baseline the worker.** With the worker **running**, capture the current
   mandant list it services and the last-run timestamps:

   ```sql
   -- read-only, run with -d eazybusiness
   SELECT kMandant, cName FROM dbo.tMandant ORDER BY kMandant;
   SELECT TOP 50 * FROM Worker.tStatus  ORDER BY 1 DESC;   -- adjust ORDER to a timestamp column
   SELECT TOP 50 * FROM Worker.tErrorlog ORDER BY 1 DESC;
   ```

2. **Register a fresh mandant** via the normal path
   (`Projekte/Testsystem/register-mandant.sql`, or a manual
   `INSERT dbo.tMandant …` on test1). Note the new `kMandant` and the wall-clock
   time of the insert.

3. **Observe WITHOUT restarting anything.** For the next ~5–10 minutes, re-poll
   `Worker.tStatus` / `Worker.tErrorlog` and watch whether the worker starts
   servicing the new `kMandant` (new status rows, sync attempts, errors). Record
   the delay, or "no pickup".

4. **Restart the worker service** (stop → start). Re-poll as in step 3. Record
   whether pickup happens now and how fast.

5. **Client re-login (optional).** If steps 3–4 showed no pickup, open the WaWi
   client and log into the new mandant once, then re-poll. Some discovery paths
   are client-initiated.

## What to record (update O2 in the plan with this)

| Trigger | Worker picks up the new mandant? | Delay |
|---|---|---|
| Insert only, no restart |  |  |
| After service restart |  |  |
| After client login |  |  |

Fill the table, then set O2 in the plan to the observed behaviour. The safe
default the reset runbook already assumes: **worker service fully stopped before
any registration**, restarted only after neutralisation is verified.

## Cleanup

If you created a throwaway mandant DB for this probe, drop it and remove its
`dbo.tMandant` row afterwards. Restore the worker service to the state you found
it in (step Preconditions).
