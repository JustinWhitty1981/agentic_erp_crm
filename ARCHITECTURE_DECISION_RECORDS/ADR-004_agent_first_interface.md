# ADR-004: Agent-First Interface Design

**Status:** Accepted  
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
