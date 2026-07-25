-- scripts/database/11_interaction_logging.sql
-- ============================================================================
-- INTERACTION LOGGING SCHEMA
-- Enterprise-grade logging for agent-human interactions
-- ============================================================================

-- Ensure UUID extension is available
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Create the interaction log table
CREATE TABLE IF NOT EXISTS agent_interactions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    
    -- Correlation IDs (Critical for debugging specific conversations)
    conversation_id UUID NOT NULL,          -- Links messages in a single chat thread
    telegram_chat_id TEXT NOT NULL,         -- The Telegram group/user ID (e.g., "8551240949")
    telegram_message_id BIGINT,             -- Specific message ID for reference
    bot_id TEXT NOT NULL,                   -- Which bot instance handled this (if multiple)
    user_id TEXT NOT NULL,                  -- The user's Telegram ID
    
    -- Timing
    timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    duration_ms INTEGER,                    -- How long the whole interaction took
    
    -- The Request
    human_input TEXT NOT NULL,              -- The raw user prompt
    intent_classification TEXT,             -- Auto-detected intent (e.g., "lookup", "update")
    confidence_score FLOAT,                 -- Model's confidence in the intent
    
    -- The "Trajectory" (The most valuable debugging data)
    agent_thoughts TEXT[],                  -- Array of "Thought: ..." strings from the agent
    actions_taken JSONB,                  -- JSON array of {tool_name, tool_input, log}
    tool_observations JSONB,              -- JSON array of tool outputs
    
    -- The Result
    final_output TEXT,                      -- The final message sent to the user
    response_sources JSONB,                 -- IDs of records used (e.g., customer IDs)
    
    -- Metadata
    model_used TEXT,
    token_usage JSONB,                      -- {input: 120, output: 85}
    error_message TEXT,                     -- If the chain failed
    feedback_score FLOAT,                   -- Optional: User rating (1-5)
    
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes for fast querying and debugging
CREATE INDEX IF NOT EXISTS idx_interactions_conversation 
    ON agent_interactions(conversation_id);

CREATE INDEX IF NOT EXISTS idx_interactions_telegram_chat 
    ON agent_interactions(telegram_chat_id);

CREATE INDEX IF NOT EXISTS idx_interactions_timestamp 
    ON agent_interactions(timestamp DESC);

CREATE INDEX IF NOT EXISTS idx_interactions_human_input 
    ON agent_interactions USING GIN(to_tsvector('english', human_input));

CREATE INDEX IF NOT EXISTS idx_interactions_actions 
    ON agent_interactions USING GIN(actions_taken);

CREATE INDEX IF NOT EXISTS idx_interactions_user 
    ON agent_interactions(user_id);

CREATE INDEX IF NOT EXISTS idx_interactions_bot 
    ON agent_interactions(bot_id);

-- ============================================================================
-- USEFUL VIEWS FOR DEBUGGING
-- ============================================================================

-- View: Recent interactions with full context
CREATE OR REPLACE VIEW v_recent_interactions AS
SELECT 
    id,
    telegram_chat_id,
    user_id,
    human_input,
    actions_taken,
    final_output,
    error_message,
    duration_ms,
    timestamp
FROM agent_interactions
ORDER BY timestamp DESC
LIMIT 100;

-- View: Failed interactions
CREATE OR REPLACE VIEW v_failed_interactions AS
SELECT 
    id,
    telegram_chat_id,
    user_id,
    human_input,
    actions_taken,
    error_message,
    timestamp
FROM agent_interactions
WHERE error_message IS NOT NULL
ORDER BY timestamp DESC;

-- View: Tool performance summary
CREATE OR REPLACE VIEW v_tool_performance AS
SELECT 
    (actions_taken_elem->>'tool') as tool_name,
    COUNT(*) as call_count,
    AVG(duration_ms) as avg_duration_ms,
    SUM(CASE WHEN error_message IS NOT NULL THEN 1 ELSE 0 END) as error_count
FROM agent_interactions, 
     jsonb_array_elements(agent_interactions.actions_taken) as actions_taken_elem
GROUP BY tool_name
ORDER BY call_count DESC;

-- ============================================================================
-- SAMPLE QUERIES FOR DEBUGGING
-- ============================================================================

-- Find all interactions about a specific person
-- SELECT * FROM agent_interactions 
-- WHERE to_tsvector('english', human_input) @@ to_tsquery('Suzy & Smith');

-- Find all failed interactions for a user
-- SELECT * FROM agent_interactions 
-- WHERE user_id = '8551240949' AND error_message IS NOT NULL;

-- Get tool usage statistics
-- SELECT tool_name, call_count, avg_duration_ms 
-- FROM v_tool_performance 
-- ORDER BY call_count DESC;
