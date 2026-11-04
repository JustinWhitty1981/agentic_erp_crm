# Agent First ERP CRM - AI Agent Documentation Guide

Welcome! This guide is designed specifically for AI agents working on the Agent First ERP CRM project. Follow this documentation structure to navigate the codebase effectively.

## Quick Navigation

### 📚 Core Documentation
- **[README.md](README.md)** - Project overview and getting started
- **[architecture.md](architecture.md)** - System architecture and agent roles
- **[QUICKSTART.md](QUICKSTART.md)** - Deployment and setup instructions
- **[PLAN.md](PLAN.md)** - Development roadmap and priorities

### 🤖 Agent-Specific Guides
- **[agents/customer_service/README.md](agents/customer_service/README.md)** - **the deployed agent**: Go backend, tools, environment, endpoints
- **[agents/customer_service/backend_go/](agents/customer_service/backend_go/)** - that backend's source
- **[blueprint/AGENT_SUMMARY.md](blueprint/AGENT_SUMMARY.md)** - Blueprint pattern reference implementation
- **[blueprint/tools/README.md](blueprint/tools/README.md)** - Tool development guidelines
- **[docs/agent_requirements/customer_service/customer_service.md](docs/agent_requirements/customer_service/customer_service.md)** - Customer service agent requirements
- **[docs/agent_requirements/inventory/inventory.md](docs/agent_requirements/inventory/inventory.md)** - Inventory agent requirements
- **[docs/ATTACHMENT_SYSTEM.md](docs/ATTACHMENT_SYSTEM.md)** - Attachment system documentation

### 🏛️ Architecture Decision Records
- **[ARCHITECTURE_DECISION_RECORDS/ADR-001_why_log_every_tool_call.md](ARCHITECTURE_DECISION_RECORDS/ADR-001_why_log_every_tool_call.md)** - Why log every tool call
- **[ARCHITECTURE_DECISION_RECORDS/ADR-002_database_first_architecture.md](ARCHITECTURE_DECISION_RECORDS/ADR-002_database_first_architecture.md)** - Database-first architecture rationale
- **[ARCHITECTURE_DECISION_RECORDS/ADR-003_view_based_tool_design.md](ARCHITECTURE_DECISION_RECORDS/ADR-003_view_based_tool_design.md)** - View-based tool design pattern
- **[ARCHITECTURE_DECISION_RECORDS/ADR-004_agent_first_interface.md](ARCHITECTURE_DECISION_RECORDS/ADR-004_agent_first_interface.md)** - Agent-first interface design
- **[ARCHITECTURE_DECISION_RECORDS/ADR-005_idempotent_agent_operations.md](ARCHITECTURE_DECISION_RECORDS/ADR-005_idempotent_agent_operations.md)** - Idempotent operations for safe retries

### 🗄️ Database Documentation
- **[db/README.md](db/README.md)** - **single source of truth for schema**; which legacy SQL directories are superseded
- **[db/MIGRATIONS.md](db/MIGRATIONS.md)** - finding-to-migration mapping the verification harnesses read
- **[dev/README.md](dev/README.md)** - this development server: container, audit access, TLS, gotchas
- **[docs/database/DATABASE_REVIEW.md](docs/database/DATABASE_REVIEW.md)** - full data-model review driving the remediation
- **[docs/database/agent_schema_reference.md](docs/database/agent_schema_reference.md)** - Database schema reference
- **[docs/database/agent_first_erp_crm_mental_model.md](docs/database/agent_first_erp_crm_mental_model.md)** - Database mental model for agents
- **[docs/database/agent_first_erp_crm_schema.sql](docs/database/agent_first_erp_crm_schema.sql)** - **superseded**: the dump `0001_baseline_canonical_port.sql` was ported from. Read it for the shape the review found; `db/migrations/` is what the database is
- **[docs/INTERACTION_LOGGING.md](docs/INTERACTION_LOGGING.md)** - Agent interaction tracking & debugging
- **[db/migrations/](db/migrations/)** - the schema, in the order it is applied
- **[db/seeds/](db/seeds/)** - demo data, idempotent, never DDL
- **[scripts/db/](scripts/db/)** - `db up`, `verify.sh`, `test-functions.sh`: the harnesses that assert the two above
- **[scripts/docs/check_agent_docs.sh](scripts/docs/check_agent_docs.sh)** - the check behind `code:agent_docs_match_surface`; it fails when a page describes an agent or a catalog that is not there
- **[scripts/database/](scripts/database/)** - **superseded**: the pre-0001 SQL copies, listed file by file in [db/README.md](db/README.md)
- **[blueprint/docs/](blueprint/docs/)** - Agent-friendly SQL documentation

---

## Project Overview

Agent First ERP CRM is a database-first AI agent operating system that enables:
- **Autonomous customer service agents** with full CRM capabilities - deployed, in `agents/customer_service/`
- **Tool-based architecture** where agents compose functions dynamically
- **Verbose agent logging**, with every run's trajectory queryable from the database it wrote
- **Semantic search** using PGVector - *the indexes exist (`0012`) and nothing fills them*: no embedder
  in the current deployment produces the 1536 dimensions the columns declare. Read
  `agents/customer_service/README.md`'s "What is not here" before planning around this one
- **Telegram integration** - *not in the deployed agent*, which serves HTTP and SSE. The reference
  implementation in `blueprint/` and the upstream checkout at `/home/justin/agents/dumb_agent` both
  have working adapters; the transport is a `main.go` change and the loop does not care which is attached

---

## Key Concepts

### Two implementations of one pattern
- **Deployed**: `agents/customer_service/` - a Go backend, React UI, HTTP and SSE, and the trajectory
  writer. Start here to change what this agent does.
- **Reference**: `blueprint/bot.py` (~215 lines) - the same loop in one Python file, with LangChain and
  Telegram. Start here to understand the pattern, or to build a new agent quickly.

The two agree on the rules that matter: a read names a `vw_*` view, a write calls a function, every run
records itself, and the model never chooses an audit column's value.

### Database-First Design
All agent state and knowledge lives in PostgreSQL:
- **Customer data**: Stored in normalized tables
- **Tool functions**: Stored as SQL functions in `pg_catalog`
- **Vector embeddings**: PGVector for semantic search
- **Audit logs**: Complete conversation and action history

### Agent Roles
1. **Chief Agent Officer (CAO)** - Validation and orchestration layer. Not built; the customer service
   agent has the detection half of an escalation and no second agent to route one to
2. **Customer Service Agent** - Handles customer inquiries and support. **Deployed**, in
   `agents/customer_service/`; it is the role `AGENT_ROLE` defaults to
3. **Inventory Agent** - Manages stock and product information. Requirements in
   `docs/agent_requirements/inventory/inventory.md`; the schema side is ready (the inventory views and
   both doors exist), the agent is not
4. **Communication Agent** - Handles multi-channel messaging. Not built

---

## How to Work on This Project

### 1. Understanding the Architecture
Start by reading:
1. [architecture.md](architecture.md) - System overview
2. [docs/database/agent_first_erp_crm_mental_model.md](docs/database/agent_first_erp_crm_mental_model.md) - Database concepts

### 2. Setting Up Development Environment
Follow [QUICKSTART.md](QUICKSTART.md) for Docker-based deployment.

### 3. Understanding Agent Tools
- The deployed surface is `agents/customer_service/backend_go/pkg/crm/tools.go`: eight CRM tools, four reading `vw_*` views and four calling stored functions (ADR-003)
- Both obey one rule the blueprint did not always: **a write calls a database function and never composes its own INSERT.** `code:cs_writes_through_doors` watches that, and its comment says what the grep had to grow to catch it
- Review individual tool implementations in **[blueprint/tools/](blueprint/tools/)**
- Read **[blueprint/tools/README.md](blueprint/tools/README.md)** for tool development guidelines
- Study **[docs/agent_requirements/customer_service/customer_service.md](docs/agent_requirements/customer_service/customer_service.md)** for domain requirements
- Review example tools in `blueprint/tools/`:
  - `customer_lookup.py` - Customer information retrieval
  - `add_customer.py` - Add new customers
  - `update_customer.py` - Update customer information
  - `customer_communications.py` - Communication history
  - `communication_logger.py` - Interaction logging, in the fuller shape of `add_communication.py`
  - `tool_logger.py` - Per-call accumulation for the trajectory. It holds no database code, and the note at its top explains why it used to

### 4. Database Operations
- Schema: [db/migrations/](db/migrations/), applied in filename order by `scripts/db/db up`. Nothing else creates tables - `db/README.md` lists the files that used to try
- The customer functions, the audit log and the interaction log are in `0001` onward; the numbered files under `scripts/database/` are the superseded copies they came from
- Semantic search: `0012` built the hnsw indexes and nothing writes the vectors. See **What is not here** in `agents/customer_service/README.md`
- **Documentation**: [docs/INTERACTION_LOGGING.md](docs/INTERACTION_LOGGING.md) - How to debug agent behavior

---

## Common Tasks

### Adding a New Tool
1. Decide which half owns the rule. If the tool changes persistent state, the decision belongs in a
   `db/migrations/NNNN_*.sql` function, so start there and not in the Go file (ADR-002)
2. Give the migration the next free number. `migrate.sh` rejects a file numbered at or below the highest
   applied, which is why the two planned ones became 0024 and 0025 - see db/MIGRATIONS.md
3. Wire the tool in `agents/customer_service/backend_go/pkg/crm/tools.go`: read a `vw_*` view or call the
   function, send an idempotency key if it writes (ADR-005), and record what it touched with `turn.Source`
4. Write the description for a reader that cannot see the schema: what it answers, what it refuses, and
   which fact only the caller has
5. Add it to the table in `agents/customer_service/README.md`, then run `scripts/docs/check_agent_docs.sh`.
   It fails on a tool in one and not the other, which is what makes step 5 not optional
6. Add a probe to `db/tests/` that fails the day the function stops meaning what the tool says

### Creating a New Agent
1. Start from `agents/customer_service/` for a deployment, or [blueprint/bot.py](blueprint/bot.py) to see
   the whole pattern in one file
2. Define agent-specific tools, in the order above: the function first, then the tool that calls it
3. Keep the trajectory writer and the memory store. An agent that cannot be read back cannot be fixed,
   and an agent whose memory dies with its container has no memory - both are 0023's and 0011's subject
4. Test the agent with your intended use cases, in `db/tests/` for the schema half and `go test ./...`
   for the loop half

### Debugging
1. Check PostgreSQL logs for SQL errors
2. `GET /api/interactions?view=recent` is the agent reading its own trajectory; `docker logs -f
   afpc-customer-service` is the same run while it happens, at `LOG_LEVEL=debug`
3. `audit_log` is who changed what, `human_sessions` and `bot_actions` are the login and the action;
   `vw_audit_coverage` says which tables have a trail and which are exempted, with the reason
4. Use the `vw_*` views to verify data state - they are the same read path the agent uses, which is the
   point: a state the views cannot show is a state the agent cannot see either
5. Query `agent_interactions` for full trajectory analysis, and `vw_tool_calls` to see it one call at a
   time

### Testing
Four things can be wrong independently, and each has its own harness:
1. `./scripts/db/verify.sh` - structural assertions over the catalog (the B-checks), no fixtures
2. `./scripts/db/test-functions.sh` - one probe per finding, run against a copy of the database with
   the residue check around it; this is also where the `code:*` markers report, including
   `code:agent_docs_match_surface`
3. `go test ./...` in `agents/customer_service/backend_go` - the loop, the tool wiring and the
   derivations, against fakes and with no database. See the note on the one failing test in that
   package's README section
4. `pytest blueprint/tests/ -v` - the reference implementation's tests, which need a test database
   (`createdb agent_first_erp_crm_test`) and describe the Python shape rather than the deployed one

And the one that checks the documentation: `scripts/docs/check_agent_docs.sh`, run on its own or
through 2.

---

## File Structure

Two rules about this list. Directories that hold the live system are expanded; the ones the schema
sweep left behind are named once and described rather than walked, because a tree that lists
superseded files at the same depth as current ones is how a reader ends up editing the wrong file.

```
agent_first/
├── README.md, QUICKSTART.md, architecture.md, PLAN.md, AGENTS.md
├── Makefile                        # dev-up, db-verify, db-test, docs-schema
├── ARCHITECTURE_DECISION_RECORDS/  # ADR-001..005, cited by the code that obeys them
│
├── agents/
│   ├── customer_service/           # THE DEPLOYED AGENT
│   │   ├── README.md               # tools, environment, endpoints, what is not here
│   │   ├── Dockerfile, docker-compose.yml
│   │   ├── frontend/               # React UI, pointed at :4550
│   │   └── backend_go/
│   │       ├── cmd/server/main.go  # wiring, auth, endpoints, startup order
│   │       └── pkg/
│   │           ├── agent/          # the loop: prompt, dispatch, trajectory, rehydration
│   │           ├── crm/            # the eight CRM tools and their argument coercion
│   │           ├── db/             # the pool: TLS modes, tenant on connect, row to JSON
│   │           ├── formatters/     # truncation and fallback summaries
│   │           ├── ids/            # UUIDv5 derivations: conversation ids, claim keys
│   │           ├── llm/            # Azure token provider (unused: this runs LLM_PROVIDER=local)
│   │           ├── logging/        # slog + masking, and the agent_interactions writer
│   │           ├── mcp/            # HighByte MCP client, inherited and inert
│   │           ├── memory/         # agent_memories, with the file store as an explicit fallback
│   │           ├── tools/          # the registry, and the non-CRM tools
│   │           └── turn/           # what turn a call is running in; a leaf, and on purpose
│   └── jada/                       # the reference drop: unmodified, unreadable to the build user, not the deployment
│
├── db/                             # THE SCHEMA, and the harness that asserts it
│   ├── README.md                   # single source of truth: which SQL files are superseded
│   ├── MIGRATIONS.md               # finding to migration, the marker table, and the tracked tasks
│   ├── migrations/                 # 0000..0023 applied in filename order; 0024 and 0025 are planned
│   ├── tests/                      # N_N_<finding>.sql, one probe per block, VERDICT lines
│   └── seeds/                      # 01_demo_customers.sql - data, idempotent, never DDL
│
├── dev/                            # THIS SERVER: container, roles, TLS, and what will bite you
│   ├── README.md                   # read before a connection fails for a reason that is not the network
│   ├── docker-compose.yml, tls/    # the volume and the exported CA (dev/tls/afpc-ca.crt)
│
├── scripts/
│   ├── db/                         # db, init.sh, migrate.sh, roles.sql, verify.sh, test-functions.sh, _common.sh
│   ├── docs/                       # check_agent_docs.sh (the doc watchdog), regen_view_columns.py
│   ├── tests/                      # python test helpers
│   └── database/, 08_create_views.sql  # superseded pre-0001 SQL; db/README lists each file
│
├── docs/
│   ├── INTERACTION_LOGGING.md, ATTACHMENT_SYSTEM.md
│   ├── agent_requirements/         # customer_service/, inventory/ - what each agent is specified to do
│   ├── database/                   # the review's companions; agent_first_erp_crm_schema.sql is superseded
│   └── history/                    # MISALIGNMENT_FIXES.md, STABILITY_IMPROVEMENTS.md
│
└── blueprint/                      # THE REFERENCE IMPLEMENTATION: same rules, one Python file
    ├── bot.py                      # ~215 lines: loop, tools, memory, PostgreSQL
    ├── tools/                      # the eight tools bot.py registers, in Python, plus the trajectory helpers
    ├── docs/                       # agent-friendly SQL docs; views.md's lists are checked against the catalog
    ├── tests/                      # pytest; needs a test database
    └── *.sql                       # superseded copies, kept so the fork is legible - see db/README.md
```

The tree was regenerated by hand in this session's documentation sweep; `T4`'s checker covers the
*content* claims (tools, environment keys, views, columns, migrations) rather than the shape of this
list, so a new top-level directory is still something a human adds here.
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
5. **Support** - Follow-ups (`followups`). Tickets were part of the vestigial schema and are
   referenced by nothing in the canonical one - see `db/migrations/0017_interaction_readpath.sql`

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
| `units_of_measure` | Master data: units an item can be counted, weighed or measured in |
| `costing_methods` | Master data: how an item's cost is derived |
| `currencies` | Master data: ISO 4217 codes behind the three currency columns, and how many minor units each has; global, so declared in B19 rather than given tenant policies |
| `currency_rates` | Rate history per currency pair; one open row per pair by partial unique index, gaps and overlaps across closed rows unconstrained; global, and outside 0013's trail because `audit_log.tenant_id` is NOT NULL |
| `idempotency_keys` | ADR-005 request claims: one row per (tenant, operation, key) with the cached answer, the lease, and the retention deadline |
| `audit_log` | Row-level change history: append-only by grant, tamper-evident by a sha256 chain segmented per (tenant, month); one trail row per row-change on every tenant-coded table except itself and `idempotency_keys` |

### Views for Agents
| View | Purpose |
|------|---------|
| `vw_customers` | Customer entity overview |
| `vw_customer_communications_summary` | Customer interactions with context |
| `vw_recent_communications` | Last 7 days of communications |
| `vw_pending_followups` | Tasks requiring action |
| `vw_entity_communication_stats` | Customer health metrics |
| `vw_primary_contact_communications` | Primary contact interactions |
| `vw_communication_thread` | Communication threading hierarchy |
| `vw_agent_activity_summary` | Agent activity summary |
| `vw_entity_contact_details` | Complete entity and contact details — **not in the schema**: defined only in the superseded `blueprint/08_create_views.sql` (T4) |
| `vw_communication_timeline` | Chronological communication view — **not in the schema**: same superseded file (T4) |
| `vw_recent_interactions` | Every interaction the caller's row security reaches — order and limit belong to the caller, because a `LIMIT` inside a view runs before your filter |
| `vw_failed_interactions` | Error analysis — which **runs** failed, never which tool |
| `vw_tool_calls` | One row per tool invocation, derived by position from `agent_interactions` |
| `vw_tool_performance` | Tool usage statistics — calls counted per call, duration and errors per run |
| `vw_index_redundancy` | Indexes that are identical to, or a leading prefix of, another index |
| `vw_domain_vocabulary` | What every status/type/code column accepts, how it is enforced, and why — `char(3)` code columns included since 0018, and the code tables it lists values for are derived from the catalog rather than named |
| `vw_rls_status` | What row-level security actually does per table: forced or not, which roles, the read and write predicates verbatim, and a verdict |
| `vw_timestamp_status` | Whether each table's `updated_at` can be trusted: is it maintained, on which commands, is it nullable, and which functions rewrite the table anyway |
| `vw_idempotency_status` | Which functions change persistent state and whether a retry of them is guarded (ADR-005 pattern) or UNGUARDED |
| `vw_audit_coverage` | Which tenant-coded tables have a row trail, which are exempted, and the reason each decision was made |
| `vw_inventory_valuation` | Inventory value by warehouse/category, **per currency** after 0018 — nothing converts, so a warehouse holding a USD item and a JPY item reports two rows, not one sum |
| `vw_currency_rates` | The rate in force per currency pair, and the difference between *expired* and *never quoted* — `in_force`, `rows_for_pair`, `as_of` |
| `vw_item_availability` | Stock levels across warehouses |
| `vw_item_movement_summary` | 30-day item movement patterns. `total_inbound`/`total_outbound` exclude `RESERVATION` rows — a commitment makes stock unavailable, it moves nothing — while `net_quantity` still counts them |
| `vw_low_stock_alerts` | Items below reorder point |

See [blueprint/docs/views.md](blueprint/docs/views.md) for complete view reference.

### Database Naming Conventions
- **SQL Tables**: snake_case (e.g., `customers`, `communications`)
- **SQL Views**: MUST use `vw_` prefix (e.g., `vw_customers`, `vw_customer_communications_summary`)
- **SQL Columns**: snake_case (e.g., `created_at`, `entity_id`)
- **SQL Functions**: snake_case with verb prefix (e.g., `add_customer`, `get_inventory`)
- **Python Variables**: snake_case (e.g., `customer_id`)
- **Python Classes**: PascalCase (e.g., `CustomerServiceAgent`)

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
- **SQL Views**: MUST use `vw_` prefix (e.g., `vw_customers`, `vw_pending_followups`)
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

- Review [docs/history/MISALIGNMENT_FIXES.md](docs/history/MISALIGNMENT_FIXES.md) for known issues
- Check [docs/history/STABILITY_IMPROVEMENTS.md](docs/history/STABILITY_IMPROVEMENTS.md) for best practices
- Refer to [PLAN.md](PLAN.md) for current priorities and roadmap

---

**Note**: This documentation is designed for AI agents. Human developers should also refer to these guides for consistency.