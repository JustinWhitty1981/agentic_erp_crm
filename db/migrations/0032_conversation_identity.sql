-- 0032: give a conversation the agent it happened with
--       (re-keys agent_interactions.conversation_id after ids.Thread began including the agent)
--
-- WHY THIS FILE EXISTS
--
-- The sales agent answered "Hi" on 2026-11-08 with "I'm the Inventory Control Agent - stock levels,
-- shortages, movement history, valuation, and reservations", and followed it with a shelf report it had
-- never read. Its system prompt is correct - "You are the Sales and Procurement Agent" is the first
-- sentence the binary builds - and the reason the answer was not is that the prompt was outranked by
-- ten worked examples: the read path that rehydrates a conversation's history (`pkg/agent`'s
-- `Rehydrate`, from `vw_recent_interactions WHERE conversation_id = $1`) was handed another agent's
-- turns and the model answered in the voice it was shown.
--
-- The cause is one omitted argument. `pkg/ids` derived the conversation id as
-- uuid5(namespace, "thread", threadID): a name with a *which* and no *whose*. Three backends share one
-- namespace and one tenant, so a thread string named one conversation between all of them - and this
-- is not an edge case, because all three web UIs post the same thread string. `App.tsx` had been
-- sending the literal 'default' since the first fork, so every browser on :4550, :4560 and :4570 was
-- continuing one merged history. Measured on this server before the change: 22 rows under the thread
-- 'default' spread over three agents, and 202 rows under the scheduled thread 'schedule' spread over
-- two - every tick of the inventory agent and every tick of the sales agent filed as one conversation.
--
-- The Go half is fixed in the three backends' `pkg/ids/ids.go` (`Thread(agentID, threadID)`) and at
-- the one reader that needed it. `logging.NewRun` already received `botID` and used it only as a label
-- on the row, so the identity was at the call site and unused - which is the whole of the bug's shape.
--
-- WHY THIS CAN BE DONE WITHOUT LOSING A CONVERSATION
--
-- A change to a derivation cannot normally be repaired in SQL, because the table holds the hash and
-- not the input. Here it can, because `pkg/logging` writes the caller's thread string into
-- `telegram_chat_id`: a column whose name is a relic of the blueprint's Telegram transport and whose
-- content, in all three deployed agents, is the HTTP thread id (`docs/INTERACTION_LOGGING.md` says so,
-- and the first query below is the measurement). So every row can be re-derived, and history does not
-- have to start over to become correct.
--
-- WHAT THE FILE DOES
--
--   §1 reproduces the derivation in SQL and proves it against what the deployed code already wrote,
--      refusing to continue if it reproduces nothing - the failure where this file would silently
--      re-key nothing and report a clean run.
--   §2 re-keys, per tenant, the rows the OLD derivation names. Idempotent by construction: a row
--      already carrying the new id is not the old derivation of anything, so it is not touched, and
--      re-running the file changes zero rows.
--   §3 asserts the post-condition the defect denies: no conversation this schema holds belongs to two
--      agents.
--
-- The helper is a TEMPORARY object. It exists so one UPDATE can call it, and it disappears with the
-- session, which is the right lifetime for a function whose only purpose is to reproduce a hash a Go
-- program computes. Its SHA-1 dependency is the same kind of dependency 0013's audit chain already
-- has on `digest()` - pgcrypto is in the baseline for both.
--
-- WHAT THIS FILE DOES NOT DO, AND WHY THAT IS THE RIGHT ANSWER
--
-- It does not add a `conversations` table with a `bot_id` column and make `agent_interactions` point at
-- it. That is the shape in which the schema itself could refuse a shared conversation - a CHECK cannot
-- see other rows, so the constraint would need the table - and it is declined for the reason 0016 gives
-- about two heads on one door: `ids.Thread` already says who a conversation is with, and a second place
-- that says it is a second place to keep in step. The registry would also make every run two INSERTs,
-- one of which exists only to be joined back. If a fourth agent ever makes conversation ownership a
-- thing to *query* rather than to derive, that is when the table earns its keep, and the derivation
-- stays the same either way.
--
-- Grants: none. This file changes one column's values on a table whose write path is the loop's
-- INSERT and this UPDATE. The runner wraps it in one transaction, so §1's refusal or §3's assertion
-- leaves the ledger untouched and nothing is half re-keyed. Row security is FORCED on
-- `agent_interactions`, so §2 sets `app.tenant_id` per tenant rather than relying on the owner's
-- exemption, which 0009 removed. The row trail fires on every re-keyed row, which is correct: 430
-- identities re-attributed after the fact, and five turns written since the code changed, are exactly
-- the kind of thing `audit_log` exists to be able to say.

--------------------------------------------------------------------------
-- §1. The derivation, in SQL, checked against the rows the code wrote.
--------------------------------------------------------------------------
CREATE FUNCTION pg_temp.afpc_thread_conversation(parts text[]) RETURNS uuid AS $$
DECLARE
    -- uuid5 over the project's namespace, byte-for-byte the way pkg/ids computes it: the namespace's
    -- 16 raw bytes, then the kind, then the parts joined with NUL - and NUL is why this cannot be
    -- written as uuid_generate_v5(ns, text): Postgres text cannot hold a 0x00 byte, so a helper that
    -- took a string could not reproduce a pre-image that contains one.
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

DO $$
DECLARE
    v_rows        int;
    v_legible     int;
    v_old_matches int;
    v_new_matches int;
    v_nobody     int;
BEGIN
    SELECT count(*), count(*) FILTER (WHERE telegram_chat_id IS NOT NULL)
      INTO v_rows, v_legible
      FROM agent_interactions;

    -- The OLD derivation: thread string alone. The NEW one: agent then thread string. Counting both
    -- says which code wrote this database, which is the fact §2 acts on.
    SELECT count(*) FILTER (WHERE conversation_id =
                     pg_temp.afpc_thread_conversation(ARRAY[telegram_chat_id])),
           count(*) FILTER (WHERE conversation_id =
                     pg_temp.afpc_thread_conversation(ARRAY[bot_id, telegram_chat_id]))
      INTO v_old_matches, v_new_matches
      FROM agent_interactions
     WHERE telegram_chat_id IS NOT NULL;

    RAISE NOTICE '0032 §1: % rows, % with a legible thread string; % match the old derivation, % the new',
        v_rows, v_legible, v_old_matches, v_new_matches;

    IF v_legible > 0 AND v_old_matches = 0 AND v_new_matches = 0 THEN
        RAISE EXCEPTION '0032 §1: the SQL derivation reproduces none of the % conversation ids this '
                        'database holds, so either pkg/ids changed again or these rows were not '
                        'written by it. Refusing to re-key on a guess.', v_legible
            USING HINT = 'read ids.Thread and the two ARRAY[...] forms above side by side. A '
                         'derivation this file cannot reproduce is a derivation this file must not '
                         'rewrite: the re-key would move every history into identifiers nothing reads '
                         'back, which is the discontinuity this file exists to avoid.';
    END IF;

    -- `bot_id` is nullable in the schema (it has been NOT NULL in practice since 0017, which is what
    -- the check reports rather than assumes). A row without one cannot be re-keyed to a pair, so it is
    -- named here and left alone by §2 rather than silently matching nothing.
    SELECT count(*) INTO v_nobody
      FROM agent_interactions
     WHERE telegram_chat_id IS NOT NULL AND bot_id IS NULL;
    IF v_nobody > 0 THEN
        RAISE NOTICE '0032 §1: % rows have a thread and no bot_id, so the pair is unresolvable and '
                     'they are left as they are', v_nobody;
    END IF;

    IF v_legible < v_rows THEN
        RAISE NOTICE '0032 §1: % rows have no thread string and cannot be re-derived. Those are '
                     'fixture rows (0017 inserts conversation ids directly); §2 leaves them alone '
                     'and §3 does not judge them.', v_rows - v_legible;
    END IF;
END
$$;

--------------------------------------------------------------------------
-- §2. Re-key the rows the old derivation names.
--------------------------------------------------------------------------
DO $$
DECLARE
    v_t      record;
    v_moved  int := 0;
    v_touch  int;
BEGIN
    FOR v_t IN SELECT tenant_id FROM tenants ORDER BY tenant_id LOOP
        -- Row security on this table is FORCED, and a forced policy applies to the owner too: without
        -- this the UPDATE below would evaluate afpc_policy_tenant() and abort with 55000 rather than
        -- quietly rewrite nothing.
        PERFORM set_config('app.tenant_id', v_t.tenant_id::text, true);

        UPDATE agent_interactions a
           SET conversation_id = pg_temp.afpc_thread_conversation(ARRAY[a.bot_id, a.telegram_chat_id])
         WHERE a.tenant_id = v_t.tenant_id
           AND a.telegram_chat_id IS NOT NULL
           AND a.bot_id IS NOT NULL          -- §1 counts them; the pair needs both halves
           -- The narrow predicate, and it is the whole of the safety: rewrite only rows whose id is
           -- what the OLD rule produced. A row the new code wrote already disagrees with that and is
           -- left exactly as it is, which is what makes this file re-runnable.
           AND a.conversation_id = pg_temp.afpc_thread_conversation(ARRAY[a.telegram_chat_id]);

        GET DIAGNOSTICS v_touch = ROW_COUNT;
        v_moved := v_moved + v_touch;
    END LOOP;

    RAISE NOTICE '0032 §2: % rows re-keyed to a conversation id that names the agent as well as the '
                 'thread', v_moved;
END
$$;

--------------------------------------------------------------------------
-- §3. The post-condition, which is the defect stated as something to check.
--------------------------------------------------------------------------
DO $$
DECLARE
    v_shared int;
BEGIN
    -- Every tenant is visible to this check through the SELECT policy (`audit_read_all` is
    -- unconditional), so no set_config is needed to assert across the table.
    SELECT count(*) INTO v_shared
      FROM (
        SELECT conversation_id
          FROM agent_interactions
         WHERE telegram_chat_id IS NOT NULL
         GROUP BY conversation_id
        HAVING count(DISTINCT bot_id) > 1
      ) d;

    IF v_shared > 0 THEN
        RAISE EXCEPTION '0032 §3: % conversation ids still hold turns of more than one agent. A '
                        'conversation that belongs to two processes is a history each of them will '
                        'answer in the other''s voice.', v_shared
            USING HINT = 'the derivation is in pkg/ids/ids.go (Thread) and the reader is '
                         'pkg/agent''s Rehydrate; §2 re-keys only rows whose id is the old '
                         'derivation, so a row surviving here was written by a third path';
    END IF;

    RAISE NOTICE 'VERDICT OK 0032 §3: no conversation in this database belongs to two agents, and '
                 'every re-keyed row''s id is a function of the pair that names it';
END
$$;
