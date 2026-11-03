-- Finding 6.5, as behaviour: "money, units, and currency".
--
-- The review's evidence for 6.5 is a column census - currency_code char(3) with no table and no
-- FK behind it, no rate history anywhere, and 9 of 15 numeric columns sharing one precision
-- between money and physical quantity. All three sentences are accurate, and a census cannot say
-- what any of them *do*. What they do is the finding: the movement door multiplies two of those
-- columns and writes the product into a third (block B); an item priced in one currency gets a
-- balance labelled in another (block C); two currencies can be averaged into one number that is
-- neither (block C's second half); a rate history does not exist, so one rate is implied forever
-- (block D); and the published vocabulary register cannot see the columns at all, because its
-- candidate rule looks only at text and varchar (block E).
--
-- Version-aware throughout, the way 4_3 and 4_6 became so: on a pre-0018 database the door and the
-- catalog behave the way the measurements say they do and the phrases below print ERR; after 0018
-- the same calls print OK. Where a block has to tell "the mechanism is absent" from "the mechanism
-- is present and broken" it checks for the object first with to_regclass - a test that reports a
-- verdict from a branch it could not reach is the harness crediting itself for nothing, which is
-- the point db/MIGRATIONS.md's marker table makes about greps.
--
-- Blocks A and C need that distinction; B and D do not, because a door call and a missing table
-- answer the same way on either side. Every write is inside a transaction that is rolled back:
-- this database is persistent and this finding is about money.

-- A. The currency vocabulary. 6.5 says the column has no table; the consequence is that the only
--    thing stopping a typo is the width of the column, which stops nothing that is three characters
--    long. Written as a membership test rather than a list of bad codes, because "does the database
--    know what EUR is" has one honest answer and it is a foreign key.
BEGIN;
DO $$
DECLARE
    v_wh     uuid;
    v_item   uuid;
    v_master boolean;
    v_rows   bigint;
BEGIN
    SELECT to_regclass('public.currencies') IS NOT NULL INTO v_master;
    INSERT INTO warehouses (warehouse_code, name) VALUES ('P65-A','6_5 probe')
     RETURNING warehouse_id INTO v_wh;
    INSERT INTO inventory_items (sku, name, base_unit_of_measure)
         VALUES ('P65-A','6_5 probe item','EACH') RETURNING item_id INTO v_item;

    IF NOT v_master THEN
        -- No master to ask. Reproduce the consequence instead of asserting it from the catalog, so
        -- that the pre-fix branch shows the finding rather than describing it.
        INSERT INTO inventory_movements (movement_type, item_id, to_warehouse_id, quantity,
                                        unit_of_measure, performed_by, currency_code, reason_code)
             VALUES ('RECEIPT', v_item, v_wh, 1, 'EACH', '6_5 probe', 'XYZ', 'P65-A');
        SELECT count(*) INTO v_rows FROM inventory_movements
         WHERE item_id = v_item AND currency_code = 'XYZ';
        RAISE NOTICE 'VERDICT ERR no currency master exists, so an invented code is a row like any '
                     'other - % of them landed', v_rows;
    ELSE
        BEGIN
            INSERT INTO inventory_movements (movement_type, item_id, to_warehouse_id, quantity,
                                            unit_of_measure, performed_by, currency_code, reason_code)
                 VALUES ('RECEIPT', v_item, v_wh, 1, 'EACH', '6_5 probe', 'XYZ', 'P65-A');
            RAISE NOTICE 'VERDICT ERR a code the currency master does not have was accepted, so the '
                         'foreign key is declared and not enforced';
        EXCEPTION WHEN foreign_key_violation THEN
            RAISE NOTICE 'VERDICT OK the currency master refuses a code it does not have (23503) - '
                         '6.5''s missing edge, and membership rather than column width is now the '
                         'wall';
        END;
    END IF;
END
$$;
ROLLBACK;

-- B. Measurement 1: the precision finding is not cosmetic. The door computes quantity * unit_cost
--    into total_cost; both factors are numeric(12,4), so the product can need 16 integer digits
--    while the column is sized for 11. Asked of the door, not of the column, because a typmod that
--    reads 24,4 and a receipt that lands are different claims and only the second one is evidence.
BEGIN;
DO $$
DECLARE
    v_wh   uuid;
    v_item uuid;
    v_num  numeric;
BEGIN
    INSERT INTO warehouses (warehouse_code, name) VALUES ('P65-B','6_5 probe')
     RETURNING warehouse_id INTO v_wh;
    INSERT INTO inventory_items (sku, name, base_unit_of_measure)
         VALUES ('P65-B','6_5 probe item','EACH') RETURNING item_id INTO v_item;
    BEGIN
        PERFORM execute_inventory_movement('RECEIPT', v_item, NULL::uuid, v_wh,
                 1000000::numeric, 1000000::numeric, '6_5 probe', 'PO', NULL::uuid, 'P65-B');
        SELECT total_cost INTO v_num FROM inventory_movements
         WHERE item_id = v_item AND reason_code = 'P65-B';
        RAISE NOTICE 'VERDICT OK a million units at a million each is one movement of % - money and '
                     'quantity no longer share a ceiling', v_num;
    EXCEPTION WHEN numeric_value_out_of_range THEN
        RAISE NOTICE 'VERDICT ERR money and quantity share one precision and the door multiplies '
                     'them: the receipt is refused by the column''s ceiling, not by the business';
    END;
END
$$;
ROLLBACK;

-- C. Measurements 2 and 3. The currency of a balance had no writer at all, so an item that said one
--    thing and a column default that said another were both stored and neither was wrong; and the
--    one path that can still reach that shape after 0018 - an item master moved under an existing
--    balance - has no CHECK that can state it, so 0018 §3b refuses it at the door instead of
--    averaging euros and dollars into a single number. Both halves are asked of the door.
BEGIN;
DO $$
DECLARE
    v_wh     uuid;
    v_item   uuid;
    v_avg    numeric;
    v_bal    text;
    v_mv     text;
    v_master boolean;
BEGIN
    SELECT to_regclass('public.currencies') IS NOT NULL INTO v_master;
    INSERT INTO warehouses (warehouse_code, name) VALUES ('P65-C','6_5 probe')
     RETURNING warehouse_id INTO v_wh;
    -- An item that declares a currency. Legal on either side: before 0018 there is no master to
    -- refuse it, after 0018 JPY is one of the rows the seed installs.
    INSERT INTO inventory_items (sku, name, base_unit_of_measure, currency_code)
         VALUES ('P65-C','6_5 yen item','EACH','JPY') RETURNING item_id INTO v_item;
    PERFORM execute_inventory_movement('RECEIPT', v_item, NULL::uuid, v_wh,
             10::numeric, 100::numeric, '6_5 probe', 'PO', NULL::uuid, 'P65-C');
    SELECT cost_currency::text, average_cost INTO v_bal, v_avg FROM inventory_on_hand
     WHERE item_id = v_item AND warehouse_id = v_wh;
    SELECT currency_code::text INTO v_mv FROM inventory_movements
     WHERE item_id = v_item AND reason_code = 'P65-C';

    IF v_bal <> 'JPY' THEN
        -- Measurement 3, reproducing itself: the item said JPY, the door wrote the column default.
        RAISE NOTICE 'VERDICT ERR the balance a door created for a JPY item is kept in % and its '
                     'movement says % - average_cost means whatever the label happens to say, and '
                     'no function body connects it to the item', v_bal, v_mv;
    ELSIF NOT v_master THEN
        RAISE NOTICE 'VERDICT ERR the balance reads JPY without a currency master behind it, which '
                     'is not an answer this file knows how to trust';
    ELSE
        -- The drift case, produced the only way it can now be produced.
        UPDATE inventory_items SET currency_code = 'CHF' WHERE item_id = v_item;
        BEGIN
            PERFORM execute_inventory_movement('RECEIPT', v_item, NULL::uuid, v_wh,
                     10::numeric, 100::numeric, '6_5 probe', 'PO', NULL::uuid, 'P65-C2');
            SELECT average_cost INTO v_avg FROM inventory_on_hand
             WHERE item_id = v_item AND warehouse_id = v_wh;
            RAISE NOTICE 'VERDICT ERR a movement whose currency disagrees with the balance it '
                         'averaged into produced % - two currencies in one number', v_avg;
        EXCEPTION WHEN check_violation THEN
            IF (SELECT count(*) FROM inventory_movements
                 WHERE item_id = v_item AND reason_code = 'P65-C2') <> 0 THEN
                RAISE NOTICE 'VERDICT ERR the refusal came after the ledger row, so a rejected '
                             'movement is still in the history 0015 decided a refusal must not leave';
            ELSE
                RAISE NOTICE 'VERDICT OK the door refuses to blend two currencies into one average, '
                             'before it writes, which is the case no CHECK can state';
            END IF;
        END;
    END IF;
END
$$;
ROLLBACK;

-- D. The rate history. Absent before 0018; after it, the question worth asking is not whether a
--    table exists but whether in force, expired, and never quoted come back as three different
--    answers, because a LEFT JOIN that returns NULL for two of them is how a rate table stops being
--    trusted by the person reading it.
BEGIN;
DO $$
DECLARE
    v_rate uuid;
BEGIN
    IF to_regclass('public.currency_rates') IS NULL THEN
        RAISE NOTICE 'VERDICT ERR there is no rate history anywhere, so a cost expressed in one '
                     'currency carries one implied rate forever';
    ELSE
        INSERT INTO currency_rates (from_currency, to_currency, rate, valid_from, valid_to, source)
             VALUES ('JPY','USD', 0.0065, now() - interval '2 days',
                     now() - interval '1 day', '6_5 probe')
         RETURNING rate_id INTO v_rate;
        IF (SELECT count(*) FROM vw_currency_rates
             WHERE from_currency = 'JPY' AND to_currency = 'USD'
               AND NOT in_force AND rows_for_pair = 1) <> 1 THEN
            RAISE NOTICE 'VERDICT ERR an expired rate is not reported as expired - %',
                (SELECT coalesce(string_agg(in_force::text || '/' || rows_for_pair::text, ','),
                        'no rows') FROM vw_currency_rates
                  WHERE from_currency = 'JPY' AND to_currency = 'USD');
        ELSIF EXISTS (SELECT 1 FROM vw_currency_rates
                       WHERE from_currency = 'GBP' AND to_currency = 'AUD') THEN
            RAISE NOTICE 'VERDICT ERR a pair nobody ever quoted appears in the rate view, so '
                         'expired and never-existed have become the same answer';
        ELSIF EXISTS (SELECT 1 FROM currency_rates WHERE from_currency = to_currency) THEN
            RAISE NOTICE 'VERDICT ERR the history stores identity rates, which arithmetic already '
                         'knows and a row can contradict';
        ELSE
            RAISE NOTICE 'VERDICT OK the rate history answers in force, expired, and never quoted '
                         'as three different things, and translates nothing yet';
        END IF;
    END IF;
END
$$;
ROLLBACK;

-- E. Measurement 5: the register's silence. vw_domain_vocabulary is what AGENTS.md calls the answer
--    to "what does this column accept", and it asked that question only of text and varchar
--    columns - so a char(3) code with no table behind it was invisible to the mechanism built to
--    report exactly that. The candidate count is taken from the catalog rather than from
--    information_schema.columns, because that view lists a view's columns too and the finding is
--    about base tables; vw_domain_vocabulary is built the same way for the same reason. One more
--    exclusion than the register's own: a column that is *referenced* by a foreign key is a value
--    space rather than a use of one, which is what keeps currencies.currency_code itself out of
--    the count - §5 exempts the code tables for that reason and a census that forgot it would
--    report the register as short by a row it is correct to omit.
BEGIN;
DO $$
DECLARE
    v_seen bigint;
    v_all  bigint;
BEGIN
    SELECT count(*) INTO v_all FROM pg_attribute a
      JOIN pg_class c ON c.oid = a.attrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relkind = 'r' AND a.attnum > 0 AND NOT a.attisdropped
       AND a.atttypid = 'bpchar'::regtype
       AND a.attname IN ('currency_code','cost_currency')
       AND NOT EXISTS (SELECT 1 FROM pg_constraint fk
                        WHERE fk.contype = 'f' AND fk.confrelid = c.oid
                          AND fk.confkey[1] = a.attnum);
    SELECT count(DISTINCT (table_name, column_name)) INTO v_seen FROM vw_domain_vocabulary
     WHERE column_name IN ('currency_code','cost_currency');
    IF v_seen < v_all THEN
        RAISE NOTICE 'VERDICT ERR the vocabulary register answers for % of the % currency code '
                     'columns - a char(3) is outside the candidate set, so a missing constraint on '
                     'it is invisible to the view whose job is to report missing constraints',
            v_seen, v_all;
    ELSIF EXISTS (SELECT 1 FROM vw_domain_vocabulary
                   WHERE column_name IN ('currency_code','cost_currency')
                     AND enforced_by = 'none - free text') THEN
        RAISE NOTICE 'VERDICT ERR the register now lists the currency columns and has no answer for '
                     'them, which is B2''s finding wearing a new hat';
    ELSE
        RAISE NOTICE 'VERDICT OK the register says what the currency columns accept (% of %), and '
                     'the answer is a lookup table rather than a CHECK list', v_seen, v_all;
    END IF;
END
$$;
ROLLBACK;
