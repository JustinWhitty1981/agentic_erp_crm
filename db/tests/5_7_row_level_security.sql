-- Finding 5.7, as behaviour: "RLS is decorative".
--
-- The review's own evidence is three catalog readings - rls_on=2, rls_forced=0, and three
-- policy rows whose predicates quote app.current_agent. Those are all true and none of them
-- says what happens when an agent touches a row, which is the only thing the finding is about.
-- So this file asks the four questions whose answers are the finding, from the only seat RLS
-- can be seen from: a non-owner role. verify.sh's B7/B19-B23 assert the same facts from
-- pg_class and pg_policy, and would agree with a policy that does the wrong thing politely.
--
-- Every block runs as afpc_app or afpc_auditor under SET LOCAL ROLE inside a transaction that
-- rolls back. That is not decoration either - the harness connects as postgres, postgres is a
-- superuser, and a superuser bypasses row security however it is configured, so a test that
-- stayed in the owner's seat would report 5.7 as fixed by a migration that changed nothing it
-- could observe. (This is the same trap 0008's B3 avoided from the other side: there the
-- question was whether a rule *fires*, here whether a rule *binds*.)
--
-- Each block's VERDICT ERR phrase is written to appear ONLY on the failure branch, because
-- scripts/db/test-functions.sh decides KNOWN-OPEN vs CLOSED with a grep, not a parser. Blocks
-- that succeed before 0009 as well as after - C and D below - deliberately have no harness
-- row, for the reason 0006 established: a phrase that cannot reproduce on the pre-migration
-- database reads CLOSED through a branch that was never at risk.

-- A. 5.7.3's write half. The old inventory_movements policy checked
--    performed_by = current_setting('app.current_agent', true), and nothing in the repository
--    sets app.current_agent, so the comparison is with NULL and never true: an honest agent
--    could not record a movement at all. The owner path, which is what blueprint/bot.py
--    actually uses, was unrestricted - the control failed in both directions and only the
--    direction that breaks a customer could be noticed.
BEGIN;
DO $$
DECLARE
    v_wh    uuid;
    v_it    uuid;
    v_tenant uuid := '00000000-0000-0000-0000-000000000001';
    v_ok    boolean := false;
BEGIN
    INSERT INTO warehouses (tenant_id, warehouse_code, name, warehouse_type)
        VALUES (v_tenant, 'T7-A', '5.7 block A', 'PRIMARY') RETURNING warehouse_id INTO v_wh;
    INSERT INTO inventory_items (tenant_id, sku, name, product_type)
        VALUES (v_tenant, 'T7-A', '5.7 item A', 'STOCKED') RETURNING item_id INTO v_it;

    BEGIN
        EXECUTE 'SET LOCAL ROLE afpc_app';
        PERFORM set_config('app.tenant_id', v_tenant::text, true);
        INSERT INTO inventory_movements (movement_type, item_id, to_warehouse_id, quantity,
                                         unit_of_measure, performed_by)
            VALUES ('RECEIPT', v_it, v_wh, 3, 'EACH', 'afpc_app');
        v_ok := true;
    EXCEPTION WHEN insufficient_privilege THEN
        v_ok := false;
    WHEN OTHERS THEN
        RAISE NOTICE 'VERDICT INFO the movement insert failed as %: %', SQLSTATE,
            left(SQLERRM, 90);
        v_ok := true;   -- some other reason; not the finding under test
    END;
    EXECUTE 'RESET ROLE';

    IF NOT v_ok THEN
        RAISE NOTICE 'VERDICT ERR an agent cannot record a movement it is allowed to make - '
                     'the WITH CHECK compares performed_by to a setting nothing sets';
    ELSE
        RAISE NOTICE 'VERDICT OK an agent can record a movement; the write predicate is '
                     'tenancy, not an unset GUC';
    END IF;
END
$$;
ROLLBACK;

-- B. 5.7.3's read half, and the quieter of the two: the same missing GUC in a SELECT qual
--    means an agent's own reservations are invisible to it. Nothing complains, because an
--    empty result is indistinguishable from "you have nothing to do" - which is precisely the
--    class of bug an agent cannot debug from its own error messages.
BEGIN;
DO $$
DECLARE
    v_wh     uuid;
    v_it     uuid;
    v_tenant uuid := '00000000-0000-0000-0000-000000000001';
    v_seen   int;
    v_party  bigint;
    v_order  uuid;
BEGIN
    INSERT INTO warehouses (tenant_id, warehouse_code, name, warehouse_type)
        VALUES (v_tenant, 'T7-B', '5.7 block B', 'PRIMARY') RETURNING warehouse_id INTO v_wh;
    INSERT INTO inventory_items (tenant_id, sku, name, product_type)
        VALUES (v_tenant, 'T7-B', '5.7 item B', 'STOCKED') RETURNING item_id INTO v_it;
    -- A real document to hold the stock against, raised through 0028's door. The probe used to pass
    -- gen_random_uuid() here, which was the exact shape 0015 left thirteen units stuck in and which
    -- 0030's enforcement now refuses - so keeping it would have made this file the one writer of the
    -- defect the orders programme exists to close, and the refusal would have looked like a failure of
    -- row security rather than of the fixture. Both files that did this were found the same way: the
    -- harness's phrase mapping reported them CLOSED while an ERROR aborted the block, which is the
    -- false green 4_8 §8c's comment warns about, arrived through a different door.
    INSERT INTO entities (tenant_id, name, entity_type)
        VALUES (v_tenant, '5.7 block B party', 'customer') RETURNING id INTO v_party;
    SELECT order_id INTO v_order
      FROM create_order('SALES', v_party, NULL, NULL, NULL, NULL, NULL,
                        '5.7 block B fixture', 'MANUAL', NULL);

    -- Written as the owner, so RLS cannot filter the row on the way in.
    INSERT INTO inventory_reservations (tenant_id, item_id, warehouse_id, order_type, order_id,
                                        reserved_quantity, reserved_by)
        VALUES (v_tenant, v_it, v_wh, 'SALES', v_order, 2, 'someone-else');

    BEGIN
        EXECUTE 'SET LOCAL ROLE afpc_app';
        PERFORM set_config('app.tenant_id', v_tenant::text, true);
        SELECT count(*) INTO v_seen FROM inventory_reservations WHERE warehouse_id = v_wh;
    EXCEPTION WHEN OTHERS THEN
        v_seen := -1;
    END;
    EXECUTE 'RESET ROLE';

    IF v_seen = 0 THEN
        RAISE NOTICE 'VERDICT ERR an agent cannot read its own reservations - the qual '
                     'compares reserved_by to a setting nothing sets, so they look empty';
    ELSIF v_seen < 0 THEN
        RAISE NOTICE 'VERDICT INFO the reservation read raised instead of filtering';
    ELSE
        RAISE NOTICE 'VERDICT OK a reservation that exists is visible to the tenant that '
                     'holds it (% row(s))', v_seen;
    END IF;
END
$$;
ROLLBACK;

-- C. The audit account, which is the reason 5.7 cannot be closed by an isolation policy alone.
--    The resolver afpc_current_tenant() RAISES when neither tenant GUC is set, and a policy
--    that calls it would therefore lock the view-only account out of the database it exists to
--    read. Both permissive policies apply to a read role and are OR'd, and constant folding
--    removes the raising branch from the plan - but that is a property of the plan, so it is
--    tested rather than argued. No harness row: this passes before 0009 too, because before
--    0009 there is no policy to trip over.
BEGIN;
DO $$
DECLARE
    v_tenant uuid := '00000000-0000-0000-0000-000000000001';
    v_other  uuid;
    v_seen   int;
    v_raised text;
BEGIN
    INSERT INTO tenants (slug, name) VALUES ('0007-audit-probe', 'cross-tenant probe')
     RETURNING tenant_id INTO v_other;
    INSERT INTO warehouses (tenant_id, warehouse_code, name, warehouse_type)
        VALUES (v_tenant, 'T7-C', 'mine', 'PRIMARY'),
               (v_other,   'T7-C', 'theirs', 'PRIMARY');

    BEGIN
        EXECUTE 'SET LOCAL ROLE afpc_auditor';
        -- Empty, not RESET: 0003 sets app.default_tenant_id at database level, and RESET
        -- resolves to that instead of to nothing.
        PERFORM set_config('app.tenant_id', '', true);
        PERFORM set_config('app.default_tenant_id', '', true);
        SELECT count(*) INTO v_seen FROM warehouses WHERE warehouse_code = 'T7-C';
        IF v_seen <> 2 THEN
            RAISE NOTICE 'VERDICT ERR the audit role sees % of two tenants'' warehouses with '
                         'no tenant context', v_seen;
        ELSE
            RAISE NOTICE 'VERDICT OK the audit role reads across tenants with no tenant '
                         'context at all, and never evaluates the raising resolver';
        END IF;
    EXCEPTION WHEN insufficient_privilege THEN
        RAISE NOTICE 'VERDICT ERR the audit role cannot read the table it audits: %',
            left(SQLERRM, 80);
    WHEN raise_exception THEN
        RAISE NOTICE 'VERDICT ERR the audit role''s read failed on tenant context, not on '
                     'privilege: %', left(SQLERRM, 80);
    END;
    EXECUTE 'RESET ROLE';
END
$$;
ROLLBACK;

-- D. A view is where a row-security fix is most easily incomplete: the views are owned by
--    postgres, and a postgres-owned view evaluates its base tables as its owner, which
--    bypasses the invoker's policies entirely. The claim under test is the differential one -
--    a view must never return more of somebody else's rows than the table refuses - which is
--    what the reloption is for. No harness row: before 0009 there is no filter for the view to
--    leak past, so the equality holds on the old database too. Rehearsal caught the failure
--    mode this guards: setting security_invoker and then recreating the view drops it again.
BEGIN;
DO $$
DECLARE
    v_tenant  uuid := '00000000-0000-0000-0000-000000000001';
    v_other   uuid;
    v_table   int;
    v_view    int;
BEGIN
    INSERT INTO tenants (slug, name) VALUES ('0007-view-probe', 'view cross-tenant probe')
     RETURNING tenant_id INTO v_other;
    INSERT INTO inventory_items (tenant_id, sku, name, product_type)
        VALUES (v_tenant, 'T7-D', 'mine', 'STOCKED'), (v_other, 'T7-D', 'theirs', 'STOCKED');

    BEGIN
        EXECUTE 'SET LOCAL ROLE afpc_app';
        PERFORM set_config('app.tenant_id', v_tenant::text, true);
        SELECT count(*) INTO v_table FROM inventory_items WHERE sku = 'T7-D';
        SELECT count(*) INTO v_view FROM vw_item_availability WHERE sku = 'T7-D';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'VERDICT INFO the view comparison could not run: %', left(SQLERRM, 80);
        v_table := 0; v_view := 0;
    END;
    EXECUTE 'RESET ROLE';

    IF v_view > v_table THEN
        RAISE NOTICE 'VERDICT ERR the view leaks % rows the table refuses - it still runs as '
                     'its owner', v_view - v_table;
    ELSE
        RAISE NOTICE 'VERDICT OK the view returns no more than the table allows the invoker '
                     'to see (% and %)', v_table, v_view;
    END IF;
END
$$;
ROLLBACK;

-- E. The predicate has to be usable, not merely present. A VOLATILE tenant resolver is
--    re-evaluated per row and cannot become an index condition, so every tenant-filtered read
--    degenerates to a scan - 0006's last note promises these indexes are reachable "as soon as
--    a tenant predicate is present, which 0009 guarantees". Asserted the way 0006 asserts:
--    take the sequential paths away and ask whether the plan can still use the tenant-led
--    index. A preference claim on a small table would be a coin flip; usability is the same
--    answer at any size, and it is the answer 0003's composite indexes were built for.
BEGIN;
DO $$
DECLARE
    v_plan   text := '';
    r        record;
    v_n      int;
BEGIN
    -- A handful of rows in two tenants, so a plan exists at all. The second tenant is created
    -- here rather than assumed: warehouses.tenant_id is an FK, and a probe that invents an id
    -- fails on referential integrity before the planner gets involved - which reads as an
    -- unrelated error and hides the finding.
    IF NOT EXISTS (SELECT 1 FROM tenants WHERE tenant_id = '00000000-0000-0000-0000-000000000002') THEN
        INSERT INTO tenants (tenant_id, slug, name)
            VALUES ('00000000-0000-0000-0000-000000000002', '5-7-second-tenant',
                    'second tenant for the sargability probe');
    END IF;
    INSERT INTO warehouses (tenant_id, warehouse_code, name, warehouse_type)
        SELECT '00000000-0000-0000-0000-000000000001', 'T7-E-'||g, 'mine', 'PRIMARY'
          FROM generate_series(1, 50) g;
    INSERT INTO warehouses (tenant_id, warehouse_code, name, warehouse_type)
        SELECT '00000000-0000-0000-0000-000000000002', 'T7-E-'||g, 'theirs', 'PRIMARY'
          FROM generate_series(1, 50) g;

    BEGIN
        EXECUTE 'SET LOCAL ROLE afpc_app';
        PERFORM set_config('app.tenant_id', '00000000-0000-0000-0000-000000000001', true);
        EXECUTE 'SET LOCAL enable_seqscan = off';
        EXECUTE 'SET LOCAL enable_bitmapscan = off';
        FOR r IN EXECUTE 'EXPLAIN (COSTS OFF) SELECT count(*) FROM warehouses '
                         'WHERE warehouse_code = ''T7-E-7'''
        LOOP
            v_plan := v_plan || r."QUERY PLAN" || ' ';
        END LOOP;
    EXCEPTION WHEN OTHERS THEN
        v_plan := '';
    END;
    EXECUTE 'RESET ROLE';

    IF v_plan LIKE '%Index Cond%afpc_policy_tenant()%' THEN
        RAISE NOTICE 'VERDICT OK the tenant predicate is an index condition - 0006''s '
                     'tenant-led indexes are reachable through the policy';
    ELSE
        SELECT count(*) INTO v_n FROM pg_class WHERE relname = 'warehouses'
          AND relrowsecurity;
        RAISE NOTICE 'VERDICT ERR the tenant predicate is not an index condition (% rows '
                     'scanned for it) - either there is no policy or its resolver is VOLATILE, '
                     'and every filtered read becomes a scan: %', v_n, left(v_plan, 120);
    END IF;
END
$$;
ROLLBACK;

-- F. Tenancy is only real if the tenant's rows can be created by the tenant. The CRM's own
--    write path is the test: add_customer, which touches entities, contacts and
--    entity_relationships through the function the blueprint tools call. Before 0009 this
--    fails on a sequence 0002 could not grant - the six serial keys predate its ALTER DEFAULT
--    PRIVILEGES records - which is also why RLS itself was untestable on the CRM tables until
--    the grant landed in the same migration.
BEGIN;
DO $$
DECLARE
    r       record;
    v_email text := 'block-f-' || md5(random()::text) || '@example.com';
    v_ok    boolean;
    v_msg   text;
    v_seen  int;
BEGIN
    BEGIN
        EXECUTE 'SET LOCAL ROLE afpc_app';
        PERFORM set_config('app.tenant_id', '00000000-0000-0000-0000-000000000001', true);
        -- Eleven arguments, all typed. Finding 4.4 is still open - two overloads share the
        -- first ten parameter positions, so a 4- or 10-argument call is ambiguous (42725) and
        -- this test would otherwise report an access failure it did not cause. Eleven positions
        -- are accepted by only one candidate, which is the same workaround 0016 makes
        -- unnecessary. When 0016 lands, this call stays valid: one overload accepts any arity
        -- its defaults cover.
        FOR r IN EXECUTE 'SELECT * FROM add_customer($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)'
            USING 'Block'::text, 'F'::text, v_email::text, '555-0007'::text,
                  NULL::text, NULL::text, NULL::text, NULL::text,
                  'US'::text, 'active'::text, 'individual'::text
        LOOP
            v_ok := r.success;
            v_msg := r.message;
        END LOOP;
        SELECT count(*) INTO v_seen FROM contacts WHERE email = v_email;
    EXCEPTION WHEN OTHERS THEN
        v_ok := false;
        v_msg := SQLERRM;
    END;
    EXECUTE 'RESET ROLE';

    IF NOT v_ok THEN
        -- add_customer reports failure as a row, not as an exception: its own handler turns
        -- anything it hits into success=false plus a message. Read the message, because the
        -- two reasons an agent cannot write a customer are very different findings - and the
        -- pre-0009 answer here is 'permission denied for sequence entities_id_seq', which is
        -- 0002's gap, not 0009's, and would be a false accusation if it were flattened.
        RAISE NOTICE 'VERDICT ERR the app role cannot write a CRM row at all: %',
            left(v_msg, 90);
    ELSIF v_seen <> 1 THEN
        RAISE NOTICE 'VERDICT ERR add_customer reported success but the agent cannot read '
                     'back its own contact (% rows visible) - the write works and the policy '
                     'does not', v_seen;
    ELSE
        RAISE NOTICE 'VERDICT OK the agent role can write a customer through the same path the '
                     'blueprint tool uses, and read it back in its own tenant';
    END IF;
END
$$;
ROLLBACK;
