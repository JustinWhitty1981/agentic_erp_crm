# Interaction Logging System

**Purpose:** Complete agent trajectory logging for debugging and analysis.

**Location:** `db/migrations/0001_baseline_canonical_port.sql` (the table) and `0017_interaction_readpath.sql` (the views); `scripts/database/11_interaction_logging.sql` is the superseded copy that named the full-text index the port never carried

---

## Overview

The interaction logging system captures **every** agent-human interaction in detail, enabling:

- **Debugging:** Understand exactly why an agent made a specific decision
- **Auditing:** Full audit trail of all agent actions
- **Performance Analysis:** Track tool usage, response times, and error rates
- **Training:** Use real interactions to improve agent behavior
- **Compliance:** Complete record of all customer interactions

---

## What Gets Logged

### 1. Correlation Context
- `conversation_id`: Links all messages in a conversation thread
- `telegram_chat_id`: The Telegram chat/group ID
- `telegram_message_id`: The specific message that triggered the interaction
- `bot_id`: Which bot instance handled the request
- `user_id`: The user's identifier

### 2. Request Details
- `human_input`: The raw user prompt
- `intent_classification`: Auto-detected intent (e.g., "customer_lookup")
- `confidence_score`: Model's confidence in the intent

### 3. Agent Trajectory (Most Valuable!)
- `agent_thoughts`: The LLM's internal reasoning
- `actions_taken`: Which tools were called and with what parameters
- `tool_observations`: Raw outputs from each tool

### 4. Response & Metadata
- `final_output`: The actual response sent to the user
- `response_sources`: IDs of records/data used
- `model_used`: Which LLM model processed the request
- `token_usage`: Input/output token counts
- `duration_ms`: Total time for the interaction
- `error_message`: If something failed
- `feedback_score`: Optional user rating (1-5)

---

## Database Schema

### agent_interactions Table

```sql
CREATE TABLE agent_interactions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID NOT NULL,
    run_id TEXT NOT NULL,
    telegram_chat_id TEXT,
    telegram_message_id BIGINT,
    bot_id TEXT,
    user_id TEXT,
    timestamp TIMESTAMPTZ DEFAULT NOW(),
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
    created_at TIMESTAMPTZ DEFAULT NOW()
);
```

**Indexes:**
```sql
CREATE INDEX idx_actions ON agent_interactions USING GIN (actions_taken);
CREATE INDEX idx_conv ON agent_interactions (conversation_id);
CREATE INDEX idx_timestamp ON agent_interactions (timestamp DESC);
CREATE INDEX idx_user ON agent_interactions (user_id);
```

---

## Usage in Code

### Basic Usage

```python
from interaction_logger import log_agent_trajectory   # archive/blueprint/interaction_logger.py - a module bot.py does not import

log_id = log_agent_trajectory(
    conversation_id="uuid-here",
    telegram_chat_id="8551240949",
    telegram_message_id=7593,
    bot_id="agent-first-erp-crm-main",
    user_id="8551240949",
    human_input="Find Suzy Smith's contact info",
    intermediate_steps=agent_response["intermediate_steps"],
    final_output="Found 2 matches for Suzy Smith...",
    model_used="qwen3.5:122b",
    duration_ms=245
)
```

### In the Telegram Bot

**Not in the reference implementation, and this is the page's most important correction:**
`bot.py` never imports `interaction_logger` and never calls `log_agent_trajectory`, so a blueprint
run files **no** `agent_interactions` row - `grep -c log_agent_trajectory archive/blueprint/bot.py` answers 0.
The writer exists and is correct; it is simply not wired. The deployed Go agents do wire it, in the
loop's `defer` (`../../../agents/customer_service/backend_go/pkg/agent/agent.go` -> `pkg/logging`), which is
where the trajectory rows `scripts/agents/tool_testplan.sh` asserts against come from. Wiring, from
the module that does work, looks like this:

```python
# AgentExecutor is created with return_intermediate_steps=True
agent_executor = AgentExecutor(
    agent=agent,
    tools=tools,
    verbose=True,
    return_intermediate_steps=True,  # CRITICAL
)

# After invocation, log the result
result = agent_executor.invoke({"input": user_message})
log_agent_trajectory(
    conversation_id=conversation_id,
    telegram_chat_id=chat_id,
    telegram_message_id=message_id,
    bot_id=BOT_ID,
    user_id=user_id,
    human_input=user_message,
    intermediate_steps=result["intermediate_steps"],
    final_output=result["output"],
    model_used=OLLAMA_MODEL
)
```

---

## Debugging Queries

### Find All Interactions About a Specific Person

```sql
SELECT 
    human_input, 
    final_output, 
    timestamp
FROM agent_interactions 
WHERE to_tsvector('english', human_input) @@ to_tsquery('Suzy & Smith')
ORDER BY timestamp DESC;
```

### Find All Failed Interactions

```sql
SELECT 
    human_input,
    actions_taken,
    error_message,
    timestamp
FROM agent_interactions 
WHERE error_message IS NOT NULL
ORDER BY timestamp DESC;
```

### Analyze Tool Performance

```sql
SELECT 
    (actions_taken->>'tool') as tool_name,
    COUNT(*) as call_count,
    AVG(duration_ms) as avg_duration_ms,
    SUM(CASE WHEN error_message IS NOT NULL THEN 1 ELSE 0 END) as error_count
FROM agent_interactions,
     jsonb_array_elements(actions_taken) as actions_taken
GROUP BY tool_name
ORDER BY call_count DESC;
```

### Find Low-Confidence Intent Classifications

**This one answers zero rows here, always, and the reason is a schema fact:** neither backend's
recorder includes `intent_classification` or `confidence_score` in its column list, and 0 of the
`agent_interactions` rows on this server have either. What the deployment records instead is the
model's reasoning text, in `agent_thoughts`, which a reader judges rather than a threshold filtering
it. The columns are waiting for an implementation that never came.

```sql
SELECT human_input, intent_classification, confidence_score, final_output
  FROM agent_interactions
 WHERE confidence_score < 0.7            -- 0 rows, on every version of this database
 ORDER BY confidence_score ASC;

-- The question it was reaching for, answerable today: multi-step runs that still errored.
SELECT run_id, left(human_input, 60) AS asked, step_count, error_message
  FROM vw_recent_interactions
 WHERE error_message IS NOT NULL
 ORDER BY "timestamp" DESC LIMIT 20;
```

### Get Full Trajectory for a Specific Interaction

```sql
-- id is the row's uuid primary key; run_id is the identifier a caller actually holds
-- (POST /api/chat returns it). A placeholder word instead of a uuid fails 22P02 - that is
-- the type being strict, not the query being wrong.
SELECT human_input, agent_thoughts, actions_taken, tool_observations, final_output,
       response_sources, error_message, duration_ms
  FROM agent_interactions
 WHERE id = 'interaction-uuid-here';        -- or: WHERE run_id = 'the-run-uuid'
```

---

## Views for Quick Analysis

> **Names.** The three read views are `vw_*`, like every other view in this schema. The
> `v_*` spellings this page used carry no prefix the catalog has ever used, so every query
> written from them raised `42P01`. Corrected in place below.

### vw_recent_interactions

Last 100 interactions with full context:

```sql
SELECT * FROM vw_recent_interactions LIMIT 10;
```

### vw_failed_interactions

All interactions that resulted in errors:

```sql
SELECT * FROM vw_failed_interactions LIMIT 20;
```

### vw_tool_performance

Tool usage statistics and error rates:

```sql
SELECT * FROM vw_tool_performance;
```

---

## Integration with LangChain

The logging system leverages LangChain's built-in `return_intermediate_steps` feature:

```python
# When you invoke the agent
result = agent_executor.invoke({"input": user_message})

# You get back:
{
    "input": "Find Suzy Smith",
    "output": "Found 2 matches...",
    "intermediate_steps": [
        (AgentAction(tool="search", tool_input="Suzy Smith", log="Thought:..."), "Found 2 matches"),
        (AgentAction(tool="get_details", tool_input="id=42", log="Thought:..."), "Details: ...")
    ]
}
```

The `log_agent_trajectory` function extracts this data and stores it in the database.

---

## Best Practices

### 1. Always Log
Every interaction should be logged, including failures. This is critical for debugging.

### 2. Capture Context
Always include `conversation_id`, `telegram_chat_id`, `user_id`, and `message_id` for traceability.

### 3. Monitor Performance
Query `vw_tool_performance` regularly to identify slow or error-prone tools.

### 4. Review Failures
Check `vw_failed_interactions` daily to catch and fix issues quickly.

### 5. Use for Training
Export successful interactions to train fine-tuned models on real-world examples.

---

## Privacy & Security

- All logs are stored in your own PostgreSQL database
- No data leaves your infrastructure
- Sensitive data (phone numbers, emails) are stored as-is from the tool outputs
- Consider adding data masking for production deployments

---

## Troubleshooting

### Logging Fails Silently

If `log_agent_trajectory` returns `None`, check:
1. Database connectivity
2. Environment variables (POSTGRES_HOST, etc.)
3. Database permissions

The function logs errors to the Python logger, so check your application logs.

### Missing `intermediate_steps`

Make sure `return_intermediate_steps=True` is set on your `AgentExecutor`:

```python
agent_executor = AgentExecutor(
    agent=agent,
    tools=tools,
    return_intermediate_steps=True,  # This is required!
)
```

### Performance Impact

Logging is asynchronous and shouldn't impact response times. If you notice slowdowns:
1. Check database performance
2. Consider batching logs
3. Use connection pooling

---

## Future Enhancements

- **LangSmith Integration:** Add `LANGSMITH_TRACING=true` for interactive traces
- **Feedback Collection:** Add `/feedback` command for users to rate responses
- **Real-time Dashboard:** Build a web UI for monitoring interactions
- **Automated Alerts:** Notify on high error rates or performance degradation
- **Conversation Summaries:** Auto-generate summaries of long conversations

---

*Generated for Agent First ERP CRM - Interaction logging system documentation*