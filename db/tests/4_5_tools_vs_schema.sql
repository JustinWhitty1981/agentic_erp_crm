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
    v_ent bigint;
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
    n     int;
    m     int;
BEGIN
    -- 5c, rewritten for what 0017 decided and what it found.

    -- The three views this repository's own documentation tells an agent to query. Measured
    -- before 0017: 0 of the 3 exist, because 0001 ported the TABLE out of
    -- blueprint/11_interaction_logging.sql and left that file's VIEWS behind, so the debugging
    -- instructions and the schema disagreed by a whole read path.
    SELECT count(*) INTO n FROM pg_class
     WHERE relnamespace = 'public'::regnamespace AND relkind = 'v'
       AND relname IN ('vw_recent_interactions','vw_failed_interactions','vw_tool_performance');
    IF n < 3 THEN
        RAISE NOTICE 'VERDICT ERR 00000 | the debug views the docs promise are missing (% of 3 '
                     'exist): AGENTS.md and docs/INTERACTION_LOGGING.md both tell a reader to '
                     'query them', n;
    ELSE
        RAISE NOTICE 'VERDICT OK the three documented interaction views exist';
    END IF;

    -- agent_tool_calls: 4.5 asked for it to be created or its code deleted. Neither, measured:
    -- the only file that touches it is never imported, and its per-call grain is derivable from
    -- the log the live code does write. So the honest phrase is about whether anything ANSWERS
    -- the question, not whether a table with a given name exists.
    SELECT count(*) INTO n FROM pg_class WHERE relname = 'agent_tool_calls';
    SELECT count(*) INTO m FROM pg_class WHERE relname = 'vw_tool_calls' AND relkind = 'v';
    IF n = 0 AND m = 0 THEN
        RAISE NOTICE 'VERDICT ERR 00000 | nothing derives the per-call answer: no '
                     'agent_tool_calls table and no vw_tool_calls view, so the trajectory is '
                     'only readable per run';
    ELSIF n = 0 THEN
        RAISE NOTICE 'VERDICT INFO agent_tool_calls is absent by decision (0017): the per-call '
                     'grain comes from agent_interactions, and a second log of the same calls '
                     'is a second implementation of ADR-001';
    ELSIF m = 0 THEN
        RAISE NOTICE 'VERDICT OK agent_tool_calls exists, so 0017''s decision was reversed by '
                     'some later change - check that the two logs agree';
    ELSE
        RAISE NOTICE 'VERDICT ERR 00000 | both exist: agent_tool_calls and the derivation are '
                     'two answers to one question, and they will disagree first or last';
    END IF;

    -- tickets: no code touches it, and after 0017 nothing in the schema does either. Its only
    -- reference in the repository is a LEFT JOIN in a superseded file.
    SELECT count(*) INTO n FROM pg_class WHERE relname = 'tickets';
    SELECT count(*) INTO m FROM pg_class c
     WHERE c.relkind = 'v' AND c.relnamespace = 'public'::regnamespace
       AND pg_get_viewdef(c.oid) ~ '\y(tickets|agent_tool_calls)\y';
    IF n = 0 AND m = 0 THEN
        RAISE NOTICE 'VERDICT INFO tickets is absent by decision (0017): nothing in public '
                     'names it; the support domain is followups';
    ELSIF n > 0 THEN
        RAISE NOTICE 'VERDICT OK tickets exists';
    ELSE
        RAISE NOTICE 'VERDICT ERR 00000 | % view(s) reference tickets or agent_tool_calls, which '
                     'no migration creates - that is a 42P01 waiting for a reader, which is '
                     'exactly how 4.5 read', m;
    END IF;
END
$$;
