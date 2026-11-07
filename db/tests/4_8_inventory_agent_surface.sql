-- The inventory agent's surface, one block per thing its tools claim.
--
-- This is the probe the customer service agent's 4_7 is for the CRM: it fails the day a door or a
-- view stops meaning what agents/inventory/backend_go/pkg/inventory/tools.go says it means.
-- The blocks differ in what closes them, which is why they are stated separately rather than as
-- one verdict:
--
--   8a  the reservation door's ledger row: the three trailing values against the three trailing
--       columns. 0026's finding, found by db/seeds/02_demo_inventory.sql attempting the first
--       successful reservation since 0018 rotated them, and reproduced here in permanently:
--       the mapped phrase fires when a future patch puts a value in the wrong column again.
--   8b  the door's signature: the claim's POSITION, the tool's Call relies on, and the OUT
--       columns the tool reads by name. Closed by 0015; a rename or reordering fires it.
--   8c  the four views' projected columns - the lists tools.go and check.go SELECT by name.
--       Deliberately UNMAPPED in the harness's CASES table: unlike 8a and 8b there is no past
--       finding it credits, it guards a future one, and on the day it fires the fix is whatever
--       migration renamed the column, which is the row to add then. Until then its verdict is
--       printed by the harness's raw section and read by whoever runs it, which is the most any
--       forward-looking assertion honestly earns.
--
-- Each block prints its mapped phrase from an existence guard FIRST, so a database predating the
-- fix says KNOWN-OPEN rather than SURPRISE (dev/README's rule for phrases only reachable after).

BEGIN;

-- ---------------------------------------------------------------------------
-- 8a. the ledger row's positions, exercised through the door itself
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_wh     uuid;
    v_item   uuid;
    v_order  uuid;
    v_status text;
    v_ref_t  text;
    v_ref_i  uuid;
    v_cur    text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'reserve_inventory_for_order') THEN
        RAISE NOTICE 'VERDICT ERR 0026 | there is no reservation door at all';
        RETURN;
    END IF;

    INSERT INTO warehouses (warehouse_code, name)
         VALUES ('AFPC-TEST-8A', 'harness warehouse') RETURNING warehouse_id INTO v_wh;
    INSERT INTO inventory_items (sku, name)
         VALUES ('AFPC-TEST-8A', 'harness item') RETURNING item_id INTO v_item;
    PERFORM execute_inventory_movement('RECEIPT', v_item, NULL, v_wh, 10, 2,
             'afpc_harness', 'PO', NULL, NULL, 'EACH');

    -- 0030 makes a commitment name a document, so the harness raises one. An invented uuid is no
    -- longer a value this door accepts, which is the finding rather than an obstacle: the surface
    -- probe that checks the reservation door works must itself hold a real order.
    INSERT INTO entities (name, entity_type)
        VALUES ('AFPC-TEST-8 party', 'customer');
    SELECT order_id INTO v_order
      FROM create_order('SALES', (SELECT id FROM entities WHERE name = 'AFPC-TEST-8 party'),
                        NULL, NULL, NULL, NULL, NULL, NULL, 'MANUAL', NULL);
    BEGIN
        SELECT max(status) INTO v_status
          FROM reserve_inventory_for_order(v_item, v_wh, 3, 'SALES', v_order, 'afpc_harness');
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'VERDICT ERR 0026 | the reservation door''s ledger values sit in the wrong '
                     'columns: the SUCCESS path dies with % - %', SQLSTATE, left(SQLERRM, 80);
        RETURN;
    END;

    IF v_status <> 'SUCCESS' THEN
        RAISE NOTICE 'VERDICT ERR 8a | the door answered % where it must answer SUCCESS - the '
                     'fixture is wrong before the finding can be judged', v_status;
        RETURN;
    END IF;

    SELECT m.reference_type, m.reference_id, m.currency_code
      INTO v_ref_t, v_ref_i, v_cur
      FROM inventory_movements m
     WHERE m.movement_type = 'RESERVATION' AND m.item_id = v_item;

    IF v_ref_t IS DISTINCT FROM 'ORDER' OR v_ref_i IS DISTINCT FROM v_order
       OR v_cur IS DISTINCT FROM 'USD' THEN
        RAISE NOTICE 'VERDICT ERR 0026 | the reservation door''s ledger values sit in the wrong '
                     'columns: reference_type=% reference_id=% currency=% - the ORDER, the order, '
                     'and the currency each belong in the NEXT column over',
            coalesce(v_ref_t, 'NULL'), coalesce(v_ref_i::text, 'NULL'), coalesce(v_cur, 'NULL');
    ELSE
        RAISE NOTICE 'VERDICT OK 8a a successful reservation writes its ledger row with every '
                     'value under the column that names it';
    END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- 8b. the signature the tool's positional Call is written against
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_names text[];
    v_outs  text;
BEGIN
    -- INPUT parameters only, in order: proargnames carries the TABLE(...) OUT columns too, and
    -- a check that counted them would report 11 for a door with eight arguments - the probe
    -- failing its own signature reading rather than the tool's claim.
    SELECT array_agg(g.a ORDER BY g.n) INTO v_names
      FROM (SELECT p.proargnames, p.proargmodes FROM pg_proc p
             WHERE p.proname = 'reserve_inventory_for_order') s,
           unnest(s.proargnames, s.proargmodes) WITH ORDINALITY AS g(a, mode, n)
     WHERE mode IS NULL OR mode::text IN ('i', 'b');
    IF v_names IS NULL OR array_length(v_names, 1) <> 8
       OR v_names[8] <> 'p_idempotency_key' OR v_names[7] <> 'p_location_id' THEN
        RAISE NOTICE 'VERDICT ERR 4.3 | the reservation door''s parameter positions are not what '
                     'reserve_inventory calls them as: % - the tool sends eight positional '
                     'arguments and the claim last', coalesce(v_names::text, 'no signature');
    ELSE
        RAISE NOTICE 'VERDICT OK 8b the door takes the location then the claim, which is the '
                     'order the tool''s Call array is built in';
    END IF;

    SELECT pg_get_function_result(p.oid) INTO v_outs
      FROM pg_proc p WHERE p.proname = 'reserve_inventory_for_order';
    IF v_outs NOT LIKE 'TABLE(reservation_id uuid, status character varying, message text)' THEN
        RAISE NOTICE 'VERDICT ERR 4.3 | the reservation door answers % - the tool reads '
                     'reservation_id, status and message BY NAME', v_outs;
    ELSE
        RAISE NOTICE 'VERDICT OK 8b the door publishes reservation_id, status and message, which '
                     'are the keys the tool reports';
    END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- 8c. every column the agent's SQL names, view by view
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_miss text := '';
    v_gaps text;
    v_pair record;
BEGIN
    FOR v_pair IN
        SELECT * FROM (VALUES
            ('vw_low_stock_alerts', ARRAY['item_id','sku','name','warehouse_id','warehouse_name',
                'quantity_on_hand','quantity_available','quantity_in_transit',
                'reorder_point','safety_stock','lead_time_days','alert_level','stock_percentage']),
            ('vw_item_availability', ARRAY['item_id','sku','name','warehouse_id','warehouse_name','location_code',
                'quantity_on_hand','quantity_available','quantity_reserved','quantity_in_transit',
                'reorder_point','safety_stock','stock_status','needs_reorder','average_cost',
                'cost_currency']),
            ('vw_item_movement_summary', ARRAY['item_id','movement_date','movement_type',
                'net_quantity','movement_count','avg_unit_cost','total_inbound','total_outbound']),
            ('vw_inventory_valuation', ARRAY['warehouse_name','category_name','currency_code',
                'unique_items','total_units','total_value','available_value'])
        ) AS v(view_name, cols)
    LOOP
        IF to_regclass(v_pair.view_name) IS NULL THEN
            v_miss := v_miss || ' ' || v_pair.view_name || '(gone)';
            CONTINUE;
        END IF;

        SELECT string_agg(c.name, ' ') INTO v_gaps
          FROM unnest(v_pair.cols) AS c(name)
         WHERE NOT EXISTS (
            SELECT 1 FROM pg_attribute a
             WHERE a.attrelid = v_pair.view_name::regclass
               AND a.attname = c.name AND a.attnum > 0 AND NOT a.attisdropped);

        IF v_gaps IS NOT NULL THEN
            v_miss := v_miss || ' ' || v_pair.view_name || ': ' || v_gaps;
        END IF;
    END LOOP;

    IF v_miss <> '' THEN
        RAISE NOTICE 'VERDICT ERR 4.5 | the inventory agent''s SQL names columns its views do '
                     'not have:% - tools.go and check.go must be edited together with whatever '
                     'renamed them', v_miss;
    ELSE
        RAISE NOTICE 'VERDICT OK 8c all four inventory views still carry every column the agent '
                     'projects - the read surface and the code agree';
    END IF;
END
$$;

ROLLBACK;
