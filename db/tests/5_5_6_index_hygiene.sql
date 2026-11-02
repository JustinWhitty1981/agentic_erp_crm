-- Findings 5.5 and 5.6, observed as behaviour rather than as a catalog read.
--
-- verify.sh can already see that an index exists. What it cannot see, and what both findings
-- turn on, is whether an index gets USED - and that is a question about statistics, so it
-- cannot be answered on an empty development table. 0006 learned this while verifying itself:
-- with entities empty, the planner prefers a sequential scan, and equally prefers a full btree
-- scan of idx_entities_tenant_name used as a filter when the sequential path is merely
-- forbidden. Neither says anything about whether the trigram index works.
--
-- So this file supplies its own volume, inside a transaction that rolls back. ANALYZE is legal
-- inside a transaction and its pg_statistic writes roll back with the rows, so the planner sees
-- a table with real numbers and then forgets it. The sequences the inserts advance are restored
-- afterwards by scripts/db/test-functions.sh.
--
-- Two separate claims, checked separately, because they fail for different reasons:
--
--   (a) USABILITY - the index can answer the predicate at all. Checked by forbidding the other
--       access paths and asking whether the trigram still appears. This is the honest form of
--       "is 5.5 fixed", and it is size-independent given statistics.
--   (b) PREFERENCE - the planner chooses it without being pushed. Only asserted once the table
--       is genuinely large; below that a sequential scan is the CORRECT plan and reporting it
--       as a failure would teach people to ignore the row.
--
-- 5.6's hygiene half is a plain catalog assertion: it is a claim about what exists, and no
-- amount of data would make it more true.

-- 5.5 - the customer lookup path.
--
-- The query is the one blueprint/tools/customer_lookup.py:42 sends: a contains-match on
-- entities.name through vw_customers with a LIMIT. Before 0006 there is no index that can
-- answer it at any size, which is the defect; after 0006 the trigram answers it.
BEGIN;
DO $$
DECLARE
    v_plan  text;
    v_pages bigint;
BEGIN
    INSERT INTO entities (name, entity_type, status)
    SELECT 'Volume Probe ' || g || ' ' ||
           (ARRAY['Alpha', 'Beta', 'Gamma', 'Delta'])[1 + (g % 4)], 'customer', 'active'
      FROM generate_series(1, 10000) g;
    -- The needle: a fragment no generated name contains. A pattern that matches every row
    -- would be answered by a sequential scan for reasons that have nothing to do with whether
    -- the index exists, which is the mistake in the first draft of this file.
    INSERT INTO entities (name) VALUES ('Xylophonic Prime Holdings');
    ANALYZE entities;

    -- (a) usability
    SET LOCAL enable_seqscan = off;
    SET LOCAL enable_indexscan = off;   -- without this, a btree full scan as a filter wins
    EXECUTE 'EXPLAIN (FORMAT JSON, COSTS OFF) SELECT 1 FROM public.entities '
            'WHERE name ILIKE ' || quote_literal('%Xylophonic%') || ' LIMIT 5'
       INTO v_plan;
    RESET enable_seqscan; RESET enable_indexscan;

    IF v_plan LIKE '%idx_entities_name_trgm%' THEN
        RAISE NOTICE 'VERDICT OK the lookup predicate is answered by the trigram index';
    ELSE
        RAISE NOTICE 'VERDICT ERR no index can answer the entity-name lookup (5.5): %',
            left(v_plan, 110);
    END IF;

    -- (b) preference, but only where the claim is meaningful. On a 10,000-row table the planner
    -- correctly chooses the sequential path (measured: it stops preferring it somewhere between
    -- 10k and 20k rows), so asserting this now would be asserting a cost-model detail.
    SELECT relpages INTO v_pages FROM pg_class WHERE oid = 'public.entities'::regclass;
    IF v_pages > 4000 THEN
        EXECUTE 'EXPLAIN (FORMAT JSON, COSTS OFF) SELECT 1 FROM public.entities '
                'WHERE name ILIKE ' || quote_literal('%Xylophonic%') || ' LIMIT 5'
           INTO v_plan;
        IF v_plan LIKE '%"Node Type": "Seq Scan"%' THEN
            RAISE NOTICE 'VERDICT ERR the trigram index is not being preferred at this scale '
                         '(% pages) even though it can answer the predicate', v_pages;
        ELSE
            RAISE NOTICE 'VERDICT OK at % pages the planner prefers the index without being '
                         'asked to', v_pages;
        END IF;
    ELSE
        RAISE NOTICE 'VERDICT INFO preference not asserted: entities is % pages, below the '
                     'point where a sequential scan stops being the cheaper answer', v_pages;
    END IF;

    -- The other ILIKE in the tree: add_customer and update_customer test `email ILIKE p_email`.
    -- A btree on lower(email) would not be used by that predicate, which is why this is trgm.
    INSERT INTO contacts (first_name, last_name, email)
    SELECT 'F', 'L', 'probe-' || g || '@volume-probe.invalid' FROM generate_series(1, 10000) g;
    INSERT INTO contacts (first_name, last_name, email)
    VALUES ('F', 'L', 'needle@zq7x9trgm.invalid');
    ANALYZE contacts;

    SET LOCAL enable_seqscan = off;
    SET LOCAL enable_indexscan = off;
    EXECUTE 'EXPLAIN (FORMAT JSON, COSTS OFF) SELECT 1 FROM public.contacts '
            'WHERE email ILIKE ' || quote_literal('%zq7x9trgm%')
       INTO v_plan;
    RESET enable_seqscan; RESET enable_indexscan;

    IF v_plan LIKE '%idx_contacts_email_trgm%' THEN
        RAISE NOTICE 'VERDICT OK the email duplicate check is answered by the trigram index';
    ELSE
        RAISE NOTICE 'VERDICT ERR no index can answer the email duplicate check (5.5): %',
            left(v_plan, 110);
    END IF;
END
$$;
ROLLBACK;

-- 5.6 - does a foreign key existence check actually use the index 0006 added for it?
--
-- This is the query Postgres runs when a parent row is deleted or re-keyed, and it is why a
-- tenant-led composite was not enough: that check names no tenant. The column here is nullable,
-- so the index is PARTIAL, and the load-bearing assumption is that an equality predicate
-- implies IS NOT NULL so the planner can take it. Measured against a 300k-row table that is 99%
-- NULL, the partial form is 43x smaller than the plain one with the same check timing.
BEGIN;
DO $$
DECLARE
    v_ent  bigint;
    v_plan text;
BEGIN
    INSERT INTO entities (name) VALUES ('AFPC Fk Probe Parent') RETURNING id INTO v_ent;

    -- Mostly absent references, with exactly one pointing at the parent: the shape of an
    -- optional foreign key, and the shape a partial index is chosen for.
    INSERT INTO human_sessions (user_id, user_name, bot_id, bot_type, entity_id,
                                session_status, login_time)
    SELECT 900000 + g, 'probe-user', 'probe-bot', 'telegram',
           CASE WHEN g = 9000 THEN v_ent END, 'active',
           now() - ((g % 500) || ' minutes')::interval
      FROM generate_series(1, 10000) g;
    ANALYZE human_sessions;

    EXECUTE 'EXPLAIN (FORMAT JSON, COSTS OFF) SELECT 1 FROM public.human_sessions '
            'WHERE entity_id = ' || v_ent::text || ' LIMIT 1'
       INTO v_plan;

    IF v_plan LIKE '%idx_human_sessions_entity_id%' THEN
        RAISE NOTICE 'VERDICT OK the foreign key check uses the partial index on %.%',
            'human_sessions', 'entity_id';
    ELSIF v_plan LIKE '%"Node Type": "Seq Scan"%' THEN
        RAISE NOTICE 'VERDICT ERR the foreign key check still scans the child table, so a '
                     'parent delete reads every page of it under a lock (5.6)';
    ELSE
        RAISE NOTICE 'VERDICT INFO the check took neither path: %', left(v_plan, 110);
    END IF;
END
$$;
ROLLBACK;

-- 5.6 - the hygiene invariant.
--
-- This reads vw_index_redundancy rather than re-deriving the answer, which is the point of the
-- view: a check that exists in a migration, a scoreboard and a test file is a check whose three
-- copies drift, and the first copy of this one was wrong in a way only two of the three would
-- have noticed. The view excludes primary keys, unique indexes, partial indexes and expression
-- keys from being called redundant, each for a reason that is not style - notably 0004's identity
-- index, whose COALESCE positions distinguish no-bin stock rows and would read as a mere
-- superset of the plain (tenant_id, item_id, warehouse_id) unique next to it.
DO $$
DECLARE
    v_rows int;
    v_list text;
BEGIN
    IF to_regclass('public.vw_index_redundancy') IS NULL THEN
        RAISE NOTICE 'VERDICT ERR no redundancy view exists yet, so 5.6 has been measured by '
                     'nobody (0006 creates it)';
        RETURN;
    END IF;

    SELECT count(*), coalesce(string_agg(table_name || '.' || redundant_index || ' [' ||
                                         redundancy || ' in ' || covered_by || ']', ', '), '-')
      INTO v_rows, v_list
      FROM vw_index_redundancy;

    IF v_rows = 0 THEN
        RAISE NOTICE 'VERDICT OK no redundant index pairs in public';
    ELSE
        RAISE NOTICE 'VERDICT ERR % index pairs are redundant: %', v_rows, v_list;
    END IF;
END
$$;
