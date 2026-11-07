-- Development reference data for the inventory agent. Data only: db/README is explicit that a seed
-- file containing DDL is how the schema forked once already, and this file creates no function,
-- not even a helper - the door calls are EXECUTE'd positionally rather than wrapped, because a
-- CREATE FUNCTION here would be the DDL this directory's one rule forbids.
--
-- Re-runnable by contract. Every master-data row is guarded on the natural key that identifies it
-- (warehouse_code, category_code, sku), and every movement on `performed_by`, the column the door
-- records the caller in - because an ON CONFLICT cannot wrap a function call, and a door that
-- refused the seed's second RECEIPT as a duplicate business event would be *right* to.
--
-- Stock is written through execute_inventory_movement and nothing else, which is the point: the
-- receipt/issue ledger creates the on_hand rows (the door upserts them), the consistency trigger
-- keeps available = on_hand - reserved, and the 30-day velocity the agent reads from
-- vw_item_movement_summary is real movement history rather than a number pasted into a column.
-- A broken movement door fails this seed rather than surfacing later as an availability report
-- that disagrees with the ledger. The direct INSERTs are warehouses and items - master data no
-- door exists to create (the write-path scan finds no function that touches inventory_items),
-- which is stated here because 0022's clock claim depends on the seed's writes being visible.
--
-- The tenant is named explicitly even though init.sh mirrors app.default_tenant_id, for 01's
-- reason: a seed that relies on the fallback writes into whatever tenant the server last
-- defaulted to.

SET client_min_messages TO notice;

SELECT set_config('app.tenant_id',
    (SELECT tenant_id::text FROM tenants WHERE slug = 'default'), false);

-- ---------------------------------------------------------------------------
-- 1. Warehouses - one main building and one regional, so every availability
--    question has a per-warehouse shape rather than a single answer.
-- ---------------------------------------------------------------------------
INSERT INTO warehouses (warehouse_code, name, warehouse_type, city, country, timezone,
                        default_warehouse, is_active)
SELECT v.code, v.name, v.wtype, v.city, 'US', 'America/Chicago', v.dflt, true
  FROM (VALUES ('MAIN', 'Main Warehouse', 'PRIMARY', 'Austin', true),
               ('EAST', 'East Distribution', 'SECONDARY', 'Atlanta', false))
       AS v(code, name, wtype, city, dflt)
 WHERE NOT EXISTS (SELECT 1 FROM warehouses w WHERE w.warehouse_code = v.code);

-- ---------------------------------------------------------------------------
-- 2. Categories
-- ---------------------------------------------------------------------------
INSERT INTO item_categories (category_code, name, default_cost_method,
                             default_reorder_point, default_safety_stock)
SELECT v.code, v.name, v.cm, v.rp, v.ss
  FROM (VALUES ('PARTS', 'Parts', 'STANDARD', 30, 8),
               ('CONSUM', 'Consumables', 'AVERAGE', 100, 25),
               ('FG', 'Finished Goods', 'STANDARD', 15, 5))
       AS v(code, name, cm, rp, ss)
 WHERE NOT EXISTS (SELECT 1 FROM item_categories c WHERE c.category_code = v.code);

-- ---------------------------------------------------------------------------
-- 3. Items. Ten, each in a situation the read paths must be able to tell apart:
--    healthy, borderline, low, critical, nearly out with a lead time that makes
--    it worse, fast-moving, slow-moving, an assembly, a service with no stock
--    at all, and one item nobody has ever moved - velocity unknown, not zero.
-- ---------------------------------------------------------------------------
INSERT INTO inventory_items (sku, name, description, category_id, product_type,
                             base_unit_of_measure, cost_method, standard_cost,
                             currency_code, reorder_point, reorder_quantity,
                             safety_stock, lead_time_days, order_multiple, is_active)
SELECT v.sku, v.name, v.descr,
       (SELECT category_id FROM item_categories WHERE category_code = v.cat),
       v.ptype, 'EACH', v.cm, v.cost, 'USD', v.rp, v.rq, v.ss, v.lead, v.mult, true
  FROM (VALUES
    ('IN-1000', '12V Battery Pack',        'Sealed maintenance-free battery.',        'PARTS',  'STOCKED',  'STANDARD',  84.00,  40, 100, 10,  7,  1),
    ('IN-1001', 'Oil Filter Cartridge',    'Spin-on, standard grade.',                'CONSUM', 'STOCKED',  'AVERAGE',    6.50, 100, 300, 25,  5, 12),
    ('IN-1002', 'Brake Rotor 320mm',       'Vented front rotor.',                     'PARTS',  'STOCKED',  'STANDARD', 120.00,  30,  50,  8, 14,  1),
    ('IN-1003', 'Coolant 5L Jerrican',     'Long-life premix.',                       'CONSUM', 'STOCKED',  'AVERAGE',   22.00,  60, 200, 15,  3,  4),
    ('IN-1004', 'Air Filter Panel',        'Panel filter, generic fit.',              'PARTS',  'STOCKED',  'STANDARD',   9.00,  50, 150, 12,  7, 10),
    ('IN-1005', 'Diagnostic Session (2h)', 'Booked labour, no stock.',                'PARTS',  'SERVICE',  'STANDARD',  0.00, NULL,NULL,NULL,NULL,1),
    ('IN-1006', 'Wheel Bearing Kit',       'Hub and bearing, per corner.',            'PARTS',  'STOCKED',  'STANDARD',  64.00,  25,  40,  6, 10,  1),
    ('IN-1007', 'Workbench Task Lamp',     'Assembled on site from parts.',           'FG',     'ASSEMBLY', 'STANDARD',  45.00,   8,  20,  2, 21,  1),
    ('FG-2000', 'Service Kit A',           'Filter, fluids, gaskets, boxed.',         'FG',     'ASSEMBLY', 'STANDARD',  55.00,  15,  30,  5,  5,  1),
    ('CON-3000', 'Shop Towel Case',        'Blue shop towel, 6-roll case.',           'CONSUM', 'STOCKED',  'AVERAGE',   14.00, 200, 400, 40,  2,  1)
  ) AS v(sku, name, descr, cat, ptype, cm, cost, rp, rq, ss, lead, mult)
 WHERE NOT EXISTS (SELECT 1 FROM inventory_items i WHERE i.sku = v.sku);

-- ---------------------------------------------------------------------------
-- 4. Stock history, through the movement door.
--
-- Receipts first, then issues backdated across the window so that
-- vw_item_movement_summary's 30-day velocity is a measurement rather than a
-- constant, and the items land at the on-hand quantities section 3's thresholds
-- describe. The UPDATE that backdates performed_at is the same visible exception
-- 01 declares: the door stamps now() and no door argument changes that, and
-- seeding everything on one day would leave the trend half of the agent with
-- nothing true to find.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_mid   uuid;
    v_main  uuid;
    v_east  uuid;
    v_item  uuid;
    v_ord   uuid;   -- the order 0030's enforcement now requires a commitment to name
    v_line  uuid;   -- ... and the line 0030's view needs for the commitment to say something
    r       record;
BEGIN
    IF EXISTS (SELECT 1 FROM inventory_movements
                WHERE performed_by = 'seed:02_demo_inventory') THEN
        RAISE NOTICE 'inventory seed: stock history already present, skipping';
        RETURN;
    END IF;

    SELECT warehouse_id INTO v_main FROM warehouses WHERE warehouse_code = 'MAIN';
    SELECT warehouse_id INTO v_east FROM warehouses WHERE warehouse_code = 'EAST';

    -- RECEIPT(item sku, qty, unit_cost, warehouse, days ago)
    FOR r IN SELECT * FROM (VALUES
        ('IN-1000',  60,  84.00, 'MAIN', 28),
        ('IN-1001', 180,   6.50, 'MAIN', 28),
        ('IN-1002',  34, 120.00, 'MAIN', 26),
        ('IN-1003', 400,  22.00, 'MAIN', 25),
        ('IN-1003',  80,  22.00, 'EAST', 24),
        ('IN-1004', 120,   9.00, 'MAIN', 25),
        ('IN-1006',  55,  64.00, 'MAIN', 23),
        ('IN-1007',  30,  45.00, 'MAIN', 21),
        ('FG-2000',  75,  55.00, 'MAIN', 20),
        ('CON-3000',300,  14.00, 'MAIN', 20)
    ) AS t(sku, qty, cost, wh, ago) LOOP
        SELECT item_id INTO v_item FROM inventory_items WHERE sku = r.sku;
        EXECUTE format(
            'SELECT execute_inventory_movement(''RECEIPT'', $1, NULL, $2, $3, $4,
             $5, $6, $7, NULL, ''EACH'')')
          INTO v_mid
          USING v_item,
                CASE WHEN r.wh = 'MAIN' THEN v_main ELSE v_east END,
                r.qty, r.cost, 'seed:02_demo_inventory', 'PO', afpc_uuid_v7();
        UPDATE inventory_movements SET performed_at = now() - make_interval(days => r.ago)
          WHERE movement_id = v_mid;
    END LOOP;

    -- ISSUE(item sku, qty, warehouse, days ago) - totals leave each item where
    -- section 3's reorder_point says it should be: IN-1000 at 12, IN-1002 at 4,
    -- CON-3000 at 95, and so on.
    FOR r IN SELECT * FROM (VALUES
        ('IN-1000', 16, 'MAIN', 21), ('IN-1000', 18, 'MAIN', 12), ('IN-1000', 14, 'MAIN', 4),
        ('IN-1001', 46, 'MAIN', 19), ('IN-1001', 46, 'MAIN', 6),
        ('IN-1002', 15, 'MAIN', 17), ('IN-1002', 15, 'MAIN', 3),
        ('IN-1003', 64, 'MAIN', 20), ('IN-1003', 65, 'MAIN', 11), ('IN-1003', 57, 'MAIN', 2),
        ('IN-1003', 20, 'EAST', 9),
        ('IN-1004', 69, 'MAIN', 13),
        ('IN-1006', 46, 'MAIN', 15),
        ('IN-1007', 16, 'MAIN', 10),
        ('FG-2000', 35, 'MAIN', 8),
        ('CON-3000', 41, 'MAIN', 18), ('CON-3000', 41, 'MAIN', 13),
        ('CON-3000', 41, 'MAIN',  8), ('CON-3000', 41, 'MAIN',  4), ('CON-3000', 41, 'MAIN', 1)
    ) AS t(sku, qty, wh, ago) LOOP
        SELECT item_id INTO v_item FROM inventory_items WHERE sku = r.sku;
        EXECUTE format(
            'SELECT execute_inventory_movement(''ISSUE'', $1, $2, NULL, $3, NULL,
             $4, $5, $6, NULL, ''EACH'')')
          INTO v_mid
          USING v_item,
                CASE WHEN r.wh = 'MAIN' THEN v_main ELSE v_east END,
                r.qty, 'seed:02_demo_inventory', 'ORDER', afpc_uuid_v7();
        UPDATE inventory_movements SET performed_at = now() - make_interval(days => r.ago)
          WHERE movement_id = v_mid;
    END LOOP;

    -- One live commitment, through the reservation door, so quantity_available
    -- and quantity_on_hand differ somewhere and the agent has to know why.
    --
    -- Raised through create_order and add_order_line first, and that is 0030's enforcement talking
    -- and not decoration: reserve_inventory_for_order now refuses a document type whose order_id
    -- names nothing, and this block used to hand it afpc_uuid_v7() out of thin air. The seed is the
    -- one writer that runs on a from-zero database after every migration, so a commitment that
    -- resolves is the only shape this file can take. Before 0030 the id it invented became one of
    -- the four dangling rows 0030 §3 had to backfill, which is the whole story of the leak in one
    -- line of seed.
    IF NOT EXISTS (SELECT 1 FROM inventory_reservations
                    WHERE reserved_by = 'seed:02_demo_inventory') THEN
        SELECT item_id INTO v_item FROM inventory_items WHERE sku = 'IN-1003';
        SELECT order_id INTO v_ord
          FROM create_order('SALES',
                            (SELECT id FROM vw_customers WHERE name = 'Delta Manufacturing Co'),
                            NULL, v_main, NULL, NULL, NULL,
                            'seed: a customer order awaiting shipment', 'MANUAL', NULL);
        SELECT order_line_id INTO v_line
          FROM add_order_line(v_ord, v_item, NULL, 5, 40, NULL, 'STANDARD', v_main,
                              NULL, NULL, NULL, NULL);
        -- The line is passed so the commitment is ATTRIBUTED and not merely addressed: 0030's
        -- vw_order_commitments can then show these 5 units against the line they hold, which is the
        -- difference between a demo database that exercises the read path and one that merely
        -- contains the rows.
        PERFORM * FROM reserve_inventory_for_order(
            v_item, v_main, 5, 'SALES', v_ord, 'seed:02_demo_inventory', NULL, NULL, v_line);
    END IF;

    RAISE NOTICE 'inventory seed: stock history created through the doors';
END
$$;
