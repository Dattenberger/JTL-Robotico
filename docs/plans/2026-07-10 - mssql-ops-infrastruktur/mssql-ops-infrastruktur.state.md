# State: mssql-ops-infrastruktur

> ⚠️ ORCHESTRATOR-MANDATORY (read after every compact/resume):
>
> 1. Read the plan file (`mssql-ops-infrastruktur.md`) to know what is being planned
> 2. Check the Phase below to know where the workflow stopped
> 3. Check Research Agents below — alive sub-agents can be resumed via SendMessage
> 4. Check Building Blocks below to know which block is next
> 5. Check Open Questions below to know what still blocks progress

**Plan:** [→ mssql-ops-infrastruktur.md](mssql-ops-infrastruktur.md)
**Skill:** feature-planning → handover to implement-long-plan-v3
**Created:** 2026-07-10
**Last update:** 2026-07-10

**Phase:** Done (planning) — Implementation via implement-long-plan-v3 started 2026-07-10

**Complexity:** Large
**Modular?:** No (research subspecs are evidence, plan detail is flat §1–§7)

---

## Research Agents (Background)

Session 2026-07-09/10. Agents are addressable by name in the original session only;
their full reports are preserved verbatim in the research files.

| Subsystem | Agent (name) | Status | Research File |
|---|---|---|---|
| Migrations-Tooling (+ grate deep-dive) | research-migrations | done | research/1-migrations-tooling/1-migrations-tooling.md |
| EKL-Runner-Grenze (excel_ekl) | ekl-runner-boundary | done | research/1.1-ekl-runner-grenze/1.1-ekl-runner-grenze.md |
| Instanz-Survey test1/prod | sql-survey | done | research/2-instanz-survey/2-instanz-survey.md |
| Module Signing + Agent-Job | research-signing-jobs | done | research/3-module-signing-agent-job/3-module-signing-agent-job.md |
| JTL-Wawi-Spezifika | research-jtl | done | research/4-jtl-spezifika/4-jtl-spezifika.md |
| Repo-Inventar | repo-inventar | done | research/5-repo-inventar/5-repo-inventar.md |

---

## Building Blocks

| # | Building Block | Detail-Location | Status |
|---|---|---|---|
| 1 | Migrationsfundament grate (Ebene A) | §1 in plan (flat) | ✅ User-Approved |
| 2 | RoboticoOps-DB + globale Kette (Ebene B) | §2 in plan (flat) | ✅ User-Approved |
| 3 | Reset-SP + Agent-Job-Logik | §3 in plan (flat) | ✅ User-Approved |
| 4 | Validierung & Probeliste vm-sql-test1 | §4 in plan (flat) | ✅ User-Approved |
| 5 | Doku, ADRs, Rollout, Ablösung | §5 in plan (flat) | ✅ User-Approved |
| 6 | Hygiene/Cleanup (vorbereitend) | §6 in plan (flat) | ✅ User-Approved |
| 7 | Tests | §7 in plan (flat) | ✅ User-Approved |

---

## Open Questions

| ID | Question | Affected | Owner | Status |
|---|---|---|---|---|
| O1 | Semantik Worker.tTarget.nAbgleichstyp | §3/§4 | Research (test1 probe) | open — tTarget wird bis Klärung nicht angefasst (D9) |
| O2 | Worker-Discovery frischer tMandant-Einträge | §4 | Research (test1 probe, manual) | open |
| O3 | eazybusiness_premig: Backup+Drop oder behalten? | §6 | User | open |
| O4 | Amazon-Konten (pf_user) in tm-Klonen? | §3 | Research (read-only probe) | open — Neutralisierung ist guarded, funktioniert unabhängig |
| O5 | Cert-Passwort-Ablage in ~/.claude-secrets.md bestätigen | §2/§5 | User | open |

---

## Decisions Applied

| ID | Title | Block | Phase |
|---|---|---|---|
| D1 | grate als Migrations-Runner | 1 | Skeleton |
| D2 | Zwei Ketten, ein Verfahren (Ebene A/B) | 1,2 | Skeleton |
| D3 | Journal-Schema Robotico bzw. ops | 1,2 | Skeleton |
| D4 | Admin-DB = RoboticoOps | 2 | Skeleton |
| D5 | Reset asynchron via Queue + Agent-Job | 3 | Skeleton |
| D6 | Hybrid-Signing + sysadmin-Job-Owner | 2,3 | Skeleton |
| D7 | Status-SP statt Grants | 3 | Skeleton |
| D8 | Config inkl. Keys in ops.Mandant | 2 | Skeleton |
| D9 | Worker-Neutralisierung im Reset | 3 | Detailed |
| D10 | CW = additiv geteilte Zone; API-Verträge | 1 | Detailed |
| D11 | Nur skriptbasierte Promotion; test1 reguläres Ziel | 1,5 | Detailed |
| D12 | Alt-Skripte bleiben bis Validierung | 5 | Detailed |
| D13 | Hygiene nur manuell | 6 | Detailed |

---

## Iteration Log Pointer

The detailed iteration log lives in the plan file (`mssql-ops-infrastruktur.md` → `## Iteration Log`).

## Implementation Handover (2026-07-10)

- Branch/Worktree: `feature/mssql-ops-infrastruktur` in `worktrees/feature/mssql-ops-infrastruktur`
- Implementation: implement-long-plan-v3, Opus worker agents, user pre-approved all standard choices ("Ich wähle direkt die Standards")
- Post-implementation: static-analysis review pass with Fable agents at LOW effort (user request): correctness vs. plan, no over-complication, no missing features
- Hard constraints for all agents: NO writes against any SQL server (read-only sqlcmd allowed), no secrets in files, edits only inside the worktree
