# Inventory Control Agent

The second deployed agent: stock monitoring on a schedule, and a chat surface that answers
questions about the same data. Same loop, same trajectory writer, same database-memory store as
`agents/customer_service/`; different tools, different prompt, and a goroutine the other one does
not have.

Requirements: [`docs/agent_requirements/inventory/inventory.md`](../../docs/agent_requirements/inventory/inventory.md).
Backend source: `backend_go/` (module `jada-backend`, a sibling lineage of the customer service
agent's — mostly the same packages, rewritten tool layer).

## Running it

```bash
cd agents/inventory
docker compose up --build -d          # :4560
curl -s localhost:4560/api/health | jq
```

It talks to the same `afpc-pg` and the same tenant as the customer service agent. `AFPC_PG_HOST`
is read from `agents/customer_service/.env` — the file `scripts/db/init.sh` writes with the
address the leaf certificate lists — rather than copied, so a re-provision updates both agents by
updating one file.

The demo data this agent reads is `db/seeds/02_demo_inventory.sql`: ten items across two
warehouses with thirty days of movement history, arranged so the alert view has a CRITICAL line,
several LOW lines, healthy stock, and one item whose velocity is genuinely unknown.

## The schedule

Every `INVENTORY_CHECK_INTERVAL_MINUTES` (default 30; first tick 30 seconds after boot) the
process runs a deterministic scan of `vw_low_stock_alerts` — no model call, because 17,520 prompts
a year to run one indexed SELECT is an expense, not an architecture. Each tick files a
trajectory row like any other run:

```sql
SELECT timestamp, duration_ms, left(final_output, 60), error_message
  FROM agent_interactions WHERE bot_id = 'inventory' ORDER BY timestamp DESC LIMIT 10;
```

That query *is* the reliability requirement: "must run every 30 minutes" is a gap in this list,
and "did a check fail" is `vw_failed_interactions` with `bot_id='inventory'`. When the scan finds
CRITICAL lines it also upserts `agent_memories` under `inventory.alert.state` — only when the
finding changed, so the memory says what is true rather than how often the timer woke up.

A failing tick logs, records, and waits for the next one; the timer recovers from panics and does
not exit, because it shares the process with the chat endpoints.

## Tools

Registered only with a connected database, same rule as the customer service agent — a tool the
prompt promises and the pool cannot answer looks like a data problem. `GET /api/tools` is the
truth of which set is live.

| Tool | Reads | Write path | Policy |
|------|-------|------------|--------|
| `get_low_stock_items` | `vw_low_stock_alerts` | — | read-only |
| `get_item_availability` | `vw_item_availability` | — | read-only |
| `get_item_movement_summary` | `vw_item_movement_summary` + the availability view for the stock side of days-of-supply | — | read-only |
| `get_inventory_valuation` | `vw_inventory_valuation` | — | read-only |
| `reserve_inventory` | — | `reserve_inventory_for_order(...)`, idempotency key last (ADR-005) | the only write |

Plus the shared six from `pkg/tools` (`current_time`, `search_web`, `scrape_url`, and the three
memory tools), which resolve to the database store exactly as they do for the customer service
agent.

The door this agent exists next to, `execute_inventory_movement`, is deliberately **not** a tool:
a monitoring agent that can move stock can silence its own alarms. The seed and the
`4_1`/`4_3` probes use it; the agent may not.

### What `reserve_inventory` answers look like

`SUCCESS` with a `reservation_id`, or `INSUFFICIENT_STOCK` with the warehouse's real available
number — the door's two published statuses, passed through with its words. Anything else the door
says is an error to this tool, and it surfaces as one: statuses are business outcomes, errors are
SQLSTATEs, and 0015 decided the door does not mix them. A retried identical call replays from the
claim (ADR-005); a retry after a restock re-evaluates, because a refusal's claim is released, not
cached.

## Endpoints

| | |
|---|---|
| `POST /api/chat` | `{message, thread_id?}` → `{response, thread_id}`. |
| `POST /api/chat/stream` | The same turn as SSE. |
| `POST /api/reset` | Clears in-process context for a thread. |
| `GET /api/history` | What the model is currently shown. |
| `GET /api/tools` | The registered surface, with each tool's policy. |
| `GET /api/interactions` | The trajectory: `?view=recent|failed|tool_calls|performance&bot_id=inventory` — filtering by this agent's rows is the point of `bot_id` here. |
| `GET /api/health` | Status; `inventory_tools` counts the five above; 503 when a configured database could not be reached. |

## Environment

Keys this container sets; the shared ones mean what they mean in
`agents/customer_service/README.md` (`AFPC_PG_*`, `AFPC_TENANT_ID`, `LLM_*`, `LOG_*`, `API_KEYS`,
`CORS_ORIGINS`, `STRICT_TOOL_POLICIES`, `REQUIRE_WRITE_APPROVAL`, `MAX_TOOL_ITERATIONS`,
`MAX_BODY_BYTES`, `MEMORY_DRIVER`):

| Variable | Default | Meaning |
|---|---|---|
| `AGENT_ROLE` | `inventory` | `agent_interactions.bot_id` and `inventory_reservations.reserved_by` when the caller names no one. Two places, one value, resolved once. |
| `INVENTORY_CHECK_INTERVAL_MINUTES` | `30` | The timer. Non-positive or unparsable falls back to 30 with a warning rather than disabling the schedule — the requirement is that checks run. |
| `AFPC_PG_APPNAME` | `inventory-agent` | So `pg_stat_activity` can tell these connections from the customer service agent's, which share the role and the tenant. |

## What is not here

- **No UI.** No React build, no `static/` — the chat endpoints are the interface, and `GET /`
  answers with the service JSON.
- **No Telegram, no CAO.** The requirements doc's push-alerting and validation halves describe
  components this deployment does not have; alerts are database-readable instead. Both live in
  that doc's "What is not here yet" with their real status.
- **No movement, receipt, or write-off.** One write tool exists; see the table for why.
- **No embedding search.** The item reads are exact-sku and ILIKE-name against the views, like
  everything else on this server until an embedder fills the 0012 indexes.
- **The check does not use the model.** Deliberate — see *The schedule*. If a tick's findings
  deserve prose, a human asks for them, and the chat turn pays for the tokens, not the service
  window.

## Debugging

1. `docker logs -f afpc-inventory-agent` — tick lines are `msg="inventory check"` with
   critical/low counts and milliseconds.
2. The trajectory query above: a missing 30-minute gap means the process was down, not that the
   check "failed silently", which is not a state this design has — a tick that dies records
   itself dying.
3. `SELECT * FROM vw_audit_coverage` says the trail exists; `audit_chain_verify()` says it is
   intact; `agent_memories` keyed `inventory.alert.state` says what the timer last believed.
