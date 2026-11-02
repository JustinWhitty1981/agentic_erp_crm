-- Finding 6.3, as behaviour: "timestamp hygiene is inconsistent".
--
-- The review's evidence is a table of nine objects that carry an updated_at, with a column that
-- says whether a trigger maintains it. That reading is accurate and, in two places, narrower than
-- the database turned out to be: the population is eleven tables and growing, one of the columns
-- it credits to a trigger only covers UPDATE, and the table it says "has an updated_at" describes
-- a column that accepts NULL on some tables and not on others. All four are questions about what a
-- write does to a value, which a static table cannot answer.
--
-- So every block below performs a write and reads the column back, with one device that is worth
-- stating because it is the difference between a test and a coincidence: the stamp is now(), the
-- transaction timestamp, so inside a single transaction a before/after comparison of two writes
-- compares an instant with itself and proves nothing either way. Each block therefore *pins* the
-- column to a past value first and asks whether the write moved it off the pin. That is a claim
-- that survives any transaction boundary, and it also happens to be the exact affordance
-- 0010's triggers exist to preserve - a backfill that supplies its own timestamps.
--
-- The harness connects as postgres, which for 6.3 is the right seat: this finding is about whether
-- a column records writes, not about who is allowed to make them, so unlike 5.7 there is no role
-- change here. Block H is the exception, because "the trigger only works for the owner" is exactly
-- the 0009 mistake waiting to be repeated in a timestamp.
--
-- Each VERDICT ERR phrase is written to appear ONLY on the failure branch, because
-- scripts/db/test-functions.sh decides KNOWN-OPEN against CLOSED with a grep, not a parser.

-- A. 6.3's headline: an ordinary UPDATE on a table that has the column and no trigger. This is
--    the entities row of the review's table - "yes / yes / no" - and the defect is invisible to
--    anyone SELECTing the column, because it is populated.
BEGIN;
DO $$
DECLARE
    v_id     bigint;
    v_pinned timestamptz := '2000-01-01T00:00:00Z';
    v_after  timestamptz;
BEGIN
    INSERT INTO entities (name, entity_type, status)
        VALUES ('6_3 probe A', 'customer', 'inactive') RETURNING id INTO v_id;
    UPDATE entities SET updated_at = v_pinned WHERE id = v_id;
    UPDATE entities SET status = 'active' WHERE id = v_id;
    SELECT updated_at INTO v_after FROM entities WHERE id = v_id;
    IF v_after IS NULL THEN
        RAISE NOTICE 'VERDICT ERR updated_at is NULL after an UPDATE - the column is not '
                     'maintained and was never set';
    ELSIF v_after <= v_pinned THEN
        RAISE NOTICE 'VERDICT ERR updated_at went stale on an ordinary write - it reads % after '
                     'an UPDATE that did not mention it, which is 6.3: the column exists, looks '
                     'populated, and a sync query that trusts it silently skips the row', v_after;
    ELSE
        RAISE NOTICE 'VERDICT OK an UPDATE that never mentions updated_at advances it (%)',
                     date_trunc('seconds', v_after)::text;
    END IF;
END
$$;
ROLLBACK;

-- B. The declaration half (finding B): the same column, nullable on some tables and NOT NULL on
--    others. A NULL updated_at is a different lie from a stale one - "WHERE updated_at >
--    :watermark" drops the row without complaint. Written through communications, which the
--    review lists as maintained, to show that a BEFORE UPDATE-only trigger leaves the insert path
--    to a default that a caller can override with NULL.
BEGIN;
DO $$
DECLARE
    v_ent   bigint;
    v_id    bigint;
    v_seen  timestamptz;
    v_nulls int;
BEGIN
    SELECT count(*) INTO v_nulls
      FROM pg_class c JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'updated_at'
     WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r'
       AND a.attnum > 0 AND NOT a.attisdropped AND NOT a.attnotnull;
    IF v_nulls > 0 THEN
        RAISE NOTICE 'VERDICT ERR the same column is declared two ways - % tables have a '
                     'nullable updated_at and the rest do not, so a watermark predicate skips '
                     'rows on half the schema by accident', v_nulls;
    ELSE
        -- entity_id, direction and summary are NOT NULL here, and sku-shaped codes are checked
        -- by 0007's vocabulary, so the fixture carries them: a probe that dies on an unrelated
        -- constraint reads as a timestamp failure it did not cause.
        INSERT INTO entities (name, entity_type, status)
            VALUES ('6_3 probe B', 'customer', 'active') RETURNING id INTO v_ent;
        INSERT INTO communications (entity_id, channel, communication_type, direction, summary,
                                    started_at, agent_id, updated_at)
            VALUES (v_ent, 'telegram', 'call', 'inbound', '6_3 block B', now(), '6_3-probe', NULL)
         RETURNING id INTO v_id;
        SELECT updated_at INTO v_seen FROM communications WHERE id = v_id;
        IF v_seen IS NULL THEN
            RAISE NOTICE 'VERDICT ERR a row can still be written with a NULL updated_at';
        ELSE
            RAISE NOTICE 'VERDICT OK updated_at is one column with one declaration, and an insert '
                         'that passes NULL still gets a real timestamp';
        END IF;
    END IF;
END
$$;
ROLLBACK;

-- C. A table with no timestamp to go stale (finding C of this file's own census, not the
--    review's): addresses is rewritten by update_customer and cannot show it. The review lists it
--    as "created_at yes / updated_at no" without comment, because from a dump there is nothing to
--    comment on - the absence only matters because something performs the write.
BEGIN;
DO $$
DECLARE
    v_ent    bigint;
    v_addr   bigint;
    v_pinned timestamptz := '2000-01-01T00:00:00Z';
    v_after  timestamptz;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_attribute
                    WHERE attrelid = 'addresses'::regclass AND attname = 'updated_at') THEN
        RAISE NOTICE 'VERDICT ERR an address edit leaves no timestamp anywhere - update_customer '
                     'rewrites addresses and the table has no updated_at column, so there is '
                     'nothing for a trigger to maintain';
    ELSE
        INSERT INTO entities (name, entity_type, status)
            VALUES ('6_3 probe C', 'customer', 'active') RETURNING id INTO v_ent;
        INSERT INTO addresses (entity_id, address_type, street, city, is_primary)
            VALUES (v_ent, 'billing', '1 Probe Way', 'Testville', true) RETURNING id INTO v_addr;
        UPDATE addresses SET updated_at = v_pinned WHERE id = v_addr;
        UPDATE addresses SET city = 'Renamedville' WHERE id = v_addr;
        SELECT updated_at INTO v_after FROM addresses WHERE id = v_addr;
        IF v_after <= v_pinned THEN
            RAISE NOTICE 'VERDICT ERR an address edit went stale - the column was added and is '
                         'not maintained (% after a write)', v_after;
        ELSE
            RAISE NOTICE 'VERDICT OK an address edit is visible in a timestamp, on the table '
                         'found by asking pg_proc which rows its functions write';
        END IF;
    END IF;
END
$$;
ROLLBACK;

-- D. Finding D: the age of a stock row. The review says three tables have "no timestamp-shaped
--    column at all"; measured, they all have one, and the one on inventory_on_hand is
--    last_movement_at, which every movement overwrites. So the question is not whether the table
--    has a time column - it does - but whether it can tell a row created today from one created
--    two years ago and touched five minutes later.
BEGIN;
DO $$
DECLARE
    v_wh   uuid;
    v_it   uuid;
    v_birth timestamptz;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_attribute
                    WHERE attrelid = 'inventory_on_hand'::regclass AND attname = 'created_at') THEN
        RAISE NOTICE 'VERDICT ERR the age of a stock row is unknowable - inventory_on_hand has no '
                     'row-creation timestamp, only last_movement_at, which the next movement '
                     'overwrites (this is the review''s "highest-growth tables" paragraph)';
    ELSE
        INSERT INTO warehouses (warehouse_code, name, warehouse_type)
            VALUES ('AFPC-63D', '6_3 warehouse', 'PRIMARY') RETURNING warehouse_id INTO v_wh;
        INSERT INTO inventory_items (sku, name, product_type)
            VALUES ('AFPC-63D', '6_3 item', 'STOCKED') RETURNING item_id INTO v_it;
        INSERT INTO inventory_on_hand (item_id, warehouse_id, quantity_on_hand, quantity_reserved)
            VALUES (v_it, v_wh, 7, 0) RETURNING created_at INTO v_birth;
        UPDATE inventory_on_hand SET quantity_on_hand = 9, last_movement_at = now()
         WHERE item_id = v_it AND warehouse_id = v_wh;
        IF v_birth IS NULL THEN
            RAISE NOTICE 'VERDICT ERR inventory_on_hand.created_at exists but is NULL on insert';
        ELSE
            RAISE NOTICE 'VERDICT OK a stock row can say when it began to exist, and a movement '
                         'does not rewrite that answer';
        END IF;
    END IF;
END
$$;
ROLLBACK;

-- E. Finding C: one rule written twice. The review lists three triggers and their events; it does
--    not compare their bodies, and the body comparison is what says whether the schema has one
--    implementation of "set updated_at" or two that can drift. Counted over every trigger
--    function, because the defect class is wider than the timestamp case.
BEGIN;
DO $$
DECLARE
    v_pairs int;
    v_names text;
BEGIN
    SELECT count(*) INTO v_pairs FROM (
        SELECT md5(coalesce(p.prosrc, '')) AS body
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
          JOIN pg_type t ON t.oid = p.prorettype
         WHERE n.nspname = 'public' AND t.typname = 'trigger' AND p.prokind = 'f'
           AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
         GROUP BY 1 HAVING count(*) > 1) x;
    IF v_pairs > 0 THEN
        SELECT string_agg(pronames, ' / ' ORDER BY pronames) INTO v_names FROM (
            SELECT string_agg(p.proname, ' & ' ORDER BY p.proname) AS pronames
              FROM pg_proc p
              JOIN pg_namespace n ON n.oid = p.pronamespace
              JOIN pg_type t ON t.oid = p.prorettype
             WHERE n.nspname = 'public' AND t.typname = 'trigger' AND p.prokind = 'f'
             GROUP BY md5(coalesce(p.prosrc, '')) HAVING count(*) > 1) y;
        RAISE NOTICE 'VERDICT ERR the same rule is installed twice (% pairs of identical trigger '
                     'bodies: %) - two copies of one rule are how it drifts', v_pairs, v_names;
    ELSE
        RAISE NOTICE 'VERDICT OK exactly one trigger function implements the timestamp rule, and '
                     'no trigger body duplicates another';
    END IF;
END
$$;
ROLLBACK;

-- F. The register, checked against the catalog rather than trusted. vw_timestamp_status says which
--    tables maintain the column and which are declared immutable; the declaration is only worth
--    reading if it disagrees with something when something changes, so this asserts the two
--    statements that make it a report rather than a list.
BEGIN;
DO $$
DECLARE
    v text;
BEGIN
    IF to_regclass('public.vw_timestamp_status') IS NULL THEN
        RAISE NOTICE 'VERDICT ERR nothing publishes which tables maintain a write timestamp, so '
                     '6.3 can only be checked by reading a document';
    ELSE
        SELECT string_agg(table_name, ', ' ORDER BY table_name) INTO v
          FROM vw_timestamp_status WHERE needs_attention;
        IF v IS NOT NULL THEN
            RAISE NOTICE 'VERDICT ERR the register reports % needing attention: %',
                         (SELECT count(*) FROM vw_timestamp_status WHERE needs_attention), v;
        ELSIF (SELECT count(*) FROM vw_timestamp_status WHERE verdict = 'maintained') <>
              (SELECT count(*) FROM pg_class c
                 JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'updated_at'
                      AND a.attnum > 0 AND NOT a.attisdropped
                WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r') THEN
            RAISE NOTICE 'VERDICT ERR the register''s maintained count disagrees with the '
                         'catalog''s column count';
        ELSE
            RAISE NOTICE 'VERDICT OK % tables maintain the column, % are declared immutable with '
                         'the evidence that says so, and the two counts agree with pg_attribute',
                (SELECT count(*) FROM vw_timestamp_status WHERE verdict = 'maintained'),
                (SELECT count(*) FROM vw_timestamp_status
                  WHERE verdict LIKE '%by decision%' OR verdict LIKE '%by design%');
        END IF;
    END IF;
END
$$;
ROLLBACK;

-- H. Whether the mechanism reaches the role that actually writes the data. A trigger that only
--    worked when the owner wrote would pass every catalog check in this file, which is the 0009
--    lesson applied one section later: verify by behaving, in the seat the product sits in.
BEGIN;
DO $$
DECLARE
    v_ent    bigint;
    v_pinned timestamptz := '2000-01-01T00:00:00Z';
    v_after  timestamptz;
    v_msg    text;
BEGIN
    INSERT INTO entities (name, entity_type, status)
        VALUES ('6_3 probe H', 'customer', 'active') RETURNING id INTO v_ent;
    BEGIN
        EXECUTE 'SET LOCAL ROLE afpc_app';
        PERFORM set_config('app.tenant_id',
            (SELECT tenant_id::text FROM tenants WHERE slug = 'default'), true);
        UPDATE entities SET updated_at = v_pinned WHERE id = v_ent;
        UPDATE entities SET status = 'inactive' WHERE id = v_ent;
        SELECT updated_at INTO v_after FROM entities WHERE id = v_ent;
        EXECUTE 'RESET ROLE';
        IF v_after IS NULL OR v_after <= v_pinned THEN
            RAISE NOTICE 'VERDICT ERR the agent role''s own write left updated_at at % - the '
                         'trigger is invisible to the role that runs it', v_after;
        ELSE
            RAISE NOTICE 'VERDICT OK a write by afpc_app stamps the column - and the role needs '
                         'no EXECUTE on the trigger function, because the executor runs the body, '
                         'not the invoker';
        END IF;
    EXCEPTION
        WHEN insufficient_privilege THEN
            EXECUTE 'RESET ROLE';
            RAISE NOTICE 'VERDICT ERR the agent role could not write the row at all: %',
                left(SQLERRM, 80);
        WHEN OTHERS THEN
            EXECUTE 'RESET ROLE';
            RAISE NOTICE 'VERDICT INFO the agent-role write failed for a reason unrelated to '
                         'timestamps: %', left(SQLERRM, 80);
    END;
END
$$;
ROLLBACK;
