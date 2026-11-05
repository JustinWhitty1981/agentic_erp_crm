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
- `telegram_chat_id`: **in the deployed agents this column carries the HTTP/SSE thread id**, not a
  Telegram id - `pkg/logging/interactions.go` writes `row["thread_id"]` into it, which is why live
  values read `default`, `web:date-check`, `tp_4_195257` and the scheduled check's `schedule`. The
  column name is the pre-0001 design's; the value is this deployment's. `telegram_message_id` and
  `user_id` are in the table and are written by nothing (0 of 99 rows)
- `telegram_message_id`: The specific message that triggered the interaction
- `bot_id`: Which bot instance handled the request
- `user_id`: The user's Telegram ID

### 2. **Request Details**
- `human_input`: The raw user prompt
- `intent_classification`: Auto-detected intent (e.g., "customer_lookup")
- `confidence_score`, `intent_classification`, `feedback_score`: **columns with no writer in this
  deployment.** The Go recorder's column list (`interactions.go:323-326`) does not include them, so
  they are NULL on every row either agent has filed - 0 of 99. They are not a gap in logging, they
  are a design idea the loop never adopted, and any query that filters on one answers zero rows
  and looks like an empty system

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

`agent_interactions` is created by `db/migrations/0001_baseline_canonical_port.sql` and altered by the
migrations after it; apply the directory in filename order (`scripts/db/db up`) rather than any single
file. The page that lists which of the numbered `scripts/database/*.sql` files are superseded, and why
this one is among them, is `db/README.md` - and 0017's finding about that file is the reason this
section used to tell you to run it: 0001 ported the *table* out of it and left its *views* behind, so
the debugging instructions on this page raised 42P01 for as long as they pointed there.

Key fields:
- `agent_thoughts text[]`: one entry per reasoning step
- `actions_taken jsonb`: a JSON **array**, one object per tool call, in the order they ran
- `tool_observations jsonb`: a JSON array, same order - the pairing `vw_tool_calls` depends on, which is
  why a writer must append to both in one loop
- `run_id`: NOT NULL, and the key a retry is claimed under (`idempotency_keys`, ADR-005). A writer that
  omits it fails with 23502, which is what `interaction_logger.py` did until this session
- `response_sources jsonb`: which records the answer was built from, collected as the tools ran
- `error_message`: why the run failed. **Per run**, not per call - which is why `vw_tool_calls` labels a
  column `run_errored` rather than pretending to know which call broke

There is **no full-text index** on `human_input`, and this page claimed there was one. Searching the
trajectory is a `LIKE` or an `ILIKE` over the rows a caller's row security reaches, which on a large
table is a scan; `idx_timestamp` and `idx_agent_interactions_tenant_time` are what bounds it.

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

**The blueprint's `bot.py` does not log any turn it serves.** `grep -c log_agent_trajectory
bot.py` answers 0: the writer (`blueprint/interaction_logger.py`) exists, is correct, and is not
imported by the loop, so a reference-implementation run files no `agent_interactions` row. The
deployed Go agents are the opposite case - the record is written in the loop's `defer`, so a run
that panics or is cancelled still lands its row, and `scripts/agents/tool_testplan.sh` reads that
row back as one of its three verification planes. (`bot_with_logging.py` is the name this page used
for it; that file is not in the repository, which is the kind of thing `T4`'s check looks for in the
docs rather than in the code.)

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
-- Do not aggregate actions_taken by hand. This is the form this page carried, and it is not an
-- error - it is worse than an error:
--
--   SELECT (actions_taken->>'tool') as tool_name, COUNT(*) as call_count
--     FROM agent_interactions, jsonb_array_elements(actions_taken) as actions_taken
--    GROUP BY tool_name;
--
-- The alias shadows the column it was expanded from, so `->>'tool'` resolves against the
-- wrong thing and the query answers ONE row - tool_name NULL, call_count 265 on this server
-- this minute. A green result that means nothing.
--
-- vw_tool_calls derives the per-call grain positionally instead - step n of actions_taken
-- with step n of tool_observations, because the loop appends one of each per iteration - and
-- vw_tool_performance counts at that grain while timing and erroring at the run grain:
SELECT tool_name, call_count, run_count, mean_run_duration_ms, errored_run_pct
  FROM vw_tool_performance
 ORDER BY call_count DESC;
```

One truth the view cannot express, stated in 0017's own words: **per-call errors are not
derivable.** The base table has one `error_message` per *run*, and `tool_observations[].type`
is a Python class name that reads `str` for a result and for an error alike, so `run_errored`
on a per-call row is a run-level fact wearing a call's clothes. `vw_tool_performance`'s error
percentage is therefore "runs that used this tool and errored", which is a different number
from "calls that failed" and is named that way on purpose.

### Find Low-Confidence Intent Classifications

**This query cannot work on this server, and the reason is a fact about the schema.** Neither
deployed agent writes `intent_classification` or `confidence_score` - they are not in the Go
recorder's column list (`pkg/logging/interactions.go`), and 0 of 101 rows have either. The
design assumed the model would report its own confidence; what shipped is the model's reasoning
text in `agent_thoughts`, which a reader can judge. Kept so a future embedder of intent scoring
knows the columns are waiting:

```sql
SELECT human_input, intent_classification, confidence_score, final_output
  FROM agent_interactions
 WHERE confidence_score < 0.7           -- answers 0 rows here, always
 ORDER BY confidence_score ASC;

-- What answers the same *question* today: runs that took more than one tool call and still
-- errored, which is the closest observable to "the agent was unsure":
SELECT run_id, left(human_input, 60) AS asked, step_count, error_message
  FROM vw_recent_interactions
 WHERE error_message IS NOT NULL
 ORDER BY "timestamp" DESC LIMIT 20;
```

### Get Full Trajectory for a Specific Interaction

```sql
-- id is the row's uuid primary key; run_id is the one a caller is given (POST /api/chat returns
-- it). Use whichever you have - and put a real uuid in, because a placeholder word fails 22P02:
-- that is the column being strict about its type, not the query being wrong.
SELECT human_input, agent_thoughts, actions_taken, tool_observations, final_output,
       response_sources, error_message, duration_ms
  FROM agent_interactions
 WHERE id = 'interaction-uuid-here';        -- or: WHERE run_id = 'the-run-uuid'
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
-- The correlation key is run_id, the value POST /api/chat returns and SSE carries in its done
-- event. interaction_id is the row's own uuid and no caller is ever handed it, so filtering by
-- it works only after you have found the row some other way. Replace the placeholder with a
-- real uuid: a bare word fails 22P02, which is the column being strict, not the query being wrong.
SELECT step_number, tool_name, tool_input, observation #>> '{}' AS output
  FROM vw_tool_calls
 WHERE run_id = '4f9b1c2e-7a5d-4e8b-9c3f-1d2e3f4a5b6c'
 ORDER BY step_number;
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

Recording is **synchronous**, inside a `defer`, with a context detached from the request's and a
deadline of its own (10s). That is a deliberate trade: an async writer would lose exactly the runs
where a client gave up on a slow tool, which are the most useful rows in the table - and the cost
is the tail of the turn's latency. If you notice slowdowns: If you notice slowdowns:
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

- [db/README.md](../db/README.md) - the schema's source of truth. (`scripts/database/` is the superseded pre-0001 copies; its README opens with why nothing in it should be run.)
- [Blueprint Documentation](../blueprint/README.md)
- [Agent Requirements](../docs/agent_requirements/)

## In the deployed agents

Both Go agents write this table from one place, `pkg/logging`: the loop accumulates a run's tool calls
and observations, and a `defer` files the row with `run_id`, `conversation_id` (a UUIDv5 of the thread,
`pkg/ids`), `bot_id` from `AGENT_ROLE`, `duration_ms`, and `response_sources` naming the rows it touched.
Two consequences worth knowing before debugging with this page:

- **Read it through the endpoint as well as the table.** `GET /api/interactions?view=recent|failed|tool_calls|performance`
  is the agent reading its own trajectory, and `&bot_id=inventory` filters to one agent's rows.
  (`performance` groups by tool across every agent, so asking it for one agent is refused rather than
  answered with everyone's.)
- **`vw_tool_calls` is derived, not stored.** Step *n* of `actions_taken` pairs with step *n* of
  `tool_observations`, and `observations_aligned` states whether that agreement held. A run whose
  observations did not align is a recorder bug or a panic mid-loop, and it is visible as a column
  rather than something you notice by reading prose.
