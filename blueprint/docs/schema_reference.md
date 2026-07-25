# Agent First ERP CRM Schema Reference

**Purpose:** Complete database schema reference for AI agents and developers.

**Generated from:** PostgreSQL 16.14 using pgschema 1.12.0

---

## Schema Overview

The Agent First ERP CRM database is organized into the following domains:

1. **Party Management** - Entities, contacts, relationships, and addresses
2. **Communications** - All interactions with threading and sentiment analysis
3. **Audit Logging** - Human sessions, bot actions, and interaction tracking
4. **Inventory** - Products, warehouses, stock levels, and movements
5. **Support** - Tickets and follow-ups

---

## Core Tables

### Entities

Business organizations and customers.

| Column | Type | Description |
|--------|------|-------------|
| id | SERIAL | Primary key |
| entity_type | VARCHAR(50) | 'customer', 'vendor', 'prospect', 'employee' |
| name | TEXT | Display name |
| legal_name | TEXT | Legal business name (NULL for individuals) |
| tax_id | VARCHAR(50) | EIN, VAT ID, SSN (encrypted in production) |
| industry | VARCHAR(100) | Industry classification |
| website | TEXT | Website URL |
| status | TEXT | 'active', 'inactive', 'blacklisted' |
| created_at | TIMESTAMPTZ | Record creation timestamp |
| updated_at | TIMESTAMPTZ | Last update timestamp |
| embedding | VECTOR(1536) | Semantic search embedding |

### Contacts

Individual human beings.

| Column | Type | Description |
|--------|------|-------------|
| id | SERIAL | Primary key |
| first_name | TEXT | First name |
| last_name | TEXT | Last name |
| email | TEXT | Email address |
| phone | TEXT | Phone number |
| title | TEXT | Job title |
| status | TEXT | 'active', 'inactive' |
| preferences | JSONB | Communication preferences |
| created_at | TIMESTAMPTZ | Record creation timestamp |
| updated_at | TIMESTAMPTZ | Last update timestamp |
| embedding | VECTOR(1536) | Semantic search embedding |

### Entity Relationships

Links contacts to entities with roles.

| Column | Type | Description |
|--------|------|-------------|
| id | SERIAL | Primary key |
| entity_id | INTEGER | Reference to entities |
| contact_id | INTEGER | Reference to contacts |
| role | VARCHAR(100) | Role at the entity (e.g., "Procurement Manager") |
| is_primary | BOOLEAN | Main point of contact? |
| start_date | DATE | Relationship start date |
| end_date | DATE | NULL = currently active |
| notes | TEXT | Additional notes |
| created_at | TIMESTAMPTZ | Record creation timestamp |

### Addresses

Physical locations for entities and contacts.

| Column | Type | Description |
|--------|------|-------------|
| id | SERIAL | Primary key |
| entity_id | INTEGER | Reference to entities (optional) |
| contact_id | INTEGER | Reference to contacts (optional) |
| address_type | VARCHAR(50) | 'billing', 'shipping', 'headquarters', 'mailing' |
| street | TEXT | Street address |
| city | TEXT | City |
| state | TEXT | State/Province |
| postal_code | TEXT | Postal/ZIP code |
| country | TEXT | Country code (default: 'US') |
| is_primary | BOOLEAN | Primary address? |
| created_at | TIMESTAMPTZ | Record creation timestamp |

---

## Communications Layer

### Communications

All interactions (calls, emails, chats, meetings, tickets, notes).

| Column | Type | Description |
|--------|------|-------------|
| id | BIGSERIAL | Primary key |
| entity_id | INTEGER | Reference to entities |
| contact_id | INTEGER | Reference to contacts |
| communication_type | VARCHAR(50) | 'email', 'call', 'meeting', 'ticket', 'chat', 'note' |
| direction | VARCHAR(10) | 'inbound', 'outbound', 'internal' |
| subject | TEXT | Subject line |
| summary | TEXT | AI-generated summary (required) |
| full_content | TEXT | Full transcript (optional) |
| channel | VARCHAR(50) | Communication channel |
| started_at | TIMESTAMPTZ | When communication started |
| ended_at | TIMESTAMPTZ | When communication ended |
| duration_seconds | INTEGER | Duration in seconds |
| agent_id | VARCHAR(50) | AI agent identifier |
| human_agent_id | INTEGER | Human agent reference |
| sentiment_score | NUMERIC(3,2) | Sentiment score (-1 to 1) |
| sentiment_label | VARCHAR(20) | 'positive', 'neutral', 'negative' |
| outcome | VARCHAR(50) | 'resolved', 'escalated', 'pending', 'closed' |
| priority | VARCHAR(20) | 'low', 'normal', 'high', 'critical' |
| follow_up_required | BOOLEAN | Requires follow-up? |
| follow_up_date | DATE | Follow-up date |
| follow_up_action | TEXT | Required follow-up action |
| attachments | JSONB | Array of file references |
| parent_id | BIGINT | Parent communication (threading) |
| thread_root_id | BIGINT | Root of conversation thread |
| created_at | TIMESTAMPTZ | Record creation timestamp |
| updated_at | TIMESTAMPTZ | Last update timestamp |
| embedding | VECTOR(1536) | Semantic search embedding |

---

## Audit Logging

### Human Sessions

Tracks human agent login sessions.

| Column | Type | Description |
|--------|------|-------------|
| session_id | UUID | Primary key |
| user_id | VARCHAR(50) | Human user identifier |
| user_name | VARCHAR(100) | Human's display name |
| bot_id | VARCHAR(50) | Bot identifier |
| bot_type | VARCHAR(50) | Bot type (e.g., 'customer_service') |
| login_time | TIMESTAMPTZ | Session start time |
| logout_time | TIMESTAMPTZ | Session end time |
| ip_address | INET | Client IP address |
| user_agent | TEXT | Browser/client info |
| session_status | VARCHAR(20) | 'active', 'completed', 'terminated' |
| created_at | TIMESTAMPTZ | Record creation timestamp |
| updated_at | TIMESTAMPTZ | Last update timestamp |

### Bot Actions

Logs every action taken by AI agents.

| Column | Type | Description |
|--------|------|-------------|
| action_id | UUID | Primary key |
| session_id | UUID | Reference to human_sessions |
| user_id | VARCHAR(50) | Human user who commanded the bot |
| bot_id | VARCHAR(50) | Bot that performed the action |
| action_type | VARCHAR(50) | Type of action (e.g., 'query', 'update') |
| action_description | TEXT | Human-readable description |
| input_parameters | JSONB | Input parameters |
| output_result | JSONB | Result/output |
| success | BOOLEAN | Whether action succeeded |
| error_message | TEXT | Error if action failed |
| execution_time_ms | INTEGER | Execution time in milliseconds |
| timestamp | TIMESTAMPTZ | When action occurred |
| created_at | TIMESTAMPTZ | Record creation timestamp |

### Audit Summary

Daily aggregation of human-bot interactions.

| Column | Type | Description |
|--------|------|-------------|
| summary_id | UUID | Primary key |
| date | DATE | Summary date |
| user_id | VARCHAR(50) | Human user identifier |
| bot_id | VARCHAR(50) | Bot identifier |
| total_sessions | INTEGER | Total sessions for the day |
| total_actions | INTEGER | Total actions for the day |
| successful_actions | INTEGER | Successful actions count |
| failed_actions | INTEGER | Failed actions count |
| avg_session_duration_minutes | NUMERIC(10,2) | Average session duration |
| created_at | TIMESTAMPTZ | Record creation timestamp |

### Agent Interactions

Complete trajectory logging for debugging and analysis.

| Column | Type | Description |
|--------|------|-------------|
| id | UUID | Primary key |
| conversation_id | UUID | Conversation thread identifier |
| run_id | TEXT | LangChain run identifier |
| telegram_chat_id | TEXT | Telegram chat ID |
| telegram_message_id | BIGINT | Telegram message ID |
| bot_id | TEXT | Bot identifier |
| user_id | TEXT | User identifier |
| timestamp | TIMESTAMPTZ | Interaction timestamp |
| human_input | TEXT | Raw user input |
| intent_classification | TEXT | Detected intent |
| confidence_score | DOUBLE PRECISION | Model confidence |
| agent_thoughts | TEXT[] | Agent's reasoning steps |
| actions_taken | JSONB | Tool calls made |
| tool_observations | JSONB | Tool outputs |
| final_output | TEXT | Response sent to user |
| response_sources | JSONB | Data sources used |
| model_used | TEXT | LLM model identifier |
| token_usage | JSONB | Token counts |
| error_message | TEXT | Error if failed |
| duration_ms | INTEGER | Total duration |
| feedback_score | DOUBLE PRECISION | User rating (1-5) |
| created_at | TIMESTAMPTZ | Record creation timestamp |

---

## Inventory Tables

### Item Categories

Product category hierarchy.

| Column | Type | Description |
|--------|------|-------------|
| category_id | SERIAL | Primary key |
| category_code | VARCHAR(50) | Category code |
| name | TEXT | Category name |
| parent_category_id | INTEGER | Parent category reference |

### Inventory Items

Product catalog.

| Column | Type | Description |
|--------|------|-------------|
| item_id | SERIAL | Primary key |
| sku | VARCHAR(50) | Stock keeping unit (unique) |
| name | TEXT | Item name |
| category_id | INTEGER | Reference to item_categories |
| base_unit_of_measure | VARCHAR(50) | Unit of measure |
| standard_cost | NUMERIC(10,2) | Standard cost |
| safety_stock | INTEGER | Safety stock level |
| reorder_point | INTEGER | Reorder threshold |
| is_active | BOOLEAN | Active status |
| created_at | TIMESTAMPTZ | Record creation timestamp |
| updated_at | TIMESTAMPTZ | Last update timestamp |

### Warehouses

Storage locations.

| Column | Type | Description |
|--------|------|-------------|
| warehouse_id | SERIAL | Primary key |
| warehouse_code | VARCHAR(50) | Warehouse code |
| name | TEXT | Warehouse name |
| is_active | BOOLEAN | Active status |
| created_at | TIMESTAMPTZ | Record creation timestamp |

### Locations

Specific bins/shelves within warehouses.

| Column | Type | Description |
|--------|------|-------------|
| location_id | SERIAL | Primary key |
| warehouse_id | INTEGER | Reference to warehouses |
| location_code | VARCHAR(50) | Location code |
| zone | VARCHAR(50) | Zone identifier |
| aisle | VARCHAR(50) | Aisle identifier |
| bin | VARCHAR(50) | Bin identifier |
| created_at | TIMESTAMPTZ | Record creation timestamp |

### Inventory On Hand

Current stock levels.

| Column | Type | Description |
|--------|------|-------------|
| item_id | INTEGER | Reference to inventory_items |
| warehouse_id | INTEGER | Reference to warehouses |
| quantity_on_hand | INTEGER | Total quantity |
| quantity_available | INTEGER | Available quantity |
| quantity_reserved | INTEGER | Reserved quantity |
| last_updated | TIMESTAMPTZ | Last update timestamp |

### Inventory Movements

All stock changes.

| Column | Type | Description |
|--------|------|-------------|
| movement_id | BIGSERIAL | Primary key |
| movement_type | VARCHAR(50) | 'receipt', 'shipment', 'transfer', 'adjustment' |
| item_id | INTEGER | Reference to inventory_items |
| from_warehouse_id | INTEGER | Source warehouse (for transfers) |
| to_warehouse_id | INTEGER | Destination warehouse (for transfers) |
| quantity | INTEGER | Quantity moved (negative for out) |
| reference_type | VARCHAR(50) | Reference document type |
| reference_id | TEXT | Reference document ID |
| performed_at | TIMESTAMPTZ | When movement occurred |
| performed_by | VARCHAR(50) | Who performed the movement |

### Inventory Reservations

Allocated stock for orders.

| Column | Type | Description |
|--------|------|-------------|
| reservation_id | BIGSERIAL | Primary key |
| item_id | INTEGER | Reference to inventory_items |
| order_id | INTEGER | Reference to orders |
| warehouse_id | INTEGER | Reference to warehouses |
| reserved_quantity | INTEGER | Reserved quantity |
| shipped_quantity | INTEGER | Shipped quantity |
| remaining_quantity | INTEGER | Remaining to ship |
| created_at | TIMESTAMPTZ | Record creation timestamp |
| shipped_at | TIMESTAMPTZ | When shipped |

---

## Indexes

### Performance Indexes

```sql
-- Entity and contact indexes
CREATE INDEX idx_entities_embedding ON entities USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);
CREATE INDEX idx_contacts_embedding ON contacts USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);

-- Communication indexes
CREATE INDEX idx_comm_entity ON communications (entity_id);
CREATE INDEX idx_comm_contact ON communications (contact_id);
CREATE INDEX idx_comm_thread_root ON communications (thread_root_id);
CREATE INDEX idx_comm_created ON communications (created_at);
CREATE INDEX idx_comm_type ON communications (communication_type);

-- Audit logging indexes
CREATE INDEX idx_human_sessions_user_id ON human_sessions (user_id);
CREATE INDEX idx_human_sessions_bot_id ON human_sessions (bot_id);
CREATE INDEX idx_human_sessions_login_time ON human_sessions (login_time);
CREATE INDEX idx_bot_actions_session_id ON bot_actions (session_id);
CREATE INDEX idx_bot_actions_user_id ON bot_actions (user_id);
CREATE INDEX idx_bot_actions_bot_id ON bot_actions (bot_id);
CREATE INDEX idx_bot_actions_timestamp ON bot_actions (timestamp);

-- Agent interaction indexes
CREATE INDEX idx_actions ON agent_interactions USING gin (actions_taken);
CREATE INDEX idx_conv ON agent_interactions (conversation_id);
CREATE INDEX idx_timestamp ON agent_interactions (timestamp DESC);
CREATE INDEX idx_user ON agent_interactions (user_id);

-- Audit summary indexes
CREATE INDEX idx_audit_summary_date ON audit_summary (date);
CREATE INDEX idx_audit_summary_user_bot ON audit_summary (user_id, bot_id);

-- Inventory indexes
CREATE INDEX idx_inventory_item_warehouse ON inventory_on_hand (item_id, warehouse_id);
CREATE INDEX idx_inventory_movements_item ON inventory_movements (item_id, performed_at);
```

---

## Views

See [views.md](./views.md) for complete view documentation.

---

## Schema Graph

The `_schema_graph` table contains a knowledge graph of the entire schema for AI agent understanding.

Query this table to understand the system structure:

```sql
SELECT * FROM _schema_graph;
```

---

*Generated for Agent First ERP CRM - Complete schema reference for AI agents and developers*