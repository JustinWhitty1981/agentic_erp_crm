-- Finding 4.3: reserve_inventory_for_order crashes inside its own error handler, so
-- failures abort the caller's transaction instead of returning the documented
-- status='ERROR' row.
-- Expected on the unfixed baseline: VERDICT ERR, with a "structure of query does not
-- match function result type" context line rather than a clean ERROR row.

BEGIN;
DO $$
DECLARE
    r record;
    v_wh uuid;
BEGIN
    INSERT INTO warehouses (warehouse_code, name)
        VALUES ('AFPC-TEST-3', 'harness warehouse')
        RETURNING warehouse_id INTO v_wh;

    -- Deliberately nonexistent item: this must take the handler path.
    FOR r IN SELECT * FROM reserve_inventory_for_order(
                 '00000000-0000-0000-0000-000000000000'::uuid, v_wh, 5,
                 'sales_order', gen_random_uuid(), 'afpc_harness')
    LOOP
        RAISE NOTICE 'VERDICT OK row=% status=% message=%',
            r.reservation_id, r.status, left(r.message, 60);
    END LOOP;
    RAISE NOTICE 'VERDICT CLEAN no rows returned, no exception';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'VERDICT ERR % | %', SQLSTATE, left(SQLERRM, 140);
END
$$;
ROLLBACK;

-- Finding 4.3 (second half): a reservation writes a movement row, so the reservation
-- path re-triggers the missing-unit-of-measure defect even when stock is sufficient.
BEGIN;
DO $$
DECLARE
    v_wh uuid;
    v_item uuid;
    r record;
BEGIN
    INSERT INTO warehouses (warehouse_code, name)
        VALUES ('AFPC-TEST-3B', 'harness warehouse') RETURNING warehouse_id INTO v_wh;
    INSERT INTO inventory_items (sku, name)
        VALUES ('AFPC-TEST-3B', 'harness item') RETURNING item_id INTO v_item;
    INSERT INTO inventory_on_hand (item_id, warehouse_id, quantity_on_hand,
                                   quantity_available, quantity_reserved)
        VALUES (v_item, v_wh, 100, 100, 0);

    FOR r IN SELECT * FROM reserve_inventory_for_order(
                 v_item, v_wh, 10, 'sales_order', gen_random_uuid(), 'afpc_harness')
    LOOP
        RAISE NOTICE 'VERDICT STOCK row=% status=%', r.reservation_id, r.status;
    END LOOP;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'VERDICT ERR % | %', SQLSTATE, left(SQLERRM, 140);
END
$$;
ROLLBACK;
