# Interaction Logging System

## Overview

The Agent First ERP CRM system includes enterprise-grade interaction logging that captures **every** agent-human interaction in detail. This enables:

- **Debugging**: Understand exactly why an agent made a specific decision
- **Auditing**: Full audit trail of all agent actions
- **Performance Analysis**: Track tool usage, response times, and error rates
- **Training**: Use real interactions to improve agent behavior
- **Compliance**: Complete record of all customer interactions

## What Gets Logged

For every interaction, we capture:

### 1. **Correlation Context**
- `conversation_id`: Links all messages in a single conversation thread
- `telegram_chat_id`: The Telegram chat/group ID
- `telegram_message_id`: The specific message that triggered the interaction
- `bot_id`: Which bot instance handled the request
- `user_id`: The user's Telegram ID

### 2. **Request Details**
- `human_input`: The raw user prompt
- `intent_classification`: Auto-detected intent (e.g., "customer_lookup")
- `confidence_score`: Model's confidence in the intent

### 3. **Agent Trajectory** (Most Valuable!)
- `agent_thoughts`: The LLM's internal reasoning ("Thought: I should search for...")
- `actions_taken`: Which tools were called and with what parameters
- `tool_observations`: Raw outputs from each tool

### 4. **Response & Metadata**
- `final_output`: The actual response sent to the user
- `response_sources`: IDs of records/data used
- `model_used`: Which LLM model processed the request
- `token_usage`: Input/output token counts
- `duration_ms`: Total time for the interaction
- `error_message`: If something failed
- `feedback_score`: Optional user rating (1-5)

## Database Schema

The `agent_interactions` table is created by running:

```bash
psql -h {your-database-host} -U {your-username} -d {your-database-name} -f scripts/database/11_interaction_logging.sql
```

Key fields:
- `agent_thoughts[]`: Array of thought strings
- `actions_taken[]`: JSON array of tool calls
- `tool_observations[]`: JSON array of tool outputs
- Full-text search enabled on `human_input`

## Usage in Code

### Basic Usage

```python
from tools.interaction_logger import log_agent_trajectory

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

The `bot_with_logging.py` file automatically logs all interactions:

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

```sql
SELECT 
    human_input,
    intent_classification,
    confidence_score,
    final_output
FROM agent_interactions 
WHERE confidence_score < 0.7
ORDER BY confidence_score ASC;
```

### Get Full Trajectory for a Specific Interaction

```sql
SELECT 
    human_input,
    agent_thoughts,
    actions_taken,
    tool_observations,
    final_output
FROM agent_interactions 
WHERE id = 'interaction-uuid-here';
```

## Views for Quick Analysis

Four views over `agent_interactions`, created by `db/migrations/0017_interaction_readpath.sql`.
They were documented here long before they existed in the schema - `0001` ported the table out of
`blueprint/11_interaction_logging.sql` and left that file's views behind, so this page's
instructions raised `42P01` for fifteen migrations. They also carry the two grain distinctions the
legacy definitions got wrong, so read the column names, not the habit:

### `vw_recent_interactions`
Every interaction the caller's row security reaches

```sql
SELECT * FROM vw_recent_interactions ORDER BY "timestamp" DESC LIMIT 10;
```

There is no `LIMIT` inside the view. The legacy one truncated to 100 rows *before* the caller's
filter ran, so a query for a specific bot's recent runs could answer **0 rows** while the table
held 5 (measured, and probe D asserts the fix). "Last 100" is a thing the caller writes.
`step_count` is exposed so a scan does not have to expand `actions_taken` to decide whether a run
is worth opening.

### `vw_failed_interactions`
Runs that ended with an `error_message`

```sql
SELECT * FROM vw_failed_interactions ORDER BY "timestamp" DESC LIMIT 20;
```

`error_message` is one column per **run**, so this answers "which runs failed", never "which tool
failed". Use `vw_tool_calls` to see the steps of a failing run; the finest grain that has an error
is the run.

### `vw_tool_calls`
One row per tool invocation, derived by position

```sql
SELECT step_number, tool_name, tool_input, observation #>> '{}' AS output
  FROM vw_tool_calls WHERE interaction_id = 'the-run-uuid' ORDER BY step_number;
```

Step *n* of `actions_taken` paired with step *n* of `tool_observations`. This is the grain a table
named `agent_tool_calls` would have stored; 0017 derives it rather than keep a second log of the
same calls, because two writers of one fact drift. `observations_aligned` says whether the two
arrays in that run had the same length - when they do not, the unpaired steps read `observation IS
NULL` and the column says so, rather than showing an output against the wrong tool.

### `vw_tool_performance`
Tool usage statistics and error rates, per tenant

```sql
SELECT tool_name, call_count, run_count, mean_run_duration_ms, errored_run_pct
  FROM vw_tool_performance;
```

Counts are measured at the call grain; durations and errors at the run grain. The legacy version
mixed them: a run that errored and had used three tools printed `error_count = 3` where the truth
is one errored run, and averaging a run's duration once per call turned 900 ms beside 100 ms into
700 ms rather than 500. Both numbers are reproduced in the migration's header. `tenant_id` is a
grouping key, so two tenants' usage never adds together (0009's rule for aggregate views).

One row whose `actions_taken` holds a JSON object instead of an array contributes nothing to these
views instead of taking the report down for every reader, which is what it did to the legacy one
(`22023`, measured).

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

## Best Practices

### 1. **Always Log**
Every interaction should be logged, including failures. This is critical for debugging.

### 2. **Capture Context**
Always include `conversation_id`, `telegram_chat_id`, `user_id`, and `message_id` for traceability.

### 3. **Monitor Performance**
Query `vw_tool_performance` regularly to identify slow or error-prone tools.

### 4. **Review Failures**
Check `vw_failed_interactions` daily to catch and fix issues quickly.

### 5. **Use for Training**
Export successful interactions to train fine-tuned models on real-world examples.

## Privacy & Security

- All logs are stored in your own PostgreSQL database
- No data leaves your infrastructure
- Sensitive data (phone numbers, emails) are stored as-is from the tool outputs
- Consider adding data masking for production deployments

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

## Future Enhancements

- **LangSmith Integration**: Add `LANGSMITH_TRACING=true` for interactive traces
- **Feedback Collection**: Add `/feedback` command for users to rate responses
- **Real-time Dashboard**: Build a web UI for monitoring interactions
- **Automated Alerts**: Notify on high error rates or performance degradation
- **Conversation Summaries**: Auto-generate summaries of long conversations

## Related Documentation

- [Database Scripts README](../scripts/database/README.md)
- [Blueprint Documentation](../blueprint/README.md)
- [Agent Requirements](../docs/agent_requirements/)
