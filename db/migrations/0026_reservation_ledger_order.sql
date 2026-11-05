-- 0026_reservation_ledger_order.sql — the reservation door's commitment row had its last three
-- VALUES rotated against its column list, so every SUCCESS since 0018 died on the door's own
-- ledger INSERT. Finding 6.5's regression; probe `4_3`'s status block had been saying VERDICT ERR
-- with this exact 42804 since the day 0018 landed - the harness just had not been run against
-- this database since.
--
-- What 0018 §3b did, measured off the installed body: it capture-transformed the function's text,
-- appending `currency_code` to the END of the column list and inserting `afpc_item_currency(p_item_id)`
-- AFTER `p_reserved_by` - the middle - of the VALUES. Both needles matched exactly once, both
-- assertions passed, and the three trailing values now sit a rotation away from their columns:
--
--     reference_type  <-  afpc_item_currency(p_item_id)     ('USD' into a varchar - accepted, false)
--     reference_id    <-  CASE p_order_type ...             (text into uuid - the 42804 that kills the write)
--     currency_code   <-  p_order_id                        (uuid never reached: the statement dies one column early)
--
-- The INSUFFICIENT_STOCK half never noticed - it returns before this INSERT - which is why probe
-- 4_3's first block says OK while its second says ERR, and why "a reservation succeeded" was a
-- sentence this schema could print but not execute: the exception rolled the whole call back,
-- door-returned error included. The failure surfaced here, building the inventory agent's seed:
-- the first successful reservation anyone had asked the deployed database for in weeks.
--
-- The shape of the defect is the lesson 0018's own prose preaches - "a rule stated on two sides
-- of a relationship is two rules" - applied to a patch and a body: appending a column and
-- inserting a value are two edits to one relationship (position N of the column list ↔ position
-- N of the VALUES), and a needle pair can satisfy both halves' text while violating the
-- relationship itself. What was missing from 0018 was not care but behaviour: it asserted the
-- patched TEXT contained the call (it does - the count assertion passes) and never asserted the
-- patched FUNCTION could RESERVE. This migration patches the same way (both needles, hit-count
-- 1, EXECUTE of the result) and then runs the door end to end inside a subtransaction it
-- discards, so the verdict comes from a reservation, not from a string.

SET client_min_messages TO notice;

-- ---------------------------------------------------------------------------
-- 1. The patch, same capture-transform discipline as 0018 §3b
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_body text;
    v_new  text;
    t      record;
BEGIN
    IF (SELECT count(*) FROM pg_proc WHERE proname = 'reserve_inventory_for_order') <> 1 THEN
        RAISE EXCEPTION '0026 found % heads of reserve_inventory_for_order',
            (SELECT count(*) FROM pg_proc WHERE proname = 'reserve_inventory_for_order');
    END IF;

    SELECT pg_get_functiondef(p.oid) INTO v_body
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'reserve_inventory_for_order';

    -- Both edits, in either order, land on the same final arrangement; the needles are the two
    -- rotated positions, stated with enough context to be unique (each measured 1 hit before
    -- this ran, and the loop re-measures rather than trusting this comment).
    FOR t IN SELECT * FROM (VALUES
        (E'             ''ORDER_COMMITMENT'', p_reserved_by, afpc_item_currency(p_item_id),',
         E'             ''ORDER_COMMITMENT'', p_reserved_by,',
         'the currency out of the reference_type slot'),
        (E'             p_order_id);',
         E'             p_order_id, afpc_item_currency(p_item_id));',
         'the currency back in at the end, after reference_id')
    ) AS n(needle, patch, which)
    LOOP
        IF array_length(string_to_array(v_body, t.needle), 1) - 1 <> 1 THEN
            RAISE EXCEPTION '0026''s % needle matched % times - the body is not the one 0018 left',
                t.which, array_length(string_to_array(v_body, t.needle), 1) - 1;
        END IF;
        v_new := replace(v_body, t.needle, t.patch);
        IF v_new = v_body THEN
            RAISE EXCEPTION '0026''s % patch did not apply', t.which;
        END IF;
        v_body := v_new;
    END LOOP;

    EXECUTE v_body;
END
$$;

-- ---------------------------------------------------------------------------
-- 2. The behaviour assertion: make a reservation, read its ledger row, discard everything.
--
--    Everything the probe touches runs inside a nested block whose normal ending is a forced
--    exception - a subtransaction that always rolls back, so a passing check leaves no fixture
--    behind and a failing one aborts the migration with the failure's own message (anything that
--    is not the discard word is re-raised). The positions this reads are the whole finding:
--    reference_type is the MAPPED document kind, reference_id is the order, currency is the
--    item's. A rotation in any direction trips one of the three.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_wh     uuid;
    v_item   uuid;
    v_order  uuid;
    v_res    uuid;
    v_status text;
    v_ref_t  text;
    v_ref_i  uuid;
    v_cur    char(3);
BEGIN
    BEGIN  -- subtransaction: the check's fixture must vanish whether it passed or not
        INSERT INTO warehouses (warehouse_code, name)
             VALUES ('AFPC-0026', '0026 selftest warehouse')
          RETURNING warehouse_id INTO v_wh;
        INSERT INTO inventory_items (sku, name, base_unit_of_measure, currency_code)
             VALUES ('AFPC-0026', '0026 selftest item', 'EACH', 'USD')
          RETURNING item_id INTO v_item;

        PERFORM execute_inventory_movement('RECEIPT', v_item, NULL, v_wh, 10, 2,
                 '0026 selftest', 'PO', NULL, NULL, 'EACH');

        v_order := afpc_uuid_v7();
        SELECT reservation_id, status INTO v_res, v_status
          FROM reserve_inventory_for_order(v_item, v_wh, 3, 'SALES', v_order, '0026 selftest');

        IF v_status IS DISTINCT FROM 'SUCCESS' THEN
            RAISE EXCEPTION '0026 selftest: the door answered % (reservation_id %) - it cannot '
                            'have written its ledger row', coalesce(v_status, 'NULL'), v_res;
        END IF;

        SELECT m.reference_type, m.reference_id, m.currency_code
          INTO v_ref_t, v_ref_i, v_cur
          FROM inventory_movements m
         WHERE m.movement_type = 'RESERVATION' AND m.item_id = v_item;

        IF v_ref_t IS DISTINCT FROM 'ORDER'::text THEN
            RAISE EXCEPTION '0026 selftest: reference_type is % - SALES must map to ORDER, the '
                            'way 0015 §4 decided it', coalesce(quote_literal(v_ref_t), 'NULL');
        END IF;
        IF v_ref_i IS DISTINCT FROM v_order THEN
            RAISE EXCEPTION '0026 selftest: reference_id % is not the order % that was named - '
                            'the rotation this migration is about is still in the VALUES',
                v_ref_i, v_order;
        END IF;
        IF v_cur IS DISTINCT FROM 'USD'::char(3) THEN
            RAISE EXCEPTION '0026 selftest: currency_code is % - 0018 §3b''s derivation belongs '
                            'in this column and nowhere else', coalesce(v_cur, 'NULL');
        END IF;

        IF NOT EXISTS (SELECT 1 FROM inventory_reservations WHERE reservation_id = v_res) THEN
            RAISE EXCEPTION '0026 selftest: status SUCCESS named reservation %, which is not there', v_res;
        END IF;

        RAISE EXCEPTION '0026-selftest-discard';  -- normal ending: unwind the subtransaction
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM IS DISTINCT FROM '0026-selftest-discard' THEN
            RAISE;   -- a real failure aborts the migration with its own SQLSTATE
        END IF;
    END;

    RAISE NOTICE '0026: a reservation succeeds end to end - reservation, ledger row, all three '
                 'positions, and the fixture leaves no trace';
END
$$;

-- ---------------------------------------------------------------------------
-- 3. The text half of the guard, so a future capture-transform can rot this the way 0018 did.
--    Cheap to state next to behaviour it cannot replace: the body names the currency exactly
--    once, and names it AFTER p_order_id, which is the position the column list reserves for it.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_src text;
BEGIN
    SELECT prosrc INTO v_src FROM pg_proc WHERE proname = 'reserve_inventory_for_order';
    IF (array_length(string_to_array(v_src, 'afpc_item_currency(p_item_id)'), 1) - 1) <> 1 THEN
        RAISE EXCEPTION '0026 left % currency derivations in the body - the door names its own '
                        'column''s source exactly once',
            array_length(string_to_array(v_src, 'afpc_item_currency(p_item_id)'), 1) - 1;
    END IF;
    IF position('p_order_id, afpc_item_currency(p_item_id))' IN v_src) = 0 THEN
        RAISE EXCEPTION '0026''s arrangement is not in the installed body - the patch was applied '
                        'to a text that was then discarded (0018''s own §3b failure mode, kept '
                        'out of the fix that fixes 0018)';
    END IF;
END
$$;
