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
| `0004_on_hand_identity` | 4.2 | unique expression identity `(tenant_id, item_id, warehouse_id, COALESCE(location_id,nil), COALESCE(lot_number,''))`; the function's `ON CONFLICT` arbiter is extended to name `tenant_id` in the same migration, because inference matches an index's key columns **as a set** and a 4-column target cannot reach a 5-column unique; deterministic merge of pre-existing duplicates, refusing to guess when they differ in real location or lot |
| `0005_key_types` | 5.1–5.4 | integer PKs to bigint, `parent_id`/`thread_root_id` to bigint + FK, time-ordered UUIDs |
| `0006_index_hygiene` | 5.5, 5.6 | delete 8 duplicate sets, index `entities`/`contacts` search paths, index `transaction_id` |
| `0007_domain_constraints` | 5.9 | lookup tables for the 31 unconstrained status/type columns |
| `0008_delete_safety` | 5.10 | CASCADE to RESTRICT on stock edges, explicit close-out functions |
| `0009_rls_enforcement` | 5.7 | ENABLE+FORCE on all business tables, tenant policies, drop inert `app.current_agent` ones |
| `0010_timestamp_triggers` | 6.3 | one `BEFORE INSERT OR UPDATE` trigger, `created_at` on the two tables lacking it |
| `0011_idempotency` | 6.1 | `idempotency_keys` plus version-bumping triggers — ADR-005 implemented |
| `0012_vector_indexing` | 6.4 | ivfflat to hnsw, index the two unindexed embeddings, vectors to a side table |
| `0013_audit_log` | 6.2 | row-level immutable audit in `public`, append-only grants |
| `0014_movement_contract` | 4.1, 4.2, 4.3 | `p_unit_of_measure`, ISSUE-branch warehouse columns, cost divisor, stop re-wrapping 23502, **and assert `ROW_COUNT` in the ISSUE branch** (the phantom-issue half of 4.2, which no constraint can express; the ON CONFLICT line moved to 0004) |
| `0015_reservation_locking` | 4.3, 4.2 | handler OUT tuple, `FOR UPDATE`, honour `location_id` — now including the **multi-bin double-decrement** below — no recursive movement insert |
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

### Found while building 0004

- **`ON CONFLICT` inference matches an index's key columns as a SET, not a prefix.**
  All five cases are executed by `db/tests/0_0_conflict_inference_rule.sql`, and the
  practical rule is: adding a column to a unique index breaks every `ON CONFLICT` written
  against it. 0006 must check for inference sites before "improving" any unique index.
  Column *order* is free; membership is not.
- **A warehouse-wide ISSUE decrements the full quantity from every bin.** Two bins holding
  10 each, one movement of 5, leaves 10 units on the books. This is new beyond review 4.2,
  and it is a consequence of fixing 4.2: before 0004 the duplicates were unrepresentable
  in practice because the receipt path could not insert. `inventory_movements` also has
  `from_location_id`/`to_location_id` that no function ever populates, which is why the
  WHERE clause has nothing location-aware to use. Tracked in 0015.
- **The nil UUID is already the schema's "no location" value** —
  `reserve_inventory_for_order` is called with it by `db/tests/4_3` and by the tools. An
  earlier draft of 0004 forbade it on `locations` while simultaneously defaulting
  `locations.location_id` to it, which made every location INSERT fail with 23514. The
  guard now sits only on `inventory_on_hand`, where the collision would actually matter.
- **The dedup/merge path in 0004 was rehearsed on a clone, and that found a bug that
  nothing else could reach.** `CREATE DATABASE afpc_rehearse TEMPLATE agent_first_erp_crm`,
  drop the identity index, insert duplicates, run section 3 verbatim. Scenario A (three
  quantity-only copies) merged to 1 row / 15 units / version 7, survivor = most recent.
  Scenario C (NULL lot beside empty-string lot, which collapse under the sentinel) refused
  with the conflicting spellings named. **The merge's `DELETE ... USING ranked` referenced a
  CTE that had gone out of scope with the preceding `UPDATE`** - correct SQL, wrong
  statement, and it would have aborted the first real population with `relation "ranked"
  does not exist`, because on this host `v_group` is always 0 and the block returns before
  reaching it. Also: two of the ambiguity conditions were dead code - within one collapsed
  key, `location_id` can only be NULL or nil, never a real bin - so they are removed rather
  than left to imply a protection that does not exist.
- **Clones and restored copies had no tenant context.** `ALTER DATABASE ... SET` is stored
  in `pg_db_role_setting`, which `CREATE DATABASE ... TEMPLATE` does not copy, so a rehearsal
  clone failed every INSERT with `no tenant context`. Fixed by mirroring the value with
  `ALTER SYSTEM` in `init.sh`; the database-level setting still wins where it exists, so a
  deliberate override is never silently replaced.

### Fixed in the tooling during 0004

`db fresh` and `db up` ran their acceptance steps under `|| true`, so a rebuild reported
exit 0 while the function harness was red. The first migration run since that was
introduced is the one that caught it, which is the entire argument against it.
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
