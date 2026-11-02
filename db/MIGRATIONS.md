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
| `0006_index_hygiene` | 5.5, 5.6 | drop 6 redundant indexes (3 identical pairs + 3 prefix pairs — the prefix form is the same defect, the review only counted identical column lists), give leading coverage to the 14 foreign key columns that had none, and index what the CRM actually queries: trigram GINs for the two `ILIKE '%…%'` paths (a btree cannot answer those at all), `entities.tax_id`/`contacts.phone` for equality, and an `addresses` composite that also removes `vw_customers`' per-row address sort. Creates `vw_index_redundancy` so the question has one definition instead of three. `inventory_movements.transaction_id` is **left alone** — unindexed today, not a foreign key, queried by nothing; 6.1 argues it into a dedup key, which is `0011`'s decision with its access method attached |
| `0007_domain_constraints` | 5.9 | 20 membership CHECKs, 6 columns pointed at two new master-data tables (`units_of_measure`, `costing_methods`), and `vw_domain_vocabulary`, which publishes what every domain column accepts and names the 4 left free on purpose with the reason. Which mechanism a column gets is a rule, not a preference — see the header of the migration |
| `0008_delete_safety` | 5.10 | flip 5 CASCADE edges to RESTRICT (on-hand and reservations to items/warehouses, `bot_actions` to sessions) plus `inventory_on_hand.location_id`'s SET NULL — measured: a parent delete really did destroy stock and the audit trail whenever nothing had ever MOVED, because the edges that looked safe were protected by accident of the movement FKs. Retains `locations -> warehouses` CASCADE as composition, proved by a probe that attempts it. Adds the close-out path the review prescribes: `decommission_warehouse()` / `retire_item()`, which refuse with the actual stock counts and close out by `is_active` |
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

| Count | Before 0003 | After 0004 | After 0005 | After 0006 | After 0007 | After 0008 | Why |
|---|---|---|---|---|---|---|---|
| FKs | 30 | 47 | 48 | 48 | 54 | 54 | `tenant_id` FKs, RESTRICT, on 17 tables; then `thread_root_id`, which 5.2 found had no constraint at all; then 6 to the master-data tables, which is why B17 had to be re-run against them |
| tenant-coded tables | 0 | 18 | 18 | 18 | 18 | 18 | the review's "0 rows returned" for 5.8 |
| FKs with no index anywhere | 12 | 11 | 11 | **0** | 0 | 0 | the corrected measure (see below): a column in no key position of any index. Unchanged by 0005 — `idx_comms_thread_root` already covers the new FK. 0006 indexes all of them |
| FK columns leading no index | — | 14 | 14 | **0** | 0 | 0006's invariant, now asserted. The judgment 0003 left to be confirmed resolved **against** the tenant-led composites: an FK existence check carries no tenant predicate, so `(tenant_id, col)` cannot serve it — measured, 47 buffers/0.193 ms as a seq scan versus 6 buffers/0.017 ms index-only. Both shapes are kept where both query shapes exist, which is not the duplicate case 5.6 is about |
| redundant index pairs (identical + prefix) | 8 | 3 | 3 | **0** | 0 | 4 pairs became single indexes when 0003 replaced the global natural key with a tenant-scoped unique; `0004` removed `idx_on_hand_available`/`idx_on_hand_low_stock`. The remaining 3 are pre-existing `idx_comm_*`/`idx_comms_*` pairs in `communications` (correction C1). 0006 found **3 more of the same defect that the review's measure could not see**: indexes whose column list is a strict leading prefix of another index on the same table (`audit_summary`, `locations`, `inventory_reservations`) — so the honest count of 5.6 is 6, not 3 |
| integer key columns | 19 | 19 | **0** | 0 | 0 | 5.1/5.3: four serial PKs and fifteen referencing columns, widened together |
| key columns narrower than their ceiling | 4 | 4 | **0** | 0 | 0 | bigint keys fed by an integer sequence — see B14 |
| domain columns with no published answer | 30 | 30 | 30 | 30 | **0** | 0 | 5.9's count, restated as a question the database can answer. 26 are constrained, 4 are free text with a recorded reason |
| tables | 18 | 19 | 19 | 19 | 21 | 21 | the two master-data tables, `units_of_measure` and `costing_methods` |
| CASCADE edges | 6 | 6 | 6 | 6 | 6 | **1** | 5.10's count. Five flipped to RESTRICT (four inventory, one audit); `locations -> warehouses` retained — bin rows with no stock, no open reservations and no ledger reference are structure, and deleting them with the warehouse is composition, not destruction. B3 checks both sides: no CASCADE on a table that holds facts, and no CASCADE anywhere else beyond that one named edge |

Also deferred from 0003, deliberately:

- **Views.** All 12 `vw_*` views use explicit column lists, so none picked up
  `tenant_id`. 0003 reports which ones and leaves them: a view owned by `postgres`
  bypasses RLS anyway, so the fix belongs with `security_invoker` in 0009, not here.
  0005 dropped and recreated eight of them (they blocked the retype) and proved the
  recreation was faithful column-for-column; the `tenant_id` gap is still 0009's.
- **Corrected by 0006.** This note claimed `idx_movements_date (performed_at)` was
  prefix-redundant with 0003's `idx_movements_tenant_date (tenant_id, performed_at)`. It is
  not: prefix-redundancy requires the *same leading columns*, and these two differ in the
  first one. `(performed_at)` is the only index that can serve a cross-tenant range over the
  ledger, so it stays. The claim was wrong because it was reasoned from the index names
  rather than read from `indkey` — which is what `vw_index_redundancy` now does instead.
- **Function EXECUTE is PUBLIC by default.** Thirteen business functions are callable by
  every role, including `afpc_auditor`, because 0001 created them before 0002's grants and
  PostgreSQL grants EXECUTE to PUBLIC at creation. The writes inside fail on table
  privileges, so nothing leaks today, but least-privilege says the audit account should not
  be able to *try*. `0009` owns the sweep: REVOKE from PUBLIC, GRANT to `afpc_app`, and
  `ALTER DEFAULT PRIVILEGES ... REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC` so new functions
  start closed. 0008 already did this for its own two functions and prints the remaining
  count.
- **Row-level isolation.** `tenant_id` exists and is enforced structurally, but nothing
  filters by it yet. `db/tests/5_8_tenancy.sql` block 8d demonstrates both the read and
  the write hole, and is the KNOWN-OPEN row that 0009 turns green.

## Found while building 0008

- **A delete graph can be protected entirely by accident, and the accident is load-bearing.**
  Every probe where a parent delete *destroyed* stock (item with stock and no movements,
  warehouse never in a ledger row) succeeded; every probe where history existed was already
  refused by `inventory_movements`' RESTRICT/NO ACTION edges — which 0008 does not touch, and
  which the review never mentions as protection. So before 0008 the schema was safe exactly for
  the rows anyone had audited and unsafe exactly for the rows nobody had moved yet: a
  freshly-received pallet is destroyable by deleting its warehouse, and an old one is not.
  "RESTRICT (or soft delete)" is the review prescribing intent where only accident existed.
- **The SET NULL on `inventory_on_hand.location_id` is the same finding in a quieter form**, and
  it was not in 5.10's six. Measured: deleting a stocked bin either silently re-homed the
  quantity to warehouse level, or — when a no-bin row for the same item/warehouse/lot already
  existed — aborted inside **0004's identity index** with a 23505. The second failure mode
  arrives as a duplicate-key error naming neither the bin nor the constraint; an operator
  reading it would debug 0004, not the delete they issued. Two outcomes, neither an answer.
  It flips to RESTRICT with the CASCADEs.
- **5.10 counts 6 CASCADEs; the honest list is 5 + 1, and the retained one needs a probe.**
  `locations -> warehouses` is a genuine part-whole relation — a bin *is* the warehouse,
  expressed as shelves — and its blast radius after the other five flip is exactly "bins that
  nothing has ever counted, reserved, or moved against". Retaining it is the judgment call,
  and B3's catalog reading could not distinguish "retained on purpose" from "the migration
  forgot", so the migration attempts the empty-bin cascade for real (probe D), and
  `db/tests/5_10_delete_safety.sql` block F keeps attempting it as a regression guard — with
  no harness row, because it passes pre-0008 too and a row that cannot reproduce would read
  CLOSED through a branch that was never at risk (0006's preference-assertion lesson again).
- **`RETURN` inside a plpgsql exception handler ends the whole block, not the handler.** The
  first draft of block D used it to skip the ERR line after a successful refusal; the ERR
  guard then never ran on *either* path. A boolean, set in the handler and read after
  `END`, is the form that works. (Also caught: the documented `cond EXCEPTION;` condition-name
  declaration — both in a DO block and in a real function — fails here with "type exception
  does not exist", so the rollback sentinel became an explicit SQLSTATE via
  `RAISE ... USING ERRCODE`, which is also a better sentinel because it cannot be confused
  with an unrelated `raise_exception`.)
- **A test fixture inside a schema that gained CHECKs and FKs in 0007 must speak the
  vocabulary.** The first draft of these probes inserted `bot_type='langchain'` (0007 added a
  membership check), `order_id=900001` (uuid), `movements` without `performed_by`, and
  sessions `user_id` as both integer and string (varchar in the baseline — the two spellings
  compare unequal: `'999777' = 999777` is a type error, not a coercion). None of those are
  findings; they are 0008 writing against the database that exists after 0007, which is the
  point of a sequence that replays.

## Found while building 0007

- **`get_followup_customers` branches on a value nothing writes.** The function's first condition
  is `rec.status = 'follow-up'` where `rec.status` is `entities.status`
  (`db/migrations/0001_baseline_canonical_port.sql:1288`), and `entities.status`'s only documented
  values are active / inactive / blacklisted (`docs/database/schema.md:43`). No SQL, function or
  tool in the repository writes `'follow-up'` to anything — yet
  `blueprint/tools/followup_customers.py:36` tells the agent that a customer is surfaced because
  "their status is marked as 'follow-up'". So the most prominent reason the tool advertises is
  unreachable by design, and 5.9 is the reason it was invisible: an undeclared vocabulary cannot
  be checked for a missing member. **Assigned to `0014`**, which owns the movement and follow-up
  contracts; `vw_domain_vocabulary` admits the value today so the gap is a *missing writer* rather
  than a schema that could never hold the state, and `db/tests/5_9_domain_values.sql` block 4
  proves the reader works given the value.
- **Two documentation files disagree about `movement_type`, in both case and membership.**
  `schema.md:352` says `'RECEIPT', 'ISSUE', 'TRANSFER', 'ADJUSTMENT', 'RESERVATION'`;
  `blueprint/docs/schema_reference.md:299` says `'receipt', 'shipment', 'transfer', 'adjustment'`.
  The code settles it: `execute_inventory_movement` branches on `('RECEIPT','RETURN')` and
  `('ISSUE','ADJUSTMENT')`, which is uppercase and includes a value neither document lists. The
  CHECK follows the code, because the code is what runs. Note what the constraint buys: TRANSFER
  and RESERVATION are now *named* members of the vocabulary that no branch handles, which is
  finding 4.6 stated as a set rather than as a suspicion — `0014` cannot accidentally leave it
  implicit any more.
- **A column's DEFAULT and its vocabulary are written in different parts of the same file, and
  nothing connects them.** `inventory_items.base_unit_of_measure` defaults to `'EACH'`; the first
  draft of the code table seeded `'EA'`. Had the check missed that, every insert relying on the
  default would have failed in production, not in review. 0007 now asserts it: no column may
  default to a value its own constraint rejects, CHECK-backed and lookup-backed alike.
- **`pg_get_constraintdef()` renders two different shapes for the same kind of constraint**, and a
  filter that spells one of them silently reports the other as "no constraint". Written with an
  explicit array cast it prints `= ANY ((ARRAY['a'::character varying, ...])::text[])` — what 0003's
  `tenants_status_check` looks like; written the way this migration's loop generates it, it prints
  `= ANY (ARRAY['a'::text, ...])`. `vw_domain_vocabulary` initially showed 1 of 20 CHECKed columns.
  A regex, not a `LIKE`, and `db/tests/5_9_domain_values.sql` block 2 is what proves the extraction
  works: it writes every value the view publishes and requires each to be accepted.
- **A test phrase must exist only on the failure side.** The harness matches with `grep -qF`, not
  with a parser, so mapping `carries a reason` reported REGRESSION on a database where the check
  passed — the phrase also appeared in `VERDICT OK every free-text domain column carries a reason`.
  Every 5.9 phrase is now a fragment the OK branch cannot contain.
- **Two membership CHECKs on one column is a contradiction, not a refinement.** Discovered by
  accident when a probe constraint survived next to `entities_status_allowed` and the view printed
  the column twice with different value sets, which also made 5.1's coverage count wrong by one.
  Asserted against, as `vw_domain_vocabulary` being one row per column (B18).
- **Why the mechanism differs per column, and why that is not inconsistency.** A CHECK where the
  repository can name the complete set (a documented list, or a value the code branches on) — an
  unlisted value is then a bug, and refusing it is the point. A lookup table where the set names
  something that grows (units, costing methods) — being wrong should cost an `INSERT`, not a
  migration. Nothing at all where the set belongs to whatever is installed: `bot_actions.action_type`
  names a *tool*, and constraining it would make every new agent a schema change. The fourth case
  is `entity_relationships.role`, which the schema's own examples ("Procurement Manager", "Owner")
  make a job title. All four appear in `vw_domain_vocabulary` with the reason, and B2 fails if any
  of them appears without one.
- **Nothing in the tree branches on `warehouse_type`, `location_type`, `product_type` or
  `order_type`, and no document lists their values** — only defaults (`PRIMARY`, `STORAGE`,
  `STOCKED`, none). These four CHECKs are the weakest evidence in the migration: the sets were
  composed from what the surrounding columns imply (a `parent_warehouse_id` means a second kind of
  warehouse exists; `aisle`/`rack`/`shelf`/`bin`/`zone` mean a location has a role). Each
  constraint comment says so, and the same note is in the migration header. A deployment that
  ships in cross-docks will hit `warehouses_warehouse_type_allowed` and learn, from the constraint
  name, that this was a guess rather than a specification. The alternative — leaving them open —
  was rejected because 5.9's thesis is that an undefined vocabulary hides bugs, and these are the
  columns a warehouse agent would write.

## Found while building 0006

- **An index that exists is not an index that is used.** 5.5 and 5.6 are both about behaviour,
  and every way of checking them from `pg_indexes` passes vacuously on an empty table. The
  first draft of 0006 verified itself with an `EXPLAIN` and reported "still a sequential scan"
  on a database with zero rows — which is the *correct* plan at zero rows. The split that works:
  the migration asserts the index is *usable* (forbid the other access paths, require the
  trigram to appear), and the harness asserts it is *preferred*, against 10,000 rows it inserts
  itself and rolls back. `ANALYZE` is legal inside a transaction and its statistics roll back
  with the rows, which is what makes the second form possible.
- **A btree cannot serve `ILIKE '%fragment%'` at all — not "slowly", not "at low selectivity".**
  Measured on 5,000 rows: seq scan either way, with a plain btree *and* with a
  `text_pattern_ops` btree. This is why `pg_trgm` has been installed since 0000 and finally got
  used. It is also why a btree on `lower(email)` would not have fixed the email check: `ILIKE`
  is not rewritten into a `lower()` comparison, so only a trigram index is an access path.
- **Prefix redundancy is the same finding as duplicate columns, and the review missed it.** An
  index whose key list is a strict leading prefix of another index answers no query the wider
  one cannot answer. Three such pairs were live. This changes the shape of the fix: the check is
  now "is one key list a prefix of another", not "are two key lists equal".
- **`x.indexrelid < y.indexrelid` as a pair-dedup tiebreak is a silent lie.** The first version
  of the prefix check carried one, to stop reporting each pair twice. It made the check find 3
  redundant pairs on the development database and **0** on a clone where the same indexes had
  been recreated in the other order. The condition was already asymmetric through "narrower and
  a prefix", so the tiebreak was not deduplicating anything — it was selecting which bugs to
  see. Twins *do* need a tiebreak, and it belongs on the equality branch only.
- **`indkey` is zero-subscripted, and `indkey::int[]` keeps them.** Third time this has bitten
  this repository (0004's introspection, 0005's coverage query, 0006's prefix slice). A slice
  `[1:n]` of it skips the first column, so an array built that way compares the wrong keys and
  can be *wrong in the direction of looking clean*. Rebuild through
  `unnest(...) WITH ORDINALITY` + `array_agg` when a slice is needed.
- **A check duplicated across a migration, a scoreboard and a test file drifts.** Fixing the
  tiebreak bug meant editing four copies, and one of them would not have needed editing had the
  bug not already been latent there. `vw_index_redundancy` is now the single definition, per
  ADR-003, and is readable by `afpc_auditor` through 0002's default privileges — so the auditor
  and the harness ask the same question of the same object.
- **An FK existence check carries no tenant predicate.** `DELETE FROM entities WHERE id = X`
  makes Postgres run `SELECT 1 FROM child WHERE entity_id = X`, across every tenant. 0003's
  tenant-led composites were correct for scans and useless for this, which is the mechanism
  behind 0003's "confirm this judgment" note. Answered, in favour of keeping both shapes.
- **A partial index is a legitimate FK index.** For a nullable FK, `(col) WHERE col IS NOT NULL`
  is taken by the FK check without being forced — an equality implies `IS NOT NULL` — and on a
  300,000-row table that is 99% NULL it measured 48 kB against 2,064 kB for the plain form, at
  the same 0.03 ms. So 0006 derives the shape from `attnotnull` instead of choosing a style:
  10 partial, 4 plain.
- **Dropping an index can break an `ON CONFLICT` that never names one** (0004's rule, applied
  preemptively here). Every drop in 0006 is announced, checked against function bodies by name,
  checked to be non-unique, and checked to be covered by a surviving index — and the migration
  aborts if any of those four fail. The coverage check is what caught the subscript bug above.
- **What 5.5 asked for that this does not do**: index `entities.status`, `entities.entity_type`,
  or `contacts.first_name`/`last_name`. Two are queried by nothing (and at 60/20/20 and 75/25
  would be a table scan with extra steps); the pair is already served by 0003's
  `(tenant_id, last_name, first_name)` as soon as a tenant predicate is present, which 0009
  guarantees — measured 0.046 ms indexed against 0.392 ms scanning. Adding them would create
  the near-duplicates this migration exists to remove.

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
