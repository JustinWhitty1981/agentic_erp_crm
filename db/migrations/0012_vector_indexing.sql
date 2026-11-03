-- 0012: make the vector layer searchable, and move the vectors exactly zero times
--       (DATABASE_REVIEW.md 6.4)
--
-- 6.4 makes three claims, and this migration acts on all three after re-measuring each:
--
--   * "only 1 of 3 embedding columns is searchable by ANN; the others force exhaustive
--     scans" - TRUE, and fixed: entities.embedding and contacts.embedding get hnsw indexes
--     beside communications'.
--   * "ivfflat ... WITH (lists=100) is tuned for ~1M rows" and "the largest object in the
--     schema an index over an empty table" - TRUE, to the byte: measured on this database,
--     idx_comms_embedding is 1608 kB over ZERO rows, and pgvector itself printed
--     "DETAIL: This will cause low recall." when 0001 built it on the empty table. lists=100
--     wants ~10x that many rows to train on; hnsw has no training step, and the same
--     measurement gives it 16 kB empty. And unlike the ivfflat it replaces, an hnsw scan is
--     a plan that can actually run: measured on the clone at 500 populated rows, the planner
--     will not use the old ivfflat AT ALL (it chooses Seq Scan + Sort), while probe B below
--     shows hnsw answers the ordering when the alternatives are forbidden. Probe B asserts
--     only that usability half, deliberately: entities' main tuples are ~61-byte things
--     spanning a handful of pages, where seq+sort is the CORRECT unforced plan at that
--     size, and a migration that asserts cost-model preference at five pages is asserting a
--     rounding detail. So the swap is ivfflat -> hnsw on all three columns,
--     cosine metric kept: the metric is a property of the embedding model, not of the
--     index, and no code anywhere uses a different operator (measured: zero ANN operators
--     in any SQL or tool file - which this migration's register note should make an agent
--     notice, not hide).
--   * "vector(1536) is stored inline on communications ... dragging ~6KB/row into every
--     ordinary CRM scan" - FALSE AS STATED, and the correction is why this migration
--     creates no side table. The vector type's storage is EXTERNAL (attstorage='e',
--     measured), which for 6148-byte values means the main tuple never carries them:
--     2000 vectorized rows average 61 bytes in the main fork, and a non-projecting scan
--     reads 8 buffers for 1000 rows - TOAST already IS the side table, with the join
--     hidden in the executor. The 6KB/row tax that is real belongs to the one object that
--     PROJECTS the column: vw_customers carries e.embedding, and a projecting scan of the
--     same data costs 3033 buffers versus 8 (measured, ~300x). Fixing the claim therefore
--     means editing the view's column list, which no consumer reads through (measured: the
--     blueprint tools name their columns explicitly) - not moving a column that is already
--     not in the rows. If a future population ever stores vectors small enough to stay
--     inline, probe F in this migration's verify block is the tripwire that would make the
--     side table correct after all.
--
-- Deferred, with reasons, not silence:
--   * halfvec's 2x density - there are no vectors to make dense; the entire schema payload
--     is NULLs on an empty copy. Revisit on population.
--   * the ANN read path itself - indexing a capability nobody queries is B12's scoreboard,
--     not a feature; wiring a semantic-search tool is Phase 5 code work.
--   * B12's own SQL was uncorrelated (it joined pg_class to the INDEXED TABLE and asked
--     for a name like '%embedding%' - a question no table in this schema can answer, so it
--     would count every vector column, including a VIEW's, as an offender forever). Fixed
--     in verify.sh alongside this file; the same class of defect B11 had, pointing the
--     other way: always-fail rather than never-fail, which is why it surfaced at the first
--     application instead of hiding for seven migrations.

SET client_min_messages TO notice;

-- ---------------------------------------------------------------------------
-- 1. The index swap
-- ---------------------------------------------------------------------------
-- Non-concurrent on purpose: the runner applies each migration inside one
-- transaction, where CREATE INDEX CONCURRENTLY is illegal. On this (empty) copy the
-- build is milliseconds; on a populated copy an hnsw build takes a write lock for its
-- duration, which is the operator's scheduling decision to make, not to hide in a file -
-- stated here because 0006 established that migrations are not the place to pretend DDL
-- is free.
DROP INDEX IF EXISTS idx_comms_embedding;          -- ivfflat, lists=100, 1608 kB of nothing

CREATE INDEX IF NOT EXISTS idx_comms_embedding
    ON communications USING hnsw (embedding vector_cosine_ops);
CREATE INDEX IF NOT EXISTS idx_entities_embedding
    ON entities USING hnsw (embedding vector_cosine_ops);
CREATE INDEX IF NOT EXISTS idx_contacts_embedding
    ON contacts USING hnsw (embedding vector_cosine_ops);

COMMENT ON INDEX idx_comms_embedding IS
    'hnsw, cosine - replaces 0001''s ivfflat (lists=100), which cost 1608 kB on zero rows '
    'and printed "low recall" at its own build time (6.4). The cosine opclass is inherited '
    'from that index, not re-derived: the metric belongs to the embedding model that will '
    'populate the column, and no code currently uses any metric at all. Built by 0012.';
COMMENT ON INDEX idx_entities_embedding IS
    'hnsw, cosine. The column is populated by no code path today; this index is the '
    'capability the semantic-search feature needs before the tool that uses it exists '
    '(6.4''s complaint was that the half-built layer could not answer ANN queries at all). '
    'Built by 0012.';
COMMENT ON INDEX idx_contacts_embedding IS
    'hnsw, cosine; same note as idx_entities_embedding. Built by 0012.';

-- ---------------------------------------------------------------------------
-- 2. vw_customers: the scan tax, where it actually lives
-- ---------------------------------------------------------------------------
-- One property this rewrite had to learn the hard way (first rehearsal died on it):
-- CREATE OR REPLACE VIEW can ADD columns and can never DROP one. 0009's capture-rewrite-prove
-- pattern replays a definition with MORE columns, so it never met the limit; removing the
-- embedding projection is the first migration that does, and the only mechanism is
-- DROP + CREATE - which recreates the object from scratch, reloptions and privileges included.
-- So this section (a) refuses to drop anything that depends on the view, (b) restores the
-- access-method flags and the three read grants the same transaction gave them back, and
-- (c) proves the column list changed in exactly the one intended position.
DO $$
DECLARE
    v_before text;
    v_after  text;
    v_depends int;
BEGIN
    SELECT string_agg(attname, ',' ORDER BY attnum) INTO v_before
      FROM pg_attribute WHERE attrelid = 'vw_customers'::regclass AND attnum > 0 AND NOT attisdropped;

    -- Auto cascade would silently destroy a dependent view's view; ask first.
    SELECT count(*) INTO v_depends
      FROM pg_depend d JOIN pg_class o ON o.oid = d.objid
     WHERE d.refobjid = 'vw_customers'::regclass AND d.deptype = 'n'
       AND o.relname <> 'vw_customers';
    IF v_depends <> 0 THEN
        RAISE EXCEPTION 'vw_customers has % dependent object(s) - dropping it would cascade; '
                        'this rewrite must be redone as a column-preserving change or the '
                        'dependents recreated in the same migration', v_depends;
    END IF;
    IF v_before NOT LIKE '%embedding%' THEN
        RAISE EXCEPTION 'vw_customers carried no embedding column before this rewrite - the '
                        'finding this section closes is not the one present (review 6.4)';
    END IF;

    DROP VIEW vw_customers;
    CREATE VIEW vw_customers AS
        SELECT e.id,
               e.name,
               c.email,
               c.phone,
               (SELECT concat_ws(', ', a.street, a.city, a.state, a.postal_code)
                  FROM addresses a
                 WHERE a.entity_id = e.id
                 ORDER BY a.is_primary DESC, a.created_at DESC
                 LIMIT 1) AS address,
               e.status,
               e.created_at,
               e.updated_at,
               e.tenant_id
          FROM entities e
          JOIN entity_relationships er ON er.entity_id = e.id AND er.is_primary = true
          JOIN contacts c ON c.id = er.contact_id
         WHERE e.entity_type::text = 'customer'::text;

    -- 0009's obligation, discharged the way it asked: reloptions die with a replace, and a
    -- recreate never had them at all, so the flag is set here, after the object exists.
    ALTER VIEW vw_customers SET (security_invoker = true);

    -- The fresh object's ACL comes from 0002's ALTER DEFAULT PRIVILEGES (measured: it lands,
    -- because the migration runs as postgres). Asserted rather than trusted - if a populated
    -- copy ever recreated these under a different role, a silent loss of the auditor's read
    -- would be the worst possible outcome of a vector optimization.
    GRANT SELECT ON vw_customers TO afpc_readonly, afpc_auditor, afpc_app;
    IF NOT (has_table_privilege('afpc_auditor', 'vw_customers'::regclass, 'SELECT')
            AND has_table_privilege('afpc_readonly', 'vw_customers'::regclass, 'SELECT')
            AND has_table_privilege('afpc_app', 'vw_customers'::regclass, 'SELECT')) THEN
        RAISE EXCEPTION 'the recreated vw_customers is missing a read grant - 6.4 must not '
                        'cost the audit roles their visibility';
    END IF;

    -- Capture, rewrite, compare - all in one transaction, because the before-list stops
    -- existing the moment the replace runs. The assertion is derived from v_before itself
    -- (drop one name, expect the rest in order), not from a literal copy of the old column
    -- list: a literal is the 0007 "LIKE that spells one rendering" mistake in new clothes.
    SELECT string_agg(attname, ',' ORDER BY attnum) INTO v_after
      FROM pg_attribute WHERE attrelid = 'vw_customers'::regclass AND attnum > 0 AND NOT attisdropped;

    IF (SELECT string_agg(c, ',' ORDER BY ord)
          FROM unnest(string_to_array(v_before, ',')) WITH ORDINALITY AS t(c, ord)
         WHERE c <> 'embedding') IS DISTINCT FROM v_after THEN
        RAISE EXCEPTION 'the vw_customers rewrite changed more than the embedding column: '
                        'before % after %', v_before, v_after;
    END IF;
    RAISE NOTICE '6.4: vw_customers rebuilt - % columns, embedding dropped from position % of '
                 'the old list, everything else in order',
                 (SELECT count(*) FROM unnest(string_to_array(v_after, ','))),
                 (SELECT ord FROM unnest(string_to_array(v_before, ','))
                               WITH ORDINALITY AS t(c, ord) WHERE c = 'embedding');
END
$$;

COMMENT ON VIEW vw_customers IS
    'Customer + primary contact + best address, one row per customer (0006 fixed the per-row '
    'address sort; 0009 exposed tenant_id and made the view invoker-security). 0012 removed '
    'e.embedding: a vector(1536) projected through a listing view is 6KB of toast fetch per '
    'customer per page (measured: 3033 buffers projecting vs 8 not, ~300x), and no consumer '
    'reads it - the blueprint tools name their columns explicitly. Semantic search queries '
    'the entities table directly against idx_entities_embedding.';

-- ---------------------------------------------------------------------------
-- 3. Verify by behaving
-- ---------------------------------------------------------------------------
-- Index-definition checks are the B10/B11 failure mode waiting to recur: "an hnsw index
-- named %embedding% exists" is satisfied by an index nothing can plan onto. So the probes
-- here put actual rows in the actual table, ask the actual planner for an actual plan, and
-- assert what it says. 500 rows, because EXPLAIN against zero rows proves nothing either
-- way (0006's lesson, quoted in its own file), and all fixtures are deleted at the end.
DO $$
DECLARE
    v_line    text;
    v_plan    text := '';
    v_main0   bigint;
    v_toast0  bigint;
    v_main1   bigint;
    v_toast1  bigint;
    v_hnsw    text;
    v_exact   text;
    v_match   integer;
    v_n       int := 0;
BEGIN
    ------------------------------------------------------------------
    -- A. populate: 500 customers with real random vectors. The fork sizes are captured
    --    before and after because probe D's claim is about DELTA - a populated copy's
    --    absolute sizes include everything the table already held, and a threshold on
    --    those would be a coin flip rather than a measurement.
    ------------------------------------------------------------------
    SELECT pg_relation_size('entities'),
           coalesce(pg_total_relation_size((SELECT reltoastrelid FROM pg_class
                                            WHERE oid = 'entities'::regclass)), 0)
      INTO v_main0, v_toast0;

    INSERT INTO entities (name, entity_type, status, embedding)
        SELECT '0012 probe e' || g, 'customer', 'active',
               (SELECT array_agg(random()::real) FROM generate_series(1, 1536))::vector
          FROM generate_series(1, 500) g;
    ANALYZE entities;

    ------------------------------------------------------------------
    -- B. ANN behaviour: the index must be ABLE to answer the ordering.
    --    Asserted as usability-with-penalties-off, not planner preference: 500 thin main
    --    tuples (vectors live in toast) span ~5 pages, where a seq scan + top-N sort is the
    --    CORRECT unforced plan, and asserting preference here would be asserting a cost-model
    --    detail (0006's preference/usability split, learned there and quoted in its own file).
    --    With seqscan and sort both forbidden, the only plan that can produce a <=> ordering
    --    is an hnsw scan - which pre-0012 simply is not available, so the failure branch
    --    reproduces the finding at any population.
    ------------------------------------------------------------------
    SET LOCAL enable_seqscan = off;
    SET LOCAL enable_sort = off;
    FOR v_line IN EXECUTE $q$EXPLAIN (COSTS OFF)
            SELECT id FROM entities
             ORDER BY embedding <=> (SELECT embedding FROM entities WHERE name = '0012 probe e1')
             LIMIT 10$q$
    LOOP
        v_plan := v_plan || v_line || E'\n';
    END LOOP;
    RESET enable_seqscan;
    RESET enable_sort;
    IF v_plan NOT LIKE '%idx_entities_embedding%' OR v_plan NOT LIKE '%Index Scan%' THEN
        RAISE EXCEPTION 'B failed: with seq scan and sort forbidden, the planner still could '
                        'not answer the ANN ordering from any index on entities.embedding - '
                        'no hnsw index is usable on that column. Plan:%  %', E'\n', v_plan;
    END IF;
    IF v_plan LIKE '%Sort%' THEN
        RAISE EXCEPTION 'B failed: the ANN plan includes a Sort even though seq scan was '
                        'disabled, so it is still reading and ranking rows the 6.4 way - an '
                        'index bolted on that nothing can plan onto:%  %', E'\n', v_plan;
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- C. the index is not merely used, it is right: with a candidate set larger than the
    --    table, hnsw's top-10 must equal the exhaustive top-10. ef_search is raised locally
    --    for this probe - the assertion is "the graph stores the true distances", not
    --    "default recall", which is a tuning property of the future query path.
    ------------------------------------------------------------------
    BEGIN
        SET LOCAL hnsw.ef_search = 1000;
        SELECT string_agg(id::text, ',' ORDER BY id) INTO v_hnsw FROM (
            SELECT id FROM entities
             ORDER BY embedding <=> (SELECT embedding FROM entities WHERE name = '0012 probe e1')
             LIMIT 10) h;
        SELECT string_agg(id::text, ',' ORDER BY id) INTO v_exact FROM (
            SELECT id, row_number() OVER (ORDER BY embedding <=>
                   (SELECT embedding FROM entities WHERE name = '0012 probe e1')) rn
              FROM entities) x
         WHERE rn <= 10;
        -- Exactness is only the claim when the candidate budget covers the table; on a
        -- populated copy hnsw is approximate BY DESIGN and demanding equality here would
        -- make this migration fail for the size of the data rather than for its indexing.
        -- The replay-safe form is the recall lower bound the ef_search knob buys.
        IF (SELECT count(*) FROM entities) <= 1000 THEN
            IF v_hnsw IS DISTINCT FROM v_exact THEN
                RAISE EXCEPTION 'C failed: with the whole table inside the ef_search budget, '
                                'the hnsw index returned a different top-10 than an exhaustive '
                                'scan - the graph is inconsistent with the column it indexes';
            END IF;
        ELSIF (SELECT count(*) FROM unnest(string_to_array(v_hnsw, ',')))
                - (SELECT count(*) FROM unnest(string_to_array(v_hnsw, ',')) x(i)
                    WHERE i = ANY (string_to_array(v_exact, ','))) < 9 THEN
            RAISE EXCEPTION 'C failed: recall below 9/10 at ef_search=1000 on % rows - the '
                            'graph is not serving ANN queries honestly',
                            (SELECT count(*) FROM entities);
        END IF;
        v_n := v_n + 1;
    END;

    ------------------------------------------------------------------
    -- D. the storage premise of "no side table", asserted rather than remembered: the
    --    vectors landed in the toast fork, not the row fork. pg_column_size is the wrong
    --    instrument here and this is where 0012 learned it - it DETOASTS, so it reports
    --    ~6148 bytes for the value whether the row carries it or a pointer does, and a
    --    threshold on it fails against a schema that is storing things exactly as claimed.
    --    The sound instrument is the fork sizes: 500 rows x 6148 bytes is ~3.1 MB, so if
    --    they are out of line the toast fork grew by that much and the main fork barely
    --    moved; if a future change inlines them (STORAGE plain, a type swap, a dump/restore
    --    that loses the attstorage), the main fork grows ~6KB/row and this fails, which is
    --    the evidence that would make 6.4's side-table prescription right after all.
    ------------------------------------------------------------------
    SELECT pg_relation_size('entities'),
           coalesce(pg_total_relation_size((SELECT reltoastrelid FROM pg_class
                                            WHERE oid = 'entities'::regclass)), 0)
      INTO v_main1, v_toast1;
    IF (v_toast1 - v_toast0) < 500 * 3000 THEN
        RAISE EXCEPTION 'D failed: 500 vectorised rows grew the toast fork by only % bytes - '
                        'the vectors are not where 0012 decided they live',
                        (v_toast1 - v_toast0);
    END IF;
    IF (v_main1 - v_main0) > 500 * 400 THEN
        RAISE EXCEPTION 'D failed: 500 vectorised rows grew the MAIN fork by % bytes (>400B/row) '
                        '- the vectors are inline, which is 6.4''s scan claim being true, and '
                        'the side-table decision in this file must be revisited',
                        (v_main1 - v_main0);
    END IF;
    RAISE NOTICE '6.4: storage premise holds - % main bytes and % toast bytes for 500 '
                 'vectorised rows (out of line, as attstorage e promised)',
                 (v_main1 - v_main0), (v_toast1 - v_toast0);
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- E. the census this migration promises: every vector column of a base table is led by
    --    a hnsw index. Correlated per column - B12's original asked a table to be named
    --    like an index, so it could never pass; the same predicate lives in verify.sh now.
    ------------------------------------------------------------------
    SELECT count(*) INTO v_match
      FROM pg_attribute a
      JOIN pg_class c ON c.oid = a.attrelid AND c.relkind = 'r'
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_type t ON t.oid = a.atttypid
     WHERE n.nspname = 'public' AND t.typname = 'vector'
       AND a.attnum > 0 AND NOT a.attisdropped
       AND NOT EXISTS (SELECT 1 FROM pg_index i
                         JOIN pg_class ix ON ix.oid = i.indexrelid
                         JOIN pg_am  am ON am.oid = ix.relam
                        WHERE i.indrelid = c.oid AND am.amname = 'hnsw'
                          AND i.indkey[0] = a.attnum);
    IF v_match <> 0 THEN
        RAISE EXCEPTION 'E failed: % vector column(s) still have no hnsw index leading them', v_match;
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- F. and none wearing the old access method: an ivfflat surviving here would mean a
    --    second index object the review counted and this migration did not name.
    ------------------------------------------------------------------
    SELECT count(*) INTO v_match
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_am am ON am.oid = c.relam
     WHERE n.nspname = 'public' AND c.relkind = 'i' AND am.amname = 'ivfflat';
    IF v_match <> 0 THEN
        RAISE EXCEPTION 'F failed: % ivfflat index(es) remain in public - the swap left the '
                        'under-trained objects 6.4 is about still mounted', v_match;
    END IF;
    v_n := v_n + 1;

    DELETE FROM entities WHERE name LIKE '0012 probe e%';
    -- Scoped to the fixtures: on a populated copy "entities is now empty" was never true,
    -- and a replay must fail on residue it caused, not on data it merely moved past.
    IF (SELECT count(*) FROM entities WHERE name LIKE '0012 probe e%') <> 0 THEN
        RAISE EXCEPTION 'probe cleanup failed: % fixture rows remain',
            (SELECT count(*) FROM entities WHERE name LIKE '0012 probe e%');
    END IF;

    IF v_n <> 5 THEN
        RAISE EXCEPTION 'expected 5 behavioural verifications, completed %', v_n;
    END IF;
    RAISE NOTICE '6.4: % checks passed - the planner uses hnsw (and its graph is exact), the '
                 'vectors stay out of the rows, every vector column leads a hnsw index, and no '
                 'ivfflat survives', v_n;
END
$$;
