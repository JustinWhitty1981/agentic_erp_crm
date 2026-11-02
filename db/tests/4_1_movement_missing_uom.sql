-- Finding 4.1: execute_inventory_movement cannot insert a movement.
-- The signature has 10 parameters and never mentions a unit of measure, while
-- inventory_movements.unit_of_measure is NOT NULL with no default.
-- Expected on the unfixed baseline: VERDICT ERR P0001 (the wrapper re-raises the
-- original 23502 not-null violation, discarding its SQLSTATE).

BEGIN;
DO $$
DECLARE
    v_wh uuid;
    v_item uuid;
BEGIN
    INSERT INTO warehouses (warehouse_code, name)
        VALUES ('AFPC-TEST-1', 'harness warehouse')
        RETURNING warehouse_id INTO v_wh;
    INSERT INTO inventory_items (sku, name)
        VALUES ('AFPC-TEST-1', 'harness item')
        RETURNING item_id INTO v_item;

    PERFORM execute_inventory_movement(
        'RECEIPT', v_item, NULL, v_wh, 10, 5.00,
        'afpc_harness', 'purchase_order', NULL, 'baseline probe');

    RAISE NOTICE 'VERDICT OK movement accepted without a unit of measure';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'VERDICT ERR % | %', SQLSTATE, left(SQLERRM, 120);
END
$$;
ROLLBACK;
