-- Finding 4.5, the half that lives on the customer service agent's call path.
--
-- 0017 settled what 4.5 was NOT - there is no missing `agent_tool_calls` table and no missing
-- `tickets` table - and left what it IS: the tools and the schema disagree, and until this session
-- the disagreement included a write path that exists only in a Python file, a read path whose
-- parameter nothing reads, and a memory store that is a directory.
--
-- Three blocks, one per migration, because the findings are different defects that happen to
-- belong to the same agent:
--
--   7a  add_communication did not exist in the database at all. blueprint/tools/add_communication.py
--       carried the INSERT, qualified to a schema no migration creates.
--   7b  get_followup_customers accepted p_days_threshold and compared against a literal 7 days. Its
--       third reason, 'Unresolved communication', tested a variable nothing assigned, and the
--       staleness clock was the row's write time rather than the conversation's.
--   7c  save_memory was a file write. Nothing in pg_catalog knew what the agent remembered, and a
--       container rebuild forgot it.
--
-- Each block prints its mapped phrase from an existence guard FIRST, so a pre-fix database says
-- KNOWN-OPEN rather than SURPRISE - dev/README's entry about a phrase only reachable after the fix,
-- which is a test that stops existing without saying so.

BEGIN;

-- ---------------------------------------------------------------------------
-- 7a. the interaction door
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_ent     bigint;
    v_comm    bigint;
    v_ok      boolean;
    v_msg     text;
    v_rows    bigint;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'add_communication') THEN
        RAISE NOTICE 'VERDICT ERR 4.5 | there is no door for interactions: add_communication is '
                     'not in the database, so every log-a-call path is a caller-side INSERT';
    ELSE
        RAISE NOTICE 'VERDICT OK 4.5 add_communication is a database function';

        -- The property the Python door never had: a name that matches two customers is refused
        -- with both candidates, and nothing is filed. Built through the CRM doors so this block
        -- depends on nothing but the functions it is testing.
        SELECT entity_id INTO v_ent FROM add_customer('Harness', 'Twins',
            'twins-7a@afpc.test.invalid', '+17770000001', NULL, NULL, NULL, NULL, 'US', 'active',
            'individual', NULL, 'home', true);
        PERFORM * FROM add_customer('Harness', 'Twinsworth', 'twins2-7a@afpc.test.invalid',
            '+17770000002', NULL, NULL, NULL, NULL, 'US', 'active',
            'individual', NULL, 'home', true);

        -- 'Harness Twin' is a substring of both names and equal to neither, which is the case the
        -- exact-match tier cannot resolve and must not guess. Asking for 'Harness Twins' would be
        -- answered correctly by the exact tier - and a probe that mistakes a working rule for a
        -- bug is the same error as one that misses a bug, so the distinction is written here.
        SELECT success, communication_id, message INTO v_ok, v_comm, v_msg
          FROM add_communication(p_customer_name := 'Harness Twin',
                                 p_summary := 'Ambiguous on purpose.',
                                 p_communication_type := 'call', p_direction := 'inbound');
        IF v_ok OR v_comm IS NOT NULL THEN
            RAISE NOTICE 'VERDICT ERR 4.5 | an ambiguous name was resolved anyway (id=%): the door '
                         'is choosing a customer the caller never uniquely named', v_comm;
        ELSIF v_msg NOT LIKE '%Twinsworth%' THEN
            RAISE NOTICE 'VERDICT ERR 4.5 | an ambiguous name refused without naming the candidates '
                         '(%): the caller has to guess again', left(v_msg, 90);
        ELSE
            RAISE NOTICE 'VERDICT OK ambiguous names refuse with candidates';
        END IF;

        SELECT count(*) INTO v_rows FROM communications c
         WHERE c.summary = 'Ambiguous on purpose.';
        IF v_rows <> 0 THEN
            RAISE NOTICE 'VERDICT ERR 4.5 | the refusal wrote a row (rows=%): a rejected call is '
                         'still on the customer''s record', v_rows;
        END IF;

        -- Idempotency at the door: the retry an agent's timeout produces must be one communication.
        SELECT communication_id INTO v_comm FROM add_communication(
            p_entity_id := v_ent, p_summary := 'Retry probe.', p_communication_type := 'call',
            p_direction := 'outbound', p_idempotency_key :=
                '00000000-0000-0000-0000-00000007a001');
        PERFORM * FROM add_communication(
            p_entity_id := v_ent, p_summary := 'Retry probe.', p_communication_type := 'call',
            p_direction := 'outbound', p_idempotency_key :=
                '00000000-0000-0000-0000-00000007a001');
        SELECT count(*) INTO v_rows FROM communications c
         WHERE c.summary = 'Retry probe.';
        IF v_rows <> 1 THEN
            RAISE NOTICE 'VERDICT ERR 4.5 | one idempotency key produced % rows: ADR-005 pattern '
                         '2 is not wired at this door', v_rows;
        ELSE
            RAISE NOTICE 'VERDICT OK a retried interaction is one interaction';
        END IF;
    END IF;

EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'VERDICT ERR 4.5 | add_communication raised % - %', SQLSTATE, left(SQLERRM, 120);
END
$$;

-- ---------------------------------------------------------------------------
-- 7b. the follow-up threshold and its clock
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_a     bigint;
    v_b     bigint;
    v_c     bigint;
    v_found bigint;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'get_followup_customers') THEN
        RAISE NOTICE 'VERDICT ERR 4.5 | there is no follow-up read path at all';
        RETURN;
    END IF;

    -- Three fixtures, each isolating one claim, all inserted directly rather than through the
    -- doors: a probe that cannot reproduce the old failure because it depends on a newer migration
    -- reports CLOSED for the wrong reason. Asserted as membership of a named entity id and never
    -- as the size of the list, because other cases write to this database (0013's rule).
    --
    --   v_a: 40 days old on BOTH clocks, resolved       -> the threshold's own claim
    --   v_b: 40 days old on started_at, written now     -> the clock's claim
    --   v_c: contacted now, outcome escalated           -> the branch that never fired
    SELECT count(*) INTO v_found FROM entities WHERE entity_type = 'customer';

    INSERT INTO entities (name, entity_type, status) VALUES ('Threshold Harness', 'customer', 'active')
        RETURNING id INTO v_a;
    INSERT INTO contacts (first_name, last_name, email, status)
        VALUES ('Threshold', 'Harness', 'threshold-7b@afpc.test.invalid', 'active') RETURNING id INTO v_b;
    INSERT INTO entity_relationships (entity_id, contact_id, role, is_primary)
        VALUES (v_a, v_b, 'Customer', true);
    INSERT INTO communications (entity_id, communication_type, direction, summary, outcome,
                                created_at, started_at)
        VALUES (v_a, 'call', 'inbound', 'Forty days ago.', 'resolved',
                now() - interval '40 days', now() - interval '40 days');

    SELECT count(*) INTO v_found FROM get_followup_customers(3650) g WHERE g.entity_id = v_a;
    IF v_found <> 0 THEN
        RAISE NOTICE 'VERDICT ERR 4.5 | the threshold is decorative: a ten-year horizon still '
                     'lists a customer contacted forty days ago, so p_days_threshold reaches no '
                     'comparison';
    ELSE
        RAISE NOTICE 'VERDICT OK a ten-year horizon clears a forty-day-old customer';
    END IF;

    SELECT count(*) INTO v_found FROM get_followup_customers(7) g WHERE g.entity_id = v_a;
    IF v_found <> 1 THEN
        RAISE NOTICE 'VERDICT ERR 4.5 | the seven-day horizon does not list a forty-day-stale '
                     'customer (% rows) - the parameter moves the answer the wrong way', v_found;
    ELSE
        RAISE NOTICE 'VERDICT OK a seven-day horizon lists a forty-day-old customer';
    END IF;

    INSERT INTO entities (name, entity_type, status) VALUES ('Backdate Harness', 'customer', 'active')
        RETURNING id INTO v_b;
    INSERT INTO contacts (first_name, last_name, email, status)
        VALUES ('Backdate', 'Harness', 'backdate-7b@afpc.test.invalid', 'active') RETURNING id INTO v_c;
    INSERT INTO entity_relationships (entity_id, contact_id, role, is_primary)
        VALUES (v_b, v_c, 'Customer', true);
    INSERT INTO communications (entity_id, communication_type, direction, summary, outcome,
                                started_at)
        VALUES (v_b, 'call', 'inbound', 'Logged a month late.', 'resolved',
                now() - interval '40 days');

    SELECT count(*) INTO v_found FROM get_followup_customers(7) g
     WHERE g.entity_id = v_b AND g.follow_up_reason = 'No recent communications';
    IF v_found <> 1 THEN
        RAISE NOTICE 'VERDICT ERR 4.5 | a conversation from forty days ago that was written to the '
                     'table this instant is not stale - the tool reads the row''s write time and '
                     'labels it the interaction time';
    ELSE
        RAISE NOTICE 'VERDICT OK the staleness clock is the interaction, not the INSERT';
    END IF;

    -- The branch that has never fired since 0001 ported it: nothing about v_c is stale, so only
    -- the unresolved-outcome arm can put it on the list, and that arm tested a variable no
    -- statement had assigned.
    IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'add_communication') THEN
        INSERT INTO entities (name, entity_type, status) VALUES ('Escalate Harness', 'customer', 'active')
            RETURNING id INTO v_c;
        INSERT INTO contacts (first_name, last_name, email, status)
            VALUES ('Escalate', 'Harness', 'escalate-7b@afpc.test.invalid', 'active')
            RETURNING id INTO v_a;
        INSERT INTO entity_relationships (entity_id, contact_id, role, is_primary)
            VALUES (v_c, v_a, 'Customer', true);
        PERFORM add_communication(p_entity_id := v_c, p_summary := 'Angry, escalated.',
            p_communication_type := 'call', p_direction := 'inbound',
            p_outcome := 'escalated', p_sentiment_label := 'negative');
        SELECT count(*) INTO v_found FROM get_followup_customers(7) g
         WHERE g.entity_id = v_c AND g.follow_up_reason = 'Unresolved communication';
        IF v_found <> 1 THEN
            RAISE NOTICE 'VERDICT ERR 4.5 | the unresolved-outcome reason cannot fire (rows=%): a '
                         'test that can only evaluate UNKNOWN takes neither branch', v_found;
        ELSE
            RAISE NOTICE 'VERDICT OK an unresolved thread reaches the follow-up list';
        END IF;
    ELSE
        RAISE NOTICE 'VERDICT ERR 4.5 | the unresolved-outcome reason cannot fire: there is no door '
                     'to create the interaction it tests';
    END IF;

EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'VERDICT ERR 4.5 | get_followup_customers raised % - %', SQLSTATE, left(SQLERRM, 120);
END
$$;

-- ---------------------------------------------------------------------------
-- 7c. memory inside the wall
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_ok    boolean;
    v_found bigint;
    v_err   text;
    v_td    uuid;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'save_memory') THEN
        RAISE NOTICE 'VERDICT ERR ADR-002 | memory lives outside the database: save_memory is not '
                     'a function, so what the agent was told is a file in a container';
        RETURN;
    END IF;

    SELECT count(*) INTO v_found FROM information_schema.tables WHERE table_name = 'agent_memories';
    IF v_found <> 1 THEN
        RAISE NOTICE 'VERDICT ERR ADR-002 | memory lives outside the database: save_memory exists '
                     'but agent_memories does not (% rows)', v_found;
        RETURN;
    END IF;
    RAISE NOTICE 'VERDICT OK memory is a table';

    SELECT tenant_id INTO v_td FROM tenants WHERE slug = 'default';

    -- Round trip in the runtime seat, on the spelling the filename version folded into a
    -- neighbour. Three spellings, two notes, one key.
    SET LOCAL ROLE afpc_app;
    PERFORM set_config('app.tenant_id', v_td::text, true);
    SELECT success INTO v_ok FROM save_memory('Harness  PREFS', 'email not phone', gen_random_uuid());
    SELECT success INTO v_ok FROM save_memory('harness prefs', 'prefers mornings', gen_random_uuid());
    SELECT count(*) INTO v_found FROM get_memory('HARNESS   prefs', 10);
    IF v_found <> 2 THEN
        RAISE NOTICE 'VERDICT ERR ADR-002 | three spellings of one key produced % entries - '
                     'normalisation is not agreed between the read path and the write path', v_found;
    ELSE
        RAISE NOTICE 'VERDICT OK one key, two notes, spelled three ways';
    END IF;

    -- The grant half: an agent that can edit its own past can rewrite why it did something. The
    -- attempt is made inside the seat, because from the owner's seat this measures a superuser.
    v_err := NULL;
    BEGIN
        EXECUTE format('UPDATE agent_memories SET content = %L WHERE content IS NOT NULL',
                       'rewritten');
    EXCEPTION WHEN insufficient_privilege THEN
        v_err := '42501';
    END;
    RESET ROLE;
    IF v_err IS DISTINCT FROM '42501' THEN
        RAISE NOTICE 'VERDICT ERR ADR-002 | the runtime role can edit the memory table (%): '
                     'append-only is a comment, not a wall', coalesce(v_err, 'no error');
    ELSE
        RAISE NOTICE 'VERDICT OK the memory table is append-only by grant';
    END IF;

    -- And the trail: 0013's attaching census ran before this table existed, so nothing else would
    -- notice the trigger being absent.
    SELECT count(*) INTO v_found FROM audit_log l
     WHERE l.table_name = 'agent_memories' AND l.action = 'INSERT';
    IF v_found < 2 THEN
        RAISE NOTICE 'VERDICT ERR ADR-002 | % audit rows for two writes to agent_memories: the '
                     'trigger 0013 attaches by census is missing on a table born later', v_found;
    ELSE
        RAISE NOTICE 'VERDICT OK the memory table leaves a trail';
    END IF;

EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'VERDICT ERR ADR-002 | the memory path raised % - %', SQLSTATE, left(SQLERRM, 120);
END
$$;

ROLLBACK;
