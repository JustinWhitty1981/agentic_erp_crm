# ADR-003: View-Based Tool Design

**Status:** Accepted - see *Consequence accounting* below for which promises the code kept
**Date:** July 2026  
**Authors:** Agent First ERP CRM Team

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

## Consequence accounting (measured, 2026-11-05)

- **The pattern is what shipped, and 23 `vw_*` views are the agent's whole read path.** Note the names
  above are wrong in two ways, both corrected here rather than in the decision: the `vw_` prefix is
  mandatory in this schema (`v_item_availability` is a shape no migration ever used, and querying it
  raises `42P01`), and the four examples are `vw_customer_communications_summary`,
  `vw_pending_followups`, `vw_entity_communication_stats` and `vw_item_availability`.
- **One boundary the original did not anticipate:** a *parameterised* read cannot be a view, so
  `get_followup_customers(days)` is a function that reads like a view. That is not a violation of this
  ADR - it is the same rule applied to an argument a view cannot carry, and 0022 is what made the
  argument mean something.
- **"Use materialized views for expensive aggregations" was not taken: there are 0 materialized views in
  this database.** Every `vw_*` is a plain view, deliberately - 0009's row security is applied through
  them (`security_invoker`), and a matview would store one caller's visibility and serve it to everyone,
  which is the exact failure 0011 lost writes to in a different guise. Expensive aggregations are handled
  with indexes instead, and `vw_index_redundancy` is the tool that keeps those honest.
- **`vw_pending_followups` deserves the footnote this ADR cannot:** it is a correct view over a table
  (`followups`) that has no writer, so it is empty by construction, and the live follow-up answer is the
  function above. A view is only as good as the write path behind it, which is the half of "view-based
  design" this document should have said out loud.
- The "View Creation Script" pointer is a **superseded** copy - `scripts/database/08_create_views.sql`
  creates its views inside the twin schema and errors on the first statement. The views live in
  `db/migrations/0001`, are made tenancy-aware by `0009`, and the interaction read path came in `0017`.
  A new view is a numbered migration with grants to both read roles, never a hand-run script.

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

*This ADR is part of the Agent First ERP CRM Architecture Decision Records.*
