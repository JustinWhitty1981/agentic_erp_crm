-- Sample Data Setup for Agent First ERP CRM Customer Service Bot
-- Run this script to create the agent_first_erp_crm schema and populate with test data

-- Create schema if it doesn't exist
CREATE SCHEMA IF NOT EXISTS agent_first_erp_crm;

-- Create entities table (replaces old customers table)
CREATE TABLE IF NOT EXISTS agent_first_erp_crm.entities (
    id SERIAL PRIMARY KEY,
    entity_type VARCHAR(50) NOT NULL,
    name TEXT NOT NULL,
    legal_name TEXT,
    tax_id VARCHAR(50),
    industry VARCHAR(100),
    website TEXT,
    status TEXT DEFAULT 'active',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    embedding VECTOR(1536)
);

-- Create contacts table
CREATE TABLE IF NOT EXISTS agent_first_erp_crm.contacts (
    id SERIAL PRIMARY KEY,
    first_name TEXT NOT NULL,
    last_name TEXT NOT NULL,
    email TEXT,
    phone TEXT,
    title TEXT,
    status TEXT DEFAULT 'active',
    preferences JSONB,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    embedding VECTOR(1536)
);

-- Create entity_relationships table
CREATE TABLE IF NOT EXISTS agent_first_erp_crm.entity_relationships (
    id SERIAL PRIMARY KEY,
    entity_id INTEGER NOT NULL REFERENCES agent_first_erp_crm.entities(id),
    contact_id INTEGER NOT NULL REFERENCES agent_first_erp_crm.contacts(id),
    role VARCHAR(100),
    is_primary BOOLEAN DEFAULT FALSE,
    start_date DATE,
    end_date DATE,
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(entity_id, contact_id)
);

CREATE INDEX IF NOT EXISTS idx_primary_contact ON agent_first_erp_crm.entity_relationships(entity_id) 
WHERE is_primary = TRUE;

-- Create addresses table
CREATE TABLE IF NOT EXISTS agent_first_erp_crm.addresses (
    id SERIAL PRIMARY KEY,
    entity_id INTEGER REFERENCES agent_first_erp_crm.entities(id),
    contact_id INTEGER REFERENCES agent_first_erp_crm.contacts(id),
    address_type VARCHAR(50),
    street TEXT,
    city TEXT,
    state TEXT,
    postal_code TEXT,
    country TEXT DEFAULT 'US',
    is_primary BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_addresses_entity ON agent_first_erp_crm.addresses(entity_id);
CREATE INDEX IF NOT EXISTS idx_addresses_contact ON agent_first_erp_crm.addresses(contact_id);

-- Create communications table
CREATE TABLE IF NOT EXISTS agent_first_erp_crm.communications (
    id BIGSERIAL PRIMARY KEY,
    entity_id INTEGER NOT NULL REFERENCES agent_first_erp_crm.entities(id),
    contact_id INTEGER REFERENCES agent_first_erp_crm.contacts(id),
    communication_type VARCHAR(50),
    direction VARCHAR(20),
    subject TEXT,
    summary TEXT NOT NULL,
    full_content TEXT,
    attachments JSONB,
    parent_id BIGINT REFERENCES agent_first_erp_crm.communications(id),
    thread_root_id BIGINT,
    sentiment_score FLOAT,
    sentiment_label VARCHAR(20),
    outcome VARCHAR(50),
    follow_up_required BOOLEAN DEFAULT FALSE,
    follow_up_date DATE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    embedding VECTOR(1536)
);

CREATE INDEX IF NOT EXISTS idx_communications_entity ON agent_first_erp_crm.communications(entity_id);
CREATE INDEX IF NOT EXISTS idx_communications_contact ON agent_first_erp_crm.communications(contact_id);
CREATE INDEX IF NOT EXISTS idx_communications_thread_root ON agent_first_erp_crm.communications(thread_root_id);

-- Create tickets table (placeholder for future)
CREATE TABLE IF NOT EXISTS agent_first_erp_crm.tickets (
    id BIGSERIAL PRIMARY KEY,
    entity_id INTEGER REFERENCES agent_first_erp_crm.entities(id),
    contact_id INTEGER REFERENCES agent_first_erp_crm.contacts(id),
    agent_id TEXT,
    subject TEXT,
    message TEXT,
    status TEXT DEFAULT 'open',
    priority VARCHAR(20) DEFAULT 'normal',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    embedding VECTOR(1536)
);

-- Create agents table
CREATE TABLE IF NOT EXISTS agent_first_erp_crm.agents (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    role TEXT NOT NULL,
    api_key TEXT UNIQUE,
    permissions JSONB,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Create audit_log table
CREATE TABLE IF NOT EXISTS agent_first_erp_crm.audit_log (
    id BIGSERIAL PRIMARY KEY,
    agent_id TEXT,
    action TEXT,
    target_table TEXT,
    target_id INTEGER,
    old_value JSONB,
    new_value JSONB,
    validation_status TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_audit_log_agent_id ON agent_first_erp_crm.audit_log(agent_id);
CREATE INDEX IF NOT EXISTS idx_audit_log_created_at ON agent_first_erp_crm.audit_log(created_at);

-- Create views for backward compatibility and easier queries

-- View: customers (backward compatibility)
CREATE OR REPLACE VIEW agent_first_erp_crm.customers AS
SELECT 
    e.id,
    e.name,
    c.email,
    c.phone,
    a.street || ', ' || a.city || ', ' || a.state || ' ' || a.postal_code AS address,
    e.status,
    e.created_at,
    e.updated_at,
    e.embedding
FROM agent_first_erp_crm.entities e
LEFT JOIN agent_first_erp_crm.entity_relationships er ON e.id = er.entity_id AND er.is_primary = TRUE
LEFT JOIN agent_first_erp_crm.contacts c ON er.contact_id = c.id
LEFT JOIN agent_first_erp_crm.addresses a ON e.id = a.entity_id AND a.is_primary = TRUE
WHERE e.entity_type IN ('customer', 'prospect');

-- View: recent_communications
CREATE OR REPLACE VIEW agent_first_erp_crm.recent_communications AS
SELECT 
    c.id,
    e.name AS entity_name,
    c.contact_id,
    c.communication_type,
    c.direction,
    c.summary,
    c.started_at,
    c.outcome,
    c.sentiment_label
FROM agent_first_erp_crm.communications c
JOIN agent_first_erp_crm.entities e ON c.entity_id = e.id
WHERE c.started_at >= NOW() - INTERVAL '7 days'
ORDER BY c.started_at DESC;

-- View: entity_communication_stats
CREATE OR REPLACE VIEW agent_first_erp_crm.entity_communication_stats AS
SELECT 
    e.id AS entity_id,
    e.name AS entity_name,
    e.entity_type,
    e.status,
    COUNT(c.id) AS total_communications,
    COUNT(CASE WHEN c.outcome = 'resolved' THEN 1 END) AS resolved_count,
    COUNT(CASE WHEN c.outcome = 'pending' OR c.outcome = 'escalated' THEN 1 END) AS pending_count,
    MAX(c.started_at) AS last_contact_date
FROM agent_first_erp_crm.entities e
LEFT JOIN agent_first_erp_crm.communications c ON e.id = c.entity_id
GROUP BY e.id, e.name, e.entity_type, e.status;

-- Insert sample data

-- Insert sample entities (customers)
INSERT INTO agent_first_erp_crm.entities (entity_type, name, legal_name, industry, status) VALUES
('customer', 'Alice Johnson', NULL, 'Retail', 'active'),
('customer', 'Bob''s Small Engines', 'Bob''s Small Engines LLC', 'Automotive', 'active'),
('customer', 'Charlie Martinez', NULL, 'Healthcare', 'active'),
('customer', 'Acme Corporation', 'Acme Corp Inc.', 'Manufacturing', 'active'),
('prospect', 'Diana Prince', NULL, 'Consulting', 'active');

-- Insert sample contacts
INSERT INTO agent_first_erp_crm.contacts (first_name, last_name, email, phone, title, status) VALUES
('Alice', 'Johnson', 'alice.johnson@email.com', '555-0101', 'Owner', 'active'),
('Bob', 'Smith', 'bob@bobsengines.com', '555-0102', 'Owner', 'active'),
('Charlie', 'Martinez', 'charlie.m@healthcare.com', '555-0103', 'Director', 'active'),
('Diana', 'Prince', 'diana.prince@consulting.com', '555-0104', 'CEO', 'active');

-- Insert entity relationships
INSERT INTO agent_first_erp_crm.entity_relationships (entity_id, contact_id, role, is_primary) VALUES
(1, 1, 'Owner', TRUE),
(2, 2, 'Owner', TRUE),
(3, 3, 'Director', TRUE),
(5, 4, 'CEO', TRUE);

-- Insert sample addresses
INSERT INTO agent_first_erp_crm.addresses (entity_id, address_type, street, city, state, postal_code, country, is_primary) VALUES
(1, 'billing', '123 Main St', 'Chicago', 'IL', '60601', 'US', TRUE),
(2, 'billing', '456 Oak Ave', 'Naperville', 'IL', '60540', 'US', TRUE),
(3, 'billing', '789 Health Blvd', 'Evanston', 'IL', '60201', 'US', TRUE),
(4, 'billing', '100 Industrial Pkwy', 'Aurora', 'IL', '60505', 'US', TRUE);

-- Insert sample communications
INSERT INTO agent_first_erp_crm.communications (entity_id, contact_id, communication_type, direction, subject, summary, outcome, sentiment_label) VALUES
(1, 1, 'email', 'inbound', 'Order Status Inquiry', 'Customer asked about order ORD-10001 status. Provided update.', 'resolved', 'neutral'),
(2, 2, 'call', 'outbound', 'Follow-up on Service', 'Called to follow up on recent service request. Customer satisfied.', 'resolved', 'positive'),
(3, 3, 'meeting', 'inbound', 'Quarterly Review', 'Met to discuss quarterly performance and upcoming needs.', 'resolved', 'positive'),
(1, 1, 'chat', 'inbound', 'Quick Question', 'Customer had a quick question about return policy. Answered.', 'resolved', 'neutral'),
(4, NULL, 'email', 'outbound', 'New Product Announcement', 'Sent email about new product line to potential customer.', 'pending', 'neutral');

-- Create indexes for PGVector (if extension is enabled)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pgvector') THEN
        CREATE INDEX IF NOT EXISTS idx_entities_embedding ON agent_first_erp_crm.entities USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);
        CREATE INDEX IF NOT EXISTS idx_contacts_embedding ON agent_first_erp_crm.contacts USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);
        CREATE INDEX IF NOT EXISTS idx_communications_embedding ON agent_first_erp_crm.communications USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);
        CREATE INDEX IF NOT EXISTS idx_tickets_embedding ON agent_first_erp_crm.tickets USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);
    ELSE
        RAISE NOTICE 'pgvector extension not enabled. Skipping vector indexes.';
    END IF;
END $$;

-- Create triggers for auto-update
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS update_entities_updated_at ON agent_first_erp_crm.entities;
CREATE TRIGGER update_entities_updated_at BEFORE UPDATE ON agent_first_erp_crm.entities
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_contacts_updated_at ON agent_first_erp_crm.contacts;
CREATE TRIGGER update_contacts_updated_at BEFORE UPDATE ON agent_first_erp_crm.contacts
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_communications_updated_at ON agent_first_erp_crm.communications;
CREATE TRIGGER update_communications_updated_at BEFORE UPDATE ON agent_first_erp_crm.communications
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_tickets_updated_at ON agent_first_erp_crm.tickets;
CREATE TRIGGER update_tickets_updated_at BEFORE UPDATE ON agent_first_erp_crm.tickets
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Verify setup
SELECT 'Schema and sample data created successfully!' AS status;
SELECT 'Entities: ' || COUNT(*) FROM agent_first_erp_crm.entities AS entity_count;
SELECT 'Contacts: ' || COUNT(*) FROM agent_first_erp_crm.contacts AS contact_count;
SELECT 'Communications: ' || COUNT(*) FROM agent_first_erp_crm.communications AS comm_count;
