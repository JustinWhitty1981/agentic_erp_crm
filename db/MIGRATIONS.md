# Migration plan — one finding, one migration

`verify.sh` and `test-functions.sh` both read this mapping, so a check is only
credited as CLOSED when the migration named here has been applied. Names are load
bearing; changing one without the other turns a green row red.

| Migration | Finding | What it changes |
|---|---|---|
| `0000_extensions` | — | vector, pg_trgm, uuid-ossp, pgcrypto, pg_stat_statements |
| `0001_baseline_canonical_port` | — | the schema as reviewed, in `public`, twin qualifiers stripped, 8 broken `COMMENT ON` targets fixed |
| `0002_access_grants` | — | auditor/runtime grants, default privileges, audit read policies |
| `0003_tenant_foundation` | 5.8 | `tenants` registry; `tenant_id uuid NOT NULL` on all 17 business tables with FK + tenant-led index; `afpc_current_tenant()` resolves the column default from `app.tenant_id` / `app.default_tenant_id`; all 6 natural keys re-scoped to be unique per tenant |
| `0004_on_hand_identity` | 4.2 | unique `(tenant_id, item_id, warehouse_id, location_id, lot_number)` with sentinels, then re-run `afpc_drop_redundant_tenant_indexes()` — the new composite makes `idx_inventory_on_hand_tenant` redundant, and 0003's assertion only holds if 0004 does this too |
| `0005_key_types` | 5.1–5.4 | integer PKs to bigint, `parent_id`/`thread_root_id` to bigint + FK, time-ordered UUIDs |
| `0006_index_hygiene` | 5.5, 5.6 | delete 8 duplicate sets, index `entities`/`contacts` search paths, index `transaction_id` |
| `0007_domain_constraints` | 5.9 | lookup tables for the 31 unconstrained status/type columns |
| `0008_delete_safety` | 5.10 | CASCADE to RESTRICT on stock edges, explicit close-out functions |
| `0009_rls_enforcement` | 5.7 | ENABLE+FORCE on all business tables, tenant policies, drop inert `app.current_agent` ones |
| `0010_timestamp_triggers` | 6.3 | one `BEFORE INSERT OR UPDATE` trigger, `created_at` on the two tables lacking it |
| `0011_idempotency` | 6.1 | `idempotency_keys` plus version-bumping triggers — ADR-005 implemented |
| `0012_vector_indexing` | 6.4 | ivfflat to hnsw, index the two unindexed embeddings, vectors to a side table |
| `0013_audit_log` | 6.2 | row-level immutable audit in `public`, append-only grants |
| `0014_movement_contract` | 4.1, 4.3 | `p_unit_of_measure`, ISSUE-branch warehouse columns, cost divisor, stop re-wrapping 23502 |
| `0015_reservation_locking` | 4.3 | handler OUT tuple, `FOR UPDATE`, honour `location_id`, no recursive movement insert |
| `0016_single_add_customer` | 4.4 | one `add_customer` overload instead of two ambiguous ones |
| `0017_tool_call_log` | 4.5 | create `agent_tool_calls` and `tickets`, or delete the code that writes them |
| `0018_currencies` | 6.5 | `currencies` + rate history, money vs quantity precision |
| `0019_partitioning` | 6.6 | partition the append-only tables, BRIN on time columns |
| `0020_temporal_controls` | 6.6 | soft delete / bitemporal columns on contacts, addresses, communications |

## Consequences a later migration must pick up

`verify.sh` prints these counts every run, so the deltas are visible rather than
remembered.

| Count | Before 0003 | After | Why |
|---|---|---|---|
| FKs | 30 | 47 | `tenant_id` FKs, RESTRICT, on 17 tables |
| tenant-coded tables | 0 | 18 | the review's "0 rows returned" for 5.8 |
| unindexed FK columns | 12 | 14 | `warehouse_id` on `inventory_on_hand` and `inventory_reservations` lost first-column coverage when their indexes were re-led with `tenant_id`. Under 0009's RLS a tenant-led index serves the hot path better; a genuinely cross-tenant stock query is a governance report, not an agent path. **0006 must confirm that judgment rather than inherit it.** |
| duplicate index sets | 8 | 4 | 4 pairs became single indexes when 0003 replaced the global natural key with a tenant-scoped unique on the same columns. The remaining 4 are pre-existing: three `idx_comm_*`/`idx_comms_*` pairs in `communications` (finding C1) and `idx_on_hand_available`/`idx_on_hand_low_stock`. **0006 is now a 4-item job, not an 8-item one.** |

Also deferred from 0003, deliberately:

- **Views.** All 12 `vw_*` views use explicit column lists, so none picked up
  `tenant_id`. 0003 reports which ones and leaves them: a view owned by `postgres`
  bypasses RLS anyway, so the fix belongs with `security_invoker` in 0009, not here.
- **`idx_movements_date (performed_at)`** is prefix-redundant with the new
  `idx_movements_tenant_date` but was not dropped: removing a pre-existing index is
  0006's remit, and doing it under the cover of a tenancy migration would make the
  tenancy diff impossible to read.
- **Row-level isolation.** `tenant_id` exists and is enforced structurally, but nothing
  filters by it yet. `db/tests/5_8_tenancy.sql` block 8d demonstrates both the read and
  the write hole, and is the KNOWN-OPEN row that 0009 turns green.
- **The backfill.** 0003's `UPDATE ... WHERE tenant_id IS NULL` is correct only because
  no earlier migration creates rows. 0004 onward must not repeat that literal: after
  0003 a NULL can only mean "the fallback resolved to nothing", and rewriting it to the
  default tenant would silently mis-file rows rather than repair them.

## Tracked as code, not migrations

Schema correctness is only half of findings 3.1 and 4.5. These are checked by
grepping the working tree rather than `schema_migrations`:

| Marker | Meaning |
|---|---|
| `code:tool_prefix` | no `agent_first_erp_crm.` qualifiers remain in `blueprint/` (33 references) |
| `code:vw_customers_filter` | `entity_type` filter decided between `= 'customer'` and `IN ('customer','prospect')` |
