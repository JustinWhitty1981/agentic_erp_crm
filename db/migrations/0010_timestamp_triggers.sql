-- 0010: make updated_at mean "last written" (DATABASE_REVIEW.md 6.3)
--
-- 6.3's verdict is "timestamp hygiene is inconsistent", and its evidence is a table: nine
-- objects carry an updated_at, two of them are maintained by a trigger, seven are not, and the
-- two that are maintained fire on UPDATE only. The consequence it draws is the one that matters:
-- "no incremental-sync or change-data-capture query in this model is trustworthy" - because the
-- column exists, looks populated, and says nothing about what changed.
--
-- Measuring it on this database produced four findings the review could not contain, because it
-- is a reading of the canonical dump rather than of the schema the earlier migrations built:
--
--   A. THE POPULATION IS ELEVEN TABLES, NOT NINE. Measured: entities, contacts, communications,
--      human_sessions, followups, _schema_graph, inventory_items, item_categories, locations,
--      warehouses - the review's list, which omits tenants, the table 0003 created with an
--      updated_at and nothing to maintain it. The finding grew by one simply by following the
--      plan, which is the argument for deriving the scope from the catalog rather than from a
--      list in a document: section 4 loops over pg_attribute and B11 asks the same question, so a
--      table that gains the column later is covered by the mechanism or named by the scoreboard.
--   B. A NULL updated_at IS A DIFFERENT LIE FROM A STALE ONE. The column is nullable on six of
--      the eleven tables and NOT NULL on five - one column, one meaning, two declarations, in one
--      schema. A sync query written as "WHERE updated_at > :watermark" silently drops every NULL
--      row on the nullable half, which reads as "nothing changed" about a row that changed
--      yesterday. Section 3.3 backfills from created_at and makes the declaration uniform.
--      created_at is left nullable on purpose: a row whose creation time is unknown is a fact
--      about the port, and inventing a timestamp would replace an honest gap with a fabricated
--      one. That is the choice 0005 made about dangling thread anchors, applied here.
--   C. THE TWO EXISTING TRIGGERS ARE ONE RULE WRITTEN TWICE.
--      update_communications_updated_at() and update_updated_at_column() have byte-identical
--      bodies - md5 of prosrc, asserted in section 2 rather than assumed, because if they ever
--      differ then replacing both with one function silently changes behaviour on one of them.
--      Two implementations of one rule is how they drift apart, and 0001's port is what left both
--      behind.
--   D. THE REVIEW'S LAST PARAGRAPH IS WRONG IN A USEFUL WAY. It says inventory_movements,
--      inventory_on_hand and inventory_reservations "have no timestamp-shaped column at all", and
--      separately that this "removes the natural partition key from two of the highest-growth
--      tables". Measured: movements has performed_at, reservations has reserved_at, on_hand has
--      last_movement_at - all NOT NULL, all defaulted to now(). None of the three has a
--      *row-creation* timestamp, which is a different fact from the one each of those columns
--      records, and for on_hand the difference is fatal: last_movement_at is overwritten by every
--      movement, so the age of a stock row is unknowable from its second transaction onward. So
--      section 3.1 adds created_at to the two tables the review's own words name and leaves
--      inventory_movements alone - a movement is an event, and performed_at is already both its
--      event time and its write time. A second column there would be a second truth.
--
-- What the trigger does on UPDATE is the part worth reading twice:
--
--     IF NEW.updated_at IS NOT DISTINCT FROM OLD.updated_at THEN NEW.updated_at := now();
--
-- i.e. stamp it unless the statement set it deliberately. An ordinary edit - a name, a quantity,
-- a status - gets stamped, which is the finding. The case the condition exists for is the
-- backfill: a migration or import that carries real historical timestamps survives instead of
-- being overwritten with the clock. Every bulk repair in this directory that rewrites rows
-- (0004's duplicate merge, 0005's key widening, 0006's index rebuilds) would otherwise stamp the
-- whole table "changed now" and destroy the ordering the next migration reads. Probes A and B
-- assert both halves of that sentence, in that order, on the same row.
--
-- The stamp is now(), the transaction timestamp, and that has a consequence worth stating before
-- anyone debugs a probe: inside one transaction every write in it is stamped identically, so
-- "the column did not move" is not evidence of a broken trigger and "it moved" is not evidence of
-- a working one either. Every before/after assertion below therefore *pins* the column to a past
-- value first and asks whether the write moved it off it, which is a claim that holds at any
-- transaction boundary. The same property is what makes a batch a single event to a
-- change-data-capture reader - probe D asserts twenty rows move to one timestamp, because
-- clock_timestamp() would have produced twenty and a watermark could fall between any pair.
--
-- Two consequences nobody should have to discover:
--   - The touch trigger fires on every write path, so operations that look like reads of state -
--     shipping a reservation, decommissioning a warehouse, retiring an item - all move their
--     rows' updated_at now. That is the point. It also means 0011's optimistic-locking trigger
--     lands on the same two tables (inventory_on_hand, inventory_reservations), and PostgreSQL
--     fires same-timing same-event row triggers in name order: afpc_touch_updated_at runs before
--     trg_*. Both assign to NEW and return it, so the order is not observable today; recorded
--     because an AFTER-row variant would see the stamped value.
--   - addresses is a table the review's arithmetic missed. It appears as "created_at yes,
--     updated_at no", with no trigger - and update_customer rewrites it on every address change,
--     so an agent editing a shipping address leaves no trace anywhere. That is the same defect as
--     the stale columns, one step worse, because there is no column to be stale. It was found by
--     asking pg_proc which tables its functions write, which is why section 3.2 derives its list
--     that way and why the register publishes the answer.

SET client_min_messages TO notice;

-- ---------------------------------------------------------------------------
-- 1. One implementation of the rule
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION afpc_touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        -- "IS NOT DISTINCT FROM" rather than "=" because the column is still nullable on six
        -- tables at the moment this migration runs, and NULL = NULL is NULL: the comparison this
        -- replaces would never stamp a row whose updated_at had never been set.
        IF NEW.updated_at IS NOT DISTINCT FROM OLD.updated_at THEN
            NEW.updated_at := now();
        END IF;
    ELSIF NEW.updated_at IS NULL THEN
        -- Insert path. The column defaults to now() on every table that has it, so this fires
        -- only for a caller that passes NULL explicitly - which is the backfill shape, again.
        NEW.updated_at := now();
    END IF;
    RETURN NEW;
END
$$;

COMMENT ON FUNCTION afpc_touch_updated_at IS
    'The single implementation of "updated_at means last written" (review 6.3), fired by a BEFORE '
    'INSERT OR UPDATE row trigger named afpc_touch_updated_at on every table that has an '
    'updated_at column. On UPDATE it stamps the column unless the statement set it to something '
    'other than its current value, so a backfill or import that carries historical timestamps '
    'survives while an ordinary edit cannot forget to maintain it; on INSERT it fills a NULL. '
    'now() is deliberately the transaction timestamp rather than clock_timestamp(): every row one '
    'statement touches shares one instant, which is what makes a batch a single event to a '
    'change-data-capture reader - and the reason a test of this trigger must pin the column to a '
    'past value before it asks whether a write moved it. Retires update_updated_at_column and '
    'update_communications_updated_at, which were the same body twice.';

-- ---------------------------------------------------------------------------
-- 2. Retire the bespoke triggers, then the duplicated function
-- ---------------------------------------------------------------------------
-- Asserted before dropping rather than after: a trigger whose definition differs from the one
-- being replaced is a different database than the one this migration was written against, and
-- repointing it quietly would lose whatever the variant does.
DO $$
DECLARE
    r       record;
    v_h1    text;
    v_h2    text;
    v_n     int := 0;
BEGIN
    SELECT md5(coalesce(p1.prosrc, '')), md5(coalesce(p2.prosrc, ''))
      INTO v_h1, v_h2
      FROM pg_proc p1, pg_proc p2
     WHERE p1.proname = 'update_communications_updated_at'
       AND p2.proname = 'update_updated_at_column';
    IF v_h1 IS NULL OR v_h2 IS NULL THEN
        RAISE EXCEPTION 'one of the two legacy timestamp functions is already absent - '
                        're-measure 6.3 before continuing';
    END IF;
    IF v_h1 <> v_h2 THEN
        RAISE EXCEPTION 'the two legacy timestamp trigger functions have DIFFERENT bodies (% vs '
                        '%) - 6.3 describes one rule written twice, and if they differ then '
                        'replacing both with one function changes behaviour on one of them',
                        left(v_h1, 8), left(v_h2, 8);
    END IF;
    RAISE NOTICE '6.3C confirmed: update_communications_updated_at and update_updated_at_column '
                 'are byte-identical (%), so one replacement loses nothing', left(v_h1, 8);

    FOR r IN SELECT tg.tgname, c.relname AS tbl, tg.tgtype::int AS bits
               FROM pg_trigger tg
               JOIN pg_class c ON c.oid = tg.tgrelid
               JOIN pg_proc p  ON p.oid = tg.tgfoid
              WHERE c.relnamespace = 'public'::regnamespace
                AND p.proname IN ('update_communications_updated_at','update_updated_at_column')
              ORDER BY c.relname
    LOOP
        -- 19 = FOR EACH ROW | BEFORE | UPDATE (bits 1 + 2 + 16), which is 6.3's "fire on UPDATE
        -- only". Asserted as a number rather than read from pg_get_triggerdef, because the bits
        -- are also what B11 has to test and getting them wrong is how the first version of that
        -- check passed for seven years: 2 is BEFORE, not INSERT, and 4 is INSERT, not UPDATE.
        IF r.bits <> 19 THEN
            RAISE EXCEPTION 'trigger %.% is tgtype %, not 19 (BEFORE UPDATE FOR EACH ROW) - the '
                            'finding describes a narrower trigger than the one installed, so the '
                            'replacement would change behaviour', r.tbl, r.tgname, r.bits;
        END IF;
        EXECUTE format('DROP TRIGGER %I ON public.%I', r.tgname, r.tbl);
        v_n := v_n + 1;
        RAISE NOTICE 'repointing %.% (was BEFORE UPDATE only) to the consolidated trigger',
                     r.tbl, r.tgname;
    END LOOP;
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'expected the two UPDATE-only timestamp triggers, dropped % - re-measure '
                        '6.3. (trg_on_hand_consistency is the schema''s third trigger; it '
                        'maintains quantity_available, not a timestamp, and is left alone)', v_n;
    END IF;

    DROP FUNCTION update_communications_updated_at();
    DROP FUNCTION update_updated_at_column();
    RAISE NOTICE '6.3C: both copies of the rule dropped; afpc_touch_updated_at is now the only '
                 'function that writes the column';
END
$$;

-- ---------------------------------------------------------------------------
-- 3. The columns 6.3 says are missing, and the declarations it says are inconsistent
-- ---------------------------------------------------------------------------
-- 3.1 The row-creation timestamps (finding D). Backfilled from the earliest ledger event that
--     could have created the row, which is the only truthful source available. On this database
--     both tables are empty, so these UPDATEs do nothing here and real work on a populated copy -
--     which is why they are written as backfills rather than left to the column default.
DO $$
DECLARE
    v_rows int;
BEGIN
    ALTER TABLE inventory_on_hand ADD COLUMN created_at timestamptz;
    UPDATE inventory_on_hand ioh
       SET created_at = COALESCE(
            (SELECT min(m.performed_at) FROM inventory_movements m
              WHERE m.item_id = ioh.item_id
                AND (m.to_warehouse_id = ioh.warehouse_id
                  OR m.from_warehouse_id = ioh.warehouse_id)),
            ioh.last_movement_at, now())
     WHERE ioh.created_at IS NULL;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    ALTER TABLE inventory_on_hand ALTER COLUMN created_at SET DEFAULT now();
    ALTER TABLE inventory_on_hand ALTER COLUMN created_at SET NOT NULL;
    COMMENT ON COLUMN inventory_on_hand.created_at IS
        'When this stock row began to exist. Distinct from last_movement_at, which every movement '
        'overwrites: before 0010 the age of a stock row was unknowable from its second '
        'transaction onward (review 6.3, finding D). Backfilled from the earliest movement that '
        'touched the same item in the same warehouse, which is a lower bound and the only '
        'evidence there was.';
    RAISE NOTICE '6.3D: inventory_on_hand.created_at added (% existing rows backfilled from the '
                 'earliest movement that could have made them)', v_rows;

    ALTER TABLE inventory_reservations ADD COLUMN created_at timestamptz;
    UPDATE inventory_reservations
       SET created_at = COALESCE(reserved_at, now())
     WHERE created_at IS NULL;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    ALTER TABLE inventory_reservations ALTER COLUMN created_at SET DEFAULT now();
    ALTER TABLE inventory_reservations ALTER COLUMN created_at SET NOT NULL;
    COMMENT ON COLUMN inventory_reservations.created_at IS
        'When the row was created. reserved_at is the same instant for a reservation nobody has '
        'touched since and a different one after a shipment or cancellation edits it, which is '
        'why both columns exist (review 6.3, finding D).';
    RAISE NOTICE '6.3D: inventory_reservations.created_at added (% rows backfilled from '
                 'reserved_at)', v_rows;

    -- inventory_movements is deliberately not in this list, and the reason goes where an agent
    -- will read it rather than being left to someone wondering about the missing column.
    COMMENT ON COLUMN inventory_movements.performed_at IS
        'When the movement happened - for an event row, also when it was written, which is why '
        'this table has no created_at (review 6.3, finding D). Movements are append-only; 0013''s '
        'audit work enforces that, 0010 only records why the column is absent.';
END
$$;

-- 3.2 Then the tables that hold an editable row and cannot show it. Derived rather than listed,
--     from the only evidence inside the database about which rows change: a live function body
--     that UPDATEs the table. That is what found addresses, which the review classifies as merely
--     missing a column, and it is what makes a later migration's new write path a FAIL instead of
--     an oversight - verify.sh B24 asks this same question.
DO $$
DECLARE
    v_tbl   text;
    v_src   text;
    v_n     int := 0;
BEGIN
    FOR v_tbl IN
        SELECT c.relname
          FROM pg_class c
         WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r'
           AND c.relname <> 'schema_migrations'
           AND NOT EXISTS (SELECT 1 FROM pg_attribute a
                            WHERE a.attrelid = c.oid AND a.attname = 'updated_at'
                              AND a.attnum > 0 AND NOT a.attisdropped)
           AND EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                        WHERE n.nspname = 'public' AND p.prokind = 'f'
                          AND lower(pg_get_functiondef(p.oid))
                              ~ ('update +(only +)?(public\.)?' || c.relname || '[^a-z_]'))
         ORDER BY 1
    LOOP
        -- A column to backfill from is required, and if there is none that is an error rather
        -- than a silent NULL: updated_at means "last written", and the only honest value for a
        -- row that was never written is the moment it began to exist.
        SELECT a.attname INTO v_src
          FROM pg_attribute a
          JOIN pg_class c ON c.oid = a.attrelid
         WHERE c.relname = v_tbl AND a.attnum > 0 AND NOT a.attisdropped
           AND a.attname IN ('created_at','reserved_at','performed_at','last_movement_at')
         ORDER BY array_position(
             ARRAY['created_at','reserved_at','performed_at','last_movement_at'], a.attname)
         LIMIT 1;
        IF v_src IS NULL THEN
            RAISE EXCEPTION '% is rewritten by a live function and has no timestamp to backfill '
                            'updated_at from - add the column by hand with a stated source', v_tbl;
        END IF;

        EXECUTE format('ALTER TABLE public.%I ADD COLUMN updated_at timestamptz', v_tbl);
        EXECUTE format('UPDATE public.%I SET updated_at = COALESCE(%I, now())', v_tbl, v_src);
        EXECUTE format('ALTER TABLE public.%I ALTER COLUMN updated_at SET DEFAULT now()', v_tbl);
        EXECUTE format('ALTER TABLE public.%I ALTER COLUMN updated_at SET NOT NULL', v_tbl);
        EXECUTE format($fmt$COMMENT ON COLUMN public.%I.updated_at IS
            'When this row was last written, maintained by afpc_touch_updated_at (review 6.3). '
            'Added by 0010 because a function UPDATEs these rows and nothing showed it; existing '
            'rows carry their %s as a lower bound, not a measured change time.'$fmt$,
            v_tbl, v_src);
        v_n := v_n + 1;
        RAISE NOTICE '6.3: %.updated_at added - a live function UPDATEs this table and there was '
                     'no column that could show it (backfilled from %)', v_tbl, v_src;
    END LOOP;
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'expected 2 tables that something rewrites but nothing can show (measured: '
                        'addresses, inventory_on_hand), found % - the census of live write paths '
                        'moved underneath this migration', v_n;
    END IF;
END
$$;

-- 3.3 One declaration for one meaning (finding B): the nullable half of the existing population.
--     Backfilled before any trigger exists, so nothing here is stamped by the mechanism being
--     installed rather than repaired.
DO $$
DECLARE
    r   record;
    v_n int := 0;
BEGIN
    FOR r IN SELECT c.relname AS tbl
               FROM pg_class c
               JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'updated_at'
                                  AND a.attnum > 0 AND NOT a.attisdropped
              WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r'
                AND NOT a.attnotnull
              ORDER BY 1
    LOOP
        EXECUTE format('UPDATE public.%I SET updated_at = COALESCE(created_at, now()) '
                       'WHERE updated_at IS NULL', r.tbl);
        EXECUTE format('ALTER TABLE public.%I ALTER COLUMN updated_at SET NOT NULL', r.tbl);
        v_n := v_n + 1;
    END LOOP;
    RAISE NOTICE '6.3B: % tables'' updated_at normalised to NOT NULL, backfilled from created_at '
                 'where it was never set - a watermark predicate can no longer skip rows by '
                 'accident', v_n;
END
$$;

-- ---------------------------------------------------------------------------
-- 4. Install the one mechanism everywhere the column exists
-- ---------------------------------------------------------------------------
-- The same shape as 0009's policy loop: the scope is a question to the catalog, so a table that
-- gains an updated_at in a later migration is covered by the mechanism or named by the
-- scoreboard, and not left to a comment nobody re-reads.
DO $$
DECLARE
    t       text;
    v_n     int := 0;
    v_names text;
    v_null  text;
BEGIN
    FOR t IN SELECT c.relname
               FROM pg_class c
               JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'updated_at'
                                  AND a.attnum > 0 AND NOT a.attisdropped
              WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r'
              ORDER BY 1
    LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS afpc_touch_updated_at ON public.%I', t);
        EXECUTE format($f$CREATE TRIGGER afpc_touch_updated_at
                             BEFORE INSERT OR UPDATE ON public.%I
                             FOR EACH ROW EXECUTE FUNCTION afpc_touch_updated_at()$f$, t);
        v_n := v_n + 1;
    END LOOP;

    IF v_n <> 13 THEN
        RAISE EXCEPTION 'installed the touch trigger on % tables, expected 13 - 6.3 measured 9 '
                        'with the column, 0003 added tenants, and section 3 adds addresses, '
                        'inventory_on_hand and inventory_reservations. A different number means '
                        'the population moved and the register in section 7 would describe the '
                        'wrong schema', v_n;
    END IF;

    -- Nothing may keep a private copy of the rule. This is what makes finding C permanent rather
    -- than a one-time cleanup.
    SELECT string_agg(fn, ', ' ORDER BY fn) INTO v_names FROM (
        SELECT DISTINCT p.proname AS fn
          FROM pg_trigger tg
          JOIN pg_class c ON c.oid = tg.tgrelid
          JOIN pg_proc p  ON p.oid = tg.tgfoid
         WHERE c.relnamespace = 'public'::regnamespace AND NOT tg.tgisinternal
           AND p.proname <> 'afpc_touch_updated_at'
           AND pg_get_functiondef(p.oid) LIKE '%updated_at%'
    ) x;
    IF v_names IS NOT NULL THEN
        RAISE EXCEPTION 'functions other than afpc_touch_updated_at still write updated_at: % - '
                        '6.3C is open again', v_names;
    END IF;

    SELECT string_agg(tbl, ', ' ORDER BY tbl) INTO v_null FROM (
        SELECT DISTINCT c.relname AS tbl
          FROM pg_class c
          JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'updated_at'
                             AND a.attnum > 0 AND NOT a.attisdropped
         WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r' AND NOT a.attnotnull
    ) x;
    IF v_null IS NOT NULL THEN
        RAISE EXCEPTION 'tables whose updated_at is still nullable: % - finding B is open', v_null;
    END IF;

    RAISE NOTICE '6.3: afpc_touch_updated_at installed on % tables - every table with the column, '
                 'no table with a private variant of the rule, no nullable declaration left', v_n;
END
$$;

-- ---------------------------------------------------------------------------
-- 5. Verify by behaving
-- ---------------------------------------------------------------------------
-- pg_trigger can report thirteen correctly named triggers with the correct tgtype while the
-- column still goes stale, because a trigger that fires and assigns the wrong thing is
-- indistinguishable from a working one in the catalog. The pin-then-write pattern below is
-- load-bearing, not decoration: see the header's paragraph on now().
DO $$
DECLARE
    v_ent    bigint;
    v_addr   bigint;
    v_wh     uuid;
    v_it     uuid;
    v_pinned timestamptz := '2000-01-01T00:00:00Z';
    v_birth  timestamptz;
    v_a      timestamptz;
    v_b      timestamptz;
    v_n      int := 0;
    v_distinct int;
    v_msg    text;
BEGIN
    INSERT INTO entities (name, entity_type, status)
        VALUES ('0010 probe', 'customer', 'inactive') RETURNING id INTO v_ent;

    ------------------------------------------------------------------
    -- 5.1 the backfill affordance, asserted first because every probe after it depends on it: a
    --     statement that sets the column deliberately is not overwritten with the clock.
    ------------------------------------------------------------------
    UPDATE entities SET updated_at = v_pinned WHERE id = v_ent;
    SELECT updated_at INTO v_a FROM entities WHERE id = v_ent;
    IF v_a IS DISTINCT FROM v_pinned THEN
        RAISE EXCEPTION '5.1 failed: an UPDATE carrying an explicit historical timestamp became '
                        '% instead of staying % - every bulk repair in this directory would stamp '
                        'the whole table and destroy the ordering the next migration reads',
                        v_a, v_pinned;
    END IF;
    v_n := v_n + 1;
    RAISE NOTICE 'probe A: an explicit timestamp survives the trigger, so history imports and '
                 'backfills are still possible';

    ------------------------------------------------------------------
    -- 5.2 the finding itself: an ordinary UPDATE, which never mentions the column, moves it.
    --     Compared against the pinned value rather than against the previous read, because within
    --     one transaction those are the same instant and the comparison would prove nothing.
    ------------------------------------------------------------------
    UPDATE entities SET status = 'active' WHERE id = v_ent;
    SELECT updated_at INTO v_b FROM entities WHERE id = v_ent;
    IF v_b IS NULL THEN
        RAISE EXCEPTION '5.2 failed: updated_at is NULL after an UPDATE on a table the trigger is '
                        'supposed to cover';
    END IF;
    IF v_b <= v_pinned THEN
        RAISE EXCEPTION '5.2 failed: an ordinary UPDATE left updated_at at % - the column still '
                        'silently goes stale, which is 6.3 itself', v_b;
    END IF;
    v_n := v_n + 1;
    RAISE NOTICE 'probe B: an UPDATE that never mentions updated_at advances it - 6.3''s headline '
                 'defect, closed';

    ------------------------------------------------------------------
    -- 5.3 a write is a write. An UPDATE that changes no values still takes a lock and still
    --     stamps; a trigger that compared whole rows would miss it, and a CDC reader could not
    --     tell the two apart.
    ------------------------------------------------------------------
    UPDATE entities SET updated_at = v_pinned WHERE id = v_ent;
    UPDATE entities SET name = '0010 probe' WHERE id = v_ent;
    SELECT updated_at INTO v_b FROM entities WHERE id = v_ent;
    IF v_b <= v_pinned THEN
        RAISE EXCEPTION '5.3 failed: a no-op UPDATE left updated_at at % - the column tracks '
                        'writes, and this was one', v_b;
    END IF;
    v_n := v_n + 1;
    RAISE NOTICE 'probe C: an UPDATE that changes no data still stamps - the column tracks writes, '
                 'not whether the writer believes the values differ';

    ------------------------------------------------------------------
    -- 5.4 a batch is one instant, which is the property that makes "sync everything after the
    --     last watermark" correct for a multi-row statement instead of leaving rows on either
    --     side of a drifting clock. This is the reason the trigger uses now() rather than
    --     clock_timestamp(), stated as behaviour.
    ------------------------------------------------------------------
    INSERT INTO contacts (first_name, last_name)
        SELECT 'Probe', 'Person' || g FROM generate_series(1, 20) g;
    UPDATE contacts SET updated_at = v_pinned WHERE last_name LIKE 'Person%';
    UPDATE contacts SET title = 'procurement' WHERE last_name LIKE 'Person%';
    SELECT count(DISTINCT updated_at) INTO v_distinct FROM contacts WHERE last_name LIKE 'Person%';
    IF v_distinct <> 1 THEN
        RAISE EXCEPTION '5.4 failed: one UPDATE across twenty pinned rows produced % distinct '
                        'timestamps - a watermark can fall between them and silently lose rows',
                        v_distinct;
    END IF;
    SELECT min(updated_at) INTO v_a FROM contacts WHERE last_name LIKE 'Person%';
    IF v_a <= v_pinned THEN
        RAISE EXCEPTION '5.4 failed: the batch stamp % was never written at all', v_a;
    END IF;
    DELETE FROM contacts WHERE last_name LIKE 'Person%';
    v_n := v_n + 1;
    RAISE NOTICE 'probe D: a 20-row statement moves twenty pinned rows to one timestamp (%) - '
                 'clock_timestamp would have produced twenty and a watermark could fall between',
                 date_trunc('milliseconds', v_a)::text;

    ------------------------------------------------------------------
    -- 5.5 the table the review could not see. The claim is that the two time columns on a stock
    --     row now answer different questions, and the write shape is the one the product uses.
    --     It is written as the two statements execute_inventory_movement runs internally rather
    --     than as a call to that function, for a reason: 4.1 is still open - the function's
    --     signature never mentions a unit of measure while inventory_movements.unit_of_measure is
    --     NOT NULL with no default - so calling it fails on the ledger INSERT before it ever
    --     reaches the stock row. A 0010 probe that depended on 0014 would fail today and read as
    --     a 0010 bug. When 0014 lands, repoint this probe at the function: the assertion is
    --     stronger from the real call site.
    ------------------------------------------------------------------
    INSERT INTO warehouses (warehouse_code, name, warehouse_type)
        VALUES ('AFPC-0010', '0010 probe warehouse', 'PRIMARY') RETURNING warehouse_id INTO v_wh;
    INSERT INTO inventory_items (sku, name, product_type)
        VALUES ('AFPC-0010', '0010 probe item', 'STOCKED') RETURNING item_id INTO v_it;
    INSERT INTO inventory_on_hand (item_id, warehouse_id, quantity_on_hand, quantity_reserved)
        VALUES (v_it, v_wh, 10, 0) RETURNING created_at INTO v_birth;
    IF v_birth IS NULL THEN
        RAISE EXCEPTION '5.5 failed: inventory_on_hand.created_at is NULL on a fresh insert - the '
                        'column section 3.1 added has no working default';
    END IF;

    -- The ADJUSTMENT branch: a plain UPDATE of the stock row.
    UPDATE inventory_on_hand SET updated_at = v_pinned WHERE item_id = v_it AND warehouse_id = v_wh;
    UPDATE inventory_on_hand
       SET quantity_on_hand = quantity_on_hand - 3, last_movement_at = now()
     WHERE item_id = v_it AND warehouse_id = v_wh;
    SELECT updated_at, created_at INTO v_a, v_b
      FROM inventory_on_hand WHERE item_id = v_it AND warehouse_id = v_wh;
    IF v_a <= v_pinned THEN
        RAISE EXCEPTION '5.5 failed: a stock adjustment left updated_at at % - this is the table '
                        'with the most writes in the schema', v_a;
    END IF;
    IF v_b IS DISTINCT FROM v_birth THEN
        RAISE EXCEPTION '5.5 failed: the adjustment moved created_at from % to % - a row''s birth '
                        'is not a function of its latest transaction', v_birth, v_b;
    END IF;

    -- The RECEIPT branch: an upsert whose DO UPDATE half reaches the same row through 0004's
    -- expression identity. An ON CONFLICT DO UPDATE is a different executor path from a plain
    -- UPDATE, and a trigger that only covered one of them would leave stock writes invisible.
    UPDATE inventory_on_hand SET updated_at = v_pinned WHERE item_id = v_it AND warehouse_id = v_wh;
    INSERT INTO inventory_on_hand (item_id, warehouse_id, quantity_on_hand, average_cost,
                                   last_movement_at)
        VALUES (v_it, v_wh, 4, 0, now())
        ON CONFLICT (item_id, warehouse_id,
                     COALESCE(location_id, '00000000-0000-0000-0000-000000000000'::uuid),
                     COALESCE(lot_number, ''), tenant_id)
        DO UPDATE SET quantity_on_hand = inventory_on_hand.quantity_on_hand + 4,
                      last_movement_at = now();
    SELECT updated_at INTO v_a FROM inventory_on_hand
      WHERE item_id = v_it AND warehouse_id = v_wh;
    IF v_a <= v_pinned THEN
        RAISE EXCEPTION '5.5 failed: the upsert path left updated_at at % - stock is written both '
                        'ways, and only one of them is maintained', v_a;
    END IF;
    v_n := v_n + 1;
    RAISE NOTICE 'probe E: a stock row''s adjustment and its upsert both advanced the write stamp '
                 'and left the birth stamp alone - 6.3D, on both paths that touch the row';

    ------------------------------------------------------------------
    -- 5.6 the table the review's arithmetic missed, asserted as behaviour rather than as a column
    --     census: an agent editing a shipping address has to leave something behind.
    ------------------------------------------------------------------
    INSERT INTO addresses (entity_id, address_type, street, city, is_primary)
        VALUES (v_ent, 'billing', '1 Probe Way', 'Testville', false) RETURNING id INTO v_addr;
    UPDATE addresses SET updated_at = v_pinned WHERE id = v_addr;
    UPDATE addresses SET city = 'Renamedville' WHERE id = v_addr;
    SELECT updated_at INTO v_b FROM addresses WHERE id = v_addr;
    IF v_b <= v_pinned THEN
        RAISE EXCEPTION '5.6 failed: an address edit left updated_at at % - update_customer '
                        'rewrites this table and nothing showed it before 0010', v_b;
    END IF;
    v_n := v_n + 1;
    RAISE NOTICE 'probe F: an address edit is now visible in a timestamp - a table found by asking '
                 'the functions which rows they write, not the review';

    ------------------------------------------------------------------
    -- 5.7 the whole population, in three directions. Asserted over every table rather than the
    --     four the probes touched, because what 6.3 describes is invisible to anyone querying a
    --     table nobody probed.
    ------------------------------------------------------------------
    SELECT string_agg(tbl, ', ' ORDER BY tbl) INTO v_msg FROM (
        SELECT c.relname AS tbl
          FROM pg_class c
          JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'updated_at'
                             AND a.attnum > 0 AND NOT a.attisdropped
         WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r'
           AND NOT EXISTS (SELECT 1 FROM pg_trigger tg
                            WHERE tg.tgrelid = c.oid AND tg.tgname = 'afpc_touch_updated_at'
                              AND (tg.tgtype::int & 16) = 16)
    ) x;
    IF v_msg IS NOT NULL THEN
        RAISE EXCEPTION '5.7 failed: tables whose updated_at exists and is unmaintained: % - this '
                        'is the 6.3 shape, still', v_msg;
    END IF;

    SELECT string_agg(tbl, ', ' ORDER BY tbl) INTO v_msg FROM (
        SELECT c.relname AS tbl
          FROM pg_class c
         WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r'
           AND c.relname <> 'schema_migrations'
           AND NOT EXISTS (SELECT 1 FROM pg_attribute a
                            WHERE a.attrelid = c.oid
                              AND a.attname IN ('created_at','reserved_at','performed_at')
                              AND a.attnum > 0 AND NOT a.attisdropped)
    ) x;
    IF v_msg IS NOT NULL THEN
        RAISE EXCEPTION '5.7 failed: tables with no way to tell when a row began: % - every table '
                        'that holds rows has a beginning, or this migration missed one', v_msg;
    END IF;

    -- The third direction is arithmetic, and it is the one a mechanism that only works where it
    -- was tested would fail: the trigger population must be exactly the column population, not a
    -- subset of it and not something wider.
    IF (SELECT count(*) FROM pg_class c JOIN pg_attribute a
                 ON a.attrelid = c.oid AND a.attname = 'updated_at'
                AND a.attnum > 0 AND NOT a.attisdropped
         WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r')
       <> (SELECT count(DISTINCT tg.tgrelid) FROM pg_trigger tg
             JOIN pg_class c ON c.oid = tg.tgrelid
            WHERE c.relnamespace = 'public'::regnamespace
              AND tg.tgname = 'afpc_touch_updated_at') THEN
        RAISE EXCEPTION '5.7 failed: % tables have an updated_at and % are covered by the '
                        'trigger - a mechanism that only reaches the tables someone thought to '
                        'list it is 6.3 with better spelling',
                        (SELECT count(*) FROM pg_class c JOIN pg_attribute a
                          ON a.attrelid = c.oid AND a.attname = 'updated_at'
                         AND a.attnum > 0 AND NOT a.attisdropped
                         WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r'),
                        (SELECT count(DISTINCT tg.tgrelid) FROM pg_trigger tg
                          JOIN pg_class c ON c.oid = tg.tgrelid
                         WHERE c.relnamespace = 'public'::regnamespace
                           AND tg.tgname = 'afpc_touch_updated_at');
    END IF;
    v_n := v_n + 1;
    RAISE NOTICE 'probe G: 13 of 13 tables with the column are maintained, none is nullable, and '
                 'every table that holds rows has a creation timestamp';

    ------------------------------------------------------------------
    -- 5.8 the rule reaches the role that writes the data, not only the owner. 0009's lesson is
    --     that a control which works only for a superuser is not a control, and the same trap
    --     sits here in a milder form: the harness, the tools and blueprint/bot.py all connect as
    --     postgres, so a probe that stayed in the owner's seat would say nothing about afpc_app.
    ------------------------------------------------------------------
    BEGIN
        BEGIN
            EXECUTE 'SET LOCAL ROLE afpc_app';
            PERFORM set_config('app.tenant_id',
                (SELECT tenant_id::text FROM tenants WHERE slug = 'default'), true);
            UPDATE entities SET updated_at = v_pinned WHERE id = v_ent;
            UPDATE entities SET status = 'follow-up' WHERE id = v_ent;
            SELECT updated_at INTO v_b FROM entities WHERE id = v_ent;
            IF v_b <= v_pinned THEN
                RAISE EXCEPTION '5.8 failed: a write by afpc_app left updated_at at % - the '
                                'trigger holds for the owner and not for the agent', v_b;
            END IF;
            EXECUTE 'RESET ROLE';
            v_n := v_n + 1;
            RAISE NOTICE 'probe H: the agent role''s own writes stamp the column. Note that '
                         'afpc_app needs no EXECUTE on the trigger function: a trigger body is run '
                         'by the executor, and its EXECUTE is not privilege-checked against the '
                         'invoker the way 0009''s policy quals are - measured, and the reason '
                         'section 6 revokes without granting';
        EXCEPTION
            WHEN OTHERS THEN
                EXECUTE 'RESET ROLE';
                RAISE;
        END;
    END;

    IF v_n <> 8 THEN
        RAISE EXCEPTION 'expected 8 behavioural verifications, completed %', v_n;
    END IF;

    -- Fixtures out, in the order 0008's RESTRICT edges require.
    DELETE FROM addresses           WHERE id = v_addr;
    DELETE FROM inventory_movements WHERE performed_by = '0010-probe';
    DELETE FROM inventory_on_hand   WHERE warehouse_id = v_wh;
    DELETE FROM locations           WHERE warehouse_id = v_wh;
    DELETE FROM inventory_items     WHERE item_id = v_it;
    DELETE FROM warehouses          WHERE warehouse_id = v_wh;
    DELETE FROM entities            WHERE id = v_ent;
    IF (SELECT count(*) FROM entities WHERE id = v_ent)
       + (SELECT count(*) FROM warehouses WHERE warehouse_code = 'AFPC-0010')
       + (SELECT count(*) FROM contacts WHERE last_name LIKE 'Person%')
       + (SELECT count(*) FROM addresses WHERE id = v_addr) <> 0 THEN
        RAISE EXCEPTION '0010 left probe fixtures behind';
    END IF;
    RAISE NOTICE '6.3: % behavioural checks passed, fixtures erased', v_n;
END
$$;

-- ---------------------------------------------------------------------------
-- 6. Privileges, because 0009 made that every migration's job
-- ---------------------------------------------------------------------------
-- Revoked from PUBLIC per 0009's obligation list, and deliberately NOT granted to afpc_app, which
-- is a different decision than 0009 made about its own functions and therefore needs a reason: a
-- trigger body is executed on behalf of whatever role ran the statement, and the function's own
-- EXECUTE is not part of that check. Measured on a clone - afpc_app updated three rows through a
-- BEFORE UPDATE trigger whose function it could not execute, and the same UPDATE succeeded before
-- and after the grant, so the grant buys nothing. Policy quals behave the opposite way (0009's
-- finding B, where the missing grant produced "permission denied for function"), and the
-- difference is worth remembering: the question is who the server counts as the caller, and for a
-- trigger it is not the caller. ALTER DEFAULT PRIVILEGES is not repeated here - 0009 established
-- it cannot close a function forward, and B22 is the mechanism that keeps this from recurring.
REVOKE EXECUTE ON FUNCTION afpc_touch_updated_at() FROM PUBLIC;

DO $$
DECLARE
    v text;
BEGIN
    -- The same question verify.sh B22 asks, with the same three declared exemptions - the
    -- context helpers 0009 kept PUBLIC-executable because a column default or a policy qual
    -- calls them during an ordinary SELECT. They are exempt by argument, recorded there, and
    -- repeated here because an assertion that re-derives a decision it should inherit is how two
    -- places start disagreeing.
    SELECT string_agg(proname, ', ' ORDER BY proname) INTO v FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f'
       AND p.proname NOT IN ('afpc_current_tenant', 'afpc_policy_tenant', 'afpc_uuid_v7')
       AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
       AND (p.proacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) x
                                         WHERE x.grantee = 0 AND x.privilege_type = 'EXECUTE'));
    IF v IS NOT NULL THEN
        RAISE EXCEPTION 'functions still executable by every role in the cluster: % - 0009''s '
                        'obligation is open again, and B22 will report it too', v;
    END IF;
    RAISE NOTICE 'privileges: afpc_touch_updated_at is closed to PUBLIC, and the sweep 0009 did '
                 'is still clean (% context helpers stay open by 0009''s argument, not by '
                 'oversight)', 3;
END
$$;

-- ---------------------------------------------------------------------------
-- 7. The state an agent should be able to ask about
-- ---------------------------------------------------------------------------
-- 6.3 is a question about what a column *means*, and the catalog answers it only in pieces: a
-- column here, a trigger there, no way to ask "would an incremental-sync query trust this table".
-- The review's table is a static claim about a dump; this is the same question, running.
CREATE OR REPLACE VIEW vw_timestamp_status AS
WITH writers AS (
    -- Which tables the schema itself says can change. Derived from pg_proc, not from a list, so
    -- a migration that adds a write path changes the register without anyone editing it.
    SELECT c.oid AS rel, p.proname
      FROM pg_class c
      JOIN pg_proc p ON p.pronamespace = 'public'::regnamespace AND p.prokind = 'f'
     WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r'
       AND lower(pg_get_functiondef(p.oid))
           ~ ('update +(only +)?(public\.)?' || c.relname || '[^a-z_]')
)
SELECT c.relname AS table_name,
    EXISTS (SELECT 1 FROM pg_attribute a
             WHERE a.attrelid = c.oid AND a.attname = 'created_at'
               AND a.attnum > 0 AND NOT a.attisdropped)              AS has_created_at,
    EXISTS (SELECT 1 FROM pg_attribute a
             WHERE a.attrelid = c.oid AND a.attname = 'updated_at'
               AND a.attnum > 0 AND NOT a.attisdropped)              AS has_updated_at,
    (SELECT a.attnotnull FROM pg_attribute a
      WHERE a.attrelid = c.oid AND a.attname = 'updated_at'
        AND a.attnum > 0 AND NOT a.attisdropped)                     AS updated_at_not_null,
    (SELECT string_agg(DISTINCT w.proname, ', ' ORDER BY w.proname)
       FROM writers w WHERE w.rel = c.oid)                           AS rewritten_by,
    (SELECT tg.tgname FROM pg_trigger tg
      WHERE tg.tgrelid = c.oid AND NOT tg.tgisinternal
        AND pg_get_functiondef(tg.tgfoid) LIKE '%updated_at%'
      ORDER BY tg.tgname LIMIT 1)                                    AS maintained_by,
    COALESCE((SELECT (tg.tgtype::int & 16) = 16 FROM pg_trigger tg
               WHERE tg.tgrelid = c.oid
                 AND tg.tgname = 'afpc_touch_updated_at'), false)    AS moves_on_update,
    COALESCE((SELECT (tg.tgtype::int & 4) = 4 FROM pg_trigger tg
               WHERE tg.tgrelid = c.oid
                 AND tg.tgname = 'afpc_touch_updated_at'), false)    AS fills_on_insert,
    CASE
        WHEN c.relname = 'schema_migrations'
            THEN 'build bookkeeping - no timestamp semantics'
        WHEN EXISTS (SELECT 1 FROM pg_attribute a
                      WHERE a.attrelid = c.oid AND a.attname = 'updated_at'
                        AND a.attnum > 0 AND NOT a.attisdropped)
             AND COALESCE((SELECT (tg.tgtype::int & 16) = 16 FROM pg_trigger tg
                            WHERE tg.tgrelid = c.oid
                              AND tg.tgname = 'afpc_touch_updated_at'), false)
            THEN 'maintained'
        WHEN EXISTS (SELECT 1 FROM pg_attribute a
                      WHERE a.attrelid = c.oid AND a.attname = 'updated_at')
            THEN 'NOT MAINTAINED - the column exists and goes stale: this is 6.3'
        WHEN EXISTS (SELECT 1 FROM writers w WHERE w.rel = c.oid)
            THEN 'NOT MAINTAINED - a function rewrites these rows and there is no column'
        WHEN c.relname = 'inventory_movements'
            THEN 'append-only by design - performed_at is both the event time and the write time'
        ELSE 'no updated_at by decision - nothing in the schema rewrites these rows'
    END                                                            AS verdict,
    (CASE WHEN EXISTS (SELECT 1 FROM pg_attribute a
                        WHERE a.attrelid = c.oid AND a.attname = 'updated_at'
                          AND a.attnum > 0 AND NOT a.attisdropped)
                AND NOT COALESCE((SELECT (tg.tgtype::int & 16) = 16 FROM pg_trigger tg
                                  WHERE tg.tgrelid = c.oid
                                    AND tg.tgname = 'afpc_touch_updated_at'), false)
              THEN true
              WHEN EXISTS (SELECT 1 FROM writers w WHERE w.rel = c.oid)
                AND NOT EXISTS (SELECT 1 FROM pg_attribute a
                                 WHERE a.attrelid = c.oid AND a.attname = 'updated_at')
              THEN true
              ELSE false END)                                        AS needs_attention
FROM pg_class c
WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r'
ORDER BY needs_attention DESC, c.relname;

COMMENT ON VIEW vw_timestamp_status IS
    'One row per table: whether it has a creation timestamp, whether it has an updated_at, whether '
    'that column is NOT NULL, which functions rewrite the table, which trigger maintains the '
    'column, and whether that trigger fires on UPDATE and on INSERT - with needs_attention set for '
    'the two ways the answer can be no. The verdict column is the question 6.3 was really asking '
    '(can I write an incremental-sync query against this table), because a stale column is worse '
    'than an absent one: it is believed. rewritten_by comes from pg_proc rather than from a list, '
    'which is how addresses became a finding here and stayed out of the review. LIMITATION: a '
    'dynamic EXECUTE format(''UPDATE %I''...) would not appear in rewritten_by. None exists in '
    'public; 0009''s own dynamic SQL is DDL, and probe G checks the population against the '
    'catalog instead of trusting this view alone.';

-- 0009's other obligation, and this view is subject to it because it is new: CREATE OR REPLACE
-- VIEW discards the reloptions, so security_invoker is applied after the definition, and B21
-- counts this view with the others.
ALTER VIEW vw_timestamp_status SET (security_invoker = true);
GRANT SELECT ON vw_timestamp_status TO afpc_auditor, afpc_readonly;

DO $$
DECLARE
    v text;
BEGIN
    -- The register is only worth reading if its verdict agrees with the catalog it came from, in
    -- both directions: nothing "maintained" that a trigger does not maintain, and nothing
    -- "append-only by decision" that a function in fact rewrites.
    SELECT string_agg(table_name, ', ' ORDER BY table_name) INTO v
      FROM vw_timestamp_status
     WHERE verdict = 'maintained' AND NOT moves_on_update;
    IF v IS NOT NULL THEN
        RAISE EXCEPTION 'the register calls % maintained while moves_on_update is false', v;
    END IF;

    SELECT string_agg(table_name, ', ' ORDER BY table_name) INTO v
      FROM vw_timestamp_status
     WHERE verdict LIKE 'no updated_at by decision%' AND rewritten_by IS NOT NULL;
    IF v IS NOT NULL THEN
        RAISE EXCEPTION 'the register declares % append-only while a function UPDATEs them - the '
                        'verdict disagrees with its own evidence', v;
    END IF;

    SELECT count(*) INTO v FROM vw_timestamp_status WHERE needs_attention;
    IF v::int <> 0 THEN
        RAISE EXCEPTION '% tables need attention according to vw_timestamp_status', v;
    END IF;

    RAISE NOTICE 'vw_timestamp_status: % maintained, % declared immutable, % bookkeeping, % '
                 'needing attention',
        (SELECT count(*) FROM vw_timestamp_status WHERE verdict = 'maintained'),
        (SELECT count(*) FROM vw_timestamp_status
          WHERE verdict LIKE '%by design%' OR verdict LIKE '%by decision%'),
        (SELECT count(*) FROM vw_timestamp_status WHERE verdict LIKE 'build bookkeeping%'),
        (SELECT count(*) FROM vw_timestamp_status WHERE needs_attention);
END
$$;
