# ADR-002: Database-First Architecture

**Status:** Accepted  
**Date:** July 2026  
**Authors:** Agent First ERP CRM Team

---

## Context

AI agents require persistent, structured memory to operate effectively in business contexts. Traditional approaches include:
- In-memory state (loses context between sessions)
- External vector databases (adds complexity and cost)
- API-based data access (slow and limited)

---

## Decision

We will use **PostgreSQL as the single source of truth** for all agent state, knowledge, and memory:

1. **Structured data** - Normalized tables for entities, contacts, communications, inventory
2. **Semantic memory** - PGVector embeddings for natural language search and similarity
3. **Audit trail** - Complete logging of all agent actions and human sessions
4. **Tool functions** - SQL functions stored in the database catalog

---

## Consequences

### Positive
- **Single source of truth** - No data synchronization needed
- **ACID compliance** - Transactional integrity for all operations
- **Full SQL power** - Complex queries, aggregations, and joins
- **Semantic search** - Hybrid queries combining structured + vector search
- **Cost effective** - No additional database infrastructure needed
- **Agent friendly** - Tools can be SQL functions directly

### Negative
- **Coupling** - Agents tightly coupled to database schema
- **Migration complexity** - Schema changes require careful planning
- **Performance** - Complex queries may be slower than NoSQL alternatives

### Mitigations
- Use database views for abstraction
- Implement proper indexing strategies
- Use connection pooling for performance

---

## Alternatives Considered

1. **MongoDB + Vector DB** - More flexible but loses ACID guarantees
2. **Redis for state** - Fast but no persistence
3. **Graph database** - Better relationships but less mature tooling

---

## References

- [Database Mental Model](../docs/database/agent_first_erp_crm_mental_model.md)
- [Schema Reference](../docs/database/agent_schema_reference.md)
- [blueprint/docs/schema_reference.md](../blueprint/docs/schema_reference.md)

---

*This ADR is part of the Agent First ERP CRM Architecture Decision Records.*
