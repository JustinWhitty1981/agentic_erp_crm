# Quick Start Guide - Agent First ERP CRM

Three things can be "started" in this repository, and they are different exercises:

| | What it is | Where |
|---|---|---|
| **The database** | The schema, its migrations, and the harnesses that assert them | `scripts/db/`, `db/` |
| **The customer service agent** | A deployed agent: Go backend, React UI, HTTP and SSE | `agents/customer_service/` |
| **The inventory agent** | The same loop with stock tools and an in-container check timer | `agents/inventory/` |

`archive/blueprint/` is the reference implementation the other two descend from — a single-file Python
LangChain agent on Telegram. It is lineage: read it for the pattern, deploy from `agents/`. The two
Go backends are the runtime, and
[ADR-006](ARCHITECTURE_DECISION_RECORDS/ADR-006_go_runtime_over_python_reference.md) carries the
measurements behind the switch.

---

## 1. The database

On the development server, `scripts/db/db up` starts the container, provisions the roles and applies
every migration in `db/migrations/`:

```bash
scripts/db/db up        # container, roles, migrations
scripts/db/db verify    # structural assertions (the B-checks)
scripts/db/db test      # function behaviour, probe by probe
```

On any other Postgres, apply the same files in order and nothing else:

```bash
for f in db/migrations/*.sql; do psql "$TARGET" -f "$f"; done
```

> **Do not run `setup_sample_data.sql` to create a schema.** Its first statement is
> `CREATE SCHEMA agent_first_erp_crm`, followed by `CREATE TABLE IF NOT EXISTS` for eight tables
> inside it, and that fork is the root cause of
> [docs/database/DATABASE_REVIEW.md](docs/database/DATABASE_REVIEW.md) §3.1. Seed files in `db/` hold
> data and never DDL; the schema lives in `db/migrations/` and loads into `public`. Everything in this
> repository assumes that, including the tools: a database with the second schema in it is a database
> where `SELECT * FROM vw_customers` works and `SELECT * FROM agent_first_erp_crm.vw_customers` does
> not, which is the symptom to recognise rather than a problem to fix in the caller. The same rule
> covers `scripts/database/` and the `.sql` files sitting in `archive/blueprint/` and `docs/database/`: they
> are the superseded copies the schema came from, listed file by file in `db/README.md`.

Want the demo data the agents' acceptance plan was measured against? `scripts/db/db seed` applies every
`db/seeds/*.sql` in order — both are idempotent by contract, so it is safe to re-run:

```bash
scripts/db/db seed          # 01_demo_customers.sql, then 02_demo_inventory.sql
```

(`01_demo_customers.sql` creates its customers through the same `add_customer` door the agent uses, and
`02_demo_inventory.sql` builds its stock through `execute_inventory_movement` and one reservation, so a
seeded database has a real ledger, not a spreadsheet of numbers.)

A quick way to tell "seeded" from "empty" is to ask the question the data exists to answer:
`SELECT count(*) FROM get_followup_customers(7)` comes back with the seeded customers (five by their
follow-up mark, two because nothing has been said to them lately), and
`SELECT * FROM vw_low_stock_alerts` has a CRITICAL line. Both counts move once the agents have been
prompted — they are the state, not a constant, so read them as a smoke test rather than an assertion.

## 2. The agents

```bash
cd agents/customer_service && docker compose up --build -d   # :4550
cd agents/inventory        && docker compose up --build -d   # :4560
curl -s localhost:4550/api/health | jq
curl -s localhost:4560/api/health | jq
```

`health` is the first thing to read, because a process starts **degraded rather than dead** when the
database is configured and not answering: HTTP 503, a `degraded_reason`, and no domain tools
registered. That is a maintenance window not taking the UI down with it. The state you want is
`"status": "healthy"` with `crm_tools: 8` on `:4550` and `inventory_tools: 5` on `:4560` — `healthy`
rather than `ok`, which is what the field actually says. A `degraded` at HTTP 200 is the other case:
a box deliberately configured with no database, which is a choice rather than a fault.

Both read the same `afpc-pg` and the same tenant, and they are distinguished in every row by
`AGENT_ROLE` → `agent_interactions.bot_id` and `communications.agent_id`.

Configuration comes from the environment; the per-agent READMEs have the table for every key
(`agents/customer_service/README.md`, `agents/inventory/README.md`). The four that decide whether it
works:

| | |
|---|---|
| `AFPC_PG_HOST` | An **IP address**, not a hostname — see dev/README.md on the certificate's SANs. `scripts/db/init.sh` writes it into **each** agent directory's own `.env`, because Compose interpolates `${...}` only from the project's `.env` and a cross-directory read would silently re-blind one agent on re-provision. |
| `AFPC_PG_PASSWORD` | The `afpc_app` role. Read-only roles start fine and fail at the first write. |
| `AFPC_TENANT_ID` | Required. The server refuses to start without it rather than fall back to whichever tenant the connection's `app.default_tenant_id` happens to resolve to. |
| `API_KEYS` | Unset means the endpoints are open, which `/api/health` reports as `DISABLED`. On a shared network, set it. |

## 3. One turn

The five questions the customer service agent exists to answer, as HTTP:

```bash
curl -s localhost:4550/api/chat -H 'content-type: application/json' \
  -d '{"message":"Tell me about Alice Nguyen","thread_id":"web:demo"}'
```

Ask the same thread: *"what's the recent communication history for Alice Nguyen?"*, *"show me stats for
her"*, *"I just spoke with Alice about order ORD-10001, we discussed the shipping timeline"*, *"who
needs a follow-up?"*. The fourth is the one that writes — and note what the response carries:
`{response, thread_id, run_id}`. The `run_id` is the key into the trajectory row this turn wrote, which
is what makes step 4 below a lookup rather than a search.

The inventory agent answers the same kind of question about stock, and reserves against an order on
instruction:

```bash
curl -s localhost:4560/api/chat -H 'content-type: application/json' \
  -d '{"message":"Which items are below their reorder point?","thread_id":"web:demo"}'
```

Streaming, which is what both UIs use:

```bash
curl -Ns localhost:4550/api/chat/stream -H 'content-type: application/json' \
  -d '{"message":"who needs a follow-up?","thread_id":"web:demo"}'
```

Watch the process while you do it — verbose logging is the default, and the tool calls, their masked
arguments, and the model's reasoning are the fastest way to see what the agent actually did:

```bash
docker logs -f afpc-customer-service
docker logs -f afpc-inventory-agent     # includes the scheduled ticks: msg="inventory check"
```

## 4. Verify the database saw it

```bash
psql "host=<server-ip> dbname=agent_first_erp_crm user=afpc_auditor sslmode=verify-full" -c \
  "SELECT started_at, entity_name, communication_type, direction, summary
     FROM vw_recent_communications ORDER BY started_at DESC LIMIT 5;"
```

And the trajectory, which is the record of *how* it answered — every tool call, in order, with what
each returned:

```sql
SELECT * FROM vw_recent_interactions ORDER BY "timestamp" DESC LIMIT 10;
SELECT tool_name, step_number, run_duration_ms FROM vw_tool_calls ORDER BY interaction_at DESC LIMIT 20;
-- the turn you just made, by the run_id the response gave you:
SELECT * FROM vw_tool_calls WHERE run_id = '<that run_id>';
```

`docs/INTERACTION_LOGGING.md` is the page for reading a run back.

## 5. Verify every tool, not just this turn

```bash
./scripts/agents/tool_testplan.sh
```

One prompt per registered tool of both deployed agents — 21 cases, 25 verdicts — each asserted on
three independent planes: the call happened, the state is real, the run recorded itself. The agent's
prose is never the assertion. It takes 10–25 minutes because every case is a real model turn, and it
re-runs cleanly because the fixtures carry a timestamp. Plan and rationale:
[`docs/agent_requirements/agent_test_plan.md`](docs/agent_requirements/agent_test_plan.md).

## Troubleshooting

**Database connection error, and the log says `certificate signed by unknown authority`.** Not a
network fault. `AFPC_PG_SSLROOTCERT` is unset, or the compose file's CA bind mount is missing — the
certificate is exported into `dev/tls/` by `scripts/db/init.sh` and is deliberately not baked into the
image. `require` will appear to work, and is the thing to avoid rather than reach for: it encrypts, and
checks nothing.

**`/api/health` answers 503 with `degraded`.** The database did not answer. The log line names the
host, port, user and sslmode it tried; the most common cause is a hostname where the certificate only
lists IP addresses, so try the IP. Startup itself is not one shot: the ping retries with backoff for
fifteen seconds, which is the reboot window where `afpc-pg` and the agents are separate compose
projects and nothing orders them.

**The agent answers "I don't have a tool for that".** `crm_tools` or `inventory_tools` is 0 in
`/api/health`: the domain tools are registered only with a connection (a tool the prompt promises and
the pool cannot answer looks like a data problem), so a zero there is the degraded case above, not a
missing migration.

**A tool is registered and every call to it errors `relation ... does not exist`.** Registration is
gated on the connection, not per function, so a missing door does not unregister the tool that calls
it. `/api/health` does probe, and reports what it cannot find as `missing_functions` with a
`degraded` 503: the customer service agent checks `add_communication`, `save_memory` and
`get_followup_customers` - one door per migration the deployment needed, 0021/0023/0022 - and the
inventory agent checks `reserve_inventory_for_order` and `save_memory`. A probe list is a claim about
which doors a process opens, so when you fork an agent, edit the list in the same commit as the tools.
`scripts/db/db status` says which migrations are in.

**A customer search comes back "ambiguous, N customers match".** A real refusal, and the behaviour is
the door's: a substring that reaches more than one row is not resolved by whichever row the scan
happened to reach first, and the answer lists the candidates. It happens after running the acceptance
plan more than once, because its fixtures are `Jane Doe 195257` and `Jane Doe 200755` — two rows, one
substring. Re-issue with the id it named. A substring that reaches exactly one row is resolved and
logged normally.

**A streaming turn hangs and then fails.** A proxy between the browser and the agent is buffering SSE.
`LLM_STREAM=false` answers the same turn in one JSON body.

**An answer that contradicts the database, with no tool call in `vw_tool_calls` for the run.** The
thread remembered an earlier conversation: `Rehydrate` loads a thread's prior turns, so reusing a
`thread_id` for a test of *current* state can get a confident answer from history. Use a fresh thread
id — which is why the acceptance harness stamps its threads per invocation.

**The inventory agent's ticks are missing from `agent_interactions`.** The timer runs inside the
container, so no gap means the process was down; check `docker ps` and
`INVENTORY_CHECK_INTERVAL_MINUTES`. "Did it run" is a query here, not a log search.

## Next steps

1. **Read the loop that ships:** `agents/customer_service/backend_go/pkg/agent/agent.go` — the dispatch, the trajectory `defer`, rehydration. `archive/blueprint/bot.py` is the same pattern in one Python file (lineage — [ADR-006](ARCHITECTURE_DECISION_RECORDS/ADR-006_go_runtime_over_python_reference.md)).
2. **Read the deployments:** `agents/customer_service/README.md` and `agents/inventory/README.md` —
   tools, environment, endpoints.
3. **Read the design:** `architecture.md`, then `docs/database/agent_first_erp_crm_mental_model.md`.
4. **Build a new agent:** copy `agents/customer_service/`, replace `pkg/crm` with your domain package,
   write the requirement first (`docs/agent_requirements/<role>/`), put the write rules in a migration
   before the tool that calls them, and keep the trajectory writer — a run you cannot read back is a run
   you cannot fix.

---

*Keep it simple. One agent at a time — and now there are two, which is the argument for the rule.*
*And make the writes go through the database's own functions.*
