# Database Schema Design (Enterprise Edition v2.0)

This document outlines the PostgreSQL schema with PGVector support for the Agent First ERP CRM.
**Design Philosophy:** Enterprise-grade, mirroring SAP/Oracle/Infor patterns.

## Core Concepts
- **Entity:** A business organization OR an individual that transacts (Customer, Vendor, Prospect, Employee).
- **Contact:** A specific human being.
- **Relationship:** The link between a Contact and an Entity (e.g., "Jane is Procurement Manager at Bob's Small Engines").

---

## Core Tables

### 1. `_schema_graph` (Knowledge Graph)
Knowledge graph of the entire schema for AI agent understanding.

```sql
CREATE TABLE _schema_graph (
    node_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    node_type VARCHAR(50) NOT NULL,
    node_name VARCHAR(255) NOT NULL,
    description TEXT,
    properties JSONB,
    relationships JSONB,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);
```

### 2. `entities` (Business Entities)
Stores business entities (companies or individuals) that transact with us.

```sql
CREATE TABLE entities (
    id SERIAL PRIMARY KEY,
    entity_type VARCHAR(50) DEFAULT 'customer' NOT NULL,  -- 'customer', 'vendor', 'prospect', 'employee'
    name TEXT NOT NULL,                                    -- Display name
    legal_name TEXT,                                       -- Legal business name (NULL for individuals)
    tax_id VARCHAR(50),                                    -- EIN, VAT ID, SSN (encrypted in prod)
    industry VARCHAR(100),                                 -- Optional: "Automotive", "Healthcare"
    website TEXT,
    status TEXT DEFAULT 'active',                          -- active, inactive, blacklisted
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now(),
    embedding VECTOR(1536)                                 -- For semantic search
);
```

### 3. `contacts` (Individual Humans)
Stores individual human beings.

```sql
CREATE TABLE contacts (
    id SERIAL PRIMARY KEY,
    first_name TEXT NOT NULL,
    last_name TEXT NOT NULL,
    email TEXT,
    phone TEXT,
    title TEXT,                    -- Job title
    status TEXT DEFAULT 'active',
    preferences JSONB,             -- Communication preferences
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now(),
    embedding VECTOR(1536)         -- For semantic search
);
```

### 4. `entity_relationships` (Contact-Entity Links)
Defines how contacts relate to entities.

```sql
CREATE TABLE entity_relationships (
    id SERIAL PRIMARY KEY,
    entity_id INTEGER NOT NULL REFERENCES entities(id),
    contact_id INTEGER NOT NULL REFERENCES contacts(id),
    role VARCHAR(100),             -- "Procurement Manager", "Owner"
    is_primary BOOLEAN DEFAULT FALSE,
    start_date DATE,
    end_date DATE,                 -- NULL = currently active
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE(entity_id, contact_id)
);

CREATE INDEX idx_primary_contact ON entity_relationships(entity_id) WHERE is_primary = TRUE;
```

### 5. `addresses` (Multiple Addresses)
Supports multiple addresses per entity or contact.

```sql
CREATE TABLE addresses (
    id SERIAL PRIMARY KEY,
    entity_id INTEGER REFERENCES entities(id),
    contact_id INTEGER REFERENCES contacts(id),
    address_type VARCHAR(50),      -- 'billing', 'shipping', 'headquarters', 'mailing', 'home'
    street TEXT,
    city TEXT,
    state TEXT,
    postal_code TEXT,
    country TEXT DEFAULT 'US',
    is_primary BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_addresses_entity ON addresses(entity_id);
CREATE INDEX idx_addresses_contact ON addresses(contact_id);
```

---

## Communications & Follow-ups

### 6. `communications` (All Interactions)
Conversation logs, support tickets, and all interactions.

```sql
CREATE TABLE communications (
    id BIGSERIAL PRIMARY KEY,
    entity_id INTEGER NOT NULL REFERENCES entities(id),
    contact_id INTEGER REFERENCES contacts(id),
    communication_type VARCHAR(50) NOT NULL,  -- 'email', 'call', 'meeting', 'ticket', 'chat', 'note'
    direction VARCHAR(10) NOT NULL,           -- 'inbound', 'outbound', 'internal'
    subject TEXT,
    summary TEXT NOT NULL,                    -- AI-generated summary
    full_content TEXT,                        -- Full transcript (optional)
    channel VARCHAR(50),                      -- Communication channel
    started_at TIMESTAMPTZ DEFAULT now() NOT NULL,
    ended_at TIMESTAMPTZ,
    duration_seconds INTEGER,
    agent_id VARCHAR(50),                     -- AI agent that handled it
    human_agent_id INTEGER REFERENCES contacts(id),
    sentiment_score NUMERIC(3,2),
    sentiment_label VARCHAR(20),
    outcome VARCHAR(50),                      -- 'resolved', 'escalated', 'pending', 'closed'
    priority VARCHAR(20),
    follow_up_required BOOLEAN DEFAULT FALSE,
    follow_up_date DATE,
    follow_up_action TEXT,
    attachments JSONB DEFAULT '[]',           -- Array of file references
    parent_id INTEGER REFERENCES communications(id),  -- Threading
    thread_root_id INTEGER,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now(),
    embedding VECTOR(1536)
);

CREATE INDEX idx_comm_entity ON communications(entity_id);
CREATE INDEX idx_comm_contact ON communications(contact_id);
CREATE INDEX idx_comm_type ON communications(communication_type);
CREATE INDEX idx_comms_direction ON communications(direction);
CREATE INDEX idx_comms_outcome ON communications(outcome);
CREATE INDEX idx_comms_priority ON communications(priority);
CREATE INDEX idx_comms_sentiment ON communications(sentiment_label);
CREATE INDEX idx_comms_followup ON communications(follow_up_required, follow_up_date) WHERE follow_up_required = TRUE;
CREATE INDEX idx_comms_thread_root ON communications(thread_root_id);
CREATE INDEX idx_comms_parent ON communications(parent_id);
CREATE INDEX idx_comms_embedding ON communications USING ivfflat (embedding vector_cosine_ops) WITH (lists=100);
```

### 7. `followups` (Follow-up Tasks)
Standalone follow-up task tracking.

```sql
CREATE TABLE followups (
    id BIGSERIAL PRIMARY KEY,
    entity_id INTEGER NOT NULL REFERENCES entities(id),
    contact_id INTEGER REFERENCES contacts(id),
    description TEXT NOT NULL,
    due_date TIMESTAMPTZ,
    priority VARCHAR(20) DEFAULT 'medium',    -- 'low', 'medium', 'high'
    status VARCHAR(20) DEFAULT 'pending',     -- 'pending', 'completed', 'cancelled'
    completed_at TIMESTAMPTZ,
    completion_notes TEXT,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_followup_entity ON followups(entity_id);
CREATE INDEX idx_followup_status ON followups(status);
```

---

## Inventory Management

### 8. `item_categories` (Product Categories)
Hierarchical inventory categories.

```sql
CREATE TABLE item_categories (
    category_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    category_code VARCHAR(50) NOT NULL UNIQUE,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    parent_category_id UUID REFERENCES item_categories(category_id) ON DELETE SET NULL,
    category_level INTEGER DEFAULT 1,
    default_cost_method VARCHAR(20) DEFAULT 'AVERAGE',
    default_reorder_point NUMERIC(12,4) DEFAULT 0,
    default_safety_stock NUMERIC(12,4) DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT now() NOT NULL
);

CREATE INDEX idx_categories_code ON item_categories(category_code);
CREATE INDEX idx_categories_parent ON item_categories(parent_category_id);
```

### 9. `inventory_items` (Products/Items)
Product catalog with detailed inventory tracking.

```sql
CREATE TABLE inventory_items (
    item_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sku VARCHAR(50) NOT NULL UNIQUE,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    category_id UUID REFERENCES item_categories(category_id),
    product_type VARCHAR(50) DEFAULT 'STOCKED' NOT NULL,
    item_group VARCHAR(100),
    base_unit_of_measure VARCHAR(20) DEFAULT 'EACH' NOT NULL,
    weight NUMERIC(12,4),
    weight_unit VARCHAR(20) DEFAULT 'KG',
    dimensions_length NUMERIC(10,2),
    dimensions_width NUMERIC(10,2),
    dimensions_height NUMERIC(10,2),
    dimension_unit VARCHAR(20) DEFAULT 'CM',
    cost_method VARCHAR(20) DEFAULT 'AVERAGE' NOT NULL,
    standard_cost NUMERIC(12,4),
    last_cost NUMERIC(12,4),
    currency_code CHAR(3) DEFAULT 'USD' NOT NULL,
    reorder_point NUMERIC(12,4) DEFAULT 0,
    reorder_quantity NUMERIC(12,4),
    safety_stock NUMERIC(12,4) DEFAULT 0,
    lead_time_days INTEGER DEFAULT 0,
    min_order_qty NUMERIC(12,4),
    order_multiple NUMERIC(12,4) DEFAULT 1,
    is_active BOOLEAN DEFAULT true NOT NULL,
    is_serialized BOOLEAN DEFAULT false NOT NULL,
    is_lot_controlled BOOLEAN DEFAULT false NOT NULL,
    shelf_life_days INTEGER,
    created_by VARCHAR(100),
    created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT now() NOT NULL,
    version INTEGER DEFAULT 1 NOT NULL,
    CONSTRAINT chk_cost_positive CHECK (standard_cost >= 0 AND last_cost >= 0),
    CONSTRAINT chk_sku_format CHECK (sku ~ '^[A-Z0-9-]+$')
);

CREATE INDEX idx_inventory_items_sku ON inventory_items(sku);
CREATE INDEX idx_inventory_items_category ON inventory_items(category_id);
CREATE INDEX idx_inventory_items_active ON inventory_items(is_active) WHERE is_active = true;
CREATE INDEX idx_inventory_items_group ON inventory_items(item_group) WHERE is_active = true;
```

### 10. `warehouses` (Warehouse Locations)
Warehouse/fulfillment center management.

```sql
CREATE TABLE warehouses (
    warehouse_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    warehouse_code VARCHAR(50) NOT NULL UNIQUE,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    parent_warehouse_id UUID REFERENCES warehouses(warehouse_id) ON DELETE SET NULL,
    warehouse_type VARCHAR(50) DEFAULT 'PRIMARY' NOT NULL,
    address_line1 VARCHAR(255),
    city VARCHAR(100),
    state VARCHAR(100),
    postal_code VARCHAR(20),
    country CHAR(2) DEFAULT 'US',
    is_active BOOLEAN DEFAULT true NOT NULL,
    allows_negative BOOLEAN DEFAULT false NOT NULL,
    default_warehouse BOOLEAN DEFAULT false NOT NULL,
    timezone VARCHAR(50) DEFAULT 'America/Chicago',
    created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT now() NOT NULL
);

CREATE INDEX idx_warehouses_code ON warehouses(warehouse_code);
CREATE INDEX idx_warehouses_active ON warehouses(is_active) WHERE is_active = true;
CREATE INDEX idx_warehouses_parent ON warehouses(parent_warehouse_id);
```

### 11. `locations` (Storage Locations)
Storage locations within warehouses (zones, aisles, bins).

```sql
CREATE TABLE locations (
    location_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    warehouse_id UUID NOT NULL REFERENCES warehouses(warehouse_id) ON DELETE CASCADE,
    location_code VARCHAR(50) NOT NULL,
    zone VARCHAR(50),
    aisle VARCHAR(20),
    rack VARCHAR(20),
    shelf VARCHAR(20),
    bin VARCHAR(20),
    location_type VARCHAR(50) DEFAULT 'STORAGE' NOT NULL,
    capacity_units NUMERIC(12,4),
    is_active BOOLEAN DEFAULT true NOT NULL,
    created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT now() NOT NULL,
    UNIQUE(warehouse_id, location_code)
);

CREATE INDEX idx_locations_warehouse ON locations(warehouse_id);
CREATE INDEX idx_locations_code ON locations(warehouse_id, location_code);
CREATE INDEX idx_locations_type ON locations(location_type) WHERE is_active = true;
```

### 12. `inventory_on_hand` (Current Stock Levels)
Current inventory levels with lot/serial tracking.

```sql
CREATE TABLE inventory_on_hand (
    on_hand_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    item_id UUID NOT NULL REFERENCES inventory_items(item_id) ON DELETE CASCADE,
    warehouse_id UUID NOT NULL REFERENCES warehouses(warehouse_id) ON DELETE CASCADE,
    location_id UUID REFERENCES locations(location_id) ON DELETE SET NULL,
    quantity_on_hand NUMERIC(12,4) DEFAULT 0 NOT NULL,
    quantity_available NUMERIC(12,4) DEFAULT 0 NOT NULL,
    quantity_reserved NUMERIC(12,4) DEFAULT 0 NOT NULL,
    quantity_in_transit NUMERIC(12,4) DEFAULT 0 NOT NULL,
    quantity_damaged NUMERIC(12,4) DEFAULT 0 NOT NULL,
    lot_number VARCHAR(100),
    serial_numbers JSONB,
    expiry_date DATE,
    average_cost NUMERIC(12,4),
    cost_currency CHAR(3) DEFAULT 'USD' NOT NULL,
    last_counted_at TIMESTAMPTZ,
    last_movement_at TIMESTAMPTZ DEFAULT now() NOT NULL,
    version INTEGER DEFAULT 1 NOT NULL,
    CONSTRAINT chk_available_calculation CHECK (quantity_available = quantity_on_hand - quantity_reserved),
    CONSTRAINT chk_quantities_non_negative CHECK (quantity_on_hand >= 0 AND quantity_available >= 0 AND quantity_reserved >= 0)
);

CREATE INDEX idx_on_hand_item ON inventory_on_hand(item_id);
CREATE INDEX idx_on_hand_warehouse ON inventory_on_hand(warehouse_id);
CREATE INDEX idx_on_hand_location ON inventory_on_hand(location_id);
CREATE INDEX idx_on_hand_available ON inventory_on_hand(item_id, quantity_available) WHERE quantity_available > 0;
CREATE INDEX idx_on_hand_expiry ON inventory_on_hand(expiry_date) WHERE expiry_date IS NOT NULL;
CREATE INDEX idx_on_hand_low_stock ON inventory_on_hand(item_id, quantity_available);
```

### 13. `inventory_movements` (Stock Movements)
Stock movement tracking with batch support.

```sql
CREATE TABLE inventory_movements (
    movement_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    movement_type VARCHAR(50) NOT NULL,           -- 'RECEIPT', 'ISSUE', 'TRANSFER', 'ADJUSTMENT', 'RESERVATION'
    reference_type VARCHAR(50),                   -- 'ORDER', 'PO', 'TRANSFER'
    reference_id UUID,
    item_id UUID NOT NULL REFERENCES inventory_items(item_id) ON DELETE RESTRICT,
    from_warehouse_id UUID REFERENCES warehouses(warehouse_id),
    from_location_id UUID REFERENCES locations(location_id),
    to_warehouse_id UUID NOT NULL REFERENCES warehouses(warehouse_id),
    to_location_id UUID REFERENCES locations(location_id),
    quantity NUMERIC(12,4) NOT NULL,
    unit_of_measure VARCHAR(20) NOT NULL,
    conversion_factor NUMERIC(12,6) DEFAULT 1.0,
    unit_cost NUMERIC(12,4),
    total_cost NUMERIC(15,4),
    currency_code CHAR(3) DEFAULT 'USD' NOT NULL,
    lot_number VARCHAR(100),
    serial_number VARCHAR(255),
    reason_code VARCHAR(50),
    notes TEXT,
    performed_by VARCHAR(100) NOT NULL,
    performed_at TIMESTAMPTZ DEFAULT now() NOT NULL,
    batch_id UUID,
    transaction_id UUID DEFAULT gen_random_uuid(),
    CONSTRAINT chk_quantity_nonzero CHECK (quantity <> 0)
);

CREATE INDEX idx_movements_date ON inventory_movements(performed_at DESC);
CREATE INDEX idx_movements_item ON inventory_movements(item_id);
CREATE INDEX idx_movements_type_date ON inventory_movements(movement_type, performed_at DESC);
CREATE INDEX idx_movements_reference ON inventory_movements(reference_type, reference_id);
CREATE INDEX idx_movements_batch ON inventory_movements(batch_id);
CREATE INDEX idx_movements_warehouse ON inventory_movements(to_warehouse_id);

-- Row Level Security
ALTER TABLE inventory_movements ENABLE ROW LEVEL SECURITY;
CREATE POLICY agent_movement_insert_policy ON inventory_movements FOR INSERT TO PUBLIC 
    WITH CHECK (performed_by = current_setting('app.current_agent', true));
CREATE POLICY agent_movement_view_policy ON inventory_movements FOR SELECT TO PUBLIC USING (true);
```

### 14. `inventory_reservations` (Stock Reservations)
Inventory reservation system for orders.

```sql
CREATE TABLE inventory_reservations (
    reservation_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    item_id UUID NOT NULL REFERENCES inventory_items(item_id) ON DELETE CASCADE,
    warehouse_id UUID NOT NULL REFERENCES warehouses(warehouse_id) ON DELETE CASCADE,
    location_id UUID REFERENCES locations(location_id),
    order_type VARCHAR(50) NOT NULL,
    order_id UUID NOT NULL,
    order_line_id UUID,
    reserved_quantity NUMERIC(12,4) NOT NULL,
    shipped_quantity NUMERIC(12,4) DEFAULT 0,
    cancelled_quantity NUMERIC(12,4) DEFAULT 0,
    lot_number VARCHAR(100),
    serial_numbers JSONB,
    priority INTEGER DEFAULT 1,
    reserved_at TIMESTAMPTZ DEFAULT now() NOT NULL,
    expected_ship_date DATE,
    reserved_by VARCHAR(100),
    notes TEXT,
    CONSTRAINT chk_reservation_quantities CHECK ((shipped_quantity + cancelled_quantity) <= reserved_quantity)
);

CREATE INDEX idx_reservations_item ON inventory_reservations(item_id);
CREATE INDEX idx_reservations_order ON inventory_reservations(order_type, order_id);
CREATE INDEX idx_reservations_priority ON inventory_reservations(item_id, priority);
CREATE INDEX idx_reservations_ship_date ON inventory_reservations(expected_ship_date) WHERE expected_ship_date IS NOT NULL;

-- Row Level Security
ALTER TABLE inventory_reservations ENABLE ROW LEVEL SECURITY;
CREATE POLICY agent_reservation_policy ON inventory_reservations TO PUBLIC 
    USING (reserved_by = current_setting('app.current_agent', true));
```

---

## Audit & Agent Tracking

### 15. `human_sessions` (Human Agent Sessions)
Tracks when human agents log in and start sessions.

```sql
CREATE TABLE human_sessions (
    session_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id VARCHAR(50) NOT NULL,
    user_name VARCHAR(100) NOT NULL,
    bot_id VARCHAR(50) NOT NULL,
    bot_type VARCHAR(50) NOT NULL,
    login_time TIMESTAMPTZ DEFAULT now() NOT NULL,
    logout_time TIMESTAMPTZ,
    ip_address INET,
    user_agent TEXT,
    session_status VARCHAR(20) DEFAULT 'active' NOT NULL,
    contact_id INTEGER REFERENCES contacts(id),
    entity_id INTEGER REFERENCES entities(id),
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_human_sessions_user_id ON human_sessions(user_id);
CREATE INDEX idx_human_sessions_bot_id ON human_sessions(bot_id);
CREATE INDEX idx_human_sessions_login_time ON human_sessions(login_time);
CREATE INDEX idx_human_sessions_status ON human_sessions(session_status);
CREATE INDEX idx_human_sessions_user_bot ON human_sessions(user_id, bot_id);
```

### 16. `bot_actions` (Bot Action Logging)
Logs every action taken by a bot during a human session.

```sql
CREATE TABLE bot_actions (
    action_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id UUID NOT NULL REFERENCES human_sessions(session_id) ON DELETE CASCADE,
    user_id VARCHAR(50) NOT NULL,
    bot_id VARCHAR(50) NOT NULL,
    action_type VARCHAR(50) NOT NULL,
    action_description TEXT,
    input_parameters JSONB,
    output_result JSONB,
    success BOOLEAN NOT NULL,
    error_message TEXT,
    execution_time_ms INTEGER,
    timestamp TIMESTAMPTZ DEFAULT now() NOT NULL,
    contact_id INTEGER REFERENCES contacts(id),
    entity_id INTEGER REFERENCES entities(id),
    created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_bot_actions_session_id ON bot_actions(session_id);
CREATE INDEX idx_bot_actions_user_id ON bot_actions(user_id);
CREATE INDEX idx_bot_actions_bot_id ON bot_actions(bot_id);
CREATE INDEX idx_bot_actions_timestamp ON bot_actions(timestamp);
CREATE INDEX idx_bot_actions_action_type ON bot_actions(action_type);
CREATE INDEX idx_bot_actions_success ON bot_actions(success);
CREATE INDEX idx_bot_actions_session_user ON bot_actions(session_id, user_id);
```

### 17. `agent_interactions` (Full Trajectory Logging)
Complete agent trajectory logging for debugging and analysis.

```sql
CREATE TABLE agent_interactions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID NOT NULL,
    run_id TEXT NOT NULL,
    telegram_chat_id TEXT,
    telegram_message_id BIGINT,
    bot_id TEXT,
    user_id TEXT,
    timestamp TIMESTAMPTZ DEFAULT now(),
    human_input TEXT,
    intent_classification TEXT,
    confidence_score DOUBLE PRECISION,
    agent_thoughts TEXT[],
    actions_taken JSONB,
    tool_observations JSONB,
    final_output TEXT,
    response_sources JSONB,
    model_used TEXT,
    token_usage JSONB,
    error_message TEXT,
    duration_ms INTEGER,
    feedback_score DOUBLE PRECISION,
    created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_conv ON agent_interactions(conversation_id);
CREATE INDEX idx_timestamp ON agent_interactions(timestamp DESC);
CREATE INDEX idx_user ON agent_interactions(user_id);
CREATE INDEX idx_actions ON agent_interactions USING GIN (actions_taken);
```

### 18. `audit_summary` (Daily Aggregation)
Daily summary of human-bot interactions.

```sql
CREATE TABLE audit_summary (
    summary_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    date DATE NOT NULL,
    user_id VARCHAR(50) NOT NULL,
    bot_id VARCHAR(50) NOT NULL,
    total_sessions INTEGER DEFAULT 0 NOT NULL,
    total_actions INTEGER DEFAULT 0 NOT NULL,
    successful_actions INTEGER DEFAULT 0 NOT NULL,
    failed_actions INTEGER DEFAULT 0 NOT NULL,
    avg_session_duration_minutes NUMERIC(10,2),
    created_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE(date, user_id, bot_id)
);

CREATE INDEX idx_audit_summary_date ON audit_summary(date);
CREATE INDEX idx_audit_summary_user_bot ON audit_summary(user_id, bot_id);
```

---

## Stored Functions

### Customer Functions

**`add_customer()`** - Add new customers (individual or business)
```sql
-- Overload 1: Simple version
add_customer(
    p_first_name TEXT, p_last_name TEXT, p_email TEXT, p_phone TEXT,
    p_street TEXT DEFAULT NULL, p_city TEXT DEFAULT NULL,
    p_state TEXT DEFAULT NULL, p_postal_code TEXT DEFAULT NULL,
    p_country TEXT DEFAULT 'US', p_status TEXT DEFAULT 'active'
) RETURNS TABLE(success BOOLEAN, entity_id INTEGER, contact_id INTEGER, message TEXT)

-- Overload 2: Extended version with entity type
add_customer(
    p_first_name TEXT DEFAULT NULL, p_last_name TEXT DEFAULT NULL,
    p_email TEXT DEFAULT NULL, p_phone TEXT DEFAULT NULL,
    p_street TEXT DEFAULT NULL, p_city TEXT DEFAULT NULL,
    p_state TEXT DEFAULT NULL, p_postal_code TEXT DEFAULT NULL,
    p_country TEXT DEFAULT 'US', p_status TEXT DEFAULT 'active',
    p_entity_type TEXT DEFAULT 'individual',
    p_organization_name TEXT DEFAULT NULL,
    p_address_type TEXT DEFAULT 'home',
    p_is_primary BOOLEAN DEFAULT true
) RETURNS TABLE(success BOOLEAN, entity_id INTEGER, contact_id INTEGER, message TEXT)
```

**`update_customer()`** - Update existing customer information
```sql
update_customer(
    p_search_name TEXT,
    p_search_email TEXT DEFAULT NULL,
    p_search_phone TEXT DEFAULT NULL,
    p_first_name TEXT DEFAULT NULL,
    p_last_name TEXT DEFAULT NULL,
    p_email TEXT DEFAULT NULL,
    p_phone TEXT DEFAULT NULL,
    p_street TEXT DEFAULT NULL,
    p_city TEXT DEFAULT NULL,
    p_state TEXT DEFAULT NULL,
    p_postal_code TEXT DEFAULT NULL,
    p_country TEXT DEFAULT NULL,
    p_status TEXT DEFAULT NULL
) RETURNS TABLE(success BOOLEAN, entity_id INTEGER, contact_id INTEGER, message TEXT)
```

**`get_followup_customers()`** - Get customers requiring follow-up
```sql
get_followup_customers(p_days_threshold INTEGER DEFAULT 7)
RETURNS TABLE(entity_id INTEGER, name TEXT, email TEXT, phone TEXT, 
              last_communication_date TIMESTAMPTZ, follow_up_reason TEXT)
```

### Inventory Functions

**`execute_inventory_movement()`** - Execute inventory movement
```sql
execute_inventory_movement(
    p_movement_type VARCHAR,
    p_item_id UUID,
    p_from_warehouse_id UUID,
    p_to_warehouse_id UUID,
    p_quantity NUMERIC,
    p_unit_cost NUMERIC,
    p_performed_by VARCHAR,
    p_reference_type VARCHAR,
    p_reference_id UUID,
    p_reason_code VARCHAR
) RETURNS UUID
```

**`reserve_inventory_for_order()`** - Reserve inventory for an order
```sql
reserve_inventory_for_order(
    p_item_id UUID,
    p_warehouse_id UUID,
    p_quantity NUMERIC,
    p_order_type VARCHAR,
    p_order_id UUID,
    p_reserved_by VARCHAR
) RETURNS TABLE(reservation_id UUID, status VARCHAR, message TEXT)
```

### Utility Functions

**`split_name()`** - Split full name into first and last name
```sql
split_name(full_name TEXT) RETURNS TABLE(first_name TEXT, last_name TEXT)
```

**`update_updated_at_column()`** - Trigger function for auto-updating timestamps
```sql
update_updated_at_column() RETURNS TRIGGER
```

**`update_communications_updated_at()`** - Trigger for communications table
```sql
update_communications_updated_at() RETURNS TRIGGER
```

**`update_on_hand_consistency()`** - Trigger for inventory_on_hand consistency
```sql
update_on_hand_consistency() RETURNS TRIGGER
```

---

## Triggers

```sql
-- Auto-update updated_at timestamps
CREATE TRIGGER update_human_sessions_updated_at
    BEFORE UPDATE ON human_sessions
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_communications_updated_at
    BEFORE UPDATE ON communications
    FOR EACH ROW EXECUTE FUNCTION update_communications_updated_at();

CREATE TRIGGER trg_on_hand_consistency
    BEFORE INSERT OR UPDATE ON inventory_on_hand
    FOR EACH ROW EXECUTE FUNCTION update_on_hand_consistency();
```

---

## Database Views

The schema includes numerous views for agent-friendly queries. See [README_VIEWS.md](README_VIEWS.md) for complete documentation.

Key views include:
- `vw_customers` - Customer entity overview
- `vw_customer_communications_summary` - Customer interactions with context
- `vw_recent_communications` - Last 7 days of communications
- `vw_pending_followups` - Tasks requiring action
- `vw_entity_communication_stats` - Customer health metrics
- `vw_inventory_valuation` - Inventory value by warehouse/category
- `vw_item_availability` - Stock levels across warehouses
- `vw_item_movement_summary` - 30-day item movement patterns
- `vw_low_stock_alerts` - Items below reorder point

---

*This schema is designed to be extended. New tables can be added as new agents (HR, Accounting, etc.) are introduced.*