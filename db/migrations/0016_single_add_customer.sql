-- 0016: one add_customer, so the CRM's main write path has one meaning and a retry has one
--       (DATABASE_REVIEW.md 4.4; Obligations-0011's first CRM head)
--
-- What the file found, measured rather than assumed:
--
--   * Two heads, and neither is the one the review thought was newer. `0001` ported both
--     because §3.3's forked SQL directories both defined the function - `scripts/database/
--     09_customer_functions.sql` (10 parameters) and `agent_swarm_schema.sql` (14). The
--     14-parameter head is a superset: same first ten positions, same names, plus the
--     individual/business split. The 10-parameter head is the older CRM-only body, which
--     has no organization path, no address_type, and a single merged duplicate check.
--   * "Every parameter is defaultable" is not why it is ambiguous, and the correction matters.
--     In the 10-parameter head the FIRST FOUR parameters are not defaultable - measured from
--     pg_proc's proargdefaults. Ambiguity is about how many positions each CANDIDATE accepts,
--     not about whether the call is complete: both candidates accept 10 positions, so a
--     10-argument call has two winners; and both accept 4 as well (in the 14-parameter head
--     everything after p_first_name is defaulted), so the shortest CRM call fails the same way.
--     The only arities that resolve today are 11 through 14. 0009's block F and 5_1's probe
--     both discovered this while trying to do something else, and 5_1 reports it as INFO rather
--     than claim a pass it did not earn.
--   * The register prints add_customer TWICE, both UNGUARDED. That is not a view bug - it is
--     one row per function object, and there are two objects. So 4.4 was visible in the
--     idempotency register before it was visible in the call path: a domain function with two
--     rows is a fork that came back inside the canonical schema.
--   * The head that survives needs a claim, and this door is the one ADR-005 was written for.
--     0011 chose pattern 2 over pattern 1 by measuring that no unique index on email exists
--     anywhere (contacts.email has a trigram GIN for ILIKE, not a constraint) - so the
--     duplicate check is a read followed by a write with nothing between them. Measured with
--     two backends on a clone, one second apart against one email: with no key, BOTH returned
--     success and the database kept 2 entities and 2 contacts for one request. With a key, ONE
--     customer exists and both callers were answered with the same entity_id - the second
--     attempt's claim INSERT waited on the arbiter's unique index, and by the time it resumed
--     the first had committed status 'completed', so it was answered from the cache instead of
--     refused. That waiting is not something this file designed; it is what 0011's arbiter does
--     when two transactions reach the same key at the same moment, and it is the first
--     measurement here showing the claim guarding a race rather than only a retry. A keyless
--     pair still races, because a claim only serialises the callers who take one - which is
--     Obligations-0011's unfinished half, and §4's probes assert the sequential form because a
--    second backend cannot exist inside a migration.
--   * The two duplicate checks are written to two different rules. Email: `ILIKE`. Phone:
--     `=`. Measured - a contact existing as 'Ada@Example.invalid' is refused when asked for
--     as 'ada@example.invalid', while the same person entered as '+1 555 0100' and
--     '555-0100' is created twice. This is not 4.4, and fixing it here would change who the
--     database believes is the same human without saying so anywhere; probe I measures both
--     halves and Obligations-0016 hands the decision to whoever normalises contact identity.

SET client_min_messages TO notice;

-- ---------------------------------------------------------------------------
-- 1. One head
-- ---------------------------------------------------------------------------
-- Both old heads are dropped by full signature and one is created, because CREATE OR REPLACE
-- with a fifteenth parameter would not have replaced anything: it would have added a THIRD
-- overload and made 4.4 worse in a new way (0014's rehearsal paid for that lesson, 0015's §2
-- reused it, and probe A counts heads again here because the failure mode is invisible until
-- a call goes ambiguous).
DROP FUNCTION IF EXISTS add_customer(
    text, text, text, text, text, text, text, text, text, text);
DROP FUNCTION IF EXISTS add_customer(
    text, text, text, text, text, text, text, text, text, text, text, text, text, boolean);

CREATE OR REPLACE FUNCTION add_customer(
    p_first_name        text DEFAULT NULL::text,
    p_last_name         text DEFAULT NULL::text,
    p_email             text DEFAULT NULL::text,
    p_phone             text DEFAULT NULL::text,
    p_street            text DEFAULT NULL::text,
    p_city              text DEFAULT NULL::text,
    p_state             text DEFAULT NULL::text,
    p_postal_code       text DEFAULT NULL::text,
    p_country           text DEFAULT 'US'::text,
    p_status            text DEFAULT 'active'::text,
    p_entity_type       text DEFAULT 'individual'::text,
    p_organization_name text DEFAULT NULL::text,
    p_address_type      text DEFAULT 'home'::text,
    p_is_primary        boolean DEFAULT true,
    p_idempotency_key   uuid  DEFAULT NULL
) RETURNS TABLE(success boolean, entity_id bigint, contact_id bigint, message text)
LANGUAGE plpgsql AS $$
DECLARE
    v_entity_id  bigint;
    v_contact_id bigint;
    v_found      bigint;
    v_claim      record;
    v_state      text := '';
    v_ok         boolean := true;
    v_msg        text;
BEGIN
    ------------------------------------------------------------------
    -- ADR-005 pattern 2 at the head, which is what Obligations-0011 asked of the CRM's
    -- write path and what turns the register's UNGUARDED row into a fact. The fingerprint
    -- covers the fourteen business arguments and not the key: two calls that would create
    -- the same customer are the same operation, and a call that differs in any of them is
    -- a DIFFERENT request wearing someone else's key (0011's conflict, probe D).
    ------------------------------------------------------------------
    IF p_idempotency_key IS NOT NULL THEN
        SELECT * INTO v_claim FROM idempotency_claim(
            p_idempotency_key, 'add_customer',
            jsonb_build_object(
                'first', p_first_name, 'last', p_last_name, 'email', p_email,
                'phone', p_phone, 'street', p_street, 'city', p_city,
                'state', p_state, 'postal', p_postal_code, 'country', p_country,
                'status', p_status, 'entity_type', p_entity_type,
                'org', p_organization_name, 'addr_type', p_address_type,
                'primary', p_is_primary));
        v_state := v_claim.claim_state;
        IF v_state = 'replay' THEN
            success      := (v_claim.cached_response ->> 'success')::boolean;
            entity_id    := (v_claim.cached_response ->> 'entity_id')::bigint;
            contact_id   := (v_claim.cached_response ->> 'contact_id')::bigint;
            message      := v_claim.cached_response ->> 'message';
            RETURN NEXT;
            RETURN;
        ELSIF v_state = 'in_progress' THEN
            RAISE EXCEPTION 'add_customer: an attempt with key % is already in flight',
                p_idempotency_key
                USING ERRCODE = '40001',
                      HINT = 'the lease expires and a take-over rotates the token (0011)';
        ELSIF v_state = 'conflict' THEN
            -- P0001, the code 0015's two doors answer with, and deliberately not 23505: no
            -- unique index was violated here, and a caller that maps SQLSTATEs to messages
            -- should not learn that contacts.email is constrained when it is not (0011
            -- measured that it is not, which is the reason pattern 2 is on this door at all).
            RAISE EXCEPTION 'add_customer: key % was settled for a DIFFERENT request (fingerprint mismatch)',
                p_idempotency_key
                USING ERRCODE = 'P0001',
                      HINT = 'a caller''s idempotency key names one customer; never reuse one across requests';
        END IF;
    END IF;

    ------------------------------------------------------------------
    -- Which kind of customer. The pair lives in no column: entities.entity_type is a
    -- different axis ({customer, prospect, vendor, employee} - what the row IS to the
    -- ledger), while p_entity_type says whether the contact is a person or an
    -- organisation, and the only place its domain is written down today is two IF arms and
    -- one Python tool (blueprint/tools/add_customer.py refuses a third value before the
    -- call). A rule that exists only in a caller is a rule the database does not have, so
    -- the body states it; there is nothing in the catalog to derive it from, and §6's
    -- comment says so instead of pretending the guard was read from a constraint.
    ------------------------------------------------------------------
    IF p_entity_type IS NULL OR p_entity_type NOT IN ('individual', 'business') THEN
        RAISE EXCEPTION 'add_customer: p_entity_type % is neither individual nor business',
            coalesce(quote_nullable(p_entity_type), 'NULL')
            USING ERRCODE = '22023',
                  HINT = 'entities.entity_type is a different axis (customer/prospect/vendor/employee)';
    END IF;

    ------------------------------------------------------------------
    -- Refusals stay rows. This function's contract has a success boolean, so a business
    -- refusal is data the caller branches on - which is not the same thing as 0014/0015's
    -- argument against an ERROR status: an answer about the request is a row, the absence
    -- of an answer is an exception. Every refusal below releases the claim rather than
    -- caching itself, so the request can be tried again once the world has changed.
    ------------------------------------------------------------------
    IF p_entity_type = 'individual' THEN
        IF p_first_name IS NULL OR p_first_name = '' THEN
            v_ok := false; v_msg := 'First name is required for individual customers';
        ELSIF p_last_name IS NULL OR p_last_name = '' THEN
            v_ok := false; v_msg := 'Last name is required for individual customers';
        END IF;
    ELSIF p_organization_name IS NULL OR p_organization_name = '' THEN
        v_ok := false; v_msg := 'Organization name is required for business customers';
    END IF;

    IF v_ok AND (p_email IS NULL OR p_email = '') AND (p_phone IS NULL OR p_phone = '') THEN
        v_ok := false; v_msg := 'At least one of email or phone is required';
    END IF;

    -- The two reads the claim cannot make atomic. Each counts instead of fetching a row:
    -- the answer is a yes and the row is someone else's tenant or an arbitrary one of
    -- several. ILIKE on email is 5.9's rule (case is not identity), and it is what the
    -- trigram index on contacts.email is there to serve; the phone comparison is the same
    -- rule NOT applied, which §5 measures rather than quietly repairs.
    IF v_ok AND p_email IS NOT NULL AND p_email <> '' THEN
        SELECT count(*) INTO v_found FROM contacts WHERE email ILIKE p_email;
        IF v_found > 0 THEN
            v_ok := false; v_msg := 'A contact with this email already exists';
        END IF;
    END IF;

    IF v_ok AND p_phone IS NOT NULL AND p_phone <> '' THEN
        SELECT count(*) INTO v_found FROM contacts WHERE phone = p_phone;
        IF v_found > 0 THEN
            v_ok := false; v_msg := 'A contact with this phone number already exists';
        END IF;
    END IF;

    ------------------------------------------------------------------
    -- Nothing above decided a refusal, so this is where the database changes. Every write
    -- is inside one guard because there is exactly one place in the body that knows whether
    -- a claim is being answered or released: a refusal that had to remember to let go of the
    -- claim in each of six exit paths is a refusal that would eventually forget one.
    ------------------------------------------------------------------
    IF v_ok THEN
        ------------------------------------------------------------------
        -- Three rows for an individual, four with an address. The explicit NOW()s the ported
        -- body carried are gone: created_at has had a column default since 0001 and 0010's
        -- trigger owns updated_at, so a timestamp in the statement was a second place for a
        -- fact the schema already states.
        ------------------------------------------------------------------
        INSERT INTO entities (entity_type, name, status)
        VALUES ('customer',
                CASE WHEN p_entity_type = 'business'
                     THEN trim(p_organization_name)
                     ELSE trim(p_first_name || ' ' || p_last_name) END,
                p_status)
        -- Qualified. Nothing here collides the way 0015's reservation_id did - that INSERT's
        -- RETURNING target was also an OUT column, and plpgsql bound the name to the variable
        -- (42702). The qualification is what keeps this statement honest if a column is ever
        -- also an OUT name.
        RETURNING entities.id INTO v_entity_id;

        -- The contact and the relationship, branching exactly as the surviving head did, which is
        -- not the branching a reader would expect. A business WITH a named human gets role
        -- 'Customer' - the value an individual gets - and only a business with no named human gets
        -- 'Business Contact', on a contact whose name columns are empty strings. So the column
        -- records "was a person named at creation", not what the relationship is, and
        -- entity_relationships.role has no vocabulary to argue with it (0007 published it as free
        -- text: "a job title, not a code"). Normalising it would move rows that
        -- vw_entity_contact_details and update_customer already read, so 0016 preserves the
        -- behaviour and probe E pins all three shapes. If a later migration takes the role axis
        -- seriously, that is a decision in its own file, with the views in the same commit.
        IF p_entity_type = 'individual'
           OR (p_entity_type = 'business'
               AND (p_first_name IS NOT NULL OR p_last_name IS NOT NULL)) THEN
            INSERT INTO contacts (first_name, last_name, email, phone, status)
            VALUES (coalesce(p_first_name, ''), coalesce(p_last_name, ''),
                    p_email, p_phone, 'active')
            RETURNING contacts.id INTO v_contact_id;

            INSERT INTO entity_relationships (entity_id, contact_id, role, is_primary)
            VALUES (v_entity_id, v_contact_id, 'Customer', true);
        ELSE
            -- A business with no named human: the contact row exists because email and phone live
            -- on contacts, not because anyone is here. Empty strings rather than NULLs because
            -- that is what the head being collapsed wrote, and a report that coalesced the two
            -- would change on the strength of the difference.
            INSERT INTO contacts (first_name, last_name, email, phone, status)
            VALUES ('', '', p_email, p_phone, 'active')
            RETURNING contacts.id INTO v_contact_id;

            INSERT INTO entity_relationships (entity_id, contact_id, role, is_primary)
            VALUES (v_entity_id, v_contact_id, 'Business Contact', true);
        END IF;

        -- The address, kept as the surviving head had it: a row when any of the four street-ish
        -- fields is present, so a phone-only customer stays a three-row write rather than gaining
        -- an empty address. p_address_type and p_is_primary are the two parameters the 10-parameter
        -- head could not express, and they are why that head is the one being dropped.
        IF p_street IS NOT NULL OR p_city IS NOT NULL OR p_state IS NOT NULL
           OR p_postal_code IS NOT NULL THEN
            INSERT INTO addresses (entity_id, contact_id, address_type, street, city, state,
                                   postal_code, country, is_primary)
            VALUES (v_entity_id, v_contact_id, p_address_type, p_street, p_city, p_state,
                    p_postal_code, p_country, p_is_primary);
        END IF;
    END IF;

    ------------------------------------------------------------------
    -- The single exit. Success is the only outcome worth caching, so it is the only one that
    -- completes the claim; every refusal releases it, because the thing being refused is a
    -- fact that can change (the duplicate gets deleted, the missing name arrives) and a key
    -- whose answer is a permanent no hides the attempt that would have worked.
    ------------------------------------------------------------------
    IF v_ok THEN
        v_msg := CASE WHEN p_entity_type = 'business'
                      THEN 'Business customer added successfully: ' || p_organization_name
                      ELSE 'Customer added successfully: '
                           || trim(p_first_name || ' ' || p_last_name) END;
        IF v_state = 'claimed' THEN
            PERFORM idempotency_complete(v_claim.claim_id, v_claim.current_token,
                    jsonb_build_object('success', v_ok, 'entity_id', v_entity_id,
                                       'contact_id', v_contact_id, 'message', v_msg));
        END IF;
    ELSIF v_state = 'claimed' THEN
        PERFORM idempotency_complete(v_claim.claim_id, v_claim.current_token,
                                     NULL, false, v_msg);
    END IF;

    RETURN QUERY SELECT v_ok, v_entity_id, v_contact_id, v_msg;
    RETURN;

EXCEPTION
    WHEN OTHERS THEN
        -- The re-wrap is gone, and this is its third appearance in three migrations: 0014
        -- deleted it from execute_inventory_movement, 0015 from reserve_inventory_for_order,
        -- and this body had the same WHEN OTHERS returning a row whose only evidence of
        -- failure is a string starting 'Error adding customer: '. The FK on a missing
        -- tenant, the CHECK on a status outside entities.status, the 40001 of a live lease
        -- and a deadlock all arrived here and left as success=false plus someone else's
        -- message. Callers that branch on success still can, because refusals are rows;
        -- they simply cannot mistake a database fact for a business answer.
        --
        -- What the handler keeps doing is releasing the claim, so a retry of a failed
        -- attempt can run at all (0011: a claim left in_flight is a lease, and a lease that
        -- nothing settles is a door that stays shut until it expires).
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
-- 2. Privileges, and what the register now says
-- ---------------------------------------------------------------------------
-- The surviving head is a NEW object, so it is born EXECUTE-to-PUBLIC and B22 will name it
-- the same day if this section forgets. Both dropped heads had exactly one grant beyond the
-- owner (afpc_app), which is what the new head gets; the read roles get nothing, because this
-- function's whole purpose is writing.
REVOKE EXECUTE ON FUNCTION add_customer(
    text, text, text, text, text, text, text, text, text, text, text, text, text, boolean,
    uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION add_customer(
    text, text, text, text, text, text, text, text, text, text, text, text, text, boolean,
    uuid) TO afpc_app;

-- ---------------------------------------------------------------------------
-- 3. What the schema now says about itself
-- ---------------------------------------------------------------------------
COMMENT ON FUNCTION add_customer(
        text, text, text, text, text, text, text, text, text, text, text, text, text, boolean,
        uuid) IS
    'Create a customer: one entities row (entity_type always customer), one contacts row, one '
    'entity_relationships row, and one addresses row when any street-ish field is given. '
    'Fifteen parameters: the fourteen the surviving 14-parameter head had, all DEFAULTed, plus '
    'p_idempotency_key. Before this file the name had TWO heads (10 and 14 parameters, both '
    'ported by 0001 from the two SQL files that defined them), and any call of 10 or fewer '
    'positions was ambiguous - 42725 - because both candidates accept those positions. '
    'individual/business is chosen by p_entity_type, whose domain is these two words and lives '
    'in no column (entities.entity_type is the other axis: what the row is to the ledger); '
    'anything else is refused as 22023 rather than falling through to the individual branch. '
    'Answers are rows because the contract has a success boolean: missing required fields, an '
    'email or phone already on file, and the created case all return (success, entity_id, '
    'contact_id, message). Errors are not answers and keep their SQLSTATE - this body used to '
    'end in WHEN OTHERS returning success=false and ''Error adding customer: '' || SQLERRM, '
    'which is the re-wrap 0014 and 0015 deleted from the inventory doors and it made a '
    'constraint violation indistinguishable from a business refusal. With p_idempotency_key a '
    'retry of the same request is answered from the claim instead of writing a second '
    'customer (ADR-005 pattern 2, and the mechanism 0011 chose precisely because no unique '
    'index on email exists to arbitrate it - the duplicate checks here are reads, so without a '
    'key two concurrent calls both pass them). A refusal releases the claim rather than caching '
    'itself: the duplicate may be deleted, and a key whose answer is a permanent no is a key '
    'that hides the second attempt. Built by 0001, collapsed and claimed by 0016.';

-- ---------------------------------------------------------------------------
-- 4. Verify by behaving
-- ---------------------------------------------------------------------------
-- The seat rule the last six migrations obeyed: a control is checked in the seat it binds.
-- 4.4 is a call-resolution finding, so the first probes are about arities; the claim probes
-- follow 0011 and 0015's shapes; the last one sits in afpc_app, because a duplicate check that
-- runs under forced row security is a different promise than one that runs as the owner.
DO $$
DECLARE
    v_one     uuid;
    v_ent     bigint;
    v_con     bigint;
    v_msg     text;
    v_ok      boolean;
    v_rows    bigint;
    v_err     text;
    v_key     uuid;
    v_state   text;
    v_second  bigint;
    v_found   bigint;
    v_ents    bigint[];
    v_n       int := 0;
    v_r       record;
BEGIN
    ------------------------------------------------------------------
    -- A. one callable head, and every arity the tree actually issues resolves. The four
    --    forms are not arbitrary: 4 and 10 are what the review's repro and the pre-0016
    --    5_1 probe pass, 11 is 0009's block F working around the ambiguity, 14 is the
    --    blueprint tool. All four used to be two winners; 11 to 14 were the only ones that
    --    resolved, which is why the finding read as "cannot be called" rather than "cannot
    --    be called shortly".
    ------------------------------------------------------------------
    IF (SELECT count(*) FROM pg_proc WHERE proname = 'add_customer') <> 1 THEN
        RAISE EXCEPTION 'A failed: % heads of add_customer are installed - a collapse that '
                        'CREATEs without DROPping is a third overload, which is 4.4 wearing '
                        'the fix''s own clothes',
            (SELECT count(*) FROM pg_proc WHERE proname = 'add_customer');
    END IF;

    FOR v_r IN SELECT * FROM (VALUES
            (4), (10), (11), (14)
        ) AS t(arity)
    LOOP
        v_err := NULL;
        BEGIN
            -- Each arity in its own nested block; a failure is reported with the position
            -- count that caused it, because "the call went ambiguous" is the finding and the
            -- arity is the evidence.
            IF v_r.arity >= 4  THEN
                SELECT success, entity_id INTO v_ok, v_ent
                  FROM add_customer('A' || v_r.arity, 'B',
                                    'ar' || v_r.arity || '@probe.invalid', '111' || v_r.arity);
            END IF;
            IF v_r.arity >= 10 THEN
                SELECT success, entity_id INTO v_ok, v_ent
                  FROM add_customer('A', 'B', 'x' || v_r.arity || '@probe.invalid', '222' || v_r.arity,
                                    NULL, NULL, NULL, NULL, 'US', 'active');
            END IF;
            IF v_r.arity >= 11 THEN
                SELECT success, entity_id INTO v_ok, v_ent
                  FROM add_customer('A', 'B', 'y' || v_r.arity || '@probe.invalid', '333' || v_r.arity,
                                    NULL, NULL, NULL, NULL, 'US', 'active', 'individual');
            END IF;
            IF v_r.arity >= 14 THEN
                SELECT success, entity_id INTO v_ok, v_ent
                  FROM add_customer('A', 'B', 'z' || v_r.arity || '@probe.invalid', '444' || v_r.arity,
                                    NULL, NULL, NULL, NULL, 'US', 'active',
                                    'individual', NULL, 'home', true);
            END IF;
        EXCEPTION WHEN OTHERS THEN
            v_err := SQLSTATE;
        END;
        IF v_err IS NOT NULL THEN
            RAISE EXCEPTION 'A failed: a %-position call answered % - the ambiguity is '
                            'resolved only for the arities someone happened to test',
                v_r.arity, v_err;
        END IF;
        IF NOT v_ok THEN
            RAISE EXCEPTION 'A failed: a %-position call resolved but was refused (%): the '
                            'arities have to come back as customers, not as answers that look '
                            'like the ambiguity this file removes', v_r.arity, v_msg;
        END IF;
    END LOOP;
    -- (probe A's rows go in the tail sweep, keyed on their emails like everything else)
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- B. the register says one thing about this name now, and it says pattern 2. Before
    --    0016 it printed TWO rows, both UNGUARDED - which was the finding showing through a
    --    different view: one row per function object, and there were two objects.
    ------------------------------------------------------------------
    SELECT count(*) INTO v_rows FROM vw_idempotency_status WHERE function = 'add_customer';
    IF v_rows <> 1 THEN
        RAISE EXCEPTION 'B failed: the operations register prints % rows for add_customer - '
                        'the collapse is not visible where the register counts objects', v_rows;
    END IF;
    SELECT max(verdict) INTO v_state FROM vw_idempotency_status WHERE function = 'add_customer';
    IF v_state NOT LIKE 'ADR-005 pattern 2%' THEN
        RAISE EXCEPTION 'B failed: the register calls the CRM''s main write path % - a claim '
                        'is at the head, so the verdict is derived from something that exists',
            v_state;
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- C. a keyed retry of the same request is ONE customer. This is the whole reason the
    --    claim is here rather than only on the inventory doors: the duplicate checks are
    --    reads, there is no unique index behind either, so a retry - or a second agent asking
    --    for the same person - used to produce two entities, two contacts, two relationships.
    ------------------------------------------------------------------
    v_key   := gen_random_uuid();
    SELECT success, entity_id, contact_id INTO v_ok, v_ent, v_con
      FROM add_customer('Retria', 'Vault', 'retria@probe.invalid', '555-0001',
                        NULL, NULL, NULL, NULL, 'US', 'active',
                        'individual', NULL, 'home', true, v_key);
    IF NOT v_ok OR v_ent IS NULL THEN
        RAISE EXCEPTION 'C failed: the first keyed call did not create a customer (% %)', v_ok, v_msg;
    END IF;
    SELECT success, entity_id, contact_id INTO v_ok, v_second, v_con
      FROM add_customer('Retria', 'Vault', 'retria@probe.invalid', '555-0001',
                        NULL, NULL, NULL, NULL, 'US', 'active',
                        'individual', NULL, 'home', true, v_key);
    IF NOT v_ok OR v_second IS DISTINCT FROM v_ent OR v_con IS NULL THEN
        RAISE EXCEPTION 'C failed: the replay answered entity % (contact %) against the cached '
                        '% - the retry wrote a second customer or the cached row lost an id',
            v_second, v_con, v_ent;
    END IF;
    SELECT count(*) INTO v_rows FROM entities WHERE name = 'Retria Vault';
    IF v_rows <> 1 THEN
        RAISE EXCEPTION 'C failed: a keyed pair of calls created % entities, not 1', v_rows;
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- D. a refusal releases the claim instead of caching itself. The duplicate is removed
    --    between the two attempts, which is the case that makes the difference real: a key
    --    whose answer is a permanent no would refuse the second call after the obstacle is
    --    gone, and the caller would never learn that it can now succeed.
    ------------------------------------------------------------------
    -- The obstacle first, and inserted directly rather than through this door: a contact can
    -- appear that way (that is why the duplicate check is a read and not a key), and a probe
    -- that reserved the email with add_customer would be testing one call against itself.
    INSERT INTO entities (entity_type, name, status)
         VALUES ('customer', 'Obstacle Person', 'active') RETURNING id INTO v_ent;
    INSERT INTO contacts (first_name, last_name, email, phone, status)
         VALUES ('Obstacle', 'Person', 'dup@probe.invalid', NULL, 'active')
     RETURNING id INTO v_found;
    INSERT INTO entity_relationships (entity_id, contact_id, role, is_primary)
         VALUES (v_ent, v_found, 'Customer', true);

    v_key := gen_random_uuid();
    SELECT success INTO v_ok
      FROM add_customer('New', 'Person', 'dup@probe.invalid', NULL,
                        NULL, NULL, NULL, NULL, 'US', 'active',
                        'individual', NULL, 'home', true, v_key);
    IF v_ok THEN
        RAISE EXCEPTION 'D failed: an email already on contacts created a second customer - '
                        'the duplicate read is not the guard it is written to be';
    END IF;
    IF (SELECT count(*) FROM idempotency_keys
         WHERE idempotency_key = v_key AND status = 'in_flight') <> 0 THEN
        RAISE EXCEPTION 'D failed: the refusal left its claim in flight - releasing it is the '
                        'half of ADR-005 that makes a retry possible at all';
    END IF;

    DELETE FROM entity_relationships WHERE contact_id = v_found;
    DELETE FROM contacts WHERE id = v_found;
    DELETE FROM entities WHERE id = v_ent;

    SELECT success, entity_id INTO v_ok, v_second
      FROM add_customer('New', 'Person', 'dup@probe.invalid', NULL,
                        NULL, NULL, NULL, NULL, 'US', 'active',
                        'individual', NULL, 'home', true, v_key);
    IF NOT v_ok THEN
        RAISE EXCEPTION 'D failed: after the obstacle was deleted the same key still refused '
                        '(% is %) - a refusal was cached as an answer, which is how a claim '
                        'becomes a tombstone', v_ok, v_second;
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- E. one key, two different customers: the fingerprint makes it a conflict, and the
    --    conflict propagates rather than answering as a refusal row. A caller that reuses a
    --    key for someone else must not get a quiet no.
    ------------------------------------------------------------------
    v_key := gen_random_uuid();
    SELECT success INTO v_ok FROM add_customer('First', 'One', 'k1@probe.invalid', NULL,
                        NULL, NULL, NULL, NULL, 'US', 'active',
                        'individual', NULL, 'home', true, v_key);
    v_err := NULL;
    BEGIN
        SELECT success INTO v_ok FROM add_customer('Second', 'Two', 'k2@probe.invalid', NULL,
                        NULL, NULL, NULL, NULL, 'US', 'active',
                        'individual', NULL, 'home', true, v_key);
    EXCEPTION WHEN OTHERS THEN
        v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM 'P0001' THEN
        RAISE EXCEPTION 'E failed: the same key on a different request answered % - 0011''s '
                        'fingerprint is supposed to make that a conflict, loudly, with the '
                        'SQLSTATE 0015''s two doors already use for it',
            coalesce(v_err, 'a row (the second customer was created)');
    END IF;
    IF (SELECT count(*) FROM entities WHERE name IN ('First One', 'Second Two')) <> 1 THEN
        RAISE EXCEPTION 'E failed: a key reused across two requests wrote % customers',
            (SELECT count(*) FROM entities WHERE name IN ('First One', 'Second Two'));
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- F. the three write shapes the head can produce, pinned because 0016 collapses an
    --    overload rather than rewriting a policy: an individual, a business WITH a named
    --    human (role 'Customer' - the surprising one, and surprising enough to assert), and a
    --    business with no named human ('Business Contact' on a contact with empty names).
    ------------------------------------------------------------------
    SELECT entity_id, contact_id INTO v_ent, v_con
      FROM add_customer('Ada', 'Lovelace', 'ada@probe.invalid', '555-0101',
                        '1 Analytical Way', 'London', NULL, NULL, 'US', 'active',
                        'individual', NULL, 'home', true);
    IF (SELECT count(*) FROM addresses WHERE entity_id = v_ent) <> 1 THEN
        RAISE EXCEPTION 'F failed: an individual with a street wrote % address rows',
            (SELECT count(*) FROM addresses WHERE entity_id = v_ent);
    END IF;
    IF (SELECT role FROM entity_relationships WHERE contact_id = v_con) <> 'Customer' THEN
        RAISE EXCEPTION 'F failed: an individual got role %',
            (SELECT role FROM entity_relationships WHERE contact_id = v_con);
    END IF;

    SELECT entity_id, contact_id INTO v_ent, v_con
      FROM add_customer('Grace', NULL, 'grace@probe.invalid', NULL,
                        NULL, NULL, NULL, NULL, 'US', 'active',
                        'business', 'Hopper Metals', 'billing', false);
    IF (SELECT role FROM entity_relationships WHERE contact_id = v_con) <> 'Customer' THEN
        RAISE EXCEPTION 'F failed: a business naming a human got role % - that is the '
                        'behaviour the collapsed head had, and 0016 is not the file that '
                        'changes it',
            (SELECT role FROM entity_relationships WHERE contact_id = v_con);
    END IF;
    IF (SELECT name FROM entities WHERE id = v_ent) <> 'Hopper Metals' THEN
        RAISE EXCEPTION 'F failed: a business entity took its name from % rather than the '
                        'organization',
            (SELECT name FROM entities WHERE id = v_ent);
    END IF;
    IF (SELECT count(*) FROM addresses WHERE entity_id = v_ent) <> 0 THEN
        RAISE EXCEPTION 'F failed: a business with none of the four street fields wrote % '
                        'address rows - the OR condition is what keeps a name-only customer '
                        'a three-row write',
            (SELECT count(*) FROM addresses WHERE entity_id = v_ent);
    END IF;

    SELECT entity_id, contact_id INTO v_ent, v_con
      FROM add_customer(NULL, NULL, 'nobody@probe.invalid', '555-0102',
                        NULL, NULL, NULL, NULL, 'US', 'active',
                        'business', 'Nameless Ltd', 'home', true);
    IF (SELECT role FROM entity_relationships WHERE contact_id = v_con) <> 'Business Contact' THEN
        RAISE EXCEPTION 'F failed: a business with no named human got role %',
            (SELECT role FROM entity_relationships WHERE contact_id = v_con);
    END IF;
    IF (SELECT first_name || last_name FROM contacts WHERE id = v_con) <> '' THEN
        RAISE EXCEPTION 'F failed: the unnamed contact carried a name (empty strings are what '
                        'the surviving head wrote, not NULLs)';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- G. the domain that named no column. p_entity_type used to fall through to the
    --    individual branch for anything that was not the word business, so a typo produced a
    --    person out of an organisation and reported success. The pair now refuses, and the
    --    refusal is an error rather than a row because it is a wrong argument (0015's rule).
    ------------------------------------------------------------------
    v_err := NULL;
    BEGIN
        SELECT success INTO v_ok FROM add_customer('Org', NULL, 'typo@probe.invalid', NULL,
                        NULL, NULL, NULL, NULL, 'US', 'active', 'organization');
    EXCEPTION WHEN OTHERS THEN
        v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '22023' THEN
        RAISE EXCEPTION 'G failed: p_entity_type ''organization'' answered % - it used to '
                        'silently create an individual', coalesce(v_err, 'a row (the fall-through survived)');
    END IF;
    IF (SELECT count(*) FROM entities WHERE name = 'Org') <> 0 THEN
        RAISE EXCEPTION 'G failed: the refused entity_type still wrote an entities row';
    END IF;
    -- NULL is the same trap in a different costume: p_entity_type has a default, so NULL
    -- arrives only when a caller names the parameter and passes nothing.
    v_err := NULL;
    BEGIN
        SELECT success INTO v_ok FROM add_customer('Nil', 'Type', 'nil@probe.invalid', NULL,
                        NULL, NULL, NULL, NULL, 'US', 'active', NULL);
    EXCEPTION WHEN OTHERS THEN
        v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '22023' THEN
        RAISE EXCEPTION 'G failed: a NULL p_entity_type answered % - the guard says NOT IN '
                        'and NULL is neither in nor out', coalesce(v_err, 'a row');
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- H. no re-wrap: a database fact arrives as itself. entities.status is CHECKed by 0007,
    --    so a status outside the list is a constraint violation - and this body used to turn
    --    it into success=false and a sentence. The tool's Python branch cannot tell the two
    --    apart; its SQLSTATE can.
    ------------------------------------------------------------------
    v_err := NULL;
    BEGIN
        SELECT success INTO v_ok FROM add_customer('Bad', 'Status', 'bs@probe.invalid', NULL,
                        NULL, NULL, NULL, NULL, 'US', 'inactive-but-typed-wrong');
    EXCEPTION WHEN OTHERS THEN
        v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '23514' THEN
        RAISE EXCEPTION 'H failed: a status outside entities.status answered % - 23514 is the '
                        'fact, and the old handler made it a message',
            coalesce(v_err, 'a row (success=false, which is the re-wrap)');
    END IF;
    IF (SELECT count(*) FROM entities WHERE name = 'Bad Status') <> 0 THEN
        RAISE EXCEPTION 'H failed: the refused status wrote a customer anyway';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- I. the two duplicate checks are written to two rules, asserted as behaviour so the
    --    asymmetry cannot be inherited silently. Email is case-blind, so the same address
    --    typed differently is one person; phone is exact, so the same number typed
    --    differently is two. Neither half is 4.4, and the fix - normalising a phone number
    --    into a comparable form - is a decision about who the database believes is the same
    --    human, which belongs in a file that says so out loud.
    ------------------------------------------------------------------
    SELECT success INTO v_ok FROM add_customer('Case', 'Shift', 'caSe@probe.invalid', '555-0200');
    SELECT success INTO v_ok FROM add_customer('Case', 'Shift', 'CASE@probe.invalid', '555-0201');
    IF v_ok THEN
        RAISE EXCEPTION 'I failed: an email differing only in case created a second contact - '
                        'the ILIKE rule 5.9 paid for is gone';
    END IF;
    SELECT success INTO v_ok FROM add_customer('Form', 'At', 'form@probe.invalid', '+1 555 0300');
    SELECT success INTO v_ok FROM add_customer('Form', 'At', 'form2@probe.invalid', '555-0300');
    IF NOT v_ok THEN
        RAISE EXCEPTION 'I failed: two phone formats refused each other - something '
                        'normalised phone without updating this probe, and the entities/contacts '
                        'rows the second call did not write are now missing';
    END IF;
    IF (SELECT count(*) FROM contacts WHERE first_name = 'Form') <> 2 THEN
        RAISE EXCEPTION 'I failed: the phone asymmetry is no longer measurable (% contacts)',
            (SELECT count(*) FROM contacts WHERE first_name = 'Form');
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- J. the seat. Forced row security means the duplicate read is a TENANT'S duplicate
    --    read, and that is the right promise: the same email at two tenants is two customers,
    --    each visible only to its owner. Checked as afpc_app, which is the only way to know
    --    the wall is applied to this function's reads rather than assumed from a SELECT.
    ------------------------------------------------------------------
    INSERT INTO tenants (name, slug) VALUES ('0016 second tenant', 'afpc-0016-t2')
     RETURNING tenant_id INTO v_one;
    SET LOCAL ROLE afpc_app;
    PERFORM set_config('app.tenant_id', v_one::text, true);
    SELECT success, entity_id INTO v_ok, v_ent
      FROM add_customer('Shared', 'Email', 'caSe@probe.invalid', NULL,
                        NULL, NULL, NULL, NULL, 'US', 'active',
                        'individual', NULL, 'home', true);
    RESET ROLE;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'J failed: the door is not usable by afpc_app (% %) - 0009''s wall and '
                        'this function have never met', v_ok, v_msg;
    END IF;
    IF (SELECT tenant_id FROM entities WHERE id = v_ent) <> v_one THEN
        RAISE EXCEPTION 'J failed: the customer landed in tenant % rather than % - the '
                        'column default is doing the work and not the caller',
            (SELECT tenant_id FROM entities WHERE id = v_ent), v_one;
    END IF;
    IF (SELECT count(*) FROM entities WHERE id = v_ent
          AND entity_type = 'customer') <> 1 THEN
        RAISE EXCEPTION 'J failed: add_customer wrote entity_type % - vw_customers''s filter '
                        'depends on this never changing quietly',
            (SELECT entity_type FROM entities WHERE id = v_ent);
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- K. 0013's identity half, at the door that creates customers: the trail names the role
    --    that wrote the row, not whatever the statement said.
    ------------------------------------------------------------------
    -- Matched on the row's own id, not on its name. Obligations-0013 says never count
    -- audit_log absolutely, and this is the case it did not spell out: a probe whose subject
    -- has a name the probe invented will find the PREVIOUS REPLAY's trail row in any database
    -- that has run this migration twice - a rehearsal clone built from a live that already
    -- applied it, which is exactly where it failed. The id cannot repeat, so the count means 1.
    IF (SELECT count(*) FROM audit_log WHERE table_name = 'entities'
         AND action = 'INSERT' AND new_values->>'id' = v_ent::text) <> 1 THEN
        RAISE EXCEPTION 'K failed: the entities row % this probe created is trailed % times',
            v_ent, (SELECT count(*) FROM audit_log WHERE table_name = 'entities'
                     AND new_values->>'id' = v_ent::text);
    END IF;
    IF (SELECT min(db_user) FROM audit_log WHERE table_name = 'entities'
         AND new_values->>'id' = v_ent::text) <> 'afpc_app' THEN
        RAISE EXCEPTION 'K failed: the seat that created the customer was recorded as % - 5.8''s '
                        'identity answer, in one column',
            (SELECT min(db_user) FROM audit_log WHERE table_name = 'entities'
              AND new_values->>'id' = v_ent::text);
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- L. what the collapse costs a caller that was using the other head. The 10-parameter
    --    head required four arguments positionally; the surviving head defaults all of them,
    --    so a shorter call now resolves and is answered by the validation rules instead of
    --    by 42725. Asserted, because "nothing else broke" is a claim about arity, and arity is
    --    how 4.4 was found in the first place.
    ------------------------------------------------------------------
    v_err := NULL;
    BEGIN
        SELECT success, message INTO v_ok, v_msg
          FROM add_customer(NULL::text, NULL::text, NULL::text, NULL::text);
    EXCEPTION WHEN OTHERS THEN
        v_err := SQLSTATE;
    END;
    IF v_err IS NOT NULL THEN
        RAISE EXCEPTION 'L failed: an all-NULL call answered % - it should be refused as a '
                        'row, and 42725 was never an answer to anything', v_err;
    END IF;
    -- Refused, and by the first rule the surviving head applies (a name before a contact
    -- point), which is the order the 14-parameter head had and 0016 keeps. The second call
    -- reaches the rule the first one never got to, so both halves of the ladder are shown to
    -- be reachable through one head at short arity.
    IF v_ok OR v_msg <> 'First name is required for individual customers' THEN
        RAISE EXCEPTION 'L failed: an all-NULL call reported success=% (%)', v_ok, v_msg;
    END IF;
    SELECT success, message INTO v_ok, v_msg
      FROM add_customer('No', 'Contact');
    IF v_ok OR v_msg <> 'At least one of email or phone is required' THEN
        RAISE EXCEPTION 'L failed: a named call with no contact point reported success=% (%)',
            v_ok, v_msg;
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- Cleanup. Contacts and entities are CRM facts, so the order is the one 0008's RESTRICT
    --    edges demand: relationships and addresses first, then the rows they point at. The
    --    audit rows about all of this stay, which is 0013 working as designed.
    ------------------------------------------------------------------
    -- Everything this file created is reachable from an email it invented, so the sweep is
    -- keyed on that and not on a list of names that has to be edited in step with every probe.
    -- The order is what 0008's RESTRICT edges demand, and the entity ids are captured before
    -- the relationships that name them are gone. The trail rows about all of it stay: that is
    -- 0013 being honest rather than residue.
    SELECT array_agg(DISTINCT entity_id) INTO v_ents FROM entity_relationships
     WHERE contact_id IN (SELECT id FROM contacts WHERE email LIKE '%@probe.invalid');
    DELETE FROM addresses        WHERE entity_id = ANY (v_ents);
    DELETE FROM communications   WHERE entity_id = ANY (v_ents);
    DELETE FROM entity_relationships WHERE contact_id IN
        (SELECT id FROM contacts WHERE email LIKE '%@probe.invalid');
    DELETE FROM contacts WHERE email LIKE '%@probe.invalid';
    DELETE FROM entities WHERE id = ANY (v_ents);
    DELETE FROM idempotency_keys WHERE operation = 'add_customer';
    DELETE FROM tenants WHERE slug = 'afpc-0016-t2';

    IF v_n <> 12 THEN
        RAISE EXCEPTION 'expected 12 behavioural verifications, completed %', v_n;
    END IF;
    RAISE NOTICE '4.4: % checks passed - one add_customer answers every arity the tree '
                 'issues, a retried call creates one customer, a refusal can be retried, a '
                 'wrong argument is an error rather than a message, and the duplicate rule the '
                 'schema cannot express is asserted as behaviour in both directions', v_n;
END
$$;
