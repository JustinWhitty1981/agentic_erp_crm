# Database Views Reference

**Purpose:** Simplified query interfaces for agents and developers.

**Location:** `scripts/database/08_create_views.sql`

---

## Overview

Views provide simplified, agent-friendly interfaces to complex database queries. They encapsulate joins, aggregations, and business logic into single-query interfaces.

---

## Customer-Facing Views

### customers

Backward compatibility view mapping entities/contacts to legacy customer format.

```sql
SELECT * FROM agent_first_erp_crm.customers;
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

### customer_communications_summary

All communications for customers with full context.

```sql
SELECT * FROM agent_first_erp_crm.customer_communications_summary;
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

### recent_communications

Last 7 days of all communications.

```sql
SELECT * FROM agent_first_erp_crm.recent_communications;
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

### pending_followups

All communications requiring follow-up.

```sql
SELECT * FROM agent_first_erp_crm.pending_followups;
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

### entity_communication_stats

Aggregated communication metrics per entity.

```sql
SELECT * FROM agent_first_erp_crm.entity_communication_stats;
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

### primary_contact_communications

Communications only with primary contacts.

```sql
SELECT * FROM agent_first_erp_crm.primary_contact_communications;
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

### communication_thread_view

Shows communication threading hierarchy.

```sql
SELECT * FROM agent_first_erp_crm.communication_thread_view;
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

### agent_activity_summary

Summary of activity per bot agent.

```sql
SELECT * FROM agent_first_erp_crm.agent_activity_summary;
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

### v_recent_interactions

Last 100 agent interactions with full trajectory.

```sql
SELECT * FROM agent_first_erp_crm.v_recent_interactions;
```

**Columns:**
- `human_input` - Raw user input
- `intent_classification` - Detected intent
- `confidence_score` - Model confidence
- `actions_taken` - Tool calls made
- `final_output` - Response sent
- `duration_ms` - Total duration
- `error_message` - Error if failed
- `timestamp` - When interaction occurred

**Use Case:** Debugging, reviewing agent behavior

---

### v_failed_interactions

All interactions that resulted in errors.

```sql
SELECT * FROM agent_first_erp_crm.v_failed_interactions;
```

**Columns:**
- `human_input` - Raw user input
- `actions_taken` - Tool calls made
- `error_message` - Error details
- `timestamp` - When failed

**Use Case:** Identifying and fixing agent issues

---

### v_tool_performance

Tool usage statistics and error rates.

```sql
SELECT * FROM agent_first_erp_crm.v_tool_performance;
```

**Columns:**
- `tool_name` - Tool identifier
- `call_count` - Number of calls
- `avg_duration_ms` - Average execution time
- `error_count` - Number of errors
- `error_rate` - Error percentage

**Use Case:** Optimizing tool performance, identifying problematic tools

---

## Inventory Views

### v_inventory_valuation

Inventory value by warehouse/category.

```sql
SELECT * FROM agent_first_erp_crm.v_inventory_valuation;
```

**Columns:**
- `warehouse_name` - Warehouse name
- `category_name` - Category name
- `total_value` - Total inventory value
- `item_count` - Number of items

**Use Case:** Financial reporting

---

### v_item_availability

Stock levels across warehouses.

```sql
SELECT * FROM agent_first_erp_crm.v_item_availability;
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

### v_item_movement_summary

30-day movement patterns.

```sql
SELECT * FROM agent_first_erp_crm.v_item_movement_summary;
```

**Columns:**
- `sku` - Item SKU
- `item_name` - Item name
- `total_receipts` - Total received
- `total_shipments` - Total shipped
- `net_change` - Net inventory change

**Use Case:** Analyzing item movement

---

### v_low_stock_alerts

Items below reorder point.

```sql
SELECT * FROM agent_first_erp_crm.v_low_stock_alerts;
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
FROM agent_first_erp_crm.v_item_availability
WHERE sku = 'WIDGET-A';
```

---

## Creating Custom Views

To create a new view:

```sql
CREATE OR REPLACE VIEW agent_first_erp_crm.my_custom_view AS
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