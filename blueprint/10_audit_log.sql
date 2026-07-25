-- Audit Log Table for CAO Validation
-- This table provides an immutable log of all agent actions for validation and compliance
-- Required for the CAO (Chief Agent Officer) validation layer

DROP TABLE IF EXISTS agent_swarm.audit_log CASCADE;

CREATE TABLE agent_swarm.audit_log (
    id BIGSERIAL PRIMARY KEY,
    agent_id TEXT NOT NULL,                    -- e.g., 'customer_service', 'inventory_agent'
    action TEXT NOT NULL,                      -- e.g., 'create_ticket', 'update_customer', 'add_communication'
    target_table TEXT,                         -- Table that was modified
    target_id INTEGER,                         -- ID of the modified record
    old_value JSONB,                           -- Previous state (NULL for creates)
    new_value JSONB NOT NULL,                  -- New state
    validation_status TEXT DEFAULT 'pending',  -- 'pending', 'passed', 'failed'
    validation_agent_id TEXT,                  -- CAO agent that validated
    validation_notes TEXT,                     -- Notes from validation
    created_at TIMESTAMPTZ DEFAULT NOW(),
    validated_at TIMESTAMPTZ
);

-- Indexes for performance
CREATE INDEX idx_audit_log_agent_id ON agent_swarm.audit_log(agent_id);
CREATE INDEX idx_audit_log_created_at ON agent_swarm.audit_log(created_at);
CREATE INDEX idx_audit_log_validation_status ON agent_swarm.audit_log(validation_status);
CREATE INDEX idx_audit_log_target ON agent_swarm.audit_log(target_table, target_id);

-- Function to log agent actions
CREATE OR REPLACE FUNCTION log_agent_action(
    p_agent_id TEXT,
    p_action TEXT,
    p_target_table TEXT,
    p_target_id INTEGER,
    p_old_value JSONB,
    p_new_value JSONB
) RETURNS BIGINT AS $$
DECLARE
    v_audit_id BIGINT;
BEGIN
    INSERT INTO agent_swarm.audit_log (
        agent_id, action, target_table, target_id, old_value, new_value
    ) VALUES (
        p_agent_id, p_action, p_target_table, p_target_id, p_old_value, p_new_value
    ) RETURNING id INTO v_audit_id;
    
    RETURN v_audit_id;
END;
$$ LANGUAGE plpgsql;

-- Function to validate an audit log entry (called by CAO)
CREATE OR REPLACE FUNCTION validate_audit_action(
    p_audit_id BIGINT,
    p_validation_status TEXT,
    p_validation_notes TEXT DEFAULT NULL
) RETURNS VOID AS $$
BEGIN
    IF p_validation_status NOT IN ('passed', 'failed') THEN
        RAISE EXCEPTION 'Invalid validation status: %', p_validation_status;
    END IF;
    
    UPDATE agent_swarm.audit_log
    SET 
        validation_status = p_validation_status,
        validated_at = NOW(),
        validation_notes = COALESCE(p_validation_notes, validation_notes)
    WHERE id = p_audit_id;
END;
$$ LANGUAGE plpgsql;

-- Grant permissions
GRANT SELECT ON agent_swarm.audit_log TO jarvis;
GRANT INSERT ON agent_swarm.audit_log TO jarvis;
GRANT EXECUTE ON FUNCTION log_agent_action TO jarvis;
GRANT EXECUTE ON FUNCTION validate_audit_action TO jarvis;

-- Comments for documentation
COMMENT ON TABLE agent_swarm.audit_log IS 'Immutable log of all agent actions for CAO validation';
COMMENT ON COLUMN agent_swarm.audit_log.validation_status IS 'Status: pending (awaiting validation), passed (verified), failed (validation failed)';
COMMENT ON FUNCTION log_agent_action IS 'Logs a new agent action to the audit trail';
COMMENT ON FUNCTION validate_audit_action IS 'Validates an audit log entry by the CAO agent';