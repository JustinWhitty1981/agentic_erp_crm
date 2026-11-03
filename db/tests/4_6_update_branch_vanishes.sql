-- Finding 4.2, the half that identity constraints cannot fix.
--
-- execute_inventory_movement's ISSUE/ADJUSTMENT branch is
--
--     UPDATE inventory_on_hand
--        SET quantity_on_hand = quantity_on_hand - p_quantity, last_movement_at = NOW()
--      WHERE item_id = p_item_id AND warehouse_id = p_from_warehouse_id;
--
-- with no assertion on the row count. Migration 0004 makes at most one row match that
-- predicate, which is a strict improvement - but "at most one" includes none, and an
-- issue against a warehouse that has never received the item updates zero rows, decrements
-- nothing, and returns a movement id as if stock had moved. The ledger then records an
-- ISSUE that no balance reflects.
--
-- This is a different defect from the missing ON CONFLICT arbiter, so it gets its own
-- row in the scoreboard rather than being credited to 0004. The fix belongs with the
-- function rewrite in 0014: raise on ROW_COUNT = 0, or write a negative on-hand row and
-- let a CHECK reject it, which is the behaviour an ERP ledger should have.
--
-- The INSERT-of-a-movement path WAS avoided here: it still failed on the 4.1
-- unit_of_measure defect, and calling the function would have read a 23502 as the hole
-- being closed for the wrong reason. 0014 closes 4.1, which retires that constraint - so
-- the file now reads the signature from pg_proc and runs the real call once the function
-- can reach its ISSUE branch (0010's probe-E repoint obligation, applied at the call site
-- the ledger belongs to). Pre-0014 databases run exactly the old statement probe;
-- post-0014 they also see the stronger property the statement form could not express: a
-- refused issue leaves no ledger row.

BEGIN;
DO $$
DECLARE
    v_wh      uuid;
    v_item    uuid;
    v_before  int;
    v_after   int;
    v_touch   int;
    v_fixed   boolean;
BEGIN
    INSERT INTO warehouses (warehouse_code, name)
        VALUES ('AFPC-TEST-6', 'harness warehouse') RETURNING warehouse_id INTO v_wh;
    INSERT INTO inventory_items (sku, name)
        VALUES ('AFPC-TEST-6', 'harness item') RETURNING item_id INTO v_item;

    -- Deliberately no inventory_on_hand row: this is an issue against a warehouse that
    -- has never received the item.
    SELECT count(*) INTO v_before FROM inventory_on_hand
     WHERE item_id = v_item AND warehouse_id = v_wh;

    SELECT EXISTS (SELECT 1 FROM pg_proc p, unnest(p.proargnames) AS a
                    WHERE p.proname = 'execute_inventory_movement'
                      AND a = 'p_unit_of_measure') INTO v_fixed;

    IF NOT v_fixed THEN
        -- The statement the function's ISSUE branch executes, taken literally, because
        -- pre-0014 the function never reaches it (header above).
        UPDATE inventory_on_hand
           SET quantity_on_hand = quantity_on_hand - 5
         WHERE item_id = v_item AND warehouse_id = v_wh;
        GET DIAGNOSTICS v_touch = ROW_COUNT;

        IF v_touch = 0 THEN
            RAISE NOTICE 'VERDICT ERR 00000 | phantom issue: the UPDATE matched % rows and '
                         'decremented nothing, yet the function returns a movement id - the '
                         'ledger records an ISSUE no balance reflects', v_touch;
        ELSE
            RAISE NOTICE 'VERDICT INFO the stock UPDATE matched % row(s)', v_touch;
        END IF;
    ELSE
        BEGIN
            PERFORM execute_inventory_movement(
                'ISSUE', v_item, v_wh, NULL, 5, 5.00,
                'afpc_harness', 'ORDER', NULL, 'phantom probe');
            RAISE NOTICE 'VERDICT ERR 00000 | phantom issue: the call returned a movement id '
                         'after matching no stock row - the ledger records an ISSUE no '
                         'balance reflects';
        EXCEPTION WHEN OTHERS THEN
            IF (SELECT count(*) FROM inventory_movements WHERE item_id = v_item) <> 0 THEN
                RAISE NOTICE 'VERDICT ERR % | phantom issue: the call refused, yet its ledger '
                             'row survived the refusal - an ISSUE no balance reflects', SQLSTATE;
            ELSE
                RAISE NOTICE 'VERDICT OK the zero-stock issue was refused (SQLSTATE %), and '
                             'the ledger row it had already written went back with it', SQLSTATE;
            END IF;
        END;
    END IF;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'VERDICT ERR % | the probe itself failed, which says nothing about the '
                 'phantom issue: %', SQLSTATE, left(SQLERRM, 100);
END
$$;
ROLLBACK;

-- Second half of the same blind spot, and it turns out to be the worse half. The predicate
-- is not location-aware, so once 0004's identity lets per-bin rows coexist, an ISSUE against
-- a warehouse holding stock in two bins decrements EVERY bin by the full quantity. Measured,
-- not reasoned: two bins of 10, one issue of 5, 10 units left on the books. This is not an
-- ambiguous pick, it is a wrong balance, and it is a new finding beyond what review 4.2
-- described - the review's concern was duplicates; the fix for duplicates makes this one
-- reachable.
--
-- Version-aware, because the honest post-0015 claim is a different one. The statement probe
-- below is the function's WHERE clause taken literally, and a literal copy of an OLD clause
-- still misbehaves forever no matter what the function does now - so post-0015 the file asks
-- the door instead, and the claim becomes the arithmetic: a movement of 5 leaves exactly 15,
-- drawn in pick order. Pre-0015 keeps the statement form for exactly the reason 4_6 was
-- written that way (0014 was not yet applied and the call could not reach its ISSUE branch).
BEGIN;
DO $$
DECLARE
    v_wh    uuid;
    v_item  uuid;
    v_a     uuid;
    v_b     uuid;
    v_touched int;
    v_left    numeric;
    v_fixed   boolean;
BEGIN
    INSERT INTO warehouses (warehouse_code, name)
        VALUES ('AFPC-TEST-6B', 'harness warehouse') RETURNING warehouse_id INTO v_wh;
    INSERT INTO inventory_items (sku, name)
        VALUES ('AFPC-TEST-6B', 'harness item') RETURNING item_id INTO v_item;
    -- No name column: locations is identified by warehouse_id + location_code. Two rows
    -- in one statement, so RETURNING cannot feed INTO directly (P0003: query returned
    -- more than one row) - the ids are read back instead.
    INSERT INTO locations (warehouse_id, location_code) VALUES (v_wh, 'BIN-A'), (v_wh, 'BIN-B');
    SELECT location_id INTO v_a FROM locations WHERE warehouse_id = v_wh AND location_code = 'BIN-A';
    SELECT location_id INTO v_b FROM locations WHERE warehouse_id = v_wh AND location_code = 'BIN-B';

    INSERT INTO inventory_on_hand (item_id, warehouse_id, location_id,
                                  quantity_on_hand, quantity_available, quantity_reserved)
        VALUES (v_item, v_wh, v_a, 10, 10, 0), (v_item, v_wh, v_b, 10, 10, 0);

    SELECT EXISTS (SELECT 1 FROM pg_proc p, unnest(p.proargnames) AS a
                    WHERE p.proname = 'execute_inventory_movement'
                      AND a = 'p_from_location_id') INTO v_fixed;

    IF NOT v_fixed THEN
        -- Exactly the statement the function issues, location omitted from the WHERE.
        WITH taken AS (
            UPDATE inventory_on_hand
               SET quantity_on_hand = quantity_on_hand - 5
             WHERE item_id = v_item AND warehouse_id = v_wh
            RETURNING location_id
        )
        SELECT count(DISTINCT location_id) INTO v_touched FROM taken;
    ELSE
        -- Post-0015: the same claim at the door, measured as which bins actually changed,
        -- not as a restatement of the new WHERE clause inside the test file. An issue of 5
        -- from a warehouse holding 10 in each of two bins drains ONE bin.
        PERFORM execute_inventory_movement('ISSUE', v_item, v_wh, NULL, 5, 5,
                 'afpc_harness', 'ORDER', NULL, 'two-bin issue probe');
        SELECT count(DISTINCT location_id) INTO v_touched
          FROM inventory_on_hand
         WHERE item_id = v_item AND warehouse_id = v_wh AND quantity_on_hand <> 10;
    END IF;

    IF v_touched > 1 THEN
        -- Not "it picked one bin arbitrarily", which is what this probe was written to
        -- confirm. It decremented EVERY bin in the warehouse by the full quantity, so a
        -- movement of 5 removes 10 units of stock across the ledger. That is a wrong
        -- balance, not an ambiguous one, and it is strictly worse than the read the
        -- review anticipated.
        RAISE NOTICE 'VERDICT ERR 00000 | a warehouse-wide issue touched % of % bins: the '
                     'full quantity was deducted from each, leaving % units on the books '
                     'for a movement of 5',
            v_touched,
            (SELECT count(*) FROM inventory_on_hand WHERE item_id = v_item),
            (SELECT coalesce(sum(quantity_on_hand), 0)
              FROM inventory_on_hand WHERE item_id = v_item);
    ELSIF v_touched = 0 THEN
        RAISE NOTICE 'VERDICT ERR 00000 | the deduction reached no bin at all - the movement '
                     'is a ledger row with no balance behind it';
    ELSE
        RAISE NOTICE 'VERDICT OK the issue resolved exactly one bin';
    END IF;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'VERDICT ERR % | %', SQLSTATE, left(SQLERRM, 90);
END
$$;
ROLLBACK;
