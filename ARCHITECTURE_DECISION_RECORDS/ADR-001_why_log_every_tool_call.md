# ADR-001: Why Log Every Tool Call?

**Status:** Accepted - see *Consequence accounting* below for which promises the code kept
**Date:** July 2026  
**Authors:** Agent First ERP CRM Team

---

## Context

In AI agent systems, understanding why an agent made a specific decision is critical for:
- Debugging unexpected behavior
- Auditing compliance requirements
- Training and improving agent performance
- Building trust in automated systems

Traditional logging captures only the final output, losing the intermediate reasoning steps that led to that output.

---

## Decision

We will log **every** tool call made by AI agents, including:
1. **Agent thoughts** - The LLM's internal reasoning at each step
2. **Actions taken** - Which tools were called and with what parameters
3. **Tool observations** - Raw outputs from each tool
4. **Final output** - The response sent to the user
5. **Metadata** - Token usage, duration, model used, confidence scores

This data will be stored in the `agent_interactions` table with full JSONB fields for flexible querying.

---

## Consequence accounting (measured, 2026-11-05)

- **The core decision is live and load-bearing.** Every run by either deployed agent is one
  `agent_interactions` row with `actions_taken`, `tool_observations`, `response_sources`, `run_id` and
  `duration_ms`, and `vw_tool_calls` derives the per-call view from it. `scripts/agents/tool_testplan.sh`
  asserts this per release, so the ADR's own claim is now tested rather than intended.
- **Item 5 of "what is logged" is half true.** Token usage, duration and model are written;
  **confidence scores are not** - `confidence_score`, `intent_classification` and `feedback_score` are
  columns neither backend includes in its INSERT, and 0 of 101 rows have them. The reasoning text landed
  in `agent_thoughts` instead.
- **"Use async logging to minimize blocking" was not taken, deliberately.** Recording is synchronous in
  the loop's `defer` with a context detached from the request's (`context.WithoutCancel`) and a 10-second
  deadline of its own. Async would have lost exactly the runs where a client gave up mid-tool, which are
  the most useful rows in the table; the cost is the tail of the turn's latency.
- **Data retention:** none is implemented for this table. `audit_log` chains and `idempotency_keys`
  expire; `agent_interactions` grows, and partitioning it is the unapplied `0024`.
- **Data masking:** applied to the *process log* (`pkg/logging.Mask`/`MaskArgs`) and deliberately **not**
  to the trajectory, because the row is what an auditor cross-checks the trail against.
- The pointer to `scripts/database/11_interaction_logging.sql` is a **superseded** pre-0001 copy - it is
  also the file that named a full-text GIN index the canonical port never carried. The live definition is
  `db/migrations/0001_baseline_canonical_port.sql` plus `0017_interaction_readpath.sql`.

## Consequences

### Positive
- **Full traceability** - Can replay exactly what the agent did
- **Debugging power** - Can identify where reasoning went wrong
- **Training data** - Successful trajectories can be used for fine-tuning
- **Compliance** - Complete audit trail for regulated industries
- **Performance analysis** - Can identify slow or error-prone tools

### Negative
- **Storage overhead** - More data to store and manage
- **Privacy concerns** - May log sensitive information
- **Performance impact** - Writing logs adds latency

### Mitigations
- Implement data retention policies
- Add data masking for sensitive fields
- Use async logging to minimize blocking

---

## Alternatives Considered

1. **Log only failures** - Lost too much debugging context
2. **Log to external service (e.g., LangSmith)** - Adds dependency and cost
3. **No logging** - Impossible to debug or improve agent behavior

---

## References

- [Interaction Logging Documentation](../docs/INTERACTION_LOGGING.md)
- [Agent Interactions Table Schema](../scripts/database/11_interaction_logging.sql)
- [blueprint/docs/interaction_logging.md](../blueprint/docs/interaction_logging.md)

---

*This ADR is part of the Agent First ERP CRM Architecture Decision Records.*
