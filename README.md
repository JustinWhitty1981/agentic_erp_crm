[![Status](https://img.shields.io/badge/Status-Alpha-orange?style=for-the-badge)](README.md#project-status-early-stage-experimental-prototype)

# Agent First ERP CRM

A **Database-First, Agent-Native** business operating system.
**Minimalist UI Agents + PostgreSQL + PGVector.**

**Planning and architecture by Justin. Implementation primarily by Jarvis (self-hosted open-source models on bare metal, served through an OpenAI-compatible endpoint). No commercial LLM API spend.**

## 🚧 Project Status: Early-Stage Experimental Prototype

> **Warning:** This project is in **active development** and should be considered an **experimental
> prototype**. What is here works against one tenant on one server, and every claim below names the
> check that proves it.

### What This Is
- **Two deployed agents**, not one: a customer service agent (`agents/customer_service/`, `:4550`) and
  an inventory control agent (`agents/inventory/`, `:4560`). Both are Go backends with a React UI, HTTP
  and SSE transports, and the same agent loop — the second is a sibling fork of the first with the tool
  layer replaced and a check timer added.
- **A schema that enforces what the documentation claims**: 23 applied migrations (`0000`-`0018`,
  `0021`-`0023`, `0026`), row-level security `FORCED` on all 21 tenant-coded tables while the six
  exceptions are declared with their reasons rather than forgotten (five global by decision, one build
  ledger — `vw_rls_status` publishes every predicate verbatim and gives a verdict), a tamper-evident row
  trail chained per tenant and month (`audit_log`, `audit_chain_verify()`), and idempotency claims for
  retryable writes (`vw_idempotency_status` says which functions are guarded and which are not).
- **A blueprint** for how specialized agents can run operations through conversation —
  `blueprint/bot.py`, the same rules in one Python file with LangChain and Telegram. It is lineage:
  the runtimes are the two Go backends, and
  [ADR-006](ARCHITECTURE_DECISION_RECORDS/ADR-006_go_runtime_over_python_reference.md) records the
  measurements behind that switch.
- **And a method**: every claim in `db/` and in these pages has a check that fails when the claim stops
  being true, including an acceptance harness that prompts each deployed agent once per registered tool
  and verifies the answer against the database rather than against the agent's own prose
  (`docs/agent_requirements/agent_test_plan.md`, `scripts/agents/tool_testplan.sh` — 21 cases, 25
  verdicts, all green as of 2026-11-04).

### What's Under Construction
- **Semantic search:** the hnsw indexes exist (`0012`) and nothing writes the vectors, because no
  embedder in this deployment produces the dimensions the columns declare — measured, the local models
  answer 1024 and 4096. "Find customers who complained about shipping last week" is not implemented.
- **Agent registry:** no versioning, dependency resolution, or discovery. An agent is a process with an
  `AGENT_ROLE` and a set of grants, not a row in a table — `agents` is not a table and nothing pretends
  otherwise.
- **A third agent, and the swarm the vision assumes:** two roles are deployed (customer service,
  inventory). Accounting, sales, HR and the communication agent are documentation and table space.
- **Escalation:** requirement 7's detection half exists (sentiment, outcomes, per-customer stats); there
  is no CAO agent to escalate *to*, so the escalation path ends in a status value on a row.
- **Observability beyond the table:** the trajectory is queryable (`vw_recent_interactions`,
  `vw_tool_calls`, `vw_tool_performance`) and the inventory agent's scheduled checks land a row per tick
  so "did it run" is a query, but nothing aggregates any of it into an alert.
- **Two audit tables nothing writes:** `human_sessions` and `bot_actions` exist, are read by the audit
  coverage machinery, and have zero rows from either implementation. The trail that *is* written is
  `audit_log` (triggers) and `agent_interactions` (the loop). Say so before pointing a monitor at them.

What is *not* under construction, and was listed here as though it were: row-level security (enforced,
`FORCE ROW LEVEL SECURITY`, with `vw_rls_status` publishing what each policy actually does), the tool
library (fourteen tools in the customer service agent, eleven in the inventory agent, eight of them
the same CRM surface the blueprint registers), logging (one row per run with every tool call in it, a
process log that masks what it can, and a trajectory that deliberately does not - `agents/customer_service/README.md`'s
"what reaches the log" explains why the record has to keep the values to be a record), and inventory
writes (reservations go through `reserve_inventory_for_order`, which is a
day-one tool and whose ledger bug 0026 found and fixed).

### What You Can Do Now
1. **Run the customer service agent** — `cd agents/customer_service && docker compose up --build -d`,
   then `curl -s localhost:4550/api/health | jq`. Fourteen tools: eight CRM (three reading `vw_*` views,
   five calling stored functions), three memory tools over `agent_memories`, the clock, and two web
   tools.
2. **Run the inventory agent** — `cd agents/inventory && docker compose up --build -d`, then
   `curl -s localhost:4560/api/health | jq`. Eleven tools: four stock reads, one reservation door, and
   the same six shared tools — plus a 30-minute deterministic check whose every tick files a trajectory
   row.
3. **Run the acceptance plan against both** — `./scripts/agents/tool_testplan.sh`. It is slow (every
   case is a real model turn) and it re-runs cleanly (fixtures carry a timestamp).
4. **Read the loop** — `agents/customer_service/backend_go/pkg/agent/agent.go` is the shape of a run
   turn: dispatch, trajectory defer, rehydration. `blueprint/bot.py` is the same pattern in 215 Python
   lines — background reading, not an on-ramp ([ADR-006](ARCHITECTURE_DECISION_RECORDS/ADR-006_go_runtime_over_python_reference.md)).
5. **Contribute** to the tool library, the schema's doors, or the documentation — `AGENTS.md` is the
   route map and `PLAN.md` is the queue.

### Roadmap
| Phase | Goal | Status |
|-------|------|--------|
| **Alpha** | Core blueprint + 1 working agent | 🟢 Done: the blueprint, and a deployed agent behind it |
| **Alpha+** | A second agent on the same loop, and an acceptance plan that verifies it | 🟢 Done 2026-11-04: `agents/inventory/`, `scripts/agents/tool_testplan.sh` |
| **Beta** | Tool library + 3 agents + basic registry | 🔵 2 of 3 agents deployed; the registry and the third role are open |
| **1.0** | Production-ready with monitoring, security, docs | ⚪ Future — the monitoring half needs an alerting path that does not exist yet |

---

**We welcome contributors!** If you're interested in helping build the missing pieces, check out `PLAN.md` for priorities and `AGENTS.md` for how to navigate the codebase.

## 🚀 Quick Start for AI Agents

If you're an AI agent working on this project, start here:
- **[AGENTS.md](AGENTS.md)** - Complete guide for AI agents navigating this project
- **[agents/customer_service/](agents/customer_service/)** and **[agents/inventory/](agents/inventory/)** - the two deployed agents; **[blueprint/](blueprint/)** - the pattern's first statement, in one Python file: lineage, not a runtime ([ADR-006](ARCHITECTURE_DECISION_RECORDS/ADR-006_go_runtime_over_python_reference.md))
- **[QUICKSTART.md](QUICKSTART.md)** - Setup and deployment instructions
- **[docs/agent_requirements/agent_test_plan.md](docs/agent_requirements/agent_test_plan.md)** - how a turn is proven, tool by tool

## Vision

Create a swarm of specialized AI agents to run a business where **the conversation is the interface**.

- **No Dashboards:** Natural language UI, simply ask, "How are sales?" and get an instant answer.
- **No Forms:** Say, "Add a note to John's file," and it's done.
- **Shared Memory:** PostgreSQL holds the collective memory of all agents in tables both agents read;
  PGVector is where semantic recall will live, and its columns are empty until an embedder is deployed
  that matches them.

## Architecture Overview

- **CAO (Chief Agent Officer):** the gatekeeper, orchestrator, and validator. **Not built.** What exists
  instead is the schema's own enforcement plus the trajectory: a run that claims something can be read
  back and checked, and a write that has no door cannot happen.
   - Heremes/OpenClaw, or BYO (build your own)
- **Specialized Agents:** Independent processes (customer service and inventory are deployed) that read
  `vw_*` views and call stored functions — never compose their own INSERT against business tables.
- **Shared Memory:** PostgreSQL with **PGVector** for semantic search, context-aware memory, and hybrid
  queries. The context part is real today (`agent_memories`, plus conversation history rehydrated from
  `agent_interactions` after a restart); the semantic part is not.
- **Interface:** the deployed agents speak HTTP and SSE into a React UI; the blueprint speaks Telegram.
  The transport is a `main.go` change and the loop does not care which is attached.
- **Validation:** every agent action lands a row — in `agent_interactions` for the run, in `audit_log`
  for the row-change — and the acceptance harness asserts the database agrees with what the agent said.

## Documentation Navigation

| Document | Purpose |
|----------|---------|
| [AGENTS.md](AGENTS.md) | **Start here** - AI agent navigation guide |
| [architecture.md](architecture.md) | System architecture and agent roles |
| [QUICKSTART.md](QUICKSTART.md) | Setup and deployment instructions |
| [PLAN.md](PLAN.md) | Development roadmap and priorities |
| [agents/customer_service/README.md](agents/customer_service/README.md) | The deployed customer service agent: tools, environment, endpoints |
| [agents/inventory/README.md](agents/inventory/README.md) | The second deployed agent, and its check timer |
| [db/README.md](db/README.md) | **Single source of truth for the schema**, and which SQL directories are superseded |
| [db/MIGRATIONS.md](db/MIGRATIONS.md) | finding → migration, one row per thing the review found |
| [dev/README.md](dev/README.md) | This development server: container, roles, TLS, gotchas |
| [docs/agent_requirements/agent_test_plan.md](docs/agent_requirements/agent_test_plan.md) | The acceptance plan for every tool of both agents |
| [blueprint/AGENT_SUMMARY.md](blueprint/AGENT_SUMMARY.md) | The pattern's first statement, in Python — lineage, not a runtime |
| [ARCHITECTURE_DECISION_RECORDS/ADR-006_go_runtime_over_python_reference.md](ARCHITECTURE_DECISION_RECORDS/ADR-006_go_runtime_over_python_reference.md) | Why the runtime is Go and the blueprint is lineage |
| [docs/database/](docs/database/) | Database schema and documentation |
| [OpenClaw Blueprint (Precursor)](https://github.com/JustinWhitty1981/openclaw_blueprint/tree/main) | Reference implementation and performance benchmarks |

## Tech Stack

- **Database:** PostgreSQL 17 with **PGVector** (`pgvector/pgvector:pg17`), TLS `verify-full`, three
  roles (`afpc_app` for the agents, `afpc_readonly` and `afpc_auditor` for humans reading).
- **Agents:** Go backends (module `jada-backend`, one per agent), a React UI built into the binary's
  `static/`, chi router, `pgx` pool.
- **LLM:** `qwen3.8-flash-next` on vLLM behind an OpenAI-compatible endpoint
  (`VLLM_BASE_URL=http://<host>:18300/v1`, `LLM_PROVIDER=local`) for agent inference. Self-hosted; no
  commercial API spend. The Azure path in `pkg/llm` is inherited from the reference drop and unused
  here.
- **Orchestration:** none yet — the CAO is not built, so an agent's schedule is either a human prompt or
  the inventory container's own timer.
- **Current Interface:** HTTP `POST /api/chat` and SSE `POST /api/chat/stream`. Telegram exists in the
  blueprint and in the upstream reference, not in the deployed agents.
- **Validation:** the database's own constraints and doors, the trajectory table, and
  `scripts/agents/tool_testplan.sh`, which is the custom framework standing in for CAO verification.

## Why This Approach?

| Feature | Traditional ERP | Agent First ERP CRM (Database-First) |
| :--- | :--- | :--- |
| **Interface** | Web UI (Clicks, Forms) | **Conversation (Natural Language)** |
| **Speed** | Slow (API overhead, App layer) | **Direct SQL** (through views and functions, not free-form queries) |
| **Flexibility** | Fixed schema, hard to change | **Custom schema**, migrations in order, every one of them asserted |
| **Agent Access** | Restricted by API permissions | **Full access** (with row-level security enforced, `vw_rls_status`) |
| **Memory** | Static records | **Rows first** (`agent_memories`, `agent_interactions`); semantic recall via PGVector is designed, not deployed |
| **Accountability** | "Someone changed it" | **One row per change, chained** — `audit_log` plus a per-run trajectory |

---

*The blueprint pattern ensures simplicity and maintainability across all agents.  Agent orchestration is difficult enough!*
