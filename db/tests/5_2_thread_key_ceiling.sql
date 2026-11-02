-- Finding 5.2: communications.parent_id and thread_root_id are integer columns
-- pointing at a bigint key. The FK loads and validates because Postgres applies an
-- implicit narrowing cast, so the defect is invisible at rest and in pg_constraint -
-- it fires only once id passes 2^31. These cases make the time bomb observable today.
--
-- Sequences are not transactional, so the counter this file advances is restored by
-- scripts/db/test-functions.sh from the table, not from the transaction.

-- 5a. The ceiling.
BEGIN;
DO $$
DECLARE
    v_ent    int;
    v_parent bigint;
BEGIN
    INSERT INTO entities (name) VALUES ('Ceiling Probe') RETURNING id INTO v_ent;
    -- is_called = true, so the next id handed out is 2147483648, one past integer.
    PERFORM setval('communications_id_seq', 2147483647, true);

    INSERT INTO communications (entity_id, communication_type, direction, summary)
        VALUES (v_ent, 'note', 'inbound', 'row beyond 2^31')
        RETURNING id INTO v_parent;

    IF v_parent <= 2147483647 THEN
        RAISE NOTICE 'VERDICT OK could not reach the ceiling (id=%)', v_parent;
        RETURN;
    END IF;

    RAISE NOTICE 'VERDICT INFO parent row accepted with id=% because the key is bigint', v_parent;

    BEGIN
        INSERT INTO communications (entity_id, communication_type, direction, summary, parent_id)
            VALUES (v_ent, 'note', 'inbound', 'reply to that row', v_parent);
        RAISE NOTICE 'VERDICT ERR 00000 | and the reply was accepted too - unexpected';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'VERDICT ERR % | threading dies here: %', SQLSTATE, left(SQLERRM, 90);
    END;
END
$$;
ROLLBACK;

-- 5b. thread_root_id has no foreign key at all, so the denormalised anchor can point
-- at a row that never existed - a defect in kind, not merely in degree.
BEGIN;
DO $$
DECLARE
    v_ent int;
    v_fk  int;
    n     int;
BEGIN
    SELECT count(*) INTO v_fk FROM pg_constraint
     WHERE conrelid = 'communications'::regclass
       AND conkey @> ARRAY[(SELECT attnum FROM pg_attribute
                            WHERE attrelid = 'communications'::regclass
                              AND attname = 'thread_root_id')]::int2[]
       AND contype = 'f';

    INSERT INTO entities (name) VALUES ('Anchor Probe') RETURNING id INTO v_ent;
    INSERT INTO communications (entity_id, communication_type, direction, summary, thread_root_id)
        VALUES (v_ent, 'note', 'inbound', 'dangling anchor', 987654321);
    SELECT count(*) INTO n FROM communications WHERE thread_root_id = 987654321;

    IF n > 0 AND v_fk = 0 THEN
        RAISE NOTICE 'VERDICT ERR 00000 | thread_root_id has no FK and accepted a reference to a nonexistent row';
    elsif n > 0 THEN
        RAISE NOTICE 'VERDICT ERR 00000 | dangling reference stored although an FK exists';
    ELSE
        RAISE NOTICE 'VERDICT OK dangling anchor rejected';
    END IF;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'VERDICT OK dangling anchor rejected: %', left(SQLERRM, 80);
END
$$;
ROLLBACK;
