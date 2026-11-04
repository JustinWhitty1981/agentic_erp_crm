# Database tables - generated

Regenerated from the live catalog by `scripts/docs/gen_schema_docs.sh` (the `make
docs-schema` target) on 2026-11-04. **Do not edit**: the next run replaces this file. Prose
about tables belongs in `db/README.md`; the checks over them live in
`scripts/db/verify.sh`.

What this cannot show is whether the policies are FORCED or work, or which tables leave a trail:
`vw_rls_status` and `vw_audit_coverage` answer those, in SQL, from the same catalog.

```
name | kind | policies | rls | comment
_schema_graph|table|0|off|Knowledge graph of the agent_first_erp_crm schema for AI agent understanding. Query this table to understand the entire system structure.
addresses|table|2|on|
agent_interactions|table|2|on|
agent_memories|table|2|on|What the agent was told to remember, one row per entry, append-only. Replaces the markdown files under memory_store/, which lived and died with the container's filesystem and whose key identity was a sanitised filename (so "a/b" and "a_b" were silently the same memory). A key may be written many times - the history is the point, and get_memory shows it newest first. Nothing updates a row and nothing in the schema deletes one from an agent's seat, which is why there is no updated_at: 0010's register publishes this table as append-only by decision and probe H watches the verdict rather than the claim. Tenancy, row security, and the row trail are the same mechanisms every other tenant-coded table uses. Built by 0023.
audit_log|table|2|on|Row-level, append-only change history - the mechanism 6.2 found missing. One row per INSERT/UPDATE/DELETE on every tenant-coded table except audit_log (recursion) and idempotency_keys (transient state; see vw_audit_coverage for the register and reasons). Append-only by GRANT (no UPDATE/DELETE/TRUNCATE to any role but the owner - a superuser bypass is EXPOSED, not prevented, which is what the hash chain is for) and tamper-evident per (tenant, month) segment: row_hash = sha256(prev_hash || canonical payload), genesis hash derived from the segment identity, so nothing external has to be trusted. UPDATE stores only the changed columns in old/new (vectors as '<vector omitted>' - their stringification costs 60x the rest of an audit row, measured). row_pk is the primary key as {column: value} jsonb: polymorphic by necessity across 18+ tables, which review 3.x calls unenforceable and 6.6 will make prunable; here it is an evidence field, not a join. Built by 0013.
audit_summary|table|2|on|
bot_actions|table|2|on|
communications|table|2|on|
contacts|table|2|on|
costing_methods|table|0|off|Master data: how an item's cost is derived. Referenced by inventory_items.cost_method and item_categories.default_cost_method - the same vocabulary in two columns, which is the second reason this is a table: a CHECK would state the list twice and let the two copies drift. Global reference data. Built by 0007 (review 5.9).
currencies|table|0|off|ISO 4217 currency codes: the master data behind the three currency columns the baseline put in the inventory model with no table to point at (6.5). Global by decision - a currency is a fact about money, not about a tenant - which is declared in verify.sh's B19 rather than left as an absence, the same exemption units_of_measure and costing_methods carry. Retired with is_active, never deleted: the FKs are RESTRICT (0008), and a balance priced in a currency that has ceased to exist is a history question, not a cleanup. currency_code's shape is CHECKed here and nowhere else: the referencing columns' mechanism is the foreign key, and a rule stated on both sides of a relationship is two rules. Built by 0018.
currency_rates|table|0|off|One row per currency pair per period: the rate history 6.5 found missing, so that a cost valuation no longer has to assume one rate forever. It does not yet change any valuation - nothing converts (§0's first declined decision): who the base currency of a tenant is, which rate applies to an average built from months of receipts, and whether an inverse is a reciprocal or a stored row are three decisions this file refuses to make as a side effect of a CREATE TABLE. Global by decision like the other master data, so verify.sh's B19 declares it, and outside 0013's trail because audit_log.tenant_id is NOT NULL and no tenant owns a market rate - probe L asserts that boundary rather than leaving it to be noticed. The mechanical promise is one open row per pair; overlaps across closed rows and gaps between them are not constrained, and probe E demonstrates the gap rather than claiming it away.
entities|table|2|on|
entity_relationships|table|2|on|
followups|table|2|on|
human_sessions|table|2|on|
idempotency_keys|table|2|on|ADR-005 pattern 2, and the mechanism 6.1 measured as absent: one row per request an agent has been asked to run, so a retry answers with the first attempt's outcome instead of performing the operation twice. The arbiter is (tenant_id, operation, idempotency_key) because a global one loses writes: measured on a clone, tenant B's claim of a key tenant A already held returned INSERT 0 0 with no error and nothing visible to B. A key is therefore unique per tenant per operation, which is also what makes a leaked key from one customer of this database useless as a denial of service to another. In-flight rows carry a LEASE, not a lock: an attempt that dies leaves its row in_flight until the lease lapses, at which point the next claim takes it over rather than waiting for a garbage collector. Built by 0011.
inventory_items|table|2|on|
inventory_movements|table|2|on|
inventory_on_hand|table|2|on|
inventory_reservations|table|2|on|
item_categories|table|2|on|
locations|table|2|on|
schema_migrations|table|0|off|
tenants|table|2|on|Tenant registry. Under 0009 an agent role reads only its own row, cannot create a tenant (a fresh key cannot satisfy the WITH CHECK), and cannot change or delete any other tenant's row; renaming its own entry is permitted. The audit roles read the whole registry, which is the point of having them.
units_of_measure|table|0|off|Master data: the units an item can be counted, weighed or measured in. Referenced by inventory_items.base_unit_of_measure, inventory_items.weight_unit, inventory_items.dimension_unit and inventory_movements.unit_of_measure. Global reference data, deliberately not tenant-scoped: a kilogram is the same in every tenant. Adding a unit is an INSERT, not a migration - which is the whole reason this is a table and not a CHECK. Built by 0007 (review 5.9).
warehouses|table|2|on|
```
