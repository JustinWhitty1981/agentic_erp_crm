# Sales & Procurement Agent

The third deployed agent: the one the orders schema was built for. `0027`-`0030` put sales, purchase and
work documents in the database and gave them doors, and this directory is the half that reaches them —
raised the same afternoon, 53 minutes after `0030` was applied. What that order of work bought is the
sentence in *The schedule* below: the agent's first hour found a schema fact rather than a Go bug,
because `0031` had to exist before the keeper it was written to be could keep anything.

Same loop, same trajectory writer, same database-memory store as `agents/customer_service/` and
`agents/inventory/`; different tools, different prompt, and a timer that keeps two policies the schema
has always had from decaying quietly.

Requirements: [`docs/agent_requirements/sales/sales.md`](../../docs/agent_requirements/sales/sales.md).
Backend source: `backend_go/`, module `jada-backend`. Counted with `diff` rather than remembered: of its
26 Go files, **18 are byte-identical** to `agents/customer_service/`'s — all of `pkg/db` among them,
which is the reason the number is written down at all: a fix to the row decoder has to land three times.
**Three differ** — `cmd/server/main.go` (identity, ports, the door-probe list, the timer),
`pkg/agent/agent.go` (the system prompt, and the one line that resolves this agent's name) and that
package's test — and **five are new**: `pkg/orders`.

One identity helper is spelled differently on purpose, and the difference is a fact about the two
forks rather than a style choice. The CRM fork resolves its name twice: `crm.AgentID()` returns `any`
because its only job is to be an argument handed to `add_communication`, while `pkg/agent` reads
`AGENT_ROLE` inline for the trajectory row. Here the same value is both the doors' default —
`performed_by`, `cancelled_by` — and `agent_interactions.bot_id` on every row this process writes,
conversational and scheduled alike, so it is resolved once, in `pkg/orders`' `AgentName()`, and
`pkg/agent` delegates to it. `TestAgentNameResolvesOnceFromTheEnvironment` is the assertion that keeps
the two places one word.

## Running it

```bash
cd agents/sales
docker compose up --build -d          # :4570
curl -s localhost:4570/api/health | jq
```

The UI is at `http://<this machine>:4570/` — the same React app, third copy, four identity strings
different (heading, page title, welcome text, port). It builds into `backend_go/static`, which the
binary serves; `GET /` with no build answers the service JSON, which is all a bare port-check sees.

It talks to the same `afpc-pg` and the same tenant as the other two. `AFPC_PG_HOST` comes from **this
directory's** `.env`, which `scripts/db/init.sh` writes with the address the leaf certificate lists —
one file per agent directory, for the reason recorded in `agents/inventory/README.md`: Compose
interpolates `${...}` from the project's own `.env` and the shell, never from an `env_file` entry, so a
shared file would update one agent on re-provision and silently leave two pointing at an old address.

### What this server's data looks like when it starts

`db/seeds/` raises no orders — there is no orders seed, and that is deliberate rather than an omission,
because a demo purchase order with a fake supplier on the end of it is the kind of row a later report
mistakes for history. So on a fresh database this agent's list is four documents, and all four are
`origin = RESERVATION_BACKFILL`: orders `0030` raised under itself to explain thirteen units that had
been committed since `0015` and could not be released. They have no customer. Ask it "what orders are
there" and it should say exactly that, because the alternative is an agent describing a leak as a
customer.

To get something real to look at, ask for it:

```
Raise a purchase order for 10 of the coolant we already buy from Steelworks Ltd, NET30, needed by the
end of next month. Then add a line for a calibration service, 350, no item.
```

Which is deliberately phrased the way a person phrases it. The agent has to find Steelworks in
`get_suppliers`, find the coolant's `item_id` in `get_order_lines`, resolve "the Main Warehouse" to a
uuid from a document that already names it, and read `current_time` before "end of next month" becomes a
`required_date` — four reads before one write, which is what the tool descriptions are written to make it
do. Ask it for an item that has never been on a document, though, and the honest answer is that it cannot
name one: see *What is not here*.

## The schedule

Every `ORDERS_HOUSEKEEPING_INTERVAL_MINUTES` (default 60; first tick 30 seconds after boot) the process
does two things that the schema was written with and never given a keeper for:

1. **`idempotency_sweep()`** — `0011`'s retention policy said a settled claim is history after 24 hours
   and an unclaimed one is live work. The policy existed; nothing ran it. On the day this agent was built,
   `0030` collected the backlog — 28 rows — and named the keeper as owed. This is the keeper, and
   `0031` is the privilege it needed: `0011` had revoked `EXECUTE` from `afpc_app` deliberately ("garbage
   collection is an operator action", asserted at apply time), so the first tick reconciled four lines
   and answered `42501` on the other half. That closure was written when the only caller in the world was
   a human with psql; a scheduled caller makes its second premise false, and 0031 grants on the strength
   of a measurement rather than of that sentence — two tenants, one expired claim each, one `in_flight`
   claim, `afpc_app` sweeping its own tenant, and the other tenant's rows required to survive.
2. **The reconciliation** — `vw_order_commitments` answers, per line, whether the counter on a document
   agrees with the ledger that moved the stock. Before this timer, the only way to find out was for
   somebody to select it, which is the same class of gap as an alarm nobody subscribes to.

Each tick files a trajectory row like any other run — no model call, because both jobs are one
statement the database answers exactly:

```sql
SELECT timestamp, duration_ms, left(final_output, 90), error_message
  FROM agent_interactions WHERE bot_id = 'sales' ORDER BY timestamp DESC LIMIT 10;
```

That query *is* the reliability requirement: a missing hour is a gap in this list, and a failed tick is
`vw_failed_interactions`. Read `final_output` beside `error_message`, because the two halves are
independent by design and one sentence carries both: `claims swept: 3 expired collected` is a clean hour,
`CLAIM SWEEP FAILED (…): retention was not enforced this tick` is the sweep refusing while the
reconciliation still ran. The earlier shape of that string said `0 expired collected` for a sweep that
had been denied permission, which is the specific way a schedule goes wrong quietly — and it is what the
first hour of this timer actually looked like. `TestATickStillReconcilesWhenTheSweepFails` and
`TestDescribeSaysAFailedSweepFailed` in `pkg/orders/housekeeping_test.go` hold both halves. When the finding changes, the tick also writes `agent_memories` under
`orders.reconciliation.state` — compared against the stored sentence rather than against a rendering,
which is the lesson `agents/inventory`'s check.go records after shipping 48 duplicate memories a day.

A failing tick logs, records, and waits for the next one; the timer recovers from panics and does not
exit, because it shares the process with the chat endpoints. One half failing does not stop the other:
the sweep's error is carried to the row and the reconciliation still scans, still compares, and still
files its memory when the finding moves.

## Tools

Registered only with a connected database, same rule as the other two — a tool the prompt promises and
the pool cannot answer looks like a data problem. `GET /api/tools` is the truth of which set is live.

| Tool | Reads | Write path | Policy |
|------|-------|------------|--------|
| `get_orders` | `vw_orders` | — | read-only |
| `get_order_lines` | `vw_order_lines` | — | read-only |
| `get_order_commitments` | `vw_order_commitments` | — | read-only |
| `get_customers` | `vw_customers` | — | read-only |
| `get_suppliers` | `vw_suppliers` | — | read-only |
| `create_order` | — | `create_order(...)`, claim last (ADR-005) | write |
| `add_order_line` | — | `add_order_line(...)`, claim last | write |
| `transition_order` | — | `transition_order(...)`, claim last | write |
| `add_supplier` | — | `add_supplier(...)`, claim last | write |
| `ship_sales_order` | — | `ship_sales_order(...)`, claim last | write |
| `receive_purchase_order` | — | `receive_purchase_order(...)`, claim last | write |
| `cancel_inventory_reservation` | — | `cancel_inventory_reservation(...)`, claim last | write |

Plus the shared six from `pkg/tools` — `current_time`, `search_web`, `scrape_url`, `save_memory_tool`,
`get_memory_tool` and `list_memories_tool` — the same code as the other two agents'. Naming all six
rather than summarising three of them is not pedantry: those are the strings the system prompt carries,
and a README that says "the three memory tools" cannot be checked against a registry, which is exactly
what `scripts/docs/check_agent_docs.sh` now does to all three agents.

**Twelve domain tools, seven of them writes.** That is wider than either sibling's surface, and the
width is the schema's shape rather than an ambition: a document has three doors that finish it because
shipping, receiving and releasing are three different facts about the world. The alternative — one
`complete_order` tool that branches on `order_type` in Go — would move `order_lifecycle`'s
discrimination rule into a process, which is ADR-002's named failure.

Two doors that exist in the schema are deliberately **not** here:

- **`book_work_order_production`**, `plan_work_order_operation` and `add_work_centre`. A work order can
  be *created* here (WORK, with COMPONENT and PRODUCT lines), and `0030`'s backfill depends on that
  being possible. Booking its production is not: it needs routings, which `0029` §7 declined to invent,
  and a tool that can book output against no routing is a tool that will be described as live before it
  is true.
- **`execute_inventory_movement`.** The inventory agent's reason, inherited verbatim: a process that can
  move stock freely can silence the alarms its own documents raise. Movements here arrive through the
  fulfilment doors, which attach each one to a line.

### What the doors answer

`success` plus the row's own keys (`order_id`, `order_line_id`, `supplier_id`, `reservation_id`) and a
`message`. **A refusal is a row, not an error** — that distinction is `0014`/`0015`/`0016`'s and these
tools keep it — and the message is the database's, verbatim, because it was written for whoever reads
it next. An *error* from a door means a wrong argument or a wall (`22023`, `23514`, `23503`, `40001`),
and `db/tests/7_1_orders.sql` §1f asserts each door is claim-guarded, so a retry of a timed-out
shipment is one shipment.

The one refusal worth knowing in advance is `transition_order` on SHIPPED: `order_lifecycle` marks it
`stock_moving`, the door refuses to write a consequence of stock by hand, and the hint names
`ship_sales_order`. That is not the tool being unhelpful; it is the design of the whole programme
expressed as an error message.

## Endpoints

| | |
|---|---|
| `POST /api/chat` | `{message, thread_id?}` → `{response, thread_id, run_id}`. The `run_id` keys the trajectory row the turn wrote, which is how `scripts/agents/tool_testplan.sh` verifies a case's database effect instead of its prose. |
| `POST /api/chat/stream` | The same turn as SSE. |
| `POST /api/reset` | Clears in-process context for a thread. |
| `GET /api/history` | What the model is currently shown. |
| `GET /api/tools` | The registered surface, with each tool's policy. |
| `GET /api/interactions` | The trajectory: `?view=recent|failed|tool_calls|performance&bot_id=sales`. |
| `GET /api/health` | Status; `order_tools` counts the twelve above; 503 when a configured database could not be reached, when it is not migrated as far as these tools (`missing_functions`), or when the tenant resolves to nothing. |

## Environment

Keys this container sets; the shared ones mean what they mean in `agents/customer_service/README.md`
(`AFPC_PG_*`, `AFPC_TENANT_ID`, `LLM_*`, `LOG_*`, `API_KEYS`, `CORS_ORIGINS`, `STRICT_TOOL_POLICIES`,
`REQUIRE_WRITE_APPROVAL`, `MAX_TOOL_ITERATIONS`, `MAX_BODY_BYTES`, `MEMORY_DRIVER`):

| Variable | Default | Meaning |
|---|---|---|
| `AGENT_ROLE` | `sales` | `agent_interactions.bot_id` on every row this process writes, scheduled or conversational; the `reserved_by` / `performed_by` default on the doors that take one; and half of `conversation_id`, since `ids.Thread` hashes `(bot, thread)` and that is the key history is rehydrated by. Two places, one value, resolved once — `pkg/agent`'s identity test is what keeps them from disagreeing, and finding 4.9 is what a fork that skips this line would cost. |
| `ORDERS_HOUSEKEEPING_INTERVAL_MINUTES` | `60` | The timer. Non-positive or unparsable falls back to 60 **and says 60 in the warning**, because a warning naming the wrong value sends an operator looking for a schedule that is not running. |
| `AFPC_PG_APPNAME` | `sales-agent` | So `pg_stat_activity` can tell these connections from the other two agents', which share the role and the tenant. |
| `REQUIRE_WRITE_APPROVAL` | `false` | Worth turning on for this binary: seven of the twelve domain tools can write. The gate is caller-side, so nothing in the schema changes when it is on. |

## What is not here

- **No work-order production**, no `add_work_centre`. See *Tools* for the reason, which is a routing
  that does not exist rather than a feature that was skipped.
- **No item master, and no warehouse list - but both ids are readable, and that distinction is the
  whole of the difference between a limitation and a dead end.** A line is added with `item_id` **or** a
  description, and every door takes a uuid, so each one has to be *returnable* by some read here:
  `get_order_lines` carries `item_id` beside `sku`, `get_suppliers` carries `supplier_id` (which is what
  `create_order`'s `vendor_id` takes, not an entity id), and `get_orders` and `get_order_lines` carry
  `warehouse_id` beside the name and the code. The last one was not true until 2026-11-07: `vw_orders`
  has had `warehouse_id` since `0028` and the tool's projection left it out, so the agent's own sentence
  was "the list shows warehouse names but not ids" and case 25 raised nothing.
  `TestEveryDoorKeyIsReadableFromARead` is now the assertion that a door's key is returnable by a read
  in this package, and it fails on the day one of those columns goes missing again.

  What remains genuinely open is narrower and worth stating as such: on a database with **no documents
  at all**, this agent cannot resolve a warehouse name, because the only reads that carry the id are
  documents. `PLAN.md` carries `vw_warehouses` as the way to close that - one of the queued two, which
  take 0033 and 0034 in whichever order they land - 0032 went to finding 4.9's conversation re-key.
  What is *not* done is teaching the Go layer to look
  up a code, which would put a second way to name one identity into a process that writes documents.
- **No way to find a reservation to cancel.** `cancel_inventory_reservation` takes `reservation_id`, and
  **no view in this schema returns one** - measured over every `vw_*` column, not guessed: the id lives
  in `inventory_reservations` and `vw_order_commitments` answers everything about a commitment *except*
  its own row's key. The half that works is the creating half - `reserve_inventory_for_order` RETURNS
  `reservation_id`, so a hold an agent raised itself is a hold it can name afterwards - and the half that
  does not is every hold that already existed, which includes all four of this server's backfilled ones.
  So the release door is reachable by a human who runs SQL and not by a conversation, which is the gap
  `0030` was written to close, closed one column short. Acceptance case 33 takes its id from a fixture for
  exactly that reason, and `TestEveryDoorKeyIsReadableFromARead` pins the absence rather than pretending
  otherwise: the day a migration adds the column to a view, that test fails and says to move the name
  into the reachable set.
- **No invoicing, and no money owed.** There is no `invoices` table. `vw_orders`' totals are what a
  document is *worth*; a tool that implied the second from the first would be a second truth.
- **No auto-replenishment.** `vw_low_stock_alerts` and `vw_suppliers.lead_time_days` are enough to
  *compute* a purchase order and nothing here does it. An agent that raises orders on a timer is a
  decision about who funds them; this timer files rows, it does not place orders.
- **No embedding search here.** `communications` is embedded now (`0035`, by the customer service
  agent's keeper) and this process registers no tool over it: a purchase order's `notes` is not a
  conversation, and `get_orders`' filters are the indexed columns, of which `notes` is not one. Sharing
  the search tool across forks is a one-line registration, and one keeper only - two sweeps over one
  column would be two writers of the same fact.
- **No Telegram, no CAO, no push transport.** Alerts land in `agent_interactions` and `agent_memories`.

## Debugging

1. `docker logs -f afpc-sales-agent` — tick lines are `msg="order housekeeping"` with the claim count,
   the line count, the disagreements and the milliseconds.
2. `SELECT * FROM vw_order_commitments WHERE ledger_agreement = 'DISAGREES'` is the alarm itself, asked
   by hand. If it is empty and the timer says otherwise, the timer's row is the wrong one to believe:
   `vw_tool_calls` for that `run_id` shows what the scan actually returned.
3. A stuck commitment is `quantity_unresolved > 0` with `cancel_inventory_reservation` as the way to end
   it. Units in `quantity_committed_unlinked` are held against the *document* and no line — the state
   `0030`'s backfill was written to eliminate, and the reason the view keeps it in its own column.
4. `audit_chain_verify()` for the trail, `agent_memories` keyed `orders.reconciliation.state` for what
   the timer last believed, `vw_idempotency_status` for whether a door a caller keeps retrying is
   actually guarded.
5. **A read tool that works when the caller names something and fails when they do not is a clause
   builder bug, and the error says so: `42P18 could not determine data type of parameter $2`.** Every
   filter in `pkg/orders` is a WHERE fragment handed to one builder, and a fragment with nothing to
   bind (`is_active`, `quantity_open > 0`, `ledger_agreement = 'DISAGREES'`, `is_terminal IS NOT TRUE`,
   `quantity_unresolved > 0`) must contribute no argument. When it contributed a nil, the SQL never
   mentioned that position, Postgres could not infer its type, and the whole query was refused - so the
   failure was not "filter unavailable", it was the read. `get_suppliers` was the worst hit because its
   `is_active` clause is added on the *default* path: 20 of its 28 calls on 2026-11-07 failed, which is
   how the agent came to be told twice that a supplier it had just registered did not exist. The rule
   lives in `clauseFor` (`pkg/orders/args.go`) and `TestNoQuerySendsAParameterItsSQLNeverNames` is what
   keeps a sixth filter from repeating it.
6. **"0 units held unresolved" beside a view that says 13 is a decoding bug, not a data bug.** Until
   2026-11-07 this tick's sums read `pgtype.Numeric` as a number and so got zero, in the one column
   anybody queries, while its JSON was correct; `pkg/db`'s `normalise` unwraps it now, and
   `TestTheTickAddsUpWhatTheViewAddsUpTo` pins the arithmetic. The sibling instance was the claim count
   itself - `idempotency_sweep` RETURNS integer, pgx sends an int32, and the parser did not have that
   arm, so the sweep's number printed 0 whatever it collected.

## Related

- `docs/agent_requirements/sales/sales.md` — what this agent is specified to do, written before the Go
- `db/migrations/0027_suppliers.sql` … `0030_order_fulfilment.sql` — the schema this agent exists for
- `db/tests/7_1_orders.sql` — the probe that fails the day a door stops meaning what `pkg/orders` says
- `docs/agent_requirements/agent_test_plan.md` — the acceptance plan: cases 22-36 are this agent, one per registered tool, with case 29 the refusal that matters and case 35 the timer
- `db/migrations/0031_sweep_keeper_grant.sql` — the privilege this agent's first tick was missing
- `agents/customer_service/`, `agents/inventory/` — the siblings this one is forked from
- `scripts/agents/tool_testplan.sh` — the plan's executable form
