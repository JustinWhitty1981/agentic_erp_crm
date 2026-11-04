-- Development reference data for the customer service agent. Data only: db/README is explicit
-- that a seed file containing DDL is how the schema forked once already (§3.3, and the twin
-- `agent_first_erp_crm` schema's origin is a setup_sample_data.sql that created eight tables).
--
-- Re-runnable by contract, not by bookkeeping. Every customer is guarded on the contact that
-- makes it identifiable and every interaction on a summary string this file invented, because
-- add_customer and add_communication refuse a duplicate rather than absorbing one - an
-- ON CONFLICT DO NOTHING cannot wrap a function call, and a guard that reads "did I already run"
-- from a table the seed does not own would stop working the day someone edits a customer by
-- hand. seed.sh's header states the rule; this file is the first thing to obey it.
--
-- Everything is written through the doors, never with an INSERT. That is the point of having
-- them: the seed exercises add_customer's address and relationship branching, add_communication's
-- threading and outcome vocabulary, and 0021's refusal rules, so a broken door fails the seed
-- rather than appearing later as a mysterious empty follow-up list. The only direct writes here
-- are the created_at backdates below, which no door can express - and those are stated, not
-- hidden, because 0022's clock claim depends on them being visible.
--
-- The tenant is named explicitly even though init.sh mirrors app.default_tenant_id with
-- ALTER SYSTEM. A seed that relies on the fallback is a seed that silently writes into whatever
-- tenant the server last defaulted to, which is the same class of accident 0022's probe H found
-- while asking the tenants table for a tenant through the wall.

SET client_min_messages TO notice;

SELECT set_config('app.tenant_id',
    (SELECT tenant_id::text FROM tenants WHERE slug = 'default'), false);

-- ---------------------------------------------------------------------------
-- 1. Customers
-- ---------------------------------------------------------------------------
-- Seven, each in a different situation, so that the four read paths a customer service agent
-- calls have something distinct to find: a healthy account, a stale one, an unresolved one, a
-- marked one, a threaded one, a contact-poor one, and one that must not be promoted.

DO $$
DECLARE
    v_ent bigint;
    v_msg text;
BEGIN
    -- 1. Healthy: recent, positive, resolved.
    IF NOT EXISTS (SELECT 1 FROM contacts WHERE email = 'alice.nguyen@afpc.example.invalid') THEN
        SELECT entity_id, message INTO v_ent, v_msg FROM add_customer(
            p_first_name := 'Alice', p_last_name := 'Nguyen',
            p_email := 'alice.nguyen@afpc.example.invalid', p_phone := '+15550100101',
            p_street := '14 Riverside Ave', p_city := 'Madison', p_state := 'WI',
            p_postal_code := '53703', p_country := 'US', p_status := 'active',
            p_entity_type := 'individual', p_address_type := 'home', p_is_primary := true,
            p_idempotency_key := '00000000-0000-4000-8000-000000000001');
        IF v_ent IS NULL THEN
            RAISE EXCEPTION 'seed: add_customer refused Alice Nguyen: %', v_msg;
        END IF;
    END IF;

    -- 2. A business, and the one that will show up as stale.
    IF NOT EXISTS (SELECT 1 FROM contacts WHERE email = 'service@bobsengines.afpc.example.invalid') THEN
        SELECT entity_id INTO v_ent FROM add_customer(
            p_first_name := 'Bob', p_last_name := 'Hartley',
            p_email := 'service@bobsengines.afpc.example.invalid', p_phone := '+15550100102',
            p_street := '9 Foundry Row', p_city := 'Peoria', p_state := 'IL',
            p_postal_code := '61602', p_country := 'US', p_status := 'active',
            p_entity_type := 'business', p_organization_name := 'Bob''s Small Engines',
            p_address_type := 'headquarters', p_is_primary := true,
            p_idempotency_key := '00000000-0000-4000-8000-000000000002');
    END IF;

    -- 3. Unresolved: the sentiment and the outcome the escalation path is supposed to notice.
    IF NOT EXISTS (SELECT 1 FROM contacts WHERE email = 'carol.diaz@afpc.example.invalid') THEN
        SELECT entity_id INTO v_ent FROM add_customer(
            p_first_name := 'Carol', p_last_name := 'Diaz',
            p_email := 'carol.diaz@afpc.example.invalid', p_phone := '+15550100103',
            p_street := '220 Elm Ct', p_city := 'Tucson', p_state := 'AZ',
            p_postal_code := '85701', p_country := 'US', p_status := 'active',
            p_entity_type := 'individual', p_address_type := 'home', p_is_primary := true,
            p_idempotency_key := '00000000-0000-4000-8000-000000000003');
    END IF;

    -- 4. Marked for follow-up by a human, which is the reason column that outranks an inference.
    IF NOT EXISTS (SELECT 1 FROM contacts WHERE email = 'accounts@deltamanuf.afpc.example.invalid') THEN
        SELECT entity_id INTO v_ent FROM add_customer(
            p_first_name := NULL, p_last_name := NULL,
            p_email := 'accounts@deltamanuf.afpc.example.invalid', p_phone := '+15550100104',
            p_street := '4500 Industrial Pkwy', p_city := 'Akron', p_state := 'OH',
            p_postal_code := '44307', p_country := 'US', p_status := 'follow-up',
            p_entity_type := 'business', p_organization_name := 'Delta Manufacturing Co',
            p_address_type := 'headquarters', p_is_primary := true,
            p_idempotency_key := '00000000-0000-4000-8000-000000000004');
    END IF;

    -- 5. Threaded: a quote sent, a reply received, a follow-up call after that.
    IF NOT EXISTS (SELECT 1 FROM contacts WHERE email = 'ops@everestfreight.afpc.example.invalid') THEN
        SELECT entity_id INTO v_ent FROM add_customer(
            p_first_name := 'Priya', p_last_name := 'Raman',
            p_email := 'ops@everestfreight.afpc.example.invalid', p_phone := '+15550100105',
            p_street := '77 Terminal Rd', p_city := 'Newark', p_state := 'NJ',
            p_postal_code := '07114', p_country := 'US', p_status := 'active',
            p_entity_type := 'business', p_organization_name := 'Everest Freight LLC',
            p_address_type := 'headquarters', p_is_primary := true,
            p_idempotency_key := '00000000-0000-4000-8000-000000000005');
    END IF;

    -- 6. Contact-poor: an email and nothing else, which is the shape that makes a phone lookup
    --    return "no match" honestly rather than a wrong person.
    IF NOT EXISTS (SELECT 1 FROM contacts WHERE email = 'farid.hosseini@afpc.example.invalid') THEN
        SELECT entity_id INTO v_ent FROM add_customer(
            p_first_name := 'Farid', p_last_name := 'Hosseini',
            p_email := 'farid.hosseini@afpc.example.invalid', p_phone := NULL,
            p_city := 'Dearborn', p_state := 'MI', p_postal_code := '48120',
            p_country := 'US', p_status := 'active',
            p_entity_type := 'individual', p_address_type := 'home', p_is_primary := true,
            p_idempotency_key := '00000000-0000-4000-8000-000000000006');
    END IF;

    -- 7. Blacklisted: a customer the follow-up machinery must not promote back into the pipeline.
    --    mark_customer_followup refuses this, and 0014 pinned that refusal; the row exists so the
    --    refusal is testable against real data rather than only against a probe fixture.
    IF NOT EXISTS (SELECT 1 FROM contacts WHERE email = 'grace.okafor@afpc.example.invalid') THEN
        SELECT entity_id INTO v_ent FROM add_customer(
            p_first_name := 'Grace', p_last_name := 'Okafor',
            p_email := 'grace.okafor@afpc.example.invalid', p_phone := '+15550100107',
            p_street := '3 Harbour Way', p_city := 'Portland', p_state := 'OR',
            p_postal_code := '97201', p_country := 'US', p_status := 'blacklisted',
            p_entity_type := 'individual', p_address_type := 'home', p_is_primary := true,
            p_idempotency_key := '00000000-0000-4000-8000-000000000007');
    END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- 2. Interactions
-- ---------------------------------------------------------------------------
-- Logged through add_communication with p_started_at in the past, so the demo data is a set of
-- conversations that happened over the last six weeks rather than six weeks of rows written at
-- the moment the seed ran. That distinction is 0022's: the tool answers "who have we not spoken
-- to", and every row below is a case where the row's write time and the conversation's time
-- disagree. A seed that left created_at and started_at equal would look fine and teach nothing.
DO $$
DECLARE
    v_alice   bigint;
    v_bob     bigint;
    v_carol   bigint;
    v_delta   bigint;
    v_everest bigint;
    v_farid   bigint;
    v_grace   bigint;
    v_c1      bigint;
    v_c2      bigint;
    v_ok      boolean;
    v_msg     text;
BEGIN
    SELECT id INTO v_alice   FROM entities WHERE name = 'Alice Nguyen';
    SELECT id INTO v_bob     FROM entities WHERE name = 'Bob''s Small Engines';
    SELECT id INTO v_carol   FROM entities WHERE name = 'Carol Diaz';
    SELECT id INTO v_delta   FROM entities WHERE name = 'Delta Manufacturing Co';
    SELECT id INTO v_everest FROM entities WHERE name = 'Everest Freight LLC';
    SELECT id INTO v_farid   FROM entities WHERE name = 'Farid Hosseini';
    SELECT id INTO v_grace   FROM entities WHERE name = 'Grace Okafor';

    ------------------------------------------------------------------
    -- Alice: current, pleasant, two channels.
    ------------------------------------------------------------------
    IF v_alice IS NOT NULL AND NOT EXISTS (SELECT 1 FROM communications WHERE summary =
            'Confirmed the annual service plan renews in March.') THEN
        PERFORM * FROM add_communication(
            p_entity_id := v_alice, p_communication_type := 'call', p_direction := 'inbound',
            p_subject := 'Renewal question',
            p_summary := 'Confirmed the annual service plan renews in March.',
            p_channel := 'phone', p_agent_id := 'customer_service',
            p_sentiment_label := 'positive', p_outcome := 'resolved',
            p_started_at := now() - interval '3 days');
    END IF;
    IF v_alice IS NOT NULL AND NOT EXISTS (SELECT 1 FROM communications WHERE summary =
            'Emailed the updated pricing sheet she asked for.') THEN
        PERFORM * FROM add_communication(
            p_entity_id := v_alice, p_communication_type := 'email', p_direction := 'outbound',
            p_subject := 'Pricing sheet',
            p_summary := 'Emailed the updated pricing sheet she asked for.',
            p_channel := 'email', p_agent_id := 'customer_service',
            p_sentiment_label := 'neutral', p_outcome := 'resolved',
            p_started_at := now() - interval '2 days');
    END IF;

    ------------------------------------------------------------------
    -- Bob: nothing for six weeks. The stale case, and the one a follow-up list exists to catch.
    ------------------------------------------------------------------
    IF v_bob IS NOT NULL AND NOT EXISTS (SELECT 1 FROM communications WHERE summary =
            'Discussed the parts backorder; he accepted a two-week lead time.') THEN
        PERFORM * FROM add_communication(
            p_entity_id := v_bob, p_communication_type := 'call', p_direction := 'outbound',
            p_subject := 'Backorder',
            p_summary := 'Discussed the parts backorder; he accepted a two-week lead time.',
            p_channel := 'phone', p_agent_id := 'customer_service',
            p_sentiment_label := 'neutral', p_outcome := 'resolved',
            p_started_at := now() - interval '41 days');
    END IF;
    IF v_bob IS NOT NULL AND NOT EXISTS (SELECT 1 FROM communications WHERE summary =
            'Left a voicemail about the replacement carburettor.') THEN
        PERFORM * FROM add_communication(
            p_entity_id := v_bob, p_communication_type := 'note', p_direction := 'internal',
            p_subject := 'Voicemail, no answer',
            p_summary := 'Left a voicemail about the replacement carburettor.',
            p_channel := 'phone', p_agent_id := 'customer_service',
            p_outcome := 'pending', p_started_at := now() - interval '12 days');
    END IF;

    ------------------------------------------------------------------
    -- Carol: unhappy, escalated, still open. This is the row the sentiment and escalation rules
    -- in the requirements document are about, and before 0022 it would not have reached the
    -- follow-up list at all.
    ------------------------------------------------------------------
    IF v_carol IS NOT NULL AND NOT EXISTS (SELECT 1 FROM communications WHERE summary =
            'Shipment arrived three weeks late and two cases were damaged.') THEN
        PERFORM * FROM add_communication(
            p_entity_id := v_carol, p_communication_type := 'email', p_direction := 'inbound',
            p_subject := 'Damaged delivery',
            p_summary := 'Shipment arrived three weeks late and two cases were damaged.',
            p_full_content := 'Second delivery this quarter with damage. Wants the freight claim '
                              'filed and a credit for the rush order she did not get.',
            p_channel := 'email', p_agent_id := 'customer_service',
            p_sentiment_label := 'negative', p_priority := 'high',
            p_outcome := 'escalated', p_started_at := now() - interval '5 days');
    END IF;
    IF v_carol IS NOT NULL AND NOT EXISTS (SELECT 1 FROM communications WHERE summary =
            'Called to say the credit memo was issued; she is checking her bank.') THEN
        PERFORM * FROM add_communication(
            p_entity_id := v_carol, p_communication_type := 'call', p_direction := 'outbound',
            p_subject := 'Credit memo issued',
            p_summary := 'Called to say the credit memo was issued; she is checking her bank.',
            p_channel := 'phone', p_agent_id := 'customer_service',
            p_sentiment_label := 'mixed', p_outcome := 'pending',
            p_started_at := now() - interval '1 day');
    END IF;

    ------------------------------------------------------------------
    -- Delta: marked for follow-up by a human, and the thread is a quote nobody has answered.
    ------------------------------------------------------------------
    IF v_delta IS NOT NULL AND NOT EXISTS (SELECT 1 FROM communications WHERE summary =
            'Asked for a quote on twelve pallet racking units.') THEN
        SELECT communication_id INTO v_c1 FROM add_communication(
            p_entity_id := v_delta, p_communication_type := 'email', p_direction := 'inbound',
            p_subject := 'Racking quote',
            p_summary := 'Asked for a quote on twelve pallet racking units.',
            p_channel := 'email', p_agent_id := 'customer_service',
            p_outcome := 'pending', p_started_at := now() - interval '20 days');
    END IF;
    IF v_delta IS NOT NULL AND NOT EXISTS (SELECT 1 FROM communications WHERE summary =
            'Sent the quote: 12 units, 30-day validity, freight included.') THEN
        PERFORM * FROM add_communication(
            p_entity_id := v_delta, p_communication_type := 'email', p_direction := 'outbound',
            p_subject := 'Racking quote',
            p_summary := 'Sent the quote: 12 units, 30-day validity, freight included.',
            p_channel := 'email', p_agent_id := 'customer_service',
            p_parent_id := (SELECT c.id FROM communications c
                             WHERE c.summary = 'Asked for a quote on twelve pallet racking units.'
                             LIMIT 1),
            p_outcome := 'pending', p_started_at := now() - interval '18 days');
    END IF;

    ------------------------------------------------------------------
    -- Everest: a three-message thread, which is the shape vw_communication_thread exists to
    -- reconstruct and 0021's thread_root_id inheritance was written for.
    ------------------------------------------------------------------
    IF v_everest IS NOT NULL AND NOT EXISTS (SELECT 1 FROM communications WHERE summary =
            'Opening a standing weekly lane from Newark to Buffalo.') THEN
        SELECT communication_id INTO v_c1 FROM add_communication(
            p_entity_id := v_everest, p_communication_type := 'meeting', p_direction := 'inbound',
            p_subject := 'Weekly lane',
            p_summary := 'Opening a standing weekly lane from Newark to Buffalo.',
            p_channel := 'meet', p_agent_id := 'customer_service',
            p_outcome := 'resolved', p_started_at := now() - interval '30 days');
        SELECT communication_id INTO v_c2 FROM add_communication(
            p_entity_id := v_everest, p_communication_type := 'email', p_direction := 'outbound',
            p_subject := 'Weekly lane',
            p_summary := 'Sent the lane schedule and the driver contact list.',
            p_channel := 'email', p_agent_id := 'customer_service',
            p_parent_id := v_c1, p_outcome := 'pending',
            p_started_at := now() - interval '28 days');
        -- The third message is the one that proves inheritance: its parent has a root that is not
        -- itself, and the root it lands on has to be v_c1.
        PERFORM * FROM add_communication(
            p_entity_id := v_everest, p_communication_type := 'call', p_direction := 'inbound',
            p_subject := 'Weekly lane',
            p_summary := 'Confirmed the first pickup for Tuesday, asked to bill monthly.',
            p_channel := 'phone', p_agent_id := 'customer_service',
            p_parent_id := v_c2, p_outcome := 'resolved',
            p_sentiment_label := 'positive', p_started_at := now() - interval '26 days');
    END IF;

    ------------------------------------------------------------------
    -- Farid: one old note, and nothing since. Email-only, so a phone lookup must miss honestly.
    ------------------------------------------------------------------
    IF v_farid IS NOT NULL AND NOT EXISTS (SELECT 1 FROM communications WHERE summary =
            'Chatted about whether he needs the extended warranty.') THEN
        PERFORM * FROM add_communication(
            p_entity_id := v_farid, p_communication_type := 'chat', p_direction := 'inbound',
            p_subject := 'Warranty question',
            p_summary := 'Chatted about whether he needs the extended warranty.',
            p_channel := 'web', p_agent_id := 'customer_service',
            p_outcome := 'closed', p_started_at := now() - interval '55 days');
    END IF;

    ------------------------------------------------------------------
    -- Grace: closed out. The last interaction says so, because her status says do not contact.
    ------------------------------------------------------------------
    IF v_grace IS NOT NULL AND NOT EXISTS (SELECT 1 FROM communications WHERE summary =
            'Account closed at her request; no further contact unless she writes in.') THEN
        PERFORM * FROM add_communication(
            p_entity_id := v_grace, p_communication_type := 'note', p_direction := 'internal',
            p_subject := 'Account closed',
            p_summary := 'Account closed at her request; no further contact unless she writes in.',
            p_agent_id := 'customer_service', p_outcome := 'closed',
            p_priority := 'low', p_started_at := now() - interval '9 days');
    END IF;

    ------------------------------------------------------------------
    -- The backdates, stated. Every interaction above was written now about something that
    -- happened weeks ago, which means created_at is this instant and started_at is the truth.
    -- A reader who wants the row's age should ask created_at; a reader who wants the
    -- conversation's age asks started_at, and 0022 is the reason those are different questions.
    ------------------------------------------------------------------
    SELECT count(*) INTO v_c1 FROM communications;
    RAISE NOTICE 'seed: % communications rows, all written this instant about interactions up to '
                 '55 days ago - created_at and started_at disagree by design', v_c1;
END
$$;

-- ---------------------------------------------------------------------------
-- 3. What the seed leaves behind
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    RAISE NOTICE 'seed: % customers / % contacts / % interactions / % of them stale at 7 days',
        (SELECT count(*) FROM entities WHERE entity_type = 'customer'),
        (SELECT count(*) FROM contacts),
        (SELECT count(*) FROM communications),
        (SELECT count(*) FROM get_followup_customers(7));
    -- The check that the demo data is actually usable by the agent, rather than merely present:
    -- every customer the lookup tool can name must have a primary contact, because vw_customers
    -- joins through one and get_followup_customers joins the same way (0022 §"what this file does
    -- NOT change"). A customer here without one would be invisible to the tools and the seed
    -- would be lying about what it demoed.
    IF (SELECT count(*) FROM entities e WHERE e.entity_type = 'customer'
          AND NOT EXISTS (SELECT 1 FROM entity_relationships er
                           WHERE er.entity_id = e.id AND er.is_primary)) <> 0 THEN
        RAISE EXCEPTION 'seed: a customer has no primary contact and is therefore invisible to '
                        'vw_customers and get_followup_customers - fix the door that let it happen';
    END IF;
END
$$;
