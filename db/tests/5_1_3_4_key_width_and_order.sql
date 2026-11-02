-- Findings 5.1, 5.3 and 5.4, observed as behaviour.
--
-- 5.2 has its own file because its symptom is an error at the moment of insert. These are
-- quieter: a column that is merely the wrong width, and a key distribution that is merely
-- bad, both look completely normal in the catalog. 0005's own verification reads types,
-- and reading a type is exactly what failed for 5.2 - "it loads and validates" was the
-- review's phrase. So this file asks what the database DOES.
--
-- Sequences are not transactional. scripts/db/test-functions.sh restores every serial
-- counter from its table after the run, which is why the setval calls here do not have to
-- undo themselves.

-- 5.1/5.3 - the ceiling, as an end-to-end path rather than a column type.
--
-- The point is not that entities.id can hold 2^31+1. It is that a row can exist there, be
-- referenced by a communication, be threaded, and be read back through the views and the
-- functions an agent actually calls. Any single integer still in that chain makes the
-- whole feature fail at a row count, in production, on a Tuesday.
BEGIN;
DO $$
DECLARE
    v_dummy  bigint;
    v_ent    bigint;
    v_other  bigint;
    v_msg    bigint;
    v_reply  bigint;
    v_rows   int;
BEGIN
    SELECT setval('entities_id_seq', 2147483647, true) INTO v_dummy;
    INSERT INTO entities (name) VALUES ('AFPC Ceiling Entity') RETURNING id INTO v_ent;

    IF v_ent <= 2147483647 THEN
        RAISE NOTICE 'VERDICT INFO could not reach the ceiling (id=%) - the sequence is '
                     'not an integer one, so this case cannot fire', v_ent;
        RETURN;
    END IF;

    INSERT INTO contacts (first_name, last_name)
        VALUES ('AFPC', 'CeilingContact') RETURNING id INTO v_other;
    INSERT INTO entity_relationships (entity_id, contact_id, relationship_type)
        VALUES (v_ent, v_other, 'primary');
    INSERT INTO communications (entity_id, contact_id, communication_type, direction, summary)
        VALUES (v_ent, v_other, 'email', 'inbound', 'root beyond 2^31')
        RETURNING id INTO v_msg;

    -- Reply to it. Before 0005 this is the statement that raised 22003, because
    -- parent_id was integer and the parent id was not.
    BEGIN
        INSERT INTO communications (entity_id, contact_id, communication_type, direction,
                                    summary, parent_id, thread_root_id)
             VALUES (v_ent, v_other, 'email', 'outbound', 'reply', v_msg, v_msg)
             RETURNING id INTO v_reply;
        RAISE NOTICE 'VERDICT OK threaded a reply to a message at id=%', v_msg;
    EXCEPTION WHEN numeric_value_out_of_range WHEN raise_exception THEN
        RAISE NOTICE 'VERDICT ERR threading dies here: %', left(SQLERRM, 90);
        RETURN;
    END;

    -- And read the whole thing back the way an agent tool would: through the view.
    SELECT count(*) INTO v_rows FROM vw_customer_communications_summary
     WHERE entity_id = v_ent;
    IF v_rows >= 2 THEN
        RAISE NOTICE 'VERDICT OK vw_customer_communications_summary returns the big-id '
                     'rows (%), so no view is still narrowing them', v_rows;
    ELSE
        RAISE NOTICE 'VERDICT ERR the view returned % rows for entity % - a cast is '
                     'swallowing them', v_rows, v_ent;
    END IF;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'VERDICT ERR % | the >2^31 path failed: %', SQLSTATE, left(SQLERRM, 90);
END
$$;
ROLLBACK;

-- 5.1 - the same ceiling through the FUNCTION layer. add_customer returns entity_id; if
-- that OUT column is still integer, the widening stopped at the schema and the API raises
-- where the table would not. Called with all ten positional arguments, which is the form
-- 0016 is meant to make unambiguous; until then an ambiguity error here is the known 4.4,
-- and this case deliberately reports it as INFO rather than pretending it passed.
BEGIN;
DO $$
DECLARE
    v_dummy bigint;
    v_ent   bigint;
    v_ok    boolean := false;
    r       record;
BEGIN
    SELECT setval('entities_id_seq', 2147483647, true) INTO v_dummy;
    BEGIN
        FOR r IN SELECT * FROM add_customer('AFPC', 'CeilingPerson',
                                           'ceiling-51@example.com', '555-0231',
                                           NULL, NULL, NULL, NULL, 'US', 'active')
        LOOP
            v_ent := r.entity_id;
            v_ok  := r.success;
        END LOOP;

        IF NOT v_ok THEN
            RAISE NOTICE 'VERDICT INFO add_customer reported failure, so no id to check';
        ELSIF v_ent > 2147483647 THEN
            RAISE NOTICE 'VERDICT OK add_customer handed back entity_id=% past 2^31 - the '
                         'OUT columns are as wide as the columns they come from', v_ent;
        ELSE
            -- The function returned a small id even though the sequence was pushed past
            -- 2^31, which means the value passed through an integer on its way out.
            RAISE NOTICE 'VERDICT ERR add_customer returned entity_id=% while the table '
                         'was handing out % - the API is narrower than the schema',
                         v_ent, (SELECT max(id) FROM entities);
        END IF;
    EXCEPTION WHEN ambiguous_function THEN
        -- A call failure is finding 4.4, not 5.1. Saying so is the honest outcome: the
        -- 5_8-style "ERR because something else is broken" row is how a harness starts
        -- teaching people to ignore it.
        RAISE NOTICE 'VERDICT INFO add_customer is ambiguous (finding 4.4, closed by 0016); '
                     'its OUT types are asserted structurally by 0005 section 8.5';
    WHEN OTHERS THEN
        RAISE NOTICE 'VERDICT ERR % | add_customer could not be called: %',
            SQLSTATE, left(SQLERRM, 80);
    END;
END
$$;
ROLLBACK;

-- 5.4 - are the keys actually arriving in order?
--
-- This is the only assertion in the suite that can tell a time-ordered generator from a
-- random one, and it cannot be made by reading a column default: the default could name
-- any function at all. A dozen keys are inserted, their physical order is compared with
-- their key order, and the btree is asked how full its leaf pages are.
BEGIN;
DO $$
DECLARE
    i        int;
    back     int := 0;
    rows_    int := 0;
BEGIN
    CREATE TEMP TABLE _afpc_t_54 (id uuid PRIMARY KEY DEFAULT afpc_uuid_v7(), n int)
        ON COMMIT DROP;
    -- Insert in small batches with a yielding pause, which is what a ledger does. A single
    -- generate_series insert would let Postgres evaluate every default in one instant, and
    -- then the assertion below would be measuring the random tail rather than the clock.
    -- 10 batches of 10 rather than 40: the ordering property does not need more, and this
    -- file runs inside a harness against a database that persists for the life of the
    -- project, so wall-clock cost is a real cost.
    FOR i IN 1..10 LOOP
        INSERT INTO _afpc_t_54 (n) SELECT i * 10 + g FROM generate_series(1, 10) g;
        PERFORM pg_sleep(0.003);
    END LOOP;

    SELECT count(*) INTO rows_ FROM _afpc_t_54;

    SELECT count(*) INTO back FROM (
        SELECT id, lag(id) OVER (ORDER BY n) AS prev_id FROM _afpc_t_54
    ) z WHERE z.prev_id IS NOT NULL AND z.id <= z.prev_id;

    IF back = 0 THEN
        RAISE NOTICE 'VERDICT OK % keys inserted in key order - the btree appends', rows_;
    ELSIF back::numeric / greatest(rows_, 1) < 0.02 THEN
        RAISE NOTICE 'VERDICT OK % of % keys out of order: keys minted inside one shared '
                     'microsecond, which is unordered by design', back, rows_;
    ELSE
        RAISE NOTICE 'VERDICT ERR % of % keys arrived out of order - the key default is '
                     'still scattering', back, rows_;
    END IF;

    -- The same claim from the other side: a random default produces roughly half its keys
    -- out of order. Counting distinct millisecond buckets distinguishes "monotonic but
    -- coarse" from "random", which no row-count check can see.
    IF (SELECT count(DISTINCT substring(replace(id::text,'-','') from 1 for 12))
          FROM _afpc_t_54) > 1 THEN
        RAISE NOTICE 'VERDICT INFO keys span % distinct millisecond buckets',
            (SELECT count(DISTINCT substring(replace(id::text,'-','') from 1 for 12))
               FROM _afpc_t_54);
    END IF;
END
$$;

-- 5.4 and the sentinel from 0004: a time-ordered key can never collide with the nil UUID,
-- which a random one could in principle have done. Worth asserting because 0004's identity
-- index treats the nil UUID as "no bin", and that reasoning is only sound if real keys
-- never land there.
DO $$
DECLARE i int; hit uuid;
BEGIN
    FOR i IN 1..20000 LOOP
        hit := afpc_uuid_v7();
        IF hit = '00000000-0000-0000-0000-000000000000'::uuid THEN
            RAISE NOTICE 'VERDICT ERR afpc_uuid_v7() generated the no-bin sentinel';
            RETURN;
        END IF;
    END LOOP;
    RAISE NOTICE 'VERDICT OK 20000 keys, none of them the nil-UUID sentinel';
END
$$;
ROLLBACK;
