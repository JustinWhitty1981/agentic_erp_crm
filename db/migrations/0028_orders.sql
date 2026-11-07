-- 0028: orders and order_items — one header, one detail, three document types
--       (the orders programme, migration 2 of 4)
--
-- WHY ONE PAIR OF TABLES AND NOT THREE
--
-- Sales, purchase and work orders share a shape that is not a coincidence: a dated agreement with a
-- counterparty, carrying lines, each line a quantity of something at some place, and a lifecycle
-- that ends closed or cancelled. They differ in who is on the other end, which direction stock
-- moves, and what a line means. Three header/detail pairs would make the differences structural and
-- the commonality accidental, and the decisive objection is the one 0027 established:
-- `inventory_reservations.order_id` is a single uuid column that must be able to name the document a
-- commitment belongs to. Against three tables that reference is a three-way OR, and PostgreSQL
-- cannot express a three-way OR as a foreign key. It would stay exactly what it is today — a number
-- that means something only if the reader remembers which table it came from.
--
-- So: `orders` + `order_items`, discriminated by order_type ∈ {SALES, PURCHASE, WORK} — the three
-- the business names, and the same three 0015's CASE already treats as documents (it maps
-- PURCHASE→PO and SALES/WORK→ORDER; that collapse is 0029's to repair, not this file's).
--
-- WHERE THE TYPE DIFFERENCES LIVE
--
--   * Counterparty: a customer, a supplier, or nobody. Both columns exist, both are nullable, and
--     one CHECK says which must be filled. That is a rule about persistent state with no subquery in
--     it, so it is DDL's (ADR-002), and it binds every seat that writes, an operator in psql
--     included.
--   * Direction of stock: not a column. It is which door moves it, and those doors are 0030.
--   * What a line means: `line_type` — STANDARD on a document with a counterparty, COMPONENT for
--     what a work order consumes, PRODUCT for what it yields. This is the seam the manufacturing
--     model lands on in 0029, which is why lines carry the axis now rather than acquiring it later.
--   * A line that is not a catalog item: a purchase order procures services as well as goods, and
--     `inventory_items.product_type` already admits SERVICE, so categorised services ARE items.
--     `item_id` is nullable with a CHECK that a blank one must carry a description, because a
--     one-off plumber is a real line, and forcing every expense into the item master is how a
--     deployment grows one item called MISCELLANEOUS, which is a NULL with a tax code.
--
-- WHAT IS NOT STORED, AND WHY EACH OMISSION IS A DECISION
--
--   * Header totals are not stored. A total over lines is an aggregate across rows, and a stored
--     aggregate is a second truth about the rows it summarises. vw_orders sums them set-based, in
--     one grouped pass, which is 0022's conclusion (its rewrite replaced a loop doing two aggregate
--     reads per customer) applied before the fact rather than after it.
--   * Line amount IS stored, as a GENERATED column. It is a pure function of two columns on the
--     same row, so it is the one derived value that can live in the table without being a second
--     truth — and PostgreSQL infers its width from the multiplication instead of a human guessing
--     it. That guess is precisely what 0018 had to fix: `total_cost = p_quantity * p_unit_cost`
--     written into numeric(15,4) from numeric(12,4) factors, which dies with a 22003 on arithmetic
--     the schema itself asked for.
--   * Line status is not stored. It is quantity_fulfilled and quantity_cancelled against quantity,
--     and vw_order_lines names the state. A second lifecycle on the line would be a second register
--     to keep honest, and every question about a line is already answerable from its quantities.
--   * `updated_by` is not a column. The actor for a later change is audit_log's job, and 0013
--     decided that identity twice already; a column that duplicates what the trail says is a column
--     that can rot out of agreement with it. `created_by` stays because it is a fact about the row's
--     beginning, and it defaults to the connection's application_name, which is set by the pool and
--     is not something a model can type into a tool argument.
--
-- THE KEY RULE THIS MIGRATION FOLLOWS
--
--   0027 measured that a foreign key does not respect row security, so a single-column key into a
--   tenant-coded table is satisfied by another tenant's row. Every reference this file adds carries
--   the tenant in the key: `(tenant_id, col) → target (tenant_id, pk)`. That is load-bearing against
--   `entities`, whose id is a bigint from a sequence and therefore enumerable, and it is
--   defence-in-depth against the uuid-v7 tables, whose ids are not guessable. It is applied uniformly
--   anyway, because the alternative is a rule whose shape depends on which table is being
--   referenced, and that is the kind of exception that outlives its reason. §11 records the edges
--   this file did not retrofit, and probe K counts them, so the debt stays a number rather than
--   becoming a rumour.

SET client_min_messages TO notice;

-- ---------------------------------------------------------------------------
-- 1. The lifecycle register
-- ---------------------------------------------------------------------------
-- Why a table and not one CHECK over pairs. The per-type legal set is a relationship BETWEEN two
-- sets. Written as `CHECK ((order_type='SALES' AND status IN (...)) OR ...)`, it references two
-- columns — and vw_domain_vocabulary's census reads single-column membership constraints
-- (`cardinality(conkey)=1`), so a two-column CHECK would leave orders.status looking unconstrained to
-- the register while being the most constrained column on the server. This shape states each half
-- where the register can see it: a membership CHECK per column, and the pair's legality as a key.
--
-- It is GLOBAL, deliberately: a lifecycle is this repository's workflow, not a tenant's
-- configuration. It carries no tenant_id, is declared by name in B19 rather than given policies, and
-- is not in B1b's natural-key list because it has no natural key to scope.
CREATE TABLE IF NOT EXISTS order_lifecycle (
    order_type   varchar(20)  NOT NULL,
    status_code  varchar(50)  NOT NULL,
    ordinal      integer      NOT NULL,
    terminal     boolean      NOT NULL DEFAULT false,
    -- Some statuses are not a decision, they are a consequence: an order is SHIPPED because stock
    -- left, and the register says so here so transition_order can refuse to write a consequence by
    -- hand. Without this column, "mark order 47 shipped" is a sentence a model can say and the
    -- database will do, and the ledger would then disagree with the document.
    stock_moving boolean      NOT NULL DEFAULT false,
    notes        text,
    PRIMARY KEY (order_type, status_code),
    -- The same three values orders.order_type admits. Duplicated rather than referenced — there is
    -- nothing to reference, since the type axis is a CHECK and not a master table — and watched by
    -- probe H, which compares the two lists out of the catalog rather than trusting that both were
    -- edited. A register silently admitting a fourth type would define lifecycles no order can have.
    CONSTRAINT order_lifecycle_type_allowed CHECK (order_type IN ('SALES','PURCHASE','WORK')),
    CONSTRAINT order_lifecycle_ordinal_positive CHECK (ordinal > 0),
    -- The pair's own consistency: a status that is a lifecycle's last word cannot sit at position 1,
    -- because then the only way in would be from nothing and transition_order's direction rule would
    -- have no forward to mean.
    CONSTRAINT order_lifecycle_terminal_not_first CHECK (NOT terminal OR ordinal > 1)
);

COMMENT ON TABLE order_lifecycle IS
    'Which statuses each order type may hold, and in what order. Global master data about this '
    'repository''s workflow, not a tenant''s configuration: a status no door implements is not a '
    'status a tenant can be offered. orders carries a composite foreign key to it, which is what '
    'makes "a work order that is SHIPPED" a key violation rather than a sentence in a function body. '
    'ordinal gives transition_order a direction to check; terminal means leaving is refused. Built '
    'by 0028.';

INSERT INTO order_lifecycle (order_type, status_code, ordinal, terminal, stock_moving, notes) VALUES
    ('SALES','DRAFT',       1, false, false, 'raised, not yet agreed with the customer'),
    ('SALES','CONFIRMED',   2, false, false, 'agreed; stock may be reserved against it'),
    ('SALES','PICKING',     3, false, false, 'a pick is in progress'),
    ('SALES','SHIPPED',     4, false, true,  'stock has left — written by 0030''s ship door only'),
    ('SALES','CLOSED',      5, true,  false, 'nothing further owed either way'),
    ('SALES','CANCELLED',   6, true,  false, 'no stock moved and none will'),
    ('PURCHASE','DRAFT',     1, false, false, 'raised, not yet sent to the supplier'),
    ('PURCHASE','SUBMITTED', 2, false, false, 'sent; receipt expected'),
    ('PURCHASE','RECEIVED',  3, false, true,  'stock has arrived — written by 0030''s receive door'),
    ('PURCHASE','CLOSED',    4, true,  false, 'invoiced and finished'),
    ('PURCHASE','CANCELLED', 5, true,  false, 'the supplier did not, or no longer must'),
    ('WORK','DRAFT',          1, false, false, 'raised, operations not yet planned'),
    ('WORK','RELEASED',       2, false, false, 'given to a work centre — 0029''s door'),
    ('WORK','IN_PRODUCTION',  3, false, false, 'at least one operation has started'),
    ('WORK','COMPLETED',      4, false, true,  'built; output booked against the PRODUCT line by 0030'),
    ('WORK','CLOSED',         5, true,  false, 'costed and finished'),
    ('WORK','CANCELLED',      6, true,  false, 'not going to be built')
ON CONFLICT (order_type, status_code) DO UPDATE
    SET ordinal = EXCLUDED.ordinal, terminal = EXCLUDED.terminal,
        stock_moving = EXCLUDED.stock_moving, notes = EXCLUDED.notes;
-- The upsert makes this file replayable, which is the only way `scripts/db/db fresh` stays honest.
-- It is also 0016's warning observed rather than repeated: the arbiter names the register's own key,
-- and nothing else on this server writes this table, so pattern 1's mechanism is the whole story
-- here. Probe J asserts the row count so an accidental extra status fails in this file and not in a
-- view three migrations later.

-- ---------------------------------------------------------------------------
-- 2. The FK targets: the tenant-led uniqueness each referenced pair needs
-- ---------------------------------------------------------------------------
-- 0027 added the one on entities. Each index below is the two-column uniqueness a composite foreign
-- key must have as its target — not a faster way to find a row. entities_pkey answers "which party is
-- this"; these answer "is this row yours", which is the only question an FK can be told to ask.
-- Neither is the redundancy 5.6 counts: vw_index_redundancy decides by leading column list and these
-- differ in their first column, and 0006 says so directly — "Both shapes are kept where both query
-- shapes exist, which is not the duplicate case 5.6 is about."
CREATE UNIQUE INDEX IF NOT EXISTS suppliers_tenant_supplier_key
    ON suppliers (tenant_id, supplier_id);
CREATE UNIQUE INDEX IF NOT EXISTS warehouses_tenant_warehouse_key
    ON warehouses (tenant_id, warehouse_id);
CREATE UNIQUE INDEX IF NOT EXISTS inventory_items_tenant_item_key
    ON inventory_items (tenant_id, item_id);

COMMENT ON INDEX warehouses_tenant_warehouse_key IS
    'The target of a document''s warehouse reference, added by 0028 so "is this warehouse yours" is a '
    'key rather than a query. warehouses_warehouse_code_key answers a different question (is this code '
    'free), which is why both exist.';

-- ---------------------------------------------------------------------------
-- 3. orders
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS orders (
    order_id        uuid          PRIMARY KEY DEFAULT afpc_uuid_v7(),
    tenant_id       uuid          NOT NULL DEFAULT afpc_current_tenant(),

    order_type      varchar(20)   NOT NULL,
    order_number    varchar(50)   NOT NULL,

    -- Exactly one is filled, and which one is decided by orders_counterparty_matches_type below.
    customer_id     bigint,
    vendor_id       uuid,
    -- The site the document is about: ships from, receives into, or is built at. Nullable, because a
    -- sales order can be raised before anyone knows which warehouse will serve it; 0030's doors
    -- require it at the moment the answer has to be acted on.
    warehouse_id    uuid,

    status          varchar(50)   NOT NULL DEFAULT 'DRAFT',
    -- Why a row has no counterparty, when that is the case. RESERVATION_BACKFILL is not a loophole:
    -- the four commitments already on this server name order ids invented by the demo seed and by
    -- probes, and none of them carries a customer — notes is empty and reserved_by says
    -- 'seed:02_demo_inventory' or 'service bay'. 0004's rule for pre-existing data is to merge what
    -- can be proved and refuse to guess the rest, so 0030 backfills those orders with no customer and
    -- says so here, rather than inventing a party to satisfy a constraint.
    origin          varchar(20)   NOT NULL DEFAULT 'MANUAL',

    currency_code   char(3)       NOT NULL DEFAULT 'USD',
    ordered_date    date          NOT NULL DEFAULT ((now() AT TIME ZONE 'utc')::date),
    required_date   date,
    closed_at       timestamptz,
    priority        integer,
    notes           text,
    -- Why the document is where it is. The trail records that the status changed and who by; it
    -- cannot record the reason, and "why was this cancelled" is the first question anyone asks of a
    -- closed order. Set only by transition_order, and only on a move into a terminal state.
    status_reason   text,
    created_by      varchar(100)  NOT NULL DEFAULT coalesce(current_setting('application_name', true), 'unknown'),
    created_at      timestamptz   NOT NULL DEFAULT now(),
    updated_at      timestamptz   NOT NULL DEFAULT now(),
    version         integer       NOT NULL DEFAULT 1,

    CONSTRAINT orders_tenant_id_fkey
        FOREIGN KEY (tenant_id) REFERENCES tenants (tenant_id) ON DELETE RESTRICT,
    CONSTRAINT orders_customer_in_tenant_fkey
        FOREIGN KEY (tenant_id, customer_id) REFERENCES entities (tenant_id, id)
        ON DELETE RESTRICT,
    CONSTRAINT orders_vendor_in_tenant_fkey
        FOREIGN KEY (tenant_id, vendor_id) REFERENCES suppliers (tenant_id, supplier_id)
        ON DELETE RESTRICT,
    CONSTRAINT orders_warehouse_in_tenant_fkey
        FOREIGN KEY (tenant_id, warehouse_id) REFERENCES warehouses (tenant_id, warehouse_id)
        ON DELETE RESTRICT,
    CONSTRAINT orders_currency_code_fkey
        FOREIGN KEY (currency_code) REFERENCES currencies (currency_code) ON DELETE RESTRICT,

    -- The lifecycle in two halves, both visible to the register: membership per column, then the
    -- legality of the pair by key.
    CONSTRAINT orders_type_allowed CHECK (order_type IN ('SALES','PURCHASE','WORK')),
    CONSTRAINT orders_status_allowed CHECK (
        status IN ('DRAFT','CONFIRMED','PICKING','SHIPPED','CLOSED','CANCELLED',
                   'SUBMITTED','RECEIVED','RELEASED','IN_PRODUCTION','COMPLETED')),
    CONSTRAINT orders_lifecycle_applies
        FOREIGN KEY (order_type, status) REFERENCES order_lifecycle (order_type, status_code)
        ON DELETE RESTRICT,
    CONSTRAINT orders_origin_allowed CHECK (origin IN ('MANUAL','IMPORT','RESERVATION_BACKFILL')),

    -- Which counterparty each document may name. One statement of the rule, evaluated by the
    -- database on every write from every seat.
    CONSTRAINT orders_counterparty_matches_type CHECK (
        (order_type = 'SALES'
            AND (customer_id IS NOT NULL OR origin = 'RESERVATION_BACKFILL')
            AND vendor_id IS NULL)
        OR (order_type = 'PURCHASE' AND vendor_id IS NOT NULL AND customer_id IS NULL)
        OR (order_type = 'WORK' AND customer_id IS NULL AND vendor_id IS NULL)
    ),
    -- The number a human types onto an invoice, and the prefix the document type obliges it to
    -- carry. Both halves are same-row, so both are CHECKs: the format is a shape rule and the
    -- agreement with order_type is a consistency rule. Neither is restated in any function body.
    CONSTRAINT orders_number_format CHECK (order_number ~ '^(SO|PO|WO)-[0-9]{6,}$'),
    CONSTRAINT orders_number_prefix_matches_type CHECK (
        split_part(order_number, '-', 1) = CASE order_type
            WHEN 'SALES' THEN 'SO' WHEN 'PURCHASE' THEN 'PO' WHEN 'WORK' THEN 'WO' END),
    CONSTRAINT orders_number_per_tenant UNIQUE (tenant_id, order_number),
    -- The target for order_items and for every document-level edge that follows, including 0030's
    -- reservation linkage.
    CONSTRAINT orders_tenant_order_key UNIQUE (tenant_id, order_id),

    CONSTRAINT orders_priority_known CHECK (priority IS NULL OR priority BETWEEN 1 AND 10),
    CONSTRAINT orders_dates_sane CHECK (
        required_date IS NULL OR ordered_date IS NULL OR required_date >= ordered_date),
    -- A document in a terminal state has a moment when it became one. The converse is deliberately
    -- not asserted: an import can carry a closed_at on a document still being worked, and refusing
    -- that would be a rule about tidiness rather than about meaning.
    CONSTRAINT orders_terminal_states_are_stamped CHECK (
        status NOT IN ('CLOSED','CANCELLED') OR closed_at IS NOT NULL)
);

ALTER TABLE orders
    DROP CONSTRAINT IF EXISTS orders_tenant_id_fkey;
ALTER TABLE orders
    ADD CONSTRAINT orders_tenant_id_fkey
    FOREIGN KEY (tenant_id) REFERENCES tenants (tenant_id) ON DELETE RESTRICT;

-- The three questions the order surface gets asked, each as one indexed path. All lead with
-- tenant_id (0003/0006) because a policy filters every one of them anyway, and 0009's STABLE
-- resolver makes the predicate an index condition rather than a per-row filter.
CREATE INDEX IF NOT EXISTS idx_orders_tenant_type_state_date
    ON orders (tenant_id, order_type, status, ordered_date DESC);
-- (currency_code) and not (tenant_id, currency_code): currencies is global, and an FK existence
-- check carries no tenant predicate, so the composite form cannot serve it (0006's measurement,
-- and the reason 0027 indexed suppliers.currency_code the same way).
CREATE INDEX IF NOT EXISTS idx_orders_currency
    ON orders (currency_code);
CREATE INDEX IF NOT EXISTS idx_orders_tenant_customer
    ON orders (tenant_id, customer_id) WHERE customer_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_orders_tenant_vendor
    ON orders (tenant_id, vendor_id) WHERE vendor_id IS NOT NULL;
-- The partial predicate is the question the procurement and stock agents ask: what is still live.
-- It is also the only index here that a partitioned successor (0024) could carry forward as BRIN
-- alongside a range split, so the shape is worth choosing deliberately.
CREATE INDEX IF NOT EXISTS idx_orders_tenant_warehouse_open
    ON orders (tenant_id, warehouse_id, ordered_date DESC)
    WHERE status NOT IN ('CLOSED','CANCELLED');

COMMENT ON TABLE orders IS
    'Every document that drives a transaction: a sales order from a customer, a purchase order to a '
    'supplier, a work order that drives production. One header table with a CHECKed discriminator, '
    'because three tables could not be the target of the single uuid column '
    'inventory_reservations.order_id has always been. Counterparty is decided by constraint per type; '
    'the status vocabulary is orders_status_allowed and the legal (type,status) pairs are a key to '
    'order_lifecycle; totals are not stored — vw_orders sums them set-based so a header cannot '
    'disagree with its own lines. Every reference into a tenant-coded table carries the tenant in the '
    'key, which is what 0027 measured a single-column FK cannot do. Built by 0028.';

COMMENT ON CONSTRAINT orders_counterparty_matches_type ON orders IS
    'The three document types, distinguished by who is on the other end. A sales order names a '
    'customer — or is the commitment 0030 imports, where the party is genuinely unknown and origin '
    'records that instead of a guess being stored. A purchase order names a supplier and cannot also '
    'name a customer. A work order names neither, because production has no counterparty.';

COMMENT ON CONSTRAINT orders_lifecycle_applies ON orders IS
    'The per-type status rule, as a key rather than as a boolean expression over two columns — which '
    'is what lets vw_domain_vocabulary see both halves of the decision, since its census reads '
    'single-column membership constraints. Adding a status means one INSERT here and one value in '
    'orders_status_allowed; probe H fails the day those two lists drift.';

COMMENT ON COLUMN orders.created_by IS
    'Who raised it, defaulted from the connection''s application_name — which the pool sets from '
    'AFPC_PG_APPNAME and a model cannot pass as a tool argument, the same reason agent_id and bot_id '
    'are not arguments anywhere on this surface. Later changes are not duplicated here: audit_log '
    'already says who, and 0013 decided that identity so that columns would not have to.';

-- ---------------------------------------------------------------------------
-- 4. order_items
-- ---------------------------------------------------------------------------
-- Column ORDER is load-bearing here, not cosmetic: a GENERATED expression may only reference
-- columns declared before it, so unit_price precedes line_amount. That is also the honest reading
-- order — a line is a quantity at a price, and the amount is what falls out of them.
CREATE TABLE IF NOT EXISTS order_items (
    order_line_id      uuid          PRIMARY KEY DEFAULT afpc_uuid_v7(),
    tenant_id          uuid          NOT NULL DEFAULT afpc_current_tenant(),
    order_id           uuid          NOT NULL,

    line_number        integer       NOT NULL,
    line_type          varchar(20)   NOT NULL DEFAULT 'STANDARD',

    item_id            uuid,
    description        text,
    quantity           numeric(18,4) NOT NULL,
    unit_price         numeric(18,6),
    unit_of_measure    varchar(20)   NOT NULL,
    -- Exact by construction. The type is inferred from the multiplication, so 0018's overflow class
    -- cannot be reintroduced by someone picking a width; and the value cannot drift from the two it
    -- is computed from, because there is no way to write it.
    line_amount        numeric GENERATED ALWAYS AS (quantity * unit_price) STORED,
    -- One name, three meanings, because a commitment and a line track the same three quantities and
    -- a reader who knows inventory_reservations already knows this: received for PURCHASE, shipped
    -- for SALES, produced for WORK. Written only by 0030's doors.
    quantity_fulfilled numeric(18,4) NOT NULL DEFAULT 0,
    quantity_cancelled numeric(18,4) NOT NULL DEFAULT 0,
    warehouse_id       uuid,
    lot_number         varchar(100),
    serial_numbers     jsonb,
    required_date      date,
    notes              text,
    created_at         timestamptz   NOT NULL DEFAULT now(),
    updated_at         timestamptz   NOT NULL DEFAULT now(),
    version            integer       NOT NULL DEFAULT 1,

    CONSTRAINT order_items_tenant_id_fkey
        FOREIGN KEY (tenant_id) REFERENCES tenants (tenant_id) ON DELETE RESTRICT,
    -- A line cannot outlive its header, and a header cannot be deleted while a line stands: 0008's
    -- posture on any table that holds facts, extended to the pair this file introduces.
    CONSTRAINT order_items_order_in_tenant_fkey
        FOREIGN KEY (tenant_id, order_id) REFERENCES orders (tenant_id, order_id)
        ON DELETE RESTRICT,
    CONSTRAINT order_items_item_in_tenant_fkey
        FOREIGN KEY (tenant_id, item_id) REFERENCES inventory_items (tenant_id, item_id)
        ON DELETE RESTRICT,
    CONSTRAINT order_items_warehouse_in_tenant_fkey
        FOREIGN KEY (tenant_id, warehouse_id) REFERENCES warehouses (tenant_id, warehouse_id)
        ON DELETE RESTRICT,
    CONSTRAINT order_items_unit_of_measure_fkey
        FOREIGN KEY (unit_of_measure) REFERENCES units_of_measure (uom_code) ON DELETE RESTRICT,

    CONSTRAINT order_items_line_type_allowed CHECK
        (line_type IN ('STANDARD','COMPONENT','PRODUCT')),
    -- Goods or services, but never nothing: an unpriced, unnamed line is where an invoice dispute
    -- begins.
    CONSTRAINT order_items_names_something CHECK (
        item_id IS NOT NULL OR btrim(coalesce(description, '')) <> ''),
    -- Quantity is positive in every direction, and direction is line_type plus the door that moved
    -- it. 0018 measured the alternative twice: a negative RECEIPT cannot reach the ON CONFLICT DO
    -- UPDATE arm at all, because the tentative INSERT fails the non-negative CHECK on the way in, so
    -- a schema that expresses direction with signs ends up with one arm that never runs.
    CONSTRAINT order_items_quantity_positive CHECK (quantity > 0),
    CONSTRAINT order_items_price_not_negative CHECK (unit_price IS NULL OR unit_price >= 0),
    -- A line cannot be more than itself. This is the invariant 0030's fulfilment doors must preserve,
    -- stated where the database can enforce it rather than in the door that would remember to.
    CONSTRAINT order_items_progress_within_line CHECK (
        quantity_fulfilled >= 0 AND quantity_cancelled >= 0
        AND quantity_fulfilled + quantity_cancelled <= quantity),
    CONSTRAINT order_items_line_number_positive CHECK (line_number > 0),
    -- A line number means a position in a document, so it starts at 1 and never at 0.
    CONSTRAINT order_items_line_number_per_order UNIQUE (tenant_id, order_id, line_number),
    -- 0030 wires inventory_reservations.order_line_id to this, and it is why the key exists now: the
    -- column has had no writer since 0001, and a target has to be in place before the edge can be.
    CONSTRAINT order_items_tenant_line_key UNIQUE (tenant_id, order_line_id),
    CONSTRAINT order_items_required_date_sane CHECK (
        required_date IS NULL OR required_date >= (created_at AT TIME ZONE 'utc')::date - 3650)
);

ALTER TABLE order_items
    DROP CONSTRAINT IF EXISTS order_items_tenant_id_fkey;
ALTER TABLE order_items
    ADD CONSTRAINT order_items_tenant_id_fkey
    FOREIGN KEY (tenant_id) REFERENCES tenants (tenant_id) ON DELETE RESTRICT;

-- What a purchasing agent asks more than anything else on this surface: everything we have ordered
-- of this item and not yet got. Partial because an item's whole history is a different question and
-- answers with a different index.
-- No (tenant_id, order_id, line_number) index of its own: order_items_line_number_per_order already
-- creates exactly that one, and adding a second copy is the identical-pair defect 5.6 counts. This
-- was checked by probe A on the first dry run and by probe M on the second.
CREATE INDEX IF NOT EXISTS idx_order_items_tenant_item
    ON order_items (tenant_id, item_id);
-- The same single-column form inventory_movements and inventory_items use for the same edge: an FK to
-- global master data, which no tenant predicate can help.
CREATE INDEX IF NOT EXISTS idx_order_items_unit_of_measure
    ON order_items (unit_of_measure);
-- The warehouse a line is received into, which 0030's doors read per line and a stock agent filters
-- on. (tenant_id, warehouse_id) is the key form; a partial index could not serve the referential
-- check on the item edge above, which is why that one is not partial.
CREATE INDEX IF NOT EXISTS idx_order_items_tenant_warehouse
    ON order_items (tenant_id, warehouse_id);

COMMENT ON TABLE order_items IS
    'Line-level detail for every document type: a quantity of something, at a price where there is '
    'one, with what has been fulfilled and what cancelled, and the role the line plays — STANDARD on '
    'a document with a counterparty, COMPONENT consumed or PRODUCT yielded by a work order. '
    'line_amount is a GENERATED column so its width is inferred from the multiplication rather than '
    'chosen, which is how 0018''s numeric overflow is prevented instead of fixed a second time. No '
    'status is stored here: a line''s state is its quantities, and vw_order_lines names it. '
    'order_line_id is the row inventory_reservations.order_line_id was always meant to point at. '
    'Built by 0028.';

COMMENT ON CONSTRAINT order_items_progress_within_line ON order_items IS
    'The invariant 0030 exists to preserve. Kept in DDL rather than in the doors because a fulfilled '
    'quantity can also be edited by an import, an operator, and a future migration that forgets — and '
    'a line whose progress exceeds its quantity makes every derived state in vw_order_lines a lie.';

-- ---------------------------------------------------------------------------
-- 5. One rule no CHECK can state, so it is a trigger rather than a branch
-- ---------------------------------------------------------------------------
-- "A COMPONENT or PRODUCT line only exists on a work order" compares a line to its HEADER, and a
-- CHECK cannot look at another row. The alternatives were a door that remembers (rejected: ADR-002),
-- or a second composite key through a helper table (rejected: it would be a third copy of the type
-- axis). An AFTER ROW trigger is where PostgreSQL puts cross-row rules, and it is placed after the
-- foreign keys in creation order so that a line naming a nonexistent header is refused by the key
-- with the key's own message, and this trigger only ever sees lines whose header is real.
CREATE OR REPLACE FUNCTION afpc_line_type_matches_document()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_type   text;
    v_number text;
BEGIN
    -- Read through the wall. An AFTER trigger runs in the writing session's identity, so under
    -- 0009's forced policies this sees the caller's own header and no other's — which is the right
    -- seat: a line that could not name the header would already have been refused by the key above.
    SELECT o.order_type, o.order_number INTO v_type, v_number
      FROM orders o WHERE o.order_id = NEW.order_id;
    IF v_type IS NULL THEN
        -- Unreachable while the foreign key stands, and stated anyway because the day the key is
        -- relaxed this is the arm that decides what a silent pass means.
        RAISE EXCEPTION
            'order_items % on order %: no header row is visible to this connection',
            NEW.order_line_id, NEW.order_id
            USING ERRCODE = '23503';
    END IF;

    IF NEW.line_type <> 'STANDARD' AND v_type <> 'WORK' THEN
        RAISE EXCEPTION
            'order_items line % on %: line_type % is a manufacturing role and the document is a % '
            'order, which has no production for a line to be a role in',
            NEW.line_number, v_number, NEW.line_type, v_type
            USING ERRCODE = '23514',
                  HINT = 'COMPONENT and PRODUCT are for WORK orders; a sales or purchase line is '
                         'STANDARD. The distinction is what tells 0030 which way stock moves.';
    END IF;

    IF NEW.line_type = 'STANDARD' AND v_type = 'WORK' THEN
        RAISE EXCEPTION
            'order_items line % on %: a work order either consumes something or yields something, '
            'and a STANDARD line in a bill of materials does neither',
            NEW.line_number, v_number
            USING ERRCODE = '23514';
    END IF;

    RETURN NULL;
END
$$;

COMMENT ON FUNCTION afpc_line_type_matches_document() IS
    'Cross-row consistency between an order_items line and its orders header, which no CHECK can '
    'express because a CHECK cannot read another row. STANDARD belongs to documents with a '
    'counterparty; COMPONENT and PRODUCT belong to work orders, and a work order line that is neither '
    'consuming nor yielding has no effect to plan. Fires AFTER the foreign keys so a line naming a '
    'missing header is the key''s answer and not this one. Built by 0028.';

-- ---------------------------------------------------------------------------
-- 6. The wall, the trail, and the counters — 0009's and 0013's shapes, by hand, per table
-- ---------------------------------------------------------------------------
-- Written out per table rather than looped, for the reason 0023 gives: the mechanisms that are
-- derived from the catalog enrol a new table automatically, but the ATTACHING of them ran in
-- migrations that have already been applied and cannot see a table born after them. A loop over a
-- catalog query here would be a way of forgetting which tables still need it by hand.
DO $$
DECLARE
    t text;
BEGIN
    FOR t IN SELECT unnest(ARRAY['orders','order_items']) LOOP
        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE public.%I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON public.%I', t);
        EXECUTE format('CREATE POLICY tenant_isolation ON public.%I AS PERMISSIVE FOR ALL TO PUBLIC '
                       'USING (tenant_id = afpc_policy_tenant()) '
                       'WITH CHECK ((tenant_id = afpc_policy_tenant()))', t);
        EXECUTE format('DROP POLICY IF EXISTS audit_read_all ON public.%I', t);
        EXECUTE format('CREATE POLICY audit_read_all ON public.%I AS PERMISSIVE '
                       'FOR SELECT TO afpc_auditor, afpc_readonly USING (true)', t);
        -- 0013's trail, attached explicitly (its census ran and cannot see these tables).
        EXECUTE format('DROP TRIGGER IF EXISTS afpc_audit_row ON public.%I', t);
        EXECUTE format('CREATE TRIGGER afpc_audit_row AFTER INSERT OR UPDATE OR DELETE ON public.%I '
                       'FOR EACH ROW EXECUTE FUNCTION afpc_audit_row()', t);
        -- 0010's timestamp rule, read from the catalog in its own migration and honoured here: both
        -- tables are edited, so both maintain updated_at, and neither statement can forget to.
        EXECUTE format('DROP TRIGGER IF EXISTS afpc_touch_updated_at ON public.%I', t);
        EXECUTE format('CREATE TRIGGER afpc_touch_updated_at BEFORE INSERT OR UPDATE ON public.%I '
                       'FOR EACH ROW EXECUTE FUNCTION afpc_touch_updated_at()', t);
        -- 0011's version counter, attached in the same breath as the column exists, because B10
        -- reads the trigger BODY for `NEW.version :=` and a column nothing assigns is 6.1's
        -- decorative counter. 0011's own installer cannot reach these tables: it ran seventeen files
        -- before this one.
        EXECUTE format('DROP TRIGGER IF EXISTS afpc_bump_version ON public.%I', t);
        EXECUTE format('CREATE TRIGGER afpc_bump_version BEFORE UPDATE ON public.%I '
                       'FOR EACH ROW EXECUTE FUNCTION afpc_bump_version()', t);
    END LOOP;

    -- The cross-row rule, on the child only. Its name sorts after afpc_audit_row and before
    -- afpc_touch_updated_at; all three are AFTER-row except the last two are BEFORE, and 0011's
    -- obligation about name-ordered firing is honoured because none of these bodies reads another's
    -- column.
    EXECUTE 'DROP TRIGGER IF EXISTS afpc_line_type_matches_document ON order_items';
    EXECUTE 'CREATE TRIGGER afpc_line_type_matches_document '
            || 'AFTER INSERT OR UPDATE OF line_type, order_id ON order_items '
            || 'FOR EACH ROW EXECUTE FUNCTION afpc_line_type_matches_document()';
END
$$;

-- ---------------------------------------------------------------------------
-- 7. document_counters: the number on the invoice
-- ---------------------------------------------------------------------------
-- A human-facing document number has to be unique, sequential within a period, and allocated
-- without two callers being able to compute the same one. The naive form — SELECT max()+1 — is a
-- serialisation failure generator under concurrency and a duplicate the moment two transactions
-- commit in the same instant, so the allocation is a single UPSERT whose arbiter IS the lock:
-- PostgreSQL serialises the two statements on the unique index, and RETURNING hands each caller a
-- different value. That is 0011's measurement about a claim guarding a race rather than only a
-- retry, arrived at from the arithmetic side.
--
-- This table is tenant-coded, so it enrols in tenancy, the wall, and the trail like any other —
-- including the trail, which is why it is attached below rather than waived: every order create
-- advances a counter, and an untrailed counter would make "what was the next number" a question the
-- row trail cannot answer.
CREATE TABLE IF NOT EXISTS document_counters (
    tenant_id   uuid          NOT NULL DEFAULT afpc_current_tenant(),
    doc_type    varchar(20)   NOT NULL,
    period      char(6)       NOT NULL,
    next_value  bigint        NOT NULL DEFAULT 1,
    created_at  timestamptz   NOT NULL DEFAULT now(),
    updated_at  timestamptz   NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, doc_type, period),
    CONSTRAINT document_counters_tenant_id_fkey
        FOREIGN KEY (tenant_id) REFERENCES tenants (tenant_id) ON DELETE RESTRICT,
    -- The prefixes orders_number_prefix_matches_type expects, so the two halves of a document number
    -- are defined in one place each and probe G asserts they still agree.
    CONSTRAINT document_counters_type_allowed CHECK (doc_type IN ('SO','PO','WO')),
    CONSTRAINT document_counters_period_format CHECK (period ~ '^[0-9]{6}$'),
    -- 0 is not a document number, and a counter that has run off the end of a bigint is a
    -- measurement nobody wants to discover in production.
    CONSTRAINT document_counters_value_positive CHECK (next_value > 0)
);

ALTER TABLE document_counters
    DROP CONSTRAINT IF EXISTS document_counters_tenant_id_fkey;
ALTER TABLE document_counters
    ADD CONSTRAINT document_counters_tenant_id_fkey
    FOREIGN KEY (tenant_id) REFERENCES tenants (tenant_id) ON DELETE RESTRICT;

DO $$
BEGIN
    ALTER TABLE document_counters ENABLE ROW LEVEL SECURITY;
    ALTER TABLE document_counters FORCE ROW LEVEL SECURITY;
    DROP POLICY IF EXISTS tenant_isolation ON document_counters;
    CREATE POLICY tenant_isolation ON document_counters AS PERMISSIVE
        FOR ALL TO PUBLIC
        USING (tenant_id = afpc_policy_tenant())
        WITH CHECK ((tenant_id = afpc_policy_tenant()));
    DROP POLICY IF EXISTS audit_read_all ON document_counters;
    CREATE POLICY audit_read_all ON document_counters AS PERMISSIVE
        FOR SELECT TO afpc_auditor, afpc_readonly
        USING (true);
    DROP TRIGGER IF EXISTS afpc_audit_row ON document_counters;
    CREATE TRIGGER afpc_audit_row
        AFTER INSERT OR UPDATE OR DELETE ON document_counters
        FOR EACH ROW EXECUTE FUNCTION afpc_audit_row();
    DROP TRIGGER IF EXISTS afpc_touch_updated_at ON document_counters;
    CREATE TRIGGER afpc_touch_updated_at
        BEFORE INSERT OR UPDATE ON document_counters
        FOR EACH ROW EXECUTE FUNCTION afpc_touch_updated_at();
END
$$;

COMMENT ON TABLE document_counters IS
    'The allocator behind orders.order_number: one row per (tenant, kind, YYYYMM), advanced by the '
    'UPSERT in create_order. The unique key is the lock — a SELECT max()+1 would let two callers '
    'compute the same number, which is 0011''s race seen from the arithmetic side. Tenant-coded, so '
    'it carries the wall and the trail like any other table: every create advances it, and '
    '"what was the next number" has to be answerable from the row trail. Nothing deletes from here; '
    'a counter is history. Built by 0028.';

COMMENT ON CONSTRAINT document_counters_type_allowed ON document_counters IS
    'The three prefixes, which orders_number_prefix_matches_type maps order_type onto. Two lists of '
    'the same three strings is one too many, so probe G derives both from the catalog and compares '
    'them rather than trusting that both were edited.';

-- ---------------------------------------------------------------------------
-- 8. The doors
-- ---------------------------------------------------------------------------
-- Three of them, because these are the three decisions this table can be the subject of: raise a
-- document, add something to it, move it along. Nothing here touches stock — that is 0030, and the
-- separation is what keeps 0028 replayable against a database with reservations already on it.
--
-- None of the three restates a membership rule. A wrong argument arrives with its own SQLSTATE and
-- its constraint's own name, which is what 0014/0015/0016 concluded about errors-as-answers. The two
-- places a value is *mapped* rather than tested — order_type to document prefix, and a blank unit of
-- measure to the item master — are mappings, and each is total-by-probe rather than total-by-hope.

CREATE OR REPLACE FUNCTION create_order(
    p_order_type      text    DEFAULT NULL,
    p_customer_id     bigint  DEFAULT NULL,
    p_vendor_id       uuid    DEFAULT NULL,
    p_warehouse_id    uuid    DEFAULT NULL,
    p_currency_code   char(3) DEFAULT NULL,
    p_required_date   date    DEFAULT NULL,
    p_priority        integer DEFAULT NULL,
    p_notes           text    DEFAULT NULL,
    p_origin          text    DEFAULT 'MANUAL',
    p_idempotency_key uuid    DEFAULT NULL
) RETURNS TABLE(success boolean, order_id uuid, order_number text, message text)
LANGUAGE plpgsql AS $$
DECLARE
    v_claim  record;
    v_state  text := '';
    v_ok     boolean := true;
    v_msg    text;
    v_id     uuid;
    v_number text;
    v_prefix text;
    v_seq    bigint;
BEGIN
    ------------------------------------------------------------------
    -- ADR-005 pattern 2, in 0016's shape. Two calls that would raise the same order are one
    -- operation; a call that differs in any business argument is a different request wearing someone
    -- else's key, which is a conflict and not a cache hit. The fingerprint covers every argument
    -- except the key, including p_origin: a backfill and a human raising the same document are
    -- different operations, and pretending otherwise would let one answer the other.
    ------------------------------------------------------------------
    IF p_idempotency_key IS NOT NULL THEN
        SELECT * INTO v_claim FROM idempotency_claim(
            p_idempotency_key, 'create_order',
            jsonb_build_object(
                'type', p_order_type, 'customer', p_customer_id, 'vendor', p_vendor_id,
                'warehouse', p_warehouse_id, 'currency', p_currency_code,
                'required', p_required_date, 'priority', p_priority,
                'notes', p_notes, 'origin', p_origin));
        v_state := v_claim.claim_state;
        IF v_state = 'replay' THEN
            success     := (v_claim.cached_response ->> 'success')::boolean;
            order_id    := (v_claim.cached_response ->> 'order_id')::uuid;
            order_number:= v_claim.cached_response ->> 'order_number';
            message     := v_claim.cached_response ->> 'message';
            RETURN NEXT;
            RETURN;
        ELSIF v_state = 'in_progress' THEN
            RAISE EXCEPTION 'create_order: an attempt with key % is already in flight',
                p_idempotency_key USING ERRCODE = '40001';
        ELSIF v_state = 'conflict' THEN
            RAISE EXCEPTION 'create_order: key % was settled for a DIFFERENT request',
                p_idempotency_key USING ERRCODE = 'P0001';
        END IF;
    END IF;

    ------------------------------------------------------------------
    -- The number. A mapping, not a test: an order_type outside the published three yields a NULL
    -- prefix, which document_counters' own key refuses before anything is written, so the failure is
    -- the vocabulary's and not a branch's. Probe H asserts the mapping is total over the values
    -- orders publishes, which is 0015's probe-I discipline moved to a mapping that would otherwise be
    -- invisible when it broke.
    ------------------------------------------------------------------
    v_prefix := CASE p_order_type
                    WHEN 'SALES'    THEN 'SO'
                    WHEN 'PURCHASE' THEN 'PO'
                    WHEN 'WORK'     THEN 'WO'
                END;

    INSERT INTO document_counters (doc_type, period, next_value)
    VALUES (v_prefix, to_char(now() AT TIME ZONE 'utc', 'YYYYMM'), 1)
    ON CONFLICT (tenant_id, doc_type, period)
      DO UPDATE SET next_value = document_counters.next_value + 1
    RETURNING document_counters.next_value INTO v_seq;
    -- RETURNING gives the value the row holds AFTER the conflict action, so the first call in a
    -- period gets 1 and every later one gets the incremented counter, from one statement and with no
    -- window in which two callers can read the same number.

    v_number := v_prefix || '-' || lpad(v_seq::text, 6, '0');

    INSERT INTO orders (order_type, order_number, customer_id, vendor_id, warehouse_id,
                        currency_code, required_date, priority, notes, origin, status)
    VALUES (p_order_type, v_number, p_customer_id, p_vendor_id, p_warehouse_id,
            coalesce(p_currency_code, 'USD'), p_required_date, p_priority,
            NULLIF(btrim(coalesce(p_notes, '')), ''), coalesce(p_origin, 'MANUAL'), 'DRAFT')
    RETURNING orders.order_id INTO v_id;

    v_msg := format('%s order %s raised as DRAFT%s',
        p_order_type, v_number,
        CASE WHEN p_customer_id IS NOT NULL THEN ' for customer ' || p_customer_id::text
             WHEN p_vendor_id   IS NOT NULL THEN ' against supplier ' || p_vendor_id::text
             WHEN p_order_type = 'WORK'    THEN ' for internal production'
             ELSE '' END);

    IF v_state = 'claimed' THEN
        PERFORM idempotency_complete(v_claim.claim_id, v_claim.current_token,
            jsonb_build_object('success', true, 'order_id', v_id,
                               'order_number', v_number, 'message', v_msg));
    END IF;

    RETURN QUERY SELECT v_ok, v_id, v_number, v_msg;
    RETURN;

EXCEPTION
    WHEN OTHERS THEN
        -- Every refusal releases the claim (0016's ladder), including the counter's own: an
        -- order_type the vocabulary does not have is a deletable obstacle, and a cached no would
        -- hide the attempt that named a real one.
        IF v_state = 'claimed' THEN
            BEGIN
                PERFORM idempotency_complete(v_claim.claim_id, v_claim.current_token,
                                             NULL, false, SQLERRM);
            EXCEPTION WHEN OTHERS THEN NULL;
            END;
        END IF;
        RAISE EXCEPTION USING ERRCODE = SQLSTATE, MESSAGE = SQLERRM;
END
$$;

COMMENT ON FUNCTION create_order(text, bigint, uuid, uuid, char(3), date, integer, text, text, uuid) IS
    'Raise a document: SALES for a customer, PURCHASE against a supplier, WORK for production. The '
    'new order is always DRAFT — raising and committing are two decisions, and a door that accepted '
    'a starting status would let a document be created already shipped, which the lifecycle exists to '
    'prevent. The human-facing number is allocated by a UPSERT whose unique key is the lock, so two '
    'concurrent creates cannot compute the same one. Counterparty rules and the type vocabulary are '
    'the constraints''; nothing in this body restates them, so a wrong value answers with its own '
    'SQLSTATE and its own constraint name. With p_idempotency_key a retried call is one order (ADR-005, '
    '0011''s claim, 0016''s ladder). Returns (success, order_id, order_number, message) in '
    'add_customer''s shape. Built by 0028.';

CREATE OR REPLACE FUNCTION add_order_line(
    p_order_id        uuid    DEFAULT NULL,
    p_item_id         uuid    DEFAULT NULL,
    p_description     text    DEFAULT NULL,
    p_quantity        numeric DEFAULT NULL,
    p_unit_price      numeric DEFAULT NULL,
    p_unit_of_measure varchar DEFAULT NULL,
    p_line_type       text    DEFAULT 'STANDARD',
    p_warehouse_id    uuid    DEFAULT NULL,
    p_required_date   date    DEFAULT NULL,
    p_lot_number      text    DEFAULT NULL,
    p_notes           text    DEFAULT NULL,
    p_idempotency_key uuid    DEFAULT NULL
) RETURNS TABLE(success boolean, order_line_id uuid, line_number integer, message text)
LANGUAGE plpgsql AS $$
DECLARE
    v_claim   record;
    v_state   text := '';
    v_ok      boolean := true;
    v_msg     text;
    v_line    uuid;
    v_num     integer;
    v_try     integer := 0;
    v_type    text;
    v_hwh     uuid;
    v_term    boolean;   -- named for what it holds: the register's terminal flag.
                 -- This variable was v_live and held lc.terminal, and the first run refused every
                 -- line add, which is the whole argument for naming a flag after its truth
    v_uom     varchar(20);
BEGIN
    IF p_idempotency_key IS NOT NULL THEN
        SELECT * INTO v_claim FROM idempotency_claim(
            p_idempotency_key, 'add_order_line',
            jsonb_build_object(
                'order', p_order_id, 'item', p_item_id, 'desc', p_description,
                'qty', p_quantity, 'price', p_unit_price, 'uom', p_unit_of_measure,
                'kind', p_line_type, 'warehouse', p_warehouse_id, 'required', p_required_date,
                'lot', p_lot_number, 'notes', p_notes));
        v_state := v_claim.claim_state;
        IF v_state = 'replay' THEN
            success       := (v_claim.cached_response ->> 'success')::boolean;
            order_line_id := (v_claim.cached_response ->> 'order_line_id')::uuid;
            line_number   := (v_claim.cached_response ->> 'line_number')::integer;
            message       := v_claim.cached_response ->> 'message';
            RETURN NEXT;
            RETURN;
        ELSIF v_state = 'in_progress' THEN
            RAISE EXCEPTION 'add_order_line: an attempt with key % is already in flight',
                p_idempotency_key USING ERRCODE = '40001';
        ELSIF v_state = 'conflict' THEN
            RAISE EXCEPTION 'add_order_line: key % was settled for a DIFFERENT request',
                p_idempotency_key USING ERRCODE = 'P0001';
        END IF;
    END IF;

    IF p_order_id IS NULL THEN
        RAISE EXCEPTION 'add_order_line: p_order_id is required — a line belongs to a document'
            USING ERRCODE = '22023';
    END IF;

    ------------------------------------------------------------------
    -- The header, read through the wall. A hidden order answers as a refusal rather than as a NULL
    -- the foreign key would then accept — 0018 measured that difference and lost a write to it.
    -- Joining order_lifecycle to get `terminal` is a read of the published register, not a second
    -- copy of the status vocabulary: the answer comes from the same rows the key consults.
    ------------------------------------------------------------------
    SELECT o.order_type, o.warehouse_id, lc.terminal INTO v_type, v_hwh, v_term
      FROM orders o
      JOIN order_lifecycle lc ON lc.order_type = o.order_type AND lc.status_code = o.status
     WHERE o.order_id = p_order_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'add_order_line: order % is not a document this connection can see',
            p_order_id
            USING ERRCODE = '22023',
                  HINT = 'an id from another tenant is indistinguishable from one that was never '
                         'created, because row security hides the row before the key is consulted';
    END IF;
    IF v_term THEN
        RAISE EXCEPTION 'add_order_line: order % is in a terminal state and takes no new lines',
            p_order_id
            USING ERRCODE = '23514',
                  HINT = 'reopen is not a transition (0028''s lifecycle has no way back from '
                         'CLOSED/CANCELLED); raise a new document and cancel this one';
    END IF;

    -- A blank unit resolves through the ITEM MASTER, which is 0014's and 0015's precedent for the
    -- same argument and for the same reason: the item already knows what it is counted in, and a
    -- second answer from the caller is a second truth. A non-catalog line has no item to ask, so the
    -- column's NOT NULL answers, and that answer is the right one.
    v_uom := coalesce(p_unit_of_measure,
                      (SELECT i.base_unit_of_measure FROM inventory_items i
                        WHERE i.item_id = p_item_id));

    ------------------------------------------------------------------
    -- The line number is the next position in THIS document, allocated by reading the max and
    -- letting the unique index be the arbiter. Two concurrent adds to one order collide on
    -- order_items_line_number_per_order, and the loser recomputes; five attempts is not a timeout
    -- but a bound, because a collision that persists that long is a bug in this loop and should
    -- surface as the key's own error rather than as a silent give-up.
    ------------------------------------------------------------------
    LOOP
        v_try := v_try + 1;
        BEGIN
            INSERT INTO order_items (order_id, line_number, line_type, item_id, description,
                                     quantity, unit_price, unit_of_measure, warehouse_id,
                                     required_date, lot_number, notes)
            SELECT p_order_id, coalesce(max(i.line_number), 0) + 1,
                   coalesce(p_line_type, 'STANDARD'), p_item_id,
                   NULLIF(btrim(coalesce(p_description, '')), ''), p_quantity, p_unit_price,
                   v_uom, coalesce(p_warehouse_id, v_hwh), p_required_date,
                   NULLIF(btrim(coalesce(p_lot_number, '')), ''),
                   NULLIF(btrim(coalesce(p_notes, '')), '')
              FROM order_items i
             WHERE i.order_id = p_order_id
             -- GROUP BY is absent because the only aggregate is max() and everything else is a
             -- constant from outside the query. 0022's rewrite made the same point about a loop
             -- doing per-row aggregates: this is one pass over the document's own lines.
            RETURNING order_items.order_line_id, order_items.line_number
                 INTO v_line, v_num;
            EXIT;
        EXCEPTION WHEN unique_violation THEN
            IF v_try >= 5 THEN
                RAISE EXCEPTION USING ERRCODE = SQLSTATE, MESSAGE = SQLERRM;
            END IF;
        END;
    END LOOP;

    v_msg := format('Line %s on %s: %s %s%s', v_num,
        (SELECT o.order_number FROM orders o WHERE o.order_id = p_order_id),
        p_quantity, coalesce(v_uom, ''),
        CASE WHEN p_item_id IS NOT NULL THEN ' of ' ||
                 (SELECT i.name FROM inventory_items i WHERE i.item_id = p_item_id)
             WHEN NULLIF(btrim(coalesce(p_description, '')), '') IS NOT NULL
                 THEN ' of ' || btrim(p_description)
             ELSE '' END);

    IF v_state = 'claimed' THEN
        PERFORM idempotency_complete(v_claim.claim_id, v_claim.current_token,
            jsonb_build_object('success', true, 'order_line_id', v_line,
                               'line_number', v_num, 'message', v_msg));
    END IF;

    RETURN QUERY SELECT v_ok, v_line, v_num, v_msg;
    RETURN;

EXCEPTION
    WHEN OTHERS THEN
        IF v_state = 'claimed' THEN
            BEGIN
                PERFORM idempotency_complete(v_claim.claim_id, v_claim.current_token,
                                             NULL, false, SQLERRM);
            EXCEPTION WHEN OTHERS THEN NULL;
            END;
        END IF;
        RAISE EXCEPTION USING ERRCODE = SQLSTATE, MESSAGE = SQLERRM;
END
$$;

COMMENT ON FUNCTION add_order_line(uuid, uuid, text, numeric, numeric, varchar, text, uuid, date, text, text, uuid) IS
    'Add one line to an existing document. The line number is the next position in that document, '
    'allocated under the unique index rather than by a max() the caller trusts, so two concurrent '
    'adds collide and recompute instead of both writing the same position. A blank unit_of_measure '
    'resolves through the item master, the way 0014 and 0015 resolve the movement unit — the item '
    'already knows what it is counted in. A line with no item must carry a description '
    '(order_items_names_something); the number must be positive (order_items_quantity_positive); and '
    'a manufacturing line role is refused on a non-work document by the after-row consistency trigger, '
    'not by this body. Lines cannot be added to a document in a terminal state, because CLOSED and '
    'CANCELLED are the register''s last word and an appended line would make the document mean '
    'something its status denies. With p_idempotency_key a retried call is one line. Built by 0028.';

CREATE OR REPLACE FUNCTION transition_order(
    p_order_id          uuid    DEFAULT NULL,
    p_to_status         text    DEFAULT NULL,
    p_reason            text    DEFAULT NULL,
    p_expected_version  integer DEFAULT NULL,
    p_idempotency_key   uuid    DEFAULT NULL
) RETURNS TABLE(success boolean, order_id uuid, status text, message text)
LANGUAGE plpgsql AS $$
DECLARE
    v_claim   record;
    v_state   text := '';
    v_ok      boolean := true;
    v_msg     text;
    v_from    record;
    v_to      record;
    v_number  text;
BEGIN
    IF p_idempotency_key IS NOT NULL THEN
        SELECT * INTO v_claim FROM idempotency_claim(
            p_idempotency_key, 'transition_order',
            jsonb_build_object('order', p_order_id, 'to', p_to_status, 'reason', p_reason,
                               'version', p_expected_version));
        v_state := v_claim.claim_state;
        IF v_state = 'replay' THEN
            success  := (v_claim.cached_response ->> 'success')::boolean;
            order_id := (v_claim.cached_response ->> 'order_id')::uuid;
            status   := v_claim.cached_response ->> 'status';
            message  := v_claim.cached_response ->> 'message';
            RETURN NEXT;
            RETURN;
        ELSIF v_state = 'in_progress' THEN
            RAISE EXCEPTION 'transition_order: an attempt with key % is already in flight',
                p_idempotency_key USING ERRCODE = '40001';
        ELSIF v_state = 'conflict' THEN
            RAISE EXCEPTION 'transition_order: key % was settled for a DIFFERENT request',
                p_idempotency_key USING ERRCODE = 'P0001';
        END IF;
    END IF;

    IF p_order_id IS NULL OR p_to_status IS NULL THEN
        RAISE EXCEPTION 'transition_order: p_order_id and p_to_status are both required'
            USING ERRCODE = '22023';
    END IF;

    ------------------------------------------------------------------
    -- Where it is. Both rows are read from the published register rather than from a list in this
    -- body, so the direction rule and the terminal rule are the register's, and a status added there
    -- is obeyed here without this file being touched.
    ------------------------------------------------------------------
    SELECT o.order_type, o.order_number, o.version, lc.ordinal AS from_ordinal,
           lc.terminal AS from_terminal
      INTO v_from
      FROM orders o
      JOIN order_lifecycle lc ON lc.order_type = o.order_type AND lc.status_code = o.status
     WHERE o.order_id = p_order_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'transition_order: order % is not a document this connection can see',
            p_order_id
            USING ERRCODE = '22023',
                  HINT = 'another tenant''s id and a nonexistent one are the same refusal, because '
                         'row security hides the row before any key is consulted (0018)';
    END IF;
    v_number := v_from.order_number;

    SELECT lc.ordinal AS to_ordinal, lc.terminal AS to_terminal, lc.stock_moving AS to_stock
      INTO v_to
      FROM order_lifecycle lc
     WHERE lc.order_type = v_from.order_type AND lc.status_code = p_to_status;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'transition_order: % is not a status a % order has, according to '
                        'order_lifecycle', p_to_status, v_from.order_type
            USING ERRCODE = '23503',
                  HINT = 'the register is the only place the legal pairs live; adding a status to '
                         'orders_status_allowed without a row here would leave a value no document '
                         'can hold';
    END IF;

    IF p_expected_version IS NOT NULL AND p_expected_version <> v_from.version THEN
        -- A concurrent edit landed between the read and the write. 40001 is the right SQLSTATE: this
        -- is the same class of conflict 0011's claim answers with in_progress, and a caller that
        -- retries after re-reading is a caller doing the correct thing.
        RAISE EXCEPTION 'transition_order: order % has version %, not the % this caller read — '
                        'somebody else moved it first', p_order_id, v_from.version, p_expected_version
            USING ERRCODE = '40001';
    END IF;

    IF v_from.from_terminal THEN
        RAISE EXCEPTION 'transition_order: % is % and % is a terminal state — there is no way back '
                        'in this lifecycle', v_number, v_from.order_type, p_to_status
            USING ERRCODE = '23514',
                  HINT = 'a reopened document is a new document; the old one is history and the trail '
                         'says so';
    END IF;

    IF v_to.to_stock THEN
        RAISE EXCEPTION 'transition_order: % is a status that reports something the warehouse did, '
                        'not a decision a caller can make', p_to_status
            USING ERRCODE = '23514',
                  HINT = 'use the fulfilment door (0030): the ledger row is what makes the status '
                         'true, and a status set without one is a document disagreeing with its stock';
    END IF;

    -- The only step backwards this lifecycle allows is into CANCELLED, and that allowance has to be
    -- tested in the same expression that refuses the others. Splitting it across two branches is how
    -- a rule ends up half-enforced: the first branch alone would refuse a cancellation on an order
    -- that had already moved forward, which is the single most common thing a purchasing department
    -- needs to do.
    IF v_to.to_ordinal < v_from.from_ordinal AND p_to_status <> 'CANCELLED' THEN
        RAISE EXCEPTION 'transition_order: % would take % backwards from ordinal % to %',
                p_to_status, v_number, v_from.from_ordinal, v_to.to_ordinal
            USING ERRCODE = '23514',
                  HINT = 'a document that has moved forward is corrected by a new line or a new '
                         'document; CANCELLED is the one backward move, and it is terminal';
    END IF;

    UPDATE orders
       SET status        = p_to_status,
           closed_at     = CASE WHEN v_to.to_terminal THEN now() ELSE NULL END,
           status_reason = CASE WHEN v_to.to_terminal
                                THEN NULLIF(btrim(coalesce(p_reason, '')), '')
                                ELSE status_reason END
     WHERE orders.order_id = p_order_id;

    v_msg := format('%s moved %s → %s%s', v_number, v_from.order_type || ' status', p_to_status,
                    CASE WHEN v_to.to_terminal THEN ' (terminal)' ELSE '' END);

    IF v_state = 'claimed' THEN
        PERFORM idempotency_complete(v_claim.claim_id, v_claim.current_token,
            jsonb_build_object('success', true, 'order_id', p_order_id,
                               'status', p_to_status, 'message', v_msg));
    END IF;

    -- No cast on the third column, and that is 0015's finding rather than a style choice: RETURN
    -- QUERY matches the query's columns against the declared OUT types EXACTLY, so a `::varchar`
    -- beside a `text` OUT column dies with "structure of query does not match function result type"
    -- even though the two types are assignment-compatible everywhere else. p_to_status is text.
    RETURN QUERY SELECT v_ok, p_order_id, p_to_status, v_msg;
    RETURN;

EXCEPTION
    WHEN OTHERS THEN
        IF v_state = 'claimed' THEN
            BEGIN
                PERFORM idempotency_complete(v_claim.claim_id, v_claim.current_token,
                                             NULL, false, SQLERRM);
            EXCEPTION WHEN OTHERS THEN NULL;
            END;
        END IF;
        RAISE EXCEPTION USING ERRCODE = SQLSTATE, MESSAGE = SQLERRM;
END
$$;

COMMENT ON FUNCTION transition_order(uuid, text, text, integer, uuid) IS
    'Move a document to its next status, with a reason. Four rules, all read from order_lifecycle '
    'rather than listed here: the target must be a status this type has; a terminal state cannot be '
    'left; a status whose register row says it reports a stock movement cannot be set by a decision '
    'at all (that is 0030''s doors, and it is what stops "mark it shipped" from making a document '
    'disagree with its ledger); and the only step backwards is into CANCELLED. Pass '
    'p_expected_version to make a stale read a conflict (40001) instead of a lost update — the '
    'version column is maintained by 0011''s trigger, not by this body. closed_at is stamped on the '
    'way into a terminal state and only there, because orders_terminal_states_are_stamped is the '
    'constraint that asks the question. With p_idempotency_key a retried call is one transition. '
    'Built by 0028.';

-- ---------------------------------------------------------------------------
-- 9. The read paths — ADR-003: a read names a view
-- ---------------------------------------------------------------------------
-- Two, because there are two grains. A header read answers "what is this document worth and where is
-- it"; a line read answers "what is on it and how far has each part got". The totals are computed
-- here, once, by one grouped pass over the lines — which is what makes them unable to disagree with
-- the lines, and what 0022 concluded about doing aggregates per row in a loop.
CREATE OR REPLACE VIEW vw_orders AS
SELECT o.tenant_id,
       o.order_id,
       o.order_type,
       o.order_number,
       o.status,
       o.origin,
       lc.ordinal            AS lifecycle_position,
       lc.terminal           AS is_terminal,
       lc.stock_moving       AS reports_a_movement,
       o.customer_id,
       cu.name               AS customer_name,
       o.vendor_id,
       su.supplier_code      AS vendor_code,
       ve.name               AS vendor_name,
       o.warehouse_id,
       wh.name               AS warehouse_name,
       o.currency_code,
       o.ordered_date,
       o.required_date,
       o.closed_at,
       o.priority,
       o.notes,
       o.status_reason,
       o.created_by,
       o.created_at,
       o.updated_at,
       o.version,
       coalesce(l.line_count, 0)          AS line_count,
       coalesce(l.total_amount, 0)::numeric(38,10) AS total_amount,
       coalesce(l.total_quantity, 0)      AS total_quantity,
       coalesce(l.fulfilled_amount, 0)::numeric(38,10) AS fulfilled_amount,
       -- Open value: what the lines are worth that have not been fully delivered or cancelled. The
       -- question a procurement conversation actually asks, and it is arithmetic over the same
       -- grouped pass rather than a second query per order.
       coalesce(l.open_amount, 0)::numeric(38,10) AS open_amount
  FROM orders o
  LEFT JOIN order_lifecycle lc ON lc.order_type = o.order_type AND lc.status_code = o.status
  LEFT JOIN entities cu        ON cu.id = o.customer_id
  LEFT JOIN suppliers su        ON su.supplier_id = o.vendor_id
  LEFT JOIN entities ve         ON ve.id = su.entity_id
  LEFT JOIN warehouses wh       ON wh.warehouse_id = o.warehouse_id
  LEFT JOIN (
        SELECT i.tenant_id,
               i.order_id,
               count(*)                                   AS line_count,
               sum(coalesce(i.line_amount, 0))            AS total_amount,
               sum(i.quantity)                            AS total_quantity,
               sum(coalesce(i.line_amount, 0)
                   * (i.quantity_fulfilled / i.quantity)) AS fulfilled_amount,
               sum(coalesce(i.line_amount, 0)
                   * ((i.quantity - i.quantity_fulfilled - i.quantity_cancelled)
                      / i.quantity))                     AS open_amount
          FROM order_items i
         GROUP BY i.tenant_id, i.order_id
       ) l ON l.tenant_id = o.tenant_id AND l.order_id = o.order_id;

ALTER VIEW vw_orders SET (security_invoker = true);
GRANT SELECT ON vw_orders TO afpc_readonly, afpc_auditor;

COMMENT ON VIEW vw_orders IS
    'One row per order, with the counterparty named, the lifecycle position the register gives it, '
    'and its totals derived from its own lines in one grouped pass — no total is stored on the header, '
    'so none can disagree with the lines. The vendor''s own name arrives through the supplier''s party '
    'row, which is what 0027''s design makes possible: a supplier is a party, so the same name shows '
    'here and in the communications history. tenant_id is exposed and the view runs as its invoker '
    '(0009). No LIMIT: order and limit belong to the caller (0017). Built by 0028.';

CREATE OR REPLACE VIEW vw_order_lines AS
SELECT i.tenant_id,
       i.order_id,
       o.order_number,
       o.order_type,
       o.status                   AS order_status,
       i.order_line_id,
       i.line_number,
       i.line_type,
       i.item_id,
       it.sku,
       it.name                    AS item_name,
       it.product_type            AS item_product_type,
       i.description,
       i.quantity,
       i.unit_of_measure,
       i.unit_price,
       i.line_amount,
       i.quantity_fulfilled,
       i.quantity_cancelled,
       (i.quantity - i.quantity_fulfilled - i.quantity_cancelled) AS quantity_open,
       -- The line''s state, named here rather than stored on the row: three numbers already say
       -- everything a status would, and a status column would be a fourth thing to keep honest.
       CASE
           WHEN i.quantity_cancelled = i.quantity THEN 'CANCELLED'
           WHEN i.quantity_fulfilled >= i.quantity THEN 'FULFILLED'
           WHEN i.quantity_fulfilled > 0 THEN 'PARTIAL'
           WHEN o.status IN ('CLOSED','CANCELLED') THEN 'UNFULFILLED_CLOSED'
           ELSE 'OPEN'
       END                        AS line_state,
       i.warehouse_id,
       wh.warehouse_code,
       i.lot_number,
       i.serial_numbers,
       i.required_date,
       i.notes,
       i.created_at,
       i.updated_at,
       i.version
  FROM order_items i
  JOIN orders o           ON o.order_id = i.order_id
  LEFT JOIN inventory_items it ON it.item_id = i.item_id
  LEFT JOIN warehouses wh  ON wh.warehouse_id = i.warehouse_id;

ALTER VIEW vw_order_lines SET (security_invoker = true);
GRANT SELECT ON vw_order_lines TO afpc_readonly, afpc_auditor;

COMMENT ON VIEW vw_order_lines IS
    'Every line on every order the caller can see, with the item it names and the progress it has '
    'made. line_state is derived from the three quantities rather than stored, so it cannot be out of '
    'date with them; UNFULFILLED_CLOSED is the state a purchasing review needs — a line on a dead '
    'document that never arrived — and it is visible here rather than nowhere. Built by 0028.';

-- ---------------------------------------------------------------------------
-- 10. Privileges — 0009's obligation, per object, because the default revoke is a no-op for functions
-- ---------------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION create_order(text, bigint, uuid, uuid, char(3), date, integer, text, text, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION add_order_line(uuid, uuid, text, numeric, numeric, varchar, text, uuid, date, text, text, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION transition_order(uuid, text, text, integer, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION afpc_line_type_matches_document() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION create_order(text, bigint, uuid, uuid, char(3), date, integer, text, text, uuid) TO afpc_app;
GRANT  EXECUTE ON FUNCTION add_order_line(uuid, uuid, text, numeric, numeric, varchar, text, uuid, date, text, text, uuid) TO afpc_app;
GRANT  EXECUTE ON FUNCTION transition_order(uuid, text, text, integer, uuid) TO afpc_app;

-- ---------------------------------------------------------------------------
-- 11. Verify by behaving
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_n        int := 0;
    v_ord      uuid;
    v_ord2     uuid;
    v_num      text;
    v_num2     text;
    v_line     uuid;
    v_lnum     integer;
    v_ent      bigint;
    v_sup      uuid;
    v_wh       uuid;
    v_item     uuid;
    v_item2    uuid;
    v_ok       boolean;
    v_msg      text;
    v_status   text;
    v_err      text;
    v_cname    text;
    v_found    bigint;
    v_wh2      uuid;   -- a warehouse and an item that belong to the OTHER tenant. Both are made
                 -- here rather than re-homed: from inside tenant 1 the wall hides a foreign id, so a
                 -- probe that reads one gets NULL, and a NULL in a composite key means "no
                 -- reference" and passes correctly while asserting nothing. And an INSERT...SELECT
                 -- that copies a real row's master-data references is how a fixture inherits shapes
                 -- this migration must not invent.
    v_ent2     bigint;   -- the SECOND tenant's party and supplier, kept in variables of their own.
                 -- An earlier draft wrote them over v_ent and v_sup, so every probe after K was
                 -- building tenant-one documents out of tenant-two counterparties and the composite
                 -- keys refused them — correctly, and for entirely the wrong reason.
    v_sup2     uuid;
    v_item_f   uuid;   -- the foreign tenant's item, named for what it is: reusing v_item2 here is
                 -- what made probe M's service line name another tenant's stock
    v_blind    bigint;  -- counted edges, never a party id: an earlier draft of this probe
                 -- INTO'd the second count into v_ent and probe L then tried to delete entity #6,
                 -- which is what a reused variable costs
    v_td       uuid;
    v_t2       uuid;
    v_key      uuid;
    v_before   bigint;
    v_total    numeric;
    v_sum      numeric;
    r          record;
BEGIN
    ------------------------------------------------------------------
    -- A. enrolled in every mechanism, asserted from the catalog. Written as a loop over the three
    --    new tables because the mechanisms are the same for each, and a table missing one is the
    --    finding — not the loop being shorter.
    ------------------------------------------------------------------
    FOR r IN SELECT t FROM unnest(ARRAY['orders','order_items','document_counters']) AS t
    LOOP
        IF (SELECT count(*) FROM information_schema.columns
             WHERE table_name = r.t AND column_name = 'tenant_id'
               AND is_nullable = 'NO' AND data_type = 'uuid'
               AND column_default LIKE 'afpc_current_tenant%') <> 1 THEN
            RAISE EXCEPTION 'A failed: %.tenant_id is not the tenancy column 0003 prescribes', r.t;
        END IF;
        IF (SELECT count(*) FROM pg_class c WHERE c.oid = format('public.%I', r.t)::regclass
             AND c.relrowsecurity AND c.relforcerowsecurity) <> 1 THEN
            RAISE EXCEPTION 'A failed: % is not ENABLE+FORCE row secured (B7)', r.t;
        END IF;
        IF (SELECT count(*) FROM pg_policy po
             WHERE po.polrelid = format('public.%I', r.t)::regclass
               AND po.polname = 'tenant_isolation'
               AND po.polqual IS NOT NULL AND po.polwithcheck IS NOT NULL) <> 1 THEN
            RAISE EXCEPTION 'A failed: %.tenant_isolation has no WITH CHECK half, so writes would '
                            'not be filtered', r.t;
        END IF;
        IF (SELECT count(*) FROM pg_trigger tg WHERE tg.tgrelid = format('public.%I', r.t)::regclass
             AND tg.tgname = 'afpc_audit_row' AND NOT tg.tgisinternal) <> 1 THEN
            RAISE EXCEPTION 'A failed: no trail on % — 0013''s census cannot see a table born '
                            'after it, and vw_audit_coverage would report the disagreement (B26)', r.t;
        END IF;
        -- Every foreign key's columns must lead an index on this side, or the parent-side check is a
        -- scan. Checked by column-list containment because two of these tables' keys are composite.
        IF EXISTS (SELECT 1 FROM pg_constraint k
                    WHERE k.conrelid = format('public.%I', r.t)::regclass AND k.contype = 'f'
                      AND NOT EXISTS (SELECT 1 FROM pg_index i
                                       WHERE i.indrelid = k.conrelid
                                         AND i.indkey::int[] @> k.conkey::int[])) THEN
            SELECT string_agg(DISTINCT k.conname, ', ') INTO v_msg
              FROM pg_constraint k
             WHERE k.conrelid = format('public.%I', r.t)::regclass AND k.contype = 'f'
               AND NOT EXISTS (SELECT 1 FROM pg_index i
                                WHERE i.indrelid = k.conrelid AND i.indkey::int[] @> k.conkey::int[]);
            RAISE EXCEPTION 'A failed: % has a foreign key whose columns lead no index (%)', r.t, v_msg;
        END IF;
    END LOOP;
    -- The version counters, in the register's own words rather than this file's: B10 reads the
    -- trigger body for an assignment, and 0011's installer ran before these tables existed.
    IF (SELECT count(*) FROM pg_class c
         JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'version'
                            AND a.atttypid = 'integer'::regtype
         JOIN pg_trigger tg ON tg.tgrelid = c.oid AND tg.tgname = 'afpc_bump_version'
                            AND NOT tg.tgisinternal
         JOIN pg_proc p ON p.oid = tg.tgfoid AND lower(p.prosrc) ~ 'new[.]version[[:space:]]*:='
         WHERE c.relname IN ('orders','order_items')) <> 2 THEN
        RAISE EXCEPTION 'A failed: orders/order_items version columns are not both moved by a '
                        'trigger that assigns them — that is 6.1''s decorative counter, in a file '
                        'written to avoid it';
    END IF;
    -- The three composite FK targets this migration had to create. If any is missing the keys
    -- silently point at nothing useful, so they are asserted as objects and not as intentions.
    FOR r IN SELECT t FROM unnest(ARRAY['suppliers_tenant_supplier_key',
                                        'warehouses_tenant_warehouse_key',
                                        'inventory_items_tenant_item_key']) AS t
    LOOP
        IF to_regclass('public.' || r.t) IS NULL THEN
            RAISE EXCEPTION 'A failed: the composite FK target index % is absent, so the edge that '
                            'names it cannot be tenant-led', r.t;
        END IF;
    END LOOP;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- The fixtures, made through the doors rather than hand-inserted: a migration whose test data
    -- arrives by a path no caller uses is testing a shape the deployment never sees. The party comes
    -- from add_customer and the supplier from add_supplier LINKING that party, which is 0027's
    -- both-roles case exercised as a precondition rather than asserted as a claim.
    ------------------------------------------------------------------
    SELECT tenant_id INTO v_td FROM tenants WHERE slug = 'default';

    SELECT entity_id INTO v_ent
      FROM add_customer('0028', 'Steelfield', 'orders0028@afpc.example.invalid', '+15550128',
                        '1 River Rd', 'Chicago', NULL, NULL, 'US', 'active', 'business',
                        '0028 Steelfield Ltd', 'shipping', true, NULL);
    -- A street is given so the party has somewhere to ship, and the address type has to be one the
    -- published vocabulary admits: 'work' is not, which this line discovered by failing.
    SELECT supplier_id INTO v_sup
      FROM add_supplier('0028-SUP', v_ent, NULL, NULL, 'Net 30', NULL, NULL, NULL, true, NULL);
    SELECT warehouse_id INTO v_wh FROM warehouses ORDER BY default_warehouse DESC NULLS LAST,
                                                          warehouse_code LIMIT 1;
    -- Two items: one stocked, one a SERVICE. The pair that lets probe F assert both a catalog line
    -- and a one-off, which is the distinction the nullable item_id exists to make.
    SELECT item_id INTO v_item  FROM inventory_items
     WHERE product_type IN ('STOCKED','ASSEMBLY') ORDER BY sku LIMIT 1;
    SELECT item_id INTO v_item2 FROM inventory_items WHERE product_type = 'SERVICE'
     ORDER BY sku LIMIT 1;
    IF v_item IS NULL OR v_item2 IS NULL THEN
        RAISE EXCEPTION 'fixtures failed: the item master holds no stocked row (%) and no SERVICE '
                        'row (%), and the SERVICE value in product_type is what makes a non-goods '
                        'line a catalog line rather than a free-text excuse',
            coalesce(v_item::text,'none'), coalesce(v_item2::text,'none');
    END IF;

    ------------------------------------------------------------------
    -- B. the three document types, each with the counterparty its type requires — and each of the
    --    four ways of getting that wrong, refused by the constraint rather than by an IF arm.
    ------------------------------------------------------------------
    SELECT order_id, order_number INTO v_ord, v_num
      FROM create_order('SALES', v_ent, NULL, NULL, NULL, NULL, NULL, NULL, 'MANUAL', NULL);
    IF v_ord IS NULL OR v_num NOT LIKE 'SO-%' THEN
        RAISE EXCEPTION 'B failed: a sales order came back as % / %', v_ord, coalesce(v_num,'nothing');
    END IF;
    SELECT order_id INTO v_ord2 FROM create_order('PURCHASE', NULL, v_sup, NULL, NULL, NULL,
                                                  NULL, NULL, 'MANUAL', NULL);
    IF v_ord2 IS NULL THEN
        RAISE EXCEPTION 'B failed: a purchase order naming a supplier was refused';
    END IF;
    SELECT order_id INTO v_ord2 FROM create_order('WORK', NULL, NULL, v_wh, NULL, NULL, NULL,
                                                  '0028 build', 'MANUAL', NULL);
    IF v_ord2 IS NULL THEN
        RAISE EXCEPTION 'B failed: a work order with no counterparty was refused — the type that '
                        'exists precisely because production has no counterparty';
    END IF;

    v_err := NULL;
    BEGIN
        PERFORM * FROM create_order('SALES', NULL, v_sup, NULL, NULL, NULL, NULL, NULL, 'MANUAL', NULL);
    EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '23514' THEN
        RAISE EXCEPTION 'B failed: a sales order naming a SUPPLIER answered % — the counterparty '
                        'rule must be a constraint, not a memory', coalesce(v_err, 'no error: it was stored');
    END IF;
    v_err := NULL;
    BEGIN
        PERFORM * FROM create_order('PURCHASE', v_ent, NULL, NULL, NULL, NULL, NULL, NULL, 'MANUAL', NULL);
    EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '23514' THEN
        RAISE EXCEPTION 'B failed: a purchase order naming a CUSTOMER answered %', coalesce(v_err,'none');
    END IF;
    v_err := NULL;
    BEGIN
        PERFORM * FROM create_order('WORK', v_ent, v_sup, NULL, NULL, NULL, NULL, NULL, 'MANUAL', NULL);
    EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '23514' THEN
        RAISE EXCEPTION 'B failed: a work order naming BOTH counterparties answered % — production '
                        'has no counterparty and the CHECK is what says so', coalesce(v_err,'none');
    END IF;
    v_err := NULL;
    BEGIN
        PERFORM * FROM create_order('SALES', NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'MANUAL', NULL);
    EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '23514' THEN
        RAISE EXCEPTION 'B failed: a customer-less sales order answered % — an order for nobody is '
                        'not a document', coalesce(v_err, 'no error: it was stored');
    END IF;
    -- And the same refusal from the other seat, so the rule is shown to belong to the table and not
    -- to the function: an operator typing SQL gets the identical answer.
    v_err := NULL;
    BEGIN
        INSERT INTO orders (order_type, order_number, customer_id, vendor_id, origin)
        VALUES ('WORK', 'WO-999999', v_ent, NULL, 'MANUAL');
    EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '23514' THEN
        RAISE EXCEPTION 'B failed: a direct INSERT that contradicts the counterparty rule answered % '
                        '— if this passes, the rule moved into the door and the door is now the only '
                        'thing enforcing it', coalesce(v_err, 'no error: the row was stored');
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- C. the lifecycle: which pairs exist, stated by the register and enforced by a key.
    ------------------------------------------------------------------
    v_err := NULL;
    BEGIN
        INSERT INTO orders (order_type, order_number, status, origin)
        -- origin is MANUAL, not the type: a fourth value in that CHECK would answer 23514 before
        -- the lifecycle key ever spoke, and this probe would pass by proving the wrong thing.
        VALUES ('WORK', 'WO-999998', 'SHIPPED', 'MANUAL');
    EXCEPTION WHEN foreign_key_violation THEN
        v_err := '23503';
        GET STACKED DIAGNOSTICS v_cname = CONSTRAINT_NAME;
    END;
    IF v_err IS DISTINCT FROM '23503' THEN
        RAISE EXCEPTION 'C failed: a WORK order in status SHIPPED answered % — the pair is not in '
                        'order_lifecycle and a key should be the thing that noticed', coalesce(v_err,'none');
    END IF;
    IF v_cname IS DISTINCT FROM 'orders_lifecycle_applies' THEN
        RAISE EXCEPTION 'C failed: the refusal came from % rather than the lifecycle key, so some '
                        'other rule is doing this job by accident', v_cname;
    END IF;
    v_err := NULL;
    BEGIN
        INSERT INTO orders (order_type, order_number, status, origin)
        VALUES ('SALES', 'SO-999997', 'FROBNICATED', 'MANUAL');
    EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '23514' THEN
        RAISE EXCEPTION 'C failed: a status outside the published vocabulary answered %',
            coalesce(v_err, 'no error: it was stored');
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- D. transition_order's four rules, each shown to hold and each shown to refuse.
    ------------------------------------------------------------------
    SELECT order_id INTO v_ord FROM create_order('SALES', v_ent, NULL, NULL, NULL, NULL, NULL,
                                                 NULL, 'MANUAL', NULL);
    SELECT success, status INTO v_ok, v_status FROM transition_order(v_ord, 'CONFIRMED', NULL, NULL, NULL);
    IF NOT v_ok OR v_status <> 'CONFIRMED' THEN
        RAISE EXCEPTION 'D failed: DRAFT→CONFIRMED was refused: %', v_msg;
    END IF;
    -- Forward is fine, backwards is not...
    v_err := NULL;
    BEGIN
        PERFORM * FROM transition_order(v_ord, 'DRAFT', NULL, NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '23514' THEN
        RAISE EXCEPTION 'D failed: moving a confirmed order back to DRAFT answered % — a lifecycle '
                        'that runs backwards on request is a status column with extra stages',
            coalesce(v_err, 'no error: it happened');
    END IF;
    -- ...except into CANCELLED, which is the case that must NOT be refused by the direction rule.
    SELECT success INTO v_ok FROM transition_order(v_ord, 'CANCELLED', 'customer changed their mind',
                                                   NULL, NULL);
    IF NOT v_ok THEN
        RAISE EXCEPTION 'D failed: cancelling a confirmed order was refused by the direction rule — '
                        'the most common backward move a purchasing desk makes';
    END IF;
    -- A terminal state is the last word.
    v_err := NULL;
    BEGIN
        PERFORM * FROM transition_order(v_ord, 'CONFIRMED', NULL, NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '23514' THEN
        RAISE EXCEPTION 'D failed: reopening a cancelled order answered %', coalesce(v_err,'none');
    END IF;
    IF (SELECT closed_at FROM orders WHERE order_id = v_ord) IS NULL THEN
        RAISE EXCEPTION 'D failed: a terminal order with no closed_at — the door sets it and the '
                        'constraint asks for it, and neither fired';
    END IF;
    IF (SELECT status_reason FROM orders WHERE order_id = v_ord)
       IS DISTINCT FROM 'customer changed their mind' THEN
        RAISE EXCEPTION 'D failed: the reason for the cancellation was not recorded';
    END IF;
    -- The safety rule that is really about the ledger: no status that reports a stock movement can be
    -- set by a decision. This is the one that stops an agent talking its way into a shipped state.
    SELECT order_id INTO v_ord2 FROM create_order('SALES', v_ent, NULL, NULL, NULL, NULL, NULL,
                                                  NULL, 'MANUAL', NULL);
    v_err := NULL;
    BEGIN
        PERFORM * FROM transition_order(v_ord2, 'SHIPPED', NULL, NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '23514' THEN
        RAISE EXCEPTION 'D failed: marking an order SHIPPED without moving stock answered % — '
                        'stock_moving on the register is what refuses this, and 0030 is why',
            coalesce(v_err, 'no error: the document now claims a movement that did not happen');
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- E. optimistic concurrency, asserted by behaviour: the counter moves on its own, and a caller
    --    that read an older one is refused rather than silently overwriting.
    ------------------------------------------------------------------
    IF (SELECT version FROM orders WHERE order_id = v_ord2) <> 1 THEN
        RAISE EXCEPTION 'E failed: a fresh order has version % — 0011''s trigger either is not '
                        'attached or fires after the write it should count',
            (SELECT version FROM orders WHERE order_id = v_ord2);
    END IF;
    SELECT success INTO v_ok FROM transition_order(v_ord2, 'CONFIRMED', NULL, NULL, NULL);
    IF (SELECT version FROM orders WHERE order_id = v_ord2) <> 2 THEN
        RAISE EXCEPTION 'E failed: after one transition the version is %; the column is decoration',
            (SELECT version FROM orders WHERE order_id = v_ord2);
    END IF;
    v_err := NULL;
    BEGIN
        PERFORM * FROM transition_order(v_ord2, 'PICKING', NULL, 1, NULL);
    EXCEPTION WHEN serialization_failure THEN v_err := '40001';
    END;
    IF v_err IS DISTINCT FROM '40001' THEN
        RAISE EXCEPTION 'E failed: a write carrying a version the row has already passed answered % '
                        '— a lost update is exactly what 0011 installed the counter to make detectable',
            coalesce(v_err, 'no error: it overwrote the newer row');
    END IF;
    IF (SELECT status FROM orders WHERE order_id = v_ord2) <> 'CONFIRMED' THEN
        RAISE EXCEPTION 'E failed: the refused stale-version write changed the status anyway';
    END IF;
    SELECT success INTO v_ok FROM transition_order(v_ord2, 'PICKING', NULL, 2, NULL);
    IF NOT v_ok THEN
        RAISE EXCEPTION 'E failed: the correct-version retry did not succeed';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- F. the lines: what a line must name, what it cannot be, and what is computed rather than told.
    ------------------------------------------------------------------
    SELECT order_id INTO v_ord FROM create_order('SALES', v_ent, NULL, NULL, NULL, NULL, NULL,
                                                 NULL, 'MANUAL', NULL);
    SELECT success, order_line_id, line_number INTO v_ok, v_line, v_lnum
      FROM add_order_line(v_ord, v_item, NULL, 10, 5.5, NULL, 'STANDARD', NULL, NULL, NULL, NULL, NULL);
    IF NOT v_ok OR v_lnum <> 1 THEN
        RAISE EXCEPTION 'F failed: the first line on a fresh document landed at position %', v_lnum;
    END IF;
    -- The generated column, checked as arithmetic and as immutability. Both halves matter: the value
    -- is why the column exists, and the refusal is why it is not a second truth.
    SELECT line_amount, (quantity * unit_price) INTO v_total, v_sum
      FROM order_items WHERE order_line_id = v_line;
    IF v_total IS DISTINCT FROM v_sum OR v_total IS DISTINCT FROM 55.0::numeric THEN
        RAISE EXCEPTION 'F failed: line_amount is % where quantity × unit_price is %', v_total, v_sum;
    END IF;
    v_err := NULL;
    BEGIN
        UPDATE order_items SET line_amount = 1 WHERE order_line_id = v_line;
    EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE;
    END;
    IF v_err IS NULL THEN
        RAISE EXCEPTION 'F failed: a generated column was overwritten — the one derived value this '
                        'schema stores earns its place only by being unwritable';
    END IF;
    IF (SELECT line_amount FROM order_items WHERE order_line_id = v_line) <> 55.0 THEN
        RAISE EXCEPTION 'F failed: the refused write changed line_amount anyway';
    END IF;
    -- The unit arrived from the ITEM MASTER, which is 0014/0015's precedent and the whole argument
    -- against a caller picking a second answer.
    IF (SELECT i.unit_of_measure FROM order_items i WHERE i.order_line_id = v_line)
       IS DISTINCT FROM (SELECT base_unit_of_measure FROM inventory_items WHERE item_id = v_item) THEN
        RAISE EXCEPTION 'F failed: a blank unit_of_measure did not resolve through the item master';
    END IF;

    v_err := NULL;
    BEGIN
        PERFORM * FROM add_order_line(v_ord, v_item, NULL, 0, 5, NULL, 'STANDARD', NULL, NULL,
                                      NULL, NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '23514' THEN
        RAISE EXCEPTION 'F failed: a zero quantity answered % (expected the CHECK''s own 23514)',
            coalesce(v_err, 'no error: it was stored');
    END IF;
    v_err := NULL;
    BEGIN
        PERFORM * FROM add_order_line(v_ord, NULL, '   ', 1, 100, 'EACH', 'STANDARD', NULL, NULL,
                                      NULL, NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '23514' THEN
        RAISE EXCEPTION 'F failed: a line naming neither an item nor anything answered %',
            coalesce(v_err, 'no error: an unnameable line was stored');
    END IF;
    -- The one-off service line: no item, a description, a unit someone had to name.
    SELECT order_line_id INTO v_line
      FROM add_order_line(v_ord, NULL, 'Calibrate the yard scale', 1, 850, 'HR', 'STANDARD', NULL,
                          NULL, NULL, NULL, NULL);
    IF v_line IS NULL THEN
        RAISE EXCEPTION 'F failed: a description-only line was refused — item_id is nullable exactly '
                        'so that a purchase order can procure a service that is not in the catalog';
    END IF;
    v_err := NULL;
    BEGIN
        PERFORM * FROM add_order_line(v_ord, NULL, 'no unit at all', 1, 10, NULL, 'STANDARD', NULL,
                                      NULL, NULL, NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '23502' THEN
        RAISE EXCEPTION 'F failed: a non-catalog line with no unit answered % — the column''s NOT NULL '
                        'is the answer, because there is no item to resolve one from',
            coalesce(v_err, 'no error: it was stored');
    END IF;
    -- A line cannot be more than itself.
    v_err := NULL;
    BEGIN
        UPDATE order_items SET quantity_fulfilled = quantity + 1 WHERE order_line_id = v_line;
    EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '23514' THEN
        RAISE EXCEPTION 'F failed: fulfilling beyond the quantity answered % — 0030''s doors are the '
                        'reason this invariant is in DDL and not in a door', coalesce(v_err,'none');
    END IF;
    -- And the line-role rule, which no CHECK can state because it lives across two tables.
    v_err := NULL;
    BEGIN
        PERFORM * FROM add_order_line(v_ord, v_item, NULL, 2, NULL, NULL, 'COMPONENT', NULL, NULL,
                                      NULL, NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '23514' THEN
        RAISE EXCEPTION 'F failed: a COMPONENT line on a SALES order answered % — the after-row '
                        'trigger is the only place this rule can live, so it is the only place it may live',
            coalesce(v_err, 'no error: a sales order grew a bill of materials');
    END IF;
    SELECT order_id INTO v_ord2 FROM create_order('WORK', NULL, NULL, v_wh, NULL, NULL, NULL, NULL,
                                                  'MANUAL', NULL);
    SELECT success INTO v_ok FROM add_order_line(v_ord2, v_item, NULL, 4, NULL, NULL, 'COMPONENT',
                                                 NULL, NULL, NULL, NULL, NULL);
    IF NOT v_ok THEN
        RAISE EXCEPTION 'F failed: a COMPONENT line on a WORK order was refused — the trigger '
                        'disagrees with the type axis it is supposed to enforce';
    END IF;
    SELECT success INTO v_ok FROM add_order_line(v_ord2, v_item, NULL, 1, NULL, NULL, 'PRODUCT',
                                                 NULL, NULL, NULL, NULL, NULL);
    IF NOT v_ok THEN
        RAISE EXCEPTION 'F failed: the PRODUCT line a work order yields was refused';
    END IF;
    -- No two lines share a position, and the retry loop earned its keep rather than hiding a bug.
    IF (SELECT count(*) FROM order_items i WHERE i.order_id = v_ord2) <> 2
       OR (SELECT count(DISTINCT i.line_number) FROM order_items i WHERE i.order_id = v_ord2) <> 2 THEN
        RAISE EXCEPTION 'F failed: two lines on one work order occupy % distinct positions',
            (SELECT count(DISTINCT i.line_number) FROM order_items i WHERE i.order_id = v_ord2);
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- G. the numbers. Unique per tenant, monotonic within a period, and prefixed by the type that
    --    produced them — which is the mapping create_order contains and no constraint can complete
    --    alone (orders_number_prefix_matches_type checks the row against itself; only behaviour
    --    checks it against the counter).
    ------------------------------------------------------------------
    v_before := 0;
    v_msg := '';   -- the loop compares against the previous allocation, so it starts empty rather
                   -- than against whatever the last probe left in the variable
    FOR r IN SELECT 1 AS x FROM generate_series(1, 4) LOOP
        SELECT order_number INTO v_num
          FROM create_order('SALES', v_ent, NULL, NULL, NULL, NULL, NULL, NULL, 'MANUAL', NULL);
        IF v_num IS NULL OR v_num <= coalesce(v_msg, '') THEN
            RAISE EXCEPTION 'G failed: allocation % gave % after %, so the counter is not the lock '
                            'this file claims it is', r.x, v_num, coalesce(v_msg, 'nothing');
        END IF;
        v_msg := v_num;
        v_before := v_before + 1;
    END LOOP;
    IF (SELECT count(DISTINCT o.order_number) FROM orders o
         WHERE o.order_type = 'SALES' AND o.tenant_id = v_td) < 5 THEN
        RAISE EXCEPTION 'G failed: % sales orders share % distinct numbers',
            (SELECT count(*) FROM orders WHERE order_type = 'SALES'),
            (SELECT count(DISTINCT order_number) FROM orders WHERE order_type = 'SALES');
    END IF;
    -- All three prefixes, from the three types, in one pass: the totality of the mapping, measured
    -- from the rows rather than from the body that writes them.
    SELECT string_agg(prefix, ',' ORDER BY prefix) INTO v_msg
      FROM (SELECT DISTINCT split_part(order_number, '-', 1) AS prefix FROM orders) x;
    IF v_msg IS DISTINCT FROM 'PO,SO,WO' THEN
        RAISE EXCEPTION 'G failed: the prefixes in use are % — every order_type must map to exactly '
                        'one document prefix, or a type exists that cannot be numbered', v_msg;
    END IF;
    IF EXISTS (SELECT 1 FROM orders WHERE order_number NOT LIKE
                CASE order_type WHEN 'SALES' THEN 'SO-%' WHEN 'PURCHASE' THEN 'PO-%'
                               WHEN 'WORK' THEN 'WO-%' END) THEN
        RAISE EXCEPTION 'G failed: a document carries a number whose prefix contradicts its type';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- H. the lists agree. Every one of these is derived from the catalog rather than restated, so
    --    what fails is a divergence between two places that were both edited, which is the failure
    --    0018 named as "the second copy that rots while looking green".
    ------------------------------------------------------------------
    SELECT string_agg(v, ',' ORDER BY v) INTO v_msg
      FROM (SELECT DISTINCT m[1] AS v FROM regexp_matches(
              (SELECT pg_get_constraintdef(oid) FROM pg_constraint
                WHERE conname = 'orders_type_allowed'), '''([^'']+)''', 'g') m) x;
    IF v_msg IS DISTINCT FROM 'PURCHASE,SALES,WORK' THEN
        RAISE EXCEPTION 'H failed: orders publishes % as its document types', v_msg;
    END IF;
    SELECT string_agg(t, ',' ORDER BY t) INTO v_cname
      FROM (SELECT DISTINCT order_type AS t FROM order_lifecycle) y;
    IF v_cname IS DISTINCT FROM v_msg THEN
        RAISE EXCEPTION 'H failed: order_lifecycle covers (%) different types than orders publishes '
                        '(%), so a type exists that cannot have a lifecycle or a lifecycle with no '
                        'document', v_cname, v_msg;
    END IF;
    SELECT string_agg(v, ',' ORDER BY v) INTO v_msg
      FROM (SELECT DISTINCT m[1] AS v FROM regexp_matches(
              (SELECT pg_get_constraintdef(oid) FROM pg_constraint
                WHERE conname = 'orders_status_allowed'), '''([^'']+)''', 'g') m) x;
    SELECT string_agg(DISTINCT status_code, ',' ORDER BY status_code) INTO v_cname
      FROM order_lifecycle;
    IF v_cname IS DISTINCT FROM v_msg THEN
        RAISE EXCEPTION 'H failed: the status vocabulary (%) and the lifecycle register (%) are not '
                        'the same list — one of them is a value no document can hold', v_msg, v_cname;
    END IF;
    -- orders' types must be a subset of the ones inventory_reservations already admits. This is the
    -- drift 0022 refused to trust for an outcome pair, and here it decides whether a reservation can
    -- name the document it belongs to.
    IF EXISTS (SELECT 1 FROM (SELECT DISTINCT order_type FROM order_lifecycle) o
                WHERE NOT EXISTS (
                    SELECT 1 FROM pg_constraint k
                     WHERE k.conname = 'inventory_reservations_order_type_allowed'
                       AND k.convalidated
                       AND position(quote_literal(o.order_type) IN
                                     pg_get_constraintdef(k.oid)) > 0)) THEN
        RAISE EXCEPTION 'H failed: an order type exists that inventory_reservations would refuse, so '
                        'reserving stock for that document cannot be expressed';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- I. a retried call is one operation, on all three doors.
    ------------------------------------------------------------------
    v_key := gen_random_uuid();
    SELECT order_id INTO v_ord FROM create_order('SALES', v_ent, NULL, NULL, NULL, NULL, NULL,
                                                 '0028 idempotent', 'MANUAL', v_key);
    SELECT order_id INTO v_ord2 FROM create_order('SALES', v_ent, NULL, NULL, NULL, NULL, NULL,
                                                  '0028 idempotent', 'MANUAL', v_key);
    IF v_ord2 IS DISTINCT FROM v_ord THEN
        RAISE EXCEPTION 'I failed: the replayed create answered with a different order id';
    END IF;
    IF (SELECT count(*) FROM orders WHERE notes = '0028 idempotent') <> 1 THEN
        RAISE EXCEPTION 'I failed: one claim produced % orders',
            (SELECT count(*) FROM orders WHERE notes = '0028 idempotent');
    END IF;
    -- Same key, different request: a conflict, never a cache hit (0011's fingerprint).
    v_err := NULL;
    BEGIN
        PERFORM * FROM create_order('SALES', v_ent, NULL, NULL, NULL, NULL, NULL,
                                   '0028 DIFFERENT', 'MANUAL', v_key);
    EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM 'P0001' THEN
        RAISE EXCEPTION 'I failed: reusing a settled key for a different request answered % — the '
                        'fingerprint is what makes that a conflict rather than a wrong answer',
            coalesce(v_err, 'no error: it replayed someone else''s order');
    END IF;
    v_key := gen_random_uuid();
    SELECT order_line_id INTO v_line FROM add_order_line(v_ord, v_item, NULL, 3, 7, NULL, 'STANDARD',
                                                         NULL, NULL, NULL, NULL, v_key);
    SELECT order_line_id INTO v_line FROM add_order_line(v_ord, v_item, NULL, 3, 7, NULL, 'STANDARD',
                                                         NULL, NULL, NULL, NULL, v_key);
    IF (SELECT count(*) FROM order_items i WHERE i.order_id = v_ord
          AND i.quantity = 3 AND i.unit_price = 7) <> 1 THEN
        RAISE EXCEPTION 'I failed: a replayed line add produced % rows',
            (SELECT count(*) FROM order_items WHERE order_id = v_ord AND quantity = 3);
    END IF;
    IF (SELECT count(*) FROM vw_idempotency_status s
         WHERE s.function IN ('create_order','add_order_line','transition_order')
           AND NOT s.unguarded) <> 3 THEN
        RAISE EXCEPTION 'I failed: the idempotency register credits % of the three order doors with '
                        'a claim — either the wiring is partial or the derivation stopped seeing it',
            (SELECT count(*) FROM vw_idempotency_status s
              WHERE s.function IN ('create_order','add_order_line','transition_order')
                AND NOT s.unguarded);
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- J. the registers notice these tables by themselves, and the trail is real rather than attached.
    ------------------------------------------------------------------
    FOR r IN SELECT t FROM unnest(ARRAY['orders','order_items','document_counters']) AS t LOOP
        SELECT verdict INTO v_msg FROM vw_timestamp_status WHERE table_name = r.t;
        IF v_msg IS DISTINCT FROM 'maintained' THEN
            RAISE EXCEPTION 'J failed: the timestamp register says % of %', coalesce(v_msg,'nothing'), r.t;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM vw_audit_coverage a WHERE a.table_name = r.t AND a.row_audited) THEN
            RAISE EXCEPTION 'J failed: % is not trailead, and vw_audit_coverage''s scope is the '
                            'catalog''s, so B26 counts this disagreement', r.t;
        END IF;
    END LOOP;
    IF (SELECT count(*) FROM audit_log WHERE table_name = 'orders' AND action = 'INSERT') < 8 THEN
        RAISE EXCEPTION 'J failed: % audit rows for orders after a probe that created at least eight',
            (SELECT count(*) FROM audit_log WHERE table_name = 'orders' AND action = 'INSERT');
    END IF;
    -- Per segment, never a total: 0013's obligation about counting the trail.
    IF (SELECT count(*) FROM audit_chain_verify() WHERE NOT chain_ok) <> 0 THEN
        SELECT string_agg(reason, ' / ') INTO v_msg FROM audit_chain_verify() WHERE NOT chain_ok;
        RAISE EXCEPTION 'J failed: the chain does not verify after 0028 added three trailed tables — %',
            v_msg;
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- K. tenancy, in both directions, in the seats the wall binds. The point of this probe is not
    --    that another tenant's row is invisible — 0009 established that — it is that a KEY cannot be
    --    satisfied by one, which is the difference 0027 measured and 0028 extends to four more
    --    edges. Each refusal is asserted by constraint name, because a different rule firing for the
    --    right reason is still a rule nobody intended.
    ------------------------------------------------------------------
    INSERT INTO tenants (name, slug) VALUES ('0028 second tenant', 'afpc-0028-t2')
     RETURNING tenant_id INTO v_t2;
    INSERT INTO warehouses (tenant_id, warehouse_code, name, warehouse_type)
    SELECT v_t2, '0028T2', w.name || ' (tenant two)', w.warehouse_type FROM warehouses w LIMIT 1;
    INSERT INTO inventory_items (tenant_id, sku, name, product_type, base_unit_of_measure,
                                 cost_method, currency_code, reorder_point, category_id)
    SELECT v_t2, '0028T2-' || i.sku, i.name || ' (tenant two)', i.product_type,
           i.base_unit_of_measure, i.cost_method, i.currency_code, i.reorder_point,
           i.category_id FROM inventory_items i LIMIT 1;
    SELECT warehouse_id INTO v_wh2 FROM warehouses WHERE tenant_id = v_t2 LIMIT 1;
    SELECT item_id INTO v_item_f FROM inventory_items WHERE tenant_id = v_t2 LIMIT 1;
    IF v_wh2 IS NULL OR v_item_f IS NULL THEN
        RAISE EXCEPTION 'K failed: could not make a foreign warehouse and item to test against, so '
                        'the two edges this probe has not yet proven are unproven';
    END IF;

    SET LOCAL ROLE afpc_app;
    PERFORM set_config('app.tenant_id', v_t2::text, true);
    SELECT entity_id INTO v_ent2
      FROM add_customer('0028', 'Other Tenant', 't2orders0028@afpc.example.invalid', NULL, NULL,
                        NULL, NULL, NULL, 'US', 'active', 'business', '0028 Other Tenant Ltd',
                        'work', true, NULL);
    -- An email is not decoration: add_customer refuses a customer with no contact point, which is
    -- 0016's rule that an empty selector is refused before any work, discovered here by the fixture
    -- coming back with a NULL id and the next line blaming the wrong door.
    SELECT supplier_id INTO v_sup2
      FROM add_supplier('0028-T2-SUP', v_ent2, NULL, NULL, NULL, NULL, NULL, NULL, true, NULL);
    RESET ROLE;

    SET LOCAL ROLE afpc_app;
    PERFORM set_config('app.tenant_id', v_td::text, true);
    FOR r IN SELECT t FROM unnest(ARRAY['orders_customer_in_tenant_fkey',
                                         'orders_vendor_in_tenant_fkey',
                                         'orders_warehouse_in_tenant_fkey']) AS t LOOP
        v_err := NULL;
        BEGIN
            IF r.t = 'orders_customer_in_tenant_fkey' THEN
                INSERT INTO orders (order_type, order_number, customer_id, origin)
                VALUES ('SALES', 'SO-999990', v_ent2, 'MANUAL');
            ELSIF r.t = 'orders_vendor_in_tenant_fkey' THEN
                INSERT INTO orders (order_type, order_number, vendor_id, origin)
                VALUES ('PURCHASE', 'PO-999990', v_sup2, 'MANUAL');
            ELSE
                INSERT INTO orders (order_type, order_number, warehouse_id, origin)
                VALUES ('WORK', 'WO-999990', v_wh2, 'MANUAL');
            END IF;
        EXCEPTION WHEN foreign_key_violation THEN
            v_err := '23503';
            GET STACKED DIAGNOSTICS v_cname = CONSTRAINT_NAME;
        END;
        IF v_err IS DISTINCT FROM '23503' THEN
            RAISE EXCEPTION 'K failed: naming another tenant''s % answered % — the composite key is '
                            'the only thing between this database and a document about someone '
                            'else''s data', r.t, coalesce(v_err, 'no error: it was WRITTEN');
        END IF;
        IF v_cname IS DISTINCT FROM r.t THEN
            RAISE EXCEPTION 'K failed: the refusal for % arrived from % instead', r.t, v_cname;
        END IF;
    END LOOP;
    -- A line naming another tenant's item is the same class of mistake, and one step further from
    -- home: it would commit stock that is not theirs to commit.
    v_err := NULL;
    BEGIN
        INSERT INTO order_items (order_id, line_number, item_id, quantity, unit_of_measure)
        SELECT o.order_id, 99, v_item_f, 1, 'EACH'
          FROM orders o
         WHERE o.tenant_id = v_td AND o.order_type = 'SALES' LIMIT 1;
    EXCEPTION WHEN foreign_key_violation THEN
        v_err := '23503';
        GET STACKED DIAGNOSTICS v_cname = CONSTRAINT_NAME;
    END;
    IF v_err IS DISTINCT FROM '23503' OR v_cname IS DISTINCT FROM 'order_items_item_in_tenant_fkey' THEN
        RAISE EXCEPTION 'K failed: a line naming another tenant''s item answered % from %',
            coalesce(v_err,'no error'), coalesce(v_cname,'nothing');
    END IF;
    -- And the read paths show nothing across.
    IF EXISTS (SELECT 1 FROM vw_orders WHERE tenant_id <> v_td)
       OR EXISTS (SELECT 1 FROM vw_order_lines WHERE tenant_id <> v_td) THEN
        RAISE EXCEPTION 'K failed: an order read published another tenant''s document';
    END IF;
    RESET ROLE;
    SELECT count(*) FILTER (WHERE cardinality(conkey) > 1),
           count(*) FILTER (WHERE cardinality(conkey) = 1)
      INTO v_found, v_blind
      FROM pg_constraint
     WHERE contype = 'f' AND confrelid IN ('entities'::regclass,'suppliers'::regclass,
                                          'warehouses'::regclass,'inventory_items'::regclass);
    RAISE NOTICE 'K: % tenant-led document edge(s) now exist against % still-blind single-column '
                 'edges into the same tables; the blind ones are 0027''s owed list, and probe C '
                 'there watches the finding from both directions', v_found, v_blind;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- L. delete safety, demonstrated rather than declared: every edge this file adds is RESTRICT, so
    --    the parent-side deletes must refuse and say which key refused.
    ------------------------------------------------------------------
    SELECT order_id INTO v_ord FROM create_order('SALES', v_ent, NULL, NULL, NULL, NULL, NULL,
                                                 '0028 delete-me', 'MANUAL', NULL);
    PERFORM * FROM add_order_line(v_ord, v_item, NULL, 1, 1, NULL, 'STANDARD', NULL, NULL, NULL,
                                  NULL, NULL);
    v_err := NULL;
    BEGIN
        DELETE FROM orders WHERE order_id = v_ord;
    EXCEPTION WHEN foreign_key_violation THEN
        v_err := '23503';
        GET STACKED DIAGNOSTICS v_cname = CONSTRAINT_NAME;
    END;
    IF v_err IS DISTINCT FROM '23503' THEN
        RAISE EXCEPTION 'L failed: deleting an order with lines answered % — 0008''s rule is that a '
                        'table holding facts does not take its children with it',
            coalesce(v_err, 'no error: the header and its line both vanished');
    END IF;
    DELETE FROM order_items WHERE order_id = v_ord;
    DELETE FROM orders WHERE order_id = v_ord;

    -- And the party an order names cannot be deleted from under it — the sentence the whole "keep the
    -- relationships consistent" instruction is short for.
    --
    -- On a party made for the test, not on the fixture party. The first draft reused v_ent and then
    -- spent four DELETEs discovering that a party used by eight probes has eight kinds of dependent:
    -- addresses, followups, communications, entity_relationships and 0027's supplier row all answer
    -- before the document edge does, each refusal true and each one masking the assertion. A party
    -- with exactly one order on it makes whichever key speaks the one being tested — which is what
    -- 0017's probe G argues: get the assertion to say the thing it names.
    SELECT entity_id INTO v_ent2
      FROM add_customer('0028L', 'Anchor', 'anchor0028@afpc.example.invalid', NULL, '1 Quay Rd',
                        'Hoboken', NULL, NULL, 'US', 'active', 'business', '0028 Anchor Ltd',
                        'shipping', true, NULL);
    DELETE FROM addresses WHERE entity_id = v_ent2;
    DELETE FROM entity_relationships WHERE entity_id = v_ent2;
    DELETE FROM contacts WHERE email = 'anchor0028@afpc.example.invalid';
    SELECT order_id INTO v_ord FROM create_order('SALES', v_ent2, NULL, NULL, NULL, NULL, NULL,
                                                 '0028 party-anchor', 'MANUAL', NULL);
    v_err := NULL;
    BEGIN
        DELETE FROM entities WHERE id = v_ent2;
    EXCEPTION WHEN foreign_key_violation THEN
        v_err := '23503';
        GET STACKED DIAGNOSTICS v_cname = CONSTRAINT_NAME;
    END;
    IF v_err IS DISTINCT FROM '23503' THEN
        RAISE EXCEPTION 'L failed: deleting a party an order names answered %',
            coalesce(v_err, 'no error: the document is now about a party that does not exist');
    END IF;
    IF v_cname IS DISTINCT FROM 'orders_customer_in_tenant_fkey' THEN
        RAISE EXCEPTION 'L failed: the party delete was refused by % rather than by the document '
                        'edge under test', v_cname;
    END IF;
    -- The other direction, which is what makes this a proof and not merely a refusal: remove the
    -- order and the party is free. A key that held a party forever would pass the first half too.
    DELETE FROM order_items WHERE order_id = v_ord;
    DELETE FROM orders WHERE order_id = v_ord;
    BEGIN
        DELETE FROM entities WHERE id = v_ent2;
        v_msg := 'freed';
    EXCEPTION WHEN foreign_key_violation THEN
        v_msg := 'still held';
    END;
    IF v_msg IS DISTINCT FROM 'freed' THEN
        RAISE EXCEPTION 'L failed: the party is % after its only document went, so the edge that '
                        'refused the first delete was never the one under test', v_msg;
    END IF;
    v_n := v_n + 1;
    ------------------------------------------------------------------
    -- M. the derived totals are arithmetic and not decoration: the view's number is recomputed from
    --    the lines by a different expression and the two must agree. A view that computes a total
    --    correctly once is indistinguishable from one that does so by accident, which is 0017's
    --    argument about a record of a run agreeing with itself, moved to money.
    ------------------------------------------------------------------
    SELECT order_id INTO v_ord FROM create_order('PURCHASE', NULL, v_sup, NULL, NULL, NULL, NULL,
                                                 NULL, 'MANUAL', NULL);
    PERFORM * FROM add_order_line(v_ord, v_item,  NULL, 4,   12.25, NULL, 'STANDARD', NULL, NULL,
                                  NULL, NULL, NULL);
    PERFORM * FROM add_order_line(v_ord, NULL, 'Freight', 1, 250.5, 'HR', 'STANDARD', NULL, NULL,
                                  NULL, NULL, NULL);
    PERFORM * FROM add_order_line(v_ord, v_item2, NULL, 2, 60, NULL, 'STANDARD', NULL, NULL, NULL,
                                  NULL, NULL);
    UPDATE order_items SET quantity_fulfilled = 2 WHERE order_id = v_ord AND line_number = 1;

    SELECT total_amount, open_amount, line_count INTO v_total, v_sum, v_found
      FROM vw_orders WHERE order_id = v_ord;
    IF v_found <> 3 THEN
        RAISE EXCEPTION 'M failed: vw_orders counts % lines on a document with three', v_found;
    END IF;
    -- Recomputed by a different expression over the same rows. Two ways of writing one sum,
    -- agreeing, is the only evidence that neither is a coincidence.
    SELECT sum(coalesce(i.line_amount, 0))                                AS amt,
           sum(coalesce(i.line_amount, 0)
               * ((i.quantity - i.quantity_fulfilled - i.quantity_cancelled) / i.quantity)) AS amt_open
      INTO r
      FROM order_items i WHERE i.order_id = v_ord;
    IF v_total IS DISTINCT FROM r.amt THEN
        RAISE EXCEPTION 'M failed: vw_orders says % where the lines sum to % — the view is the only '
                        'place a total lives, so a disagreement here means one of the two '
                        'expressions was edited alone', v_total, r.amt;
    END IF;
    IF abs(coalesce(v_sum, 0) - coalesce(r.amt_open, 0)) > 0.0000001 THEN
        RAISE EXCEPTION 'M failed: open value is % in the view and % from the lines', v_sum, r.amt_open;
    END IF;
    -- The derived line state, which is the same claim one grain finer.
    SELECT string_agg(line_state, ',' ORDER BY line_number) INTO v_msg
      FROM vw_order_lines WHERE order_id = v_ord;
    IF v_msg IS DISTINCT FROM 'PARTIAL,OPEN,OPEN' THEN
        RAISE EXCEPTION 'M failed: three lines whose quantities say PARTIAL,OPEN,OPEN read as % — '
                        'a stored status could rot; a derived one can only be wrong in the view, '
                        'which is where this probe is looking', v_msg;
    END IF;
    IF (SELECT count(*) FROM vw_index_redundancy) <> 0 THEN
        RAISE EXCEPTION 'M failed: 0028 added a redundant index pair, which 0006''s invariant forbids';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    ------------------------------------------------------------------
    -- Cleanup, in the order the keys require: documents, then lines, then the party rows the
    -- documents held, and the peripheral rows of a party in the order the party model nests them —
    -- addresses reference contacts as well as entities, so an address has to go before either. This
    -- ordering is the same claim the DDL makes, demonstrated on the way out rather than asserted,
    -- and 0027's cleanup is where the shape was learned.
    ------------------------------------------------------------------
    -- Scoped by tenant, never unqualified. 0027's cleanup made this argument about itself and then
    -- three unqualified DELETEs appeared here; on a from-zero replay they are equivalent to nothing
    -- at all, which is exactly how an unqualified delete survives review. Replaying this file after
    -- the agents have used it must remove this probe's rows and no others.
    DELETE FROM order_items WHERE tenant_id IN (v_td, v_t2);
    DELETE FROM orders WHERE tenant_id IN (v_td, v_t2);
    DELETE FROM document_counters WHERE tenant_id IN (v_td, v_t2);
    DELETE FROM idempotency_keys WHERE operation IN ('create_order','add_order_line','transition_order');
    DELETE FROM suppliers WHERE entity_id IN (SELECT id FROM entities WHERE name LIKE '0028 %')
                           OR tenant_id = v_t2;
    DELETE FROM addresses WHERE entity_id IN (SELECT id FROM entities WHERE name LIKE '0028 %');
    DELETE FROM entity_relationships
     WHERE entity_id IN (SELECT id FROM entities WHERE name LIKE '0028 %')
        OR contact_id IN (SELECT id FROM contacts WHERE email IN
                ('orders0028@afpc.example.invalid','anchor0028@afpc.example.invalid',
                 't2orders0028@afpc.example.invalid'));
    DELETE FROM contacts WHERE email IN ('orders0028@afpc.example.invalid',
                                         'anchor0028@afpc.example.invalid',
                                         't2orders0028@afpc.example.invalid');
    DELETE FROM inventory_items WHERE tenant_id = v_t2;
    DELETE FROM warehouses WHERE tenant_id = v_t2;
    DELETE FROM entities WHERE name LIKE '0028 %' OR tenant_id = v_t2;
    DELETE FROM tenants WHERE slug = 'afpc-0028-t2';

    IF (SELECT count(*) FROM orders) <> 0 OR (SELECT count(*) FROM order_items) <> 0 THEN
        RAISE EXCEPTION 'cleanup failed: % orders and % lines remain; probes G and M count these '
                        'tables, so residue here becomes a false verdict two files away',
            (SELECT count(*) FROM orders), (SELECT count(*) FROM order_items);
    END IF;

    IF v_n <> 13 THEN
        RAISE EXCEPTION 'expected 13 behavioural verifications, completed %', v_n;
    END IF;
    RAISE NOTICE '0028: % checks passed - one header and one detail table carry three document types, '
                 'the counterparty rule and the lifecycle are constraints rather than memories, a '
                 'status that reports a stock movement cannot be talked into existence, totals are '
                 'derived so a header cannot disagree with its lines, and no document can name a '
                 'party, supplier, warehouse or item that is not its tenant''s', v_n;
END
$$;

-- ---------------------------------------------------------------------------
-- 12. Obligations this file leaves open, on purpose
-- ---------------------------------------------------------------------------
-- * `inventory_reservations.order_id` still points at nothing. That is 0030's, with the four
--   existing commitments it will backfill into orders of origin RESERVATION_BACKFILL and the
--   `order_line_id` column that will get its first writer. Doing the enforcement without the doors
--   that consume a commitment would refuse reservations whose documents could never be closed.
-- * `inventory_movements.reference_type` still maps WORK onto 'ORDER' and still admits 'TICKET',
--   which names a table 0017 deleted. Both are 0029's, because the mapping is only wrong the moment
--   a work order exists and the vocabulary change belongs with the door that would write it.
-- * No `reopen` transition exists, by design: the register has no way back out of a terminal state,
--   and a document that needs correcting is a new document pointing at the old one. If a deployment
--   genuinely needs reopen, the honest form is a transition that also writes why, and the terminal
--   flag belongs on the new pair rather than on the rule.
-- * The tenant-blind edges 0027 lists are unchanged here. Probe K counts them rather than fixing
--   them, so the number is in the log every run.
-- * `document_counters` has no retention policy, because it has nothing to retain: one row per
--   (tenant, kind, month) is bounded by the calendar. Unlike idempotency_keys, it does not need a
--   sweeper, and saying which counters do not need one is how the sweep's own list stays short.
-- * A per-tenant, per-kind, per-month counter row is a serialisation point if creates for one kind
--   become hot. The escape hatch is a bucket in the key and a wider lpad, not a different mechanism;
--   it is named here so that whoever measures contention finds the decision rather than the surprise.
