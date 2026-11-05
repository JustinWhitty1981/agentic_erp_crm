# Customer Service Agent

> **Deprecated as a runtime — this is lineage.** `bot.py` is still the shortest statement of the
> pattern this repository runs on, and it stays in the tree for that reason. But no deployed agent
> runs this code path, and following the setup below gets you plaintext database connections, a
> conversation memory that dies with the process, and no trajectory row — correct pattern, wrong
> substrate. The runtimes are `agents/customer_service/backend_go` and
> `agents/inventory/backend_go`; the four measurements behind the switch are in
> [ADR-006](../ARCHITECTURE_DECISION_RECORDS/ADR-006_go_runtime_over_python_reference.md).

A simple, single-file customer service bot built with LangChain v1, Ollama, and PostgreSQL.

## Features

- **Tool Calling**: Automatically decides when to check customer info, log communications, or manage customers
- **Conversation Memory**: Remembers context within a chat session
- **PostgreSQL Integration**: Queries your existing `agent_first_erp_crm` database
- **Clean Docker Environment**: Isolated dependencies, no conflicts with your main system

## Prerequisites

- Docker installed on your VM
- PostgreSQL database `agent_first_erp_crm` running at `{your-postgres-host}:5432`
- Ollama running with `ornith:35b` at `{your-ollama-host}:11434`
- Telegram bot token — there is no `.env` here and no `.env.example` either; create one, or export `TELEGRAM_BOT_TOKEN` - the name `bot.py:61` reads and `docker-compose.yml:12` passes through

## Quick Start

### 1. Configure Environment

There is no `.env.example` in this directory, so create the file and fill it in:

```bash
printf 'TELEGRAM_BOT_TOKEN=\nPOSTGRES_HOST=\nPOSTGRES_DB=agent_first_erp_crm\n' > .env
```

### 2. Run with Docker

```bash
cd "$(git rev-parse --show-toplevel)/blueprint"
docker-compose up --build
```

### 3. Run Locally (for development)

```bash
pip install -r requirements.txt
python bot.py
```

## Testing the Bot

Send a message to your Telegram bot:
- "Show me customers who need follow-up"
- "Look up customer John Smith"
- "Get communications for Sarah Johnson"
- "What are the stats for Acme Corp?"
- "Log a call with customer John Smith about their order"
- "What time is it?"
- "Add a new customer: John Doe, john@example.com, 555-1234"
- "Update customer John Smith's phone to 555-9999"

## Database Schema

Everything lives in **`public`** of the `agent_first_erp_crm` database. This section used to say the bot
uses an `agent_first_erp_crm` *schema*, which review 3.1 measured no migration creates - and the
difference is not cosmetic, because a qualified name raises 42P01 while an unqualified one resolves, so
the sentence was a description of the failure rather than of the system.

| Table or view | Purpose |
|---------------|---------|
| `entities` | The organisation side: what a "customer" is in this model |
| `contacts` | The people, with the name, email, phone and status the tools read |
| `entity_relationships` | Which contact belongs to which entity, and which one is primary |
| `addresses` | Where they are; one entity can have several, with `address_type` naming which |
| `communications` | Interaction history - one row per interaction, and `add_communication` is the only door |
| `vw_customers` | The backward-compatibility view: `entities` and `contacts` shaped like the old `customers` table |
| `vw_recent_communications` | The last seven days |
| `vw_entity_communication_stats` | Aggregated metrics per entity |

### Database Functions

The bot uses these custom functions (the doors listed in [docs/customer_functions.md](docs/customer_functions.md) - `db/migrations/0001`, `0016`, `0021`; that `docs/database/` path was a superseded copy):

| Function | Purpose |
|----------|---------|
| `add_customer()` | Add a new customer with validation |
| `update_customer()` | Update customer information |
| `get_followup_customers()` | Get customers requiring follow-up |

The audit log functionality is `db/migrations/0013_audit_log.sql`: triggers writing `audit_log` in `public`, chained per tenant and month, and `audit_chain_verify()` reading the chain back. `blueprint/10_audit_log.sql` is the superseded copy, and it created `agent_first_erp_crm.audit_log` - a schema no migration makes, which is finding 3.1.

## Architecture

This is a **simple agent** pattern:
- **Single LLM**: `ornith:35b` via Ollama (configurable in `.env`)
- **LangChain v1**: Handles tool calling and memory automatically
- **InMemorySaver**: Short-term conversation history per user
- **PostgreSQL**: Long-term customer data and communication history
- **Telegram**: User interface for the bot

### Tools (8 total)

| Tool | Description |
|------|-------------|
| `get_customer_info` | Look up customer information by name |
| `get_customer_communications` | Get recent communications for a customer |
| `get_entity_stats` | Get communication statistics for an entity |
| `add_communication` | Log a new customer communication |
| `current_time` | Return the current local date and time |
| `add_customer_tool` | Add a new customer to the database |
| `update_customer_tool` | Update an existing customer's information |
| `get_followup_customers_tool` | Get customers requiring follow-up |

No agent swarms (multi-agent systems), no multi-agent debates, no complex orchestration. Just a straightforward bot that does what it's supposed to do.

## Stopping the Bot

```bash
docker-compose down
```

Or if running locally:
```bash
pkill -f "python bot.py"
```

## Development

To run in foreground for debugging:

```bash
docker-compose up --build
```

To exec into the container:

```bash
docker exec -it cs-bot sh
```

## Project Structure

```
blueprint/
├── bot.py                 # The whole pattern in one file - lineage, not the runtime (see the banner above)
├── Dockerfile             # Container configuration
├── docker-compose.yml     # Docker orchestration
├── requirements.txt       # Python dependencies
├── .env                   # Environment variables
├── setup_sample_data.sql  # SUPERSEDED: creates the twin schema; the seeds are ../db/seeds/
├── README.md              # This file
└── tools/                 # Example tools ("soup kitchen")
    ├── README.md
    ├── customer_lookup.py
    ├── communication_logger.py
```

## Related Documentation

- `docs/database/agent_first_erp_crm_schema.sql` - Full database schema
- `docs/database/agent_schema_reference.md` - Schema reference for agents
- [docs/customer_functions.md](docs/customer_functions.md) - the customer doors, with the signatures that exist
- `db/migrations/0013_audit_log.sql` - the trail, and `docs/INTERACTION_LOGGING.md` for the run record

---

Built with simplicity in mind. Less complexity, more working code.