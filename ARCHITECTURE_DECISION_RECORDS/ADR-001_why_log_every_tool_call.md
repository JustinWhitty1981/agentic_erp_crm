# ADR-001: Why Log Every Tool Call?

**Status:** Accepted  
**Date:** July 2026  
**Authors:** Agent Swarm Team

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

*This ADR is part of the Agent Swarm Architecture Decision Records.*