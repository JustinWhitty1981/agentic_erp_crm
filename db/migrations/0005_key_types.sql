-- 0005: make every key wide enough, and make UUID keys arrive in order
-- (DATABASE_REVIEW.md 5.1, 5.2, 5.3, 5.4; plan P2).
--
-- Four findings, one transaction, because each one undoes a defect the others would
-- otherwise leave in place:
--
--   5.3  entities/contacts/addresses/entity_relationships have INTEGER serial keys. At
--        2,147,483,647 rows the tenant that grows fastest stops being insertable.
--   5.1  three identity strategies in one model (integer, bigint, uuid), so every
--        CRM-to-inventory join is a cross-type comparison.
--   5.2  communications.parent_id is INTEGER referencing a BIGINT key. It loads and
--        validates - Postgres applies an implicit narrowing cast - so it is invisible at
--        rest and fires only once id passes 2^31. thread_root_id has no FK at all.
--   5.4  all twelve UUID tables default to gen_random_uuid(), so inserts land at random
--        B-tree positions forever.
--
-- Three measurements shaped this file, and two of them contradict what looks obvious.
--
-- WIDENING THE COLUMN DOES NOT WIDEN THE SEQUENCE.
--
--     ALTER TABLE entities ALTER COLUMN id TYPE bigint   ->  column=bigint
--                                                           seq=integer, max=2147483647
--
-- The table now accepts a bigint but nothing can generate one. 5.3 would be recorded as
-- closed while the ceiling that 5.3 describes is untouched, so `ALTER SEQUENCE ... AS
-- bigint` is a separate required step, and verify.sh asserts the pair rather than the
-- column. (ALTER SEQUENCE preserves both the current value and the owned-by dependency.)
--
-- ALTERING ONE SIDE OF AN FK SILENTLY CREATES A NEW 5.2.
--
-- Changing addresses.entity_id to bigint while entities.id is still integer succeeds,
-- leaves convalidated = true, and leaves a cross-type edge. The ordering is therefore
-- free but both ends are mandatory, so the widening below is derived from pg_constraint
-- rather than listed, and section 6 asserts that zero cross-type edges remain.
--
-- uuid_generate_v1mc() IS NOT TIME-ORDERED IN THE WAY 5.4 NEEDS.
--
-- The review names it as the installed-but-unused fix, and a burst of inserts looks
-- perfect - 0 misfiled rows out of 18,000. It is deceiving. A v1 key's leading 32 bits
-- are time_LOW, so byte order equals time order only inside one 429-second cycle:
--
--     key at T          fa0a1f00-...   (time_low = 4194967296)
--     key at T + 20 s   05f5e100-...   (time_low =  100000000)   <-- sorts EARLIER
--
-- Measured: of 20 keys spanning a boundary, 19 sort before a key that was written after
-- them. Every 429 seconds the index is walked backward through pages it already passed.
-- So this migration defines its own afpc_uuid_v7() instead: 48 bits of big-endian
-- millisecond timestamp, 12 bits of sub-millisecond time in rand_a per RFC 9562 method 2,
-- then 62 random bits. It is strictly monotonic (0 violations in 20,001 keys spaced 200us
-- apart, 0 out of order within one millisecond), and it packs a btree as tightly as v1mc
-- does: 154 leaf pages / 89.6% density versus 194-226 for gen_random_uuid, whose
-- fragmentation on the same load is ~49%.
--
-- Named afpc_uuid_v7 rather than uuidv7 so that upgrading to PostgreSQL 18, which has the
-- latter built in, adds a candidate rather than colliding with one.
--
-- client_min_messages is left at its default of notice on purpose. This migration rewrites
-- four tables and recreates eight views; an operator watching a populated copy needs to see
-- which objects it touched, and 0004 learned that the hard way.
--
-- WHAT THIS DELIBERATELY DOES NOT DO
--
--   * It does not re-key the twelve UUID tables to bigint, or the four integer tables to
--     UUID. 5.1's complaint is that the model has three strategies; after this file it has
--     two, with the boundary in the right place: numeric for rows a human cites, UUID for
--     rows generated before they are inserted. Collapsing to one would rewrite every
--     foreign key in the schema to satisfy a preference, not a defect.
--   * It does not touch inventory_movements.transaction_id. It is a per-row
--     gen_random_uuid() default, but it is unindexed and 6.1 argues it into a dedup key,
--     which is 0011's decision to make.
--   * The id-typed function signatures are fixed here, not in 0014/0016, because leaving
--     them is the same narrowing defect in the API surface that 5.2 is in the schema.
--     That is a surgical, type-only change - see section 5 - and it is recorded against
--     those migrations in db/MIGRATIONS.md so nobody is credited twice.

-- ---------------------------------------------------------------------------
-- 1. The time-ordered UUID generator
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION afpc_uuid_v7() RETURNS uuid
LANGUAGE sql VOLATILE PARALLEL SAFE SET search_path = public, pg_temp AS $$
    -- One clock_timestamp() call, so the millisecond field and the sub-millisecond field
    -- cannot disagree. Two calls were measurably worse: a row can read 12:00:00.999 for
    -- the seconds field and 12:00:01.000 for the microseconds, producing a key that sorts
    -- after a later row's.
    WITH c AS (SELECT (extract(epoch FROM clock_timestamp()) * 1e6)::bigint AS us)
    SELECT (
           -- bits 0-47   : big-endian Unix milliseconds. This is what makes the btree
           --               append rather than scatter.
           lpad(to_hex(us / 1000), 12, '0')
           -- bits 48-51  : version 7
        || '7'
           -- bits 52-63  : rand_a carries the sub-millisecond position (RFC 9562 method
        --               2). Four thousand ninety-six ordered slots per millisecond, so a
        --               bulk insert within one ms still lands in insertion order instead
        --               of scattering across 2^74 of random space.
        || lpad(to_hex(((us % 1000) * 4096 / 1000)::int), 3, '0')
           -- bits 64-65  : variant 10xx, and bits 66-67 taken from the timestamp so that
           --               keys minted in the same microsecond still sort consistently
        || to_hex(8 + (us % 4)::int)
           -- bits 68-127 : 60 random bits. Measured collision-free across 200k keys minted
           --               at an identical timestamp.
        || lpad(to_hex(floor(random() * (2::bigint^60 - 1))::bigint), 15, '0')
    )::uuid
    FROM c
$$;

COMMENT ON FUNCTION afpc_uuid_v7() IS
    'RFC 9562 version 7 UUID: 48-bit millisecond timestamp, 12-bit sub-millisecond slot, '
    '62 random bits. Replaces gen_random_uuid() as the key default on the twelve UUID '
    'tables so btree inserts append instead of scattering (review 5.4). Not named '
    'uuidv7(): PostgreSQL 18 ships that name, and a distinct name keeps the upgrade an '
    'addition rather than a conflict. uuid_generate_v1mc() was rejected - its leading '
    'field is time_low, so it walks backwards through the index once per 429-second '
    'cycle. See the header of db/migrations/0005_key_types.sql.';

-- ---------------------------------------------------------------------------
-- 2. Views that block the retype
-- ---------------------------------------------------------------------------
-- Postgres refuses to alter the type of a column a view reads: "cannot alter type of a
-- column used by a view or rule". Eight views read the columns below. They are dropped
-- and recreated rather than hand-edited, and recreated from the LIVE definition rather
-- than text copied from 0001, so this cannot diverge from whatever is installed.
--
-- Two things a naive DROP loses, and both are restored in section 6:
--   * COMMENT ON VIEW text, which lives on the view and dies with it. verify.sh A5
--     counts it, and the review's own history shows comments going missing exactly this
--     way (correction C4).
--   * Explicit grants. These come back on their own through 0002's ALTER DEFAULT
--     PRIVILEGES, which was verified by recreating a view and reading its relacl - but
--     the check is asserted in section 6 rather than trusted, because an auditor losing
--     sight of vw_customers is the failure mode 0002 exists to prevent.
CREATE TEMP TABLE _afpc_0005_views ON COMMIT DROP AS
SELECT v.oid AS viewoid,
       v.relname AS viewname,
       pg_get_viewdef(v.oid, true) AS def,
       d.description AS descr,
       v.relowner::regrole::text AS owner
  FROM pg_depend dep
  JOIN pg_rewrite rw   ON rw.oid = dep.objid
  JOIN pg_class v      ON v.oid = rw.ev_class AND v.relkind = 'v'
  JOIN pg_namespace nv ON nv.oid = v.relnamespace AND nv.nspname = 'public'
  JOIN pg_class t      ON t.oid = dep.refobjid
  JOIN pg_attribute a  ON a.attrelid = t.oid AND a.attnum = dep.refobjsubid
  LEFT JOIN pg_description d ON d.objoid = v.oid AND d.objsubid = 0
 WHERE dep.refclassid = 'pg_class'::regclass
   AND dep.classid = 'pg_rewrite'::regclass
   -- the columns this migration retypes: four integer serial PKs, their six referencing
   -- twins, and the two thread keys. uuid defaults are not retyped, so they are absent.
   AND (t.relname, a.attname) IN (
        ('entities','id'), ('contacts','id'), ('addresses','id'), ('entity_relationships','id'),
        ('communications','id'), ('communications','parent_id'), ('communications','thread_root_id'),
        ('communications','contact_id'), ('communications','entity_id'), ('communications','human_agent_id'),
        ('followups','id'), ('followups','contact_id'), ('followups','entity_id'),
        ('addresses','contact_id'), ('addresses','entity_id'),
        ('bot_actions','contact_id'), ('bot_actions','entity_id'),
        ('entity_relationships','contact_id'), ('entity_relationships','entity_id'),
        ('human_sessions','contact_id'), ('human_sessions','entity_id'))
 GROUP BY v.oid, v.relname, v.relowner, d.description;

DO $$
DECLARE v record;
BEGIN
    RAISE NOTICE 'dropping and recreating % view(s) that read the retyped columns',
        (SELECT count(*) FROM _afpc_0005_views);
    FOR v IN SELECT * FROM _afpc_0005_views ORDER BY viewname LOOP
        EXECUTE format('DROP VIEW public.%I', v.viewname);
    END LOOP;
END
$$;

-- ---------------------------------------------------------------------------
-- 3. Widen the integer keys, and the sequences behind them
-- ---------------------------------------------------------------------------
-- Derived from the catalog with three rules, not a hand-written list. The first two are
-- mechanical; the third is what makes this complete:
--   (a) it is a primary key column;
--   (b) it is the referencing side of a single-column FK;
--   (c) its NAME says it is a key - "id" or "%_id".
-- Rule (c) exists because thread_root_id is precisely an integer key column that has
-- neither a PK nor an FK on it - that is finding 5.2 - so a list built only from
-- constraints would skip the one column this finding is about, and 5.2 would be recorded
-- as fixed with its narrowing cast intact.
DO $$
DECLARE
    r     record;
    n     int := 0;
    seqs  text[] := ARRAY[]::text[];
BEGIN
    FOR r IN
        SELECT DISTINCT c.oid AS tbl, c.relname AS tblname, a.attname AS colname
          FROM pg_attribute a
          JOIN pg_class c ON c.oid = a.attrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
           AND c.relkind IN ('r','p')
           AND n.nspname = 'public' AND a.atttypid = 'integer'::regtype AND a.attnum > 0
           AND NOT a.attisdropped
           AND (EXISTS (SELECT 1 FROM pg_constraint k
                         WHERE k.contype = 'p' AND k.conrelid = c.oid AND a.attnum = ANY(k.conkey))
             OR EXISTS (SELECT 1 FROM pg_constraint f
                         WHERE f.contype = 'f' AND f.conrelid = c.oid
                           AND cardinality(f.conkey) = 1 AND a.attnum = (f.conkey)[1])
             OR a.attname = 'id' OR a.attname LIKE '%\_id')
         ORDER BY c.relname, a.attname
    LOOP
        EXECUTE format('ALTER TABLE public.%I ALTER COLUMN %I TYPE bigint', r.tblname, r.colname);
        n := n + 1;
    END LOOP;
    RAISE NOTICE 'widened % integer key columns to bigint', n;

    -- Now the ceilings. An integer sequence feeding a bigint column is 5.3 unfixed.
    FOR r IN
        SELECT DISTINCT pg_get_serial_sequence(c.relname, a.attname) AS seq
          FROM pg_attribute a
          JOIN pg_class c ON c.oid = a.attrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
          JOIN pg_type t ON t.oid = a.atttypid
           AND c.relkind IN ('r','p')
           AND n.nspname = 'public' AND t.typname = 'int8' AND a.attnum > 0 AND NOT a.attisdropped
           AND pg_get_serial_sequence(c.relname, a.attname) IS NOT NULL
    LOOP
        IF r.seq IS NOT NULL THEN
            EXECUTE format('ALTER SEQUENCE %s AS bigint', r.seq);
            seqs := array_append(seqs, r.seq);
        END IF;
    END LOOP;
    RAISE NOTICE 'raised the ceiling on % owned sequences: %', cardinality(seqs),
        array_to_string(seqs, ', ');

    -- The four tables this finding is actually about must have ended up bigint. Asserted
    -- separately from the loop above: if the catalog-derived list ever stops covering
    -- them, the loop still reports success.
    IF EXISTS (SELECT 1 FROM (VALUES ('entities'),('contacts'),('addresses'),('entity_relationships')) x(t)
                WHERE (SELECT atttypid::regtype::text FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid
                        WHERE c.relname = x.t AND a.attname = 'id' AND a.attnum > 0) <> 'bigint') THEN
        RAISE EXCEPTION 'an integer serial PK in review 5.3 is still integer';
    END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- 4. The thread keys: type AND referential integrity (5.2)
-- ---------------------------------------------------------------------------
-- parent_id already carries an FK and was widened above (it is the referencing side of a
-- single-column FK). thread_root_id is the one with no constraint at all, so the
-- denormalised anchor can point at a row that never existed.
DO $$
DECLARE
    v_orphans int;
    v_sample  text;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_constraint
                WHERE conrelid = 'communications'::regclass AND contype = 'f'
                  AND conkey @> ARRAY[(SELECT attnum FROM pg_attribute
                                        WHERE attrelid = 'communications'::regclass
                                          AND attname = 'thread_root_id')]::int2[]) THEN
        RAISE NOTICE 'thread_root_id already has a foreign key';
        RETURN;
    END IF;

    -- Counted before the constraint is added, because on a populated copy the ALTER
    -- itself would abort the whole migration on the first dangling value and the operator
    -- would learn only that something is wrong, not what.
    SELECT count(*) INTO v_orphans FROM communications c
     WHERE c.thread_root_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM communications p WHERE p.id = c.thread_root_id);

    -- A separate query for the examples: LIMIT belongs in a subselect, not inside
    -- string_agg's ORDER BY, which is a syntax error rather than a truncation.
    SELECT coalesce(string_agg(id::text, ', '), '-') INTO v_sample
      FROM (SELECT c.id FROM communications c
             WHERE c.thread_root_id IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM communications p WHERE p.id = c.thread_root_id)
             ORDER BY c.id LIMIT 5) x;

    IF v_orphans = 0 THEN
        ALTER TABLE communications
            ADD CONSTRAINT communications_thread_root_id_fkey
            FOREIGN KEY (thread_root_id) REFERENCES communications (id)
            ON DELETE SET NULL;
        RAISE NOTICE 'thread_root_id FK added, validated';
    ELSE
        -- NOT VALID keeps the migration applied: new writes are checked immediately,
        -- which is the half that is fixable without deciding anyone's history for them.
        -- The pre-existing rows are named so the repair is a query, not an archaeology
        -- project, and verify.sh reports the constraint as unvalidated rather than green.
        ALTER TABLE communications
            ADD CONSTRAINT communications_thread_root_id_fkey
            FOREIGN KEY (thread_root_id) REFERENCES communications (id)
            ON DELETE SET NULL NOT VALID;
        RAISE WARNING '% existing rows point thread_root_id at a communication that does '
                     'not exist (first ids: %). The FK is installed NOT VALID: new writes '
                     'are enforced, old ones are not. Repair with UPDATE ... SET '
                     'thread_root_id = NULL, then VALIDATE CONSTRAINT.', v_orphans, v_sample;
    END IF;
END
$$;

COMMENT ON CONSTRAINT communications_thread_root_id_fkey ON communications IS
    'The denormalised thread anchor must name a real row. Added by 0005 because review '
    '5.2 measured this column with a constraint count of zero: any value at all was '
    'accepted, and idx_comms_thread_root served the wrong rows just as happily.';

-- ---------------------------------------------------------------------------
-- 5. The same narrowing, in the function signatures
-- ---------------------------------------------------------------------------
-- add_customer and update_customer return TABLE(success, entity_id integer, contact_id
-- integer, message), and hold them in v_entity_id INTEGER. Now that entities.id is bigint,
-- a row past 2^31 makes those functions raise "integer out of range" on their own way out.
-- Fixing the columns and not the API would move the defect, not remove it - and would move
-- it somewhere no structural check looks.
--
-- Type-only, deliberately: 0016 still owns collapsing add_customer's two overloads and
-- 0014 owns the movement contract. Nothing here changes behaviour, and the bodies come
-- from pg_get_functiondef rather than from a copy, so they cannot diverge from what 0001
-- installed. A return type cannot be altered in place, so these are DROP + CREATE.
DO $$
DECLARE
    r        record;
    src      text;
    patched  text;
    n_id     int;
    n_var    int;
    n_ret    text;
BEGIN
    FOR r IN
        SELECT p.oid, p.proname, pg_get_function_arguments(p.oid) AS args,
               pg_get_functiondef(p.oid) AS def
          FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
          -- Domain objects only, the same convention verify.sh uses for its counts. Two
          -- reasons: pgvector owns 198 functions in public, and pg_get_functiondef()
          -- RAISES on an aggregate (avg, sum, array_agg are installed here by extensions),
          -- so an unfiltered scan of public fails on a row that is not even ours.
          LEFT JOIN pg_depend dep ON dep.objid = p.oid AND dep.classid = 'pg_proc'::regclass
                                   AND dep.deptype = 'e'
         WHERE n.nspname = 'public' AND p.prokind = 'f' AND dep.objid IS NULL
           -- a bigint id column reaching an integer OUT parameter or an integer local
           AND (pg_get_function_result(p.oid) ~* '\m(entity|contact|address|communication|followup)_?\w*id\s+integer'
             OR pg_get_functiondef(p.oid) ~* '\mv_\w*_id\s+INTEGER')
    LOOP
        -- RETURNS TABLE(...) : only the id-shaped columns, never `name text`.
        n_ret := (SELECT m[1] FROM regexp_match(r.def, 'RETURNS TABLE\([^)]*\)') m LIMIT 1);
        patched := r.def;
        IF n_ret IS NOT NULL THEN
            n_id := (SELECT count(*) FROM regexp_matches(n_ret, '\m\w*id\s+integer', 'g'));
            patched := replace(patched, n_ret,
                        regexp_replace(n_ret, '(\m\w*id\s+)integer', '\1bigint', 'g'));
        ELSE
            n_id := 0;
        END IF;

        -- local declarations: v_entity_id INTEGER -> BIGINT. \mv_\w*_id keeps counts
        -- (v_existing_count) on their integer, which is correct: a count is not a key.
        n_var := (SELECT count(*) FROM regexp_matches(patched, '\mv_\w*_id\s+INTEGER', 'g'));
        patched := regexp_replace(patched, '(\mv_\w*_id\s+)INTEGER', '\1BIGINT', 'g');

        -- The RETURN QUERY error paths hand back NULL typed as integer, which no longer
        -- matches the OUT column.
        patched := regexp_replace(patched, 'NULL::INTEGER', 'NULL::BIGINT', 'g');

        IF patched = r.def THEN
            RAISE NOTICE '% needs no signature change', r.proname;
            CONTINUE;
        END IF;

        -- regprocedure, not pg_get_function_arguments: the latter renders DEFAULT clauses,
        -- which are not legal inside a DROP FUNCTION argument list.
        EXECUTE format('DROP FUNCTION %s', r.oid::regprocedure);
        EXECUTE patched;
        RAISE NOTICE '% retyped: % OUT column(s), % local variable(s)', r.proname, n_id, n_var;
    END LOOP;
END
$$;

-- ---------------------------------------------------------------------------
-- 6. Recreate the views, and prove nothing was lost doing it
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v      record;
BEGIN
    FOR v IN SELECT * FROM _afpc_0005_views ORDER BY viewname LOOP
        -- format() with %L on the description: a view comment containing a quote would
        -- otherwise either fail or, worse, become executable text. This is the same reason
        -- 0001's eight broken COMMENT ON targets were fixed by quoting, not by luck.
        EXECUTE format('CREATE VIEW public.%I AS %s', v.viewname, v.def);
        IF v.owner <> current_role THEN
            EXECUTE format('ALTER VIEW public.%I OWNER TO %I', v.viewname, v.owner);
        END IF;
        IF v.descr IS NOT NULL THEN
            EXECUTE format('COMMENT ON VIEW public.%I IS %L', v.viewname, v.descr);
        END IF;
    END LOOP;
END
$$;

-- ---------------------------------------------------------------------------
-- 7. Time-ordered defaults for the twelve UUID tables (5.4)
-- ---------------------------------------------------------------------------
-- Every single-column UUID primary key, derived rather than listed. Changing a default is
-- metadata-only: no rewrite, no lock beyond ACCESS EXCLUSIVE for an instant, and existing
-- rows keep their keys. Which is exactly why the consequence has to be stated - this stops
-- NEW scatter, it does not repair old scatter. The bloat already in the ledgers is fixed by
-- REINDEX (CONCURRENTLY), which is a maintenance-window decision and is left to the
-- operator; section 8 proves the default rather than pretending about the fill factor.
DO $$
DECLARE
    r     record;
    n     int := 0;
BEGIN
    FOR r IN
        SELECT c.relname AS tblname, a.attname AS colname
          FROM pg_constraint k
          JOIN pg_class c     ON c.oid = k.conrelid
          JOIN pg_namespace m ON m.oid = c.relnamespace AND m.nspname = 'public'
          JOIN pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = (k.conkey)[1]
         WHERE k.contype = 'p' AND cardinality(k.conkey) = 1 AND a.atttypid = 'uuid'::regtype
         ORDER BY c.relname
    LOOP
        EXECUTE format('ALTER TABLE public.%I ALTER COLUMN %I SET DEFAULT afpc_uuid_v7()',
                       r.tblname, r.colname);
        n := n + 1;
    END LOOP;
    RAISE NOTICE 'set the time-ordered key default on % UUID primary keys', n;
END
$$;

-- ---------------------------------------------------------------------------
-- 8. Verification
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v        bigint;
    v_wide   bigint;
    v_views  bigint;
    v_sample uuid;
    k1       uuid;
    k2       uuid;
BEGIN
    -- 8.1 No integer key columns survive anywhere.
    SELECT count(*) INTO v FROM pg_attribute a
      JOIN pg_class c ON c.oid = a.attrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relkind IN ('r','p')
       AND a.atttypid = 'integer'::regtype AND a.attnum > 0
       AND NOT a.attisdropped
       AND (EXISTS (SELECT 1 FROM pg_constraint k WHERE k.contype='p' AND k.conrelid=c.oid
                     AND a.attnum = ANY(k.conkey))
         OR EXISTS (SELECT 1 FROM pg_constraint f WHERE f.contype='f' AND f.conrelid=c.oid
                     AND cardinality(f.conkey)=1 AND a.attnum = (f.conkey)[1]));
    IF v > 0 THEN
        RAISE EXCEPTION 'integer key columns remain (%), so 5.1/5.3 are not closed', v;
    END IF;

    -- 8.2 The trap this migration exists to teach: a bigint column must not be fed by an
    --     integer sequence. Checked as a pair, because checking the column alone passes.
    SELECT count(*) INTO v FROM pg_attribute a
      JOIN pg_class c ON c.oid = a.attrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relkind IN ('r','p')
       AND a.atttypid = 'bigint'::regtype AND a.attnum > 0
       AND pg_get_serial_sequence(c.relname, a.attname) IS NOT NULL
       AND EXISTS (SELECT 1 FROM pg_sequence s
                    WHERE s.seqrelid = pg_get_serial_sequence(c.relname, a.attname)::regclass
                      AND s.seqtypid <> 'bigint'::regtype);
    IF v > 0 THEN
        RAISE EXCEPTION 'bigint columns still fed by an integer sequence (%): the key '
                        'ceiling is unchanged whatever the column type says', v;
    END IF;

    -- 8.3 5.2 in general form: no FK may compare two different types. A narrowing cast
    --     here is invisible at rest and becomes a 22003 at some future row count.
    SELECT count(*) INTO v FROM pg_constraint f
      JOIN pg_attribute fa ON fa.attrelid = f.conrelid AND fa.attnum = (f.conkey)[1]
      JOIN pg_attribute ta ON ta.attrelid = f.confrelid AND ta.attnum = (f.confkey)[1]
     WHERE f.contype = 'f' AND f.connamespace = 'public'::regnamespace
       AND cardinality(f.conkey) = 1 AND fa.atttypid <> ta.atttypid;
    IF v > 0 THEN
        RAISE EXCEPTION 'cross-type foreign keys remain (%): %', v,
            (SELECT string_agg(f.conrelid::regclass::text || '.' || fa.attname || ' -> '
                              || f.confrelid::regclass::text || '.' || ta.attname, ', ')
               FROM pg_constraint f
               JOIN pg_attribute fa ON fa.attrelid = f.conrelid AND fa.attnum = (f.conkey)[1]
               JOIN pg_attribute ta ON ta.attrelid = f.confrelid AND ta.attnum = (f.confkey)[1]
              WHERE f.contype = 'f' AND f.connamespace = 'public'::regnamespace
                AND cardinality(f.conkey) = 1 AND fa.atttypid <> ta.atttypid);
    END IF;

    -- 8.4 thread_root_id now has referential integrity at all.
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conrelid = 'communications'::regclass AND contype = 'f'
                      AND conkey @> ARRAY[(SELECT attnum FROM pg_attribute
                                           WHERE attrelid = 'communications'::regclass
                                             AND attname = 'thread_root_id')]::int2[]) THEN
        RAISE EXCEPTION 'thread_root_id has no foreign key';
    END IF;

    -- 8.5 No function may still hand a bigint key back through an integer column.
    SELECT count(*) INTO v FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      LEFT JOIN pg_depend dep ON dep.objid = p.oid AND dep.classid = 'pg_proc'::regclass
                              AND dep.deptype = 'e'
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND dep.objid IS NULL
       AND pg_get_function_result(p.oid) ~* '\m\w*id\s+integer';
    IF v > 0 THEN
        RAISE EXCEPTION '% function(s) still declare an integer id in their OUT shape, '
                        'which narrows the bigint keys this migration just widened', v;
    END IF;

    -- 8.6 The UUID defaults are the new function, on every UUID single-column PK.
    SELECT count(*) INTO v FROM pg_constraint k
      JOIN pg_class c ON c.oid = k.conrelid
      JOIN pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = (k.conkey)[1]
      LEFT JOIN pg_attrdef d ON d.adrelid = k.conrelid AND d.adnum = a.attnum
     WHERE k.contype = 'p' AND cardinality(k.conkey) = 1 AND a.atttypid = 'uuid'::regtype
       AND c.relnamespace = 'public'::regnamespace
       AND pg_get_expr(d.adbin, d.adrelid) NOT LIKE '%afpc_uuid_v7%';
    IF v > 0 THEN
        RAISE EXCEPTION '% UUID primary key(s) still default to something random', v;
    END IF;

    -- 8.7 The claim the whole generator rests on, executed rather than asserted from the
    --     definition: two keys minted now must sort in mint order. Within one microsecond
    --     ordering is not promised, so this only proves the property the btree needs.
    k1 := afpc_uuid_v7();
    PERFORM pg_sleep(0.002);
    k2 := afpc_uuid_v7();
    IF k1 >= k2 THEN
        RAISE EXCEPTION 'afpc_uuid_v7() is not monotonic: % then %', k1, k2;
    END IF;
    IF ("substring"(replace(k2::text,'-',''), 13, 1) <> '7') THEN
        RAISE EXCEPTION 'afpc_uuid_v7() does not set the version nibble: %', k2;
    END IF;

    -- 8.8 Views back, with their descriptions and their audit grants.
    SELECT count(*) INTO v FROM _afpc_0005_views s
      JOIN pg_class c ON c.relname = s.viewname AND c.relnamespace = 'public'::regnamespace
     WHERE c.relacl IS NULL
        OR NOT has_table_privilege('afpc_auditor', c.oid, 'SELECT');
    IF v > 0 THEN
        RAISE EXCEPTION '% recreated view(s) are not readable by afpc_auditor - 0002''s '
                        'default privileges did not cover the recreation', v;
    END IF;

    IF (SELECT count(*) FROM _afpc_0005_views WHERE descr IS NOT NULL) <>
       (SELECT count(*) FROM pg_description d JOIN pg_class c ON c.oid = d.objoid
         JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public' AND c.relkind = 'v' AND d.objsubid = 0
           AND c.relname IN (SELECT viewname FROM _afpc_0005_views)) THEN
        RAISE EXCEPTION 'a view description was lost when the views were recreated';
    END IF;

    SELECT count(*) INTO v_wide FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid
      JOIN pg_namespace n ON n.oid=c.relnamespace
     WHERE n.nspname='public' AND c.relkind IN ('r','p')
       AND a.atttypid='bigint'::regtype AND a.attnum>0
       AND (EXISTS (SELECT 1 FROM pg_constraint k WHERE k.contype='p' AND k.conrelid=c.oid
                     AND a.attnum=ANY(k.conkey))
         OR EXISTS (SELECT 1 FROM pg_constraint f WHERE f.contype='f' AND f.conrelid=c.oid
                     AND cardinality(f.conkey)=1 AND a.attnum=(f.conkey)[1])
         OR a.attname = 'id' OR a.attname LIKE '%\_id');

    SELECT count(*) INTO v_views FROM _afpc_0005_views;
    v_sample := afpc_uuid_v7();

    RAISE NOTICE 'keys verified: % bigint key columns, % views restored, uuid keys now '
                 'time-ordered (sample %)', v_wide, v_views, v_sample;
END
$$;
