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
| `0014_movement_contract` | 4.1, 4.2, 4.3 | `execute_inventory_movement` rewritten: 10→12 parameters (`p_unit_of_measure` DEFAULT NULL resolving through the ITEM MASTER, `p_idempotency_key` DEFAULT NULL wired to 0011's claim - both additions defaulted so every existing call resolves, and the old 10-parameter head DROPPED first because CREATE OR REPLACE with a changed signature creates a SECOND overload, which is how the 4.4 failure mode briefly reappeared inside 0014's own rehearsal). `to_warehouse_id`'s NOT NULL - 4.1's SECOND wall, invisible in the review's reading - becomes a per-type warehouse-shape CHECK over all six vocabulary members; TRANSFER (accepted-and-silent since 0007) now moves both sides atomically; RESERVATION refuses with a pointer to its owner; ISSUE/ADJUSTMENT assert ROW_COUNT (4.6's phantom, with the refused movement's ledger row proving atomicity at the call site - 0010's repoint obligation discharged in `4_6`'s rewrite). The catch-all re-wrap is gone: original SQLSTATEs propagate verbatim. The catch-all's replacement handler exists only to fail a claim so a retry can run. 4.3's divisor claim corrected by measurement: (oh+qty)=0 needs a negative RECEIPT, and a negative RECEIPT cannot reach DO UPDATE - the tentative INSERT row fails the non-negative CHECK first - so the CASE stays as a tripwire and the honest decrease door is ADJUSTMENT. `mark_customer_followup` is the writer 0007 proved absent for `entities.status='follow-up'`: convergent, claim-free, refuses to trample blacklisted. The register's lie about this function (pattern 1 for an ACCUMULATING upsert, standing since 0004 because the ladder reads `ON CONFLICT` and not semantics) is corrected by the claim being real, not by editing the ladder. 4_1's own fixture carried a second, invisible violation ('purchase_order' is not reference_type; the 23502 fired before the CHECK could) - fixed in the same commit, pre-fix output unchanged by measurement |
| `0015_reservation_locking` | 4.3, 4.2, 4.6 (multi-bin half) | **One pick policy instead of two copies.** `afpc_pick_bins` locks the candidate on-hand rows `FOR UPDATE` in drain order (FEFO, then bin, then row id) and returns the PLAN — it writes nothing — so both doors that take stock out decide before they touch and a refusal leaves no trace (4.6's demand, reached from the reservation side). `reserve_inventory_for_order` 6→8 parameters (`p_location_id`, `p_idempotency_key`); `execute_inventory_movement` 12→14 (`p_from_location_id`, `p_to_location_id` — the two ledger columns that have existed since 0001 and had no writer); both old heads DROPPED by full signature. 4.3's crash cause is corrected by measurement: not `SQLERRM` in the text column (that pairing works), the SECOND OUT element — a bare string literal in `RETURN QUERY` is `unknown` and will not coerce into a `varchar` OUT column, so every return path died and the handler was merely the one the review's repro reached. Two walls behind it, invisible until the return worked: the guard's `SELECT ... INTO` reads ONE bin and calls it the warehouse (measured false refusal — "Only 0 available" while 10 units sit in the other bin), and for an item with no rows it compares `NULL < n`, UNKNOWN not false, so with only the cast fixed the door returned SUCCESS having written a commitment against zero on-hand rows. The review's "drop the recursive movement insert" is declined: the RESERVATION ledger row stays — 0014's refusal pointer and 0007's note that RESERVATION is a live vocabulary member both depend on it — and gets what it lacked (unit from the item master, the warehouse columns the shape CHECK demands, and a `reference_type` MAPPED from the order type, because the two published lists share only TRANSFER; probe I derives the mapping's totality from the register rather than restating it). What the kept row distorted, `vw_item_movement_summary` counting a positive-quantity commitment as inbound, is fixed directionally in the migration's own §4 by capture-transform-prove. 4.3's `status='ERROR'` remedy is declined for the same reason 0014 deleted the re-wrap: statuses are the two business outcomes, errors propagate with their own SQLSTATE, and the handler exists to release the claim. Wrong arguments (nonexistent item or warehouse, non-positive quantity, an order type outside the vocabulary) refuse as 22023 BEFORE the pick — a shortage answer to a wrong argument is 4.3's conflation with the numbers rearranged — with the FK and CHECK still the floor for raw writes, both halves probed. One boundary named instead of buried: the pick draws on `quantity_available`, so committed stock is not issuable through the generic door and no fulfilment step exists yet; probe L asserts the wall so the migration that takes it down does so deliberately. `4_3` rewritten version-aware, `4_6`'s second phrase flipped to an observable at the door |
| `0016_single_add_customer` | 4.4, 6.1 (CRM half) | **One head instead of two.** Both were ported by `0001` because §3.3's forked directories each defined the function; the 14-parameter one is a superset (same first ten positions *and the same names*), so it survives, both heads are DROPped by full signature, and one is CREATEd with 15 parameters — 14 DEFAULTed plus `p_idempotency_key`. Corrected by measurement: "every parameter is defaultable" is not why it is ambiguous (in the 10-parameter head the first four are not defaultable) — ambiguity is about how many positions each **candidate accepts**, and both accept 4 and both accept 10, so only 11–14 resolved (0009's block F and 5_1's probe each worked around it and 5_1 reported the workaround as INFO rather than a pass). Post-collapse all four arities the tree actually issues resolve, and `5_1`'s 2^31 probe **runs** for the first time, proving 0005's OUT widening behaviourally instead of structurally. The register printed add_customer TWICE, both UNGUARDED — one row per function object, which is 4.4 visible from a different view; now one row, pattern 2, derived. **A claim at the head is what ADR-005 was for here**: 0011 chose pattern 2 because no unique index on email exists (contacts.email carries a trigram GIN for the ILIKE), so both duplicate checks are reads. Measured with two backends one second apart: keyless → 2 entities and 2 contacts for one request; keyed → 1 customer and both callers answered with the same entity_id, the second having waited on the arbiter's unique index and then replayed — the claim guarding a race, not only a retry. Successes complete the claim, every refusal releases it (the obstacle is deletable, and a cached no hides the attempt that would have worked). `p_entity_type`'s domain (`individual`/`business`) is named in the body because it lives in no column — `entities.entity_type` is a different axis — and any other value used to fall through to the individual branch and report success; now 22023, matching 0015's rule that a wrong argument is an error rather than a status. The `WHEN OTHERS → success=false, 'Error adding customer: ' \|\| SQLERRM` handler is gone (third instance of the shape 0014/0015 deleted): a violation of `entities.status` arrives as 23514 and the tool's Python branch no longer has to read prose to tell a constraint from a business answer. Two things deliberately NOT changed: the `entity_relationships.role` logic (a business naming a human gets role `'Customer'`, the surprising behaviour the surviving head had — pinned by probe F, not laundered) and the email/phone asymmetry (email matched `ILIKE`, phone by `=`; measured both directions, handed to Obligations-0016 because normalising a phone is a decision about who the database believes is the same human). A misused key answers `P0001` like 0015's doors, deliberately not `23505`: no unique index was violated and the caller must not learn that email is constrained when 0011 measured that it is not |
| `0017_interaction_readpath` | 4.5 | **No tables, four views, one renamed migration.** 4.5's sentence ends "referenced but created nowhere: `agent_tool_calls` … and `tickets`"; measured, neither half is a missing table. `agent_tool_calls` is touched by exactly one file, `archive/blueprint/tools/tool_logger.py`, which **nothing imports** - and whose first act is a runtime `CREATE TABLE IF NOT EXISTS` plus three indexes in a schema the connection cannot create in: not a missing table but a second implementation of ADR-001's rule that never ran, because `interaction_logger.py` already writes the canonical `agent_interactions`. `tickets` is touched by no code; its only reference in the repository is a `LEFT JOIN` at `archive/blueprint/08_create_views.sql:218`, in a file `db/README.md` lists as superseded, and `vw_agent_activity_summary` was ported without that join (probe G keeps both decisions from rotting into folklore by failing the day anything in `public` names either). What is actually missing is the other half of the same file: `AGENTS.md` and `docs/INTERACTION_LOGGING.md` both advertise `vw_recent_interactions`, `vw_failed_interactions` and `vw_tool_performance` as how anyone reads agent behaviour back, and `0001` ported `11_interaction_logging.sql`'s TABLE and not its VIEWS - measured 0 of 3 exist, so this repository's own debugging instructions have raised 42P01 since the first migration that made them runnable. Hence the rename: the migration is named for the read path, not the table the review guessed. The legacy definitions were not worth copying, and four numbers say so: one errored run that used three tools printed `error_count = 3` where the truth is 1 errored run; averaging a run's duration once per call turned 900 ms beside 100 ms into **700 ms** where the mean of the two runs that used the tool is 500; `ORDER BY … LIMIT 100` inside the view truncated BEFORE the caller's filter, so asking for bot Z's recent runs returned **0 rows** while the table held 5; and one row whose `actions_taken` holds a JSON object took the whole report down for every tenant with 22023. So `vw_tool_calls` derives the per-call grain positionally (`jsonb_array_elements … WITH ORDINALITY`, step *n* of `actions_taken` with step *n* of `tool_observations`, because `interaction_logger.py` appends one of each per loop iteration - an agreement between two columns, so `observations_aligned` states whether it held), `vw_tool_performance` counts at the call grain and times and errors at the run grain, the two listings drop the hidden `LIMIT` (order moves to the docs, where the caller can write it), and a non-array `actions_taken` contributes nothing instead of failing. `vw_recent_interactions` also exposes `step_count` so a scan need not expand the payload, and `vw_failed_interactions` deliberately projects `actions_taken` while the listing view deliberately does not. One boundary is stated rather than glossed: **per-call errors are not derivable** - the base table has one `error_message` per run and `tool_observations[].type` is a Python class name that reads `str` for a result and for an error alike - so `run_errored` is a run-level fact wearing a per-call row, probe H demonstrates that, and probe H also fails if the view ever grows a column implying more. Grants to both read roles, then `security_invoker` AFTER the creates (0009's ordering). Harness: `4_5`'s 5c is rewritten with verdicts that match the decision rather than the table names, two new CASES phrases, and `code:tool_prefix` scoped to `*.py` because all of `archive/blueprint/` holds 267 qualified references and only 33 of them are a live code path (the marker table further down now says which markers are watched and which are only written down) |
| `0018_currencies` | 6.5 | **The currency a cost is in, said once.** 6.5's three sentences are all true and all understated. Measured through the doors: `total_cost` is written as `p_quantity * p_unit_cost` into `numeric(15,4)` while both factors are `numeric(12,4)` — ceiling just under 1e8 each, so the product can need 1e16 and the column stops at 1e11; a receipt of 1,000,000 at 1,000,000 dies with **22003 numeric field overflow**, a crash on arithmetic the schema asked for (1e5 × 1e5 = 1e10 fits, which is where the wall actually is). The averaging statement in the same body has no currency term — `grep -c currency` over the installed source is **0** — so a balance of 100 at 10 labelled EUR plus a receipt of 100 at 10 gives `average_cost 10.0000` **labelled EUR**, a dollar cost folded into a euro balance with nothing saying it happened. And `inventory_on_hand.cost_currency` has *no writer at all*: no function body names it, so a new balance for an item whose own `currency_code` is JPY is created as **USD** (measured), which is the same lie written twice. `currencies` is master data in `units_of_measure`'s shape — global, natural code PK, `is_active` rather than deletion, RESTRICT edges, one leading index each per 0006 — with the ISO-4217 shape CHECKed **on the master once**, because a rule stated on both sides of a relationship is two rules and the referencing side's mechanism is the FK. Membership replaces width as the wall: 'XYZ' and 'xt' were accepted before and answer 23503 now, and the only 22001 left is a fourth character. The seed includes USD because all three columns are `NOT NULL DEFAULT 'USD'` — an FK without that row would turn the default into an INSERT failure, so that one is a precondition, not a preference. `currency_rates` is the history, and `vw_currency_rates` is what makes it more than a filing cabinet: the row in force as of the statement (`as_of` says so, because a view containing a quiet `now()` answers a different question on every scan), `in_force = false` where a pair's rows have all expired, and `rows_for_pair` so *expired* and *never existed* read differently. One-open-row-per-pair is a partial unique index; overlaps and gaps across closed rows need `EXCLUDE USING gist` over a timestamptz range, which needs `btree_gist`, which `0000` did not install — adding an extension to make a weaker promise than the index already makes is the wrong order, so probe E **shows** a gap existing quietly instead of claiming it away. Money gets `numeric(18,4)` and `total_cost` `numeric(24,4)` (1e16 fits 24,4 and does not fit 20,4, measured); quantities stay (12,4), because the finding is that the two axes shared a precision, not that a stock ceiling was small. Where the derivation lives is the part worth reading: the obvious mechanism is a column DEFAULT calling a function with the row's own key, and PostgreSQL forbids it twice over (§3's comment carries both errors, and a generated column needs an `IMMUTABLE` lie to do the same thing), so the rule is in **the two doors that write money** via capture-transform, and the watchdog for the writer that forgets it is a census — probe K counts balances whose stored currency disagrees with their item, so a bypassed rule arrives as a number rather than as a rumour. One case the derivation cannot see is refused instead: a balance already kept in a currency the item master has moved away from, which no CHECK can state and `ON UPDATE RESTRICT` cannot either (it guards the referenced key, not a referencing column moving), so the averaging door refuses that movement **before its ledger row**, 23514, which is 0015's decide-then-touch shape wearing a currency. Nothing converts anything: valuation gains `currency_code` in its projection *and* its GROUP BY — a warehouse holding a USD item and a JPY item was summing dollars and yen into one number, 0009's complaint about a missing grouping key on the other axis — and a `tenants.base_currency` column was declined as a column with no reader, the same mistake 0007 refuses for a vocabulary member no path writes. `vw_domain_vocabulary` is widened by capture-transform too, because its candidate rule was `atttypid IN ('text','varchar')` plus a name shape and a `char(3)` code is neither: the three currency columns were invisible to the published answer to "what does this column accept", and `verify.sh`'s B18 asked the same incomplete question beside it. Widening that filter immediately surfaced `currencies.currency_code` itself as UNDECIDED — a master's own key IS the value space — so §5 exempts code tables, **derived** from the catalog rather than listed, and the set became `units_of_measure`, `costing_methods`, `currencies`. Harness: five new `6_5` rows, one per block; B18's candidate rule and B19's global declaration both change with this file. |
| `0021_communication_write` | 4.5 | **The write door the tools were drawing.** Requirement 5 of the customer service agent is "log new interactions", and no function in the schema creates a `communications` row: `archive/blueprint/tools/add_communication.py` carried its own INSERT, qualified to the twin schema §3.3 says no migration ever made, so the rule lived where the database could not enforce it and the CHECKs lived here. `add_communication` is 20 parameters, all DEFAULTed, in 0016's shape. Four things it had to get right that the Python door could not: a customer named by a substring is resolved by an exact match or refused **with the candidates listed**, because `SELECT id INTO ... WHERE name ILIKE '%x%'` keeps whichever row the scan reached first and discards the rest without an error, which files a call against the wrong customer and then the trail faithfully records the mistake; an id or contact_id that the wall hides answers as a refusal rather than as a NULL a foreign key would accept (0018 measured that difference and lost a write to it); the six vocabularies on this table are the CHECKs' and are **not** restated in the body, so a direction of `sideways` keeps its own 23514; and `thread_root_id` gets its first writer, inheriting the parent's root so a reply-to-a-reply lands on the thread the first message started. `p_follow_up_required` without `p_follow_up_date` is refused - the flag and the date are one decision and `idx_comms_followup` is the schema saying so - and **no `followups` row is created**, which probe G asserts rather than comments, because `followups` has no writer in the schema and a door that touched two tables when its name names one is how the next fork starts. Claim-wired (ADR-005 pattern 2) with 0016's ladder, including the part 0016 proved by measurement: a *refusal* leaves the claim re-takeable, so probe I fixes the world rather than the arguments and a key never becomes a permanent no |
| `0022_followup_threshold` | 4.5 | **Three defects in one function, two of them silent.** `get_followup_customers` is the tool a service agent calls most, and `p_days_threshold` was declared, documented, DEFAULTed, and never read: the comparison was against a literal `INTERVAL '7 days'`, measured to answer identically at 1 and 60. The third reason, `Unresolved communication`, tested `last_outcome`, which no statement between `DECLARE` and that `ELSIF` ever assigned, so `NULL IN ('pending','escalated')` was UNKNOWN on every iteration and the branch has never fired in any migration since 0001 ported it - the same failure as dev/README's `SELECT INTO` entry, arrived at from the other direction (there the variable keeps a stale value; here it never had one). And the staleness clock was `created_at`, the row's write time, reported as `last_communication_date`: invisible while every row is written as the call happens, and a customer who has not been spoken to in forty days disappears from the list the moment anyone logs a call late or imports real dates - which is exactly what the seed in `db/seeds/` now does, and is the fixture that makes probe D discriminating. Rewritten set-based rather than as a loop with two aggregate reads per customer, which is what makes "a variable that survives an iteration" unreachable instead of merely absent. Signature untouched on purpose, so `CREATE OR REPLACE` matches the existing object: no second head (4.4's failure mode) and the ACL 0009 established survives - asserted, along with the pair of outcome values the filter names being checked against `vw_domain_vocabulary` rather than trusted, so a vocabulary rename fails here instead of matching nothing quietly. A negative or NULL threshold is 22023 before the scan; the INNER join to the primary contact and the absence of any promised order are preserved, and both are §5's |
| `0023_agent_memory` | ADR-002 | **The last agent state that was a file.** `pkg/memory/memory.go` wrote markdown into a container directory that no compose file declares as a volume, so an agent's memory had the lifetime of its image - redeploy and it forgets every preference it was ever told, with no error and no trail. Key identity was a filename, and sanitising `[^\w\-_.]` to `_` means `a/b` and `a_b` are the same memory: two intentions, one file, nothing reporting it. `agent_memories` is append-only rows of `(key, content, created_at)` and `save_memory` / `get_memory` / `list_memories` are the three operations. The table had to satisfy every mechanism that is derived rather than listed - 0003's tenancy column, 0006's tenant-led index, 0009's ENABLE+FORCE and read+write policy (B7 counts this table the moment it exists), 0013's trigger, which this migration attaches by hand because that census already ran and cannot see a table born after it - and it takes no `updated_at`, because nothing rewrites a row and 0010's register would then publish a maintenance promise nobody can keep; probe H watches the verdict rather than the claim. Append-only is a grant, not a convention: UPDATE/DELETE/TRUNCATE are revoked from `afpc_app` and PUBLIC the way 0013 did for `audit_log`, and B29 counts it, because probe B's first draft ran the UPDATE *after* `RESET ROLE` and reported a pass measuring a superuser's own privileges rather than the wall. All three domain rules live in constraints and the body contains no validation arm - a restated CHECK is the second copy that rots while looking green - so an impossible key answers 23514 naming the constraint, `get_memory` on that key answers zero rows, and probe E states that the asymmetry is a choice. `save_memory` takes a claim, so a retried tool call is one memory rather than two entries about the same fact and `list_memories`' count means what was learned instead of how often the model stuttered |
| `0024_partitioning` | 6.6 | *(was planned as `0019_partitioning`; renumbered, see below)* partition the append-only tables, BRIN on time columns |
| `0025_temporal_controls` | 6.6 | *(was planned as `0020_temporal_controls`; renumbered)* soft delete / bitemporal columns on contacts, addresses, communications |
| `0026_reservation_ledger_order` | 4.3, 6.5 | **The values were right and the columns were wrong.** `reserve_inventory_for_order`'s commitment row names eleven columns and forty cents of them in the wrong seats: 0018 §3b appended `currency_code` to the column list's end and inserted the currency expression after `p_reserved_by` — the middle of the VALUES — and both of its needles matched exactly once, so a transform that is asserted by text applied a rotation: `reference_type` received a currency code (accepted, false), `reference_id` received the mapped document kind (text into uuid, `42804`), and the order id never arrived anywhere. Every SUCCESS died on the door's own ledger INSERT and rolled back whole; only INSUFFICIENT_STOCK, which returns before the INSERT, ever completed — which is why probe `4_3` printed the second half of its own verdict line as ERR since the day 0018 landed and nobody had run the harness since. Found by `db/seeds/02_demo_inventory.sql` attempting the first successful reservation since, from the inventory agent's direction: a door cannot be probed into existence by the tools documentation says will use it. The fix is the same capture-transform with the needles swapped to the two rotated slots, plus what 0018 lacked: a behaviour assertion that RESERVES inside a subtransaction it discards and reads the three positions back, so the verdict comes from a reservation and not from a string. `4_8` §8a keeps the claim permanent. |
| `0027_suppliers` | — (orders 1/4) | **The counterparty a purchase order can honestly name, and the first edge in this schema that cannot point at another tenant's party.** Ordered first because 0028's counterparty column has nowhere to point without it. Two measurements precede the DDL, and they are the reasons the shape is this shape. `entities.entity_type` is CHECKed over one value per row, so a company that sells us steel and buys our spare parts is not representable — whichever value it holds, the other half of the relationship is invisible to the database — and a CHECK cannot contain a subquery, so "the party this purchase order names must actually be a supplier" is a claim `orders` could never have stated about a bigint. Separately: **a single-column foreign key is tenant-blind**, measured — an `afpc_app` connection bound to tenant A inserted an `addresses` row for tenant B's entity and answered `INSERT 0 1`, because referential-integrity checks do not apply row security, so the key was satisfied by a row the caller can never read back; the same statement through a composite `(tenant_id, entity_id) → entities (tenant_id, id)` answered 23503 naming the pair. That is 0011's "load-bearing, not hygiene" one step further: there a tenant-blind index lost a write, here a tenant-blind key admits a foreign row, and both are silent from the seat that does them. `suppliers` therefore **extends** the party root instead of paralleling it — `suppliers.entity_id` is the tenant-led key, so "is a supplier" is the existence of a row rather than the value of a column, one party can hold both roles, and a supplier that were not an `entities` row would have no contacts, no addresses and no `communications`, which in this system means no answer to "what has this supplier told us". The rejected alternatives are in the header, including why a party-roles table is four tables of machinery for one role. Uniqueness had to be tenant-led too: `UNIQUE (entity_id)` **fires before** the composite FK, so the first draft reported another tenant's party as a duplicate key — a sequencing fact, not a data one, and the reason the constraint is `(tenant_id, entity_id)`. `add_supplier` is the door (idempotent by the natural key it cannot CHECK), `vw_suppliers` the read, and the table is enrolled in B1 and B1b so a later migration cannot add it to the schema and not to the wall. Twelve behavioural probes |
| `0028_orders` | — (orders 2/4) | **One header and one detail table for three document types, and every new reference edge in the schema carrying its tenant.** The decisive objection to `sales_orders`/`purchase_orders`/`work_orders` is not tidiness: `inventory_reservations.order_id` is a single uuid that must name the document a commitment belongs to, and against three tables that reference is a three-way OR, which PostgreSQL cannot express as a foreign key — so it would remain what it is today, a number that means something only if the reader remembers which table it came from. So `orders` + `order_items`, discriminated by `order_type ∈ {SALES, PURCHASE, WORK}`, with the type differences where each mechanism can actually state them: the counterparty rule (customer XOR supplier XOR nobody, per type) as a **CHECK** because it has no subquery in it and must bind an operator in psql as well as a door; direction of stock in **the doors**, not a column; what a line means in `line_type` (STANDARD / COMPONENT / PRODUCT), which is the seam 0029 lands on. Lifecycle is one membership CHECK per column plus a composite key into a **global** `order_lifecycle`, and the reason it is not the obvious `CHECK ((type='SALES' AND status IN (…)) OR …)` is that `vw_domain_vocabulary` censuses single-column membership (`cardinality(conkey)=1`) — a two-column CHECK would leave `orders.status` looking unconstrained to the published answer while being the most constrained column on the server. The register carries `stock_moving` so `transition_order` can refuse to write a **consequence** by hand: "mark order 47 shipped" is a sentence a model can say, and without that column the database would do it and the ledger would then disagree with the document. Four things deliberately not stored, each with its reason in the header: header totals (a stored aggregate is a second truth about the rows it summarises — `vw_orders` sums them set-based, 0022's conclusion applied before the fact rather than after); line status (answerable from `quantity_fulfilled`/`quantity_cancelled` against `quantity`, and a second lifecycle is a second register to keep honest); `updated_by` (`audit_log` is who-changed-what's owner, and 0013 already decided that identity twice); and a width for `line_amount` — it is GENERATED, so PostgreSQL infers the precision from the multiplication, which is precisely the guess 0018 had to un-guess when `numeric(15,4)` died with a 22003 on arithmetic the schema asked for. `item_id` is nullable with a CHECK that a blank one carries a description, because a purchase order procures services and a one-off plumber is a real line; forcing every expense into the item master is how a deployment grows one item called MISCELLANEOUS, which is a NULL with a tax code. §11 records the tenant-blind edges this file did **not** retrofit and probe K counts them, so the debt is a number and not a rumour. Enrolled in B1, B1b and B19 (the globals). Thirteen behavioural probes |
| `0029_work_orders` | — (orders 3/4) | **A work order gets a plan, and the ledger vocabulary is repaired by the migration that would have exposed it.** The document with no counterparty, which 0028's header rule already stated; what was missing is what sits between the COMPONENT lines it consumes and the PRODUCT lines it yields. `work_centres` (tenant-coded operational master data inside a warehouse, so the warehouse edge is the same composite form — a bench cannot name somebody else's building) and `work_order_operations` (sequenced, with the planned quantity, the centre, and the two counters a real report needs), plus `plan_work_order_operation` and `add_work_centre` as doors and `vw_work_order_plan` / `vw_work_centres` as reads. Two vocabulary facts land here rather than in 0028 because a mapping is only wrong once something exists to exercise it: `inventory_movements.reference_type` CHECKed {ADJUSTMENT, ORDER, PO, TICKET, TRANSFER} while 0015's CASE maps PURCHASE→PO and **both** SALES and WORK→ORDER — so a movement made for a work order and one made for a sales order were indistinguishable in the ledger, a relationship that reads as if it were maintained — and TICKET names a table 0017 deleted, which is a live constraint pointing at a nonexistent thing. Measured before either edit: zero movements use TICKET, so dropping the value rewrites no history. The CASE is edited by capture-transform (read the installed body, assert the needle occurs once, DROP by full signature, recreate, re-grant), because a retyped body is a second implementation of the door 0015 tuned and 4.4's two-head failure mode is one DROP away. What it refuses to pre-build is the part worth keeping: no `routings`, no bill of materials, and **no `source_routing_operation_id`** column, because a uuid naming no table is the `order_id` defect waiting to be discovered — unreadable by any key, unfilled by any writer, and certain to be described as live by the next documentation pass. §7 records it as owed. It also moves no stock (0030's doors) and adds no `release_work_order`, because `transition_order` already implements that exact forward and a second function enforcing the same move is the duplication 0013's trail exists to catch. Ten behavioural probes |
| `0030_order_fulfilment` | 4.3, — (orders 4/4) | **The doors that finish a document, the first release this schema ever had, and the commitments that named nothing.** `reserve_inventory_for_order` has written stock commitments since 0015 and nothing in the schema could ever undo one: 13 units sat committed against four `order_id` values that named **no row in any table**, because the column is a bare uuid with no key behind it — 4.3's leftover, and the reason the inventory agent could make a commitment it could not walk back. So: `order_line_id` on the ledger (the line a commitment holds stock for, which is what 0030's reconciliation needs to be a query), §2's release selector as the mirror of 0015's drain order, §3's backfill that raises documents and lines **before** attaching enforcement so the trigger cannot refuse the history it is meant to explain, and a dangling PURCHASE or WORK commitment refused rather than given an invented counterparty — `RESERVATION_BACKFILL` orders carry no party and `origin` says why. Then the four doors: `ship_sales_order`, `receive_purchase_order`, `book_work_order_production` (components out, product in, one document at a time), and `cancel_inventory_reservation` — the release, with `afpc_reservation_names_a_document` attached only once the existing rows satisfy it and probe N proving the eight-argument shape agents still send. `vw_order_commitments` is the reconciliation as a read path, and it publishes `quantity_committed_unlinked` beside `quantity_committed`: a commitment that names this document and item but no line is real held stock, and joining on `order_line_id` alone would report it as **nothing committed** — the difference between "0 held" and "held, not attributed" is a decision the reader is entitled to make. §4b adds `inventory_reservations.updated_at` with 0010's touch trigger because these doors are the first writers that table has had and B24's rule would otherwise be false of it — the one harness failure this file closes. §5.5 teaches the reservation door `p_order_line_id` as a **ninth, appended, defaulted** parameter (position is the whole trick: the claim key is eighth and the inventory tool sends eight positional arguments, so an inserted parameter would land the key in a column — 4_8's 8b now asserts the invariant that survived rather than the arity that did not), and its fourth needle, a `line` key in the idempotency fingerprint, was removed on the reasoning that the fingerprint is compared against the one stored when a claim was first made, so changing it makes every in-flight claim look like a payload mismatch for 24h in order to guard a case the first answer already settles correctly. `idempotency_sweep`'s backlog is collected here (28 rows on this server) and §9 names who owes the keeper |
| `0031_sweep_keeper_grant` | 6.1, — (orders tail) | **The retention policy's keeper, given the privilege it was missing - and the one migration here whose justification is a measurement rather than a COMMENT.** `agents/sales`' hourly tick called `idempotency_sweep()` on its first run and got `42501`: 0011 had revoked that grant deliberately, with an assertion, because in July the only caller in the world was a human with psql, and one of its two premises - that collection is an operator action - went false the day a schedule was written. The grant is narrower than it sounds, and §1 refuses to assume why: it aborts unless `afpc_app` has no BYPASSRLS, unless `idempotency_keys` is RLS-FORCED, and unless the function is still SECURITY INVOKER, which are the three properties that make an agent-run sweep collect its own tenant's expired claims and nothing else - 0011's own COMMENT describing exactly that split. §2 records that the runtime role has held table-level DELETE since 0002, so this was one function grant and not a privilege review, and PUBLIC stays closed. §3 proves the reach instead of arguing it: two tenants with one expired claim each plus an unexpired in_flight claim, `afpc_app` sweeping one of them, and a count on the other two, inside a subtransaction that is then discarded - so the file commits a privilege and changes no row. If row security ever stopped filtering that DELETE, §3 would fail and 0011's objection become the correct one again, which is the right relationship between a grant and the claim that justifies it |

| `0032_conversation_identity` | 4.9 (post-review) | **A conversation id learns which agent it belongs to.** `ids.Thread` hashed the caller's thread string alone, three backends share one namespace and one tenant, and every web UI posts the same thread string, so one thread named one conversation between all three agents - and the reader (`Rehydrate`) hands that history back as prior assistant turns. The sales agent's "Hi" answer on 2026-11-08 was another agent's greeting. §1 reproduces the derivation in SQL and refuses to continue if it matches nothing; §2 re-keys, per tenant, only the rows the old rule names, which is what makes the file re-runnable; §3 asserts the post-condition the defect denies. Recoverable at all because `pkg/logging` writes the thread string into `telegram_chat_id` - the hash is not the record. |
| `0035_semantic_search` | 6.4, — (finding 6.4's other half) | **The vectors the indexes have been waiting for, and the fact that makes a swapped embedder a refusal.** 0012 built three hnsw indexes and declined the read path in its own header ("wiring a semantic-search tool is Phase 5 code work"), and `6_4_vectors.sql` has proved the ANN path is usable and cheaper ever since — on 500 rows of `random()::real`, which is a statement about an index and not about a feature. Measured again the day before this file: 25 communications, 22 entities, 15 contacts, **zero** non-null embeddings, and four pages of documentation agreeing that no embedder here produces 1536 dimensions. What changed is a server that answers an explicit width. So this adds two doors and changes no column and no index: `search_similar_communications`, which is 0012's deferred read path and applies its horizon **inside** the ANN top-k — filter-after-limit answers "the nearest rows, if any happen to be recent", which on a corpus where the nearest matches are old is an empty list that reads as "nobody complained"; and `embed_communications`, which fills gaps and never re-derives a value that is already there, because `afpc_audit_row` logs a no-op rewrite and a keeper that re-writes a row it did not change would file trail history for a table nobody changed, forever. Then the part the file exists for. Two embedding models both produce 1536 floats, a column holding both still inserts, indexes, and searches, and the ranking it returns is plausible garbage — and nothing in pgvector, in the catalog, or in verify.sh's existing 38 checks can see it. `embedding_space` is that fact's home, it is stamped by the first write rather than typed by an operator, and the door refuses any later write naming another model. §1's CHECK and B31 hold the width to the column from two sides because a constraint cannot read `pg_attribute`. §5b puts the composition rule — subject, summary and body, whitespace collapsed, capped at 4000 — in a view and not in a client, for 0007's oldest argument: a rule about the data that lives in a caller is a rule that eventually disagrees with the schema, and a vector is a rule about text. §5 is the register: **EMPTY, PARTIAL, UNSTAMPED, MISMATCH, UNINDEXED, COMPLETE** per vector column, because "nothing matched" and "nothing is searchable" are the same zero rows and only one of them is an answer. Two measurements set the design and are recorded here rather than in prose: asking the smaller model of the pair for 1536 answered `400 dimensions exceeds embedding length 1024`, and the identical call an hour earlier answered **200 OK with 1024 floats and no complaint** — so the width is asserted in the client, in the door, and by the column's type; and `afpc_audit_row` already strips vectors to a `<vector omitted>` sentinel, which is what made a backfill cheap enough to run against a live table. §7's seven probes run inside the file's own transaction and leave nothing behind, and they include the second model being refused on a populated column. `entities.embedding` and `contacts.embedding` stay empty **by decision** and say so in the register: requirement 1 is a question about what was said. The keeper that calls the write door is in `agents/customer_service`, not here — this file makes the capability possible and nothing more |


**Why the two planned migrations moved.** `0013_audit_log` refers to `0019` four times as the partitioning decision, and an applied migration is checksum-frozen, so the number could not be reassigned to something else. `0021`-`0023` were needed by the deployed customer service agent, and `migrate.sh` rejects any file numbered at or below the highest applied - which means that once those three were applied, `0019` could never have been applied to *this* database at all. The plans therefore move to `0024`/`0025`, and 0013's four references should be read as "the partitioning migration", which is now 0024. The alternative - numbering the CRM work `0019`-`0021` - would have made an applied file's prose wrong, and that is the worse debt.

## Consequences a later migration must pick up

`verify.sh` prints these counts every run — the catalog line for most, a named check's detail
for the rest — so the deltas are visible rather than remembered. One row is the exception:
"callable operations that take an idempotency claim" is printed by nothing, and its cells are
filled from `vw_idempotency_status` by hand. That is a weaker promise than the table's intro
otherwise makes, so the cell says where each number came from; if a future migration wants it
watched, the right move is a B-check over the register, not a wider hand-fill.

| Count | Before 0003 | After 0004 | After 0005 | After 0006 | After 0007 | After 0008 | After 0009 | Why | After 0010 | After 0011 | After 0012 | After 0013 | After 0014 | After 0015 | After 0016 | After 0017 | After 0018 | After 0023 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| FKs | 30 | 47 | 48 | 48 | 54 | 54 | 54 | `tenant_id` FKs, RESTRICT, on 17 tables; then `thread_root_id`, which 5.2 found had no constraint at all; then 6 to the master-data tables, which is why B17 had to be re-run against them. 0018's five are the currency edges 6.5 says are missing - three from the inventory model to `currencies`, two from `currency_rates`.| 54 | 55 | 55 | 56 | 56 | 56 | 56 | 56 | **60** | **61** |
| tenant-coded tables | 0 | 18 | 18 | 18 | 18 | 18 | 18 | the review's "0 rows returned" for 5.8 | 18 | 19 | 19 | 20 | 20 | 20 | 20 | 20 | 20 | **21** |
| FKs with no index anywhere | 12 | 11 | 11 | **0** | 0 | 0 | 0 | the corrected measure (see below): a column in no key position of any index. Unchanged by 0005 — `idx_comms_thread_root` already covers the new FK. 0006 indexes all of them | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| FK columns leading no index | — | 14 | 14 | **0** | 0 | 0 | 0 | 0006's invariant, now asserted. The judgment 0003 left to be confirmed resolved **against** the tenant-led composites: an FK existence check carries no tenant predicate, so `(tenant_id, col)` cannot serve it — measured, 47 buffers/0.193 ms as a seq scan versus 6 buffers/0.017 ms index-only. Both shapes are kept where both query shapes exist, which is not the duplicate case 5.6 is about | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| redundant index pairs (identical + prefix) | 8 | 3 | 3 | **0** | 0 | 0 | 0 | 4 pairs became single indexes when 0003 replaced the global natural key with a tenant-scoped unique; `0004` removed `idx_on_hand_available`/`idx_on_hand_low_stock`. The remaining 3 are pre-existing `idx_comm_*`/`idx_comms_*` pairs in `communications` (correction C1). 0006 found **3 more of the same defect that the review's measure could not see**: indexes whose column list is a strict leading prefix of another index on the same table (`audit_summary`, `locations`, `inventory_reservations`) — so the honest count of 5.6 is 6, not 3 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| integer key columns | 19 | 19 | **0** | 0 | 0 | 0 | 0 | 5.1/5.3: four serial PKs and fifteen referencing columns, widened together | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| key columns narrower than their ceiling | 4 | 4 | **0** | 0 | 0 | 0 | 0 | bigint keys fed by an integer sequence — see B14 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| domain columns with no published answer | 30 | 30 | 30 | 30 | **0** | 0 | 0 | 5.9's count, restated as a question the database can answer. 26 were constrained when this row was written and 4 are free text with a recorded reason; 27 by 0017; **32 after 0018**, because the register's candidate rule was widened to see `char(3)` and the five currency columns it had been blind to walked in | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| tables | 18 | 19 | 19 | 19 | 21 | 21 | 21 | the two master-data tables, `units_of_measure` and `costing_methods`. `currencies` and `currency_rates` are 0018's, and the first new tables since 0013's `audit_log`: both global, so both are declared in B19 rather than given policies, which is the pair of verdicts `vw_rls_status` now prints as five.| 21 | 22 | 22 | 23 | 23 | 23 | 23 | 23 | **25** | **26** |
| tables with row security forced | 2 | 2 | 2 | 2 | 2 | 2 | **18** | 5.7's `rls_forced = 0`. Scope is "has a `tenant_id` column", read from the catalog, so a new tenant-coded table joins automatically and B7 fails on it if it does not. The 4 tables without one are declared global in B19 | 18 | 19 | 19 | 20 | 20 | 20 | 20 | 20 | 20 | **21** |
| policies in `public` | 3 | 3 | 3 | 3 | 3 | 3 | **36** | 18 × `tenant_isolation` (FOR ALL, qual + WITH CHECK) + 18 × `audit_read_all` (FOR SELECT, `USING (true)`, the read roles' door). 5 dropped first: 3 keyed off `app.current_agent`, 2 of 0002's stopgaps | — | 38 | 38 | 40 | 40 | 40 | 40 | 40 | 40 | **42** |
| views | 14 | 14 | 14 | 14 | 14 | 14 | **15** | `vw_rls_status`. All 15 now carry `security_invoker=true` and every one over a tenant table exposes `tenant_id`, which is what closes 0003's deferral NOTICE. And from 0017 four are dependent rather than base-level - three read `agent_interactions`'s columns, one reads `vw_tool_calls` - so a partition split or a column rename has views to recreate in the same commit - see Obligations-0017. `vw_currency_rates` is 0018's, and the first view over a table with no `tenant_id`, which is why it exposes no tenant column.| **16** | 17 | 17 | 18 | 18 | 18 | 18 | **22** | **23** | 23 |
| functions executable by every role | — | — | — | — | 13 | 13 | **0** | 0008's census, swept. Three stay open by declaration — `afpc_current_tenant`, `afpc_policy_tenant`, `afpc_uuid_v7` — because they are called from column defaults and policy quals during an ordinary SELECT | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| CASCADE edges | 6 | 6 | 6 | 6 | 6 | **1** | 1 | 5.10's count. Five flipped to RESTRICT (four inventory, one audit); `locations -> warehouses` retained — bin rows with no stock, no open reservations and no ledger reference are structure, and deleting them with the warehouse is composition, not destruction. B3 checks both sides: no CASCADE on a table that holds facts, and no CASCADE anywhere else beyond that one named edge | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 |
| triggers in `public` | 3 | 3 | 3 | 3 | 3 | 3 | 3 | 13 `afpc_touch_updated_at` triggers plus `trg_on_hand_consistency`. The two bespoke timestamp triggers 0001 ported are retired, and 6.3C's duplicated function with them. 0018 adds two, one per new table, because 0010's rule is read from the catalog and a code table with an `updated_at` is exactly the case it was written for.| **14** | 17 | 17 | 36 | 36 | 36 | 36 | 36 | **38** | **39** |
| tables whose `updated_at` is maintained | 2 | 2 | 2 | 2 | 2 | 2 | 2 | 6.3's own measure, which is a behaviour claim rather than a column census: two of eleven before 0010 (the review's two "yes" rows), thirteen of thirteen after. 0018's two are `currencies` and `currency_rates`, so B11's census covers every mutable table in the schema and none of them lies.| **13** | 14 | 14 | 15 | 15 | 15 | 15 | 15 | **17** | 17 |
| tables with no row-creation timestamp | 3 | 3 | 3 | 2 | 2 | 2 | 2 | 6.3's last paragraph named three; measured, `inventory_movements.performed_at` already served, so the real gap was two. `schema_migrations.applied_at` is build bookkeeping| 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| base-table vector columns led by hnsw | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 6.4. 0001 gave one of three an ivfflat; measured at 0011, the planner did not use even THAT for an ANN ordering unforced (Seq Scan + Sort at 500 rows), so 0 of 3 were really searchable in a plan anyone would run. 0012 makes it 3 of 3 | 0 | 0 | **3** | 3 | 3 | 3 | 3 | 3 | 3 | 3 |
| domain functions in `public` | — | — | — | — | — | — | — | 4.4's own evidence, and available without calling anything: a name with two heads in `pg_proc` is §3.3's fork come back inside the canonical schema. Counted from the printed catalog line. Only the two rightmost cells were measured when they were true - backfilling the earlier ones now would be arithmetic dressed up as history. `afpc_item_currency` is 0018's: a mechanism, not a door, revoked from PUBLIC with the rest of them.| — | — | — | — | — | 26 | **25** | 25 | **26** | **30** |
| callable operations that take an idempotency claim | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 6.1/ADR-005 pattern 2, counted from `vw_idempotency_status`, because the register is the only place the claim is visible. 0011 built the mechanism and said where a claim belonged; 0014 is the first function that actually takes one, which is what turns its register row from a regex's guess into a fact. 0015 makes it two: the reservation door, whose register row had said "pattern 3" because a `version` column exists on a table it writes and nothing had ever compared it | 0 | 0 | 0 | 0 | **1** | **2** | **3** | 3 | 3 | **5** |

**What 0021-0023 moved, in one place.** These three migrations are the first since 0008 whose
subject is a *caller* rather than a table: they exist because a customer service agent was about to
be deployed against this schema and three things it needs were not in it. Two rows move by one and
one by two, and the reason is the same in each case - `agent_memories` is a tenant-coded table, so
it enrolls in tenancy (tenant-coded 20→21, FKs 60→61, RLS-forced 20→21, its two policies 40→42),
in the trail that 0013's census can no longer reach (triggers 38→39), and in the key-typing rules
that made 0005 prefer UUIDv7 here rather than a sequence (which is also why the `tables` row is the
one place a new sequence did not appear). The function rows move for a different reason: `add_communication`,
`save_memory`, `get_memory` and `list_memories` are four new objects, and two of them take a claim,
so "callable operations that take an idempotency claim" goes 3→5 counting only domain operations -
`idempotency_claim` itself answers the same query and is the mechanism, not an operation on it, so
the cell is read from `vw_idempotency_status` and not from a raw `proargnames` census. `views` and
`base-table vector columns led by hnsw` are unchanged, and that is the point of two of §5's
obligations: 0023 added no view, and it added no vector column to make the 6.4 row look busier.

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
  `agent_first_erp_crm` in `archive/blueprint/bot.py`'s default config cannot even log in
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
  *Amended by 0031, and it is the premise that changed rather than the argument.* Something now runs
  it - `agents/sales`' tick - and the closure on the grant was the last thing standing between that
  keeper and its job. 0011's reasoning was sound for July's caller, where "operator action" described
  who would call it; there is now a scheduled caller that is not an operator, and "safe to leave
  closed" had been measured against the backlog 0030 had to collect by hand. 0031 grants to
  `afpc_app` alone, behind the three assertions that keep it the tenant-scoped half of the split 0011
  designed, and asserts the closure 0011 could only assert once, at apply time. Nothing in the schema
  schedules anything, which was this bullet's point in July and is still its point.
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

### Obligations 0014 creates for the migrations after it

- **`0015` owns two things this file made load-bearing.** The RESERVATION path:
  `execute_inventory_movement` now REFUSES the type (23514, with the pointer), and
  `reserve_inventory_for_order`'s own direct movement INSERT omits `unit_of_measure` - so
  0015 must either drop that insert (the plan says: no recursive movement insert) or give
  it a unit; the warehouse-shape CHECK will not let it slide past in the current shape.
  And the multi-bin double-decrement: 0014's ROW_COUNT assertion catches zero, not two -
  the location-honouring WHERE is 0015's, and `4_6`'s second block keeps it honestly open.
- **Phase-5 tools that call `execute_inventory_movement` should pass a key.** The parameter
  exists and is wired; ADR-005's schema half is done and the client half is one argument.
  Without a key the function is as replay-safe as it was - which the register states.
- **`mark_customer_followup` is the pattern for state-setters 0007 found writerless.** If
  another vocabulary member turns out to be a dead end (the `5_9` probe prints those
  candidates), the answer is a convergent setter, not a trigger with opinions.

### Obligations 0015 creates for the migrations after it

- **A rewrite that changes a signature owes the claim, and the delta table is the only thing
  watching.** Both doors retook `p_idempotency_key` in this file; `vw_idempotency_status` is
  derived, so a rewrite that drops the `idempotency_claim` call silently moves a row from
  pattern 2 back to whatever the ladder guesses. The count of claim-taking functions is
  written down in this file's delta table (2 after this file) and asserted nowhere, which is
  the weakest watch in the table — see the note above it.
- **Whoever adds reservation fulfilment must invert probe L deliberately.** The pick draws on
  `quantity_available`, so today reserved stock cannot be issued through the generic door and
  there is no path that consumes a reservation. That is a boundary, not a feature: when the
  fulfilment step lands, probe L's expectation flips from "23514" to "the issue succeeds", and
  the flip must be in the same commit as the new code, with §6's COMMENT amended in the same
  pass. Probe C's balance arithmetic is the other assertion that moves.
- **The `order_type` → `reference_type` mapping is total over what the register publishes, and
  probe I reads the register rather than this file's memory of it.** A migration that adds a
  sixth order type without a mapping line fails there by name. The reverse also holds: a
  mapping added for a type that the CHECK later stops admitting leaves a dead `CASE` arm, and
  nothing but reading both sides will notice.
- **`afpc_pick_bins` is granted to `afpc_app` and revoked from PUBLIC on purpose** — it is a
  mechanism, not a door. A third function that takes stock out should call it rather than
  re-implement the drain order (B25's one-implementation-per-rule argument, applied to bodies
  instead of trigger text); a function that plans a draw and then skips the ledger row would
  produce the phantom this helper exists to prevent.
- **Phase-5 tools should pass a key and, where they know the bin, a location id.** Both
  parameters are DEFAULTed, so nothing breaks without them, and nothing is protected either —
  ADR-005's client half is still unclaimed, and 0015's bin naming is invisible to a caller that
  keeps sending NULL.

### Obligations 0016 creates for the migrations after it

- **`update_customer` is the remaining CRM head with no claim, and nothing in the plan owns
  it.** 0011's register lists it as UNGUARDED for the same reason add_customer was: its body
  is reads followed by writes. 0016 fixed the head 4.4 named; 0017 is scoped to 4.5's missing
  tables, so the ADR-005 gap in the CRM's other write path has no migration number attached
  to it. That is a hole in this file's own coverage tracker, not a closed item.
- **Probe I asserts an asymmetry, not a policy.** Email is matched `ILIKE`, phone by `=`.
  Whoever normalises contact identity - a `phone_e164` generated column, or a trigram index
  with a tenant-led arbiter - must edit probe I in the same commit, because the probe's whole
  value is that a silent behaviour change makes it fail.
- **The race is only half guarded, and the honest fix is a constraint.** A caller that takes
  no key can still create two customers for one human: the duplicate checks are reads, and
  measured, two backends one second apart produced two entities and two contacts. The claim
  serialises callers who use it. The durable answer is a unique index on
  `(tenant_id, lower(email)) WHERE email IS NOT NULL` - a data-model decision 0011 declined
  when it chose pattern 2 over pattern 1, and one 0016 declines again rather than making it as
  a side effect of a syntax fix. If it lands, `add_customer`'s register verdict moves toward
  pattern 1 and probe C has to be re-read, not just re-run.
- **A two-backend assertion cannot live in a migration.** The measurement that justified this
  file's claim came from the shell, so nothing in `verify.sh` or `db/tests/` will notice if the
  arbiter stops serialising. T3's CI is the place it belongs: two `psql` processes, one key,
  one row count.
- **Phase-5 tools should pass the key and stop reading prose.** `archive/blueprint/tools/add_customer.py`
  issues fourteen positional arguments; the fifteenth is defaulted, so nothing breaks until a
  retry happens. Its `except Exception` path already turns an error into a message, which is
  the half the deleted SQL re-wrap was doing - so the code-side change is one argument, and it
  belongs in T1's sweep of the same file.

### Obligations 0017 creates for the migrations after it

- **`0019_partitioning` has three dependent views to recreate, and one dependent view of a
  view.** `vw_tool_calls`, `vw_recent_interactions` and `vw_failed_interactions` read
  `agent_interactions`'s columns; `vw_tool_performance` reads `vw_tool_calls`. A partition split
  of `agent_interactions` therefore costs a `DROP VIEW` chain and a re-create in dependency order
  - 0009's machinery (capture the column lists, recreate, prove them identical) is the precedent
  for doing that faithfully, and `security_invoker` and the two `GRANT SELECT`s are dropped by the
  replace, so they belong in the same commit and after the creates. If `audit_log` is partitioned
  as well, its segments are detach units and none of this changes that: the trail is not a
  dependency of these four.
- **`vw_tool_calls` is where a per-call error would have to come from, and probe H is the guard
  on pretending it already has.** The base table records one `error_message` per run, and
  `tool_observations[].type` is `str` for an error return and for a result return alike, so
  nothing in the schema distinguishes "this call failed" from "this run failed and this call is
  one of its steps". The change that would close it is a key on the step objects -
  `actions_taken[i].error` or the same on the observations - written by `interaction_logger.py`,
  not a parallel log table, because two writers of one fact is §3.3 again. Whoever adds it must
  delete probe H's second half and widen the view in the same commit; leaving the probe to fail
  on a real improvement is how a guard becomes an obstacle.
- **T1 owns the deletion 0017 proved dead.** `archive/blueprint/tools/tool_logger.py` creates a table at
  runtime and inserts into it, and `archive/blueprint/postgres_callback.py` carries the same shape;
  nothing imports either. 0017 answers their question with a view rather than adding a writer, so
  the code sweep now has a reason to delete rather than defer: the runtime DDL cannot work in this
  schema, and a future reader who finds the module will otherwise think the derivation in
  `vw_tool_calls` is the duplicate. If T1 instead wires `tool_logger.py` up, that is a decision to
  have two loggers, and `vw_tool_calls` should then read the table it writes.
- **T2 owns the other half of `4_5`.** The rewritten 5b line maps to `code:vw_customers_filter`,
  whose `closed()` branch does not exist yet, so the harness prints it KNOWN-OPEN forever - which
  is honest but inert, and it is the reason the marker table gained a "Watched by" column. The
  underlying finding is bigger than the view's filter: `entities.entity_type` admits `prospect`,
  and no function in the schema can write that column - `update_customer` has no
  `p_entity_type`, `add_customer` always writes `'customer'` - so a documented domain member has
  no door. Deciding the filter without deciding the writer leaves a value reachable only by raw
  INSERT.
- **Phase-5 agents should read this path rather than parse jsonb.** The trajectory question -
  what did the agent call, in what order, with what out - has exactly one canonical answer now.
  An agent that re-implements `jsonb_array_elements` over `actions_taken` will disagree with
  `vw_tool_performance` on fan-out, which is the arithmetic this file exists to have fixed once.

### Obligations 0018 creates for the migrations after it

- **`0019_partitioning` cannot partition `currency_rates` the way it partitions the other
  append-only tables, and the collision is measured, not suspected.** A unique index on a
  partitioned table must include every partitioning column - `0019` will want `valid_from` as the
  partition key of a history table, and `uq_rates_one_current` is `UNIQUE (from_currency,
  to_currency) WHERE valid_to IS NULL`. Attempted on a scratch range-partitioned clone:
  `0A000 unique constraint on partitioned table must include all partitioning columns`;
  adding `valid_from` to the index makes it build, and makes the promise vacuous, because a pair can
  then hold two open rows in two different partitions. So either rates stay unpartitioned, or
  §2's one-open-row mechanism has to become the one it declined here.
- **The mechanism §2 declined is available, and that is the reason to say so out loud.** An
  `EXCLUDE USING gist (from_currency WITH =, during WITH &&)` over a `tstzrange` is the general
  answer - it forbids overlaps *and*, with a fillgap helper, gaps. Measured on a clone: it fails
  today with `42704 data type character has no default operator class for access method "gist"`,
  and `CREATE EXTENSION btree_gist` succeeds in this image, so the reason 0018 did not use it is
  scope rather than ability. A future migration that installs the extension for another reason owes
  this table a decision in the same commit; probe E's gap assertion is the thing that will notice
  if nobody pays.
- **Nothing converts, and one number has to be chosen before anything can.** Valuation is grouped
  by currency instead of translated, so `vw_inventory_valuation` now answers "value of this
  warehouse-category, per currency" and cannot answer "total value". Building conversion means
  fixing three things this file refused to guess at: a tenant's base currency (`tenants` has no
  such column, and adding one with no reader is the 0007 mistake), which rate applies to an
  `average_cost` built from months of receipts (the movements have dates, the average does not),
  and whether an inverse is `1 / rate` or a stored row. `vw_currency_rates` is the reader that
  exists; the arithmetic that would consume it does not.
- **`afpc_item_currency` is called from exactly two places and probe N counts them.** A third
  caller is legitimate the day a new money-writing door exists, and probe N will fail on it. That
  is the same arrangement as 0017's probe H: delete the assertion in the commit that earns it, not
  in a later one that has to rediscover why it was there.
- **`inventory_items.currency_code` is still a writable mistake, because there is no item door.**
  There is no `add_item`: the item master is created by raw INSERT, so a wrong currency at the top
  of the derivation cannot be refused by anything until the door exists. §3b makes a *changed*
  currency loud, and probe K counts the rows that disagree, but the Phase-5 item door is the place
  the rule gets a real gate. Its sibling in the CRM is `update_customer`, still UNGUARDED with no
  migration number (Obligations-0016) - two heads of the same shape, both unfixed.
- **A populated deployment owns a reconciliation this file deliberately does not run.** Probe K
  prints `6.5 NOTE n balance rows disagree with their item's currency` and stops there, on purpose:
  rewriting `cost_currency` to match the item master would relabel an `average_cost` that was
  computed in the other currency, which is measurement 2 with tidier handwriting. The safe shape is
  a report plus a human decision per item, and a deployment with real stock has to make it before
  anything starts trusting `vw_inventory_valuation` across currencies.
- **Global master data has no trail, and a currency retirement is exactly the kind of change 0013
  was written to make loud.** `audit_log.tenant_id` is NOT NULL, so a row in a table with no tenant
  has nowhere to be filed; probe L asserts the absence rather than letting it be discovered. If the
  trail is ever widened to globals, probe L's second and third assertions have to be inverted in
  the same commit, and `vw_audit_coverage`'s scope sentence ("tenant-coded tables") stops being
  true and needs rewriting with it.
- **The register now sees a future `char(3)` currency column, so B2 is the guard for one.** Measured
  on a scratch table: `CREATE TABLE t (tenant_id uuid, currency_code char(3))` lands in
  `vw_domain_vocabulary` with `enforced_by = 'none - free text'` and a `UNDECIDED` reason, which turns
  `verify.sh`'s B2 red on the next run. That is the intended shape - a money column that arrives
  without an edge to `currencies` is now a visible failure rather than a silent one - but it also
  means a migration that adds a currency column *deliberately* (a quotation line's currency, a
  payment's) has to either add the FK in the same commit or record a reason in 0007's register of
  free-text columns. §1's decision that membership lives on the master is what makes both branches
  cheap; it is not what makes them automatic.
- **`warehouses.country char(2)` is measurement 4 with a different name, and it is now the odd one
  out.** §5's candidate rule sees a `char(2)` the way it sees a `char(3)`, but the column matches
  none of the name shapes, so it stays out of the register entirely - which is a third state, past
  "constrained" and "free with a reason": not asked about. If `countries` is ever added, §5's
  derivation will find it without being edited, and probe J is the check that the hand-written
  value-listing arm kept pace. That asymmetry - derived set, manual UNION of value lists - is the
  part of 0018 most likely to be tripped over.

### Obligations the orders programme (0027–0030) creates for the migrations after it

- **Both debts 0030 named are paid, by `agents/sales`, and one of them needed a migration.** The
  ticker exists: `runHousekeeping`, `runInventoryCheck`'s shape - hourly, no model in the loop, every
  run an `agent_interactions` row, so "it ran" is a query and "it stopped" is a gap in that list. Its
  first tick supplied the evidence this bullet was asking for: it reconciled four lines and answered
  `42501` on the sweep, because the keeper 0030 asked for had been granted to nobody, which is what
  0031 is for. Two claims about a scheduled keeper are now obligations on whoever edits it, both held
  in `pkg/orders/housekeeping.go`: **a tick that failed must say so in `final_output` rather than
  arrive as a clean zero** - `describe()` renders a broken sweep as `CLAIM SWEEP FAILED (…)`
  because "claims swept: 0 expired collected" is exactly the sentence this server believed for an hour
  while retention was not being enforced - and **one half failing must not stop the other**, because a
  privilege gap in the retention policy says nothing about whether a line's counter agrees with the
  ledger that moved its stock, and an earlier version of that block returned before the
  reconciliation's memory write. `TestATickStillReconcilesWhenTheSweepFails` holds both.
- **`vw_order_commitments` answers everything about a commitment except which commitment it is.** The
  view carries the line's quantities, the ledger's total, and a verdict, and no `reservation_id` - and no
  view in the schema has one, measured over every `vw_*` column. So `cancel_inventory_reservation`, the
  door `0030` exists to be the way a hold ends, takes an argument no read can return - and the creating
  door answers it, so a hold raised after `0030` is nameable by whoever raised it:
  reachable from psql, unreachable in a conversation. `0030` added `order_line_id` to
  `inventory_reservations` so that the reconciliation could be a query, and the same argument that
  justified *that* - a fact the agents must act on needs a key the agents can name - applies one column
  later. The fix is that column in the view that already joins to the row, plus its grant and a probe;
  `agents/sales/README.md`'s "What is not here" and `TestEveryDoorKeyIsReadableFromARead` keep it visible
  until then, the latter by asserting the absence so that adding it updates the documentation in the same
  commit rather than three months after.
- **`vw_order_commitments.ledger_agreement` now has a subscriber.** The same tick scans it hourly, and
  when the answer moves it writes `agent_memories` under `orders.reconciliation.state`, so "what
  changed overnight" is a read rather than a re-scan. `audit_summary`'s rollup and
  `vw_pending_followups`' writerless table are still in that class - a policy with no keeper - and
  this one has left it.
- **The tenant-blind edges 0028 §11 lists are counted, not fixed.** Probe K publishes the number.
  Retrofitting them is one migration with a decision in it, not six ALTERs: existing rows may
  already reference a party in another tenant (0027 measured that this is possible and silent), so
  the file has to say what it does when a row's `tenant_id` and its target's disagree — refuse the
  migration, re-point the row, or archive both — and a fix that guesses is a data change wearing DDL.
- **`order_lifecycle` is global on purpose, so a tenant that wants its own workflow needs three
  edits at once.** The `tenant_id` column, the composite key every `orders` status edge now depends
  on, and B1/B19's enrolment — plus which half of `stock_moving` stays repository-wide, because a
  status that reports a warehouse action is not a tenant's preference and a tenant that could set it
  false could have `transition_order` write consequences by hand again.
- **`create_order` refuses an unknown `order_type` with someone else's message.** Measured while
  building `agents/sales`: `23502 null value in column "doc_type" of relation "document_counters"` -
  not `22023`, and naming an internal table where it should name the caller's argument. The mechanism
  is deliberate in 0028: the type-to-prefix `CASE` has no `ELSE`, so the counter's own NOT NULL key is
  the arbiter, which fires before anything is written and keeps the vocabulary in one place rather than
  two. It is still the wrong sentence for a tool's caller, who has never heard of `document_counters`
  and will read a database fault into a typo. The fix is an `ELSIF` in that `CASE` raising `22023` with
  `p_order_type` and the published values read from `vw_domain_vocabulary` - not a restated list, which
  is how a second vocabulary starts disagreeing with the first - and `document_counters`' key stays as
  the backstop it already is. Nothing pins the current code today - `7_1` §1a tests the counterparty
  rule, not this typo, and §1f's own probe is the door's arity - so that migration adds its case to
  §1a and says which code it chose, rather than leaving the answer to whatever SQLSTATE the plumbing
  happens to raise.
- **A fourth `line_type` is a door change, not a value insert.** `afpc_line_type_matches_document`
  and `book_work_order_production`'s direction rule both read the axis, and 0015's `reference_type`
  CASE maps document kind to ledger kind. Adding a member without all three is the 0026 class of
  defect — accepted, and false.
- **Routings are owed, in the form 0027's rule prescribes.** 0029 §7: when they arrive they arrive as
  `routings` and `routing_operations` with a tenant-led key from `work_order_operations` into them
  *in the same migration*. The seam column was declined because a uuid naming no table is exactly the
  `order_id` defect 0030 spent a backfill and a trigger closing.

## Found while building 0027–0030

Four measurements that changed a shape rather than confirming one, gathered here because the programme
is one design read across four files and a reader of `verify.sh` cannot tell from a table row which
facts were surprising.

1. **A foreign key does not respect row security.** 0027's probe: tenant A's connection, an
   `addresses` row for tenant B's entity, `INSERT 0 1`. RLS is applied to the statement the caller
   runs, not to the RI machinery's internal reads, so the key was satisfied by a row no read path in
   the tenant can reach. Six edges into `entities` have this shape today. Composite
   `(tenant_id, col)` edges answer 23503 instead, and every key 0028–0030 adds is that form.
2. **A UNIQUE constraint can fire before the FK it depends on.** Same migration: `UNIQUE
   (entity_id)` on a party extension reported another tenant's party as a duplicate key, because
   uniqueness is checked without consulting the composite edge. The fix is a tenant-led unique — not
   a reordered statement, which is what it first looked like.
3. **The first writer of a table is what proves its `updated_at` was missing.** B24 has been passing
   on `inventory_reservations` since 0010 because nothing had ever UPDATEd one of its rows: the
   column this programme needed in order to answer "when did this commitment settle" did not exist,
   and no register could see the absence of a writer. 0030 §4b is 0013's prescription (the column
   plus 0010's own trigger), applied before the doors landed rather than in a follow-up.
4. **Two probes were measuring their own assumptions, not the code.** `4_3`'s second DO block
   reserved against `gen_random_uuid()` — the shape whose residue this programme exists to remove —
   and 4_8's 8b asserted `array_length(proargnames,1) = 8`, which is arity wearing an invariant. Both
   now state the rule that survives a signature change: positions 7 and 8 are what the tool calls
   them, and anything past the eighth argument is appended and defaulted. Each branch was
   negative-tested by reordering and un-defaulting the new parameter in a rolled-back transaction;
   the second branch turned out to be **unreachable by DDL** (PostgreSQL rejects a defaulted
   parameter followed by a plain one), which is worth recording as the probe's own limit.

## Found while building 0018

- **The obvious mechanism died in the parser twice, and the second death is the instructive one.**
  `ALTER COLUMN ... SET DEFAULT afpc_item_currency(item_id)` is refused as
  `cannot use column reference in DEFAULT expression`; wrapping the read in a subquery - the shape
  that suggests itself when the first error is read as "it wants an expression, not a name" - is
  refused again as `cannot use subquery in DEFAULT expression`. Two rejections for two unrelated
  reasons, and the idea is dead either way. It is worth noting because the mechanism is so natural
  that three of this file's sections were drafted around it before any of them ran.
- **A generated column looks like the rescue and is the trap.** Its expression may name another
  column of the same row, so `cur char(3) GENERATED ALWAYS AS (afpc_item_currency(item_id)) STORED`
  is the shape to try, and it is refused - `42P17 generation expression is not immutable`. The way
  *around* that is to mark a table-reading function `IMMUTABLE`, and measured, PostgreSQL accepts
  that and builds the column. So the failure mode is not a wall but a door: the syntax that "works"
  produces a stored value that silently disagrees with the table it read, on every edit to that
  table, forever. 0007's note about a constraint that cannot be violated has a generated-column
  twin.
- **`0019` would break this file's rate promise, and the only way to find that out was to try it on
  a partitioned table.** `UNIQUE (from_currency, to_currency) WHERE valid_to IS NULL` cannot exist
  on a range-partitioned-by-`valid_from` `currency_rates` - a partitioned unique index must include
  the partition key - and the version that includes it stops being an arbiter. Writing an obligation
  ("partitioning needs care here") would have been true and useless; the obligation now carries the
  error and the reason the obvious workaround is vacuous.
- **A view depends on itself, and `pg_depend` will report it as a dependent.** §4's guard - refuse
  if anything depends on the three views about to be dropped - fired on `vw_inventory_valuation`,
  `vw_item_availability` and `vw_item_movement_summary`, which are the three views being dropped. A
  view's `_RETURN` rule is a `pg_rewrite` entry whose own relation it reads, so the census needs
  `dv.oid <> bv.oid`. Same family as 0017's `pg_class`-versus-`pg_rewrite` note, one step further
  in.
- **Drop and recreate inside one loop, and the ALTER you were about to need is blocked again.** The
  first draft of §4 walked the three views capture → drop → alter → recreate, and died on the
  *second* view's ALTER with `cannot alter type of a column used by a view or rule`: recreating the
  first view restored its dependency on the very column the next statement wants to widen. Hence
  capture-all, drop-all, alter, recreate-all, staged through a temp table. The general shape is
  worth keeping: a transformation that touches N columns and M views has one ordering, and it is
  not the one that reads most naturally.
- **Reasoning about which constraint would fire produced the wrong SQLSTATE, and the probe caught
  it.** §6's probe G' was written expecting `23502`: an invisible item, a `NULL` derivation, a NOT
  NULL column. What actually happens is that the row is *accepted*, with `currency_code = 'USD'` -
  a foreign-key check does not apply row security, and USD is a perfectly real currency, so nothing
  is violated. The probe was rewritten to assert the measured outcome and the file's argument
  changed with it: this is why §0 says *census* where it first said *claim*. A rule enforced by a
  column mechanism fails loudly and a rule enforced by a body fails only where a count is looked at.
- **Widening a vocabulary register surfaced an `UNDECIDED` in the new master table's own key.**
  `currencies.currency_code` matches a name shape written for status-like columns, and a code
  table's key is a value space rather than a column that references one, so §5 needed an exemption -
  derived from the same catalog rule as the set itself, not a hand-written name list, because the
  whole reason `currencies` appeared was that a named list had fallen behind. Two lessons in one
  line: a candidate rule that quietly excludes a data type is also a rule that quietly includes
  whatever else has that type; and B18 and the register are independent recomputations of one
  sentence, so both changed in this file and neither was trusted to notice the other.
- **A census probe counts the drift its own probes manufactured.** §6's probe K reports how many
  balance rows disagree with their item's currency, and on the first real apply it printed `1` on a
  database with no stock in it at all: probes C and D create exactly that disagreement to prove §3b
  refuses it. The fix is not to drop the count but to scope it - `sku NOT LIKE '0018-%'` - **and** to
  assert that the excluded set is non-empty, because an exclusion with no counter-assertion is how a
  census becomes a way of not looking. Same family as 0017's namespaced-fixture note, in the opposite
  direction: there the probe was reading an aggregate that summed other migrations' rows; here it was
  reading a schema that included its own.
- **The register's new reach was tested by giving it something new to see.** Adding a
  `CREATE TABLE t (tenant_id uuid, currency_code char(3))` inside a scratch transaction makes it
  appear in `vw_domain_vocabulary` as `none - free text` and turns B2 red - which is what §5's
  widening is actually for. Worth measuring, because the alternative reading of a candidate rule that
  includes `bpchar` is that it exists to catalogue the three columns this file fixed, and a rule that
  only describes last migration's finding is a comment rather than a check.
- **`char` blank padding makes a typo indistinguishable from its own correction.** Pre-0018, the row
  written as `'xt'` matched `= 'xt'`, `= 'xt '` and `= 'xt  '` alike, so even a careful reader cannot
  tell the three characters that were meant. This is why §1 put the membership rule on the master
  and left the type alone: a `CHECK (currency_code ~ '^[A-Z]{3}$')` on four columns is four rules,
  and a FK to a table whose own key is shape-CHECKed is one.
- **0010's touch trigger honours a caller that names `updated_at`, which makes the obvious version
  of this file's timestamp probe untestable.** `now()` does not advance inside a transaction, so
  "did the stamp move?" cannot be answered here at all - the first draft failed on the clock, not on
  the trigger. What *can* be answered, and what 0010 actually promises, is the other half: an
  explicit value survives, an unnamed update is stamped to the transaction instant. Probe M asserts
  both. Same lesson 6_3's header carries; re-learning it cost a rehearsal cycle.
- **Three quoting errors, all invisible in an editor, all caught by a rehearsal.** `format('%I', …)`
  applied to a COMMENT body quotes it as an identifier; `%L` is the one that means a string. An
  unescaped apostrophe in a needle's *description* (`§5's`) ended a SQL literal inside a plpgsql
  string. And a RAISE whose argument list had one more entry than its message had placeholders was
  reported forty lines from the statement at fault - 0017's note, encountered again by different
  means. None of the three is visible as a diff; each is a parse failure in a string nested two
  levels deep.
- **A plpgsql query alias that shadows a block variable is a different query.** §6's probe M said
  `FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid` inside a block that already declared
  `t record` for a needle loop, and PostgreSQL resolved `t` to the record: `record "t" has no field
  "tgrelid"`. The alias was renamed to `tr`. It reads as a warning about variable names in queries,
  and it is really a reminder that in plpgsql a bare name is never *only* a table alias.

## Found while building 0017

- **The measurement that made the legacy definitions indefensible was mounting them.** The plan
  said "or delete the code that calls them", and both options were guessable without evidence;
  what settled them was creating the four legacy views on a clone of live, inserting a two-run
  fixture, and reading the report. `error_count 3` against a truth of 1, `700 ms` against 500,
  `0 rows` against 5, and a whole report dying from one object-valued row are four numbers no
  amount of reading the body would have produced - a wrong aggregate is invisible in the text of
  a wrong aggregate.
- **`LIMIT` inside a view is a filter that runs first.** Measured: five old rows of bot Z, four
  newer rows of bot A, `LIMIT 4` in the view, `WHERE bot_id = 'Z'` outside it - zero rows, while
  the table holds five. The fix is not to widen the number. The order a view promises is not a
  property a view can hold anyway, because an outer plan may re-sort; so the listing keeps neither
  the `LIMIT` nor the `ORDER BY`, and the documentation shows the caller writing both.
- **Two of the four views' columns are not what their own assertions expected.** `vw_tool_calls`
  projects the observation's *value*, not the step element, so `observation ->> 'output'` is
  NULL - a JSONB string has no key to index - and the read is `observation #>> '{}'`. The first
  draft of probe B asserted the wrong operator, and the failure message ("1=b_lookup->-,
  2=b_update->-") looked like a pairing bug rather than a projection one. Same family as the
  `count()` typo in the same file's §2: PostgreSQL reads `count()` as a parameterless aggregate
  and refuses it (`42601`), so the honest spelling in a hand-written view is `count(*)`.
- **A probe that sums a report view needs namespaced fixtures, not a filter.** The first draft
  filtered `vw_tool_performance` by `run_id`, which the view does not expose - it is aggregated
  by tenant and tool - so the assertion would have counted the fixtures `0013` and `0016` left
  behind. The fix is upstream of the assertion: every probe invents its own tool names
  (`c_lookup`, `b_update`) so the aggregate it reads is the one it caused. This is Obligations-
  0013's "assert per-subject, never totals", in a place where there is no subject id to assert on.
- **A `RAISE` whose message is split across lines counts its placeholders by eye, and miscounts
  one.** `psql` reported "too many parameters specified for RAISE" pointing at a line forty
  distant from the statement at fault: the concatenation read as one string with one `%` and the
  argument list had two. Counting placeholders per `RAISE` before rehearsing is cheap; the
  compiler's idea of a statement boundary is not where the error is.
- **`pg_depend` will not tell you which views read a table.** Querying it with
  `classid='pg_class'` returned zero rows for a base table four views depend on: a view's
  dependency on a column is recorded against `pg_rewrite` with `refobjid`/`refobjsubid`. The
  dependency census that Obligations-0017's first bullet rests on came from joining
  `pg_depend` to `pg_rewrite` to `pg_class`, and it reports each view once per *column*, which is
  why the raw list looks longer than four.
- **`SET LOCAL ROLE` is the same backend, and the second seat needs its own reset.** Probe I
  runs the application seat and the audit seat in one block; a `RESET ROLE` placed between two
  assertions rather than after them silently downgrades the next one to the owner's view of the
  data - which passes every isolation assertion in the file. The shape that survives reading is
  role, set tenant, assert, assert, reset - and the second assertion is the one that actually
  tests the wall, because seeing your own rows is what a broken policy also does.
- **Markers can be inert, and the harness cannot tell you.** `closed()` has one branch per
  `code:*` marker and a catch-all that answers "not closed", so a row mapped to a marker nobody
  wrote a branch for reads KNOWN-OPEN forever: the right verdict for the wrong reason, in a
  column labelled with a migration that does not exist. `code:vw_customers_filter` is that case
  today, and it is why the marker table now carries a "Watched by" column rather than just a
  meaning.
- **Two more views live only in the superseded SQL.** The same census found
  `vw_entity_contact_details` and `vw_communication_timeline` promised in `AGENTS.md`'s view table
  and defined only in `archive/blueprint/08_create_views.sql` - so `AGENTS.md` named five views the
  catalog did not have, 0017 creates three of them, and the other two are nobody's finding yet.
  Every column either one reads exists in `public` (measured, including
  `entities.industry`/`website`/`legal_name` and `entity_relationships.start_date`/`end_date`), so
  a port is the faithful-recreation job 0009 already knows how to do rather than a schema change.
  The count is in T4, where the rest of the doc-vs-catalog class lives.

## Found while building 0016

- **One finding was visible in another view first.** The idempotency register printed
  `add_customer` twice, both rows UNGUARDED, because it emits one row per function object and
  the catalog held two objects. Nobody reading 4.4's call failure would have looked there;
  nobody reading the register would have called it a fork. The general lesson is the one B25
  already states for trigger bodies: a census that counts *objects* will show duplication that
  a census of *names* hides.
- **The claim guards a race, and that was not what 0011 claimed it for.** Two backends, one
  key, one second apart: the second call's `idempotency_claim` INSERT waited on the arbiter's
  unique index instead of reporting a conflict, and when it resumed the first had committed
  `status='completed'`, so it was answered from the cache - the same entity_id, one customer.
  ADR-005 and 0011 both describe the table as an answer to *retries*; the concurrency property
  follows from the same index and had never been measured here until now.
- **A fix in one finding can turn another finding's probe from inert to live.** `5_1`'s 2^31
  case has been printing INFO for eleven migrations - honestly, because a call that goes
  ambiguous proves nothing about key width. The moment one head answered 10 positional
  arguments, the same block became an assertion that 0005's OUT widening really reaches callers
  (`entity_id=2147483648` came back). Every test that steps around an open finding is a test
  waiting for its author to close it, and the INFO line was what made that findable.
- **A parameter's domain is invisible to the machinery that publishes domains.** 0007's
  `vw_domain_vocabulary` answers "what does this column accept" for every typed column in the
  schema, and probe 5.9 asks whether anyone can read the answer. `p_entity_type`'s values are
  in no column: `entities.entity_type` is a different axis (customer/prospect/vendor/employee),
  and the only two places `individual`/`business` are written down are two IF arms and one
  Python file. So 5.9's "0 columns with no published answer" is true of columns and says
  nothing about the arguments a function takes, which is where a fall-through can turn a typo
  into a person. The guard is a literal pair with a comment saying it is a projection of
  nothing.
- **The re-wrap is a habit, not an incident.** Three migrations, three bodies ending in
  `WHEN OTHERS` returning a row built from `SQLERRM` - `execute_inventory_movement` (0014),
  `reserve_inventory_for_order` (0015), `add_customer` (0016). Each made a constraint violation
  legible only as prose, and each was written by someone following the file next door. What
  finally differs here is that the refusals are explicit about being answers and the handler is
  explicit about not being one.
- **A probe that counts trail rows by a value it invented fails on the second replay, not the
  first.** Probe K asked how many `audit_log` rows carry `new_values->>'name' = 'Shared Email'`
  and expected 1. On a rehearsal clone - a database where 0016 had already been applied once,
  which is what a clone of live is - the name matched both the ancestor's INSERT and this
  run's, and the count was 2. Obligations-0013's rule ("assert per-subject counts, never
  totals") was followed and was still not enough: the subject has to be the row's **identity**,
  which cannot repeat, not an attribute the probe chose. Keyed on
  `new_values->>'id'`, the same assertion is replay-safe, and the exception message now says
  which row it could not find rather than which role it blamed.
- **Two probes failed for the right reason and the wrong cause.** Probe D's first draft made
  the keyed call *before* creating the duplicate, so it was refused by nothing and its
  assertion could not have fired; probe L expected the contact-point rule and got the
  name-first rule, because the surviving head's checks are a chain and the earlier link won.
  Both are 0015's lesson again - arrange the state so the assertion can only fire for the
  reason it claims to test - and both were caught by running the probes rather than by reading
  them.

## Found while building 0015

- **4.3's diagnosis was wrong about which element broke, and right about the crash.** A bare
  string literal in a `RETURN QUERY` list is `unknown`-typed, and plpgsql will not coerce that
  into a `character varying` OUT column — 42804. `SQLERRM` in a `text` position is fine. So
  the review's "the handler's third element is text where the ordering doesn't align" named
  the correct SQLSTATE for the wrong column, and the consequence was wider than the handler:
  every `RETURN QUERY` in the body died, so a *successful* reservation could not be reported
  either. Measured three ways on a clone: uncast literal 42804, same literal with `::varchar`
  succeeds, `SQLERRM::text` alone in the text position is not the problem.
- **The finding about the read was "arbitrary single row"; measured, it is two defects that
  happen to point at the same statement.** `SELECT col INTO var` over several rows raises
  nothing — plpgsql keeps whichever row the scan returns first and discards the rest (two bins
  of 10 and 0: the guard printed "Only 0 available, requested 5"). And when *no* row matches,
  the variable is untouched, so `IF v_available < p_quantity` compares NULL and evaluates
  UNKNOWN, which is not false: the guard steps aside and the function reserves against nothing.
  With only the return-path fix applied, a call for an item with zero on-hand rows returned
  `SUCCESS` and left a commitment behind (measured: 1 reservation row, 0 on-hand rows). The
  write half is worse than the review said too — every matched row deducted by the full
  quantity, which `4_6` had already measured at 2 of 2 bins.
- **The reservation's movement INSERT had a second wall behind 4.1's, and NOT NULL was hiding
  it.** `p_order_type` was passed into `movements.reference_type`, and the two published
  vocabularies overlap in one member (TRANSFER): `SALES`, `PURCHASE`, `WORK` and `STOCK` are
  all legal order types and all illegal reference types. The 23502 on `unit_of_measure` fires
  first, so no call had ever reached the CHECK. Same shape as 0014's `4_1` fixture, one
  migration later — fix the visible violation and the invisible one becomes the failure.
- **A structural check on a function body reads its comments as code.** Probe J was going to
  assert "no `ERROR` status exists" with `pg_get_functiondef(...) LIKE '%''ERROR''%'`, and it
  failed — on this file's own explanatory comment about why there is no ERROR status, because
  `pg_get_functiondef` returns the body including its comments. 0011's register carries the
  same warning about classifying bodies by text; the lesson repeats one migration later,
  against an author who had just read it. Replaced with the behavioural form.
- **A `RAISE EXCEPTION` inside a block whose own `WHEN OTHERS` watches a different SQLSTATE
  reports its own failure as the finding.** Probe J's first rehearsal failed with "answered
  P0001" — its own assertion's P0001, caught by its own handler, after the exception it was
  checking for had been correctly observed. The assertions now sit outside the guarded blocks,
  against a sentinel set in the handler.
- **Three catalog facts that the obvious syntax gets wrong.** `allowed_values` in
  `vw_domain_vocabulary` is `text[]`, so `x = ANY ((SELECT allowed_values ...))` fails with
  "operator does not exist: character varying = text[]" and needs `= ANY (SELECT unnest(...))`
  — while the scalar-subquery form is correct inside `unnest()` itself, which is how the same
  probe gets its loop values. `max(uuid)` does not exist in this build (uuid ordering is 18),
  so the single-value read is `(array_agg(reservation_id))[1]`. And a `FOR r IN SELECT ...`
  target must be a `record` declared in the block that runs the loop — a name reused from an
  outer block's different shape is a compile error at execution time.
- **Using `regexp_matches` to count occurrences of a needle that contains parentheses counts
  zero.** The outbound arm of the view transform was guarded by
  `count(*) FROM regexp_matches(def, '...abs(quantity)...', 'g')` and reported 0 matches while
  `replace()` found and replaced the identical text: to a regex, `(quantity)` is a capturing
  group. The guard contradicted the operation it guarded, and the migration refused to run on
  a definition it could have fixed. Substring occurrence is
  `array_length(string_to_array(text, needle), 1) - 1`, which is a literal question and gets a
  literal answer.
- **`FOR UPDATE` cannot be combined with aggregates, and that constraint is what forced the
  plan/apply split.** Summing availability across bins needs an aggregate; locking the rows in
  drain order needs `FOR UPDATE`; PostgreSQL refuses the pair (42809). So the helper locks and
  plans in a loop and the callers sum the plan — which turned out to be the right shape anyway,
  because a plan that writes nothing is how a refusal leaves no trace.
- **Checking what a view returns meant reading `pg_attribute`, and that exposed a second
  problem.** `archive/blueprint/docs/views.md` - the page `AGENTS.md` sends agents to for the complete
  view reference - documented `vw_item_movement_summary` with five columns (`sku`, `item_name`,
  `total_receipts`, `total_shipments`, `net_change`) that the view has never had; the live one
  has nine. `docs/database/README_VIEWS.md` repeats the same five. That page's example queries
  also carry the `agent_first_erp_crm.` qualifier 102 times across `archive/blueprint/**/*.md`,
  which is 3.1's twin in prose rather than Python and is not counted by `code:tool_prefix` (33, `.py`
  only). Fixed here for the one view this migration changed; the class of it is T4. (100 of the
  102 by 0017, which rewrote four of this page's example queries in the form that actually
  resolves.)
- **A probe that sets up a boundary has to exhaust the alternative, not just arrange it.**
  Probe L first reserved 10 of a two-bin warehouse holding 20, then asserted that issuing 5
  failed — and the issue succeeded, because the other bin still had units and the pick was
  entitled to drain it. The failure was the probe's, not the function's, and it is the same
  error 4_6's simulation arm made in the other direction (restating the new `WHERE` inside the
  test, which passes forever no matter what the code does). Both were replaced by observable
  consequences at the door.

## Found while building 0014

- **The 4.4 failure mode reappeared inside 0014's own rehearsal.** `CREATE OR REPLACE
  FUNCTION` with a CHANGED parameter list does not replace - it creates a second overload,
  and every call to the name went ambiguous on the spot ("function ... is not unique" -
  4.4's own SQLSTATE, 42725, emitted by the fix's own probe). A rewrite that adds a
  parameter is a DROP by full signature plus a CREATE; probe I now asserts the count of
  callable heads from pg_proc so the lesson cannot rot into folklore.
- **`ON CONFLICT DO UPDATE` evaluates the CHECK against the tentative INSERT-side row.**
  4.3's average-cost divisor cannot reach zero through a RECEIPT, because reaching it needs
  a negative quantity, and the negative quantity fails `chk_quantities_non_negative` on the
  way IN, before the arbiter ever resolves. The review's claim was reasoned from the
  constraint list and was, in the only direction that mattered, wrong; the failing-row
  DETAIL `(-120, -120, ...)` settled it. Guard kept as a tripwire, decrease routed through
  ADJUSTMENT where it always should have been.
- **A `WHEN` naming a condition that matches nothing catches nothing, silently.**
  `WHEN cardinality_violation` caught neither 2201E nor 22012 in this build (measured: both
  escaped) - the same family as B12's always-fail predicate, in the other direction: an
  exception handler whose arms name the wrong SQLSTATE is a migration that reports its own
  probes as uncaught failures rather than passes. Predefined condition names are not a
  complete cover of the SQLSTATE space; when in doubt, `WHEN SQLSTATE '22023'` or OTHERS
  plus a SQLSTATE check, and probe the handler the way 0005 probes a constraint.
- **A default on a master-data column can make a refusal branch reachable only through the
  door you did not think of.** The missing-unit 22023 fires for a NULL `base_unit_of_measure`
  - which cannot exist (0007 made it NOT NULL with a default) - so its only live trigger is
  a nonexistent item, which probe B now walks through deliberately. The function body keeps
  a line no valid data reaches; the probe keeps the claim testable; the comment keeps the
  three facts together.
- **4.1's test fixture silently violated 0007's vocabulary** (`reference_type
  'purchase_order'`) and could not be caught doing it, because NOT NULL is checked before
  any CHECK in the same statement, and NOT NULL was the finding under test. Fixing the
  first violation is what made the second one exist - the clearest instance yet of why the
  harness re-runs every mapped phrase against both pre- and post-fix databases, and why
  0007's note says an undeclared vocabulary "cannot be checked for a missing member."
- **The idempotency register had been lying about the movement path since 0004.** The
  ladder's `on +conflict` test classes an ACCUMULATING upsert as "pattern 1 - a replay is
  answered from the cache", and every replay of a receipt doubled stock under a green
  register row. Body-text classification cannot see semantics; the fix Obligations-0011
  already named (a claim at the function head) makes the verdict true instead of making
  the view clever.

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
  values are active / inactive / blacklisted (`docs/database/schema.md`, the `### 2. entities` block's `status` comment). No SQL, function or
  tool in the repository writes `'follow-up'` to anything — yet
  `archive/blueprint/tools/followup_customers.py:36` tells the agent that a customer is surfaced because
  "their status is marked as 'follow-up'". So the most prominent reason the tool advertises is
  unreachable by design, and 5.9 is the reason it was invisible: an undeclared vocabulary cannot
  be checked for a missing member. **Assigned to `0014`**, which owns the movement and follow-up
  contracts; `vw_domain_vocabulary` admits the value today so the gap is a *missing writer* rather
  than a schema that could never hold the state, and `db/tests/5_9_domain_values.sql` block 4
  proves the reader works given the value.
- **Two documentation files disagree about `movement_type`, in both case and membership.**
  (`docs/database/schema.md`, the `### 13. inventory_movements` block) says `'RECEIPT', 'ISSUE', 'TRANSFER', 'ADJUSTMENT', 'RESERVATION'`;
  `archive/blueprint/docs/schema_reference.md:299` says `'receipt', 'shipment', 'transfer', 'adjustment'`.
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
- **`public` contains 194 extension-owned functions and 4 aggregates** — 198 extension-owned
  *procs* total, and the aggregates are `avg` and `sum` over `vector` and `halfvec`, from pgvector
  (there is no extension-owned `array_agg`; the measured split is 194/4/0 over `prokind` f/a/p).
  `pg_get_functiondef()` **raises** on an aggregate, so an unfiltered
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

## The tracked tasks

`T1`–`T4` are the four jobs the migrations above keep deferring, and they are named here because they
were cited from `0017`'s obligations, from `0016`'s, and from `archive/blueprint/docs/views.md` without any of
those pages saying where the list lived — a dangling pointer of exactly the class T4 is about. Each is
a *task*, not a migration: none of them changes a table, which is why no number in the ledger is free
for them.

| Task | Job | Where it stands |
|---|---|---|
| **T1** | Sweep the code path off the twin schema, and delete what the sweep proves is dead | Done. `archive/blueprint/**/*.py` went from 33 qualified references to 0, measured by `code:tool_prefix`. The sweep is also what found the two runtime-DDL modules 0017 describes: `archive/blueprint/tools/tool_logger.py` no longer creates `agent_tool_calls` (it accumulates per run and `interaction_logger.py` writes the one row), and `archive/blueprint/postgres_callback.py` no longer creates `agent_interactions`. Both had been failing at runtime, silently, which is why 0017 could say "never imported" and the sentence stayed true |
| **T2** | Decide whether `entity_type` gets a writer, and with it `vw_customers`' filter | Open, and honestly so: `code:vw_customers_filter` has no `closed()` branch, so the harness prints the row KNOWN-OPEN rather than green |
| **T3** | Put the two-backend idempotency assertion in CI | Open. The measurement that closed 0011's question came from a shell one-liner, so nothing here notices if the arbiter stops serialising; it needs two processes and a runner, which a migration file cannot provide |
| **T4** | Check every list in the documentation against the catalog, and mark the places where a doc is describing an object it does not have | Done for the class, watched for the recurrence. `code:agent_docs_match_surface` runs `scripts/docs/check_agent_docs.sh`, which resolves every advertised `vw_*` name against `pg_class`, compares all seventeen column lists in `archive/blueprint/docs/views.md` against `pg_attribute`, fails on a doc row that promises a view nobody created, and fails on the inverse too — a view the docs disclaim that some later migration added. The lists were regenerated by `scripts/docs/regen_view_columns.py`: 117 columns the page had never
named, and nine it had invented — `bot_id` on `vw_agent_activity_summary`, `embedding` on
`vw_customers`, `communication_id` on `vw_communication_thread`, `item_name` and `shortage_amount` on
the two stock views, and four (`vw_pending_followups`' `communication_type`, `follow_up_action`,
`follow_up_date` and `summary`) describing the shape of a `communications` row when the view reads the
`followups` table. What no check can do is tell whether a **description** still matches what a column
means; the check proves the name exists |

## Tracked as code, not migrations

Schema correctness is only half of findings 3.1 and 4.5. These are watched by
`_common.sh`'s `closed()`, which both harnesses call, so neither can disagree about what
green means — and a marker `closed()` has no branch for is *inert*: `code:*` falls through to
"not closed", the row prints KNOWN-OPEN forever, and nobody is told the grep was never written.
The middle column is therefore which of these is actually watched.

| Marker | Watched by | Meaning |
|---|---|---|
| `code:tool_prefix` | a grep of `archive/blueprint/**/*.py` for `agent_first_erp_crm.` | 0, swept in this session from 33. The same grep over all of `archive/blueprint/` found 267 at 0017: 134 in the superseded `.sql` copies §3.3 lists and 100 in documentation examples; the examples are swept too, and `docs-check: historical-record` exempts the two files whose whole content is quoting the state the review found. The scope stays `.py` because a marker over 267 would be green only after a job no one has scheduled |
| `code:cs_writes_through_doors` | a grep of `agents/customer_service`, `agents/jada` and `archive/blueprint/` for `INSERT INTO [public.\|agent_first_erp_crm.]communications` | 0021's rule, watched where it could be broken: an agent recording an interaction calls `add_communication`, and no caller carries its own INSERT. **The regex grew the qualified form for a reason**: with only `[public.]` allowed, this marker reported green while four blueprint tools were INSERTing into `agent_first_erp_crm.communications` — a statement that cannot run, so nothing it guarded looked broken. Sweeping the `.py` files made all four visible at once, and two of them (`add_customer.py`, `update_customer.py`) wrote `communication_type = 'system'`, a value the column's CHECK list has never contained, which meant the INSERT raised 23514 and the rollback undid the customer creation the note was describing. `code:*` markers that only notice working code are how a rule dies |
| `code:agent_docs_match_surface` | `scripts/docs/check_agent_docs.sh` | The documentation claim, watched by the script that can check it: every tool the Go backend registers is named in `agents/customer_service/README.md`, every key the compose file sets or the code reads appears in an environment table, every view the docs claim exists is in the catalog, every migration is a row in the ledger, and no live doc tells a caller to qualify to the twin schema. Wired into `scripts/db/test-functions.sh` through this marker, so a doc that drifts from the code goes on the same report as a constraint that drifts from the schema |
| `code:vw_customers_filter` | **nothing yet** | `entity_type` filter decided between `= 'customer'` and `IN ('customer','prospect')`. One `4_5` row is mapped here because the decision is embedded in a fixture that has been failing since 0007 — `update_customer` cannot make a customer a prospect, because `prospect` is an `entity_type` value and no function in the schema writes that column at all. T2 decides the question; whoever lands it adds the branch here, or the row stays honestly open |
