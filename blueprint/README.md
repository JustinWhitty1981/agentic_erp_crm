# Customer Service Agent

A simple, single-file customer service bot built with LangChain v1, Ollama, and PostgreSQL.

## Features

- **Tool Calling**: Automatically decides when to check customer info, log communications, or manage customers
- **Conversation Memory**: Remembers context within a chat session
- **PostgreSQL Integration**: Queries your existing `jarvis_data` database
- **Clean Docker Environment**: Isolated dependencies, no conflicts with your main system

## Prerequisites

- Docker installed on your VM
- PostgreSQL database `jarvis_data` running at `{your-postgres-host}:5432`
- Ollama running with `ornith:35b` at `{your-ollama-host}:11434`
- Telegram bot token (already configured in `.env`)

## Quick Start

### 1. Configure Environment

Copy the `.env.example` to `.env` and fill in your values:

```bash
cp .env.example .env
```

### 2. Run with Docker

```bash
cd /home/justin/agent_swarm/blueprint
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

The bot uses the `agent_swarm` schema in your `jarvis_data` database with these tables/views:

| Table/View | Purpose |
|------------|---------|
| `agent_swarm.customers` | Customer information (name, email, phone, address, status) |
| `agent_swarm.communications` | Communication history (entity_id, type, direction, summary, timestamp) |
| `agent_swarm.entity_communication_stats` | Aggregated stats per entity |
| `agent_swarm.recent_communications` | Recent communication view (last 7 days) |
| `agent_swarm.entities` | Entity records |
| `agent_swarm.entity_relationships` | Entity-contact relationships |
| `agent_swarm.contacts` | Contact details |
| `agent_swarm.addresses` | Address information |

### Database Functions

The bot uses these custom functions (defined in `docs/database/09_customer_functions.sql`):

| Function | Purpose |
|----------|---------|
| `add_customer()` | Add a new customer with validation |
| `update_customer()` | Update customer information |
| `get_followup_customers()` | Get customers requiring follow-up |

The audit log functionality is defined in `docs/database/10_audit_log.sql`.

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

No agent swarms, no multi-agent debates, no complex orchestration. Just a straightforward bot that does what it's supposed to do.

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
├── bot.py                 # Main agent (source of truth)
├── customer_tools.py      # Customer management tools
├── Dockerfile             # Container configuration
├── docker-compose.yml     # Docker orchestration
├── requirements.txt       # Python dependencies
├── .env                   # Environment variables
├── setup_sample_data.sql  # Sample data for testing
├── README.md              # This file
└── tools/                 # Example tools ("soup kitchen")
    ├── README.md
    ├── customer_lookup.py
    ├── communication_logger.py
    └── customer_management.py
```

## Related Documentation

- `docs/database/agent_swarm_schema.sql` - Full database schema
- `docs/database/agent_schema_reference.md` - Schema reference for agents
- `docs/database/09_customer_functions.sql` - Customer management functions
- `docs/database/10_audit_log.sql` - Audit log schema

---

Built with simplicity in mind. Less complexity, more working code.