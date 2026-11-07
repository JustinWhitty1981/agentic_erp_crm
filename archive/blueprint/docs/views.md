# Database Views Reference

**Purpose:** Simplified query interfaces for agents and developers.

**Definitions:** `db/migrations/0001_baseline_canonical_port.sql`, widened by `0009` (tenancy),
`0017` (the interaction read path) and `0018` (currency). **Not**
`scripts/database/08_create_views.sql`, which `db/README.md` lists among the superseded copies - this
page named that file as the location for long enough that two of its view lists described a schema no
migration creates.

> **The column lists below are read from `pg_attribute`, in declared order, and a check re-runs that
> claim.** They used to be prose that someone had copied from the SQL: `vw_agent_activity_summary` was
> listed with `bot_id`, a column it never had, and without `unique_contacts`, `escalated_count` or
> `first_activity`, three it always did; every tenant view was missing the `tenant_id` 0009 gave it.
> That is T4's class, and `scripts/docs/check_agent_docs.sh` - the script behind
> `code:agent_docs_match_surface` - now compares all seventeen lists against the catalog, so the page
> cannot rot into a description of a database that is not there. Read the column list as authority and
> the prose above each one as intent; where they disagree, the check is wrong or the migration is, and
> either is a bug worth reporting.
>
> The definitions themselves remain in SQL. This page is not where a view is authored: `CREATE OR
> REPLACE VIEW` belongs in a numbered migration, and a change made only here is the same mistake in
> the other direction.

> **Changed by `db/migrations/0009_rls_enforcement.sql`, in three ways.** (1) Every view over a tenant
> table exposes `tenant_id` as its last column, which the lists now carry. (2) The four aggregate views
> (`vw_agent_activity_summary`, `vw_entity_communication_stats`, `vw_inventory_valuation`,
> `vw_item_movement_summary`) also group by it, because grouping without it adds two tenants' numbers
> together. (3) They are all `security_invoker` now, which is what makes row-level security apply to a
> query that goes through a view; an agent sees one tenant and the audit account sees all of them,
> which is the reason for (1).


## Overview

Views provide simplified, agent-friendly interfaces to complex database queries. They encapsulate joins, aggregations, and business logic into single-query interfaces.

---

## Customer-Facing Views

### vw_customers

Backward compatibility view mapping entities/contacts to legacy customer format.

```sql
SELECT * FROM vw_customers;
```

**Columns:** (in declared order, read from `pg_attribute`. T4's sweep regenerated every
list on this page: the ones it replaced had been written against the superseded SQL, and were wrong
in both directions - names the view never had, and columns 0009 added to every tenant view. `code:agent_docs_match_surface` re-checks them against the catalog, so this cannot quietly rot again)
- `id` - Entity ID
- `name` - Entity name
- `email` - Primary contact email
- `phone` - Primary contact phone
- `address` - Primary address
- `status` - Entity status
- `created_at` - Creation timestamp
- `updated_at` - Last update timestamp
- `tenant_id` - Whose row this is. Every tenant-coded view exposes it last (0009), which is what makes an agent's and an auditor's result sets differ without two views

**Use Case:** Legacy code compatibility

---

### vw_customer_communications_summary

All communications for customers with full context.

```sql
SELECT * FROM vw_customer_communications_summary;
```

**Columns:** (in declared order, read from `pg_attribute`. T4's sweep regenerated every
list on this page: the ones it replaced had been written against the superseded SQL, and were wrong
in both directions - names the view never had, and columns 0009 added to every tenant view. `code:agent_docs_match_surface` re-checks them against the catalog, so this cannot quietly rot again)
- `id` - The view's own key, carried from the underlying row
- `started_at` - When communication started
- `entity_id` - Customer entity ID
- `entity_name` - Customer name
- `entity_type` - Type (customer/vendor/prospect)
- `entity_status` - The customer's own status
- `contact_id` - Contact ID
- `contact_name` - Full contact name
- `contact_title` - The person's title, from `contacts`
- `communication_type` - Type of communication
- `direction` - Inbound/outbound/internal
- `subject` - Communication subject
- `summary` - AI-generated summary
- `channel` - How the interaction arrived, where the table distinguishes it from the type
- `duration_seconds` - How long the interaction took, in seconds
- `outcome` - Resolution status
- `priority` - Priority level
- `sentiment_score` - The numeric sentiment, where one was recorded
- `sentiment_label` - Positive/neutral/negative
- `follow_up_required` - Requires follow-up?
- `follow_up_date` - Follow-up date
- `agent_id` - Which agent recorded the row; `agent_interactions.bot_id` is the same idea on the trajectory side, and this view groups by `agent_id` because that is the column `communications` has
- `human_agent_id` - The person who handled it, when a person did
- `parent_id` - The message this one answers
- `thread_root_id` - The first message of the thread this reply belongs to
- `tenant_id` - Whose row this is. Every tenant-coded view exposes it last (0009), which is what makes an agent's and an auditor's result sets differ without two views

**Use Case:** Agent queries, customer service dashboards

---

### vw_recent_communications

Last 7 days of all communications.

```sql
SELECT * FROM vw_recent_communications;
```

**Columns:** (in declared order, read from `pg_attribute`. T4's sweep regenerated every
list on this page: the ones it replaced had been written against the superseded SQL, and were wrong
in both directions - names the view never had, and columns 0009 added to every tenant view. `code:agent_docs_match_surface` re-checks them against the catalog, so this cannot quietly rot again)
- `id` - The view's own key, carried from the underlying row
- `started_at` - Timestamp
- `entity_id` - The `entities` row this is about
- `entity_name` - Entity name
- `entity_type` - customer or prospect; the CHECK is the list
- `contact_name` - Contact name
- `contact_title` - The person's title, from `contacts`
- `communication_type` - Type of communication
- `direction` - inbound, outbound or internal
- `subject` - Subject line
- `summary` - Summary
- `outcome` - Resolution status
- `priority` - How soon this matters, from the column's own vocabulary
- `agent_id` - Which agent recorded the row; `agent_interactions.bot_id` is the same idea on the trajectory side, and this view groups by `agent_id` because that is the column `communications` has
- `tenant_id` - Whose row this is. Every tenant-coded view exposes it last (0009), which is what makes an agent's and an auditor's result sets differ without two views

**Use Case:** Activity feeds, monitoring

---

### vw_pending_followups

All communications requiring follow-up.

```sql
SELECT * FROM vw_pending_followups;
```

**Columns:** (in declared order, read from `pg_attribute`. T4's sweep regenerated every
list on this page: the ones it replaced had been written against the superseded SQL, and were wrong
in both directions - names the view never had, and columns 0009 added to every tenant view. `code:agent_docs_match_surface` re-checks them against the catalog, so this cannot quietly rot again)
- `id` - The view's own key, carried from the underlying row
- `entity_id` - The `entities` row this is about
- `contact_id` - The `contacts` row this is about, or NULL when no person was named
- `description` - What is owed
- `due_date` - When the follow-up is owed
- `priority` - Priority level
- `status` - The row's status, from that table's own vocabulary - `vw_domain_vocabulary` lists it
- `completed_at` - When it was done
- `completion_notes` - Notes left at completion
- `created_at` - When the row was written, which is not the same fact and 0022 is the finding that says so
- `updated_at` - When the row last changed, if the table keeps one - `vw_timestamp_status` says which do
- `entity_name` - Customer name
- `contact_name` - Contact name
- `tenant_id` - Whose row this is. Every tenant-coded view exposes it last (0009), which is what makes an agent's and an auditor's result sets differ without two views

**Use Case:** Task lists, agent action items

---

### vw_entity_communication_stats

Aggregated communication metrics per entity.

```sql
SELECT * FROM vw_entity_communication_stats;
```

**Columns:** (in declared order, read from `pg_attribute`. T4's sweep regenerated every
list on this page: the ones it replaced had been written against the superseded SQL, and were wrong
in both directions - names the view never had, and columns 0009 added to every tenant view. `code:agent_docs_match_surface` re-checks them against the catalog, so this cannot quietly rot again)
- `entity_id` - Entity ID
- `entity_name` - Entity name
- `entity_type` - Entity type
- `status` - The row's status, from that table's own vocabulary - `vw_domain_vocabulary` lists it
- `total_communications` - Total count
- `resolved_count` - Resolved count
- `escalated_count` - Escalated count
- `pending_count` - Interactions still pending
- `positive_count` - Interactions labelled positive
- `negative_count` - Interactions labelled negative
- `avg_sentiment` - Average sentiment score
- `last_contact_date` - Most recent contact
- `first_contact_date` - The oldest interaction
- `avg_duration_seconds` - Mean interaction length
- `tenant_id` - Whose row this is. Every tenant-coded view exposes it last (0009), which is what makes an agent's and an auditor's result sets differ without two views

**Use Case:** Customer health scores, engagement metrics

---

### vw_primary_contact_communications

Communications only with primary contacts.

```sql
SELECT * FROM vw_primary_contact_communications;
```

**Columns:** (in declared order, read from `pg_attribute`. T4's sweep regenerated every
list on this page: the ones it replaced had been written against the superseded SQL, and were wrong
in both directions - names the view never had, and columns 0009 added to every tenant view. `code:agent_docs_match_surface` re-checks them against the catalog, so this cannot quietly rot again)
- `id` - The view's own key, carried from the underlying row
- `started_at` - Timestamp
- `entity_id` - The `entities` row this is about
- `entity_name` - Entity name
- `entity_type` - customer or prospect; the CHECK is the list
- `contact_id` - The `contacts` row this is about, or NULL when no person was named
- `primary_contact` - Primary contact name
- `contact_title` - Contact title
- `communication_type` - Type
- `direction` - inbound, outbound or internal
- `subject` - Subject
- `summary` - Summary
- `outcome` - Outcome
- `priority` - How soon this matters, from the column's own vocabulary
- `agent_id` - Which agent recorded the row; `agent_interactions.bot_id` is the same idea on the trajectory side, and this view groups by `agent_id` because that is the column `communications` has
- `tenant_id` - Whose row this is. Every tenant-coded view exposes it last (0009), which is what makes an agent's and an auditor's result sets differ without two views

**Use Case:** Executive-level interaction tracking

---

### vw_communication_thread

Shows communication threading hierarchy.

```sql
SELECT * FROM vw_communication_thread;
```

**Columns:** (in declared order, read from `pg_attribute`. T4's sweep regenerated every
list on this page: the ones it replaced had been written against the superseded SQL, and were wrong
in both directions - names the view never had, and columns 0009 added to every tenant view. `code:agent_docs_match_surface` re-checks them against the catalog, so this cannot quietly rot again)
- `id` - The view's own key, carried from the underlying row
- `parent_id` - Parent communication ID
- `thread_root_id` - Root of conversation thread
- `started_at` - Timestamp
- `entity_name` - Entity name
- `contact_name` - Contact name
- `communication_type` - Type
- `subject` - The line a human would recognise as what it was about
- `summary` - What happened, in the space the schema budgets for it
- `outcome` - How the interaction ended, from the CHECKed list in `vw_domain_vocabulary`
- `tenant_id` - Whose row this is. Every tenant-coded view exposes it last (0009), which is what makes an agent's and an auditor's result sets differ without two views

**Use Case:** Reconstructing conversation flows

---

## Agent Activity Views

### vw_agent_activity_summary

Summary of activity per bot agent.

```sql
SELECT * FROM vw_agent_activity_summary;
```

**Columns:** (in declared order, read from `pg_attribute`. T4's sweep regenerated every
list on this page: the ones it replaced had been written against the superseded SQL, and were wrong
in both directions - names the view never had, and columns 0009 added to every tenant view. `code:agent_docs_match_surface` re-checks them against the catalog, so this cannot quietly rot again)
- `agent_id` - Which agent recorded the row; `agent_interactions.bot_id` is the same idea on the trajectory side, and this view groups by `agent_id` because that is the column `communications` has
- `total_actions` - Total actions performed
- `unique_entities` - Unique entities served
- `unique_contacts` - How many people, which is not the same count
- `resolved_count` - Resolved communications
- `escalated_count` - Interactions escalated to someone
- `avg_sentiment` - Average sentiment
- `last_activity` - Last activity timestamp
- `first_activity` - The earliest row this agent wrote
- `tenant_id` - Whose row this is. Every tenant-coded view exposes it last (0009), which is what makes an agent's and an auditor's result sets differ without two views

**Use Case:** Performance monitoring, workload balancing

---

### vw_recent_interactions

Every interaction the caller's row security reaches, newest first **if the caller says `ORDER BY "timestamp" DESC`**. This page promised "last 100"; a `LIMIT` inside a view runs before the caller's filter, so 0017 leaves the 100 to the caller - `ORDER BY "timestamp" DESC LIMIT 100`.

```sql
SELECT * FROM vw_recent_interactions;
```

**Columns:** (in declared order, read from `pg_attribute`. T4's sweep regenerated every
list on this page: the ones it replaced had been written against the superseded SQL, and were wrong
in both directions - names the view never had, and columns 0009 added to every tenant view. `code:agent_docs_match_surface` re-checks them against the catalog, so this cannot quietly rot again)
- `tenant_id` - Which tenant's run this is
- `interaction_id` - The `agent_interactions` primary key
- `timestamp` - When the run happened
- `conversation_id` - Conversation the run belongs to
- `run_id` - Caller-supplied run identifier
- `telegram_chat_id` - Chat the input arrived from, if any
- `user_id` - Who the code believed was talking
- `bot_id` - Which agent ran
- `human_input` - The raw message
- `intent_classification` - What the router thought it was
- `final_output` - What was sent back
- `error_message` - Set when the run failed
- `duration_ms` - Whole-run duration
- `step_count` - How many tool calls the run made, without expanding the payload

**Use Case:** Debugging and reviewing agent behaviour. The trajectory itself is in `vw_tool_calls`.

---

### vw_failed_interactions

Runs that ended with an `error_message`. That column is **run-level**, so this answers "which runs failed", never "which tool failed" - see `vw_tool_calls`.

```sql
SELECT * FROM vw_failed_interactions;
```

**Columns:** (in declared order, read from `pg_attribute`. T4's sweep regenerated every
list on this page: the ones it replaced had been written against the superseded SQL, and were wrong
in both directions - names the view never had, and columns 0009 added to every tenant view. `code:agent_docs_match_surface` re-checks them against the catalog, so this cannot quietly rot again)
- `tenant_id` - Which tenant's run this is
- `interaction_id` - The `agent_interactions` primary key
- `timestamp` - When it failed
- `conversation_id` - Conversation
- `run_id` - Run identifier
- `telegram_chat_id` - Chat, if any
- `user_id` - Who was talking
- `bot_id` - Which agent
- `model_used` - Which model answered
- `human_input` - The raw message
- `actions_taken` - The full step array - this view projects it, the listing one does not
- `error_message` - What the run reported
- `duration_ms` - How long it took to fail

**Use Case:** Identifying and fixing agent issues.

---

### vw_tool_calls

One row per tool invocation, derived from `agent_interactions` by position: step *n* of `actions_taken` paired with step *n* of `tool_observations`. This is the grain a table named `agent_tool_calls` would have stored, and 0017 decided to derive it rather than keep a second log of the same calls.

```sql
SELECT * FROM vw_tool_calls;
```

**Columns:** (in declared order, read from `pg_attribute`. T4's sweep regenerated every
list on this page: the ones it replaced had been written against the superseded SQL, and were wrong
in both directions - names the view never had, and columns 0009 added to every tenant view. `code:agent_docs_match_surface` re-checks them against the catalog, so this cannot quietly rot again)
- `tenant_id` - Whose call this was
- `interaction_id` - The run the call belongs to
- `conversation_id` - Conversation
- `run_id` - Run identifier
- `bot_id` - Which agent made the call
- `interaction_at` - When the run happened
- `step_number` - 1-based position in the run
- `tool_name` - The tool called
- `tool_input` - What was passed, as JSONB
- `action_at` - The step's own timestamp, as the logger wrote it
- `observation` - The tool's output *value*, or NULL where the arrays do not line up - a scalar output reads with `#>> '{}'`
- `observation_type` - Python class name of the output - `str` for a result and for an error
- `observations_aligned` - Whether the two arrays in that run had the same length
- `run_errored` - Did the run report an error - a run fact, worn by every one of its calls
- `run_duration_ms` - The run's duration, not this call's latency

**Use Case:** Reconstructing exactly what an agent did, in order, without a second audit table.

---

### vw_tool_performance

Per tool, per tenant: calls, runs, the mean duration of the runs that used it, and how many of those runs errored. Counts are at the call grain, timings and errors at the run grain - the version in `archive/blueprint/11_interaction_logging.sql` mixed them, and `db/migrations/0017_interaction_readpath.sql` carries the two numbers it changed.

```sql
SELECT * FROM vw_tool_performance;
```

**Columns:** (in declared order, read from `pg_attribute`. T4's sweep regenerated every
list on this page: the ones it replaced had been written against the superseded SQL, and were wrong
in both directions - names the view never had, and columns 0009 added to every tenant view. `code:agent_docs_match_surface` re-checks them against the catalog, so this cannot quietly rot again)
- `tenant_id` - Aggregate key - without it two tenants' usage adds together
- `tool_name` - The tool
- `call_count` - Invocations in this tenant
- `run_count` - Runs that used it at least once
- `mean_run_duration_ms` - Mean duration of those runs - a run time, not a tool latency
- `errored_run_count` - How many of those runs ended in an error (anywhere in them)
- `errored_run_pct` - That share, as a percentage

**Use Case:** Optimizing tool performance and identifying problematic tools.

---

## Inventory Views

### vw_inventory_valuation

Inventory value by warehouse and category, **per currency**.

```sql
SELECT warehouse_name, category_name, currency_code, sum(total_value) AS value
  FROM vw_inventory_valuation
 GROUP BY 1, 2, 3
 ORDER BY 1, 2, 3;
```

**Columns:** (in declared order, read from `pg_attribute`. T4's sweep regenerated every
list on this page: the ones it replaced had been written against the superseded SQL, and were wrong
in both directions - names the view never had, and columns 0009 added to every tenant view. `code:agent_docs_match_surface` re-checks them against the catalog, so this cannot quietly rot again)
- `warehouse_id` - The `warehouses` row this is about
- `warehouse_name` - The warehouse's name
- `warehouse_type` - What the warehouse is for
- `category_id` - The `item_categories` row this is about
- `category_name` - The category's name
- `unique_items` - How many distinct items the group holds
- `total_units` - How many of this item, across the group
- `total_value` - Units times cost, summed within the group and no further
- `available_value` - The value of what could actually be shipped
- `currency_code` - What the numbers on this row are in. Nothing converts (0018)
- `tenant_id` - Whose row this is. Every tenant-coded view exposes it last (0009), which is what makes an agent's and an auditor's result sets differ without two views

- `warehouse_id` - Which warehouse
- `warehouse_name` - Its name
- `warehouse_type` - PRIMARY / SECONDARY / TRANSIT
- `category_id` - Which item category, NULL for uncategorised items
- `category_name` - Its name
- `unique_items` - Distinct items counted in this group
- `total_units` - Quantity on hand
- `total_value` - On-hand value at average cost
- `available_value` - Value of what is not reserved
- `currency_code` - **Added by 0018, and the reason the three numbers above changed grain.** An item's

  balances are in the item's currency; a warehouse holds many items, so summing `quantity * cost`
  across a USD item and a JPY item is dollars plus yen. Grouping by it is 0009's argument about
  `tenant_id` applied to the other axis of the same SELECT list. Nothing converts: there is no
  tenant base currency and no rule for which rate applies to an averaged cost, so a total across
  currencies is not available from here and that is a decision, not an omission.
- `tenant_id` - Aggregate key from 0009

**Use Case:** Financial reporting, per currency

---

### vw_currency_rates

The rate in force for each currency pair the schema has ever held one for.

```sql
SELECT from_currency, to_currency, rate_in_force, in_force
  FROM vw_currency_rates
 WHERE from_currency = 'JPY';
```

**Columns:** (in declared order, read from `pg_attribute`. T4's sweep regenerated every
list on this page: the ones it replaced had been written against the superseded SQL, and were wrong
in both directions - names the view never had, and columns 0009 added to every tenant view. `code:agent_docs_match_surface` re-checks them against the catalog, so this cannot quietly rot again)
- `from_currency` - Left side of the pair
- `to_currency` - Right side. Both come from `currency_rates`, so a pair nobody has quoted is absent
- `rate_in_force` - The number to multiply by, or NULL when no row is in force
- `valid_from` - When this row's authority starts
- `valid_to` - And ends; NULL means still in force
- `source` - Where the quote came from
- `in_force` - Whether a row covers the instant the view was asked at
- `rows_for_pair` - How many rows the pair has ever had, so *expired* and *never quoted* read differently
- `as_of` - The instant the view measured at - a `now()` in a view answers a different question on every scan, so it is named

**Use Case:** Asking whether a conversion is even possible. Nothing in the schema reads this view
to price anything - `vw_inventory_valuation` is grouped by currency instead of translated - so it is
a record with a status, not an input to arithmetic yet.

---

### vw_item_availability

Stock levels across warehouses.

```sql
SELECT * FROM vw_item_availability;
```

**Columns:** (in declared order, read from `pg_attribute`. T4's sweep regenerated every
list on this page: the ones it replaced had been written against the superseded SQL, and were wrong
in both directions - names the view never had, and columns 0009 added to every tenant view. `code:agent_docs_match_surface` re-checks them against the catalog, so this cannot quietly rot again)
- `item_id` - The `inventory_items` row this is about
- `sku` - Item SKU
- `name` - The entity's or item's own name column
- `base_unit_of_measure` - What the quantity means, from `units_of_measure`
- `category_id` - The `item_categories` row this is about
- `category_name` - The category's name
- `warehouse_id` - The `warehouses` row this is about
- `warehouse_name` - Warehouse name
- `warehouse_code` - The warehouse's code
- `location_id` - The `locations` row this is about
- `location_code` - The bin's code
- `quantity_on_hand` - Total quantity
- `quantity_available` - Available quantity
- `quantity_reserved` - What is committed and still on the shelf
- `quantity_in_transit` - Expected, not arrived
- `reorder_point` - Below this, the item is on the list
- `safety_stock` - The buffer the reorder arithmetic keeps
- `lead_time_days` - How long a replenishment takes, per supplier
- `is_serialized` - Whether the item is tracked by serial number
- `is_lot_controlled` - Whether the item is tracked by lot
- `expiry_date` - When a tracked lot stops being good
- `average_cost` - The item's cost as this balance carries it, in `cost_currency`
- `cost_currency` - Which currency `average_cost` is in
- `stock_status` - NORMAL/LOW_STOCK/CRITICAL/OUT_OF_STOCK
- `needs_reorder` - Whether the level is at or below the reorder point
- `tenant_id` - Whose row this is. Every tenant-coded view exposes it last (0009), which is what makes an agent's and an auditor's result sets differ without two views

**Use Case:** Checking item availability

---

### vw_item_movement_summary

30-day movement patterns, grouped by item, day, and movement type.

```sql
SELECT * FROM vw_item_movement_summary;
```

**Columns:** (in declared order, read from `pg_attribute`. T4's sweep regenerated every
list on this page: the ones it replaced had been written against the superseded SQL, and were wrong
in both directions - names the view never had, and columns 0009 added to every tenant view. `code:agent_docs_match_surface` re-checks them against the catalog, so this cannot quietly rot again)
- `item_id` - The `inventory_items` row this is about
- `movement_date` - The day the movements happened
- `movement_type` - RECEIPT, ISSUE, TRANSFER, ADJUSTMENT, RETURN or RESERVATION
- `net_quantity` - What the stock level moved by, reservations included
- `movement_count` - How many ledger rows the window holds
- `avg_unit_cost` - Mean cost per unit over the window
- `total_inbound` - Receipts in the window, reservations excluded - a commitment makes stock unavailable, it moves nothing (0014 made the reservation a commitment rather than a movement, and the view's own COMMENT says which rows its totals count)
- `total_outbound` - Issues in the window, reservations excluded, for the same reason
- `tenant_id` - Whose row this is. Every tenant-coded view exposes it last (0009), which is what makes an agent's and an auditor's result sets differ without two views

- `item_id` - The item the movements are for
- `movement_date` - Day, truncated
- `movement_type` - `RECEIPT` / `ISSUE` / `TRANSFER` / `ADJUSTMENT` / `RESERVATION` / `RETURN`
- `net_quantity` - Signed total of every movement in the group
- `movement_count` - Rows in the group
- `avg_unit_cost` - Mean unit cost across those rows
- `total_inbound` - Sum of positive quantities; **excludes `RESERVATION`**
- `total_outbound` - Sum of absolute negative quantities; **excludes `RESERVATION`**
- `tenant_id` - Which tenant's movements these are (grouped, so two tenants never share a row)

**Use Case:** Analyzing item movement. A reservation commits stock without moving it, so it
counts in `net_quantity` and in neither of the two direction columns - see
`db/migrations/0015_reservation_locking.sql` for why that is the honest split.

---

### vw_low_stock_alerts

Items below reorder point.

```sql
SELECT * FROM vw_low_stock_alerts;
```

**Columns:** (in declared order, read from `pg_attribute`. T4's sweep regenerated every
list on this page: the ones it replaced had been written against the superseded SQL, and were wrong
in both directions - names the view never had, and columns 0009 added to every tenant view. `code:agent_docs_match_surface` re-checks them against the catalog, so this cannot quietly rot again)
- `item_id` - The `inventory_items` row this is about
- `sku` - Item SKU
- `name` - The entity's or item's own name column
- `reorder_point` - Reorder threshold
- `safety_stock` - The buffer the reorder arithmetic keeps
- `lead_time_days` - How long a replenishment takes, per supplier
- `category_id` - The `item_categories` row this is about
- `category_name` - The category's name
- `warehouse_id` - The `warehouses` row this is about
- `warehouse_name` - Warehouse name
- `quantity_on_hand` - What the count says is there
- `quantity_available` - Available quantity
- `quantity_in_transit` - Expected, not arrived
- `total_available` - Available across every row the group covers
- `alert_level` - The same comparison, named for the alert rather than for the shelf
- `stock_percentage` - How far the level is from full, as a number the UI can bar
- `tenant_id` - Whose row this is. Every tenant-coded view exposes it last (0009), which is what makes an agent's and an auditor's result sets differ without two views

**Use Case:** Replenishment tasks

---

### vw_orders

One row per document, of any of the three types, with its counterparty resolved and its totals summed from its lines.

```sql
SELECT order_number, order_type, status, customer_name, open_amount
  FROM vw_orders
 WHERE NOT is_terminal
 ORDER BY priority DESC, required_date;
```

**Columns:** (in declared order, read from `pg_attribute`, like every other list on this page;
`code:agent_docs_match_surface` re-checks them, so a rename fails here rather than in production)
- `tenant_id` - Whose row this is. Every tenant-coded view exposes it last (0009), which is what makes an agent's and an auditor's result sets differ without two views
- `order_id` - The `orders` primary key. `inventory_reservations.order_id` names this value for the document a commitment is held against, and `inventory_movements.reference_id` names it for the document a movement was made on behalf of - which is the whole reason the three document types share one header table
- `order_type` - SALES, PURCHASE or WORK - the three the business names, and the axis that decides which counterparty column may be filled, what a line's `line_type` is allowed to say, and which direction stock moves. It is half of the key into `order_lifecycle`, so the status beside it is legal for THIS type only
- `order_number` - The document's own number: SO-, PO- or WO- plus a per-type counter, unique per tenant, and issued by `create_order` rather than composed by a caller. The two words mean different things on two of the types - see the table's COMMENT
- `status` - Where the document is, in its type's lifecycle. The (type, status) pair is a key into the GLOBAL `order_lifecycle` rather than a two-column CHECK, which is what lets `vw_domain_vocabulary` see the constraint at all (`cardinality(conkey)=1`)
- `origin` - MANUAL, IMPORT, or RESERVATION_BACKFILL - the last one marks a document 0030 raised to explain stock that was already committed, and it is the only way a SALES order may have no customer
- `lifecycle_position` - The status's place in its type's lifecycle, joined from `order_lifecycle`. NULL means the installed register has no row for this (type, status) pair, which probe C counts
- `is_terminal` - Whether this status is a lifecycle's last word, so a forward-only rule can be stated without listing statuses in code
- `reports_a_movement` - True when this status is a consequence of stock moving (SHIPPED, RECEIVED, COMPLETED). `transition_order` refuses to write one by hand, which is the column's whole purpose
- `customer_id` - The `entities` row on the buying end. NULL on a purchase or work order, and required on a sales order that was not backfilled
- `customer_name` - That party's name, joined from `entities`
- `vendor_id` - The `suppliers` row on the selling end, which is not the same kind of key as `customer_id` - one is a party id, the other a supplier row id, and the CHECK makes them mutually exclusive
- `vendor_code` - The supplier's own code
- `vendor_name` - The supplier's party name, resolved through `suppliers.entity_id`
- `warehouse_id` - The document's default warehouse: a line that names none is issued out of or received into this one, which is why the fulfilment doors take an optional override. The edge carries `tenant_id` in the key, like every edge 0027 onward added
- `warehouse_name` - That warehouse's name, joined
- `currency_code` - The currency every line price on this document is in, an FK to `currencies`. Per-document rather than per-line because a mixed-currency order needs FX and nothing here does it (0018). `total_amount`, `fulfilled_amount` and `open_amount` are LABELLED by this column and never converted by it
- `ordered_date` - The agreement's date. Not `created_at`, which is when the row was written
- `required_date` - The date the document is needed by, which an individual line may override. It is not `created_at`, and 0030's release selector drains on it (FEFO) after priority
- `closed_at` - When a terminal status was reached; NULL while the document is open
- `priority` - 1 highest to 4 lowest, and the allocation order 0030's release selector uses after the date
- `notes` - Free text on the row
- `status_reason` - Whoever changed the status last, in their own words. Not the audit trail, which is `audit_log`
- `created_by` - The connection that wrote it - `application_name`, which the pool sets and a tool argument cannot
- `created_at` - When the row was written
- `updated_at` - When the row last changed, by 0010's touch trigger
- `version` - How many times the row has been written, raised by 0011's `afpc_bump_version` trigger. On `orders` this IS the optimistic-lock token: `transition_order`'s `p_expected_version` is compared against it, and the comparison happens before the direction rules, so a caller working from a stale read is told that and nothing else
- `line_count` - How many lines the document has, summed in one grouped pass rather than stored
- `total_amount` - What the document is worth, summed from the lines' generated `line_amount` and expressed in the header's `currency_code`. Derived here rather than stored on the row, because a stored aggregate is a second truth about the rows it summarises
- `total_quantity` - Units ordered across every line. Different lines are counted in different units, so this is a piece count and not a comparable measure - the same reason `vw_item_movement_summary` does not sum heterogeneous quantities
- `fulfilled_amount` - Value of the part already fulfilled, pro-rating each line by `quantity_fulfilled / quantity`
- `open_amount` - Value still to move, by the same pro-rating

**Use Case:** orders. The definitions live in `db/migrations/0028_orders.sql`,
`0029_work_orders.sql` and `0030_order_fulfilment.sql`; the rules they encode are in those files'
headers, and the behavioural probes that keep them true run inside the same files.

---

### vw_order_lines

One row per line, with its document's type and status beside it and its state named from its three quantities.

```sql
SELECT order_number, line_number, line_type, description, quantity_open, line_state
  FROM vw_order_lines
 WHERE order_type = 'PURCHASE' AND line_state = 'OPEN';
```

**Columns:** (in declared order, read from `pg_attribute`, like every other list on this page;
`code:agent_docs_match_surface` re-checks them, so a rename fails here rather than in production)
- `tenant_id` - Whose row this is. Every tenant-coded view exposes it last (0009), which is what makes an agent's and an auditor's result sets differ without two views
- `order_id` - The document this line belongs to, with the header's own type and status joined beside it - which is what makes "what is still open on our purchase orders" one statement
- `order_number` - The header's number, joined so a line listing does not need a second read
- `order_type` - The header's type. A line's own `line_type` says what it is; this says what document it belongs to
- `order_status` - The header's status, in the same one join - which is what makes "what is still open on our purchase orders" one statement
- `order_line_id` - The `order_items` primary key, and the value `inventory_reservations.order_line_id` names once a commitment is attributed
- `line_number` - Position within the document, assigned by the door as max+1
- `line_type` - STANDARD, COMPONENT or PRODUCT. On a sales or purchase line it is STANDARD; on a work order it is the seam between what the document consumes and what it yields, and `afpc_line_type_matches_document` refuses the mismatch rather than filing a work order's component as a sale
- `item_id` - The `inventory_items` row, or NULL for a line that is not a catalog item. A blank one is not an unfilled field: `order_items_names_something` requires `description` in its place, which is 0028's answer to a purchase order that procures services
- `sku` - The item's SKU
- `item_name` - The item master's name, `it.name` - so NULL on a line that has no item. What such a line says about itself is `description`, and a reader who assumed the two were coalesced is reading a sentence the view does not write
- `item_product_type` - GOODS or SERVICE from the item master - the axis a purchase order procures along. NULL on a line with no item
- `description` - The line's own words. Required when `item_id` is NULL, which is what keeps a one-off plumber billable and out of the item master, where he would become an item called MISCELLANEOUS
- `quantity` - What the line promises, carried from `order_items`
- `unit_of_measure` - Which unit that quantity is counted in, from the master - so a number cannot be filed in an undefined unit
- `unit_price` - Price per unit, in the header's currency
- `line_amount` - `quantity * unit_price`, GENERATED - a pure function of two columns on the same row, so it is the one derived value that can live in the table without being a second truth, and the width PostgreSQL infers from the multiplication is the width that needs (0018's overflow was a human guessing it). `order_items.updated_at` exists because a generated column depends on it
- `quantity_fulfilled` - What has moved for it. The counter 0030's doors raise, and the one this view's verdict is compared against
- `quantity_cancelled` - What is off the line
- `quantity_open` - `quantity` minus fulfilled minus cancelled
- `line_state` - OPEN, PARTIAL, FULFILLED, CANCELLED or UNFULFILLED_CLOSED, named here from the three quantities rather than stored in a fourth column that could disagree with them
- `warehouse_id` - Where this line's stock is held, or NULL to mean the document's own - the fulfilment doors read it in that order
- `warehouse_code` - That warehouse's code
- `lot_number` - Which lot the line wants, when it wants a particular one; NULL means any lot, and the pick drains FEFO
- `serial_numbers` - Serials on the line, if it carries any - jsonb because a serial is a list and the schema has no reason to own its shape
- `required_date` - This line's need-by date, which overrides the header's for this line alone and is what the release selector drains on
- `notes` - Free text on the row
- `created_at` - When the row was written
- `updated_at` - When the row last changed, by 0010's touch trigger
- `version` - Writes to the line's row, raised by `afpc_bump_version`. The counters 0030's doors raise move it with them, so a line that says it has not changed since you read it has not

**Use Case:** order_lines. The definitions live in `db/migrations/0028_orders.sql`,
`0029_work_orders.sql` and `0030_order_fulfilment.sql`; the rules they encode are in those files'
headers, and the behavioural probes that keep them true run inside the same files.

---

### vw_suppliers

One row per supplier, carrying the party it is beside the terms it buys on.

```sql
SELECT supplier_code, party_name, payment_terms, lead_time_days
  FROM vw_suppliers
 WHERE is_active
 ORDER BY supplier_code;
```

**Columns:** (in declared order, read from `pg_attribute`, like every other list on this page;
`code:agent_docs_match_surface` re-checks them, so a rename fails here rather than in production)
- `tenant_id` - Whose row this is. Every tenant-coded view exposes it last (0009), which is what makes an agent's and an auditor's result sets differ without two views
- `supplier_id` - The `suppliers` primary key. `orders.vendor_id` points here, not at `entity_id`, so a purchase order names the relationship rather than the company
- `supplier_code` - What the supplier is called on paper. `add_order_line`'s SUPPLIER:<code> external reference resolves through this column, which is why the exclusion constraint that stops a catalog line and a supplier line repeating is keyed on it and not on `party_name`
- `entity_id` - The party this supplier IS - `entities.id`, with `tenant_id` in the same key because a foreign key does not respect row security (0027 measured it)
- `party_name` - The party's name, joined from `entities`
- `legal_name` - The registered name, where it differs from the trading name
- `tax_id` - Tax reference, on the party
- `party_type` - The party's own `entity_type` value. Read it rather than inferring "supplier" from it: the CHECK on `entities.entity_type` admits one value per row, which is exactly why this table exists
- `payment_terms` - How the supplier expects to be paid - free text on purpose, because it belongs to the agreement, not to a vocabulary
- `lead_time_days` - How long an order to this supplier normally takes, which a replenishment decision reads and 0030's receipt date does not enforce
- `currency_code` - The currency their invoices come in, an FK to `currencies`. NOT NULL with a column default of `USD`, and `add_supplier` passes `coalesce(p_currency_code, 'USD')` so the door and the column cannot disagree. There is deliberately no party-level currency to inherit: `entities` has no currency column, and a relationship attribute invented for the sake of a default would be a second place to say the same thing
- `is_active` - false retires the supplier without deleting agreements that name it; 0008's rule for a thing that cannot leave a trail
- `notes` - Free text on the row
- `created_at` - When the row was written
- `updated_at` - When the row last changed, by 0010's touch trigger
- `version` - Writes to the supplier row, raised by `afpc_bump_version`. Retiring one is an UPDATE, so the number moves with `is_active`

**Use Case:** suppliers. The definitions live in `db/migrations/0028_orders.sql`,
`0029_work_orders.sql` and `0030_order_fulfilment.sql`; the rules they encode are in those files'
headers, and the behavioural probes that keep them true run inside the same files.

---

### vw_work_centres

Where operations run, what they run in, and how many operations are still waiting for one.

```sql
SELECT work_centre_code, warehouse_code, capacity_hours_per_day, open_operations
  FROM vw_work_centres;
```

**Columns:** (in declared order, read from `pg_attribute`, like every other list on this page;
`code:agent_docs_match_surface` re-checks them, so a rename fails here rather than in production)
- `tenant_id` - Whose row this is. Every tenant-coded view exposes it last (0009), which is what makes an agent's and an auditor's result sets differ without two views
- `work_centre_id` - The `work_centres` primary key
- `work_centre_code` - What a human calls the bench: upper-cased and shaped by `work_centres_code_format`, unique per tenant (`work_centres_code_per_tenant`), and the key a plan resolves a place through
- `name` - Its name
- `warehouse_id` - Which warehouse it is inside, with the tenant in the same key - a bench cannot name somebody else's building
- `warehouse_code` - That warehouse's code
- `warehouse_name` - And its name
- `capacity_hours_per_day` - How many hours of work it can absorb a day. Nothing enforces it yet, which is why it is capacity *per day* and not a promise
- `is_active` - false retires a centre without deleting the operations that name it - 0008's rule for a thing that cannot leave a trail by disappearing, stated here for a work bench rather than for a supplier
- `notes` - Free text on the row
- `created_at` - When the row was written
- `updated_at` - When the row last changed, by 0010's touch trigger
- `version` - Writes to the centre's row, raised by `afpc_bump_version`
- `open_operations` - Operations here that are not COMPLETED - the queue a scheduling question starts from

**Use Case:** work_centres. The definitions live in `db/migrations/0028_orders.sql`,
`0029_work_orders.sql` and `0030_order_fulfilment.sql`; the rules they encode are in those files'
headers, and the behavioural probes that keep them true run inside the same files.

---

### vw_work_order_plan

One row per planned operation on a WORK order, with the line it works on and the centre it runs in resolved.

```sql
SELECT order_number, sequence, work_centre_code, planned_hours, actual_hours, status
  FROM vw_work_order_plan
 WHERE order_id = '01a1a9...'::uuid
 ORDER BY sequence;
```

**Columns:** (in declared order, read from `pg_attribute`, like every other list on this page;
`code:agent_docs_match_surface` re-checks them, so a rename fails here rather than in production)
- `tenant_id` - Whose row this is. Every tenant-coded view exposes it last (0009), which is what makes an agent's and an auditor's result sets differ without two views
- `order_id` - The WORK order this plan belongs to
- `order_number` - The header's number, joined so a line listing does not need a second read
- `operation_id` - The `work_order_operations` row
- `sequence` - Position in the plan, starting at 1; 0030's production door does not read it, and §7 says why
- `order_line_id` - The line this operation works on, or NULL for a step that acts on the document rather than on a stock line. `book_work_order_production` moves stock through the LINE, so a plan whose operations name nothing cannot be reconciled against it
- `line_type` - The kind of LINE this operation acts on - COMPONENT means it consumes stock, PRODUCT means it yields it. Joined from `vw_order_lines`, so it is the document's claim and not a second one stored on the operation
- `line_sku` - The line's item SKU, or NULL for a line with no item
- `line_item_name` - And its name
- `description` - What the operation IS, in the planner's words, and it is joined from `work_order_operations` rather than from the line - the two can say different things, so both are worth reading. Nullable: the door stores `NULLIF(btrim(...))`, so an operation with no words is possible and reads as one
- `work_centre_id` - Where the operation runs, or NULL for a step the plan never placed at a bench
- `work_centre_code` - The centre's code, joined by the same LEFT JOIN that brings its name - so NULL says either no bench was assigned to this step or the centre is gone, and the two are told apart by `work_centre_id`
- `work_centre_name` - And its name
- `planned_hours` - The estimate. NULL is 'not estimated' and is kept distinct from 0, which is 'no time'
- `actual_hours` - Recorded against real work
- `hours_variance` - `actual_hours - planned_hours`, so a POSITIVE number means the work took longer than estimated. NULL when either side is NULL, which is the difference between 'not estimated' and 'estimated at zero' - the two are different sentences and this column keeps them apart rather than blending them into 0
- `quantity_produced` - Output booked against this operation
- `quantity_scrapped` - Production booked as scrap
- `status` - PENDING, IN_PROGRESS or COMPLETED. The operation's own state, not the order's, and the two can disagree only for the reason `start`'s door refuses
- `started_at` - When it began
- `completed_at` - When it finished
- `created_at` - When the row was written
- `updated_at` - When the row last changed, by 0010's touch trigger
- `version` - Writes to the operation's row, raised by `afpc_bump_version`

**Use Case:** work_order_plan. The definitions live in `db/migrations/0028_orders.sql`,
`0029_work_orders.sql` and `0030_order_fulfilment.sql`; the rules they encode are in those files'
headers, and the behavioural probes that keep them true run inside the same files.

---

### vw_order_commitments

One row per order line: what it promises, what stock is committed against it, what the ledger has moved, and whether the two agree.

```sql
SELECT order_number, line_number, quantity, quantity_committed, quantity_shipped, ledger_agreement
  FROM vw_order_commitments
 WHERE quantity_committed > 0 AND ledger_agreement <> 'nothing moved yet';
```

**Columns:** (in declared order, read from `pg_attribute`, like every other list on this page;
`code:agent_docs_match_surface` re-checks them, so a rename fails here rather than in production)
- `tenant_id` - Whose row this is. Every tenant-coded view exposes it last (0009), which is what makes an agent's and an auditor's result sets differ without two views
- `order_id` - The document the line belongs to, carried so a caller can join the commitment back to the header without a second read
- `order_number` - The header's number, joined so a line listing does not need a second read
- `order_type` - The header's type. A line's own `line_type` says what it is; this says what document it belongs to
- `order_status` - The header's status, in the same one join - which is what makes "what is still open on our purchase orders" one statement
- `order_line_id` - The `order_items` primary key, and the value `inventory_reservations.order_line_id` names once a commitment is attributed
- `line_number` - Position within the document, assigned by the door as max+1
- `line_type` - The line's kind, from `order_items`. A COMPONENT or PRODUCT line's commitments are a work order's stock movements; STANDARD is a document's own goods
- `item_id` - The `inventory_items` row the line is for; NULL on a service line, and a service line's commitments are always 0, which is the honest answer rather than an error
- `item_name` - The item master's name, or the line's own description when there is no item
- `quantity` - What the line promises, carried from `order_items`
- `quantity_fulfilled` - What has moved for it. The counter 0030's doors raise, and the one this view's verdict is compared against
- `quantity_cancelled` - What is off the line
- `quantity_open` - `quantity` minus fulfilled minus cancelled
- `quantity_committed` - Units held live against THIS line, attributed by `inventory_reservations.order_line_id` - the join 0030 added, because a commitment that names only the document cannot be reconciled line by line
- `quantity_released` - Of the units committed to this line, how many have settled - shipped or cancelled, summed from the reservation row's own counters
- `quantity_unresolved` - `reserved_quantity` minus shipped minus cancelled: what is still held. This is 0015's `held_quantity`, and 13 of these units sat here forever until 0030 gave them a door
- `quantity_committed_unlinked` - Units held against this document AND this item whose reservation names no line. Reported separately and never folded into `quantity_committed`: joining on the line alone makes them invisible, and '0 committed' where the truth is 'committed, not attributed' is the one number in this view that is unsafe to act on
- `ledger_rows` - How many `inventory_movements` rows name this line, RESERVATION rows excluded
- `ledger_quantity` - What the ledger says actually moved for this line and item, signed and absolute-summed. The RESERVATION rows are excluded for 0015's reason - a commitment makes stock unavailable, it moves nothing - and `vw_item_movement_summary`'s two direction columns apply the same rule
- `ledger_agreement` - The verdict, in the register's own register: 'nothing moved yet', 'fulfilled without a movement (non-stock line)', 'agrees', or 'DISAGREES'. A line with no movements is not a disagreement, which is what keeps the column usable as an alarm rather than a nuisance
- `required_date` - The line's need-by date
- `line_updated_at` - When the line last changed. Named so it cannot be confused with the order header's `updated_at`, which is what a reader of 'this row' would otherwise assume

**Use Case:** order_commitments. The definitions live in `db/migrations/0028_orders.sql`,
`0029_work_orders.sql` and `0030_order_fulfilment.sql`; the rules they encode are in those files'
headers, and the behavioural probes that keep them true run inside the same files.

---

## Usage Examples

Every statement below was run against this server's database before it was written into this page, and
each names only columns `pg_attribute` says the view has. That sentence is the whole difference between
this section and the one it replaced, which had four examples, all of which raised `42P01` or `42703`:
`customer_communications_summary` and `pending_followups` and `agent_activity_summary` are the view names
*without* the `vw_` prefix this repository requires, `bot_id` is a column of `agent_interactions` and not
of `vw_agent_activity_summary` (which groups by `agent_id`), `item_name` is `name`, and the two
`follow_up_*` names described a `communications` row while the view reads the `followups` table, where
the column is `due_date`.

### One customer's communications, newest first

```sql
SELECT communication_type, direction, summary, outcome, sentiment_label, started_at
  FROM vw_customer_communications_summary
 WHERE entity_id = 5
 ORDER BY started_at DESC
 LIMIT 10;
```

### Tasks that are due

Note what this one answers on this server today: **zero rows**, because `followups` has no writer in the
schema (0021 §5 leaves that decision open). The live "who needs contact" question is
`SELECT * FROM get_followup_customers(7)`, and an agent that says it checked the pending list has told
you something true and useless.

```sql
SELECT entity_name, contact_name, description, due_date, priority, status
  FROM vw_pending_followups
 WHERE priority IN ('high', 'critical')
 ORDER BY due_date;
```

### What the agents have been doing

```sql
SELECT agent_id, total_actions, unique_entities, resolved_count,
       escalated_count, ROUND(avg_sentiment::numeric, 2) AS avg_sentiment, last_activity
  FROM vw_agent_activity_summary
 ORDER BY total_actions DESC;
```

### Where an item is, and whether it needs reordering

```sql
SELECT sku, name, warehouse_name, quantity_on_hand, quantity_reserved,
       quantity_available, reorder_point, stock_status, needs_reorder
  FROM vw_item_availability
 WHERE sku = 'IN-1003';
```

---

## Creating Custom Views

To create a new view:

```sql
CREATE OR REPLACE VIEW vw_my_custom_view AS
SELECT 
    e.name as entity_name,
    c.first_name || ' ' || c.last_name as contact_name,
    comm.summary
FROM entities e
JOIN entity_relationships er ON er.entity_id = e.id
JOIN contacts c ON c.id = er.contact_id
JOIN communications comm ON comm.entity_id = e.id
WHERE comm.started_at >= NOW() - INTERVAL '30 days';
```

---

## Best Practices

1. **Use views for complex queries** - Don't repeat JOINs in your code
2. **Check view performance** - Use EXPLAIN ANALYZE on complex views
3. **Document custom views** - Add comments to explain purpose
4. **Version control view definitions** - Store CREATE VIEW statements in SQL scripts

---

*Generated for Agent First ERP CRM - Database views reference*

### vw_index_redundancy
Indexes whose key list is identical to, or a strict leading prefix of, another index on the
same table - write amplification with no read benefit (DATABASE_REVIEW.md 5.6). Built by
`db/migrations/0006_index_hygiene.sql`; both forms of the finding are in one place so the
harness, the scoreboard and an auditor ask one definition of "redundant".

```sql
SELECT * FROM vw_index_redundancy;
```

| Column | Meaning |
|---|---|
| table_name | the table carrying the redundant index |
| redundant_index | the index that can go |
| redundant_keys | its columns, in order |
| covered_by | the surviving index that already answers every query it could |
| redundancy | `identical` or `prefix` |

Primary keys, unique indexes, partial indexes and expression keys are never reported as
redundant. The last two exclusions are load-bearing: an index on
`(tenant_id, item_id, warehouse_id)` looks like a prefix of 0004's identity index but is not
interchangeable with it, because the identity index's `COALESCE` positions are what tell a
no-bin stock row from a real one.

### vw_domain_vocabulary
What each status/type column accepts, how that is enforced, and why. Built by
`db/migrations/0007_domain_constraints.sql` as the machine-readable half of review 5.9: the
constraints make the database correct, this makes correctness queryable by an agent that is about
to write a value.

```sql
SELECT * FROM vw_domain_vocabulary WHERE table_name = 'followups';
```

| Column | Meaning |
|---|---|
| table_name, column_name | the domain column |
| enforced_by | `check`, `lookup table`, or `none - free text` |
| rule | the constraint or foreign key that enforces it |
| enforced_on_existing_rows | false means a NOT VALID constraint: new writes are checked, old rows are not |
| nulls | whether the column admits NULL |
| allowed_values | the literal set, extracted from the constraint definition |
| lookup_values / lookup_table | the current codes, and the table they live in |
| reason | for a free-text column: why it stayed open. For everything else: NULL |

One row per domain column in `public`, derived from the catalog, so a column nobody considered
appears as `UNDECIDED` rather than going missing.
