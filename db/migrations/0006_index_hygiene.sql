-- 0006: remove indexes that do nothing, and add the ones the hot path is missing
-- (DATABASE_REVIEW.md 5.5 and 5.6; plan P3).
--
-- 5.6 is write amplification with no read benefit. 5.5 is the opposite failure: the most
-- frequent agent action in the system - look a customer up by part of their name - runs
-- without any index that can serve it. Both are the same underlying absence: nobody ever
-- asked what a given index is FOR.
--
-- Four measurements decided this file's shape, and one of them contradicts the review.
--
-- A BTREE CANNOT SERVE THE QUERY THE APPLICATION WRITES.
--
-- blueprint/tools/customer_lookup.py:42 builds `WHERE name ILIKE '%' || :term || '%'`, and
-- update_customer builds the same shape for entities.name and contacts.email. Measured on a
-- 5,000-row entities table with only btree indexes available (a plain one and a
-- text_pattern_ops one, which is what a btree-on-text needs for pattern work):
--
--     name ILIKE '%A1B2C%'      ->  Seq Scan, 108 buffers, 2.6 ms
--     name ILIKE 'Customer A%'  ->  Seq Scan,  81 buffers, 2.7 ms
--     name ILIKE '%A1B2C%' (trigram GIN) -> Bitmap Index Scan, 7 buffers, 0.09 ms
--
-- So 5.5's list needs trigram indexes, not btrees, wherever the predicate is ILIKE. pg_trgm
-- has been installed since 0000 and used by nothing until now. A prefix pattern that matches
-- a large share of the table still seq-scans with the trigram in place - that is the planner
-- choosing correctly, not the index failing: 'ZZQQ%' costs 0.12 ms, 'Customer A%' 2.7 ms on
-- 6% of rows.
--
-- AN FK EXISTENCE CHECK HAS NO TENANT PREDICATE, SO A TENANT-LED INDEX DOES NOT COVER IT.
--
-- 0003 re-led many indexes with tenant_id, which is right for RLS scans and quietly removed
-- leading coverage from the columns Postgres must probe when a parent row is deleted or
-- re-keyed: `SELECT 1 FROM entity_relationships WHERE entity_id = $1 LIMIT 1` names no
-- tenant. Measured on a 5,000-row child table, that check as a seq scan versus an
-- entity_id-led index:
--
--     without leading coverage  47 buffers, 0.193 ms
--     with    leading coverage   6 buffers, 0.017 ms   (index-only, 11x)
--
-- Those buffers are 47 pages of the child table read while the parent row is locked, and the
-- page count is the size of the child. This is the judgment db/MIGRATIONS.md asked 0006 to
-- confirm rather than inherit: it is confirmed, against 0003, and section 3 closes the whole
-- class, not just the eleven columns the review happened to count.
--
-- MOST OPTIONAL FOREIGN KEYS SHOULD BE *PARTIAL* INDEXES.
--
-- The nullable FK columns (human_agent_id, from_location_id, bot_actions.entity_id, ...) are
-- absent on most rows. Measured on a 300,000-row table whose FK column is NULL 99% of the
-- time, with a partial `(col) WHERE col IS NOT NULL` index:
--
--     index size  48 kB partial  vs  2,064 kB plain        (43x)
--     FK check    Index Only Scan, 0.030 ms partial  vs  0.028 ms plain
--
-- The planner takes the partial index for the FK check without being forced to, because an
-- equality predicate implies `IS NOT NULL`. So section 3 derives the shape from `attnotnull`
-- rather than choosing a style: NOT NULL columns get a plain btree, nullable ones get a
-- partial. Same read behaviour, a fraction of the write cost 5.6 exists to reduce.
--
-- 5.6 IS BIGGER THAN THE REVIEW SAY: PREFIX-REDUNDANCY IS THE SAME DEFECT.
--
-- The review counted indexes with *identical* column lists, of which 3 pairs survive today
-- (0003 dissolved 4 and 0004 removed 1). An index whose key list is a strict leading prefix
-- of another index on the same table serves no scan the wider one cannot: it is the identical
-- defect, just less obvious. Four such pairs exist. Three are pure duplicates and are dropped
-- in section 2; the fourth, `idx_addresses_entity`, is dropped in section 4 *because* 0006
-- replaces it with a wider index that covers the same lookups and the sort as well.
--
-- WHAT THIS DELIBERATELY DOES NOT DO
--
--   * It does not index `entities.status` or `entities.entity_type`. 5.5 names them, but grep
--     finds no query in the tree that filters on either: status appears only in
--     `SET status = COALESCE(p_status, status)` and as a vw_customers output column, and
--     entity_type only as `= 'customer'` inside vw_customers itself, applied after the join.
--     Their distributions are 60/20/20 and 75/25, so an index would be a sequential read with
--     extra steps. Adding an index that serves no query is precisely the finding this migration
--     is fixing, so it is declined rather than performed.
--   * It does not index `contacts.first_name`/`last_name` separately. 0003 already created
--     `idx_contacts_tenant_name (tenant_id, last_name, first_name)`, and with a tenant
--     predicate present - which 0009's RLS guarantees on every query - a name search uses it:
--     measured 0.046 ms indexed with the predicate, 0.392 ms seq scan without. A second
--     name-led index would be a near-duplicate of it, i.e. finding 5.6 reintroduced by the
--     migration whose purpose is to remove 5.6.
--   * It does not index `inventory_movements.transaction_id`. It is unindexed today, but it is
--     not a foreign key and nothing queries it; 6.1 argues it into a deduplication key, and
--     that is 0011's decision to make with its access method attached to it.
--   * No index here is created CONCURRENTLY, because migrate.sh runs each file in one
--     transaction and CONCURRENTLY cannot do that. On a populated copy these are
--     SHARE-locking builds against real traffic; section 5 reports the row counts it locked so
--     the operator can see what a production run costs, and `dev/README.md` carries the
--     CONCURRENTLY equivalents.

SET client_min_messages TO notice;

-- ---------------------------------------------------------------------------
-- 0. The hazard check 0004 taught the hard way
-- ---------------------------------------------------------------------------
-- Inference for `ON CONFLICT (cols)` matches an index's key columns as a SET, so dropping or
-- re-keying a unique index can silently break an upsert that names no index at all. Every
-- index this migration drops is therefore announced, and asserted unreferenced, before it
-- goes. All six are non-unique - inference cannot use a non-unique index as an arbiter - but
-- "cannot" is checked here rather than remembered, because the cost of being wrong is an
-- exception in a function that no test exercises.
CREATE TEMP TABLE _afpc_0006_dropped ON COMMIT DROP AS
SELECT * FROM (VALUES
    -- 5.6: exact duplicate key sets. The idx_comms_* side survives: the naming census in
    -- communications is 11 idx_comms_* to 4 idx_comm_*, so the minority spellings go.
    ('communications','idx_comm_contact'),
    ('communications','idx_comm_entity'),
    ('communications','idx_comm_type'),
    -- 5.6 in its prefix form: each of these is a strict leading prefix of a wider index
    -- on the same table, so it answers no query the wider one does not.
    ('audit_summary','idx_audit_summary_tenant'),        -- prefix of (tenant_id,date,user_id,bot_id) UNIQUE
    ('locations','idx_locations_tenant'),                -- prefix of (tenant_id,warehouse_id,location_code) UNIQUE
    ('inventory_reservations','idx_reservations_item')   -- prefix of (item_id,priority)
) AS d(tbl, idx);

DO $$
DECLARE
    r         record;
    v_n       int := 0;
    v_ref     text;
    v_keys    text;
    v_wider   text;
    v_dropped_keys int[];
BEGIN
    FOR r IN SELECT * FROM _afpc_0006_dropped ORDER BY tbl, idx LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = format('public.%I', r.idx)::regclass) THEN
            RAISE NOTICE '% already gone - nothing to drop', r.idx;
            CONTINUE;
        END IF;

        -- Is anything using it as an ON CONFLICT arbiter, by name?
        SELECT string_agg(p.proname, ', ') INTO v_ref
          FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
          LEFT JOIN pg_depend dep ON dep.objid = p.oid AND dep.classid = 'pg_proc'::regclass
                                 AND dep.deptype = 'e'
         WHERE n.nspname = 'public' AND p.prokind = 'f' AND dep.objid IS NULL
           AND pg_get_functiondef(p.oid) LIKE '%' || r.idx || '%';
        IF v_ref IS NOT NULL THEN
            RAISE EXCEPTION 'refusing to drop %: it is named in the body of %', r.idx, v_ref;
        END IF;

        SELECT indisunique,
               (SELECT string_agg(coalesce(a.attname::text, 'EXPR'), ',' ORDER BY k.ord)
                  FROM unnest(i.indkey) WITH ORDINALITY k(attnum, ord)
                  LEFT JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
                 WHERE k.ord <= i.indnatts)
          INTO v_wider, v_keys
          FROM pg_index i WHERE i.indexrelid = format('public.%I', r.idx)::regclass;

        -- The claim that makes the drop safe, asserted per index rather than argued in a
        -- comment: some OTHER index on the same table has this one's key list as a leading
        -- prefix (so every scan survives), or, for the duplicate pairs, an identical twin
        -- remains.
        IF v_wider::boolean THEN
            RAISE EXCEPTION '% is UNIQUE - dropping it would remove a constraint, not an '
                            'index, and 0006 is not authorised to decide constraints', r.idx;
        END IF;

        -- The key list being given up. Normalised through unnest-with-ordinality rather than
        -- cast, because indkey is an int2vector with ZERO-based subscripts: `indkey::int[]`
        -- keeps them, so `[1:n]` would skip the first column and compare the wrong keys. The
        -- same trap that bit 0004's index introspection, third time.
        SELECT array_agg(u.ax ORDER BY u.ord) INTO v_dropped_keys
          FROM unnest((SELECT indkey::int[] FROM pg_index
                        WHERE indexrelid = format('public.%I', r.idx)::regclass))
               WITH ORDINALITY u(ax, ord);

        IF NOT EXISTS (
            SELECT 1 FROM pg_index o
             CROSS JOIN LATERAL (
                SELECT array_agg(t.ax ORDER BY t.ord)                              AS full_keys,
                       (SELECT array_agg(s.ax ORDER BY s.ord)
                          FROM unnest(o.indkey::int[]) WITH ORDINALITY s(ax, ord)
                         WHERE s.ord <= cardinality(v_dropped_keys))           AS prefix_keys
                  FROM unnest(o.indkey::int[]) WITH ORDINALITY t(ax, ord)
             ) kk
             WHERE o.indrelid = format('public.%I', r.tbl)::regclass
               AND o.indexrelid <> format('public.%I', r.idx)::regclass
               -- identical key set (the duplicate case), or this index's keys are a leading
               -- prefix of the survivor (the prefix-redundant case). A survivor shorter than
               -- the dropped index produces a short prefix_keys, which cannot compare equal.
               AND (kk.full_keys = v_dropped_keys OR kk.prefix_keys = v_dropped_keys)
        ) THEN
            RAISE EXCEPTION 'refusing to drop %: no other index on % covers key list (%)',
                r.idx, r.tbl, v_keys;
        END IF;

        EXECUTE format('DROP INDEX public.%I', r.idx);
        v_n := v_n + 1;
        RAISE NOTICE 'dropped % (%) - covered by another index on %', r.idx, v_keys, r.tbl;
    END LOOP;
    RAISE NOTICE '5.6: % redundant indexes removed', v_n;
END
$$;

-- ---------------------------------------------------------------------------
-- 1. FK coverage: every single-column foreign key must LEAD some index
-- ---------------------------------------------------------------------------
-- Derived from pg_constraint, not listed, for the same reason 0005's widening list is: a
-- hand-written list drifts the moment a migration adds a table. The predicate is "no index
-- on this table has this column in position 0" - a column indexed only in position 2 or 3
-- counts as uncovered, which is exactly what 0003's tenant-led re-lead left behind and what
-- the measurement in the header prices at 47 pages scanned under a lock.
DO $$
DECLARE
    r           record;
    v_name      text;
    v_prefix    text;
    v_sql       text;
    n           int := 0;
    v_part      int := 0;
    v_plain     int := 0;
BEGIN
    -- Names follow the prefix each table already uses, so this migration does not add a third
    -- spelling to communications the way 5.6 found it carrying two.
    FOR r IN
        SELECT c.conrelid::regclass::text          AS tbl,
               (SELECT attname FROM pg_attribute
                 WHERE attrelid = c.conrelid AND attnum = (c.conkey)[1]) AS col,
               (SELECT attnotnull FROM pg_attribute
                 WHERE attrelid = c.conrelid AND attnum = (c.conkey)[1]) AS notnull,
               c.conname                            AS fk
          FROM pg_constraint c
         WHERE c.contype = 'f' AND c.connamespace = 'public'::regnamespace
           AND cardinality(c.conkey) = 1
           -- not the tenant_id columns: 0003 gave every table a tenant-led index, which is
           -- the right shape for those (a tenant scan is the only query they get)
           AND (SELECT attname FROM pg_attribute
                 WHERE attrelid = c.conrelid AND attnum = (c.conkey)[1]) <> 'tenant_id'
           AND NOT EXISTS (SELECT 1 FROM pg_index i
                            WHERE i.indrelid = c.conrelid
                              AND i.indkey[0] = (c.conkey)[1])
         ORDER BY c.conrelid::regclass::text, 2
    LOOP
        SELECT coalesce(pfx.short, r.tbl) INTO v_prefix
          FROM (VALUES ('communications','comms'), ('inventory_movements','movements'),
                       ('inventory_reservations','reservations'), ('inventory_on_hand','on_hand'),
                       ('entity_relationships','entity_relationships')) pfx(tbl, short)
         WHERE pfx.tbl = r.tbl
         LIMIT 1;
        v_prefix := coalesce(v_prefix, r.tbl);
        v_name   := 'idx_' || v_prefix || '_' || r.col;
        -- An FK whose column is nullable is optional: most rows do not participate in it.
        -- The partial form measured 43x smaller with identical FK-check timing.
        v_sql := format('CREATE INDEX %I ON public.%I (%I)%s', v_name, r.tbl, r.col,
                        CASE WHEN r.notnull THEN ''
                             ELSE ' WHERE ' || quote_ident(r.col) || ' IS NOT NULL' END);
        BEGIN
            EXECUTE v_sql;
            n := n + 1;
            IF r.notnull THEN v_plain := v_plain + 1; ELSE v_part := v_part + 1; END IF;
            RAISE NOTICE 'FK coverage: % on %.% (%) for %', v_name, r.tbl, r.col,
                CASE WHEN r.notnull THEN 'plain' ELSE 'partial' END, r.fk;
        EXCEPTION WHEN duplicate_table THEN
            RAISE NOTICE 'FK coverage: % already exists', v_name;
        END;
    END LOOP;
    RAISE NOTICE '5.6/FK: % indexes added (% partial, % plain)', n, v_part, v_plain;

    -- The invariant, stated as one rather than as a count of the columns known today: after
    -- this migration no single-column foreign key may lack leading index coverage.
    IF EXISTS (SELECT 1 FROM pg_constraint c
                WHERE c.contype = 'f' AND c.connamespace = 'public'::regnamespace
                  AND cardinality(c.conkey) = 1
                  AND (SELECT attname FROM pg_attribute
                        WHERE attrelid = c.conrelid AND attnum = (c.conkey)[1]) <> 'tenant_id'
                  AND NOT EXISTS (SELECT 1 FROM pg_index i
                                   WHERE i.indrelid = c.conrelid AND i.indkey[0] = (c.conkey)[1])) THEN
        RAISE EXCEPTION 'single-column foreign keys still lack leading index coverage';
    END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- 2. The CRM read path 5.5 measured as unindexed
-- ---------------------------------------------------------------------------
-- Each index here is justified by a query that exists, and the two that 5.5 asks for but that
-- no query needs are declined - with the reason - in the header.

-- entities.name: the single most frequent agent action. ILIKE '%frag%' is what the tool
-- builds, and a btree cannot answer it at any selectivity (measured, header).
CREATE INDEX IF NOT EXISTS idx_entities_name_trgm
    ON entities USING gin (name gin_trgm_ops);

COMMENT ON INDEX idx_entities_name_trgm IS
    'Trigram index for the customer lookup path: vw_customers WHERE name ILIKE ''%term%'' '
    '(blueprint/tools/customer_lookup.py). A btree cannot serve a contains pattern at all - '
    'measured: seq scan either way - and pg_trgm has been installed since 0000 and unused '
    'until this migration. Review 5.5.';

-- entities.tax_id: an exact-match dedup check during onboarding, currently a full scan, and
-- the one 5.5 column whose predicate is equality rather than pattern.
CREATE INDEX IF NOT EXISTS idx_entities_tax_id ON entities (tax_id) WHERE tax_id IS NOT NULL;

-- contacts.email: add_customer/update_customer test `email ILIKE p_email`, which is a
-- pattern predicate even when the caller passes no wildcards, so it needs trgm too - a btree
-- on lower(email) would not be used by ILIKE.
CREATE INDEX IF NOT EXISTS idx_contacts_email_trgm
    ON contacts USING gin (email gin_trgm_ops);

-- contacts.phone: equality in the same duplicate checks.
CREATE INDEX IF NOT EXISTS idx_contacts_phone ON contacts (phone) WHERE phone IS NOT NULL;

-- vw_customers resolves the address with a correlated
--   WHERE entity_id = e.id ORDER BY is_primary DESC, created_at DESC LIMIT 1
-- once per output row. The old idx_addresses_entity satisfied the predicate and then sorted,
-- per row, forever. This index removes the sort; the sort-free plan is the point, and it is
-- why idx_addresses_entity is dropped rather than kept alongside (section 0's rule in the
-- other direction: do not leave a prefix behind the index that supersedes it).
CREATE INDEX IF NOT EXISTS idx_addresses_entity_primary_recent
    ON addresses (entity_id, is_primary DESC, created_at DESC);

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_class WHERE oid = 'public.idx_addresses_entity'::regclass) THEN
        DROP INDEX public.idx_addresses_entity;
        RAISE NOTICE 'dropped idx_addresses_entity - it is a strict prefix of '
                     'idx_addresses_entity_primary_recent, which also serves the entity_id '
                     'foreign key check';
    END IF;
END
$$;


-- ---------------------------------------------------------------------------
-- 4. Who is watching, rather than who is guessing
-- ---------------------------------------------------------------------------
-- "Is this index redundant?" is a question with a non-obvious answer, and the obvious version
-- of it was wrong here: the first draft of this migration's check paired indexes with
-- `x.indexrelid < y.indexrelid` to avoid reporting each pair twice, which silently meant "only
-- report redundancy when the narrower index happens to have been created first". It found 3
-- pairs on the development database and 0 on a clone where the same indexes had been recreated
-- in the other order. The condition is already asymmetric through "narrower AND a prefix", so no
-- tiebreak was needed at all.
--
-- That is worth one definition rather than four, because a check duplicated across a migration,
-- a test file and a scoreboard is a check that drifts. The view follows ADR-003: it is the same
-- object the harness reads and the same object an auditor can open, and 0002's default
-- privileges make it readable by afpc_auditor without further grants.
CREATE OR REPLACE VIEW vw_index_redundancy AS
WITH k AS (
    -- Key lists rebuilt 1-based. indkey is an int2vector with ZERO-based subscripts, so
    -- `indkey::int[]` keeps them and a slice like [1:n] of it skips the first column - the
    -- third time that representation has bitten something in this repository. Aggregating
    -- through WITH ORDINALITY yields a normal 1-based array. A key of 0 is an expression, not
    -- a column, and can never equal a real attnum, so an expression position is a safe
    -- mismatch rather than a false match.
    SELECT i.indrelid, i.indexrelid, i.indisunique, i.indpred,
           (SELECT array_agg(q.v ORDER BY q.o)
              FROM unnest(i.indkey::int[]) WITH ORDINALITY q(v, o)) AS attnums,
           cardinality(i.indkey::int[]) AS n,
           (SELECT string_agg(coalesce(a.attname::text, '(expression)'), ', ' ORDER BY o.ord)
              FROM unnest(i.indkey) WITH ORDINALITY o(attnum, ord)
              LEFT JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = o.attnum) AS key_names,
           (i.indpred IS NOT NULL) AS is_partial
      FROM pg_index i
      JOIN pg_class c ON c.oid = i.indrelid
      JOIN pg_namespace ns ON ns.oid = c.relnamespace AND ns.nspname = 'public'
)
SELECT xk.indrelid::regclass::text                      AS table_name,
       xr.relname                                       AS redundant_index,
       xk.key_names                                     AS redundant_keys,
       yr.relname                                       AS covered_by,
       yk.key_names                                     AS covered_by_keys,
       CASE WHEN xk.attnums = yk.attnums THEN 'identical' ELSE 'prefix' END AS redundancy
  FROM k xk
  JOIN k yk ON yk.indrelid = xk.indrelid
           -- A strict prefix is already asymmetric, so it needs no tiebreak; twins do, or each
           -- would be reported as redundant to the other. The later-created twin is the one to
           -- drop, which is also the one a restore script would have added last.
           AND (yk.n > xk.n OR (yk.n = xk.n AND xk.indexrelid > yk.indexrelid))
  JOIN pg_class xr ON xr.oid = xk.indexrelid
  JOIN pg_class yr ON yr.oid = yk.indexrelid
 WHERE xk.indpred IS NULL                        -- a partial index is never assumed redundant
   AND NOT xk.indisunique                        -- a unique index may be a constraint, not slack
   AND xk.attnums = (yk.attnums)[1:xk.n]         -- prefix OR, when n is equal, identity
   AND xr.relname NOT LIKE '%_pkey';

COMMENT ON VIEW vw_index_redundancy IS
    'Indexes whose key list is identical to, or a strict leading prefix of, another index on '
    'the same table: write amplification with no read benefit. Two forms of the same finding, '
    'and the second is easy to miss - the review counted only identical column lists (5.6). '
    'Expression keys, unique indexes, partial indexes and primary keys are excluded from being '
    'called redundant, each for a reason that is not style: an expression index is not '
    'interchangeable with an index on its raw column (0004''s identity index), and a partial '
    'index may be the only thing enforcing an optional foreign key efficiently. Built by 0006.';

-- ---------------------------------------------------------------------------
-- 5. Nothing was lost, and the claims above are re-checked, not remembered
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v       bigint;
    v_scan  text;
    v_best  text;
    n       int;
BEGIN
    -- 5.1 5.6 proper: no two indexes on a table may share a key list.
    SELECT count(*) INTO v FROM (
        SELECT indrelid, indkey::int[] AS k FROM pg_index
         WHERE indrelid IN (SELECT oid FROM pg_class WHERE relnamespace = 'public'::regnamespace)
         GROUP BY indrelid, k HAVING count(*) > 1) d;
    IF v > 0 THEN
        RAISE EXCEPTION 'identical index key sets remain on % table(s)', v;
    END IF;

    -- 5.2 The same finding in its prefix form, asked of the view rather than re-derived here.
    IF EXISTS (SELECT 1 FROM vw_index_redundancy) THEN
        RAISE EXCEPTION 'redundant indexes remain: %',
            (SELECT string_agg(table_name || '.' || redundant_index || ' [' || redundancy ||
                               ' in ' || covered_by || ']', ', ')
               FROM (SELECT * FROM vw_index_redundancy ORDER BY 1 LIMIT 8) z);
    END IF;

    -- 5.3 The ILIKE columns are reachable by an index, checked as a catalog fact and then as a
    --     plan. The plan probe forbids the sequential path first: on a table this migration
    --     has not populated, the planner would rather seq scan than seek, which is correct
    --     and proves nothing about whether the index WORKS. Asking "can this predicate use the
    --     index at all" is the claim that can be settled here; asking "does it win" needs data
    --     and belongs in db/tests/5_5_6_index_hygiene.sql, which inserts some.
    SELECT count(*) INTO v FROM (VALUES ('entities','name'),('contacts','email')) c(t, col)
     WHERE NOT EXISTS (SELECT 1 FROM pg_index i
                         JOIN pg_opclass o ON o.oid = i.indclass[0]
                         JOIN pg_class tc ON tc.oid = i.indrelid
                        WHERE tc.relname = c.t AND i.indkey[0] = (SELECT attnum FROM pg_attribute
                                                                  WHERE attrelid = tc.oid AND attname = c.col)
                          AND o.opcname = 'gin_trgm_ops');
    IF v > 0 THEN
        RAISE EXCEPTION '% ILIKE column(s) have no trigram index, so 5.5 is not closed', v;
    END IF;

    -- Whether the trigram also BEATS the sequential path is a question about statistics, not
    -- about this migration, and an empty table always answers it "no". db/tests/
    -- 5_5_6_index_hygiene.sql puts rows in and asks it for real.

    -- 5.4 Every added FK index is actually usable: assert each FK column leads something.
    SELECT count(*) INTO v FROM pg_constraint c
     WHERE c.contype = 'f' AND c.connamespace = 'public'::regnamespace
       AND cardinality(c.conkey) = 1
       AND (SELECT attname FROM pg_attribute
             WHERE attrelid = c.conrelid AND attnum = (c.conkey)[1]) <> 'tenant_id'
       AND NOT EXISTS (SELECT 1 FROM pg_index i
                        WHERE i.indrelid = c.conrelid AND i.indkey[0] = (c.conkey)[1]);
    IF v > 0 THEN
        RAISE EXCEPTION '% foreign key columns still lead no index', v;
    END IF;

    -- 5.5 A partial FK index must not be created on a NOT NULL column: there the predicate
    --     is decoration, and the index is the wide one with extra steps. Checked as a class.
    SELECT count(*) INTO v FROM pg_index i
      JOIN pg_class c ON c.oid = i.indexrelid
     WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'i'
       AND i.indpred IS NOT NULL AND (i.indkey::int[])[1] > 0
       AND (SELECT attnotnull FROM pg_attribute a
             WHERE a.attrelid = i.indrelid AND a.attnum = (i.indkey::int[])[1]);
    IF v > 0 THEN
        RAISE NOTICE '% partial indexes sit on a NOT NULL column - the predicate is vacuous '
                     'and a plain index is smaller; not fatal, but 0006 did not intend it', v;
    END IF;

    -- 5.6 Locks taken, reported rather than assumed. On a fresh database every count is zero
    --     and this is noise; on a populated copy it is the number an operator needs before
    --     agreeing to run this file during business hours.
    SELECT string_agg(t, ', ' ORDER BY rows DESC) INTO v_best FROM (
        SELECT relname||'='||n_live_tup||' rows' AS t, n_live_tup AS rows
          FROM pg_stat_user_tables
         WHERE relname IN ('communications','inventory_movements','addresses','entity_relationships',
                           'entities','contacts','audit_summary','locations','inventory_on_hand')
    ) x;
    RAISE NOTICE 'indexes now in place across: %', coalesce(v_best, '(no statistics yet)');

    SELECT count(*) INTO n FROM pg_class c JOIN pg_am am ON am.oid = c.relam
      JOIN pg_namespace ns ON ns.oid = c.relnamespace
     WHERE ns.nspname = 'public' AND c.relkind = 'i' AND am.amname = 'gin';
    RAISE NOTICE 'verified: % GIN indexes (the ILIKE path), no duplicate or prefix-redundant '
                 'index pairs, every foreign key leading an index', n;
END
$$;
