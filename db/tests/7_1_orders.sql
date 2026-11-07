-- The orders programme's surface, one block per thing 0027-0030 promise.
--
-- This is the probe `4_7` is for the customer service agent and `4_8` for the inventory one: it fails
-- the day a door or a view stops meaning what `agents/sales/backend_go/pkg/orders/tools.go` and
-- `docs/agent_requirements/sales/sales.md` say it means. The migrations each ran their own behavioural
-- blocks at apply time - 0027 twelve, 0028 thirteen, 0029 ten, 0030 fourteen - and those run once per
-- database. This file is the half that runs every time the harness does, which is the difference
-- between a migration that was true when it landed and a schema that is still true.
--
-- Blocks 1a-1g are mapped in `scripts/db/test-functions.sh`'s CASES. 1h, the column census, is
-- deliberately unmapped for `4_8` §8c's reason: it credits no past finding, and on the day it fires
-- the row to add maps it to whatever migration renamed the column.
--
-- Each block prints its mapped phrase from an existence guard FIRST, so a database predating the
-- programme says KNOWN-OPEN rather than SURPRISE.

-- ---------------------------------------------------------------------------
-- 1a. what a document is allowed to say about who is on the other end
-- ---------------------------------------------------------------------------
-- `create_order`'s description promises that a SALES order names a customer and a PURCHASE order
-- names a supplier, and that the WORK order names neither. The rule lives in
-- `orders_counterparty_matches_type` and not in the function's body, which is 0028's decision and the
-- reason this probe exists: if the CHECK is ever dropped or narrowed, the door would accept a
-- purchase order that cannot answer who it was placed with, and the tool's sentence becomes a rumour.
BEGIN;
DO $$
DECLARE
    v_ent   bigint;
    v_sup   uuid;
    v_wh    uuid;
    v_ord   uuid;
    v_err   text;
BEGIN
    IF to_regclass('public.orders') IS NULL THEN
        RAISE NOTICE 'VERDICT ERR 0028 | there is no orders table at all';
        RETURN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'orders_counterparty_matches_type')
    THEN
        RAISE NOTICE 'VERDICT ERR 0028 | the counterparty rule is not a constraint, so it is a habit';
        RETURN;
    END IF;

    INSERT INTO warehouses (warehouse_code, name) VALUES ('AFPC-TEST-1A', 'harness warehouse')
     RETURNING warehouse_id INTO v_wh;
    INSERT INTO entities (name, entity_type) VALUES ('AFPC-TEST-1A customer', 'customer')
     RETURNING id INTO v_ent;
    INSERT INTO entities (name, entity_type) VALUES ('AFPC-TEST-1A vendor', 'vendor');
    SELECT supplier_id INTO v_sup FROM add_supplier('AFPC-TEST-1A',
        (SELECT id FROM entities WHERE name = 'AFPC-TEST-1A vendor'), NULL, NULL, NULL, NULL,
        NULL, NULL, true, NULL);

    -- A purchase order naming a customer rather than a supplier: refused, by the wall and not by an
    -- if-statement, which is what "binds every seat that writes" is supposed to mean.
    v_err := NULL;
    BEGIN
        SELECT order_id INTO v_ord FROM create_order('PURCHASE', v_ent, NULL, v_wh, NULL, NULL,
                                                     NULL, '1a wrong counterparty', 'MANUAL', NULL);
    EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE || ': ' || left(SQLERRM, 90);
    END;
    IF v_err IS NULL THEN
        RAISE NOTICE 'VERDICT ERR 0028 | a PURCHASE order naming a customer was accepted - the '
                     'counterparty CHECK no longer covers the case the tool description states';
        RETURN;
    END IF;
    IF v_err NOT LIKE '23514%' THEN
        RAISE NOTICE 'VERDICT ERR 0028 | the wrong counterparty answered % instead of 23514, which '
                     'means something other than the CHECK refused it and the refusal will not be '
                     'the same for a raw INSERT', left(v_err, 70);
        RETURN;
    END IF;

    -- And the three legal shapes still are legal, including the one an agent most often wants: a
    -- work order with neither party, because production is not an agreement with anyone.
    IF (SELECT count(*) FROM (
            SELECT create_order('SALES', v_ent, NULL, v_wh, NULL, NULL, NULL, '1a', 'MANUAL', NULL)
            UNION ALL SELECT create_order('PURCHASE', NULL, v_sup, v_wh, NULL, NULL, NULL, '1a',
                                          'MANUAL', NULL)
            UNION ALL SELECT create_order('WORK', NULL, NULL, v_wh, NULL, NULL, NULL, '1a',
                                          'MANUAL', NULL)) x) <> 3 THEN
        RAISE NOTICE 'VERDICT ERR 0028 | one of the three legal counterparty shapes now fails';
        RETURN;
    END IF;

    -- The vocabulary the origin column admits, read back rather than trusted: RESERVATION_BACKFILL
    -- is the reason a SALES order may exist with no customer, and a CHECK that lost that value would
    -- make 0030's own backfill refuse to re-run.
    IF (SELECT count(*) FROM unnest(ARRAY['MANUAL','IMPORT','RESERVATION_BACKFILL']) u
         WHERE NOT EXISTS (SELECT 1 FROM pg_constraint
                            WHERE conname = 'orders_origin_allowed'
                              AND pg_get_constraintdef(oid) LIKE '%'||u||'%')) <> 0 THEN
        RAISE NOTICE 'VERDICT ERR 0028 | orders'' origin vocabulary no longer names every value the '
                     'programme writes, which is how a backfill becomes un-re-runnable';
        RETURN;
    END IF;

    RAISE NOTICE 'VERDICT OK 0028 | a document''s counterparty rule is a constraint, and the three '
                 'legal shapes and the backfill origin all still hold';
END
$$;
ROLLBACK;

-- ---------------------------------------------------------------------------
-- 1b. the lifecycle register, through the door that enforces it
-- ---------------------------------------------------------------------------
-- The register is only worth having if the door refuses what it says the door refuses: a status that
-- is a consequence of stock, and a step backwards. Both halves are probed because the first is the
-- design and the second is the kind of rule that gets dropped the afternoon someone wants to correct a
-- mistyped status.
BEGIN;
DO $$
DECLARE
    v_ent  bigint;
    v_ord  uuid;
    v_stat text;
    v_ver  int;
    v_err  text;
BEGIN
    IF to_regclass('public.order_lifecycle') IS NULL THEN
        RAISE NOTICE 'VERDICT ERR 0028 | there is no lifecycle register, so every status is free text';
        RETURN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_name = 'order_lifecycle' AND column_name = 'stock_moving') THEN
        RAISE NOTICE 'VERDICT ERR 0028 | the register has no stock_moving column, so nothing can tell '
                     'transition_order which statuses it must refuse';
        RETURN;
    END IF;

    INSERT INTO entities (name, entity_type) VALUES ('AFPC-TEST-1B', 'customer') RETURNING id INTO v_ent;
    SELECT order_id INTO v_ord FROM create_order('SALES', v_ent, NULL, NULL, NULL, NULL, NULL,
                                                 '1b', 'MANUAL', NULL);

    -- A consequence, typed. The message matters as much as the refusal: the model has to be able to
    -- find the door it should have called.
    v_err := NULL;
    BEGIN
        PERFORM * FROM transition_order(v_ord, 'SHIPPED', 'because I said so', NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE || ': ' || left(SQLERRM, 140);
    END;
    IF v_err IS NULL THEN
        RAISE NOTICE 'VERDICT ERR 0028 | transition_order wrote a stock-moving status, which is the '
                     'ledger disagreeing with the document by design';
        RETURN;
    END IF;

    -- A legal forward move, and the version moving with it. SALES's own path is
    -- DRAFT/CONFIRMED/PICKING/SHIPPED/CLOSED/CANCELLED - SUBMITTED is a purchase order's word - so the
    -- probe reads its statuses from the register rather than from this file's memory of them, which is
    -- the difference between a probe and a transcription.
    SELECT status, version INTO v_stat, v_ver FROM orders WHERE order_id = v_ord;
    PERFORM * FROM transition_order(v_ord, 'CONFIRMED', '1b confirmed', v_ver, NULL);
    SELECT status, version INTO v_stat, v_ver FROM orders WHERE order_id = v_ord;
    IF v_stat <> 'CONFIRMED' THEN
        RAISE NOTICE 'VERDICT ERR 0028 | a legal forward transition left the status at %s', v_stat;
        RETURN;
    END IF;
    IF v_ver <= 1 THEN
        RAISE NOTICE 'VERDICT ERR 0028 | a write did not move version (now %s), so the optimistic '
                     'guard below can never have anything to compare against', v_ver;
        RETURN;
    END IF;

    -- Backwards, refused: CONFIRMED is ordinal 2 of SALES and DRAFT is 1.
    v_err := NULL;
    BEGIN
        PERFORM * FROM transition_order(v_ord, 'DRAFT', 'undo', v_ver, NULL);
    EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE || ': ' || left(SQLERRM, 140);
    END;
    IF v_err IS NULL THEN
        RAISE NOTICE 'VERDICT ERR 0028 | a status went backwards, which erases a document''s history '
                     'in the one table that is supposed to keep it';
        RETURN;
    END IF;

    -- The optimistic arm, and its order: the version is checked BEFORE the direction rules, so a
    -- caller that read a stale row is told that, rather than being told about a status it could have
    -- reached. That ordering is the difference between an actionable refusal and a confusing one.
    v_err := NULL;
    BEGIN
        PERFORM * FROM transition_order(v_ord, 'PICKING', 'stale', 1, NULL);
    EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE || ': ' || left(SQLERRM, 140);
    END;
    IF v_err IS NULL THEN
        RAISE NOTICE 'VERDICT ERR 0028 | transition_order accepted expected_version 1 for a row on '
                     'version %s - the lost update the argument exists to catch', v_ver;
        RETURN;
    END IF;
    IF v_err NOT LIKE '%version%' THEN
        RAISE NOTICE 'VERDICT ERR 0028 | the stale-version refusal says %s, which is not about the '
                     'version - the guard fires for the wrong reason and the caller cannot act on it',
                     left(v_err, 60);
        RETURN;
    END IF;
    PERFORM * FROM transition_order(v_ord, 'PICKING', 'current version', v_ver, NULL);
    IF (SELECT status FROM orders WHERE order_id = v_ord) <> 'PICKING' THEN
        RAISE NOTICE 'VERDICT ERR 0028 | the guard fires on a stale version but the transition it '
                     'documents does not happen on a current one';
        RETURN;
    END IF;

    -- A terminal move sets closed_at, because "when did this stop being live" is a question a
    -- listing view answers with that column and not with updated_at.
    SELECT version INTO v_ver FROM orders WHERE order_id = v_ord;
    PERFORM * FROM transition_order(v_ord, 'CLOSED', '1e closed', v_ver, NULL);
    IF (SELECT closed_at FROM orders WHERE order_id = v_ord) IS NULL THEN
        RAISE NOTICE 'VERDICT ERR 0028 | reaching a terminal status left closed_at null, so every '
                     '"how long has this been done" answer would be an inference from updated_at';
        RETURN;
    END IF;
    v_err := NULL;
    BEGIN
        PERFORM * FROM transition_order(v_ord, 'PICKING', 'out of a closed document', NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE || ': ' || left(SQLERRM, 140);
    END;
    IF v_err IS NULL THEN
        RAISE NOTICE 'VERDICT ERR 0028 | a CLOSED order accepted another transition, which makes '
                     'terminal a word and not a state';
        RETURN;
    END IF;

    RAISE NOTICE 'VERDICT OK 0028 | the register refuses a consequence and a reversal, and the '
                 'version it publishes is the one the door checks';
END
$$;
ROLLBACK;

-- ---------------------------------------------------------------------------
-- 1c. a line, and the money arithmetic that must not be a second truth
-- ---------------------------------------------------------------------------
BEGIN;
DO $$
DECLARE
    v_ent   bigint;
    v_ord   uuid;
    v_item  uuid;
    v_line  uuid;
    v_wh    uuid;
    v_amt   numeric;
    v_state text;
    v_err   text;
BEGIN
    IF to_regclass('public.order_items') IS NULL THEN
        RAISE NOTICE 'VERDICT ERR 0028 | there is no order detail table, so a document cannot be lined';
        RETURN;
    END IF;

    INSERT INTO warehouses (warehouse_code, name) VALUES ('AFPC-TEST-1C', 'harness warehouse')
     RETURNING warehouse_id INTO v_wh;
    INSERT INTO entities (name, entity_type) VALUES ('AFPC-TEST-1C', 'customer') RETURNING id INTO v_ent;
    INSERT INTO inventory_items (sku, name, base_unit_of_measure)
         VALUES ('AFPC-TEST-1C', 'harness item', 'EACH') RETURNING item_id INTO v_item;
    SELECT order_id INTO v_ord FROM create_order('SALES', v_ent, NULL, v_wh, NULL, NULL, NULL,
                                                 '1c', 'MANUAL', NULL);

    SELECT order_line_id INTO v_line FROM add_order_line(v_ord, v_item, NULL, 3, '19.99', NULL,
                                                         'STANDARD', v_wh, NULL, NULL, NULL, NULL);
    -- GENERATED, by DDL, so no trigger keeps it: a body that recomputed it in a door would be a second
    -- definition of a product, and the second one is the one that rots.
    SELECT line_amount INTO v_amt FROM order_items WHERE order_line_id = v_line;
    IF v_amt IS NULL OR abs(v_amt - 59.97) > 0.0001 THEN
        RAISE NOTICE 'VERDICT ERR 0028 | line_amount reads %s for 3 x 19.99 - the generated column is '
                     'no longer the arithmetic the tool description states', v_amt;
        RETURN;
    END IF;

    -- A line with no item and no words is not a line, and 0028 made that a CHECK rather than a
    -- validation arm so that a raw INSERT cannot be the one that gets away with it.
    v_err := NULL;
    BEGIN
        PERFORM * FROM add_order_line(v_ord, NULL, NULL, 1, 1, NULL, 'STANDARD', v_wh, NULL, NULL,
                                      NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE || ': ' || left(SQLERRM, 90);
    END;
    IF v_err IS NULL THEN
        RAISE NOTICE 'VERDICT ERR 0028 | a line with neither an item nor a description was accepted - '
                     'an unlabelled quantity is what a MISCELLANEOUS item becomes on the day someone '
                     'is asked to report on it';
        RETURN;
    END IF;

    -- What a line means is tied to what the document is: COMPONENT and PRODUCT are a work order's
    -- vocabulary, and a sales order that grows one has broken the seam 0029 lands production on.
    v_err := NULL;
    BEGIN
        PERFORM * FROM add_order_line(v_ord, v_item, NULL, 1, 1, NULL, 'COMPONENT', v_wh, NULL, NULL,
                                      NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE || ': ' || left(SQLERRM, 90);
    END;
    IF v_err IS NULL THEN
        RAISE NOTICE 'VERDICT ERR 0029 | a sales order accepted a COMPONENT line, so line_type no '
                     'longer says what the line does to stock';
        RETURN;
    END IF;

    -- And the state the view names from three numbers, not from a status column that could disagree.
    SELECT line_state INTO v_state FROM vw_order_lines WHERE order_line_id = v_line;
    IF v_state <> 'OPEN' THEN
        RAISE NOTICE 'VERDICT ERR 0028 | a brand new line reads %s, which is not what its quantities say',
                     v_state;
        RETURN;
    END IF;
    UPDATE order_items SET quantity_fulfilled = 3 WHERE order_line_id = v_line;
    SELECT line_state INTO v_state FROM vw_order_lines WHERE order_line_id = v_line;
    IF v_state <> 'FULFILLED' THEN
        RAISE NOTICE 'VERDICT ERR 0028 | a complete line still reads %s - vw_order_lines'' state '
                     'derivation stopped meaning its quantities', v_state;
        RETURN;
    END IF;

    RAISE NOTICE 'VERDICT OK 0028 | a line''s amount is generated, a line without words is refused, '
                 'and its state is read from what it owes';
END
$$;
ROLLBACK;

-- ---------------------------------------------------------------------------
-- 1d. the four doors that finish a document, callable and guarded
-- ---------------------------------------------------------------------------
-- 0030's claim is not only that these functions exist - pg_proc says that - but that the runtime role
-- can call them and that a retry of one is one operation. The second half is what makes them doors
-- rather than helpers: an agent that re-issues a shipment after a timeout must not ship twice.
BEGIN;
DO $$
DECLARE
    v_name   text;
    v_missing text := '';
    v_unguarded text := '';
BEGIN
    IF to_regprocedure('ship_sales_order(uuid,uuid,text,uuid)') IS NULL THEN
        RAISE NOTICE 'VERDICT ERR 0030 | none of the fulfilment doors are installed';
        RETURN;
    END IF;

    FOR v_name IN SELECT unnest(ARRAY['ship_sales_order', 'receive_purchase_order',
                                      'book_work_order_production',
                                      'cancel_inventory_reservation']) LOOP
        -- By oid and not by a name+signature string: has_function_privilege resolves an exact
        -- signature, and writing one here would be a second arity claim to keep true - the same
        -- reason 1g reads the parameter list out of the catalog.
        IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                        WHERE n.nspname = 'public' AND p.proname = v_name
                          AND has_function_privilege('afpc_app', p.oid, 'EXECUTE')) THEN
            v_missing := v_missing || ' ' || v_name;
        END IF;
        -- The register's own verdict column, read rather than recomputed: 0011 derives it from the
        -- function body's claim ladder, so an assertion here that re-implemented the ladder would be a
        -- second definition of "guarded" - the failure 0007 refuses for a CHECK.
        IF NOT EXISTS (SELECT 1 FROM vw_idempotency_status
                        WHERE function = v_name AND unguarded = false) THEN
            v_unguarded := v_unguarded || ' ' || v_name;
        END IF;
    END LOOP;

    IF v_missing <> '' THEN
        RAISE NOTICE 'VERDICT ERR 0030 | the write seat cannot execute%s - the doors exist and the '
                     'agent cannot reach them', trim(v_missing);
        RETURN;
    END IF;
    IF v_unguarded <> '' THEN
        RAISE NOTICE 'VERDICT ERR 0030 | %s change state with no claim attached, so a retry of a timed-out '
                     'shipment is a second shipment and the register says so', trim(v_unguarded);
        RETURN;
    END IF;

    RAISE NOTICE 'VERDICT OK 0030 | all four fulfilment doors are callable by the runtime role and '
                 'listed as claim-guarded';
END
$$;
ROLLBACK;

-- ---------------------------------------------------------------------------
-- 1e. a commitment, attributed and not, and the release that ends it
-- ---------------------------------------------------------------------------
-- The finding 0030 was written for, stated as an assertion: held stock is a fact about a document, a
-- line, and a moment. All three, because a count without the second is the number that read as zero
-- for four hundred thousand days, and a settlement without the third cannot be audited after the fact.
BEGIN;
DO $$
DECLARE
    v_ent   bigint;
    v_ord   uuid;
    v_line  uuid;
    v_item  uuid;
    v_wh    uuid;
    v_rid   uuid;
    v_cmt   numeric;
    v_unl   numeric;
    v_upd   timestamptz;
BEGIN
    IF to_regclass('public.vw_order_commitments') IS NULL THEN
        RAISE NOTICE 'VERDICT ERR 0030 | there is no reconciliation view, so a counter and a ledger '
                     'cannot be compared by anything';
        RETURN;
    END IF;

    INSERT INTO warehouses (warehouse_code, name) VALUES ('AFPC-TEST-1E', 'harness warehouse')
     RETURNING warehouse_id INTO v_wh;
    INSERT INTO inventory_items (sku, name, base_unit_of_measure)
         VALUES ('AFPC-TEST-1E', 'harness item', 'EACH') RETURNING item_id INTO v_item;
    PERFORM execute_inventory_movement('RECEIPT', v_item, NULL, v_wh, 20, 2, 'afpc_harness',
        'PO', NULL, NULL, 'EACH');
    INSERT INTO entities (name, entity_type) VALUES ('AFPC-TEST-1E', 'customer') RETURNING id INTO v_ent;
    SELECT order_id INTO v_ord FROM create_order('SALES', v_ent, NULL, v_wh, NULL, NULL, NULL,
                                                 '1e', 'MANUAL', NULL);
    SELECT order_line_id INTO v_line FROM add_order_line(v_ord, v_item, NULL, 4, 5, NULL, 'STANDARD',
                                                         v_wh, NULL, NULL, NULL, NULL);

    -- Named, this time: the door that makes a commitment can be told which line it holds stock for.
    SELECT reservation_id INTO v_rid
      FROM reserve_inventory_for_order(v_item, v_wh, 4, 'SALES', v_ord, 'afpc_harness', NULL, NULL,
                                       v_line);

    SELECT quantity_committed, quantity_committed_unlinked INTO v_cmt, v_unl
      FROM vw_order_commitments WHERE order_line_id = v_line;
    IF v_cmt <> 4 OR v_unl <> 0 THEN
        RAISE NOTICE 'VERDICT ERR 0030 | an attributed commitment of 4 reads as committed=%s '
                     'unlinked=%s', v_cmt, v_unl;
        RETURN;
    END IF;

    IF (SELECT order_line_id FROM inventory_reservations WHERE reservation_id = v_rid) IS NULL THEN
        RAISE NOTICE 'VERDICT ERR 0030 | the reservation door was handed a line and stored none, so '
                     'the reconciliation is blind on the write path that has a reader';
        RETURN;
    END IF;

    -- The release. It is the half the schema never had, so it gets the assertion rather than the
    -- comment: after it, the units are not held, the row is still there, and it says when.
    PERFORM * FROM cancel_inventory_reservation(v_rid, NULL, '1e released', 'afpc_harness', NULL);

    IF (SELECT quantity_unresolved FROM vw_order_commitments WHERE order_line_id = v_line) <> 0 THEN
        RAISE NOTICE 'VERDICT ERR 0030 | a cancelled commitment is still unresolved, which is the '
                     'stuck-reservation finding returning through a door built to close it';
        RETURN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM inventory_reservations WHERE reservation_id = v_rid) THEN
        RAISE NOTICE 'VERDICT ERR 0030 | releasing a commitment deleted it - the commitment was a '
                     'fact, and 0008''s rule for a thing that cannot leave a trail is that it stays';
        RETURN;
    END IF;
    SELECT updated_at INTO v_upd FROM inventory_reservations WHERE reservation_id = v_rid;
    IF v_upd IS NULL THEN
        RAISE NOTICE 'VERDICT ERR 0030 | the settled commitment carries no timestamp, so the question '
                     '"when did this release" has no answer in the row that released it';
        RETURN;
    END IF;

    RAISE NOTICE 'VERDICT OK 0030 | a commitment can name its line, the view tells attributed from '
                 'unattributed, and releasing one settles it without erasing it';
END
$$;
ROLLBACK;

-- ---------------------------------------------------------------------------
-- 1f. the enforcement, and the two document kinds it does not reach
-- ---------------------------------------------------------------------------
-- The trigger is the rule 0030 attached only after its backfill satisfied it, so both halves are
-- probed: a commitment against a document that does not exist must fail, and a STOCK hold - which
-- names no table by design - must not. A wall that fires on the third case is a wall that quietly
-- breaks the agent that makes them.
BEGIN;
DO $$
DECLARE
    v_item uuid;
    v_wh   uuid;
    v_err  text;
    v_rid  uuid;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
                    WHERE t.tgname = 'afpc_reservation_names_a_document' AND c.relname = 'inventory_reservations')
    THEN
        RAISE NOTICE 'VERDICT ERR 0030 | nothing enforces that a commitment names a document, so '
                     'order_id is still a pointer with nothing behind it';
        RETURN;
    END IF;

    INSERT INTO warehouses (warehouse_code, name) VALUES ('AFPC-TEST-1F', 'harness warehouse')
     RETURNING warehouse_id INTO v_wh;
    INSERT INTO inventory_items (sku, name, base_unit_of_measure)
         VALUES ('AFPC-TEST-1F', 'harness item', 'EACH') RETURNING item_id INTO v_item;
    PERFORM execute_inventory_movement('RECEIPT', v_item, NULL, v_wh, 10, 2, 'afpc_harness',
        'PO', NULL, NULL, 'EACH');

    v_err := NULL;
    BEGIN
        SELECT reservation_id INTO v_rid FROM reserve_inventory_for_order(v_item, v_wh, 1, 'SALES',
            '01a1dead-0000-7000-8000-000000000001', 'afpc_harness', NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE || ': ' || left(SQLERRM, 90);
    END;
    IF v_err IS NULL THEN
        RAISE NOTICE 'VERDICT ERR 0030 | a commitment was made against a document that does not '
                     'exist, which is the shape thirteen units have been stuck in';
        RETURN;
    END IF;

    -- The pass-through, which since §4 is also a capability rather than an exception: an internal hold
    -- names no document, and saying so is legal instead of impossible.
    v_err := NULL;
    BEGIN
        SELECT reservation_id INTO v_rid FROM reserve_inventory_for_order(v_item, v_wh, 1, 'STOCK',
            NULL, 'afpc_harness', NULL, NULL);
        IF v_rid IS NULL THEN v_err := 'answered no reservation'; END IF;
    EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE || ': ' || left(SQLERRM, 70);
    END;
    IF v_err IS NOT NULL THEN
        RAISE NOTICE 'VERDICT ERR 0030 | a STOCK hold naming no document is refused (%s) - the type '
                     'that names no table cannot be written, which is the leak wearing a different '
                     'name', v_err;
        RETURN;
    END IF;

    -- And the direction the relaxation must not have opened: a SALES commitment that names nothing.
    v_err := NULL;
    BEGIN
        PERFORM * FROM reserve_inventory_for_order(v_item, v_wh, 1, 'SALES', NULL, 'afpc_harness',
                                                   NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE;
    END;
    IF v_err NOT IN ('23502','23503','23514') THEN
        RAISE NOTICE 'VERDICT ERR 0030 | a SALES commitment naming no document answered %s - §4 let a '
                     'document type back into the shape §3 closed', coalesce(v_err,'nothing, it worked');
        RETURN;
    END IF;

    RAISE NOTICE 'VERDICT OK 0030 | a commitment cannot name a document that is not there, a hold that '
                 'names no document works, and a document type still cannot name nothing';
END
$$;
ROLLBACK;

-- ---------------------------------------------------------------------------
-- 1g. the doors' positions, as the Go tools call them
-- ---------------------------------------------------------------------------
-- Positional, because that is the calling convention every one of these agents uses: a door parameter
-- inserted in the middle is not a type error, it is the idempotency key landing in a column. 4_8 §8b
-- is the same assertion for the reservation door; this is it for the orders half, read from the catalog
-- rather than from a comment.
BEGIN;
DO $$
DECLARE
    v_door  record;
    v_bad   text := '';
    v_names text[];
    v_n     int;
BEGIN
    -- name, declared arity, and the position the claim key sits at. The reservation door's key is
    -- EIGHTH of NINE because 0030 §5.5 appended the line reference after it - appending is the only
    -- shape in which a positional caller of eight survives a signature change - and that is exactly
    -- the case the third column is here to state rather than smooth over. Every parameter past the
    -- key has to be defaulted, which is the fourth assertion below.
    FOR v_door IN SELECT * FROM (VALUES
            ('create_order', 10, 10), ('add_order_line', 12, 12), ('transition_order', 5, 5),
            ('add_supplier', 10, 10), ('ship_sales_order', 4, 4), ('receive_purchase_order', 4, 4),
            ('book_work_order_production', 5, 5), ('cancel_inventory_reservation', 5, 5),
            ('reserve_inventory_for_order', 9, 8)
        ) AS t(name, argc, keypos)
    LOOP
        -- The defaulted count is pronargdefaults, and it is the number of TRAILING parameters with a
    -- DEFAULT - which is the only kind of defaulting PostgreSQL allows, and the reason §5.5 appends.
    SELECT array_agg(g.a ORDER BY g.n), max(s.pronargdefaults)
      INTO v_names, v_n
          FROM (SELECT p.proargnames, p.proargmodes, p.pronargdefaults FROM pg_proc p
                 WHERE p.proname = v_door.name AND p.pronamespace = 'public'::regnamespace) s,
               unnest(s.proargnames, s.proargmodes) WITH ORDINALITY AS g(a, mode, n)
         WHERE mode IS NULL OR mode::text IN ('i','b');

        IF v_names IS NULL OR array_length(v_names, 1) <> v_door.argc THEN
            v_bad := v_bad || format(' %s has %s input parameters, the tools send %s',
                v_door.name, coalesce(array_length(v_names,1)::text,'none'), v_door.argc);
        ELSIF v_names[v_door.keypos] <> 'p_idempotency_key' THEN
            v_bad := v_bad || format(' %s''s parameter %s is %s, not the claim key - a positional '
                'caller puts its idempotency in a column, which is 4.4''s ambiguity with a quieter '
                'failure mode', v_door.name, v_door.keypos, v_names[v_door.keypos]);
        ELSIF v_n < array_length(v_names,1) - v_door.keypos THEN
            v_bad := v_bad || format(' %s has %s parameter(s) past the claim key and only %s of the '
                'whole list defaulted - everything appended after a key must be optional or the '
                'callers that stop at the key stop resolving',
                v_door.name, array_length(v_names,1) - v_door.keypos, v_n);
        END IF;
    END LOOP;

    IF v_bad <> '' THEN
        RAISE NOTICE 'VERDICT ERR 0030 | the doors'' positions are not what pkg/orders calls them '
                     'as:%s', trim(v_bad);
        RETURN;
    END IF;
    RAISE NOTICE 'VERDICT OK 0030 | every orders door has the arity its tools send and the claim key '
                 'where they put it, with anything past the key defaulted - which is the shape a '
                 'positional caller survives a signature change in';
END
$$;
ROLLBACK;

-- ---------------------------------------------------------------------------
-- 1h. every column the sales agent's SQL names, view by view (unmapped)
-- ---------------------------------------------------------------------------
-- The projection lists in pkg/orders/tools.go are the contract between a Go string and a view, and
-- nothing else in this repository notices when one of them stops existing. Deliberately unmapped in
-- CASES, for 4_8 §8c's reason: it credits no past finding, and on the day it fires the row to add
-- maps it to whatever migration renamed the column.
BEGIN;
DO $$
DECLARE
    v_pair  record;
    v_bad   text := '';
BEGIN
    FOR v_pair IN SELECT * FROM (VALUES
            ('vw_orders', ARRAY['order_number','order_type','status','origin','lifecycle_position',
                                'is_terminal','reports_a_movement','customer_id','customer_name',
                                'vendor_id','vendor_code','vendor_name','warehouse_name',
                                'currency_code','ordered_date','required_date','priority','line_count',
                                'total_amount','total_quantity','open_amount','status_reason',
                                'order_id']),
            ('vw_order_lines', ARRAY['order_number','order_type','order_status','line_number',
                                     'line_type','item_id','sku','item_name','item_product_type',
                                     'description','quantity','unit_of_measure','unit_price',
                                     'line_amount','quantity_fulfilled','quantity_cancelled',
                                     'quantity_open','line_state','warehouse_code','lot_number',
                                     'required_date','order_id','order_line_id']),
            ('vw_order_commitments', ARRAY['order_number','order_type','order_status','line_number',
                                           'line_type','item_id','item_name','quantity',
                                           'quantity_open','quantity_committed','quantity_released',
                                           'quantity_unresolved','quantity_committed_unlinked',
                                           'ledger_rows','ledger_quantity','ledger_agreement',
                                           'required_date','order_id','order_line_id']),
            ('vw_customers', ARRAY['id','name','email','phone','status']),
            ('vw_suppliers', ARRAY['supplier_id','supplier_code','entity_id','party_name','legal_name',
                                   'tax_id','party_type','payment_terms','lead_time_days',
                                   'currency_code','is_active'])
        ) AS t(view_name, cols)
    LOOP
        IF to_regclass('public.' || v_pair.view_name) IS NULL THEN
            v_bad := v_bad || ' ' || v_pair.view_name || ' does not exist';
            CONTINUE;
        END IF;
        SELECT string_agg(c, ', ') INTO v_bad
          FROM unnest(v_pair.cols) AS c
         WHERE NOT EXISTS (SELECT 1 FROM information_schema.columns k
                            WHERE k.table_schema = 'public'
                              AND k.table_name = v_pair.view_name AND k.column_name = c);
        IF coalesce(v_bad, '') <> '' THEN
            v_bad := ' ' || v_pair.view_name || ' lacks ' || v_bad;
        END IF;
    END LOOP;

    IF v_bad <> '' THEN
        RAISE NOTICE 'VERDICT ERR 0030 | the read surface and the code disagree:%s', trim(v_bad);
        RETURN;
    END IF;
    RAISE NOTICE 'VERDICT OK 0030 | every column the sales agent projects is in the view it names';
END
$$;
ROLLBACK;
