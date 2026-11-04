# Quick Start Guide - Agent First ERP CRM

Two things can be "started" in this repository, and they are different exercises:

| | What it is | Where |
|---|---|---|
| **The database** | The schema, its migrations, and the harnesses that assert them | `scripts/db/`, `db/` |
| **The customer service agent** | The deployed agent: Go backend, React UI, HTTP and SSE | `agents/customer_service/` |

`blueprint/` is the reference implementation the second is derived from — a single-file Python
LangChain agent on Telegram. Read it to learn the pattern; deploy `agents/customer_service/`.

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
> not, which is the symptom to recognise rather than a problem to fix in the caller.

Want the demo customers the agent's tests were measured against? `db/seeds/01_demo_customers.sql` is
idempotent, and `get_followup_customers(7)` answers six rows afterward, which is a fast way to tell
"seeded" from "empty".

## 2. The agent

```bash
cd agents/customer_service
docker compose up --build -d          # publishes :4550
curl -s localhost:4550/api/health | jq
```

`health` is the first thing to read, because the process starts **degraded rather than dead** when the
database is configured and not answering: HTTP 503, a `degraded_reason`, and no CRM tools registered.
That is a maintenance window not taking the UI down with it. `"status": "ok"` with `"crm_tools": 8` is
the state you want.

Configuration comes from the environment, and `agents/customer_service/README.md` has the table for
every key. The four that decide whether it works:

| | |
|---|---|
| `AFPC_PG_HOST` | An **IP address**, not a hostname — see dev/README.md on the certificate's SANs. |
| `AFPC_PG_PASSWORD` | The `afpc_app` role. Read-only roles start fine and fail at the first write. |
| `AFPC_TENANT_ID` | Required. The server refuses to start without it rather than fall back to whichever tenant the connection's `app.default_tenant_id` happens to resolve to. |
| `API_KEYS` | Unset means the endpoints are open, which `/api/health` reports as `DISABLED`. On a shared network, set it. |

## 3. One turn

The five questions the agent exists to answer, as HTTP:

```bash
curl -s localhost:4550/api/chat -H 'content-type: application/json' \
  -d '{"message":"Tell me about Alice Johnson","thread_id":"web:demo"}'
```

Ask the same thread: *"what's the recent communication history for Alice Johnson?"*, *"show me stats
for her"*, *"I just spoke with Alice about order ORD-10001, we discussed the shipping timeline"*,
*"who needs a follow-up?"*. The fourth is the one that writes.

Streaming, which is what the UI uses:

```bash
curl -Ns localhost:4550/api/chat/stream -H 'content-type: application/json' \
  -d '{"message":"who needs a follow-up?","thread_id":"web:demo"}'
```

Watch the process while you do it — verbose logging is the default, and the tool calls, their masked
arguments, and the model's reasoning are the fastest way to see what the agent actually did:

```bash
docker logs -f afpc-customer-service
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
```

`docs/INTERACTION_LOGGING.md` is the page for reading a run back.

## Troubleshooting

**Database connection error, and the log says `certificate signed by unknown authority`.** Not a
network fault. `AFPC_PG_SSLROOTCERT` is unset, or the compose file's CA bind mount is missing — the
certificate is exported into `dev/tls/` by `scripts/db/init.sh` and is deliberately not baked into the
image. `require` will appear to work, and is the thing to avoid rather than reach for: it encrypts, and
checks nothing.

**`/api/health` answers 503 with `degraded`.** The database did not answer. The log line names the
host, port, user and sslmode it tried; the most common cause is a hostname where the certificate only
lists IP addresses, so try the IP.

**A streaming turn hangs and then fails.** A proxy between the browser and the agent is buffering SSE.
`LLM_STREAM=false` answers the same turn in one JSON body.

**The agent answers "I don't have a tool for that".** Either `crm_tools` is 0 in `/api/health`
(degraded, see above) or the database is migrated to before `0021`, in which case `add_communication`
does not exist and the startup line says so — it probes for the three functions the deployment needs.

**Every customer search comes back ambiguous.** The seed worked. Two customers share a substring; the
function refuses rather than guessing and lists the candidates, which is what `add_communication` does
with a name like "Alice".

## Next steps

1. **Read the pattern:** `blueprint/bot.py` — the same loop in one file.
2. **Read the deployment:** `agents/customer_service/README.md` — tools, environment, endpoints.
3. **Read the design:** `architecture.md`, then `docs/database/agent_first_erp_crm_mental_model.md`.
4. **Build a new agent:** copy `agents/customer_service/`, change the tools in `pkg/crm` and the prompt
   in `pkg/agent`, and keep the trajectory writer — a run you cannot read back is a run you cannot fix.

---

*Keep it simple. One agent at a time. And make the writes go through the database's own functions.*
