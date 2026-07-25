# ADR-003: View-Based Tool Design

**Status:** Accepted  
**Date:** July 2026  
**Authors:** Agent Swarm Team

---

## Context

AI agents need to query complex data relationships efficiently. Direct table access requires agents to:
- Understand complex JOINs
- Know which columns to select
- Handle NULL values gracefully
- Write efficient queries

This creates friction and increases the chance of errors.

---

## Decision

We will design **database views** as the primary interface for agent tools:

1. **Pre-joined data** - Views encapsulate complex JOINs
2. **Simplified columns** - Only relevant fields exposed
3. **Business logic** - Calculated fields in views (e.g., sentiment labels)
4. **Consistent interface** - Same view structure regardless of underlying changes

Example views:
- `customer_communications_summary` - Full customer interaction context
- `pending_followups` - Tasks requiring action
- `entity_communication_stats` - Aggregated customer metrics
- `v_item_availability` - Stock levels across warehouses

---

## Consequences

### Positive
- **Simpler agent tools** - Tools query views, not raw tables
- **Consistent data** - Same view returns same structure
- **Easier debugging** - Views can be queried directly
- **Performance** - Views can include optimized indexes
- **Abstraction** - Underlying schema can change without breaking tools

### Negative
- **View maintenance** - Views must be updated with schema changes
- **Potential complexity** - Nested views can be hard to debug
- **Performance overhead** - Complex views may be slower than direct queries

### Mitigations
- Document all views with purpose and columns
- Use materialized views for expensive aggregations
- Test views independently

---

## Alternatives Considered

1. **Raw table access** - Too complex for agents
2. **Application-layer abstraction** - Adds Python code complexity
3. **GraphQL layer** - Adds infrastructure complexity

---

## References

- [Views Documentation](../blueprint/docs/views.md)
- [View Creation Script](../scripts/database/08_create_views.sql)

---

*This ADR is part of the Agent Swarm Architecture Decision Records.*