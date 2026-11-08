-- Finding 4.9: a conversation id named a thread, and not who was on it.
--
-- `pkg/ids` derived `agent_interactions.conversation_id` as uuid5(namespace, "thread", threadID), with
-- no agent in the input, and `pkg/agent`'s rehydration reads history by that id alone. Three deployed
-- backends share one namespace and one tenant, and all three web UIs posted the same thread string -
-- the literal 'default' - so every browser on :4550, :4560 and :4570 was continuing one merged
-- history. The symptom was the sales agent answering "Hi" with "I'm the Inventory Control Agent" on
-- 2026-11-08; the mechanism was the ten prior assistant turns it had been handed, which outranked a
-- correct system prompt. Measured here before the fix: 22 rows under one thread across three agents,
-- and 202 scheduled ticks under the thread 'schedule' across two.
--
-- 0032 re-keys the rows, and `Thread` now takes the pair. What this file adds is the permanent form:
-- the property, the proof that the detector can see it, and the derivation checked as an identity
-- rather than as a hope.
--
-- The helper is the same SQL reproduction 0032 §1 used, restated here because a probe that called a
-- pg_temp function from a migration would be testing whether the migration is still loaded. Its
-- SHA-1 dependency is 0013's, and its output is pkg/ids' - §c is where those two claims meet.

CREATE FUNCTION pg_temp.v5_thread(parts text[]) RETURNS uuid AS $$
DECLARE
    -- uuid5 over the project's namespace, byte-for-byte the way pkg/ids computes it. NUL is why this
    -- is written over bytea rather than with uuid_generate_v5: Postgres text cannot hold 0x00, so a
    -- function taking a string cannot reproduce a pre-image containing one.
    v_raw  bytea := decode(replace('f69d1282-6418-457f-90ba-5482b6cb90c9', '-', ''), 'hex');
    v_name bytea := convert_to('thread', 'UTF8') || '\x00'::bytea;
    v_dig  bytea;
    v_i    int;
BEGIN
    FOR v_i IN 1..coalesce(array_length(parts, 1), 0) LOOP
        v_name := v_name || convert_to(parts[v_i], 'UTF8') || '\x00'::bytea;
    END LOOP;
    v_name := substring(v_name from 1 for length(v_name) - 1);   -- joined, not terminated

    v_dig := digest(v_raw || v_name, 'sha1');
    v_dig := set_byte(v_dig, 6, (get_byte(v_dig, 6) & 15) | 80);   -- version 5
    v_dig := set_byte(v_dig, 8, (get_byte(v_dig, 8) & 63) | 128);  -- RFC 4122 variant
    RETURN encode(substring(v_dig from 1 for 16), 'hex')::uuid;
END $$ LANGUAGE plpgsql IMMUTABLE;

BEGIN;

-- ---------------------------------------------------------------------------
-- 4.9a. The detector has seen the thing it detects: plant one thread string
--       shared by two agents, and require the query to notice.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_found int;
BEGIN
    INSERT INTO agent_interactions (conversation_id, run_id, bot_id, telegram_chat_id, "timestamp",
                                    human_input, final_output, tenant_id)
    VALUES
        ('00000000-0000-5000-8000-000000000499', '00000000-0000-4000-8000-0000000049a1',
         'sales', 'planted-4_9a', now(), '<planted 4_9a sales>', 'said sales',
             '00000000-0000-0000-0000-000000000001'),
        ('00000000-0000-5000-8000-000000000499', '00000000-0000-4000-8000-0000000049a2',
         'inventory', 'planted-4_9a', now(), '<planted 4_9a inventory>', 'said inventory',
             '00000000-0000-0000-0000-000000000001');

    SELECT count(*) INTO v_found
      FROM (SELECT conversation_id
              FROM agent_interactions
             WHERE telegram_chat_id IS NOT NULL
             GROUP BY conversation_id
            HAVING count(DISTINCT bot_id) > 1) d;

    IF v_found = 0 THEN
        -- The plant is the finding and the query walked past it. Anything 4.9b would then report is
        -- about nothing, so this is the line that has to be true first.
        RAISE NOTICE 'VERDICT ERR 0 | the detector does not see a conversation shared by two agents '
                     'even when one is planted in front of it, so 4.9b cannot certify anything';
    ELSE
        RAISE NOTICE 'VERDICT OK 4.9a: a shared conversation is detectable (% found with the plant '
                     'in place)', v_found;
    END IF;
END
$$;

ROLLBACK;

-- ---------------------------------------------------------------------------
-- 4.9b. On this database's own rows: no conversation belongs to two agents.
--       Filtered to rows carrying a thread string, because 0017's fixture rows
--       invent ids and are not this rule's subject. The count is printed so a
--       reader can see whether the assertion had anything to look at.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_shared  int;
    v_legible int;
BEGIN
    SELECT count(*) FILTER (WHERE telegram_chat_id IS NOT NULL) INTO v_legible
      FROM agent_interactions;

    IF v_legible = 0 THEN
        -- Not a pass: a database that has never served a chat cannot demonstrate separation. This is
        -- the branch that would otherwise read CLOSED through silence.
        RAISE NOTICE 'VERDICT KNOWN-OPEN 4.9 | no row carries a thread string, so the shared-'
                     'conversation question is unasked here; run one turn against each agent first';
        RETURN;
    END IF;

    SELECT count(*) INTO v_shared
      FROM (SELECT conversation_id
              FROM agent_interactions
             WHERE telegram_chat_id IS NOT NULL
             GROUP BY conversation_id
            HAVING count(DISTINCT bot_id) > 1) d;

    IF v_shared > 0 THEN
        RAISE NOTICE 'VERDICT ERR 4.9 | % conversation ids hold turns of more than one agent (% '
                     'legible rows): rehydration would hand one agent another agent''s voice',
                     v_shared, v_legible;
    ELSE
        RAISE NOTICE 'VERDICT OK 4.9b: % legible rows, and no conversation is shared between agents',
                     v_legible;
    END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- 4.9c. The derivation, as an identity rather than a property: every legible row
--       is uuid5(thread, agent, thread), and nothing still is what the thread
--       alone named. The second half is the one that goes red when a writer
--       regresses to the old call, which is otherwise a greeting away from being
--       noticed by a human instead.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_new_bad int;
    v_old_left int;
BEGIN
    SELECT count(*) FILTER (WHERE conversation_id <> pg_temp.v5_thread(ARRAY[bot_id, telegram_chat_id])),
           count(*) FILTER (WHERE conversation_id =  pg_temp.v5_thread(ARRAY[telegram_chat_id]))
      INTO v_new_bad, v_old_left
      FROM agent_interactions
     WHERE telegram_chat_id IS NOT NULL;

    IF v_new_bad > 0 OR v_old_left > 0 THEN
        RAISE NOTICE 'VERDICT ERR 4.9 | % legible rows disagree with the (agent, thread) derivation '
                     'and % still carry the thread-only id - either 0032 has not been applied here or '
                     'a writer is calling ids.Thread with one argument', v_new_bad, v_old_left;
    ELSE
        RAISE NOTICE 'VERDICT OK 4.9c: every legible row''s conversation id is the derivation of the '
                     'pair that names it, and none is what the thread alone named';
    END IF;
END
$$;
