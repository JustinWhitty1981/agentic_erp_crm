-- 0011: make a retried call mean one operation (DATABASE_REVIEW.md 6.1; ADR-005)
--
-- 6.1's finding is that ADR-005 is adopted on paper and absent in data: it mandates idempotency
-- for every operation that changes persistent state, names an `idempotency_keys` table, and asks
-- for optimistic version checks. Measured against this schema: no `%idempot%` object anywhere, no
-- `request_id` in any SQL or Python outside the imported agents/ tree, and two `version` columns
-- that nothing has ever assigned. So retries are still unsafe, which is the defect the ADR was
-- written to close.
--
-- The ADR offers four patterns in a preferred order, and which ones this schema can use turned out
-- to be a measurement rather than a reading:
--
--   1. NATURAL UNIQUENESS + UPSERT - the ADR's first choice, and its example is add_customer with
--      a unique index on email. There is none: the census of unique indexes in public returns
--      "email unique anywhere: NONE", and 0006 indexed contacts.email as a TRIGRAM GIN precisely
--      because add_customer tests `email ILIKE`, which a btree over lower(email) cannot serve. So
--      the preferred pattern is unavailable for the CRM's main write path and pattern 2 is not an
--      optimisation - it is the only door. Making email unique is a customer-identity decision
--      (shared office addresses are legitimate CRM data, and a UNIQUE that a populated database
--      cannot build is a migration that fails on someone's Friday), so it is recorded as owed to
--      the customer-model work rather than smuggled in beside a dedup table.
--   2. CLIENT-SUPPLIED KEY + DEDUP TABLE - what 0011 builds. The arbiter's scope is the part that
--      had to be measured, not reasoned: a dedup table keyed GLOBALLY, under the tenancy 0003
--      established and the row security 0009 forced, silently loses a write. On a clone, tenant A
--      claimed K1, then tenant B claimed K1 with ON CONFLICT DO NOTHING: `INSERT 0 0`, and zero
--      rows visible to B for its own request. No error, no row, no trace - a customer in one
--      tenant can wedge the same key in every other tenant, and the agent cannot tell that
--      anything happened. So the arbiter is (tenant_id, operation, idempotency_key), which is the
--      same conclusion 0003 and 0004 reached for every other unique key in this schema, arrived at
--      here by losing a write on purpose to see whether it would be lost quietly. It would.
--      Note the corollary for indexes: that unique constraint already leads with tenant_id, so
--      this migration deliberately does NOT add idx_idempotency_keys_tenant the way 0003 added
--      one per table - vw_index_redundancy would report it as a prefix of the arbiter, and 0006
--      made that a FAIL. The FK's coverage comes from the constraint the design needed anyway.
--   3. STATE-GUARDED UPDATES - the two version columns. 6.1 measured that no function body ever
--      assigns them, and re-measured here: `inventory_items.version` and
--      `inventory_on_hand.version` are integer NOT NULL DEFAULT 1, and schema_migrations.version
--      is a TEXT primary key that must be excluded by TYPE, not by name, from any loop over
--      "version columns". A trigger installed by derivation covers exactly those two tables.
--   4. REQUEST-LEVEL CACHING - the last resort, folded in as request_hash: the same key replayed
--      with a different payload is a conflict and raises, because returning the first call's
--      answer for a different call would be a lie with a cached face.
--
-- The hash is sha256 over jsonb::text, and one property of that is worth knowing before a retry
-- looks broken: jsonb's text is stable for equal content (measured: {"b":1,"a":2} and
-- {"a":2,"b":1} hash identically, so a reordered dictionary replays rather than conflicting), but
-- 1 and 1.0 are different text and so different hashes. A client that re-serialises a number
-- between the attempt and the retry gets a conflict, not a silent double-execute - it fails in
-- the direction that cannot corrupt data, and loudly.
--
-- Two consequences nobody should have to discover:
--   - 0010's touch trigger loop has already run, so a table created HERE must install
--     afpc_touch_updated_at itself. B11 counts every table with an updated_at column, and this one
--     changes state from in_flight to completed, so it belongs to the rule. It reuses 0010's
--     function rather than writing a second one, which is what B25 exists to keep true.
--   - The version bump and the touch stamp land on the same two tables, and PostgreSQL fires
--     same-timing row triggers in name order: afpc_bump_version before afpc_touch_updated_at. Both
--     assign to NEW and return it, and the bump reads only OLD.version, so the order is not
--     observable - stated because 0010's obligation list asked 0011 to say which order it assumed.

SET client_min_messages TO notice;

-- ---------------------------------------------------------------------------
-- 1. The dedup table
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS idempotency_keys (
    id                uuid         PRIMARY KEY DEFAULT afpc_uuid_v7(),
    tenant_id         uuid         NOT NULL
                                 CONSTRAINT idempotency_keys_tenant_id_fkey
                                 REFERENCES tenants(tenant_id) ON DELETE RESTRICT
                                 DEFAULT afpc_current_tenant(),
    idempotency_key   uuid         NOT NULL,
    operation         text         NOT NULL,
    request_hash      varchar(64)  NOT NULL,
    status            varchar(12)  NOT NULL DEFAULT 'in_flight'
                                 CONSTRAINT idempotency_status_allowed
                                 CHECK (status IN ('in_flight','completed','failed')),
    response          jsonb,
    error_message     text,
    attempts          integer      NOT NULL DEFAULT 1
                                 CONSTRAINT idempotency_attempts_positive
                                 CHECK (attempts > 0),
    -- ADR-005's operational half: "emit metrics for idempotent hit versus new execution to detect
    -- retry storms". Counted here rather than logged elsewhere because this row is already being
    -- read on every replay, so the metric costs one column and cannot disagree with the state it
    -- measures. attempts counts executions, hits count refusals-to-execute; a row where hits
    -- outruns attempts is a caller retrying a call it already made.
    hits              integer      NOT NULL DEFAULT 0
                                 CONSTRAINT idempotency_hits_nonnegative
                                 CHECK (hits >= 0),
    lease_expires_at  timestamptz  NOT NULL,
    expires_at        timestamptz  NOT NULL,
    -- Which attempt currently owns this key. Minted at claim, rotated at take-over, and required
    -- by idempotency_complete. Without it, a worker that stalled past its lease and then woke up
    -- would write its answer over the one the take-over attempt produced, and the table would
    -- record an operation that ran twice as one that ran once. That is the failure this whole
    -- migration exists to prevent, arriving from the opposite direction.
    claim_token       uuid         NOT NULL DEFAULT gen_random_uuid(),
    created_at        timestamptz  NOT NULL DEFAULT now(),
    updated_at        timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT idempotency_keys_scoped
        UNIQUE (tenant_id, operation, idempotency_key),
    -- The invariant that makes the sweep safe to run at any moment. A row whose RETENTION has
    -- lapsed is history and gets deleted; a row whose LEASE has lapsed is an unclaimed operation
    -- and must stay, because deleting it would turn "the worker died" into "nobody ever asked",
    -- which is the difference between a stuck key and a lost customer request. expires_at >=
    -- lease_expires_at is what keeps those two stories from overlapping.
    CONSTRAINT idempotency_lease_inside_retention
        CHECK (expires_at >= lease_expires_at)
);

COMMENT ON TABLE idempotency_keys IS
    'ADR-005 pattern 2, and the mechanism 6.1 measured as absent: one row per request an agent '
    'has been asked to run, so a retry answers with the first attempt''s outcome instead of '
    'performing the operation twice. The arbiter is (tenant_id, operation, idempotency_key) '
    'because a global one loses writes: measured on a clone, tenant B''s claim of a key tenant A '
    'already held returned INSERT 0 0 with no error and nothing visible to B. A key is therefore '
    'unique per tenant per operation, which is also what makes a leaked key from one customer of '
    'this database useless as a denial of service to another. In-flight rows carry a LEASE, not a '
    'lock: an attempt that dies leaves its row in_flight until the lease lapses, at which point '
    'the next claim takes it over rather than waiting for a garbage collector. Built by 0011.';
COMMENT ON COLUMN idempotency_keys.idempotency_key IS
    'The caller''s request identity, supplied by the tool and stable across its retries. Not '
    'generated here: a server-minted key would be a nonce, which is exactly what '
    'inventory_movements.transaction_id turned out to be (see section 5).';
COMMENT ON COLUMN idempotency_keys.operation IS
    'Names the tool, which is added without touching the schema - the same argument 0007 recorded '
    'for leaving bot_actions.action_type free text, so this column carries no CHECK by decision. '
    'It is part of the arbiter, so one request id used by two different tools is two claims, not '
    'a conflict.';
COMMENT ON COLUMN idempotency_keys.request_hash IS
    'sha256 hex over the canonical jsonb text of the request. Its job is not to identify the '
    'request - the key does that - it is to notice when a key has been reused for a DIFFERENT '
    'request and refuse to answer it from a cache. ADR-005 pattern 4, used as a safety check on '
    'pattern 2 rather than as a mechanism of its own.';
COMMENT ON COLUMN idempotency_keys.lease_expires_at IS
    'When an in_flight claim stops meaning "someone is doing this" and starts meaning "someone '
    'probably died doing this". Distinct from expires_at, which is when the ROW stops being a '
    'record of the operation: conflating the two is how a dedup table either wedges a key '
    'permanently after one crash or forgets a completed operation before the retries stop.';
COMMENT ON COLUMN idempotency_keys.expires_at IS
    'The retention policy ADR-005 asks every design of this kind to state. Set at claim time to '
    'now() + lease + retention (15 minutes + 24 hours by default): long enough that a retry storm '
    'and the human "did it go through?" follow-up both land on the cached answer, short enough '
    'that the table cannot become the system''s largest. idempotency_sweep deletes them.';

-- ---------------------------------------------------------------------------
-- 2. Row security, the timestamp rule, and the arbiter's index
-- ---------------------------------------------------------------------------
-- 0009's two obligations, discharged the way it asked. The policy is not decorative here: the
-- claim function below runs as its INVOKER, so this is the predicate that decides whether one
-- tenant can take over another tenant's claim. It is also the reason the arbiter's column order
-- matters twice - once for ON CONFLICT inference (0004's lesson) and once for the policy, which
-- compares tenant_id before any key is consulted.
ALTER TABLE idempotency_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE idempotency_keys FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON public.idempotency_keys AS PERMISSIVE
    FOR ALL TO PUBLIC
    USING (tenant_id = afpc_policy_tenant())
    WITH CHECK (tenant_id = afpc_policy_tenant());

CREATE POLICY audit_read_all ON public.idempotency_keys AS PERMISSIVE
    FOR SELECT TO afpc_auditor, afpc_readonly
    USING (true);

-- 0010's rule, applied by hand because its loop ran in an earlier migration and will not see this
-- table. The column is not history here - a claim moves in_flight -> completed exactly once, so
-- updated_at is "when the claim last changed state" - but the mechanism must be the SAME
-- mechanism, which is what B25 counts.
DROP TRIGGER IF EXISTS afpc_touch_updated_at ON idempotency_keys;
CREATE TRIGGER afpc_touch_updated_at
    BEFORE INSERT OR UPDATE ON idempotency_keys
    FOR EACH ROW EXECUTE FUNCTION afpc_touch_updated_at();

-- No idx_idempotency_keys_tenant, deliberately: 0003 adds one per tenant-coded table, and here it
-- would be a leading prefix of idempotency_keys_scoped, which 0006 made a FAIL and
-- vw_index_redundancy publishes. The FK's leading coverage comes from the arbiter.

-- ---------------------------------------------------------------------------
-- 3. The claim, and what it answers
-- ---------------------------------------------------------------------------
-- idempotency_claim is the whole mechanism: one call tells a retrying agent whether to DO THE
-- WORK, to RETURN an answer it did not produce, or to WAIT. Three of ADR-005's four patterns are
-- reachable from a SQL function without a client library, and pattern 2 is the only one that
-- works here for the CRM write path (section 1), so it is what gets built. The fourth,
-- request-level caching, arrives as request_hash - a guard on this mechanism rather than a second
-- way to deduplicate.
--
-- The order of the branches is load-bearing and came out of the experiment described in the
-- header: a claim that loses the unique-index race returns NO ROWS from its INSERT. Testing that
-- with IF FOUND would be correct; testing the row afterwards would not, because the winning
-- attempt may still be mid-transaction. So the loser takes over only a claim that is provably
-- dead (lapsed lease or recorded failure), and otherwise reads.

-- ---------------------------------------------------------------------------
-- 3. The claim, which is the whole mechanism
-- ---------------------------------------------------------------------------
-- Three of ADR-005's four patterns are reachable from SQL alone, and the first choice - natural
-- uniqueness plus an upsert - is unavailable for the CRM's main write path (section 1). So this
-- is pattern 2, built properly: one call answers a retry with DO THE WORK, RETURN AN ANSWER YOU
-- DID NOT PRODUCE, or WAIT.
--
-- The output column names avoid a specific trap worth stating for the next person: in plpgsql a
-- RETURNS TABLE column IS a variable, and naming it like a column of the table the body queries
-- makes `status` or `response` inside a WHERE bind to the variable instead of the column. So the
-- results are claim_state / claim_id / current_token / cached_response, never status or response.
--
-- The branch ORDER is the design, and each step came from a measurement on a clone:
--   1. Try to own the key. One INSERT, so the mutual exclusion is the unique index - this
--      function takes no lock and cannot deadlock with itself. Measured: a claim that loses the
--      race gets no row back (INSERT 0 0), so the test is `v_new_id IS NULL`, not FOUND.
--   2. Read the row that beat us.
--   3. Same key, different payload -> 'conflict'. Refuse rather than choose: the key names a
--      request, so answering a different request from the cache would make "did my retry run?"
--      permanently unanswerable - the one question this table must always be able to answer.
--   4. Completed -> 'replay' with the stored answer, and `hits` incremented, because ADR-005's
--      operational half asks for idempotent-hit versus new-execution metrics and this row is the
--      only place that knows whether work was skipped.
--   5. Otherwise take over ONLY a provably dead claim - lease lapsed, or a failure was recorded -
--      rotating current_token so the displaced attempt cannot write its answer over this one's.
--   6. Still in flight and still leased -> 'in_progress'. Running now would duplicate the side
--      effect, which is the defect the ADR exists to close, so the honest answer is "wait".
CREATE OR REPLACE FUNCTION idempotency_claim(
    p_idempotency_key  uuid,
    p_operation        text,
    p_request          jsonb     DEFAULT NULL,
    p_lease            interval  DEFAULT interval '5 minutes',
    p_retention        interval  DEFAULT interval '24 hours'
) RETURNS TABLE(claim_state text, claim_id uuid, current_token uuid, cached_response jsonb)
LANGUAGE plpgsql
AS $fn$
DECLARE
    -- Coalesced to the literal 'null', not left NULL: convert_to(NULL) makes digest() NULL, and a
    -- NULL hash compares DISTINCT from everything, so every claim of a bodiless operation would
    -- report 'conflict' and the table would refuse the retries it was built to absorb.
    v_hash       varchar(64) := encode(
                     digest(convert_to(coalesce(p_request::text, 'null'), 'UTF8'), 'sha256'), 'hex');
    v_new_id     uuid;
    v_new_token  uuid;
    v_row        record;
BEGIN
    ------------------------------------------------------------------
    -- The ADR's word is "Required". A NULL key is not a retry of anything - it is an operation
    -- with no identity, and the NOT NULL column would report that as a constraint violation
    -- pointing at the wrong thing. Say what is missing instead.
    ------------------------------------------------------------------
    IF p_idempotency_key IS NULL THEN
        RAISE EXCEPTION 'idempotency_claim: p_idempotency_key is NULL for operation %',
                        coalesce(p_operation, '(unnamed)')
            USING HINT = 'ADR-005 requires the caller to supply a key that is stable across its '
                         'retries. A server-generated value is not one: 6.1 measured exactly that '
                         'mistake in inventory_movements.transaction_id.';
    END IF;

    INSERT INTO idempotency_keys AS ik
            (idempotency_key, tenant_id, operation, request_hash, status,
             lease_expires_at, expires_at)
    VALUES  (p_idempotency_key, afpc_current_tenant(), p_operation, v_hash, 'in_flight',
             now() + p_lease, now() + p_lease + p_retention)
    ON CONFLICT (tenant_id, operation, idempotency_key) DO NOTHING
    RETURNING ik.id, ik.claim_token INTO v_new_id, v_new_token;

    IF v_new_id IS NOT NULL THEN
        RETURN QUERY SELECT 'claimed'::text, v_new_id, v_new_token, NULL::jsonb;
        RETURN;
    END IF;

    -- No conflict was inferred, so a row exists for this (tenant, operation, key). Read it under
    -- the caller's own row security: 0009's policy is what keeps a take-over attempt from ever
    -- seeing another tenant's claim, which is why the arbiter leads with tenant_id.
    SELECT ik.id, ik.status, ik.request_hash, ik.response, ik.lease_expires_at, ik.claim_token
      INTO v_row
      FROM idempotency_keys ik
     WHERE ik.tenant_id = afpc_current_tenant()
       AND ik.operation = p_operation
       AND ik.idempotency_key = p_idempotency_key;

    IF NOT FOUND THEN
        -- The INSERT said a row exists and the SELECT says it does not. That is REPEATABLE READ:
        -- the winning transaction committed after this one's snapshot, so the conflict was real
        -- but its row is not yet visible here. Report the wait rather than crashing a caller whose
        -- isolation level is someone else's decision; under the default READ COMMITTED, or on the
        -- retry, this branch is unreachable.
        RETURN QUERY SELECT 'in_progress'::text, NULL::uuid, NULL::uuid, NULL::jsonb;
        RETURN;
    END IF;

    IF v_row.request_hash IS DISTINCT FROM v_hash THEN
        RETURN QUERY SELECT 'conflict'::text, v_row.id, NULL::uuid, NULL::jsonb;
        RETURN;
    END IF;

    IF v_row.status = 'completed' THEN
        UPDATE idempotency_keys SET hits = hits + 1 WHERE id = v_row.id;
        RETURN QUERY SELECT 'replay'::text, v_row.id, v_row.claim_token, v_row.response;
        RETURN;
    END IF;

    UPDATE idempotency_keys AS ik
       SET status           = 'in_flight',
           lease_expires_at = now() + p_lease,
           expires_at       = GREATEST(ik.expires_at, now() + p_lease + p_retention),
           attempts         = ik.attempts + 1,
           claim_token      = gen_random_uuid(),
           error_message    = NULL
     WHERE ik.id = v_row.id
       AND ik.status <> 'completed'
       AND (ik.lease_expires_at <= now() OR ik.status = 'failed')
    RETURNING ik.id, ik.claim_token INTO v_new_id, v_new_token;

    IF v_new_id IS NOT NULL THEN
        RETURN QUERY SELECT 'claimed'::text, v_new_id, v_new_token, NULL::jsonb;
        RETURN;
    END IF;

    RETURN QUERY SELECT 'in_progress'::text, v_row.id, NULL::uuid, NULL::jsonb;
END
$fn$;

COMMENT ON FUNCTION idempotency_claim IS
    'ADR-005 pattern 2, the only dedup pattern this schema can use for its CRM write path: call it '
    'before the work and it returns claimed (do the work, you own the key), replay (someone '
    'already did it, here is the stored answer, hits incremented), in_progress (a live attempt '
    'holds the key, so running now would duplicate the side effect), or conflict (this key has '
    'already been used for a DIFFERENT request, which is a caller bug and is never answered from '
    'the cache). Mutual exclusion is the idempotency_keys_scoped unique index, not a lock, so two '
    'concurrent claims cannot both return claimed and the function cannot deadlock with itself. '
    'The lease is a crash affordance: an attempt that dies leaves an in_flight row, and the next '
    'claim takes it over once the lease lapses, rotating the token. The payload identity is '
    'sha256 over the jsonb text, so reordered dictionary keys replay (jsonb normalises them) but '
    '1 and 1.0 conflict (they are different text) - it fails toward refusing to guess. Intended '
    'to be called in the same transaction as the work it guards, with idempotency_complete at the '
    'end; see the claim-token note in idempotency_complete.';

-- ---------------------------------------------------------------------------
-- 4. Completing the work, which is where a naive design loses the race twice
-- ---------------------------------------------------------------------------
-- Two hazards this function exists to close, both of them the reason "insert a row, then update
-- it" is not yet an idempotency protocol:
--
--   A. THE DISPLACED ATTEMPT. A claims, stalls longer than its lease, B takes the key over and
--      finishes. A wakes up and completes. Without a token check, A writes its answer over B's
--      and the table now certifies an operation that ran twice. So complete requires the token it
--      was given at claim time, and raises when the row has moved on - the caller learns the
--      truth instead of recording a falsehood.
--   B. THE RETRIED COMPLETION. The caller's own network dropped, so it replays complete. That
--      must be a no-op, not a second write, and not an error: the same token, the same answer,
--      nothing to change. 0005's idempotency argument applied to the bookkeeping itself.
CREATE OR REPLACE FUNCTION idempotency_complete(
    p_claim_id     uuid,
    p_token        uuid,
    p_response     jsonb    DEFAULT NULL,
    p_success      boolean  DEFAULT true,
    p_error        text     DEFAULT NULL,
    p_retention    interval DEFAULT interval '24 hours'
) RETURNS text
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_row record;
BEGIN
    SELECT ik.status, ik.claim_token, ik.response
      INTO v_row
      FROM idempotency_keys ik
     WHERE ik.id = p_claim_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'idempotency_complete: claim % does not exist', p_claim_id
            USING HINT = 'It was swept as expired, or the id from idempotency_claim was mistyped. '
                         'Complete the work again from a fresh claim.';
    END IF;

    IF v_row.claim_token <> p_token THEN
        RAISE EXCEPTION 'idempotency_complete: claim % was taken over by another attempt '
                        '(status now %); this attempt''s answer will not be stored',
                        p_claim_id, v_row.status
            USING ERRCODE = 'exclusion_violation',
                  HINT = 'The lease lapsed while this attempt was running, so a second attempt '
                         'was allowed to start. Shorten the work or lengthen p_lease.';
    END IF;

    IF v_row.status <> 'in_flight' THEN
        IF v_row.response IS NOT DISTINCT FROM p_response
           AND (p_success OR v_row.status = 'failed') THEN
            RETURN v_row.status;              -- B: a replay of this same completion
        END IF;
        RAISE EXCEPTION 'idempotency_complete: claim % is already %, and the answer differs',
                        p_claim_id, v_row.status
            USING ERRCODE = 'check_violation';
    END IF;

    UPDATE idempotency_keys
       SET status           = CASE WHEN p_success THEN 'completed' ELSE 'failed' END,
           response         = p_response,
           error_message    = p_error,
           lease_expires_at = now(),
           expires_at       = GREATEST(expires_at, now() + p_retention)
     WHERE id = p_claim_id;

    RETURN CASE WHEN p_success THEN 'completed' ELSE 'failed' END;
END
$fn$;

COMMENT ON FUNCTION idempotency_complete IS
    'Closes a claim taken out by idempotency_claim, storing the answer a replay will be served '
    'from. Requires the token the claim handed back: an attempt whose lease lapsed and whose key '
    'was taken over is refused rather than allowed to overwrite the winner, which is the failure '
    'mode that would otherwise make this whole table a record of operations that ran twice. '
    'Replaying the same completion is a no-op returning the current status. p_success=false '
    'records a failure and leaves the row claimable at once, so a retry does not have to wait out '
    'the lease for work that provably did not happen.';

-- ---------------------------------------------------------------------------
-- 5. The version columns, which 6.1 found installed and decorative
-- ---------------------------------------------------------------------------
-- 6.1's measurement was that inventory_items.version and inventory_on_hand.version exist and that
-- a search of every function body for an assignment to them returns nothing. Re-measured here,
-- and the population is exactly those two: schema_migrations.version is a TEXT primary key, which
-- is why this loop filters on atttypid rather than on the column name - a name-only loop would
-- have tried to install an integer counter on the migration ledger and produced a trigger that
-- either fails or corrupts the record of what has been applied.
CREATE OR REPLACE FUNCTION afpc_bump_version()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        NEW.version := OLD.version + 1;
    END IF;
    RETURN NEW;
END
$$;

COMMENT ON FUNCTION afpc_bump_version IS
    'Makes the version columns mean what they claim (ADR-005 pattern 3, review 6.1): a BEFORE '
    'UPDATE row trigger setting NEW.version := OLD.version + 1, installed on every table whose '
    'version column is an integer. Unconditional, deliberately, and computed from its own counter: '
    '0010 only stamps updated_at when the statement did not set it, because a backfill legitimately '
    'carries historical timestamps, but a version number is not history - a statement that could '
    'choose the next version could choose one that matches what a concurrent reader already saw, '
    'which would make the lock lie. Order note that 0010 asked for: on inventory_on_hand this '
    'fires before afpc_touch_updated_at (both are BEFORE ROW UPDATE, PostgreSQL uses name order, '
    'and "bump" precedes "touch"), and neither reads the other''s column, so the order is not '
    'observable.';

DO $$
DECLARE
    t   text;
    v_n int := 0;
BEGIN
    FOR t IN SELECT c.relname
               FROM pg_class c
               JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'version'
                                  AND a.attnum > 0 AND NOT a.attisdropped
                                  AND a.atttypid = 'integer'::regtype
              WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r'
              ORDER BY 1
    LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS afpc_bump_version ON public.%I', t);
        EXECUTE format($f$CREATE TRIGGER afpc_bump_version
                             BEFORE UPDATE ON public.%I
                             FOR EACH ROW EXECUTE FUNCTION afpc_bump_version()$f$, t);
        v_n := v_n + 1;
    END LOOP;

    IF v_n <> 2 THEN
        RAISE EXCEPTION 'installed the version counter on % tables, expected 2 - 6.1 measured '
                        'inventory_items and inventory_on_hand, and schema_migrations.version is '
                        'excluded by TYPE (text primary key), not by name. A different number '
                        'means another table gained or lost a version column', v_n;
    END IF;
    RAISE NOTICE '6.1: afpc_bump_version installed on % tables - the columns that were '
                 'decoration now count writes', v_n;
END
$$;

-- ---------------------------------------------------------------------------
-- 6. The lifetime policy ADR-005 asks to be stated, and the collector for it
-- ---------------------------------------------------------------------------
-- A dedup table's failure mode is that it becomes the largest table in the database: every
-- mutation leaves a row behind, forever. The policy stated here is two clocks and a sweeper.
--
--   lease_expires_at   how long a claim means "someone is doing this". 5 minutes by default,
--                      because the operations it guards are single-row CRM writes and inventory
--                      movements - anything still running after five minutes is a stuck
--                      transaction, not slow work, and the next attempt should be allowed to take
--                      the key over rather than wait for a collector.
--   expires_at         how long the ROW means "this request was answered". lease + 24 hours by
--                      default: long enough that a retry storm and the human "did it go through?"
--                      follow-up both land on the cached answer, short enough that the table is
--                      bounded by request volume times a day, not by the age of the deployment.
--
-- idempotency_sweep enforces the second clock only. It never deletes a row whose LEASE still has
-- value - see the CHECK constraint that makes those two states mutually exclusive in the table.
CREATE OR REPLACE FUNCTION idempotency_sweep(p_now timestamptz DEFAULT now())
RETURNS integer
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_deleted integer;
    v_stale   integer;
BEGIN
    DELETE FROM idempotency_keys
     WHERE expires_at <= p_now;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;

    -- Reportable without being deleted: keys whose lease lapsed while still in_flight. Those are
    -- the operations nobody finished, and the count is the only way anyone will notice them.
    SELECT count(*) INTO v_stale FROM idempotency_keys
     WHERE status = 'in_flight' AND lease_expires_at <= p_now;
    IF v_stale > 0 THEN
        RAISE NOTICE 'idempotency_sweep: % claims past their lease are still in_flight at % - '
                     'nobody ran their work, they remain claimable', v_stale, p_now;
    END IF;

    RETURN v_deleted;
END
$fn$;

COMMENT ON FUNCTION idempotency_sweep IS
    'Deletes idempotency_keys rows whose retention has lapsed and returns the count; the policy it '
    'enforces is stated on the table (5-minute lease, lease plus 24 hours retention). It runs as '
    'its invoker, so under 0009 row security a sweep by afpc_app collects that tenant''s rows and '
    'a sweep by the owner collects everything - which is the right split for a table whose whole '
    'job is per-tenant request identity. Expired-but-still-in_flight claims are left alone (they '
    'are unclaimed work, not history) and reported as a NOTICE. Nothing here schedules itself: '
    'there is no cron object in this schema, and inventing one in a migration would be a second '
    'place for the retention policy to live.';

-- ---------------------------------------------------------------------------
-- 7. Privileges: 0009's obligation, and the case where its answer flips
-- ---------------------------------------------------------------------------
-- 0010 revoked its trigger function from PUBLIC and granted it to nobody, because a trigger body
-- is run by the executor and its EXECUTE is not privilege-checked against the invoker - measured
-- there. These three functions are the opposite case: they are the API, called directly by the
-- agent role, so the grant is load-bearing. Rehearsing it is not paranoia: 0009 measured that a
-- missing EXECUTE surfaces as "permission denied for function" in the middle of an ordinary
-- statement, and the last thing a retry mechanism needs is to fail only in production.
REVOKE EXECUTE ON FUNCTION idempotency_claim(uuid, text, jsonb, interval, interval) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION idempotency_complete(uuid, uuid, jsonb, boolean, text, interval) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION idempotency_sweep(timestamptz) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION idempotency_claim(uuid, text, jsonb, interval, interval) TO afpc_app;
GRANT  EXECUTE ON FUNCTION idempotency_complete(uuid, uuid, jsonb, boolean, text, interval) TO afpc_app;
-- Not afpc_app: garbage collection is an operator action. It is also safe to leave closed,
-- because every row it can delete is one nobody is waiting on.
REVOKE EXECUTE ON FUNCTION idempotency_sweep(timestamptz) FROM afpc_app;
-- The fourth function this migration creates is a trigger, and 0010 measured why its case is the
-- opposite of the API's above: the executor runs a trigger body, so its EXECUTE is not
-- privilege-checked against the invoker - afpc_app needs no grant and firing it should not be an
-- ambient capability. A new function is born {=X/postgres,...} whatever its kind, so the revoke
-- is what closes it; B22 counts every non-extension function still open to the cluster.
REVOKE EXECUTE ON FUNCTION afpc_bump_version() FROM PUBLIC;

-- The functions are SECURITY INVOKER, which is not the default so much as the absence of a
-- modifier - and here that is a decision, not an oversight. Under DEFINER the arbiter would be
-- one flat namespace no policy filters, which is precisely the global-index behaviour that lost
-- tenant B's write in the header's experiment.
DO $$
DECLARE
    v text;
BEGIN
    -- Two different rules, so two assertions. All three must be INVOKER: under DEFINER the arbiter
    -- becomes one flat namespace no policy filters, which is the global-index behaviour that lost
    -- tenant B's write in the header's experiment. But only claim and complete must be executable
    -- BY THE AGENT - sweep is closed to it on purpose, so the assertion checks that closure too,
    -- rather than an earlier draft's single predicate that failed on its own design decision.
    SELECT string_agg(proname, ', ' ORDER BY proname) INTO v FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace
       AND p.proname IN ('idempotency_claim','idempotency_complete','idempotency_sweep')
       AND p.prosecdef;
    IF v IS NOT NULL THEN
        RAISE EXCEPTION 'idempotency functions declared SECURITY DEFINER: % - the arbiter would '
                        'stop being filtered by 0009''s policies', v;
    END IF;

    SELECT string_agg(proname, ', ') INTO v FROM (
        SELECT p.proname, has_function_privilege('afpc_app', p.oid, 'EXECUTE') AS can
          FROM pg_proc p
         WHERE p.pronamespace = 'public'::regnamespace
           AND p.proname IN ('idempotency_claim','idempotency_complete')
    ) x WHERE NOT x.can;
    IF v IS NOT NULL THEN
        RAISE EXCEPTION 'afpc_app cannot execute % - a retry mechanism the agent role cannot call '
                        'is documentation, not a control (0009 measured this shape: the missing '
                        'grant surfaces mid-statement)', v;
    END IF;

    IF has_function_privilege('afpc_app', 'idempotency_sweep(timestamptz)', 'EXECUTE') THEN
        RAISE EXCEPTION 'idempotency_sweep is executable by afpc_app - collection was decided as '
                        'an operator action, and an inert privilege is how that stops being true';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
                 AND p.proname IN ('idempotency_claim','idempotency_complete','idempotency_sweep')
                 AND EXISTS (SELECT 1 FROM aclexplode(coalesce(p.proacl, p.proacl)) y
                              WHERE y.grantee = 0 AND y.privilege_type = 'EXECUTE')) THEN
        RAISE EXCEPTION 'an idempotency function is still executable by every role in the cluster '
                        '- 0009''s obligation, and B22 will report it too';
    END IF;

    -- The arbiter's existence is the mechanism. A dedup table whose unique index has been dropped
    -- is a table of notes that nothing reads, so B10 would keep saying CLOSED while retries
    -- duplicated. Checked by COLUMN ORDER, because 0004's lesson is that an ON CONFLICT target is
    -- only inferable when it names an index's keys exactly and in positional order - an arbiter
    -- over (operation, tenant_id, idempotency_key) would satisfy "a unique index exists" and make
    -- every claim raise at run time.
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conrelid = 'idempotency_keys'::regclass AND contype = 'u'
                      -- attnum is smallint, so the ARRAY literal builds a smallint[]; both sides
                      -- have to be cast or the comparison has no defined operator.
                      AND conkey::int[] = ARRAY[
                          (SELECT attnum FROM pg_attribute WHERE attrelid='idempotency_keys'::regclass
                             AND attname='tenant_id'),
                          (SELECT attnum FROM pg_attribute WHERE attrelid='idempotency_keys'::regclass
                             AND attname='operation'),
                          (SELECT attnum FROM pg_attribute WHERE attrelid='idempotency_keys'::regclass
                             AND attname='idempotency_key')]::int[]) THEN
        RAISE EXCEPTION 'no unique arbiter in (tenant_id, operation, idempotency_key) order on '
                        'idempotency_keys - claim''s ON CONFLICT target cannot be inferred, which '
                        'is an error on every call, not a silent fallback';
    END IF;
    RAISE NOTICE 'privileges: claim/complete callable by afpc_app as invoker, sweep operator-only, '
                 'arbiter in (tenant_id, operation, idempotency_key) order';
END
$$;

-- ---------------------------------------------------------------------------
-- 8. The ledger's two batch keys, which 0006 deferred to this migration
-- ---------------------------------------------------------------------------
-- 0006 left `inventory_movements.transaction_id` alone and said so: "unindexed today, not a
-- foreign key, queried by nothing; 6.1 argues it into a dedup key, which is 0011's decision with
-- its access method attached". Review 1.7 makes the same request more bluntly: "index
-- transaction_id". Deciding it required measuring what the column actually holds:
--
--   transaction_id  uuid NOT NULL DEFAULT gen_random_uuid()   - no code path assigns it; every
--                                                                 row gets a fresh value on insert.
--   batch_id        uuid NOT NULL DEFAULT gen_random_uuid()   - execute_inventory_movement mints
--                                                                 ONE value per call and writes it
--                                                                 to every row that call creates.
--
-- So the column the review wanted indexed is a per-ROW nonce, and the column nobody asked about is
-- the per-CALL key. Indexing a nonce is the trap: a btree over values that are distinct by
-- construction answers no question anyone has, and 6.1's complaint - "generated per row and
-- unindexed, so it cannot serve as a dedup key" - is the correct diagnosis with the wrong
-- prescription. A dedup key has to be SUPPLIED, because the entire claim is "this attempt is the
-- same request as that one"; an identifier invented by the row being inserted can only ever agree
-- with itself. That is why idempotency_keys.idempotency_key is a caller argument with no default,
-- and why section 3 raises when it is NULL.
--
-- The decision, then: no index on transaction_id, and no change to it - dropping or defaulting a
-- column another deployment may already be writing is 0008's kind of destruction, not a cleanup.
-- What changes is that the schema stops pretending it means something: the comment below is the
-- deliverable, and vw_idempotency_status publishes it as a verdict rather than folklore.
COMMENT ON COLUMN inventory_movements.transaction_id IS
    'A per-ROW identifier: DEFAULT gen_random_uuid() gives every movement a new value on insert, '
    'and no function or tool in this schema ever assigns or reads it. It is therefore NOT the '
    'ledger''s dedup or batch handle, whatever its name suggests - batch_id is (one value per '
    'execute_inventory_movement call, written to every row that call creates, indexed by 0006), '
    'and request identity of any kind lives in idempotency_keys.idempotency_key, which is supplied '
    'rather than generated for exactly that reason. 0011 declines review 1.7''s "index '
    'transaction_id": an index over values that are distinct by construction answers no query, and '
    '0006 deferred this call here with that reasoning. Left in place rather than dropped because a '
    'populated copy may write it.';

-- ---------------------------------------------------------------------------
-- 9. The state an agent should be able to ask about
-- ---------------------------------------------------------------------------
-- 6.1's sentence is "retries are still unsafe", which is a claim about operations, not about
-- tables - so the register is one row per function that changes persistent state, the pattern
-- ADR-005 says it may use, and whether it actually does. Everything in it is derived: participation
-- is read out of pg_proc bodies, an arbiter is an ON CONFLICT target that resolves, a version guard
-- is the trigger section 5 installed. It will mostly say 'unguarded' after this migration, because
-- wiring the tools is code work tracked in db/MIGRATIONS.md - the point is that the gap becomes
-- something an agent can query instead of something ADR-005 asserts.
CREATE OR REPLACE VIEW vw_idempotency_status AS
WITH targets AS (
    -- One list of what a body can be written against, so the same predicate is not restated four
    -- times in four columns and allowed to disagree with itself.
    SELECT c.oid AS reloid, c.relname::text AS relname
      FROM pg_class c
     WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r'
), writers AS (
    SELECT p.oid, p.proname::text AS fname, lower(pg_get_functiondef(p.oid)) AS body
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f'
       AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
), w AS (
    -- The join condition IS "this function changes that table's persistent state", which is
    -- ADR-005's own wording for what must be idempotent. The public\. escape matters: a double
    -- backslash here means "literal backslash", and pg_get_functiondef always qualifies with
    -- public., so the wrong pattern silently reports every function as writing nothing - a
    -- register that is empty rather than wrong, which is worse.
    SELECT r.oid AS fn, t.reloid AS tbl
      FROM writers r JOIN targets t
        ON r.body ~ ('insert +into +(public\.)?'    || t.relname || '[^a-z_]')
        OR r.body ~ ('update +(only +)?(public\.)?' || t.relname || '[^a-z_]')
        OR r.body ~ ('delete +from +(public\.)?'    || t.relname || '[^a-z_]')
     GROUP BY 1, 2
), listed AS (
    -- The ladder lives in exactly one place, and the outer query derives `unguarded` from its
    -- RESULT rather than restating these conditions: two copies of "which pattern counts as
    -- guarded" is how a register starts disagreeing with itself. Restating looked unavoidable
    -- here, because an output alias is not visible inside an ORDER BY expression - moving the
    -- CASE into a CTE is what makes it avoidable, since a CTE's columns are real columns.
    SELECT r.fname AS function,
        (SELECT string_agg(t.relname, ', ' ORDER BY t.relname)
           FROM w x JOIN targets t ON t.reloid = x.tbl WHERE x.fn = r.oid)      AS writes,
        -- Called, not mentioned: pg_get_functiondef contains the function's own name in its RAISE
        -- text, so a plain body match would report the mechanism as one of its own callers.
        (r.fname NOT LIKE 'idempotency%'
           AND r.body ~ 'idempotency_claim *\(')                                AS takes_a_claim,
        (r.body ~ 'on +conflict')                                               AS has_upsert_arbiter,
        EXISTS (SELECT 1 FROM w x
                  JOIN pg_attribute a ON a.attrelid = x.tbl AND a.attname = 'version'
                                       AND a.attnum > 0 AND NOT a.attisdropped
                                       AND a.atttypid = 'integer'::regtype
                  JOIN pg_trigger tg ON tg.tgrelid = x.tbl AND tg.tgname = 'afpc_bump_version'
                 WHERE x.fn = r.oid)                                            AS writes_a_counted_table,
        CASE
            WHEN r.fname LIKE 'idempotency%' THEN 'the mechanism itself'
            WHEN r.body ~ 'idempotency_claim *\('
                THEN 'ADR-005 pattern 2 - a replay is answered from the claim'
            WHEN r.body ~ 'on +conflict'
                THEN 'ADR-005 pattern 1 - natural uniqueness plus an upsert'
            WHEN EXISTS (SELECT 1 FROM w x
                          JOIN pg_attribute a ON a.attrelid = x.tbl AND a.attname = 'version'
                                               AND a.attnum > 0 AND NOT a.attisdropped
                                               AND a.atttypid = 'integer'::regtype
                          JOIN pg_trigger tg ON tg.tgrelid = x.tbl AND tg.tgname = 'afpc_bump_version'
                         WHERE x.fn = r.oid)
                THEN 'ADR-005 pattern 3 - a maintained version column can guard the write'
            ELSE 'UNGUARDED - a retry of this function performs the operation twice (6.1)'
        END                                                                    AS verdict
      FROM writers r
     -- Functions that change no table at all are not idempotency questions. Excluded by the same
     -- predicate that defines the join, rather than by a list of names, so the register's scope
     -- and its content cannot become two different decisions.
     WHERE EXISTS (SELECT 1 FROM w x WHERE x.fn = r.oid)
)
SELECT listed.*, (listed.verdict LIKE 'UNGUARDED%') AS unguarded
  FROM listed
 ORDER BY unguarded DESC, listed.function;

COMMENT ON VIEW vw_idempotency_status IS
    'One row per function that changes persistent state: which tables it writes, whether it takes '
    'an idempotency claim, whether it has a natural upsert arbiter, whether it writes a table whose '
    'version column is now maintained, and a verdict. The UNGUARDED rows are the honest remaining '
    'half of 6.1 - the mechanism exists after 0011, and the tools have not been pointed at it yet, '
    'which is code work. Limitations stated because they are how this view would mislead: '
    'participation is read from function bodies, so a tool that deduplicates in Python rather than '
    'in SQL does not show up, and a function whose writes happen only through another function '
    'reports the pattern of the call it makes, not the call it should have made.';

ALTER VIEW vw_idempotency_status SET (security_invoker = true);
GRANT SELECT ON vw_idempotency_status TO afpc_auditor, afpc_readonly;

-- ---------------------------------------------------------------------------
-- 10. Verify by behaving
-- ---------------------------------------------------------------------------
-- 6.1 is a claim about what happens when a call runs twice, and no catalog query can answer that:
-- a dedup table with a unique index and a claim function that has an ordering bug looks completely
-- healthy. So every probe below performs an operation, replays it, and counts the SIDE EFFECT
-- rather than reading back a status. The entity named '0011 probe' is the ledger of what actually
-- ran, and the assertion is always about its row count.
DO $$
DECLARE
    v_state    text;
    v_claim    uuid;
    v_token    uuid;
    v_cached   jsonb;
    v_ent      bigint;
    v_second   bigint;
    v_it       uuid;
    v_wh       uuid;
    v_ver      integer;
    v_n        int := 0;
    v_msg      text;
    v_tenant_b uuid := '00000000-0000-0000-0000-0000000000b2';
BEGIN
    ------------------------------------------------------------------
    -- A. the finding itself: a replayed mutation must run ONCE.
    ------------------------------------------------------------------
    SELECT claim_id, current_token INTO v_claim, v_token
      FROM idempotency_claim(gen_random_uuid(), '0011:add_customer',
                             '{"name":"0011 probe"}'::jsonb);
    IF v_claim IS NULL THEN
        RAISE EXCEPTION 'A failed: the first claim returned no id - nothing can be completed';
    END IF;

    -- The "work" a claim guards is an entity insert, counted rather than described.
    INSERT INTO entities (name, entity_type, status)
        VALUES ('0011 probe', 'customer', 'active') RETURNING id INTO v_ent;
    PERFORM idempotency_complete(v_claim, v_token,
                                 jsonb_build_object('entity_id', v_ent), true, NULL);
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- B. the same key, replayed, must answer from the cache and change nothing.
    ------------------------------------------------------------------
    SELECT claim_state, cached_response INTO v_state, v_cached
      FROM idempotency_claim((SELECT idempotency_key FROM idempotency_keys WHERE id = v_claim),
                             '0011:add_customer', '{"name":"0011 probe"}'::jsonb);
    IF v_state <> 'replay' THEN
        RAISE EXCEPTION 'B failed: replaying a completed claim reported % instead of replay - '
                        'a retry of the same request is being treated as new work', v_state;
    END IF;
    IF (v_cached->>'entity_id')::bigint <> v_ent THEN
        RAISE EXCEPTION 'B failed: the replay returned % instead of the first attempt''s entity %',
                        v_cached->>'entity_id', v_ent;
    END IF;
    IF (SELECT count(*) FROM entities WHERE name = '0011 probe') <> 1 THEN
        RAISE EXCEPTION 'B failed: the replay created % entities - this is 6.1 itself, the '
                        'operation ran twice because nothing recognised the second call',
                        (SELECT count(*) FROM entities WHERE name = '0011 probe');
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- C. same key, DIFFERENT request: refuse. Answering this from the cache is the way a dedup
    --     table turns a retry bug into silent data corruption, and ADR-005's pattern 4 is the
    --     fingerprint that makes it detectable.
    ------------------------------------------------------------------
    SELECT claim_state INTO v_state
      FROM idempotency_claim((SELECT idempotency_key FROM idempotency_keys WHERE id = v_claim),
                             '0011:add_customer', '{"name":"someone else"}'::jsonb);
    IF v_state <> 'conflict' THEN
        RAISE EXCEPTION 'C failed: a key reused with a different request reported % instead of '
                        'conflict - the request fingerprint is not being consulted', v_state;
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- D. an uncompleted claim within its lease must say in_progress, so a concurrent retry waits
    --     instead of performing the side effect a second time.
    ------------------------------------------------------------------
    SELECT claim_id INTO v_claim FROM idempotency_claim(gen_random_uuid(), '0011:stuck', NULL);
    SELECT claim_state INTO v_state
      FROM idempotency_claim((SELECT idempotency_key FROM idempotency_keys WHERE id = v_claim),
                             '0011:stuck', NULL);
    IF v_state <> 'in_progress' THEN
        RAISE EXCEPTION 'D failed: a live claim handed the same work to a second caller as % - '
                        'the lease is not gating execution', v_state;
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- E. and a DEAD one must be taken over. This is the crash affordance the lease exists for: an
    --     attempt that died cannot be allowed to wedge a key forever, or 0011 has replaced an
    --     unsafe retry with a stuck one. Pin the lease into the past rather than sleeping.
    ------------------------------------------------------------------
    UPDATE idempotency_keys
       SET lease_expires_at = now() - interval '1 minute',
           expires_at = now() - interval '1 minute' + interval '24 hours'
     WHERE id = v_claim;
    SELECT claim_state, current_token INTO v_state, v_token
      FROM idempotency_claim((SELECT idempotency_key FROM idempotency_keys WHERE id = v_claim),
                             '0011:stuck', NULL);
    IF v_state <> 'claimed' THEN
        RAISE EXCEPTION 'E failed: a claim whose lease lapsed reported % instead of being taken '
                        'over - a crashed attempt now blocks this key permanently', v_state;
    END IF;
    IF (SELECT attempts FROM idempotency_keys WHERE id = v_claim) <> 2 THEN
        RAISE EXCEPTION 'E failed: the take-over did not record itself in attempts (%)',
                        (SELECT attempts FROM idempotency_keys WHERE id = v_claim);
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- F. the displaced attempt, the hazard section 4 was written for. E rotated the token, so the
    --     original worker's completion must be REFUSED - if it were accepted, the table would
    --     certify an operation that ran twice as one that ran once, and every probe above would
    --     still pass.
    ------------------------------------------------------------------
    BEGIN
        PERFORM idempotency_complete(v_claim, gen_random_uuid(), '{"late":true}'::jsonb, true, NULL);
        RAISE EXCEPTION 'F failed: a completion with a stale token was accepted - the take-over '
                        'left the displaced attempt able to overwrite the winner';
    EXCEPTION
        WHEN exclusion_violation THEN NULL;      -- the required outcome
        WHEN OTHERS THEN
            RAISE EXCEPTION 'F failed: completing with a stale token raised % (%) instead of the '
                            'documented exclusion_violation', SQLSTATE, left(SQLERRM, 80);
    END;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- G. ADR-005 pattern 3: the version column 6.1 found decorative must now both move on every
    --    write and make a stale write fail. This is the write path the inventory agent uses.
    ------------------------------------------------------------------
    INSERT INTO warehouses (warehouse_code, name, warehouse_type)
        VALUES ('AFPC-0011', '0011 probe warehouse', 'PRIMARY') RETURNING warehouse_id INTO v_wh;
    INSERT INTO inventory_items (sku, name, product_type)
        VALUES ('AFPC-0011', '0011 probe item', 'STOCKED') RETURNING item_id INTO v_it;
    INSERT INTO inventory_on_hand (item_id, warehouse_id, quantity_on_hand, quantity_reserved)
        VALUES (v_it, v_wh, 10, 0);
    IF (SELECT version FROM inventory_items WHERE item_id = v_it) <> 1 THEN
        RAISE EXCEPTION 'G failed: a new item''s version is %, expected 1 - the default and the '
                        'trigger must disagree about inserts, not about each other',
                        (SELECT version FROM inventory_items WHERE item_id = v_it);
    END IF;
    SELECT version INTO v_ver FROM inventory_on_hand WHERE item_id = v_it AND warehouse_id = v_wh;
    UPDATE inventory_on_hand SET quantity_on_hand = 9, last_movement_at = now()
     WHERE item_id = v_it AND warehouse_id = v_wh AND version = v_ver;
    IF v_ver IS DISTINCT FROM 1 THEN
        RAISE EXCEPTION 'G failed: a stock row starts at version %', v_ver;
    END IF;
    IF (SELECT version FROM inventory_on_hand WHERE item_id = v_it AND warehouse_id = v_wh) <> 2 THEN
        RAISE EXCEPTION 'G failed: the version column is still decoration - it reads % after a '
                        'write, which is 6.1''s measurement',
                        (SELECT version FROM inventory_on_hand WHERE item_id = v_it AND warehouse_id = v_wh);
    END IF;
    -- And the guard the counter exists to provide: the same statement replayed with the version
    -- the writer saw changes nothing, which is how a stale update becomes detectable.
    UPDATE inventory_on_hand SET quantity_on_hand = 8, last_movement_at = now()
     WHERE item_id = v_it AND warehouse_id = v_wh AND version = v_ver;
    IF (SELECT quantity_on_hand FROM inventory_on_hand
         WHERE item_id = v_it AND warehouse_id = v_wh) <> 9 THEN
        RAISE EXCEPTION 'G failed: a write carrying an already-superseded version succeeded - the '
                        'counter moves but nothing reads it, so pattern 3 is still unavailable';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- H. the header's measurement, asserted. Two tenants must be able to use the same key without
    --    either one's claim being answered, hidden, or lost by the other. This is what a GLOBAL
    --    arbiter breaks, and it breaks silently.
    ------------------------------------------------------------------
    INSERT INTO tenants (tenant_id, slug, name)
        VALUES (v_tenant_b, 'probe-b-0011', '0011 probe tenant B') ON CONFLICT DO NOTHING;
    DECLARE
        v_key uuid := gen_random_uuid();
        v_b   record;
    BEGIN
        PERFORM idempotency_claim(v_key, '0011:shared', '{"t":"A"}'::jsonb);
        BEGIN
            EXECUTE 'SET LOCAL ROLE afpc_app';
            PERFORM set_config('app.tenant_id', v_tenant_b::text, true);
            SELECT claim_state INTO v_state
              FROM idempotency_claim(v_key, '0011:shared', '{"t":"B"}'::jsonb);
            EXECUTE 'RESET ROLE';
        EXCEPTION
            WHEN OTHERS THEN
                EXECUTE 'RESET ROLE';
                RAISE EXCEPTION 'H failed: tenant B could not claim a key tenant A already holds '
                                '(% / %) - a shared namespace is the global-index defect',
                                SQLSTATE, left(SQLERRM, 60);
        END;
        IF v_state <> 'claimed' THEN
            RAISE EXCEPTION 'H failed: tenant B reported % for a key held only by tenant A - '
                            'claims are not independent per tenant', v_state;
        END IF;
        -- and neither can see the other's row: the count is tenant A's, which owns exactly one.
        SELECT count(*) INTO v_b FROM idempotency_keys WHERE idempotency_key = v_key
          AND tenant_id = afpc_current_tenant();
        IF v_b.count <> 1 THEN
            RAISE EXCEPTION 'H failed: tenant A sees % claims for a key both tenants used', v_b.count;
        END IF;
    END;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- I. the retention policy must actually collect, and must NOT collect a claim that is only
    --    past its lease - that row is unfinished work, and deleting it would silently lose the
    --    fact that the request ever arrived.
    ------------------------------------------------------------------
    -- One row past its RETENTION (must go), one row past its LEASE but inside retention (must
    -- stay: it is unfinished work, and deleting it would turn "the worker died" into "nobody ever
    -- asked"), and one row live in both clocks (must stay). idempotency_sweep returns an integer,
    -- so it is assigned, not called from FROM as if it were a set.
    SELECT claim_id INTO v_claim FROM idempotency_claim(gen_random_uuid(), '0011:sweep-old', NULL);
    PERFORM idempotency_complete(v_claim, (SELECT claim_token FROM idempotency_keys WHERE id = v_claim),
                                 '{"done":1}'::jsonb, true, NULL);
    UPDATE idempotency_keys
       SET lease_expires_at = now() - interval '2 hours',
           expires_at = now() - interval '1 hour'
     WHERE id = v_claim;
    DECLARE
        v_dead uuid; v_live uuid; v_gone integer;
    BEGIN
        SELECT claim_id INTO v_dead  FROM idempotency_claim(gen_random_uuid(), '0011:sweep-dead', NULL);
        SELECT claim_id INTO v_live  FROM idempotency_claim(gen_random_uuid(), '0011:sweep-live', NULL);
        UPDATE idempotency_keys
           SET lease_expires_at = now() - interval '1 minute',
               expires_at = lease_expires_at + interval '24 hours'
         WHERE id = v_dead;
        v_gone := idempotency_sweep();
        IF v_gone <> 1 THEN
            RAISE EXCEPTION 'I failed: the sweep deleted % rows, expected exactly 1 - the one '
                            'expired-retention row (a sweep that deletes too much deletes evidence '
                            'of work nobody has confirmed)', v_gone;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM idempotency_keys WHERE id = v_dead) THEN
            RAISE EXCEPTION 'I failed: the sweep deleted a claim that was only past its LEASE - '
                            'unconfirmed work became invisible';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM idempotency_keys WHERE id = v_live) THEN
            RAISE EXCEPTION 'I failed: the sweep deleted rows still inside their retention';
        END IF;
    END;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- J. the register must not contradict the schema it reports on. A view whose verdict is
    --    computed from the same bodies it lists can be right and still describe the wrong
    --    database, so the two are compared, not trusted.
    ------------------------------------------------------------------
    SELECT string_agg(function, ', ' ORDER BY function) INTO v_msg FROM vw_idempotency_status
     WHERE verdict LIKE 'UNGUARDED%' AND NOT EXISTS (SELECT 1 FROM pg_proc p
              WHERE p.proname = vw_idempotency_status.function
                AND p.pronamespace = 'public'::regnamespace);
    IF v_msg IS NOT NULL THEN
        RAISE EXCEPTION 'J failed: the register lists % as live functions that are not in pg_proc',
                        v_msg;
    END IF;
    IF (SELECT count(*) FROM vw_idempotency_status WHERE takes_a_claim) <> 0 THEN
        RAISE EXCEPTION 'J failed: % functions take idempotency claims before any tool was wired - '
                        'the register is reading something other than the call sites',
                        (SELECT count(*) FROM vw_idempotency_status WHERE takes_a_claim);
    END IF;
    -- And the scope claim: this register is about functions that CHANGE state, so a read-only one
    -- appearing would mean the boundary is a name list rather than a predicate.
    IF EXISTS (SELECT 1 FROM vw_idempotency_status v
                WHERE v.writes IS NULL OR v.writes = '') THEN
        RAISE EXCEPTION 'J failed: the register lists % with no tables written - a read-only '
                        'function cannot be an idempotency question',
                        (SELECT string_agg(function, ', ') FROM vw_idempotency_status
                          WHERE writes IS NULL OR writes = '');
    END IF;
    v_n := v_n + 1;

    IF v_n <> 10 THEN
        RAISE EXCEPTION 'expected 10 behavioural verifications, completed %', v_n;
    END IF;

    -- Fixtures out, in the order 0008's RESTRICT edges require.
    DELETE FROM idempotency_keys;
    DELETE FROM inventory_movements WHERE performed_by = '0011-probe';
    DELETE FROM inventory_on_hand   WHERE warehouse_id = v_wh;
    DELETE FROM locations           WHERE warehouse_id = v_wh;
    DELETE FROM inventory_items     WHERE item_id = v_it;
    DELETE FROM warehouses          WHERE warehouse_id = v_wh;
    DELETE FROM entities            WHERE name = '0011 probe';
    DELETE FROM tenants             WHERE tenant_id = v_tenant_b;
    RAISE NOTICE '6.1: % behavioural checks passed - a replay runs once, a mismatched key '
                 'refuses, a dead claim is taken over, a stale write is detectable, and no fixture '
                 'survived', v_n;
END
$$;
