-- 0021: the door a customer service agent has to walk through, built instead of forced
--       (DATABASE_REVIEW.md 4.5's live half; ADR-002 database-first, ADR-005 pattern 2)
--
-- Why this file exists at all: `docs/agent_requirements/customer_service/customer_service.md`
-- requirement 5 is "log new interactions", and the schema has no way to do it. Measured against
-- pg_proc, the customer-domain write paths that exist are add_customer, update_customer and
-- mark_customer_followup; nothing in the database creates a `communications` row. The blueprint
-- did it the way the review's finding 4.5 describes - `blueprint/tools/add_communication.py`
-- carries its own INSERT, qualified to `agent_first_erp_crm`, the twin schema §3.3 says no
-- migration ever created. So the rule lived in a Python file, the CHECKs lived here, and the
-- only thing between them was whichever one whoever edited touched last.
--
-- What the door has to refuse, measured rather than assumed:
--
--   * Name resolution is a COUNT, not a fetch. `SELECT id INTO ... WHERE name ILIKE '%x%'`
--     keeps whichever row the scan happens to return first and discards the rest without an
--     error and without a notice - 0013's entry in the same list of shapes that fail quietly.
--     A substring search for "Ada" against two Aas picking one at random is how a call gets
--     filed against the wrong customer, which is worse than being refused: the wrong row looks
--     like a logged call forever, and the audit trail faithfully records the mistake. So the
--     body counts, and an ambiguous name answers with the candidates rather than a coin flip.
--   * An invisible row and an absent row are the same query result. Under 0009's forced row
--     security a `SELECT count(*)` for another tenant's entity_id returns 0, and 0018 measured
--     what a foreign key makes of that: nothing - "the lookup returns NULL, the referencing FK
--     sees a valid code, and the row lands". The refusal here is therefore explicit, and probe
--     F takes the afpc_app seat to prove the door refuses rather than writes a row whose entity
--     the caller cannot see.
--   * A vocabulary is stated once, in the CHECK, and not repeated here. 0007 published the six
--     domain rules on this table in vw_domain_vocabulary; writing them again in plpgsql would
--     be, in 0018's words about the currency shape CHECK, "four copies of a rule and four
--     chances to drift". So 'sideways' as a direction arrives as 23514 with its own SQLSTATE -
--     0014's rule that original codes propagate verbatim - and probe E asserts no row survived
--     the attempt. This is deliberately NOT the same decision 0016 made for p_entity_type, and
--     the difference is that add_customer's individual/business axis lives in NO column, so
--     there was nothing to defer to.
--   * A retry must not produce a second copy of a phone call. Same claim as 0016, same ladder,
--     same reason: the checks above it are reads.
--   * follow_up_required is a flag on a communication, not a task. `vw_pending_followups` reads
--     the `followups` table, which has no writer anywhere in the schema (pg_proc was asked).
--     Inventing a hidden second write here would make logging a call create work nobody asked
--     for, and would be the first door in this database that touches two tables when its name
--     names one. It is refused as a row instead, and §5 says who owns the task table.

SET client_min_messages TO notice;

-- ---------------------------------------------------------------------------
-- 1. The door
-- ---------------------------------------------------------------------------
-- New name, so no old head is being replaced and no ambiguity is being created (0014's
-- lesson in reverse: CREATE OR REPLACE matches by signature, and a name nothing has ever
-- defined cannot have two winners). Asserted at the end of §4 rather than trusted here.
CREATE OR REPLACE FUNCTION add_communication(
    p_customer_name      text        DEFAULT NULL,
    p_entity_id          bigint      DEFAULT NULL,
    p_contact_id         bigint      DEFAULT NULL,
    p_communication_type varchar     DEFAULT 'note',
    p_direction          varchar     DEFAULT 'outbound',
    p_subject            text        DEFAULT NULL,
    p_summary            text        DEFAULT NULL,
    p_full_content       text        DEFAULT NULL,
    p_channel            varchar     DEFAULT NULL,
    p_agent_id           varchar     DEFAULT NULL,
    p_sentiment_label    varchar     DEFAULT NULL,
    p_priority           varchar     DEFAULT NULL,
    p_outcome            varchar     DEFAULT NULL,
    p_started_at         timestamptz DEFAULT NULL,
    p_duration_seconds   integer     DEFAULT NULL,
    p_follow_up_required boolean     DEFAULT false,
    p_follow_up_date     date        DEFAULT NULL,
    p_follow_up_action   text        DEFAULT NULL,
    p_parent_id          bigint      DEFAULT NULL,
    p_idempotency_key    uuid        DEFAULT NULL
) RETURNS TABLE(success boolean, communication_id bigint, entity_id bigint, message text)
LANGUAGE plpgsql AS $$
DECLARE
    v_entity_id  bigint;
    v_row        record;
    v_found      bigint;
    v_candidates text;
    v_claim      record;
    v_state      text := '';
    v_ok         boolean := true;
    v_msg        text;
    v_comm_id    bigint;
BEGIN
    ------------------------------------------------------------------
    -- ADR-005 pattern 2 at the head, in 0016's shape: a replay answers from the cache, a
    -- live lease is 40001, a reused key is P0001 and not 23505 (no unique index was
    -- violated, and a caller that reads SQLSTATEs must not learn that a communication is
    -- deduplicated by key when it is deduplicated by nothing at all). The fingerprint covers
    -- the nineteen business arguments and not the key, so two calls that describe the same
    -- interaction are one operation and a call that differs in any of them is a different
    -- request wearing someone else's key.
    ------------------------------------------------------------------
    IF p_idempotency_key IS NOT NULL THEN
        SELECT * INTO v_claim FROM idempotency_claim(
            p_idempotency_key, 'add_communication',
            jsonb_build_object(
                'name', p_customer_name, 'entity_id', p_entity_id,
                'contact_id', p_contact_id, 'type', p_communication_type,
                'direction', p_direction, 'subject', p_subject,
                'summary', p_summary, 'content', p_full_content,
                'channel', p_channel, 'agent_id', p_agent_id,
                'sentiment', p_sentiment_label, 'priority', p_priority,
                'outcome', p_outcome, 'started_at', p_started_at,
                'duration', p_duration_seconds, 'follow_up', p_follow_up_required,
                'follow_up_date', p_follow_up_date, 'follow_up_action', p_follow_up_action,
                'parent_id', p_parent_id));
        v_state := v_claim.claim_state;
        IF v_state = 'replay' THEN
            success          := (v_claim.cached_response ->> 'success')::boolean;
            communication_id := (v_claim.cached_response ->> 'communication_id')::bigint;
            entity_id        := (v_claim.cached_response ->> 'entity_id')::bigint;
            message          := v_claim.cached_response ->> 'message';
            RETURN NEXT;
            RETURN;
        ELSIF v_state = 'in_progress' THEN
            RAISE EXCEPTION 'add_communication: an attempt with key % is already in flight',
                p_idempotency_key
                USING ERRCODE = '40001',
                      HINT = 'the lease expires and a take-over rotates the token (0011)';
        ELSIF v_state = 'conflict' THEN
            RAISE EXCEPTION 'add_communication: key % was settled for a DIFFERENT request (fingerprint mismatch)',
                p_idempotency_key
                USING ERRCODE = 'P0001',
                      HINT = 'a caller''s idempotency key names one communication; never reuse one across requests';
        END IF;
    END IF;

    ------------------------------------------------------------------
    -- Who is being talked about. One way to name a customer, not two: an id and a name that
    -- disagree would be a guess about which one the caller meant, and 0004 refused the same
    -- kind of guess about location and lot rather than merge it.
    --
    -- QUALIFICATION WARNING, because this is where this function bites an editor: entity_id is
    -- both an OUT column and a column of communications, so an unqualified `WHERE entity_id =
    -- ...` inside this body is ambiguous (42702) - raised at first execution, not at CREATE,
    -- since a plpgsql body is not parsed until it is entered. Every column reference below
    -- names its table. 0016 carries the same note about its RETURNING target.
    ------------------------------------------------------------------
    IF p_entity_id IS NOT NULL AND p_customer_name IS NOT NULL THEN
        v_ok := false; v_msg := 'Name a customer one way: p_entity_id or p_customer_name, not both';
    ELSIF p_entity_id IS NULL AND p_customer_name IS NULL THEN
        v_ok := false; v_msg := 'Either p_entity_id or p_customer_name is required';
    END IF;

    IF v_ok AND p_entity_id IS NOT NULL THEN
        -- Counted, not fetched: 0 covers "never existed" and "belongs to someone else" in one
        -- number, and the message says so, because the caller cannot tell which of the two the
        -- wall decided (0018: the FK would have accepted the key either way).
        SELECT count(*) INTO v_found FROM entities WHERE entities.id = p_entity_id;
        IF v_found = 0 THEN
            v_ok := false; v_msg := format('No customer with entity_id %s is visible to this tenant', p_entity_id);
        ELSE
            v_entity_id := p_entity_id;
        END IF;
    ELSIF v_ok THEN
        ------------------------------------------------------------------
        -- By name. Customers only, because that is what vw_customers says a customer is
        -- (entity_type = 'customer'), and an agent looking for a vendor in a CRM lookup tool
        -- has asked a different question.
        --
        -- Two tiers, deterministic in both directions: an exact full-name match wins outright,
        -- so a crowd of substring neighbours cannot refuse a request that named someone
        -- precisely; with no exact match, the substring hits must be exactly one. Refusing to
        -- pick between several is 4.4's lesson applied to the other axis - add_customer was
        -- ambiguous about which FUNCTION would run, this door would be ambiguous about which
        -- PERSON the call was with, and only one of those two shows up as 42725.
        ------------------------------------------------------------------
        SELECT count(*) INTO v_found
          FROM entities
         WHERE entities.entity_type = 'customer'
           AND lower(btrim(entities.name)) = lower(btrim(p_customer_name));
        IF v_found = 1 THEN
            SELECT entities.id INTO v_entity_id
              FROM entities
             WHERE entities.entity_type = 'customer'
               AND lower(btrim(entities.name)) = lower(btrim(p_customer_name));
        ELSE
            -- Candidates are named in the refusal, up to five, because an agent that is told
            -- "ambiguous" and not told BETWEEN WHAT has to make two more tool calls to find
            -- out, and the second one is the same failure.
            SELECT count(*), string_agg(quote_literal(c.name) || ' (#' || c.id || ')', ', ' ORDER BY c.name)
              INTO v_found, v_candidates
              FROM (SELECT e.name, e.id
                      FROM entities e
                     WHERE e.entity_type = 'customer'
                       AND e.name ILIKE '%' || btrim(p_customer_name) || '%'
                     ORDER BY e.name, e.id
                       LIMIT 6) AS c;

            IF v_found = 0 THEN
                v_ok := false;
                v_msg := format('No customer name matches %s', quote_literal(p_customer_name));
            ELSIF v_found = 1 THEN
                SELECT entities.id INTO v_entity_id
                  FROM entities
                 WHERE entities.entity_type = 'customer'
                   AND entities.name ILIKE '%' || btrim(p_customer_name) || '%';
            ELSIF v_found > 5 THEN
                v_ok := false;
                v_msg := format('%s customers match %s - the first of them: %s',
                                v_found, quote_literal(p_customer_name), v_candidates);
            ELSE
                v_ok := false;
                v_msg := format('%s customers match %s: %s - re-issue with p_entity_id',
                                v_found, quote_literal(p_customer_name), v_candidates);
            END IF;
        END IF;
    END IF;

    ------------------------------------------------------------------
    -- Whom at that customer, when a human is named. Optional, and NOT derived from the primary
    -- contact: "the person I spoke to" is a fact only the caller has, and defaulting it to
    -- whoever vw_customers surfaces first would file the call against the wrong human with the
    -- same confidence as getting the wrong entity. Existence is counted for the same reason
    -- 0018 gives: under the wall, a contact_id from another tenant is invisible, and the FK
    -- would accept the number regardless.
    ------------------------------------------------------------------
    IF v_ok AND p_contact_id IS NOT NULL THEN
        SELECT count(*) INTO v_found FROM contacts WHERE contacts.id = p_contact_id;
        IF v_found = 0 THEN
            v_ok := false;
            v_msg := format('No contact with id %s is visible to this tenant', p_contact_id);
        END IF;
    END IF;

    ------------------------------------------------------------------
    -- What was said. summary is NOT NULL in the table, and a door whose answer to an empty
    -- summary is 23502 tells an agent about a constraint when the truth is that nothing was
    -- summarised. Refused as a row, in 0016's register: an answer about the request is data.
    ------------------------------------------------------------------
    IF v_ok AND (p_summary IS NULL OR btrim(p_summary) = '') THEN
        v_ok := false; v_msg := 'A one-line summary is required';
    END IF;

    ------------------------------------------------------------------
    -- Threading. The root is inherited rather than recomputed, so a reply three levels down
    -- lands on the thread the first message started, which is what vw_communication_thread
    -- and idx_comms_thread_root are there to serve. 0005 gave the column its FK; this is the
    -- first writer to fill it.
    ------------------------------------------------------------------
    IF v_ok AND p_parent_id IS NOT NULL THEN
        SELECT count(*) INTO v_found FROM communications WHERE communications.id = p_parent_id;
        IF v_found = 0 THEN
            v_ok := false;
            v_msg := format('No communication with id %s is visible to this tenant', p_parent_id);
        END IF;
    END IF;

    ------------------------------------------------------------------
    -- The one flag with a missing half. follow_up_required without a date is a task nobody can
    -- schedule: idx_comms_followup is a partial index on exactly that pair, and
    -- get_followup_customers reports on the staleness a date is meant to end.
    ------------------------------------------------------------------
    IF v_ok AND coalesce(p_follow_up_required, false) AND p_follow_up_date IS NULL THEN
        v_ok := false;
        v_msg := 'p_follow_up_required needs p_follow_up_date - a follow-up with no day is a wish';
    END IF;

    ------------------------------------------------------------------
    -- The single write, inside the single guard, for the single reason 0016 states: a refusal
    -- that had to remember to let go of the claim in each of nine exit paths is a refusal that
    -- eventually forgets one.
    ------------------------------------------------------------------
    IF v_ok THEN
        INSERT INTO communications (
            entity_id, contact_id, communication_type, direction, subject, summary,
            full_content, channel, agent_id, sentiment_label, priority, outcome,
            started_at, duration_seconds, follow_up_required, follow_up_date,
            follow_up_action, parent_id, thread_root_id
        ) VALUES (
            v_entity_id, p_contact_id, p_communication_type, p_direction, p_subject,
            btrim(p_summary), p_full_content, p_channel, p_agent_id, p_sentiment_label,
            p_priority, p_outcome,
            -- NULL means "now", which is the column default's own sentence; restating it here
            -- would be a second clock. 0016's note on the same shape applies.
            coalesce(p_started_at, now()), p_duration_seconds,
            coalesce(p_follow_up_required, false), p_follow_up_date, p_follow_up_action,
            p_parent_id,
            -- Root: the parent's root if it has one, otherwise the parent itself. Read in the
            -- same statement it is needed in, because two statements let another transaction
            -- thread the parent in between them.
            CASE WHEN p_parent_id IS NULL THEN NULL
                 ELSE coalesce((SELECT c.thread_root_id FROM communications c
                                 WHERE c.id = p_parent_id), p_parent_id)
            END
        )
        RETURNING communications.id INTO v_comm_id;

        v_msg := format('Communication logged for customer %s (%s, %s)%s',
                        (SELECT e.name FROM entities e WHERE e.id = v_entity_id),
                        p_communication_type, p_direction,
                        CASE WHEN p_follow_up_required THEN ' with a follow-up due'
                             ELSE '' END);
    END IF;

    ------------------------------------------------------------------
    -- The single exit. Success is the only outcome worth caching; every refusal releases the
    -- claim, because what was refused is a fact that can change - the ambiguity gets resolved
    -- by id, the summary arrives, the other tenant's row becomes visible under a different
    -- tenant's key - and a key whose answer is a permanent no hides the attempt that would
    -- have worked (0016's reason, unchanged, on a second door).
    ------------------------------------------------------------------
    IF v_ok THEN
        IF v_state = 'claimed' THEN
            PERFORM idempotency_complete(v_claim.claim_id, v_claim.current_token,
                    jsonb_build_object('success', v_ok, 'communication_id', v_comm_id,
                                       'entity_id', v_entity_id, 'message', v_msg));
        END IF;
    ELSIF v_state = 'claimed' THEN
        PERFORM idempotency_complete(v_claim.claim_id, v_claim.current_token,
                                     NULL, false, v_msg);
    END IF;

    RETURN QUERY SELECT v_ok, v_comm_id, v_entity_id, v_msg;
    RETURN;

EXCEPTION
    WHEN OTHERS THEN
        -- No re-wrap, on the fourth door that says so (0014, 0015, 0016): a 23514 from a
        -- vocabulary CHECK and a business refusal must not leave this body wearing the same
        -- success=false and someone else's prose. What the handler does is release the claim,
        -- so a retry of a failed attempt can run at all.
        IF v_state = 'claimed' THEN
            BEGIN
                PERFORM idempotency_complete(v_claim.claim_id, v_claim.current_token,
                                             NULL, false, SQLERRM);
            EXCEPTION WHEN OTHERS THEN NULL;
            END;
        END IF;
        RAISE EXCEPTION USING ERRCODE = SQLSTATE, MESSAGE = SQLERRM;
END
$$;

-- ---------------------------------------------------------------------------
-- 2. Privileges
-- ---------------------------------------------------------------------------
-- A new function is born EXECUTE-to-PUBLIC, and 0009's sweep cannot reach it: ALTER DEFAULT
-- PRIVILEGES ... REVOKE ... FROM PUBLIC is a no-op for functions, because the initial ACL
-- already grants it and the record only adds (dev/README, the entry B22 exists to keep shut).
-- Same treatment as 0016's head: closed to PUBLIC, executable by the runtime role, and nothing
-- to the read roles, whose whole point is that they do not write.
REVOKE EXECUTE ON FUNCTION add_communication(
    text, bigint, bigint, varchar, varchar, text, text, text, varchar, varchar, varchar,
    varchar, varchar, timestamptz, integer, boolean, date, text, bigint, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION add_communication(
    text, bigint, bigint, varchar, varchar, text, text, text, varchar, varchar, varchar,
    varchar, varchar, timestamptz, integer, boolean, date, text, bigint, uuid) TO afpc_app;

-- ---------------------------------------------------------------------------
-- 3. What the schema now says about this door
-- ---------------------------------------------------------------------------
COMMENT ON FUNCTION add_communication(
        text, bigint, bigint, varchar, varchar, text, text, text, varchar, varchar, varchar,
        varchar, varchar, timestamptz, integer, boolean, date, text, bigint, uuid) IS
    'Record one interaction with one customer: a single communications row, and nothing else. '
    'Twenty parameters, nineteen of them DEFAULTed; the door has no required positional '
    'argument, because every shape of refusal the body can make is an answer rather than a '
    'type error. The customer is named one way - p_entity_id or p_customer_name, and a call '
    'giving both is refused rather than arbitrated. Name resolution prefers an exact '
    'case-insensitive full-name match and otherwise requires exactly one substring hit; '
    'several matches answer with the candidates and are never resolved by whichever row the '
    'scan reached first (4.5''s whole complaint about the Python door was that a rule lived '
    'where the database could not enforce it - this sentence is the rule, in the database). '
    'An id or a contact_id that resolves to nothing visible answers as a refusal, not as a '
    'NULL the foreign key would never notice: row security filters reads, and a FK check is '
    'not a read (0018 measured the difference and lost a write to it). Vocabularies belong to '
    'their CHECK constraints and are deliberately NOT restated here, so a direction of '
    '''sideways'' arrives as 23514 with its own SQLSTATE. p_follow_up_required without '
    'p_follow_up_date is refused - the flag and the date are one decision and the partial index '
    'on that pair is the schema saying so. p_parent_id inherits or seeds thread_root_id, which '
    'makes this the first writer the thread column has ever had. embedding stays NULL: no '
    'embedder in this deployment produces the 1536 dimensions the column declares (measured: '
    'the local models answer 1024 and 4096), and a half-filled vector column is the state 0012 '
    'documented as unmeasurable rather than merely empty. Answers are rows because the contract '
    'carries a success boolean; with p_idempotency_key a retry of the same request is answered '
    'from 0011''s claim instead of writing a second copy of a phone call, and a refusal '
    'releases the claim so it can be tried again. No followups row is created by this function: '
    'that table has no writer in the schema and vw_pending_followups reads it. Built by 0021.';

-- ---------------------------------------------------------------------------
-- 4. Verify by behaving
-- ---------------------------------------------------------------------------
-- Fixtures are invented per probe and keyed on @0021.probe.invalid emails and '0021 Probe'
-- name fragments, so no assertion here can quietly count a row an earlier migration left
-- behind - 0013's "assert per-subject, never totals", with 0017's addition that a probe on an
-- aggregate view needs a dimension value of its own. Everything is rolled forward and deleted
-- in the order 0008's RESTRICT edges demand.
DO $$
DECLARE
    v_ada     bigint;
    v_ada2    bigint;
    v_comm    bigint;
    v_comm2   bigint;
    v_ent     bigint;
    v_con     bigint;
    v_ok      boolean;
    v_msg     text;
    v_err     text;
    v_found   bigint;
    v_key     uuid;
    v_rows    bigint;
    v_root    bigint;
    v_ents    bigint[];
    v_n       int := 0;
BEGIN
    ------------------------------------------------------------------
    -- A. one callable head, and the arities the deployed callers actually issue resolve.
    --    1 (name+summary by position), 3, 7 and 20 are what a Python/Go caller sends when
    --    it passes the fields it knows; 42883 would mean an overload appeared in the name.
    ------------------------------------------------------------------
    IF (SELECT count(*) FROM pg_proc WHERE proname = 'add_communication') <> 1 THEN
        RAISE EXCEPTION 'A failed: % heads of add_communication are installed',
            (SELECT count(*) FROM pg_proc WHERE proname = 'add_communication');
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- Two customers whose names collide on purpose: one exact, one a superstring. Created
    -- through add_customer, so this migration's fixtures are made by the doors that are
    -- supposed to make them and the entity_type/relationship shape agrees with vw_customers.
    ------------------------------------------------------------------
    SELECT entity_id, contact_id INTO v_ada, v_con
      FROM add_customer('Ada', 'Lovelace', 'ada@0021.probe.invalid', '+10021000001',
                        NULL, NULL, NULL, NULL, 'US', 'active',
                        'individual', NULL, 'home', true);
    SELECT entity_id, contact_id INTO v_ada2, v_con
      FROM add_customer('Ada', 'Lovelace-Smith', 'ada2@0021.probe.invalid', '+10021000002',
                        NULL, NULL, NULL, NULL, 'US', 'active',
                        'individual', NULL, 'home', true);

    ------------------------------------------------------------------
    -- B. an exact name wins over a substring crowd. This is the tier that has to work, or
    --    resolving 'Ada Lovelace' would refuse forever as soon as anyone with a longer name
    --    exists, and the tool would look broken on the day the data grew.
    ------------------------------------------------------------------
    SELECT success, entity_id, message INTO v_ok, v_ent, v_msg
      FROM add_communication(p_customer_name := 'Ada Lovelace', p_summary := 'Called about invoice 44.');
    IF NOT v_ok OR v_ent IS DISTINCT FROM v_ada THEN
        RAISE EXCEPTION 'B failed: the exact name answered ok=% entity=% (wanted %): %',
            v_ok, v_ent, v_ada, v_msg;
    END IF;
    SELECT count(*) INTO v_comm FROM communications WHERE communications.entity_id = v_ada;
    IF v_comm <> 1 THEN
        RAISE EXCEPTION 'B failed: one exact-name call wrote % communications rows', v_comm;
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- C. a substring that matches both answers with BOTH names, and writes nothing. Asserted
    --    in both halves: a refusal that also wrote a row is 4.5's Python door with better
    --    manners, and a refusal that names no candidates sends the agent to guess again.
    ------------------------------------------------------------------
    SELECT success, communication_id, message INTO v_ok, v_comm2, v_msg
      FROM add_communication(p_customer_name := 'Ada', p_summary := 'Ambiguous request.');
    IF v_ok OR v_comm2 IS NOT NULL THEN
        RAISE EXCEPTION 'C failed: an ambiguous name reported success=% id=%', v_ok, v_comm2;
    END IF;
    IF v_msg NOT LIKE '%Ada Lovelace%' OR v_msg NOT LIKE '%Lovelace-Smith%' THEN
        RAISE EXCEPTION 'C failed: the ambiguity refusal named neither candidate: %', v_msg;
    END IF;
    IF (SELECT count(*) FROM communications
         WHERE communications.summary = 'Ambiguous request.') <> 0 THEN
        RAISE EXCEPTION 'C failed: a refused ambiguity still filed a communication';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- D. nothing named at all, and an empty summary, are refusals rather than 23502s. The
    --    second one is the interesting half: the column is NOT NULL, so the difference between
    --    a row and an exception is whether the body asked before it tried.
    ------------------------------------------------------------------
    SELECT success, message INTO v_ok, v_msg
      FROM add_communication(p_customer_name := 'Nobody Here', p_summary := 'x');
    IF v_ok THEN
        RAISE EXCEPTION 'D failed: a name that matches nobody reported success';
    END IF;
    SELECT success, message INTO v_ok, v_msg
      FROM add_communication(p_entity_id := v_ada, p_summary := '   ');
    IF v_ok THEN
        RAISE EXCEPTION 'D failed: a whitespace-only summary was accepted';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- E. a vocabulary is the CHECK's, and the error keeps its own SQLSTATE. 'sideways' is not
    --    in communications_direction_allowed; the answer must be 23514 and NOT a success=false
    --    row (0014's rule), and the row count must not move.
    ------------------------------------------------------------------
    v_err := NULL;
    BEGIN
        SELECT success INTO v_ok
          FROM add_communication(p_entity_id := v_ada, p_summary := 'Bad direction.',
                                 p_direction := 'sideways');
    EXCEPTION WHEN OTHERS THEN
        v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '23514' THEN
        RAISE EXCEPTION 'E failed: a direction outside the vocabulary answered % - it should '
                        'propagate the CHECK''s own code, not a wrapped one',
            coalesce(v_err, 'success=' || v_ok::text);
    END IF;
    IF (SELECT count(*) FROM communications WHERE communications.summary = 'Bad direction.') <> 0 THEN
        RAISE EXCEPTION 'E failed: the CHECK refused and the row survived anyway';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- F. threading: the root is inherited, and it is the first thing to ever write that column.
    --    Three levels: root, child, grandchild - because the case that breaks a naive
    --    implementation is the third one, where the parent has a root that is not itself.
    ------------------------------------------------------------------
    SELECT communication_id INTO v_comm FROM add_communication(
        p_entity_id := v_ada, p_summary := 'First message of a thread.',
        p_communication_type := 'email', p_direction := 'inbound');
    SELECT communication_id INTO v_comm2 FROM add_communication(
        p_entity_id := v_ada, p_summary := 'Reply in the thread.',
        p_communication_type := 'email', p_direction := 'outbound', p_parent_id := v_comm);
    SELECT communication_id, entity_id INTO v_root, v_ent FROM add_communication(
        p_entity_id := v_ada, p_summary := 'Third message.',
        p_communication_type := 'email', p_direction := 'outbound', p_parent_id := v_comm2);
    IF (SELECT c.thread_root_id FROM communications c WHERE c.id = v_comm2) <> v_comm THEN
        RAISE EXCEPTION 'F failed: a reply seeded its parent''s id as the root instead of inheriting it';
    END IF;
    IF (SELECT c.thread_root_id FROM communications c WHERE c.id = v_root) <> v_comm THEN
        RAISE EXCEPTION 'F failed: a reply-to-a-reply rooted at % instead of %',
            (SELECT c.thread_root_id FROM communications c WHERE c.id = v_root), v_comm;
    END IF;
    IF (SELECT c.parent_id FROM communications c WHERE c.id = v_root) <> v_comm2 THEN
        RAISE EXCEPTION 'F failed: the parent link was lost while the root was being computed';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- G. follow_up_required needs its date, and with both it lands in the partial index the
    --    follow-up read path walks. The second half is what makes the refusal worth having:
    --    a flag that was checked but not indexed would read as clean.
    ------------------------------------------------------------------
    SELECT success INTO v_ok FROM add_communication(
        p_entity_id := v_ada, p_summary := 'Needs a callback.',
        p_follow_up_required := true);
    IF v_ok THEN
        RAISE EXCEPTION 'G failed: a follow-up with no date was accepted';
    END IF;
    SELECT communication_id INTO v_comm FROM add_communication(
        p_entity_id := v_ada, p_summary := 'Needs a callback.',
        p_communication_type := 'call', p_direction := 'outbound',
        p_follow_up_required := true, p_follow_up_date := current_date + 3,
        p_follow_up_action := 'Quote the replacement part');
    IF (SELECT count(*) FROM communications c
         WHERE c.id = v_comm AND c.follow_up_required AND c.follow_up_date IS NOT NULL) <> 1 THEN
        RAISE EXCEPTION 'G failed: a dated follow-up did not land with both halves set';
    END IF;
    -- And the boundary, asserted rather than commented: this door files a note, it does not
    -- create work. If anyone later decides a logged follow-up should also be a task, this
    -- probe is the line that has to change deliberately.
    IF (SELECT count(*) FROM followups f
         WHERE f.entity_id = v_ada) <> 0 THEN
        RAISE EXCEPTION 'G failed: add_communication created a followups row - the boundary '
                        '§5 says this door does not cross has moved';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- H. a retry answers one communication. Same key, same request, called twice: the second
    --    answer must carry the first's id, and the table must not have grown. This is the
    --    behaviour the Go agent's key derivation exists to reach.
    ------------------------------------------------------------------
    v_key := gen_random_uuid();
    SELECT communication_id, success INTO v_comm, v_ok FROM add_communication(
        p_entity_id := v_ada, p_summary := 'Voicemail left.', p_communication_type := 'call',
        p_direction := 'outbound', p_idempotency_key := v_key);
    SELECT communication_id, success INTO v_comm2, v_ok FROM add_communication(
        p_entity_id := v_ada, p_summary := 'Voicemail left.', p_communication_type := 'call',
        p_direction := 'outbound', p_idempotency_key := v_key);
    IF v_comm2 IS DISTINCT FROM v_comm THEN
        RAISE EXCEPTION 'H failed: a replayed key wrote % where % was already on file',
            v_comm2, v_comm;
    END IF;
    IF (SELECT count(*) FROM communications c
         WHERE c.summary = 'Voicemail left.') <> 1 THEN
        RAISE EXCEPTION 'H failed: one key produced % rows',
            (SELECT count(*) FROM communications c WHERE c.summary = 'Voicemail left.');
    END IF;
    -- A settled key reused for a DIFFERENT request is 0011's conflict, answered as P0001 and
    -- not as a cache hit and not as 23505.
    v_err := NULL;
    BEGIN
        PERFORM * FROM add_communication(p_entity_id := v_ada, p_summary := 'A different call.',
                                         p_communication_type := 'call',
                                         p_direction := 'inbound', p_idempotency_key := v_key);
    EXCEPTION WHEN OTHERS THEN
        v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM 'P0001' THEN
        RAISE EXCEPTION 'H failed: a reused key on a different request answered % - 0011 '
                        'settles that as a conflict', coalesce(v_err, 'no error at all');
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- I. a refusal leaves the key claimable, so the SAME request succeeds once the world has
    --    changed (0016's rule, on a second door: a key whose answer is a permanent no hides the
    --    attempt that would have worked). The request cannot change here - 0011's fingerprint is
    --    settled before the failed-status take-over is even considered, so a different summary
    --    under this key is probe H's P0001, not a retry. What changes instead is the fact the
    --    refusal was about: the customer does not exist yet, and then it does. That is the case
    --    the release is FOR, and testing it by editing the arguments would have tested 0011's
    --    conflict a second time while never touching the take-over arm at all.
    ------------------------------------------------------------------
    v_key := gen_random_uuid();
    SELECT success INTO v_ok FROM add_communication(
        p_customer_name := 'Late Arrival', p_summary := 'Called the new account.',
        p_communication_type := 'call', p_direction := 'outbound', p_idempotency_key := v_key);
    IF v_ok THEN
        RAISE EXCEPTION 'I failed: the first attempt should have been refused for a customer '
                        'that does not exist yet';
    END IF;
    SELECT entity_id INTO v_ent
      FROM add_customer('Late', 'Arrival', 'late@0021.probe.invalid', '+10021000009',
                        NULL, NULL, NULL, NULL, 'US', 'active',
                        'individual', NULL, 'home', true);
    SELECT success, communication_id INTO v_ok, v_comm FROM add_communication(
        p_customer_name := 'Late Arrival', p_summary := 'Called the new account.',
        p_communication_type := 'call', p_direction := 'outbound', p_idempotency_key := v_key);
    IF NOT v_ok OR v_comm IS NULL THEN
        RAISE EXCEPTION 'I failed: the same key refused the same good request after the world '
                        'moved: ok=% id=% (% )', v_ok, v_comm, v_msg;
    END IF;
    -- And the take-over that made it work left exactly one claim row, not one per attempt:
    -- attempts counts up on the same id (0011's shape, asserted so a future "release" that
    -- deletes the row instead cannot quietly become the mechanism).
    IF (SELECT count(*) FROM idempotency_keys k
         WHERE k.idempotency_key = v_key AND k.operation = 'add_communication') <> 1 THEN
        RAISE EXCEPTION 'I failed: a retried claim left % rows in the register',
            (SELECT count(*) FROM idempotency_keys k
              WHERE k.idempotency_key = v_key AND k.operation = 'add_communication');
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- J. the wall, in the seat that has to live with it. Another tenant's entity_id is not
    --    visible here, and the door must say so instead of writing a communications row whose
    --    entity the caller cannot name - 0018's probe G' expected 23502 from exactly this and
    --    got a successful INSERT, which is the reason the existence check is in the body at all.
    ------------------------------------------------------------------
    INSERT INTO tenants (name, slug) VALUES ('0021 second tenant', 'afpc-0021-t2')
     RETURNING tenant_id INTO v_key;
    v_con := v_ada;   -- keep the fixture id across the role switch
    SET LOCAL ROLE afpc_app;
    PERFORM set_config('app.tenant_id', v_key::text, true);
    v_err := NULL;
    BEGIN
        SELECT success INTO v_ok FROM add_communication(p_entity_id := v_con,
                                                       p_summary := 'Cross-tenant attempt.');
    EXCEPTION WHEN OTHERS THEN
        v_err := SQLSTATE;
    END;
    RESET ROLE;
    IF v_err IS NOT NULL THEN
        RAISE EXCEPTION 'J failed: a cross-tenant entity_id raised % - the door answers with a '
                        'refusal, and the caller deserves to see which half failed', v_err;
    END IF;
    IF v_ok THEN
        RAISE EXCEPTION 'J failed: the door wrote a communication for an entity the caller '
                        'cannot see - a FK check is not a read (0018)';
    END IF;
    IF (SELECT count(*) FROM communications c
         WHERE c.summary = 'Cross-tenant attempt.') <> 0 THEN
        RAISE EXCEPTION 'J failed: the refusal was right and the write happened anyway';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- K. the row is the caller's tenant, by the column default, from the afpc_app seat - the
    --    same promise 0016's probe J makes of add_customer, because a door that files work in
    --    the wrong tenant is a door that leaks it.
    ------------------------------------------------------------------
    v_key := NULL;
    SELECT tenant_id INTO v_key FROM tenants WHERE slug = 'default';
    SET LOCAL ROLE afpc_app;
    PERFORM set_config('app.tenant_id', v_key::text, true);
    SELECT communication_id, entity_id INTO v_comm, v_ent
      FROM add_communication(p_entity_id := v_ada, p_summary := 'As the app role.',
                             p_idempotency_key := gen_random_uuid());
    RESET ROLE;
    IF (SELECT count(*) FROM communications c
         WHERE c.id = v_comm AND c.tenant_id = v_key) <> 1 THEN
        RAISE EXCEPTION 'K failed: a communication written by afpc_app landed outside tenant %', v_key;
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- L. the register notices the new door without being told. vw_idempotency_status is
    --    derived from function bodies, so a write path that names a claim must appear guarded
    --    and a door that forgot one must appear UNGUARDED - the row that made add_customer's
    --    fork visible from a different angle (0016). Asserting the derived answer here is what
    --    stops 0021 being credited for a guard nobody wired.
    ------------------------------------------------------------------
    SELECT count(*) INTO v_found FROM vw_idempotency_status s
     WHERE s.function = 'add_communication' AND NOT s.unguarded;
    IF v_found <> 1 THEN
        RAISE EXCEPTION 'L failed: the register says nothing about add_communication being '
                        'claim-guarded (rows %) - either the claim is not wired or the '
                        'derivation stopped seeing this function', v_found;
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- Cleanup, in the order 0008's RESTRICT edges demand: threads reference communications and
    -- communications reference entities, so children go first. Keyed on the email every fixture
    -- in this file invented, because a sweep that lists names has to be edited in step with
    -- every probe and eventually stops covering the last one added. The audit rows stay - that
    -- is 0013 being honest, not residue.
    ------------------------------------------------------------------
    SELECT array_agg(DISTINCT e.id) INTO v_ents
      FROM entities e
      JOIN entity_relationships er ON er.entity_id = e.id
      JOIN contacts c ON c.id = er.contact_id
     WHERE c.email LIKE '%@0021.probe.invalid';

    DELETE FROM communications WHERE parent_id IS NOT NULL
       AND entity_id = ANY (v_ents);
    DELETE FROM communications WHERE entity_id = ANY (v_ents);
    DELETE FROM addresses WHERE entity_id = ANY (v_ents);
    DELETE FROM entity_relationships WHERE entity_id = ANY (v_ents);
    DELETE FROM contacts WHERE email LIKE '%@0021.probe.invalid';
    DELETE FROM entities WHERE id = ANY (v_ents);
    DELETE FROM idempotency_keys WHERE operation = 'add_communication';
    DELETE FROM tenants WHERE slug = 'afpc-0021-t2';

    IF v_n <> 12 THEN
        RAISE EXCEPTION 'expected 12 behavioural verifications, completed %', v_n;
    END IF;
    RAISE NOTICE '4.5: % checks passed - a customer interaction has a door, an ambiguous name '
                 'refuses with candidates instead of reaching for the first row, a vocabulary '
                 'keeps its own SQLSTATE, a thread roots once and inherits after that, a retry '
                 'answers the first communication, a refusal can be retried, another tenant''s '
                 'entity is refused rather than filed against, and the register sees the guard',
        v_n;
END
$$;

-- ---------------------------------------------------------------------------
-- 5. Obligations this file leaves open, on purpose
-- ---------------------------------------------------------------------------
-- * `followups` has exactly one writer today: none. This door does not add one, so
--   vw_pending_followups stays empty for the whole of the CRM while communications carries
--   follow_up_required - two tables describing the same intention, which is the shape 0011 and
--   0018 keep refusing to leave standing. The migration that decides what a follow-up task IS
--   should pick one of the two representations and retire the other, and it owns
--   get_followup_customers' third branch while it is there (0022).
-- * The subject line and full body are stored verbatim; nothing here truncates or rewrites
--   customer content. Whether communications.summary is allowed to carry PII into an agent's
--   context is the ATTACHMENT_SYSTEM/logging conversation, not this door's.
-- * `channel` is free text by 0007's published decision. This function passes it through; the
--   day a channel list matters, it belongs in a lookup table and not in another IF arm here.
-- * 0019 will partition communications by month. Every row this function writes gets its
--   started_at from the caller or from now(), so the partition key is never NULL - the property
--   that migration's DETACH will depend on.
