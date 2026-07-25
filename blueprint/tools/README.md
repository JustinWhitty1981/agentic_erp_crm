# Tools Library

This folder contains individual tool modules for the Agent First ERP CRM customer service agent. Each tool is a separate file, making them reusable and discoverable across different agents.

---

## Available Tools

| Tool File | Tool Name | Purpose |
|-----------|-----------|---------|
| `customer_lookup.py` | `get_customer_info` | Look up customer information by name |
| `customer_communications.py` | `get_customer_communications` | Get customer's communication history |
| `entity_stats.py` | `get_entity_stats` | Get communication statistics for an entity |
| `add_communication.py` | `add_communication` | Log a new customer communication |
| `current_time.py` | `current_time` | Return current date/time |
| `add_customer.py` | `add_customer_tool` | Add new customer (individual or business) |
| `update_customer.py` | `update_customer_tool` | Update existing customer information |
| `followup_customers.py` | `get_followup_customers_tool` | Get list of customers needing follow-up |
| `communication_logger.py` | `log_communication`, `log_call`, `log_email`, `log_meeting` | Extended communication logging utilities |

---

## How to Use These Tools

### 1. Import Individual Tools

```python
from tools.customer_lookup import get_customer_info
from tools.customer_communications import get_customer_communications
from tools.entity_stats import get_entity_stats
from tools.add_communication import add_communication
from tools.current_time import current_time
from tools.add_customer import add_customer_tool
from tools.update_customer import update_customer_tool
from tools.followup_customers import get_followup_customers_tool
```

### 2. Register with LangChain

```python
from langchain_core.tools import tool

TOOLS = [
    get_customer_info,
    get_customer_communications,
    get_entity_stats,
    current_time,
    add_communication,
    add_customer_tool,
    update_customer_tool,
    get_followup_customers_tool,
]
```

### 3. Use in Agent

```python
from langchain.agents import create_agent
from langchain_ollama import ChatOllama

model = ChatOllama(model="ornith:35b", base_url="http://localhost:11434")
agent = create_agent(
    model=model,
    tools=TOOLS,
    system_prompt=SYSTEM_PROMPT,
)
```

---

## Tool Design Patterns

### Pattern 1: Database Query Tool
```python
@tool
def get_data_tool(query_params: str) -> str:
    """Query the database and return results."""
    conn = get_db_connection()
    try:
        with conn.cursor() as cur:
            cur.execute(query, query_params)
            results = cur.fetchall()
            return format_results(results)
    finally:
        conn.close()
```

### Pattern 2: CRUD Operation Tool
```python
@tool
def create_record_tool(data: dict) -> str:
    """Create a new record with validation."""
    # Validate input
    if not validate_input(data):
        return "Validation failed"
    
    # Execute operation
    result = execute_create(data)
    return f"Created record with ID: {result.id}"
```

### Pattern 3: Business Logic Tool
```python
@tool
def process_request_tool(request: str) -> str:
    """Execute multi-step business logic."""
    # Parse request
    # Execute multi-step process
    # Return formatted result
    return result
```

---

## Best Practices

1. **Always validate input** before processing
2. **Handle errors gracefully** with clear error messages
3. **Use transactions** for multi-step operations
4. **Log all actions** for audit trails
5. **Document parameters** clearly in docstrings
6. **Return consistent formats** for easy parsing
7. **Use environment variables** for configuration (never hardcode credentials)

---

## Adding New Tools

1. Create a new file in this folder with naming convention: `<domain>_tools.py` or `<action>_<entity>.py`
2. Use the `@tool` decorator from LangChain
3. Include comprehensive docstrings describing:
   - Purpose and when to use the tool
   - All parameters with types and descriptions
   - Return value format
4. Add database connection using environment variables
5. Test with sample data
6. Update this README

---

## Related Documentation

- `../AGENT_SUMMARY.md` - Blueprint pattern overview
- `../../docs/database/agent_schema_reference.md` - Database schema reference
- `../../docs/INTERACTION_LOGGING.md` - Interaction logging documentation