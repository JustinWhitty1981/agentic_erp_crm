# Database Review — Agent First ERP/CRM

Deep review of the data model: structures, keys, relationships, constraints, indexes,
functions, views — assessed against what this system needs to become (SAP / Salesforce /
Oracle / JDE class), not against what the DDL currently claims.

---

## 1. Method

### 1.1 Environment

Native **PostgreSQL 17** with **pgvector** (`postgresql-17-pgvector`) and `uuid-ossp`,
installed and loaded locally. The Docker route in the repo's compose files was unusable in
this sandbox (netlink/overlayfs permission failures), so the schemas were loaded natively.

Three databases were built to separate the questions:

| DB | Loaded from | Objects created |
| --- | --- | --- |
| `erp` | `docs/database/agent_first_erp_crm_schema.sql` (1947 lines) | 18 tables, 12 views, 0 errors |
| `erp2` | `blueprint/agent_swarm_schema.sql` (1417 lines) + `10_audit_log` + `11_interaction_logging` + `09_add_update_customer_functions` + `08_create_views` | 18 tables, 15 views, 0 errors |
| `mftest2` | the **documented** `make db-migrate` sequence, replayed verbatim | **1 table** |

### 1.2 What was executed vs. read

Structural facts (tables, columns, key types, FK count and delete rules, index inventory,
duplicate-index detection, triggers, functions, views, RLS flags, enum presence, tenancy
columns, sequence ceilings) come from **live `pg_catalog` / `information_schema` queries**
against the loaded databases — not from grepping SQL files. File grep was used only to
locate DDL line numbers and to trace how the Python tools call the database.

Functional facts were established by **calling the functions**, wrapped in `DO` blocks with
`EXCEPTION WHEN OTHERS THEN RAISE NOTICE ... SQLSTATE`, so each failure is reported with its
real error code rather than inferred from reading a body. Those quoted SQLSTATEs are in §4.

Two verification traps were hit and are worth recording, because both produced **false
passes** before they were caught:

- **Permissions.** The repo's `.sql` files are mode `0640`, so a `psql` running as the
  `postgres` role cannot read them. Early loads reported "0 errors" while creating nothing:
  `psql: error: ... Permission denied`. Files had to be staged world-readable. Any rerun of
  this review will hit the same thing.
- **`ON_ERROR_STOP`.** Off by default, so a migration file that dies on line 25 exits 0 and
  the loop moves on. Setting `-v ON_ERROR_STOP=1` is what exposed §3.1.

### 1.3 Baseline counts

18 tables · 30 foreign keys · 90 indexes (88 btree, 1 gin, 1 ivfflat) · 12 views ·
4 domain functions · 3 triggers · **0 enums** · **0 CHECK'd domain columns on the 31
status/type/role columns examined**.

---
## 2. Assessment against enterprise standards

Measured against the reference architectures of SAP S/4HANA, Salesforce, Oracle
E-Business Suite and JD Edwards. The question for each dimension is: "could this carry
multi-customer, multi-entity, audit-regulated volume?"

| Dimension | Reference expectation | This schema | Verdict |
| --- | --- | --- | --- |
| Surrogate keys | single consistent strategy | 12 UUID + 4 integer + 2 bigint | **Fail** |
| Multi-tenancy | tenant/company key on every row, leading every index | **0 tenancy columns in 18 tables** | **Fail** |
| Legal entity / org model | company, division, business-unit hierarchy | warehouses self-FK only; no org tree | **Fail** |
| Identity / principals | users, roles, permissions as tables; actor columns FK'd | no `users`/`principals` in canonical schema; 13 actor columns are free text | **Fail** |
| Row-level security | RLS or VCS on all business tables, enforced | enabled on **2 of 18**, `relforcerowsecurity = false`, GUC never set by any code | **Fail** |
| Audit trail | immutable, complete, tamper-evident | only aggregate `audit_summary`; real `audit_log` exists solely in the vestigial schema | **Fail** |
| Domain / master data | constrained code tables or enums | **0 enums, 31 unconstrained varchar domains** | **Fail** |
| Referential integrity | FK on every relationship incl. polymorphic | 30 FKs / 18 tables (~1.7); `reference_type`+`reference_id` unenforceable | Weak |
| Idempotency (ADR-005) | `idempotency_keys` table + version guards | **absent in both databases**; `version` columns never incremented | **Fail** |
| Money & units | minor integer units or `numeric(19,4)`, currency FK, rate history | `numeric(12,4)`, `char(3)` with no `currencies` table | Fail |
| Temporal / erasure | bitemporal or soft delete for GDPR/CCPA | `is_active` on 5 inventory tables only; none on contacts/addresses/communications | Fail |
| Scale mechanics | partition + retention on append-only data | none; no BRIN on time columns | Fail |
| Index discipline | index all FK join and search paths | `entities`/`contacts`: **PK only**; 8 duplicated index sets | **Fail** |
| Vector search | hnsw, indexed on every embedding | `ivfflat lists=100`; 2 of 3 embedding columns unindexed | Weak |
| Migration discipline | versioned, ordered, tooling-managed | 3 forked directories, no `CREATE SCHEMA`, `make db-migrate` fails | **Fail** |
| Physical model | normalised, single home per table | 18+8 tables, **same names, two schemas, zero cross-schema FKs** | **Fail** |

**Relational hygiene is genuinely good** — every table has a PK, all natural codes
(`sku`, `warehouse_code`, `category_code`, `location_code`) are unique, movements are a
proper append-only ledger with a `transaction_id`, pgvector is integrated, and views are
explicit-column rather than `SELECT *`. The failures are not sloppiness in the DDL; they
are the absence of the layers (tenancy, identity, audit, domain control) that separate a
single-tenant demo model from an enterprise product, compounded by a build path that does
not currently work.

Two findings are structural rather than additive, and they subsume several others: the
**second-schema split** (§3.1) and the **broken migration path** (§3.2). Until both are
resolved, effort spent hardening `public` does not reach production behaviour, because
the running tools never touch it.

---
## 3. Findings — Critical (blocking)

### 3.1 The application and the canonical schema are two different databases

Running the full documented sequence produces **two disconnected copies of the same model
inside one cluster**. The second is created by `setup_sample_data.sql:5`:

```sql
CREATE SCHEMA IF NOT EXISTS agent_first_erp_crm;
```

followed by `CREATE TABLE IF NOT EXISTS agent_first_erp_crm.entities` (line 8), `.contacts`
(23), `.entity_relationships` (38), `.addresses` (55), `.communications` (73), `.tickets`
(100), `.agents` (115), `.audit_log` (126).

Verified against `erp2` after loading everything:

```
nspname              | tbls                                                              | count
agent_first_erp_crm  | addresses, agents, audit_log, communications, contacts, entities, | 8
                     | entity_relationships, tickets                                     |
public               | _schema_graph, addresses, agent_interactions, audit_summary,      | 18
                     | bot_actions, communications, contacts, entities, ... warehouses |
```

Column divergence for the shared tables, measured live:

```
table_name           | public_cols | schema_cols
communications       |     27      |     19
addresses            |     11      |     11
contacts             |     11      |     11
entities             |     11      |     11
entity_relationships |      9      |      9
```

**All 9 blueprint tools hardcode the vestigial prefix** (`grep -rl 'agent_first_erp_crm\.'
blueprint/tools/*.py` → 9 files; `tool_logger.py` alone → 5 refs). Reference counts:

```
7  agent_first_erp_crm.communications
5  agent_first_erp_crm.agent_tool_calls
3  agent_first_erp_crm.vw_customers
3  agent_first_erp_crm.entities
1  agent_first_erp_crm.add_customer   (+ update_customer, get_followup_customers, contacts,
                                        entity_relationships, vw_recent_communications,
                                        vw_entity_communication_stats)
```

Catalog check for cross-schema edges: **none**. Every `public` FK points at a `public`
target, so the twins are independent — writes to one are invisible to the other.

Consequences:

- The hardened 18-table model is **bypassed by the running application**. Index, constraint,
  and RLS work done there does not change production behaviour.
- The older twin resurrects the design the canonical schema replaced: `tickets` (absent from
  both canonical schemas), `agents` (the only principal registry anywhere), `audit_log`.
- This is the most plausible mechanical explanation for ADR-005's observed symptom —
  "duplicate records in staging" (`ADR-005:19`) — a retried write landing in a schema whose
  uniqueness the other copy's constraints don't police.

**Severity: highest in this review.** It is a decision, not a fix, and §5 P0 must settle it
before P1/P2 work is worth scheduling.

### 3.2 The documented setup path builds 1 of 18 tables

`Makefile:47-54` (`make db-migrate`) is the sanctioned way to create the database. Replayed
verbatim into an empty cluster with `ON_ERROR_STOP=1`:

```
agent_first_erp_crm_schema.sql  -> FILE DOES NOT EXIST (fatal)
08_create_views.sql             -> ERROR: relation "agent_first_erp_crm.entities" does not exist
09_customer_functions.sql       -> ERROR: schema "agent_first_erp_crm" does not exist
10_audit_log.sql                -> ERROR: schema "agent_first_erp_crm" does not exist
11_interaction_logging.sql      -> OK
```

Objects created: **1**.

Two independent causes:

1. `scripts/database/agent_first_erp_crm_schema.sql` — the file line 49 loads — **is not in
   the repo**. `scripts/database/` holds `agent_swarm_schema.sql` instead; the canonical
   schema lives only at `docs/database/agent_first_erp_crm_schema.sql`.
2. Lines 50-53 reference `agent_first_erp_crm.*`, but that schema is created only by
   `setup_sample_data.sql` — invoked *afterwards* by `make db-seed` (`Makefile:59`).
   Chicken-and-egg: migrate can never pass before seed, and seed recreates §3.1's fork.

No developer following the README can produce a working database, and nothing in CI catches
it (§3.3).

### 3.3 No migration tooling; three forked sources of truth

`blueprint/agent_swarm_schema.sql` and `scripts/database/agent_swarm_schema.sql` are
byte-identical (checksum `22848d5158cf9377…`, 1417 lines) and are an **older** variant of
`docs/database/agent_first_erp_crm_schema.sql` (1947 lines) — missing `agent_interactions`.
5 of 8 migration files exist identically in three directories.

There is no `schema_migrations` table and no versioning, so the installed set is
order-dependent and nondeterministic. Observable drift from the two load orders:

```
views in erp (docs)   : 12
views in erp2 (bp)    : 15  (+ vw_failed_interactions, vw_recent_interactions,
                              vw_tool_performance)
```

`vw_customers` also differs **semantically** by source:
`WHERE e.entity_type = 'customer'` (docs) vs `WHERE e.entity_type IN ('customer','prospect')`
(`blueprint/08_create_views.sql:25`) — same name, different population.

---
## 4. Findings — High (proven by execution)

All four data-writing functions fail when actually called. Identical results in `erp` and
`erp2`, so this is not a load-order artifact.

### 4.1 `execute_inventory_movement` cannot insert a movement

Its signature accepts 10 parameters and **never mentions a unit of measure**, but
`inventory_movements.unit_of_measure` is `varchar(50) NOT NULL` with no default
(confirmed in both DBs: `is_nullable = NO`, `column_default = NULL`).

Executed:

```
NOTICE: SETUP OK: wh=d20ba637-... item=0b6553ed-...
NOTICE: RECEIPT #1 FAILED: SQLSTATE=P0001  Movement failed: null value in column
        "unit_of_measure" of relation "inventory_movements" violates not-null constraint
NOTICE: on_hand rows after #1: 0
NOTICE: RECEIPT #2 FAILED: Movement failed: null value in column "unit_of_measure" ...
```

The wrapper's `EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'Movement failed: %', SQLERRM`
re-wraps as `P0001`, discarding the original `23502`. Every call dies on statement one.

### 4.2 Its `ON CONFLICT` target does not exist

Isolating just the upsert:

```
NOTICE: ON CONFLICT TEST -> SQLSTATE=42P10  there is no unique or exclusion constraint
        matching the ON CONFLICT specification
```

Index inventory for `inventory_on_hand` — the only unique one is the PK:

```
idx_on_hand_available   f  {item_id, quantity_available}
idx_on_hand_expiry      f  {expiry_date}
idx_on_hand_item        f  {item_id}
idx_on_hand_location    f  {location_id}
idx_on_hand_low_stock   f  {item_id, quantity_available}
idx_on_hand_warehouse   f  {warehouse_id}
inventory_on_hand_pkey  t  {on_hand_id}
```

The function targets `(item_id, warehouse_id, COALESCE(location_id,...), COALESCE(lot_number,''))`
(`agent_swarm_schema.sql:209` region; same body in `erp`). Two distinct problems:

- **Runtime:** the upsert is unbuildable, so fixing 4.1 immediately surfaces 4.2.
- **Design:** on-hand has **no row identity**. Nothing prevents N rows for the same
  item/warehouse/lot/location, which makes every balance query ambiguous and the ledger
  unreconcilable. This is the core invariant of an inventory module.

### 4.3 `reserve_inventory_for_order` crashes inside its own error handler

```
NOTICE: setup ok
ERROR:  structure of query does not match function result type
CONTEXT: SQL statement "SELECT NULL::UUID, 'ERROR', SQLERRM"
```

The handler's third element is `text` where `RETURNS TABLE(..., message text)` plus
`status varchar` ordering doesn't align — so **failures abort the transaction instead of
returning the documented `ERROR` row**. Callers coding against `status='INSUFFICIENT
STOCK'` get an exception. Compounding logic bugs in the same body:

- Availability read with **no `SELECT ... FOR UPDATE`** → classic TOCTRU oversell under
  concurrent agent calls, the exact scenario ADR-005 was written for.
- Filters on-hand by `item_id + warehouse_id` while **ignoring `location_id`**, so with
  multiple bins it updates an arbitrary single row.
- Inserts a `RESERVATION` movement row → re-triggers 4.1, so the reservation path fails
  even once 4.1/4.2 are fixed for receipts.

In 4.1's ISSUE/ADJUSTMENT branch, `to_warehouse_id` (NOT NULL) is populated from the same
parameter that is NULL for an issue, and the average-cost divisor
`quantity_on_hand + p_quantity` can reach zero since `chk_quantity_nonzero` permits
negative quantities. `warehouses.allows_negative` is **defined but referenced by no check,
trigger, or function** — dead config.

### 4.4 `add_customer` is ambiguous — cannot be called

Two overloads exist and every parameter is defaultable, so Postgres cannot resolve:

```
add_customer(10 positional) -> FAILED: function add_customer(... x10) is not unique
add_customer(4 positional)  -> dup-email path -> function add_customer(x4) is not unique
```

Signatures from the catalog:

```
p_first_name, p_last_name, p_email, p_phone, p_street, p_city, p_state, p_postal_code,
p_country DEFAULT 'US', p_status DEFAULT 'active'                                    -- 10-arg
p_first_name, p_last_name, p_email, p_phone, p_street, ... p_status, p_entity_type,
p_organization_name, p_address_type, p_is_primary                                    -- 14-arg
```

### 4.5 Tools and schema disagree on name, arity, and location

`blueprint/tools/add_customer.py:136-143` issues:

```sql
SELECT * FROM agent_first_erp_crm.add_customer(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
```

Run against the canonical schema:

```
ERROR:  schema "agent_first_erp_crm" does not exist
```

Three independent mismatches in one statement: wrong schema (functions load into `public`),
wrong arity (14 vs the canonical 10-arg), and unpacking into `success, entity_id, contact_id,
message` where the canonical function returns a different shape. `customer_lookup.py:42`
queries `agent_first_erp_crm.vw_customers` — the view whose `entity_type` filter differs by
source file (§3.3). Also referenced but **created nowhere**: `agent_tool_calls`
(`count(*)` for `%tool_calls%` = 0 in both DBs) and `tickets`.

Note `add_customer` does correctly hardcode `entity_type='customer'`
(`09_add_update_customer_functions.sql:77-78`), so the view filter is consistent for rows it
creates — prospects arriving by any other route are invisible to the primary lookup view.

---
## 5. Findings — High (schema structure)

### 5.1 Split identity strategy across 18 tables

PK inventory from the catalog:

```
bigint serial : communications.id, followups.id
integer serial: addresses.id, contacts.id, entities.id, entity_relationships.id
uuid          : _schema_graph, agent_interactions, audit_summary, bot_actions,
                human_sessions, inventory_items, inventory_movements, inventory_on_hand,
                inventory_reservations, item_categories, locations, warehouses   (12)
```

Three strategies in one model. Every join from the CRM side (integer) into inventory or
telemetry (UUID) is a cross-type comparison, and the mixed types make the tenant-key and
partition work in §7 mechanically awkward.

### 5.2 `communications.parent_id` / `thread_root_id` are `integer` referencing a `bigint`

```
communications.id            | bigint
communications.parent_id     | integer
communications.thread_root_id| integer
```
DDL at `docs/database/agent_first_erp_crm_schema.sql:211-212,220`:

```sql
parent_id integer,
thread_root_id integer,
CONSTRAINT communications_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES communications (id)
```

It **loads and validates** because Postgres applies an implicit narrowing cast to the FK
column — so the defect is invisible at rest and in `pg_constraint`. Once `id` passes 2^31,
threading breaks: every new reply references a parent that no longer fits, while the table
itself keeps accepting inserts up to 9.2e18. A latent time bomb in the central CRM table.

`thread_root_id` is worse in kind: **no FK at all** (constraint count for that column = 0),
so the denormalised thread anchor can silently point at a nonexistent or wrong root, and
`idx_comms_thread_root` will happily serve those wrong rows.

### 5.3 Sequence ceilings on the four core CRM tables

```
integer  (2,147,483,647) : entities, contacts, addresses, entity_relationships
bigint   (9.2e18)        : communications, followups
```
`entities` and `contacts` are precisely the tables that scale with tenant count. At 2.1B
rows an `integer` PK is tight for a single tenant and untenable across many.

### 5.4 Random UUIDs as clustered keys in all 12 UUID tables

Every UUID PK defaults to `gen_random_uuid()` (v4). Insertion is therefore random into the
B-tree: page splits, low fill factor, and index bloat across all 12 tables — including the
append-only ledgers (`bot_actions`, `agent_interactions`, `inventory_movements`), which are
exactly the tables that grow. Time-ordered `uuid_generate_v1mc()` is installed and unused.

### 5.5 The CRM hot path has no indexes at all

```
tbl        | idx_ct | idxs
contacts   |   1    | contacts_pkey
entities   |   1    | entities_pkey
```

Zero coverage on `entities.name`, `entities.entity_type`, `entities.status`, `entities.tax_id`,
`contacts.email`, `contacts.phone`, `contacts.first_name/last_name`. Verified with a targeted
query for indexes touching those columns → `0 rows`.

Against this, the live application does:

- `customer_lookup.py:42` → `... FROM vw_customers WHERE name ILIKE %s LIMIT 5`
- `update_customer` → catalog confirms **`uses ILIKE`**
- `vw_customers` joins `entities` → `entity_relationships` → `contacts` and resolves the
  address with a **correlated `ORDER BY is_primary DESC, created_at LIMIT 1` subquery per row**

On any populated table this is a full scan of `entities`, a nested-loop per row against
`entity_relationships`, and one address subquery per output row — inside the most frequent
agent action in the system.

### 5.6 Eight duplicated index sets (write amplification, no read benefit)

```
tbl                | cols                        | dupes
communications     | {communication_type}        | idx_comm_type, idx_comms_type
communications     | {contact_id}                | idx_comm_contact, idx_comms_contact
communications     | {entity_id}                 | idx_comm_entity, idx_comms_entity
inventory_items    | {sku}                       | idx_inventory_items_sku, inventory_items_sku_key
item_categories    | {category_code}             | idx_categories_code, item_categories_category_code_key
locations          | {warehouse_id,location_code}| idx_locations_code, locations_warehouse_id_location_code_key
warehouses         | {warehouse_code}            | idx_warehouses_code, warehouses_warehouse_code_key
inventory_on_hand  | {item_id,quantity_available}| idx_on_hand_available, idx_on_hand_low_stock
```

The `idx_comm_*` vs `idx_comms_*` pairs are the fingerprint of two migration files both
having run — §3.1/§3.3 leaving residue in one database. `communications` carries
**16 indexes for 27 columns**, so every insert maintains 16 structures.

Also unindexed: `inventory_movements.transaction_id` — the dedup/lookup handle, defaulted per
row but with no index, so it cannot be queried.

### 5.7 RLS is decorative

```
rls_on | rls_forced | total
   2   |     0      |  18
```

```
policyname                    | tablename             | qual | with_check
agent_movement_view_policy    | inventory_movements  | true |
agent_movement_insert_policy  | inventory_movements  |      | performed_by = current_setting('app.current_agent', true)
agent_reservation_policy      | inventory_reservations|     | reserved_by = current_setting('app.current_agent', true)
```

Three independent reasons none of this works as a control:

1. `relforcerowsecurity = false` → the **table owner bypasses RLS entirely**.
2. 16 of 18 business tables have no policies at all.
3. **No code anywhere sets the GUC.** `grep -rn "current_agent" blueprint/ scripts/` matches
   only the two `CREATE POLICY` lines (`agent_swarm_schema.sql:710,847`).
   `current_setting(..., true)` returns NULL, so `performed_by = NULL` is never true: an
   honest non-owner role **cannot insert any movement**, while the owner path is unrestricted.
   The control fails in both directions.

### 5.8 Tenancy and identity are absent, not thin

- Tenancy columns (`tenant|org_id|company|account_id|legal_entity`) across all 18 tables:
  **0 rows returned.** Uniqueness is global, so a second customer cannot reuse warehouse
  code `MAIN`; there is no partition or shard key anywhere.
- No `users`, `principals`, `roles`, or `permissions` table in the canonical schema. The only
  registry anywhere is `agent_first_erp_crm.agents` — in the **vestigial** schema (§3.1):
  `id serial, name, role, api_key (UNIQUE), permissions jsonb, is_active`.
- Meanwhile **13 columns claim to name an actor, with 4 different types and no FK**:
  `agent_interactions.user_id/bot_id` (`text`), `audit_summary`/`bot_actions`/
  `human_sessions.user_id,bot_id`/`communications.agent_id` (`varchar(50)`),
  inventory `created_by`/`performed_by`/`reserved_by` (`varchar(100)`),
  `communications.human_agent_id` (`integer` — the **only** one with an FK, to `contacts`).

### 5.9 31 unconstrained domain columns, 0 enums

Status/type columns with no CHECK, no FK, and no enum — sample of 31:

`entities.entity_type`, `entities.status`, `contacts.status`, `communications.channel`,
`.communication_type`, `.direction`, `.outcome`, `.priority`, `.sentiment_label`,
`entity_relationships.role`, `addresses.address_type`, `followups.status`, `.priority`,
`human_sessions.session_status`, `.bot_type`, `bot_actions.action_type`,
`audit_summary` types, `inventory_items.product_type`, `.item_group`, `.cost_method`,
`.base_unit_of_measure`, `.weight_unit`, `.dimension_unit`, `inventory_movements.movement_type`,
`.reference_type`, `.unit_of_measure`, `inventory_reservations.order_type`,
`item_categories.default_cost_method`, `warehouses.warehouse_type`, `locations.location_type`.

Nothing distinguishes `active` / `Active` / `ACTIVE` / `cancelled` / `canceled`. ADR-005's own
prescription — `UPDATE … WHERE status <> new_status` (`ADR-005:35,44`) — is unsound on
free-text values, and `vw_customers` filters on `entity_type` values that no constraint
defines. For an ERP this is the master-data layer, and it is missing.

### 5.10 Six CASCADE deletes against business data

```
NO ACTION 20 | CASCADE 6 | SET NULL 3 | RESTRICT 1
CASCADE edges: inventory_on_hand->inventory_items, inventory_on_hand->warehouses,
               inventory_reservations->inventory_items, inventory_reservations->warehouses,
               locations->warehouses, bot_actions->human_sessions
```

Deleting a warehouse **silently destroys on-hand balances, reservations, and bin locations**.
Deleting an item destroys its stock rows. Stock quantities are never legitimately cascadeable;
these should be RESTRICT (or soft delete) with an explicit close-out path.

---
## 6. Findings — Medium

### 6.1 ADR-005 is adopted on paper and unimplemented in data

`ADR-005_idempotent_agent_operations.md` mandates idempotency for "all operations that
create, update, or delete persistent state" (line 23) and specifies an
`idempotency_keys` table (line 43) and optimistic version checks (lines 35, 44).

Measured: `SELECT count(*) FROM pg_class WHERE relname LIKE '%idempot%'` → **0 in both
databases**. Grep for `idempotency_key|request_id` across all SQL and Python (excluding the
imported `agents/` tree) → **no matches**. `inventory_items.version` and
`inventory_on_hand.version` exist, but a search of every function body for
`version = ... version + 1` or `NEW.version` returns **0 rows** — no trigger or function ever
increments either. `inventory_movements.transaction_id` is generated per row and unindexed,
so it cannot serve as a dedup key.

Net: retries are still unsafe, which is the exact defect ADR-005 was written to close.

### 6.2 Audit trail: aggregate only, mutable, and in the wrong schema

Canonical schema has `audit_summary` (a rollup keyed
`date, user_id, bot_id`) — no row-level history. The only complete log,
`agent_first_erp_crm.audit_log`, is created by `10_audit_log.sql:7` in the **vestigial**
schema (§3.1) and is therefore outside the model the rest of the schema constrains. No
immutability mechanism anywhere: no append-only grants, no hash chain, no trigger preventing
UPDATE/DELETE. For regulated ERP data this is the first thing an auditor asks for.

### 6.3 Timestamp hygiene is inconsistent

| table | created_at | updated_at | maintained by trigger |
| --- | --- | --- | --- |
| communications, human_sessions | yes | yes | **yes** |
| entities, contacts, followups, _schema_graph, inventory_items, item_categories, locations, warehouses | yes | yes | **no** |
| addresses, agent_interactions, audit_summary, bot_actions, entity_relationships | yes | no | — |

And the 3 triggers that do exist all fire on `UPDATE` only:

```
update_communications_updated_at | communications    | UPDATE  | BEFORE | ROW
update_human_sessions_updated_at | human_sessions    | UPDATE  | BEFORE | ROW
trg_on_hand_consistency          | inventory_on_hand | UD      | BEFORE | ROW
```

8 tables carry an `updated_at` that **silently goes stale** — so no incremental-sync or
change-data-capture query in this model is trustworthy. Separately, three tables have no
timestamp-shaped column at all (`inventory_movements` uses `performed_at`; `inventory_on_hand`
and `inventory_reservations` have no `created_at`), which removes the natural partition key
from two of the highest-growth tables.

### 6.4 Vector layer: half-indexed, wrong index type, wrong table

90 indexes: **88 btree, 1 gin, 1 ivfflat**.

```
idx_comms_embedding | ivfflat | communications   (1.6MB on an EMPTY table)
idx_actions         | gin     | agent_interactions
```

- `entities.embedding` and `contacts.embedding` exist but have **no vector index** — only 1
  of 3 embedding columns is searchable by ANN; the others force exhaustive scans.
- `ivfflat ... WITH (lists=100)` (`agent_swarm_schema.sql:209`) is tuned for ~1M rows;
  below that the lists are under-filled and recall degrades. `hnsw` is the appropriate
  default in current pgvector.
- `vector(1536)` is stored inline on `communications`, making the **largest object in the
  schema an index over an empty table**, and dragging ~6KB/row into every ordinary CRM scan.
- The `setup_sample_data.sql:236-239` block would create four more ivfflat indexes in the
  vestigial schema, including one on `agent_first_erp_crm.tickets` — a table that does not
  exist in either canonical schema.

### 6.5 Money, units, and currency

All quantities and amounts are `numeric(12,4)` (`unit_cost`, `average_cost`,
`standard_cost`, `last_cost`, all five `quantity_*` columns, `reserved_quantity`,
`shipped_quantity`); `total_cost` is `numeric(15,4)`. `currency_code char(3)` appears in
`inventory_items` and `inventory_movements` with **no `currencies` table and no FK**, and
there is no rate history anywhere — so cost valuation assumes one currency and one rate
forever. 9 of the 15 numeric columns mix money and physical quantity in the same precision,
which is the pattern that produces rounding losses in multi-UOM items
(`conversion_factor numeric(12,6)` exists but is unvalidated against `base_unit_of_measure`).

### 6.6 No partitioning, retention, or scale mechanics

Append-only tables that will dominate storage — `communications`, `agent_interactions`,
`bot_actions`, `audit_summary`, `inventory_movements` — have no partitioning, no retention
policy, and no BRIN on their time columns. `followups` and `human_sessions` carry status
lifecycles with no state-machine constraint. Deletion of aged data is not possible without
full-table `DELETE` and its vacuum consequences.

### 6.7 Views

12 in `erp`, 15 in `erp2` (§3.3). None uses `SELECT *` (verified by scanning every
`pg_get_viewdef` — good discipline), but `vw_customers` embeds the per-row correlated
address lookup described in §5.5, and `vw_primary_contact_communications`,
`vw_entity_communication_stats` depend on `entity_relationships.is_primary`, which has no
partial unique index enforcing one primary contact per entity despite
`idx_primary_contact` existing as a plain btree.

---

## 7. Prioritised remediation plan

Effort assumes one engineer familiar with Postgres; calendar is wall-clock for the DB work
alone, excluding app-tool changes.

### P0 — Make it buildable and unambiguous (block everything else)

| # | Action | Ref | Effort |
| --- | --- | --- | --- |
| 0.1 | **Decide the schema question.** Choose one home for objects. Recommended: keep `public`, delete the `agent_first_erp_crm` DDL block from `setup_sample_data.sql`, and remove the hardcoded prefix from the 9 tools via a per-connection `search_path` (one config line, no query rewrites). | §3.1 | 1-2 days + 1 day tools |
| 0.2 | Fix `make db-migrate`: correct the missing filename, add `CREATE SCHEMA`/`search_path` at the top, order the files so no step depends on seed, run with `ON_ERROR_STOP=1`. | §3.2 | 1 day |
| 0.3 | Collapse the three forked SQL directories into one migration set; delete the duplicates. | §3.3 | 1-2 days |
| 0.4 | Create `agent_tool_calls` and `tickets`, or delete the code paths that write them. | §4.5 | 1 day |

### P1 — Make the write paths correct

| # | Action | Ref | Effort |
| --- | --- | --- | --- |
| 1.1 | Add unique `(item_id, warehouse_id, location_id, lot_number)` on `inventory_on_hand` with NOT-NULL sentinels, making the upsert valid **and** giving stock rows an identity. | §4.2 | 1 day |
| 1.2 | Add a UOM parameter to `execute_inventory_movement`; fix the ISSUE branch's warehouse columns; guard the average-cost divide; stop swallowing `23502` as `P0001`. | §4.1, §4.3 | 2 days |
| 1.3 | Fix `reserve_inventory_for_order`: correct the OUT tuple in the handler, add `FOR UPDATE`, include `location_id`, drop the recursive movement insert. | §4.3 | 2 days |
| 1.4 | Remove one `add_customer` overload; align the tool's arity and result unpacking. | §4.4, §4.5 | 1-2 days |
| 1.5 | `ALTER communications.parent_id, thread_root_id TYPE bigint`; add the missing FK on `thread_root_id`. | §5.2 | 1 day |
| 1.6 | CASCADE → RESTRICT on the 5 stock/warehouse edges, plus an explicit close-out transaction. | §5.10 | 1 day |
| 1.7 | Delete the 8 duplicated index sets; add `entities`/`contacts` search indexes (`pg_trgm` GIN on `name`, unique `lower(email)`, partial on `status`); index `transaction_id`. | §5.5, §5.6 | 2-3 days |

### P2 — Make it enterprise-grade

| # | Action | Ref | Effort |
| --- | --- | --- | --- |
| 2.1 | Add `tenant_id uuid NOT NULL` to all 18 tables and lead every composite index and unique constraint with it. **Do this before P1.7 pays off at scale.** | §5.8 | 1-2 weeks |
| 2.2 | Build `tenants`, `users`, `principals`, `roles`, `permissions`; convert the 13 actor columns to FKs into one registry. | §5.8 | 1-2 weeks |
| 2.3 | Enable RLS on all tables with `FORCE ROW LEVEL SECURITY`, policy on `app.tenant_id`, and **actually set the GUC** in the connection pool. Remove or fix the inert `app.current_agent` policies. | §5.7 | 3-5 days |
| 2.4 | Implement ADR-005 for real: `idempotency_keys(key, response jsonb, created_at)` with a unique constraint and insert-first claim; triggers that increment `version`. | §6.1 | 1 week |
| 2.5 | Convert the 31 domain columns to CHECK'd lookup tables (translatable, extensible — the SAP/Oracle pattern) rather than native enums, which are painful to alter in production. | §5.9 | 1-2 weeks |
| 2.6 | Immutable, monthly-partitioned `audit_log` in the canonical schema with a hash chain and no UPDATE/DELETE grants. | §6.2 | 1 week |
| 2.7 | Unify keys: UUIDv7/v1mc for distributed tables, `bigint` sequences for append-only ledgers, never `integer`. | §5.1, §5.3, §5.4 | 1 week + migration |
| 2.8 | One shared `BEFORE INSERT OR UPDATE` trigger maintaining `updated_at`; add `created_at` to `inventory_on_hand`/`inventory_reservations`. | §6.3 | 2 days |
| 2.9 | `ivfflat` → `hnsw`; add the two missing embedding indexes; move vectors to a side table; consider `halfvec` for 2× density. | §6.4 | 3-5 days |
| 2.10 | `currencies` + rate history; amounts in minor units or `numeric(19,4)`; FK the `char(3)` columns. | §6.5 | 1 week |
| 2.11 | Partition `communications`, `agent_interactions`, `bot_actions` by month with a detach job; BRIN on time columns. | §6.6 | 1 week |
| 2.12 | Soft-delete / bitemporal columns on `contacts`, `addresses`, `communications` so erasure requests do not corrupt referential history. | §5.8, §6.6 | 1 week |

**P3 (governance, not scheduled here):** adopt a real migration tool (`golang-migrate` fits,
since `backend_go/` is the primary backend) with an applied-migrations table; add a CI job
that builds a fresh PG17+pgvector, replays migrations with `ON_ERROR_STOP=1`, asserts
expected object counts, detects duplicate indexes and unindexed FKs, and executes the §4
functions against scratch data; wire the existing `make docs-schema` (`Makefile:112`) into
CI so `docs/database/schema.md` cannot drift from the catalog. None of §3-§6 was catchable
without running it, which is the argument for all three.

---

## 8. Summary judgement

The relational skeleton is sound: clean primary keys, sensible natural-key uniqueness, real
referential edges, a proper append-only movements ledger, explicit-column views, and working
pgvector integration. What it is **not** today is deployable or enterprise-grade.

Ranked by what actually blocks progress:

1. The documented setup path builds **1 of 18 tables** (§3.2).
2. The running application targets a **vestigial second schema** and never touches the
   hardened one (§3.1) — so §4-§6 findings understate the live system's risk while
   overstating the value of fixing `public` alone.
3. **All four** data-writing functions fail when executed (§4.1-4.4).
4. Both features ADR-005 calls mandatory — idempotency and optimistic versioning — are
   **absent from the database** (§6.1).
5. The core CRM tables have **no indexes** beyond their keys (§5.5) and a **latent 2^31
   ceiling** on thread references (§5.2).
6. Tenancy, identity, row-level audit, and domain control are **structurally missing**
   (§5.7-5.10, §6.2).

Do P0 and P1 first: they are small, mechanical, and everything else is measured against a
schema nothing can currently build. Then treat `tenant_id` + identity (2.1-2.2) as the first
design commitment rather than a later migration — retrofitting them across 18 tables and
their indexes is the expensive version of the same change, and every other item on the P2
list becomes cheaper once the tenant key exists.
