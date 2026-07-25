# Agent First ERP CRM Database Schema Reference

**Purpose:** Simplified schema reference for AI agents to understand and query the database.

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

1. **Vector Embeddings**: `entities`, `contacts`, `communications` have 1536-dimension embeddings for semantic search
2. **Row Level Security**: `inventory_movements` and `inventory_reservations` have RLS policies
3. **Audit Trail**: All bot actions are logged via `human_sessions` → `bot_actions`
4. **Threading**: Communications use `parent_id` and `thread_root_id` for conversation threads
5. **Status Fields**: Most tables have `is_active` or `status` fields for soft deletes

---

*Generated for Agent First ERP CRM - Simplified schema reference for AI agents*