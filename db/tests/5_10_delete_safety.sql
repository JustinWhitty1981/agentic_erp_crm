-- Finding 5.10, as behaviour: does a parent delete destroy the facts that point at it?
--
-- verify.sh's B3 can see the delete rules in pg_constraint, and after 0008 it sees the right
-- ones. What it cannot see is whether the rules do what the migration claims - and unlike
-- 0006's index question, "is this delete refused" does not depend on table size, so the
-- honest version of the check is to attempt the destructions and watch. That is what this
-- file does, inside transactions that roll back, against fixtures it creates itself
-- (codes T10-*, so they cannot collide with rows a previous rehearsal left anywhere).
--
-- Each block's VERDICT ERR phrase is written to appear ONLY on the failure side, because
-- scripts/db/test-functions.sh decides KNOWN-OPEN vs CLOSED with a grep, not a parser.
--
-- Pre-0008, measured on a clone of this database, blocks A-D all destroy or silently rewrite;
-- block E has no function to call. Post-0008, none of them does.

-- A. Warehouse holding stock, no ledger history - the state in which the CASCADE actually
--    fired: history is what made the other edges refuse, and a warehouse that has only ever
--    sat there had none.
BEGIN;
DO $$
DECLARE
    v_wh    uuid;
    v_it    uuid;
BEGIN
    SET LOCAL app.tenant_id = '00000000-0000-0000-0000-000000000001';
    INSERT INTO warehouses (warehouse_code, name, warehouse_type)
        VALUES ('T10-A', '5.10 block A', 'PRIMARY') RETURNING warehouse_id INTO v_wh;
    INSERT INTO inventory_items (sku, name, product_type)
        VALUES ('T10-A', '5.10 item A', 'STOCKED') RETURNING item_id INTO v_it;
    INSERT INTO inventory_on_hand (item_id, warehouse_id, quantity_on_hand)
        VALUES (v_it, v_wh, 40);

    BEGIN
        DELETE FROM warehouses WHERE warehouse_id = v_wh;
        -- Counted AFTER the cascade, so this is the survivor count, which is the whole point:
        -- a healthy warehouse delete cannot leave a stock row pointing at nothing.
        IF EXISTS (SELECT 1 FROM inventory_on_hand WHERE item_id = v_it) THEN
            RAISE NOTICE 'VERDICT ERR a warehouse delete destroyed the stock at T10-A but '
                         'left the item, so the ledger is now half-gone';
        ELSE
            RAISE NOTICE 'VERDICT ERR a warehouse delete destroyed the stock rows that held '
                         'the quantities someone counted at T10-A';
        END IF;
    EXCEPTION WHEN foreign_key_violation THEN
        RAISE NOTICE 'VERDICT OK the warehouse delete was refused by % - the stock row is a '
                     'fact and RESTRICT treats it as one', 'inventory_on_hand_warehouse_id_fkey';
    END;
END
$$;
ROLLBACK;

-- B. Same for the item end, including the reservation row: an unshipped reservation is a
--    commitment to a customer, and CASCADE deleted it without asking.
BEGIN;
DO $$
DECLARE
    v_wh    uuid;
    v_it    uuid;
    v_party bigint;
    v_order uuid;
BEGIN
    SET LOCAL app.tenant_id = '00000000-0000-0000-0000-000000000001';
    INSERT INTO warehouses (warehouse_code, name, warehouse_type)
        VALUES ('T10-B', '5.10 block B', 'PRIMARY') RETURNING warehouse_id INTO v_wh;
    INSERT INTO inventory_items (sku, name, product_type)
        VALUES ('T10-B', '5.10 item B', 'STOCKED') RETURNING item_id INTO v_it;
    INSERT INTO inventory_on_hand (item_id, warehouse_id, quantity_on_hand)
        VALUES (v_it, v_wh, 5);
    -- The reservation has to name a document that exists: 0030's trigger refuses one that does not,
    -- and an order id raised by gen_random_uuid() here was the same defect this programme exists to
    -- close. 5_7 block B carries the longer note, including how both files were found - the harness's
    -- phrase mapping reported them CLOSED while an ERROR aborted the block, which is a false green
    -- arrived through a different door than the one 4_8 §8c warns about.
    INSERT INTO entities (name, entity_type)
        VALUES ('5.10 block B party', 'customer') RETURNING id INTO v_party;
    SELECT order_id INTO v_order
      FROM create_order('SALES', v_party, NULL, NULL, NULL, NULL, NULL,
                        '5.10 block B fixture', 'MANUAL', NULL);
    INSERT INTO inventory_reservations (item_id, warehouse_id, order_type, order_id,
                                        reserved_quantity)
        VALUES (v_it, v_wh, 'SALES', v_order, 2);

    BEGIN
        DELETE FROM inventory_items WHERE item_id = v_it;
        RAISE NOTICE 'VERDICT ERR an item delete destroyed the stock and the open reservation '
                     'that pointed at T10-B';
    EXCEPTION WHEN foreign_key_violation THEN
        RAISE NOTICE 'VERDICT OK the item delete was refused - stock first (%), or the '
                     'reservation, would have to go explicitly', 'inventory_on_hand_item_id_fkey';
    END;
END
$$;
ROLLBACK;

-- C. The audit half: bot_actions is what an incident review reads. A CASCADE on the session
--    meant deleting a login deleted what the agent did while logged in.
BEGIN;
DO $$
DECLARE
    v_se uuid;
BEGIN
    SET LOCAL app.tenant_id = '00000000-0000-0000-0000-000000000001';
    INSERT INTO human_sessions (user_id, user_name, bot_id, bot_type, session_status, login_time)
        VALUES ('t10-c', '5.10 block C', 't10-bot', 'orchestrator', 'completed', now())
    RETURNING session_id INTO v_se;
    INSERT INTO bot_actions (session_id, user_id, bot_id, action_type,
                             action_description, success)
        VALUES (v_se, 't10-c', 't10-bot', 'probe_tool', 'the record 5.10 refuses to lose', true);

    BEGIN
        DELETE FROM human_sessions WHERE session_id = v_se;
        RAISE NOTICE 'VERDICT ERR a session delete destroyed the agent actions recorded '
                     'against it - the audit trail at T10-C is gone';
    EXCEPTION WHEN foreign_key_violation THEN
        RAISE NOTICE 'VERDICT OK the session cannot be deleted while its actions exist - the '
                     'audit outlives the login that produced it';
    END;
END
$$;
ROLLBACK;

-- D. The SET NULL edge 5.10's CASCADE count never mentioned, found by measuring. A stocked
--    bin used to disappear in one of two ways depending on whether a warehouse-level row for
--    the same item already existed: silent re-home of the quantity, or a 23505 from 0004's
--    identity index arriving mid-delete. One phrase covers both halves, because both halves
--    are the same failure: the bin's own constraint said nothing.
BEGIN;
DO $$
DECLARE
    v_wh   uuid;
    v_it   uuid;
    v_lo   uuid;
    v_msg  text;
    v_ok   boolean := false;
BEGIN
    SET LOCAL app.tenant_id = '00000000-0000-0000-0000-000000000001';
    INSERT INTO warehouses (warehouse_code, name, warehouse_type)
        VALUES ('T10-D', '5.10 block D', 'PRIMARY') RETURNING warehouse_id INTO v_wh;
    INSERT INTO inventory_items (sku, name, product_type)
        VALUES ('T10-D', '5.10 item D', 'STOCKED') RETURNING item_id INTO v_it;
    INSERT INTO locations (warehouse_id, location_code, location_type)
        VALUES (v_wh, 'T10-D-1', 'STORAGE') RETURNING location_id INTO v_lo;
    INSERT INTO inventory_on_hand (item_id, warehouse_id, location_id, quantity_on_hand)
        VALUES (v_it, v_wh, v_lo, 6);

    BEGIN
        DELETE FROM locations WHERE location_id = v_lo;
        v_msg := 'the bin vanished and the stock was silently re-homed to warehouse level';
    EXCEPTION
        WHEN foreign_key_violation THEN
            v_ok := true;   -- RETURN is forbidden inside a handler; the flag is the same thing
            v_msg := 'refused';
        WHEN unique_violation THEN
            v_msg := 'the bin delete aborted inside 0004''s identity index (23505), an error '
                     'no operator could attribute to the bin';
    END;
    IF v_ok THEN
        RAISE NOTICE 'VERDICT OK the bin delete is refused by its own constraint - '
                     'inventory_on_hand_location_id_fkey answers instead of rewriting';
    ELSE
        RAISE NOTICE 'VERDICT ERR the bin delete was not refused by its own constraint: %', v_msg;
    END IF;
END
$$;
ROLLBACK;

-- E. The door RESTRICT implies. 5.10 prescribes "RESTRICT (or soft delete) with an explicit
--    close-out path"; without one, retiring a closed site becomes a scavenger hunt through
--    four tables. This asserts the path exists AND that it refuses with numbers rather than
--    succeeding quietly.
BEGIN;
DO $$
DECLARE
    v_wh   uuid;
    v_it   uuid;
    v_msg  text;
BEGIN
    IF to_regprocedure('public.decommission_warehouse(uuid)') IS NULL
       OR to_regprocedure('public.retire_item(uuid)') IS NULL THEN
        RAISE NOTICE 'VERDICT ERR no explicit close-out path exists for a warehouse or an '
                     'item - RESTRICT alone only says no (0008 adds both functions)';
        RETURN;
    END IF;

    SET LOCAL app.tenant_id = '00000000-0000-0000-0000-000000000001';
    INSERT INTO warehouses (warehouse_code, name, warehouse_type)
        VALUES ('T10-E', '5.10 block E', 'PRIMARY') RETURNING warehouse_id INTO v_wh;
    INSERT INTO inventory_items (sku, name, product_type)
        VALUES ('T10-E', '5.10 item E', 'STOCKED') RETURNING item_id INTO v_it;
    INSERT INTO inventory_on_hand (item_id, warehouse_id, quantity_on_hand)
        VALUES (v_it, v_wh, 12);

    -- E1: refuses, and says so with the real number.
    BEGIN
        PERFORM decommission_warehouse(v_wh);
        RAISE NOTICE 'VERDICT ERR decommission_warehouse accepted a warehouse holding 12 units '
                     '- the close-out path is a rename of CASCADE';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM LIKE '%unit%' AND SQLERRM LIKE '%stock row%' THEN
            -- numeric formats as 12.0000, so matching the number itself is a formatting
            -- bet; the refusal naming both units and rows is the claim.
            RAISE NOTICE 'VERDICT OK decommission_warehouse refuses while stock exists, and '
                         'quotes the quantity rather than a constraint name';
        ELSIF SQLERRM LIKE '%no explicit close-out path%' THEN
            RAISE;
        ELSE
            RAISE NOTICE 'VERDICT INFO decommission_warehouse refused, but for a reason that '
                         'did not mention the stock: %', left(SQLERRM, 90);
        END IF;
    END;

    -- E2: after the stock is legitimately zero, it closes the row out - by is_active, not by
    -- deletion, because movements will reference this warehouse forever.
    UPDATE inventory_on_hand SET quantity_on_hand = 0 WHERE item_id = v_it;
    BEGIN
        SELECT decommission_warehouse(v_wh) INTO v_msg;
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'VERDICT ERR decommission_warehouse could not close out an empty, '
                     'fully-settled warehouse: %', left(SQLERRM, 90);
        RETURN;
    END;
    IF (SELECT is_active FROM warehouses WHERE warehouse_id = v_wh) = false THEN
        RAISE NOTICE 'VERDICT OK %', v_msg;
    ELSE
        RAISE NOTICE 'VERDICT ERR decommission_warehouse ran on an empty warehouse and left '
                     'is_active true - the close-out did not close anything out';
    END IF;

    IF (SELECT count(*) FROM warehouses WHERE warehouse_id = v_wh) = 0 THEN
        RAISE NOTICE 'VERDICT ERR decommission_warehouse DELETED the warehouse row - 5.10 '
                     'asked for close-out, not for a function-shaped CASCADE';
    END IF;
END
$$;
ROLLBACK;

-- F. The retained cascade, proven to still mean composition.
--
-- Deliberately no KNOWN-OPEN row for this block: the bin cascade succeeds both before 0008
-- (it was always CASCADE) and after (retained on purpose), so a phrase here would read CLOSED
-- on a pre-0008 database through a branch that was never at risk - the same trap 0006's
-- preference assertion dodged. It is a regression guard: if the retained edge ever stops
-- cascading, this is the row that says so.
BEGIN;
DO $$
DECLARE
    v_wh uuid;
BEGIN
    SET LOCAL app.tenant_id = '00000000-0000-0000-0000-000000000001';
    IF (SELECT count(*) FROM pg_constraint
         WHERE conname = 'locations_warehouse_id_fkey' AND confdeltype <> 'c') > 0 THEN
        RAISE NOTICE 'VERDICT INFO locations_warehouse_id_fkey is no longer CASCADE - see 0008 '
                     'section 1 for why it was retained';
    END IF;
    INSERT INTO warehouses (warehouse_code, name, warehouse_type)
        VALUES ('T10-F', '5.10 block F', 'PRIMARY') RETURNING warehouse_id INTO v_wh;
    INSERT INTO locations (warehouse_id, location_code, location_type)
        VALUES (v_wh, 'T10-F-1', 'STORAGE'), (v_wh, 'T10-F-2', 'PICK');
    DELETE FROM warehouses WHERE warehouse_id = v_wh;
    IF EXISTS (SELECT 1 FROM locations WHERE warehouse_id = v_wh) THEN
        RAISE NOTICE 'VERDICT ERR the retained bin cascade regressed: empty bins survived their '
                     'warehouse, so warehouse deletion now strands structure';
    ELSE
        RAISE NOTICE 'VERDICT OK bins that nothing has ever counted against still go with the '
                     'warehouse - composition kept, and still composition';
    END IF;
END
$$;
ROLLBACK;
