-- Finding 4.2: the on-hand upsert's ON CONFLICT target does not exist.
-- inventory_on_hand has no unique constraint beyond its primary key, so the
-- arbiter used inside execute_inventory_movement cannot be satisfied. This probes
-- the arbiter in isolation, so it stays red even after 4.1 is fixed.
-- Expected on the unfixed baseline: VERDICT ERR 42P10.
--
-- The arbiter below gained tenant_id when 0004 introduced the tenant-scoped identity:
-- an ON CONFLICT target must list an index's key columns exactly and in order, so a
-- 4-column target can never infer into a 5-column unique. db/tests/0_0_conflict_inference
-- _rule.sql establishes that rule by experiment; change this in step with the index.

BEGIN;
DO $$
DECLARE
    v_wh uuid;
    v_item uuid;
BEGIN
    INSERT INTO warehouses (warehouse_code, name)
        VALUES ('AFPC-TEST-2', 'harness warehouse')
        RETURNING warehouse_id INTO v_wh;
    INSERT INTO inventory_items (sku, name)
        VALUES ('AFPC-TEST-2', 'harness item')
        RETURNING item_id INTO v_item;

    INSERT INTO inventory_on_hand (item_id, warehouse_id, quantity_on_hand,
                                   quantity_available, quantity_reserved)
    VALUES (v_item, v_wh, 10, 10, 0)
    ON CONFLICT (item_id, warehouse_id,
                 COALESCE(location_id, '00000000-0000-0000-0000-000000000000'::uuid),
                 COALESCE(lot_number, ''), tenant_id)
    DO UPDATE SET quantity_on_hand = inventory_on_hand.quantity_on_hand + 10;

    RAISE NOTICE 'VERDICT OK upsert arbiter resolved';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'VERDICT ERR % | %', SQLSTATE, left(SQLERRM, 120);
END
$$;

-- The same defect seen from the other side: nothing stops duplicate stock rows for
-- one item/warehouse, which is what makes balance queries ambiguous.
DO $$
DECLARE
    v_wh uuid;
    v_item uuid;
    n int;
BEGIN
    INSERT INTO warehouses (warehouse_code, name)
        VALUES ('AFPC-TEST-2B', 'harness warehouse')
        RETURNING warehouse_id INTO v_wh;
    INSERT INTO inventory_items (sku, name)
        VALUES ('AFPC-TEST-2B', 'harness item')
        RETURNING item_id INTO v_item;

    INSERT INTO inventory_on_hand (item_id, warehouse_id, quantity_on_hand,
                                   quantity_available, quantity_reserved)
    SELECT v_item, v_wh, 5, 5, 0 FROM generate_series(1, 3);
    SELECT count(*) INTO n FROM inventory_on_hand WHERE item_id = v_item AND warehouse_id = v_wh;

    IF n > 1 THEN
        RAISE NOTICE 'VERDICT ERR 00000 | % duplicate stock rows accepted for one item/warehouse', n;
    ELSE
        RAISE NOTICE 'VERDICT OK row identity enforced';
    END IF;
END
$$;
ROLLBACK;
