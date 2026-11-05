# Agent First ERP CRM Database Schema Reference

> **As-found design, not the current database.** This is the page the 2026-07 schema review was
> written *against*: its tables are the shape `0001_baseline_canonical_port.sql` ported, several of its
> notes were findings rather than facts, and it has no `tenant_id` in any column list because ten
> migrations added that column afterwards. For the schema as it is, read
> [../../db/README.md](../../db/README.md) (the source of truth), the generated
> [tables.md](tables.md)/[views.md](views.md)/[indexes.md](indexes.md), or the catalog itself:
> `\d <table>`. This page is kept because `docs/database/schema.md` and the review cite it, and a
> record of what the review found is part of why the fixes have checks.

**Purpose:** Simplified schema reference, describing the pre-remediation design.

---

## Core Domains

### 1. Party Management (Entities + Contacts)
| Table | Purpose | Key Fields |
|-------|---------|------------|
| `entities` | Companies/organizations/customers | `id`, `entity_type`, `name`, `status`, `embedding` |
| `contacts` | Individual people | `id`, `first_name`, `last_name`, `email`, `phone`, `title`, `embedding` |
| `entity_relationships` | Links contacts to entities | `entity_id`, `contact_id`, `role`, `is_primary` |
| `addresses` | Physical locations | `entity_id`, `contact_id`, `address_type`, `street`, `city`, `is_primary` |

**Key Insight:** One Entity can have multiple Contacts. One Contact can relate to multiple Entities via `entity_relationships`.

### 2. Communications & Activity
| Table | Purpose | Key Fields |
|-------|---------|------------|
| `communications` | All interactions (calls, emails, chats) | `id`, `entity_id`, `contact_id`, `communication_type`, `summary`, `sentiment_score`, `outcome`, `embedding` |
| `human_sessions` | Human agent login sessions | `session_id`, `user_id`, `user_name`, `bot_id`, `bot_type`, `login_time`, `logout_time`, `session_status` |
| `bot_actions` | Actions performed by AI agents | `action_id`, `session_id`, `user_id`, `bot_id`, `action_type`, `action_description`, `success`, `error_message`, `execution_time_ms` |
| `audit_summary` | Daily aggregation of human-bot interactions | `summary_id`, `date`, `user_id`, `bot_id`, `total_sessions`, `total_actions`, `successful_actions`, `failed_actions` |
| `agent_interactions` | Complete agent trajectory logging | `id`, `conversation_id`, `human_input`, `intent_classification`, `agent_thoughts`, `actions_taken`, `tool_observations`, `final_output`, `token_usage`, `duration_ms` |
| `followups` | Action items/tasks | `id`, `entity_id`, `contact_id`, `description`, `due_date`, `priority`, `status` |

**Key Insight:** Communications are the heart of the system. Everything links back to them. All agent actions are fully logged for debugging and auditing.

### 3. Inventory & Supply Chain
| Table | Purpose | Key Fields |
|-------|---------|------------|
| `item_categories` | Product category hierarchy | `category_id`, `category_code`, `name`, `parent_category_id` |
| `inventory_items` | Product catalog | `item_id`, `sku`, `name`, `category_id`, `base_unit_of_measure`, `standard_cost`, `is_active` |
| `warehouses` | Storage locations | `warehouse_id`, `warehouse_code`, `name`, `is_active` |
| `locations` | Specific bins/shelves within warehouses | `location_id`, `warehouse_id`, `location_code`, `zone`, `aisle`, `bin` |
| `inventory_on_hand` | Current stock levels | `item_id`, `warehouse_id`, `quantity_on_hand`, `quantity_available`, `quantity_reserved` |
| `inventory_movements` | All stock changes | `movement_id`, `movement_type`, `item_id`, `from_warehouse_id`, `to_warehouse_id`, `quantity`, `performed_at` |
| `inventory_reservations` | Allocated stock for orders | `reservation_id`, `item_id`, `order_id`, `reserved_quantity`, `shipped_quantity` |

**Key Flow:** Movement → Update On Hand → Reservation Management

---

## Key Relationships

```
ENTITIES ──┬── HAS_MANY ──► CONTACTS
           │
           ├── HAS_MANY ──► ADDRESSES
           │
           └── HAS_MANY ──► COMMUNICATIONS

CONTACTS ──┬── HAS_MANY ──► ADDRESSES
           │
           └── HAS_MANY ──► COMMUNICATIONS

COMMUNICATIONS ──► self-referencing (parent_id, thread_root_id)

HUMAN_SESSIONS ──► HAS_MANY ──► BOT_ACTIONS

INVENTORY_ITEMS ──► BELONGS_TO ──► ITEM_CATEGORIES
WAREHOUSES ──► HAS_MANY ──► LOCATIONS
INVENTORY_MOVEMENTS ──► UPDATES ──► INVENTORY_ON_HAND
```

---

## Agent-Friendly Views

| View | Purpose | Use When |
|------|---------|----------|
| `vw_customers` | Backward compatibility view | Need legacy customer format |
| `vw_customer_communications_summary` | Customer communications with full context | Querying customer interactions |
| `vw_recent_communications` | Last 7 days of all communications | Activity feeds, monitoring |
| `vw_pending_followups` | Tasks requiring follow-up | Finding action items |
| `vw_entity_communication_stats` | Aggregated metrics per entity | Customer health scoring |
| `vw_primary_contact_communications` | Only primary contact interactions | Executive-level tracking |
| `vw_communication_thread` | Conversation threading | Reconstructing conversations |
| `vw_agent_activity_summary` | Per-agent activity metrics | Performance monitoring |
| `vw_inventory_valuation` | Inventory value by warehouse/category | Financial reporting |
| `vw_item_availability` | Stock levels across warehouses | Checking item availability |
| `vw_item_movement_summary` | 30-day movement patterns | Analyzing item movement |
| `vw_low_stock_alerts` | Items below reorder point | Replenishment tasks |

---

## Common Query Patterns

### Get Primary Contact for an Entity
```sql
SELECT c.first_name, c.last_name, c.email, c.phone
FROM entity_relationships er
JOIN contacts c ON c.id = er.contact_id
WHERE er.entity_id = $1 AND er.is_primary = TRUE;
```

### Get Communications for an Entity (Last 30 Days)
```sql
SELECT started_at, communication_type, subject, summary, outcome
FROM communications
WHERE entity_id = $1 AND started_at >= NOW() - INTERVAL '30 days'
ORDER BY started_at DESC;
```

### Get Complete Conversation Thread
```sql
SELECT * FROM communications
WHERE thread_root_id = $1
ORDER BY started_at ASC;
```

### Check Item Availability
```sql
SELECT i.sku, i.name, w.name as warehouse, 
       ioh.quantity_on_hand, ioh.quantity_available,
       CASE 
         WHEN ioh.quantity_available <= 0 THEN 'OUT_OF_STOCK'
         WHEN ioh.quantity_available <= i.safety_stock THEN 'CRITICAL'
         WHEN ioh.quantity_available <= i.reorder_point THEN 'LOW_STOCK'
         ELSE 'NORMAL'
       END as stock_status
FROM inventory_items i
JOIN inventory_on_hand ioh ON i.item_id = ioh.item_id
JOIN warehouses w ON ioh.warehouse_id = w.warehouse_id
WHERE i.sku = $1;
```

### Get Recent Bot Actions
```sql
SELECT action_type, action_description, success, error_message, timestamp
FROM bot_actions
WHERE user_id = $1 AND bot_id = $2
ORDER BY timestamp DESC
LIMIT 50;
```

---

## Functions for Agents

| Function | Purpose |
|----------|---------|
| `execute_inventory_movement()` | Execute inventory movement with automatic on-hand updates |
| `reserve_inventory_for_order()` | Reserve inventory for an order |
| `split_name()` | Parse full name into first/last name |

---

## Important Notes

1. **Vector Embeddings**: `entities`, `contacts` and `communications` declare `vector(1536)` columns,
   and 0012 built their hnsw indexes. **Nothing writes them** - no embedder in this deployment
   produces 1536 dimensions (measured: the local models answer 1024 and 4096), so semantic search is
   not available and no query here should depend on it
2. **Row Level Security**: this line used to single out two tables, which was the pre-0009 state. Since
   0009 RLS is `FORCED` on **every** tenant-coded table - 21 today, with 42 policies, and the five
   global tables and one build ledger declared exempt rather than forgotten. `vw_rls_status` publishes
   each predicate verbatim with a verdict
3. **Audit Trail**: `human_sessions` and `bot_actions` are the design's answer and both have **zero
   rows** - nothing writes them. The live trail is `agent_interactions` (one row per run) plus
   `audit_log` (one row per row-change, chained, since 0013). See [audit_schema.md](audit_schema.md)
4. **Threading**: `communications.parent_id` and `thread_root_id` - true, and `thread_root_id` got its
   first writer in 0021, so a reply to a reply lands on the thread the first message started
5. **Status Fields**: `status` and `is_active` are ordinary columns here, **not** soft deletes: soft
   delete and bitemporal control are the still-unapplied `0025`. What 0007 did add is the CHECK'd
   vocabulary each accepts, published by `vw_domain_vocabulary`

---

*Generated for Agent First ERP CRM - Simplified schema reference for AI agents*