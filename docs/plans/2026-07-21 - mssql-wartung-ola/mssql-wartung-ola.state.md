# State: mssql-wartung-ola

> **On resume:** re-read `~/.claude/skills/implement-long-plan-v3/SKILL.md`
> and this file in full before any other action.

**Plan:** [→ mssql-wartung-ola.md](mssql-wartung-ola.md)
**Chunks:** [→ chunks.json](chunks.json)
**Reports:** ./reports/
**Started:** 2026-07-22 (Session d3ea7324, Fable 5)

## plan_lifecycle

```yaml
current_path: docs/plans/2026-07-21 - mssql-wartung-ola/mssql-wartung-ola.md
status: archived
moved_at: n/a (created in place 2026-07-21)
archived_at: 2026-07-23T01:30:00+02:00
```

## User Directives (this run)

```yaml
chunk_cut: "genau 1 Block, 1 Chunk (Nutzer-Vorgabe, kein Analyse-Spielraum)"
impl_agent: fable-low     # Nutzer-Vorgabe für IMPL+TEST & SELF-FIX
scope: "B1–B5 (test1); B6 Prod-Cutover bleibt human-gated und ist NICHT Teil dieses Runs"
```

## Documentation Plan

```yaml
doc_activation: full      # bestätigt Lukas 2026-07-22 (docActivation=full)
doc_landscape: "docs/runbooks (5 Dateien, kein agentic-Katalog), docs/SQL (DATA-MODEL, NAMING, ARCHITECTURE), keine docs/architecture|decisions-Ordner (ADRs plan-scoped)"
doc_plan_sketch:
  - "7 [EDIT]-Deliverables sind bereits im Plan §4 verankert (validate_structure, validate_rollout, README §4 THROW, NAMING-CONVENTIONS, DATA-MODEL, ARCHITECTURE, rollout-runbook) — Teil des Chunks, nicht des Doc-Runs"
  - "Inline-Anchor-Pflicht: Header + @see für jede neue Ebene-B-Datei (README §3)"
  - "ADR-Promotion (2 plan-scoped ADRs) erst bei Plan-Archivierung, nicht in diesem Run"
```

## Conventions

```yaml
build_command: "n/a (SQL-Repo, kein Build)"
test_command: "npm run db:lint  # = pwsh db-migrations/tests/lint-migrations.ps1"
lint_command: "npm run db:lint"
deploy_command: "npm run db:deploy:test:global  # = pwsh db-migrations/deploy.ps1 -Scope global -Environment TEST (native grate; PATH=$HOME/.dotnet:$HOME/.dotnet/tools, DOTNET_ROOT=$HOME/.dotnet). VERIFIZIERT 2026-07-22: deploy.ps1 liegt unter db-migrations/, NICHT scripts/; -Environment TEST wählt test1 via targets.config.json"
structure_check: "sqlcmd gegen validate_structure.sql + validate_rollout.sql (Struktur- + Rollout-Gate)"
test_target: "vm-sql-test1.zdbikes.local (SQL 2025, German locale — Datumsliterale 'YYYYMMDD'); sqlcmd: /opt/mssql-tools18/bin/sqlcmd -E -C -S <server> (VERIFIZIERT: nur mssql-tools18 installiert, -E Kerberos/-C TrustCert)"
prod_target: "vm-sql2.zdbikes.local — STRIKT READ-ONLY, kein Deploy in diesem Run (B6 human-gated, außerhalb Chunk-Scope)"
structure_test: "db-migrations/tests/global/validate_structure.sql + validate_rollout.sql"
commit_format: "[<Phase>.<Chunk>] <Titel> (mssql-wartung-ola)  — z. B. [B1.C1] Vendor Ola + Registry-DDL (mssql-wartung-ola); Orchestrator-Commits: [orchestrator] … (mssql-wartung-ola)"
```

## Pre-Flight

```yaml
# externe Voraussetzungen mit programmatischer Prüfung — vor Phase-3-Start abhaken
- name: test1 erreichbar + Kerberos-Auth
  check: "/opt/mssql-tools18/bin/sqlcmd -E -C -S vm-sql-test1.zdbikes.local -Q \"SELECT @@VERSION\""
- name: native grate auf PATH
  check: "which grate || ls $HOME/.dotnet/tools/grate  # deploy.ps1 nutzt native grate (v1.6.0), NICHT Docker"
- name: pwsh vorhanden
  check: "which pwsh"
- name: gepinnte Ola-Einzelskripte verfügbar
  check: "CommandLog.sql / CommandExecute.sql / DatabaseIntegrityCheck.sql / IndexOptimize.sql (byte-unverändert) müssen für up/0022 beschafft werden; DatabaseBackup.sql bewusst NICHT — Version im Kopfkommentar festhalten"
- name: Database Mail auf test1 (optional/guarded)
  check: "SELECT COUNT(*) FROM msdb.dbo.sysmail_profile WHERE name = N'Standard SMTP'  # fehlt ggf. → 260 druckt PRINT-Hinweis statt Phantom-Profil (FT-16), kein THROW"
# --- E2E-Isolation (Phase 1b, blocking) ---
- name: Isolation — Ziel ist test1, NIE vm-sql2
  check: "/opt/mssql-tools18/bin/sqlcmd -E -C -S vm-sql-test1.zdbikes.local -Q \"SELECT @@SERVERNAME\"  # -S darf NIE vm-sql2 sein"
  blocking: true
- name: Isolation — test1 hat keine CBB-Backup-Kette (BACKUP TO NUL folgenlos)
  check: "sqlcmd -Q \"SELECT COUNT(*) FROM msdb.dbo.backupset WHERE is_copy_only=0 AND backup_finish_date > DATEADD(DAY,-2,SYSDATETIME())\"  # 0/leer erwartet — sonst KEIN BACKUP TO NUL (TC-7)"
  blocking: true
- name: SQL-Agent geteilt mit Reset-Pipeline — kein Reset in Arbeit
  check: "sqlcmd -Q \"SELECT COUNT(*) FROM msdb.dbo.sysjobactivity a JOIN msdb.dbo.sysjobs j ON j.job_id=a.job_id WHERE a.stop_execution_date IS NULL AND a.start_execution_date IS NOT NULL AND j.name LIKE N'RoboticoOps - Reset%' AND a.session_id=(SELECT MAX(session_id) FROM msdb.dbo.syssessions)\"  # 0 erwartet; Start: EXEC master.dbo.xp_servicecontrol N'START',N'SQLServerAGENT'"
  blocking: true
```

## End-to-End-Test-Plan

```yaml
e2e: run
rationale: "Plan schreibt real gegen Live-test1 (grate-Deploy, echte Wartungsjobs, BACKUP TO NUL, DELETE/purge auf msdb) — Verhaltensversprechen AC5/AC7/AC9/AC10/AC12/AC13 nur via E2E prüfbar, nicht via Block-Audit"
runbook: docs/plans/2026-07-21 - mssql-wartung-ola/reports/e2e-runbook.md
target: vm-sql-test1.zdbikes.local (test1 only; vm-sql2 strikt read-only, B6 out-of-scope)
cases: { auto: 13, manual: 0 }   # Mail-Weg AC6 ist B6/Prod, kein test1-Case
persistent_runbooks: none   # kein docs/runbooks/agentic/-Katalog im Projekt
resolved_user_questions:   # beantwortet Lukas 2026-07-22
  - "test1-Wartungsfenster: JA, freies Fenster — Agent darf temporär gestartet/gestoppt werden; Reset-Guard (Pre-Flight) bleibt Pflicht."
  - "Residual-State: Jobs BELASSEN, disabled (Plan-Sollzustand D34, validate_rollout-konform); Agent nach E2E zurück in Stopped-Baseline; zz-test-Reste entfernen."
open_user_questions: none
result:   # Phase-4-Ausführung 2026-07-22, grate fc508ad
  status: "13/13 auto PASS, 0 issues, 0 escalations"
  report: docs/plans/2026-07-21 - mssql-wartung-ola/reports/e2e-report.md
  drift: "keine substanzielle Code-Drift; 2 Umwelt-Drifts (test1 hat copy_only-Backup-Regime + Legacy-Ola von 2024-06-24 in eazybusiness.dbo) → Prereq-2 + TC-2 angepasst"
  teardown_caveat: "Agent-Stopp nicht ausführbar (Windows-Dienstrechte fehlen; Kerberos-Login nur SQL-sysadmin) — funktional folgenlos, Schalter '0' (D34) sichert ab; Agent bleibt Running"
```

## Task Table (DAG)

| Task | Status | Commit | Notes |
|---|---|---|---|
| C1 (B1–B5 komplett) | ✅ complete | 923b6c7 (impl), 217314a (self-fix 0 fixes) | fable-low; test1-Deploy + B5-Prüfliste live grün |
| B1-audit | ✅ converged | 2a420d6 (wave 1: 5 fixes), fc508ad (wave 2: 0023-Entscheid) | 7 Findings, 0 postponed; Wave-Verify clean |

## Workflow Runs

```yaml
plan_workflow_run_id: wf_b1fee2a7-5e4   # gestartet 2026-07-22 ~22:00, Task wim4rcvu7
finalize_workflow_run_id: wf_026c9f42-dab  # complete 2026-07-23 ~00:15: integration skipped (1 Block), e2e pre-run gefaltet, docs 6 Worker ok, Commit 3c579be; ADR-Promotion als Closure-Task geflaggt
last_return: "complete (2026-07-22 ~23:20): commits 923b6c7/217314a/2a420d6/fc508ad; completedChunks=[C1], completedAudits=[B1]; waveVerify clean; delegated issue I1 (test1 eazybusiness.dbo Legacy-Ola-Reste von 2024, Nice-to-have, ohne Owner); Deviations u. a.: Ola-Pin master-Snapshot 20260722_200334, 3 dokumentierte Byte-Breaks (Lint h/CRLF/BOM), IndexOptimize Medium+High beide REORGANIZE (D13), 260-Mailprofil via xp_instance_regread/-write, FT-13-Wrapper unnötig (upstream hat IF NOT EXISTS)"
```

## Log

- 2026-07-22: Phase 0 Setup — State-File angelegt; Plan committed (d722993), QG Runde 2 (Deep) vollständig eingearbeitet, D1–D41, Gaps geschlossen.
- 2026-07-22: Phase 1 — chunks.json (1 Block/1 Chunk, fable-low) + E2E-Runbook (13 auto, 0 manuell, e2e: run) fertig; Runbook-Finalisierung mit Nutzer-Antworten läuft (Agent-Fenster: frei; Jobs bleiben disabled).
- 2026-07-22: Phase 2 — Nutzer: e2eScope=run, docActivation=full. Pre-Flight: pwsh+grate ✅; test1-Kerberos war rot (MagicDNS-Kanonisierung, fehlender ts.net-SPN) → /etc/hosts-Fix `100.71.24.47 vm-sql-test1.zdbikes.local`, jetzt ✅ (Memory: test1-kerberos-hosts-fix). Plan-Linkcheck ✅.
- 2026-07-22: Git-State-Check: Worktree dirty mit VOR-BESTEHENDEN PayPal-Removal-Änderungen (gestagte Löschungen + 4 modifizierte Dateien + 0003_drop_paypal_mechanic.sql) — Entscheidung: IGNORE mit Schutzauflage. Die Workflow-Commits sind file-scoped; KEINE der PayPal-Dateien darf in Wartungs-Commits gelangen (Vorfall bei d722993 bereits einmal korrigiert).
- 2026-07-22: Phase 3 gestartet — plan.workflow.js, planStartCommit d722993.
- 2026-07-22: Phase 4 Teil A (autonome E2E) — 13/13 Auto-Cases PASS gegen test1 (grate fc508ad redeployt), 0 Issues, 0 Eskalationen. Alle AC verhaltensgeprüft (Registry, Job-Läufe grün, Statistik ALL, Watchdog 51100/Grenzfall, Liveness 51105+Grace, Drift-Korrektur, Fremd-Job-Entfernung, Idempotenz 0-changes, Lint+Struktur+Rollout-Gate). Drift-Befunde: test1 hat copy_only-CBB-Regime (Prereq-2 geschärft) + Legacy-Ola 2024 in eazybusiness.dbo (TC-2 auf Provenienz präzisiert, B6 entfernt sie). Teardown: zz-test weg, Jobs disabled belassen, Schalter '0'; Agent-Stopp scheiterte an Windows-Dienstrechten (folgenlos, D34-Schalter sichert ab). Report: reports/e2e-report.md.

## Phase 4 — Documentation

```yaml
doc_final:
  ran: 2026-07-23T00:05:00+02:00
  report: docs/plans/2026-07-21 - mssql-wartung-ola/reports/docs-final-report.md
  worker_units: 6   # data-model, naming-conventions, ops-architecture, migrations-readme, rollout-runbook, inline:maint-suite-global
  docs_updated: 1   # ARCHITECTURE — ops-architecture worker completed dangling ADR-A/ADR-B refs (frontmatter + §8)
  docs_verified_no_change: 5   # DATA-MODEL, NAMING, README, rollout-runbook + 8 inline-anchor SQL files
  auto_fixes: 0     # keine unsicheren Link-Reparaturen nötig; einziger Fix bereits vom Worker angewandt
  cross_doc_contradictions: 0   # Zählungen konsistent: 6 Jobs · 5 maint-Procs · 3 Schemas · 5 Registry-Tabellen · THROW 51100–51129 · reset-next-free 51130
  flagged: 1        # ADR-Promotion Link-Rewrite (Closure-Step): 2 plan-scoped ADRs → docs/decisions/NNNN; betrifft ARCHITECTURE frontmatter+§8, NAMING §9 symbolic ref, 8 @see ADR-Anker in SQL-Dateien
  gaps: 0           # jede Quelldatei hat ein aktualisiertes Doc-Zuhause
  knowledge_skill_flags: 0
```
