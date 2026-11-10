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

-- ---------------------------------------------------------------------------
-- 7d. the semantic surface: 0035's two doors, the space that remembers which
--     model filled the column, and the two registers that say how much of the
--     corpus is searchable.
-- ---------------------------------------------------------------------------
-- This is the block 0012 deferred when it built the indexes and declined the read path
-- ("wiring a semantic-search tool is Phase 5 code work"), so it is the check that keeps
-- 6_4_vectors.sql honest. That probe proves the ANN path is usable and cheaper, on 500 rows of
-- random()::real, which is a statement about an index and not about a feature. What is asserted
-- below is the other half: the rules that could each stop being true without anything else
-- noticing.
--
-- Every vector here is ONE-HOT: a 1 in slot 1 or slot 2, and 0 in the other 1534. That is
-- deliberate, and the reason is that cosine ignores magnitude. "All 0.001" and "all 0.002" are
-- the same direction and score 1.0 apart, so the obvious way to synthesise a fake embedding makes
-- every near and far fixture identical to every other and vacates each ordering assertion.
-- One-hot gives distances that are exact and interpretable: 1.0 for the same slot, 0.0 for a
-- different one, with no floating point luck in between.
--
-- The index is not what these blocks test. At this row count the planner will seq-scan, and 6_4
-- is where the hnsw path is proven. What is proven here is the SQL's semantics, which no plan
-- shape changes.
--
-- All of it is inside the file's BEGIN ... ROLLBACK, including the probe's own stamp of
-- embedding_space, so nothing is cleaned up by hand. That is 6_4's convention rather than an
-- oversight: a fixture vector left in the column under the model name this block used would make
-- the keeper's first real tick a refusal, and the rollback is what makes that state unreachable.

DO $$
DECLARE
    v_sig text;
BEGIN
    IF to_regclass('public.vw_embedding_status') IS NULL THEN
        RAISE NOTICE 'VERDICT KNOWN-OPEN 6.4 | there is no semantic surface at all: no door writes '
                     'a vector and no register says how many there are';
        RETURN;
    END IF;

    SELECT string_agg(p.proname, ',' ORDER BY p.proname) INTO v_sig
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('embed_communications', 'search_similar_communications');
    IF v_sig IS NULL OR v_sig NOT LIKE '%embed_communications%' THEN
        RAISE NOTICE 'VERDICT KNOWN-OPEN 6.4 | no door writes a vector, so the indexes 0012 built '
                     'are still a scoreboard and not a feature';
        RETURN;
    END IF;
    IF v_sig NOT LIKE '%search_similar_communications%' THEN
        RAISE NOTICE 'VERDICT ERR 6.4 | vectors can be written and never read, which is 6.4 again '
                     'in a different file: an index with no reader is a cost and not a capability';
        RETURN;
    END IF;

    -- Closed to the cluster, open to the runtime role. Asserted behaviourally, because "the grant
    -- is in the file" and "the role can open the door" are two statements, and 0031 is the record
    -- of a keeper that could not tell them apart while reporting a clean zero every hour.
    IF has_function_privilege('afpc_app', 'embed_communications(jsonb,text,text,uuid)', 'EXECUTE')
       AND has_function_privilege('afpc_app',
               'search_similar_communications(vector,integer,integer)', 'EXECUTE')
       AND NOT has_function_privilege('public',
               'embed_communications(jsonb,text,text,uuid)', 'EXECUTE')
    THEN
        RAISE NOTICE 'VERDICT OK 0035 | both semantic doors are installed, closed to PUBLIC, and '
                     'openable by the role the keeper runs as';
    ELSE
        RAISE NOTICE 'VERDICT ERR 0035 | the semantic doors are installed and the grants are not the '
                     'pair 0035 §6 wrote: afpc_app=% PUBLIC=%',
            has_function_privilege('afpc_app', 'embed_communications(jsonb,text,text,uuid)',
                                   'EXECUTE'),
            has_function_privilege('public', 'embed_communications(jsonb,text,text,uuid)',
                                   'EXECUTE');
    END IF;
END
$$;

DO $$
DECLARE
    v_q     text;
    v_near  text;
    v_far   text;
    v_ent   bigint;
    v_old   bigint;
    v_new   bigint;
    v_other uuid;
    v_mine  uuid;
    v_r      record;
    v_found  integer;
    v_stale  integer;
    v_model  text;
BEGIN
    v_q    := '['||(SELECT string_agg(CASE WHEN g = 1 THEN '1' ELSE '0' END, ',')
                      FROM generate_series(1, 1536) g)||']';
    v_far  := '['||(SELECT string_agg(CASE WHEN g = 2 THEN '1' ELSE '0' END, ',')
                      FROM generate_series(1, 1536) g)||']';
    v_near := v_q;
    v_mine := afpc_current_tenant();

    --------------------------------------------------------------------------
    -- 7d-a. what an embedding is MADE FROM is the view's decision. 4.5's lesson, one
    --        column type away: a rule stated in a client and enforced in the schema is
    --        the rule that eventually disagrees with itself, and a vector is a rule
    --        about text. If this composition ever moves into pkg/crm, the day it drifts
    --        the corpus stops meaning one thing and no search would say so.
    --------------------------------------------------------------------------
    IF to_regclass('public.vw_unembedded_communications') IS NULL THEN
        RAISE NOTICE 'VERDICT KNOWN-OPEN 6.4 | there is no queue view, so whatever gets embedded is '
                     'whatever a Go string decided';
        RETURN;
    END IF;

    INSERT INTO entities (name, entity_type, status)
         VALUES ('4_7 probe customer', 'customer', 'active') RETURNING id INTO v_ent;
    INSERT INTO communications (entity_id, communication_type, direction, subject, summary,
                                full_content, started_at)
         VALUES (v_ent, 'call', 'inbound', E'  Shipping\tissues  ',
                 E'the pallet arrived   late,\nagain', 'and   wet', now())
      RETURNING id INTO v_new;

    SELECT embeddable_text, truncated, nothing_to_embed INTO v_r
      FROM vw_unembedded_communications WHERE communication_id = v_new;
    IF v_r.embeddable_text IS NULL THEN
        RAISE NOTICE 'VERDICT ERR 6.4 | a fresh communication never reaches the queue, so the keeper '
                     'has no way to see it';
        RETURN;
    END IF;
    IF v_r.embeddable_text <> 'Shipping issues the pallet arrived late, again and wet' THEN
        RAISE NOTICE 'VERDICT ERR 6.4 | the queue composes % from subject, summary and body: the '
                     'collapse rule lives somewhere other than the view',
            quote_literal(v_r.embeddable_text);
        RETURN;
    END IF;
    IF v_r.truncated OR v_r.nothing_to_embed THEN
        RAISE NOTICE 'VERDICT ERR 6.4 | a short complete row reports truncated=% nothing_to_embed=%',
            v_r.truncated, v_r.nothing_to_embed;
        RETURN;
    END IF;

    -- A row with nothing in any of its three text columns must be FLAGGED and not quietly queued.
    -- An empty string embeds to a valid unit-norm vector, and every such vector is near every
    -- other one's, so the corpus fills with rows that match each other and nothing else.
    INSERT INTO communications (entity_id, communication_type, direction, subject, summary,
                                full_content, started_at)
         VALUES (v_ent, 'note', 'internal', '  ', '', NULL, now())
      RETURNING id INTO v_old;
    SELECT nothing_to_embed INTO v_r FROM vw_unembedded_communications WHERE communication_id = v_old;
    IF NOT v_r.nothing_to_embed THEN
        RAISE NOTICE 'VERDICT ERR 6.4 | a row with nothing to say is embeddable, which is how a '
                     'ranking gets poisoned by arithmetic that is correct';
        RETURN;
    END IF;
    RAISE NOTICE 'VERDICT OK 0035 | the queue states once what an embedding of a communication means';

    --------------------------------------------------------------------------
    -- 7d-b. the horizon is INSIDE the ANN top-k. This is the case where the position of a
    --        predicate changes the answer and not merely the row count: with p_limit of 1,
    --        filtering after limiting returns nothing at all, and nothing reads to a human
    --        exactly like "nobody complained about shipping".
    --
    --        Fixture: the OLD row is the one that matches the question, the recent row is
    --        deliberately unrelated to it.
    --------------------------------------------------------------------------
    SELECT model INTO v_model FROM embedding_space WHERE space_key = 'communications';
    IF v_model IS NULL THEN
        INSERT INTO embedding_space (space_key, model, dimensions, served_by)
             VALUES ('communications', '4_7-probe-model', 1536, 'the probe');
        v_model := '4_7-probe-model';
    END IF;

    -- The old fixture is the one that MATCHES the question and is 400 days out; the recent one is
    -- in the window and matches nothing about it. Two assertions follow, and neither depends on
    -- what else the corpus holds, which is what makes this block runnable against a populated
    -- database rather than only against a fresh one.
    UPDATE communications SET embedding = v_near::public.vector,
                              started_at = now() - interval '400 days'
      WHERE id = v_old;
    UPDATE communications SET embedding = v_far::public.vector WHERE id = v_new;

    -- With no window, the nearest row is the old one, and its similarity is exactly 1.0 because
    -- the vectors are the same one-hot direction. Anything else here would mean the distance is
    -- not the cosine vector_cosine_ops promises the index is built for.
    SELECT count(*) INTO v_found FROM search_similar_communications(v_q::public.vector(1536),
                                                                   NULL, 1)
     WHERE communication_id = v_old;
    IF v_found <> 1 THEN
        RAISE NOTICE 'VERDICT ERR 6.4 | an unhorizoned top-1 did not return the exact match, so the '
                     'ranking is not by the cosine the index is built on';
        RETURN;
    END IF;

    -- The discriminating one. A window applied INSIDE the scan keeps walking past the excluded old
    -- row and answers with something in the window: one row. A window applied AFTER the limit takes
    -- the nearest row overall (the old one), filters it, and answers with ZERO rows, which is a
    -- wrong answer that reads to a human as "nobody has complained in the last month".
    SELECT count(*) INTO v_found FROM search_similar_communications(v_q::public.vector(1536), 30, 1);
    SELECT count(*) INTO v_stale
      FROM search_similar_communications(v_q::public.vector(1536), 30, 1)
     WHERE communication_id = v_old;
    IF v_found = 0 THEN
        RAISE NOTICE 'VERDICT ERR 6.4 | a windowed search with a limit of 1 answered no rows at all '
                     'although the window has rows in it: the horizon is applied AFTER the LIMIT, so '
                     '"last week" filters whatever happened to be nearest instead of searching '
                     'last week';
        RETURN;
    ELSIF v_stale <> 0 THEN
        RAISE NOTICE 'VERDICT ERR 6.4 | the windowed search still returned the 400-day-old row, so '
                     'p_days is not the clause 0035 §4 says it is';
        RETURN;
    END IF;
    RAISE NOTICE 'VERDICT OK 0035 | the window is inside the scan: a top-k of 1 finds a row in the '
                 'window even though the nearest thing in the corpus is outside it';

    --------------------------------------------------------------------------
    -- 7d-c. row security on the ANN path, in both directions. The hnsw graph is shared, so a
    --        nearer foreign row is a leak of someone else''s history and a top-k starved by
    --        foreign rows is the same defect pointed back at the caller: an empty answer about
    --        rows the caller owns and could see.
    --
    --        Run as afpc_app on purpose. The harness connects as a superuser, and a superuser
    --        walks past row security whatever FORCE says, so measured as itself the finding would
    --        be invisible and this block would pass on any schema.
    --------------------------------------------------------------------------
    INSERT INTO tenants (slug, name) VALUES ('4-7-semantic-probe', 'cross-tenant ANN probe')
     ON CONFLICT DO NOTHING;
    INSERT INTO entities (name, entity_type, status, tenant_id)
         VALUES ('4_7 probe other tenant', 'customer', 'active',
                 (SELECT tenant_id FROM tenants WHERE slug = '4-7-semantic-probe'))
      RETURNING id INTO v_old;
    INSERT INTO communications (entity_id, communication_type, direction, summary, started_at,
                                embedding, tenant_id)
         VALUES (v_old, 'call', 'inbound', 'their nearest row', now(), v_near::public.vector,
                 (SELECT tenant_id FROM tenants WHERE slug = '4-7-semantic-probe'));

    BEGIN
        EXECUTE 'SET LOCAL ROLE afpc_app';
        PERFORM set_config('app.tenant_id', v_mine::text, true);
        SELECT count(*) INTO v_found
          FROM search_similar_communications(v_q::public.vector(1536), NULL, 20)
         WHERE customer_name = '4_7 probe other tenant';
        IF v_found <> 0 THEN
            RAISE NOTICE 'VERDICT ERR 0035 | a similarity query returned another tenant''s row: 5.7 '
                         'with a cosine attached';
        ELSIF (SELECT count(*) FROM search_similar_communications(v_q::public.vector(1536), NULL, 20))
              < 1 THEN
            RAISE NOTICE 'VERDICT ERR 0035 | the caller sees no rows although its own tenant has '
                         'vectors: the top-k was drawn from rows this connection cannot read';
        ELSE
            RAISE NOTICE 'VERDICT OK 0035 | the ANN path answers under row security in both '
                         'directions';
        END IF;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'VERDICT ERR 0035 | the cross-tenant ANN probe raised % - %',
            SQLSTATE, left(SQLERRM, 110);
    END;
    -- RESET ROLE and not waiting for the transaction: the file has more blocks to run and they
    -- belong to the owner. set_config with is_local=true would revert on its own at ROLLBACK, so
    -- only the role needs putting back by hand.
    EXECUTE 'RESET ROLE';
    PERFORM set_config('app.tenant_id', v_mine::text, true);

    --------------------------------------------------------------------------
    -- 7d-d. the model swap, behaviourally, on a column that already has vectors in it. The
    --       existence of embedding_space is not the finding; a door that refuses it is.
    --------------------------------------------------------------------------
    BEGIN
        PERFORM * FROM embed_communications('[]'::jsonb, 'a/model/that/is/not/the/one/in/the/column');
        RAISE NOTICE 'VERDICT ERR 0035 | a second embedder was accepted into a column filled by a '
                     'first. Distances across the two are not distances, and nothing else in this '
                     'schema could ever notice';
    EXCEPTION
        WHEN check_violation THEN
            IF SQLERRM LIKE '%was filled by%' THEN
                RAISE NOTICE 'VERDICT OK 0035 | the second model is refused in SQL, by name';
            ELSE
                RAISE NOTICE 'VERDICT ERR 0035 | the refusal came from a constraint and not from the '
                             'door''s reasoning: %', left(SQLERRM, 90);
            END IF;
        WHEN OTHERS THEN
            RAISE NOTICE 'VERDICT ERR 0035 | a second embedder produced % - %',
                SQLSTATE, left(SQLERRM, 90);
    END;

    --------------------------------------------------------------------------
    -- 7d-e. the register agrees with the catalog about how many vector columns exist, and
    --       names the ones nobody writes.
    --------------------------------------------------------------------------
    IF (SELECT count(*) FROM vw_embedding_status) <>
       (SELECT count(*) FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public' AND c.relkind = 'r' AND a.attnum > 0
           AND NOT a.attisdropped AND a.atttypid = 'vector'::regtype) THEN
        RAISE NOTICE 'VERDICT ERR 0035 | the register and the catalog disagree about how many vector '
                     'columns exist, which is a scoreboard that has stopped counting';
    ELSIF (SELECT verdict FROM vw_embedding_status WHERE table_name = 'contacts') NOT LIKE 'EMPTY%' THEN
        RAISE NOTICE 'VERDICT ERR 0035 | contacts, which 0035 leaves alone by decision, is reported '
                     'as %. The scope of a claim is part of the claim',
            (SELECT verdict FROM vw_embedding_status WHERE table_name = 'contacts');
    ELSE
        RAISE NOTICE 'VERDICT OK 0035 | the register lists the whole catalog and says which columns '
                     'nothing writes';
    END IF;

    --------------------------------------------------------------------------
    -- 7d-f. the column census, in 7_1 §8h's form: the names pkg/crm's coverage() selects are
    --       the names this view carries. A rename on either side is otherwise a Go read that
    --       answers zero, which is 0031's zero-shaped bug arriving as a missing column.
    --------------------------------------------------------------------------
    SELECT count(*) INTO v_found
      FROM unnest(ARRAY['table_name','rows_total','rows_embedded','verdict','embedded_by',
                        'served_by','newest_embedded_at']) AS want(c)
     WHERE NOT EXISTS (SELECT 1 FROM pg_attribute a
                        WHERE a.attrelid = 'vw_embedding_status'::regclass
                          AND a.attname = want.c AND a.attnum > 0);
    IF v_found <> 0 THEN
        RAISE NOTICE 'VERDICT ERR 0035 | vw_embedding_status lacks % of the columns pkg/crm reads by '
                     'name, and a reader that finds nothing reports a healthy corpus', v_found;
    ELSE
        RAISE NOTICE 'VERDICT OK 0035 | the register''s columns are the ones the keeper reads';
    END IF;

    --------------------------------------------------------------------------
    -- 7d-g. a wrong width is refused by the door and not by a cast, whatever the embedder
    --       answered. Measured twice, differently, an hour apart on this server.
    --------------------------------------------------------------------------
    BEGIN
        PERFORM * FROM embed_communications(
            jsonb_build_array(jsonb_build_object('communication_id', v_new, 'embedding',
                '['||(SELECT string_agg('0.001', ',') FROM generate_series(1, 1024))||']')),
            v_model);
        RAISE NOTICE 'VERDICT ERR 0035 | a 1024-dimension vector reached a vector(1536) column, '
                     'which is the answer one of the two models here gives when asked for 1536';
    EXCEPTION
        WHEN OTHERS THEN
            -- 22023 is invalid_parameter_value, and not raise_exception, which is P0001. A handler
            -- written for the wrong name silently misses every refusal the door makes, and reports
            -- the finding as the trap 0022 found in get_followup_customers: an assertion whose test
            -- can only take the other branch.
            IF SQLSTATE::text = '22023' AND SQLERRM LIKE '%not 1536 dimensions%' THEN
                RAISE NOTICE 'VERDICT OK 0035 | a short vector is refused by name before anything is '
                             'written, whatever the embedder answered';
            ELSE
                RAISE NOTICE 'VERDICT ERR 0035 | a 1024-dimension vector reached a vector(1536) '
                             'column and produced % - % instead of the door''s refusal by width',
                    SQLSTATE, left(SQLERRM, 90);
            END IF;
    END;
END
$$;

ROLLBACK;
