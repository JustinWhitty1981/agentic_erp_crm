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
| `0009_rls_enforcement` | 5.7 | ENABLE **and FORCE** row security on all 18 tenant-coded tables with one `tenant_isolation` policy per table (qual *and* `WITH CHECK`, so reads and writes are both filtered) plus a `USING (true)` SELECT policy for the two read roles; drops the 5 policies that keyed off the `app.current_agent` GUC nothing sets. `afpc_policy_tenant()` is a **STABLE** tenant resolver for the quals, because a VOLATILE one is re-evaluated per row and cannot become an index condition (measured 479 ms against 53 ms) — which is what makes 0006's promise about the tenant-led indexes true. Rewrites the 12 CRM views to expose `tenant_id` and sets `security_invoker` on every non-extension view, because a postgres-owned view skips the wall entirely. Also pays two debts: the 6 sequences 0002 could not grant retroactively (without them `afpc_app` cannot write a customer, so RLS was untestable on the CRM tables), and 0008's census of functions born with `EXECUTE` to PUBLIC. Publishes `vw_rls_status` |
| `0010_timestamp_triggers` | 6.3 | one trigger function, `afpc_touch_updated_at()`, installed as a `BEFORE INSERT OR UPDATE` row trigger on all 13 tables that have an `updated_at` column - scope read from `pg_attribute` rather than from the review's list, because 0003 had since added `tenants` and the finding had grown by following the plan. On UPDATE it stamps the column **unless the statement set it deliberately**, so an ordinary edit cannot forget to maintain it while a backfill carrying real historical timestamps survives - the property 0004's duplicate merge and 0005's key widening needed and did not have. Retires `update_updated_at_column` and `update_communications_updated_at`, asserted by md5 to be the same body twice. Adds `created_at` to `inventory_on_hand` and `inventory_reservations` - the review says all three ledger tables have "no timestamp-shaped column at all"; measured, each has one, and none of them records when the *row* began, which for stock matters because `last_movement_at` is overwritten by every movement. Adds `updated_at` to `addresses` and `inventory_on_hand`, found by asking `pg_proc` which tables its functions `UPDATE` rather than by reading the review, and makes the six nullable `updated_at` declarations uniform so a watermark predicate cannot skip rows by accident. Publishes `vw_timestamp_status` |
| `0011_idempotency` | 6.1 | ADR-005 pattern 2, because pattern 1 was measured unavailable rather than skipped: no unique index on email exists anywhere (and 0006 indexed `contacts.email` as a trigram GIN precisely because `add_customer` tests `email ILIKE`), so natural uniqueness cannot arbitrate the CRM's main write path. `idempotency_keys` with arbiter `(tenant_id, operation, idempotency_key)` — the tenant-led order is load-bearing, not hygiene: measured on a clone, a GLOBAL claim index under 0009's forced RLS returns `INSERT 0 0` and leaves the second tenant zero visible rows, a write lost with no error. `idempotency_claim` answers a retry with claimed/replay/conflict/in_progress; the request fingerprint (sha256 over canonical jsonb text) makes a settled key reused for a *different* request a conflict, never a cache hit. Two clocks, tied by CHECK, never conflated: a 5-minute lease (crash affordance — a dead claim is taken over with a rotated `claim_token` so the displaced attempt cannot certify work that ran twice) and lease+24h retention (`idempotency_sweep` enforces it; unclaimed work is never collected as history). `afpc_bump_version()` makes the two integer `version` columns 6.1 found decorative count writes — scoped by TYPE so the text-PK migration ledger is invisible to it, installed unconditional on purpose (the deliberate opposite of 0010's timestamp rule: a version a statement could pick is a version that can match what a reader already saw). Declines review 1.7's "index `transaction_id`" with measurements: it is a per-ROW `gen_random_uuid()` nonce no code assigns or reads; `batch_id` is the per-call key and is already indexed. Reuses 0010's touch trigger on the new table rather than writing a second one, and skips `idx_idempotency_keys_tenant` because the arbiter leads with `tenant_id` already. Publishes `vw_idempotency_status` — one row per state-changing function, pattern or UNGUARDED |
| `0012_vector_indexing` | 6.4 | ivfflat → hnsw on **all three** embedding columns — and the measured correction that 6.4's "1 of 3 searchable" was really 0 of 3: at 500 rows the planner refused even the indexed column (Seq Scan + Sort). No side table: the review's "~6KB/row into every scan" is false of the rows (`attstorage='e'`, out-of-line in toast, 61-byte main tuples) and true only of the one path that PROJECTS the column — so the fix is `vw_customers` dropping `e.embedding` (recreate, not replace: `CREATE OR REPLACE VIEW` cannot drop a column; dependents counted first, `security_invoker` and the three read grants re-applied and asserted). Probes assert usability with alternatives forbidden, top-10 exactness inside the ef budget, and the storage premise by fork-size delta (500 rows: 66 kB main, 4.1 MB toast); planner *preference* is declined as a cost-model detail, with measurements. halfvec deferred: the entire schema vector payload is NULLs, so there is nothing to make dense yet |
| `0013_audit_log` | 6.2 | `audit_log`: one trail row per row-change on **18** tenant-coded tables (census-derived, so the next tenancy migration enrols its table automatically), carrying the tenant, the polymorphic `{pk: value}` identity, the action, and **only the changed columns** for updates (vectors as a sentinel - their stringification costs 60x the rest of an audit row, measured). Append-only **by grant** (afpc_app loses the UPDATE/DELETE 0002's defaults handed it; B27 counts the ACL, the test proves the attempt) and tamper-evident **by chain**: sha256 over a canonical payload prefixed by the previous row's hash, segmented per **(tenant, month)** - per tenant because 0009's wall would hide another tenant's chain head from the chain-walk query (0011's lost-write bug in a new place), by month because 0019's retention answer is DETACH and a segment is a detachable unit of chain. `audit_chain_verify` recomputes through the same function the trigger used (one definition of the payload, B25's principle at a hash) and catches rewrite, deletion, and forgery as three distinct failures; probe E tampers for real, detects, and repairs. The rollup 6.2 found standing with **no writer anywhere in pg_proc** is wired: `audit_summary_refresh` is pattern 1 by the natural key (the register classes it without being told - probe H asserts), and the B24 trip 0010 predicted is paid the prescribed way: `updated_at` + 0010's own touch trigger, not an edit to an exemption list. The identity half of 5.8 is **decided here, deferred on purpose**: db_user (resolvable in pg_authid) + tenant_id (FK), no principals table nothing authenticates against - that's §3.1's twin problem wearing more tables; the registry lands with the code that uses it. `idempotency_keys` and `audit_log` itself are the two exemptions, with reasons the coverage view publishes; a tenant hard-delete is atomic-impossible by ordinary SQL (its history FKs to it and would re-reference the deleted row - 'archived' exists), and probe G's controlled erasure is the primitive 0019 formalises as detach |
| `0014_movement_contract` | 4.1, 4.2, 4.3 | `p_unit_of_measure`, ISSUE-branch warehouse columns, cost divisor, stop re-wrapping 23502, **and assert `ROW_COUNT` in the ISSUE branch** (the phantom-issue half of 4.2, which no constraint can express; the ON CONFLICT line moved to 0004) |
| `0015_reservation_locking` | 4.3, 4.2 | handler OUT tuple, `FOR UPDATE`, honour `location_id` — now including the **multi-bin double-decrement** below — no recursive movement insert |
| `0016_single_add_customer` | 4.4 | one `add_customer` overload instead of two ambiguous ones. The `integer` → `bigint` widening of its OUT columns was done in `0005` (a type fix, not a behaviour fix), so what remains here is the overload collapse — and note that named arguments do **not** disambiguate the current pair either: they share their parameter *names* as well as their first ten positions, so the only call that resolves today supplies 11 or more arguments (measured in 0009's block F, which had to route around this) |
| `0017_tool_call_log` | 4.5 | create `agent_tool_calls` and `tickets`, or delete the code that writes them |
| `0018_currencies` | 6.5 | `currencies` + rate history, money vs quantity precision |
| `0019_partitioning` | 6.6 | partition the append-only tables, BRIN on time columns |
| `0020_temporal_controls` | 6.6 | soft delete / bitemporal columns on contacts, addresses, communications |

## Consequences a later migration must pick up

`verify.sh` prints these counts every run, so the deltas are visible rather than
remembered.

| Count | Before 0003 | After 0004 | After 0005 | After 0006 | After 0007 | After 0008 | After 0009 | Why | After 0010 | After 0011 | After 0012 | After 0013 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| FKs | 30 | 47 | 48 | 48 | 54 | 54 | 54 | `tenant_id` FKs, RESTRICT, on 17 tables; then `thread_root_id`, which 5.2 found had no constraint at all; then 6 to the master-data tables, which is why B17 had to be re-run against them | 54 | 55 | 55 | 56 |
| tenant-coded tables | 0 | 18 | 18 | 18 | 18 | 18 | 18 | the review's "0 rows returned" for 5.8 | 18 | 19 | 19 | 20 |
| FKs with no index anywhere | 12 | 11 | 11 | **0** | 0 | 0 | 0 | the corrected measure (see below): a column in no key position of any index. Unchanged by 0005 — `idx_comms_thread_root` already covers the new FK. 0006 indexes all of them | 0 | 0 | 0 | 0 |
| FK columns leading no index | — | 14 | 14 | **0** | 0 | 0 | 0 | 0006's invariant, now asserted. The judgment 0003 left to be confirmed resolved **against** the tenant-led composites: an FK existence check carries no tenant predicate, so `(tenant_id, col)` cannot serve it — measured, 47 buffers/0.193 ms as a seq scan versus 6 buffers/0.017 ms index-only. Both shapes are kept where both query shapes exist, which is not the duplicate case 5.6 is about | 0 | 0 | 0 | 0 |
| redundant index pairs (identical + prefix) | 8 | 3 | 3 | **0** | 0 | 0 | 0 | 4 pairs became single indexes when 0003 replaced the global natural key with a tenant-scoped unique; `0004` removed `idx_on_hand_available`/`idx_on_hand_low_stock`. The remaining 3 are pre-existing `idx_comm_*`/`idx_comms_*` pairs in `communications` (correction C1). 0006 found **3 more of the same defect that the review's measure could not see**: indexes whose column list is a strict leading prefix of another index on the same table (`audit_summary`, `locations`, `inventory_reservations`) — so the honest count of 5.6 is 6, not 3 | 0 | 0 | 0 | 0 |
| integer key columns | 19 | 19 | **0** | 0 | 0 | 0 | 0 | 5.1/5.3: four serial PKs and fifteen referencing columns, widened together | 0 | 0 | 0 | 0 |
| key columns narrower than their ceiling | 4 | 4 | **0** | 0 | 0 | 0 | 0 | bigint keys fed by an integer sequence — see B14 | 0 | 0 | 0 | 0 |
| domain columns with no published answer | 30 | 30 | 30 | 30 | **0** | 0 | 0 | 5.9's count, restated as a question the database can answer. 26 are constrained, 4 are free text with a recorded reason | 0 | 0 | 0 | 0 |
| tables | 18 | 19 | 19 | 19 | 21 | 21 | 21 | the two master-data tables, `units_of_measure` and `costing_methods` | 21 | 22 | 22 | 23 |
| tables with row security forced | 2 | 2 | 2 | 2 | 2 | 2 | **18** | 5.7's `rls_forced = 0`. Scope is "has a `tenant_id` column", read from the catalog, so a new tenant-coded table joins automatically and B7 fails on it if it does not. The 4 tables without one are declared global in B19 | 18 | 19 | 19 | 20 |
| policies in `public` | 3 | 3 | 3 | 3 | 3 | 3 | **36** | 18 × `tenant_isolation` (FOR ALL, qual + WITH CHECK) + 18 × `audit_read_all` (FOR SELECT, `USING (true)`, the read roles' door). 5 dropped first: 3 keyed off `app.current_agent`, 2 of 0002's stopgaps | — | 38 | 38 | 40 |
| views | 14 | 14 | 14 | 14 | 14 | 14 | **15** | `vw_rls_status`. All 15 now carry `security_invoker=true` and every one over a tenant table exposes `tenant_id`, which is what closes 0003's deferral NOTICE | **16** | 17 | 17 | 18 |
| functions executable by every role | — | — | — | — | 13 | 13 | **0** | 0008's census, swept. Three stay open by declaration — `afpc_current_tenant`, `afpc_policy_tenant`, `afpc_uuid_v7` — because they are called from column defaults and policy quals during an ordinary SELECT | 0 | 0 | 0 | 0 |
| CASCADE edges | 6 | 6 | 6 | 6 | 6 | **1** | 1 | 5.10's count. Five flipped to RESTRICT (four inventory, one audit); `locations -> warehouses` retained — bin rows with no stock, no open reservations and no ledger reference are structure, and deleting them with the warehouse is composition, not destruction. B3 checks both sides: no CASCADE on a table that holds facts, and no CASCADE anywhere else beyond that one named edge | 1 | 1 | 1 | 1 |
| triggers in `public` | 3 | 3 | 3 | 3 | 3 | 3 | 3 | 13 `afpc_touch_updated_at` triggers plus `trg_on_hand_consistency`. The two bespoke timestamp triggers 0001 ported are retired, and 6.3C's duplicated function with them| **14** | 17 | 17 | 36 |
| tables whose `updated_at` is maintained | 2 | 2 | 2 | 2 | 2 | 2 | 2 | 6.3's own measure, which is a behaviour claim rather than a column census: two of eleven before 0010 (the review's two "yes" rows), thirteen of thirteen after| **13** | 14 | 14 | 15 |
| tables with no row-creation timestamp | 3 | 3 | 3 | 2 | 2 | 2 | 2 | 6.3's last paragraph named three; measured, `inventory_movements.performed_at` already served, so the real gap was two. `schema_migrations.applied_at` is build bookkeeping| 0 | 0 | 0 | 0 |
| base-table vector columns led by hnsw | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 6.4. 0001 gave one of three an ivfflat; measured at 0011, the planner did not use even THAT for an ANN ordering unforced (Seq Scan + Sort at 500 rows), so 0 of 3 were really searchable in a plan anyone would run. 0012 makes it 3 of 3 | 0 | 0 | **3** | 3 |

Also deferred from 0003, deliberately:

- **Views — closed by 0009.** All 12 `vw_*` views used explicit column lists, so none
  picked up `tenant_id`. 0003 reported which ones and left them, correctly: exposing the
  column was pointless while a `postgres`-owned view bypassed RLS anyway. 0009 did both
  halves at once, and the second half is what made the first one necessary - the read
  roles now see every tenant in one result set, so a view without `tenant_id` is not
  merely incomplete, it is unreadable, and an aggregate view that does not group by it
  adds two tenants' bots together under one name. (0005's faithful-recreation machinery
  is the precedent for the column-for-column proof; 0009 asserts the same property from
  the catalog by comparing against the pre-rewrite column lists.)
- **Corrected by 0006.** This note claimed `idx_movements_date (performed_at)` was
  prefix-redundant with 0003's `idx_movements_tenant_date (tenant_id, performed_at)`. It is
  not: prefix-redundancy requires the *same leading columns*, and these two differ in the
  first one. `(performed_at)` is the only index that can serve a cross-tenant range over the
  ledger, so it stays. The claim was wrong because it was reasoned from the index names
  rather than read from `indkey` — which is what `vw_index_redundancy` now does instead.
- **Function EXECUTE is PUBLIC by default — swept by 0009, and the "so new functions start
  closed" half of the plan turned out not to work.** Thirteen business functions were callable
  by every role, including `afpc_auditor`, because 0001 created them before 0002's grants and
  PostgreSQL grants EXECUTE to PUBLIC at creation. 0009 revokes them and re-grants to
  `afpc_app`, but `ALTER DEFAULT PRIVILEGES ... REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC` is a
  no-op for functions - see the findings below - so what keeps it closed is B22, not a record
  in `pg_default_acl`.
- **Row-level isolation — done by 0009, with one change of seat.** `tenant_id` was enforced
  structurally but nothing filtered by it. Block 8d of `db/tests/5_8_tenancy.sql` demonstrates
  both the read and the write hole and is green now; it also had to start running as
  `afpc_app`, because it was written in the owner's seat, where a superuser bypass makes any
  policy invisible - the reason 5.7 survived as a catalog reading for seven migrations.

### Obligations 0009 creates for the migrations after it

- **`security_invoker` has to be re-applied by anyone who recreates a view, and applied by
  anyone who creates one.** `CREATE OR REPLACE VIEW` discards the view's reloptions, so the flag
  does not survive a definition change - 0009 found this by having its own view probe fail. The
  prediction made here that `0010` "rewrites views for `updated_at`" turned out wrong in an
  instructive way: it did not touch one existing view, because all twelve use explicit column
  lists, so adding a column to a base table changes no view - the same property 0003 reported as
  the reason `tenant_id` had to be added by hand. What 0010 does instead is *create*
  `vw_timestamp_status`, and a new view needs the reloption too, which B21 counts without knowing
  or caring that the view is new. `0012` may rewrite view definitions for embeddings and must
  re-apply it. Setting the flag at the *end* of a migration that touches views is the pattern.
- **New functions do not start closed, and cannot be made to.** The default-privileges
  mechanism for that is a no-op for functions (measured; see the 0009 findings), so every
  migration from `0010` on that creates a function must revoke `EXECUTE` from `PUBLIC` and
  grant it to `afpc_app` for its own functions, the way 0008 did for its two. B22 is the
  backstop and will point at the function by name.
- **A new tenant-coded table needs a policy, and B7 will say so.** The scope is read from
  the catalog, so the table appears as an offender the moment it has a `tenant_id` column
  and no `tenant_isolation` policy. A new table *without* one is not caught by that rule;
  it is caught by B19, which requires it to be declared global by name.
- **Row security binds a role, so it is inert until the agents use the role.** Every
  current Python entrypoint connects as `POSTGRES_USER`, which defaults to `postgres`,
  and a superuser bypasses row security whatever the policies say. `0009` is what makes
  the Phase 5 `db.py` (connect as `afpc_app`, `SET app.tenant_id` per connection) an
  enforcement change rather than a cosmetic one - and until it lands, the honest statement
  of 5.7's status is "the schema is protected; the applications are not yet". The role
  `agent_first_erp_crm` in `blueprint/bot.py`'s default config cannot even log in
  (`NOLOGIN`), so the first agent written against this database will fail into the right
  answer.
- **Tenant provisioning is an owner operation.** Under 0009's policies an `afpc_app`
  connection cannot insert a row into `tenants`: the key default generates a uuid that
  cannot equal the caller's tenant, and the `WITH CHECK` requires that it does. Anything
  that creates a tenant - including `0013`'s audit work and the seed path - runs as the
  owner or as an admin role that does not exist yet.

### Obligations 0010 creates for the migrations after it

- **A migration that adds a write path to a table owes that table an `updated_at`, and B24 will
  name it.** Eight tables are declared "no updated_at by decision - nothing in the schema rewrites
  these rows" on the evidence of `pg_proc`, not on a hunch. `0013` is the one most likely to trip
  it: `audit_summary` is a rollup keyed `(date, user_id, bot_id)`, and the moment its recompute
  becomes an `ON CONFLICT DO UPDATE`, the register's own evidence contradicts its verdict and the
  check goes red. The fix is the column plus the trigger, not an edit to the exemption list.
- **`0011`'s version trigger lands next to this one.** `inventory_on_hand` and
  `inventory_reservations` will carry two `BEFORE ... FOR EACH ROW` triggers, and PostgreSQL fires
  them in name order: `afpc_touch_updated_at` before `trg_*`. Both assign to `NEW` and return it,
  so the order is not observable today. It becomes observable the moment 0011's bump reads
  `NEW.updated_at`, or an `AFTER`-row variant is added - so the version column must be computed
  from its own counter, never derived from the timestamp, and `0011` should say which order it
  assumed.
- **Repoint probe E when `0014` lands.** 0010's stock probe duplicates the two statements
  `execute_inventory_movement` runs, because the function itself cannot run while 4.1 is open. Once
  0014 fixes the signature, the assertion is stronger at the real call site, and the duplicated
  statements become drift waiting to happen.
- **A `created_at` backfill is a one-time truth, not a rule.** `inventory_on_hand.created_at` is
  filled from the earliest movement that could have made the row, which is a lower bound chosen
  because nothing better exists. A migration that reconstructs history more precisely should amend
  those rows deliberately - and can, because the touch trigger honours an explicit `updated_at` and
  never touches `created_at`.
- **`updated_at` is trustworthy for writes, not for *changes*.** The trigger stamps every UPDATE
  including one that rewrites identical values, which is correct - the row was written - but it
  means the column answers "when was this row last touched", not "when did this row's data last
  differ". Anything building a delta feed from it should say which question it is asking.

### Obligations 0011 creates for the migrations after it

- **The register's UNGUARDED rows are the finding's unpaid half, and the migrations that rewrite
  those functions are the ones that owe the call.** `add_customer`, `update_customer`,
  `decommission_warehouse` and `retire_item` are listed as unguarded because nothing in them takes
  a claim yet - after 0011 the mechanism exists and the tools point at prose instead of it. When
  `0015`/`0016` rewrite a function, its head is the place a claim belongs (`claimed` -> do the work
  -> `complete`), and the register row should flip by itself, because it is derived. If a rewrite
  lands and the row does not move, the view is reading something other than the call sites, which
  is probe J's failure mode.
- **`0013`'s rollup upsert will be read by two checks at once.** The moment `audit_summary`'s
  recompute is an `ON CONFLICT DO UPDATE`, the function earns an ADR-005 pattern-1 verdict in
  `vw_idempotency_status` *and* trips B24, which 0010 put there for exactly this event. One change,
  two consequences; make both deliberately rather than being surprised twice.
- **The lease default is a claim about operation duration, and it is per-call tunable on purpose.**
  Five minutes was chosen for single-row CRM writes; the movement path `0014` fixes is a
  multi-statement transaction, and if a tool ever wraps one in a claim, the answer is a `p_lease`
  argument at that call site, never a wider global default. A lease long enough for the slowest
  operation is a lease under which nothing crashed ever gets taken over.
- **`idempotency_sweep` runs for nobody unless someone schedules it.** 0011 states the retention
  policy and builds the collector; there is no cron object in this schema and inventing one inside
  a migration would be a second place for the policy to live. The deployment must run it (or the
  Phase 5 template's housekeeping), and until something does, `expires_at` is a promise with no
  keeper. ADR-005's own words: the design is not complete without the GC story.
- **Two assertions in this migration are counts about a moment in the sequence, not properties of
  the graph.** The version loop asserts it installed on exactly 2 tables - if `0015` ever gives
  `inventory_reservations` a `version` column to lock, that assert fires and the expectation must
  be amended in the same commit as the column. And 0009's `IF n <> 18` policy count survives
  replay only because 0009 runs *before* 0011 creates the nineteenth tenant-coded table; a
  migration that reorders the sequence breaks a replay assertion three files away.

### Obligations 0013 creates for the migrations after it

- **Every future probe that writes a business table now writes trail rows, and nothing may
  count audit_log absolutely.** Row counts of audit_log differ between a database that has
  replayed 0013 once and one that has replayed it after 0014-0017's self-cleanup deletes.
  Assert chain_ok and per-subject counts, never totals.
- **0019: the (tenant, month) segments ARE the detach units, by design.** audit_log is born
  unpartitioned with a BRIN on occurred_at; when it is partitioned, retention becomes
  DROP TABLE of a segment, which the chain already understands (verify reports only
  segments that exist - a gone segment is not a broken one). The session_replication_role
  erasure in probe G is the migration-time primitive for exactly that removal; it must never
  ship in application code.
- **A new exemption from the trail must be edited in TWO places, and probe A is the reason
  that is safe**: the attach loop's NOT IN list and vw_audit_coverage's exempted CASE. A
  one-sided edit makes the view disagree with the catalog about one table, and probe A's
  XOR check fails the migration on the spot. If a third exemption ever earns one, update
  the count assertion in the same commit.
- **Tenant hard-delete is structural-impossible by ordinary SQL** (history references the
  tenant; the delete would need to write history referencing the tenant being deleted).
  Anything that wants tenant removal - seed cleanup, a future tenants-merge tool - uses the
  segment-erasure pattern above or the status column, never a bare DELETE.

## Found while building 0013

- **The harness's sequence restore had been off by one for twelve migrations, and only a
  table that keeps committed rows could catch it.** `setval(seq, max, false)` hands out
  `max` again - this file's own plan states that fact for the 2^31 probe, and DO_RESTORE
  did not apply it - which was harmless while every test rolled its tables back to EMPTY.
  audit_log is the first table with migration-era rows that persist: the first audited
  write after a test run re-drew an existing audit_id and died on `audit_log_pkey`, inside
  the UNRELATED 4_1 probe. The mapped-row SURPRISE caught it - the scoreboard mechanism
  justifying itself once more.
- **A plpgsql function body is not parsed until it is entered.** `atttypid =
  'vector'::regclass` - regclass where regtype was meant - CREATEd cleanly and failed only
  at the first audited write in the first probe. A migration whose behaviour blocks run
  after the DDL is this same lesson one layer up, and rehearsals are what cash it.
- **`GENERATED ALWAYS AS IDENTITY` forbids the chain design.** The hash must cover the
  row's position, the position must be drawn under the segment lock for order to be
  lock-order, and an explicit insert of the drawn value is the only way to do that -
  ALWAYS rejects it. BY DEFAULT keeps the guarantee (a hand-made id out of order breaks
  prev_hash) and adds replay friendliness pg_dump needs.
- **plpgsql substitutes two name levels, not three.** `r.a.tenant_id` over a loop record
  whose field `a` is a composite became, at runtime, an SQL reference to FROM item `a` -
  an error, not a slow path; and `SELECT a INTO v_ref` against a composite variable puts
  the whole row into the target's FIRST field, type error included. Hoist fields into the
  loop's query, or expand with `a.*`. Same family as the register's ORDER-BY alias trap:
  the substitution layer and the SQL layer disagree about what a dotted name means.
- **A verify function that returns one row per segment makes "count(*) >= 3" a lie waiting
  to happen.** Probe D's first form counted audit rows by counting SEGMENTS (passed at 1);
  the honest measures are `sum(audited_rows)` and `bool_and(chain_ok)` - and `bool_and`
  over NO rows is NULL, which must fail closed (`IS TRUE`), because "saw nothing" is exactly
  what an invisible history would report as.
- **The trail FKs the tenant to itself through time.** Probe G's cleanup found that
  deleting a tenants row fires an audit INSERT referencing the tenant being deleted - so a
  tenant with history cannot be hard-deleted by ordinary SQL in any order. That is the
  design saying no on purpose ('archived' is the door), and the sanctioned exception is the
  segment-erasure primitive recorded above.

## Found while building 0012

- **The review's 6.4 understated its own finding.** "Only 1 of 3 embedding columns is
  searchable by ANN" - measured at 0011, the one that *was* indexed was not searchable in any
  plan the executor would run: an ANN ordering on `communications` at 500 rows came back as
  Seq Scan + Sort unforced, and the pre-fix form of the test file's buffer probe showed the
  same - a forced "index path" degrading to the tax path with a penalty (9149 vs 9069 blocks)
  rather than finding anything to scan. An ivfflat built on an empty table trains zero lists.
  The honest statement of the finding is 0 of 3, and it could only be found by executing the
  query - which is the review's own §1.2 thesis applied to the review's own conclusion.
- **`CREATE OR REPLACE VIEW` can add columns and cannot drop one.** The first rehearsal died
  on `cannot drop columns from view` at §2 - every earlier view rewrite in this sequence
  (0005's recreation machinery, 0009's restatement) preserved or added columns, so the
  capture-rewrite-prove pattern carried an unstated assumption. Dropping `e.embedding` needs
  DROP + CREATE, which restarts the object: the reloption must be set again (0009's rule, now
  with a second reason), the grants depend on 0002's default-privileges firing for whichever
  role runs the migration (asserted now, not assumed), and a dependent object would
  auto-cascade (counted in `pg_depend` and refused first).
- **The vector's storage class was checkable in one query and the review did not check it.**
  `attstorage = 'e'` on all three columns, measured main-tuple ~61 bytes, and the 6KB/row
  claim died with the side table that would have "fixed" it. The claim was only ever true of
  the *projecting* path, and the schema had exactly one (a listing view carrying the column
  since 0001). Lesson recorded where it bites: `pg_column_size` detoasts, so it agrees with
  the claim under any storage regime - fork-size deltas are the instrument.
- **Cost-model blindness makes planner preference unfalsifiable at dev scale.** The two ANN
  plans' estimates cross twice between 500 and 5000 rows (the sort path never gets charged
  for detoast; the hnsw path gets charged for index size it does not read), while executed
  buffers differ 35x. A probe written against preference would fail or pass depending on
  statistics, not schema - so both this migration's probe B and the test file's block (a)
  assert usability with the alternatives forbidden, and block (b) asserts the executed
  buffer savings. This is 0006's usability/preference lesson with the polarity reversed:
  there the planner preferred a full btree scan for a predicate; here it refuses an index
  whose whole purpose the cost model cannot price.
- **B12 was in the always-fail family of the B11 bug.** The shipped predicate asked the
  *indexed table* to have a name like `%embedding%` - a question no relation in this schema
  can answer - so 6.4 would have scored FAIL forever, surfacing at the first application
  rather than hiding. The rewrite (per-column, correlated, `relkind='r'` so views cannot join
  the census, plus an ivfflat-survives term) is the same predicate as the migration's probe E,
  and both now agree on zero.
- **`Buffers:` lines are indented and ordered root-first.** The test file's first run captured
  nothing (a prefix-match `LIKE 'Buffers:%'` - harness SURPRISE, not a false pass, because the
  defensive branch was mapped to no phrase), and the fix revealed the root line carries the
  whole-tree total while the InitPlan's own line is last. Match `%Buffers:%`, take the first.

## Found while building 0011

- **A global dedup arbiter loses writes silently, and "silently" was the finding.** On a clone:
  tenant A claimed key K, tenant B claimed K with `ON CONFLICT DO NOTHING` under 0009's forced row
  security - `INSERT 0 0`, and zero rows visible to B for a request it was told it had made. No
  error, no trace, a customer in one tenant able to wedge a key in every other. So the arbiter is
  `(tenant_id, operation, idempotency_key)`, which is 0003's conclusion for every unique key in
  this schema, re-derived here by losing a write on purpose. ADR-005's pattern 2 done wrong is
  worse than ADR-005 unimplemented, because it fails exactly when two tenants are unlucky
  together.
- **The ADR's preferred pattern was eliminated by measurement, not taste.** Pattern 1 (natural
  uniqueness + upsert) names `add_customer` by email as its example; the census of unique indexes
  returns *email unique anywhere: NONE*, and the reason is on record three migrations back: 0006
  indexed `contacts.email` as a trigram GIN precisely because `add_customer` tests `email ILIKE`,
  which a `lower(email)` btree cannot serve. The read that settled the design was 0006's own
  comment, found while looking for why pattern 1's prerequisite had been skipped - it hadn't been,
  it had been considered, and the answer was in the ledger.
- **Review 1.7's "index `transaction_id`" is the same category of error, diagnosed correctly and
  prescribed backwards.** Measured: `inventory_movements.transaction_id` is `DEFAULT
  gen_random_uuid()` - a per-ROW nonce, assigned by no code and read by none (the repo-wide grep
  returns two migration notes and a schema dump), while `batch_id` - one value per
  `execute_inventory_movement` call, written to every row that call creates, already indexed by
  0006 - is the real per-call handle. An identifier minted by the inserted row can only ever agree
  with itself; a dedup key must be *supplied*. The deliverable here is the comment saying so,
  published in `vw_idempotency_status` rather than folklore, and the column left in place because
  a populated copy may write it (0008's rule about not calling destruction cleanup).
- **B10 was born vacuous, sibling to B11's class.** Its original form accepted any trigger whose
  *name* contained "version" - which a trigger that merely reads the column satisfies - so it
  would have reported 6.1 CLOSED while every retry kept duplicating. The rewrite asks the trigger
  function's body for `NEW.version :=` and asks the arbiter for `tenant_id` in first position,
  because both of those properties are the mechanism; the objects' names are not.
- **A derived register fails toward empty, which is worse than wrong.** The first drafts of
  `vw_idempotency_status` matched `insert into (public\\.)?tablename` - and `pg_get_functiondef`
  always qualifies with `public.`, so under standard-conforming strings a doubled backslash there
  is a literal-backslash pattern that matches nothing. The view would have returned zero rows,
  which reads as "no state-changing functions exist", not as a broken regex. Same family as 0007's
  two-renderings lesson; the guard is probe J, which compares the register's rows against
  `pg_proc` rather than trusting it.
- **A mapped test phrase that only a post-fix branch can print reports SURPRISE, not KNOWN-OPEN.**
  Block C's stale-token sentence is unreachable until the token exists, so on the pre-0011 database
  the harness said "stopped reproducing with no migration to explain why" - an accusation against a
  finding the migration fixes. Both of block C's phrases now print from its existence guard. The
  general rule: the guard branch must be able to tell every story the block registers. (Its
  sibling, found the same afternoon: a trailing comma after a quoted CASES row is *inside* bash's
  word, so `fixed_by` gained a comma, `closed()` matched nothing, and a green 6.3 row turned red.)

## Found while building 0010

- **A check can be wrong in the direction that hides the finding.** B11 has tested
  `(tgtype & 2) = 2 AND (tgtype & 4) = 4` since it was written, with the comments "-- INSERT" and
  "-- UPDATE". Both comments are wrong: the bits, established by creating probe triggers on a
  scratch table, are ROW=1, BEFORE=2, INSERT=4, DELETE=8, UPDATE=16 - so 2 is the *timing*, not a
  command, and the predicate was demanding a BEFORE INSERT trigger and never looking at UPDATE at
  all. Measured on the live schema it flagged the two tables whose column *was* maintained and
  passed silently over the nine where it was not. It was also counting `information_schema.columns`,
  which includes view columns, so it reported 13 where the truth is 11 tables and 2 views - the
  same 0009 lesson about a census answering a different question than its label, in a check that
  had been green for seven migrations. The corrected predicate reports 9 offenders before 0010 and
  0 after.
- **`now()` is the transaction timestamp, and that quietly invalidates the obvious test.** The
  first draft of 0010's probes did what a timestamp test suggests: read the column, write the row,
  read it again, compare. Inside one transaction every one of those instants is identical, so the
  assertion `new > old` fails against a *working* trigger - and, worse, `new = old` would "pass"
  against a broken one if the comparison were written the other way. Every probe now pins the
  column to a past value first and asks whether the write moved it off the pin, which is a claim
  true at any transaction boundary. The same property is what makes the trigger's
  "unless the statement set it deliberately" rule worth having: `now()` shared across a batch is a
  feature for a change-data-capture reader, and an affordance a backfill needs to be able to
  override.
- **The review's count grew by following the plan.** It lists eight tables carrying an
  `updated_at` that nothing maintains. The population here is eleven before 0010 starts, because
  0003 created `tenants` with the column and no trigger, and thirteen when 0010 adds two more. A
  finding written against a dump ages the moment the schema stops being the dump, so section 4
  derives its scope from `pg_attribute` and B11 asks the same question back. The review's other
  number is wrong the other way: it says the schema's three triggers "all fire on `UPDATE` only"
  and labels `trg_on_hand_consistency` as `UD`. Measured, that trigger is `tgtype 23` - BEFORE
  INSERT OR UPDATE. The correction matters only for accuracy, but the accuracy is what the next
  person reasons from.
- **Three tables "have no timestamp-shaped column at all" is a misreading, and the right reading is
  worse.** `inventory_movements` has `performed_at`, `inventory_reservations` has `reserved_at`,
  `inventory_on_hand` has `last_movement_at` - all NOT NULL, all defaulted. None of the three
  records when the *row* began. For the ledger tables that is harmless; for stock it is the actual
  defect, because `last_movement_at` is overwritten by the movement that changes the quantity, so a
  row created two years ago and touched five minutes ago is indistinguishable from one created five
  minutes ago. That is why 0010 adds a column to two of the three and refuses to add one to
  `inventory_movements`, where the event time and the write time are the same fact and a second
  column would be a second truth.
- **Which tables need an `updated_at` is a question the database can answer.** The review decides
  it from the presence of a column. Asking `pg_proc` which tables its own function bodies
  `UPDATE` finds `addresses` - a table the review lists as "created_at yes, updated_at no" with no
  remark, because from a dump an absent column is not a story, while `update_customer` rewrites
  those rows on every shipping-address change and leaves nothing behind anywhere in the schema.
  That is the same defect as a stale column, one step worse: there is no column to be stale. It is
  also the reason the register publishes `rewritten_by` as a derived column rather than a comment,
  and why B24 counts the disagreement between the two - a migration that adds a write path to a
  table declared immutable turns the register red by name.
- **A trigger function's EXECUTE is not privilege-checked against the invoker.** Measured on a
  clone: `afpc_app` updated three rows through a `BEFORE UPDATE` trigger whose function had been
  revoked from both `PUBLIC` and `afpc_app`, and the same `UPDATE` succeeded identically after
  re-granting it. This is the opposite of 0009's policy quals, where a missing grant produced
  `permission denied for function` in the middle of a plain `SELECT`, and it was worth measuring
  precisely because the instinct after 0009 is to reach for the grant - which would have added an
  inert privilege and a misleading precedent that a trigger body is a callable surface. 0010's
  function is revoked from `PUBLIC` and granted to nobody.
- **A test must not depend on a finding that is still open.** Probe E wants to exercise the stock
  write path, and the real write path is `execute_inventory_movement` - which cannot run at all
  until 0014 closes 4.1, because its signature never mentions a unit of measure while
  `inventory_movements.unit_of_measure` is NOT NULL with no default. Calling it made 0010 fail with
  someone else's finding. The probe writes the function's own two statements instead - the plain
  UPDATE of the adjustment branch and the `ON CONFLICT DO UPDATE` of the receipt branch, the second
  of which is a genuinely different executor path - and says in its comment that it should be
  repointed at the call site when 0014 lands.
- **Adding a column to a base table changes no view, which is the opposite of what the 0009
  obligations note predicted.** Twelve views were written with explicit column lists, so
  `inventory_on_hand.created_at` and `addresses.updated_at` appear in none of them and 0010
  restated no definition. The obligation still bit, just at the other end: 0010 *creates* a view,
  and a new view has empty `reloptions` and runs as its owner unless told otherwise, so
  `security_invoker` is applied after the definition and B21 counts it with the fifteen others.

## Found while building 0009

- **A policy's predicate is a plan, not a sentence.** 5.7 reads as a question about
  `pg_class` and `pg_policies`, and the obvious fix is a `USING (tenant_id =
  afpc_current_tenant())` clause reusing the helper 0003 already wrote. Measured on 600k rows
  in two tenants, that clause costs **479 ms** and does a sequential scan; the same clause
  against a `STABLE` resolver costs **53 ms** and does an index-only scan. The reason is the
  volatility marker: a VOLATILE function in a qual is re-evaluated for every row scanned and
  *cannot* become an index condition. So 0006's closing promise - the `(tenant_id, last_name,
  first_name)` pair becomes reachable "as soon as a tenant predicate is present, which 0009
  guarantees" - was a promise about a function's declaration, made four migrations early.
  `afpc_policy_tenant()` is that resolver, delegating to `afpc_current_tenant()` so the
  fallback chain has one implementation while the *planner contract* differs: VOLATILE is right
  for a column default (0003's reason) and wrong for a qual. B20 asserts the qual verbatim
  rather than listing things to avoid, so a third wrong way cannot hide in an exemption list.
- **A postgres-owned view is a doorway in the wall, and the fix has an order.** With RLS
  enabled, forced, and the isolation policy installed, `SELECT count(*) FROM warehouses`
  returned 1 row as `afpc_app` and `SELECT count(*) FROM <view over warehouses>` returned 2.
  Setting `security_invoker` fixes it - but `CREATE OR REPLACE VIEW` *discards the view's
  reloptions*, so the first draft of this migration, which set the flag and then rewrote the
  twelve definitions, quietly un-set it again; the rehearsal's view probe returned both
  tenants' rows. Every migration that recreates a view now inherits that obligation, and B21
  checks it from the catalog. (The version default is not a safety net: measured here, a view
  created by a superuser keeps owner semantics with empty `reloptions`.)
- **Two policies are one policy too few, and the reason is that `afpc_current_tenant()`
  raises.** A single tenant-scoped policy would make the view-only audit account unable to
  read the database it exists to read, because the resolver fails loudly when neither tenant
  GUC is set - the choice 0003 documented. So the read roles get their own `USING (true)`
  SELECT policy. That permissive policies are OR'd, and that constant folding then removes the
  raising branch from the plan entirely, is a property of the *plan*, not of the intent, so
  the audit probe empties both GUCs and reads cross-tenant rows to prove it. Related and
  deliberately unresolved: a raising predicate in a qual answers differently on an empty table
  (0 rows, no error) than on a populated one (error), because a scan that never reaches a row
  never calls the function. Both outcomes are safe; neither is a lie. It is kept because the
  alternative - filtering quietly to nothing - is how a misconfigured deployment hides.
- **`ALTER DEFAULT PRIVILEGES` cannot revoke what a default-privileges record never
  granted.** 0008 recorded this migration's duty as "the `ALTER DEFAULT PRIVILEGES` that stops
  it recurring". For tables that sentence works, because a stored record *replaces* the
  object's initial ACL. For functions it does not: the initial ACL for a function already contains
  `EXECUTE` to PUBLIC, and a default-privileges record only adds to it, so the revoke record is
  stored, reports success, and changes nothing - measured by creating a function after
  installing it and finding it executable by `afpc_auditor` still. There is no way to make
  future functions start closed from here. B22 is therefore not a belt-and-braces duplicate of
  the sweep: it is the only mechanism that works, and it fails loudly where the ALTER would
  have succeeded silently.
- **The sequence gap was why 5.7 had survived seven migrations.** `SET ROLE afpc_app; INSERT
  INTO entities` fails with `permission denied for sequence entities_id_seq` - six of the
  baseline's serial keys predate 0002's records and `ALTER DEFAULT PRIVILEGES` is not
  retroactive. The consequence is not that agents could not write customers (they connect as
  postgres today, so they could write anything). The consequence is that *no behavioural test
  of row security on the CRM tables could run*, which is how a decorative control stays
  decorative. Fixing the grant is one statement; finding it required trying to be the role.
- **`SET LOCAL ROLE` inside a plpgsql subtransaction does not revert when the block ends.** It
  reverts when the block *aborts*. A probe that succeeds therefore runs the rest of the
  migration as the role it was testing, which is how 0008's note about `RETURN` in a handler
  returns in a new costume: every probe here resets the role explicitly, on both paths.
- **The control binds a role, not a schema, so the harness had to change seats to see it at
  all.** `FORCE` answers 5.7.1 for a table *owner*; a superuser bypasses row security
  regardless, and the harness connects as postgres. Every migration up to this one could
  verify 5.7 by reading three catalog columns, and no test could have told the difference
  between a policy and a wall. That is why B7's predicate includes `polwithcheck` (a policy
  that filters reads but not writes is indistinguishable from a complete one in `pg_class`),
  why `5_8_tenancy`'s block 8d now observes through `SET LOCAL ROLE`, and why the proof this
  migration is real came from outside: as `afpc_app`, over TLS, from a foreign network
  namespace, tenant A's warehouse code was visible as A (1 row), invisible as B (0 rows), and
  a write carrying A's id while in B's context was refused by the policy.

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

- **Two more places where a reasonable query about the catalog asks the wrong question.**
  The view -> table dependency edges are recorded against the *rewrite rule's* oid, so
  `pg_depend WHERE objid = 'vw_customers'::regclass` returns two rows about the view and none
  about what it reads; the first draft of 0009's classifier used that and concluded that no view
  covered a tenant table, which would have exempted all fourteen from the rewrite. And
  `information_schema.columns WHERE column_name='tenant_id'` counts *columns*, so the census
  line labelled "tenant-coded" jumped from 18 to 30 the moment the views exposed the column - a
  number that answers a different question than its label asks is how a scoreboard loses its
  readers, so the census now filters on `relkind='r'`.
- **Overloads defeat a test before they defeat a policy.** `add_customer`'s two overloads share
  their first ten parameter *positions and names*, so a call with fewer is ambiguous (42725) -
  including with named arguments, which is the mitigation the 4.4 note suggested. Block F needed
  eleven typed arguments to reach the write path it is meant to exercise, and plpgsql hands a
  variable to the parser as `unknown`, so it needed `::text` on those too. Nothing about that
  is tenancy; it is the cost of writing a behaviour test in a schema with an open 4.x finding,
  and 0016 is where the workaround goes away.

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
