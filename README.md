[![Status](https://img.shields.io/badge/Status-Alpha-orange?style=for-the-badge)](README.md#project-status-early-stage-experimental-prototype)

# Agent First ERP CRM

A **Database-First, Agent-Native** business operating system.
**Minimalist UI Agents + PostgreSQL + PGVector.**

**Planning and architecture by Justin. Implementation primarily by Jarvis (self-hosted open-source models via Ollama/vLLM on bare metal). No commercial LLM API spend.**

## 🚧 Project Status: Early-Stage Experimental Prototype

> **Warning:** This project is in **active development** and should be considered an **experimental prototype**.

### What This Is
- A **deployed customer service agent** - Go backend, React UI, HTTP and SSE, in `agents/customer_service/`, writing through the database's own functions
- A **schema that enforces what the documentation claims**: 22 applied migrations, row-level security on every tenant-coded table, a tamper-evident row trail, and idempotency claims for retryable writes
- A **blueprint** for how specialized agents can run operations through conversation - `blueprint/bot.py`, the same rules in one Python file
- And a method: every claim in `db/` and in these pages has a check that fails when the claim stops being true

### What's Under Construction
- **Semantic search:** the hnsw indexes exist (`0012`) and nothing writes the vectors, because no embedder in this deployment produces the dimensions the columns declare. "Find customers who complained about shipping last week" is not implemented
- **Agent registry:** no versioning, dependency resolution, or discovery. An agent is a process with an `AGENT_ROLE` and a set of grants
- **More agents:** the customer service agent is the only one deployed. The inventory schema side is ready; the agent is not
- **Escalation:** requirement 7's detection half exists (sentiment, outcomes, per-customer stats); there is no second agent to escalate *to*
- **Observability beyond the table:** the trajectory is queryable (`vw_recent_interactions`, `vw_tool_calls`, `vw_tool_performance`) but nothing aggregates it into an alert

What is *not* under construction, and was listed here as though it were: row-level security (enforced, `FORCE ROW LEVEL SECURITY`, with `vw_rls_status` publishing what each policy actually does), the tool library (fourteen tools in the deployed agent, nine of them in the blueprint), and logging (one row per run, every tool call, plus the PII-masked process log).

### What You Can Do Now
1. **Run the deployed agent** - `cd agents/customer_service && docker compose up --build -d`, then `curl -s localhost:4550/api/health | jq`. Eleven tools: customer lookup, communications history, entity statistics, follow-up lists, add/update customer, log an interaction, mark a follow-up, remember a fact, the clock, and two web tools
2. **Study the blueprint** to understand the agent pattern and tool library architecture
3. **Build your own agent** using the reference implementation as a guide
4. **Contribute** to the tool library, registry, or documentation
5. **Provide feedback** on the architecture and design choices

### Roadmap
| Phase | Goal | Status |
|-------|------|--------|
| **Alpha** | Core blueprint + 1 working agent | 🟢 Done: the blueprint, and a deployed agent behind it |
| **Beta** | Tool library + 3 agents + basic registry | ⚪ Planned |
| **1.0** | Production-ready with monitoring, security, docs | ⚪ Future |

---

**We welcome contributors!** If you're interested in helping build the missing pieces, check out `PLAN.md` for priorities and `AGENTS.md` for how to navigate the codebase.

## 🚀 Quick Start for AI Agents

If you're an AI agent working on this project, start here:
- **[AGENTS.md](AGENTS.md)** - Complete guide for AI agents navigating this project
- **[agents/customer_service/](agents/customer_service/)** - The deployed agent; **[blueprint/bot.py](blueprint/bot.py)** - the reference implementation
- **[QUICKSTART.md](QUICKSTART.md)** - Setup and deployment instructions

## Vision

Create a swarm of specialized AI agents to run a business where **the conversation is the interface**.

- **No Dashboards:** Natural language UI, simply ask, "How are sales?" and get an instant answer.
- **No Forms:** Say, "Add a note to John's file," and it's done.
- **Shared Memory:** PostgreSQL with PGVector serves as the collective memory for all agents.

## Architecture Overview

- **CAO (Chief Agent Officer):** Jarvis – the gatekeeper, orchestrator, and validator. (currently in test, not ready for peer review)
   - Heremes/OpenClaw, or BYO (build your own)
- **Specialized Agents:** Independent bots (Customer Service, Inventory, Accounting, etc.) that read/write directly to the database.
- **Shared Memory:** PostgreSQL with **PGVector** for semantic search, context-aware memory, and hybrid queries.
  - [Reference (JARVIS Blueprint)](https://github.com/JustinWhitty1981/openclaw_blueprint/blob/main/JARVIS_BLUEPRINT_OODA.md) - Built and in use, not yet ready for peer review
  - [Performance Audit (14-Day)](https://github.com/JustinWhitty1981/openclaw_blueprint/blob/main/14-DAY_PERFORMANCE_AUDIT.md) - Demonstrates benefits of shared memory architecture
- **Interface:** Telegram, Teams, Slack, lightweight UI → Natural Language → SQL/Vector Queries → Response.
- **Validation:** Every agent action is logged and verified.

## Documentation Navigation

| Document | Purpose |
|----------|---------|
| [AGENTS.md](AGENTS.md) | **Start here** - AI agent navigation guide |
| [architecture.md](architecture.md) | System architecture and agent roles |
| [QUICKSTART.md](QUICKSTART.md) | Setup and deployment instructions |
| [PLAN.md](PLAN.md) | Development roadmap and priorities |
| [blueprint/AGENT_SUMMARY.md](blueprint/AGENT_SUMMARY.md) | Blueprint pattern reference |
| [docs/database/](docs/database/) | Database schema and documentation |
| [OpenClaw Blueprint (Precursor)](https://github.com/JustinWhitty1981/openclaw_blueprint/tree/main) | Reference implementation and performance benchmarks |

## Tech Stack

- **Database:** PostgreSQL with **PGVector** extension (for semantic search).
- **LLM:** `ornith:35b` via Ollama (`http://{your-ollama-host}:11434`) for agent inference.
- **Complex Reasoning:** `qwen3.5:122b` via vLLM (`http://{your-llm-host}:8001`) for architecture decisions.
- **Orchestration:** OpenClaw/Hermes (sessions, cron, memory, message tools).
- **Current Interface:** Telegram (via OpenClaw message tool or direct bot).
- **Validation:** Custom Python framework for CAO verification of agent actions.

## Why This Approach?

| Feature | Traditional ERP | Agent First ERP CRM (Database-First) |
| :--- | :--- | :--- |
| **Interface** | Web UI (Clicks, Forms) | **Conversation (Natural Language)** |
| **Speed** | Slow (API overhead, App layer) | **Instant** (Direct SQL + Vector) |
| **Flexibility** | Fixed schema, hard to change | **Custom schema**, evolve as needed |
| **Agent Access** | Restricted by API permissions | **Full access** (with row-level security) |
| **Memory** | Static records | **Semantic Memory** (PGVector) |

---

*The blueprint pattern ensures simplicity and maintainability across all agents.  Agent orchestration is difficult enough!*
