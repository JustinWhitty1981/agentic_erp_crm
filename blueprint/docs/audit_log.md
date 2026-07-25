# Audit Log System

**Purpose:** Comprehensive audit trail for all human-bot interactions.

**Location:** `scripts/database/10_audit_log.sql`

---

## Overview

The audit logging system captures every interaction between humans and AI agents, providing:

- **Accountability:** Know which human commanded which bot
- **Traceability:** Full history of all actions taken
- **Compliance:** Meet regulatory requirements for audit trails
- **Analytics:** Understand usage patterns and bot effectiveness

---

## Schema Tables

### human_sessions

Tracks when human agents log in and start sessions with bots.

```sql
CREATE TABLE agent_first_erp_crm.human_sessions (
    session_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id VARCHAR(50) NOT NULL,           -- Human user identifier
    user_name VARCHAR(100) NOT NULL,        -- Human's display name
    bot_id VARCHAR(50) NOT NULL,            -- Bot identifier
    bot_type VARCHAR(50) NOT NULL,          -- Bot type (e.g., 'customer_service')
    login_time TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    logout_time TIMESTAMP WITH TIME ZONE,
    ip_address INET,                        -- Client IP address
    user_agent TEXT,                        -- Browser/client info
    session_status VARCHAR(20) NOT NULL DEFAULT 'active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);
```

**Status Values:**
- `active` - Session is currently open
- `completed` - Session ended normally
- `terminated` - Session ended abnormally

### bot_actions

Logs every action taken by a bot during a human session.

```sql
CREATE TABLE agent_first_erp_crm.bot_actions (
    action_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id UUID NOT NULL REFERENCES agent_first_erp_crm.human_sessions(session_id),
    user_id VARCHAR(50) NOT NULL,
    bot_id VARCHAR(50) NOT NULL,
    action_type VARCHAR(50) NOT NULL,       -- Type of action
    action_description TEXT,                -- Human-readable description
    input_parameters JSONB,                 -- Input parameters
    output_result JSONB,                    -- Result/output
    success BOOLEAN NOT NULL,               -- Whether action succeeded
    error_message TEXT,                     -- Error if action failed
    execution_time_ms INTEGER,              -- Execution time
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);
```

**Action Types:**
- `query` - Data retrieval
- `update` - Data modification
- `create` - New record creation
- `delete` - Record deletion
- `export` - Data export
- `report` - Report generation

### audit_summary

Daily aggregation of human-bot interactions for quick reporting.

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
```

---

## Usage Examples

### Creating a Human Session

```python
def create_human_session(user_id, user_name, bot_id, bot_type, 
                         ip_address=None, user_agent=None):
    """Create a new human session when user logs in."""
    cursor.execute("""
        INSERT INTO agent_first_erp_crm.human_sessions (
            user_id, user_name, bot_id, bot_type, ip_address, user_agent
        ) VALUES (%s, %s, %s, %s, %s, %s)
        RETURNING session_id
    """, (user_id, user_name, bot_id, bot_type, ip_address, user_agent))
    
    session_id = cursor.fetchone()[0]
    return session_id
```

### Logging a Bot Action

```python
def log_bot_action(session_id, user_id, bot_id, action_type, description,
                   input_params, output_result, success, 
                   error_message=None, execution_time_ms=None):
    """Log an action performed by a bot."""
    cursor.execute("""
        INSERT INTO agent_first_erp_crm.bot_actions (
            session_id, user_id, bot_id, action_type, action_description,
            input_parameters, output_result, success, error_message, execution_time_ms
        ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
        RETURNING action_id
    """, (
        session_id, user_id, bot_id, action_type, description,
        psycopg2.extras.Json(input_params), 
        psycopg2.extras.Json(output_result),
        success, error_message, execution_time_ms
    ))
    
    return cursor.fetchone()[0]
```

### Closing a Human Session

```python
def close_human_session(session_id, logout_time=None):
    """Mark a human session as completed."""
    if logout_time is None:
        logout_time = datetime.utcnow()
    
    cursor.execute("""
        UPDATE agent_first_erp_crm.human_sessions
        SET logout_time = %s, session_status = 'completed', updated_at = NOW()
        WHERE session_id = %s
    """, (logout_time, session_id))
```

---

## Query Examples

### Get All Actions for a User-Bot Pair

```sql
SELECT 
    ba.timestamp,
    ba.action_type,
    ba.action_description,
    ba.success,
    ba.execution_time_ms
FROM agent_first_erp_crm.bot_actions ba
WHERE ba.user_id = '123456' 
  AND ba.bot_id = 'cs_bot_01'
ORDER BY ba.timestamp DESC
LIMIT 50;
```

### Get Session Details with Action Count

```sql
SELECT 
    hs.session_id,
    hs.user_name,
    hs.bot_id,
    hs.login_time,
    hs.logout_time,
    COUNT(ba.action_id) as total_actions,
    SUM(CASE WHEN ba.success THEN 1 ELSE 0 END) as successful_actions
FROM agent_first_erp_crm.human_sessions hs
LEFT JOIN agent_first_erp_crm.bot_actions ba ON hs.session_id = ba.session_id
WHERE hs.user_id = '123456'
GROUP BY hs.session_id, hs.user_name, hs.bot_id, hs.login_time, hs.logout_time
ORDER BY hs.login_time DESC;
```

### Daily Audit Summary Report

```sql
SELECT 
    date,
    user_id,
    bot_id,
    total_sessions,
    total_actions,
    successful_actions,
    failed_actions,
    ROUND(avg_session_duration_minutes::numeric, 2) as avg_duration_min
FROM agent_first_erp_crm.audit_summary
WHERE date >= CURRENT_DATE - INTERVAL '7 days'
ORDER BY date DESC, total_actions DESC;
```

### Find Failed Actions

```sql
SELECT 
    ba.timestamp,
    hs.user_name,
    ba.bot_id,
    ba.action_type,
    ba.action_description,
    ba.error_message
FROM agent_first_erp_crm.bot_actions ba
JOIN agent_first_erp_crm.human_sessions hs ON ba.session_id = hs.session_id
WHERE ba.success = FALSE
  AND ba.timestamp >= CURRENT_DATE - INTERVAL '24 hours'
ORDER BY ba.timestamp DESC;
```

---

## Integration Points

1. **Bot Initialization:** Create `human_sessions` record when human logs in
2. **Every Bot Action:** Log to `bot_actions` before/after execution
3. **Session End:** Update `human_sessions` with logout time and status
4. **Daily Aggregation:** Run cron job to populate `audit_summary`

---

## Security Considerations

- **Append-only:** Audit tables are append-only (no UPDATE/DELETE except corrections)
- **Data Masking:** Sensitive data in `input_parameters` and `output_result` should be masked
- **Backup:** Audit logs should be backed up separately for compliance
- **Encryption:** Consider encryption at rest for audit tables containing PII

---

## Performance Optimization

### Recommended Indexes

```sql
CREATE INDEX idx_human_sessions_user_id ON agent_first_erp_crm.human_sessions(user_id);
CREATE INDEX idx_human_sessions_bot_id ON agent_first_erp_crm.human_sessions(bot_id);
CREATE INDEX idx_human_sessions_login_time ON agent_first_erp_crm.human_sessions(login_time);
CREATE INDEX idx_human_sessions_status ON agent_first_erp_crm.human_sessions(session_status);

CREATE INDEX idx_bot_actions_session_id ON agent_first_erp_crm.bot_actions(session_id);
CREATE INDEX idx_bot_actions_user_id ON agent_first_erp_crm.bot_actions(user_id);
CREATE INDEX idx_bot_actions_bot_id ON agent_first_erp_crm.bot_actions(bot_id);
CREATE INDEX idx_bot_actions_timestamp ON agent_first_erp_crm.bot_actions(timestamp);
CREATE INDEX idx_bot_actions_action_type ON agent_first_erp_crm.bot_actions(action_type);

CREATE INDEX idx_audit_summary_date ON agent_first_erp_crm.audit_summary(date);
CREATE INDEX idx_audit_summary_user_bot ON agent_first_erp_crm.audit_summary(user_id, bot_id);
```

---

## Best Practices

1. **Log Everything:** Every bot action should be logged, including failures
2. **Include Context:** Always log user_id, bot_id, and session_id
3. **Monitor Failures:** Check failed actions daily
4. **Archive Old Data:** Consider archiving audit data older than 1 year
5. **Regular Reports:** Generate weekly/monthly audit summary reports

---

*Generated for Agent First ERP CRM - Audit logging system documentation*