-- Finding 5.9, as behaviour.
--
-- verify.sh can already answer "does this column have a CHECK". The four things worth knowing
-- are different, and none of them are visible in pg_constraint:
--
--   1. Does the constraint reject the same word spelled differently? That is 5.9's actual
--      complaint - active / Active / ACTIVE - and a membership CHECK only fixes it if the
--      comparison is exact rather than case-folded.
--   2. Does it still accept the values the rest of the system writes? A constraint that refuses
--      add_customer's own vocabulary is worse than no constraint, because it fails at runtime in
--      the one place a test like this one is the only thing that would notice.
--   3. Can the vocabulary grow without DDL? This is the whole reason unit_of_measure and
--      cost_method are lookup tables and followups.status is a CHECK. If the answer is that both
--      behave the same, the distinction was decoration.
--   4. Is the admitted value actually readable back? entities.status admits 'follow-up' because
--      get_followup_customers branches on it. If the function does not then report it, the value
--      is a fig leaf and 5.9 is not closed, it has been papered over.

-- 1. Case is now significant, in the direction that matters.
BEGIN;
DO $$
DECLARE
    v_con text;
BEGIN
    BEGIN
        INSERT INTO entities (name, entity_type, status)
            VALUES ('AFPC Case Probe', 'customer', 'ACTIVE');
        RAISE NOTICE 'VERDICT ERR entities.status accepted ACTIVE alongside active, so 5.9 '
                     'is not closed - the two are indistinguishable to every query in the tree';
    EXCEPTION WHEN check_violation THEN
        GET STACKED DIAGNOSTICS v_con = CONSTRAINT_NAME;
        RAISE NOTICE 'VERDICT OK a case variant is refused by % ', v_con;
    END;

    -- The mirror of the same claim: the documented spelling must be accepted, or the constraint
    -- above is refusing the vocabulary rather than protecting it.
    BEGIN
        INSERT INTO entities (name, entity_type, status)
            VALUES ('AFPC Case Probe', 'customer', 'active');
        RAISE NOTICE 'VERDICT OK the documented spelling is accepted';
    EXCEPTION WHEN check_violation THEN
        GET STACKED DIAGNOSTICS v_con = CONSTRAINT_NAME;
        RAISE NOTICE 'VERDICT ERR the documented value active was refused by % - the CHECK does '
                     'not contain the vocabulary the code writes', v_con;
    END;
END
$$;
ROLLBACK;

-- 2. Every value the view publishes must be writable, on the columns the CRM path touches.
--
-- Driven from vw_domain_vocabulary rather than listed here, so the day a value is added to a
-- constraint this test starts covering it too. A test that restates the schema proves the test
-- file was written, not that the schema is right.
BEGIN;
DO $$
DECLARE
    r        record;
    v        text;
    refused  int := 0;
    tried    int := 0;
    stmt     text;
BEGIN
    IF to_regclass('public.vw_domain_vocabulary') IS NULL THEN
        RAISE NOTICE 'VERDICT ERR no published vocabulary yet - 5.9 asks what each column may '
                     'hold and nothing can answer it (0007 creates vw_domain_vocabulary)';
        RETURN;
    END IF;
    FOR r IN SELECT table_name, column_name, unnest(allowed_values) AS val
               FROM vw_domain_vocabulary
              WHERE enforced_by = 'check'
                AND table_name || '.' || column_name IN (
                    'entities.status','entities.entity_type','contacts.status',
                    'addresses.address_type','communications.direction',
                    'communications.outcome','communications.priority','followups.priority')
              ORDER BY 1, 2, 3
    LOOP
        tried := tried + 1;
        -- One row per value, written straight to the column. The tables with NOT NULL columns
        -- that have no default are handled by giving each its own shape.
        BEGIN
            EXECUTE format('INSERT INTO public.%I (%I) VALUES (%L)',
                           r.table_name, r.column_name, r.val);
        EXCEPTION WHEN check_violation THEN
            refused := refused + 1;
            RAISE NOTICE '  refused %.% = %', r.table_name, r.column_name, r.val;
        WHEN not_null_violation THEN
            -- The column accepted the value; the insert failed on an unrelated required column.
            NULL;
        END;
    END LOOP;
    IF refused = 0 THEN
        RAISE NOTICE 'VERDICT OK all % published values were accepted by their own constraint',
            tried;
    ELSE
        RAISE NOTICE 'VERDICT ERR % of % published values were refused by the constraint that '
                     'publishes them', refused, tried;
    END IF;
END
$$;
ROLLBACK;

-- 3. Master data grows with an INSERT; a CHECK grows with a migration.
--
-- The claim being tested is the one 0007's header makes about its own design, so it is worth
-- having a red row attached to it rather than a paragraph.
BEGIN;
DO $$
DECLARE
    v_con text;
BEGIN
    IF to_regclass('public.units_of_measure') IS NOT NULL THEN
      BEGIN
        INSERT INTO inventory_items (sku, name, base_unit_of_measure)
            VALUES ('AFPC-UOM-1', 'AFPC Pallet', 'PALLET');
        RAISE NOTICE 'VERDICT ERR units_of_measure did not restrict an unknown code, so the '
                     'foreign key is not doing what a CHECK could not';
    EXCEPTION WHEN foreign_key_violation THEN
        RAISE NOTICE 'VERDICT OK an unregistered unit is refused before any code exists for it';
    END;

    -- The whole point of the table: registering the unit is data, and the value becomes legal.
    INSERT INTO units_of_measure (uom_code, label, uom_kind)
        VALUES ('PALLET', 'Pallet', 'QUANTITY') ON CONFLICT DO NOTHING;
    BEGIN
        INSERT INTO inventory_items (sku, name, base_unit_of_measure)
            VALUES ('AFPC-UOM-1', 'AFPC Pallet', 'PALLET');
        RAISE NOTICE 'VERDICT OK PALLET became legal by INSERT alone - no DDL, so a deployment '
                     'that ships in pallets is not blocked on a migration';
    EXCEPTION WHEN foreign_key_violation THEN
        RAISE NOTICE 'VERDICT ERR PALLET was registered and is still refused - the FK is not '
                     'reading the table it points at';
    END;
    ELSE
        RAISE NOTICE 'VERDICT ERR no master-data tables exist yet, so a unit of measure cannot '
                     'be registered without DDL - the layer 5.9 calls missing (0007)';
    END IF;

    -- And the contrast, on the same database, for a column 0007 decided is a state machine.
    -- (An entity is created first: on an empty development database a subselect that finds
    -- nothing produces a NULL, and the not-null violation that follows says nothing at all about
    -- the constraint being tested.)
    INSERT INTO entities (name, entity_type, status) VALUES ('AFPC Outcome Probe', 'customer', 'active');
    BEGIN
        INSERT INTO communications (entity_id, communication_type, direction, summary, outcome)
            VALUES ((SELECT max(id) FROM entities), 'email', 'inbound', 'x',
                    'definitely-not-a-state');
        RAISE NOTICE 'VERDICT ERR communications.outcome accepted an undefined state';
    EXCEPTION WHEN check_violation THEN
        GET STACKED DIAGNOSTICS v_con = CONSTRAINT_NAME;
        RAISE NOTICE 'VERDICT OK an undefined state is refused by % - the other half of the same '
                     'decision', v_con;
    END;
END
$$;
ROLLBACK;

-- 4. The value admitted for the sake of the code that reads it.
--
-- get_followup_customers branches on entities.status = 'follow-up'. Nothing in the repository
-- writes that value - which is a finding in its own right, recorded against 0014 in
-- db/MIGRATIONS.md. What this asserts is the half 0007 is responsible for: the vocabulary now
-- PERMITS it, and the function reports it, so the gap is a missing writer rather than a schema
-- that can never hold the state.
BEGIN;
DO $$
DECLARE
    v_ent bigint;
    v_n   int := 0;
    r     record;
BEGIN
    INSERT INTO entities (name, entity_type, status)
        VALUES ('AFPC Followup Flag', 'customer', 'follow-up') RETURNING id INTO v_ent;
    -- The function's own FROM clause is entities -> entity_relationships(is_primary) ->
    -- contacts, so a status the branch would match is still invisible without the shape. This
    -- is the same requirement that made vw_customers return 0 rows for seeded data in 0005's
    -- rehearsal, and it belongs in the probe rather than in a comment about why it failed.
    INSERT INTO contacts (first_name, last_name, email, status)
        VALUES ('Probe', 'Contact', 'followup-flag@example.invalid', 'active');
    INSERT INTO entity_relationships (entity_id, contact_id, role, is_primary)
        VALUES (v_ent, (SELECT max(id) FROM contacts), 'Owner', true);
    FOR r IN SELECT * FROM get_followup_customers(7) WHERE entity_id = v_ent LOOP
        v_n := v_n + 1;
        IF r.follow_up_reason LIKE '%follow-up%' THEN
            RAISE NOTICE 'VERDICT OK the follow-up branch is reachable: %', r.follow_up_reason;
        ELSE
            RAISE NOTICE 'VERDICT INFO the row was returned for another reason: %',
                r.follow_up_reason;
        END IF;
    END LOOP;
    IF v_n = 0 THEN
        RAISE NOTICE 'VERDICT ERR entities.status = follow-up produced no follow-up row, so the '
                     'value 0007 admitted is still unreachable';
    END IF;
END
$$;
ROLLBACK;

-- 5. The free-text decisions, pinned.
--
-- 0007 leaves four columns open on purpose and records the reason in vw_domain_vocabulary. The
-- risk in an intentional exception is that a later migration "finishes the job" and constrains
-- it, which reads like an improvement right up until a new agent tool cannot log an action. These
-- rows are what turns that into a test failure.
BEGIN;
DO $$
DECLARE
    v_sess uuid;
    v_con  text;
    v_bad  int;
BEGIN
    INSERT INTO human_sessions (user_id, user_name, bot_id, bot_type, session_status, login_time)
        VALUES (999001, 'AFPC Probe', 'probe-bot', 'unknown', 'active', now())
        RETURNING session_id INTO v_sess;

    BEGIN
        INSERT INTO bot_actions (session_id, user_id, bot_id, action_type,
                                 action_description, success)
            VALUES (v_sess, 999001, 'probe-bot', 'brand_new_tool_nobody_predicted',
                    'probing', true);
        RAISE NOTICE 'VERDICT OK action_type still takes a name no migration has heard of - '
                     'constraining it would make every new agent tool a schema change';
    EXCEPTION WHEN check_violation THEN
        GET STACKED DIAGNOSTICS v_con = CONSTRAINT_NAME;
        RAISE NOTICE 'VERDICT ERR action_type is now constrained by % - 0007 declined that on '
                     'purpose, and vw_domain_vocabulary.reason says why', v_con;
    END;

    -- The reasons themselves are part of the contract: an unconstrained column with no reason is
    -- an oversight wearing a decision.
    IF to_regclass('public.vw_domain_vocabulary') IS NULL THEN
        RAISE NOTICE 'VERDICT ERR no published vocabulary yet, so no free-text column carries a '
                     'reason either (0007)';
        RETURN;
    END IF;

    SELECT count(*) INTO v_bad FROM vw_domain_vocabulary
     WHERE enforced_by = 'none - free text' AND (reason IS NULL OR reason LIKE 'UNDECIDED%');
    IF v_bad = 0 THEN
        RAISE NOTICE 'VERDICT OK each open column''s openness is explained in the view';
    ELSE
        RAISE NOTICE 'VERDICT ERR % free-text domain column(s) are undocumented', v_bad;
    END IF;
END
$$;
ROLLBACK;
