-- 0030: the doors that finish a document, and the commitment ledger that has never been released
--       (the orders programme, migration 4 of 4)
--
-- WHY THIS FILE EXISTS
--
-- 0015 gave this database the ability to hold stock for a document. Nothing gave it the ability to
-- stop holding it. That is not a missing convenience, it is a measured condition: four reservations
-- are live, thirteen units sit in `inventory_on_hand.quantity_reserved`, and there is no function in
-- `pg_proc` that ships, cancels or releases one. `shipped_quantity` and `cancelled_quantity` are
-- columns with no writer, so `quantity_available = quantity_on_hand - quantity_reserved` is a
-- number that only ever goes down. Every low-stock alert this server raises from here on is a little
-- more wrong than the last, and it is wrong in the direction that makes a warehouse look fuller than
-- it is not — reserved against documents that are finished, or fictional, or both.
--
--   reservation         type   qty  order_id                             names
--   (measured before this file ran: 4 rows, 13 units, 0 released)
--
-- Two of those order ids were minted by probes and one by the demo seed, and none of them names a
-- row in any table — because until 0028 there was no orders table to name. `inventory_reservations
-- .order_id` has been an unbacked uuid since 0001. So this file does three things in one order, and
-- the order matters:
--
--   1. BUILD the documents the commitments already claim (the backfill, §3). Not invent: a
--      reservation states a tenant, an item, a warehouse and a quantity, and every one of those is
--      a fact about a line. So the backfill writes an order and a line from the reservation's own
--      columns, which is 0004's rule for pre-existing data — merge what can be proved, refuse to
--      guess the rest — and it gives `order_line_id` its first writer, eight months after 0001
--      declared it.
--   2. ENFORCE the pointer (§3), so that no further commitment can name a document that does not
--      exist. Attaching it after the backfill is the whole point of doing them in this order: on a
--      database where step 1 has not run, step 2 refuses every reservation ever made again.
--   3. OPEN the doors that release stock (§5): ship, receive, produce, cancel. These are the four
--      places a document stops being a promise and becomes ledger, and they are the only writers of
--      the statuses 0028 marked `stock_moving` — which is the rule that makes "mark it shipped"
--      impossible and "ship it" possible.
--
-- WHAT THE DOORS SHARE, AND WHY THAT IS THE DESIGN
--
--   Every stock fact they write goes through `execute_inventory_movement`. 0014 built that function
--   as the one place the ledger and the balance are written together, with the bin plan from
--   `afpc_pick_bins`, the currency guard from 0018, and a claim of its own. A fulfilment door that
--   composed its own INSERT would be a second implementation of the balance arithmetic — which is
--   how 4.2 and 4.6 happened. So these four doors are document logic plus one call, and the
--   movement's line reference is passed through as a fifteenth defaulted parameter, added to the
--   installed head by capture-transform (§5.0) rather than retyped: 0029's method, and the reason
--   this file asserts each needle occurs exactly once before executing any of them.
--
-- WHAT THIS DOES NOT DO
--
--   * It does not enforce `inventory_movements.reference_id`. Measured: 36 movements, and the demo
--     seed invents a fresh uuid for every one of them, so a key would refuse the seed. The
--     reservation column is different in kind — NOT NULL, and it drives a balance — which is why
--     one gets enforced now and the other is recorded in §9 with the change that would make it
--     possible.
--   * It does not give a backfilled order a customer. Two of these documents were created by a
--     probe that named no party; `origin` says why the counterparty is empty, and probe D asserts
--     the alternative — inventing a party to satisfy a constraint — is not what happened.
--   * It installs no scheduler. `idempotency_sweep` still has no keeper; §9 says where the keeper
--     goes and why a migration cannot be the thing that runs it.

SET client_min_messages TO notice;

-- ---------------------------------------------------------------------------
-- 1. The ledger learns which LINE it moved
-- ---------------------------------------------------------------------------
-- 0028's header named the trap this closes: a receipt that arrives over six weeks cannot be
-- reconciled against a line from `reference_id` alone, because that column names a document and a
-- document has many lines. So either the line's `quantity_fulfilled` is a denormalised number that
-- can silently disagree with the ledger, or the ledger names the line. This migration does both
-- halves honestly: the column exists, the doors write it, and probe H asserts that the counter and
-- the sum of the ledger rows agree — so drift fails in the harness instead of at an audit.
--
-- It is a composite foreign key to order_items, for the reason 0027 measured and 0028 generalised:
-- a single-column key into a tenant-coded table is satisfied by another tenant's row. 0029's header
-- argued that a uuid naming no table is the `order_id` defect, and adding this column without its
-- key would be that argument, unapplied.
ALTER TABLE inventory_movements
    ADD COLUMN IF NOT EXISTS reference_line_id uuid;

COMMENT ON COLUMN inventory_movements.reference_line_id IS
    'Which line of the document this movement delivered, consumed or produced. NULL is normal and '
    'correct: an ADJUSTMENT has no document, and a movement against a single-line document needs no '
    'disambiguation. Where it is set, order_items.quantity_fulfilled stops being a number someone '
    'maintains and becomes a number that can be checked — this column is what a reconciliation has '
    'to join on. Added by 0030, which is also the first writer of it.';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'inventory_movements_reference_line_in_tenant_fkey') THEN
        ALTER TABLE inventory_movements
            ADD CONSTRAINT inventory_movements_reference_line_in_tenant_fkey
            FOREIGN KEY (tenant_id, reference_line_id)
            REFERENCES order_items (tenant_id, order_line_id) ON DELETE RESTRICT;
    END IF;
END
$$;

CREATE INDEX IF NOT EXISTS idx_movements_reference_line
    ON inventory_movements (tenant_id, reference_line_id);
CREATE INDEX IF NOT EXISTS idx_movements_tenant_reference_line
    ON inventory_movements (reference_line_id) WHERE reference_line_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 2. The release selector: the same drain order, run backwards
-- ---------------------------------------------------------------------------
-- A reservation's units are spread across bins by afpc_pick_bins (FEFO, then bin, then row id).
-- Giving them back has to walk the same rows in the same order, or two releases of the same
-- commitment land differently and the bin a picker was told about is not the bin that got freed.
-- 0015 wrote one helper for exactly that reason and said so in its own comment; this is the mirror
-- half of it, and probe G compares the two ORDER BY clauses out of pg_proc rather than trusting
-- that both files remember the rule — the same technique 0029 used on 0015's CASE mapping.
--
-- It selects on quantity_reserved, not quantity_available: picking by availability would take back
-- units that were never committed and free stock a different document is holding.
CREATE OR REPLACE FUNCTION afpc_release_bins(
    p_item      uuid,
    p_warehouse uuid,
    p_location  uuid,
    p_quantity  numeric
) RETURNS TABLE(on_hand_id uuid, bin_location uuid, units_released numeric)
LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    v_r    record;
    v_left numeric := p_quantity;
BEGIN
    FOR v_r IN
        SELECT h.on_hand_id, h.location_id, h.quantity_reserved
          FROM inventory_on_hand h
         WHERE h.item_id = p_item
           AND h.warehouse_id = p_warehouse
           AND (p_location IS NULL
                OR h.location_id IS NOT DISTINCT FROM p_location)
           AND h.quantity_reserved > 0
         ORDER BY h.expiry_date NULLS LAST, h.location_id NULLS FIRST, h.on_hand_id
           FOR UPDATE
    LOOP
        on_hand_id   := v_r.on_hand_id;
        bin_location := v_r.location_id;
        IF v_left > 0 THEN
            units_released := least(v_r.quantity_reserved, v_left);
            v_left := v_left - units_released;
        ELSE
            units_released := 0;
        END IF;
        RETURN NEXT;
    END LOOP;
END
$$;

COMMENT ON FUNCTION afpc_release_bins(uuid, uuid, uuid, numeric) IS
    'Which on-hand rows a release may give units back to, and how many from each: the mirror of '
    'afpc_pick_bins, same FEFO/bin/row-id order, selecting on quantity_reserved rather than '
    'quantity_available because a release returns a commitment and not free stock. Locks each '
    'candidate FOR UPDATE in that order and writes nothing, so a caller that decides to refuse has '
    'written nothing. Shortfall is sum(units_released) < requested, and 0030''s cancel door treats a '
    'shortfall as an inconsistency it reports rather than absorbs — reserved stock that has gone '
    'missing from the balance is a bug in another door, and silently releasing less would hide it. '
    'Probe G asserts the ORDER BY text agrees with 0015''s helper. Built by 0030.';

-- ---------------------------------------------------------------------------
-- 3. The backfill: the documents these commitments always claimed
-- ---------------------------------------------------------------------------
-- Written as a merge and not a repair script, because everything the new rows assert is already
-- asserted by a reservation: tenant, item, warehouse, quantity, document type. What is NOT
-- recoverable is the counterparty — one of these ids came from a probe that named no party — so the
-- order carries origin='RESERVATION_BACKFILL' and 0028's counterparty CHECK is read, in the same
-- breath, as the record of that gap rather than as a rule to route around.
DO $$
DECLARE
    v_ord      uuid;
    v_line     uuid;
    v_number   text;
    v_seq      bigint;
    v_res      record;
    v_n_orders int := 0;
    v_n_lines  int := 0;
    v_bad      text;
BEGIN
    ------------------------------------------------------------------
    -- (a) The ones that cannot be merged, refused rather than guessed at.
    -- A PURCHASE commitment with no resolvable order would need a supplier, and a supplier chosen by
    -- a migration is a spend record attributed to the wrong company — a worse error than an
    -- unresolvable pointer, which is at least visibly one. Measured on this database: zero rows in
    -- this bucket, all four are SALES. The refusal is here because it is the honest branch, not
    -- because it is expected to run.
    ------------------------------------------------------------------
    -- v_bad is the list, and the type falls out of the first entry rather than from a second query
    -- that could return several rows and abort the RAISE that is trying to explain the problem.
    SELECT string_agg(doc, ', ' ORDER BY doc) INTO v_bad
      FROM (SELECT DISTINCT format('%s order %s', r.order_type, r.order_id) AS doc
              FROM inventory_reservations r
             WHERE r.order_type IN ('PURCHASE','WORK')
               AND NOT EXISTS (SELECT 1 FROM orders o
                                WHERE o.tenant_id = r.tenant_id AND o.order_id = r.order_id)) d;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION '0030 cannot backfill a % commitment without a counterparty, and a supplier '
                        'or a plant chosen by a migration is a false attribution rather than a gap. '
                        'Rows involved: %',
            split_part(v_bad, ' ', 1), v_bad
            USING HINT = 'create the document, point the named reservation at it, then re-run; '
                        '0004''s rule is to merge what can be proved and refuse to guess the rest';
    END IF;

    ------------------------------------------------------------------
    -- (b) One order per distinct claimed document, with the reservation's own facts.
    ------------------------------------------------------------------
    FOR v_res IN
        SELECT DISTINCT r.tenant_id, r.order_id, r.order_type, r.warehouse_id,
               min(r.reserved_at) OVER (PARTITION BY r.tenant_id, r.order_id) AS first_at
          FROM inventory_reservations r
         WHERE r.order_type = 'SALES'
           AND NOT EXISTS (SELECT 1 FROM orders o
                            WHERE o.tenant_id = r.tenant_id AND o.order_id = r.order_id)
         ORDER BY r.tenant_id, r.order_id
    LOOP
        -- The number comes from the same allocator a raised order uses, so a backfilled document
        -- cannot collide with one a human raises next month, and the sequence stays monotonic across
        -- the import. lpad is create_order's, so the two agree by construction (probe I checks it).
        INSERT INTO document_counters (tenant_id, doc_type, period, next_value)
        VALUES (v_res.tenant_id, 'SO', to_char(coalesce(v_res.first_at, now()) AT TIME ZONE 'utc',
                                              'YYYYMM'), 1)
        ON CONFLICT (tenant_id, doc_type, period)
          DO UPDATE SET next_value = document_counters.next_value + 1
        RETURNING document_counters.next_value INTO v_seq;

        v_number := 'SO-' || lpad(v_seq::text, 6, '0');

        -- order_id is the one this file did not mint: keeping the existing value is what makes the
        -- commitment resolve instead of becoming a new fact beside the old one. It is a v7 where the
        -- probe minted one and a v4 where a probe used gen_random_uuid, and 0005's rule about key
        -- shape is satisfied by the column, not by the lineage of this particular row.
        INSERT INTO orders (order_id, tenant_id, order_type, order_number, status, origin,
                            warehouse_id, ordered_date, priority, notes, created_by)
        VALUES (v_res.order_id, v_res.tenant_id, 'SALES', v_number, 'CONFIRMED',
                'RESERVATION_BACKFILL', v_res.warehouse_id,
                (coalesce(v_res.first_at, now()) AT TIME ZONE 'utc')::date,
                NULL,
                'Backfilled by 0030 from commitments that already named this document id',
                'migration:0030')
        ON CONFLICT (order_id) DO NOTHING;
        v_n_orders := v_n_orders + 1;
    END LOOP;

    ------------------------------------------------------------------
    -- (c) The lines, and order_line_id's first writer since 0001 declared it.
    -- A reservation is a line: same item, same quantity, same warehouse, same due date. Writing one
    -- per commitment is a merge, and it is what lets ship/cancel name the line in the ledger (§1).
    ------------------------------------------------------------------
    FOR v_res IN
        SELECT r.tenant_id, r.reservation_id, r.item_id, r.warehouse_id, r.reserved_quantity,
               r.expected_ship_date, r.location_id, r.lot_number, r.serial_numbers, r.notes,
               o.order_id
          FROM inventory_reservations r
          JOIN orders o ON o.tenant_id = r.tenant_id AND o.order_id = r.order_id
         WHERE r.order_line_id IS NULL
           AND r.order_type IN ('SALES','PURCHASE')
         ORDER BY r.tenant_id, o.order_id, r.reserved_at, r.reservation_id
    LOOP
        INSERT INTO order_items (tenant_id, order_id, line_number, line_type, item_id, description,
                                 quantity, unit_price, unit_of_measure, warehouse_id, lot_number,
                                 serial_numbers, required_date, notes)
        VALUES (v_res.tenant_id, v_res.order_id,
                -- coalesce INSIDE the aggregate: 0029's probe C found this exact bug in the plan
                -- door two files ago, and an order's first line has max() = NULL.
                (SELECT coalesce(max(i.line_number), 0) + 1 FROM order_items i
                  WHERE i.order_id = v_res.order_id),
                'STANDARD', v_res.item_id,
                'Backfilled from reservation ' || v_res.reservation_id,
                v_res.reserved_quantity, NULL,
                (SELECT i.base_unit_of_measure FROM inventory_items i
                  WHERE i.item_id = v_res.item_id),
                v_res.warehouse_id, v_res.lot_number, v_res.serial_numbers,
                v_res.expected_ship_date,
                coalesce(v_res.notes, 'reserved_quantity is the ordered quantity here'))
        RETURNING order_items.order_line_id INTO v_line;

        UPDATE inventory_reservations
           SET order_line_id = v_line
         WHERE reservation_id = v_res.reservation_id;
        v_n_lines := v_n_lines + 1;
    END LOOP;

    RAISE NOTICE '0028/0029 built the documents; 0030 gave the % already-committed row(s) the % '
                 'line(s) they always were, so the reservation pointer now resolves',
                 (SELECT count(*) FROM inventory_reservations), v_n_lines;
END
$$;

-- ---------------------------------------------------------------------------
-- 3b. The enforcement, attached only once the rows above can satisfy it
-- ---------------------------------------------------------------------------
-- Two rules, both cross-row, neither expressible as a CHECK — which is the sentence ADR-002 spends
-- on the database half and this trigger answers:
--   * a commitment whose order_type is a document type must name a document of THAT type. The
--     column pair is the fact; today it is two numbers that agree only if the caller remembers.
--   * a commitment that names a line must name a line of the document it names. The composite key
--     in §4 proves the line exists and is the caller's; only this says it belongs to the order.
-- STOCK and TRANSFER holds are left alone, and that is not an oversight: 0015's CASE files a
-- TRANSFER hold's document id as 'TRANSFER' and a STOCK hold's as NULL, and there is no transfers
-- table for either to point at. Requiring a pointer to a nonexistent table would be 0029's objection
-- to an anticipatory column, applied to a trigger.
CREATE OR REPLACE FUNCTION afpc_reservation_names_a_document()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_type text;
BEGIN
    IF NEW.order_type NOT IN ('SALES','PURCHASE','WORK') THEN
        RETURN NEW;
    END IF;

    SELECT o.order_type INTO v_type
      FROM orders o WHERE o.order_id = NEW.order_id AND o.tenant_id = NEW.tenant_id;
    IF v_type IS NULL THEN
        RAISE EXCEPTION
            'inventory_reservations: order_type % names document %, and no % order the caller can '
            'see has that id', NEW.order_type, NEW.order_id, NEW.order_type
            USING ERRCODE = '23503',
                  HINT = 'raise it with create_order first; 0030 made document ids resolvable, and '
                         'a commitment naming nothing is the leak that file was written to close';
    END IF;
    IF v_type <> NEW.order_type THEN
        RAISE EXCEPTION
            'inventory_reservations: order_type % but document % is a % order',
            NEW.order_type, NEW.order_id, v_type
            USING ERRCODE = '23503',
                  HINT = 'the two columns are one claim about one document; agreeing by accident is '
                         'how a reservation ends up releasing the wrong warehouse''s stock';
    END IF;

    IF NEW.order_line_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM order_items i
             WHERE i.order_line_id = NEW.order_line_id AND i.order_id = NEW.order_id) THEN
        RAISE EXCEPTION
            'inventory_reservations: line % is not a line of order %',
            NEW.order_line_id, NEW.order_id
            USING ERRCODE = '23503',
                  HINT = 'the line exists and is the caller''s — §4''s key would have said so — but '
                         'it belongs to another document, and shipping against it would fulfil the '
                         'wrong order''s promise';
    END IF;

    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS afpc_reservation_names_a_document ON inventory_reservations;
CREATE TRIGGER afpc_reservation_names_a_document
    BEFORE INSERT OR UPDATE OF order_id, order_type, order_line_id ON inventory_reservations
    FOR EACH ROW EXECUTE FUNCTION afpc_reservation_names_a_document();

COMMENT ON TRIGGER afpc_reservation_names_a_document ON inventory_reservations IS
    'The pointer inventory_reservations.order_id has carried since 0001 finally has a meaning '
    'attached to it: for the three document types it must resolve to a live orders row of the same '
    'type, and a named line must belong to that order. Fires BEFORE so nothing is written before the '
    'refusal, and it does NOT fire on an UPDATE of shipped_quantity/cancelled_quantity, because a '
    'fulfilment door must be able to settle a commitment whose document has since been changed. '
    'STOCK and TRANSFER holds pass through: they name no document table (0015''s CASE already '
    'treats them that way). Built by 0030.';

-- ---------------------------------------------------------------------------
-- 4. And the same for the line column, in DDL where DDL can do it
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'inventory_reservations_order_line_in_tenant_fkey') THEN
        ALTER TABLE inventory_reservations
            ADD CONSTRAINT inventory_reservations_order_line_in_tenant_fkey
            FOREIGN KEY (tenant_id, order_line_id)
            REFERENCES order_items (tenant_id, order_line_id) ON DELETE RESTRICT;
    END IF;
END
$$;

CREATE INDEX IF NOT EXISTS idx_reservations_order_line
    ON inventory_reservations (tenant_id, order_line_id);

COMMENT ON CONSTRAINT inventory_reservations_order_line_in_tenant_fkey ON inventory_reservations IS
    'The column 0001 declared and nothing ever wrote, now pointed at 0028''s line table with the '
    'tenant in the key. It is the difference between "a commitment belongs to some order" and a '
    'commitment that can be joined to the line it will fulfil. The order-level pairing is a trigger''s '
    'job (§3b) because a CHECK cannot read another row; this one is a key''s job.';

-- ---------------------------------------------------------------------------
-- 4b. The settled commitment has to say WHEN it settled
-- ---------------------------------------------------------------------------
-- B24's rule is 6.3's: a function that rewrites a table's rows must leave a timestamp that moves.
-- inventory_reservations had created_at only, which was honest while nothing ever changed a
-- commitment after making it — 0015's door INSERTed and left, and no other function in pg_proc
-- touched a row. This file adds two that do, so the finding stops being theoretical: without this
-- column, "how long has this order been holding stock" and "was this hold released a week ago or a
-- year ago" are both unanswerable, which is precisely the question the leak raised.
--
-- NOT NULL with a DEFAULT, on four rows, in the same transaction as the doors: no backfill to
-- reason about, and 0003's posture that a tenancy-style column is not nullable.
ALTER TABLE inventory_reservations
    ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

COMMENT ON COLUMN inventory_reservations.updated_at IS
    'When the commitment last changed — reserved, settled by a shipment, or released. Added by 0030 '
    'because 0030 is the migration that first rewrote these rows after creation; before it, '
    'created_at was the whole history and 6.3 had nothing to complain about. Maintained by 0010''s '
    'trigger, not by the doors.';

DROP TRIGGER IF EXISTS afpc_touch_updated_at ON inventory_reservations;
CREATE TRIGGER afpc_touch_updated_at
    BEFORE INSERT OR UPDATE ON inventory_reservations
    FOR EACH ROW EXECUTE FUNCTION afpc_touch_updated_at();

-- ---------------------------------------------------------------------------
-- 5.0 One parameter added to the ledger door, so a fulfilment line can be named
-- ---------------------------------------------------------------------------
-- execute_inventory_movement is the only writer of the balance and the ledger together (0014), so
-- reference_line_id has to reach the ledger through it and not beside it. The head is edited the way
-- 0029 edited its CASE: read the installed definition, replace four asserted-once needles, drop by
-- identity arguments, recreate. The alternative — retyping a 200-line body that 0018 and 0026 each
-- amended — is a second implementation of the balance arithmetic, and 4.2/4.6 are what the schema
-- looks like when that happens.
--
-- The parameter is appended after the two location additions 0026 made, and defaulted, so every
-- positional call in the seeds and the harness keeps resolving to the same single head. probe F
-- counts heads, because 0014's own comment says why: CREATE OR REPLACE with a changed parameter list
-- does not replace, it overloads, and then every call to the name is ambiguous.
DO $$
DECLARE
    v_src  text;    -- the definition as installed, then progressively rewritten
    v_orig text;    -- kept only so the final comparison below means "changed", not "equal to itself"
    v_new  text;
    v_sig  text;
    v_n    int;
    v_newsig text;
    v_pair text[][] := ARRAY[
        [', p_to_location_id uuid DEFAULT NULL::uuid)',
         ', p_to_location_id uuid DEFAULT NULL::uuid, p_reference_line_id uuid DEFAULT NULL::uuid)'],
        ['reference_type, reference_id, reason_code, batch_id
    ) VALUES (',
         'reference_type, reference_id, reference_line_id, reason_code, batch_id
    ) VALUES ('],
        ['p_reference_type, p_reference_id, p_reason_code, v_batch_id
    ) RETURNING movement_id INTO v_movement_id;',
         'p_reference_type, p_reference_id, p_reference_line_id, p_reason_code, v_batch_id
    ) RETURNING movement_id INTO v_movement_id;'],
        ['''uom'', p_unit_of_measure));',
         '''uom'', p_unit_of_measure, ''line'', p_reference_line_id));']
    ];
    i int;
BEGIN
    SELECT pg_get_functiondef(p.oid),
           format('%s.%I(%s)', n.nspname, p.proname,
                  pg_get_function_identity_arguments(p.oid))
      INTO v_src, v_sig
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'execute_inventory_movement';
    IF v_src IS NULL THEN
        RAISE EXCEPTION '5.0 failed: execute_inventory_movement is not installed, so there is no '
                        'single ledger door for these fulfilment doors to call — the design below '
                        'assumes 0014''s function exists and is the only writer';
    END IF;

    -- Every needle asserted to occur exactly once BEFORE any replace. 0026 is the record of what a
    -- blind replace does to a VALUES list: it rotates it, and the door then "works" for the first
    -- seed call that happens to line up.
    FOR i IN SELECT unnest(ARRAY[1,2,3,4]) LOOP
        v_n := length(v_src) - length(replace(v_src, v_pair[i][1], ''));
        IF v_n <> length(v_pair[i][1]) THEN
            RAISE EXCEPTION '5.0 failed: needle % occurs % time(s) in the installed body, expected '
                            'exactly once — the body has been edited since this transform was '
                            'written, and a partial replace would produce a function that '
                            'compiles and mis-records every movement',
                i, CASE WHEN v_n = 0 THEN 0 ELSE v_n / length(v_pair[i][1]) END;
        END IF;
    END LOOP;

    v_orig := v_src;
    FOR i IN SELECT unnest(ARRAY[1,2,3,4]) LOOP
        v_new := replace(v_src, v_pair[i][1], v_pair[i][2]);
        v_src := v_new;
    END LOOP;
    IF v_src = v_orig THEN
        RAISE EXCEPTION '5.0 failed: four needles matched and the text still did not change — one of '
                        'the replacements is the same string as what it replaces';
    END IF;

    EXECUTE format('DROP FUNCTION %s', v_sig);
    EXECUTE v_src;

    -- The ACL, on the NEW head's identity arguments (the old signature no longer names anything).
    -- Closed to PUBLIC per object because ALTER DEFAULT PRIVILEGES REVOKE is a no-op for functions,
    -- and a fresh function object starts open — 0009's obligation restated by 0029 for the same edit.
    SELECT format('%s.%I(%s)', n2.nspname, p2.proname,
                  pg_get_function_identity_arguments(p2.oid)) INTO v_newsig
      FROM pg_proc p2 JOIN pg_namespace n2 ON n2.oid = p2.pronamespace
     WHERE n2.nspname = 'public' AND p2.proname = 'execute_inventory_movement';
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC', v_newsig);
    EXECUTE format('GRANT  EXECUTE ON FUNCTION %s TO afpc_app', v_newsig);

    SELECT count(*) INTO v_n FROM pg_proc WHERE proname = 'execute_inventory_movement';
    IF v_n <> 1 THEN
        RAISE EXCEPTION '5.0 failed: % heads of execute_inventory_movement are installed — 0014''s '
                        'comment says exactly this, and an overload makes every call to the name '
                        'ambiguous rather than merely wrong', v_n;
    END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- 5.1 cancel_inventory_reservation — the release that has never existed
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cancel_inventory_reservation(
    p_reservation_id  uuid    DEFAULT NULL,
    p_quantity        numeric DEFAULT NULL,
    p_reason          text    DEFAULT NULL,
    p_cancelled_by    text    DEFAULT NULL,
    p_idempotency_key uuid    DEFAULT NULL
) RETURNS TABLE(success boolean, reservation_id uuid, status text,
                released_quantity numeric, message text)
LANGUAGE plpgsql AS $$
DECLARE
    v_claim  record;
    v_state  text := '';
    v_res    record;
    v_open   numeric;
    v_take   numeric;
    v_released numeric := 0;
    v_r      record;
    v_uom    varchar(20);
    v_cur    char(3);
    v_mid    uuid;
    v_msg    text;
BEGIN
    IF p_reservation_id IS NULL THEN
        RAISE EXCEPTION 'cancel_inventory_reservation: p_reservation_id is required — a release '
                        'that names no commitment is a stock adjustment, and that door already '
                        'exists'
            USING ERRCODE = '22023';
    END IF;

    IF p_idempotency_key IS NOT NULL THEN
        SELECT * INTO v_claim FROM idempotency_claim(
            p_idempotency_key, 'cancel_inventory_reservation',
            jsonb_build_object('reservation', p_reservation_id, 'qty', p_quantity,
                               'reason', p_reason, 'by', p_cancelled_by));
        v_state := v_claim.claim_state;
        IF v_state = 'replay' THEN
            success           := (v_claim.cached_response ->> 'success')::boolean;
            reservation_id    := (v_claim.cached_response ->> 'reservation_id')::uuid;
            status            := v_claim.cached_response ->> 'status';
            released_quantity := (v_claim.cached_response ->> 'released')::numeric;
            message           := v_claim.cached_response ->> 'message';
            RETURN NEXT; RETURN;
        ELSIF v_state = 'in_progress' THEN
            RAISE EXCEPTION 'cancel_inventory_reservation: an attempt with key % is already in flight',
                p_idempotency_key USING ERRCODE = '40001';
        ELSIF v_state = 'conflict' THEN
            RAISE EXCEPTION 'cancel_inventory_reservation: key % was settled for a DIFFERENT request',
                p_idempotency_key USING ERRCODE = 'P0001';
        END IF;
    END IF;

    -- FOR UPDATE, in the door's stated order: commitment, then the balance rows it names, then the
    -- ledger. 0015's note about one drain order is the reason this is a sentence and not a hint —
    -- a concurrent ship of the same order must take the locks in the same sequence or the two
    -- deadlock on the same bin.
    SELECT r.reservation_id, r.item_id, r.warehouse_id, r.location_id, r.order_id,
           r.order_type, r.order_line_id, r.reserved_quantity,
           coalesce(r.shipped_quantity, 0) AS shipped, coalesce(r.cancelled_quantity, 0) AS cancelled,
           i.base_unit_of_measure, i.currency_code
      INTO v_res
      FROM inventory_reservations r
      JOIN inventory_items i ON i.item_id = r.item_id
     WHERE r.reservation_id = p_reservation_id
       FOR UPDATE OF r;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'cancel_inventory_reservation: reservation % is not a commitment this '
                        'connection can see', p_reservation_id
            USING ERRCODE = '22023',
                  HINT = 'another tenant''s id and one that was never made are the same refusal, '
                         'because row security hides the row before any key is consulted (0018)';
    END IF;

    v_open := v_res.reserved_quantity - v_res.shipped - v_res.cancelled;
    IF v_open <= 0 THEN
        -- Not a constraint's business: chk_reservation_quantities says a settlement cannot EXCEED the
        -- commitment, and a fully-settled one is inside that rule. Only the arithmetic here knows it
        -- is finished.
        RAISE EXCEPTION 'cancel_inventory_reservation: reservation % is already settled (% of % '
                        'shipped, % cancelled) — releasing it again would take stock a document '
                        'never promised',
            p_reservation_id, v_res.shipped, v_res.reserved_quantity, v_res.cancelled
            USING ERRCODE = '23514';
    END IF;

    v_take := coalesce(p_quantity, v_open);
    IF v_take <= 0 THEN
        RAISE EXCEPTION 'cancel_inventory_reservation: p_quantity must be positive (% given) — '
                        'direction belongs to the door, not to a sign', v_take
            USING ERRCODE = '22023';
    END IF;
    IF v_take > v_open THEN
        RAISE EXCEPTION 'cancel_inventory_reservation: % of % committed units requested for '
                        'release, and % are still open', v_take, v_res.reserved_quantity, v_open
            USING ERRCODE = '22023',
                  HINT = 'omit p_quantity to release everything still open; shipped units are '
                         'consumed by the ship door, not cancelled here';
    END IF;

    ------------------------------------------------------------------
    -- The balance first. The ledger row that follows describes a change that has already happened,
    -- which is the only order in which an audit trail is evidence rather than a note.
    ------------------------------------------------------------------
    FOR v_r IN SELECT * FROM afpc_release_bins(v_res.item_id, v_res.warehouse_id,
                                               v_res.location_id, v_take)
    LOOP
        IF v_r.units_released > 0 THEN
            UPDATE inventory_on_hand h
               SET quantity_reserved = h.quantity_reserved - v_r.units_released
             WHERE h.on_hand_id = v_r.on_hand_id;
            v_released := v_released + v_r.units_released;
        END IF;
    END LOOP;
    IF v_released <> v_take THEN
        -- Reported, never absorbed. quantity_available is derived from quantity_reserved by 0004's
        -- trigger, so a commitment whose balance units have gone missing means some other door moved
        -- reserved stock without settling the row — and quietly releasing less than asked would make
        -- THAT invisible while fixing the visible symptom.
        RAISE EXCEPTION 'cancel_inventory_reservation: releasing % units found only % reserved in '
                        'the bins — the commitment and the balance disagree, which is 4.2''s shape '
                        'and 0030''s doors must not paper over it', v_take, v_released
            USING ERRCODE = '23514',
                  HINT = 'compare inventory_reservations against sum(quantity_reserved) for this '
                         'item and warehouse; vw_inventory_valuation and 0015''s probes both answer';
    END IF;

    -- Qualified, and it is not hygiene: reservation_id is also this function's OUT column, so an
    -- unqualified reference in the WHERE is two things at once and plpgsql refuses to choose (42702).
    -- Every name that RETURNS TABLE shares with a column has to be qualified on both sides here.
    UPDATE inventory_reservations r
       SET cancelled_quantity = coalesce(r.cancelled_quantity, 0) + v_take
     WHERE r.reservation_id = p_reservation_id;

    ------------------------------------------------------------------
    -- The ledger mirror of 0015's row, written the way 0015 writes it.
    --
    -- execute_inventory_movement does not implement RESERVATION rows — that is why 0015's own door
    -- INSERTs into inventory_movements directly, and this door follows the same precedent rather
    -- than inventing a second path. The quantity is NEGATIVE because the row reverses a commitment,
    -- and the ledger's own reader agrees: vw_item_movement_summary excludes RESERVATION from
    -- inbound/outbound while net_quantity counts it, so +5 and -5 net to zero movement and nothing
    -- else changes. reference_type comes from the same CASE 0015 uses, so a WORK hold releases under
    -- WORK (0029's repair) and not under ORDER.
    ------------------------------------------------------------------
    v_uom := v_res.base_unit_of_measure;
    v_cur := v_res.currency_code;

    INSERT INTO inventory_movements
            (movement_type, item_id, to_warehouse_id, to_location_id, quantity,
             unit_of_measure, reason_code, performed_by, reference_type, reference_id,
             reference_line_id, currency_code, notes)
    VALUES  ('RESERVATION', v_res.item_id, v_res.warehouse_id, v_res.location_id, -v_take,
             v_uom, 'RESERVATION_RELEASED',
             coalesce(nullif(btrim(coalesce(p_cancelled_by, '')), ''),
                      current_setting('application_name', true), 'unknown'),
             CASE v_res.order_type
                 WHEN 'PURCHASE' THEN 'PO'
                 WHEN 'SALES'    THEN 'ORDER'
                 WHEN 'WORK'     THEN 'WORK'
                 WHEN 'TRANSFER' THEN 'TRANSFER'
                 ELSE NULL
             END,
             CASE WHEN v_res.order_type IN ('STOCK','TRANSFER') THEN NULL ELSE v_res.order_id END,
             v_res.order_line_id, v_cur,
             'Released by cancel_inventory_reservation: '
                 || coalesce(nullif(btrim(coalesce(p_reason, '')), ''), 'no reason given'));

    status := CASE WHEN v_res.cancelled + v_take = v_res.reserved_quantity
                   THEN 'CANCELLED' ELSE 'PARTIALLY_CANCELLED' END;
    message := format('Released %s of %s committed unit(s) on reservation %s (%s)',
                      v_take, v_open, p_reservation_id, coalesce(v_res.order_type, 'STOCK'));

    IF v_state = 'claimed' THEN
        PERFORM idempotency_complete(v_claim.claim_id, v_claim.current_token,
            jsonb_build_object('success', true, 'reservation_id', p_reservation_id,
                               'status', status, 'released', v_take, 'message', message));
    END IF;

    success := true;
    reservation_id := p_reservation_id;
    released_quantity := v_take;
    RETURN NEXT;
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

COMMENT ON FUNCTION cancel_inventory_reservation(uuid, numeric, text, text, uuid) IS
    'Release a commitment, wholly or in part: the bins give the reserved units back to '
    'quantity_available, cancelled_quantity moves, and the ledger records the reversal as a '
    'negative RESERVATION row under the same reference_type 0015 would have used to make it. This '
    'is the door whose absence 0030 exists to fix — before it, a reservation could be created and '
    'never undone, so 13 units on this server sat out of availability forever. A reservation whose '
    'document names a LINE is left attached to it: cancelling a commitment is not cancelling an '
    'order line, and 0028 derived the line''s state from its own quantities, so inventing a '
    'quantity_cancelled here would be a second claim about a document. Omit p_quantity to release '
    'everything still open. Refuses a settled reservation and a quantity beyond what is open, both '
    'with the arithmetic in the message. With p_idempotency_key a retried call releases once. Built '
    'by 0030.';

-- ---------------------------------------------------------------------------
-- 5.2 The one routine three doors share: settle what a document already holds
-- ---------------------------------------------------------------------------
-- Released, not cancelled: a shipped unit leaves the reservation through shipped_quantity, which is
-- the column 0015 declared and nothing wrote. Returning the amount lets each door decide whether a
-- commitment mattered; none of them refuses a fulfilment for want of one, because reserving is
-- optional and shipping is not.
CREATE OR REPLACE FUNCTION afpc_settle_commitments(
    p_order_id     uuid,
    p_item_id      uuid,
    p_warehouse    uuid,
    p_quantity     numeric,
    p_performed_by text
) RETURNS numeric
LANGUAGE plpgsql AS $$
DECLARE
    v_left  numeric   := p_quantity;
    v_r     record;
    v_take  numeric;
    v_got   numeric;
    v_b     record;
    v_out   numeric   := 0;
BEGIN
    IF v_left IS NULL OR v_left <= 0 THEN
        RETURN 0;
    END IF;
    -- Lock order: document, then commitments, then bins — the sequence ship and cancel take too,
    -- which is what keeps two concurrent fulfilments of one order from deadlocking on a bin (0015's
    -- single-drain-order note, applied across doors rather than inside one).
    FOR v_r IN
        SELECT r.reservation_id, r.item_id, r.warehouse_id, r.location_id, r.reserved_quantity,
               coalesce(r.shipped_quantity, 0) AS shipped,
               coalesce(r.cancelled_quantity, 0) AS cancelled
          FROM inventory_reservations r
         WHERE r.order_id = p_order_id
           AND r.item_id  = p_item_id
           AND (p_warehouse IS NULL OR r.warehouse_id = p_warehouse)
         ORDER BY r.priority NULLS LAST, r.reserved_at, r.reservation_id
           FOR UPDATE OF r
    LOOP
        IF v_left <= 0 THEN EXIT; END IF;
        v_take := least(v_left, v_r.reserved_quantity - v_r.shipped - v_r.cancelled);
        IF v_take <= 0 THEN CONTINUE; END IF;

        v_got := 0;
        FOR v_b IN SELECT * FROM afpc_release_bins(v_r.item_id, v_r.warehouse_id,
                                                   v_r.location_id, v_take)
        LOOP
            IF v_b.units_released > 0 THEN
                UPDATE inventory_on_hand h
                   SET quantity_reserved = h.quantity_reserved - v_b.units_released
                 WHERE h.on_hand_id = v_b.on_hand_id;
                v_got := v_got + v_b.units_released;
            END IF;
        END LOOP;

        IF v_got <> v_take THEN
            RAISE EXCEPTION 'afpc_settle_commitments: reservation % could return only % of % unit(s)',
                v_r.reservation_id, v_got, v_take
                USING ERRCODE = '23514',
                      HINT = 'same reason cancel_inventory_reservation refuses: a commitment whose '
                             'balance units are gone is a disagreement between two doors, and '
                             'fulfilling through it would make the ledger agree with neither';
        END IF;

        UPDATE inventory_reservations r
           SET shipped_quantity = coalesce(r.shipped_quantity, 0) + v_take
         WHERE r.reservation_id = v_r.reservation_id;

        v_left := v_left - v_take;
        v_out  := v_out + v_take;
    END LOOP;
    RETURN v_out;
END
$$;

COMMENT ON FUNCTION afpc_settle_commitments(uuid, uuid, uuid, numeric, text) IS
    'Give back whatever a document already has committed for one item, up to the quantity being '
    'fulfilled, and say how much that was: the shared half of ship, receive and produce. Writes '
    'nothing to the ledger — the caller''s ISSUE or RECEIPT row is the movement, and a RESERVATION '
    'row on top of it would count the same stock twice. shipped_quantity is the column 0015 declared '
    'and no function ever wrote; this is its first writer, which is also 0030''s argument that the '
    'fulfilment doors and the reservation leak are one change and not two. Built by 0030.';

-- ---------------------------------------------------------------------------
-- 5.3 ship_sales_order / receive_purchase_order — the same shape, mirrored
-- ---------------------------------------------------------------------------
-- Both take a document and make its lines true in the warehouse. They differ in direction, in which
-- counterparty they name in the ledger, and in the order of the two writes:
--
--   SHIP     release the commitment FIRST, then ISSUE.  execute_inventory_movement checks
--            quantity_available, and reserved stock is by definition not available — so issuing
--            before releasing would refuse a shipment of stock the warehouse is holding for exactly
--            this order. The order is not stylistic; it is the availability formula read out loud.
--   RECEIVE  RECEIPT FIRST, then release.  A receipt adds on_hand; the in-transit commitment that
--            covered it is then released so quantity_reserved does not double-count stock that has
--            physically arrived.
--
-- Neither restates a lifecycle rule: the terminal check comes from order_lifecycle, the status they
-- write is computed from what the ledger now says, and 0028's stock_moving flag is why these two
-- exist at all — SHIPPED and RECEIVED cannot be set by transition_order, so a document can only
-- reach them by doing the thing those words report.
CREATE OR REPLACE FUNCTION ship_sales_order(
    p_order_id        uuid    DEFAULT NULL,
    p_warehouse_id    uuid    DEFAULT NULL,
    p_performed_by    text    DEFAULT NULL,
    p_idempotency_key uuid    DEFAULT NULL
) RETURNS TABLE(success boolean, order_id uuid, order_number text, status text,
                shipped_quantity numeric, message text)
LANGUAGE plpgsql AS $$
DECLARE
    v_claim   record;
    v_state   text := '';
    v_head    record;
    v_line    record;
    v_open    numeric;
    v_wh      uuid;
    v_cost    numeric;
    v_moved   numeric := 0;
    v_lines   int := 0;
    v_done    boolean;
    v_mid     uuid;
    v_by      text;
BEGIN
    IF p_order_id IS NULL THEN
        RAISE EXCEPTION 'ship_sales_order: p_order_id is required' USING ERRCODE = '22023';
    END IF;

    IF p_idempotency_key IS NOT NULL THEN
        SELECT * INTO v_claim FROM idempotency_claim(
            p_idempotency_key, 'ship_sales_order',
            jsonb_build_object('order', p_order_id, 'warehouse', p_warehouse_id,
                               'by', p_performed_by));
        v_state := v_claim.claim_state;
        IF v_state = 'replay' THEN
            success          := (v_claim.cached_response ->> 'success')::boolean;
            order_id         := (v_claim.cached_response ->> 'order_id')::uuid;
            order_number     := v_claim.cached_response ->> 'order_number';
            status           := v_claim.cached_response ->> 'status';
            shipped_quantity := (v_claim.cached_response ->> 'shipped')::numeric;
            message          := v_claim.cached_response ->> 'message';
            RETURN NEXT; RETURN;
        ELSIF v_state = 'in_progress' THEN
            RAISE EXCEPTION 'ship_sales_order: an attempt with key % is already in flight',
                p_idempotency_key USING ERRCODE = '40001';
        ELSIF v_state = 'conflict' THEN
            RAISE EXCEPTION 'ship_sales_order: key % was settled for a DIFFERENT request',
                p_idempotency_key USING ERRCODE = 'P0001';
        END IF;
    END IF;

    SELECT o.order_type, o.order_number, o.warehouse_id, lc.terminal
      INTO v_head
      FROM orders o
      JOIN order_lifecycle lc ON lc.order_type = o.order_type AND lc.status_code = o.status
     WHERE o.order_id = p_order_id
       FOR UPDATE OF o;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ship_sales_order: order % is not a document this connection can see',
            p_order_id USING ERRCODE = '22023';
    END IF;
    IF v_head.order_type <> 'SALES' THEN
        RAISE EXCEPTION 'ship_sales_order: order % is a % document — stock leaves a warehouse on a '
                        'SALES order and arrives on a PURCHASE one',
            p_order_id, v_head.order_type USING ERRCODE = '23514',
            HINT = 'receive_purchase_order is the other half of this pair, and it is named by '
                   'direction rather than by whoever happens to be asking';
    END IF;
    IF v_head.terminal THEN
        RAISE EXCEPTION 'ship_sales_order: order % is already in a terminal state', v_head.order_number
            USING ERRCODE = '23514';
    END IF;

    v_wh  := coalesce(p_warehouse_id, v_head.warehouse_id);
    v_by  := coalesce(nullif(btrim(coalesce(p_performed_by, '')), ''),
                      current_setting('application_name', true), 'unknown');

    FOR v_line IN
        SELECT i.order_line_id, i.item_id, i.line_number, i.quantity, i.quantity_fulfilled,
               i.quantity_cancelled, i.warehouse_id,
               coalesce((SELECT u.base_unit_of_measure FROM inventory_items u
                          WHERE u.item_id = i.item_id), 'EACH') AS uom
          FROM order_items i
         WHERE i.order_id = p_order_id AND i.line_type = 'STANDARD'
           AND i.quantity - i.quantity_fulfilled - i.quantity_cancelled > 0
         ORDER BY i.line_number
           FOR UPDATE OF i
    LOOP
        v_lines := v_lines + 1;
        IF v_line.item_id IS NULL THEN
            RAISE EXCEPTION 'ship_sales_order: line % of % is a service or a one-off and cannot be '
                            'shipped — there is no stock item to take out of a bin',
                v_line.line_number, v_head.order_number
                USING ERRCODE = '23514',
                      HINT = 'a non-catalog line is fulfilled by the document being closed, not by '
                             'a movement; 0027/0028 made item_id nullable precisely so a PO could '
                             'procure a plumber, and a sales order ships goods';
        END IF;
        v_open := v_line.quantity - v_line.quantity_fulfilled - v_line.quantity_cancelled;

        -- (1) release the commitment, if this document has one
        PERFORM afpc_settle_commitments(p_order_id, v_line.item_id,
                                        coalesce(v_line.warehouse_id, v_wh), v_open, v_by);

        -- (2) then move the stock, naming the line so the counter and the ledger reconcile (§1)
        SELECT h.average_cost INTO v_cost
          FROM inventory_on_hand h
         WHERE h.item_id = v_line.item_id AND h.warehouse_id = coalesce(v_line.warehouse_id, v_wh)
         ORDER BY h.on_hand_id LIMIT 1;

        v_mid := execute_inventory_movement(
            p_movement_type     => 'ISSUE',
            p_item_id           => v_line.item_id,
            p_from_warehouse_id => coalesce(v_line.warehouse_id, v_wh),
            p_to_warehouse_id   => NULL,
            p_quantity          => v_open,
            p_unit_cost         => v_cost,
            p_performed_by      => v_by,
            p_reference_type    => 'ORDER',
            p_reference_id      => p_order_id,
            p_reason_code       => 'ORDER_SHIPPED',
            p_unit_of_measure   => v_line.uom,
            p_idempotency_key   => NULL,
            p_reference_line_id => v_line.order_line_id);

        UPDATE order_items i
           SET quantity_fulfilled = i.quantity_fulfilled + v_open
         WHERE i.order_line_id = v_line.order_line_id;
        v_moved := v_moved + v_open;
    END LOOP;

    IF v_lines = 0 THEN
        RAISE EXCEPTION 'ship_sales_order: % has no line still waiting to go out — either it has '
                        'already shipped, or it has no lines at all', v_head.order_number
            USING ERRCODE = '23514',
                  HINT = 'a document with a commitment but no lines cannot exist after 0030''s '
                         'backfill, which gave every live reservation a line of its own';
    END IF;

    -- The status the ledger now earns, computed rather than asserted: SHIPPED only when nothing is
    -- outstanding, PICKING while something is. A partial shipment is not a fiction the door is
    -- allowed to describe as complete.
    SELECT NOT EXISTS (SELECT 1 FROM order_items i
                        WHERE i.order_id = p_order_id AND i.line_type = 'STANDARD'
                          AND i.quantity - i.quantity_fulfilled - i.quantity_cancelled > 0)
      INTO v_done;
    status := CASE WHEN v_done THEN 'SHIPPED' ELSE 'PICKING' END;

    UPDATE orders o
       SET status = CASE WHEN v_done THEN 'SHIPPED' ELSE 'PICKING' END
     WHERE o.order_id = p_order_id;

    order_number := v_head.order_number;
    message := format('%s shipped %s unit(s) across %s line(s) from warehouse %s → %s',
                      v_head.order_number, v_moved, v_lines, v_wh, status);

    IF v_state = 'claimed' THEN
        PERFORM idempotency_complete(v_claim.claim_id, v_claim.current_token,
            jsonb_build_object('success', true, 'order_id', p_order_id,
                               'order_number', order_number, 'status', status,
                               'shipped', v_moved, 'message', message));
    END IF;
    success := true;
    RETURN NEXT; RETURN;

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

COMMENT ON FUNCTION ship_sales_order(uuid, uuid, text, uuid) IS
    'Ship every outstanding goods line on a SALES order: release what the document has committed, '
    'then ISSUE the stock, naming the line in the ledger row so the line''s counter and the movement '
    'history are reconcilable (probe H asserts it). Release-before-issue is the availability formula '
    'talking, not a preference — reserved units are not available, so issuing first would refuse a '
    'shipment of stock held for this very order. Writes SHIPPED when nothing is left out and PICKING '
    'when something is, which is 0028''s stock_moving rule honoured from the inside: SHIPPED cannot '
    'be set by transition_order precisely so that only a door that moved stock can say it. A '
    'service line (item_id NULL) is a refusal with a reason, not a zero-quantity movement. Retries '
    'with p_idempotency_key ship once. Built by 0030.';

CREATE OR REPLACE FUNCTION receive_purchase_order(
    p_order_id        uuid    DEFAULT NULL,
    p_warehouse_id    uuid    DEFAULT NULL,
    p_performed_by    text    DEFAULT NULL,
    p_idempotency_key uuid    DEFAULT NULL
) RETURNS TABLE(success boolean, order_id uuid, order_number text, status text,
                received_quantity numeric, accepted_quantity numeric, message text)
LANGUAGE plpgsql AS $$
DECLARE
    v_claim  record;
    v_state  text := '';
    v_head   record;
    v_line   record;
    v_open   numeric;
    v_wh     uuid;
    v_stock  numeric := 0;
    v_service numeric := 0;
    v_lines  int := 0;
    v_done   boolean;
    v_by     text;
    v_mid    uuid;
BEGIN
    IF p_order_id IS NULL THEN
        RAISE EXCEPTION 'receive_purchase_order: p_order_id is required' USING ERRCODE = '22023';
    END IF;

    IF p_idempotency_key IS NOT NULL THEN
        SELECT * INTO v_claim FROM idempotency_claim(
            p_idempotency_key, 'receive_purchase_order',
            jsonb_build_object('order', p_order_id, 'warehouse', p_warehouse_id, 'by', p_performed_by));
        v_state := v_claim.claim_state;
        IF v_state = 'replay' THEN
            success           := (v_claim.cached_response ->> 'success')::boolean;
            order_id          := (v_claim.cached_response ->> 'order_id')::uuid;
            order_number      := v_claim.cached_response ->> 'order_number';
            status            := v_claim.cached_response ->> 'status';
            received_quantity := (v_claim.cached_response ->> 'received')::numeric;
            accepted_quantity := (v_claim.cached_response ->> 'accepted')::numeric;
            message           := v_claim.cached_response ->> 'message';
            RETURN NEXT; RETURN;
        ELSIF v_state = 'in_progress' THEN
            RAISE EXCEPTION 'receive_purchase_order: an attempt with key % is already in flight',
                p_idempotency_key USING ERRCODE = '40001';
        ELSIF v_state = 'conflict' THEN
            RAISE EXCEPTION 'receive_purchase_order: key % was settled for a DIFFERENT request',
                p_idempotency_key USING ERRCODE = 'P0001';
        END IF;
    END IF;

    SELECT o.order_type, o.order_number, o.warehouse_id, lc.terminal
      INTO v_head
      FROM orders o
      JOIN order_lifecycle lc ON lc.order_type = o.order_type AND lc.status_code = o.status
     WHERE o.order_id = p_order_id
       FOR UPDATE OF o;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'receive_purchase_order: order % is not a document this connection can see',
            p_order_id USING ERRCODE = '22023';
    END IF;
    IF v_head.order_type <> 'PURCHASE' THEN
        RAISE EXCEPTION 'receive_purchase_order: order % is a % document', p_order_id,
            v_head.order_type USING ERRCODE = '23514',
            HINT = 'ship_sales_order is the outbound half of this pair';
    END IF;
    IF v_head.terminal THEN
        RAISE EXCEPTION 'receive_purchase_order: order % is already in a terminal state',
            v_head.order_number USING ERRCODE = '23514';
    END IF;

    v_wh := coalesce(p_warehouse_id, v_head.warehouse_id);
    IF v_wh IS NULL THEN
        RAISE EXCEPTION 'receive_purchase_order: % names no warehouse to receive into, and none was '
                        'given', v_head.order_number USING ERRCODE = '22023',
            HINT = 'inventory_movements_warehouse_shape requires a destination for a RECEIPT — the '
                   'ledger cannot say stock arrived without saying where';
    END IF;
    v_by := coalesce(nullif(btrim(coalesce(p_performed_by, '')), ''),
                    current_setting('application_name', true), 'unknown');

    FOR v_line IN
        SELECT i.order_line_id, i.item_id, i.line_number, i.quantity, i.quantity_fulfilled,
               i.quantity_cancelled, i.unit_price, i.warehouse_id,
               coalesce((SELECT u.base_unit_of_measure FROM inventory_items u
                          WHERE u.item_id = i.item_id), 'EACH') AS uom,
               (SELECT u.product_type FROM inventory_items u WHERE u.item_id = i.item_id) AS ptype
          FROM order_items i
         WHERE i.order_id = p_order_id AND i.line_type = 'STANDARD'
           AND i.quantity - i.quantity_fulfilled - i.quantity_cancelled > 0
         ORDER BY i.line_number
           FOR UPDATE OF i
    LOOP
        v_lines := v_lines + 1;
        v_open  := v_line.quantity - v_line.quantity_fulfilled - v_line.quantity_cancelled;

        IF v_line.item_id IS NULL OR v_line.ptype = 'SERVICE' THEN
            -- Nothing arrives. The line is nonetheless satisfied, because a hired engineer being
            -- paid is what a delivered service means, and forcing a stock row for it would put a
            -- phantom unit in a bin to make a counter go up.
            UPDATE order_items i SET quantity_fulfilled = i.quantity_fulfilled + v_open
             WHERE i.order_line_id = v_line.order_line_id;
            v_service := v_service + v_open;
        ELSE
            v_mid := execute_inventory_movement(
                p_movement_type     => 'RECEIPT',
                p_item_id           => v_line.item_id,
                p_from_warehouse_id => NULL,
                p_to_warehouse_id   => coalesce(v_line.warehouse_id, v_wh),
                p_quantity          => v_open,
                -- The line's own price, narrowed to the ledger's numeric(18,4) deliberately: 0018's
                -- width rule is that the money column must be able to hold what the arithmetic
                -- produces, and a unit price beyond 1e14 is a data error the cast will say so about.
                p_unit_cost         => round(v_line.unit_price, 4),
                p_performed_by      => v_by,
                p_reference_type    => 'PO',
                p_reference_id      => p_order_id,
                p_reason_code       => 'PO_RECEIVED',
                p_unit_of_measure   => v_line.uom,
                p_idempotency_key   => NULL,
                p_reference_line_id => v_line.order_line_id);

            UPDATE order_items i SET quantity_fulfilled = i.quantity_fulfilled + v_open
             WHERE i.order_line_id = v_line.order_line_id;
            v_stock := v_stock + v_open;

            -- Release AFTER the receipt, for the mirrored reason in the header: an in-transit
            -- commitment covered stock that was not yet here, and it is now here.
            PERFORM afpc_settle_commitments(p_order_id, v_line.item_id,
                                           coalesce(v_line.warehouse_id, v_wh), v_open, v_by);
        END IF;
    END LOOP;

    IF v_lines = 0 THEN
        RAISE EXCEPTION 'receive_purchase_order: % has nothing outstanding to receive',
            v_head.order_number USING ERRCODE = '23514';
    END IF;

    SELECT NOT EXISTS (SELECT 1 FROM order_items i
                        WHERE i.order_id = p_order_id AND i.line_type = 'STANDARD'
                          AND i.quantity - i.quantity_fulfilled - i.quantity_cancelled > 0)
      INTO v_done;
    status := CASE WHEN v_done THEN 'RECEIVED' ELSE 'SUBMITTED' END;
    UPDATE orders o SET status = CASE WHEN v_done THEN 'RECEIVED' ELSE 'SUBMITTED' END
     WHERE o.order_id = p_order_id;

    order_number := v_head.order_number;
    received_quantity := v_stock;
    accepted_quantity := v_service;
    message := format('%s received %s stock unit(s) and %s service unit(s) into %s → %s',
                      v_head.order_number, v_stock, v_service, v_wh, status);

    IF v_state = 'claimed' THEN
        PERFORM idempotency_complete(v_claim.claim_id, v_claim.current_token,
            jsonb_build_object('success', true, 'order_id', p_order_id,
                               'order_number', order_number, 'status', status,
                               'received', v_stock, 'accepted', v_service, 'message', message));
    END IF;
    success := true;
    RETURN NEXT; RETURN;

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

COMMENT ON FUNCTION receive_purchase_order(uuid, uuid, text, uuid) IS
    'Receive every outstanding line on a PURCHASE order into a warehouse. Goods lines produce a '
    'RECEIPT movement naming the line and the supplier document; service lines (a blank item_id, or '
    'an item whose product_type is SERVICE) satisfy the line without touching a bin, because a '
    'delivered engineer is not a unit of stock and inventing one is how a deployment grows an '
    'MISCELLANEOUS item — the reason 0027 made item_id nullable. RECEIPT-then-release for the same '
    'reason ship does release-then-ISSUE, read off the other side of the availability formula. '
    'Writes RECEIVED when nothing is outstanding and leaves SUBMITTED when something is. Refuses '
    'without a destination warehouse, because the ledger''s own CHECK requires one. Built by 0030.';

-- ---------------------------------------------------------------------------
-- 5.4 book_work_order_production — components out, product in
-- ---------------------------------------------------------------------------
-- The ratio is the whole of what this door knows about manufacturing, and it is stated so that its
-- limits are visible: without a bill of materials, the only defensible statement about how much of a
-- component a run consumes is the one the document's own lines make. A WORK order that was planned
-- with 4 of a part to yield 1 finished unit consumes 4 per unit. When routings arrive (0029 §10),
-- the ratio moves to the operation that owns the step and this door reads it instead of deriving it
-- — which is why the derivation is one expression and not scattered through the loop.
CREATE OR REPLACE FUNCTION book_work_order_production(
    p_order_id        uuid    DEFAULT NULL,
    p_quantity        numeric DEFAULT NULL,
    p_performed_by    text    DEFAULT NULL,
    p_operation_id    uuid    DEFAULT NULL,
    p_idempotency_key uuid    DEFAULT NULL
) RETURNS TABLE(success boolean, order_id uuid, order_number text, status text,
                produced_quantity numeric, consumed_quantity numeric, message text)
LANGUAGE plpgsql AS $$
DECLARE
    v_claim  record;
    v_state  text := '';
    v_head   record;
    v_prod   record;
    v_cmp    record;
    v_wh     uuid;
    v_take   numeric;
    v_cost   numeric;
    v_made   numeric := 0;
    v_used   numeric := 0;
    v_by     text;
    v_mid    uuid;
    v_done   boolean;
BEGIN
    IF p_order_id IS NULL OR p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'book_work_order_production: p_order_id and a positive p_quantity are '
                        'required — a run that produces nothing is a status change, not production'
            USING ERRCODE = '22023';
    END IF;

    IF p_idempotency_key IS NOT NULL THEN
        SELECT * INTO v_claim FROM idempotency_claim(
            p_idempotency_key, 'book_work_order_production',
            jsonb_build_object('order', p_order_id, 'qty', p_quantity, 'op', p_operation_id,
                               'by', p_performed_by));
        v_state := v_claim.claim_state;
        IF v_state = 'replay' THEN
            success            := (v_claim.cached_response ->> 'success')::boolean;
            order_id           := (v_claim.cached_response ->> 'order_id')::uuid;
            order_number       := v_claim.cached_response ->> 'order_number';
            status             := v_claim.cached_response ->> 'status';
            produced_quantity  := (v_claim.cached_response ->> 'produced')::numeric;
            consumed_quantity  := (v_claim.cached_response ->> 'consumed')::numeric;
            message            := v_claim.cached_response ->> 'message';
            RETURN NEXT; RETURN;
        ELSIF v_state = 'in_progress' THEN
            RAISE EXCEPTION 'book_work_order_production: an attempt with key % is already in flight',
                p_idempotency_key USING ERRCODE = '40001';
        ELSIF v_state = 'conflict' THEN
            RAISE EXCEPTION 'book_work_order_production: key % was settled for a DIFFERENT request',
                p_idempotency_key USING ERRCODE = 'P0001';
        END IF;
    END IF;

    SELECT o.order_type, o.order_number, o.warehouse_id, lc.terminal
      INTO v_head
      FROM orders o
      JOIN order_lifecycle lc ON lc.order_type = o.order_type AND lc.status_code = o.status
     WHERE o.order_id = p_order_id
       FOR UPDATE OF o;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'book_work_order_production: order % is not a document this connection can '
                        'see', p_order_id USING ERRCODE = '22023';
    END IF;
    IF v_head.order_type <> 'WORK' THEN
        RAISE EXCEPTION 'book_work_order_production: % is a % order and produces nothing — the '
                        'document types differ by what happens to stock, and this is the sentence '
                        'that keeps them apart', p_order_id, v_head.order_type
            USING ERRCODE = '23514';
    END IF;
    IF v_head.terminal THEN
        RAISE EXCEPTION 'book_work_order_production: order % is already in a terminal state',
            v_head.order_number USING ERRCODE = '23514';
    END IF;

    v_wh := (SELECT i.warehouse_id FROM order_items i
              WHERE i.order_id = p_order_id AND i.line_type = 'PRODUCT'
              ORDER BY i.line_number LIMIT 1)
           -- An operation assigned to a work centre says where the work happened, and the centre
           -- knows which building it is in. coalesce order below puts the line first: the plan says
           -- WHAT is made, the centre only says WHERE it was machined.
           ;
    v_wh := coalesce((SELECT wc.warehouse_id FROM work_order_operations op
                       JOIN work_centres wc ON wc.work_centre_id = op.work_centre_id
                      WHERE op.order_id = p_order_id
                        AND (p_operation_id IS NULL OR op.operation_id = p_operation_id)
                      LIMIT 1), v_wh, v_head.warehouse_id);
    IF v_wh IS NULL THEN
        RAISE EXCEPTION 'book_work_order_production: % names no warehouse, no product line with a '
                        'bin, and no work centre — the ledger has to say where the output appeared',
            v_head.order_number USING ERRCODE = '22023';
    END IF;

    -- Exactly one PRODUCT line. More than one is a plan for two documents wearing one header, and
    -- this door cannot decide which one a run produced.
    SELECT count(*) INTO v_made FROM order_items i
     WHERE i.order_id = p_order_id AND i.line_type = 'PRODUCT';
    IF v_made <> 1 THEN
        RAISE EXCEPTION 'book_work_order_production: % has % PRODUCT line(s); production needs '
                        'exactly one thing it produces', v_head.order_number, v_made
            USING ERRCODE = '23514',
                  HINT = '0028''s line_type is what distinguishes a work order''s lines, and a '
                         'document with two outputs is two work orders';
    END IF;
    v_made := 0;   -- reused as the running counter below

    SELECT i.order_line_id, i.item_id, i.quantity, i.quantity_fulfilled,
           coalesce((SELECT u.base_unit_of_measure FROM inventory_items u
                      WHERE u.item_id = i.item_id), 'EACH') AS uom
      INTO v_prod
      FROM order_items i
     WHERE i.order_id = p_order_id AND i.line_type = 'PRODUCT'
       FOR UPDATE OF i;

    v_by := coalesce(nullif(btrim(coalesce(p_performed_by, '')), ''),
                    current_setting('application_name', true), 'unknown');

    ------------------------------------------------------------------
    -- Components out FIRST. The order matters twice over: a run whose inputs are short must fail
    -- before it books output that did not get made, and 0015's availability rule makes the ISSUE the
    -- statement that decides.
    ------------------------------------------------------------------
    FOR v_cmp IN
        SELECT i.order_line_id, i.item_id, i.quantity AS comp_qty, i.quantity_fulfilled,
               i.quantity_cancelled, i.warehouse_id,
               coalesce((SELECT u.base_unit_of_measure FROM inventory_items u
                          WHERE u.item_id = i.item_id), 'EACH') AS uom
          FROM order_items i
         WHERE i.order_id = p_order_id AND i.line_type = 'COMPONENT'
         ORDER BY i.line_number
           FOR UPDATE OF i
    LOOP
        v_take := round(p_quantity * (v_cmp.comp_qty / v_prod.quantity), 4);
        IF v_take <= 0 THEN
            CONTINUE;   -- a rounding-to-zero draw is a plan that cannot be consumed, and 0014's
                        -- chk_quantity_nonzero would refuse the row anyway
        END IF;
        IF v_cmp.quantity_fulfilled + v_take > v_cmp.comp_qty THEN
            RAISE EXCEPTION 'book_work_order_production: % of % would consume % of line %''s % '
                            'unit(s), and % remain', v_head.order_number, p_quantity, v_take,
                (SELECT i.line_number FROM order_items i WHERE i.order_line_id = v_cmp.order_line_id),
                v_cmp.comp_qty, v_cmp.comp_qty - v_cmp.quantity_fulfilled - v_cmp.quantity_cancelled
                USING ERRCODE = '23514',
                      HINT = 'the plan says this document consumes that much; producing more than the '
                             'plan can support needs a new line, not a silent overrun';
        END IF;

        SELECT h.average_cost INTO v_cost
          FROM inventory_on_hand h
         WHERE h.item_id = v_cmp.item_id AND h.warehouse_id = coalesce(v_cmp.warehouse_id, v_wh)
         ORDER BY h.on_hand_id LIMIT 1;

        v_mid := execute_inventory_movement(
            p_movement_type => 'ISSUE', p_item_id => v_cmp.item_id,
            p_from_warehouse_id => coalesce(v_cmp.warehouse_id, v_wh), p_to_warehouse_id => NULL,
            p_quantity => v_take, p_unit_cost => v_cost, p_performed_by => v_by,
            p_reference_type => 'WORK', p_reference_id => p_order_id,
            p_reason_code => 'PRODUCTION_CONSUMED', p_unit_of_measure => v_cmp.uom,
            p_idempotency_key => NULL, p_reference_line_id => v_cmp.order_line_id);

        UPDATE order_items i SET quantity_fulfilled = i.quantity_fulfilled + v_take
         WHERE i.order_line_id = v_cmp.order_line_id;
        v_used := v_used + v_take;
    END LOOP;

    -- Output in.
    v_take := least(p_quantity, v_prod.quantity - v_prod.quantity_fulfilled);
    IF v_take <= 0 THEN
        RAISE EXCEPTION 'book_work_order_production: % has already produced its planned % unit(s)',
            v_head.order_number, v_prod.quantity USING ERRCODE = '23514';
    END IF;
    v_mid := execute_inventory_movement(
        p_movement_type => 'RECEIPT', p_item_id => v_prod.item_id,
        p_from_warehouse_id => NULL, p_to_warehouse_id => v_wh,
        p_quantity => v_take, p_unit_cost => NULL, p_performed_by => v_by,
        p_reference_type => 'WORK', p_reference_id => p_order_id,
        p_reason_code => 'PRODUCTION_OUTPUT', p_unit_of_measure => v_prod.uom,
        p_idempotency_key => NULL, p_reference_line_id => v_prod.order_line_id);

    UPDATE order_items i SET quantity_fulfilled = i.quantity_fulfilled + v_take
     WHERE i.order_line_id = v_prod.order_line_id;
    v_made := v_take;

    -- The operations report what the run made, on the steps that touch the produced line. Hours are
    -- deliberately untouched: an operation's actual_hours is what someone clocked, and no run of
    -- components can know it.
    UPDATE work_order_operations w
       SET quantity_produced = w.quantity_produced + v_take
     WHERE w.order_id = p_order_id
       AND (p_operation_id IS NULL OR w.operation_id = p_operation_id)
       AND (w.order_line_id IS NULL OR w.order_line_id = v_prod.order_line_id);

    IF p_operation_id IS NOT NULL THEN
        -- wo_operations_status_matches_stamps is a three-way rule about columns on this row, so the
        -- door has to move the status and the stamps together or the CHECK refuses the pair.
        UPDATE work_order_operations w
           SET status = 'COMPLETED', started_at = coalesce(w.started_at, now()),
               completed_at = now()
         WHERE w.operation_id = p_operation_id
           AND w.status <> 'COMPLETED';
    END IF;

    SELECT NOT EXISTS (SELECT 1 FROM order_items i
                        WHERE i.order_id = p_order_id AND i.line_type = 'PRODUCT'
                          AND i.quantity - i.quantity_fulfilled - i.quantity_cancelled > 0)
      INTO v_done;
    status := CASE WHEN v_done THEN 'COMPLETED' ELSE 'IN_PRODUCTION' END;
    UPDATE orders o SET status = CASE WHEN v_done THEN 'COMPLETED' ELSE 'IN_PRODUCTION' END
     WHERE o.order_id = p_order_id;

    order_number := v_head.order_number;
    produced_quantity := v_made;
    consumed_quantity := v_used;
    message := format('%s produced %s unit(s) of %s, consuming %s unit(s) across its components → %s',
                      v_head.order_number, v_made,
                      (SELECT i.name FROM inventory_items i WHERE i.item_id = v_prod.item_id),
                      v_used, status);

    IF v_state = 'claimed' THEN
        PERFORM idempotency_complete(v_claim.claim_id, v_claim.current_token,
            jsonb_build_object('success', true, 'order_id', p_order_id,
                               'order_number', order_number, 'status', status,
                               'produced', v_made, 'consumed', v_used, 'message', message));
    END IF;
    success := true;
    RETURN NEXT; RETURN;

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

COMMENT ON FUNCTION book_work_order_production(uuid, numeric, text, uuid, uuid) IS
    'Run a work order: consume its COMPONENT lines in the ratio the plan states, then receive its '
    'one PRODUCT line. Components first, so a short batch fails before any output is booked — a '
    'ledger that says 1 made and 0 consumed is worse than a refused run. The ratio (component '
    'quantity / product quantity) is everything this door can honestly know without a bill of '
    'materials, and when routings land it is read from them instead (0029 §10). Refuses more than '
    'one PRODUCT line, an overrun of the plan, and a document that is not WORK. Writes COMPLETED only '
    'when the product line is satisfied, which 0028''s stock_moving flag reserves to doors like this '
    'one. Reports quantity_produced on the operations that touch the produced line and leaves '
    'actual_hours alone, because what somebody clocked is not a fact a run can infer. Built by 0030.';

-- ---------------------------------------------------------------------------
-- 6. The reconciliation, as a read path
-- ---------------------------------------------------------------------------
-- 0028's header named the trap: either a line's counter is a denormalised number that can silently
-- disagree with the ledger, or the ledger names the line and the two can be compared. §1 gave the
-- ledger the column and §5 the doors that fill it, so the comparison is now possible — and it
-- belongs in a view, because ADR-003's rule is that a state the views cannot show is a state the
-- agent cannot see, and "does this document agree with its stock history" is a state.
CREATE OR REPLACE VIEW vw_order_commitments AS
SELECT i.tenant_id,
       i.order_id,
       o.order_number,
       o.order_type,
       o.status            AS order_status,
       i.order_line_id,
       i.line_number,
       i.line_type,
       i.item_id,
       it.name             AS item_name,
       i.quantity,
       i.quantity_fulfilled,
       i.quantity_cancelled,
       (i.quantity - i.quantity_fulfilled - i.quantity_cancelled) AS quantity_open,
       coalesce(c.committed, 0)  AS quantity_committed,
       coalesce(c.released, 0)   AS quantity_released,
       coalesce(c.resolved, 0)   AS quantity_unresolved,
       -- A commitment naming this document and item but no line. It could have been left out — a
       -- join on order_line_id makes it invisible, and the view would then read "0 committed" where
       -- the truth is "committed, not attributed". Those are different sentences and only one of
       -- them is safe to act on, so the number is published rather than omitted.
       coalesce(u.unlinked, 0)   AS quantity_committed_unlinked,
       coalesce(l.ledger_rows, 0) AS ledger_rows,
       l.ledger_quantity,
       -- The verdict, in the register's own register. A line with no movements is not a disagreement:
       -- a service is fulfilled by the document, and saying "no movements" rather than "0 = 5,
       -- DISAGREES" is what keeps this column usable as an alarm.
       CASE
           WHEN coalesce(l.ledger_rows, 0) = 0 AND i.quantity_fulfilled = 0
               THEN 'nothing moved yet'
           WHEN coalesce(l.ledger_rows, 0) = 0
               THEN 'fulfilled without a movement (non-stock line)'
           WHEN coalesce(l.ledger_quantity, 0) = i.quantity_fulfilled THEN 'agrees'
           ELSE 'DISAGREES'
       END                 AS ledger_agreement,
       i.required_date,
       i.updated_at        AS line_updated_at
  FROM order_items i
  JOIN orders o ON o.order_id = i.order_id
  LEFT JOIN inventory_items it ON it.item_id = i.item_id
  LEFT JOIN LATERAL (
        SELECT sum(r.reserved_quantity) AS committed,
               sum(coalesce(r.shipped_quantity, 0) + coalesce(r.cancelled_quantity, 0)) AS released,
               sum(r.reserved_quantity - coalesce(r.shipped_quantity, 0)
                   - coalesce(r.cancelled_quantity, 0)) AS resolved
          FROM inventory_reservations r
         WHERE r.order_line_id = i.order_line_id
       ) c ON true
  LEFT JOIN LATERAL (
        SELECT sum(r2.reserved_quantity - coalesce(r2.shipped_quantity, 0)
                   - coalesce(r2.cancelled_quantity, 0)) AS unlinked
          FROM inventory_reservations r2
         WHERE r2.order_id = i.order_id AND r2.item_id = i.item_id
           AND r2.order_line_id IS NULL
       ) u ON true
  LEFT JOIN LATERAL (
        -- "Fulfilled", not "signed": the rows that moved THIS line forward.
        --
        -- Deriving the sign from which warehouse end the row names — the obvious reading, and the one
        -- this view first had — is wrong, because a line's progress is a property of the document, not
        -- of the movement's geometry. An ISSUE is +7 of progress on a sales line, +4 of progress on a
        -- work order's COMPONENT line, and -7 on nothing at all; a RECEIPT is progress on a purchase
        -- line and on a PRODUCT line. Read from the movement's shape alone, every shipped sales line
        -- disagrees with itself by a factor of -1, which probe E caught by behaving rather than by
        -- being argued with.
        SELECT count(*) FILTER (WHERE m.movement_type <> 'RESERVATION') AS ledger_rows,
               sum(CASE
                       WHEN m.movement_type = 'RESERVATION' THEN 0
                       WHEN o.order_type = 'SALES'    AND m.movement_type = 'ISSUE'   THEN m.quantity
                       WHEN o.order_type = 'PURCHASE' AND m.movement_type = 'RECEIPT' THEN m.quantity
                       WHEN o.order_type = 'WORK'     AND i.line_type = 'PRODUCT'
                                                      AND m.movement_type = 'RECEIPT'  THEN m.quantity
                       WHEN o.order_type = 'WORK'     AND i.line_type = 'COMPONENT'
                                                      AND m.movement_type = 'ISSUE'    THEN m.quantity
                       -- anything else naming this line is a movement the document did not ask for,
                       -- and counting it as zero makes the row show up as a disagreement rather than
                       -- silently balancing it out
                       ELSE 0
                   END)                                            AS ledger_quantity
          FROM inventory_movements m
         WHERE m.reference_line_id = i.order_line_id
       ) l ON true;

ALTER VIEW vw_order_commitments SET (security_invoker = true);
GRANT SELECT ON vw_order_commitments TO afpc_readonly, afpc_auditor;

COMMENT ON VIEW vw_order_commitments IS
    'One row per order line: what it promises, what stock is committed against it — attributed to '
    'this line, plus a separate figure for commitments on the same document and item that name no '
    'line — what the ledger has actually moved, and whether the two agree. This is the check 0028 promised when it made '
    'line progress a stored counter — quantity_fulfilled is maintained in the same transaction by '
    'the doors in §5, and ledger_agreement compares it against sum of the movement rows that name '
    'the line, so a door that forgets one half fails here rather than at an audit. '
    '"fulfilled without a movement" is a service line and is expected; "DISAGREES" is never '
    'expected, and 0030''s probe H asserts there are none. tenant_id exposed, security_invoker set '
    '(0009), no LIMIT (0017). Built by 0030.';

-- ---------------------------------------------------------------------------
-- 7. Privileges
-- ---------------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION cancel_inventory_reservation(uuid, numeric, text, text, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION ship_sales_order(uuid, uuid, text, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION receive_purchase_order(uuid, uuid, text, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION book_work_order_production(uuid, numeric, text, uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION afpc_settle_commitments(uuid, uuid, uuid, numeric, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION afpc_release_bins(uuid, uuid, uuid, numeric) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION afpc_reservation_names_a_document() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION cancel_inventory_reservation(uuid, numeric, text, text, uuid) TO afpc_app;
GRANT  EXECUTE ON FUNCTION ship_sales_order(uuid, uuid, text, uuid) TO afpc_app;
GRANT  EXECUTE ON FUNCTION receive_purchase_order(uuid, uuid, text, uuid) TO afpc_app;
GRANT  EXECUTE ON FUNCTION book_work_order_production(uuid, numeric, text, uuid, uuid) TO afpc_app;
GRANT  EXECUTE ON FUNCTION afpc_settle_commitments(uuid, uuid, uuid, numeric, text) TO afpc_app;
GRANT  EXECUTE ON FUNCTION afpc_release_bins(uuid, uuid, uuid, numeric) TO afpc_app;

-- ---------------------------------------------------------------------------
-- 5.5 The reservation door learns to name the line it holds stock for
-- ---------------------------------------------------------------------------
-- §3 gives order_line_id a writer for the rows that already existed, and §4 lets the database refuse
-- a wrong one. Without this, the column would be true of the migration and false of everything made
-- after it: reserve_inventory_for_order takes an item, a warehouse and a document, and a commitment
-- that names an order but no line is one step short of the thing §1's reconciliation needs. So the
-- door that makes commitments learns the argument the fact has always had.
--
-- Appended as the NINTH parameter, defaulted, because p_idempotency_key is eighth and a positional
-- caller that sends eight arguments must not find its claim key landing in a line column. The
-- inventory agent's tool sends exactly eight, and TestClaimsAreLast in that package keeps the key
-- last when the tool grows the ninth. Same reason 0014 appended its two additions rather than
-- inserting them, and the same reason 0016 drops by full signature first: CREATE OR REPLACE with a
-- changed parameter list OVERLOADS, and an overload makes every call to the name ambiguous.
DO $$
DECLARE
    v_src  text;
    v_orig text;
    v_new  text;
    v_sig  text;
    v_n    int;
    v_pair text[][] := ARRAY[
        ['p_idempotency_key uuid DEFAULT NULL::uuid)',
         'p_idempotency_key uuid DEFAULT NULL::uuid, p_order_line_id uuid DEFAULT NULL::uuid)'],
        ['(item_id, warehouse_id, location_id, order_type, order_id,
             reserved_quantity, reserved_by, priority)',
         '(item_id, warehouse_id, location_id, order_type, order_id,
             reserved_quantity, reserved_by, priority, order_line_id)'],
        ['(p_item_id, p_warehouse_id, p_location_id, p_order_type, p_order_id,
             p_quantity, p_reserved_by, 1)',
         '(p_item_id, p_warehouse_id, p_location_id, p_order_type, p_order_id,
             p_quantity, p_reserved_by, 1, p_order_line_id)']
    ];
    i int;
BEGIN
    SELECT pg_get_functiondef(p.oid),
           format('%s.%I(%s)', n.nspname, p.proname,
                  pg_get_function_identity_arguments(p.oid))
      INTO v_src, v_sig
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'reserve_inventory_for_order';
    IF v_src IS NULL THEN
        RAISE EXCEPTION '5.5 failed: reserve_inventory_for_order is not installed';
    END IF;

    -- Three needles. The fourth this transform first carried — adding a 'line' key to the idempotency
    -- fingerprint — is deliberately not in it, for two reasons worth keeping together. The fingerprint
    -- is checked against the one stored when a claim was FIRST made, so changing what goes into it
    -- makes every in-flight claim look like a payload mismatch for as long as it can be retried (24h
    -- here). And the case it would guard is already guarded: the key, the item, the warehouse, the
    -- quantity and the document are in it, and a retry that added only a line reference describes the
    -- same reservation of the same stock — where returning the first answer is the correct answer and
    -- not a stale one.
    v_orig := v_src;
    FOR i IN SELECT unnest(ARRAY[1,2,3]) LOOP
        v_n := length(v_src) - length(replace(v_src, v_pair[i][1], ''));
        IF v_n <> length(v_pair[i][1]) THEN
            RAISE EXCEPTION '5.5 failed: needle % occurs % time(s) in the installed body, expected '
                            'exactly once — the door has moved since this transform was written, and '
                            'a partial replace would produce a function whose INSERT and its argument '
                            'list disagree',
                i, CASE WHEN v_n = 0 THEN 0 ELSE v_n / length(v_pair[i][1]) END;
        END IF;
        v_src := replace(v_src, v_pair[i][1], v_pair[i][2]);
    END LOOP;
    IF v_src = v_orig THEN
        RAISE EXCEPTION '5.5 failed: all three needles matched and nothing changed';
    END IF;

    EXECUTE format('DROP FUNCTION %s', v_sig);
    EXECUTE v_src;

    SELECT format('%s.%I(%s)', n2.nspname, p2.proname,
                  pg_get_function_identity_arguments(p2.oid)) INTO v_sig
      FROM pg_proc p2 JOIN pg_namespace n2 ON n2.oid = p2.pronamespace
     WHERE n2.nspname = 'public' AND p2.proname = 'reserve_inventory_for_order';
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC', v_sig);
    EXECUTE format('GRANT  EXECUTE ON FUNCTION %s TO afpc_app', v_sig);

    SELECT count(*) INTO v_n FROM pg_proc WHERE proname = 'reserve_inventory_for_order';
    IF v_n <> 1 THEN
        RAISE EXCEPTION '5.5 failed: % heads of reserve_inventory_for_order — 4.4 in this schema''s '
                        'own history, and the reason every one of these transforms drops before it '
                        'creates', v_n;
    END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- 8. Verify by behaving
-- ---------------------------------------------------------------------------
-- Every mutating probe below runs inside a subtransaction that is then discarded, because this file
-- has already changed real state once (the backfill) and a verification pass must not change it
-- again. The discard pattern is 0029's probe E, including the reason the verdict is captured in a
-- variable and asserted OUTSIDE the handler: a handler that swallows an exception also swallows an
-- assertion, and the run then reports a clean pass for a probe that never finished.
DO $$
DECLARE
    v_n         int := 0;
    v_err       text;
    v_msg       text;
    v_cname     text;
    v_ok        boolean;
    v_found     bigint;
    v_td        uuid;
    v_t2        uuid;
    v_ord       uuid;
    v_ord2      uuid;
    v_line      uuid;
    v_line2     uuid;
    v_rid       uuid;
    v_rstat     text;
    v_ent       bigint;
    v_sup       uuid;
    v_wh        uuid;
    v_item      uuid;
    v_key       uuid;
    v_mid       uuid;
    v_q         numeric;
    v_q2        numeric;
    v_res       text;
    v_shipped   numeric;
    v_status    text;
    v_number    text;
    v_before_r  numeric;
    v_before_oh numeric;
    v_lines     int;
    v_wh_fixture   uuid;   -- the three below exist only when 0030 had to make them; §8 says why
    v_item_fixture uuid;
    v_ent_fixture  bigint;
    v_ent2         bigint;   -- tenant two's party, in its own variable — see probe J
    r           record;
BEGIN
    ------------------------------------------------------------------
    -- A. the shape this file claims, read back from the catalog.
    ------------------------------------------------------------------
    SELECT tenant_id INTO v_td FROM tenants WHERE slug = 'default';
    ------------------------------------------------------------------
    -- Master data, created rather than assumed — 0028's and 0029's note, and the reason all three
    -- files in this programme carry it: scripts/db/db migrates and only then seeds, so a migration
    -- that reads db/seeds/ rows cannot run on a clean database at all. Each row below is deleted at
    -- the bottom of this file if and only if this file made it.
    ------------------------------------------------------------------
    SELECT warehouse_id INTO v_wh FROM warehouses WHERE tenant_id = v_td
     ORDER BY default_warehouse DESC NULLS LAST, warehouse_code LIMIT 1;
    IF v_wh IS NULL THEN
        INSERT INTO warehouses (tenant_id, warehouse_code, name, warehouse_type, is_active)
        VALUES (v_td, '0030PROBE', '0030 probe store', 'PRIMARY', true)
        RETURNING warehouses.warehouse_id INTO v_wh;
        v_wh_fixture := v_wh;
    END IF;
    SELECT item_id INTO v_item FROM inventory_items WHERE tenant_id = v_td ORDER BY sku LIMIT 1;
    IF v_item IS NULL THEN
        INSERT INTO inventory_items (tenant_id, sku, name, description, product_type,
                                     base_unit_of_measure, cost_method, currency_code, reorder_point)
        VALUES (v_td, '0030-PROBE-STOCK', '0030 probe part', 'Created by 0030''s own fixtures',
                'STOCKED', 'EACH', 'AVERAGE', 'USD', 4)
        RETURNING inventory_items.item_id INTO v_item;
        v_item_fixture := v_item;
    END IF;
    SELECT id INTO v_ent FROM vw_customers WHERE tenant_id = v_td ORDER BY id LIMIT 1;
    IF v_ent IS NULL THEN
        SELECT entity_id INTO v_ent
          FROM add_customer('0030', 'Fixture', 'fixture0030@afpc.example.invalid', NULL, NULL, NULL,
                            NULL, NULL, 'US', 'active', 'business', '0030 Fixture Co', 'shipping',
                            true, NULL);
        v_ent_fixture := v_ent;
    END IF;
    -- Stock for the doors to move, received once rather than per-probe: the probes that need it run
    -- inside discards, and an empty shelf would make every one of them a refusal about availability
    -- instead of about the rule under test. 40 units is more than any probe asks for, and the
    -- cleanup below reverses the row through the same door that wrote it.
    IF NOT EXISTS (SELECT 1 FROM inventory_on_hand h
                    WHERE h.item_id = v_item AND h.warehouse_id = v_wh
                      AND h.quantity_on_hand >= 40) THEN
        PERFORM execute_inventory_movement('RECEIPT', v_item, NULL, v_wh, 40, 2,
                                          'migration:0030', 'ADJUSTMENT', NULL, 'SEED_BALANCE',
                                          'EACH');
    END IF;
    IF (SELECT count(*) FROM pg_attribute
         WHERE attrelid = 'inventory_movements'::regclass AND attname = 'reference_line_id'
           AND atttypid = 'uuid'::regtype AND NOT attnotnull) <> 1 THEN
        RAISE EXCEPTION 'A failed: inventory_movements.reference_line_id is not the nullable uuid '
                        'column 0030 adds — a NOT NULL one would refuse the 36 movements already '
                        'filed, and a wider type cannot join to order_items';
    END IF;
    FOR r IN SELECT t FROM unnest(ARRAY[
              'inventory_movements_reference_line_in_tenant_fkey',
              'inventory_reservations_order_line_in_tenant_fkey']) AS t
    LOOP
        v_msg := r.t;   -- reused below as the constraint name under test
        IF (SELECT count(*) FROM pg_constraint k JOIN pg_class c ON c.oid = k.conrelid
             WHERE k.conname = v_msg AND k.contype = 'f' AND k.convalidated
               AND cardinality(k.conkey) = 2) <> 1 THEN
            RAISE EXCEPTION 'A failed: % is not an installed, validated, TWO-COLUMN key — the '
                            'single-column form is the one 0027 measured as tenant-blind', v_msg;
        END IF;
    END LOOP;
    IF (SELECT count(*) FROM pg_trigger t
         WHERE t.tgrelid = 'inventory_reservations'::regclass
           AND t.tgname = 'afpc_reservation_names_a_document' AND NOT t.tgisinternal
           AND (t.tgtype & 2) = 2) <> 1 THEN
        RAISE EXCEPTION 'A failed: the enforcement trigger is missing or is not a BEFORE trigger, '
                        'so a commitment could be written before it refused';
    END IF;
    IF (SELECT count(*) FROM vw_index_redundancy) <> 0 THEN
        RAISE EXCEPTION 'A failed: 0030 added a redundant index pair, which 0006''s invariant forbids';
    END IF;
    -- The reference_type CASE must still be the only writer's mapping: 0029 fixed WORK, and a
    -- fulfilment door that names a document type in the ledger has to agree with it.
    IF NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.proname = 'afpc_release_bins') THEN
        RAISE EXCEPTION 'A failed: the release selector is absent, so cancel would have to guess bins';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- B. THE LEAK, CLOSED. Measured rather than asserted, and the numbers are the point: before this
    --    file there were four commitments naming nothing and thirteen units with no way back.
    ------------------------------------------------------------------
    SELECT count(*) INTO v_found
      FROM inventory_reservations res
     WHERE res.order_type IN ('SALES','PURCHASE','WORK')
       AND NOT EXISTS (SELECT 1 FROM orders o
                        WHERE o.tenant_id = res.tenant_id AND o.order_id = res.order_id);
    IF v_found <> 0 THEN
        RAISE EXCEPTION 'B failed: % document-type commitment(s) still name a document that does not '
                        'exist — §3 is the reason 0030 attaches its trigger only after the backfill, '
                        'and if this is nonzero the backfill did not run', v_found;
    END IF;
    SELECT count(*) INTO v_found
      FROM inventory_reservations res
     WHERE res.order_type IN ('SALES','PURCHASE') AND res.order_line_id IS NULL;
    IF v_found <> 0 THEN
        RAISE EXCEPTION 'B failed: % commitment(s) resolve to a document but not to a LINE, so '
                        'order_line_id is still the column 0001 declared and nothing wrote', v_found;
    END IF;
    -- Backfilled documents exist, and the stock they hold is STILL held: a migration that resolved
    -- the pointer by releasing the units would have "fixed" the leak by deleting the evidence and
    -- changing what the warehouse can promise.
    IF (SELECT count(*) FROM inventory_reservations) > 0
       AND (SELECT count(*) FROM orders WHERE origin = 'RESERVATION_BACKFILL') < 1 THEN
        RAISE EXCEPTION 'B failed: % commitment(s) exist and none of them needed a backfill, which '
                        'the two checks above say is impossible — either the documents were already '
                        'there, or §3 did not run',
            (SELECT count(*) FROM inventory_reservations);
    ELSIF (SELECT count(*) FROM inventory_reservations) = 0 THEN
        -- A from-zero database mid-lineage: migrations run before the seeds, so there is nothing to
        -- resolve yet. The assertions that need a subject are skipped and SAY so rather than passing
        -- quietly — the difference between "verified" and "not applicable" is exactly what
        -- test-functions.sh separates KNOWN-OPEN from CLOSED for.
        RAISE NOTICE 'B: no commitments exist on this database yet, so §3 had nothing to resolve; '
                     'db/seeds/02 and the first real order exercise it';
    END IF;
    SELECT sum(res.reserved_quantity - coalesce(res.shipped_quantity,0) - coalesce(res.cancelled_quantity,0))
      INTO v_q FROM inventory_reservations res;
    SELECT sum(h.quantity_reserved) INTO v_q2 FROM inventory_on_hand h;
    -- Coalesced on both sides, because "nothing committed" and "nothing reserved" are both NULL and
    -- zero in equal measure: a from-zero database has no reservations at all, so sum() is NULL while
    -- sum(quantity_reserved) over real rows is 0.0000, and IS DISTINCT FROM read that as a
    -- disagreement in the file whose whole subject is disagreement.
    IF coalesce(v_q, 0) <> coalesce(v_q2, 0) THEN
        RAISE EXCEPTION 'B failed: the commitments add up to % and the balance to % — the backfill '
                        'was supposed to leave both alone, and this is the disagreement the whole '
                        'file is about, arriving in the file that fixes it',
            coalesce(v_q, 0)::text, coalesce(v_q2, 0)::text;
    END IF;
    IF v_q IS NULL AND coalesce(v_q2, 0) <> 0 THEN
        RAISE EXCEPTION 'B failed: the balance holds % committed unit(s) while no commitment row '
                        'claims any — that is the disagreement 0030 exists to end, arriving inside '
                        'the file that ends it', v_q2;
    END IF;
    -- And the reconciliation view is not silently empty.
    IF (SELECT count(*) FROM vw_order_commitments) <> (SELECT count(*) FROM order_items) THEN
        RAISE EXCEPTION 'B failed: vw_order_commitments shows % of % lines — a read path that hides '
                        'a row is worse than no read path, because the agent will conclude the line '
                        'is gone', (SELECT count(*) FROM vw_order_commitments),
                        (SELECT count(*) FROM order_items);
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- C. the enforcement, from the seat that will actually be used. Three refusals and one
    --    acceptance, each discarded: the point is the answer, not the row.
    ------------------------------------------------------------------

    v_err := NULL;
    BEGIN
        PERFORM * FROM reserve_inventory_for_order(v_item, v_wh, 1, 'SALES', gen_random_uuid(),
                                                   '0030-probe', NULL, NULL);
        RAISE EXCEPTION 'accepted' USING ERRCODE = 'P0002';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'accepted' THEN v_err := SQLSTATE;
        ELSE v_err := 'no error: a document id that names nothing was WRITTEN'; END IF;
    END;
    IF v_err IS DISTINCT FROM '23503' THEN
        RAISE EXCEPTION 'C failed: reserving for a nonexistent order answered % — the trigger is the '
                        'only thing that makes order_id mean something, and 0030''s whole argument is '
                        'that it must', v_err;
    END IF;

    -- The type must agree too: a SALES commitment against a WORK document would release the wrong
    -- warehouse's stock on a ship that the other door owns.
    v_err := NULL;
    BEGIN
        SELECT order_id INTO v_ord FROM create_order('WORK', NULL, NULL, v_wh, NULL, NULL, NULL,
                                                     '0030 type-mismatch', 'MANUAL', NULL);
        PERFORM * FROM reserve_inventory_for_order(v_item, v_wh, 1, 'SALES', v_ord,
                                                   '0030-probe', NULL, NULL);
        RAISE EXCEPTION 'accepted' USING ERRCODE = 'P0002';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'accepted' THEN v_err := SQLSTATE;
        ELSE v_err := 'no error: the two columns disagreed and nothing noticed'; END IF;
    END;
    IF v_err IS DISTINCT FROM '23503' THEN
        RAISE EXCEPTION 'C failed: a SALES commitment naming a WORK order answered %', v_err;
    END IF;

    -- A line from another document, same tenant, same type: §4's key passes (the line is real and
    -- the caller's), and only the trigger can refuse it.
    v_err := NULL;
    BEGIN
        SELECT order_id INTO v_ord FROM create_order('SALES', v_ent, NULL, v_wh, NULL, NULL, NULL,
                                                    '0030 line-a', 'MANUAL', NULL);
        IF v_ord IS NULL THEN
            SELECT id INTO v_ent FROM vw_customers WHERE tenant_id = v_td ORDER BY id LIMIT 1;
            SELECT order_id INTO v_ord FROM create_order('SALES', v_ent, NULL, v_wh, NULL, NULL,
                                                         NULL, '0030 line-a', 'MANUAL', NULL);
        END IF;
        SELECT order_line_id INTO v_line FROM add_order_line(v_ord, v_item, NULL, 5, 10, NULL,
                                                             'STANDARD', v_wh, NULL, NULL, NULL, NULL);
        SELECT order_id INTO v_ord2 FROM create_order('SALES', v_ent, NULL, v_wh, NULL, NULL, NULL,
                                                      '0030 line-b', 'MANUAL', NULL);
        PERFORM * FROM reserve_inventory_for_order(v_item, v_wh, 1, 'SALES', v_ord2, '0030-probe',
                                                   NULL, NULL);
        UPDATE inventory_reservations SET order_line_id = v_line
         WHERE order_type = 'SALES' AND order_id = v_ord2;
        RAISE EXCEPTION 'accepted' USING ERRCODE = 'P0002';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'accepted' THEN v_err := SQLSTATE;
        ELSE v_err := 'no error: a commitment borrowed another order''s line'; END IF;
    END;
    IF v_err IS DISTINCT FROM '23503' THEN
        RAISE EXCEPTION 'C failed: attaching another document''s line answered % — this is the '
                        'relationship no key on this table can express, so if the trigger stops '
                        'checking it, nothing does', v_err;
    END IF;

    -- And the legal case must be ACCEPTED, or the three refusals above are a blanket failure.
    -- The order is made INSIDE this subtransaction: the two blocks above discarded theirs, so reusing
    -- v_ord would have been a probe that reserves against a row that is no longer there — which is
    -- how this line first failed, with the enforcement refusing a document that had already been
    -- rolled back. The enforcement was right; the probe was not.
    v_err := NULL;
    BEGIN
        SELECT order_id INTO v_ord FROM create_order('SALES', v_ent, NULL, v_wh, NULL, NULL, NULL,
                                                     '0030 legal', 'MANUAL', NULL);
        SELECT order_line_id INTO v_line FROM add_order_line(v_ord, v_item, NULL, 3, 5, NULL,
                                      'STANDARD', v_wh, NULL, NULL, NULL, NULL);
        SELECT reservation_id INTO v_rid
          FROM reserve_inventory_for_order(v_item, v_wh, 2, 'SALES', v_ord, '0030-probe', NULL, NULL);
        IF v_rid IS NULL THEN
            v_err := 'the door returned no reservation id'; 
        END IF;
        -- and the line belongs to the same document, so attaching it is legal
        UPDATE inventory_reservations SET order_line_id = v_line
         WHERE reservation_id = v_rid;
        RAISE EXCEPTION 'accepted' USING ERRCODE = 'P0002';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'accepted' THEN v_err := SQLSTATE || ': ' || left(SQLERRM, 120); END IF;
    END;
    IF v_err IS NOT NULL THEN
        RAISE EXCEPTION 'C failed: the legitimate reservation was refused too (%), which makes the '
                        'three refusals above meaningless', v_err;
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- D. a backfilled document has no invented counterparty. The alternative — pointing a purchase
    --    commitment at whichever supplier was inserted first — is a false attribution, and 0028's
    --    CHECK permits the gap only when origin names it.
    ------------------------------------------------------------------
    SELECT count(*), count(*) FILTER (WHERE customer_id IS NULL),
           count(*) FILTER (WHERE vendor_id IS NOT NULL)
      INTO v_found, v_q, v_q2
      FROM orders WHERE origin = 'RESERVATION_BACKFILL';
    IF v_found = 0 AND NOT EXISTS (SELECT 1 FROM inventory_reservations) THEN
        RAISE NOTICE 'D: no backfilled documents and no commitments, so the counterparty rule below '
                     'has no subject on this database yet — skipped, and stated';
    ELSIF v_found = 0 THEN
        RAISE EXCEPTION 'D failed: % commitment(s) exist and no backfilled document does, which B '
                        'already said is impossible', (SELECT count(*) FROM inventory_reservations);
    END IF;
    IF v_found > 0 AND v_q <> v_found THEN
        RAISE EXCEPTION 'D failed: % backfilled order(s), of which % name no party — the backfill '
                        'resolves what a reservation already proved and no more', v_found, v_q;
    END IF;
    IF coalesce(v_q2, 0) <> 0 THEN
        RAISE EXCEPTION 'D failed: a backfilled order names a supplier, and nothing in '
                        'inventory_reservations can prove one';
    END IF;
    IF EXISTS (SELECT 1 FROM orders o WHERE o.origin = 'RESERVATION_BACKFILL'
                 AND o.order_number !~ '^SO-[0-9]{6,}$') THEN
        RAISE EXCEPTION 'D failed: a backfilled document carries a number outside the format '
                        'create_order allocates, so the two writers disagree about what a number is';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- E. THE ROUND TRIP: raise a PO, receive it, sell it, hold it, ship it — and check every number
    --    the warehouse now claims, on a subtransaction that leaves nothing behind.
    --
    -- This is the only probe that exercises all four halves of 0030 together, and it is written as
    -- behaviour because the arithmetic it checks is the arithmetic no CHECK can reach: quantity_on_hand
    -- minus quantity_reserved, across two documents and five rows.
    ------------------------------------------------------------------
    SELECT id INTO v_ent FROM vw_customers WHERE tenant_id = v_td ORDER BY id LIMIT 1;
    v_res := 'not-run';
    v_err := NULL;
    BEGIN
        -- a supplier, and a purchase order for 20 of something at 3
        SELECT supplier_id INTO v_sup
          FROM add_supplier('0030-SUP', NULL, '0030 Components Ltd', NULL, 'Net 30', NULL, NULL,
                            NULL, true, NULL);
        SELECT order_id, order_number INTO v_ord, v_number
          FROM create_order('PURCHASE', NULL, v_sup, v_wh, NULL, NULL, NULL, NULL, 'MANUAL', NULL);
        SELECT order_line_id INTO v_line
          FROM add_order_line(v_ord, v_item, NULL, 20, 3.00, NULL, 'STANDARD', v_wh, NULL, NULL,
                              NULL, NULL);

        SELECT success, status, received_quantity INTO v_ok, v_status, v_q
          FROM receive_purchase_order(v_ord, NULL, '0030-probe', NULL);
        IF NOT v_ok THEN v_res := 'receive refused: ' || v_status; RAISE EXCEPTION 'stop'; END IF;
        IF v_status <> 'RECEIVED' OR v_q <> 20 THEN
            v_res := format('receive said %s / %s', v_status, v_q); RAISE EXCEPTION 'stop';
        END IF;
        IF (SELECT count(*) FROM inventory_movements m
             WHERE m.reference_line_id = v_line AND m.movement_type = 'RECEIPT') <> 1 THEN
            v_res := 'the receipt did not name the line'; RAISE EXCEPTION 'stop';
        END IF;

        -- now sell 7 of them, hold them, and ship
        SELECT order_id INTO v_ord2
          FROM create_order('SALES', v_ent, NULL, v_wh, NULL, NULL, NULL, '0030 sale', 'MANUAL', NULL);
        SELECT order_line_id INTO v_line2
          FROM add_order_line(v_ord2, v_item, NULL, 7, 9.00, NULL, 'STANDARD', v_wh, NULL, NULL,
                              NULL, NULL);

        -- DELTAS, not totals. The first draft asserted that the shelf held exactly 7 reserved units
        -- after this hold, which is true only if nothing else was holding any — on the live database
        -- the demo seed and 0015's own probes hold several, so the assertion was about other
        -- people's rows and would have failed for reasons this probe has nothing to do with.
        SELECT coalesce(sum(h.quantity_reserved), 0), coalesce(sum(h.quantity_on_hand), 0),
               coalesce(sum(h.quantity_available), 0)
          INTO v_before_r, v_before_oh, v_shipped
          FROM inventory_on_hand h WHERE h.item_id = v_item AND h.warehouse_id = v_wh;

        SELECT reservation_id INTO v_rid
          FROM reserve_inventory_for_order(v_item, v_wh, 7, 'SALES', v_ord2, '0030-probe', NULL, NULL);

        SELECT coalesce(sum(h.quantity_reserved), 0) INTO v_found
          FROM inventory_on_hand h WHERE h.item_id = v_item AND h.warehouse_id = v_wh;
        IF v_found <> v_before_r + 7 THEN
            v_res := format('a 7-unit hold moved reserved %s → %s instead of %s', v_before_r,
                            v_found, v_before_r + 7);
            RAISE EXCEPTION 'stop';
        END IF;

        SELECT success, status, shipped_quantity INTO v_ok, v_status, v_q
          FROM ship_sales_order(v_ord2, NULL, '0030-probe', NULL);
        IF NOT v_ok THEN v_res := 'ship refused'; RAISE EXCEPTION 'stop'; END IF;
        IF v_status <> 'SHIPPED' OR v_q <> 7 THEN
            v_res := format('ship said %s / %s', v_status, v_q); RAISE EXCEPTION 'stop';
        END IF;

        -- every number the warehouse now claims, checked against what it claimed before
        SELECT coalesce(sum(h.quantity_reserved), 0), coalesce(sum(h.quantity_on_hand), 0),
               coalesce(sum(h.quantity_available), 0)
          INTO v_found, v_q2, v_q
          FROM inventory_on_hand h WHERE h.item_id = v_item AND h.warehouse_id = v_wh;
        -- The receipt is already inside v_before_oh — the capture sits after it, on purpose, so
        -- that "what changed" means what this probe changed. The first draft added 20 again here and
        -- the run said 60 → 53, which is the arithmetic being right and the expectation being wrong.
        IF v_q2 <> v_before_oh - 7 THEN
            v_res := format('on hand went %s → %s across a 7-unit shipment', v_before_oh, v_q2);
            RAISE EXCEPTION 'stop';
        END IF;
        -- Reserved is back to exactly the figure this order did not touch: the hold is released by
        -- the shipment, and whatever the seed and other probes were holding is untouched.
        IF v_found <> v_before_r THEN
            v_res := format('reserved is %s after shipping, and was %s before the hold — a shipment '
                            'must leave the shelf promising exactly what it promised before',
                            v_found, v_before_r);
            RAISE EXCEPTION 'stop';
        END IF;
        IF v_q <> v_shipped - 7 THEN
            v_res := format('available went %s → %s: shipping reserved stock leaves it exactly as '
                            'the shipment itself does, because the hold had already taken it out of '
                            'availability', v_shipped, v_q);
            RAISE EXCEPTION 'stop';
        END IF;
        -- shipped_quantity is the column 0015 declared and nothing wrote, now written
        SELECT coalesce(res.shipped_quantity, -1), coalesce(res.cancelled_quantity, 0)
          INTO v_before_r, v_q2
          FROM inventory_reservations res WHERE res.reservation_id = v_rid;
        IF v_before_r <> 7 THEN
            v_res := format('the commitment reports %s shipped of 7', v_before_r); RAISE EXCEPTION 'stop';
        END IF;
        IF (SELECT count(*) FROM order_items i WHERE i.order_line_id = v_line2
              AND i.quantity_fulfilled = 7) <> 1 THEN
            v_res := 'the sales line does not report itself fulfilled'; RAISE EXCEPTION 'stop';
        END IF;
        -- H's claim, tested where it is real: the counter and the ledger agree on a line that moved.
        IF (SELECT ledger_agreement FROM vw_order_commitments
             WHERE order_line_id = v_line2) <> 'agrees' THEN
            v_res := 'a shipped line reads as ' || (SELECT ledger_agreement FROM vw_order_commitments
                                                     WHERE order_line_id = v_line2);
            RAISE EXCEPTION 'stop';
        END IF;
        IF (SELECT ledger_rows FROM vw_order_commitments WHERE order_line_id = v_line2) <> 1 THEN
            v_res := 'the shipment filed more or less than one ledger row for the line';
            RAISE EXCEPTION 'stop';
        END IF;
        v_res := 'pass';
        RAISE EXCEPTION 'discard' USING ERRCODE = 'P0002';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT IN ('discard','stop') AND v_res = 'not-run' THEN
            v_res := 'raised ' || SQLSTATE || ': ' || left(SQLERRM, 140);
        END IF;
    END;
    IF v_res <> 'pass' THEN
        RAISE EXCEPTION 'E failed: %', v_res;
    END IF;
    -- And the discard discarded: nothing above may survive in the live tables.
    IF EXISTS (SELECT 1 FROM orders WHERE notes LIKE '0030 sale%')
       OR EXISTS (SELECT 1 FROM inventory_reservations WHERE reserved_by = '0030-probe') THEN
        RAISE EXCEPTION 'E failed: the subtransaction was committed — a probe that changes the '
                        'warehouse''s numbers while checking them is not a probe, it is an incident';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- F. cancel: the door that did not exist, on a commitment that does. Also discarded.
    ------------------------------------------------------------------
    v_res := 'not-run';
    BEGIN
        SELECT order_id INTO v_ord
          FROM create_order('SALES', v_ent, NULL, v_wh, NULL, NULL, NULL, '0030 cancel',
                            'MANUAL', NULL);
        SELECT order_line_id INTO v_line
          FROM add_order_line(v_ord, v_item, NULL, 4, 5, NULL, 'STANDARD', v_wh, NULL, NULL,
                              NULL, NULL);
        SELECT reservation_id INTO v_rid
          FROM reserve_inventory_for_order(v_item, v_wh, 4, 'SALES', v_ord, '0030-probe', NULL, NULL);

        SELECT coalesce(sum(h.quantity_reserved), 0), coalesce(sum(h.quantity_available), 0)
          INTO v_before_r, v_before_oh
          FROM inventory_on_hand h WHERE h.item_id = v_item AND h.warehouse_id = v_wh;

        SELECT success, status, released_quantity INTO v_ok, v_status, v_q
          FROM cancel_inventory_reservation(v_rid, 2, 'customer halved the order', '0030-probe', NULL);
        IF NOT v_ok OR v_status <> 'PARTIALLY_CANCELLED' OR v_q <> 2 THEN
            v_res := format('partial cancel said %s / %s', v_status, v_q); RAISE EXCEPTION 'stop';
        END IF;
        SELECT coalesce(sum(h.quantity_reserved), 0) INTO v_q2
          FROM inventory_on_hand h WHERE h.item_id = v_item AND h.warehouse_id = v_wh;
        IF v_q2 <> v_before_r - 2 THEN
            v_res := format('a 2-unit release moved reserved from %s to %s', v_before_r, v_q2);
            RAISE EXCEPTION 'stop';
        END IF;
        -- The ledger mirror, and its sign
        IF (SELECT count(*) FROM inventory_movements m
             WHERE m.reference_id = v_ord AND m.movement_type = 'RESERVATION'
               AND m.quantity = -2 AND m.reason_code = 'RESERVATION_RELEASED') <> 1 THEN
            v_res := 'the release filed no negative RESERVATION row'; RAISE EXCEPTION 'stop';
        END IF;
        -- The half that matters to a planner: a release changes nothing that is ON the shelf and
        -- everything that may still be promised. quantity_available is derived from the other two by
        -- 0004's trigger, so this is the availability formula being checked rather than trusted.
        SELECT coalesce(sum(h.quantity_reserved), 0), coalesce(sum(h.quantity_available), 0)
          INTO v_q2, v_found
          FROM inventory_on_hand h WHERE h.item_id = v_item AND h.warehouse_id = v_wh;
        IF v_q2 <> v_before_r - 2 OR v_found <> v_before_oh + 2 THEN
            v_res := format('a 2-unit release moved reserved %s→%s and available %s→%s, and it should '
                            'have moved reserved by -2 and available by +2 with on_hand unchanged',
                            v_before_r, v_q2, v_before_oh, v_found);
            RAISE EXCEPTION 'stop';
        END IF;

        SELECT status INTO v_status FROM cancel_inventory_reservation(v_rid, NULL, 'rest',
                                                                    '0030-probe', NULL);
        IF v_status <> 'CANCELLED' THEN
            v_res := 'the second release left the commitment as ' || v_status; RAISE EXCEPTION 'stop';
        END IF;
        v_err := NULL;
        BEGIN
            PERFORM * FROM cancel_inventory_reservation(v_rid, 1, 'third time', '0030-probe', NULL);
        EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE;
        END;
        IF v_err IS DISTINCT FROM '23514' THEN
            v_res := 'a settled reservation answered ' || coalesce(v_err, 'no error at all');
            RAISE EXCEPTION 'stop';
        END IF;
        -- The two RESERVATION rows for one commitment now net to zero, which is what
        -- vw_item_movement_summary's net_quantity is for.
        IF (SELECT coalesce(sum(m.quantity), 0) FROM inventory_movements m
             WHERE m.reference_id = v_ord AND m.movement_type = 'RESERVATION') <> 0 THEN
            v_res := 'a fully released commitment leaves a non-zero reservation total in the ledger';
            RAISE EXCEPTION 'stop';
        END IF;
        v_res := 'pass';
        RAISE EXCEPTION 'discard' USING ERRCODE = 'P0002';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT IN ('discard','stop') AND v_res = 'not-run' THEN
            v_res := 'raised ' || SQLSTATE || ': ' || left(SQLERRM, 140);
        END IF;
    END;
    IF v_res <> 'pass' THEN RAISE EXCEPTION 'F failed: %', v_res; END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- G. the two bin selectors still agree.
    -- 0015 wrote one helper so that a pick and a release could not disagree about which bin a unit
    -- came from, and said in its own comment that a deployment changing the rule changes one function.
    -- That promise is only true if someone checks the second function was written the same way, and
    -- the cheapest honest check is the ORDER BY text itself — the technique 0029 applied to 0015's CASE.
    ------------------------------------------------------------------
    -- Whitespace collapsed before the extract: the ORDER BY and its FOR UPDATE sit on separate
    -- source lines in both helpers, and `.` does not cross a newline, so an expression written across
    -- two lines reads as "unreadable" and the probe would fail for a formatting reason.
    SELECT substring(regexp_replace(pg_get_functiondef(p.oid), '\s+', ' ', 'g')
                     from 'ORDER BY (.*?) FOR UPDATE') INTO v_msg
      FROM pg_proc p WHERE p.proname = 'afpc_pick_bins';
    SELECT substring(regexp_replace(pg_get_functiondef(p.oid), '\s+', ' ', 'g')
                     from 'ORDER BY (.*?) FOR UPDATE') INTO v_number
      FROM pg_proc p WHERE p.proname = 'afpc_release_bins';
    IF v_msg IS NULL OR v_number IS NULL THEN
        RAISE EXCEPTION 'G failed: the ORDER BY could not be read out of one of the two selectors, so '
                        'the comparison below proves nothing (pick=%, release=%s)',
            coalesce(v_msg,'unreadable'), coalesce(v_number,'unreadable');
    END IF;
    IF v_msg IS DISTINCT FROM v_number THEN
        RAISE EXCEPTION 'G failed: a pick drains % while a release drains % — 0015''s one-policy '
                        'promise is now two policies, and the bin a picker was told about is not the '
                        'bin that gets freed', v_msg, v_number;
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- H. the reconciliation has teeth: a counter edited behind the doors must read as DISAGREES.
    --    Asserting only "no rows disagree" would pass on a view whose comparison is broken the way
    --    0017's observations_aligned could: an always-true expression and a correct one look identical
    --    until a row is wrong, so this makes a row wrong, on purpose, inside a discard.
    ------------------------------------------------------------------
    v_res := 'not-run';
    v_err := NULL;
    BEGIN
        -- Take a line that moved, lie about its counter, and see what the view says.
        SELECT order_id INTO v_ord FROM create_order('SALES', v_ent, NULL, v_wh, NULL, NULL, NULL,
                                                     '0030 reconcile', 'MANUAL', NULL);
        SELECT order_line_id INTO v_line
          FROM add_order_line(v_ord, v_item, NULL, 3, 4, NULL, 'STANDARD', v_wh, NULL, NULL, NULL, NULL);
        PERFORM * FROM ship_sales_order(v_ord, NULL, '0030-probe', NULL);
        SELECT ledger_agreement INTO v_msg FROM vw_order_commitments WHERE order_line_id = v_line;
        IF v_msg <> 'agrees' THEN
            v_res := 'a correctly shipped line reads as ' || coalesce(v_msg,'nothing');
            RAISE EXCEPTION 'stop';
        END IF;
        -- An UNDERCOUNT, not a fantasy: order_items_progress_within_line refuses a counter above the
        -- quantity, so the first draft's "set it to 9" failed the CHECK before it could fail the
        -- comparison — a probe that has to break a constraint to make its point is testing the wrong
        -- thing. One unit short satisfies the CHECK and still disagrees with the ledger.
        UPDATE order_items SET quantity_fulfilled = quantity_fulfilled - 1
         WHERE order_line_id = v_line;
        SELECT ledger_agreement INTO v_msg FROM vw_order_commitments WHERE order_line_id = v_line;
        IF v_msg <> 'DISAGREES' THEN
            v_res := 'a counter edited behind the doors still reads as ' || coalesce(v_msg,'nothing');
            RAISE EXCEPTION 'stop';
        END IF;
        v_res := 'pass';
        RAISE EXCEPTION 'discard' USING ERRCODE = 'P0002';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT IN ('discard','stop') AND v_res = 'not-run' THEN
            v_res := 'raised ' || SQLSTATE || ': ' || left(SQLERRM, 140);
        END IF;
    END;
    IF v_res <> 'pass' THEN RAISE EXCEPTION 'H failed: %', v_res; END IF;
    -- ...and on the live data, nothing disagrees. Both halves together are the claim.
    IF (SELECT count(*) FROM vw_order_commitments WHERE ledger_agreement = 'DISAGREES') <> 0 THEN
        RAISE EXCEPTION 'H failed: % line(s) on this server report progress their ledger does not '
                        'support — %',
            (SELECT count(*) FROM vw_order_commitments WHERE ledger_agreement = 'DISAGREES'),
            (SELECT string_agg(order_number || '/' || line_number, ', ')
               FROM vw_order_commitments WHERE ledger_agreement = 'DISAGREES');
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- I. the ledger door still has ONE head and the old positional calls still resolve. 0014's
    --    comment is the reason this is asserted rather than assumed: CREATE OR REPLACE with a changed
    --    parameter list overloads, and an overload makes every call to the name ambiguous — including
    --    the seed's, which is 11 positional arguments and does not name a single parameter.
    ------------------------------------------------------------------
    IF (SELECT count(*) FROM pg_proc WHERE proname = 'execute_inventory_movement') <> 1 THEN
        RAISE EXCEPTION 'I failed: % heads of execute_inventory_movement — §5.0 added a parameter '
                        'without dropping the old head first',
            (SELECT count(*) FROM pg_proc WHERE proname = 'execute_inventory_movement');
    END IF;
    IF (SELECT count(*) FROM pg_proc p, unnest(p.proargnames) AS a
         WHERE p.proname = 'execute_inventory_movement' AND a = 'p_reference_line_id') <> 1 THEN
        RAISE EXCEPTION 'I failed: the ledger door has no p_reference_line_id parameter, so no door '
                        'can name a line and §1''s column has no writer';
    END IF;
    -- The seed's exact call shape: 11 positional arguments, no names. Inside a discard, because this
    -- probe's subject is whether the CALL resolves, not whether the adjustment lands — and the first
    -- draft let it land, quietly removing one unit of real stock on every run of this migration. The
    -- from-zero database found it: the cleanup then asked for 40 back from a shelf holding 39.
    v_err := NULL;
    BEGIN
        PERFORM execute_inventory_movement('ADJUSTMENT', v_item, v_wh, NULL, 1, NULL,
                                          '0030-probe', 'ADJUSTMENT', gen_random_uuid(), NULL,
                                          'EACH');
        RAISE EXCEPTION 'discard' USING ERRCODE = 'P0002';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'discard' THEN v_err := SQLSTATE || ': ' || left(SQLERRM, 80); END IF;
    END;
    IF v_err IS NOT NULL THEN
        RAISE EXCEPTION 'I failed: a positional call of the pre-0030 shape now answers % — the '
                        'seed and four harness probes call it that way, and adding a defaulted '
                        'parameter is only safe while it stays the LAST one', v_err;
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- J. tenancy: another tenant's document is invisible to these doors, and their commitments and
    --    ledger rows do not appear in this tenant's read path.
    ------------------------------------------------------------------
    INSERT INTO tenants (name, slug) VALUES ('0030 second tenant', 'afpc-0030-t2')
     RETURNING tenant_id INTO v_t2;
    SELECT order_id INTO v_ord FROM create_order('SALES', v_ent, NULL, v_wh, NULL, NULL, NULL,
                                                 '0030 t1 order', 'MANUAL', NULL);
    SET LOCAL ROLE afpc_app;
    PERFORM set_config('app.tenant_id', v_t2::text, true);
    -- v_ent2, never v_ent: 0028's probe K recorded exactly this failure — a fixture variable reused
    -- by a later probe, so every probe after this one builds tenant-one documents out of a tenant-two
    -- party and the composite keys refuse them for a reason nobody is testing.
    SELECT entity_id INTO v_ent2
      FROM add_customer('0030', 'Other', 'x0030@afpc.example.invalid',
                        NULL, NULL, NULL, NULL, NULL, 'US', 'active',
                        'business', '0030 Other Co', 'shipping', true, NULL);
    SELECT order_id INTO v_ord2 FROM create_order('SALES', v_ent2, NULL, NULL, NULL, NULL, NULL,
                                                  '0030 t2 order', 'MANUAL', NULL);
    v_err := NULL;
    BEGIN
        PERFORM * FROM ship_sales_order(v_ord, NULL, '0030-probe', NULL);
    EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '22023' THEN
        RAISE EXCEPTION 'J failed: tenant 2 shipping tenant 1''s document answered % — a fulfilment '
                        'door that reads through the wall is the difference between an order '
                        'reference and an authorisation', coalesce(v_err, 'no error: it shipped it');
    END IF;
    IF EXISTS (SELECT 1 FROM vw_order_commitments WHERE tenant_id <> v_t2) THEN
        RAISE EXCEPTION 'J failed: vw_order_commitments published a row across the wall';
    END IF;
    RESET ROLE;
    SET LOCAL ROLE afpc_app;
    PERFORM set_config('app.tenant_id', v_td::text, true);
    IF EXISTS (SELECT 1 FROM vw_order_commitments WHERE tenant_id <> v_td) THEN
        RAISE EXCEPTION 'J failed: the default tenant sees % lines it does not own',
            (SELECT count(*) FROM vw_order_commitments WHERE tenant_id <> v_td);
    END IF;
    RESET ROLE;
    -- The reads above ran as the app role and the mutations ran as the owner; both are what a
    -- deployed agent does, and the difference between them is 0027's whole argument about keys.
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- K. the registers notice everything, and the trail still verifies.
    ------------------------------------------------------------------
    IF (SELECT count(*) FROM vw_idempotency_status s
         WHERE s.function IN ('cancel_inventory_reservation','ship_sales_order',
                              'receive_purchase_order','book_work_order_production')
           AND NOT s.unguarded) <> 4 THEN
        RAISE EXCEPTION 'K failed: the idempotency register credits % of 0030''s four doors with a '
                        'claim — ADR-005 is per-door, and a fulfilment without one is a double '
                        'shipment waiting for a network timeout',
            (SELECT count(*) FROM vw_idempotency_status s
              WHERE s.function IN ('cancel_inventory_reservation','ship_sales_order',
                                   'receive_purchase_order','book_work_order_production')
                AND NOT s.unguarded);
    END IF;
    FOR r IN SELECT t FROM unnest(ARRAY['orders','order_items','inventory_reservations',
                                        'inventory_movements','document_counters']) AS t
    LOOP
        -- (row_audited, exempted, decision) are the register's three columns; the reason lives in
        -- `decision`, and asking for a column that is not there is how a check becomes an error.
        IF NOT EXISTS (SELECT 1 FROM vw_audit_coverage a
                        WHERE a.table_name = r.t AND (a.row_audited OR a.exempted)) THEN
            RAISE EXCEPTION 'K failed: % is neither trailead nor exempted, so vw_audit_coverage '
                            'cannot answer who changed it', r.t;
        END IF;
    END LOOP;
    IF (SELECT count(*) FROM audit_chain_verify() WHERE NOT chain_ok) <> 0 THEN
        SELECT string_agg(reason, ' / ') INTO v_msg FROM audit_chain_verify() WHERE NOT chain_ok;
        RAISE EXCEPTION 'K failed: the chain does not verify after 0030 — %', v_msg;
    END IF;
    -- 6.3, specifically: the table this file rewrites must now say when.
    SELECT verdict INTO v_msg FROM vw_timestamp_status WHERE table_name = 'inventory_reservations';
    IF v_msg IS DISTINCT FROM 'maintained' THEN
        RAISE EXCEPTION 'K failed: the timestamp register says % of inventory_reservations, and '
                        '0030''s two settlement doors are the reason B24 counts it — a rewritten row '
                        'with no timestamp is a change nobody can date', coalesce(v_msg, 'nothing');
    END IF;
    -- vw_domain_vocabulary must still publish the reference_type set 0029 repaired; a second
    -- membership CHECK on the same column would be listed twice and B18 would fail.
    IF (SELECT count(*) FROM vw_domain_vocabulary d
         WHERE d.table_name = 'inventory_movements' AND d.column_name = 'reference_type') <> 1 THEN
        RAISE EXCEPTION 'K failed: reference_type appears % time(s) in the vocabulary register',
            (SELECT count(*) FROM vw_domain_vocabulary d
              WHERE d.table_name = 'inventory_movements' AND d.column_name = 'reference_type');
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- L. a retried call is one fulfilment, on all four doors, at the level that matters: the stock.
    ------------------------------------------------------------------
    v_res := 'not-run';
    BEGIN
        v_key := gen_random_uuid();
        SELECT order_id INTO v_ord FROM create_order('SALES', v_ent, NULL, v_wh, NULL, NULL, NULL,
                                                     '0030 replay', 'MANUAL', v_key);
        SELECT order_id INTO v_ord2 FROM create_order('SALES', v_ent, NULL, v_wh, NULL, NULL, NULL,
                                                      '0030 replay', 'MANUAL', v_key);
        IF v_ord2 <> v_ord THEN
            v_res := 'a replayed create made a second order'; RAISE EXCEPTION 'stop';
        END IF;
        SELECT order_line_id INTO v_line
          FROM add_order_line(v_ord, v_item, NULL, 2, 3, NULL, 'STANDARD', v_wh, NULL, NULL, NULL,
                              v_key);
        PERFORM * FROM add_order_line(v_ord, v_item, NULL, 2, 3, NULL, 'STANDARD', v_wh, NULL, NULL,
                                      NULL, v_key);
        IF (SELECT count(*) FROM order_items WHERE order_id = v_ord) <> 1 THEN
            v_res := 'a replayed line add made two lines'; RAISE EXCEPTION 'stop';
        END IF;
        SELECT reservation_id INTO v_rid
          FROM reserve_inventory_for_order(v_item, v_wh, 2, 'SALES', v_ord, '0030-probe', NULL, NULL);
        v_key := gen_random_uuid();
        SELECT status INTO v_status FROM cancel_inventory_reservation(v_rid, NULL, 'twice',
                                                                    '0030-probe', v_key);
        SELECT status INTO v_status FROM cancel_inventory_reservation(v_rid, NULL, 'twice',
                                                                    '0030-probe', v_key);
        IF (SELECT count(*) FROM inventory_movements m
             WHERE m.reference_id = v_ord AND m.movement_type = 'RESERVATION'
               AND m.quantity < 0) <> 1 THEN
            v_res := 'a replayed release filed ' ||
                     (SELECT count(*) FROM inventory_movements m
                       WHERE m.reference_id = v_ord AND m.movement_type = 'RESERVATION'
                         AND m.quantity < 0) || ' ledger rows for one release';
            RAISE EXCEPTION 'stop';
        END IF;
        v_res := 'pass';
        RAISE EXCEPTION 'discard' USING ERRCODE = 'P0002';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT IN ('discard','stop') AND v_res = 'not-run' THEN
            v_res := 'raised ' || SQLSTATE || ': ' || left(SQLERRM, 140);
        END IF;
    END;
    IF v_res <> 'pass' THEN RAISE EXCEPTION 'L failed: %', v_res; END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- M. the claim backlog, collected once. 0011 wrote idempotency_sweep and nothing has called it
    --    since: every row in the table was past expires_at when this file measured it. Running it
    --    here is the retention policy honoured on the existing rows; it is NOT a keeper, and §9 says
    --    where the keeper goes. A migration can collect a backlog; only a process with a clock can
    --    prevent one.
    ------------------------------------------------------------------
    SELECT count(*) INTO v_found FROM idempotency_keys WHERE expires_at <= now();
    v_q := idempotency_sweep();
    IF v_q <> v_found THEN
        RAISE EXCEPTION 'M failed: the sweep deleted % of % expired claim(s) — 0011''s policy says '
                        'every one, so either the predicate here or the predicate there is wrong',
            v_q, v_found;
    END IF;
    IF (SELECT count(*) FROM idempotency_keys WHERE expires_at <= now()) <> 0 THEN
        RAISE EXCEPTION 'M failed: % expired claim(s) survived a sweep that reported success',
            (SELECT count(*) FROM idempotency_keys WHERE expires_at <= now());
    END IF;
    RAISE NOTICE 'M: % claim(s) past 0011''s retention collected; the table refills the moment a '
                 'door is called with a key and nothing schedules the next sweep — that keeper is '
                 'owed by §9', v_q;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- N. the door records the link, and the view distinguishes an attributed commitment from one it
    --    could not attribute. Both halves matter: the first is §5.5 working, the second is the case
    --    §5.5 cannot eliminate (a caller that names no line), which must show up as a number rather
    --    than as an absence.
    ------------------------------------------------------------------
    v_res := 'not-run';
    BEGIN
        SELECT order_id INTO v_ord FROM create_order('SALES', v_ent, NULL, v_wh, NULL, NULL, NULL,
                                                     '0030 linked', 'MANUAL', NULL);
        SELECT order_line_id INTO v_line
          FROM add_order_line(v_ord, v_item, NULL, 3, 4, NULL, 'STANDARD', v_wh, NULL, NULL, NULL, NULL);
        SELECT reservation_id INTO v_rid
          FROM reserve_inventory_for_order(v_item, v_wh, 3, 'SALES', v_ord, '0030-probe', NULL,
                                          NULL, v_line);
        SELECT order_line_id INTO v_line2 FROM inventory_reservations WHERE reservation_id = v_rid;
        IF v_line2 IS DISTINCT FROM v_line THEN
            v_res := 'the door was handed the line and did not keep it'; RAISE EXCEPTION 'stop';
        END IF;
        IF (SELECT quantity_committed FROM vw_order_commitments
             WHERE order_line_id = v_line) <> 3
           OR (SELECT quantity_committed_unlinked FROM vw_order_commitments
                WHERE order_line_id = v_line) <> 0 THEN
            v_res := format('an attributed commitment reads as committed=%s unlinked=%s',
                (SELECT quantity_committed FROM vw_order_commitments WHERE order_line_id = v_line),
                (SELECT quantity_committed_unlinked FROM vw_order_commitments
                  WHERE order_line_id = v_line));
            RAISE EXCEPTION 'stop';
        END IF;

        -- The same fact, unattributed: still a number, on a document of its own so the two cases
        -- cannot sum into each other.
        SELECT order_id INTO v_ord2 FROM create_order('SALES', v_ent, NULL, v_wh, NULL, NULL, NULL,
                                                      '0030 unlinked', 'MANUAL', NULL);
        SELECT order_line_id INTO v_line2
          FROM add_order_line(v_ord2, v_item, NULL, 3, 4, NULL, 'STANDARD', v_wh, NULL, NULL,
                              NULL, NULL);
        SELECT reservation_id INTO v_rid
          FROM reserve_inventory_for_order(v_item, v_wh, 3, 'SALES', v_ord2, '0030-probe', NULL,
                                          NULL, NULL);
        IF (SELECT quantity_committed FROM vw_order_commitments
             WHERE order_line_id = v_line2) <> 0
           OR (SELECT quantity_committed_unlinked FROM vw_order_commitments
                WHERE order_line_id = v_line2) <> 3 THEN
            v_res := format('an unattributed commitment reads as committed=%s unlinked=%s — the '
                            'second number is the one that keeps a held commitment from reading as '
                            'no commitment',
                (SELECT quantity_committed FROM vw_order_commitments WHERE order_line_id = v_line2),
                (SELECT quantity_committed_unlinked FROM vw_order_commitments
                  WHERE order_line_id = v_line2));
            RAISE EXCEPTION 'stop';
        END IF;
        v_res := 'pass';
        RAISE EXCEPTION 'discard' USING ERRCODE = 'P0002';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT IN ('discard','stop') AND v_res = 'not-run' THEN
            v_res := 'raised ' || SQLSTATE || ': ' || left(SQLERRM, 140);
        END IF;
    END;
    IF v_res <> 'pass' THEN RAISE EXCEPTION 'N failed: %', v_res; END IF;
    -- Nine parameters, one head, and the eight-argument shape the agent still sends.
    IF (SELECT count(*) FROM pg_proc p, unnest(p.proargnames) AS a
         WHERE p.proname = 'reserve_inventory_for_order' AND a = 'p_order_line_id') <> 1 THEN
        RAISE EXCEPTION 'N failed: the reservation door has no p_order_line_id parameter';
    END IF;
    -- And the older shape still works: eight positional arguments, which is what the inventory agent
    -- sends today. Its own document, created OUTSIDE the discard, because the orders the two blocks
    -- above made were rolled back with them, and 3b's enforcement is right to refuse a commitment
    -- against a document that does not exist — the 23503 that this probe first produced was the
    -- trigger catching the probe, not the door losing a shape.
    v_err := NULL;
    BEGIN
        SELECT order_id INTO v_ord2
          FROM create_order('SALES', v_ent, NULL, v_wh, NULL, NULL, NULL,
                            '0030 eight-argument shape', 'MANUAL', NULL);
        SELECT reservation_id INTO v_rid
          FROM reserve_inventory_for_order(v_item, v_wh, 1, 'SALES', v_ord2, '0030-probe', NULL, NULL);
        IF v_rid IS NULL THEN
            v_err := 'answered no reservation_id'; RAISE EXCEPTION 'stop';
        END IF;
        IF v_ord2 IS NULL THEN
            v_err := 'the order it reserved against was never made'; RAISE EXCEPTION 'stop';
        END IF;
        RAISE EXCEPTION 'discard' USING ERRCODE = 'P0002';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT IN ('discard','stop') THEN v_err := SQLSTATE || ': ' || left(SQLERRM, 90); END IF;
    END;
    IF v_err IS NOT NULL THEN
        RAISE EXCEPTION 'N failed: an eight-argument call — the shape agents/inventory''s tool sends '
                        'today — now answers %; a defaulted parameter has to be APPENDED, not '
                        'inserted', v_err;
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- Cleanup. The subtransaction pattern above means almost nothing here needs deleting; what does
    -- is probe J's second tenant and probe C's leftovers if a discard ever stopped early. Scoped by
    -- tenant and by marker, deepest child first — the ordering 0028 argues for and 0029 broke.
    ------------------------------------------------------------------
    -- Only probe J leaves rows outside a discard, so only probe J's rows are deleted. The backfill's
    -- orders and lines are PERMANENT output — they are the four commitments made resolvable — and a
    -- cleanup that cleared them would undo §3 while the assertions above still reported it done. The
    -- first draft here matched origin = 'MANUAL', which on a replay after the agents have used the
    -- surface would delete every real document: 0028's note about unqualified deletes, in a WHERE
    -- clause rather than a DELETE, which is harder to see and just as destructive.
    -- Reverse the fixture receipt THROUGH THE DOOR, then remove its ledger row. 0014's function is
    -- the only writer of the balance, so an UPDATE on inventory_on_hand to tidy up would be the
    -- second implementation of the same arithmetic — which is what 4.2 and 4.6 are about.
    -- The NET of everything this file's own receipts and issues left on the shelf, so a replay that
    -- stopped partway cannot ask a warehouse for stock it does not have.
    -- Guarded, because the receipt above only happens when the shelf was under 40 units: on a
    -- database that already had stock there is nothing to reverse, and 0014's door refuses a
    -- zero-quantity movement with the sentence "direction belongs to the movement type, not the
    -- sign" — which the backfill-database run earned by asking to issue 0.
    SELECT coalesce(sum(CASE WHEN m.movement_type = 'RECEIPT' THEN m.quantity
                             WHEN m.movement_type = 'ISSUE'  THEN -m.quantity
                             ELSE 0 END), 0)
      INTO v_q
      FROM inventory_movements m
     WHERE m.performed_by = 'migration:0030' AND m.movement_type IN ('RECEIPT','ISSUE');
    IF v_q > 0 THEN
        PERFORM execute_inventory_movement('ISSUE', v_item, v_wh, NULL, v_q, 2,
                                          'migration:0030', 'ADJUSTMENT', NULL,
                                          'CLEANUP_FIXTURE_STOCK', 'EACH');
    END IF;
    DELETE FROM inventory_movements WHERE performed_by = 'migration:0030';
    DELETE FROM order_items WHERE order_id IN (SELECT order_id FROM orders WHERE notes LIKE '0030 %');
    DELETE FROM orders WHERE notes LIKE '0030 %';
    DELETE FROM document_counters WHERE tenant_id = v_t2;
    DELETE FROM addresses WHERE entity_id IN (SELECT id FROM entities WHERE name LIKE '0030 %');
    DELETE FROM entity_relationships WHERE entity_id IN (SELECT id FROM entities WHERE name LIKE '0030 %');
    DELETE FROM contacts WHERE email IN ('x0030@afpc.example.invalid',
                                         'fixture0030@afpc.example.invalid');
    DELETE FROM suppliers WHERE entity_id IN (SELECT id FROM entities WHERE name LIKE '0030 %');
    -- The fixture's own balance rows, or the item cannot be dropped: inventory_on_hand holds it with
    -- a RESTRICT edge, and the shelf this file made is this file's residue. Scoped to the fixture item,
    -- which is NULL on any database that already had a catalog — so on the live server this deletes
    -- nothing, and on a from-zero one it deletes the row §8's receipt created.
    DELETE FROM inventory_on_hand WHERE item_id = v_item_fixture;
    DELETE FROM inventory_items WHERE item_id = v_item_fixture;
    DELETE FROM warehouses WHERE warehouse_id = v_wh_fixture;
    DELETE FROM entities WHERE name LIKE '0030 %' OR tenant_id = v_t2;
    DELETE FROM tenants WHERE slug = 'afpc-0030-t2';

    -- Asserted from both ends: nothing of the probes remains, and everything the backfill made does.
    IF (SELECT count(*) FROM orders WHERE notes LIKE '0030 %') <> 0 THEN
        RAISE EXCEPTION 'cleanup failed: % probe order(s) remain',
            (SELECT count(*) FROM orders WHERE notes LIKE '0030 %');
    END IF;
    IF EXISTS (SELECT 1 FROM inventory_reservations)
       AND ((SELECT count(*) FROM orders WHERE origin = 'RESERVATION_BACKFILL') < 1
            OR (SELECT count(*) FROM inventory_reservations
                 WHERE order_line_id IS NULL AND order_type IN ('SALES','PURCHASE')) <> 0) THEN
        RAISE EXCEPTION 'cleanup failed: there are commitments and either no backfilled document or a '
                        'commitment with no line — this file''s permanent output was treated as '
                        'fixture, or §3 did not finish';
    END IF;
    IF (SELECT count(*) FROM inventory_reservations res
         WHERE res.order_type IN ('SALES','PURCHASE','WORK')
           AND NOT EXISTS (SELECT 1 FROM orders o WHERE o.order_id = res.order_id)) <> 0 THEN
        RAISE EXCEPTION 'cleanup failed: a document-type commitment lost its document on the way out, '
                        'which means this file deleted an order the reservations still point at';
    END IF;
    IF (SELECT count(*) FROM vw_order_commitments WHERE ledger_agreement = 'DISAGREES') <> 0 THEN
        RAISE EXCEPTION 'cleanup failed: % line(s) disagree with their ledger after 0030 finished — '
                        'H proved the detector works, so this is a real row and not a false alarm',
            (SELECT count(*) FROM vw_order_commitments WHERE ledger_agreement = 'DISAGREES');
    END IF;

    IF v_n <> 14 THEN
        RAISE EXCEPTION 'expected 14 behavioural verifications, completed %', v_n;
    END IF;
    RAISE NOTICE '0030: % checks passed - the four commitments that named nothing now name documents '
                 'and lines, a commitment cannot be made against a document that does not exist, the '
                 'thirteen units held since 0015 can be released by a door, the door that makes a new '
                 'commitment can name the line it holds stock for, a shipped line''s counter '
                 'reconciles against the ledger that made it, and the claim backlog 0011''s policy '
                 'promised to collect is collected', v_n;
END
$$;

-- ---------------------------------------------------------------------------
-- 9. What this file leaves open, and where each half goes
-- ---------------------------------------------------------------------------
-- * THE SWEEPER, WHICH IS NOT HERE. idempotency_sweep had no caller when this file measured 28 rows
--   all past expires_at, and probe M collects that backlog once. A migration cannot keep it collected:
--   only a process with a clock can, and this database has no scheduler installed (measured —
--   pg_cron is not in pg_available_extensions, so a `schedule()` call is not an option here). The
--   keeper belongs beside the one that already works: agents/inventory/backend_go's runInventoryCheck
--   timer, which is a Go ticker whose every tick files an agent_interactions row. The same shape,
--   calling the same function, is the cheapest true implementation of ADR-005's retention clause —
--   and with a third agent writing claims through the same doors, an uncollected table stops being a
--   papercut and becomes the largest table in the schema by row count.
-- * `inventory_movements.reference_id` is still an unbacked uuid for the 36 rows the demo seed filed
--   with afpc_uuid_v7() out of thin air. Enforcing it means rewriting db/seeds/02's two movement
--   loops to name real documents, which is a change to what the development data MEANS (every
--   movement would belong to an order that also has to exist) and wants its own decision and probe,
--   not a footnote. reference_line_id is enforced now because it has exactly one kind of target.
-- * Production costing. book_work_order_production issues components at the bin's average_cost and
--   receives the product at NULL, so vw_inventory_valuation's money side does not improve from a
--   run. Standard costing across a bill of materials is a decision with a policy in it, and 0018
--   established that a currency or cost the schema guesses is worse than one it leaves blank.
-- * Partial shipment quantities. The doors ship everything a line still owes; a warehouse that sends
--   4 of 7 needs a per-line `ship_this_quantity` argument and a line status that says PARTIALLY_SHIPPED
--   is a fact rather than a derived state. It is deliberately not here: 0028 decided a line's state
--   is its quantities, and adding an argument that lets a partial ship happen without a movement
--   naming the shortfall would break the reconciliation in §1 in the direction of a lie.
-- * The backfilled documents cannot be shipped and then closed by these doors if a probe's order_id
--   resolves to a warehouse the item is not in. §3 uses the reservation's own warehouse, which is the
--   only one the fact names, so the case is not expected — but a RESERVATION_BACKFILL order is a
--   document with no raiser, and the first agent that reads one should be told so by origin, which
--   vw_orders publishes.
-- * `cancel_inventory_reservation` does not close a document. Cancelling the last commitment on an
--   order leaves the order CONFIRMED, because whether the ORDER is cancelled is a decision about the
--   customer agreement and not a consequence of a bin release; transition_order is the door for it,
--   and it will refuse CANCELLED only for a stock-moving status, which CANCELLED is not.

