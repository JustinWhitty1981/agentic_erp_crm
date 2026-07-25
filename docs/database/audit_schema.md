# Audit Logging System

## Overview

The Agent Swarm maintains a comprehensive audit trail of all human-bot interactions. This ensures:
- **Accountability:** Know which human commanded which bot
- **Traceability:** Full history of all actions taken
- **Compliance:** Meet regulatory requirements for audit trails
- **Analytics:** Understand usage patterns and bot effectiveness

## Schema Design

### Table: `human_sessions`

Tracks when humans log in and start sessions with agents.

```sql
CREATE TABLE agent_swarm.human_sessions (
    session_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id VARCHAR(50) NOT NULL,           -- Human user identifier (e.g., "123456")
    user_name VARCHAR(100) NOT NULL,        -- Human's display name (e.g., "Kimmy Sue")
    bot_id VARCHAR(50) NOT NULL,            -- Bot identifier (e.g., "cs_bot_01")
    bot_type VARCHAR(50) NOT NULL,          -- Bot type (e.g., "customer_service", "inventory")
    login_time TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    logout_time TIMESTAMP WITH TIME ZONE,
    ip_address INET,                        -- Client IP address
    user_agent TEXT,                        -- Browser/client info
    session_status VARCHAR(20) NOT NULL DEFAULT 'active', -- active, completed, terminated
    
    -- Audit fields
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Indexes for performance
CREATE INDEX idx_human_sessions_user_id ON agent_swarm.human_sessions(user_id);
CREATE INDEX idx_human_sessions_bot_id ON agent_swarm.human_sessions(bot_id);
CREATE INDEX idx_human_sessions_login_time ON agent_swarm.human_sessions(login_time);
CREATE INDEX idx_human_sessions_status ON agent_swarm.human_sessions(session_status);
```

### Table: `bot_actions`

Logs every action taken by a bot during a human session.

```sql
CREATE TABLE agent_swarm.bot_actions (
    action_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id UUID NOT NULL REFERENCES agent_swarm.human_sessions(session_id),
    user_id VARCHAR(50) NOT NULL,           -- Human user who commanded the bot
    bot_id VARCHAR(50) NOT NULL,            -- Bot that performed the action
    action_type VARCHAR(50) NOT NULL,       -- Type of action (e.g., "query", "update", "export")
    action_description TEXT,                -- Human-readable description
    input_parameters JSONB,                 -- Input parameters passed to the bot
    output_result JSONB,                    -- Result/output of the action
    success BOOLEAN NOT NULL,               -- Whether the action succeeded
    error_message TEXT,                     -- Error if action failed
    execution_time_ms INTEGER,              -- How long the action took
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    
    -- Audit fields
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Indexes for performance
CREATE INDEX idx_bot_actions_session_id ON agent_swarm.bot_actions(session_id);
CREATE INDEX idx_bot_actions_user_id ON agent_swarm.bot_actions(user_id);
CREATE INDEX idx_bot_actions_bot_id ON agent_swarm.bot_actions(bot_id);
CREATE INDEX idx_bot_actions_timestamp ON agent_swarm.bot_actions(timestamp);
CREATE INDEX idx_bot_actions_action_type ON agent_swarm.bot_actions(action_type);

-- Composite index for common queries
CREATE INDEX idx_bot_actions_session_user ON agent_swarm.bot_actions(session_id, user_id);
```

### Table: `audit_summary`

Daily summary of human-bot interactions for quick reporting.

```sql
CREATE TABLE agent_swarm.audit_summary (
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

CREATE INDEX idx_audit_summary_date ON agent_swarm.audit_summary(date);
CREATE INDEX idx_audit_summary_user_bot ON agent_swarm.audit_summary(user_id, bot_id);
```

## Usage Examples

### Example 1: Human Logs In

```python
from datetime import datetime
import os
import psycopg2
from dotenv import load_dotenv

load_dotenv()

def get_db_connection():
    """Get PostgreSQL connection from environment variables."""
    return psycopg2.connect(
        host=os.getenv("POSTGRES_HOST", "localhost"),
        database=os.getenv("POSTGRES_DB", "agent_swarm"),
        user=os.getenv("POSTGRES_USER", "postgres"),
        password=os.getenv("POSTGRES_PASSWORD", "")
    )

def create_human_session(user_id, user_name, bot_id, bot_type, ip_address=None, user_agent=None):
    """Create a new human session when user logs in."""
    conn = get_db_connection()
    cursor = conn.cursor()
    
    cursor.execute("""
        INSERT INTO agent_swarm.human_sessions (
            user_id, user_name, bot_id, bot_type, ip_address, user_agent
        ) VALUES (%s, %s, %s, %s, %s, %s)
        RETURNING session_id
    """, (user_id, user_name, bot_id, bot_type, ip_address, user_agent))
    
    session_id = cursor.fetchone()[0]
    conn.commit()
    cursor.close()
    conn.close()
    
    return session_id

# Example usage:
# session_id = create_human_session(
#     user_id="123456",
#     user_name="Kimmy Sue",
#     bot_id="cs_bot_01",
#     bot_type="customer_service",
#     ip_address="10.0.0.100",
#     user_agent="Mozilla/5.0..."
# )
# Result: session_id = "a1b2c3d4-..."
```

### Example 2: Log Bot Action

```python
def log_bot_action(session_id, user_id, bot_id, action_type, description, 
                   input_params, output_result, success, error_message=None, execution_time_ms=None):
    """Log an action performed by a bot."""
    conn = get_db_connection()
    cursor = conn.cursor()
    
    cursor.execute("""
        INSERT INTO agent_swarm.bot_actions (
            session_id, user_id, bot_id, action_type, action_description,
            input_parameters, output_result, success, error_message, execution_time_ms
        ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
        RETURNING action_id
    """, (
        session_id, user_id, bot_id, action_type, description,
        psycopg2.extras.Json(input_params), psycopg2.extras.Json(output_result),
        success, error_message, execution_time_ms
    ))
    
    action_id = cursor.fetchone()[0]
    conn.commit()
    cursor.close()
    conn.close()
    
    return action_id

# Example usage:
# action_id = log_bot_action(
#     session_id="a1b2c3d4-...",
#     user_id="123456",
#     bot_id="cs_bot_01",
#     action_type="query",
#     description="Retrieved customer information for John Doe",
#     input_params={"customer_id": "CUST-20240123"},
#     output_result={"name": "John Doe", "email": "john@example.com", ...},
#     success=True,
#     execution_time_ms=245
# )
```

### Example 3: Close Human Session

```python
def close_human_session(session_id, logout_time=None):
    """Mark a human session as completed."""
    conn = get_db_connection()
    cursor = conn.cursor()
    
    if logout_time is None:
        logout_time = datetime.utcnow()
    
    cursor.execute("""
        UPDATE agent_swarm.human_sessions
        SET logout_time = %s, session_status = 'completed', updated_at = NOW()
        WHERE session_id = %s
    """, (logout_time, session_id))
    
    conn.commit()
    cursor.close()
    conn.close()
```

## Query Examples

### Get All Actions for a Specific User-Bot Pair

```sql
SELECT 
    ba.timestamp,
    ba.action_type,
    ba.action_description,
    ba.success,
    ba.execution_time_ms
FROM agent_swarm.bot_actions ba
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
FROM agent_swarm.human_sessions hs
LEFT JOIN agent_swarm.bot_actions ba ON hs.session_id = ba.session_id
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
FROM agent_swarm.audit_summary
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
FROM agent_swarm.bot_actions ba
JOIN agent_swarm.human_sessions hs ON ba.session_id = hs.session_id
WHERE ba.success = FALSE
  AND ba.timestamp >= CURRENT_DATE - INTERVAL '24 hours'
ORDER BY ba.timestamp DESC;
```

## Integration Points

1. **Bot Initialization:** When a human logs in, create a `human_sessions` record
2. **Every Bot Action:** Log to `bot_actions` table before/after execution
3. **Session End:** Update `human_sessions` with logout time and status
4. **Daily Aggregation:** Run a cron job to populate `audit_summary` table

## Security Considerations

- All audit tables are append-only (no UPDATE/DELETE except for corrections)
- Sensitive data in `input_parameters` and `output_result` should be masked if needed
- Audit logs should be backed up separately for compliance
- Consider encryption at rest for audit tables containing PII
