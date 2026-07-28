# ADR-005: Idempotent Agent Operations

**Status:** Proposed  
**Date:** 2026-07-28  
**Authors:** Justin Whitty  

## Context

Our agent-first ERP/CRM system relies on autonomous agents that:
- Retry operations on network failures
- May process the same request multiple times
- Operate in a distributed environment where race conditions are possible

Without idempotency guarantees these scenarios produce:
- Duplicate customer records
- Duplicate communication logs
- Data corruption from repeated state changes

A single retried `add_customer` call under network partition has already produced duplicate records in staging; the same pattern will surface in production under agent retries and concurrent instances.

## Decision

All operations that create, update, or delete persistent state (including side-effecting calls that write to external systems) must be **idempotent**.  
Read-only operations are exempt.

### Implementation Patterns (preferred order)

1. **Natural uniqueness + Upsert**  
   Unique constraints (email, external_id, …) + `ON CONFLICT DO UPDATE` / `INSERT … ON CONFLICT`.

2. **Client-supplied idempotency key**  
   Required `request_id` (UUID) stored in a deduplication table (or Redis) with a TTL. Return the cached result on replay.

3. **State-guarded updates**  
   `UPDATE … WHERE current_status = 'expected'` (or a version column) so an already-applied change is a no-op.

4. **Request-level caching** (last resort)  
   Short-lived cache keyed by the full request hash when the above cannot be applied.

### Examples

- `add_customer(email, …)` → unique index on `email` + upsert; return existing row on conflict.
- `add_communication(request_id, …)` → store `request_id` in `idempotency_keys`; return previous result if seen.
- `update_customer_status(id, new_status)` → `UPDATE … WHERE status <> new_status` (or use a version column).

## Consequences

**Positive:**
- Safe retries without data corruption
- Graceful handling of network failures
- Scalable across multiple agent instances

**Negative:**
- Additional complexity in operation design
- Need for caching / deduplication infrastructure (PostgreSQL table or Redis)
- Slight performance overhead for duplicate detection
- Requires a clear policy for key lifetime and garbage collection

**Operational:**
- Emit metrics for “idempotent hit” vs “new execution” to detect retry storms
- Every mutating agent tool must include an explicit “call twice → same result / no extra rows” test

## References

- HTTP Idempotency: https://developer.mozilla.org/en-US/docs/Web/HTTP/Methods
- Stripe’s Idempotency Guide: https://stripe.com/docs/api/idempotent_requests
- Previous discussion: Conversation #8921 (2026-07-28)
