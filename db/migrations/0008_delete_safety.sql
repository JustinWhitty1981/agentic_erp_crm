-- 0008: make destructive deletes say so, or refuse (DATABASE_REVIEW.md 5.10; plan P4).
--
-- 5.10 counts 6 CASCADE edges against business data and prescribes "RESTRICT (or soft
-- delete) with an explicit close-out path". Each prescription here is a measurement made on
-- a pre-0008 clone, not a reading of the review:
--
--   A. DELETE FROM inventory_items  where the item has stock rows and no ledger history
--      -> succeeded. The stock rows - quantities someone counted - were gone with it.
--   B. DELETE FROM warehouses       where the warehouse has a stocked bin, no history
--      -> succeeded. inventory_on_hand.warehouse_id CASCADE deleted the stock rows
--      directly; the bin cascade never even got to them.
--   C. DELETE FROM human_sessions   where the session has agent actions
--      -> succeeded. bot_actions CASCADE deleted the audit trail.
--   D. DELETE FROM locations        where stock points at the bin
--      -> the ON DELETE SET NULL edge on inventory_on_hand.location_id either silently
--      re-homed the stock to warehouse level, or - when a no-bin row for the same
--      item/warehouse/lot already existed - aborted with "duplicate key value violates
--      unique constraint inventory_on_hand_key": a 23505 from 0004's identity index
--      arriving mid-delete, an error no operator could attribute to the bin they removed.
--      One edge, two failure modes, neither of them an answer.
--
-- The pattern across A-C: the edges that look protected are protected only by other edges.
-- inventory_movements.item_id is RESTRICT and .warehouse_id NO ACTION, so anything that ever
-- MOVED is safe - which is exactly the same statement as: the destruction happens precisely
-- when the table has no history yet. A warehouse that received one pallet cannot be silently
-- deleted; a warehouse holding 40 units that never moved can. Protection by accident is not
-- a design, and "no ledger entries yet" is precisely when a mistaken delete is recoverable
-- only from the stock rows themselves.
--
-- WHAT GETS WHAT, AND WHY
--
--   inventory_on_hand.{item_id, warehouse_id}          CASCADE -> RESTRICT   stock is a fact
--   inventory_reservations.{item_id, warehouse_id}     CASCADE -> RESTRICT   a commitment is a fact
--   bot_actions.session_id                             CASCADE -> RESTRICT   the audit trail is a fact
--   inventory_on_hand.location_id                      SET NULL -> RESTRICT  (failure mode D)
--
--   locations.warehouse_id                             CASCADE - RETAINED.
--     5.10's count includes it, but a bin is not a fact that outlives its warehouse - it is
--     the warehouse, expressed as shelves. The dangerous part of deleting a warehouse was
--     never the bins; it was the stock, and that is now refused by the two edges above. What
--     still protects the CASCADE's blast radius is the graph around it: a bin referenced by
--     a movement or a reservation aborts the whole delete (NO ACTION), and a bin referenced
--     by on-hand rows aborts it as of this migration (RESTRICT above). The only bins this
--     cascade can now destroy are ones nothing has ever counted, reserved, or moved against.
--     Section 3 proves that reading with a probe, so it is a verified fact rather than an
--     argument in a comment - and B3 asserts exactly one CASCADE survives, naming it.
--
--   warehouses.parent_warehouse_id, item_categories.parent, communications.thread_root_id
--     SET NULL - RETAINED. Threading and hierarchy are annotations on rows that keep their
--     meaning when the annotation target goes away; a message is not the thread, and a
--     warehouse is not its parent. Different relation, different rule.
--
-- On the mechanics: Postgres has no ALTER for a delete rule, so each edge is dropped and
-- re-added with its name. The name is kept deliberately - it appears in every violation
-- message, in the scoreboard, and in operators' notes from the last incident. The re-add
-- validates, which on a populated copy is a sequential check of the child table under a
-- lock; the rows it finds cannot violate anything (the CASCADE enforced the same predicate
-- until a microsecond ago), so this is cost, not risk. Section 3 reports the row counts it
-- scanned, the same courtesy 0006 extended for its index builds.
--
-- WHAT THIS DOES NOT DO
--
--   * It does not delete anything. Every probe runs in a subtransaction and vanishes.
--   * It does not add soft-delete columns: warehouses.is_active and inventory_items.is_active
--     already exist. What was missing is the explicit close-out the review asks for, and
--     section 2 adds it - because RESTRICT alone turns "retire this warehouse" into a
--     scavenger hunt through four tables.

SET client_min_messages TO notice;

-- ---------------------------------------------------------------------------
-- 1. Flip the five edges
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _afpc_0008_edges ON COMMIT DROP AS
SELECT * FROM (VALUES
    ('inventory_on_hand',         'inventory_on_hand_item_id_fkey',         'c'),
    ('inventory_on_hand',         'inventory_on_hand_warehouse_id_fkey',    'c'),
    ('inventory_on_hand',         'inventory_on_hand_location_id_fkey',     'n'),
    ('inventory_reservations',    'inventory_reservations_item_id_fkey',    'c'),
    ('inventory_reservations',    'inventory_reservations_warehouse_id_fkey','c'),
    ('bot_actions',               'bot_actions_session_id_fkey',            'c')
) AS e(tbl, con, from_rule);

DO $$
DECLARE
    r           record;
    c           record;
    v_cols      text;
    v_rcols     text;
    v_def       text;
    v_n         int := 0;
BEGIN
    FOR r IN SELECT * FROM _afpc_0008_edges ORDER BY tbl, con LOOP
        SELECT * INTO c FROM pg_constraint
         WHERE conname = r.con AND connamespace = 'public'::regnamespace;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'expected foreign key % to exist - 0008 rewrites named edges, it '
                            'does not create them (a renamed constraint is a different claim '
                            'than the one 5.10 measured)', r.con;
        END IF;

        IF c.confdeltype = 'r' THEN
            RAISE NOTICE '% already RESTRICT - nothing to flip', r.con;
            CONTINUE;
        END IF;
        IF c.confdeltype <> r.from_rule THEN
            RAISE EXCEPTION '% has delete rule %, but 0008 was written against % - the graph '
                            'moved under this migration; stop and re-measure',
                r.con, c.confdeltype, r.from_rule;
        END IF;

        -- Key lists rebuilt through unnest WITH ORDINALITY: indkey/conkey are zero-subscripted
        -- int2vectors and a plain slice compares the wrong columns (0004, 0005, 0006 - this is
        -- the fourth call site, and the only one that builds DDL out of the answer).
        SELECT string_agg(a.attname::text, ', ' ORDER BY k.ord),
               string_agg(b.attname::text, ', ' ORDER BY k.ord)
          INTO v_cols, v_rcols
          FROM unnest(c.conkey) WITH ORDINALITY k(n, ord)
          JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.n
          JOIN pg_attribute b ON b.attrelid = c.confrelid AND b.attnum = (c.confkey)[k.ord];

        v_def := CASE WHEN c.condeferrable
                      THEN ' DEFERRABLE' || CASE WHEN c.condeferred THEN ' INITIALLY DEFERRED' ELSE '' END
                      ELSE '' END;

        EXECUTE format('ALTER TABLE public.%I DROP CONSTRAINT %I', r.tbl, r.con);
        EXECUTE format('ALTER TABLE public.%I ADD CONSTRAINT %I FOREIGN KEY (%s) REFERENCES public.%I (%s) ON DELETE RESTRICT%s',
                       r.tbl, r.con, v_cols, c.confrelid::regclass::text, v_rcols, v_def);
        v_n := v_n + 1;
        RAISE NOTICE '%: ON DELETE % -> RESTRICT (%)', r.con,
            CASE r.from_rule WHEN 'c' THEN 'CASCADE' ELSE 'SET NULL' END, v_cols;
    END LOOP;
    RAISE NOTICE '5.10: % edges flipped (5 CASCADE, 1 SET NULL); the surviving CASCADE is '
                 'locations -> warehouses, retained deliberately - see section 3.4', v_n;

    -- 6, not 5: 5.10's "six CASCADE deletes" are five flips plus one retained, and the sixth
    -- edge changed here (on_hand.location_id's SET NULL) was never in that count - it is the
    -- one this migration found by measuring, not reading.
    IF v_n <> 6 THEN
        RAISE EXCEPTION 'expected to flip 6 edges, flipped % - the list and the graph disagree', v_n;
    END IF;
END
$$;

COMMENT ON CONSTRAINT locations_warehouse_id_fkey ON public.locations IS
    'ON DELETE CASCADE, retained by 0008 after measuring what it can actually destroy: a bin '
    'is composition, not an independent fact, and every reference that could make destroying '
    'bins destructive (stock rows, reservations, the movement ledger) is now itself a '
    'RESTRICT/NO ACTION edge in front of the same delete. Deleting a warehouse that has ever '
    'held anything fails loudly. Use decommission_warehouse() for the intended path (5.10).';

-- ---------------------------------------------------------------------------
-- 2. The explicit close-out the review's alternative demands
-- ---------------------------------------------------------------------------
-- RESTRICT turns a silent destruction into a confusing error unless there is a door out.
-- These two functions are that door: they check what a delete would strand, refuse with the
-- numbers rather than a constraint name, and then close the row out the way the schema means
-- it - is_active = false, history untouched. Physical deletion stays possible for rows that
-- never did anything, by just... deleting them, which will now work.

CREATE OR REPLACE FUNCTION decommission_warehouse(
    p_warehouse_id  uuid
)
RETURNS text
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_name    text;
    v_stock   bigint;
    v_qty     numeric;
    v_open    bigint;
    v_bins    int;
    v_gone    int;
BEGIN
    SELECT name INTO v_name FROM warehouses
     WHERE warehouse_id = p_warehouse_id AND tenant_id = afpc_current_tenant();
    IF NOT FOUND THEN
        RAISE EXCEPTION 'warehouse % does not exist in this tenant', p_warehouse_id;
    END IF;

    SELECT count(*), coalesce(sum(quantity_on_hand), 0) INTO v_stock, v_qty
      FROM inventory_on_hand
     WHERE warehouse_id = p_warehouse_id AND quantity_on_hand <> 0;
    IF v_stock > 0 THEN
        RAISE EXCEPTION 'warehouse % still holds % unit(s) across % stock row(s) - move or '
                        'adjust the stock first; RESTRICT exists precisely so this cannot '
                        'close out silently', v_name, v_qty, v_stock;
    END IF;

    SELECT count(*) INTO v_open
      FROM inventory_reservations
     WHERE warehouse_id = p_warehouse_id
       AND reserved_quantity > coalesce(shipped_quantity, 0) + coalesce(cancelled_quantity, 0);
    IF v_open > 0 THEN
        RAISE EXCEPTION 'warehouse % still carries % open reservation(s) - cancel or ship '
                        'them first', v_name, v_open;
    END IF;

    -- Bins nothing has ever counted against or moved from are the only ones that can go;
    -- the rest are marked inactive and stay, because the ledger will name them forever.
    SELECT count(*) INTO v_bins FROM locations WHERE warehouse_id = p_warehouse_id;
    DELETE FROM locations l
     WHERE l.warehouse_id = p_warehouse_id
       AND NOT EXISTS (SELECT 1 FROM inventory_on_hand  o WHERE o.location_id  = l.location_id)
       AND NOT EXISTS (SELECT 1 FROM inventory_movements m
                        WHERE m.from_location_id = l.location_id OR m.to_location_id = l.location_id)
       AND NOT EXISTS (SELECT 1 FROM inventory_reservations r WHERE r.location_id = l.location_id);
    GET DIAGNOSTICS v_gone = ROW_COUNT;
    UPDATE locations SET is_active = false
     WHERE warehouse_id = p_warehouse_id
       AND NOT EXISTS (SELECT 1 FROM inventory_on_hand o WHERE o.location_id = locations.location_id);

    UPDATE warehouses SET is_active = false
     WHERE warehouse_id = p_warehouse_id;

    RETURN format('warehouse %s decommissioned: %s of %s bin(s) released, %s bin(s) kept '
                  'inactive for history, stock rows and ledger untouched',
                  v_name, v_gone, v_bins, v_bins - v_gone);
END
$$;

COMMENT ON FUNCTION decommission_warehouse IS
    'The explicit close-out path 5.10 prescribes as the alternative to CASCADE: refuses with '
    'the actual stock and reservation counts if the warehouse still holds either, otherwise '
    'marks it inactive, releases bins that no fact references, and deletes nothing that '
    'history points at. A warehouse row is never destroyed by this function - after it has '
    'existed in the ledger it is a fact itself.';

CREATE OR REPLACE FUNCTION retire_item(
    p_item_id  uuid
)
RETURNS text
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_sku     text;
    v_stock   bigint;
    v_qty     numeric;
    v_open    bigint;
BEGIN
    SELECT sku INTO v_sku FROM inventory_items
     WHERE item_id = p_item_id AND tenant_id = afpc_current_tenant();
    IF NOT FOUND THEN
        RAISE EXCEPTION 'item % does not exist in this tenant', p_item_id;
    END IF;

    SELECT count(*), coalesce(sum(quantity_on_hand), 0) INTO v_stock, v_qty
      FROM inventory_on_hand
     WHERE item_id = p_item_id AND quantity_on_hand <> 0;
    IF v_stock > 0 THEN
        RAISE EXCEPTION 'item % still has % unit(s) on hand across % row(s) - issue, transfer '
                        'or adjust them to zero before retiring', v_sku, v_qty, v_stock;
    END IF;

    SELECT count(*) INTO v_open
      FROM inventory_reservations
     WHERE item_id = p_item_id
       AND reserved_quantity > coalesce(shipped_quantity, 0) + coalesce(cancelled_quantity, 0);
    IF v_open > 0 THEN
        RAISE EXCEPTION 'item % still carries % open reservation(s)', v_sku, v_open;
    END IF;

    UPDATE inventory_items SET is_active = false WHERE item_id = p_item_id;
    RETURN format('item %s retired: %s zero-quantity stock row(s) kept as bookkeeping, '
                  'movements kept, is_active = false', v_sku, v_stock);
END
$$;

COMMENT ON FUNCTION retire_item IS
    'The explicit close-out for inventory_items, the counterpart of decommission_warehouse '
    '(5.10). Refuses while the item has any nonzero stock or an open reservation; retires by '
    'is_active rather than deletion, because on_hand and movements rows will reference the '
    'item forever and RESTRICT says so.';

-- ---------------------------------------------------------------------------
-- 2b. Privileges on what this migration created
-- ---------------------------------------------------------------------------
-- A function is born with EXECUTE granted to PUBLIC, so without this paragraph the
-- view-only audit account could invoke the close-out path - the writes inside would still
-- fail on table privileges (both functions are SECURITY INVOKER), but "it errored on the
-- UPDATE" is not the same guarantee as "it cannot try". Rehearsed by the audit probe after
-- 0008: afpc_auditor reached line 13 of decommission_warehouse before anything complained.
-- The other thirteen functions carry the same PUBLIC grant; sweeping those, and the
-- ALTER DEFAULT PRIVILEGES that stops it recurring, belongs with the access-model work in
-- 0009 - recorded in db/MIGRATIONS.md.

REVOKE EXECUTE ON FUNCTION decommission_warehouse(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION retire_item(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION decommission_warehouse(uuid) TO afpc_app;
GRANT  EXECUTE ON FUNCTION retire_item(uuid) TO afpc_app;

-- ---------------------------------------------------------------------------
-- 3. Verify, by attempting the destructions
-- ---------------------------------------------------------------------------
-- A catalog read of confdeltype proves the edge changed. It does not prove the deletion is
-- refused - and unlike 0006's index question, a RESTRICT rejection is size-independent: it
-- is the same answer with one row or a million, so it CAN be proven here, with fixtures
-- that each subtransaction erases.
DO $$
DECLARE
    v_wh      uuid;
    v_it      uuid;
    v_lo      uuid;
    v_se      uuid;
    v_n       int := 0;
BEGIN
    SET LOCAL app.tenant_id = '00000000-0000-0000-0000-000000000001';

    -- 3.1 measurement A: a warehouse holding stock that never moved.
    BEGIN
        INSERT INTO warehouses (warehouse_code, name, warehouse_type)
            VALUES ('AFPC-0008-PROTECT', '0008 protection probe', 'PRIMARY')
        RETURNING warehouse_id INTO v_wh;
        INSERT INTO inventory_items (sku, name, product_type)
            VALUES ('AFPC-0008-A', '0008 stocked item', 'STOCKED')
        RETURNING item_id INTO v_it;
        INSERT INTO inventory_on_hand (item_id, warehouse_id, quantity_on_hand)
            VALUES (v_it, v_wh, 40);
        DELETE FROM warehouses WHERE warehouse_id = v_wh;
        RAISE EXCEPTION '5.10 not fixed: deleting a warehouse destroyed the stock holding '
                        'inside it';
    EXCEPTION WHEN foreign_key_violation THEN
        v_n := v_n + 1;
        RAISE NOTICE 'probe A: a warehouse holding stock cannot be deleted (refused by % - '
                     'subtransaction erased the fixture)', 'inventory_on_hand_warehouse_id_fkey';
    END;

    -- 3.2 measurement D: the bin delete that used to be silent or misattributed.
    BEGIN
        INSERT INTO warehouses (warehouse_code, name, warehouse_type)
            VALUES ('AFPC-0008-BIN', '0008 bin probe', 'PRIMARY')
        RETURNING warehouse_id INTO v_wh;
        INSERT INTO inventory_items (sku, name, product_type)
            VALUES ('AFPC-0008-B', '0008 binned item', 'STOCKED')
        RETURNING item_id INTO v_it;
        INSERT INTO locations (warehouse_id, location_code, location_type)
            VALUES (v_wh, '0008-1', 'STORAGE')
        RETURNING location_id INTO v_lo;
        INSERT INTO inventory_on_hand (item_id, warehouse_id, location_id, quantity_on_hand)
            VALUES (v_it, v_wh, v_lo, 6);
        DELETE FROM locations WHERE location_id = v_lo;
        RAISE EXCEPTION '5.10 not fixed: deleting a bin silently re-homed the stock it held';
    EXCEPTION
        WHEN foreign_key_violation THEN
            v_n := v_n + 1;
            RAISE NOTICE 'probe B: a bin holding stock cannot be deleted (it must be emptied '
                         'by a movement first - the silent re-home and its 23505 twin are both gone)';
        WHEN unique_violation THEN
            RAISE EXCEPTION '5.10 half-fixed: the bin delete still fails through 0004''s '
                            'identity index rather than through its own constraint';
    END;

    -- 3.3 measurement C: the audit trail.
    BEGIN
        INSERT INTO human_sessions (user_id, user_name, bot_id, bot_type, session_status, login_time)
            VALUES ('999008', 'probe', 'afpc-0008-bot', 'orchestrator', 'active', now())
        RETURNING session_id INTO v_se;
        INSERT INTO bot_actions (session_id, user_id, bot_id, action_type,
                                 action_description, success)
            VALUES (v_se, '999008', 'afpc-0008-bot', 'probe_tool', 'the action 5.10 refuses '
                    'to let vanish', true);
        DELETE FROM human_sessions WHERE session_id = v_se;
        RAISE EXCEPTION '5.10 not fixed: deleting a session destroyed the audit trail';
    EXCEPTION WHEN foreign_key_violation THEN
        v_n := v_n + 1;
        RAISE NOTICE 'probe C: a session with agent actions cannot be deleted - the audit '
                     'outlives the login that produced it';
    END;

    -- 3.4 the retained CASCADE, proven to mean what section 1 says it means: bins that are
    --     pure structure still go with the warehouse. The sentinel exception rolls the probe
    --     back; the deletes before it prove the cascade fires.
    BEGIN
        INSERT INTO warehouses (warehouse_code, name, warehouse_type)
            VALUES ('AFPC-0008-COMP', '0008 composition probe', 'PRIMARY')
        RETURNING warehouse_id INTO v_wh;
        INSERT INTO locations (warehouse_id, location_code, location_type)
            VALUES (v_wh, 'EMPTY-1', 'STORAGE'), (v_wh, 'EMPTY-2', 'PICK');
        DELETE FROM warehouses WHERE warehouse_id = v_wh;
        IF EXISTS (SELECT 1 FROM locations WHERE warehouse_id = v_wh) THEN
            RAISE EXCEPTION '5.10 overshoot: the retained CASCADE no longer cascades - empty '
                            'bins survived their warehouse';
        END IF;
        RAISE EXCEPTION '0008 composition probe passed' USING ERRCODE = 'P8001';
    EXCEPTION
        WHEN foreign_key_violation THEN
            RAISE EXCEPTION 'probe D: deleting an EMPTY warehouse is now refused - RESTRICT '
                            'spread beyond the facts it protects into the structure it does not';
        WHEN SQLSTATE 'P8001' THEN
            -- The sentinel carries its own SQLSTATE rather than sharing raise_exception with
            -- the overshoot failure, so the pass signal cannot be confused with a bug signal
            -- by matching message text. Any other P0001 raised above propagates uncaught.
            v_n := v_n + 1;
            RAISE NOTICE 'probe D: bins that are pure structure still cascade with the '
                         'warehouse - composition, kept on purpose';
    END;

    IF v_n <> 4 THEN
        RAISE EXCEPTION 'expected 4 verified behaviours, got %', v_n;
    END IF;
END
$$;

-- 3.5 The privileges, asserted rather than assumed. A REVOKE that does not match a grant is
--     silent, and "the audit account cannot try" is exactly the kind of claim that should not
--     rest on a paragraph of prose.
DO $$
DECLARE
    v text;
BEGIN
    SELECT string_agg(f, ', ') INTO v FROM (VALUES
        ('decommission_warehouse(uuid)'), ('retire_item(uuid)')) q(f)
     WHERE has_function_privilege('afpc_auditor', format('public.%s', f)::regprocedure, 'EXECUTE')
        OR has_function_privilege('afpc_readonly', format('public.%s', f)::regprocedure, 'EXECUTE')
        OR NOT has_function_privilege('afpc_app', format('public.%s', f)::regprocedure, 'EXECUTE');
    IF v IS NOT NULL THEN
        RAISE EXCEPTION 'close-out privileges wrong for: % - audit and read-only accounts must '
                        'not be able to invoke a write path, and afpc_app must', v;
    END IF;
    RAISE NOTICE 'close-out functions: executable by afpc_app only, refused to the read roles';

    -- And the census this migration deliberately leaves for 0009: functions still born with
    -- PUBLIC EXECUTE. Printed so the number moves when someone sweeps them.
    SELECT count(*) INTO v FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f'
       AND has_function_privilege('afpc_auditor', p.oid, 'EXECUTE')
       AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e');
    RAISE NOTICE 'functions still executable by every role (PUBLIC default, 0009''s to sweep): %', v;
END
$$;

-- 3.6 The cost of the re-validation, reported not assumed (same courtesy as 0006 section 5.6).
DO $$
DECLARE
    v text;
BEGIN
    SELECT string_agg(t, ', ' ORDER BY rows DESC) INTO v FROM (
        SELECT relname || '=' || n_live_tup || ' rows' AS t, n_live_tup AS rows
          FROM pg_stat_user_tables
         WHERE relname IN ('inventory_on_hand', 'inventory_reservations', 'bot_actions')
    ) x;
    RAISE NOTICE 'delete rules now RESTRICT on every stock and audit edge; edges re-validated '
                 'across: %', coalesce(v, '(no statistics yet)');
END
$$;
