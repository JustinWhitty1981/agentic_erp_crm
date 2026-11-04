-- 0023: agent memory moves inside the wall, where the other things the agent remembers live
--       (ADR-002 database-first, applied to the one state this deployment kept on disk)
--
-- Why this file exists: ADR-002's claim is that agent state lives in PostgreSQL. Everything the
-- customer service agent remembers did - until you look at `pkg/memory/memory.go`, which writes
-- markdown files into a container directory. Two consequences made that worth fixing rather than
-- documenting:
--
--   * The files are inside the container's filesystem, which is not a volume the Go compose file
--     declares, so an agent's memory has the lifetime of its image. Redeploy and the agent forgets
--     every preference it was ever told, with no error and no trail.
--   * Key identity was a filename, and filenames are lossy in a way that has no owner. Sanitising
--     `[^\w\-_.]` to `_` means `a/b` and `a_b` are the SAME memory: two callers, two intentions,
--     one file, appended to by both, and nothing reports the collision. Here the two keys are two
--     keys, and the one that cannot exist is refused by a constraint rather than folded into a
--     neighbour.
--
-- What the table had to satisfy before it was allowed to exist, because this schema's invariants
-- are catalog-derived and a new tenant-coded table walks into every one of them:
--   * 0003 - tenant_id uuid NOT NULL DEFAULT afpc_current_tenant(), FK to tenants, RESTRICT.
--   * 0006 - an index leading with tenant_id, on the path the tools actually walk.
--   * 0009 - ENABLE + FORCE ROW LEVEL SECURITY and tenant_isolation with WITH CHECK, plus the read
--     roles' SELECT policy. B7 counts tenant-coded tables missing any of that, so this table
--     enrolls itself or the scoreboard goes red the first time it runs.
--   * 0010 - no updated_at, on purpose. The verdict 'no updated_at by decision - nothing in the
--     schema rewrites these rows' holds only while no function body contains an UPDATE against
--     this table, which probe H watches. Adding the column to look complete would be 0011's
--     complaint about a version counter that counts nothing.
--   * 0013 - the audit trigger, attached by this migration rather than assumed: 0013's attaching
--     census already ran and cannot see a table born after it, while vw_audit_coverage's scope is
--     the catalog's, so an untrailed new table is exactly the disagreement B26 counts.
--   * 0002 - grants arrive automatically; two of them are declined by hand below.
--   * B22 - every new function is closed to PUBLIC per object, because ALTER DEFAULT PRIVILEGES
--     REVOKE is a no-op for functions. One exception is not made here: the normalisation rule is
--     stated in a CHECK constraint (see below), so there is no helper function to grant.
--
-- Where the rules live, and why none of them is in the function body: the key's shape, the key's
-- normalised form, and the presence of content are three constraints, and `save_memory` contains
-- no IF arm that repeats any of them. A body that restates a constraint is the second copy 0018
-- refuses - and unlike a prose error, a restated domain drifts silently, because the constraint
-- keeps passing while the arm rots. The answer to a bad argument is therefore its own SQLSTATE
-- (23514, named), which is what 0014/0015/0016 concluded about errors-as-answers. The one rule
-- that stays in a body is get_memory's p_limit range: it is an argument about how many rows to
-- return, there is no column for a constraint to live on, and 0015's rule says refuse a wrong
-- argument before doing the work.
--
-- The append-only choice is 0013's posture in a new place: append-only BY GRANT, which holds
-- against every account an agent can connect as, not by convention among callers. What it costs
-- is retention, and §6 says who owes that.

SET client_min_messages TO notice;

-- ---------------------------------------------------------------------------
-- 1. The table
-- ---------------------------------------------------------------------------
-- uuid PK rather than a bigint sequence: 0005's rule is sequences for ledgers whose order IS the
-- story, and the story here is which key was written, not what number it got. It also keeps B23
-- (sequences afpc_app cannot draw from) out of this migration's business - there is no sequence to
-- grant, which is the reason audit_log's IDENTITY needed an explicit grant probe.
CREATE TABLE IF NOT EXISTS agent_memories (
    id          uuid          PRIMARY KEY DEFAULT afpc_uuid_v7(),
    tenant_id   uuid          NOT NULL DEFAULT afpc_current_tenant(),
    memory_key  varchar(120)  NOT NULL,
    content     text          NOT NULL,
    created_at  timestamptz   NOT NULL DEFAULT now(),

    -- Three constraints, and the only place any of them is written.
    --
    -- The shape forbids the characters that made the filename version lossy - `/` above all - and
    -- allows one space between words, because an LLM naming a memory will say "customer
    -- preferences" and a rule that makes that an error is a rule the agent will fight.
    --
    -- The identity check is the normalisation, stated as a property of stored rows rather than as
    -- a step some caller performs: a row is valid only if it already equals its own normalised
    -- form. That is what licenses save_memory to normalise on the way in without that being a
    -- private second copy of the rule - and if the body's expression ever drifts from this one,
    -- the constraint fails the write rather than quietly storing two keys that mean one thing.
    --
    -- lower(), btrim(), and collapsing runs of whitespace are all inside that identity: 'Customer
    -- Prefs', ' customer  prefs ' and 'customer prefs' are one key.
    CONSTRAINT agent_memories_key_shape CHECK (
        memory_key ~ '^[a-z0-9][a-z0-9 ._-]{0,119}$'),
    CONSTRAINT agent_memories_key_normalised CHECK (
        memory_key = lower(btrim(regexp_replace(memory_key, '\s+', ' ', 'g')))),
    CONSTRAINT agent_memories_content_present CHECK (
        btrim(content) <> '')
);

ALTER TABLE agent_memories
    DROP CONSTRAINT IF EXISTS agent_memories_tenant_id_fkey;
ALTER TABLE agent_memories
    ADD CONSTRAINT agent_memories_tenant_id_fkey
    FOREIGN KEY (tenant_id) REFERENCES tenants (tenant_id) ON DELETE RESTRICT;

-- The one path the tools walk: "everything about this key, newest first", and "every key there
-- is". Leading with tenant_id is 0003's rule and makes the isolation policy an index condition
-- rather than a filter, which is 0009's 479 ms against 53 ms measurement applied to a table that
-- was built for it.
CREATE INDEX IF NOT EXISTS idx_agent_memories_tenant_key_time
    ON agent_memories (tenant_id, memory_key, created_at DESC);

COMMENT ON TABLE agent_memories IS
    'What the agent was told to remember, one row per entry, append-only. Replaces the markdown '
    'files under memory_store/, which lived and died with the container''s filesystem and whose '
    'key identity was a sanitised filename (so "a/b" and "a_b" were silently the same memory). A '
    'key may be written many times - the history is the point, and get_memory shows it newest '
    'first. Nothing updates a row and nothing in the schema deletes one from an agent''s seat, '
    'which is why there is no updated_at: 0010''s register publishes this table as append-only by '
    'decision and probe H watches the verdict rather than the claim. Tenancy, row security, and '
    'the row trail are the same mechanisms every other tenant-coded table uses. Built by 0023.';

COMMENT ON CONSTRAINT agent_memories_key_shape ON agent_memories IS
    'The key vocabulary, in one place: lowercase, 1-120 characters, starting alphanumeric, then '
    'letters, digits, space, dot, underscore, hyphen. No function restates this list - save_memory '
    'lets it answer, and the read paths match against a normalised value, which probe E shows '
    'means an impossible key reads as empty rather than erroring.';

COMMENT ON CONSTRAINT agent_memories_key_normalised ON agent_memories IS
    'The key identity, in one place: lower case, no surrounding whitespace, no runs of internal '
    'whitespace. Written as a property of the stored row rather than as a step, so the writer '
    'cannot be the only thing that knows it. An expression duplicated in a body and a constraint '
    'is 0018''s "four copies" complaint; the constraint is the copy that survives, and it fails a '
    'write whose body has drifted instead of storing two spellings of one memory.';

-- ---------------------------------------------------------------------------
-- 2. The wall, the trail, and the grants - 0009's and 0013's shapes, by hand
-- ---------------------------------------------------------------------------
ALTER TABLE agent_memories ENABLE ROW LEVEL SECURITY;
ALTER TABLE agent_memories FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON public.agent_memories AS PERMISSIVE
    FOR ALL TO PUBLIC
    USING (tenant_id = afpc_policy_tenant())
    WITH CHECK ((tenant_id = afpc_policy_tenant()));
CREATE POLICY audit_read_all ON public.agent_memories AS PERMISSIVE
    FOR SELECT TO afpc_auditor, afpc_readonly
    USING (true);

-- Explicit, because the census that normally does this ran in 0013 and cannot see a table born
-- afterwards. Without it, vw_audit_coverage reports this table in scope and silent, and B26 counts
-- the disagreement.
DROP TRIGGER IF EXISTS afpc_audit_row ON agent_memories;
CREATE TRIGGER afpc_audit_row
    AFTER INSERT OR UPDATE OR DELETE ON agent_memories
    FOR EACH ROW EXECUTE FUNCTION afpc_audit_row();

-- 0002's forward defaults land afpc_app with SELECT, INSERT, UPDATE, DELETE on a new table. The
-- two history-altering privileges are declined here, the way 0013 declined them on audit_log:
-- append-only is a property of the grant, not of the code that happens to use it. TRUNCATE goes
-- too - it is the third way to lose the trail''s subject without a row-level event.
REVOKE UPDATE, DELETE, TRUNCATE ON agent_memories FROM afpc_app;
REVOKE UPDATE, DELETE, TRUNCATE ON agent_memories FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- 3. The three operations
-- ---------------------------------------------------------------------------
-- The Go tool names stay save_memory_tool / get_memory_tool / list_memories_tool: those strings
-- are in the model's context and in the README, and renaming them would be a change to the
-- agent's interface dressed up as a database migration. The mapping is one hop and is written in
-- each function's comment as well as in the tool descriptions.

CREATE OR REPLACE FUNCTION save_memory(
    p_key             text,
    p_content         text,
    p_idempotency_key uuid DEFAULT NULL
) RETURNS TABLE(success boolean, memory_id uuid, message text)
LANGUAGE plpgsql AS $$
DECLARE
    v_claim record;
    v_state text := '';
    v_ok    boolean := true;
    v_msg   text;
    v_id    uuid;
BEGIN
    ------------------------------------------------------------------
    -- ADR-005 pattern 2, in 0016's shape. This is the door where a retry matters least and the
    -- register where it matters most: an agent that reissues a tool call after a timeout would
    -- otherwise append the same fact twice, and list_memories' entry_count would then be a number
    -- about how often the model stuttered rather than how much was learned.
    ------------------------------------------------------------------
    IF p_idempotency_key IS NOT NULL THEN
        SELECT * INTO v_claim FROM idempotency_claim(
            p_idempotency_key, 'save_memory',
            jsonb_build_object('key', lower(btrim(regexp_replace(coalesce(p_key, ''),
                                                '\s+', ' ', 'g'))),
                               'content', p_content));
        v_state := v_claim.claim_state;
        IF v_state = 'replay' THEN
            success   := (v_claim.cached_response ->> 'success')::boolean;
            memory_id := (v_claim.cached_response ->> 'memory_id')::uuid;
            message   := v_claim.cached_response ->> 'message';
            RETURN NEXT;
            RETURN;
        ELSIF v_state = 'in_progress' THEN
            RAISE EXCEPTION 'save_memory: an attempt with key % is already in flight',
                p_idempotency_key
                USING ERRCODE = '40001';
        ELSIF v_state = 'conflict' THEN
            RAISE EXCEPTION 'save_memory: key % was settled for a DIFFERENT request',
                p_idempotency_key
                USING ERRCODE = 'P0001';
        END IF;
    END IF;

    -- No validation arm follows, by design: see the header. The INSERT normalises, the three
    -- constraints decide what is a legal row, and a refusal arrives with its own SQLSTATE and the
    -- constraint's own name, which is a better answer than any sentence this body could write.
    INSERT INTO agent_memories (memory_key, content)
    VALUES (lower(btrim(regexp_replace(coalesce(p_key, ''), '\s+', ' ', 'g'))), p_content)
    RETURNING agent_memories.id INTO v_id;

    v_msg := format('Remembered under key %s', quote_literal(
        (SELECT m.memory_key FROM agent_memories m WHERE m.id = v_id)));

    IF v_state = 'claimed' THEN
        PERFORM idempotency_complete(v_claim.claim_id, v_claim.current_token,
            jsonb_build_object('success', true, 'memory_id', v_id, 'message', v_msg));
    END IF;

    RETURN QUERY SELECT v_ok, v_id, v_msg;
    RETURN;

EXCEPTION
    WHEN OTHERS THEN
        -- Releasing the claim is the only thing this handler does, and 0014/0015/0016's reason
        -- is unchanged: a claim left in_flight after a failure is a door that stays shut until
        -- the lease expires, and a constraint refusal is exactly the kind of failure whose retry
        -- is meant to succeed.
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

CREATE OR REPLACE FUNCTION get_memory(
    p_key   text,
    p_limit integer DEFAULT 10
) RETURNS TABLE(created_at timestamptz, content text)
LANGUAGE plpgsql
STABLE AS $$
BEGIN
    IF p_limit IS NULL OR p_limit < 1 OR p_limit > 200 THEN
        RAISE EXCEPTION 'get_memory: p_limit % is outside 1..200', p_limit
            USING ERRCODE = '22023',
                  HINT = 'page with it; 200 entries of prose is already past what the agent''s '
                         'tool-output cap lets through';
    END IF;

    -- The same normalisation expression as the column identity, applied to the argument. That is
    -- the one duplication this migration accepts, and the reason it is tolerable is that the
    -- CHECK would refuse any row the writer failed to normalise, so the pair cannot silently
    -- disagree about stored data - at worst a read finds nothing that was never written.
    RETURN QUERY
    SELECT m.created_at, m.content
      FROM agent_memories m
     WHERE m.memory_key = lower(btrim(regexp_replace(coalesce(p_key, ''), '\s+', ' ', 'g')))
     ORDER BY m.created_at DESC, m.id DESC
     LIMIT p_limit;
END
$$;

CREATE OR REPLACE FUNCTION list_memories()
RETURNS TABLE(memory_key text, entry_count bigint, last_entry_at timestamptz)
LANGUAGE plpgsql
STABLE AS $$
BEGIN
    RETURN QUERY
    SELECT m.memory_key::text,
           count(*)::bigint,
           max(m.created_at)
      FROM agent_memories m
     GROUP BY m.memory_key
     ORDER BY m.memory_key;
END
$$;

-- ---------------------------------------------------------------------------
-- 4. Privileges, and what the schema now says
-- ---------------------------------------------------------------------------
-- Born EXECUTE-to-PUBLIC, and the default-privileges revoke is a no-op for functions, so it is
-- done per object (0009's sweep and 0016's note). The read roles get the two reads and not the
-- write, which is what they are for.
REVOKE EXECUTE ON FUNCTION save_memory(text, text, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION get_memory(text, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION list_memories() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION save_memory(text, text, uuid) TO afpc_app;
GRANT  EXECUTE ON FUNCTION get_memory(text, integer) TO afpc_app;
GRANT  EXECUTE ON FUNCTION list_memories() TO afpc_app;
GRANT  EXECUTE ON FUNCTION get_memory(text, integer) TO afpc_readonly, afpc_auditor;
GRANT  EXECUTE ON FUNCTION list_memories() TO afpc_readonly, afpc_auditor;

COMMENT ON FUNCTION save_memory(text, text, uuid) IS
    'Append one thing to remember under one key. Returns (success, memory_id, message) in the same '
    'shape as add_customer and add_communication, so a caller that branches on success branches '
    'on one shape across the whole CRM surface. The key is normalised with the expression the '
    'column identity states; there is no IF arm anywhere in this body, because the three domain '
    'rules on this table are constraints and a restated constraint is the second copy that drifts. '
    'So a key outside the published shape answers 23514 naming agent_memories_key_shape, blank '
    'content answers 23514 naming agent_memories_content_present, and in both cases no row is '
    'written and the claim is released. With p_idempotency_key a retried call is one memory rather '
    'than two entries about the same fact (ADR-005, 0011''s claim, 0016''s ladder: replay answers '
    'from cache, a live lease is 40001, a reused key on a different request is P0001). Built by '
    '0023.';

COMMENT ON FUNCTION get_memory(text, integer) IS
    'The last p_limit entries under one key, newest first. Read and write normalise with the same '
    'expression, which is the whole reason the pair is two functions over one table rather than '
    'two files: a key cannot be half-found. A key the shape CHECK forbids matches nothing and '
    'answers with zero rows - the same answer an empty key gives, deliberately, because moving the '
    'shape rule into this body would state it twice. p_limit outside 1..200 is 22023 before any '
    'scan. Order is what this function returns, not what it promises: an outer plan may re-sort, '
    'which is 0017''s rule about a sort inside a view, restated here because the shape is the '
    'same. Built by 0023.';

COMMENT ON FUNCTION list_memories() IS
    'Every key this tenant''s agent has been told to remember, how many entries each has, and when '
    'the last was written. The count is what makes the append-only shape visible to the caller: a '
    'key with six entries has been told six things, which a file that overwrote itself could not '
    'have said. Built by 0023.';

-- ---------------------------------------------------------------------------
-- 5. Verify by behaving
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_id      uuid;
    v_id2     uuid;
    v_ok      boolean;
    v_msg     text;
    v_found   bigint;
    v_err     text;
    v_key     uuid;
    v_td      uuid;
    v_t2      uuid;
    v_n       int := 0;
BEGIN
    ------------------------------------------------------------------
    -- A. the table is enrolled in every mechanism a tenant-coded table is supposed to be in.
    --    Asserted from the catalog, because "I wrote the DDL" is not evidence that it applied.
    ------------------------------------------------------------------
    IF (SELECT count(*) FROM information_schema.columns
         WHERE table_name = 'agent_memories' AND column_name = 'tenant_id'
           AND is_nullable = 'NO' AND data_type = 'uuid'
           AND column_default LIKE 'afpc_current_tenant%') <> 1 THEN
        RAISE EXCEPTION 'A failed: agent_memories.tenant_id is not the tenancy column 0003 '
                        'prescribes - B1 cannot see this table and neither can a policy';
    END IF;
    IF (SELECT count(*) FROM pg_class c
         WHERE c.oid = 'agent_memories'::regclass
           AND c.relrowsecurity AND c.relforcerowsecurity) <> 1 THEN
        RAISE EXCEPTION 'A failed: row security is not enabled AND forced - B7 counts exactly '
                        'this disagreement and this table would be it';
    END IF;
    IF (SELECT count(*) FROM pg_policy po
         WHERE po.polrelid = 'agent_memories'::regclass
           AND po.polname = 'tenant_isolation'
           AND po.polqual IS NOT NULL AND po.polwithcheck IS NOT NULL) <> 1 THEN
        RAISE EXCEPTION 'A failed: the isolation policy is missing its WITH CHECK half, so reads '
                        'would be filtered and writes would not - 5.7''s decorative case';
    END IF;
    IF (SELECT count(*) FROM pg_trigger t
         WHERE t.tgrelid = 'agent_memories'::regclass
           AND t.tgname = 'afpc_audit_row' AND NOT t.tgisinternal) <> 1 THEN
        RAISE EXCEPTION 'A failed: no audit trigger on agent_memories - 0013''s census ran before '
                        'this table existed, so nothing else would ever notice';
    END IF;
    IF (SELECT count(*) FROM pg_index i
         WHERE i.indrelid = 'agent_memories'::regclass
           AND (SELECT q.v FROM unnest(i.indkey::int[]) WITH ORDINALITY AS q(v, o)
                 WHERE q.o = 1 LIMIT 1)
               = (SELECT a.attnum FROM pg_attribute a
                   WHERE a.attrelid = 'agent_memories'::regclass AND a.attname = 'tenant_id')) = 0 THEN
        -- Rebuilt through unnest WITH ORDINALITY rather than sliced: int2vector is zero-based and
        -- (indkey::int[])[1] is the SECOND key column - the mistake dev/README records three
        -- migrations making, in three different files.
        RAISE EXCEPTION 'A failed: no index leads with tenant_id (0003''s rule)';
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_name = 'agent_memories' AND column_name = 'updated_at') THEN
        RAISE EXCEPTION 'A failed: agent_memories grew an updated_at on a table nothing updates - '
                        '0010''s register would publish a maintenance promise nobody can keep';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- B. append-only is a property of the grant, tested in the seat that has to live with it.
    --    INSERT works; UPDATE and DELETE answer 42501. A grant that is never attempted is a grant
    --    nobody knows the shape of, which is 0013's argument for probing the bypass.
    ------------------------------------------------------------------
    SELECT tenant_id INTO v_td FROM tenants WHERE slug = 'default';
    SET LOCAL ROLE afpc_app;
    PERFORM set_config('app.tenant_id', v_td::text, true);
    SELECT success, memory_id INTO v_ok, v_id
      FROM save_memory('0023-probe-b', 'The customer prefers email.', gen_random_uuid());
    IF NOT v_ok OR v_id IS NULL THEN
        RAISE EXCEPTION 'B failed: afpc_app could not save a memory - the grant structure and '
                        'this function have never met';
    END IF;

    -- Both attempts are made WITHOUT leaving the seat, and that ordering is the whole probe: the
    -- first draft RESET ROLEd before the UPDATE and reported a pass on a table afpc_app could in
    -- fact edit. A superuser holds every privilege whatever the ACL says, so an attempt from the
    -- owner's seat measures the owner. This is 0013's probe E lesson and dev/README's masquerading
    -- entry, met from the opposite side - there the mistake was trusting a grant check, here it
    -- was trusting a refusal.
    v_err := NULL;
    BEGIN
        EXECUTE format('UPDATE agent_memories SET content = %L WHERE id = %L', 'rewritten', v_id);
    EXCEPTION WHEN insufficient_privilege THEN
        v_err := '42501';
    END;
    IF v_err IS DISTINCT FROM '42501' THEN
        RAISE EXCEPTION 'B failed: afpc_app updated an append-only row (answered %). A table that '
                        'any caller can edit is not append-only, whatever its comment says',
            coalesce(v_err, 'no error at all');
    END IF;
    v_err := NULL;
    BEGIN
        EXECUTE format('DELETE FROM agent_memories WHERE id = %L', v_id);
    EXCEPTION WHEN insufficient_privilege THEN
        v_err := '42501';
    END;
    IF v_err IS DISTINCT FROM '42501' THEN
        RAISE EXCEPTION 'B failed: afpc_app deleted from an append-only table (answered %)',
            coalesce(v_err, 'no error at all');
    END IF;
    -- The row the refused UPDATE targeted is still there and still says what it was told: the
    -- append-only claim is about content, not about the counter.
    SELECT content INTO v_msg FROM agent_memories WHERE agent_memories.id = v_id;
    IF v_msg IS DISTINCT FROM 'The customer prefers email.' THEN
        RAISE EXCEPTION 'B failed: the refused UPDATE changed the row anyway (content now %)', v_msg;
    END IF;
    RESET ROLE;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- C. the shape is the CHECK's, said once, and a refused argument leaves no row.
    --    '../../etc/passwd' is the character class that made the filename version lossy; the
    --    second fixture is a blank key, which the same constraint covers from the other side.
    ------------------------------------------------------------------
    v_err := NULL;
    BEGIN
        PERFORM * FROM save_memory('../../etc/passwd', 'traversal', NULL);
    EXCEPTION WHEN OTHERS THEN
        v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '23514' THEN
        RAISE EXCEPTION 'C failed: a key outside the published shape answered % - expected the '
                        'CHECK''s own 23514. If this became an IF arm the rule would exist twice, '
                        'and the second copy is the one that rots',
            coalesce(v_err, 'no error - it was STORED');
    END IF;
    IF (SELECT count(*) FROM agent_memories WHERE agent_memories.memory_key LIKE '%passwd%') <> 0 THEN
        RAISE EXCEPTION 'C failed: the refused key wrote a row anyway';
    END IF;

    v_err := NULL;
    BEGIN
        PERFORM * FROM save_memory('   ', 'nothing to remember', NULL);
    EXCEPTION WHEN OTHERS THEN
        v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '23514' THEN
        RAISE EXCEPTION 'C failed: a blank key answered % - the shape constraint is supposed to '
                        'be the only thing that decides this', coalesce(v_err, 'no error');
    END IF;

    v_err := NULL;
    BEGIN
        PERFORM * FROM save_memory('0023-probe-c', '     ', NULL);
    EXCEPTION WHEN OTHERS THEN
        v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '23514' THEN
        RAISE EXCEPTION 'C failed: whitespace-only content answered % - expected '
                        'agent_memories_content_present to be the thing that says no',
            coalesce(v_err, 'no error - it was STORED');
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- D. normalisation: what is NOT identity, and what is. Case and whitespace runs are not
    --    identity, so three spellings of one phrase are one memory with a three-entry history.
    --    Punctuation IS identity, so the underscore form is a DIFFERENT key - and that half is
    --    asserted too, because folding '_' into ' ' would be the filename version's bug revived
    --    under a better name: two intentions, one row, nothing reporting it.
    ------------------------------------------------------------------
    PERFORM * FROM save_memory('0023   PROBE  Key', 'first note', NULL);
    PERFORM * FROM save_memory('  0023 probe key  ', 'second note', NULL);
    PERFORM * FROM save_memory('0023 PROBE KEY', 'third note', NULL);
    SELECT count(*) INTO v_found FROM get_memory('0023 probe key', 10);
    IF v_found <> 3 THEN
        RAISE EXCEPTION 'D failed: three spellings of one phrase produced % entries under it - '
                        'they were meant to be one memory with a history', v_found;
    END IF;
    SELECT count(*) INTO v_found FROM get_memory('0023 probe_key', 10);
    IF v_found <> 0 THEN
        RAISE EXCEPTION 'D failed: the underscore spelling matched % rows - normalisation reached '
                        'past whitespace and folded two different keys together, which is exactly '
                        'what a sanitised filename did', v_found;
    END IF;
    SELECT count(DISTINCT m.memory_key) INTO v_found FROM agent_memories m
     WHERE m.memory_key LIKE '0023 probe%key';
    IF v_found <> 1 THEN
        RAISE EXCEPTION 'D failed: the three spellings landed in % distinct keys, not one', v_found;
    END IF;
    -- Newest first. Asserted positionally against a row whose created_at is deliberately in the
    -- past, because the three saves above share one transaction timestamp - `now()` does not
    -- advance inside a transaction (dev/README) - so among them the ORDER BY falls to the id
    -- tiebreak, and afpc_uuid_v7() orders by millisecond and then by random bits: within the same
    -- millisecond it is not insertion order at all. A probe that demanded 'third note' here would
    -- be a coin flip that happened to look like a test.
    v_msg := NULL;
    INSERT INTO agent_memories (memory_key, content, created_at)
    VALUES ('0023 probe key', 'oldest note', now() - interval '30 days');
    SELECT string_agg(g.content, '|' ORDER BY g.ord) INTO v_msg
      FROM get_memory('0023 PROBE KEY', 10) WITH ORDINALITY AS g(created_at, content, ord);
    IF v_msg IS NULL OR v_msg NOT LIKE '%|oldest note' THEN
        RAISE EXCEPTION 'D failed: the ordered read is % - a 30-day-old entry must be last, which '
                        'is the only ordering claim this fixture can make honestly',
            coalesce(v_msg, 'nothing');
    END IF;
    IF split_part(v_msg, '|', 1) = 'oldest note' THEN
        RAISE EXCEPTION 'D failed: the oldest entry came back first';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- E. a key the shape constraint forbids reads as empty rather than erroring, which is the
    --    documented consequence of stating the shape once. Asserted so that the choice is visible
    --    to whoever wants the read path to refuse instead: at that moment the rule moves to two
    --    places, and this probe is where they find out.
    ------------------------------------------------------------------
    SELECT count(*) INTO v_found FROM get_memory('impossible/key shape', 10);
    IF v_found <> 0 THEN
        RAISE EXCEPTION 'E failed: a malformed key matched % rows - it cannot have been written',
            v_found;
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- F. a retried save is one memory. Same key, same content, same claim; the second answer is
    --    the first row's id and the table did not grow.
    ------------------------------------------------------------------
    v_key := gen_random_uuid();
    SELECT memory_id INTO v_id FROM save_memory('0023-probe-f', 'learned once', v_key);
    SELECT memory_id INTO v_id2 FROM save_memory('0023-probe-f', 'learned once', v_key);
    IF v_id2 IS DISTINCT FROM v_id THEN
        RAISE EXCEPTION 'F failed: the replay answered with a different memory id';
    END IF;
    IF (SELECT count(*) FROM agent_memories m
         WHERE m.memory_key = '0023-probe-f') <> 1 THEN
        RAISE EXCEPTION 'F failed: one claim produced % rows',
            (SELECT count(*) FROM agent_memories m WHERE m.memory_key = '0023-probe-f');
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- G. tenancy, in both directions, from seats that are bound by the wall. A superuser cannot
    --    test this (dev/README's masquerading entry: the owner sees every tenant however the
    --    tables are configured), and the tenant ids are read BEFORE the role switch, because the
    --    tenants table is itself filtered - 0022's probe H learned that the hard way.
    ------------------------------------------------------------------
    INSERT INTO tenants (name, slug) VALUES ('0023 second tenant', 'afpc-0023-t2')
     RETURNING tenant_id INTO v_t2;
    SELECT tenant_id INTO v_td FROM tenants WHERE slug = 'default';

    SET LOCAL ROLE afpc_app;
    PERFORM set_config('app.tenant_id', v_t2::text, true);
    SELECT count(*) INTO v_found FROM list_memories();
    IF v_found <> 0 THEN
        RAISE EXCEPTION 'G failed: a brand-new tenant can already see % memory keys - the wall is '
                        'not filtering the read path', v_found;
    END IF;
    SELECT success INTO v_ok FROM save_memory('0023 PROBE KEY', 'other tenant note', NULL);
    IF NOT v_ok THEN
        RAISE EXCEPTION 'G failed: the second tenant could not write its own memory';
    END IF;
    v_msg := NULL;
    SELECT count(*) INTO v_found FROM get_memory('0023 PROBE KEY', 10);
    IF v_found <> 1 THEN
        RAISE EXCEPTION 'G failed: tenant 2 reads % entries under a key tenant 1 has written '
                        'three times - the aggregate/filter pair is not being bound by the wall',
            v_found;
    END IF;
    SELECT content INTO v_msg FROM get_memory('0023 PROBE KEY', 1);
    IF v_msg IS DISTINCT FROM 'other tenant note' THEN
        RAISE EXCEPTION 'G failed: tenant 2 read tenant 1''s note through a shared key (saw %)',
            coalesce(v_msg, 'nothing');
    END IF;
    RESET ROLE;

    SET LOCAL ROLE afpc_app;
    PERFORM set_config('app.tenant_id', v_td::text, true);
    -- Set membership rather than a positional read: the four entries under this key in this
    -- tenant include three written in one instant and one backdated, and probe D explains why
    -- "which is first" is not answerable among the three. What IS answerable, and what tenancy
    -- has to guarantee, is that tenant 2''s note is not in the set.
    SELECT count(*) INTO v_found FROM get_memory('0023 PROBE KEY', 10);
    IF v_found <> 4 THEN
        RAISE EXCEPTION 'G failed: the default tenant sees % entries under the shared key, '
                        'expected its own four', v_found;
    END IF;
    SELECT count(*) INTO v_found FROM get_memory('0023 PROBE KEY', 10) g
     WHERE g.content = 'other tenant note';
    IF v_found <> 0 THEN
        RAISE EXCEPTION 'G failed: another tenant''s note appears in this tenant''s read (rows %)',
            v_found;
    END IF;
    RESET ROLE;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- H. the registers notice this table by themselves. vw_timestamp_status must call it
    --    append-only-by-decision and not NOT MAINTAINED, vw_audit_coverage must show it trailead,
    --    and vw_idempotency_status must credit save_memory with a claim. All three are derived
    --    from the catalog, so a change in any derivation shows up here instead of in a quarterly
    --    documentation review.
    ------------------------------------------------------------------
    SELECT verdict INTO v_msg FROM vw_timestamp_status WHERE table_name = 'agent_memories';
    IF v_msg NOT LIKE 'no updated_at by decision%' THEN
        RAISE EXCEPTION 'H failed: the timestamp register says % of agent_memories', v_msg;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM vw_audit_coverage a
                    WHERE a.table_name = 'agent_memories' AND a.row_audited) THEN
        RAISE EXCEPTION 'H failed: the coverage register does not see agent_memories as trailead';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM vw_idempotency_status s
                    WHERE s.function = 'save_memory' AND NOT s.unguarded) THEN
        RAISE EXCEPTION 'H failed: the idempotency register does not credit save_memory with a '
                        'claim - either it is not wired or the derivation stopped seeing it';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- I. the trail exists: writing memories produced audit rows, so the memory row is not the
    --    only evidence that it happened (6.2's completeness point, on a table two days old).
    ------------------------------------------------------------------
    IF (SELECT count(*) FROM audit_log l
         WHERE l.table_name = 'agent_memories' AND l.action = 'INSERT') < 5 THEN
        RAISE EXCEPTION 'I failed: % audit rows for a table this probe wrote to at least five '
                        'times - the trigger is attached and firing into nothing',
            (SELECT count(*) FROM audit_log l
              WHERE l.table_name = 'agent_memories' AND l.action = 'INSERT');
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- Cleanup. The table refuses DELETE from afpc_app and the owner performs it, which is the
    -- point of the split; the audit rows about the fixtures stay behind as the record that the
    -- fixtures happened at all (0013 being honest, not residue).
    ------------------------------------------------------------------
    DELETE FROM agent_memories WHERE memory_key LIKE '0023-probe%'
                                OR memory_key LIKE '0023 probe%';
    DELETE FROM idempotency_keys WHERE operation = 'save_memory';
    DELETE FROM tenants WHERE slug = 'afpc-0023-t2';

    IF v_n <> 9 THEN
        RAISE EXCEPTION 'expected 9 behavioural verifications, completed %', v_n;
    END IF;
    RAISE NOTICE 'ADR-002: % checks passed - what the agent remembers is in the database, '
                 'survives a rebuild, is separated by tenant, cannot be edited or deleted by the '
                 'role that writes it, leaves a trail, and is visible in all three registers '
                 'without any of them being told about it', v_n;
END
$$;

-- ---------------------------------------------------------------------------
-- 6. Obligations this file leaves open, on purpose
-- ---------------------------------------------------------------------------
-- * Retention. Append-only by grant means nothing can prune it from an agent's seat, and an
--   append-only table nobody prunes grows forever. The shape to copy is idempotency_sweep: a
--   maintenance function that deletes, owned by the owner, not EXECUTE-able by afpc_app, run by a
--   scheduler rather than by the model. It is not built here because no caller exists yet, and
--   0018 declined a column with no reader for the same reason.
-- * The markdown files the old implementation wrote are not imported. If a deployed container has
--   memories anyone cares about, that is a data migration with its own review, not a footnote -
--   and keys in those files were already folded by filename sanitising, so an import would be
--   inventing which memories were which.
-- * No search_memories. The file version scanned every file for a substring; the SQL form is an
--   ILIKE over content with no index behind it, which is 0006's complaint about indexing what
--   nothing queries. Whoever adds the tool adds the trigram GIN in the same commit.
-- * agent_memories carries no embedding, unlike communications. Memory is keyed facts, not prose
--   to be semantically recalled, and a vector column added to look consistent with 6.4 is a column
--   no code reads.
-- * get_memory and the column identity share one normalisation expression. A helper function
--   would remove the duplication but would also have to join B22's named list of PUBLIC-callable
--   helpers, which is a hand-kept exception list of exactly the kind 0018 prefers to derive. The
--   constraint is the copy that can win, because it refuses a row the writer failed to normalise.
