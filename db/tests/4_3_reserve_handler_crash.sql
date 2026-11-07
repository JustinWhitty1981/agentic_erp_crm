-- Finding 4.3: reserve_inventory_for_order cannot return anything at all, because a bare
-- string literal in a RETURN QUERY list is `unknown`-typed and plpgsql will not coerce that
-- into a `character varying` OUT column (measured on 0015's clone: uncast literal 42804, the
-- same literal with ::varchar fine, and SQLERRM in the text position never was the problem
-- the review guessed it was).
--
-- Version-aware, because 0015 changed what the same call means. The signature is read from
-- pg_proc rather than assumed: pre-0015 the probe asks for stock the item does not have and
-- watches the function die on its own return path; post-0015 it asks the same question and
-- expects a documented status row. The second block asserts the claim 4.3's status column
-- was always meant to carry - that INSUFFICIENT_STOCK and SUCCESS are the ONLY statuses a
-- call can produce - which is a behaviour claim, and the reason no 'ERROR' status exists in
-- the fixed function either.
--
-- The fixture used to pass 'sales_order' for p_order_type, which is not a member of
-- inventory_reservations.order_type (0007 published the list; 'SALES' is the value). The
-- finding under test fired first, so the second violation stayed invisible - the same
-- masking 0014's 4_1 fixture turned out to have, and the reason the harness re-runs every
-- phrase against both pre- and post-fix databases.

BEGIN;
DO $$
DECLARE
    v_wh      uuid;
    v_item    uuid;
    v_rows    int;
    v_status  text;
    v_fixed   boolean;
    v_party   bigint;
    v_order   uuid;
BEGIN
    INSERT INTO warehouses (warehouse_code, name)
        VALUES ('AFPC-TEST-3', 'harness warehouse') RETURNING warehouse_id INTO v_wh;
    INSERT INTO inventory_items (sku, name)
        VALUES ('AFPC-TEST-3', 'harness item') RETURNING item_id INTO v_item;

    -- A real document, raised through 0028's door, because 0030's enforcement refuses a SALES
    -- commitment that names nothing. The probe used to hand the door gen_random_uuid(), which was
    -- exactly the shape that left 13 units committed forever; keeping that shape here would have made
    -- the harness the one writer of the defect the programme exists to close. Both DO blocks sit
    -- inside this file's BEGIN...ROLLBACK, so the order, its line and the counter row it allocates are
    -- residue-free by construction.
    INSERT INTO entities (name, entity_type)
        VALUES ('AFPC-TEST-3 party', 'customer') RETURNING id INTO v_party;
    SELECT order_id INTO v_order
      FROM create_order('SALES', v_party, NULL, NULL, NULL, NULL, NULL, NULL, 'MANUAL', NULL);

    SELECT EXISTS (SELECT 1 FROM pg_proc p, unnest(p.proargnames) AS a
                    WHERE p.proname = 'reserve_inventory_for_order'
                      AND a = 'p_location_id') INTO v_fixed;

    -- A warehouse that has never received the item: the refusal the review says callers
    -- code against. Pre-0015 this is where the return path itself dies.
    BEGIN
        SELECT count(*), max(status) INTO v_rows, v_status
          FROM reserve_inventory_for_order(v_item, v_wh, 5, 'SALES',
                                          v_order, 'afpc_harness');
        IF v_fixed THEN
            IF v_rows = 1 AND v_status = 'INSUFFICIENT_STOCK' THEN
                RAISE NOTICE 'VERDICT OK a refusal is a row the caller can branch on, not an '
                             'exception (4.3)';
            ELSE
                RAISE NOTICE 'VERDICT ERR 42804 | the refusal came back as % over % rows - '
                             'INSUFFICIENT_STOCK stopped being expressible', v_status, v_rows;
            END IF;
        ELSE
            RAISE NOTICE 'VERDICT OK the call survived: status % over % rows', v_status, v_rows;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = '42804' THEN
            RAISE NOTICE 'VERDICT ERR 42804 | structure of query does not match function result '
                         'type: the documented status row could not be built, so every call '
                         'path - refusal, success, error - aborted in the return (4.3)';
        ELSE
            RAISE NOTICE 'VERDICT ERR % | % - the call failed somewhere other than the return '
                         'path 4.3 describes', SQLSTATE, left(SQLERRM, 90);
        END IF;
    END;
END
$$;
ROLLBACK;

-- The statuses the door can publish. A set, because 4.3's contract is not one value: a
-- function whose error path returns a row has three outcomes, and the third is the one that
-- hides a SQLSTATE (0014 deleted that shape from the other door). Pre-0015 this block says
-- nothing, because the door could not produce any of them.
BEGIN;
DO $$
DECLARE
    v_wh      uuid;
    v_item    uuid;
    v_list    text;
    v_fixed   boolean;
BEGIN
    SELECT EXISTS (SELECT 1 FROM pg_proc p, unnest(p.proargnames) AS a
                    WHERE p.proname = 'reserve_inventory_for_order'
                      AND a = 'p_location_id') INTO v_fixed;
    IF NOT v_fixed THEN
        RAISE NOTICE 'VERDICT OK 4.3''s status set is untestable before 0015: the door '
                     'publishes none of them (see the block above)';
        RETURN;
    END IF;

    INSERT INTO warehouses (warehouse_code, name)
        VALUES ('AFPC-TEST-3B', 'harness warehouse') RETURNING warehouse_id INTO v_wh;
    INSERT INTO inventory_items (sku, name)
        VALUES ('AFPC-TEST-3B', 'harness item') RETURNING item_id INTO v_item;

    -- One success, one refusal, and an error path that must not be a row.
    PERFORM execute_inventory_movement('RECEIPT', v_item, NULL, v_wh, 50, 2,
             'afpc_harness', 'PO', NULL, 'stock for the status probe');
    SELECT string_agg(DISTINCT s, ',' ORDER BY s) INTO v_list FROM (
        SELECT max(status) AS s FROM reserve_inventory_for_order(
                   v_item, v_wh, 5, 'SALES', v_order, 'afpc_harness')
        UNION ALL
        SELECT max(status) FROM reserve_inventory_for_order(
                   v_item, v_wh, 99999, 'SALES', v_order, 'afpc_harness')
    ) x;
    IF v_list = 'INSUFFICIENT_STOCK,SUCCESS' THEN
        RAISE NOTICE 'VERDICT OK the door publishes exactly the two documented statuses';
    ELSE
        RAISE NOTICE 'VERDICT ERR the reservation door publishes % - 4.3 is closed only if the '
                     'vocabulary of its status column stays the two business outcomes', v_list;
    END IF;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'VERDICT ERR % | the status probe itself failed: %',
        SQLSTATE, left(SQLERRM, 90);
END
$$;
ROLLBACK;
