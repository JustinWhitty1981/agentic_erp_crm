# Database Schema Design (Enterprise Edition v2.0)

This document outlines the PostgreSQL schema with PGVector support for the Agent First ERP CRM.
**Design Philosophy:** Enterprise-grade, mirroring SAP/Oracle/Infor patterns.

## Core Concepts
- **Entity:** A business organization OR an individual that transacts (Customer, Vendor, Prospect, Employee).
- **Contact:** A specific human being.
- **Relationship:** The link between a Contact and an Entity (e.g., "Jane is Procurement Manager at Bob's Small Engines").

## Core Tables

### 1. `entities` (Replaces `customers`)
Stores business entities (companies or individuals) that transact with us.
```sql
CREATE TABLE agent_first_erp_crm.entities (
    id SERIAL PRIMARY KEY,
    entity_type VARCHAR(50) NOT NULL,       -- 'customer', 'vendor', 'prospect', 'employee'
    name TEXT NOT NULL,                     -- Display name (Company Name or Full Name)
    legal_name TEXT,                        -- Legal business name (NULL for individuals)
    tax_id VARCHAR(50),                     -- EIN, VAT ID, SSN (encrypted in prod)
    industry VARCHAR(100),                  -- Optional: "Automotive", "Healthcare"
    website TEXT,
    status TEXT DEFAULT 'active',           -- active, inactive, blacklisted
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    embedding VECTOR(1536)                  -- For semantic search on entity details
);
```

### 2. `contacts`
Stores individual human beings.
```sql
CREATE TABLE agent_first_erp_crm.contacts (
    id SERIAL PRIMARY KEY,
    first_name TEXT NOT NULL,
    last_name TEXT NOT NULL,
    email TEXT,
    phone TEXT,
    title TEXT,                             -- Job title
    status TEXT DEFAULT 'active',
    preferences JSONB,                      -- Communication preferences
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    embedding VECTOR(1536)                  -- For semantic search on person's history/preferences
);
```

### 3. `entity_relationships`
Defines how contacts relate to entities.
```sql
CREATE TABLE agent_first_erp_crm.entity_relationships (
    id SERIAL PRIMARY KEY,
    entity_id INTEGER NOT NULL REFERENCES agent_first_erp_crm.entities(id),
    contact_id INTEGER NOT NULL REFERENCES agent_first_erp_crm.contacts(id),
    role VARCHAR(100),                      -- "Procurement Manager", "Owner"
    is_primary BOOLEAN DEFAULT FALSE,       -- Main point of contact?
    start_date DATE,
    end_date DATE,                          -- NULL = currently active
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(entity_id, contact_id)
);

CREATE INDEX idx_primary_contact ON agent_first_erp_crm.entity_relationships(entity_id) 
WHERE is_primary = TRUE;
```

### 4. `addresses`
Supports multiple addresses per entity or contact (billing, shipping, HQ).
```sql
CREATE TABLE agent_first_erp_crm.addresses (
    id SERIAL PRIMARY KEY,
    entity_id INTEGER REFERENCES agent_first_erp_crm.entities(id),
    contact_id INTEGER REFERENCES agent_first_erp_crm.contacts(id), -- Optional: Address for a specific person
    address_type VARCHAR(50),               -- 'billing', 'shipping', 'headquarters', 'mailing'
    street TEXT,
    city TEXT,
    state TEXT,
    postal_code TEXT,
    country TEXT DEFAULT 'US',
    is_primary BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_addresses_entity ON agent_first_erp_crm.addresses(entity_id);
CREATE INDEX idx_addresses_contact ON agent_first_erp_crm.addresses(contact_id);
```

### 5. `orders` (Placeholder for future implementation)
Stores order details and context.
```sql
CREATE TABLE agent_first_erp_crm.orders (
    id SERIAL PRIMARY KEY,
    entity_id INTEGER REFERENCES agent_first_erp_crm.entities(id), -- Changed from customer_id
    status TEXT DEFAULT 'pending',
    total NUMERIC(10, 2),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    embedding VECTOR(1536)
);
```

### 6. `products`
Product catalog with inventory tracking.
```sql
CREATE TABLE agent_first_erp_crm.products (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    sku TEXT UNIQUE,
    price NUMERIC(10, 2),
    stock INTEGER DEFAULT 0,
    minimum_order_quantity INTEGER DEFAULT 10,
    description TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    embedding VECTOR(1536) -- For semantic search on product features
);
```

### 7. `communications`
Conversation logs and support tickets.
```sql
CREATE TABLE agent_first_erp_crm.communications (
    id BIGSERIAL PRIMARY KEY,
    entity_id INTEGER NOT NULL REFERENCES agent_first_erp_crm.entities(id),
    contact_id INTEGER REFERENCES agent_first_erp_crm.contacts(id),
    communication_type VARCHAR(50), -- 'email', 'call', 'meeting', 'ticket', 'chat', 'note'
    direction VARCHAR(20),          -- 'inbound', 'outbound', 'internal'
    subject TEXT,
    summary TEXT NOT NULL,          -- AI-generated summary
    full_content TEXT,              -- Full transcript (optional)
    attachments JSONB,              -- Array of file references (NOT BLOBs)
    parent_id BIGINT REFERENCES agent_first_erp_crm.communications(id), -- Threading
    thread_root_id BIGINT,          -- Root of conversation thread
    sentiment_score FLOAT,
    sentiment_label VARCHAR(20),
    outcome VARCHAR(50),            -- 'resolved', 'escalated', 'pending', 'closed'
    follow_up_required BOOLEAN DEFAULT FALSE,
    follow_up_date DATE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    embedding VECTOR(1536) -- For semantic search on content
);

CREATE INDEX idx_communications_entity ON agent_first_erp_crm.communications(entity_id);
CREATE INDEX idx_communications_contact ON agent_first_erp_crm.communications(contact_id);
CREATE INDEX idx_communications_thread_root ON agent_first_erp_crm.communications(thread_root_id);
CREATE INDEX idx_communications_embedding ON agent_first_erp_crm.communications USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);
```

### 8. `tickets`
Support ticket tracking.
```sql
CREATE TABLE agent_first_erp_crm.tickets (
    id BIGSERIAL PRIMARY KEY,
    entity_id INTEGER REFERENCES agent_first_erp_crm.entities(id),
    contact_id INTEGER REFERENCES agent_first_erp_crm.contacts(id),
    agent_id TEXT, -- e.g., 'cs_agent_01', 'inventory_agent'
    subject TEXT,
    message TEXT,
    status TEXT DEFAULT 'open', -- open, resolved, escalated
    priority VARCHAR(20) DEFAULT 'normal',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    embedding VECTOR(1536) -- For semantic search on ticket content
);
```

### 9. `agents`
Registry of all agents, their roles, and permissions.
```sql
CREATE TABLE agent_first_erp_crm.agents (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL, -- e.g., 'Customer Service', 'Inventory'
    role TEXT NOT NULL,
    api_key TEXT UNIQUE, -- For authentication
    permissions JSONB, -- e.g., {"read": ["customers", "orders"], "write": ["tickets"]}
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);
```

### 10. `human_sessions` (Audit Logging)
Tracks when human agents log in and start sessions with bots.

```sql
CREATE TABLE agent_first_erp_crm.human_sessions (
    session_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id VARCHAR(50) NOT NULL,
    user_name VARCHAR(100) NOT NULL,
    bot_id VARCHAR(50) NOT NULL,
    bot_type VARCHAR(50) NOT NULL,
    login_time TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    logout_time TIMESTAMP WITH TIME ZONE,
    ip_address INET,
    user_agent TEXT,
    session_status VARCHAR(20) NOT NULL DEFAULT 'active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_human_sessions_user_id ON agent_first_erp_crm.human_sessions(user_id);
CREATE INDEX idx_human_sessions_bot_id ON agent_first_erp_crm.human_sessions(bot_id);
CREATE INDEX idx_human_sessions_login_time ON agent_first_erp_crm.human_sessions(login_time);
```

### 11. `bot_actions` (Audit Logging)
Logs every action taken by a bot during a human session.

```sql
CREATE TABLE agent_first_erp_crm.bot_actions (
    action_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id UUID NOT NULL REFERENCES agent_first_erp_crm.human_sessions(session_id),
    user_id VARCHAR(50) NOT NULL,
    bot_id VARCHAR(50) NOT NULL,
    action_type VARCHAR(50) NOT NULL,
    action_description TEXT,
    input_parameters JSONB,
    output_result JSONB,
    success BOOLEAN NOT NULL,
    error_message TEXT,
    execution_time_ms INTEGER,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_bot_actions_session_id ON agent_first_erp_crm.bot_actions(session_id);
CREATE INDEX idx_bot_actions_user_id ON agent_first_erp_crm.bot_actions(user_id);
CREATE INDEX idx_bot_actions_bot_id ON agent_first_erp_crm.bot_actions(bot_id);
CREATE INDEX idx_bot_actions_timestamp ON agent_first_erp_crm.bot_actions(timestamp);
```

### 12. `audit_summary` (Daily Aggregation)
Daily summary of human-bot interactions for quick reporting.

```sql
CREATE TABLE agent_first_erp_crm.audit_summary (
    summary_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    date DATE NOT NULL,
    user_id VARCHAR(50) NOT NULL,
    bot_id VARCHAR(50) NOT NULL,
    total_sessions INTEGER NOT NULL DEFAULT 0,
    total_actions INTEGER NOT NULL DEFAULT 0,
    successful_actions INTEGER NOT NULL DEFAULT 0,
    failed_actions INTEGER NOT NULL DEFAULT 0,
    avg_session_duration_minutes NUMERIC(10, 2),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(date, user_id, bot_id)
);

CREATE INDEX idx_audit_summary_date ON agent_first_erp_crm.audit_summary(date);
CREATE INDEX idx_audit_summary_user_bot ON agent_first_erp_crm.audit_summary(user_id, bot_id);
```

### 13. `agent_interactions` (Full Trajectory Logging)
Complete agent trajectory logging for debugging and analysis.

```sql
CREATE TABLE agent_first_erp_crm.agent_interactions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID NOT NULL,
    telegram_chat_id VARCHAR(50),
    telegram_message_id BIGINT,
    bot_id VARCHAR(50) NOT NULL,
    user_id VARCHAR(50) NOT NULL,
    human_input TEXT NOT NULL,
    intent_classification VARCHAR(100),
    confidence_score FLOAT,
    agent_thoughts TEXT[],
    actions_taken JSONB[],
    tool_observations JSONB[],
    final_output TEXT,
    response_sources JSONB,
    model_used VARCHAR(100),
    token_input INTEGER,
    token_output INTEGER,
    duration_ms INTEGER,
    error_message TEXT,
    feedback_score INTEGER,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_agent_interactions_conversation ON agent_first_erp_crm.agent_interactions(conversation_id);
CREATE INDEX idx_agent_interactions_user_bot ON agent_first_erp_crm.agent_interactions(user_id, bot_id);
CREATE INDEX idx_agent_interactions_timestamp ON agent_first_erp_crm.agent_interactions(timestamp);
CREATE INDEX idx_agent_interactions_human_input ON agent_first_erp_crm.agent_interactions USING gin(to_tsvector('english', human_input));
```

## Indexes for Performance

```sql
-- PGVector indexes for semantic search
CREATE INDEX idx_entities_embedding ON agent_first_erp_crm.entities USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);
CREATE INDEX idx_contacts_embedding ON agent_first_erp_crm.contacts USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);
CREATE INDEX idx_orders_embedding ON agent_first_erp_crm.orders USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);
CREATE INDEX idx_products_embedding ON agent_first_erp_crm.products USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);
CREATE INDEX idx_tickets_embedding ON agent_first_erp_crm.tickets USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);

-- Standard indexes for performance
CREATE INDEX idx_orders_entity_id ON agent_first_erp_crm.orders(entity_id);
CREATE INDEX idx_tickets_entity_id ON agent_first_erp_crm.tickets(entity_id);
CREATE INDEX idx_tickets_customer_id ON agent_first_erp_crm.tickets(contact_id);
```

## Triggers for Auto-Update

```sql
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_entities_updated_at BEFORE UPDATE ON agent_first_erp_crm.entities
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_contacts_updated_at BEFORE UPDATE ON agent_first_erp_crm.contacts
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_orders_updated_at BEFORE UPDATE ON agent_first_erp_crm.orders
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_products_updated_at BEFORE UPDATE ON agent_first_erp_crm.products
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_communications_updated_at BEFORE UPDATE ON agent_first_erp_crm.communications
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_tickets_updated_at BEFORE UPDATE ON agent_first_erp_crm.tickets
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
```

---

*This schema is designed to be extended. New tables can be added as new agents (HR, Accounting, etc.) are introduced.*
