# Customer Service Agent Requirements

## Core Identity
- **Role:** First-line support for customer inquiries.
- **Interface:** Telegram (Natural Language).
- **Database Access:** Read/Write to `customers`, `communications`, `entity_communication_stats`.
- **Implementation:** Follows the blueprint pattern (`blueprint/bot.py`).

## Functional Requirements
1.  **Retrieve Customer Info:**
    - Fetch: Name, Address, Phone, Email, Status, and Recent Notes.
    - Use `get_customer_info` tool with fuzzy name matching.
    - Support semantic search via PGVector: "Find customers who complained about shipping last week."
2.  **Update Customer Info:**
    - Update: Name, Address, Phone, Email, Status, and Recent Notes.
    - Use 'update_customer_info' tool with deterministic stored procedures or functions
3.  **Communication History:**
    - View recent interactions with `get_customer_communications`.
    - Access up to 5 most recent communications per customer.
    - Display: Date, Direction (inbound/outbound), Type, Summary.
4.  **Entity Statistics:**
    - Get communication metrics via `get_entity_stats`.
    - Shows: Total communications, resolved count, pending count.
5.  **Log New Interactions:**
    - Use `add_communication` tool after real-world interactions.
    - Capture: Customer name, direction, communication type, summary, agent name (optional).
    - Automatically link to customer record via entity_id.
    - Automatically ask to log the customer interaction when a user mentions they've received an email or a customer is on the phone.
6.  **Get Follow-up Customers:**
    - Use `get_followup_customers` tool to identify customers needing contact.
    - Returns customers with no recent communications, follow-up status, or unresolved issues.
    - Default threshold: 7 days since last contact.
    - Formats results in Telegram-friendly HTML (bold tags, bullet points).
7.  **Escalation:**
    - Detect complex or angry sentiment and escalate to the CAO with a summary.
    - Format escalation: "Customer X is upset about Order Y. Summary: [Details]. Action Required: [Suggestion]."
8.  **Agent logging:**
    - Log the prompt, tool calls, and the agents response for troubleshooting agent behaviors using tool 'tool_logger.py'. 

## Non-Functional Requirements
- **Response Time:** < 30 seconds for typical queries (ornith:35b).
- **Accuracy:** 100% data accuracy (validated by CAO).
- **Safety:** No destructive actions (DELETE, DROP) allowed.
- **Context Awareness:** Remembers previous interactions within the same Telegram session (InMemorySaver).

## Validation Rules
- Any update to `customers` or `communications` must be reported to the CAO.
- CAO validates by re-querying the database to confirm the change.
- Failed validations trigger an immediate alert to the human owner.

## Blueprint Implementation Details

The customer service agent is implemented in `blueprint/bot.py` with:

### Tools
| Tool | Purpose | Database Query |
|------|---------|----------------|
| `get_customer_info` | Look up customer by name | `SELECT name, email, phone, address, status FROM agent_first_erp_crm.customers WHERE name ILIKE %s` |
| `get_customer_communications` | Get recent interactions | `SELECT started_at, entity_name, communication_type, direction, summary FROM agent_first_erp_crm.recent_communications` |
| `get_entity_stats` | View communication metrics | `SELECT entity_name, entity_type, status, total_communications, resolved_count, pending_count FROM agent_first_erp_crm.entity_communication_stats` |
| `add_communication` | Log new interaction | `INSERT INTO agent_first_erp_crm.communications (entity_id, communication_type, direction, summary, started_at)` |
| `current_time` | Get current date/time | No database query |
| `get_followup_customers` | Get customers needing contact | `SELECT * FROM get_followup_customers(days_threshold)` |

### System Prompt Highlights
- Proactively offers to log communications when user mentions real-world interactions.
- Uses tools only when needed (doesn't force tool calls).
- Explains errors plainly if tools fail.
- Keeps responses friendly and concise.

### Deployment
- **Run:** `python bot.py` in `/home/justin/.openclaw/workspace/customer-service-bot` (background process)
- **Model:** `ornith:35b` via Ollama at `http://{your-ollama-host}:11434`
- **Database:** PostgreSQL at `{your-postgres-host}:5432` (database: `agent_first_erp_crm`, schema: `agent_first_erp_crm`)
- **Telegram:** Bot token from `.env` file
- **Note:** Not Docker-based. Runs as a native Python process.

## Testing Scenarios

1. **Happy Path:** User asks for customer info → Agent retrieves and displays → Success
2. **Communication Logging:** User mentions speaking to customer → Agent offers to log → User provides summary → Agent logs successfully
3. **Missing Customer:** User asks for non-existent customer → Agent reports "not found" gracefully
4. **Error Handling:** Database connection fails → Agent explains error without exposing internals

---

*This agent follows the blueprint pattern. Future agents should replicate this structure.*
