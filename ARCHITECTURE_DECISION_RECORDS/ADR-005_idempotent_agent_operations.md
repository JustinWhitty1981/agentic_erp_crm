# ADR-005: Idempotent Agent Operations

**Status:** Accepted - see *Consequence accounting* below for which promises the code kept
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

## Consequence accounting (measured, 2026-11-05)

- **The mechanism is real and asserted.** `idempotency_keys` with the arbiter
  `(tenant_id, operation, idempotency_key)` - tenant-led because a global claim index under forced RLS
  answers `INSERT 0 0` and loses a write silently, measured on a clone. `idempotency_claim` resolves a
  retry to claimed/replay/conflict/in_progress, and a settled key reused for a *different* request is a
  conflict, never a cache hit. Probe `6_1` covers all of it, including two backends in two tenants.
- **"Required `request_id` from the caller" is not how it turned out, and the alternative is better for
  an agent:** the key is **derived**, `pkg/ids.CallKey` = UUIDv5 of (run, operation, resolved arguments),
  so the model never types an audit-critical value and a reissued call inside one run replays. Across
  runs the keys differ on purpose - two conversations about the same customer are two events.
- **Which functions are guarded is a query, not a memory:** `vw_idempotency_status` answers pattern 1 /
  2 / 3 or **UNGUARDED** per state-changing function. Measured on this server, 2026-11-07: **15 take a
  claim** - the four the deployment started with (`add_customer`, `add_communication`, `save_memory`,
  `execute_inventory_movement`), the stock reservation door, and the ten the orders programme added
  (`create_order`, `add_order_line`, `transition_order`, `add_supplier`, `add_work_centre`,
  `plan_work_order_operation`, `ship_sales_order`, `receive_purchase_order`,
  `book_work_order_production`, `cancel_inventory_reservation`); 1 by natural uniqueness
  (`audit_summary_refresh`), 1 by version column (`retire_item`), and 3 **UNGUARDED** - `update_customer`,
  `mark_customer_followup`, `decommission_warehouse`. The first two are safe by
  idempotence-of-setting-values rather than by claim; the third is a known gap, and a tool that writes
  must either join the claim ladder or say why not.
- **A refusal releases its claim** - 0016 proved that by measurement, and probe I fixes the world rather
  than the arguments to keep it true: a key must not become a permanent "no".
- **"Emit metrics for idempotent hit vs new execution" is not implemented.** There is no metrics endpoint
  in any of the three backends. The columns exist (`hits`, `status`) and the live sum of `hits` is 0,
  because the replay path is not instrumented - which is precisely the difference between a guard and a
  guard you can see working.
- **The retention clock has a keeper, and it took a migration to notice.** *Amended 2026-11-07.* This
  ADR's original closing sentence - "`idempotency_sweep` runs for nobody unless someone schedules it, and
  until then `expires_at` is a promise with no keeper" - was true for four months and is now false in a
  way worth reading carefully, because the missing piece was never the timer. `agents/sales` runs the
  sweep hourly (`runHousekeeping`), and the sweep failed anyway: 0011 had revoked `EXECUTE` from
  `afpc_app` on purpose, on the grounds that collection is an operator action, and that closure was
  asserted once at apply time and never re-checked, so a keeper with a schedule and no grant looked, in
  the one column anybody reads, like a keeper that had found nothing to collect. **0031** is the grant,
  justified by a two-tenant measurement of reach rather than by a restatement of this paragraph, and
  `verify.sh` B30 now watches all five facts that make it the narrow thing it is. The ADR's decision
  stands - a claim is one row, keyed, with a lease and a retention - and what it had not said out loud is
  that **a policy needs a caller and a privilege, which live in different files.**

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
