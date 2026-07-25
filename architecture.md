# Agent Swarm Architecture

## 📚 Documentation Navigation

For AI agents working on this project, see:
- **[AGENTS.md](AGENTS.md)** - Complete navigation guide for AI agents
- **[README.md](README.md)** - Project overview
- **[blueprint/AGENT_SUMMARY.md](blueprint/AGENT_SUMMARY.md)** - Blueprint pattern details
- **[docs/database/](docs/database/)** - Database documentation

---

## 1. Overview
A decentralized swarm of specialized AI agents, each following a **simple, proven pattern** from the blueprint implementation. All agents share a **PostgreSQL database with PGVector** as their collective memory and state.

**Core Philosophy:** The conversation **is** the interface. No UI, no forms, no dashboards. Just natural language queries and actions.

**Design Principle:** Start simple. Each agent is a single-file Python application using LangChain v1, direct PostgreSQL access, and Docker isolation. Complexity comes from orchestration, not individual agent complexity.

## 2. Reference Implementation (Blueprint)

The `blueprint/` directory contains the **working reference** - a customer service agent that demonstrates the pattern:

### Key Features
- **Single File:** `bot.py` contains all logic (tools, agent, Telegram handler)
- **LangChain v1:** Automatic tool calling and conversation memory
- **Direct SQL:** Parameterized queries via psycopg2
- **Docker Isolation:** Clean dependencies, no conflicts
- **Telegram Interface:** Direct bot integration

### Agent Structure Pattern
```python
# 1. Configuration
DB_CONFIG = {...}
SYSTEM_PROMPT = "..."

# 2. Tools (each is a @tool-decorated function)
@tool
def get_customer_info(name: str) -> str:
    """Look up customer by name."""
    # Direct SQL query with parameterization

# 3. Agent Builder
def build_agent():
    model = ChatOllama(model="ornith:35b", ...)
    return create_agent(model, tools=TOOLS, system_prompt=SYSTEM_PROMPT)

# 4. Telegram Handler
async def handle_message(update, context):
    result = agent.invoke({"messages": [{"role": "user", "content": text}]})
    await update.message.reply_text(result["messages"][-1].content)

# 5. Main Entry Point
def main():
    application = Application.builder().token(TELEGRAM_TOKEN).build()
    application.add_handler(conv_handler)
    application.run_polling()
```

## 3. Roles & Responsibilities

### 3.1 Chief Agent Officer (CAO) – Jarvis
- **Gatekeeper:** Manages agent identities, permissions, and lifecycle.
- **Orchestrator:** Routes tasks to appropriate agents, monitors progress, and intervenes when needed.
- **Quality Controller:** **Validates every agent action** against the database state before confirming completion.
- **Human Interface:** Primary point of contact for the business owner (Justin) via Telegram.

### 3.2 Specialized Agents
Each agent follows the blueprint pattern with:
- A unique **agent identity** (name, role, Telegram bot token).
- **Direct database access** (read/write) via psycopg2.
- A defined **tool set** (functions for specific data operations).
- **Conversation memory** via LangChain's InMemorySaver.

#### Current Agent: Customer Service (Blueprint)
- **Location:** `blueprint/bot.py`
- **Responsibilities:** Handle tickets, order inquiries, basic support, log communications.
- **Database Access:** Read/Write to `customers`, `orders`, `communications` views.
- **Tools:**
  - `get_customer_info` - Look up customer details
  - `get_customer_communications` - Retrieve recent interactions
  - `get_entity_stats` - View communication statistics
  - `add_communication` - Log new interactions
  - `current_time` - Get current date/time

**See [blueprint/customer_tools.py](blueprint/customer_tools.py) for tool implementation examples.**

#### Future Agents (Following Blueprint Pattern)
- **HR Onboarding:** Manage employee records, contracts, onboarding tasks.
- **Accounting:** Generate invoices, track payments, reconcile accounts.
- **Inventory:** Monitor stock levels, reorder supplies, manage suppliers.
- **Sales:** Process orders, manage leads, track conversions.

## 4. Database Schema (Shared Memory)

The core is a **PostgreSQL database with PGVector** extension.

### 4.1 Core Tables
See **[docs/database/agent_schema_reference.md](docs/database/agent_schema_reference.md)** for the complete enterprise schema design.

**Current Implementation (Customer Service):**
- `agent_swarm.customers` - Entity/customer information
- `agent_swarm.communications` - Interaction history
- `agent_swarm.recent_communications` - View for recent interactions
- `agent_swarm.entity_communication_stats` - Aggregated statistics

**Planned Tables:**
- `orders` - Order details and status
- `products` - Product catalog with inventory
- `tickets` - Support ticket tracking
- `agents` - Agent registry and permissions
- `audit_log` - Immutable action log for validation

### 4.2 Why PGVector?
- **Semantic Search:** "Find customers who complained about shipping" (no exact keyword matching).
- **Contextual Memory:** Agents remember past interactions without rigid schema constraints.
- **Hybrid Queries:** Combine structured SQL (`WHERE status = 'open'`) with unstructured semantic search.

## 5. Communication Flow

### 5.1 Human → Agent
- Business owner or customer sends a message via Telegram.
- Message is routed to the appropriate agent (or CAO for routing).
- Agent queries the database, generates a response, and updates the state.

### 5.2 Agent → CAO
- Agents report actions (e.g., "Updated customer note") to the CAO.
- CAO validates the action by querying the database directly.
- Result: **Pass** (confirmed) or **Fail** (alert human).

### 5.3 CAO → Agent
- CAO assigns tasks, provides context, or intervenes in complex situations.
- Agents execute and report back.

## 6. Model Strategy

### 6.1 Agent Inference (Runtime)
- **Primary Model:** `ornith:35b` via Ollama (`http://{your-ollama-host}:11434`).
- **Why:** Fast response times (10-30s), sufficient intelligence for tool calling and SQL generation.
- **Fallback:** `qwen3.5:9b` for simple tasks if needed.

### 6.2 Complex Reasoning (Architecture/Decisions)
- **Model:** `qwen3.5:122b` via vLLM (`http://{your-llm-host}:8001`).
- **Use Cases:** Schema design, agent architecture, validation logic, complex debugging.
- **Not Used For:** Routine agent inference (too slow for real-time chat).

## 7. Security & Compliance
- **Least Privilege:** Agents only have permissions they need (row-level security or scoped database users).
- **Human-in-the-Loop:** Critical actions require CAO approval.
- **Audit Trail:** All agent actions are logged in `audit_log` with validation status.
- **SQL Safety:** All queries are parameterized to prevent injection attacks.

## 8. Scalability
- **Modular Design:** New agents can be added without disrupting existing ones.
- **Context Management:** Each agent has its own session/memory, avoiding context bloat.
- **CAO Coordination:** Jarvis manages the swarm, ensuring agents don't conflict or duplicate work.
- **Database Performance:** PGVector indexes ensure fast semantic search even with millions of records.

## 9. Development Workflow

### 9.1 Adding a New Agent
1. **Review the Blueprint:** Study [blueprint/bot.py](blueprint/bot.py) and [blueprint/AGENT_SUMMARY.md](blueprint/AGENT_SUMMARY.md).
2. **Copy the Blueprint:** `cp -r blueprint new-agent-name/`
3. **Update Tools:** Modify tool functions for the new domain. See [blueprint/tools/](blueprint/tools/) for examples.
4. **Update Prompt:** Adjust system prompt for the agent's role.
5. **Configure Docker:** Update `.env` and `docker-compose.yml`.
6. **Test:** Run locally, then deploy to Docker.
7. **Register with CAO:** Add agent identity to `agents` table.

### 9.2 Testing
- **Unit Tests:** Test individual tools with mock data.
- **Integration Tests:** Test full conversation flows.
- **Validation Tests:** Verify CAO validation catches incorrect claims.

---

*This architecture emphasizes simplicity and maintainability. Each agent is a standalone, testable unit that follows the blueprint pattern.*
*Complexity comes from orchestration and validation, not from individual agent complexity.*
