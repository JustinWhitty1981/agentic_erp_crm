# Agent Blueprint: Customer Service Bot

> **Deprecated as a runtime — this is lineage.** The pattern's first statement, in ~215 Python
> lines. Understand the loop here if you want it in one file; **build against
> `../../agents/customer_service/backend_go/`**, which is what actually ships. The Telegram handler,
> the `InMemorySaver`, and the per-tool `psycopg2.connect` described below are the reference's
> shape, not the running system's. Why the runtime switched to Go:
> [ADR-006](../../ARCHITECTURE_DECISION_RECORDS/ADR-006_go_runtime_over_python_reference.md).

**Purpose**: The pattern in one file, each part paired with its counterpart in the running system.
Read it to learn what the loop is made of; the page that says what ships is
[`../../agents/customer_service/README.md`](../../agents/customer_service/README.md).

---

## The two shapes, side by side

| Part | Blueprint (`bot.py` unless noted) | Runtime (`agents/customer_service/backend_go` unless noted) |
|---|---|---|
| Entry point | `main()` → `application.run_polling()` (`bot.py:195,212`) | `cmd/server/main.go`: connect → register tools → serve |
| Transport | Telegram long-poll; one worker per process | `net/http`: `POST /api/chat`, `POST /api/chat/stream` (SSE), `/api/history`, `/api/reset`, `/api/tools`, `/api/health`, `/` (`main.go:309-333`); bearer tokens via `API_KEYS` (`main.go:62`), unset means open and `/api/health` says so |
| Conversation loop | LangChain `create_agent` (`bot.py:121`) | `RunChatStream` / `RunChatSync` (`pkg/agent/agent.go:361,531`), bounded by `MAX_TOOL_ITERATIONS` (`agent.go:594`) |
| System prompt | `SYSTEM_PROMPT` (`bot.py:75-101`) | `SystemPrompt()` (`pkg/agent/agent.go:48`) |
| Memory | `InMemorySaver()` (`bot.py:119`) — dies with the process | `agent_memories` (migration 0023) through `MEMORY_DRIVER` (`pkg/memory/memory.go:46`), plus `Rehydrate` from `agent_interactions` on a cold thread (`agent.go:289`) |
| Thread key | `f"user_{user_id}"` (`bot.py:163`) | the caller's `thread_id`, and a UUIDv5 of it (`pkg/ids/ids.go:39`) so any replica resolves the same conversation |
| Database access | `get_db_connection()` per tool call, no `sslmode` (`tools/*.py`) | one `pgxpool` (`pkg/db/pg.go`), tenant claimed in `AfterConnect` via `set_config('app.tenant_id',$1,false)` |
| Blocking I/O under concurrency | `run_in_executor(None, …)` — default thread pool, GIL (`bot.py:167`) | goroutine per request; `pgx` waits on the socket, not on a lock |
| Trajectory | `interaction_logger.py`, best effort | the loop's `defer` in `RunChatStream` (`agent.go:371-375`): a run that panics still files its `agent_interactions` row via `logging.Recorder` (`pkg/logging/interactions.go:288,322`) |
| Tool surface | 8 tools in `TOOLS` (`bot.py:103-112`) | 14 registered: 8 CRM (`pkg/crm/tools.go`) + 6 shared (`pkg/tools/tools.go:290,312,335`, `pkg/memory`), each a `ToolDefinition` with `ReadOnly` / `RequiresApproval` (`pkg/tools/tools.go:23-37`) |
| Configuration | `.env` read at import (`bot.py:1-35,55-73`) | process env; the tables are each agent's README (`AFPC_PG_*`, `LLM_PROVIDER`, `VLLM_*`, `API_KEYS`, `AGENT_ROLE`, …) |

The design principle survives the switch untouched: **one agent, one job, no swarm**. What changed
is the substrate, not the shape.

---

## File Structure

```
archive/blueprint/
├── bot.py                     # the loop, prompt, builder, handlers - 215 lines
├── tools/                     # the eight registered tools, one module each
│   ├── customer_lookup.py         get_customer_info
│   ├── customer_communications.py get_customer_communications
│   ├── entity_stats.py            get_entity_stats
│   ├── current_time.py            current_time
│   ├── add_communication.py       add_communication
│   ├── add_customer.py            add_customer_tool
│   ├── update_customer.py         update_customer_tool
│   ├── followup_customers.py      get_followup_customers_tool
│   ├── tool_logger.py             trajectory accumulation helper (no database code; see its top note)
│   └── communication_logger.py    earlier shape of add_communication - imported by nothing
├── interaction_logger.py      # the best-effort trajectory writer bot.py hands each run to
├── Dockerfile, docker-compose.yml, requirements.txt, .env
├── *.sql                      # SUPERSEDED pre-0001 copies - see ../db/README.md
└── docs/                      # agent-friendly SQL docs; views.md's lists are checked vs the catalog
```

`bot.py` by section: config and env (`1-35`, with `DB_CONFIG` at `66-73`), `markdown_to_html`
(`35`), system prompt (`75-101`), `TOOLS` (`103-112`), `build_agent` (`116-128`), handlers
(`136-192`), `main` (`195-212`).

---

## Core Components

### 1. Agent construction — `build_agent()` (`bot.py:116-128`)

```python
model = ChatOllama(model=OLLAMA_MODEL, base_url=OLLAMA_URL, temperature=0.7)
checkpointer = InMemorySaver()
agent = create_agent(model=model, tools=TOOLS, system_prompt=SYSTEM_PROMPT,
                     checkpointer=checkpointer)
```

**Runtime counterpart**: no builder step at all — `AgentManager` is a struct wired in `main.go`
after the pool connects; the model is an OpenAI-compatible vLLM endpoint (`LLM_PROVIDER=local`),
not Ollama; and the checkpointer is a Postgres table. The one process that constructs the agent is
also the one that can rehydrate it, which is the property `InMemorySaver` cannot have.

### 2. The loop — `handle_message` (`bot.py:156-187`)

Reads the message, derives `thread_id`, hands the whole `agent.invoke` to
`run_in_executor(None, lambda: …)` (`bot.py:167-169`) because every tool call underneath is
synchronous psycopg2, then replies.

**Runtime counterpart**: `RunChatStream` owns the same iteration — send messages, parse tool calls,
execute, append results, loop until the model answers or `MAX_TOOL_ITERATIONS` — but as
goroutine-native code with per-event SSE emission, and wrapped in the defers that make the
trajectory row a promise rather than a hope.

### 3. The database path — `get_db_connection()` in every tool module

Ten `conn = get_db_connection()` sites and ten `conn.close()` across the eight tools: each call is
a fresh TCP handshake and authentication, plaintext (`grep sslmode archive/blueprint/` is empty), against a
server whose contract is `sslmode=verify-full`.

**Runtime counterpart**: `pkg/db/pg.go` — one pool, `AfterConnect` claims the tenant once per
connection, `Query`/`Call` are the only two shapes a tool can read through, and `ids.CallKey`
(`pkg/ids/ids.go:62`) derives the ADR-005 idempotency key the writes send.

---

## Tool Reference — each Python tool, and what replaced it

| Blueprint tool (`bot.py`'s `TOOLS`) | Reads / calls (Python) | Runtime tool | Where, and what changed |
|---|---|---|---|
| `get_customer_info` | `vw_customers` | `get_customer_info` | `pkg/crm/tools.go:90` — same view, pool instead of a fresh connect |
| `get_customer_communications` | `vw_recent_communications` (`customer_communications.py:44`) | `get_customer_communications` | `pkg/crm/tools.go:179` — moved to `vw_customer_communications_summary` (0022), so history is not capped at 7 days |
| `get_entity_stats` | `vw_entity_communication_stats` | `get_entity_stats` | `pkg/crm/tools.go:267` — same view |
| `current_time` | no database | `current_time` | moved to the shared package: `pkg/tools/tools.go:290` |
| `add_communication` | calls `add_communication()` | `add_communication` | `pkg/crm/tools.go:462` — now sends an idempotency key (`:539`); the Python never could retry safely |
| `add_customer_tool` | calls `add_customer()` | `add_customer` | `pkg/crm/tools.go:371` — renamed to the door's name; key at `:409` |
| `update_customer_tool` | calls `update_customer()` | `update_customer` | `pkg/crm/tools.go:420` — same door, one head since 0016 |
| `get_followup_customers_tool` | `FROM get_followup_customers(%s)` (`followup_customers.py:50`) | `get_followup_customers` | `pkg/crm/tools.go:327` — a parameterised read is a door call, not a view (ADR-003's boundary) |

Registered by the runtime and **not** by the blueprint: `mark_customer_followup`
(`pkg/crm/tools.go:550`), the three memory tools over `agent_memories` (`pkg/memory`), and
`search_web` / `scrape_url` (`pkg/tools/tools.go:312,335`). Hence 8 there, 14 here — and
`GET /api/tools` is the enumeration that is true.

`communication_logger.py` is the ancestor of `add_communication.py` and is imported by nothing;
`tool_logger.py` accumulates per-call observations in process and hands them to the trajectory
writer — no database code, and the note at its top explains why it used to.

---

## Database Schema

The agent uses the `agent_first_erp_crm` **database** in PostgreSQL, and every object resolves in its
`public` schema. `agent_first_erp_crm.` as a *schema* qualifier belongs to the pre-0001 scripts review
3.1 disproved, and `code:tool_prefix` keeps `archive/blueprint/**/*.py` at zero references to it. Both
implementations read and write the same catalog — that is the point of the pattern:

- **Tables behind the reads**: `entities`, `contacts`, `entity_relationships`, `addresses`,
  `communications`
- **Views the tools name**: `vw_customers`, `vw_customer_communications_summary`,
  `vw_entity_communication_stats` (the Python additionally reads `vw_recent_communications`, which
  the runtime no longer needs for this). `archive/blueprint/docs/views.md` lists each view's columns against
  `pg_attribute`, and `code:agent_docs_match_surface` fails when they drift
- **Functions (the doors)**: `add_customer`, `update_customer`, `add_communication`,
  `get_followup_customers` in `db/migrations/0001` + `0016` + `0021`; signatures in
  [docs/customer_functions.md](docs/customer_functions.md)
- **The trail**: `audit_log` (triggers, chained per tenant and month) and `agent_interactions`
  (the run). The blueprint writes the second best-effort and gets the first anyway — the triggers
  do not check who called. The runtime makes the run row a `defer`.

---

## Environment Variables

The blueprint's `.env` (`bot.py:1-35` reads it at import):

```env
TELEGRAM_BOT_TOKEN={your-telegram-bot-token}
OLLAMA_BASE_URL=http://{your-ollama-host}:11434
OLLAMA_MODEL=ornith:35b
POSTGRES_HOST={your-postgres-host}
POSTGRES_PORT=5432
POSTGRES_DB=agent_first_erp_crm
POSTGRES_USER=agent_first_erp_crm
POSTGRES_PASSWORD={yourpasswordhere}
LOG_LEVEL=INFO
```

The runtime's are a different set — `AFPC_PG_*` for the role and pool, `LLM_PROVIDER`/`VLLM_*` for
the model, `API_KEYS` for auth, `AGENT_ROLE`, `MEMORY_DRIVER`, `MAX_TOOL_ITERATIONS` — and each
agent's README table is the authoritative list, because `scripts/docs/check_agent_docs.sh` fails
when one drifts. Note `POSTGRES_USER` above is a database *role name equal to the database name*:
the pre-0001 shape; the runtime connects as `afpc_app`, which has no owner privileges and therefore
obeys RLS.

---

## Agent Behavior Patterns

### Tool calling
Unchanged in substance: the model decides from the prompt, and both implementations run the
same loop — call, feed results back, until an answer or the iteration cap.

### Memory
- Blueprint: `InMemorySaver` + `thread_id = f"user_{user_id}"`; nothing survives a restart, and a
  second process means a second, divergent memory.
- Runtime: what the caller asks to be remembered goes to `agent_memories` through the three memory
  tools (0023), and a cold `thread_id` pulls the thread's last exchanges back out of
  `agent_interactions` (`Rehydrate`, keyed by `ids.Thread`). This is the fix, not a difference of
  taste — see ADR-006 §3.

### Response handling
- Blueprint: `markdown_to_html` (`bot.py:35`) because Telegram parses HTML, plus escaping.
- Runtime: the answer is markdown for a browser, and `pkg/db`'s `normalise` decides what a row can
  say (RFC 3339 with offset, bytea decoded, uuids canonical) — `normalise_test.go` pins it.

---

## Building an agent today

Not from this directory. Fork `../../agents/customer_service/` — `cp -r`, replace `pkg/crm` with your
domain package, keep `pkg/agent`, `pkg/db`, `pkg/memory`, `pkg/logging`, `pkg/turn`, give it a port,
an `AGENT_ROLE`, an `AFPC_PG_APPNAME` — `architecture.md` §9.1 is the full route, and
`agents/inventory/` is the worked example. What you would have copied from `bot.py` — the loop, the
prompt's register, the tool descriptions — is already in Go with a trajectory writer attached.

## Extension ideas

- Add more tools — in the runtime: a migration door first, then `pkg/<domain>/tools.go` (ADR-002)
- "Replace `InMemorySaver` with `PostgresSaver`" — this one is **done**, and differently: the
  runtime's memory is `agent_memories` plus rehydration, not a checkpointer swap
- File uploads: the design record is `../../docs/ATTACHMENT_SYSTEM.md`
- Agent validation layer: still unbuilt (the CAO's rows in `../../AGENTS.md`)
- Multi-language: neither half

## Troubleshooting (the reference only)

| Issue | Solution |
|-------|----------|
| "TELEGRAM_BOT_TOKEN not set" | Check `.env` — the name `bot.py:61` reads |
| "Database connection error" | Credentials, and remember: no TLS in this path |
| "Tool not found" | Defined *and* in `TOOLS` (`bot.py:103-112`) — a module nothing imports is invisible |

For the runtime: `curl localhost:4550/api/health | jq`, then `GET /api/interactions?view=recent` —
the agent reading its own trajectory is a feature here and has no Python equivalent.

---

## Related Files

- [ADR-006](../../ARCHITECTURE_DECISION_RECORDS/ADR-006_go_runtime_over_python_reference.md) — why the pairing table above exists
- [../agents/customer_service/README.md](../../agents/customer_service/README.md) — the runtime's surface
- [docs/customer_functions.md](docs/customer_functions.md) — the customer doors
- [docs/views.md](docs/views.md) — the views, column lists checked against the catalog
- `../../db/migrations/0013_audit_log.sql` — the trail this pattern does *not* write: see the banner above

---

*Blueprint version: 1.0, paired against the runtime 2026-11-05*
