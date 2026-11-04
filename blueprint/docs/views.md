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

Per tool, per tenant: calls, runs, the mean duration of the runs that used it, and how many of those runs errored. Counts are at the call grain, timings and errors at the run grain - the version in `blueprint/11_interaction_logging.sql` mixed them, and `db/migrations/0017_interaction_readpath.sql` carries the two numbers it changed.

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

different names and no `tenant_id`)

different names and no `tenant_id`)
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

  from this view rather than present with NULLs - which is what makes `rows_for_pair` meaningful.

  from this view rather than present with NULLs - which is what makes `rows_for_pair` meaningful.
- `rate_in_force` - The number, or NULL when the pair has no row covering now
- `valid_from` / `valid_to` - The window that row covers; NULL `valid_to` means it is the open row
- `source` - Where the number came from; NULL is information (an unattributed rate)
- `in_force` - Whether a covering row exists at all. `false` with `rows_for_pair > 0` means

  *expired*, which is a different fact from a pair that has no rows; conflating them is how a rate
  table stops being trusted by the person reading it
- `rows_for_pair` - How much history this pair has
- `as_of` - `now()`, stated rather than implicit: a view that quietly contains a clock answers a

  different question on every scan

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
- `total_inbound` - Receipts in the window, reservations excluded - a commitment makes stock unavailable, it moves nothing (0019's note)
- `total_outbound` - Issues in the window, reservations excluded, for the same reason
- `tenant_id` - Whose row this is. Every tenant-coded view exposes it last (0009), which is what makes an agent's and an auditor's result sets differ without two views

five columns this view has never had)

five columns this view has never had)
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

## Usage Examples

### Get Customer Communications

```sql
SELECT 
    communication_type,
    summary,
    outcome,
    sentiment_label
FROM customer_communications_summary
WHERE entity_id = 123
ORDER BY started_at DESC
LIMIT 10;
```

### Get Pending Follow-ups

```sql
SELECT 
    entity_name,
    contact_name,
    follow_up_action,
    follow_up_date,
    priority
FROM pending_followups
WHERE priority IN ('high', 'critical')
ORDER BY follow_up_date ASC;
```

### Get Agent Performance

```sql
SELECT 
    bot_id,
    total_actions,
    ROUND(avg_sentiment::numeric, 2) as avg_sentiment
FROM agent_activity_summary
ORDER BY total_actions DESC;
```

### Check Item Availability

```sql
SELECT 
    sku,
    item_name,
    warehouse_name,
    quantity_available,
    stock_status
FROM vw_item_availability
WHERE sku = 'WIDGET-A';
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
