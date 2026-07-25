-- Create Views for Agent First ERP CRM
-- This script creates all the views documented in README_VIEWS.md
-- Run after setup_sample_data.sql

-- View 1: customers (Backward Compatibility)
-- Already created in setup_sample_data.sql, but ensure it exists
CREATE OR REPLACE VIEW agent_first_erp_crm.customers AS
SELECT 
    e.id,
    e.name,
    c.email,
    c.phone,
    COALESCE(
        a.street || ', ' || a.city || ', ' || a.state || ' ' || a.postal_code,
        'No address on file'
    ) AS address,
    e.status,
    e.created_at,
    e.updated_at,
    e.embedding
FROM agent_first_erp_crm.entities e
LEFT JOIN agent_first_erp_crm.entity_relationships er ON e.id = er.entity_id AND er.is_primary = TRUE
LEFT JOIN agent_first_erp_crm.contacts c ON er.contact_id = c.id
LEFT JOIN agent_first_erp_crm.addresses a ON e.id = a.entity_id AND a.is_primary = TRUE
WHERE e.entity_type IN ('customer', 'prospect');

-- View 2: customer_communications_summary
CREATE OR REPLACE VIEW agent_first_erp_crm.customer_communications_summary AS
SELECT 
    c.id,
    e.name AS entity_name,
    e.entity_type,
    e.status AS entity_status,
    c.contact_id,
    COALESCE(ct.first_name || ' ' || ct.last_name, 'N/A') AS contact_name,
    c.communication_type,
    c.direction,
    c.subject,
    c.summary,
    c.outcome,
    c.priority,
    c.sentiment_score,
    c.sentiment_label,
    c.follow_up_required,
    c.follow_up_date,
    c.started_at,
    c.created_at
FROM agent_first_erp_crm.communications c
JOIN agent_first_erp_crm.entities e ON c.entity_id = e.id
LEFT JOIN agent_first_erp_crm.contacts ct ON c.contact_id = ct.id;

-- View 3: recent_communications (Last 7 days)
-- Already created in setup_sample_data.sql, but ensure it exists
CREATE OR REPLACE VIEW agent_first_erp_crm.recent_communications AS
SELECT 
    c.id,
    e.name AS entity_name,
    e.entity_type,
    c.contact_id,
    ct.first_name || ' ' || ct.last_name AS contact_name,
    c.communication_type,
    c.direction,
    c.subject,
    c.summary,
    c.outcome,
    c.sentiment_label,
    c.started_at
FROM agent_first_erp_crm.communications c
JOIN agent_first_erp_crm.entities e ON c.entity_id = e.id
LEFT JOIN agent_first_erp_crm.contacts ct ON c.contact_id = ct.id
WHERE c.started_at >= NOW() - INTERVAL '7 days'
ORDER BY c.started_at DESC;

-- View 4: pending_followups
CREATE OR REPLACE VIEW agent_first_erp_crm.pending_followups AS
SELECT 
    c.id,
    e.name AS entity_name,
    e.entity_type,
    e.status AS entity_status,
    c.contact_id,
    ct.first_name || ' ' || ct.last_name AS contact_name,
    ct.title AS contact_title,
    c.communication_type,
    c.direction,
    c.subject,
    c.summary,
    c.outcome,
    c.priority,
    c.sentiment_label,
    c.follow_up_required,
    c.follow_up_date,
    c.started_at
FROM agent_first_erp_crm.communications c
JOIN agent_first_erp_crm.entities e ON c.entity_id = e.id
LEFT JOIN agent_first_erp_crm.contacts ct ON c.contact_id = ct.id
WHERE c.follow_up_required = TRUE
  AND (c.outcome = 'pending' OR c.outcome = 'escalated')
ORDER BY 
    CASE c.priority
        WHEN 'critical' THEN 1
        WHEN 'high' THEN 2
        WHEN 'medium' THEN 3
        WHEN 'low' THEN 4
        ELSE 5
    END,
    c.follow_up_date ASC;

-- View 5: entity_communication_stats
-- Already created in setup_sample_data.sql, but ensure it exists
CREATE OR REPLACE VIEW agent_first_erp_crm.entity_communication_stats AS
SELECT 
    e.id AS entity_id,
    e.name AS entity_name,
    e.entity_type,
    e.status,
    COUNT(c.id) AS total_communications,
    COUNT(CASE WHEN c.outcome = 'resolved' THEN 1 END) AS resolved_count,
    COUNT(CASE WHEN c.outcome = 'escalated' THEN 1 END) AS escalated_count,
    COUNT(CASE WHEN c.outcome = 'pending' THEN 1 END) AS pending_count,
    ROUND(AVG(c.sentiment_score)::numeric, 2) AS avg_sentiment,
    MAX(c.started_at) AS last_contact_date
FROM agent_first_erp_crm.entities e
LEFT JOIN agent_first_erp_crm.communications c ON e.id = c.entity_id
GROUP BY e.id, e.name, e.entity_type, e.status;

-- View 6: primary_contact_communications
CREATE OR REPLACE VIEW agent_first_erp_crm.primary_contact_communications AS
SELECT 
    c.id,
    e.name AS entity_name,
    e.entity_type,
    c.contact_id,
    ct.first_name || ' ' || ct.last_name AS primary_contact,
    ct.title AS contact_title,
    c.communication_type,
    c.direction,
    c.subject,
    c.summary,
    c.outcome,
    c.sentiment_label,
    c.started_at
FROM agent_first_erp_crm.communications c
JOIN agent_first_erp_crm.entities e ON c.entity_id = e.id
JOIN agent_first_erp_crm.entity_relationships er ON e.id = er.entity_id AND er.is_primary = TRUE
JOIN agent_first_erp_crm.contacts ct ON er.contact_id = ct.id
WHERE c.contact_id = ct.id
ORDER BY c.started_at DESC;

-- View 7: communication_thread_view
CREATE OR REPLACE VIEW agent_first_erp_crm.communication_thread_view AS
WITH RECURSIVE thread_hierarchy AS (
    -- Base case: root communications (no parent)
    SELECT 
        c.id,
        c.parent_id,
        c.thread_root_id,
        c.entity_id,
        c.contact_id,
        c.communication_type,
        c.direction,
        c.subject,
        c.summary,
        c.outcome,
        c.started_at,
        0 AS depth
    FROM agent_first_erp_crm.communications c
    WHERE c.parent_id IS NULL
    
    UNION ALL
    
    -- Recursive case: child communications
    SELECT 
        c.id,
        c.parent_id,
        COALESCE(c.thread_root_id, th.id) AS thread_root_id,
        c.entity_id,
        c.contact_id,
        c.communication_type,
        c.direction,
        c.subject,
        c.summary,
        c.outcome,
        c.started_at,
        th.depth + 1 AS depth
    FROM agent_first_erp_crm.communications c
    JOIN thread_hierarchy th ON c.parent_id = th.id
)
SELECT 
    th.id,
    th.parent_id,
    th.thread_root_id,
    e.name AS entity_name,
    ct.first_name || ' ' || ct.last_name AS contact_name,
    th.communication_type,
    th.direction,
    th.subject,
    th.summary,
    th.outcome,
    th.started_at,
    th.depth
FROM thread_hierarchy th
JOIN agent_first_erp_crm.entities e ON th.entity_id = e.id
LEFT JOIN agent_first_erp_crm.contacts ct ON th.contact_id = ct.id
ORDER BY th.thread_root_id, th.started_at;

-- View 8: agent_activity_summary
CREATE OR REPLACE VIEW agent_first_erp_crm.agent_activity_summary AS
SELECT 
    COALESCE(t.agent_id, 'unknown') AS agent_id,
    COUNT(DISTINCT c.entity_id) AS unique_entities,
    COUNT(c.id) AS total_actions,
    COUNT(CASE WHEN c.outcome = 'resolved' THEN 1 END) AS resolved_count,
    COUNT(CASE WHEN c.outcome = 'escalated' THEN 1 END) AS escalated_count,
    ROUND(AVG(c.sentiment_score)::numeric, 2) AS avg_sentiment,
    MAX(c.started_at) AS last_activity
FROM agent_first_erp_crm.communications c
LEFT JOIN agent_first_erp_crm.tickets t ON c.id = t.id
GROUP BY COALESCE(t.agent_id, 'unknown');

-- Create additional helpful views

-- View: entity_contact_details (Complete entity + primary contact info)
CREATE OR REPLACE VIEW agent_first_erp_crm.entity_contact_details AS
SELECT 
    e.id AS entity_id,
    e.name AS entity_name,
    e.entity_type,
    e.status AS entity_status,
    e.industry,
    e.website,
    e.legal_name,
    ct.id AS contact_id,
    ct.first_name,
    ct.last_name,
    ct.email AS contact_email,
    ct.phone AS contact_phone,
    ct.title AS contact_title,
    er.role,
    er.is_primary,
    er.start_date,
    er.end_date,
    a.street,
    a.city,
    a.state,
    a.postal_code,
    a.country
FROM agent_first_erp_crm.entities e
LEFT JOIN agent_first_erp_crm.entity_relationships er ON e.id = er.entity_id AND er.is_primary = TRUE
LEFT JOIN agent_first_erp_crm.contacts ct ON er.contact_id = ct.id
LEFT JOIN agent_first_erp_crm.addresses a ON e.id = a.entity_id AND a.is_primary = TRUE;

-- View: communication_timeline (Chronological view with full context)
CREATE OR REPLACE VIEW agent_first_erp_crm.communication_timeline AS
SELECT 
    c.id,
    c.started_at,
    e.name AS entity_name,
    e.entity_type,
    ct.first_name || ' ' || ct.last_name AS contact_name,
    ct.title AS contact_title,
    c.communication_type,
    c.direction,
    c.subject,
    c.summary,
    c.outcome,
    c.sentiment_label,
    c.follow_up_required,
    c.follow_up_date,
    CASE 
        WHEN c.direction = 'inbound' THEN 'Received from ' || COALESCE(ct.first_name, e.name)
        ELSE 'Sent to ' || COALESCE(ct.first_name, e.name)
    END AS narrative
FROM agent_first_erp_crm.communications c
JOIN agent_first_erp_crm.entities e ON c.entity_id = e.id
LEFT JOIN agent_first_erp_crm.contacts ct ON c.contact_id = ct.id
ORDER BY c.started_at DESC;

-- Verify all views created
SELECT 'Views created successfully!' AS status;
SELECT 
    schemaname,
    viewname
FROM pg_views 
WHERE schemaname = 'agent_first_erp_crm' 
ORDER BY viewname;
