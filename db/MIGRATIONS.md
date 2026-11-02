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
| `0005_key_types` | 5.1–5.4 | integer key columns → bigint (19 widened, derived from `pg_constraint` **plus** the name rule, because `thread_root_id` has no constraint to derive it from — the finding's own subject would otherwise be skipped), **and their 6 owned sequences raised to bigint with it**, since `ALTER COLUMN TYPE` leaves the sequence's ceiling alone; `thread_root_id` gets the FK it never had; `afpc_uuid_v7()` replaces `gen_random_uuid()` on all 13 UUID primary keys; the four functions that returned `entity_id integer` are widened, because widening the table and not the API only moves the ceiling |
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
| `0016_single_add_customer` | 4.4 | one `add_customer` overload instead of two ambiguous ones. The `integer` → `bigint` widening of its OUT columns was done in `0005` (a type fix, not a behaviour fix), so what remains here is the overload collapse — and note that named arguments do **not** disambiguate the current pair, because both share the first four parameter names |
| `0017_tool_call_log` | 4.5 | create `agent_tool_calls` and `tickets`, or delete the code that writes them |
| `0018_currencies` | 6.5 | `currencies` + rate history, money vs quantity precision |
| `0019_partitioning` | 6.6 | partition the append-only tables, BRIN on time columns |
| `0020_temporal_controls` | 6.6 | soft delete / bitemporal columns on contacts, addresses, communications |

## Consequences a later migration must pick up

`verify.sh` prints these counts every run, so the deltas are visible rather than
remembered.

| Count | Before 0003 | After 0004 | After 0005 | Why |
|---|---|---|---|---|
| FKs | 30 | 47 | 48 | `tenant_id` FKs, RESTRICT, on 17 tables; then `thread_root_id`, which 5.2 found had no constraint at all |
| tenant-coded tables | 0 | 18 | 18 | the review's "0 rows returned" for 5.8 |
| FKs with no index anywhere | 12 | 11 | 11 | the corrected measure (see below): a column in no key position of any index. Unchanged by 0005 — `idx_comms_thread_root` already covers the new FK |
| FK columns leading no index | — | 14 | 14 | planning-only, printed for contrast. **0006 must confirm the judgment on these rather than inherit it**: `warehouse_id` on `inventory_on_hand`/`inventory_reservations` lost first-column coverage when 0003 re-led their indexes with `tenant_id` |
| duplicate index sets | 8 | 3 | 3 | 4 pairs became single indexes when 0003 replaced the global natural key with a tenant-scoped unique; `0004` removed `idx_on_hand_available`/`idx_on_hand_low_stock`. The remaining 3 are pre-existing `idx_comm_*`/`idx_comms_*` pairs in `communications` (correction C1). **0006 is a 3-item job.** |
| integer key columns | 19 | 19 | **0** | 5.1/5.3: four serial PKs and fifteen referencing columns, widened together |
| key columns narrower than their ceiling | 4 | 4 | **0** | bigint columns fed by an integer sequence — see B14 |

Also deferred from 0003, deliberately:

- **Views.** All 12 `vw_*` views use explicit column lists, so none picked up
  `tenant_id`. 0003 reports which ones and leaves them: a view owned by `postgres`
  bypasses RLS anyway, so the fix belongs with `security_invoker` in 0009, not here.
  0005 dropped and recreated eight of them (they blocked the retype) and proved the
  recreation was faithful column-for-column; the `tenant_id` gap is still 0009's.
- **`idx_movements_date (performed_at)`** is prefix-redundant with the new
  `idx_movements_tenant_date` but was not dropped: removing a pre-existing index is
  0006's remit, and doing it under the cover of a tenancy migration would make the
  tenancy diff impossible to read.
- **Row-level isolation.** `tenant_id` exists and is enforced structurally, but nothing
  filters by it yet. `db/tests/5_8_tenancy.sql` block 8d demonstrates both the read and
  the write hole, and is the KNOWN-OPEN row that 0009 turns green.

## Found while building 0005

- **`ALTER COLUMN ... TYPE bigint` does not change the sequence behind it.** Measured:
  column `bigint`, `entities_id_seq` still `integer` with `max_value = 2147483647`. The
  table accepts a value nothing can generate. `verify.sh` B14 asserts the *pair*, because
  B9 asserting the column alone was a green light over an unchanged ceiling — the same
  shape of defect as 5.2 itself. (`ALTER SEQUENCE ... AS bigint` preserves both the current
  value and the owned-by dependency: verified `last=25 -> nextval=26`.)
- **Widening one side of an FK silently creates a new 5.2.** `addresses.entity_id` to
  bigint while `entities.id` is integer succeeds, leaves `convalidated = true`, and leaves a
  cross-type comparison that will raise `22003` at a row count. So the widening is derived
  from `pg_constraint`, both ends move in one transaction, and B13 asserts that zero
  cross-type FK edges exist anywhere — 5.2 as a class rather than as one column.
- **A constraint-derived list would have skipped the finding's own subject.**
  `thread_root_id` is an integer key column with no PK and no FK on it — that *is* 5.2 — so
  "widen every integer column that is a PK or the referencing side of an FK" leaves it
  exactly as it was while reporting success. The rule gained a third clause (`id`, `%_id`
  by name) for that reason.
- **Views block the retype, and `DROP VIEW` costs more than the view.** Eight views read
  the retyped columns; Postgres refuses the ALTER until they are gone. Recreating them from
  `pg_get_viewdef` is faithful for columns and self-healing for grants (0002's
  `ALTER DEFAULT PRIVILEGES` re-applies them — checked, not assumed) but **loses
  `COMMENT ON VIEW`**, which is how correction C4 happened in the first place. The
  descriptions are captured and re-applied, and asserted equal in count afterwards.
- **`pg_attribute` has rows for indexes.** A name-based rule with no `relkind` filter
  produced `ALTER TABLE public.addresses_pkey ALTER COLUMN id TYPE bigint`. Every catalog
  scan in this migration now says `relkind IN ('r','p')`.
- **`public` contains 198 extension-owned functions and 4 aggregates** (`array_agg`, `avg`,
  `sum` from pgvector). `pg_get_functiondef()` **raises** on an aggregate, so an unfiltered
  scan of `public` fails on rows that are not ours. Both function loops now exclude
  extension-owned objects, the same convention `verify.sh` uses for its counts — which is
  how the loop found 4 real functions instead of erroring out.
- **`add_customer` is ambiguous even with named arguments.** Both overloads share the first
  four parameter names, so `p_first_name => ...` does not disambiguate. Confirmed while
  writing a test that assumed otherwise; `db/tests/5_1_3_4_*` reports it as INFO rather
  than borrowing 0016's finding.
- **Sequences moved by a test are residue the row-count check cannot see.**
  `test-functions.sh` restored exactly one counter, by name. It now restores every serial
  sequence from its own `max(id)` before and after, and reports drift as residue — with
  `greatest(v,1)`, because `setval(seq, 0)` is an error and an empty table's `max()` is 0.
  The first run of the new check is what caught the failed restore.
- **`uuid_generate_v1mc()` is not the fix 5.4 suggests.** Its leading 32 bits are
  `time_low`, so byte order matches time order only inside one 429-second cycle: measured,
  19 of 20 keys straddling a boundary sort before a key written after them. A btree using
  it walks backwards roughly every seven minutes, forever. `afpc_uuid_v7()` — 48-bit
  millisecond timestamp, 12-bit sub-millisecond slot in `rand_a` (RFC 9562 method 2), 62
  random bits — is strictly monotonic (0 violations in 20,001 keys 200µs apart) and packs
  the same 154 leaf pages / 89.6% density that v1mc does, against 194–226 pages and ~49%
  fragmentation for `gen_random_uuid`. One `clock_timestamp()` call per key, not two: two
  reads let the ms field and the sub-ms field disagree across a boundary, which was
  measurably worse. At 1 ms resolution alone v7 is *worse than random* for a bulk insert
  (211 pages) — 40,000 rows land in ~100 ms buckets and scatter inside them; the sub-ms
  slot is what fixes that.
- **What 5.4 still owes.** A default change stops new scatter; it does not repair the
  bloat already in the ledgers. That is a `REINDEX CONCURRENTLY`, i.e. a maintenance-window
  decision, not a migration's.

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
