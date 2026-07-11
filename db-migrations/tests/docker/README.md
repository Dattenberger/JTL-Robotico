# `tests/docker/` — Ephemeral E2E MSSQL Container

A disposable, prod-parity SQL Server container for running the JTL-Robotico
migration **end-to-end** on a developer machine: bring up a clean engine, restore
a JTL test database into it, apply both grate chains, run the ported test suites,
and exercise the full SQL-Agent-driven test-mandant reset — then throw it all away.

Nothing here ever touches a real server. It talks only to a local container on
`localhost,14330`.

> [!IMPORTANT]
> This harness is self-contained. It does **not** reference files outside this
> repository at runtime — the good ideas from `excel_ekl/docker/mssql` were copied
> in, not linked. Do not add runtime dependencies on other repos.

---

## 1. What this is (and why 2022)

| Property | Value | Why |
|---|---|---|
| Image | `mcr.microsoft.com/mssql/server:2022-latest` | PROD parity — the production engine family is SQL Server 2022 |
| Container | `robotico-e2e-mssql` | fixed name; scripts reference it |
| Compose project | `robotico-e2e` | pinned so it never collides with other repos' `docker/` projects |
| Host port | `14330` → `1433` | avoids `1433` (a local SQL Server) and `1434` (excel_ekl's dev container) |
| Edition | Developer (`MSSQL_PID=Developer`) | full engine features, no license |
| SQL Agent | **enabled** (`MSSQL_AGENT_ENABLED=true`) | **required** — the reset E2E starts an Agent job |
| Collation | `Latin1_General_CI_AS` | JTL-Wawi native collation (first-init only) |
| Volume | `robotico-e2e-mssql-data` (named) | teardown wipes it for a clean slate |

> [!NOTE]
> **SQL 2022 here vs. SQL 2025 on `vm-sql-test1`.** The real TEST server runs SQL
> Server 2025; PROD (`vm-sql2`) runs 2022. This container matches **PROD** (2022),
> which is the stricter floor for the Ebene-A string/CSV API (needs the 2022
> 3-argument `STRING_SPLIT`, see `db-migrations/README.md` §8). A migration that
> applies cleanly here will apply on both TEST-2025 and PROD-2022.

---

## 2. Quickstart

All commands run from the repo root, PowerShell 7 (`pwsh`).

```powershell
# 1. Bring up a clean container (generates secrets, waits healthy, verifies).
pwsh db-migrations/tests/docker/setup.ps1

# 2. Load the generated secrets into the shell (deploy.ps1 reads them from env).
#    bash/zsh:  set -a; source db-migrations/tests/docker/.env.local; set +a
#    pwsh:      Get-Content db-migrations/tests/docker/.env.local |
#                 Where-Object { $_ -notmatch '^\s*#' -and $_ -match '=' } |
#                 ForEach-Object { $kv = $_ -split '=', 2; Set-Item "env:$($kv[0].Trim())" $kv[1] }

# 3. (Next phase) Restore a JTL test DB named 'eazybusiness' into the container —
#    via the excel_ekl test-db-jtl transfer pipeline (see §5).

# 4. Deploy Ebene B (RoboticoOps) — needs GRATE_CERT_PASSWORD from step 2.
pwsh db-migrations/deploy.ps1 -Scope global -Environment E2E

# 5. Deploy Ebene A (eazybusiness objects).
pwsh db-migrations/deploy.ps1 -Scope eazybusiness -Environment E2E

# 6. Run the reset E2E + ported *_Tests.sql suites against the container
#    (next phase — the reset runs the SQL Agent job).

# 7. Tear it all down (container + volume).
pwsh db-migrations/tests/docker/teardown.ps1
```

`setup.ps1` leaves the container **running**. It is idempotent — re-running it
reuses the existing container and `.env.local`.

---

## 3. Secret handling

Two secrets are **generated**, never committed:

| Secret | Env var | Purpose |
|---|---|---|
| SA password | `MSSQL_SA_PASSWORD` | container sa login; also the SQL-auth password for `-Environment E2E` deploys |
| Cert password | `GRATE_CERT_PASSWORD` | grate `{{CertPassword}}` token for the Ebene-B signing chain (`-Scope global`) |

- `setup.ps1` writes both as strong random values into **`.env.local`** on first
  run. That file is gitignored (see `.gitignore` in this folder) and `chmod 600`.
- `.env.example` is the committed template (placeholders only).
- `docker-compose.yml` reads `MSSQL_SA_PASSWORD` via `--env-file .env.local`
  (compose is always invoked with that flag; there is no committed `.env`).
- `deploy.ps1 -Environment E2E` reads the SA password from `$env:MSSQL_SA_PASSWORD`
  at deploy time — the password is **not** in `targets.config.json`.

> [!CAUTION]
> Never commit `.env.local` or paste its contents anywhere. If you need
> reproducible secrets, copy `.env.example` to `.env.local` and set your own — but
> the generated random values are the default and the safer choice.

---

## 4. grate: run path (Docker image)

`deploy.ps1` auto-detects how to run grate:

1. a `grate` binary on `PATH` (dotnet global tool) — **native**, or
2. no grate/dotnet → run grate from its official image via `docker run` — **docker**.

**This machine has no .NET SDK, so the harness uses the Docker path:**
`erikbra/grate:1.6.0` (pin overridable via `$env:GRATE_DOCKER_IMAGE`). `deploy.ps1`
overrides the image's baked env-var entrypoint with the `/app/grate` binary so
`--schema` / `--usertokens` etc. are honoured, mounts the chain's SQL folder
read-only at `/db`, and runs on the host network so a `localhost,14330` connection
string reaches the published container port exactly as host `sqlcmd` does.

> [!TIP]
> To use a native grate instead (faster, no per-run container), install the .NET
> SDK and `dotnet tool install --global grate`. `deploy.ps1` then prefers the
> binary automatically — no config change.

---

## 5. Where the database content comes from

This harness provides the **empty engine**. The JTL `eazybusiness` database
content is loaded separately by the **excel_ekl `test-db-jtl` transfer pipeline**
(a trimmed COPY_ONLY backup restored into the container) — that is the next phase
of this work, not part of this folder. Once a database named `eazybusiness` exists
in the container, the Ebene-A deploy and the reset E2E run against it.

Until then, `setup.ps1` + `deploy.ps1 -Scope global -Environment E2E` alone verify
the Ebene-B (RoboticoOps) chain, which needs no restored database (grate creates
`RoboticoOps`).

---

## 6. Files in this folder

| File | Role |
|---|---|
| `docker-compose.yml` | the container definition (image, port, agent, collation, healthcheck, limits) |
| `entrypoint.sh` | fixes named-volume ownership, then drops to the `mssql` user |
| `setup.ps1` | generate secrets → `up -d` → wait healthy → verify (SELECT 1, Agent, collation) |
| `teardown.ps1` | `down -v` (container + volume); `-PurgeSecrets` also deletes `.env.local` |
| `.env.example` | committed template for `.env.local` |
| `.gitignore` | keeps `.env.local` out of git |

---

## 7. Verification (what setup.ps1 asserts)

After the container reports healthy, `setup.ps1` checks, via SQL-auth `sqlcmd`
against `localhost,14330`:

- `SELECT 1` answers,
- the SQL Agent service is `Running` (`sys.dm_server_services`) — hard fail if not,
- `SERVERPROPERTY('Collation') = Latin1_General_CI_AS` — warns (with the fix) if not.

A collation mismatch means the volume was initialised before `MSSQL_COLLATION` took
effect; `teardown.ps1` (wipes the volume) + `setup.ps1` fixes it.

---

## 8. References

- Migration conventions (the contract both chains obey): [`../../README.md`](../../README.md)
- The deploy wrapper (grate runner + auth resolution): [`../../deploy.ps1`](../../deploy.ps1)
- Target catalog (the `E2E` environment): [`../../targets.config.json`](../../targets.config.json)
- The plan that introduced the ops infrastructure: `docs/plans/2026-07-10 - mssql-ops-infrastruktur/`
