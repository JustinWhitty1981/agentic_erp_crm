# ADR-004: Agent-First Interface Design

**Status:** Accepted - see *Consequence accounting* below for which promises the code kept
**Date:** July 2026  
**Authors:** Agent First ERP CRM Team

---

## Context

Traditional business software is designed with human users in mind:
- Dashboards and forms for data entry
- Click-based navigation
- Visual representations of data

However, AI agents interact differently:
- Natural language input
- Tool/function calling
- Direct data access

---

## Decision

We will design the system **for agents first**, with humans as secondary users:

1. **Natural Language Interface** - Chat/Telegram as primary UI
2. **Tool-Based Architecture** - Agents call functions, not click buttons
3. **Database-Centric** - All state lives in PostgreSQL
4. **No Dashboard Required** - Humans query via natural language

Example interaction:
```
Human: "How are sales this month?"
Agent: Queries communications and orders
Agent: "Sales are up 15% compared to last month."
```

---

## Consequence accounting (measured, 2026-11-05)

- **Chat-first held; "no frontend needed" did not, and that is the honest amendment.** Both deployed
  agents ship a React UI - `agents/*/frontend/`, built into the binary's `static/`, calling
  `window.location.origin`, so the same bundle runs on any port and there is nothing to reconfigure per
  environment. It is ~1 file of chat surface over the SSE endpoint: no dashboard, no forms, no grid.
  So "No Dashboard Required" is true in exactly the sense intended, and "simpler code - no frontend
  framework needed" is false: the framework is `react`+`vite` and it is about 300 lines.
- **The transports differ from the plan.** Telegram is in the blueprint and in the upstream reference
  drop; the deployed agents speak HTTP (`POST /api/chat`) and SSE (`POST /api/chat/stream`), and the
  loop does not care which is attached - the transport is a `main.go` change, which is the sentence this
  ADR should have led with.
- **"queries communications and orders" is stale in a way that mattered:** there is no `orders` table.
  The agent reads `communications` and the inventory views; `orders` is a planned table, and
  `inventory_reservations.order_id` is a uuid with an `order_type` and no referent, which is the shape of
  "planned" in the schema rather than in prose.
- The consequence this ADR under-sold: an agent-first interface makes the **trajectory the API**, since
  nothing else records what happened. That is why `run_id` is now returned by `POST /api/chat` and why
  `GET /api/interactions` exists on both agents.

## Consequences

### Positive
- **Faster interaction** - No navigating menus or forms
- **Natural workflow** - Talk to the system like a colleague
- **Agent autonomy** - Agents can operate without human UI
- **Simpler code** - No frontend framework needed

### Negative
- **Learning curve** - Humans must learn to "talk" to the system
- **Discovery** - Users may not know what's possible
- **Complex queries** - Ambiguous requests may need clarification

### Mitigations
- Provide examples of common queries
- Implement suggestion/autocomplete for commands
- Log and analyze failed queries to improve understanding

---

## Alternatives Considered

1. **Traditional Web UI** - Adds complexity, not agent-friendly
2. **Hybrid approach** - Compromise that satisfies neither fully
3. **Voice interface** - Similar benefits, different infrastructure

---

## References

- [Blueprint Pattern](../blueprint/AGENT_SUMMARY.md)
- [Agent Requirements](../docs/agent_requirements/)

---

*This ADR is part of the Agent First ERP CRM Architecture Decision Records.*
