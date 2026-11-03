# Database Views Reference

**Purpose:** Simplified query interfaces for agents and developers.

**Location:** `scripts/database/08_create_views.sql`

> **Read this page in two layers.** The note below is 0009's; the four interaction views added by
> `0017_interaction_readpath` are further down and are current. The column lists for the CRM and
> inventory views were written against the superseded SQL rather than the live catalog, and 0017
> found one of them is simply wrong in both directions - `vw_agent_activity_summary` is listed
> with `bot_id`, a column it has never had (the live one is `agent_id`), and is missing
> `unique_contacts`, `escalated_count` and `first_activity`. Read the lists with
> `SELECT * FROM pg_attribute WHERE attrelid = 'vw_...'::regclass` as the authority; a
> documentation sweep that checks every list against the catalog is task T4 in
> `db/MIGRATIONS.md`.

> **Changed by `db/migrations/0009_rls_enforcement.sql`, and this page describes the old
> behaviour in three ways.** (1) Every view over a tenant table now exposes `tenant_id` as its
> last column, so the twelve customer-facing and inventory views have one more column than
> listed below. (2) The four aggregate views (`vw_agent_activity_summary`,
> `vw_entity_communication_stats`, `vw_inventory_valuation`, `vw_item_movement_summary`) also
> group by it, because grouping without it adds two tenants' numbers together. (3) They are all
> `security_invoker` now, which is what makes row-level security apply to a query that goes
> through a view; an agent sees one tenant and the audit account sees all of them, which is the
> reason for (1). The canonical definitions live in `0001` (port) plus `0009` (this change) -
> not in the SQL file named above, which is one of the superseded copies listed in
> `db/README.md`.


## Overview

Views provide simplified, agent-friendly interfaces to complex database queries. They encapsulate joins, aggregations, and business logic into single-query interfaces.

---

## Customer-Facing Views

### vw_customers

Backward compatibility view mapping entities/contacts to legacy customer format.

```sql
SELECT * FROM agent_first_erp_crm.vw_customers;
```

**Columns:**
- `id` - Entity ID
- `name` - Entity name
- `email` - Primary contact email
- `phone` - Primary contact phone
- `address` - Primary address
- `status` - Entity status
- `created_at` - Creation timestamp
- `updated_at` - Last update timestamp
- `embedding` - Vector embedding for semantic search

**Use Case:** Legacy code compatibility

---

### vw_customer_communications_summary

All communications for customers with full context.

```sql
SELECT * FROM agent_first_erp_crm.vw_customer_communications_summary;
```

**Columns:**
- `entity_id` - Customer entity ID
- `entity_name` - Customer name
- `entity_type` - Type (customer/vendor/prospect)
- `contact_id` - Contact ID
- `contact_name` - Full contact name
- `communication_type` - Type of communication
- `direction` - Inbound/outbound/internal
- `subject` - Communication subject
- `summary` - AI-generated summary
- `outcome` - Resolution status
- `priority` - Priority level
- `sentiment_label` - Positive/neutral/negative
- `started_at` - When communication started
- `follow_up_required` - Requires follow-up?
- `follow_up_date` - Follow-up date

**Use Case:** Agent queries, customer service dashboards

---

### vw_recent_communications

Last 7 days of all communications.

```sql
SELECT * FROM agent_first_erp_crm.vw_recent_communications;
```

**Columns:**
- `entity_name` - Entity name
- `contact_name` - Contact name
- `communication_type` - Type of communication
- `subject` - Subject line
- `summary` - Summary
- `outcome` - Resolution status
- `started_at` - Timestamp

**Use Case:** Activity feeds, monitoring

---

### vw_pending_followups

All communications requiring follow-up.

```sql
SELECT * FROM agent_first_erp_crm.vw_pending_followups;
```

**Columns:**
- `communication_id` - Communication ID
- `entity_name` - Customer name
- `contact_name` - Contact name
- `follow_up_date` - Due date
- `follow_up_action` - Required action
- `priority` - Priority level
- `communication_type` - Type
- `summary` - Summary

**Use Case:** Task lists, agent action items

---

### vw_entity_communication_stats

Aggregated communication metrics per entity.

```sql
SELECT * FROM agent_first_erp_crm.vw_entity_communication_stats;
```

**Columns:**
- `entity_id` - Entity ID
- `entity_name` - Entity name
- `entity_type` - Entity type
- `total_communications` - Total count
- `resolved_count` - Resolved count
- `escalated_count` - Escalated count
- `avg_sentiment` - Average sentiment score
- `last_contact_date` - Most recent contact

**Use Case:** Customer health scores, engagement metrics

---

### vw_primary_contact_communications

Communications only with primary contacts.

```sql
SELECT * FROM agent_first_erp_crm.vw_primary_contact_communications;
```

**Columns:**
- `entity_name` - Entity name
- `primary_contact` - Primary contact name
- `contact_title` - Contact title
- `communication_type` - Type
- `subject` - Subject
- `summary` - Summary
- `outcome` - Outcome
- `started_at` - Timestamp

**Use Case:** Executive-level interaction tracking

---

### vw_communication_thread

Shows communication threading hierarchy.

```sql
SELECT * FROM agent_first_erp_crm.vw_communication_thread;
```

**Columns:**
- `communication_id` - Communication ID
- `parent_id` - Parent communication ID
- `thread_root_id` - Root of conversation thread
- `entity_name` - Entity name
- `contact_name` - Contact name
- `communication_type` - Type
- `started_at` - Timestamp

**Use Case:** Reconstructing conversation flows

---

## Agent Activity Views

### vw_agent_activity_summary

Summary of activity per bot agent.

```sql
SELECT * FROM agent_first_erp_crm.vw_agent_activity_summary;
```

**Columns:**
- `bot_id` - Agent identifier
- `total_actions` - Total actions performed
- `unique_entities` - Unique entities served
- `resolved_count` - Resolved communications
- `avg_sentiment` - Average sentiment
- `last_activity` - Last activity timestamp

**Use Case:** Performance monitoring, workload balancing

---

### vw_recent_interactions

Every interaction the caller's row security reaches, newest first **if the caller says `ORDER BY "timestamp" DESC`**. This page promised "last 100"; a `LIMIT` inside a view runs before the caller's filter, so 0017 leaves the 100 to the caller - `ORDER BY "timestamp" DESC LIMIT 100`.

```sql
SELECT * FROM vw_recent_interactions;
```

**Columns:** (read from `pg_attribute`; the list this page carried before 0017 described a view that did not exist)
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

**Columns:** (read from `pg_attribute`; the list this page carried before 0017 described a view that did not exist)
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

**Columns:** (read from `pg_attribute`; the list this page carried before 0017 described a view that did not exist)
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

**Columns:** (read from `pg_attribute`; the list this page carried before 0017 described a view that did not exist)
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

Inventory value by warehouse/category.

```sql
SELECT * FROM agent_first_erp_crm.vw_inventory_valuation;
```

**Columns:**
- `warehouse_name` - Warehouse name
- `category_name` - Category name
- `total_value` - Total inventory value
- `item_count` - Number of items

**Use Case:** Financial reporting

---

### vw_item_availability

Stock levels across warehouses.

```sql
SELECT * FROM agent_first_erp_crm.vw_item_availability;
```

**Columns:**
- `sku` - Item SKU
- `item_name` - Item name
- `warehouse_name` - Warehouse name
- `quantity_on_hand` - Total quantity
- `quantity_available` - Available quantity
- `stock_status` - NORMAL/LOW_STOCK/CRITICAL/OUT_OF_STOCK

**Use Case:** Checking item availability

---

### vw_item_movement_summary

30-day movement patterns, grouped by item, day, and movement type.

```sql
SELECT * FROM agent_first_erp_crm.vw_item_movement_summary;
```

**Columns:** (read from `pg_attribute`, not from the earlier draft of this page, which named
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
SELECT * FROM agent_first_erp_crm.vw_low_stock_alerts;
```

**Columns:**
- `sku` - Item SKU
- `item_name` - Item name
- `warehouse_name` - Warehouse name
- `quantity_available` - Available quantity
- `reorder_point` - Reorder threshold
- `shortage_amount` - How much below threshold

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
FROM agent_first_erp_crm.customer_communications_summary
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
FROM agent_first_erp_crm.pending_followups
WHERE priority IN ('high', 'critical')
ORDER BY follow_up_date ASC;
```

### Get Agent Performance

```sql
SELECT 
    bot_id,
    total_actions,
    ROUND(avg_sentiment::numeric, 2) as avg_sentiment
FROM agent_first_erp_crm.agent_activity_summary
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
FROM agent_first_erp_crm.vw_item_availability
WHERE sku = 'WIDGET-A';
```

---

## Creating Custom Views

To create a new view:

```sql
CREATE OR REPLACE VIEW agent_first_erp_crm.vw_my_custom_view AS
SELECT 
    e.name as entity_name,
    c.first_name || ' ' || c.last_name as contact_name,
    comm.summary
FROM agent_first_erp_crm.entities e
JOIN agent_first_erp_crm.entity_relationships er ON er.entity_id = e.id
JOIN agent_first_erp_crm.contacts c ON c.id = er.contact_id
JOIN agent_first_erp_crm.communications comm ON comm.entity_id = e.id
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
