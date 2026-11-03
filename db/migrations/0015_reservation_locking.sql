-- 0015: one pick policy, locked before it reads, for both doors that touch stock
--       (DATABASE_REVIEW.md 4.3, 4.2's multi-bin half, 0007's named-but-unhandled types)
--
-- Four things the review could not see from outside the body, each measured before being
-- acted on:
--
--   * 4.3's crash has a different cause than diagnosed. Not the third element ("text where
--     the ordering doesn't align"): SQLERRM is text and the OUT column is text, and that
--     pairing works. The failing element is the SECOND - a bare string literal in a
--     RETURN QUERY list is `unknown`-typed, and plpgsql will not coerce unknown into a
--     `character varying` OUT column. Measured three ways on a clone: the uncast literal
--     42804s, the same literal with ::varchar succeeds, and SQLERRM alone in the text
--     position is not the problem at all. So the fix is a cast in one position - and every
--     RETURN QUERY in the body needed it, the handler being merely the one the review's
--     repro happened to reach.
--   * "ignoring location_id, so with multiple bins it updates an arbitrary single row"
--     understates it in BOTH directions. The write is not arbitrary-single: it is
--     every-row-each-by-the-full-quantity (4_6 measured 2 of 2 bins decremented by 5, 15
--     units left on the books for a movement of 5). The read before it is arbitrary in the
--     narrow sense: `SELECT quantity_available INTO v_available ... WHERE item AND
--     warehouse` over two bin rows raises nothing - plpgsql keeps whichever row the scan
--     returns first and discards the rest (measured: two rows, v=10, no error). So a
--     warehouse whose empty bin comes first off the scan reports "Only 0 available" while
--     ten units sit in the other bin. The review found the write and missed that the guard
--     reads one bin and calls it the warehouse.
--   * the reservation's ledger row cannot be made correct without a vocabulary decision
--     made first. 4.3 says the movement INSERT "re-triggers 4.1" - true, and behind that
--     wall sits a second one the review did not reach: the body passes p_order_type into
--     movements.reference_type, and the two columns' published vocabularies overlap in
--     exactly one member (TRANSFER). Measured against the live register: SALES, PURCHASE,
--     WORK and STOCK are all legal order types and all illegal reference types, so the
--     reservation path would have died on a CHECK even with a unit supplied. 0007 named
--     these "the same axis named twice"; this file is where the two copies meet, and the
--     meeting is an explicit mapping that a probe forces to stay total over the published
--     list - not a widened CHECK, which would pretend the axis is one word long.
--   * 4.3's own prescription - "drop the recursive movement insert" - is declined, and the
--     reason is 0014. That migration shipped a refusal that says "RESERVATION belongs to
--     reserve_inventory_for_order, which 0015 rebuilds", and 0007's ledger records the
--     movement_type vocabulary as naming RESERVATION precisely because a path writes it.
--     Delete the insert here and both sentences become false: the generic door points
--     callers at a function that no longer records anything in the ledger, and
--     'RESERVATION' rejoins the dead-members list 0007 exists to keep empty. The row stays
--     and gets what it was missing (unit, warehouse columns, mapped reference type). What
--     the row genuinely breaks is one report - vw_item_movement_summary counts a positive
--     quantity as inbound, so a commitment showed up as stock that arrived; that is fixed
--     in §4 rather than by deleting the fact it reports.

SET client_min_messages TO notice;

-- ---------------------------------------------------------------------------
-- 1. The pick, in one place
-- ---------------------------------------------------------------------------
-- Both doors that take stock out of a warehouse (the reservation path here, the ISSUE /
-- ADJUSTMENT / TRANSFER-source path of execute_inventory_movement in §3) need the same
-- three decisions: which bin rows are candidates, in what order they are drained, and what
-- happens when the order spans more than one. Written twice, the two copies drift and one
-- of them keeps the 4.3 bug after the other is fixed - B25's one-implementation-per-rule
-- census is about trigger bodies, and the argument transfers exactly.
--
-- Locking shape, and the two PostgreSQL rules that forced it:
--   * the rows are locked in the SAME order they are drained in. Two concurrent pickers
--     that visited bins in different orders would deadlock on each other's partial writes;
--     deterministic order is what makes the lock table behave.
--   * the lock and the total cannot be one statement: FOR UPDATE is refused with aggregates
--     (42809, and the 0014-era finding that the total must be a SUM over several bins rather
--     than one row's value). So the loop locks-and-plans, and the caller reads the plan.
--   * the plan writes nothing. A refusal therefore leaves no trace, which is what 4.6's
--     phantom demanded of the reservation path too - decide, then touch.
CREATE OR REPLACE FUNCTION afpc_pick_bins(
    p_item uuid,
    p_warehouse uuid,
    p_location uuid,
    p_quantity numeric
) RETURNS TABLE(on_hand_id uuid, bin_location uuid, units_planned numeric)
LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    v_r        record;
    v_left     numeric := p_quantity;
BEGIN
    -- FEFO then bin then row id: expiry first is the one picking rule the data can state
    -- by itself (no policy table to consult), the rest exists so that the same request
    -- against the same stock always lands on the same bins. A deployment that picks by
    -- another rule changes this function and nothing else.
    FOR v_r IN
        SELECT h.on_hand_id, h.location_id, h.quantity_available
          FROM inventory_on_hand h
         WHERE h.item_id = p_item
           AND h.warehouse_id = p_warehouse
           AND (p_location IS NULL
                OR h.location_id IS NOT DISTINCT FROM p_location)
           AND h.quantity_available > 0
         ORDER BY h.expiry_date NULLS LAST, h.location_id NULLS FIRST, h.on_hand_id
           FOR UPDATE
    LOOP
        on_hand_id   := v_r.on_hand_id;
        bin_location := v_r.location_id;
        IF v_left > 0 THEN
            units_planned := least(v_r.quantity_available, v_left);
            v_left := v_left - units_planned;
        ELSE
            -- Past the requested quantity the candidate rows are still locked, because a
            -- picker that plans 5 of the 10 units in the last bin must not let another
            -- transaction change that bin before the plan is applied.
            units_planned := 0;
        END IF;
        RETURN NEXT;
    END LOOP;
END
$$;

COMMENT ON FUNCTION afpc_pick_bins(uuid, uuid, uuid, numeric) IS
    'The pick policy both inventory doors share: which on-hand rows a request may draw from '
    'and how much of it each supplies. Locks each candidate FOR UPDATE in drain order (FEFO, '
    'then bin, then row id) and returns the PLAN, writing nothing - so a caller that decides '
    'to refuse has written nothing either. NULL p_location means the whole warehouse; a named '
    'bin means only that bin, and a named bin that cannot cover the request is a refusal '
    'rather than a licence to draw elsewhere: the caller asked about that bin. Shortfall is '
    'visible as sum(units_planned) < requested; "no candidate rows at all" is visible as zero '
    'rows, which the two callers answer with different errors (23503 for a movement against '
    'a warehouse that never held the item, a documented status row for a reservation). Built '
    'by 0015 to stop 4.3''s bin-blindness from being fixed twice and drifting apart.';

-- ---------------------------------------------------------------------------
-- 2. The reservation door, rewritten
-- ---------------------------------------------------------------------------
-- Signature 6 -> 8. Both additions are DEFAULTed so every existing call still resolves, and
-- the old head is DROPPED by full signature first, because CREATE OR REPLACE with a changed
-- parameter list is a SECOND overload, not a replacement - 4.4's own 42725, which 0014's
-- rehearsal met and recorded. The count of callable heads is asserted in §7 again here for
-- the same reason.
DROP FUNCTION IF EXISTS reserve_inventory_for_order(
    uuid, uuid, numeric, varchar, uuid, varchar);

CREATE OR REPLACE FUNCTION reserve_inventory_for_order(
    p_item_id        uuid,
    p_warehouse_id   uuid,
    p_quantity       numeric,
    p_order_type     varchar,
    p_order_id       uuid,
    p_reserved_by    varchar,
    p_location_id    uuid   DEFAULT NULL,
    p_idempotency_key uuid  DEFAULT NULL
) RETURNS TABLE(reservation_id uuid, status character varying, message text)
LANGUAGE plpgsql AS $$
DECLARE
    v_res      uuid;
    v_ids      uuid[]    := '{}';
    v_takes    numeric[] := '{}';
    v_planned  numeric  := 0;
    v_bins     int       := 0;
    v_avail    numeric;
    v_r        record;
    v_claim    record;
    v_state    text      := '';
    v_msg      text;
    v_touch    int;
    i          int;
BEGIN
    ------------------------------------------------------------------
    -- ADR-005 pattern 2 at this head, per Obligations-0011. The register called this
    -- function "pattern 3 - a maintained version column can guard the write" because it
    -- writes a counted table, which is the ladder reading a possibility and calling it a
    -- fact: nothing here ever compared a version, so a retry double-reserved. A claim is
    -- the mechanism that makes the verdict true.
    ------------------------------------------------------------------
    IF p_idempotency_key IS NOT NULL THEN
        SELECT * INTO v_claim FROM idempotency_claim(
            p_idempotency_key,
            'reserve_inventory_for_order',
            jsonb_build_object(
                'item', p_item_id, 'warehouse', p_warehouse_id,
                'quantity', p_quantity, 'order_type', p_order_type,
                'order_id', p_order_id, 'location', p_location_id));
        v_state := v_claim.claim_state;
        IF v_state = 'replay' THEN
            reservation_id := (v_claim.cached_response ->> 'reservation_id')::uuid;
            status := ((v_claim.cached_response ->> 'status'))::varchar;
            message := v_claim.cached_response ->> 'message';
            RETURN NEXT;
            RETURN;
        ELSIF v_state = 'in_progress' THEN
            RAISE EXCEPTION 'reserve_inventory_for_order: an attempt with key % is already in flight',
                p_idempotency_key
                USING ERRCODE = '40001',
                      HINT = 'the lease expires and a take-over rotates the token (0011)';
        ELSIF v_state = 'conflict' THEN
            RAISE EXCEPTION 'reserve_inventory_for_order: key % was settled for a DIFFERENT request (fingerprint mismatch)',
                p_idempotency_key
                USING ERRCODE = 'P0001',
                      HINT = 'a caller''s idempotency key names one operation; never reuse one across requests';
        END IF;
    END IF;

    ------------------------------------------------------------------
    -- An unknown item or warehouse is a wrong ARGUMENT, not a shortage. Without this guard
    -- the pick finds no candidate rows and the door answers "Only 0 available" about an item
    -- that was never heard of - 4.3's own conflation, a business status standing in for an
    -- error. The other door refuses earlier for the same reason: its ledger INSERT fires the
    -- item FK (23503) before anything else happens, so the code differs by where the door
    -- notices, not by whether it does. 22023 is the shape this schema already uses for a
    -- wrong argument (0014's missing unit, a self-transfer, a non-positive quantity). RLS
    -- applies to the EXISTS, so a foreign tenant's item answers exactly like a missing one,
    -- which under 0009's wall is the intent.
    ------------------------------------------------------------------
    IF NOT EXISTS (SELECT 1 FROM inventory_items WHERE item_id = p_item_id) THEN
        RAISE EXCEPTION 'reserve_inventory_for_order: item % does not exist - "no stock" would '
                        'be the wrong answer to a wrong argument',
            p_item_id USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM warehouses WHERE warehouse_id = p_warehouse_id) THEN
        RAISE EXCEPTION 'reserve_inventory_for_order: warehouse % does not exist',
            p_warehouse_id USING ERRCODE = '22023';
    END IF;

    -- An invalid order type is wrong whatever the stock says, so it is decided before the
    -- pick. It was first noticed because a probe passed a bad type against a warehouse with
    -- nothing in it and got "Only 0 available" - 0014's ordering lesson (NOT NULL is checked
    -- before CHECK, so one defect hides the next) reproduced in a function's control flow
    -- instead of a statement's. The list comes from the register, which reads the constraint,
    -- so this guard is a projection of the schema rather than a second copy of the vocabulary
    -- - 0007's objection to restating a list applies with equal force to a whitelist in an
    -- IF. The CHECK stays the floor for every other write path (probe J proves both halves).
    IF p_order_type IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM unnest((SELECT allowed_values FROM vw_domain_vocabulary
                                   WHERE table_name = 'inventory_reservations'
                                     AND column_name = 'order_type')) v
            WHERE v.v = p_order_type) THEN
        RAISE EXCEPTION 'reserve_inventory_for_order: order type % is not a member of '
                        'inventory_reservations.order_type', p_order_type
            USING ERRCODE = '23514', HINT = 'vw_domain_vocabulary publishes the list this '
                  'guard reads; the constraint behind it is the same object';
    END IF;

    ------------------------------------------------------------------
    -- Plan (locking), then decide, then touch. The arrays are the plan; the writes below
    -- are the only place the warehouse's numbers move.
    ------------------------------------------------------------------
    FOR v_r IN SELECT * FROM afpc_pick_bins(p_item_id, p_warehouse_id,
                                            p_location_id, p_quantity)
    LOOP
        v_bins := v_bins + 1;
        v_ids := v_ids || v_r.on_hand_id;
        v_takes := v_takes || v_r.units_planned;
        v_planned := v_planned + v_r.units_planned;
    END LOOP;

    IF v_planned < p_quantity THEN
        -- The SUM of a plan, not one row's value read and called the warehouse's
        -- availability (4.3's guard, which for a two-bin warehouse was whichever bin the
        -- scan happened to return first, and which for no bins at all compared NULL < n -
        -- UNKNOWN, not false - and so reserved stock that was never there).
        SELECT coalesce(sum(h.quantity_available), 0) INTO v_avail
          FROM inventory_on_hand h
         WHERE h.item_id = p_item_id AND h.warehouse_id = p_warehouse_id
           AND (p_location_id IS NULL
                OR h.location_id IS NOT DISTINCT FROM p_location_id);

        v_msg := 'Only ' || v_avail || ' available'
                 || CASE WHEN p_location_id IS NOT NULL THEN ' in the named bin'
                         WHEN v_bins = 0 THEN ' for this item at this warehouse'
                         ELSE ' across ' || v_bins || ' bin(s)' END
                 || ', requested ' || p_quantity;

        IF v_state = 'claimed' THEN
            -- A refusal is not an answer worth caching: the same call after a restock must
            -- re-evaluate rather than replay the word "no" from a stale claim. 0011 makes a
            -- failed claim re-claimable, so this is the release, not a tombstone.
            PERFORM idempotency_complete(v_claim.claim_id, v_claim.current_token,
                                         NULL, false, v_msg);
        END IF;
        RETURN QUERY SELECT NULL::uuid, 'INSUFFICIENT_STOCK'::varchar, v_msg;
        RETURN;
    END IF;

    INSERT INTO inventory_reservations
            (item_id, warehouse_id, location_id, order_type, order_id,
             reserved_quantity, reserved_by, priority)
    VALUES  (p_item_id, p_warehouse_id, p_location_id, p_order_type, p_order_id,
             p_quantity, p_reserved_by, 1)
    -- Qualified on purpose: the OUT parameter is also called reservation_id, and an
    -- unqualified RETURNING target binds to the variable (42702, measured) - 0011's own
    -- header records the same collision for status/response. The column list is the
    -- function's, the target is the table's.
    RETURNING inventory_reservations.reservation_id INTO v_res;

    FOR i IN 1..v_bins LOOP
        IF v_takes[i] > 0 THEN
            UPDATE inventory_on_hand
               SET quantity_reserved = quantity_reserved + v_takes[i],
                   last_movement_at  = now()
             WHERE on_hand_id = v_ids[i];
            GET DIAGNOSTICS v_touch = ROW_COUNT;
            IF v_touch <> 1 THEN
                -- Locked rows do not vanish; if one did, the plan is a fiction and the
                -- reservation must not stand on it (4.6's silent-zero-update contract,
                -- asserted here rather than assumed).
                RAISE EXCEPTION 'reserve_inventory_for_order: bin % matched % rows when the plan said 1 - the allocation is abandoned, not half-applied',
                    v_ids[i], v_touch USING ERRCODE = '23503';
            END IF;
        END IF;
    END LOOP;

    ------------------------------------------------------------------
    -- The commitment row in the ledger. Three walls this used to walk into, each closed
    -- with the piece it was missing rather than by deleting the row (header, §4 for the
    -- report the row was distorting): unit_of_measure (4.1), the warehouse columns
    -- inventory_movements_warehouse_shape demands for RESERVATION (0014), and a
    -- reference_type that is a member of THAT column's vocabulary rather than the order
    -- type spelled a second way (0007's "same axis named twice").
    ------------------------------------------------------------------
    INSERT INTO inventory_movements
            (movement_type, item_id, to_warehouse_id, to_location_id, quantity,
             unit_of_measure, reason_code, performed_by, reference_type, reference_id)
    VALUES  ('RESERVATION', p_item_id, p_warehouse_id, p_location_id, p_quantity,
             coalesce((SELECT i2.base_unit_of_measure FROM inventory_items i2
                        WHERE i2.item_id = p_item_id),
                      (SELECT min(u.uom_code) FROM units_of_measure u
                        WHERE u.uom_code = 'EACH')),
             'ORDER_COMMITMENT', p_reserved_by,
             CASE p_order_type
                 WHEN 'PURCHASE' THEN 'PO'
                 WHEN 'SALES'    THEN 'ORDER'
                 WHEN 'WORK'     THEN 'ORDER'
                 WHEN 'TRANSFER' THEN 'TRANSFER'
                 WHEN 'STOCK'    THEN NULL   -- an internal hold names no document
             END,
             p_order_id);

    v_msg := 'Reserved ' || p_quantity || ' unit(s) for '
             || p_order_type || ' order ' || p_order_id
             || CASE WHEN v_bins > 1 THEN ' across ' || v_bins || ' bin(s)'
                     WHEN p_location_id IS NOT NULL THEN ' from the named bin'
                     ELSE '' END;

    IF v_state = 'claimed' THEN
        PERFORM idempotency_complete(v_claim.claim_id, v_claim.current_token,
                jsonb_build_object('reservation_id', v_res, 'status', 'SUCCESS',
                                   'message', v_msg));
    END IF;

    RETURN QUERY SELECT v_res, 'SUCCESS'::varchar, v_msg;
    RETURN;

EXCEPTION
    WHEN OTHERS THEN
        -- No ERROR row. 4.3 asked for one and the review's remedy - a fixed handler
        -- returning status='ERROR' - is the same shape as the catch-all 0014 deleted from
        -- execute_inventory_movement for reporting a constraint by a message and dropping
        -- its SQLSTATE: the FK on a nonexistent item, the CHECK on an illegal order type,
        -- the 40001 of a live lease all become the string 'ERROR'. Business outcomes
        -- (SUCCESS, INSUFFICIENT_STOCK) are rows because they are answers; an error is not
        -- an answer, it is the absence of one, and it propagates with the code it came
        -- with. What the handler does keep is the claim's release, so a retry can run.
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

-- ---------------------------------------------------------------------------
-- 3. The movement door, given the same pick
-- ---------------------------------------------------------------------------
-- Signature 12 -> 14. The two additions mirror the two warehouse columns already in the
-- list, because inventory_movements has had from_location_id and to_location_id since 0001
-- and nothing ever wrote them: the ledger could say which warehouse a movement touched and
-- no further. Old head dropped by full signature, same 42725 lesson as §2.
DROP FUNCTION IF EXISTS execute_inventory_movement(
    varchar, uuid, uuid, uuid, numeric, numeric, varchar, varchar, uuid, varchar,
    varchar, uuid);

CREATE OR REPLACE FUNCTION execute_inventory_movement(
    p_movement_type       varchar,
    p_item_id             uuid,
    p_from_warehouse_id   uuid,
    p_to_warehouse_id     uuid,
    p_quantity            numeric,
    p_unit_cost           numeric,
    p_performed_by        varchar,
    p_reference_type      varchar,
    p_reference_id        uuid,
    p_reason_code         varchar,
    p_unit_of_measure     varchar DEFAULT NULL,
    p_idempotency_key     uuid    DEFAULT NULL,
    p_from_location_id    uuid    DEFAULT NULL,
    p_to_location_id      uuid    DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
    v_movement_id uuid;
    v_batch_id    uuid := gen_random_uuid();
    v_uom         varchar(20);
    v_ids         uuid[]    := '{}';
    v_locs        uuid[]    := '{}';
    v_takes       numeric[] := '{}';
    v_planned     numeric   := 0;
    v_bins        int       := 0;
    v_rows_here   int       := 0;
    v_avail_here  numeric   := 0;
    v_touch       int;
    v_claim       record;
    v_state       text      := '';
    r             record;
    i             int;
BEGIN
    IF p_idempotency_key IS NOT NULL THEN
        SELECT * INTO v_claim FROM idempotency_claim(
            p_idempotency_key,
            'execute_inventory_movement',
            jsonb_build_object(
                'type', p_movement_type, 'item', p_item_id,
                'from', p_from_warehouse_id, 'to', p_to_warehouse_id,
                'from_loc', p_from_location_id, 'to_loc', p_to_location_id,
                'qty', p_quantity, 'cost', p_unit_cost,
                'ref_type', p_reference_type, 'ref', p_reference_id,
                'uom', p_unit_of_measure));
        v_state := v_claim.claim_state;
        IF v_state = 'replay' THEN
            RETURN (v_claim.cached_response ->> 'movement_id')::uuid;
        ELSIF v_state = 'in_progress' THEN
            RAISE EXCEPTION 'execute_inventory_movement: an attempt with key % is already in flight',
                p_idempotency_key
                USING ERRCODE = '40001',
                      HINT = 'the lease expires and a take-over rotates the token (0011)';
        ELSIF v_state = 'conflict' THEN
            RAISE EXCEPTION 'execute_inventory_movement: key % was settled for a DIFFERENT request (fingerprint mismatch)',
                p_idempotency_key
                USING ERRCODE = 'P0001',
                      HINT = 'a caller''s idempotency key names one operation; never reuse one across requests';
        END IF;
    END IF;

    -- 4.1's unit, unchanged from 0014.
    v_uom := coalesce(p_unit_of_measure,
                      (SELECT i2.base_unit_of_measure FROM inventory_items i2
                        WHERE i2.item_id = p_item_id));
    IF v_uom IS NULL THEN
        RAISE EXCEPTION 'execute_inventory_movement: no unit of measure - none given, and item % has no base_unit_of_measure',
            p_item_id
            USING ERRCODE = '22023', HINT = 'units_of_measure holds the codes; the item master is the default';
    END IF;

    IF p_movement_type = 'RESERVATION' THEN
        -- 0014's refusal, kept verbatim and now true in both directions: reserve_... does
        -- write this type's ledger row, with the unit and the mapped reference type that
        -- the generic path could not have got right.
        RAISE EXCEPTION 'execute_inventory_movement does not create reservations - use reserve_inventory_for_order'
            USING ERRCODE = '23514';
    END IF;
    IF p_movement_type = 'TRANSFER'
       AND p_from_warehouse_id IS NOT DISTINCT FROM p_to_warehouse_id THEN
        RAISE EXCEPTION 'TRANSFER needs two DIFFERENT warehouses (source=% target=%)',
            p_from_warehouse_id, p_to_warehouse_id USING ERRCODE = '22023';
    END IF;

    -- Quantity is a magnitude; direction is the type's job. chk_quantity_nonzero refused 0
    -- and said nothing about a negative, which for ISSUE meant `on_hand - (-5)` - an
    -- unannounced receipt through the issue door, and one the 0014 tests never reached
    -- because every quantity they pass is positive. Named here rather than left to whichever
    -- CHECK happens to be evaluated first.
    IF p_quantity <= 0 THEN
        RAISE EXCEPTION 'execute_inventory_movement: % needs a positive quantity, got % - direction belongs to the movement type, not the sign',
            p_movement_type, p_quantity USING ERRCODE = '22023';
    END IF;

    -- Wrong arguments first, before anything data-dependent is decided: 4.3's conflation is
    -- answering a business question about a call that never asked one. The SQLSTATE is the
    -- one this door already used for the same class (0014's missing-unit 22023), because the
    -- two doors must not disagree about what a bad argument costs; the item FK stays the
    -- floor underneath, and probe J demonstrates both halves.
    IF NOT EXISTS (SELECT 1 FROM inventory_items WHERE item_id = p_item_id) THEN
        RAISE EXCEPTION 'execute_inventory_movement: item % does not exist',
            p_item_id USING ERRCODE = '22023';
    END IF;
    IF p_movement_type IN ('RECEIPT','RETURN')
       AND NOT EXISTS (SELECT 1 FROM warehouses WHERE warehouse_id = p_to_warehouse_id) THEN
        RAISE EXCEPTION 'execute_inventory_movement: destination warehouse % does not exist',
            p_to_warehouse_id USING ERRCODE = '22023';
    END IF;

    ------------------------------------------------------------------
    -- Depleting types (ISSUE, ADJUSTMENT, TRANSFER's source): plan the draw across bins
    -- BEFORE writing anything, so the two ways 4.2/4.6 could fail - no rows, and rows that
    -- cannot cover the request - are decided while nothing has been touched. The ledger row
    -- used to be the first write of the transaction and the refusal then leaned on statement
    -- atomicity to erase it; the plan removes the need to lean.
    ------------------------------------------------------------------
    IF p_movement_type IN ('ISSUE', 'ADJUSTMENT', 'TRANSFER') THEN
        FOR r IN SELECT * FROM afpc_pick_bins(
                        p_item_id, p_from_warehouse_id,
                        p_from_location_id, p_quantity)
        LOOP
            v_bins := v_bins + 1;
            v_ids := v_ids || r.on_hand_id;
            v_locs := v_locs || r.bin_location;
            v_takes := v_takes || r.units_planned;
            v_planned := v_planned + r.units_planned;
        END LOOP;

        IF v_planned < p_quantity THEN
            SELECT count(*), coalesce(sum(h.quantity_available), 0)
              INTO v_rows_here, v_avail_here
              FROM inventory_on_hand h
             WHERE h.item_id = p_item_id
               AND h.warehouse_id = p_from_warehouse_id
               AND (p_from_location_id IS NULL
                    OR h.location_id IS NOT DISTINCT FROM p_from_location_id);

            IF v_rows_here = 0 THEN
                -- 0014's contract for exactly this case, same SQLSTATE: the warehouse never
                -- held this item, so the movement is dreamed.
                RAISE EXCEPTION 'execute_inventory_movement: no on-hand row for item % at warehouse % - the movement is refused, not dreamed',
                    p_item_id, p_from_warehouse_id
                    USING ERRCODE = '23503';
            END IF;
            RAISE EXCEPTION 'execute_inventory_movement: only % available across % bin(s) at '
                            'warehouse %, requested % - the draw is refused',
                v_avail_here, v_bins, p_from_warehouse_id, p_quantity
                USING ERRCODE = '23514',
                      HINT = 'the same fact chk_quantities_non_negative states per row; deciding it here means the ledger row is never written';
        END IF;
    END IF;

    INSERT INTO inventory_movements (
        movement_type, item_id, from_warehouse_id, to_warehouse_id,
        from_location_id, to_location_id,
        quantity, unit_cost, total_cost, unit_of_measure, performed_by,
        reference_type, reference_id, reason_code, batch_id
    ) VALUES (
        p_movement_type, p_item_id, p_from_warehouse_id, p_to_warehouse_id,
        CASE WHEN p_movement_type IN ('ISSUE','ADJUSTMENT','TRANSFER')
                  AND v_bins = 1 AND v_locs[1] IS NOT NULL
             THEN v_locs[1] END,                  -- the bin, when the draw was one bin
        p_to_location_id,
        p_quantity, p_unit_cost, p_quantity * p_unit_cost, v_uom, p_performed_by,
        p_reference_type, p_reference_id, p_reason_code, v_batch_id
    ) RETURNING movement_id INTO v_movement_id;

    IF p_movement_type IN ('RECEIPT', 'RETURN') THEN
        -- location_id is now part of the row the upsert aims at: before this, every receipt
        -- in the schema landed in the warehouse's no-bin row no matter where the stock
        -- physically sat, because the INSERT column list never named the bin.
        INSERT INTO inventory_on_hand
            (item_id, warehouse_id, location_id, quantity_on_hand, average_cost, last_movement_at)
        VALUES (p_item_id, p_to_warehouse_id, p_to_location_id, p_quantity, p_unit_cost, NOW())
        ON CONFLICT (item_id, warehouse_id,
                     COALESCE(location_id, '00000000-0000-0000-0000-000000000000'::uuid),
                     COALESCE(lot_number, ''), tenant_id)
        DO UPDATE SET
            quantity_on_hand = inventory_on_hand.quantity_on_hand + p_quantity,
            average_cost =
                CASE WHEN inventory_on_hand.quantity_on_hand + p_quantity > 0
                     THEN ((inventory_on_hand.average_cost * inventory_on_hand.quantity_on_hand)
                           + (p_unit_cost * p_quantity))
                          / (inventory_on_hand.quantity_on_hand + p_quantity)
                     ELSE inventory_on_hand.average_cost
                END,
            last_movement_at = NOW();
    ELSIF p_movement_type = 'TRANSFER' THEN
        -- Source side: the plan, applied. v_touch guards the row that the lock says exists.
        FOR i IN 1..v_bins LOOP
            IF v_takes[i] > 0 THEN
                UPDATE inventory_on_hand
                   SET quantity_on_hand = quantity_on_hand - v_takes[i],
                       last_movement_at = NOW()
                 WHERE on_hand_id = v_ids[i];
                GET DIAGNOSTICS v_touch = ROW_COUNT;
                IF v_touch <> 1 THEN
                    RAISE EXCEPTION 'TRANSFER: bin % matched % rows when the plan said 1',
                        v_ids[i], v_touch USING ERRCODE = '23503';
                END IF;
            END IF;
        END LOOP;

        INSERT INTO inventory_on_hand
            (item_id, warehouse_id, location_id, quantity_on_hand, average_cost, last_movement_at)
        VALUES (p_item_id, p_to_warehouse_id, p_to_location_id, p_quantity, p_unit_cost, NOW())
        ON CONFLICT (item_id, warehouse_id,
                     COALESCE(location_id, '00000000-0000-0000-0000-000000000000'::uuid),
                     COALESCE(lot_number, ''), tenant_id)
        DO UPDATE SET
            quantity_on_hand = inventory_on_hand.quantity_on_hand + p_quantity,
            average_cost =
                CASE WHEN inventory_on_hand.quantity_on_hand + p_quantity > 0
                     THEN ((inventory_on_hand.average_cost * inventory_on_hand.quantity_on_hand)
                           + (p_unit_cost * p_quantity))
                          / (inventory_on_hand.quantity_on_hand + p_quantity)
                     ELSE inventory_on_hand.average_cost
                END,
            last_movement_at = NOW();
    ELSIF p_movement_type IN ('ISSUE', 'ADJUSTMENT') THEN
        -- 4.6's worse half closed: the same quantity, taken once, spread over the bins the
        -- plan named - not the full quantity deducted from each bin of the warehouse.
        FOR i IN 1..v_bins LOOP
            IF v_takes[i] > 0 THEN
                UPDATE inventory_on_hand
                   SET quantity_on_hand = quantity_on_hand - v_takes[i],
                       last_movement_at = NOW()
                 WHERE on_hand_id = v_ids[i];
                GET DIAGNOSTICS v_touch = ROW_COUNT;
                IF v_touch <> 1 THEN
                    RAISE EXCEPTION 'ISSUE/ADJUSTMENT: bin % matched % rows when the plan said 1 - the movement is abandoned, not half-applied',
                        v_ids[i], v_touch USING ERRCODE = '23503';
                END IF;
            END IF;
        END LOOP;
    END IF;

    IF v_state = 'claimed' THEN
        PERFORM idempotency_complete(v_claim.claim_id, v_claim.current_token,
                jsonb_build_object('movement_id', v_movement_id));
    END IF;

    RETURN v_movement_id;

EXCEPTION
    WHEN OTHERS THEN
        IF v_state IS NOT DISTINCT FROM 'claimed' THEN
            BEGIN
                PERFORM idempotency_complete(v_claim.claim_id, v_claim.current_token,
                                             NULL, false, SQLERRM);
            EXCEPTION WHEN OTHERS THEN NULL;
            END;
        END IF;
        RAISE EXCEPTION USING ERRCODE = SQLSTATE, MESSAGE = SQLERRM;
END
$$;

-- ---------------------------------------------------------------------------
-- 4. The report the commitment row was inflating
-- ---------------------------------------------------------------------------
-- §1's header records why the reservation's ledger row is kept rather than dropped; this is
-- the price of keeping it, and it is paid rather than hidden. vw_item_movement_summary's
-- in/out split asks only whether quantity is positive, so a RESERVATION row - stock
-- committed, nothing arrived - appeared as inbound movement of that quantity. The fix is
-- directional, not a deletion: a commitment has a direction (it makes stock unavailable) and
-- it is neither inbound nor outbound.
--
-- The new definition is produced by capture-transform-prove (0012/0013's pattern) rather
-- than retyped: ask the catalog for the live text, transform two exact substrings, refuse to
-- run if either appears other than exactly once, and re-apply the reloption 0009 says dies
-- with the replace. Restating the view from memory here would be the 0007 "LIKE that spells
-- one rendering" mistake wearing a bigger coat.
DO $$
DECLARE
    v_def    text;
    v_new    text;
    v_hits   int;
    v_before text;
    v_after  text;
    c        record;
BEGIN
    SELECT string_agg(attname, ',' ORDER BY attnum) INTO v_before
      FROM pg_attribute WHERE attrelid = 'vw_item_movement_summary'::regclass
        AND attnum > 0 AND NOT attisdropped;
    SELECT pg_get_viewdef('public.vw_item_movement_summary'::regclass, true) INTO v_def;
    IF v_def IS NULL THEN
        RAISE EXCEPTION 'vw_item_movement_summary printed no definition - the transform has '
                        'nothing to work on, which is a different problem from the one this '
                        'section solves';
    END IF;

    -- Each arm matched on the two-token shape pretty-print produces (measured), not on a
    -- copy of the whole statement: a forward-fix that demands an exact multi-line literal
    -- is a migration that fails on a formatting change rather than on a meaning change.
    FOR c IN
        SELECT * FROM (VALUES
            ('WHEN quantity > 0::numeric THEN quantity',
             'WHEN (quantity > 0::numeric AND movement_type <> ''RESERVATION''::text) THEN quantity',
             'inbound'),
            ('WHEN quantity < 0::numeric THEN abs(quantity)',
             'WHEN (quantity < 0::numeric AND movement_type <> ''RESERVATION''::text) THEN abs(quantity)',
             'outbound')
        ) AS t(needle, patch, which)
    LOOP
        -- Counted as an exact substring, not through regexp_matches: the needle contains
        -- `abs(quantity)`, whose parentheses are a capturing group to a regex, so the same
        -- text that replace() finds (measured: replace worked, the count returned 0) is
        -- invisible to the guard around it. A literal-substring transform counts literally.
        v_hits := array_length(string_to_array(v_def, c.needle), 1) - 1;
        IF v_hits <> 1 THEN
            RAISE EXCEPTION 'the % arm of vw_item_movement_summary matched % times in the live '
                            'definition - the transform assumes exactly one, and applying it '
                            'to several would change a column this migration has not read',
                            c.which, v_hits;
        END IF;
        v_new := replace(v_def, c.needle, c.patch);
        IF v_new = v_def THEN
            RAISE EXCEPTION 'the % arm did not render as the transform expects - re-derive from '
                            'the live definition, never apply a forward-fix blind', c.which;
        END IF;
        v_def := v_new;
    END LOOP;

    EXECUTE 'CREATE OR REPLACE VIEW public.vw_item_movement_summary AS ' || v_new;
    ALTER VIEW public.vw_item_movement_summary SET (security_invoker = true);

    -- Columns proved unchanged: this is a meaning change, not a shape change, and if it ever
    -- stops being one, 0012's rule says the tool for that is DROP + CREATE, not a replace.
    SELECT string_agg(attname, ',' ORDER BY attnum) INTO v_after
      FROM pg_attribute WHERE attrelid = 'vw_item_movement_summary'::regclass
        AND attnum > 0 AND NOT attisdropped;
    IF v_after IS DISTINCT FROM v_before THEN
        RAISE EXCEPTION 'the view rewrite changed the column list (% -> %) - only the two '
                        'CASE arms were meant to move', v_before, v_after;
    END IF;
    RAISE NOTICE '4.3: vw_item_movement_summary no longer counts a commitment as stock that '
                 'arrived';
END
$$;

COMMENT ON VIEW vw_item_movement_summary IS
    '30-day movement pattern per item/day/type. net_quantity is every type''s signed total; '
    'total_inbound and total_outbound exclude RESERVATION rows on purpose - a reservation '
    'moves nothing, it makes stock unavailable, and counting it as inbound reported units '
    'that never arrived (0015 found this while deciding to keep the commitment row rather '
    'than delete it; §1 of that file carries the argument). Security invoker, so the report '
    'is the caller''s own tenant.';

-- ---------------------------------------------------------------------------
-- 5. Privileges, the way 0009 and 0014 taught them
-- ---------------------------------------------------------------------------
-- Both rewrites created NEW function objects (changed signatures), so both are born
-- EXECUTE-to-PUBLIC and B22 names them the same day. afpc_pick_bins is a mechanism, not a
-- door: no caller outside these two functions has a business reason to plan a pick, and one
-- that planned a draw and then skipped the ledger row would produce exactly the 4.6 phantom
-- the helper exists to prevent - so it is closed to PUBLIC and granted to the role the doors
-- are granted to, not to the read roles.
REVOKE EXECUTE ON FUNCTION afpc_pick_bins(uuid, uuid, uuid, numeric) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION afpc_pick_bins(uuid, uuid, uuid, numeric) TO afpc_app;

REVOKE EXECUTE ON FUNCTION reserve_inventory_for_order(
    uuid, uuid, numeric, varchar, uuid, varchar, uuid, uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION reserve_inventory_for_order(
    uuid, uuid, numeric, varchar, uuid, varchar, uuid, uuid) TO afpc_app;

REVOKE EXECUTE ON FUNCTION execute_inventory_movement(
    varchar, uuid, uuid, uuid, numeric, numeric, varchar, varchar, uuid, varchar,
    varchar, uuid, uuid, uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION execute_inventory_movement(
    varchar, uuid, uuid, uuid, numeric, numeric, varchar, varchar, uuid, varchar,
    varchar, uuid, uuid, uuid) TO afpc_app;

-- ---------------------------------------------------------------------------
-- 6. What the schema now says about itself
-- ---------------------------------------------------------------------------
COMMENT ON FUNCTION reserve_inventory_for_order(
        uuid, uuid, numeric, varchar, uuid, varchar, uuid, uuid) IS
    'Commit stock to an order without moving it. Eight parameters: the original six, plus '
    'p_location_id (reserve from ONE named bin; NULL spans the warehouse and drains bins in '
    'the order afpc_pick_bins defines) and p_idempotency_key (ADR-005 pattern 2 - supply one '
    'and a retry of THIS call is answered from the claim instead of reserving twice; the '
    'register''s earlier "pattern 3" verdict named a possibility, not a mechanism - nothing '
    'here ever compared a version, so a retry double-reserved). Statuses are the two business '
    'outcomes SUCCESS and INSUFFICIENT_STOCK, returned as rows; an error is not a status, '
    'because the handler that reported it as one was 4.3''s crash and a row that discards the '
    'SQLSTATE is 0014''s re-wrap wearing a column. Writes three things in one transaction: '
    'the commitment row (the fact), the per-bin quantity_reserved deltas (the balance), and '
    'the movement_type=RESERVATION ledger row with its unit, its warehouse columns, and a '
    'reference_type mapped from the order type (0007 named the two lists "the same axis '
    'named twice" - they share only TRANSFER, so the mapping is explicit and probe-total). A '
    'refusal writes nothing at all, including no claim answer to replay. Built by 0015.';

COMMENT ON FUNCTION execute_inventory_movement(
        varchar, uuid, uuid, uuid, numeric, numeric, varchar, varchar, uuid, varchar,
        varchar, uuid, uuid, uuid) IS
    'The inventory ledger''s front door for every movement_type except RESERVATION, which it '
    'refuses with a pointer to reserve_inventory_for_order. Fourteen parameters: 0014''s '
    'twelve, plus from/to location - the two ledger columns that have existed since 0001 and '
    'that nothing could fill. Depleting types (ISSUE, ADJUSTMENT, TRANSFER''s source) plan the '
    'draw across bins through afpc_pick_bins BEFORE writing, so "no stock" (23503) and "not '
    'enough stock" (23514) are both decided while nothing is touched, and the same quantity is '
    'taken once rather than deducted from every bin in the warehouse (4.6''s worse half). '
    'Quantity is a magnitude and <= 0 is refused: chk_quantity_nonzero rejected only zero, so '
    'an ISSUE of -5 was an unannounced receipt. One boundary stated rather than buried - the '
    'pick draws on quantity_available, so stock already committed to a reservation cannot be '
    'issued through this door; the fulfilment step that would consume a reservation (reducing '
    'on_hand and reserved together) has no representation in the schema yet, and probe L '
    'demonstrates the boundary instead of leaving it in prose. Built by 0014, rebuilt by 0015.';

-- ---------------------------------------------------------------------------
-- 7. Verify by behaving
-- ---------------------------------------------------------------------------
-- The seat rule the last five migrations obeyed: a check of a control runs in the seat the
-- control binds, so the locking and visibility probes take afpc_app, and the catalog claims
-- stay with the owner. Fixtures are removed at the end; the audit rows about removing them
-- stay, because that is 0013 being honest rather than residue.
DO $$
DECLARE
    v_wh_a    uuid;
    v_wh_b    uuid;
    v_item    uuid;
    v_item2   uuid;
    v_item3   uuid;
    v_order2  uuid;
    v_loc_a   uuid;
    v_loc_b   uuid;
    v_key     uuid := gen_random_uuid();
    v_key2    uuid := gen_random_uuid();
    v_order   uuid := gen_random_uuid();
    v_res     uuid;
    v_mv      uuid;
    v_sum     numeric;
    v_rows    bigint;
    v_state   text;
    v_err     text;
    v_n       int := 0;
    r         record;
    v_r       record;
    v_t2      uuid;
BEGIN
    ------------------------------------------------------------------
    -- Setup: two warehouses, one item in two bins of A, one item with no stock anywhere,
    -- and a location in B so a cross-warehouse pin can be tried.
    ------------------------------------------------------------------
    INSERT INTO warehouses (warehouse_code, name) VALUES ('0015 WH-A', 'probe source')
     RETURNING warehouse_id INTO v_wh_a;
    INSERT INTO warehouses (warehouse_code, name) VALUES ('0015 WH-B', 'probe target')
     RETURNING warehouse_id INTO v_wh_b;
    INSERT INTO inventory_items (sku, name, base_unit_of_measure)
         VALUES ('0015-A', 'probe item', 'EACH') RETURNING item_id INTO v_item;
    INSERT INTO inventory_items (sku, name) VALUES ('0015-B', 'probe item bare')
     RETURNING item_id INTO v_item2;
    INSERT INTO inventory_items (sku, name) VALUES ('0015-C', 'probe item held back')
     RETURNING item_id INTO v_item3;
    INSERT INTO locations (warehouse_id, location_code)
         VALUES (v_wh_a, '0015-A1'), (v_wh_a, '0015-A2'), (v_wh_b, '0015-B1');
    SELECT location_id INTO v_loc_a FROM locations WHERE warehouse_id = v_wh_a
      AND location_code = '0015-A1';
    SELECT location_id INTO v_loc_b FROM locations WHERE warehouse_id = v_wh_a
      AND location_code = '0015-A2';

    ------------------------------------------------------------------
    -- A. one callable head per function (the 4.4/0014 lesson restated for signatures that
    --    changed twice), and the register telling the truth about the reservation door:
    --    pattern 2 because a claim is reachable here, not pattern 3 because a version
    --    column happens to exist on a table it writes.
    ------------------------------------------------------------------
    IF (SELECT count(*) FROM pg_proc WHERE proname = 'reserve_inventory_for_order') <> 1
       OR (SELECT count(*) FROM pg_proc WHERE proname = 'execute_inventory_movement') <> 1 THEN
        RAISE EXCEPTION 'A failed: % reserve heads and % movement heads - a rewrite that '
                        'changes a signature is a DROP and a CREATE, not a second door',
            (SELECT count(*) FROM pg_proc WHERE proname = 'reserve_inventory_for_order'),
            (SELECT count(*) FROM pg_proc WHERE proname = 'execute_inventory_movement');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM vw_idempotency_status
                    WHERE function = 'reserve_inventory_for_order'
                      AND verdict LIKE 'ADR-005 pattern 2%') THEN
        RAISE EXCEPTION 'A failed: the register still calls the reservation door % - the '
                        'claim is not reachable from the head the ladder reads',
            (SELECT verdict FROM vw_idempotency_status
              WHERE function = 'reserve_inventory_for_order' LIMIT 1);
    END IF;
    IF EXISTS (SELECT 1 FROM vw_idempotency_status WHERE function = 'afpc_pick_bins') THEN
        RAISE EXCEPTION 'A failed: the pick helper is in the operations register - it locks '
                        'and plans, it writes nothing, and ADR-005 has nothing to say about it';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- B. 4.3's headline, both directions: every documented outcome is a ROW the caller can
    --    branch on, and no call path any more reports its failure as a type error.
    ------------------------------------------------------------------
    INSERT INTO inventory_on_hand (item_id, warehouse_id, location_id,
                                   quantity_on_hand, quantity_available)
         VALUES (v_item, v_wh_a, v_loc_a, 10, 10), (v_item, v_wh_a, v_loc_b, 10, 10);

    SELECT count(*), max(status) INTO v_rows, v_state
      FROM reserve_inventory_for_order(v_item, v_wh_a, 99, 'SALES',
                                       gen_random_uuid(), '0015-probe');
    IF v_rows <> 1 OR v_state <> 'INSUFFICIENT_STOCK' THEN
        RAISE EXCEPTION 'B failed: an over-reserve returned % row(s) with status % - 4.3 is '
                        'the finding that refusals must be data, not exceptions',
            v_rows, v_state;
    END IF;

    SELECT count(*), max(status), (array_agg(reservation_id))[1] INTO v_rows, v_state, v_res
      FROM reserve_inventory_for_order(v_item, v_wh_a, 15, 'SALES',
                                       gen_random_uuid(), '0015-probe');
    IF v_rows <> 1 OR v_state <> 'SUCCESS' OR v_res IS NULL THEN
        RAISE EXCEPTION 'B failed: a success returned % row(s) with status % - the cast 4.3 '
                        'needed was missing from the success row too, not just the handler',
            v_rows, v_state;
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- C. 4.6's worse half, from the reservation side: 15 units committed across two 10-unit
    --    bins must reserve 15, not 30. Before 0015 the same call deducted the full quantity
    --    from every bin it matched, which 4_6 measured at the statement level; this is the
    --    fact that probe's post-fix phrase will assert at the door the ledger belongs to.
    ------------------------------------------------------------------
    SELECT coalesce(sum(quantity_reserved), 0) INTO v_sum
      FROM inventory_on_hand WHERE item_id = v_item AND warehouse_id = v_wh_a;
    IF v_sum <> 15 THEN
        RAISE EXCEPTION 'C failed: a reservation of 15 left % reserved across the bins - the '
                        'warehouse-wide deduction 4.6 describes is still in the write path',
            v_sum;
    END IF;
    IF (SELECT count(*) FROM inventory_movements
         WHERE item_id = v_item AND movement_type = 'RESERVATION') <> 1 THEN
        RAISE EXCEPTION 'C failed: the commitment wrote % ledger rows, not 1 - either the '
                        'row vanished (0014''s refusal message would then lie) or it was '
                        'written per bin',
            (SELECT count(*) FROM inventory_movements
              WHERE item_id = v_item AND movement_type = 'RESERVATION');
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- D. p_location_id is honoured in both directions. A named bin with stock is drawn from
    --    only that bin; a named bin that is empty is a REFUSAL, not a licence to drain the
    --    rest of the warehouse - which is what "filters by item+warehouse while ignoring
    --    location_id" becomes the moment a caller knows where the goods are.
    ------------------------------------------------------------------
    PERFORM (array_agg(reservation_id))[1]
       FROM reserve_inventory_for_order(v_item, v_wh_a, 4, 'SALES',
                                        gen_random_uuid(), '0015-probe', v_loc_b);
    IF (SELECT quantity_reserved FROM inventory_on_hand
         WHERE item_id = v_item AND warehouse_id = v_wh_a AND location_id = v_loc_a) <> 10
       OR (SELECT quantity_reserved FROM inventory_on_hand
         WHERE item_id = v_item AND warehouse_id = v_wh_a AND location_id = v_loc_b) <> 9 THEN
        RAISE EXCEPTION 'D failed: a bin-pinned reservation touched the wrong rows (%)',
            (SELECT string_agg(coalesce(location_id::text,'-') || '='
                              || quantity_reserved::text, ',' ORDER BY location_id)
               FROM inventory_on_hand WHERE item_id = v_item AND warehouse_id = v_wh_a);
    END IF;

    -- Every bin is now fully committed (10 + 9 reserved of 10 + 10). A pin on the bin with
    -- nothing left must refuse, and name the bin it refused.
    SELECT max(message) INTO v_state
      FROM reserve_inventory_for_order(v_item, v_wh_a, 1, 'SALES',
                                       gen_random_uuid(), '0015-probe', v_loc_a);
    IF v_state NOT LIKE '%named bin%' THEN
        RAISE EXCEPTION 'D failed: a refusal on a pinned-empty bin said % - the answer is '
                        'about the bin the caller named, not the warehouse', v_state;
    END IF;
    IF (SELECT count(*) FROM inventory_reservations
         WHERE item_id = v_item AND reserved_quantity = 1) <> 0 THEN
        RAISE EXCEPTION 'D failed: the pinned refusal wrote a reservation row anyway';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- E. the same pick through the movement door: an ISSUE spanning bins takes the quantity
    --    once, in order, and the ledger row names the bin only when the answer is one bin.
    --    The reservations are deleted before the balances are reset: leaving commitments
    --    pointing at quantity_reserved=0 would make the fixture a fiction the audit trail
    --    then faithfully describes, and 0013 exists to make that visible.
    ------------------------------------------------------------------
    DELETE FROM inventory_reservations WHERE item_id = v_item;
    UPDATE inventory_on_hand SET quantity_reserved = 0,
           quantity_available = quantity_on_hand
     WHERE item_id = v_item AND warehouse_id = v_wh_a;
    PERFORM execute_inventory_movement('ISSUE', v_item, v_wh_a, NULL, 15, 5,
             '0015-probe', 'ORDER', NULL, 'span the bins', 'EACH');
    SELECT coalesce(sum(quantity_on_hand), 0) INTO v_sum
      FROM inventory_on_hand WHERE item_id = v_item AND warehouse_id = v_wh_a;
    IF v_sum <> 5 THEN
        RAISE EXCEPTION 'E failed: an issue of 15 left % on the books across the bins (20 '
                        'stocked) - the full quantity is still being deducted from each row',
            v_sum;
    END IF;
    IF (SELECT string_agg(quantity_on_hand::text, ',' ORDER BY location_id)
          FROM inventory_on_hand
         WHERE item_id = v_item AND warehouse_id = v_wh_a) <> '0.0000,5.0000' THEN
        RAISE EXCEPTION 'E failed: the draw did not follow the pick order: %',
            (SELECT string_agg(coalesce(location_id::text,'-') || '='
                              || quantity_on_hand::text, ',' ORDER BY location_id)
               FROM inventory_on_hand WHERE item_id = v_item AND warehouse_id = v_wh_a);
    END IF;
    IF (SELECT count(*) FROM inventory_movements
         WHERE item_id = v_item AND movement_type = 'ISSUE'
           AND from_location_id IS NULL) <> 1 THEN
        RAISE EXCEPTION 'E failed: a two-bin issue either wrote no ledger row or named a bin '
                        'it did not draw from alone';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- F. a single-bin draw DOES name the bin: the two location columns in the ledger have
    --    existed since 0001 and nothing in the schema could fill them before this file.
    ------------------------------------------------------------------
    UPDATE inventory_on_hand SET quantity_on_hand = 10, quantity_available = 10
     WHERE item_id = v_item AND warehouse_id = v_wh_a AND location_id = v_loc_b;
    PERFORM execute_inventory_movement('ISSUE', v_item, v_wh_a, NULL, 5, 5,
             '0015-probe', 'ORDER', NULL, 'named bin', 'EACH', NULL, v_loc_b);
    IF (SELECT count(*) FROM inventory_movements
         WHERE item_id = v_item AND movement_type = 'ISSUE'
           AND from_location_id = v_loc_b) <> 1 THEN
        RAISE EXCEPTION 'F failed: an issue pinned to bin % did not record the bin in the '
                        'ledger - from_location_id is still write-protected by omission',
            '0015-A2';
    END IF;
    IF (SELECT quantity_on_hand FROM inventory_on_hand
         WHERE item_id = v_item AND warehouse_id = v_wh_a AND location_id = v_loc_a) <> 0 THEN
        RAISE EXCEPTION 'F failed: a bin-pinned issue drew from a bin the caller did not name';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- G. the claim at this door: a replay of the same key answers from the cache and moves
    --    no second commitment, and a failed attempt leaves the key re-claimable (the
    --    refusal path releases it, probe B's over-reserve would otherwise have owned it).
    ------------------------------------------------------------------
    PERFORM execute_inventory_movement('RECEIPT', v_item2, NULL, v_wh_b, 20, 4,
             '0015-probe', 'PO', NULL, 'stock for the claim probe', 'EACH');
    SELECT (array_agg(reservation_id))[1] INTO v_res
      FROM reserve_inventory_for_order(v_item2, v_wh_b, 3, 'PURCHASE', v_order,
                                       '0015-probe', NULL, v_key);
    SELECT (array_agg(reservation_id))[1] INTO v_mv
      FROM reserve_inventory_for_order(v_item2, v_wh_b, 3, 'PURCHASE', v_order,
                                       '0015-probe', NULL, v_key);
    IF v_res IS DISTINCT FROM v_mv THEN
        RAISE EXCEPTION 'G failed: the replayed reservation id differs - answered from the '
                        'claim?';
    END IF;
    IF (SELECT count(*) FROM inventory_reservations
         WHERE item_id = v_item2 AND order_id = v_order) <> 1 THEN
        RAISE EXCEPTION 'G failed: a replayed reservation created % rows - the doubling '
                        '0011 was built to stop, at the door that had no guard at all',
            (SELECT count(*) FROM inventory_reservations
              WHERE item_id = v_item2 AND order_id = v_order);
    END IF;

    -- A refusal must not become a cached answer: the same call after a restock must
    -- re-evaluate. Run against an item with nothing on the books, so the refusal is about
    -- stock and not about the state the earlier probes left behind - and the retry repeats
    -- the request EXACTLY, because a claim key names one operation (0011): a different
    -- quantity under the same key is a conflict, not a re-attempt.
    v_order2 := gen_random_uuid();
    SELECT max(status) INTO v_state
      FROM reserve_inventory_for_order(v_item3, v_wh_b, 5, 'PURCHASE', v_order2,
                                       '0015-probe', NULL, v_key2);
    IF v_state <> 'INSUFFICIENT_STOCK' THEN
        RAISE EXCEPTION 'G failed: the unstocked reserve answered % instead of refusing', v_state;
    END IF;
    PERFORM execute_inventory_movement('RECEIPT', v_item3, NULL, v_wh_b, 8, 4,
             '0015-probe', 'PO', NULL, 'restock for the retry', 'EACH');
    SELECT max(status) INTO v_state
      FROM reserve_inventory_for_order(v_item3, v_wh_b, 5, 'PURCHASE', v_order2,
                                       '0015-probe', NULL, v_key2);
    IF v_state <> 'SUCCESS' THEN
        RAISE EXCEPTION 'G failed: a retry after a restock replayed the word "no" (%) - a '
                        'refusal is not an answer worth caching', v_state;
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- H. 0014's contracts, re-asserted because §3 rewrote the body that earned them: the
    --    phantom refusal still leaves no ledger row, an oversell still answers 23514, a
    --    self-transfer still refuses, RESERVATION still points elsewhere, and a keyed
    --    movement still replays to the same id.
    ------------------------------------------------------------------
    BEGIN
        PERFORM execute_inventory_movement('ISSUE', v_item2, v_wh_a, NULL, 5, 5,
                 '0015-probe', 'ORDER', NULL, 'never stocked here');
        RAISE EXCEPTION 'H failed: the phantom issue returned a movement id';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE <> '23503' THEN
                RAISE EXCEPTION 'H failed: the never-stocked issue answered % , not 23503',
                    SQLSTATE;
            END IF;
            IF (SELECT count(*) FROM inventory_movements
                 WHERE item_id = v_item2 AND from_warehouse_id = v_wh_a) <> 0 THEN
                RAISE EXCEPTION 'H failed: the refused issue left a ledger row behind';
            END IF;
    END;

    BEGIN
        PERFORM execute_inventory_movement('ISSUE', v_item, v_wh_a, NULL, 9999, 5,
                 '0015-probe', 'ORDER', NULL, 'oversell');
        RAISE EXCEPTION 'H failed: the oversell was allowed';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE <> '23514' THEN
                RAISE EXCEPTION 'H failed: the oversell answered %, not 23514', SQLSTATE;
            END IF;
    END;

    BEGIN
        PERFORM execute_inventory_movement('TRANSFER', v_item, v_wh_a, v_wh_a, 1, 5,
                 '0015-probe', 'TRANSFER', NULL, 'self transfer');
        RAISE EXCEPTION 'H failed: a self-transfer was accepted';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE <> '22023' THEN
                RAISE EXCEPTION 'H failed: the self-transfer answered %', SQLSTATE;
            END IF;
    END;

    BEGIN
        PERFORM execute_inventory_movement('RESERVATION', v_item, NULL, v_wh_a, 1, 5,
                 '0015-probe', 'ORDER', NULL, 'wrong door');
        RAISE EXCEPTION 'H failed: RESERVATION passed through the generic path';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE <> '23514' THEN
                RAISE EXCEPTION 'H failed: RESERVATION at the generic door answered %', SQLSTATE;
            END IF;
    END;

    v_mv := execute_inventory_movement('ADJUSTMENT', v_item, v_wh_a, NULL, 1, 5,
             '0015-probe', 'ADJUSTMENT', NULL, 'keyed', 'EACH', v_key2);
    IF execute_inventory_movement('ADJUSTMENT', v_item, v_wh_a, NULL, 1, 5,
             '0015-probe', 'ADJUSTMENT', NULL, 'keyed', 'EACH', v_key2)
       IS DISTINCT FROM v_mv THEN
        RAISE EXCEPTION 'H failed: the keyed movement replay is not the same id';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- I. the two vocabularies meet, driven from the register rather than from this file's
    --    memory of it. 4.3's second wall was invisible because NOT NULL was checked before
    --    the CHECK: p_order_type straight into movements.reference_type is legal for one of
    --    the five published order types, so the reservation door could not have worked even
    --    with a unit supplied. The loop asks the live register for the order types, reserves
    --    one unit of each under its own order_id, then reads the ledger rows it produced and
    --    checks their reference_type against the OTHER column's published list. A member
    --    added on one side without a mapping on the other fails here by number, and nothing
    --    in this probe restates the mapping - which is the only way the test would notice a
    --    drift rather than agree with it.
    ------------------------------------------------------------------
    FOR r IN
        SELECT t AS order_type, gen_random_uuid() AS order_id
          FROM unnest((SELECT allowed_values FROM vw_domain_vocabulary
                        WHERE table_name = 'inventory_reservations'
                          AND column_name = 'order_type')) t
    LOOP
        BEGIN
            SELECT (array_agg(reservation_id))[1] INTO v_res
              FROM reserve_inventory_for_order(v_item2, v_wh_b, 1, r.order_type,
                                               r.order_id, '0015-probe');
        EXCEPTION WHEN OTHERS THEN
            RAISE EXCEPTION 'I failed: order type % could not reserve (%) - the door refuses a '
                            'value its own table admits', r.order_type, SQLSTATE;
        END;
        IF v_res IS NULL THEN
            RAISE EXCEPTION 'I failed: order type % produced no reservation - the probe''s '
                            'fixture ran out of stock rather than the mapping failing',
                r.order_type;
        END IF;
        -- allowed_values is a text[] in this register (measured), so membership is tested
        -- over its elements. Two forms that look identical and are not:
        -- `x = ANY ((SELECT allowed_values ...))` binds the whole ARRAY as one row of the
        -- subquery and dies with "operator does not exist: character varying = text[]",
        -- while `x = ANY (SELECT unnest(allowed_values) ...)` compares against its elements.
        -- (The scalar-subquery form is fine inside unnest() itself, which is how the loop
        -- above gets its order types - the difference is whether the array is an argument
        -- to ANY or to a function.)
        SELECT count(*) INTO v_rows FROM inventory_movements m
         WHERE m.reference_id = r.order_id AND m.movement_type = 'RESERVATION'
           AND m.reference_type IS NOT NULL
           AND NOT (m.reference_type = ANY (SELECT unnest(allowed_values)
                                              FROM vw_domain_vocabulary
                                             WHERE table_name = 'inventory_movements'
                                               AND column_name = 'reference_type'));
        IF v_rows <> 0 THEN
            RAISE EXCEPTION 'I failed: order type % wrote a ledger row whose reference_type is '
                            'not in the published vocabulary - the axis is named twice again',
                r.order_type;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM inventory_movements
                        WHERE reference_id = r.order_id AND movement_type = 'RESERVATION') THEN
            RAISE EXCEPTION 'I failed: order type % reserved without a ledger row - 0014''s '
                            'refusal message points here for a reason', r.order_type;
        END IF;
    END LOOP;
    DELETE FROM inventory_reservations
     WHERE reserved_by = '0015-probe' AND item_id = v_item2;
    UPDATE inventory_on_hand SET quantity_reserved = 0,
           quantity_available = quantity_on_hand
     WHERE item_id = v_item2;
    DELETE FROM inventory_movements
     WHERE movement_type = 'RESERVATION' AND performed_by = '0015-probe';
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- J. an error keeps its SQLSTATE. This is the half of 4.3 the review prescribed
    --    differently: rather than a handler that returns status='ERROR' (which discards the
    --    code, the exact thing 0014 deleted from the other door), the two business outcomes
    --    are rows and everything else propagates. A caller that wants to branch on
    --    INSUFFICIENT_STOCK still can; a caller that wanted to branch on 'ERROR' instead of
    --    23503 wanted the re-wrap 4.1 was about.
    ------------------------------------------------------------------
    v_err := NULL;
    BEGIN
        SELECT count(*) INTO v_rows FROM reserve_inventory_for_order(
            gen_random_uuid(), v_wh_a, 1, 'SALES', gen_random_uuid(), '0015-probe');
    EXCEPTION WHEN OTHERS THEN
        v_err := SQLSTATE;
    END;
    -- Asserted OUTSIDE the guarded block: a RAISE EXCEPTION inside a block whose own handler
    -- watches for a different code is caught by itself, and reports its own P0001 as the
    -- finding (this probe did exactly that on its first rehearsal).
    IF v_err IS DISTINCT FROM '22023' THEN
        RAISE EXCEPTION 'J failed: the nonexistent-item reservation answered % - a wrong '
                        'argument must be an error, not a status row, and "0 available" '
                        'would be 4.3''s conflation with the numbers rearranged',
            coalesce(v_err, 'a row (no exception at all)');
    END IF;
    -- The other error shapes, each asserted as an error rather than as a status row. This is
    -- the behavioural form of "no ERROR status exists": the structural version of this line
    -- read pg_get_functiondef for the string 'ERROR' and failed - on this file's own
    -- explanatory comment, because a function's comments are part of the text the catalog
    -- returns. 0011's register note warns that body-text classification reads prose as code;
    -- the lesson repeats one migration later and one level deeper.
    v_err := NULL;
    BEGIN
        PERFORM (array_agg(reservation_id))[1] FROM reserve_inventory_for_order(
            v_item2, v_wh_a, 1, 'sales_order', gen_random_uuid(), '0015-probe');
    EXCEPTION WHEN OTHERS THEN
        v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '23514' THEN
        RAISE EXCEPTION 'J failed: an order type outside the vocabulary answered % - the '
                        'constraint 0007 added must be the floor under this door, not a row',
            coalesce(v_err, 'a row (no exception at all)');
    END IF;

    -- The other half of the same claim, with the door removed: a raw write must still be
    -- refused by the constraint. Without this arm the guard above could quietly become the
    -- only thing standing for a rule the table is supposed to state.
    v_err := NULL;
    BEGIN
        INSERT INTO inventory_reservations (item_id, warehouse_id, order_type, order_id,
                                           reserved_quantity, reserved_by)
             VALUES (v_item2, v_wh_a, 'sales_order', gen_random_uuid(), 1, '0015-probe');
    EXCEPTION WHEN OTHERS THEN
        v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '23514' THEN
        RAISE EXCEPTION 'J failed: a raw reservation with an illegal order type answered % - '
                        'the guard above is now the only thing enforcing a schema rule',
            coalesce(v_err, 'no exception (the row was accepted)');
    END IF;

    v_err := NULL;
    BEGIN
        PERFORM (array_agg(reservation_id))[1] FROM reserve_inventory_for_order(
            v_item2, gen_random_uuid(), 1, 'SALES', gen_random_uuid(), '0015-probe');
    EXCEPTION WHEN OTHERS THEN
        v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '22023' THEN
        RAISE EXCEPTION 'J failed: a nonexistent warehouse answered %',
            coalesce(v_err, 'a row (no exception at all)');
    END IF;

    -- The other door, same claim and same SQLSTATE: a wrong argument costs 22023 wherever it
    -- arrives, so a caller learns the fact rather than the door's internals. Underneath the
    -- guard, the item FK is still the floor - which is what the raw-write arm below shows.
    v_err := NULL;
    BEGIN
        PERFORM execute_inventory_movement('RECEIPT', gen_random_uuid(), NULL, v_wh_b, 1, 1,
                 '0015-probe', 'PO', NULL, 'unknown item');
    EXCEPTION WHEN OTHERS THEN
        v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '22023' THEN
        RAISE EXCEPTION 'J failed: a movement of a nonexistent item answered % - the two doors '
                        'must not disagree about what a wrong argument costs',
            coalesce(v_err, 'a value (no exception at all)');
    END IF;

    v_err := NULL;
    BEGIN
        INSERT INTO inventory_movements (movement_type, item_id, to_warehouse_id, quantity,
                                         unit_of_measure, performed_by)
             VALUES ('RECEIPT', gen_random_uuid(), v_wh_b, 1, 'EACH', '0015-probe');
    EXCEPTION WHEN OTHERS THEN
        v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '23503' THEN
        RAISE EXCEPTION 'J failed: a raw movement of a nonexistent item answered % - the guard '
                        'above cannot become the only thing enforcing the item''s existence',
            coalesce(v_err, 'no exception (the row was accepted)');
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- K. the report the kept ledger row was inflating: a commitment is neither inbound nor
    --    outbound, and net_quantity still shows it, because it is a real fact about the day.
    --    The probe makes its own commitment rather than leaning on an earlier one - probe I
    --    cleans the reservation ledger rows it exercises, and a probe that reads another
    --    probe's residue fails for the wrong reason on the day the order changes.
    ------------------------------------------------------------------
    PERFORM (array_agg(reservation_id))[1] FROM reserve_inventory_for_order(
        v_item2, v_wh_b, 4, 'SALES', gen_random_uuid(), '0015-probe');
    SELECT count(*) INTO v_rows FROM vw_item_movement_summary
     WHERE item_id = v_item2 AND movement_type = 'RESERVATION' AND total_inbound <> 0;
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'K failed: % reservation rows still report as inbound movement - §4''s '
                        'transform did not take', v_rows;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM vw_item_movement_summary
                    WHERE item_id = v_item2 AND movement_type = 'RESERVATION'
                      AND net_quantity > 0) THEN
        RAISE EXCEPTION 'K failed: the reservation rows vanished from the report altogether - '
                        'the fix was meant to be directional, not a deletion';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- L. the boundary §6's COMMENT names, demonstrated: stock committed to a reservation is
    --    not issuable through the generic door, because the pick draws on quantity_available
    --    and no fulfilment step exists that consumes a reservation. If a later migration
    --    adds one, this probe is the assertion it must invert deliberately rather than
    --    discover by accident.
    ------------------------------------------------------------------
    UPDATE inventory_on_hand SET quantity_on_hand = 10, quantity_available = 10,
           quantity_reserved = 0
     WHERE item_id = v_item AND warehouse_id = v_wh_a;
    DELETE FROM inventory_movements WHERE item_id = v_item;
    -- All of it: the warehouse has two bins and the pick will draw from whichever still has
    -- units, so a probe that commits only one bin leaves the other one issuable and the
    -- boundary it means to test never appears. (The first draft of this line reserved 10
    -- against 20 units and "passed" by reserving half the warehouse.)
    SELECT (array_agg(reservation_id))[1] INTO v_res
      FROM reserve_inventory_for_order(v_item, v_wh_a, 20, 'SALES',
                                       gen_random_uuid(), '0015-probe');
    v_err := NULL;
    BEGIN
        PERFORM execute_inventory_movement('ISSUE', v_item, v_wh_a, NULL, 5, 5,
                 '0015-probe', 'ORDER', NULL, 'ship against the reservation');
    EXCEPTION WHEN OTHERS THEN
        v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '23514' THEN
        RAISE EXCEPTION 'L failed: shipping against a reservation answered % - either the '
                        'pick is blind to commitments again, or a fulfilment path landed '
                        'without updating this probe', coalesce(v_err, 'no exception at all');
    END IF;
    IF (SELECT count(*) FROM inventory_movements
         WHERE item_id = v_item AND movement_type = 'ISSUE') <> 0 THEN
        RAISE EXCEPTION 'L failed: the refused fulfilment left a ledger row';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- M. the seat, in the only form this schema can express: as afpc_app the door is usable
    --    end to end - EXECUTE granted, RLS applied to the locking read, the audit helpers
    --    reachable from a trigger - and the trail names the seat that sat in it. A
    --    cross-tenant version of "can another tenant's bins be drained" is not expressible
    --    here, because every table the pick reads is tenant-coded and forced: the rows the
    --    other tenant owns are not in this tenant's warehouse at all. 0011 measured the
    --    analogous claim for the arbiter, where a global index did make a lost write
    --    reachable; this probe says what is reachable and leaves the rest in §6's COMMENT.
    ------------------------------------------------------------------
    DELETE FROM inventory_reservations WHERE item_id = v_item;
    UPDATE inventory_on_hand SET quantity_on_hand = 10, quantity_reserved = 0,
           quantity_available = quantity_on_hand
     WHERE item_id = v_item AND warehouse_id = v_wh_a;
    SET LOCAL ROLE afpc_app;
    SELECT max(status) INTO v_state FROM reserve_inventory_for_order(
        v_item, v_wh_a, 5, 'SALES', gen_random_uuid(), 'afpc_app probe');
    RESET ROLE;
    IF v_state <> 'SUCCESS' THEN
        RAISE EXCEPTION 'M failed: the reservation door is not usable by the application role '
                        '(status %) - 0009''s wall and this function have never met', v_state;
    END IF;
    IF (SELECT count(*) FROM audit_log WHERE table_name = 'inventory_reservations'
         AND db_user = 'afpc_app' AND new_values->>'reserved_by' = 'afpc_app probe') <> 1 THEN
        RAISE EXCEPTION 'M failed: the seat that wrote the commitment is not the seat the '
                        'trail records - 5.8''s identity answer, in one column';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- Cleanup: movements first (RESTRICT edges from 0008), then commitments, then balances,
    -- then masters. The trail about the deletions stays, which is 0013 working as designed.
    ------------------------------------------------------------------
    DELETE FROM inventory_movements     WHERE item_id IN (v_item, v_item2, v_item3);
    DELETE FROM inventory_reservations  WHERE item_id IN (v_item, v_item2, v_item3);
    DELETE FROM inventory_on_hand       WHERE item_id IN (v_item, v_item2, v_item3);
    DELETE FROM idempotency_keys        WHERE operation IN
                                  ('reserve_inventory_for_order',
                                   'execute_inventory_movement');
    DELETE FROM inventory_items         WHERE item_id IN (v_item, v_item2, v_item3);
    DELETE FROM locations               WHERE warehouse_id IN (v_wh_a, v_wh_b);
    DELETE FROM warehouses              WHERE warehouse_id IN (v_wh_a, v_wh_b);

    IF v_n <> 13 THEN
        RAISE EXCEPTION 'expected 13 behavioural verifications, completed %', v_n;
    END IF;
    RAISE NOTICE '4.3/4.2: % checks passed - refusals are rows, errors keep their SQLSTATE, '
                 'a quantity is taken once from the bins that have it, the bins are named when '
                 'they can be, a replayed call reserves once, and the two halves of one '
                 'vocabulary finally agree', v_n;
END
$$;
