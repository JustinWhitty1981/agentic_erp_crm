-- 0022: the follow-up read path answers its own question, on the clock it was given
--       (DATABASE_REVIEW.md 4.5's other live half - the tool surface disagreeing with itself)
--
-- Why this file exists: `get_followup_customers` is requirement 6 of
-- docs/agent_requirements/customer_service/customer_service.md, and it is the tool the deployed
-- agent will call most: "who have we not spoken to lately". Two of its three answers were
-- wrong, and neither wrong answer is visible from the outside.
--
-- What the file found, measured on this server rather than assumed:
--
--   * `p_days_threshold` is declared, DEFAULTed to 7, documented as the knob, and **never read
--     by the body**. The comparison is against a literal `INTERVAL '7 days'`. Measured: asking
--     for 60 days returned the same rows as asking for 1. This is the shape 0007 keeps refusing
--     to create - a rule stated in one place and enforced in another - except here the two
--     places are a signature and a WHERE clause, so nothing can ever notice. Probe B fails on
--     the pre-0022 body and cannot be satisfied by any amount of documentation.
--   * The third branch is unreachable. `last_outcome` is declared and no statement between
--     `DECLARE` and that `ELSIF` assigns it, so it is NULL on every iteration, and
--     `NULL IN ('pending','escalated')` is UNKNOWN, which is not TRUE. "Unresolved
--     communication" - the reason the requirements document names - has therefore never been
--     returned by this function, in any migration, since it was ported. A guard whose test can
--     only evaluate UNKNOWN takes neither branch and walks past itself: dev/README's
--     `SELECT col INTO var` entry, arrived at from the other direction (there the variable kept
--     a stale value; here it never had one to keep).
--   * The clock is the wrong clock. Staleness was measured against `created_at` - when the row
--     was written - and reported as `last_communication_date`. For a row the agent logs as the
--     call happens the two are the same instant, which is why this has never shown up. For a
--     call logged a week late, or content imported with its real date, `created_at` says
--     "contacted today" about a conversation nobody has had in forty days - so the customer
--     disappears from the follow-up list, silently, and the list is the mechanism by which
--     anyone would have noticed. `started_at` is the interaction; it is NOT NULL, it is what the
--     column pair in 0021 exists to carry, and it is what the requirements document means by
--     "since last contact". Probe D discriminates the two clocks with a row that is fresh and
--     describes something old; on the pre-0022 body that customer is missing.
--   * It was also N+1: one scan of `communications` per customer, twice, inside a loop over
--     `entities`. Set-based here, which is what makes the two aggregate readings below safe
--     rather than merely faster - in the loop, a variable that survives an iteration is a bug
--     waiting for the next refactor.
--
-- What this file deliberately does NOT change:
--   * The INNER join to the primary contact. A customer with no primary `entity_relationships`
--     row is invisible to this tool. That is the same rule `vw_customers` applies, so the two
--     surfaces agree, and making one of them see orphans would make them disagree about who a
--     customer is. §5 hands the decision to whoever owns contact identity.
--   * The row order. The loop never promised one and neither does the aggregate form; an outer
--     plan may re-sort regardless of what a view or a function says internally (0017's entry).
--     Callers ORDER BY.
--   * The signature. Same name, same single defaulted parameter, so `CREATE OR REPLACE` matches
--     the existing object: no second head (4.4's failure mode), and the OID survives along with
--     the ACL 0009's sweep established. Probe A checks the ACL survived, because a rewrite that
--     needed DROP+CREATE would reopen the B22 question.

SET client_min_messages TO notice;

-- ---------------------------------------------------------------------------
-- 1. The read path, set-based
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_followup_customers(
    p_days_threshold integer DEFAULT 7
)
RETURNS TABLE(entity_id bigint, name text, email text, phone text,
              last_communication_date timestamptz, follow_up_reason text)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_horizon timestamptz;
BEGIN
    ------------------------------------------------------------------
    -- A negative threshold is not "a very small window", it is a nonsense argument, and
    -- 0015's rule applies to reads as much as writes: refuse a wrong argument as 22023 before
    -- doing any work, because an answer computed from a misread parameter is indistinguishable
    -- from an answer. NULL is refused too, even though the parameter is DEFAULTed - DEFAULT
    -- only fires when the argument is *omitted*, and an explicit NULL means a caller that read
    -- the signature and passed nothing meaningful (0016's note about the same trap on
    -- p_entity_type: "NULL is the same trap in a different costume").
    ------------------------------------------------------------------
    IF p_days_threshold IS NULL THEN
        RAISE EXCEPTION 'get_followup_customers: p_days_threshold is NULL - omit the argument to get the default, or pass a number of days'
            USING ERRCODE = '22023';
    END IF;
    IF p_days_threshold < 0 THEN
        RAISE EXCEPTION 'get_followup_customers: p_days_threshold % is negative', p_days_threshold
            USING ERRCODE = '22023',
                  HINT = 'the argument is an age in days, not an offset';
    END IF;

    -- Computed once, for the whole query. The loop form computed it per customer, which is
    -- where a second `now()` reading could straddle a midnight and make two customers'
    -- staleness disagree about what "today" was.
    v_horizon := now() - make_interval(days => p_days_threshold);

    RETURN QUERY
    WITH per_customer AS (
        -- One pass over communications. Two aggregate readings, deliberately different shapes:
        --   * MAX(started_at) returns exactly one row for a customer with no communications at
        --     all, holding NULL - which is the "never contacted" case, and the reason the
        --     LEFT JOIN below is a LEFT JOIN.
        --   * the most recent non-NULL outcome cannot be an aggregate over the same grouping,
        --     so it is read out of an ordered array (dev/README: max(uuid) does not exist and
        --     `SELECT INTO ... LIMIT 1` leaves the target untouched on zero rows - array_agg
        --     indexed at [1] is NULL by construction, which is the answer wanted).
        SELECT c.entity_id,
               max(c.started_at) AS last_at,
               (array_agg(c.outcome ORDER BY c.started_at DESC, c.id DESC)
                    FILTER (WHERE c.outcome IS NOT NULL))[1] AS last_outcome
          FROM communications c
         GROUP BY c.entity_id
    )
    SELECT e.id,
           e.name,
           pri.email,
           pri.phone,
           pc.last_at,
           -- The ladder, in the order the original branches were written, so the reason a
           -- customer is on the list means the same thing it meant before this file. Status is
           -- first because it is a human decision recorded on the customer; staleness is an
           -- inference; an unresolved thread is a fact about the last interaction.
           CASE
             WHEN e.status = 'follow-up'                      THEN 'Status marked for follow-up'
             WHEN pc.last_at IS NULL
               OR pc.last_at < v_horizon                     THEN 'No recent communications'
             WHEN pc.last_outcome IN ('pending', 'escalated') THEN 'Unresolved communication'
           END
      FROM entities e
      JOIN entity_relationships er ON er.entity_id = e.id AND er.is_primary = true
      JOIN contacts pri ON pri.id = er.contact_id
      LEFT JOIN per_customer pc ON pc.entity_id = e.id
     WHERE e.entity_type = 'customer'
       AND (e.status = 'follow-up'
            OR pc.last_at IS NULL
            OR pc.last_at < v_horizon
            OR pc.last_outcome IN ('pending', 'escalated'));

    RETURN;
END
$$;

-- ---------------------------------------------------------------------------
-- 2. What the schema now says about itself
-- ---------------------------------------------------------------------------
COMMENT ON FUNCTION get_followup_customers(integer) IS
    'Customers who need to be contacted: one row per customer whose status is marked for '
    'follow-up, or whose most recent interaction (started_at, the interaction time - not '
    'created_at, the row-write time) is older than p_days_threshold or absent, or whose most '
    'recent recorded outcome is pending or escalated. The reason column reports the first of '
    'those three that applies, in that order. Before 0022 the parameter was never read - every '
    'threshold behaved as 7 - and the unresolved-outcome branch could not fire, because the '
    'variable it tested was never assigned; both were silent, since the answer was still a '
    'plausible list. The horizon is computed once per call. A negative or NULL threshold is '
    'refused as 22023 rather than resolved to a default, because a wrong argument is not a '
    'request for the default. Customers are reached through their PRIMARY contact, the same '
    'filter vw_customers applies, so a customer with no primary relationship is invisible to '
    'both surfaces. No order is promised - 0017''s rule that a function cannot hold one for an '
    'outer plan. Built by 0001, made honest by 0022.';

-- ---------------------------------------------------------------------------
-- 3. Verify by behaving
-- ---------------------------------------------------------------------------
-- Fixtures: four customers invented here and keyed on @0022.probe.invalid, each built so that
-- exactly one claim of this function's contract is the reason it appears. Every probe compares
-- a SET of entity ids, never a total, so no assertion can be satisfied by a row another
-- migration left behind.
DO $$
DECLARE
    v_stale    bigint;   -- contacted 40 days ago, resolved
    v_fresh    bigint;   -- contacted today, resolved
    v_escal    bigint;   -- contacted yesterday, outcome escalated  -> the unreachable branch
    v_marked   bigint;   -- status follow-up, contacted yesterday   -> precedence
    v_row      bigint;   -- the row is young, the conversation is old
    v_other    bigint;   -- the second tenant's uncalled customer
    v_td       uuid;     -- the default tenant's id, read before the wall is put on
    v_t2       uuid;     -- the fixture tenant's id, same
    v_set      bigint[];
    v_ids      bigint[];
    v_names    text[];
    v_ok       boolean;
    v_found    bigint;
    v_err      text;
    v_n        int := 0;
BEGIN
    ------------------------------------------------------------------
    -- A. one head, the same signature, and the same ACL. The rewrite keeps the object, and a
    --    rewrite that had needed DROP+CREATE would have lost the grant structure 0009
    --    established and handed B22 a new function to name.
    ------------------------------------------------------------------
    IF (SELECT count(*) FROM pg_proc WHERE proname = 'get_followup_customers') <> 1 THEN
        RAISE EXCEPTION 'A failed: % heads of get_followup_customers are installed',
            (SELECT count(*) FROM pg_proc WHERE proname = 'get_followup_customers');
    END IF;
    IF (SELECT count(*) FROM pg_proc p
         WHERE p.proname = 'get_followup_customers'
           AND pg_get_function_identity_arguments(p.oid) = 'p_days_threshold integer') <> 1 THEN
        RAISE EXCEPTION 'A failed: the signature changed - a new parameter shape is a SECOND '
                        'function, which is 4.4 re-opened by a migration about a WHERE clause';
    END IF;
    IF (SELECT proacl::text FROM pg_proc WHERE proname = 'get_followup_customers')
         NOT LIKE '%afpc_app=%' THEN
        RAISE EXCEPTION 'A failed: afpc_app lost EXECUTE in the rewrite';
    END IF;
    IF has_function_privilege('public', 'get_followup_customers(integer)', 'EXECUTE')
       AND has_function_privilege('afpc_readonly',
             'get_followup_customers(integer)', 'EXECUTE') THEN
        -- The read roles are allowed to call it; PUBLIC is not supposed to have it at all.
        IF has_function_privilege('PUBLIC', 'get_followup_customers(integer)', 'EXECUTE') THEN
            RAISE EXCEPTION 'A failed: get_followup_customers is EXECUTE to PUBLIC again - the '
                            'sweep 0009 ran cannot reach an object that was dropped and recreated';
        END IF;
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- Fixtures. Created through the doors, not by hand: add_customer for the entities and
    -- 0021's add_communication for the interactions, so this migration is tested against the
    -- write paths the agent actually uses. p_started_at carries the historical instant, which
    -- is the whole point of probe D.
    ------------------------------------------------------------------
    SELECT entity_id INTO v_stale FROM add_customer('Stale', 'Contact',
        'stale@0022.probe.invalid', '+10022000001', NULL, NULL, NULL, NULL, 'US', 'active',
        'individual', NULL, 'home', true);
    SELECT entity_id INTO v_fresh FROM add_customer('Fresh', 'Contact',
        'fresh@0022.probe.invalid', '+10022000002', NULL, NULL, NULL, NULL, 'US', 'active',
        'individual', NULL, 'home', true);
    SELECT entity_id INTO v_escal FROM add_customer('Escalated', 'Person',
        'escalated@0022.probe.invalid', '+10022000003', NULL, NULL, NULL, NULL, 'US', 'active',
        'individual', NULL, 'home', true);
    SELECT entity_id INTO v_marked FROM add_customer('Marked', 'Person',
        'marked@0022.probe.invalid', '+10022000004', NULL, NULL, NULL, NULL, 'US', 'follow-up',
        'individual', NULL, 'home', true);
    SELECT entity_id INTO v_row FROM add_customer('Backdated', 'Account',
        'backdated@0022.probe.invalid', '+10022000005', NULL, NULL, NULL, NULL, 'US', 'active',
        'individual', NULL, 'home', true);

    PERFORM add_communication(p_entity_id := v_stale, p_summary := 'Quarterly review.',
        p_communication_type := 'call', p_direction := 'inbound', p_outcome := 'resolved',
        p_started_at := now() - interval '40 days');
    PERFORM add_communication(p_entity_id := v_fresh, p_summary := 'Just spoke.',
        p_communication_type := 'call', p_direction := 'inbound', p_outcome := 'resolved',
        p_started_at := now() - interval '1 hour');
    PERFORM add_communication(p_entity_id := v_escal, p_summary := 'Angry about the shipment.',
        p_communication_type := 'email', p_direction := 'inbound', p_outcome := 'escalated',
        p_sentiment_label := 'negative', p_started_at := now() - interval '1 day');
    PERFORM add_communication(p_entity_id := v_marked, p_summary := 'Said they would call back.',
        p_communication_type := 'call', p_direction := 'outbound', p_outcome := 'pending',
        p_started_at := now() - interval '1 day');
    -- The discriminating fixture: written NOW, about a conversation from 40 days ago.
    PERFORM add_communication(p_entity_id := v_row, p_summary := 'Logged late.',
        p_communication_type := 'note', p_direction := 'internal', p_outcome := 'resolved',
        p_started_at := now() - interval '40 days');

    ------------------------------------------------------------------
    -- B. the parameter moves the answer. Restricted to the three customers whose ONLY claim on
    --    this list is staleness - the other two fixtures are here for probes C and E and would
    --    be listed at every threshold by their outcome and their status, which is correct and
    --    would have made a naive "count the whole list" assertion measure the wrong thing.
    --    Asserted at three thresholds and in both directions, so a horizon wired to the wrong
    --    sign cannot pass either.
    ------------------------------------------------------------------
    -- Every comparison below is wrapped in coalesce, and that is load-bearing rather than
    -- defensive: array_agg over zero rows returns NULL, and `NULL <> ARRAY[...]` is UNKNOWN,
    -- which takes neither branch of the IF - dev/README's "SELECT col INTO var says nothing when
    -- it matches the wrong number of rows" wearing an assertion costume. The failure this probe
    -- exists to catch IS the function returning nothing, so an unwrapped test would have passed
    -- on the broken body it is meant to catch.
    SELECT coalesce(array_agg(g.entity_id ORDER BY g.entity_id), ARRAY[]::bigint[]) INTO v_ids
      FROM get_followup_customers(7) g
     WHERE g.entity_id IN (v_stale, v_fresh, v_row);
    IF v_ids <> ARRAY[v_stale, v_row] THEN
        RAISE EXCEPTION 'B failed: at 7 days the staleness-only answer was % - expected the two '
                        'customers whose last interaction was 40 days ago',
            coalesce(array_to_string(v_ids, ','), 'nothing');
    END IF;

    SELECT coalesce(array_agg(g.entity_id ORDER BY g.entity_id), ARRAY[]::bigint[]) INTO v_ids
      FROM get_followup_customers(60) g
     WHERE g.entity_id IN (v_stale, v_fresh, v_row);
    IF cardinality(v_ids) <> 0 THEN
        RAISE EXCEPTION 'B failed: at 60 days % staleness-only customers were still listed - all '
                        'three were contacted inside 60 days, so the threshold is being ignored '
                        'or inverted', cardinality(v_ids);
    END IF;

    SELECT coalesce(array_agg(g.entity_id ORDER BY g.entity_id), ARRAY[]::bigint[]) INTO v_ids
      FROM get_followup_customers(0) g
     WHERE g.entity_id IN (v_stale, v_fresh, v_row);
    IF v_ids <> ARRAY[v_stale, v_fresh, v_row] THEN
        RAISE EXCEPTION 'B failed: at 0 days the answer was % - expected all three, since every '
                        'one of them was contacted at some point before this instant',
            coalesce(array_to_string(v_ids, ','), 'nothing');
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- C. the branch that could not fire. v_escal was contacted yesterday with an escalated
    --    outcome: not stale, not marked, so the ONLY reason it can appear at 7 days is the
    --    unresolved-outcome arm, and the reason column has to say so.
    ------------------------------------------------------------------
    SELECT count(*) INTO v_found FROM get_followup_customers(7) g
     WHERE g.entity_id = v_escal AND g.follow_up_reason = 'Unresolved communication';
    IF v_found <> 1 THEN
        RAISE EXCEPTION 'C failed: the escalated customer is not on the 7-day list for the right '
                        'reason (rows %) - this branch has never fired since 0001 ported it',
            v_found;
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- D. the clock. v_row's interaction is 40 days old and its row was written this instant, so
    --    created_at and started_at disagree on purpose. Listed, with the old date shown.
    ------------------------------------------------------------------
    SELECT count(*) INTO v_found FROM get_followup_customers(7) g
     WHERE g.entity_id = v_row
       AND g.follow_up_reason = 'No recent communications'
       AND g.last_communication_date < now() - interval '30 days';
    IF v_found <> 1 THEN
        RAISE EXCEPTION 'D failed: a conversation from 40 days ago logged today is not on the '
                        'list (rows %) - the tool is reading the row''s write time and calling '
                        'it the interaction time', v_found;
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- E. precedence. v_marked is both marked for follow-up and has a pending outcome from
    --    yesterday, so two arms want it; the status arm is the human decision and must win, and
    --    the ladder order is the only thing that decides it.
    ------------------------------------------------------------------
    SELECT count(*) INTO v_found FROM get_followup_customers(7) g
     WHERE g.entity_id = v_marked AND g.follow_up_reason = 'Status marked for follow-up';
    IF v_found <> 1 THEN
        RAISE EXCEPTION 'E failed: a customer that is both marked and unresolved answered with a '
                        'different reason - the branch ladder re-ordered itself';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- F. the two outcome values the body names are still members of the published vocabulary,
    --    and the vocabulary still has all four. Derived rather than trusted (0015's probe I):
    --    if a later migration renames an outcome, this filter must fail here rather than match
    --    nothing quietly and drop unresolved threads off the list forever. The second half is
    --    0018's rule that an exclusion has to be shown to be non-empty.
    ------------------------------------------------------------------
    -- unnest is not decoration: allowed_values is text[], and `x = ANY (subquery returning an
    -- array)` is the operator-postgres-does-not-exist case dev/README records. The scalar form
    -- fails at parse time inside a plpgsql body, which is a statement that has never been
    -- analyzed until this line runs.
    SELECT count(*) INTO v_found
      FROM unnest(ARRAY['pending', 'escalated']) AS needle(value)
     WHERE NOT (needle.value = ANY (SELECT unnest(v.allowed_values)
                                      FROM vw_domain_vocabulary v
                                     WHERE v.table_name = 'communications'
                                       AND v.column_name = 'outcome'));
    IF v_found <> 0 THEN
        RAISE EXCEPTION 'F failed: % of the outcome values this function filters on are outside '
                        'the published vocabulary - the filter has silently stopped matching', v_found;
    END IF;
    IF (SELECT cardinality(v.allowed_values) FROM vw_domain_vocabulary v
         WHERE v.table_name = 'communications' AND v.column_name = 'outcome') <> 4 THEN
        RAISE EXCEPTION 'F failed: communications.outcome no longer publishes 4 values, so the '
                        'pair this function treats as unresolved needs re-deciding, not a patch';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- G. wrong arguments are errors, and they are errors BEFORE the scan (0015's rule, applied
    --    to a read: an answer computed from a misread parameter looks like an answer).
    ------------------------------------------------------------------
    v_err := NULL;
    BEGIN
        PERFORM count(*) FROM get_followup_customers(-1);
    EXCEPTION WHEN OTHERS THEN
        v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '22023' THEN
        RAISE EXCEPTION 'G failed: a negative threshold answered % - expected 22023',
            coalesce(v_err, 'no error');
    END IF;
    v_err := NULL;
    BEGIN
        PERFORM count(*) FROM get_followup_customers(NULL::integer);
    EXCEPTION WHEN OTHERS THEN
        v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '22023' THEN
        RAISE EXCEPTION 'G failed: an explicit NULL threshold answered % - the DEFAULT only fires '
                        'when the argument is omitted, so this is 0016''s trap in a new costume',
            coalesce(v_err, 'no error - it silently used 7');
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- H. the wall. A second tenant with a customer nobody has contacted must appear in its own
    --    list and not in the default tenant's, from afpc_app's seat - because a per_customer
    --    aggregate over communications is exactly the kind of join that would leak a count
    --    across tenants if RLS did not bind the reads (0009, 0011).
    ------------------------------------------------------------------
    INSERT INTO tenants (name, slug) VALUES ('0022 second tenant', 'afpc-0022-t2');

    -- Both tenant ids are read BEFORE the first role switch, and that is not tidiness: once
    -- afpc_app is sitting in tenant 2, `SELECT tenant_id FROM tenants WHERE slug='default'`
    -- answers with nothing, because the isolation policy filters the tenants table exactly as it
    -- filters the business tables. Passing that nothing to set_config leaves app.tenant_id empty,
    -- afpc_policy_tenant() falls through to app.default_tenant_id, and the probe is quietly back
    -- in the tenant it was trying to contrast against - reporting a leak where it never took the
    -- seat it believed it had. This is 0018's "a derived value from a row you cannot see is
    -- derived from nothing" inside a probe about that very rule.
    SELECT tenant_id INTO v_td FROM tenants WHERE slug = 'default';
    SELECT tenant_id INTO v_t2 FROM tenants WHERE slug = 'afpc-0022-t2';

    SET LOCAL ROLE afpc_app;
    PERFORM set_config('app.tenant_id', v_t2::text, true);
    SELECT success, entity_id INTO v_ok, v_other
      FROM add_customer('Other', 'Tenant', 'other@0022.probe.invalid', '+10022000009',
                        NULL, NULL, NULL, NULL, 'US', 'active',
                        'individual', NULL, 'home', true);
    SELECT array_agg(g.name ORDER BY g.name) INTO v_names
      FROM get_followup_customers(7) g;
    RESET ROLE;
    IF NOT v_ok OR v_other IS NULL THEN
        RAISE EXCEPTION 'H failed: afpc_app could not create the fixture customer in its own '
                        'tenant - the wall and this function have never met';
    END IF;
    IF v_names IS NULL OR NOT ('Other Tenant' = ANY (v_names)) THEN
        RAISE EXCEPTION 'H failed: the second tenant does not see its own uncalled customer (saw %)',
            coalesce(array_to_string(v_names, ', '), 'nothing');
    END IF;
    -- The negative half, in the OTHER tenant's seat. Asserting it as the owner would be
    -- meaningless and this line was exactly that mistake: a superuser bypasses row security
    -- however the tables are configured (dev/README's masquerading entry), so the owner sees
    -- every tenant's follow-ups and has always seen them. The wall only has an opinion where a
    -- non-owner is sitting.
    SET LOCAL ROLE afpc_app;
    PERFORM set_config('app.tenant_id', v_td::text, true);
    SELECT count(*) INTO v_found FROM get_followup_customers(7) g
     WHERE g.name = 'Other Tenant';
    RESET ROLE;
    IF v_found <> 0 THEN
        RAISE EXCEPTION 'H failed: the default tenant''s list contains another tenant''s '
                        'customer (rows %) - the aggregate in this function reads communications, '
                        'and the wall has to be what filters it', v_found;
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- I. a customer never contacted at all is on the list, with a NULL date: the LEFT JOIN and
    --    the IS NULL arm, which is the case a naive rewrite to INNER loses.
    ------------------------------------------------------------------
    SELECT entity_id INTO v_stale FROM add_customer('Never', 'Contacted',
        'never@0022.probe.invalid', '+10022000010', NULL, NULL, NULL, NULL, 'US', 'active',
        'individual', NULL, 'home', true);
    SELECT count(*) INTO v_found FROM get_followup_customers(7) g
     WHERE g.entity_id = v_stale AND g.last_communication_date IS NULL
       AND g.follow_up_reason = 'No recent communications';
    IF v_found <> 1 THEN
        RAISE EXCEPTION 'I failed: a customer with no communications at all is not on the list';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- Cleanup. Order follows 0008's edges; the sweep is keyed on the invented email domain.
    ------------------------------------------------------------------
    SELECT array_agg(DISTINCT e.id) INTO v_set
      FROM entities e
      JOIN entity_relationships er ON er.entity_id = e.id
      JOIN contacts c ON c.id = er.contact_id
     WHERE c.email LIKE '%@0022.probe.invalid';
    DELETE FROM communications WHERE entity_id = ANY (v_set);
    DELETE FROM addresses WHERE entity_id = ANY (v_set);
    DELETE FROM entity_relationships WHERE entity_id = ANY (v_set);
    DELETE FROM contacts WHERE email LIKE '%@0022.probe.invalid';
    DELETE FROM entities WHERE id = ANY (v_set);
    DELETE FROM idempotency_keys WHERE operation = 'add_communication';
    DELETE FROM tenants WHERE slug = 'afpc-0022-t2';

    IF v_n <> 9 THEN
        RAISE EXCEPTION 'expected 9 behavioural verifications, completed %', v_n;
    END IF;
    RAISE NOTICE '4.5: % checks passed - the threshold means what the signature says, a '
                 '40-day-old conversation logged today is still 40 days old, an unresolved '
                 'thread reaches the list for the reason the requirements document names, a '
                 'human decision outranks an inference, a nonsense argument is refused before '
                 'the scan, and neither tenant can see the other''s follow-ups', v_n;
END
$$;

-- ---------------------------------------------------------------------------
-- 5. Obligations this file leaves open, on purpose
-- ---------------------------------------------------------------------------
-- * `follow_up_reason` is a free-text column of a function's result, not a domain: the three
--   strings are the rule and nothing else states them. A UI or an agent that branches on them
--   is branching on prose, which is the failure 0016 named for Python reading a status string.
--   The day a fourth reason appears, the reasons belong in a lookup table (0007's shape).
-- * A customer with no primary `entity_relationships` row is invisible here and in vw_customers.
--   Both surfaces agree, which is the argument for leaving it; the argument against is that the
--   follow-up list is exactly where an orphaned customer most needs to be noticed. Whoever owns
--   contact identity decides, and the two files must change together.
-- * Nothing here marks a customer 'active' again after a follow-up is logged: `entities.status`
--   is written by add_customer and by mark_customer_followup only. So a customer marked
--   'follow-up' stays on this list until a human or an agent clears the mark, and the reason
--   column will keep saying 'Status marked for follow-up' no matter how recently the customer
--   was called. That is the intended precedence, but it makes mark_customer_followup part of
--   every complete interaction loop, and the deployed agent has to treat it that way.
