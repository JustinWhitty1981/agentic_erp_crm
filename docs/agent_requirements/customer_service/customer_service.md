# Customer Service Agent Requirements

## Core Identity
- **Role:** First-line support for customer inquiries.
- **Interface:** HTTP and SSE in the deployed agent - `POST /api/chat` and `POST /api/chat/stream`,
  with the React UI over the same origin. Telegram is the reference implementation's transport only
  (`archive/blueprint/`); neither deployed binary has an adapter for it, and the loop does not care which is
  attached. See also line 113, which already said this - the page contradicted itself, and this is the
  corrected half.
- **Database Access:** Reads through the `vw_*` views the schema publishes (`vw_customers`,
  `vw_customer_communications_summary`, `vw_entity_communication_stats`); writes only through
  `add_customer`, `update_customer`, `add_communication` and `mark_customer_followup`. The first draft
  of this line said "Read/Write to `customers`, `communications`" - a table that is a view, and a table
  no caller may write to directly, which is the arrangement 0021 exists to make true. Worth knowing, because it changes what "through the database" buys: all four functions are
  **security invoker** (`prosecdef = false`, measured), and `afpc_app` holds `INSERT` on
  `communications` directly. So the door is not a privilege boundary - an agent with the grant could
  skip it - it is a *single implementation*: the CHECKs, the name resolution, the thread root and the
  claim ladder exist in one place, so a caller that bypasses the door does not gain access it lacks, it
  loses the rules. That is what `code:cs_writes_through_doors` watches, and why the rule is checked in
  code rather than granted in SQL.
- **Implementation:** `agents/customer_service/backend_go` — the blueprint pattern (`archive/blueprint/bot.py`)
  in a Go runtime. Why the runtime is not the Python reference:
  [ADR-006](../../../ARCHITECTURE_DECISION_RECORDS/ADR-006_go_runtime_over_python_reference.md).

## Functional Requirements
1.  **Retrieve Customer Info:**
    - Fetch: Name, Address, Phone, Email, Status, and Recent Notes.
    - Use `get_customer_info` tool with fuzzy name matching.
    - Support semantic search via PGVector: "Find customers who complained about shipping last week."
      Implemented 2026-11-09 by 0035 and `search_communications`; see requirement 1's row below.
2.  **Update Customer Info:**
    - Update: Name, Address, Phone, Email, Status, and Recent Notes.
    - Use the `update_customer` tool, whose door is the stored function of the same name
  (`update_customer(p_search_name, p_search_email, p_search_phone, ...)`) - not
  `update_customer_info`, which is what this requirement called it for as long as the page existed
  and which no tool in either agent has ever been named. `GET /api/tools` is the authority
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
    - Formats results for the transport it is on: the blueprint converts markdown to Telegram HTML
      (`markdown_to_html`, `bot.py`); the deployed agent returns markdown to a browser that renders it,
      and streams it over SSE.
7.  **Escalation:**
    - Detect complex or angry sentiment and escalate to the CAO with a summary.
    - Format escalation: "Customer X is upset about Order Y. Summary: [Details]. Action Required: [Suggestion]."
8.  **Agent logging:**
    - Log the prompt, tool calls, and the agents response for troubleshooting agent behaviors using tool 'tool_logger.py'. 

## Non-Functional Requirements
- **Response Time:** < 30 seconds for typical queries (ornith:35b).
- **Accuracy:** 100% data accuracy (validated by CAO).
- **Safety:** No destructive actions (DELETE, DROP) allowed.
- **Context Awareness:** Remembers previous interactions in the *thread*, and after a restart too:
  `Rehydrate` reads the thread's last turns back out of `vw_recent_interactions` (keyed by a UUIDv5 of
  the pair **(agent, thread)** - `pkg/ids`, and the agent half arrived on 2026-11-08 by way of finding
  4.9: this binary's `AGENT_ROLE` is also a `vw_recent_interactions` filter in all but name, because a
  thread string hashed alone is one conversation shared with every other agent on the tenant) before the
  first prompt of a cold conversation is assembled. Durable facts live in `agent_memories` behind the
  three memory tools - and that store has no agent column, so a key is namespaced by convention, which
  is the open half of the same requirement (`PLAN.md` §3). `InMemorySaver` is the blueprint's
  answer and dies with its container - which is 0023's subject, not a detail

## Validation Rules
- Any update to `customers` or `communications` must be reported to the CAO.
- CAO validates by re-querying the database to confirm the change.
- Failed validations trigger an immediate alert to the human owner.

## Implementation

Two implementations exist, and they share the requirements and the rules:

- **Deployed**: `agents/customer_service/` - Go backend, HTTP and SSE, React UI. The reference for what
  this agent actually does.
- **Reference**: `archive/blueprint/` - the same surface in Python and LangChain, on Telegram, and deprecated
  as a runtime ([ADR-006](../../../ARCHITECTURE_DECISION_RECORDS/ADR-006_go_runtime_over_python_reference.md)).
  The other deployed agent, `agents/inventory/`, is this loop with a different tool layer and a timer.
  Read the blueprint for the pattern; do not deploy it and expect this schema.

### Tools

| Tool | Purpose | How it reaches the data |
|------|---------|----------------|
| `get_customer_info` | Look up customer by name, email, phone, or id | `SELECT ... FROM vw_customers WHERE ...` - one selector per call, because two `ILIKE` clauses on one row set answers for whichever column matched first |
| `get_customer_communications` | Get recent interactions | `SELECT ... FROM vw_customer_communications_summary ... ORDER BY started_at DESC LIMIT 5` |
| `get_entity_stats` | View communication metrics | `SELECT ... FROM vw_entity_communication_stats` |
| `get_followup_customers` | Get customers needing contact | `SELECT * FROM get_followup_customers(p_days_threshold := 7)` - the parameter this requirement named, and which `0022` found the function had never read |
| `add_customer` | Create a customer | `add_customer(...)`: the entity, the contact, the relationship and the address, in one function |
| `update_customer` | Change a customer's details | `update_customer(...)`, selected by name plus a contact point |
| `add_communication` | Log new interaction | `add_communication(...)`. **Not** an `INSERT`. This row said `INSERT INTO communications (...)` for as long as the page existed, which is requirement 5 written as a caller-side write - the shape `0021` replaced, and the reason `4_5` is a test rather than a note |
| `mark_customer_followup` | Set or clear the follow-up mark | `mark_customer_followup(p_entity_id, p_followup)` (`0014`), which is the only door allowed to set `entities.status` after creation - so the mark is a function's decision with a grant behind it, not a tool that can write any column it names |
| `save_memory_tool`, `get_memory_tool`, `list_memories_tool` | Remember what the caller asked the agent to remember | `save_memory` / `get_memory` / `list_memories` over `agent_memories` (`0023`). In the blueprint these are files in a directory, which is what 0023 was for |
| `search_web` | Web search (Tavily) | Registered always, **refuses without `TAVILY_API_KEY`** - which is the honest degraded mode, and acceptance case 14 asserts the refusal text rather than a third party's uptime |
| `scrape_url` | One HTTP GET, read into text | The SSRF guard is the point of the tool: private addresses are refused unless `ALLOW_INTERNAL_SCRAPE` says otherwise, the read is capped by `MAX_SCRAPE_BYTES`, and acceptance case 15 verifies the block rather than trusting it |
| `current_time` | Date and time | No database query. The reason the tool exists at all is that a model without a clock cannot answer "since last Tuesday" - and it names the **weekday**, because a date on its own forces the model to compute one, which is how a follow-up meant for Tuesday lands on a Monday |

### Requirement by requirement

| # | Requirement | Status | Where the gap is, if there is one |
|---|---|---|---|
| 1 | Retrieve customer info | **Done, both halves** | The structured half is `get_customer_info`. The semantic half landed 2026-11-09: `0035` installed `search_similar_communications` and `embed_communications`, the agent's keeper fills `communications.embedding`, and `search_communications` reads it - so "find customers who complained about shipping last week" is a query, and acceptance case 38 is that sentence asked of a running process. Two properties are worth knowing before you rely on it. **A row is searchable after the next tick, not the moment it is written** - nothing embeds on write, because a trigger that called a model server would make every CRM write as available as a GPU three machines away; `vw_embedding_status.newest_embedded_at` is that gap as a number. And **an empty answer is two different facts**: the tool reads the register before it says "nothing matched", so "nothing is embedded yet" cannot be mistaken for "nobody complained", which is the failure mode this requirement would otherwise have shipped with. A keyword tool stays declined: `pg_trgm` is installed and `communications.summary` has no trigram index, so it would still be a sequential scan behind a call the agent makes constantly |
| 2 | Update customer info | Done, with one hole | `update_customer` changes name, contact points, address and `status`. It cannot change `entity_type`, so `prospect` - a documented member of that vocabulary - has no door. That is **T2** in `db/MIGRATIONS.md`, and `code:vw_customers_filter` is the marker that keeps it visible |
| 3 | Communication history | Done | Five most recent, per the requirement. The `vw_*` read is `security_invoker`, so what "recent" can show is what row security lets the caller see |
| 4 | Entity statistics | Done | `vw_entity_communication_stats`, and it counts what the `communications` table holds rather than what a session remembers |
| 5 | Log new interactions | Done through the door | `add_communication` (`0021`). Three things a caller-side `INSERT` could not promise: an ambiguous name is refused **with the candidates listed** rather than filed against whichever row the scan reached first; the six vocabularies are the CHECKs' own; and `thread_root_id` gets a writer, so a reply to a reply lands on the thread the first message started. **It creates no `followups` row** - that table has no writer anywhere in the schema, and 0021 §5 says so rather than deciding it here |
| 6 | Follow-up customers | Done, with two caveats stated by the tool | `0022` made the threshold real and made the third reason branch reachable at all; staleness is measured on the interaction, not on the row's write time. Caveats: results are unordered, and **the function returns no status column, so a blacklisted account appears in the follow-up list** - the tool says this in its own description, because a model that is not told will present the list as "customers to call" |
| 7 | Escalation | Detection only | Sentiment, `escalated` outcomes and `get_entity_stats` are all reachable. There is no CAO agent to route one to, so the format the requirement specifies has never been sent anywhere |
| 8 | Agent logging | Done | One row per run in `agent_interactions`, written by `pkg/logging` (Go) or `archive/blueprint/interaction_logger.py` (Python), with the per-call grain in `actions_taken` / `tool_observations` and `vw_tool_calls` to read it one call at a time. The requirement names `tool_logger.py`, and that file now accumulates in process memory and hands the run to the trajectory writer; it used to `CREATE TABLE` at runtime into a table that was never in the schema, which is why nothing noticed it was logging nothing |

### System Prompt Highlights
- Proactively offers to log communications when a user mentions real-world interactions.
- Uses tools only when needed (doesn't force tool calls).
- Explains errors plainly if tools fail, including the database's own refusal - a name that matches two
  customers is a question the agent should ask, not a guess it should make.
- Keeps responses friendly and concise.
- Never supplies `agent_id` or `bot_id`: those columns come from `AGENT_ROLE`, because an audit column a
  model can type is an audit column a caller can be asked to type.

### Deployment

- **Run:** `docker compose up --build -d` in `agents/customer_service/` (publishes `:4550`); `python bot.py` in `archive/blueprint/` runs the reference, which is not deployed on this server ([ADR-006](../../../ARCHITECTURE_DECISION_RECORDS/ADR-006_go_runtime_over_python_reference.md))
- **Model:** `LLM_PROVIDER=local` against an OpenAI-compatible endpoint (`VLLM_BASE_URL`), or `azure_gcc_high`
- **Database:** PostgreSQL at `AFPC_PG_HOST:AFPC_PG_PORT`, database `agent_first_erp_crm`, and every object in **`public`**. The environment table in `agents/customer_service/README.md` explains why the host has to be an IP address
- **Tenant:** `AFPC_TENANT_ID`, required. It is resolved once at startup and set on every pooled connection, so a per-request tenant is not something this process can be asked to fake
- **Telegram:** in the reference implementation only. The deployed agent has no transport but HTTP and SSE, and the loop does not care which is attached

## Testing Scenarios

1. **Happy Path:** User asks for customer info → Agent retrieves and displays → Success
2. **Communication Logging:** User mentions speaking to customer → Agent offers to log → User provides summary → Agent logs successfully
3. **Missing Customer:** User asks for non-existent customer → Agent reports "not found" gracefully
4. **Error Handling:** Database connection fails → Agent explains error without exposing internals

---

*This agent follows the pattern the blueprint first stated. Future agents fork the Go deployment — `architecture.md` 9.1 — not the Python reference ([ADR-006](../../../ARCHITECTURE_DECISION_RECORDS/ADR-006_go_runtime_over_python_reference.md)).*
