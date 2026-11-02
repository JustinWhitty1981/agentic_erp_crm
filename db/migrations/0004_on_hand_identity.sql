-- 0004: give inventory_on_hand a row identity (DATABASE_REVIEW.md 4.2, plan P1.2).
--
-- Review 4.2 measured two things about the same missing fact:
--   * execute_inventory_movement's ON CONFLICT target cannot be satisfied, because no
--     unique index covers those columns - the receipt branch of the hot inventory path
--     fails with 42P10 on every call;
--   * nothing prevents duplicate stock rows for one item/warehouse. The review's own
--     probe inserted 3 and read 3 back.
-- Those are one defect seen from two sides. A balance query over two rows has no single
-- answer, which is why the fix is a constraint rather than a dedup job.
--
-- THE CONSTRAINT THAT SHAPES THIS MIGRATION, established by experiment:
--
--     arbiter (a,b,c,d)            vs index (a,b,c,d)             -> inferable
--     arbiter (a,b,c,d)            vs index (a,b,c,d,tenant_id)   -> 42P10
--     arbiter (a,b,c,d)            vs index (tenant_id,a,b,c,d)   -> 42P10
--     arbiter (a,b,c,d,tenant_id)  vs index (a,b,c,d,tenant_id)   -> inferable
--     arbiter (a,b,c,d,tenant_id)  vs index (tenant_id,a,b,c,d)   -> inferable
--
-- The arbiter must name exactly the index's key columns, as a SET. Their relative order
-- is irrelevant - the last two rows are one query against indexes differing only in where
-- tenant_id sits. What is not allowed is a column on either side that the other lacks, so
-- "an expression index can be inferred into on a prefix" is false, and so is the
-- comforting corollary that adding a column to a unique index is a safe change.
-- db/tests/0_0_conflict_inference_rule.sql runs all five cases. It exists because this
-- was got wrong twice by reading psql line numbers, which attribute to the statement
-- AFTER the one that errored: an earlier revision of this migration confidently claimed
-- that column ORDER decided inference, and built a tenant-last index on that basis.
--
-- Because the set is what matters, the identity index can lead with tenant_id - what plan
-- 2.1 asks for and what every other tenant-scoped index in this schema does - provided the
-- arbiter names tenant_id too. So the index and the function's ON CONFLICT clause change
-- together here; leaving that to 0014 would mean shipping an identity index nothing can
-- infer into, which is inert.
--
-- What this means for the plan: 0014 no longer owes the ON CONFLICT line, only the
-- movement contract (4.1's unit_of_measure, the ISSUE branch, the cost divisor). The
-- split is honest as long as it is written down, so it is written in db/MIGRATIONS.md.
--
-- Deliberately NOT done here:
--   * quantity_available as a generated column (on_hand - reserved). It is the right end
--     state, and the baseline already asserts the relationship as a CHECK
--     (chk_available_calculation) rather than computing it - so the drift is that the
--     receipt path increments quantity_on_hand and leaves quantity_available at its
--     default, which the CHECK should already reject. Worth understanding before
--     touching; see the probe in db/tests/4_7_available_check.sql.
--   * The ISSUE/ADJUSTMENT branch's silent zero-row update. A unique index makes at most
--     one row match, which is an improvement, but "at most one" includes none. See
--     db/tests/4_6_update_branch_vanishes.sql; it is a separate scoreboard row.

SET client_min_messages TO warning;

-- ---------------------------------------------------------------------------
-- 1. Identity
-- ---------------------------------------------------------------------------
-- Order is free (see the header) so it is chosen for coverage, not convention:
--   item_id leads   - the hottest stock filter and its FK's only leading coverage;
--   warehouse_id next, which covers that FK's referential checks and makes both
--   tenant-led composites from 0003 redundant prefixes;
--   location_id fourth: its FK is covered by membership, and the tenant-led bin index
--   built in 0003 keeps the (tenant, bin) access path.
CREATE UNIQUE INDEX IF NOT EXISTS inventory_on_hand_key
    ON inventory_on_hand (
        item_id,
        warehouse_id,
        COALESCE(location_id, '00000000-0000-0000-0000-000000000000'::uuid),
        COALESCE(lot_number, ''),
        tenant_id
    );

COMMENT ON INDEX inventory_on_hand_key IS
    'The stock-row identity: one row per tenant, item, warehouse, bin and lot. Membership '
    'of all five is what enforces it; the order is chosen so item_id and warehouse_id lead, '
    'covering their foreign keys and the hot balance query. An ON CONFLICT target must name '
    'exactly these five expressions as a SET, in any order, which is what '
    'execute_inventory_movement now does. The two COALESCE expressions make "no bin" and '
    '"no lot" usable in a unique key: NULL location and the nil UUID mean the same thing '
    'here, as do NULL lot and the empty string.';

-- The nil UUID is the schema's existing "no location" value: reserve_inventory_for_order
-- is called with it by blueprint/tools and by db/tests/4_3. So it cannot be forbidden
-- where it is *supplied*, and this constraint is on inventory_on_hand only, which is the
-- table where a nil row would collide with the no-bin sentinel. inventory_on_hand has no
-- default for location_id, so reaching nil there takes a deliberate insert; if a real bin
-- ever needs to be indistinguishable from "no bin", replace the sentinel with a
-- dedicated constant in a reserved range and re-run 0004 - the arbiter and the index
-- change together, per the inference rule in the header.
ALTER TABLE inventory_on_hand
    ADD CONSTRAINT inventory_on_hand_location_id_nil_check
    CHECK (location_id IS DISTINCT FROM '00000000-0000-0000-0000-000000000000'::uuid);

-- ---------------------------------------------------------------------------
-- 2. The arbiter, moved to match
-- ---------------------------------------------------------------------------
-- Surgical, and only this: add tenant_id to the inference target. Everything else in the
-- function body - the missing unit_of_measure, the ISSUE branch, the cost divisor - is
-- 0014's work, and rewriting it here would make two migrations responsible for one
-- function and blur which fix closed which finding.
--
-- pg_get_functiondef is used rather than a copied body so this cannot silently diverge
-- from whatever 0001 installed. The target is matched as a balanced parenthesised
-- ON CONFLICT clause rather than a literal line: a literal is one reindent away from
-- becoming a no-op, and a silent no-op here means an identity index nothing can use.
DO $$
DECLARE
    v_src   text;
    v_new   text;
    v_nconf int;
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO v_src
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'execute_inventory_movement';

    IF v_src IS NULL THEN
        RAISE EXCEPTION 'execute_inventory_movement is not installed';
    END IF;

    -- Exactly one ON CONFLICT is expected in this body. Asserting the count is what makes
    -- the substitution below safe: a global replace against an unverified count could
    -- rewrite a clause that was not the stock identity.
    SELECT count(*) INTO v_nconf FROM regexp_matches(v_src, 'ON CONFLICT', 'g');
    IF v_nconf <> 1 THEN
        RAISE EXCEPTION 'expected exactly 1 ON CONFLICT clause in '
                        'execute_inventory_movement, found %; refusing to rewrite the body',
                        v_nconf;
    END IF;

    -- Already tenant-scoped? Re-running must not double-append.
    IF v_src ~ 'COALESCE\(lot_number, ''''\),\s*tenant_id\)' THEN
        RAISE NOTICE 'arbiter already names tenant_id, leaving the body alone';
        RETURN;
    END IF;

    -- The clause is identified by its unique terminating sequence rather than by parsing
    -- balanced parentheses: the arbiter nests three levels deep (ON CONFLICT -> COALESCE
    -- -> the uuid cast's parens), which a portable regex handles badly and which this
    -- does not need to.
    IF v_src !~ 'COALESCE\(lot_number, ''''\)\)' THEN
        RAISE EXCEPTION 'the ON CONFLICT clause in execute_inventory_movement does not end '
                        'in the 4-column stock identity this migration was written against; '
                        'the identity index would be unreachable. Found: %',
            substring(v_src from 'ON CONFLICT.{0,170}');
    END IF;

    v_new := regexp_replace(v_src,
        '(COALESCE\(lot_number, ''''\))\)',
        '\1, tenant_id)', 1);

    IF v_new = v_src THEN
        RAISE EXCEPTION 'the substitution changed nothing';
    END IF;

    EXECUTE v_new;
    RAISE NOTICE 'arbiter updated to the 5-column identity form';
END
$$;

-- ---------------------------------------------------------------------------
-- 3. Merge whatever identity violation a populated copy already has
-- ---------------------------------------------------------------------------
-- On this database the table is empty and every block below reports "no duplicates",
-- which is why the checks are written as queries rather than skipped. This migration is
-- meant to replay onto a copy of a real database, and there it is the part that matters.
--
-- SET rather than LOCAL: this file's top-level client_min_messages = warning exists to
-- quiet the ALTER chatter, and it would also quiet the one message that tells an
-- operator whether real duplicates were merged or refused.
SET client_min_messages TO notice;
DO $$
DECLARE
    v_dup   int;
    v_group int;
BEGIN
    SELECT count(*) INTO v_group FROM (
        SELECT 1 FROM inventory_on_hand
         GROUP BY tenant_id, item_id, warehouse_id,
                  COALESCE(location_id, '00000000-0000-0000-0000-000000000000'::uuid),
                  COALESCE(lot_number, '')
        HAVING count(*) > 1
    ) d;

    IF v_group = 0 THEN
        RAISE NOTICE 'identity: no duplicate stock rows to merge';
        RETURN;
    END IF;

    -- Ambiguity that cannot be resolved honestly is a stop, not a guess. Two rows under
    -- one identity key that differ in *which* bin, or in *which* lot, are not duplicates
    -- of one fact - they are two facts whose key is wrong. And the mixed case is the
    -- dangerous one: a group holding one NULL-lot row and one 'LOT-A' row collapses under
    -- the COALESCE sentinel, so a sum-into-survivor merge would silently relabel bulk
    -- stock as a specific lot. Counting distinct non-null values, as this block first
    -- did, misses exactly that.
    -- Which spellings of "the same collapsed key" can actually differ. Within one group
    -- every row shares COALESCE(location_id, nil), so location_id can take at most the two
    -- values NULL and nil - a real bin is a different key, and the CHECK below makes even
    -- the nil spelling unreachable. count(DISTINCT location_id) > 1 is therefore dead code
    -- and is deliberately absent; the null-ness tests are the only reachable conflict.
    SELECT count(*) INTO v_dup FROM (
        SELECT 1 FROM inventory_on_hand
         GROUP BY tenant_id, item_id, warehouse_id,
                  COALESCE(location_id, '00000000-0000-0000-0000-000000000000'::uuid),
                  COALESCE(lot_number, '')
        HAVING (count(*) FILTER (WHERE location_id IS NULL) > 0
                AND count(*) FILTER (WHERE location_id =
                        '00000000-0000-0000-0000-000000000000'::uuid) > 0)
            OR (count(*) FILTER (WHERE lot_number IS NULL) > 0
                AND count(*) FILTER (WHERE lot_number = '') > 0)
    ) a;

    IF v_dup > 0 THEN
        RAISE EXCEPTION
            '% stock row group(s) hold conflicting locations or lot numbers under one '
            'identity key. Summing them would lose bin and lot tracking, so nothing was '
            'merged. Resolve them by hand (the rows differ in location_id/lot_number, not '
            'just in quantity) and re-run. Conflicting groups: %',
            v_dup,
            -- Grouped by the COLLAPSED key, then the distinct raw spellings inside it
            -- listed. Grouping by the raw columns reports a different fact twice and
            -- yields NULL precisely when the diagnostic is most wanted - which it did.
            (SELECT string_agg(g, ' || ') FROM (
                SELECT format('item=%s wh=%s loc={%s} lot={%s}',
                              item_id, warehouse_id,
                              string_agg(DISTINCT coalesce(location_id::text, 'NULL'), '/'),
                              string_agg(DISTINCT coalesce(lot_number, 'NULL'), '/')) AS g
                  FROM inventory_on_hand
                 GROUP BY tenant_id, item_id, warehouse_id,
                          COALESCE(location_id, '00000000-0000-0000-0000-000000000000'::uuid),
                          COALESCE(lot_number, '')
                HAVING count(*) > 1 LIMIT 5) x);
    END IF;

    RAISE NOTICE 'identity: % duplicate group(s) are quantity-only copies, merging', v_group;

    -- The survivor ranking has to outlive the statement that computes it: a CTE is
    -- scoped to its own UPDATE, and the DELETE that follows cannot see it. On this host
    -- that bug is invisible (v_group is 0, so the block returns before reaching here);
    -- on the first populated copy it would have aborted the migration with
    -- 'relation "ranked" does not exist'. A temp table, instead.
    CREATE TEMP TABLE _afpc_0004_ranked ON COMMIT DROP AS
        SELECT on_hand_id,
               row_number() OVER w AS rn
          FROM inventory_on_hand
        WINDOW w AS (PARTITION BY tenant_id, item_id, warehouse_id,
                                 COALESCE(location_id, '00000000-0000-0000-0000-000000000000'::uuid),
                                 COALESCE(lot_number, '')
                     ORDER BY last_movement_at DESC NULLS LAST, on_hand_id);

    -- Deterministic survivor: the row that most recently saw movement, with on_hand_id as
    -- a tiebreak so two runs of this migration pick the same row.
    WITH grouped AS (
        SELECT (array_agg(r.on_hand_id ORDER BY r.rn))[1] AS keeper,
               sum(h.quantity_on_hand)    AS g_on_hand,
               sum(h.quantity_reserved)   AS g_reserved,
               sum(h.quantity_in_transit) AS g_transit,
               sum(h.quantity_damaged)    AS g_damaged,
               -- Highest version in the group, not the survivor's own: the merged row has
               -- seen more writes than any single member, so it must not let a client
               -- replay a stale version over it (ADR-005).
               max(h.version)             AS g_version,
               max(h.last_movement_at)    AS g_moved
          FROM inventory_on_hand h JOIN _afpc_0004_ranked r USING (on_hand_id)
         GROUP BY h.tenant_id, h.item_id, h.warehouse_id,
                  COALESCE(h.location_id, '00000000-0000-0000-0000-000000000000'::uuid),
                  COALESCE(h.lot_number, '')
        HAVING count(*) > 1
    )
    UPDATE inventory_on_hand t
       SET quantity_on_hand    = g.g_on_hand,
           quantity_reserved   = g.g_reserved,
           quantity_in_transit = g.g_transit,
           quantity_damaged    = g.g_damaged,
           version             = g.g_version,
           last_movement_at    = g.g_moved
      FROM grouped g
     WHERE t.on_hand_id = g.keeper;

    DELETE FROM inventory_on_hand t
     USING _afpc_0004_ranked r
     WHERE t.on_hand_id = r.on_hand_id AND r.rn > 1;

    -- Nothing must remain ambiguous: this is the assertion that would have caught the
    -- CTE scoping bug above on a populated copy, so it is placed after the work rather
    -- than trusting that the work happened.
    IF EXISTS (SELECT 1 FROM inventory_on_hand
                GROUP BY tenant_id, item_id, warehouse_id,
                         COALESCE(location_id, '00000000-0000-0000-0000-000000000000'::uuid),
                         COALESCE(lot_number, '')
               HAVING count(*) > 1) THEN
        RAISE EXCEPTION 'the merge left duplicate groups behind; identity not established';
    END IF;

    -- The survivor keys are reported rather than written to a table: agent_interactions
    -- is the agents' trajectory log and a DDL event does not belong in it, and the
    -- deleted rows' contents are reconstructible from inventory_movements, which is
    -- append-only. 0013_audit_log is where a real record of this goes.
    RAISE NOTICE 'identity merge complete, % surplus row(s) removed',
        (SELECT count(*) FROM _afpc_0004_ranked WHERE rn > 1);
END
$$;

-- ---------------------------------------------------------------------------
-- 4. Indexes the identity makes redundant
-- ---------------------------------------------------------------------------
-- Dropped, with the reason for each:
--   idx_on_hand_available, idx_on_hand_low_stock   both (item_id, quantity_available),
--       an exact duplicate pair from the baseline (correction C1); quantity_available is
--       not in the identity and item_id is, so both are covered without them.
--   idx_on_hand_item      (tenant_id, item_id)  - item_id leads the identity and tenant_id
--       arrives from RLS, so the balance lookup is covered.
--   idx_on_hand_warehouse (tenant_id, warehouse_id) - same argument; warehouse_id is the
--       identity's second column.
--   idx_inventory_on_hand_tenant - 0003 re-creates it on replay (its loop guard only adds
--       the column when absent), and afpc_drop_redundant_tenant_indexes() no longer removes
--       it, because no other NON-UNIQUE index on this table leads with tenant_id.
-- Kept:
--   idx_on_hand_tenant_location (tenant_id, location_id) - the (tenant, bin) path, and
--       location_id's leading coverage. It is NOT a prefix of the identity: the identity's
--       third column is the location COALESCE, not location_id. That misreading is exactly
--       how this migration first dropped something it should have kept.
--   idx_on_hand_location  (location_id) - bin-scoped queries without a tenant filter.
--   idx_on_hand_expiry    (expiry_date) - unrelated to identity.
DO $$
DECLARE
    gone   text[] := ARRAY[]::text[];
    extra  text[];
    idx    text;
BEGIN
    FOREACH idx IN ARRAY ARRAY[
        'idx_on_hand_available', 'idx_on_hand_low_stock',
        'idx_on_hand_item', 'idx_on_hand_warehouse', 'idx_inventory_on_hand_tenant'
    ] LOOP
        IF EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                    WHERE n.nspname = 'public' AND c.relname = idx) THEN
            gone := array_append(gone, idx);
        END IF;
    END LOOP;

    extra := afpc_drop_redundant_tenant_indexes();
    IF extra IS NOT NULL THEN
        gone := array_cat(gone, extra);
    END IF;

    IF cardinality(gone) > 0 THEN
        EXECUTE 'DROP INDEX ' || array_to_string(gone, ', ');
        RAISE NOTICE 'dropped % indexes made redundant by the identity: %',
            cardinality(gone), array_to_string(gone, ', ');
    END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- 5. Verification
-- ---------------------------------------------------------------------------
SET client_min_messages TO notice;
DO $$
DECLARE
    v_expr  text;
    v_nkeys int;
    v_body  text;
BEGIN
    SELECT pg_get_indexdef(i.indexrelid) INTO v_expr
      FROM pg_index i JOIN pg_class tc ON tc.oid = i.indrelid
                    JOIN pg_class ic ON ic.oid = i.indexrelid
     WHERE tc.relname = 'inventory_on_hand' AND ic.relname = 'inventory_on_hand_key';

    IF v_expr IS NULL THEN
        RAISE EXCEPTION 'the identity index does not exist';
    END IF;

    -- tenant_id must be a key column. Membership is required, position is not; without
    -- it the constraint is global again, which is 5.8 returning through 4.2. Read from
    -- the catalog, not by parsing the definition: a comma split cuts through COALESCE.
    SELECT count(*) INTO v_nkeys
      FROM pg_index i
      JOIN pg_class tc ON tc.oid = i.indrelid AND tc.relname = 'inventory_on_hand'
      JOIN pg_class ic ON ic.oid = i.indexrelid AND ic.relname = 'inventory_on_hand_key'
      JOIN unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord) ON true
      JOIN pg_attribute a ON a.attrelid = tc.oid AND a.attnum = k.attnum
     WHERE a.attname = 'tenant_id' AND k.ord <= i.indnatts;
    IF v_nkeys <> 1 THEN
        RAISE EXCEPTION 'the identity index does not include tenant_id as a key column, '
                        'so stock rows are unique across tenants rather than within one';
    END IF;

    -- The assertion that matters. The first version of this check pattern-matched the
    -- index definition text and PASSED while the real statement still raised 42P10: the
    -- definition looks identical whichever column order is used, and correctness depends
    -- on the order. So both statements are executed, zero rows are written, and the
    -- arbiter is resolved or it is not.
    BEGIN
        EXECUTE $probe$
            INSERT INTO inventory_on_hand
                    (tenant_id, item_id, warehouse_id, location_id, lot_number,
                     quantity_on_hand, quantity_available, quantity_reserved)
                SELECT tenant_id, item_id, warehouse_id, NULL, NULL, 0, 0, 0
                  FROM inventory_on_hand WHERE FALSE
             ON CONFLICT (item_id, warehouse_id,
                    COALESCE(location_id, '00000000-0000-0000-0000-000000000000'::uuid),
                    COALESCE(lot_number, ''), tenant_id)
             DO UPDATE SET quantity_on_hand = inventory_on_hand.quantity_on_hand
        $probe$;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'the identity index cannot be inferred into (SQLSTATE %): %',
            SQLSTATE, v_expr;
    END;

    -- And the function must agree with the index, because that is the pairing the rule
    -- above makes fragile: a later edit to the body can silently un-infer it.
    SELECT pg_get_functiondef(p.oid) INTO v_body
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'execute_inventory_movement';
    IF v_body !~ 'COALESCE\(lot_number, ''''\), tenant_id\)' THEN
        RAISE EXCEPTION 'execute_inventory_movement''s arbiter does not list tenant_id, so '
                        'the receipt path still fails with 42P10 despite the identity index';
    END IF;

    IF EXISTS (SELECT 1 FROM inventory_on_hand
                GROUP BY item_id, warehouse_id,
                         COALESCE(location_id, '00000000-0000-0000-0000-000000000000'::uuid),
                         COALESCE(lot_number, ''), tenant_id
               HAVING count(*) > 1) THEN
        RAISE EXCEPTION 'duplicate stock rows survived the migration';
    END IF;

    -- Every stock-table FK column must lead at least one index. This is the assertion
    -- that would have caught 0004 dropping idx_on_hand_tenant_location: the identity
    -- contains location_id but never as a first column, so "it is indexed somewhere" was
    -- true and useless.
    -- Index coverage of this table's foreign keys. Two different things, asserted
    -- separately, because they were conflated until this migration made it concrete:
    --   MEMBERSHIP (correctness) - Postgres' FK mechanism uses any index containing the
    --     column as a key column; an experiment on this server showed a non-leading
    --     position served the check with an Index Cond, not a sequential scan.
    --   LEADING (performance) - a query filtering only that column wants it first.
    -- A column may pass the first and fail the second, and this table's item_id did when
    -- the identity led with tenant_id.
    IF EXISTS (
        SELECT 1 FROM (VALUES ('item_id'), ('warehouse_id'), ('location_id'), ('tenant_id')) AS c(col)
         WHERE NOT EXISTS (SELECT 1 FROM pg_index i
                            JOIN pg_attribute a ON a.attrelid = i.indrelid
                                              AND a.attnum = ANY(i.indkey)
                                              AND a.attnum > 0
                            WHERE i.indrelid = 'inventory_on_hand'::regclass
                              AND a.attname = c.col)
    ) THEN
        RAISE EXCEPTION 'a stock FK column is in no index at all, so referential checks on '
                        'it scan the table: %',
            (SELECT string_agg(col, ', ') FROM (VALUES ('item_id'), ('warehouse_id'), ('location_id'), ('tenant_id')) AS c(col)
              WHERE NOT EXISTS (SELECT 1 FROM pg_index i
                                 JOIN pg_attribute a ON a.attrelid = i.indrelid
                                                   AND a.attnum = ANY(i.indkey)
                                                   AND a.attnum > 0
                                 WHERE i.indrelid = 'inventory_on_hand'::regclass
                                   AND a.attname = c.col));
    END IF;

    IF EXISTS (
        SELECT 1 FROM (VALUES ('item_id'), ('location_id')) AS c(col)
         WHERE NOT EXISTS (SELECT 1 FROM pg_index i
                            JOIN pg_attribute a ON a.attrelid = i.indrelid
                                              AND a.attnum = i.indkey[0]
                            WHERE i.indrelid = 'inventory_on_hand'::regclass
                              AND a.attname = c.col)
    ) THEN
        RAISE EXCEPTION 'item_id and location_id must each lead an index: they are the two '
                        'ways an agent asks about stock (by item, and by bin), and dropping '
                        'a tenant-led index in favour of the identity silently removed one';
    END IF;

    RAISE NOTICE 'identity verified: %', v_expr;
END
$$;
