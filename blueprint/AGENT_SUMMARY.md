# Agent Blueprint: Customer Service Bot

**Purpose**: This document provides an agent-friendly summary of the Customer Service Bot blueprint. Use this to understand, recreate, or extend this agent pattern.

---

## Blueprint Overview

This is a **simple single-agent** customer service bot that:
- Connects to Telegram for user interaction
- Uses LangChain v1 for tool calling and memory
- Queries a PostgreSQL database for customer data
- Can add, update, and lookup customers
- Logs communications automatically

**Key Design Principle**: Simplicity. No agent swarms (multi-agent systems), no complex orchestration. Just one agent doing one job well.

---

## File Structure

```
blueprint/
├── bot.py                 # Main agent (source of truth - 180 lines)
├── customer_tools.py      # Customer management tools (180 lines)
├── Dockerfile             # Container configuration
├── docker-compose.yml     # Docker orchestration
├── requirements.txt       # Python dependencies (12 packages)
├── .env                   # Environment variables
├── setup_sample_data.sql  # Sample data for testing
├── README.md              # User documentation
└── tools/                 # Example tools ("soup kitchen")
    ├── README.md
    ├── customer_lookup.py
    ├── communication_logger.py
    └── customer_management.py
```

---

## Core Components

### 1. Main Agent (bot.py)

**Entry Point**: `main()` function starts the Telegram bot.

**Key Sections**:
1. **Configuration** (lines 1-35): Loads env vars for Telegram, Ollama, PostgreSQL
2. **System Prompt** (lines 38-56): Defines agent capabilities and behavior
3. **Tools** (lines 59-170): 8 tools for customer operations
4. **Agent Builder** (lines 173-185): Creates LangChain agent with memory
5. **Telegram Handlers** (lines 191-240): Handles incoming messages

**Agent Construction**:
```python
model = ChatOllama(model=OLLAMA_MODEL, base_url=OLLAMA_URL, temperature=0.7)
checkpointer = InMemorySaver()
agent = create_agent(
    model=model,
    tools=TOOLS,
    system_prompt=SYSTEM_PROMPT,
    checkpointer=checkpointer,
)
```

### 2. Customer Tools (customer_tools.py)

Three specialized tools for customer management:
- `add_customer_tool()` - Add new customers with validation
- `update_customer_tool()` - Update customer information
- `get_followup_customers_tool()` - Get customers needing follow-up

---

## Tool Reference

| Tool | Purpose | Key Parameters |
|------|---------|----------------|
| `get_customer_info` | Look up customer by name | `customer_name` |
| `get_customer_communications` | Get communication history | `customer_name` |
| `get_entity_stats` | Get communication statistics | `entity_name` |
| `add_communication` | Log a new interaction | `customer_name`, `direction`, `communication_type`, `summary` |
| `current_time` | Get current date/time | None |
| `add_customer_tool` | Add new customer | `first_name`, `last_name`, `email`, `phone`, `street`, `city`, `state`, `postal_code`, `country` |
| `update_customer_tool` | Update customer | `search_name`, `first_name`, `last_name`, `email`, `phone`, `street`, `city`, `state`, `postal_code`, `country`, `status` |
| `get_followup_customers_tool` | Get follow-up list | `days_threshold` (default: 7) |

---

## Database Schema

The agent uses the `agent_first_erp_crm` schema in PostgreSQL:

**Core Tables**:
- `entities` - Customer entities (companies, individuals)
- `contacts` - Individual contact records
- `entity_relationships` - Links entities to contacts
- `addresses` - Customer addresses
- `communications` - Communication history

**Key Views**:
- `customers` - Backward compatibility view
- `recent_communications` - Last 7 days of communications
- `entity_communication_stats` - Aggregated metrics

**Custom Functions** (in `docs/database/09_customer_functions.sql`):
- `add_customer()` - Add customer with validation
- `update_customer()` - Update customer information
- `get_followup_customers()` - Get customers needing follow-up

---

## Environment Variables

Required variables in `.env`:

```env
# Telegram
TELEGRAM_BOT_TOKEN={your-telegram-bot-token}

# Ollama
OLLAMA_BASE_URL=http://{your-ollama-host}:11434
OLLAMA_MODEL=ornith:35b

# PostgreSQL
POSTGRES_HOST={your-postgres-host}
POSTGRES_PORT=5432
POSTGRES_DB=agent_first_erp_crm
POSTGRES_USER=agent_first_erp_crm
POSTGRES_PASSWORD={yourpasswordhere}

# Logging
LOG_LEVEL=INFO
```

---

## Agent Behavior Patterns

### Tool Calling Logic
The agent automatically decides when to use tools based on the system prompt:
- User asks about customer → `get_customer_info`
- User asks about communications → `get_customer_communications`
- User mentions speaking to customer → Offers to log with `add_communication`
- User asks for follow-ups → `get_followup_customers_tool`
- User wants to add customer → `add_customer_tool`
- User wants to update customer → `update_customer_tool`

### Memory Pattern
- Uses `InMemorySaver` for short-term conversation history
- Each Telegram user gets a unique `thread_id` (format: `user_{user_id}`)
- Memory persists during the session but not across restarts

### Response Handling
- Converts markdown bold (`**text**`) to HTML (`<b>text</b>`)
- Escapes HTML special characters to prevent Telegram parsing errors
- Logs all messages and responses for debugging

---

## Recreation Steps

To create a similar agent:

1. **Set up environment**:
   ```bash
   python -m venv venv
   source venv/bin/activate
   pip install langchain langchain-ollama langgraph psycopg2-binary python-dotenv python-telegram-bot
   ```

2. **Create `.env`** with your configuration

3. **Create `customer_tools.py`** with your domain-specific tools

4. **Create `bot.py`** with:
   - Configuration loading
   - System prompt defining capabilities
   - Tool implementations
   - Agent builder function
   - Interface handlers (Telegram, REST, etc.)

5. **Create `Dockerfile`** for containerization

6. **Create `docker-compose.yml`** for orchestration

---

## Extension Ideas

- Add more tools for additional domain operations
- Replace `InMemorySaver` with `PostgresSaver` for persistent memory
- Add file upload handling for document processing
- Implement agent validation layer using `audit_log` table
- Add multi-language support

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "TELEGRAM_BOT_TOKEN not set" | Check `.env` file exists and has valid token |
| "Database connection error" | Verify PostgreSQL credentials and network access |
| "Ollama connection failed" | Check Ollama URL and model availability |
| "Tool not found" | Ensure tool is defined and added to TOOLS list |

---

## Related Files

- `docs/database/agent_first_erp_crm_schema.sql` - Full database schema
- `docs/database/09_customer_functions.sql` - Customer functions
- `docs/database/10_audit_log.sql` - Audit log schema
- `docs/database/agent_schema_reference.md` - Schema reference

---

*Blueprint version: 1.0 | Last updated: 2026-07-18*