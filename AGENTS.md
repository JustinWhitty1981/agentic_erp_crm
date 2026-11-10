# Agent First ERP CRM - AI Agent Documentation Guide

Welcome! This guide is designed specifically for AI agents working on the Agent First ERP CRM project. Follow this documentation structure to navigate the codebase effectively.

## Quick Navigation

### 📚 Core Documentation
- **[README.md](README.md)** - Project overview and getting started
- **[architecture.md](architecture.md)** - System architecture and agent roles
- **[QUICKSTART.md](QUICKSTART.md)** - Deployment and setup instructions
- **[PLAN.md](PLAN.md)** - Development roadmap and priorities
- **[archive/README.md](archive/README.md)** - the frozen lineage: what `archive/blueprint/` is, and why nothing is added to it

### 🤖 Agent-Specific Guides
- **[agents/customer_service/README.md](agents/customer_service/README.md)** - **the first deployed agent** (the CRM half): Go backend, tools, environment, endpoints
- **[agents/inventory/README.md](agents/inventory/README.md)** - **the second deployed agent**: same loop, stock tools, and the in-container check timer
- **[agents/sales/README.md](agents/sales/README.md)** - **the third deployed agent**: same loop, the orders surface (5 reads, 7 doors), and the keeper for claim retention and the reconciliation
- **[agents/customer_service/backend_go/](agents/customer_service/backend_go/)** - that backend's source, and the one the other two are forked from
- **[archive/blueprint/AGENT_SUMMARY.md](archive/blueprint/AGENT_SUMMARY.md)** - the pattern's first statement, in Python - lineage, not a runtime (ADR-006)
- **[archive/blueprint/tools/README.md](archive/blueprint/tools/README.md)** - Tool development guidelines
- **[docs/agent_requirements/customer_service/customer_service.md](docs/agent_requirements/customer_service/customer_service.md)** - Customer service agent requirements
- **[docs/agent_requirements/inventory/inventory.md](docs/agent_requirements/inventory/inventory.md)** - Inventory agent requirements
- **[docs/agent_requirements/sales/sales.md](docs/agent_requirements/sales/sales.md)** - Sales & procurement agent requirements, corrected in place on 2026-11-07 to what the doors actually answer
- **[docs/agent_requirements/agent_test_plan.md](docs/agent_requirements/agent_test_plan.md)** - Acceptance plan for every tool of all three deployed agents (37 cases), and its executable form `scripts/agents/tool_testplan.sh`
- **[docs/ATTACHMENT_SYSTEM.md](docs/ATTACHMENT_SYSTEM.md)** - Attachment system documentation

### 🏛️ Architecture Decision Records
- **[ARCHITECTURE_DECISION_RECORDS/ADR-001_why_log_every_tool_call.md](ARCHITECTURE_DECISION_RECORDS/ADR-001_why_log_every_tool_call.md)** - Why log every tool call
- **[ARCHITECTURE_DECISION_RECORDS/ADR-002_database_first_architecture.md](ARCHITECTURE_DECISION_RECORDS/ADR-002_database_first_architecture.md)** - Database-first architecture rationale
- **[ARCHITECTURE_DECISION_RECORDS/ADR-003_view_based_tool_design.md](ARCHITECTURE_DECISION_RECORDS/ADR-003_view_based_tool_design.md)** - View-based tool design pattern
- **[ARCHITECTURE_DECISION_RECORDS/ADR-004_agent_first_interface.md](ARCHITECTURE_DECISION_RECORDS/ADR-004_agent_first_interface.md)** - Agent-first interface design
- **[ARCHITECTURE_DECISION_RECORDS/ADR-005_idempotent_agent_operations.md](ARCHITECTURE_DECISION_RECORDS/ADR-005_idempotent_agent_operations.md)** - Idempotent operations for safe retries
- **[ARCHITECTURE_DECISION_RECORDS/ADR-006_go_runtime_over_python_reference.md](ARCHITECTURE_DECISION_RECORDS/ADR-006_go_runtime_over_python_reference.md)** - Why the runtime is Go and the Python blueprint is lineage

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
- **[archive/blueprint/docs/](archive/blueprint/docs/)** - Agent-friendly SQL documentation

---

## Project Overview

Agent First ERP CRM is a database-first AI agent operating system that enables:
- **Autonomous customer service agents** with full CRM capabilities - deployed, in `agents/customer_service/`
- **An inventory control agent** on the same loop - deployed, in `agents/inventory/`, with a scheduled
  check whose every tick files a trajectory row
- **A sales and procurement agent** on the same loop again - deployed, in `agents/sales/`, driving the
  orders schema (`0027`-`0031`) through seven doors, and running the hourly keeper that claims retention
  and the line-by-line reconciliation owe
- **Tool-based architecture** where agents compose functions dynamically
- **Verbose agent logging**, with every run's trajectory queryable from the database it wrote
- **Semantic search** using PGVector - *real for `communications`, empty by decision elsewhere*. 0012
  built the three hnsw indexes and 0035 built the two doors, the register, and the record of which model
  filled a column; the customer service agent's keeper is the writer and `search_communications` is the
  reader. `entities.embedding` and `contacts.embedding` hold nothing, and `vw_embedding_status` says that
  per table. Read `agents/customer_service/README.md`'s "Semantic search, and the embedding keeper"
  before planning around the other two
- **Telegram integration** - *not in any of the three deployed agents*, which serve HTTP and SSE. The reference
  implementation in `archive/blueprint/` and the upstream checkout at `/home/justin/agents/dumb_agent` both
  have working adapters; the transport is a `main.go` change and the loop does not care which is attached

---

## Key Concepts

### Four processes, one pattern
- **Deployed, the CRM half**: `agents/customer_service/` - a Go backend, React UI, HTTP and SSE, and the
  trajectory writer. Start here to change what this agent does.
- **Deployed, the stock half**: `agents/inventory/` - the same loop as a sibling fork, with `pkg/inventory`
  replacing `pkg/crm` and an in-container timer added. It is the evidence for the claim that the loop is
  reusable: one domain package, four identity strings, one working second agent.
- **Deployed, the orders half**: `agents/sales/` - the same loop forked a second time, with `pkg/orders`
  (five reads, seven doors) replacing `pkg/crm` and a different kind of timer: its tick has no model in
  the loop at all, because both of its jobs are statements the database answers exactly. Two forks of
  one loop, three months apart, is the claim `architecture.md` makes about the pattern; the second one
  was the cheaper of the two, which is what makes it evidence rather than repetition.
- **Reference**: `archive/blueprint/bot.py` (~215 lines) - the same loop in one Python file, with LangChain and
  Telegram. The pattern's shortest statement, and **deprecated as a runtime**: it opens a plaintext
  connection per tool call, checkpoints memory in process, and runs one polling worker. New agents
  fork `agents/customer_service/`; [ADR-006](ARCHITECTURE_DECISION_RECORDS/ADR-006_go_runtime_over_python_reference.md)
  is the measurement record of why.

All three agree on the rules that matter: a read names a `vw_*` view or a function that returns one, a
write calls a function, every run records itself, and the model never chooses an audit column's value.

### Database-First Design
All agent state and knowledge lives in PostgreSQL:
- **Customer data**: Stored in normalized tables
- **Tool functions**: Stored as SQL functions in `pg_catalog`
- **Vector embeddings**: PGVector for semantic search
- **Audit logs**: Complete conversation and action history

### Agent Roles
1. **Chief Agent Officer (CAO)** - Validation and orchestration layer. Not built - and note that three
   deployed agents do not make one: each of them has the detection half of an escalation and nothing
   above them to route one to. What stands in for the CAO today is named in *Agent Validation* below
2. **Customer Service Agent** - Handles customer inquiries and support. **Deployed**, in
   `agents/customer_service/`; it is the role `AGENT_ROLE` defaults to
3. **Inventory Agent** - Monitors stock, alerts on shortages, reserves on instruction. **Deployed**,
   in `agents/inventory/` (`:4560`, `AGENT_ROLE=inventory`): the same Go loop as the customer service
   agent plus an in-container timer — a deterministic check every 30 minutes whose every tick lands
   an `agent_interactions` row, so "it ran" is a query and not a log. Requirements in
   `docs/agent_requirements/inventory/inventory.md`, rewritten in place on 2026-11-04 to name the
   views and doors that exist rather than the tables that were reviewed out of existence
4. **Sales & Procurement Agent** - Raises documents of all three kinds, moves them as far as a status
   can be moved by hand, and finishes the ones stock finishes. **Deployed**, in `agents/sales/`
   (`:4570`, `AGENT_ROLE=sales`): the same Go loop, `pkg/orders`' twelve domain tools, and an hourly tick
   whose every run files an `agent_interactions` row - the keeper `0011`'s retention policy and `0030`'s
   NOTICE both said was owed. Requirements in
   `docs/agent_requirements/sales/sales.md`; the doors it declines to register are explained there too -
   `book_work_order_production` and `plan_work_order_operation`, because a routing does not exist yet,
   and `execute_inventory_movement`, for the inventory agent's inherited reason that a process which can
   move stock freely can silence the alarms its own documents raise
5. **Communication Agent** - Handles multi-channel messaging. Not built

---

## How to Work on This Project

### 1. Understanding the Architecture
Start by reading:
1. [architecture.md](architecture.md) - System overview
2. [docs/database/agent_first_erp_crm_mental_model.md](docs/database/agent_first_erp_crm_mental_model.md) - Database concepts

### 2. Setting Up Development Environment
Follow [QUICKSTART.md](QUICKSTART.md) for Docker-based deployment.

### 3. Understanding Agent Tools
- The deployed surface is `agents/customer_service/backend_go/pkg/crm/tools.go`: nine CRM tools — three
  reading `vw_*` views (`vw_customers`, `vw_customer_communications_summary`,
  `vw_entity_communication_stats`), one reading `communications` by meaning through
  `search_similar_communications`, and five calling stored functions, of which four write
  (`add_customer`, `update_customer`, `add_communication`, `mark_customer_followup`) and one reads:
  `get_followup_customers` is a function and not a view because it takes `p_days_threshold`, which is the
  ADR-003 boundary in practice — a parameterised answer has a door, and 0022 is what made that argument
  mean what it says
- Both obey one rule the blueprint did not always: **a write calls a database function and never composes its own INSERT.** `code:cs_writes_through_doors` watches that, and its comment says what the grep had to grow to catch it
- Eight of the nine exist in Python in **[archive/blueprint/tools/](archive/blueprint/tools/)** — read them, and **[archive/blueprint/tools/README.md](archive/blueprint/tools/README.md)**, for the shape of a tool; wire a new one through the Go package above. The blueprint is lineage, not a starting point ([ADR-006](ARCHITECTURE_DECISION_RECORDS/ADR-006_go_runtime_over_python_reference.md))
- Study **[docs/agent_requirements/customer_service/customer_service.md](docs/agent_requirements/customer_service/customer_service.md)** for domain requirements
- Lineage examples, one part each, in `archive/blueprint/tools/`:
  - `customer_lookup.py` - Customer information retrieval
  - `add_customer.py` - Add new customers
  - `update_customer.py` - Update customer information
  - `customer_communications.py` - Communication history
  - `communication_logger.py` - Interaction logging, in the fuller shape of `add_communication.py`
  - `tool_logger.py` - Per-call accumulation for the trajectory. It holds no database code, and the note at its top explains why it used to

### 4. Database Operations
- Schema: [db/migrations/](db/migrations/), applied in filename order by `scripts/db/db up`. Nothing else creates tables - `db/README.md` lists the files that used to try
- The customer functions, the audit log and the interaction log are in `0001` onward; the numbered files under `scripts/database/` are the superseded copies they came from
- Semantic search: `0012` built the hnsw indexes, `0035` built the doors and the register, and the customer service agent's keeper is what writes the vectors. `vw_embedding_status` is the per-table answer to "is this column searchable", and `embedding_space` is the answer to "by which model" - the second is not bookkeeping: a column holding two models' vectors returns a plausible ranking of garbage
- **Documentation**: [docs/INTERACTION_LOGGING.md](docs/INTERACTION_LOGGING.md) - How to debug agent behavior

---

## Common Tasks

### Adding a New Tool
1. Decide which half owns the rule. If the tool changes persistent state, the decision belongs in a
   `db/migrations/NNNN_*.sql` function, so start there and not in the Go file (ADR-002)
2. Give the migration the next free number. `migrate.sh` rejects a file numbered at or below the highest
   applied, which is why the two planned ones became 0024 and 0025 - see db/MIGRATIONS.md. The highest
   applied today is **0035** (the semantic surface: two doors, `embedding_space`, and the register), and
   0033/0034 are still reserved for the two queued items in `PLAN.md`, which is what "by arrival and not
   by importance" costs when the arrival is a draft that never landed. So a NEW file here is `0036_*`.
   Earlier instances of the same rule: 0026 took a number rather than the free 0024 because a bug fix and
   a planned feature are not the same queue; 0032 is the same rule arriving on the day it was needed; and
   `0031` is the grant that let `agents/sales`' keeper run and is the one migration in this set that
   changes no row, while `0032` changes 430 of them and no row shape
3. Wire the tool in the domain package of the agent that owns it, and **in that package's `tools.go`** -
   `agents/customer_service/backend_go/pkg/crm/tools.go`, `agents/inventory/.../pkg/inventory/tools.go`,
   or `agents/sales/.../pkg/orders/tools.go`: read a `vw_*` view or call the function, send an
   idempotency key if it writes (ADR-005), and record what it touched with `turn.Source`. Two rules live
   in that file's own plumbing, and both were found by an agent failing a case rather than by a review:
   a WHERE clause with nothing to bind must add no argument (`clauseFor` in the package's `args.go`), and
   **every id the new door takes has to be returnable by some read in the same process** - a uuid no
   read can produce is a capability that exists in SQL and not in conversation, which is the difference
   this repository keeps making a tool in order to close. `TestEveryDoorKeyIsReadableFromARead` is the
   assertion, and it names the one column that still fails it
4. Write the description for a reader that cannot see the schema: what it answers, what it refuses, and
   which fact only the caller has. Where the description says a value "comes from" a tool, check that
   the named tool's SELECT list really returns it: `create_order` advised a `warehouse_id` "from
   `get_orders`" for a day while `get_orders` returned the name and dropped the id
5. Add it to the table in the README of the agent that owns it — `agents/customer_service/`,
   `agents/inventory/` or `agents/sales/` — then run `scripts/docs/check_agent_docs.sh`. It walks every
   tracked `backend_go` and fails on a tool in one and not the other, in either direction, which is what
   makes step 5 not optional
6. Add a probe to `db/tests/` that fails the day the function stops meaning what the tool says

### Creating a New Agent
1. Fork `agents/customer_service/`. `agents/inventory/` and `agents/sales/` are that recipe executed
   twice, so compare the two before choosing what to copy: the inventory fork is the smaller diff (one
   domain package, four identity strings), and the sales fork adds a scheduled tick whose every run
   records itself, which is the shape to copy if your agent has a fact it must check on a schedule.
   [archive/blueprint/bot.py](archive/blueprint/bot.py) shows the whole pattern in one
   file as background — it is lineage, not an on-ramp, and ADR-006 records why
2. Define agent-specific tools, in the order above: the function first, then the tool that calls it
3. Keep the trajectory writer and the memory store. An agent that cannot be read back cannot be fixed,
   and an agent whose memory dies with its container has no memory - both are 0023's and 0011's subject.
   One consequence of keeping the writer, learned the hard way on 2026-11-08: `AGENT_ROLE` is not just a
   label on the rows, it is half of the key the history is *read back* by (`ids.Thread(agent, thread)`),
   so a fork that copies the loop and keeps its parent's `AGENT_ROLE` does not merely log under the wrong
   name - it rehydrates the parent's conversations and starts answering in the parent's voice. Probe
   `4_9` and acceptance case 37 are the two checks that make that visible without a human noticing a
   greeting
4. Test the agent with your intended use cases, in `db/tests/` for the schema half and `go test ./...`
   for the loop half
5. Then say so in this file, in `README.md`, in `architecture.md` and in `QUICKSTART.md`: a fourth agent
   that these pages still describe as three is the same class of defect as a tool in code and not in a
   README, and `check_agent_docs.sh` will only catch the narrower one

### Debugging
1. Check PostgreSQL logs for SQL errors
2. `GET /api/interactions?view=recent` is the agent reading its own trajectory; `docker logs -f
   afpc-customer-service` is the same run while it happens, at `LOG_LEVEL=debug`
3. `audit_log` is who changed what — and it is the only row-level trail any of the agents writes.
   `human_sessions` and `bot_actions` exist and are read by the coverage machinery, and hold **zero
   rows**: no login console and no action logger write them, so looking for an agent's action in
   `bot_actions` is a dead end, and `agent_interactions` plus `audit_log` is the pair that answers.
   `vw_audit_coverage` says which tables have a trail and which are exempted, with the reason. One
   row's history is `WHERE table_name = 'communications' AND row_pk->>'id' = '15'` - `row_pk` is
   **jsonb** (`{"id": 15}`), not a bigint, because one trigger serves eighteen tables with different
   keys, and `row_pk = 15` and `row_pk::text = '15'` both answer zero rows and read like a missing trail
4. Use the `vw_*` views to verify data state - they are the same read path the agent uses, which is the
   point: a state the views cannot show is a state the agent cannot see either
5. Query `agent_interactions` for full trajectory analysis, and `vw_tool_calls` to see it one call at a
   time
6. **When an agent's number is wrong and its JSON is right, look in Go and not in SQL.** A `numeric`
   column arrives from pgx as `pgtype.Numeric`, a struct, and `encoding/json` renders it perfectly
   because the type implements `Marshaler` - so a tool answer and a trajectory row both read correctly
   while anything that formats or adds that same value *in Go* is silently wrong: `%v` prints
   `{300000 -4 false finite true}`, and a sum of such values is 0. That is how one deployed agent's
   summary line said "0 units held unresolved" beside `vw_order_commitments`' 13, and how another
   printed `{0 0 false finite true} available` in a sentence a human was meant to read. The same class,
   one column type away: `integer` is an **int32** to pgx, so a reader that switches on `int64` reports
   a claim sweep that ran as one that collected nothing. pgx's default map
   (`pgtype/pgtype_default.go:163-177`) is the list to write a reader against, and `pkg/db`'s
   `normalise` plus each domain package's `num`/`intArg` now do. The other shape of the same mistake is
   in the reads rather than the rows: a WHERE clause with nothing to bind must add no argument, or the
   query fails whole with `42P18 could not determine data type of parameter $n` - which is what
   `get_suppliers` did on its default path until `clauseFor` stopped the builder guessing
7. **If an agent greets you as one of the other agents, read `conversation_id` before you read the
   prompt.** The prompt is assembled per process and is usually the innocent party; the history is
   fetched by conversation id, and a model follows ten prior turns of someone else's voice. `SELECT
   telegram_chat_id, count(DISTINCT bot_id) FROM agent_interactions GROUP BY 1 HAVING count(DISTINCT
   bot_id) > 1` is the question, and finding 4.9 in `docs/INTERACTION_LOGGING.md` is the answer -
   including why a thread string is not a conversation, and why `ids.Thread` takes the pair

### Testing
Five things can be wrong independently, and each has its own harness:
1. `./scripts/db/verify.sh` - structural assertions over the catalog (the B-checks), no fixtures
2. `./scripts/db/test-functions.sh` - one probe per finding, run against a copy of the database with
   the residue check around it; this is also where the `code:*` markers report, including
   `code:agent_docs_match_surface`
3. `go test ./...` in `agents/customer_service/backend_go` - the loop, the tool wiring and the
   derivations, against fakes and with no database. See the note on the one failing test in that
   package's README section
4. `pytest archive/blueprint/tests/ -v` - **read this before running it.** These are the reference
   implementation's scripts, and they describe the Python shape rather than the deployed one; the reason
   to be careful is narrower and measurable. Two of the five (`test_create_functions.py`,
   `test_update_function.py`) connect at import - `POSTGRES_DB` defaults to **`agent_first_erp_crm`, the
   live database** - and run, then `commit()`, a `DROP FUNCTION IF EXISTS` naming a signature that does
   not exist (10 args for `add_customer`, 12 for `update_customer`, where the doors have 15 and 13), so
   the DROP removes nothing and prints "does not exist, skipping" - and then their `CREATE FUNCTION`
   **succeeds**, because a different arity is a different function. The result is the exact condition
   0016 was written to remove: a **second head** on each door, whose body is a stub returning
   `TRUE, 1, 1, 'Test'`. Measured in a scratch database with both heads installed, a call with ten or
   fewer positional arguments then fails `could not choose a best candidate function` - so the probes and
   hand-run SQL that pass fewer arguments break, while the Go tools (which send all 15) keep working,
   which is the worst shape a corruption can have: most of the surface looks fine. pytest imports every
   module it collects, so all of this happens before any assertion runs. Run them only against a scratch
   database (`createdb afpc_scratch && POSTGRES_DB=afpc_scratch python3 archive/blueprint/tests/test_functions.py`),
   and see `PLAN.md`'s item on guarding or deleting them
5. `./scripts/agents/tool_testplan.sh` - the only harness that tests what a human gets: it prompts
   all three deployed agents through `POST /api/chat` once per registered tool and verifies each turn
   on three independent planes - the call happened (`vw_tool_calls`, keyed by the returned
   `run_id`), the state is real (the views and trail the answer claims), the run recorded itself.
   Plan and cases: `docs/agent_requirements/agent_test_plan.md`. Slow (every case is a real model
   turn) and re-runnable (fixtures carry a timestamp, because `add_customer` refuses duplicates)

And the one that checks the documentation: `scripts/docs/check_agent_docs.sh`, run on its own or
through 2.

---

## File Structure

Two rules about this list. Directories that hold the live system are expanded; the ones the schema
sweep left behind are named once and described rather than walked, because a tree that lists
superseded files at the same depth as current ones is how a reader ends up editing the wrong file.

```
agent_first/
├── README.md, QUICKSTART.md, architecture.md, PLAN.md, AGENTS.md, CONTRIBUTING.md
├── Makefile                        # dev-up, db-verify, db-test, docs-schema
├── ARCHITECTURE_DECISION_RECORDS/  # ADR-001..006, cited by the code that obeys them
│
├── agents/
│   ├── sales/                      # THE THIRD DEPLOYED AGENT: same loop, the orders surface, a keeper
│   │   ├── README.md               # tools, the two jobs on the timer, endpoints, what is not here
│   │   ├── Dockerfile, docker-compose.yml   # :4570; its own .env, written by scripts/db/init.sh
│   │   ├── frontend/               # the same React UI, third copy, four identity strings different
│   │   └── backend_go/             # sibling fork: pkg/orders (5 reads, 7 doors, runHousekeeping) replaces pkg/crm
│   ├── inventory/                  # THE SECOND DEPLOYED AGENT: same loop, inventory tools, a timer
│   │   ├── README.md               # tools, schedule, endpoints, what is not here
│   │   ├── Dockerfile, docker-compose.yml   # :4560; its own .env, written by scripts/db/init.sh
│   │   ├── frontend/               # the sibling's React UI, copied rather than rewritten
│   │   └── backend_go/             # sibling fork: pkg/inventory (4 reads, 1 door, RunCheck) replaces pkg/crm
│   ├── customer_service/           # THE FIRST DEPLOYED AGENT, and the one the other two fork
│   │   ├── README.md               # tools, environment, endpoints, what is not here
│   │   ├── Dockerfile, docker-compose.yml
│   │   ├── frontend/               # React UI, built into backend_go/static and served by the binary; same-origin API_BASE
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
│   └── jada/                       # the reference drop: unmodified, unreadable to the build user, gitignored
│
├── db/                             # THE SCHEMA, and the harness that asserts it
│   ├── README.md                   # single source of truth: which SQL files are superseded
│   ├── MIGRATIONS.md               # finding to migration, the marker table, and the tracked tasks
│   ├── migrations/                 # 0000-0018, 0021-0023, 0026-0032 applied in filename order; 0024/0025 planned
│   ├── tests/                      # N_N_<finding>.sql, one probe per block, VERDICT lines
│   └── seeds/                      # 01_demo_customers.sql, 02_demo_inventory.sql - data, idempotent, never DDL
│
├── dev/                            # THIS SERVER: container, roles, TLS, and what will bite you
│   ├── README.md                   # read before a connection fails for a reason that is not the network
│   ├── docker-compose.yml, tls/    # the volume and the exported CA (dev/tls/afpc-ca.crt)
│
├── scripts/
│   ├── agents/tool_testplan.sh     # the acceptance harness: one prompt per tool, three planes per answer
│   ├── db/                         # db, init.sh, migrate.sh, seed.sh, roles.sql, verify.sh, test-functions.sh, _common.sh
│   ├── docs/                       # check_agent_docs.sh (the doc watchdog), gen_schema_docs.sh, regen_view_columns.py
│   ├── tests/                      # superseded ad-hoc python scripts, not a suite - see their README
│   └── database/, 08_create_views.sql  # superseded pre-0001 SQL; db/README lists each file
│
├── docs/
│   ├── INTERACTION_LOGGING.md, ATTACHMENT_SYSTEM.md   # the second is a design record, not a feature
│   ├── agent_requirements/         # customer_service/, inventory/, and agent_test_plan.md
│   ├── database/                   # the review's companions + generated listings; agent_first_erp_crm_schema.sql is superseded
│   └── history/                    # MISALIGNMENT_FIXES.md, STABILITY_IMPROVEMENTS.md - dated records
│
└── archive/                        # frozen lineage: nothing here runs, nothing is added here (ADR-006)
    └── blueprint/                  # the pattern in one Python file - moved out of the root on 2026-11-05
        ├── bot.py                  # ~215 lines: loop, tools, memory, PostgreSQL
        ├── tools/                  # the eight tools bot.py registers, in Python, plus the trajectory helpers
        ├── docs/                   # agent-friendly SQL docs; views.md's lists are checked against the catalog
        ├── tests/                  # import-time scripts, NOT collected tests - two of them write DDL; read the README before running
        └── *.sql                   # superseded copies, kept so the fork is legible - see db/README.md
```

The tree was last walked by hand in the 2026-11-05 documentation sweep. `T4`'s checker covers the
*content* claims (tools, environment keys, views, columns, migrations) rather than the shape of this
list, so a new top-level directory is still something a human adds here — and a claim inside this list
that the code contradicts is exactly what the sweep is for. When you change a port, a path, or which
`.env` a container reads, fix the tree in the same commit.
---

## Best Practices

1. **Database First**: If a rule about persistent state is not in a migration, it is not enforced (ADR-002)
2. **Tool Composition**: Design tools to be composable and reusable - the six shared tools are the same
   code in all three deployed agents
3. **Semantic Search**: *available for `communications`, and only there.* 0035 built the two doors, the
   customer service agent's keeper fills the column, and `vw_embedding_status` says per table how much
   of a corpus a search can actually see. `entities` and `contacts` are empty by decision, so design a
   read of those against the views and the CHECK'd vocabularies (`vw_domain_vocabulary`) instead
4. **Audit Everything**: The row trail is the triggers' job and it happens without asking; the agent's
   job is to write through a door so there is a row-change to audit, and to let the loop record the run
5. **Documentation**: Update the relevant page in the same commit - `check_agent_docs.sh` fails a tool
   that appears in code and not in a README, which is what makes this step not a suggestion
6. **Security**: Never hardcode credentials; see the environment tables in each agent's README
7. **Testing**: Every new tool earns a `db/tests/` probe and a case in the acceptance plan
8. **Naming Conventions**: Follow the patterns below - snake_case SQL, `vw_` views, verb-first functions

---

## Security Guidelines

### Environment Variables
Secrets live in the environment, never in a committed file:
- Database credentials: `dev/.env`, generated with random local credentials by `scripts/db/db up`
  (mode 600, gitignored). `dev/.env.example` documents that file's shape and its values are deliberately
  empty - an unset password makes the tooling refuse to start rather than quietly use a committed guess
- The agent runtime role: `AFPC_PG_USER` / `AFPC_PG_PASSWORD` (or `AFPC_APP_PASSWORD`, the name
  `scripts/db/roles.sql` uses), read by all three agents' compose files through `env_file`
- Endpoint auth: `API_KEYS` (comma-separated bearer tokens). Unset means open, and `/api/health` says
  `DISABLED` instead of implying otherwise
- Third-party keys: `TAVILY_API_KEY`, `HIGHBYTE_MCP_BEARER_TOKEN`, the `AZURE_*` group - all three are
  inert on this server, and each is listed in the agent README so an off knob is not mistaken for a
  broken one
- **There is no root `.env.example`.** The template is `dev/.env.example` for the database, and each
  agent's README table is the list of what its own process reads. A `Telegram bot token` is not among
  them because no deployed agent speaks Telegram
- `AFPC_PG_HOST` is in `agents/*/.env` and is gitignored for a different reason: it names a private
  address on a specific network, not a credential

### Data Protection
- Never log sensitive customer data (PII). What reaches the *log* goes through `pkg/logging`'s `Mask` and
  `MaskArgs`: an email keeps its local part's first letter and everything in its domain after the first
  dot (`jane@afpc.example.invalid` → `j***@example.invalid`), a phone match keeps its last four digits,
  and the rest becomes `***`. Two tests keep the honesty of that:
  `TestMaskLeavesTheShape` (a masked sentence must still read like the sentence) and
  `TestMaskArgsIsStable` (two identical calls must print identically, so debug logs are diffable)
- **The mask is for logs, not for the trajectory**, deliberately: `agent_interactions.tool_observations`
  carries what the tool actually returned, because that table is what an auditor cross-checks the row
  trail against (0013's reason for auditing telemetry rows). A masked `tool_input` there would make the
  row useless for the question it exists to answer. So: the log line is redacted, the record is not, and
  the record is protected by grants and RLS rather than by redaction
- Encrypted connections are the default and the checked kind: `sslmode=verify-full` against
  `dev/tls/afpc-ca.crt`. `require` encrypts and authenticates nothing
- Row-level security is **not** "where appropriate": it is `FORCED` on every tenant-coded table, none of
  the three `afpc_*` roles has `BYPASSRLS`, and `vw_rls_status` publishes each policy with a verdict. The
  database owner is *not* one of the roles an agent connects as, because an owner bypasses RLS and would
  make every isolation assertion in the harness a false pass

### Audit Trail
- Row changes: `audit_log`, written by triggers with a sha256 chain segmented per tenant and month -
  `audit_chain_verify()` is the check, and it is part of the acceptance harness's tail
- Agent runs: `agent_interactions`, one row per run, written by the loop's `defer` so a panicking run
  still records itself; `vw_tool_calls` gives it one row per call
- **Not** `bot_actions` or `human_sessions`: those two tables are in the schema and are read by the
  coverage machinery, and nothing in either implementation writes them, so both are empty. A doc that
  told you to log there was describing the pre-0001 design; the live answer is the pair above

---

## Database Architecture

### Core Domains
1. **Party Management** - `entities`, `contacts`, `entity_relationships`, `addresses`
2. **Communications** - `communications`, with threading (`thread_root_id`) and sentiment
3. **Audit Logging** - `audit_log` (the row trail) and `agent_interactions` (the run trail).
   `human_sessions` and `bot_actions` are in this domain's name and in the schema, and have **no
   writer**: they came with the pre-0001 design and are kept because the coverage machinery reads them
4. **Inventory** - `inventory_items`, `warehouses`, `inventory_on_hand`, `inventory_movements`,
   `inventory_reservations`, plus the master data (`item_categories`, `units_of_measure`,
   `costing_methods`). **There is no `products` table** - items are `inventory_items`, which is the
   difference between reading `db/migrations/` and reading the July documentation
5. **Orders** - `orders` + `order_items` (`0028`: SALES, PURCHASE and WORK in one discriminated pair,
   because `inventory_reservations.order_id` has to resolve and a three-way OR cannot be a foreign key),
   `order_lifecycle` (global: which statuses each type may hold, with `stock_moving` marking the ones
   that are consequences of stock and therefore not writable by hand), `suppliers` (`0027`, extending
   the party root so one party can be customer and supplier at once), and `work_centres` +
   `work_order_operations` (`0029`). Every reference edge these four added carries `tenant_id` in the
   key, because a foreign key does not consult row security and 0027 measured a single-column one
   satisfied by another tenant's row. **There are no `sales_orders` or `purchase_orders` tables**, and
   `0030`'s doors (`ship_sales_order`, `receive_purchase_order`, `book_work_order_production`,
   `cancel_inventory_reservation`) are what a reservation has always lacked: a way to be undone
6. **Support** - Follow-ups (`followups`). Tickets were part of the vestigial schema and are
   referenced by nothing in the canonical one - see `db/migrations/0017_interaction_readpath.sql`.
   `followups` has no writer either, so `vw_pending_followups` is empty by construction and the live
   follow-up answer comes from `get_followup_customers(days)`

### Key Tables
| Table | Purpose |
|-------|---------|
| `entities` | Business organizations and the customers recorded against them |
| `contacts` | Individual humans |
| `entity_relationships` | Links contacts to entities; `is_primary` is what a read path resolves through |
| `addresses` | Where an entity is, and `is_primary` is what `update_customer` rewrites |
| `communications` | All interactions. Every row arrives through `add_communication` |
| `human_sessions` | Vestigial: a human-agent login trail with no login screen behind it. Zero rows |
| `bot_actions` | Vestigial: an action log the loop does not write. Zero rows |
| `agent_interactions` | Complete trajectory logging, one row per run, written by the loop |
| `orders`, `order_items` | The three document types in one header/detail pair; totals and line state are derived in the views, not stored (`0028`) |
| `order_lifecycle` | Which status each order type may hold and in what order; global master data, declared in B19 rather than given tenant policies (`0028`) |
| `suppliers` | The party an order buys from, keyed to `entities` with the tenant in the same key (`0027`) |
| `work_centres`, `work_order_operations` | Where a work order's operations run and the plan they run in (`0029`) |
| `inventory_reservations` | Stock held for a document. `order_line_id` (`0030`) says which line it is held *for*, which is what makes the reconciliation a query; `updated_at` arrived with the first writer the table ever had |
| `audit_summary` | Daily aggregation, maintained by `audit_summary_refresh()` - which nothing on this server schedules, so it has zero rows. Same class of gap as `idempotency_sweep`: a policy with no keeper |
| `followups` | Support tasks - exists, read by `vw_pending_followups`, and has no writer |
| `tenants`, `locations`, `schema_migrations` | The tenant root (1 row), bin-level storage inside a warehouse (declared, unused: 0 rows, and the stock views work at warehouse grain), and the apply ledger |
| `agent_memories` | What an agent was told to remember (0023), append-only by grant |
| `units_of_measure` | Master data: units an item can be counted, weighed or measured in |
| `costing_methods` | Master data: how an item's cost is derived |
| `currencies` | Master data: ISO 4217 codes behind the three currency columns, and how many minor units each has; global, so declared in B19 rather than given tenant policies |
| `currency_rates` | Rate history per currency pair; one open row per pair by partial unique index, gaps and overlaps across closed rows unconstrained; global, and outside 0013's trail because `audit_log.tenant_id` is NOT NULL |
| `embedding_space` | One row per filled vector column, naming the embedder and the width that produced its vectors. Global, untrailed (0018's reason), and written only by `embed_communications`, which refuses a call naming a different model - the mixed-corpus state no other check can see (`0035`) |
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
| `vw_entity_contact_details` | Complete entity and contact details — **not in the schema**: defined only in the superseded `archive/blueprint/08_create_views.sql` (T4) |
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
| `vw_orders` | One row per document of any type, counterparty resolved, totals summed from the lines |
| `vw_order_lines` | One row per line, its state named from three quantities rather than stored as a fourth |
| `vw_suppliers` | Supplier facts beside the party they describe (`0027`) |
| `vw_work_centres` | Where operations run, and how many are queued at each |
| `vw_work_order_plan` | A work order's planned operations, with the line and centre resolved (`0029`) |
| `vw_embedding_status` | One row per vector column in the catalog: what it declares, whether an hnsw index leads it, how many of its rows carry a vector, which model the stamp credits, and a verdict of EMPTY / PARTIAL / UNSTAMPED / MISMATCH / UNINDEXED / COMPLETE (`0035`) |
| `vw_unembedded_communications` | The keeper's queue, and the definition of what an embedding of a communication is made from - composed in SQL so the rule has one home (`0035`) |
| `vw_order_commitments` | One row per order line against the stock held for it - attributed and unattributed counted apart, with a verdict on whether the line's counter and the ledger agree (`0030`) |

For every view's columns, read [docs/database/views.md](docs/database/views.md): it is generated from `pg_attribute` by `scripts/docs/gen_schema_docs.sh` and is current as of the last run, which the file's own header dates. `archive/blueprint/docs/views.md` is the *frozen* reference from the lineage - its lists are checked against the catalog by `check_agent_docs.sh` §3b, and nothing is added to it (ADR-006), so a view that arrived after the sweep, like 0035's two, is absent there by policy and not by accident.

### Database Naming Conventions
- **SQL Tables**: snake_case (e.g., `entities`, `communications`) — note `entities`, not `customers`:
  the party model is one table for organizations and one for people, and `vw_customers` is the join an
  agent reads
- **SQL Views**: MUST use `vw_` prefix (e.g., `vw_customers`, `vw_customer_communications_summary`).
  `v_*` is not a spelling any migration used, so `v_recent_interactions` in an old page is a 42P01
- **SQL Columns**: snake_case (e.g., `created_at`, `entity_id`)
- **SQL Functions**: snake_case with a verb prefix (e.g., `add_customer`, `reserve_inventory_for_order`).
  `get_inventory` does not exist and never did; the stock reads are views
- **Python Variables**: snake_case (e.g., `customer_id`)
- **Python Classes**: PascalCase (e.g., `CustomerServiceAgent`)

---

## Schema documentation, generated and otherwise

Three of the pages in `docs/database/` are **generated from the running catalog**, not written:

```bash
make docs-schema            # = scripts/docs/gen_schema_docs.sh
# regenerates docs/database/{tables,views,indexes}.md from pg_attribute/pg_indexes
```

Their "Do not edit" header carries the generation date, and a stale generated file is a real failure mode:
nothing checks them. The list-vs-catalog check (`code:agent_docs_match_surface`, step 3b of
`scripts/docs/check_agent_docs.sh`) watches the **column lists in `archive/blueprint/docs/views.md`**, not these
three pages — so a migration that renames a column fails there, and silently leaves `tables.md` behind
until someone runs the target. Re-run it with the migration, not after it.
Everything else in `docs/database/` is prose the review wrote, and
[db/README.md](db/README.md) remains the single source of truth for what the schema *is*.

**`pgschema` is not installed here and `docs/schema/` does not exist.** The `pip install pgschema` /
`pgschema dump` recipe this section used to carry was inherited from the pre-0001 layout, and the
`archive/blueprint/docs/schema_reference.md` header naming "pgschema 1.12.0" and PostgreSQL 16.14 is a stamp from
that generator's run, not a claim about this server — which runs PostgreSQL 17. Use the harness and the
catalog:

```bash
docker exec -it afpc-pg psql -U postgres -d agent_first_erp_crm -c '\d+ entities'
docker exec -i afpc-pg psql -U postgres -d agent_first_erp_crm -tAF'|' \
  -c "SELECT viewname FROM pg_views WHERE schemaname='public' AND viewname LIKE 'vw_%' ORDER BY 1"
```

**`_schema_graph` exists and is empty** — zero rows, measured. The old claim that it "contains a
knowledge graph of the entire schema for AI agent understanding" was inherited from the superseded
loader that would have filled it, and nothing in `db/migrations/` writes it. The graph an agent can
actually query is the set of `vw_*` views plus `vw_domain_vocabulary`, `vw_rls_status`,
`vw_audit_coverage` and `vw_idempotency_status`, which describe the catalog in the same register.

---

## Agent Validation

### Validation Layer (CAO) — designed, not built
The Chief Agent Officer was specified to provide:
- Input validation before agent execution
- Output validation after agent execution
- Safety checks for destructive operations
- Rate limiting and quota enforcement

**None of it runs on this server.** There is no CAO process, and the customer service agent has only the
detection half of an escalation (sentiment, outcomes, `get_entity_stats`) with no second agent to route
one to. What actually performs each of those four jobs today:

| The CAO's job | Who does it now |
|---|---|
| Input validation | the tools' argument coercion (`pkg/crm`, `pkg/inventory`) and the functions' own `22023` refusals — 0015's rule: a wrong argument is refused before any work |
| Output validation | `scripts/agents/tool_testplan.sh`, per release rather than per turn: the answer is checked against the rows it claims |
| Safety on destructive operations | the doors that do not exist (`execute_inventory_movement` is not a tool), `REQUIRE_WRITE_APPROVAL`/`STRICT_TOOL_POLICIES` for the caller-side gate, and 0008's delete rules |
| Rate limiting | nothing. `API_KEYS` authenticates; no quota is enforced anywhere in either backend |

### Validation Rules, as they exist in code
1. **Input**
   - Required parameters: the tool schemas, and `required` lists that refuse an empty selector
   - Data types: Go coercion in the domain packages' `args.go` (`days`) and `tools.go` (`object`, `text`,
     `integer`, and `uuidArg` in the inventory fork), with the SQL-level type errors deliberately left to
     the door
   - Injection: no path composes SQL from a value — reads are parameterized against views, writes are
     `SELECT * FROM function($1, …)`
2. **Output**
   - Format: `pkg/db`'s `normalise` decides what a caller can read (RFC 3339 timestamps with their
     offset, bytea decoded, uuids in 8-4-4-4-12) — `pkg/db/normalise_test.go` pins it
   - Sensitive data: the process log masks; the trajectory stores what the tool returned
   - Results: `observations_aligned` in `vw_tool_calls` is the machine-readable "the record of this run
     agrees with itself"; `audit_chain_verify()` is the same claim about the trail
   - "Validation status" is *not* a column anywhere: the trail exists so a claim can be checked after
     the fact, by a harness today and by a CAO eventually

---

## Development Guidelines

### Naming Conventions
See **Database Naming Conventions** above; the two lists exist so that a reader who arrives from either
heading gets the same rules, and the examples there are the ones that match the catalog. The historical
`customer_communications` table and the `get_customer_by_id` function this section once named as examples
exist in neither the schema nor the code - the first is `vw_customer_communications_summary`, the second
is `get_customer_info` reading `vw_customers`.

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