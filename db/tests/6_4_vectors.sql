-- Finding 6.4, observed as behaviour rather than as a catalog read.
--
-- 0012's header records why the review's own wording could not be used as the assertion:
-- the "planner prefers hnsw" claim is a cost-model measurement, and the cost model does not
-- charge the seq-scan path for detoasting vectors (measured here: the plans' ESTIMATES sit
-- within noise of each other around 1.5k-5k rows while their real buffer counts differ 35x;
-- the forced-off preference flip even goes the wrong way at n=5000 because generic index
-- costing scales hnsw's estimate with index size, which an hnsw search does not pay). So
-- this file asserts three things that are properties of the schema, not of the estimator:
--
--   (a) USABILITY  - when the alternatives are forbidden, an hnsw scan answers the ANN
--       ordering. Pre-0012 there is no such plan on entities at all (the rehearsal measured
--       the planner REFUSING the empty-built ivfflat on communications and seq-scanning
--       instead), so this reproduces the finding at any population.
--   (b) SAVINGS    - the ANN path the index makes possible really reads fewer blocks than
--       the scan it replaces, counted in executed buffers, not estimated costs. Pre-0012 the
--       "forced index path" degrades to the same penalised seq+sort, so the ratio is ~1 and
--       the claim reproduces too.
--   (c) CENSUS     - every vector column of a base table leads an hnsw index, no ivfflat
--       survives, and no view projects a vector. These are existence claims; no volume
--       would make them more true, so no volume is spent on them (5_5_6's split again).

-- ---------------------------------------------------------------------------
-- (a)+(b) want volume. Inside a transaction that rolls back; ANALYZE's writes roll back
-- with the rows (0006's mechanism, reused), and test-functions.sh restores the id
-- sequences the inserts advance.
-- ---------------------------------------------------------------------------
BEGIN;
DO $$
DECLARE
    v_plan    text := '';
    v_line    text;
    v_r       record;
    v_tax     bigint;
    v_idx     bigint;
BEGIN
    INSERT INTO entities (name, entity_type, embedding)
        SELECT '6.4 probe ' || g, 'customer',
               (SELECT array_agg(random()::real) FROM generate_series(1, 1536))::vector
          FROM generate_series(1, 500) g;
    ANALYZE entities;

    -- (a) usability: with the two non-ANN paths forbidden, the ONLY way to produce a
    --     <=> ordering is an hnsw index scan. A merge of a btree on embedding cannot serve
    --     the distance ordering (different sort operator family), so there is no
    --     index-scan-but-not-hnsw case to accidentally pass on.
    SET LOCAL enable_seqscan = off;
    SET LOCAL enable_sort = off;
    FOR v_line IN EXECUTE format(
            'EXPLAIN (COSTS OFF) SELECT id FROM entities '
            'ORDER BY embedding <=> (SELECT embedding FROM entities WHERE name = %L) LIMIT 10',
            '6.4 probe 1')
    LOOP v_plan := v_plan || v_line || E'\n'; END LOOP;
    RESET enable_seqscan;
    RESET enable_sort;

    IF v_plan LIKE '%idx_entities_embedding%' AND v_plan NOT LIKE '%Sort%' THEN
        RAISE NOTICE 'VERDICT OK the ANN ordering is answered by the hnsw index on entities';
    ELSE
        RAISE NOTICE 'VERDICT ERR the entities ANN query has no hnsw index to answer it (6.4): %',
            left(v_plan, 110);
    END IF;

    -- (b) savings: run BOTH plans for real and count blocks. The exhaustive path computes
    --     the distance per row, which detoasts every vector: the review's "drags ~6KB/row
    --     into every scan" is true of THIS PATH even though it is false of the stored rows
    --     (0012's header). Measured on the rehearsal clone at 1500 rows: 9053 blocks vs 260.
    --     The hnsw run is forced with the same flags as (a); pre-0012 it degrades to a
    --     penalised seq+sort that touches the same blocks as the tax run, so the ratio
    --     comes out ~1 and the phrase reproduces. The 2x bar is where a wrong access method
    --     or a non-toast column would have to be badly broken to clear it unnoticed.
    DELETE FROM entities WHERE name LIKE '6.4 probe %';
    INSERT INTO entities (name, entity_type, embedding)
        SELECT '6.4 probe ' || g, 'customer',
               (SELECT array_agg(random()::real) FROM generate_series(1, 1536))::vector
          FROM generate_series(1, 1500) g;
    ANALYZE entities;

    -- The tax run must be FORCED exhaustive: at this size the unforced planner flip-flops
    -- between the paths (measured - the cost estimates cross twice between 500 and 5000
    -- because generic index costing scales hnsw's estimate with index size while the sort
    -- path's estimate never charges for detoast). An unforced run here would make this
    -- assertion depend on which plan the estimator happened to prefer today.
    SET LOCAL enable_indexscan = off;
    SET LOCAL enable_indexonlyscan = off;
    SET LOCAL enable_bitmapscan = off;
    FOR v_r IN EXECUTE format(
            'EXPLAIN (ANALYZE, BUFFERS, TIMING OFF, COSTS OFF) SELECT id FROM entities '
            'ORDER BY embedding <=> (SELECT embedding FROM entities WHERE name = %L) LIMIT 10',
            '6.4 probe 1')
    LOOP
        IF v_r."QUERY PLAN" LIKE '%Buffers:%' AND v_tax IS NULL THEN
            v_tax := substring(v_r."QUERY PLAN" from 'hit=(\d+)')::bigint
                   + coalesce(substring(v_r."QUERY PLAN" from 'read=(\d+)')::bigint, 0);
        END IF;
    END LOOP;
    RESET enable_indexscan;
    RESET enable_indexonlyscan;
    RESET enable_bitmapscan;

    SET LOCAL enable_seqscan = off;
    SET LOCAL enable_sort = off;
    FOR v_r IN EXECUTE format(
            'EXPLAIN (ANALYZE, BUFFERS, TIMING OFF, COSTS OFF) SELECT id FROM entities '
            'ORDER BY embedding <=> (SELECT embedding FROM entities WHERE name = %L) LIMIT 10',
            '6.4 probe 1')
    LOOP
        IF v_r."QUERY PLAN" LIKE '%Buffers:%' AND v_idx IS NULL THEN
            v_idx := substring(v_r."QUERY PLAN" from 'hit=(\d+)')::bigint
                   + coalesce(substring(v_r."QUERY PLAN" from 'read=(\d+)')::bigint, 0);
        END IF;
    END LOOP;
    RESET enable_seqscan;
    RESET enable_sort;

    IF v_tax IS NULL OR v_idx IS NULL THEN
        RAISE NOTICE 'VERDICT ERR the buffer census did not run: tax=% index=%', v_tax, v_idx;
    ELSIF v_idx * 2 < v_tax THEN
        RAISE NOTICE 'VERDICT OK the ANN path reads % blocks against the exhaustive scan''s %',
            v_idx, v_tax;
    ELSE
        RAISE NOTICE 'VERDICT ERR the hnsw index saves no reads over the exhaustive scan '
                     '(% blocks vs %): the vector still rides along in the rows it is read from',
            v_idx, v_tax;
    END IF;
END
$$;
ROLLBACK;

-- ---------------------------------------------------------------------------
-- (c) the three census claims.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_rows int;
    v_list text;
BEGIN
    SELECT count(*), coalesce(string_agg(format('%s.%s', c.relname, a.attname), ', '), '-')
      INTO v_rows, v_list
      FROM pg_attribute a
      JOIN pg_class c ON c.oid = a.attrelid AND c.relkind = 'r'
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_type t ON t.oid = a.atttypid
     WHERE n.nspname = 'public' AND t.typname = 'vector'
       AND a.attnum > 0 AND NOT a.attisdropped
       AND NOT EXISTS (SELECT 1 FROM pg_index i
                         JOIN pg_class ix ON ix.oid = i.indexrelid
                         JOIN pg_am am ON am.oid = ix.relam
                        WHERE i.indrelid = c.oid AND am.amname = 'hnsw'
                          AND i.indkey[0] = a.attnum);
    IF v_rows = 0 THEN
        RAISE NOTICE 'VERDICT OK every vector column of a base table leads an hnsw index';
    ELSE
        RAISE NOTICE 'VERDICT ERR a vector column of a base table leads no hnsw index (6.4): %',
            v_list;
    END IF;

    SELECT count(*), coalesce(string_agg(c.relname, ', '), '-')
      INTO v_rows, v_list
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_am am ON am.oid = c.relam
     WHERE n.nspname = 'public' AND c.relkind = 'i' AND am.amname = 'ivfflat';
    IF v_rows = 0 THEN
        RAISE NOTICE 'VERDICT OK no ivfflat index survives in public';
    ELSE
        RAISE NOTICE 'VERDICT ERR an under-trained ivfflat index is still mounted (6.4): %',
            v_list;
    END IF;

    SELECT count(*), coalesce(string_agg(format('%s.%s', c.relname, a.attname), ', '), '-')
      INTO v_rows, v_list
      FROM pg_attribute a
      JOIN pg_class c ON c.oid = a.attrelid AND c.relkind = 'v'
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_type t ON t.oid = a.atttypid
     WHERE n.nspname = 'public' AND t.typname = 'vector'
       AND a.attnum > 0 AND NOT a.attisdropped;
    IF v_rows = 0 THEN
        RAISE NOTICE 'VERDICT OK no view projects a vector - listing scans stay thin';
    ELSE
        RAISE NOTICE 'VERDICT ERR a listing view still projects the vector (6.4): % - every '
                     'SELECT through it detoasts 6KB per row, which is the whole of the '
                     'review''s scan-tax claim', v_list;
    END IF;
END
$$;
