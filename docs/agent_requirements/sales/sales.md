# Sales & Procurement Agent Requirements

**Status: the deployed shape of this agent is `agents/sales/`.** This page was written before any Go
was, for the reason the inventory fork learned the expensive way: a requirements page that names tables
the migrations do not create produces an agent whose tools do not work. Every view and every door below
exists in `db/migrations/0027_suppliers.sql` through `0030_order_fulfilment.sql` and nowhere else, and
`scripts/docs/check_agent_docs.sh` fails the build when this page, the README, and `pkg/orders` stop
agreeing about the list.

## Core Identity

- **Role:** Raise, follow, and finish documents — customer orders, purchase orders to suppliers, and the
  commitments stock is held against. `AGENT_ROLE=sales`; that value is `agent_interactions.bot_id` on
  every row this process writes, conversational and scheduled alike, which is what separates its
  trajectory from customer_service's and inventory's when three agents share one database.
- **Shape:** A long-lived Go process running the same loop the other two run — chat over HTTP and SSE,
  the trajectory writer, the database memory store — **plus an in-container timer** that sweeps expired
  idempotency claims and reads the commitment reconciliation every hour
  (`ORDERS_HOUSEKEEPING_INTERVAL_MINUTES`, default 60). The timer exists because `0011`'s retention
  policy and `0030`'s reconciliation were both written with no keeper, and a policy nobody schedules is
  a promise that decays quietly. Building it also produced this programme's only migration that changes
  no row: `0011` had closed `idempotency_sweep` to the runtime role on the grounds that collection is an
  operator action, so the keeper's first tick reported a clean-looking zero beside a `42501`, and **0031**
  reopened the grant on a measurement of what that reach actually is. The requirement, stated as one
  sentence a later reader can test: **a policy needs a caller and a privilege, and the two live in
  different files.**
- **Database access:** reads over the `vw_*` views (`0003`'s ADR-003), writes only through the function
  doors (ADR-002). No file in `pkg/orders` composes an INSERT; `code:cs_writes_through_doors` watches
  that claim across all three backends.
- **What is genuinely new here, and what is not:** the *documents* are new — neither deployed agent can
  create one. The customer service agent can log that a customer asked for something; this one can make
  the thing they asked for exist, with lines, a delivery date, and a supplier on the other end.

## Functional Requirements

1. **Sales orders**
   - Create one for an existing customer (`create_order`, `order_type=SALES`), add lines by item or by
     description (`add_order_line`), and move it through **DRAFT → CONFIRMED → PICKING**
     (`transition_order`) — which is as far as a SALES order goes by hand. Its lifecycle has no
     SUBMITTED in it (that is a purchase order's word, and the door answers 23503 for the pair, not the
     status alone), and **SHIPPED is not writable at all**: `order_lifecycle.stock_moving` says SHIPPED
     is a consequence of stock leaving, and the database refuses a consequence typed in with 23514.
     `ship_sales_order` is what produces it, along with the ISSUE rows that make it true — and it
     produces PICKING instead when the lines are not all out yet, which is the door declining to
     describe a partial shipment as a complete one.
   - The item ids come from `vw_order_lines`' and `vw_item_availability`'s own item rows, or from the
     inventory agent. This agent's read tools do not carry an item master or a warehouse list, and the
     requirement that follows from that is stated as a rule rather than a wish: **every id a door takes
     has to be returnable by a read in the same process**, because a uuid nobody can read is a door
     nobody can walk through. Two of today's three violations of that were in Go (a projection that
     dropped `vw_orders.warehouse_id`, which stopped case 25 mid-turn) and one is in the schema
     (`reservation_id` appears in no view, so `cancel_inventory_reservation` is reachable only from
     psql). The first is fixed and pinned by `TestEveryDoorKeyIsReadableFromARead`; the second is a
     migration, and named in "What is not here" rather than left as a TODO.

2. **Purchase orders**
   - Create one against a **supplier** (`create_order`, `order_type=PURCHASE`, `vendor_id`), which is a
     party that `suppliers` says is a supplier (`0027`) — not an `entities.entity_type` value, because
     one column holds one value and a company that sells us steel and buys our spare parts is both.
   - Register the party if it is not there yet (`add_supplier`), and a line may be a **service**:
     `item_id` is nullable with a required `description` (`0028`), so "the plumber" is a real line and
     not an item called MISCELLANEOUS.
   - `receive_purchase_order` books what arrived: one RECEIPT movement per open line, naming the line,
     with that line's counter raised in the same statement. A partial delivery leaves the unfinished
     lines OPEN and moves the header back to SUBMITTED rather than to RECEIVED, because whether the rest
     is coming is a decision about the supplier and not a consequence of a pallet. A line with no item,
     or an item the master calls a SERVICE, is fulfilled with **no movement at all**, and the
     reconciliation view says so in words — `fulfilled without a movement (non-stock line)` — instead of
     counting it as a disagreement. PURCHASE is also the type with no CONFIRMED: DRAFT → SUBMITTED →
     RECEIVED.

3. **Commitments, and the thing that has never been able to release one**
   - `vw_order_commitments` answers "what is held for this document, per line, and does it agree with
     the ledger". It reports attributed and unattributed held stock in **separate columns**, because a
     commitment naming the order but no line is invisible to a join on the line, and "nothing held"
     beside "held, not attributed" is the one wrong pair of numbers in this domain that could be acted
     on.
   - `cancel_inventory_reservation` releases a commitment, wholly or partly. It exists because
     `reserve_inventory_for_order` has written commitments since `0015` and **nothing in the schema
     could undo one**: thirteen units on this server had been held forever against a document that named
     no row. Releasing is a stock fact and a document fact at once, which is why it sits with the agent
     that owns documents and not with the one that watches shelves.

4. **Reporting**
   - What is open, what is due, what is overdue: `vw_orders` with `required_date` and `is_terminal`, and
     `vw_order_lines` for the line-level answer. `vw_orders`' totals are summed from the lines in one
     grouped pass; no header total is stored, so no total can disagree with its rows.
   - Which lines' counters disagree with the ledger that moved them, and how much held stock no line
     can claim: `vw_order_commitments`' `ledger_agreement` and `quantity_committed_unlinked`. Those are
     the two questions a document model gets asked after it has been in service a month, and both are a
     SELECT. Which documents name a counterparty that does not exist is **not** one of them, and cannot
     be: `orders`' customer and vendor edges are composite foreign keys, so that state is
     unrepresentable rather than unfound — 0027's rule, measured before it was written. The scheduled tick writes a
     one-signature memory when the answer changes, the way the inventory check does, so "what changed
     overnight" is a read and not a re-scan.

## The Tool Surface (as registered)

| Tool | Door or view | Args that matter |
|------|--------------|------------------|
| `get_orders` | `vw_orders` | optional `order_type`, `status` or `open_only`, `customer_id`/`vendor_id`, `due_before`; bounded `limit` |
| `get_order_lines` | `vw_order_lines` | `order_id` or `order_number`; one line by `order_line_id` |
| `get_order_commitments` | `vw_order_commitments` | `order_id`, or `only_disagreements` to see the ledger disagree with a counter |
| `get_customers` | `vw_customers` | `name` (case-insensitive substring) or `customer_id`; the id `create_order` needs |
| `get_suppliers` | `vw_suppliers` | `name` or `supplier_code`; the id `create_order` needs for PURCHASE |
| `create_order` | `create_order(...)` | `order_type` ∈ {SALES, PURCHASE, WORK}, exactly one counterparty as the CHECK demands, `warehouse_id`, `required_date`, `priority`, `notes`; claim last |
| `add_order_line` | `add_order_line(...)` | `order_id`, `item_id` **or** `description`, `quantity`, `unit_price`, `line_type` ∈ {STANDARD, COMPONENT, PRODUCT}; claim last |
| `transition_order` | `transition_order(...)` | `order_id`, `to_status`, `reason`, `expected_version` for the lost-update guard; refuses stock-moving statuses; claim last |
| `add_supplier` | `add_supplier(...)` | `supplier_code` (upper-cased, unique per tenant), **either** `entity_id` **or** `name`, `payment_terms`, `lead_time_days`, `currency_code` — which defaults to `USD` because `entities` has no currency to inherit; claim last |
| `ship_sales_order` | `ship_sales_order(...)` | `order_id`, optional `warehouse_id` and `performed_by`; settles what the document already holds, then issues the rest; answers SHIPPED **or PICKING**; claim last |
| `receive_purchase_order` | `receive_purchase_order(...)` | `order_id`, optional `warehouse_id` and `performed_by`; one RECEIPT per open line, services fulfilled with none; answers RECEIVED **or SUBMITTED**; claim last |
| `cancel_inventory_reservation` | `cancel_inventory_reservation(...)` | `reservation_id`, optional partial `quantity`, `reason`, `cancelled_by`; claim last |

Six shared tools arrive with the fork: `current_time`, `search_web`, `scrape_url`,
`save_memory_tool`, `get_memory_tool`, `list_memories_tool` — the same code, in the same
`pkg/tools`/`pkg/memory` packages, as the other two agents.

**Eighteen registered tools, twelve of them this agent's own.** That is wider than the customer service
agent's fourteen and it is a decision rather than an accident: five reads and seven doors, because a
document has three registered doors that finish it — ship, receive, release — and each answers a
different question about the world. The fourth door the schema has, `book_work_order_production`, is
deliberately not among them, and *What is not here* says why. The alternative to this table — one
`complete_order` tool that branches on `order_type` in Go — would move the schema's discrimination rule
out of `order_lifecycle` and into a process, which is ADR-002's named failure, and the model would have
to guess which branch it was in.

## Non-Functional Requirements

- **Reliability:** the timer catches panics and still lands a trajectory row, because a scheduled run
  that dies silently is indistinguishable from one that never ran, and `vw_failed_interactions` is the
  only thing that can tell them apart afterwards.
- **Efficiency:** every read is a view the schema defines over indexed columns. The orders tables are
  new, so their indexes are `0028`'s and not `0006`'s — `(tenant_id, status)`, `(tenant_id,
  customer_id)`, `(tenant_id, vendor_id)`, `(order_id, line_number)`. "Every open order" is the query
  those were built for; a tenant-wide `ILIKE` over `notes` is not, and no tool offers it.
- **Safety:** seven of the twelve tools can write, which is more than either deployed agent allows
  itself, and three of them touch stock — two write ledger movements and the third changes what is
  reserved while moving nothing. `REQUIRE_WRITE_APPROVAL=true` is therefore worth running this
  agent with: the gate is caller-side and the doors do not care, so a deployment that turns it on
  changes nothing in the schema and everything in what reaches it. `transition_order`'s
  `expected_version` is the other half — an agent that read an order and then changed its status is
  asserting that nothing changed in between, and a stale read is answered with **40001**, the
  serialization-failure class, chosen by the door because the right response is to re-read and go
  again rather than to fix an argument.
- **Scalability:** one header and one detail table for three document types, which is the shape
  `inventory_reservations.order_id` *requires* (a three-way OR across three tables cannot be a foreign
  key), and a lifecycle register that a tenant could later be given its own copy of without editing
  Go. The partitioning question is `0024`'s and it is the same one the append-only tables already owe.

## Validation rules

- **Argument shapes** are refused in `pkg/orders` (`uuidArg`, `id64`, `numericArg`, `dateArg`) before a
  call, and **domain rules** are refused by the doors with their own SQLSTATEs. These codes were
  measured on this server, in one rolled-back transaction, rather than guessed from the constraint
  names - because a page that guesses at them teaches the wrong recovery. A malformed uuid is refused by
  the tool and never reaches SQL; an unknown `order_type` answers **23502** on
  `document_counters.doc_type` - loud, and before anything is written, because `create_order` maps the
  type to its number prefix by CASE and lets the counter table's own key refuse what is outside the
  mapping, which is the one refusal here that names a table instead of the caller's argument, and is
  filed in `db/MIGRATIONS.md`; a SALES order naming a vendor is `orders_counterparty_matches_type`
  (**23514**); a status whose type never had it is `0028`'s composite edge into `order_lifecycle`
  (**23503**); a stock-moving status is **23514**; a stale `expected_version` is **40001**; and a
  commitment against a document that does not exist is `0030`'s trigger. Each arrives with the door's
  own words and the tool passes them through: the refusals are written for whoever reads them next,
  which is the same rule `agents/inventory` documents.
- **Nothing is inferred from absence.** `quantity_committed_unlinked` is not `quantity_committed`;
  `ledger_agreement` says `nothing moved yet` rather than `agrees` when neither side has a row, and
  `fulfilled without a movement (non-stock line)` rather than a 0 that could be read as missing;
  `hours_variance` is NULL when the work was never estimated rather than 0 because the estimate was
  zero; and `vw_orders.line_count` reads 0 because it is a `coalesce`d aggregate over a document that
  genuinely has no lines — which is the one place in this surface where 0 is the truth and not an
  inference, and the reason it is stated rather than assumed. Every one of those is a different
  sentence, and four of the five would read as good news if the tool averaged them.

## Error handling

- A door that refuses answers as a row with `success=false` and a message; a door that fails answers as
  an error carrying its SQLSTATE. The distinction is `0014`/`0015`/`0016`'s, and this agent's tools keep
  it: no `WHEN OTHERS` becomes a friendly string.
- A refused write leaves its claim re-takeable (ADR-005, proven by `0016`'s two-backend measurement), so
  retrying an identical call after fixing the *world* is correct, and retrying after changing nothing
  is answered from the first attempt — which is why "do not retry a precise answer" is in the system
  prompt and not only here.
- Database unreachable at startup: the same bounded grace window as the other two, `/api/health` saying
  which mode it came up in, and the timer not armed — with a warning that names the reason, because a
  housekeeping schedule that stopped with the connection is the kind of thing that must not look fine.

## What is not here yet

- **Work orders' plan and production.** `0029` built `work_centres`, `work_order_operations`,
  `plan_work_order_operation`, and `book_work_order_production` is `0030`'s; **none is registered as a
  tool.** A work order can be *created* here (`create_order(order_type=WORK)` with COMPONENT and
  PRODUCT lines), and `0030`'s backfill depends on that being possible, but planning operations onto
  centres and booking production are a manufacturing agent's surface: they need routings, which
  `0029` §7 deliberately did not invent, and a tool that can book output without a routing is a tool
  that will be described as live before it is true.
- **`add_work_centre`.** Same reason, one level down. Centres are created by hand or by a seed today.
- **Invoicing, prices, and anything that touches money owed.** There is no `invoices` table, and
  `vw_orders`' totals are what a document is *worth*, not what has been billed. A tool that implied the
  second from the first would be a second truth.
- **Auto-replenishment.** `vw_low_stock_alerts` and `vw_suppliers.lead_time_days` are enough to *compute*
  a purchase order and nothing here does it: an agent that raises orders on a timer is a decision about
  who funds them, and the timer this agent has files rows, it does not place orders.
- **Semantic search.** The pgvector indexes exist (`0012`) and no embedder in this deployment fills
  them; `get_orders`' filters are the indexed columns above, and `notes` is not one of them.
- **Telegram, and any push transport.** Alerts land in `agent_interactions` and `agent_memories`.

## Decided later (open questions, tracked here so they are not lost)

- Whether `cancel_inventory_reservation` should also be registered on the inventory agent. It is a
  shelf fact and a document fact; today it is reachable from one seat, and the second seat is a
  duplication decision rather than a plumbing one.
- Whether the hourly tick should *also* call `audit_chain_verify()` and `vw_rls_status`' verdicts — the
  checks exist, are fast, and nothing schedules them. Filed with `T3`'s family: assertions that need a
  process, not a migration.
- Whether a `RESERVATION_BACKFILL` order — a document `0030` raised to explain stock that was already
  committed — should be visible to `get_orders` by default or only when asked for by name. It is filed
  here rather than decided silently: today it is visible, because hiding a fact from the read path is
  how a reconciliation stops matching the count of rows someone else can query.
