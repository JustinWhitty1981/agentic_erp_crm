-- Finding 4.1: execute_inventory_movement cannot insert a movement.
-- The signature has 10 parameters and never mentions a unit of measure, while
-- inventory_movements.unit_of_measure is NOT NULL with no default.
-- Expected on the unfixed baseline: VERDICT ERR P0001 (the wrapper re-raises the
-- original 23502 not-null violation, discarding its SQLSTATE).
--
-- Fixed by 0014, one correction to the fixture itself: reference_type said 'purchase_order',
-- which is not in 0007's vocabulary ('PO' is). The 23502 always fired before the CHECK could
-- be evaluated - NOT NULL is a cheaper gate - so the fixture carried a second, invisible
-- violation. Pre-0014 output is unchanged by the fix (measured: still 23502->P0001 first);
-- post-0014, both the unit and the code are now legal, and the movement succeeds via the
-- item's base_unit_of_measure - which is what the OK line below actually claims.

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
        'afpc_harness', 'PO', NULL, 'baseline probe');

    RAISE NOTICE 'VERDICT OK movement accepted without a unit of measure';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'VERDICT ERR % | %', SQLSTATE, left(SQLERRM, 120);
END
$$;
ROLLBACK;
