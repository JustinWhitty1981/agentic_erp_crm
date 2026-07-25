[![Status](https://img.shields.io/badge/Status-Alpha-orange?style=for-the-badge)](README.md#project-status-early-stage-experimental-prototype)

# Agent Swarm

A **Database-First, Agent-Native** business operating system.
**Minimalalist UI Agents + PostgreSQL + PGVector.**

**Planning and architecture by Justin. Implementation primarily by Jarvis (self-hosted open-source models via Ollama/vLLM on bare metal). No commercial LLM API spend.**

## 🚧 Project Status: Early-Stage Experimental Prototype

> **Warning:** This project is in **active development** and should be considered an **experimental prototype**.

### What This Is
- A **vision** for a database-first, agent-native business operating system
- A **blueprint** for how specialized AI agents can run operations through conversation
- A **foundation** for building self-contained, deployable agents

### What's Under Construction
-  **Tool Library:** Shared utilities (`database.py`, `vector_search.py`, `logger.py`) are not yet implemented
-  **Agent Registry:** No versioning, dependency resolution, or discovery system
-  **Observability:** No centralized logging, monitoring, or error alerting
-  **Security Hardening:** Row-level security and permission models are conceptual
-  **Production Testing:** Not tested at scale or in real-world scenarios

### What You Can Do Now
1. **Run the working blueprint agent** (`blueprint/bot.py`) - A fully functional customer service agent with 8 tools:
   - Customer lookup, communications history, entity statistics
   - Log new interactions, add/update customers, follow-up lists
2. **Study the blueprint** to understand the agent pattern and tool library architecture
3. **Build your own agent** using the reference implementation as a guide
4. **Contribute** to the tool library, registry, or documentation
5. **Provide feedback** on the architecture and design choices

### Roadmap
| Phase | Goal | Status |
|-------|------|--------|
| **Alpha** | Core blueprint + 1 working agent | 🟡 In Progress |
| **Beta** | Tool library + 3 agents + basic registry | ⚪ Planned |
| **1.0** | Production-ready with monitoring, security, docs | ⚪ Future |

---

**We welcome contributors!** If you're interested in helping build the missing pieces, check out `PLAN.md` for priorities and `AGENTS.md` for how to navigate the codebase.

## 🚀 Quick Start for AI Agents

If you're an AI agent working on this project, start here:
- **[AGENTS.md](AGENTS.md)** - Complete guide for AI agents navigating this project
- **[blueprint/bot.py](blueprint/bot.py)** - Reference implementation (~180 lines)
- **[QUICKSTART.md](QUICKSTART.md)** - Setup and deployment instructions

## Vision

Create a swarm of specialized AI agents to run a business where **the conversation is the interface**.

- **No Dashboards:** Natural language UI, simply ask, "How are sales?" and get an instant answer.
- **No Forms:** Say, "Add a note to John's file," and it's done.
- **Shared Memory:** PostgreSQL with PGVector serves as the collective memory for all agents.

## Architecture Overview

- **CAO (Chief Agent Officer):** Jarvis – the gatekeeper, orchestrator, and validator.
- **Specialized Agents:** Independent bots (Customer Service, Inventory, Accounting, etc.) that read/write directly to the database.
- **Shared Memory:** PostgreSQL with **PGVector** for semantic search, context-aware memory, and hybrid queries.
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

## Tech Stack

- **Database:** PostgreSQL with **PGVector** extension (for semantic search).
- **LLM:** `ornith:35b` via Ollama (`http://{your-ollama-host}:11434`) for agent inference.
- **Complex Reasoning:** `qwen3.5:122b` via vLLM (`http://{your-llm-host}:8001`) for architecture decisions.
- **Orchestration:** OpenClaw/Hermes (sessions, cron, memory, message tools).
- **Current Interface:** Telegram (via OpenClaw message tool or direct bot).
- **Validation:** Custom Python framework for CAO verification of agent actions.

## Why This Approach?

| Feature | Traditional ERP | Agent Swarm (Database-First) |
| :--- | :--- | :--- |
| **Interface** | Web UI (Clicks, Forms) | **Conversation (Natural Language)** |
| **Speed** | Slow (API overhead, App layer) | **Instant** (Direct SQL + Vector) |
| **Flexibility** | Fixed schema, hard to change | **Custom schema**, evolve as needed |
| **Agent Access** | Restricted by API permissions | **Full access** (with row-level security) |
| **Memory** | Static records | **Semantic Memory** (PGVector) |

---

*The blueprint pattern ensures simplicity and maintainability across all agents.*
