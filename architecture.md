# Agent First ERP CRM Architecture

## 📚 Documentation Navigation

For AI agents working on this project, see:
- **[AGENTS.md](AGENTS.md)** - Complete navigation guide for AI agents
- **[README.md](README.md)** - Project overview
- **[agents/customer_service/README.md](agents/customer_service/README.md)** and **[agents/inventory/README.md](agents/inventory/README.md)** - the two deployed agents
- **[archive/blueprint/AGENT_SUMMARY.md](archive/blueprint/AGENT_SUMMARY.md)** - the pattern's first statement (lineage; the runtime is Go — [ADR-006](ARCHITECTURE_DECISION_RECORDS/ADR-006_go_runtime_over_python_reference.md))
- **[ARCHITECTURE_DECISION_RECORDS/ADR-006_go_runtime_over_python_reference.md](ARCHITECTURE_DECISION_RECORDS/ADR-006_go_runtime_over_python_reference.md)** - why the deployed half is Go
- **[db/README.md](db/README.md)** - the schema, in the order it is applied

---

## 1. Overview
A small swarm of specialized AI agents, each following a **simple, proven pattern**, sharing one
**PostgreSQL** database as their collective memory and state. Two of them are deployed on this server;
the pattern they were built from is one Python file.

**Core Philosophy:** The conversation **is** the interface. No dashboards, no forms to fill. And under
that: the database, not the agent, is what makes a claim true. A read names a `vw_*` view; a write calls
a stored function. Both land a row someone can read back.

**Design Principle:** Start simple. Complexity comes from orchestration and enforcement, not from
individual agent complexity. Its Python ancestor proved that with one file; the deployed agents proved the
same loop in Go with a tool surface, a trajectory writer, and a second role reusing all of it.

## 2. The blueprint, and its ancestor

| | The blueprint (ships) | The ancestor (archived) |
|---|---|---|
| Where | `agents/customer_service/`, `agents/inventory/` | `archive/blueprint/` |
| Shape | Go backend (module `jada-backend`) + React UI, one process each | `bot.py`, ~215 lines, Python + LangChain |
| Transport | HTTP `POST /api/chat`, SSE `POST /api/chat/stream`, bundled UI | Telegram bot |
| Memory | `agent_memories` (0023) plus history rehydrated from `agent_interactions` on a cold thread | LangChain checkpointer + in-process state |
| Tools | 14 (customer service) / 11 (inventory): domain tools + three memory tools + a clock + two web tools | 8, all customer-domain |
| Schedule | customer service: a prompt. inventory: a prompt **or** a 30-minute in-container timer | whatever wakes the bot |
| Trajectory | the loop's own `defer`: a run that panics still records itself | `interaction_logger.py`, best effort |

The two agree on the rules that matter — which is the point of keeping the archived half in the
repository. Where they disagree, the blueprint is right about this system: **a write calls a database
function and never composes its own INSERT**, and the model never chooses an audit column's value. Why
the ancestor gave up its seat — a connection opened per tool call with no `sslmode`, a
default thread pool running blocking I/O under a GIL, an `InMemorySaver` that dies with the process,
one polling worker — is measured in
[ADR-006](ARCHITECTURE_DECISION_RECORDS/ADR-006_go_runtime_over_python_reference.md).

### 2.1 The ancestor (`archive/blueprint/`) — inert, kept for legibility
- **Single File:** `bot.py` contains all logic (config, tools, agent, Telegram handler)
- **LangChain v1:** automatic tool calling and conversation memory
- **Direct SQL:** parameterized queries via psycopg2
- **Docker Isolation:** clean dependencies, no conflicts
- **Telegram Interface:** direct bot integration
- **Tools registered (8):** `get_customer_info`, `get_customer_communications`, `get_entity_stats`,
  `current_time`, `add_communication`, `add_customer_tool`, `update_customer_tool`,
  `get_followup_customers_tool` — each in its own module under [archive/blueprint/tools/](archive/blueprint/tools/)

### 2.2 The blueprint loop (`agents/*/backend_go/pkg/`)
```
cmd/server/main.go    routes, auth (API_KEYS), startup order: connect (with a grace window) → register
  │                   the domain tools only if a pool exists → start the router (and the timer, in inventory)
  └── pkg/agent       the loop: prompt, tool dispatch, MAX_TOOL_ITERATIONS, rehydration, the
  │                   run record written by defer (run_id, actions, observations, sources, duration)
  ├── pkg/crm         the 8 customer tools        ┐ a tool either reads a vw_* view or calls a
  ├── pkg/inventory   the 5 stock tools + RunCheck ┘ function; it never composes business SQL
  ├── pkg/memory      agent_memories over the same pool; pkg/tools holds the 3 memory tools
  ├── pkg/tools       the registry, policies (read-only / RequiresApproval), the web + clock tools
  ├── pkg/db          pgx pool: TLS modes, tenant claimed on connect, row → JSON (pkg/db/normalise)
  ├── pkg/ids         UUIDv5 derivations: conversation ids, idempotency claim keys
  ├── pkg/turn        which run a call is happening in — a leaf package, on purpose
  ├── pkg/logging     slog with masking, and the agent_interactions writer
  ├── pkg/llm, mcp    inherited from the reference drop; inert on this server (LLM_PROVIDER=local)
  └── pkg/formatters  truncation and fallback summaries
```
`agent` is the only package that talks to the model; `crm`/`inventory` are the only packages that know
the domain's shape; `turn` is imported by everything and imports nothing. That graph is the reason a
second agent was a fork of the tool layer rather than a rewrite of the loop.

## 3. Roles & Responsibilities

### 3.1 Chief Agent Officer (CAO) – not built
The intended gatekeeper, orchestrator, validator and human interface. **There is no CAO process on this
server.** What its job description assumed has been taken by other parts of the system:
- *Validate every action against the database state* → the schema's own constraints, triggers and
  doors refuse what a validator would have refused, and `scripts/agents/tool_testplan.sh` validates
  claims against rows for the whole registered surface.
- *Manage agent identities* → `AGENT_ROLE` in a process's environment, which the loop stamps into
  `communications.agent_id` and `agent_interactions.bot_id`. A value the model can type is a value the
  model can be asked to type, so it never is one.
- *Route tasks between agents* → not implemented. The customer service agent has the detection half of
  an escalation (sentiment, outcomes, `get_entity_stats`) and no second agent to route one to.

### 3.2 Deployed agents
**Customer Service** — `agents/customer_service/`, `:4550`, `AGENT_ROLE=customer_service`
- **Responsibilities:** look customers up, read and log their interactions, maintain their details and
  follow-up marks, remember facts about them.
- **Reads:** `vw_customers`, `vw_customer_communications_summary`, `vw_entity_communication_stats`, and
  the function `get_followup_customers(days)` — the follow-up list is computed from contact history, not
  read from `vw_pending_followups`, because that view sits on the `followups` table and nothing writes it.
- **Writes:** `add_customer`, `update_customer`, `add_communication`, `mark_customer_followup`,
  `save_memory`.
- **Requirements:** [docs/agent_requirements/customer_service/customer_service.md](docs/agent_requirements/customer_service/customer_service.md)

**Inventory Control** — `agents/inventory/`, `:4560`, `AGENT_ROLE=inventory`
- **Responsibilities:** know what is low, where stock is, how it moves, what it is worth; reserve stock
  against an order on instruction; check the state on a schedule whether or not anyone asks.
- **Reads:** `vw_low_stock_alerts`, `vw_item_availability`, `vw_item_movement_summary`,
  `vw_inventory_valuation`.
- **Writes:** `reserve_inventory_for_order` — one door. `execute_inventory_movement` exists in the schema
  and is deliberately **not** a tool: a monitoring agent that can move stock can silence its own alarms.
- **Requirements:** [docs/agent_requirements/inventory/inventory.md](docs/agent_requirements/inventory/inventory.md)

### 3.3 Not built
HR Onboarding, Accounting, Sales, and the Communication (multi-channel) agent. Each would be the
customer service fork with `pkg/crm` replaced, the prompt and identity strings changed, the trajectory
writer and memory store kept, and a README plus a probe. `docs/agent_requirements/` is where a role gets
written down before any of that.

## 4. Database Schema (Shared Memory)

The core is a **PostgreSQL 17 database with PGVector**, reached over `verify-full` TLS, with one tenant
(`AFPC_TENANT_ID`) claimed on every connection.

### 4.1 Core tables
**See [db/README.md](db/README.md) for the single source of truth, and [docs/database/](docs/database/) for the generated catalog listings.**

What the two agents read and write:
- `entities`, `contacts`, `entity_relationships`, `addresses` - the party model; `vw_customers` is its customer-facing join
- `communications` - interaction history; every row arrives through `add_communication`
- `agent_memories` - what an agent was told to remember (0023), append-only by grant
- `agent_interactions` - the trajectory: one row per run, with `actions_taken`, `tool_observations` and `response_sources` aligned step for step
- `audit_log` - one row per row-change on every tenant-coded table except itself and `idempotency_keys`, chained per tenant and month
- `idempotency_keys` - ADR-005 claims: one row per (tenant, operation, key) with the cached answer and a lease
- `inventory_items`, `inventory_on_hand`, `inventory_movements`, `inventory_reservations`, `warehouses`, `item_categories`, `units_of_measure`, `costing_methods`, `currencies`, `currency_rates` - the stock side, which is what makes the second agent possible
- `followups` - exists, read by `vw_pending_followups`, and has **no writer** in the schema; `add_communication` sets the follow-up flags on the interaction and stops there (0021 §5 hands the decision over)
- `schema_migrations` - what has been applied, and the reason a file cannot be renumbered

**Not in the schema:** `orders`, `products`, `tickets`, `agents`. The first two are still planned.
`tickets` was in the vestigial schema and is referenced by nothing in the canonical one - follow-ups
are `followups`, and 0017 removed the tables that competed with it. `agents` is not a table because
the agent registry is a process's environment (`AGENT_ROLE`) and a column on every row it writes.
And two tables that exist are vestigial rather than live: `human_sessions` and `bot_actions` are read by
the audit-coverage machinery and written by neither implementation, so their row counts are zero and a
monitor pointed at them would be watching an empty pipe.

Everything lives in `public`. An earlier draft of this list qualified each name to a schema
named `agent_first_erp_crm.`, which review 3.1 measured was never created by any migration; the
qualified form resolves only on a machine that ran the old scripts by hand.

### 4.2 Why PGVector?
- **Semantic Search:** "Find customers who complained about shipping" (no exact keyword matching).
- **Contextual Memory:** Agents remember past interactions without rigid schema constraints.
- **Hybrid Queries:** Combine structured SQL (`WHERE status = 'open'`) with unstructured semantic search.

Two of the three are honest aspirations. The indexes and the `vector(1536)` columns are there (0012) and
empty: no embedder in this deployment produces 1536 dimensions — measured, the local models answer 1024
and 4096. The contextual memory that *is* live is the relational kind: `agent_memories` by key, and
thread history read back out of `agent_interactions`.

## 5. Communication Flow

### 5.1 Human → Agent
- A person types into the React UI, or `curl`s `POST /api/chat`, or — in the archived ancestor only —
  messaged a Telegram bot.
- The process rehydrates the thread from `agent_interactions` if it has no in-process memory of it, runs
  the loop — model, tool calls, observations, up to `MAX_TOOL_ITERATIONS` round trips — and answers.
- The answer and every call it took are already a row by the time the response finishes.

### 5.2 Agent → the database (the path that actually enforces something)
- A read goes to a `vw_*` view, so a state the views cannot show is a state the agent cannot see either.
- A write calls a stored function; the loop's three claim-sending tools (`add_customer`,
  `add_communication`, `save_memory_tool`) pass an idempotency key derived from the run and the resolved
  arguments (ADR-005), and `vw_idempotency_status` names the functions — `update_customer` and
  `mark_customer_followup` among them — that are unguarded because they set values rather than append
  rows, so a retry lands the same state instead of a second one. The function's own triggers write
  `audit_log`. The agent supplies no audit column value and cannot bypass a constraint it has no door
  through.

### 5.3 Validation, without a CAO
- The acceptance harness is the standing verification: prompt each tool, then check three independent
  planes - the call happened (`vw_tool_calls` keyed by the returned `run_id`), the state is real (the
  views, tables, and trail the answer names), the run recorded itself (`agent_interactions`,
  `response_sources`, `observations_aligned`).
- `audit_chain_verify()` says whether any trail segment has been rewritten.
- What is *not* here is a second model judging the first. Requirement 7 wants one; the detection half
  exists and the routing half does not.

## 6. Model Strategy

### 6.1 Agent Inference (Runtime)
- **Primary Model:** `qwen3.8-flash-next`, served by vLLM behind an OpenAI-compatible endpoint
  (`VLLM_BASE_URL=http://<gpu-host>:18300/v1`, `LLM_PROVIDER=local`).
- **Why:** self-hosted on bare metal, which is the project's stated constraint — no commercial LLM API
  spend, and the trajectory records a run against a model the operator controls.
- **Streaming:** `LLM_STREAM=true` by default; `false` answers the same turn in one JSON body, which is
  the knob for a proxy that buffers SSE.
- Earlier drafts of this page named `ornith:35b` via Ollama on `:11434`. That is not what these
  containers are configured to call, and `/api/health` prints what is actually in force.

### 6.2 Complex Reasoning (Architecture/Decisions)
- Done by the coding agents and humans on this machine, not by a service the agents call. The `azure_gcc_high`
  provider in `pkg/llm` is inherited from the reference implementation and unused; its one failing test
  is named in the customer service README rather than quietly excluded.

## 7. Security & Compliance
- **Least Privilege:** one runtime role (`afpc_app`) for the agents, two read-only roles for humans
  (`afpc_readonly`, `afpc_auditor`), grants declared in `scripts/db/roles.sql` and asserted by the
  verify harness. Row-level security is `FORCED` on every tenant-coded table; `vw_rls_status` publishes
  each policy verbatim along with which tables are global by decision.
- **Transport:** `sslmode=verify-full` against a CA exported into `dev/tls/`; `AFPC_PG_HOST` must be an
  address the leaf certificate lists in its SANs, which is why `scripts/db/init.sh` writes it per agent
  directory instead of leaving it to a human memory.
- **Endpoint auth:** `API_KEYS` (bearer). Unset means open, and `/api/health` says `DISABLED` out loud
  rather than implying safety.
- **PII:** the process log masks; `LOG_LEVEL=debug` is the only mode that logs arguments at all.
- **SSRF and egress:** `scrape_url` refuses private addresses unless `ALLOW_INTERNAL_SCRAPE` says
  otherwise, and caps the read at `MAX_SCRAPE_BYTES`; `search_web` refuses without a key. Both refusals
  are asserted by the acceptance plan, because a guardrail nobody tests is a rumour.
- **Audit Trail:** `audit_log` — one row per row-change, chained, append-only by grant — plus one
  `agent_interactions` row per run. Neither has a "validation status" column, because nothing validated
  them at write time; the trail's job is to make the claim checkable afterwards.
- **SQL Safety:** agents reach the database through views and functions; parameterized everywhere else.

## 8. Scalability
- **Modular Design:** the second agent cost a tool layer, a prompt, four identity strings and a timer —
  the loop, pool, memory store and trajectory writer were reused whole.
- **Context Management:** each agent has its own conversations and memory keys; both share one database,
  and `bot_id` is what separates their rows in it.
- **Database Performance:** indexed views for the reads the agents actually issue (redundancy is
  measurable: `vw_index_redundancy`), BRIN and partitioning still queued as migration 0024.
- **Honest limit:** PGVector indexes exist and nothing fills them, so "fast semantic search over
  millions of records" describes a plan, not this deployment.

## 9. Development Workflow

### 9.1 Adding a New Agent
1. **Read the loop that ships:** `agents/customer_service/backend_go/pkg/agent/agent.go` — dispatch, the trajectory `defer`, rehydration. [archive/blueprint/bot.py](archive/blueprint/bot.py) is the same pattern in 215 Python lines and is background reading, not an on-ramp ([ADR-006](ARCHITECTURE_DECISION_RECORDS/ADR-006_go_runtime_over_python_reference.md)).
2. **Write the requirement first:** `docs/agent_requirements/<role>/<role>.md`, naming the views and functions that exist — a doc that names tables which the schema sweep removed is how an agent gets built against a fiction.
3. **Fork the deployment, not the ancestor:** `cp -r agents/customer_service agents/<role>`, replace `pkg/crm` with your domain package, keep `pkg/agent`, `pkg/db`, `pkg/memory`, `pkg/logging`, `pkg/turn`.
4. **Build the write half in SQL first** (`db/migrations/NNNN_*.sql`, next free number — see `db/MIGRATIONS.md` on why numbers cannot be reused), then the tool that calls it, with an idempotency key (ADR-005).
5. **Give it an identity:** `AGENT_ROLE=<role>`, a distinct `AFPC_PG_APPNAME`, its own port, and a `bot_id` that will therefore appear on every row it writes. There is no registration step because there is no registry; the environment and the grants *are* the registration.
6. **Document it** in `agents/<role>/README.md` — the tool table must match `GET /api/tools`, because `scripts/docs/check_agent_docs.sh` fails when they don't.
7. **Test both halves:** `go test ./...` for the loop, a `db/tests/` probe for the schema, and a case in `docs/agent_requirements/agent_test_plan.md` + `scripts/agents/tool_testplan.sh` per tool — the plan's whole claim is that a human's prompt reaches a real row.

### 9.2 Testing
Five things can be wrong independently, and each has its own harness — `verify.sh` (structure),
`test-functions.sh` (behaviour, one probe per finding), `go test` (the loop against fakes), `pytest
archive/blueprint/tests/` (the ancestor, against a scratch database — read the hazard note in
`AGENTS.md` first), and `scripts/agents/tool_testplan.sh`
(a real prompt through a real model, verified against the database). `AGENTS.md` has the commands.

---

*This architecture emphasizes simplicity and maintainability. Each agent is a standalone, testable unit running the blueprint loop — one loop, one database, every run recorded. Its ancestor first stated the pattern in a single Python file.*
*Complexity comes from orchestration and validation, not from individual agent complexity.*
