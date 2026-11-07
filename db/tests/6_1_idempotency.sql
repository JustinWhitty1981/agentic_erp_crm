-- Finding 6.1, as behaviour: "idempotency is adopted on paper and absent in data".
--
-- ADR-005 mandates a test this file is the home for - "call every mutating operation twice and
-- assert the second call produces the same result and no additional side effects" - and the
-- review's evidence was an inventory: no dedup table, no request ids, two version columns nothing
-- ever assigns. An inventory cannot answer the question it is asked to settle, though: it shows
-- the objects are missing, not whether a retry of the real operations ran the work twice. So
-- every block below PERFORMS a call and its replay, and the verdict is counted from the side
-- effect (a row that exists once or twice), never from a status string that a broken mechanism
-- could print correctly.
--
-- The harness connects as postgres, a superuser, which bypasses row security even under 0009's
-- FORCE. That is worth stating because it changes what blocks D and the header's measurement can
-- prove here: with no policy filtering, the tenant isolation an agent actually gets is the one
-- coded into idempotency_claim's own WHERE clauses - which is exactly the surface block D tests,
-- and the reason the 5.7 harness is where cross-role visibility gets measured instead.
--
-- Pre-0011 the mechanism does not exist, so blocks A-D and F-G cannot reach their behaviour and
-- their guard branch emits the same mapped phrase their failure branch would; the harness then
-- reports each as KNOWN-OPEN, which is honest - the finding reproduces because there is nothing
-- to replay against. Post-0011 the guards fall through and the sentences mean what they measure.
-- Each VERDICT ERR phrase is written to appear ONLY on the failure branch, because
-- scripts/db/test-functions.sh decides KNOWN-OPEN against CLOSED with a grep, not a parser.

-- A. ADR-005's mandated test, first and last: replay a mutation and count the row. The claim
--    states are never asserted directly - a mechanism that answers 'replay' while also letting
--    the work run is the worst variant of this bug, and it would pass a status-string test.
BEGIN;
DO $$
DECLARE
    v_key    uuid := gen_random_uuid();
    v_req    jsonb := '{"name": "6_1 replay probe"}'::jsonb;
    v_claim  uuid;
    v_token  uuid;
    v_state  text;
    v_cached jsonb;
    v_n      integer;
BEGIN
    IF to_regclass('public.idempotency_keys') IS NULL THEN
        RAISE NOTICE 'VERDICT ERR a replayed mutation performs its work twice - nothing in the '
                     'schema recognises the second call, so a retry after a timeout is a second '
                     'customer (6.1, ADR-005)';
        RETURN;
    END IF;

    -- Attempt 1: claim, do the work, record the answer.
    SELECT claim_state, claim_id, current_token INTO v_state, v_claim, v_token
      FROM idempotency_claim(v_key, '6_1:add_customer', v_req);
    IF v_state <> 'claimed' THEN
        RAISE NOTICE 'VERDICT ERR a first-ever claim did not authorise the work (reported %), so '
                     'the replay below tests nothing', v_state;
        RETURN;
    END IF;
    INSERT INTO entities (name, entity_type, status)
        VALUES ('6_1 replay probe', 'customer', 'active');
    PERFORM idempotency_complete(v_claim, v_token,
                                 '{"created": "6_1 replay probe"}'::jsonb, true, NULL);

    -- Attempt 2: the caller's socket dropped, so it retries. The contract is: execute only if
    -- the claim says claimed. Anything else the retry sees means it runs the work again.
    SELECT claim_state, cached_response INTO v_state, v_cached
      FROM idempotency_claim(v_key, '6_1:add_customer', v_req);
    IF v_state = 'claimed' THEN
        INSERT INTO entities (name, entity_type, status)
            VALUES ('6_1 replay probe', 'customer', 'active');
    END IF;
    SELECT count(*) INTO v_n FROM entities WHERE name = '6_1 replay probe';
    IF v_n <> 1 THEN
        RAISE NOTICE 'VERDICT ERR a replayed mutation performs its work twice - the entity now '
                     'exists % times, which is 6.1 measured as rows, not as a status column', v_n;
    ELSE
        RAISE NOTICE 'VERDICT OK the retry was answered with state % and the first attempt''s '
                     'payload - the work exists exactly once', v_state;
    END IF;
END
$$;
ROLLBACK;

-- B. The fingerprint. A key is a request identity, so a DIFFERENT request reusing a settled key
--    must never be answered from the cache: that is the one failure mode where an idempotency
--    table actively corrupts instead of merely failing to help.
BEGIN;
DO $$
DECLARE
    v_key   uuid := gen_random_uuid();
    v_claim uuid;
    v_token uuid;
    v_state text;
BEGIN
    IF to_regclass('public.idempotency_keys') IS NULL THEN
        RAISE NOTICE 'VERDICT ERR the same key reused for a different request answers from the '
                     'cache - there is no request fingerprint to notice the difference';
        RETURN;
    END IF;
    SELECT claim_id, current_token INTO v_claim, v_token
      FROM idempotency_claim(v_key, '6_1:probe', '{"a":1}'::jsonb);
    PERFORM idempotency_complete(v_claim, v_token, '{"answer":"first"}'::jsonb, true, NULL);
    SELECT claim_state INTO v_state
      FROM idempotency_claim(v_key, '6_1:probe', '{"a":2}'::jsonb);
    IF v_state = 'replay' THEN
        RAISE NOTICE 'VERDICT ERR the same key reused for a different request answers from the '
                     'cache - the second caller received an answer it never asked for';
    ELSE
        RAISE NOTICE 'VERDICT OK a payload change on a settled key reported %, so the cached '
                     'answer cannot be served to a different request', v_state;
    END IF;
END
$$;
ROLLBACK;

-- C. The lease, both directions: a dead attempt must not wedge the key forever, and the attempt
--    it displaced must not be able to certify work that ran twice. The lease is pinned into the
--    past rather than waited out - now() is the transaction timestamp, so sleeping proves
--    nothing inside one transaction anyway.
BEGIN;
DO $$
DECLARE
    v_key    uuid := gen_random_uuid();
    v_claim  uuid;
    v_tok1   uuid;
    v_tok2   uuid;
    v_state  text;
    v_fenced boolean := true;
BEGIN
    IF to_regclass('public.idempotency_keys') IS NULL THEN
        -- Both of this block's mapped phrases, because the harness decides KNOWN-OPEN from a
        -- grep: a phrase that only a POST-0011 failure branch can print would read as SURPRISE
        -- ("stopped reproducing with no migration to explain why") on the pre-0011 database,
        -- where its behaviour has no code path at all. The second sentence therefore names the
        -- absence, not the race.
        RAISE NOTICE 'VERDICT ERR a crashed attempt owns its key forever - the lease exists so '
                     'that a dead claim can be taken over, and there is no claim to take over';
        RAISE NOTICE 'VERDICT ERR a displaced attempt can still certify work that ran twice - '
                     'there is no token to fence a stale completion with';
        RETURN;
    END IF;
    SELECT claim_id, current_token INTO v_claim, v_tok1
      FROM idempotency_claim(v_key, '6_1:crash', NULL);
    SELECT claim_state INTO v_state FROM idempotency_claim(v_key, '6_1:crash', NULL);
    IF v_state <> 'in_progress' THEN
        RAISE NOTICE 'VERDICT ERR a crashed attempt owns its key forever - a second caller was '
                     'handed live work as %, so both ran it', v_state;
        RETURN;
    END IF;

    UPDATE idempotency_keys SET lease_expires_at = now() - interval '1 minute'
     WHERE id = v_claim;
    SELECT claim_state, current_token INTO v_state, v_tok2
      FROM idempotency_claim(v_key, '6_1:crash', NULL);
    IF v_state <> 'claimed' OR v_tok2 = v_tok1 THEN
        RAISE NOTICE 'VERDICT ERR a crashed attempt owns its key forever - after the lease '
                     'lapsed a re-claim reported %', v_state;
        RETURN;
    END IF;

    -- The displaced attempt wakes up and completes. Accepting that would make the table certify
    -- an operation that ran twice as one that ran once.
    BEGIN
        PERFORM idempotency_complete(v_claim, v_tok1, '{"late":true}'::jsonb, true, NULL);
        v_fenced := false;
    EXCEPTION
        WHEN exclusion_violation THEN NULL;    -- required: the stale attempt is refused
    END;
    IF NOT v_fenced THEN
        RAISE NOTICE 'VERDICT ERR a displaced attempt can still certify work that ran twice - '
                     'its stale completion was accepted after a take-over rotated the claim';
    ELSE
        PERFORM idempotency_complete(v_claim, v_tok2, '{"won":true}'::jsonb, true, NULL);
        RAISE NOTICE 'VERDICT OK a lapsed lease was taken over with a fresh token and the '
                     'displaced attempt''s completion was refused';
    END IF;
END
$$;
ROLLBACK;

-- D. The arbiter's scope, asserted as behaviour. A global claim index under forced row security
--    loses writes silently (0011 proved it on a clone: INSERT 0 0, nothing visible to the second
--    tenant), so two tenants using the same key must each get their own claim, in their own
--    rows. See the header note about superuser RLS bypass - this is the code-level half of the
--    guarantee; the policy-level half is the 5.7 harness.
BEGIN;
DO $$
DECLARE
    v_key   uuid := gen_random_uuid();
    v_a     uuid := afpc_current_tenant();
    v_b     uuid;
    v_state text;
    v_rows  integer;
BEGIN
    IF to_regclass('public.idempotency_keys') IS NULL THEN
        RAISE NOTICE 'VERDICT ERR two tenants collide on one claim key - there is no claim table '
                     'whose arbiter could be tenant-scoped';
        RETURN;
    END IF;
    INSERT INTO tenants (slug, name) VALUES ('probe-6-1-b', '6_1 probe tenant B')
     RETURNING tenant_id INTO v_b;

    SELECT claim_state INTO v_state FROM idempotency_claim(v_key, '6_1:shared', '{"t":1}'::jsonb);
    PERFORM set_config('app.tenant_id', v_b::text, true);
    SELECT claim_state INTO v_state FROM idempotency_claim(v_key, '6_1:shared', '{"t":1}'::jsonb);
    IF v_state <> 'claimed' THEN
        RAISE NOTICE 'VERDICT ERR two tenants collide on one claim key - tenant B was told % for '
                     'a key only tenant A had touched', v_state;
    ELSE
        SELECT count(*) INTO v_rows FROM idempotency_keys WHERE idempotency_key = v_key;
        IF v_rows <> 2 THEN
            RAISE NOTICE 'VERDICT ERR two tenants collide on one claim key - both claimed it but '
                         'the arbiter holds % row(s), not one per tenant', v_rows;
        ELSE
            RAISE NOTICE 'VERDICT OK the same key claimed in two tenants produced two '
                         'independent claims and neither answered the other';
        END IF;
    END IF;
    PERFORM set_config('app.tenant_id', v_a::text, true);
END
$$;
ROLLBACK;

-- E. ADR-005 pattern 3, the half 6.1 measured as decoration: the version columns exist and
--    nothing has ever assigned them. Asserting the COUNTER is what makes a stale write
--    detectable, so the block checks the write it gates, not just the integer.
BEGIN;
DO $$
DECLARE
    v_it   uuid;
    v_wh   uuid;
    v_ver  integer;
BEGIN
    INSERT INTO warehouses (warehouse_code, name, warehouse_type)
        VALUES ('AFPC-61T', '6_1 probe warehouse', 'PRIMARY') RETURNING warehouse_id INTO v_wh;
    INSERT INTO inventory_items (sku, name, product_type)
        VALUES ('AFPC-61I', '6_1 probe item', 'STOCKED') RETURNING item_id INTO v_it;
    INSERT INTO inventory_on_hand (item_id, warehouse_id, quantity_on_hand, quantity_reserved)
        VALUES (v_it, v_wh, 10, 0);
    UPDATE inventory_on_hand SET quantity_on_hand = 9 WHERE item_id = v_it AND warehouse_id = v_wh;
    SELECT version INTO v_ver FROM inventory_on_hand WHERE item_id = v_it AND warehouse_id = v_wh;
    IF v_ver IS NOT DISTINCT FROM 1 THEN
        RAISE NOTICE 'VERDICT ERR the version columns remain decoration - a write left the '
                     'counter at %, which is 6.1''s measurement, so no write can check one', v_ver;
    ELSE
        -- The stale write: the version the first writer saw is now superseded, and an update
        -- carrying it must match nothing.
        UPDATE inventory_on_hand SET quantity_on_hand = 1
         WHERE item_id = v_it AND warehouse_id = v_wh AND version = 1;
        IF (SELECT quantity_on_hand FROM inventory_on_hand
             WHERE item_id = v_it AND warehouse_id = v_wh) <> 9 THEN
            RAISE NOTICE 'VERDICT ERR the version columns remain decoration - the counter moves '
                         'but a write carrying an already-superseded version still landed';
        ELSE
            RAISE NOTICE 'VERDICT OK version now counts writes (%) and a stale-version write '
                         'changed nothing, which makes lost updates detectable', v_ver;
        END IF;
    END IF;
END
$$;
ROLLBACK;

-- F. ADR-005's own required condition: a clear policy for key lifetime and garbage collection.
--    The policy is two clocks, and the sweep must tell them apart: collect what is expired
--    history, keep what is merely unclaimed work.
BEGIN;
DO $$
DECLARE
    v_gone integer;
    v_n    integer;
BEGIN
    IF to_regclass('public.idempotency_keys') IS NULL THEN
        RAISE NOTICE 'VERDICT ERR expired claims are never collected - there is no dedup table '
                     'to have a retention policy, so the finding is the whole of ADR-005''s '
                     'garbage-collection clause';
        RETURN;
    END IF;
    -- Baseline first, and this is not cosmetics. The sweep collects EVERY expired claim, and a
    -- database with agents actually running on it has expired claims of its own. Until 2026-11-07
    -- nothing in any backend called idempotency_sweep at all (0011's retention clock "runs for nobody
    -- unless someone schedules it", db/MIGRATIONS.md), so they piled up until a probe like this one
    -- counted them - which is how this case went from CLOSED to a false alarm the day the acceptance
    -- harness left seven expired add_customer claims behind it: the assertion was "the sweep deleted 1",
    -- and the honest answer was 8. Now `agents/sales`' hourly keeper runs it as `afpc_app` (0031), which
    -- changes the reason the baseline is needed and not the need: this block sweeps as the OWNER, under
    -- no tenant binding, so it collects every tenant's expired history in one statement, and the count
    -- it reports would otherwise be that collection plus the fixture's row. Emptying the field first
    -- makes v_gone mean the rows inserted below, and costs nothing, because the DELETE is inside the
    -- transaction this block rolls back.
    PERFORM idempotency_sweep();
    INSERT INTO idempotency_keys (idempotency_key, tenant_id, operation, request_hash, status,
                                  lease_expires_at, expires_at)
    VALUES (gen_random_uuid(), afpc_current_tenant(), '6_1:old', 'h', 'completed',
            now() - interval '3 days', now() - interval '2 days'),
           (gen_random_uuid(), afpc_current_tenant(), '6_1:dead', 'h', 'in_flight',
            now() - interval '10 minutes', now() + interval '23 hours');
    v_gone := idempotency_sweep();
    IF v_gone <> 1 THEN
        RAISE NOTICE 'VERDICT ERR expired claims are never collected - the sweep deleted % rows '
                     'where the retention clock said exactly 1', v_gone;
    ELSE
        SELECT count(*) INTO v_n FROM idempotency_keys WHERE operation = '6_1:dead';
        IF v_n <> 1 THEN
            RAISE NOTICE 'VERDICT ERR expired claims are never collected - the sweep also deleted '
                         'the claim that was only past its LEASE, erasing evidence of unfinished '
                         'work';
        ELSE
            RAISE NOTICE 'VERDICT OK the sweep collected exactly the expired history and left '
                         'the unclaimed work visible';
        END IF;
    END IF;
END
$$;
ROLLBACK;

-- G. The register. 6.1's sentence is about OPERATIONS, and before 0011 the honest answer to
--    "is this call idempotent" was a document reading. One query must now enumerate every
--    state-changing function and what guards it has, even when the answer is UNGUARDED - a gap
--    an agent can measure is work; a gap that lives in prose is how ADR-005 stayed paper.
BEGIN;
DO $$
DECLARE
    v_n      integer;
    v_probe  text;
BEGIN
    IF to_regclass('public.vw_idempotency_status') IS NULL THEN
        RAISE NOTICE 'VERDICT ERR no register exists to ask which calls are guarded - 6.1 can '
                     'only be answered by reading migration files';
        RETURN;
    END IF;
    SELECT count(*) INTO v_n FROM vw_idempotency_status;
    IF v_n = 0 THEN
        RAISE NOTICE 'VERDICT ERR no register exists to ask which calls are guarded - the view '
                     'answers the question with nothing, which is how a derived register would '
                     'hide the finding it reports';
    ELSE
        SELECT verdict INTO v_probe FROM vw_idempotency_status WHERE function = 'add_customer'
         ORDER BY verdict LIMIT 1;
        RAISE NOTICE 'VERDICT OK the register answers the question in SQL - % state-changing '
                     'functions, add_customer: %', v_n, coalesce(v_probe, '(not listed)');
    END IF;
END
$$;
ROLLBACK;
