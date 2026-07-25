# Agent First ERP CRM - AI Agent Documentation Guide

Welcome! This guide is designed specifically for AI agents working on the Agent First ERP CRM project. Follow this documentation structure to navigate the codebase effectively.

## Quick Navigation

### 📚 Core Documentation
- **[README.md](README.md)** - Project overview and getting started
- **[ARCHITECTURE.md](ARCHITECTURE.md)** - System architecture and agent roles
- **[QUICKSTART.md](QUICKSTART.md)** - Deployment and setup instructions
- **[PLAN.md](PLAN.md)** - Development roadmap and priorities

### 🤖 Agent-Specific Guides
- **[blueprint/AGENT_SUMMARY.md](blueprint/AGENT_SUMMARY.md)** - Blueprint pattern reference implementation
- **[blueprint/tools/README.md](blueprint/tools/README.md)** - Tool development guidelines
- **[docs/agent_requirements/customer_service/customer_service.md](docs/agent_requirements/customer_service/customer_service.md)** - Customer service agent requirements
- **[docs/agent_requirements/inventory/inventory.md](docs/agent_requirements/inventory/inventory.md)** - Inventory agent requirements
- **[docs/attachments/ATTACHMENT_SYSTEM.md](docs/attachments/ATTACHMENT_SYSTEM.md)** - Attachment system documentation

### 🗄️ Database Documentation
- **[docs/database/agent_schema_reference.md](docs/database/agent_schema_reference.md)** - Database schema reference
- **[docs/database/agent_first_erp_crm_mental_model.md](docs/database/agent_first_erp_crm_mental_model.md)** - Database mental model for agents
- **[docs/database/agent_first_erp_crm_schema.sql](docs/database/agent_first_erp_crm_schema.sql)** - Complete schema definition
- **[docs/INTERACTION_LOGGING.md](docs/INTERACTION_LOGGING.md)** - Agent interaction tracking & debugging
- **[scripts/database/](scripts/database/)** - SQL migration scripts
- **[blueprint/docs/](blueprint/docs/)** - Agent-friendly SQL documentation

---

## Project Overview

Agent First ERP CRM is a database-first AI agent operating system that enables:
- **Autonomous customer service agents** with full CRM capabilities
- **Semantic search** using PGVector for natural language queries
- **Tool-based architecture** where agents compose functions dynamically
- **Telegram integration** for natural language interfaces

---

## Key Concepts

### Blueprint Pattern
The reference implementation follows a single-file LangChain agent pattern:
- **Location**: `blueprint/bot.py` (~215 lines)
- **Features**: Tool calling, conversation memory, PostgreSQL integration
- **Purpose**: Starting point for new agent development

### Database-First Design
All agent state and knowledge lives in PostgreSQL:
- **Customer data**: Stored in normalized tables
- **Tool functions**: Stored as SQL functions in `pg_catalog`
- **Vector embeddings**: PGVector for semantic search
- **Audit logs**: Complete conversation and action history

### Agent Roles
1. **Chief Agent Officer (CAO)** - Validation and orchestration layer
2. **Customer Service Agent** - Handles customer inquiries and support
3. **Inventory Agent** - Manages stock and product information
4. **Communication Agent** - Handles multi-channel messaging

---

## How to Work on This Project

### 1. Understanding the Architecture
Start by reading:
1. [ARCHITECTURE.md](ARCHITECTURE.md) - System overview
2. [docs/database/agent_first_erp_crm_mental_model.md](docs/database/agent_first_erp_crm_mental_model.md) - Database concepts

### 2. Setting Up Development Environment
Follow [QUICKSTART.md](QUICKSTART.md) for Docker-based deployment.

### 3. Understanding Agent Tools
- Review individual tool implementations in **[blueprint/tools/](blueprint/tools/)**
- Read **[blueprint/tools/README.md](blueprint/tools/README.md)** for tool development guidelines
- Study **[docs/agent_requirements/customer_service/customer_service.md](docs/agent_requirements/customer_service/customer_service.md)** for domain requirements
- Review example tools in `blueprint/tools/`:
  - `customer_lookup.py` - Customer information retrieval
  - `add_customer.py` - Add new customers
  - `update_customer.py` - Update customer information
  - `customer_communications.py` - Communication history
  - `communication_logger.py` - Interaction logging

### 4. Database Operations
- Schema: [docs/database/agent_first_erp_crm_schema.sql](docs/database/agent_first_erp_crm_schema.sql)
- Customer functions: [scripts/database/09_customer_functions.sql](scripts/database/09_customer_functions.sql)
- Audit log: [scripts/database/10_audit_log.sql](scripts/database/10_audit_log.sql)
- **Interaction logging**: [scripts/database/11_interaction_logging.sql](scripts/database/11_interaction_logging.sql)
- Views: [scripts/database/08_create_views.sql](scripts/database/08_create_views.sql)
- **Documentation**: [docs/INTERACTION_LOGGING.md](docs/INTERACTION_LOGGING.md) - How to debug agent behavior

---

## Common Tasks

### Adding a New Tool
1. Review existing tools in `blueprint/tools/` for patterns
2. Follow the pattern in individual tool files (e.g., [add_customer.py](blueprint/tools/add_customer.py))
3. Add SQL function definition to appropriate migration file in `scripts/database/`
4. Update tool registry in the agent

### Creating a New Agent
1. Start from [blueprint/bot.py](blueprint/bot.py) as reference
2. Define agent-specific tools
3. Configure conversation memory and vector store
4. Test the agent with your intended use cases

### Debugging
1. Check PostgreSQL logs for SQL errors
2. Review Telegram bot logs for API issues
3. Check audit log for conversation history
4. Use database views to verify data state
5. Query `agent_interactions` table for full trajectory analysis

### Testing
1. Run tests in `blueprint/tests/` directory
2. See [blueprint/tests/README.md](blueprint/tests/README.md) for test documentation
3. Test database setup: `createdb agent_first_erp_crm_test`
4. Run with pytest: `pytest blueprint/tests/ -v`

---

## File Structure

```
agent_first_erp_crm/
├── README.md                 # Project overview
├── ARCHITECTURE.md           # System architecture
├── QUICKSTART.md            # Setup guide
├── PLAN.md                  # Development roadmap
├── AGENTS.md                # This file - agent guide
├── MIGRATION_SUMMARY.md     # Migration history
├── agents/                  # Agent implementations
├── blueprint/               # Reference implementation
│   ├── bot.py              # Main agent entry point
│   ├── QUICKSTART.md       # Blueprint-specific setup
│   ├── README.md           # Blueprint documentation
│   ├── AGENT_SUMMARY.md    # Blueprint pattern reference
│   ├── Dockerfile          # Container configuration
│   ├── docker-compose.yml  # Docker orchestration
│   ├── requirements.txt    # Python dependencies
│   └── tools/                    # Tool implementations
│       ├── README.md                    # Tool development guidelines
│       ├── add_communication.py         # Log new interactions
│       ├── add_customer.py              # Add customers
│       ├── current_time.py              # Get current time
│       ├── customer_communications.py   # Customer history
│       ├── customer_lookup.py           # Customer lookup
│       ├── entity_stats.py              # Entity statistics
│       ├── followup_customers.py        # Follow-up lists
│       ├── update_customer.py           # Update customers
│       ├── communication_logger.py      # Interaction logging
│       └── tool_logger.py               # Tool logging
├── blueprint/docs/          # Agent-friendly SQL documentation
│   ├── README.md
│   ├── schema_reference.md
│   ├── customer_functions.md
│   ├── audit_log.md
│   ├── interaction_logging.md
│   ├── sample_data.md
│   └── views.md
├── docs/                    # Documentation
│   ├── attachments/         # Attachment system docs
│   │   └── ATTACHMENT_SYSTEM.md
│   ├── agent_requirements/  # Domain requirements
│   │   ├── customer_service/
│   │   │   └── customer_service.md
│   │   └── inventory/
│   │       └── inventory.md
│   └── database/            # Database documentation
│       ├── agent_schema_reference.md
│       ├── agent_first_erp_crm_mental_model.md
│       ├── agent_first_erp_crm_schema.sql
│       ├── 08_create_views.sql
│       ├── 09_customer_functions.sql
│       └── 10_audit_log.sql
├── memory/                  # Memory components
├── scripts/                 # SQL scripts
│   └── database/            # Migration scripts
│       ├── agent_first_erp_crm_schema.sql
│       ├── 08_create_views.sql
│       ├── 09_customer_functions.sql
│       ├── 10_audit_log.sql
│       └── setup_sample_data.sql
├── tools/                   # Utility tools
│   └── interaction_logger.py
└── .tmp/                    # Temporary files (gitignored)
```

---

## Best Practices

1. **Database First**: Always consider how changes affect the database schema
2. **Tool Composition**: Design tools to be composable and reusable
3. **Semantic Search**: Leverage PGVector for natural language capabilities
4. **Audit Everything**: Use the audit log system for all agent actions
5. **Documentation**: Update relevant docs when making changes
6. **Security**: Never hardcode credentials; use environment variables
7. **Testing**: Write tests for all new tools and functions
8. **Naming Conventions**: Follow established patterns (snake_case for SQL, camelCase for Python)

---

## Security Guidelines

### Environment Variables
All sensitive data must be stored in environment variables:
- Database credentials
- API keys
- Telegram bot tokens
- LLM API keys

See `.env.example` for required variables.

### Data Protection
- Never log sensitive customer data (PII)
- Mask sensitive fields in logs
- Use encrypted connections to PostgreSQL
- Implement row-level security where appropriate

### Audit Trail
- Log all agent actions via `bot_actions` table
- Track human sessions in `human_sessions` table
- Capture full agent trajectory in `agent_interactions` table

---

## Database Architecture

### Core Domains
1. **Party Management** - Entities, contacts, relationships, addresses
2. **Communications** - All interactions with threading and sentiment
3. **Audit Logging** - Human sessions, bot actions, interaction tracking
4. **Inventory** - Products, warehouses, stock levels, movements
5. **Support** - Tickets and follow-ups

### Key Tables
| Table | Purpose |
|-------|---------|
| `entities` | Business organizations and customers |
| `contacts` | Individual humans |
| `entity_relationships` | Links contacts to entities |
| `communications` | All interactions |
| `human_sessions` | Human agent login sessions |
| `bot_actions` | AI agent actions |
| `agent_interactions` | Complete trajectory logging |
| `audit_summary` | Daily aggregation |

### Views for Agents
| View | Purpose |
|------|---------|
| `customer_communications_summary` | Customer interactions with context |
| `pending_followups` | Tasks requiring action |
| `entity_communication_stats` | Customer health metrics |
| `v_recent_interactions` | Last 100 agent interactions |
| `v_failed_interactions` | Error analysis |
| `v_tool_performance` | Tool usage statistics |

See [blueprint/docs/views.md](blueprint/docs/views.md) for complete view reference.

---

## pgschema Tool

The project uses pgschema for database schema visualization and documentation:

```bash
# Install pgschema
pip install pgschema

# Generate schema documentation
pgschema dump -h localhost -U postgres -d agent_first_erp_crm -o docs/schema/

# Generate schema graph
pgschema graph -h localhost -U postgres -d agent_first_erp_crm > schema_graph.dot
```

The `_schema_graph` table contains a knowledge graph of the entire schema for AI agent understanding.

---

## Agent Validation

### Validation Layer (CAO)
The Chief Agent Officer (CAO) provides:
- Input validation before agent execution
- Output validation after agent execution
- Safety checks for destructive operations
- Rate limiting and quota enforcement

### Validation Rules
1. **Input Validation**
   - Check required parameters
   - Validate data types
   - Sanitize user input
   - Check for injection attacks

2. **Output Validation**
   - Verify response format
   - Check for sensitive data leakage
   - Validate action results
   - Log validation status

---

## Development Guidelines

### Naming Conventions
- **SQL Tables**: snake_case (e.g., `customer_communications`)
- **SQL Columns**: snake_case (e.g., `created_at`)
- **Python Variables**: snake_case (e.g., `customer_id`)
- **Python Classes**: PascalCase (e.g., `CustomerServiceAgent`)
- **Functions**: snake_case (e.g., `get_customer_by_id`)

### Code Style
- Follow PEP 8 for Python code
- Use type hints for function signatures
- Write docstrings for all public functions
- Keep functions focused and single-purpose

### Git Workflow
1. Create feature branch from `main`
2. Make changes with commit messages
3. Run tests before committing
4. Submit pull request for review

---

## Future Directions

### Model Context Protocol (MCP)
Integration with MCP for standardized agent communication:
- Standardized tool definitions
- Inter-agent communication protocols
- Tool discovery and registration

### Validation Agent
Dedicated validation agent for:
- Pre-execution safety checks
- Post-execution verification
- Anomaly detection
- Compliance enforcement

### Enhanced Analytics
- Real-time dashboard for agent metrics
- Automated alerting for failures
- Performance optimization recommendations
- Usage pattern analysis

---

## Getting Help

- Review [docs/MISALIGNMENT_FIXES.md](docs/MISALIGNMENT_FIXES.md) for known issues
- Check [docs/STABILITY_IMPROVEMENTS.md](docs/STABILITY_IMPROVEMENTS.md) for best practices
- Refer to [PLAN.md](PLAN.md) for current priorities and roadmap

---

**Note**: This documentation is designed for AI agents. Human developers should also refer to these guides for consistency.