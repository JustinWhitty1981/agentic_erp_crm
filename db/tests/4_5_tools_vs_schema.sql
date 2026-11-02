-- Finding 4.5: tools and schema disagree about where objects live.
-- Every one of the 9 blueprint tools qualifies its SQL to a schema that this
-- migration set does not create. This case proves both halves of the fix: the
-- qualified form must fail, and the unqualified form must work.

-- 5a. The statement as blueprint/tools/customer_lookup.py issues it.
DO $$
BEGIN
    EXECUTE 'SELECT count(*) FROM agent_first_erp_crm.vw_customers LIMIT 1';
    RAISE NOTICE 'VERDICT OK qualified view resolved';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'VERDICT ERR % | qualified name cannot resolve, which is finding 3.1', SQLSTATE;
END
$$;

-- 5b. Positive control on the port. The canonical bodies of update_customer were
-- rewritten from qualified to unqualified in 0001; if the strip worked, this writes
-- to the tables in public that the rest of the model constrains.
BEGIN;
DO $$
DECLARE
    v_ent int;
    v_con int;
    r record;
BEGIN
    INSERT INTO entities (name, entity_type) VALUES ('Ada Lovelace', 'customer') RETURNING id INTO v_ent;
    INSERT INTO contacts (first_name, last_name, email)
        VALUES ('Ada', 'Lovelace', 'ada-update@example.invalid') RETURNING id INTO v_con;
    INSERT INTO entity_relationships (entity_id, contact_id, role, is_primary)
        VALUES (v_ent, v_con, 'owner', true);

    FOR r IN SELECT * FROM update_customer(
                 p_search_name := 'Ada Lovelace',
                 p_city := 'London', p_status := 'prospect')
    LOOP
        -- success=t proves the port redirected the body at public: the function
        -- joined entities -> entity_relationships -> contacts and wrote an address,
        -- all in the schema the rest of the model constrains.
        RAISE NOTICE 'VERDICT % update_customer success=% entity=% msg=%',
            CASE WHEN r.success THEN 'OK' ELSE 'ERR' END,
            r.success, r.entity_id, left(r.message, 60);
        IF r.success THEN
            RAISE NOTICE 'VERDICT CONFIRM entity status now %',
                (SELECT status FROM entities WHERE id = r.entity_id);
        END IF;
    END LOOP;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'VERDICT ERR % | %', SQLSTATE, left(SQLERRM, 120);
END
$$;
ROLLBACK;

-- 5c. Objects the tools reference that no schema in this repository creates.
DO $$
DECLARE
    n int;
BEGIN
    SELECT count(*) INTO n FROM pg_class WHERE relname = 'agent_tool_calls';
    IF n = 0 THEN
        RAISE NOTICE 'VERDICT ERR 00000 | agent_tool_calls does not exist, but tool_logger.py writes to it 5 times';
    ELSE
        RAISE NOTICE 'VERDICT OK agent_tool_calls exists';
    END IF;

    SELECT count(*) INTO n FROM pg_class WHERE relname = 'tickets';
    IF n = 0 THEN
        RAISE NOTICE 'VERDICT ERR 00000 | tickets does not exist (it lived only in the vestigial schema)';
    ELSE
        RAISE NOTICE 'VERDICT OK tickets exists';
    END IF;
END
$$;
