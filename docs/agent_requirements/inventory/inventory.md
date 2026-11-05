# Inventory Agent Requirements

**Status: the deployed shape of this agent is `agents/inventory/`.** This page was rewritten
in place on 2026-11-04 because the version it replaced predated the schema sweep: it named four
tables (`products`, `stock_levels`, `orders`, `sales_history`) that the canonical migrations do not
create, a Telegram transport the deployment does not have, and a CAO that was never built. The
*intent* of the original — monitor stock, surface shortages, never decide by inference what a human
must decide by hand — survives in full; every mechanic below is one the current database actually
offers. Where the old page said something true in spirit but false in name, that is called out,
because the drift between this page and `db/migrations/` is exactly how an agent gets built wrong.

## Core Identity

- **Role:** Watch stock levels, alert on shortages, and answer questions about inventory in plain
  language. `AGENT_ROLE=inventory`; that value lands in `agent_interactions.bot_id` on every run,
  scheduled or conversational, which is what separates this agent's rows from customer_service's in
  the trajectory views.
- **Shape:** A long-lived Go process running the same loop the customer service agent runs
  (chat over HTTP/SSE, trajectory writer, database memory store), **plus an in-container timer**
  that runs a deterministic stock check every 30 minutes
  (`INVENTORY_CHECK_INTERVAL_MINUTES`, default 30). No host cron: the schedule lives with the
  process it schedules, and both are restarted together.
- **Database access:** reads over the `vw_*` views the schema publishes (ADR-003); writes only
  through the function doors (ADR-002). The one write tool registered from day one is
  `reserve_inventory_for_order`; `execute_inventory_movement` is the door the *seed* uses to
  create stock history, and a tool only if auto-reorder is ever decided on (see "Decided later").

## Functional Requirements

1. **Stock monitoring**
   - *Then:* `SELECT * FROM products WHERE current_stock < minimum_order_quantity`.
   - *Now:* `vw_low_stock_alerts`, which is that predicate and more, maintained by triggers rather
     than recomputed per query: `reorder_point`, `safety_stock`, `lead_time_days`,
     `quantity_on_hand/available/in_transit`, `alert_level`, `stock_percentage`, per warehouse.
     The tool does not reimplement the shortage rule — a rule restated is a rule that can drift,
     and `alert_level` is the schema's own verdict.
   - Days of stock remaining: derived from the 30-day outbound velocity in
     `vw_item_movement_summary` (`total_outbound` over the window, excluding `RESERVATION` rows —
     a commitment makes stock unavailable, it moves nothing). The old page's `sales_history` table
     does not exist; movements are the real ledger of what left the building.
   - Trends ("stock is dropping faster than usual"): same view, current velocity against the
     row's own `daily_average` baseline where the schema provides one.

2. **Alerting**
   - *Then:* "Send alerts via Telegram to the business owner." *Now:* the deployment serves HTTP
     and SSE; no Telegram adapter is wired (AGENTS.md, "What is not here"). An alert is a fact
     recorded where a human or a monitor can read it from the database:
     - every scheduled check writes an **`agent_interactions` trajectory row** (`human_input`
       names it as a scheduled check) with `actions_taken`/`response_sources` recording the items
       it looked at — so "did the 30-minute check run" is a SQL query
       (`WHERE bot_id='inventory'`), and "did any check fail" is
       `vw_failed_interactions`, which is the requirement "must run successfully every 30
       minutes" made checkable;
     - a check that finds critical stock **upserts a memory**
       (`agent_memories`, driver `db`, key **`inventory.alert.state`** - one signature row for the whole
       check rather than one row per SKU, and written only when the signature changed, so the memory
       says what is true rather than how often the timer woke) so the next chat turn can
       answer "what did you find overnight?" without a re-scan;
     - the chat surface can be asked directly at any time: `get_low_stock_items` returns the
       shortage list with `suggested_shortfall` - `reorder_point - quantity_available`, and `null`
       when there is no shortfall. It does **not** round up to `order_multiple`: the column exists
       (`0001`) and nothing in `pkg/inventory` reads it, so a reorder quantity is a human's arithmetic
       from the item's own number, not the tool's. Naming that gap here rather than in code is the
       difference between a deferral and a bug.

3. **Reporting**
   - Low-stock list, per-warehouse availability, 30-day movement summaries, valuation by
     warehouse/category (`vw_inventory_valuation`, per currency — nothing converts): four read
     tools over the four views.
   - *"Log all checks to the audit_log"* — the intent is "every check leaves a trail", and the
     mechanism is now trigger-owned: whatever an inventory run changes lands in `audit_log` via
     `afpc_audit_row`, and whatever it merely *read* lands in `agent_interactions` via the
     trajectory recorder. A tool that INSERTs into `audit_log` itself is the exact shape the
     `code:cs_writes_through_doors` guard rejects; the old page's `log_inventory_check` tool is
     deliberately not built.

## The Tool Surface (as registered)

| Tool | Door or view | Args that matter |
|------|--------------|------------------|
| `get_low_stock_items` | `vw_low_stock_alerts` | optional `category`, `warehouse_id`; bounded `limit` |
| `get_item_availability` | `vw_item_availability` | `sku` or `item_id`, optional `warehouse_id` |
| `get_item_movement_summary` | `vw_item_movement_summary` | item/warehouse, 30-day window is the view's |
| `get_inventory_valuation` | `vw_inventory_valuation` | by warehouse/category/currency |
| `reserve_inventory` | `reserve_inventory_for_order(...)` | item, warehouse, quantity, order_type ∈ {PURCHASE, SALES, WORK, TRANSFER, STOCK}, order_id, reserved_by; **idempotency key last, derived per run** (ADR-005) |

The reserve door returns a status row — `SUCCESS` or `INSUFFICIENT_STOCK` — never an invented
`ERROR`: errors propagate with their SQLSTATE (item does not exist is `22023`, an illegal order
type is `23514`, a live claim lease is `40001`). The tool passes the door's own words through,
because the door's messages are written to be read by whoever asks next.

## Non-Functional Requirements

- **Reliability:** the timer catches panics; a check that dies still lands a trajectory row with
  `error_message` set, because the alternative — silence that looks like success — is what
  `vw_failed_interactions` exists to end.
- **Efficiency:** every read is a view the schema defines over indexed columns; no tool composes
  a query against a business table, so no tool can be slow in a way the schema cannot see and
  `verify.sh` cannot check. The 10,000-product question is a view-plan question, not a tool one.
- **Safety:** read-only by registration — the four read tools carry `Policy.ReadOnly=true` and
  only `reserve_inventory` can change anything, and only the schema's door decides whether it
  did. "Auto-reorder" would need a human to decide that twice: to register the movement tool,
  and to fund the orders it would place.
- **Scalability:** the same mechanism as efficiency; plus one deliberate non-choice — the
  scheduled check does not go through the LLM. It is deterministic Go code; a model call every
  30 minutes, 48 a day, 100% of days, to run a SELECT the database already answered.

## Validation rules

*Then:* "Alerts must include the exact SQL query used for verification; the CAO re-runs it."
*Now:* the CAO does not exist, and an embedded query is a promise to reproduce it faithfully.
The equivalent that is checkable: every run records `response_sources` — the exact
table:row pairs it touched — and the audit chain (`audit_chain_verify()`) makes those rows
re-derivable independently of anything the agent claims. Verification is a second query against
the same view, which is how a reader re-runs the alert's arithmetic anyway.

## Error handling

- Item with no movement history: velocity is unknown, not zero — "cannot compute days of stock"
  says so; `vw_item_movement_summary` answers nothing for it and the tool says that rather than
  dividing by zero or inventing a baseline.
- Item with no `reorder_point`: skipped from the shortage list — the alert rule needs a threshold
  and `vw_low_stock_alerts` already omits such rows (`4_2`'s point); a guess is not a warning.
- Database unreachable at startup: the same contract the customer service agent documents — a
  bounded grace window of retries, then degraded, and `/api/health` says which mode it came up in.
  A scheduled tick that cannot connect records the failed run and waits for the next tick; it
  does not exit, because the container's liveness is not the schedule's business.

## What is not here yet

- **Telegram / any push transport.** The reference implementations have working adapters
  (`archive/blueprint/`, `dumb_agent`); this deployment's transport decision is open. Alerting above is
  database-readable, not notification-delivered.
- **The CAO.** Every "CAO validates" sentence in the old page was written about an agent that has
  never existed. Escalation detection exists in the customer service agent; there is no second
  agent to route to, and this one does not pretend there is.
- **Auto-reorder via `execute_inventory_movement`.** The door is built, probed (`4_1`, `4_3`), and
  used by the seed to create demo history. Registering it as a tool is an explicit decision —
  see Safety.
- **Semantic product search.** The pgvector indexes exist (0012) and no embedder in this
  deployment fills them; `get_item_availability` matches on sku/name via the view, which is
  honest and limited.

## Decided later (open questions, tracked nowhere but here, so here)

- Whether the 30-minute check should *also* file `followups` rows for critical items — the
  `followups` table exists, is probed, and nothing in the deployed system writes it; that is a
  product decision about who owns the task list, not a plumbing gap.
- Whether checks for multiple agents share `agent_interactions` (they do — `bot_id` separates
  them) or a dedicated schedule table earns its keep once there are two scheduled agents.
