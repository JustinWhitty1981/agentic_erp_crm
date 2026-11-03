-- 0017: the debug read path the documentation already promised, and the honest answer to the
--       two table names that turned out not to be on any code path
--       (DATABASE_REVIEW.md 4.5; ADR-001's rule, given a way to be read)
--
-- 4.5 ends with "Also referenced but created nowhere: agent_tool_calls ... and tickets". Both
-- halves of that sentence needed measuring before acting, and both came out differently:
--
--   * `agent_tool_calls` is touched by exactly one file - `blueprint/tools/tool_logger.py`, five
--     statements - and nothing imports that module (measured: no reference in any file under
--     `blueprint/`). Its first act is `CREATE TABLE IF NOT EXISTS`, plus three indexes, at
--     runtime, in a schema the connection cannot create in. That is not a missing table, it is
--     a second implementation of ADR-001's rule that never ran: the canonical mechanism is
--     `agent_interactions`, which `interaction_logger.py` does write, with `actions_taken` and
--     `tool_observations` as per-step jsonb arrays and one row per run.
--   * `tickets` is touched by no code at all. Its only reference in the repository is a
--     `LEFT JOIN agent_first_erp_crm.tickets` in `blueprint/08_create_views.sql:218` - a file
--     `db/README.md` lists as superseded - and the view that join belonged to
--     (`vw_agent_activity_summary`) was ported without it: measured against the live
--     definition, no canonical object names `tickets`.
--
-- What IS missing, and what this file actually builds, is three objects the documentation
-- treats as existing. `AGENTS.md`'s view table and `docs/INTERACTION_LOGGING.md` both advertise
-- `vw_recent_interactions`, `vw_failed_interactions` and `vw_tool_performance` as how anyone -
-- human or agent - reads agent behaviour back. Measured: 0 of 3 exist. They live in
-- `blueprint/11_interaction_logging.sql`, and `0001` ported that file's TABLE and not its
-- VIEWS, so the port carried half of a feature and left the other half in a superseded file -
-- §3.1's split, one directory level down. The debugging instructions in this repository's own
-- entry point have been telling agents to query three views that raise 42P01.
--
-- The legacy definitions are not worth copying, and four measurements say so. All four are
-- arithmetic on `actions_taken` fan-out, so they are stated as numbers:
--
--   * one run that errors and used three tools reports `error_count = 3` for each of those
--     tools' rows, where the truth is one errored run (measured on a clone: 3 printed against
--     1);
--   * `avg_duration_ms` averages the RUN's duration once per call, so a 900 ms run that made
--     three calls to one tool and a 100 ms run that made one produce 700 ms where the mean over
--     the two runs that used the tool is 500 ms (measured, same fixture);
--   * `ORDER BY ... LIMIT 100` inside the view truncates BEFORE a caller's filter, so asking
--     "the recent interactions of bot Z" when Z's five runs are older than someone else's newest
--     four returns **0 rows** while the table holds 5 (measured) - a debug view whose answer to
--     a real question is "nothing happened" is worse than no view;
--   * one row whose `actions_taken` holds a JSON object instead of an array makes the whole
--     view fail with 22023 "cannot extract elements from an object" (measured): a single bad
--     write takes down the read path for every tenant, which is the availability shape of 4.6's
--     "a report no one can run".
--
-- So: four views here, all derived from the canonical table, and no tables. One thing the
-- derivation genuinely cannot recover is stated rather than glossed - per-CALL errors.
-- `agent_interactions` records one `error_message` per run, and `tool_observations[].type` is
-- the Python class name of the observation, which is `str` for a tool that returned an error
-- text and `str` for a tool that returned a result. `vw_tool_calls` therefore exposes
-- `run_errored`, and probe H demonstrates that it is a run-level fact wearing a per-call row.
-- If per-call failures ever need to be an answer rather than an inference, the schema change is
-- a column on the step arrays, not a parallel log table - and §2's COMMENT says so where the
-- next reader will find it.

SET client_min_messages TO notice;

-- ---------------------------------------------------------------------------
-- 1. One row per tool call, derived
-- ---------------------------------------------------------------------------
-- The grain `agent_tool_calls` would have stored, computed from the arrays the live logger
-- already writes. Positional pairing is what makes it a call rather than a set: step n of
-- `actions_taken` and step n of `tool_observations` are the same LangChain (action, observation)
-- pair, because `interaction_logger.py` appends one of each inside the same loop iteration.
-- That is an agreement between two columns, so it is checked rather than assumed: when the two
-- arrays are different lengths every observation in that run reads NULL with
-- `observations_aligned` false, because a silently mis-paired output is how a debug view starts
-- a lie.
CREATE OR REPLACE VIEW vw_tool_calls AS
SELECT i.tenant_id,
       i.id            AS interaction_id,
       i.conversation_id,
       i.run_id,
       i.bot_id,
       i."timestamp"   AS interaction_at,
       a.ord           AS step_number,
       a.value ->> 'tool'                  AS tool_name,
       (a.value -> 'tool_input')           AS tool_input,
       (a.value ->> 'timestamp')           AS action_at,
       (o.value -> 'output')               AS observation,
       (o.value ->> 'type')                AS observation_type,
       (jsonb_array_length(i.tool_observations) = jsonb_array_length(i.actions_taken))
                                           AS observations_aligned,
       i.error_message IS NOT NULL         AS run_errored,
       i.duration_ms                       AS run_duration_ms
  FROM agent_interactions i
 CROSS JOIN LATERAL jsonb_array_elements(i.actions_taken)
                    WITH ORDINALITY AS a(value, ord)
  LEFT JOIN LATERAL jsonb_array_elements(i.tool_observations)
                    WITH ORDINALITY AS o(value, ord) ON o.ord = a.ord
 WHERE jsonb_typeof(i.actions_taken) = 'array'
   AND jsonb_typeof(i.tool_observations) = 'array';

COMMENT ON VIEW vw_tool_calls IS
    'One row per tool invocation, derived from agent_interactions by position: step n of '
    'actions_taken paired with step n of tool_observations. Built by 0017 as the answer to the '
    'question "what did the agent call, in what order, with what in and what out" - which is '
    'the table 4.5 found referenced and never created. It is a view and not a table on purpose: '
    'a second log of the same calls is a second implementation of ADR-001''s rule, and the two '
    'copies drift, which is what §3.3 is a post-mortem for. Runs whose arrays are not both '
    'JSON arrays contribute no rows at all, so this view counts calls, never runs; '
    'vw_tool_performance carries that limit forward and says so. What it cannot tell you is '
    'which call failed: the base table records one error_message per run, and the observation''s '
    '"type" is a Python class name that reads str for both a result and an error, so '
    'run_errored is a run-level fact wearing a per-call row. Making per-call failure an answer '
    'means a key on the step objects, not a parallel table.';

-- ---------------------------------------------------------------------------
-- 2. The performance report, with the fan-out arithmetic done once
-- ---------------------------------------------------------------------------
-- Call counts come from the calls; run-level numbers come from the runs, after the calls have
-- been deduplicated back to them. That is the whole difference from the legacy definition, and
-- §'s header carries the two numbers it changes (error_count 3 -> 1, avg 700 -> 500 on the
-- fixture probe C builds).
CREATE OR REPLACE VIEW vw_tool_performance AS
WITH calls AS (
    SELECT tenant_id, tool_name, interaction_id, run_errored, run_duration_ms
      FROM vw_tool_calls
), per_tool AS (
    SELECT tenant_id, tool_name, count(*) AS call_count
      FROM calls
     GROUP BY tenant_id, tool_name
), run_attrs AS (
    -- Back to one row per (tool, run): the DISTINCT is what stops a tool called three times in
    -- one run contributing that run's duration and error state three times.
    SELECT DISTINCT tenant_id, tool_name, interaction_id, run_errored, run_duration_ms
      FROM calls
), per_run AS (
    SELECT tenant_id, tool_name,
           count(*)                        AS run_count,
           avg(run_duration_ms)              AS mean_run_duration_ms,
           count(*) FILTER (WHERE run_errored) AS errored_run_count
      FROM run_attrs
     GROUP BY tenant_id, tool_name
)
SELECT p.tenant_id,
       p.tool_name,
       p.call_count,
       r.run_count,
       round(r.mean_run_duration_ms::numeric, 1) AS mean_run_duration_ms,
       r.errored_run_count,
       round(100.0 * r.errored_run_count / r.run_count, 1) AS errored_run_pct
  FROM per_tool p
  JOIN per_run r ON r.tenant_id = p.tenant_id AND r.tool_name = p.tool_name;

COMMENT ON VIEW vw_tool_performance IS
    'Per tool, per tenant: how many calls, in how many runs, how long those runs took on '
    'average, and how many of them ended in an error. The column names say which grain each '
    'number is measured at, because the version of this report in '
    'blueprint/11_interaction_logging.sql averaged and counted at the call grain using '
    'run-level values - measured, an errored run of three calls printed error_count 3, and a '
    '900 ms run beside a 100 ms one printed 700 ms instead of 500. mean_run_duration_ms is a '
    'run duration, not a tool latency: agent_interactions has no per-step timing beyond an '
    'ISO timestamp, so the honest unit is the run. errored_run_pct is the share of runs that '
    'used this tool and reported an error anywhere in themselves - an error in another '
    'tool''s step is counted here too, which is what the data supports and, after 0017, what '
    'the column admits. Built by 0017 from vw_tool_calls.';

-- ---------------------------------------------------------------------------
-- 3. The two listings, without the truncation that answered "nothing happened"
-- ---------------------------------------------------------------------------
-- Both are the documented "quick analysis" path, so both carry every column the legacy
-- definition had plus `tenant_id` - with one exception, stated in the view's own comment: the
-- listing drops `actions_taken` for `step_count`, because a listing that projects the payload
-- pays for rows nobody meant to open. Neither keeps the ORDER BY ... LIMIT: a predicate cannot
-- be pushed below a LIMIT, so a filtered read of a truncated view reports the absence of rows
-- that exist. The order the legacy view promised is not a property a view can hold anyway (an
-- outer plan is free to re-sort), so it moves to the documentation, where a caller writes it.
CREATE OR REPLACE VIEW vw_recent_interactions AS
SELECT tenant_id,
       id AS interaction_id,
       "timestamp",
       conversation_id,
       run_id,
       telegram_chat_id,
       user_id,
       bot_id,
       human_input,
       intent_classification,
       final_output,
       error_message,
       duration_ms,
       jsonb_array_length(CASE WHEN jsonb_typeof(actions_taken) = 'array'
                               THEN actions_taken ELSE '[]'::jsonb END) AS step_count
  FROM agent_interactions;

COMMENT ON VIEW vw_recent_interactions IS
    'Every interaction the caller''s row security can reach, newest rows first only if the '
    'caller says ORDER BY "timestamp" DESC. The 100 in this view''s documentation is a LIMIT a '
    'caller writes, not one the view hides: the version in '
    'blueprint/11_interaction_logging.sql truncated inside itself, and a filter applied on top '
    'of a truncation runs after it - measured, five rows of the bot being asked about were in '
    'the table and the view answered with zero rows. step_count is exposed so a scan of this '
    'view does not have to expand actions_taken to see whether a run is worth opening. Built '
    'by 0017.';

CREATE OR REPLACE VIEW vw_failed_interactions AS
SELECT tenant_id,
       id AS interaction_id,
       "timestamp",
       conversation_id,
       run_id,
       telegram_chat_id,
       user_id,
       bot_id,
       model_used,
       human_input,
       actions_taken,
       error_message,
       duration_ms
  FROM agent_interactions
 WHERE error_message IS NOT NULL;

COMMENT ON VIEW vw_failed_interactions IS
    'Runs that ended with an error_message. The column is run-level, so this view answers '
    '"which runs failed", never "which tool failed" - see vw_tool_calls''s comment for the one '
    'thing the derivation cannot recover and what a schema change would have to add to close '
    'it. actions_taken is projected here because a failure worth reading is worth reading in '
    'full; vw_recent_interactions deliberately does not, and offers step_count instead - the '
    'same reason 0012 took e.embedding out of vw_customers: a listing view that projects a wide '
    'column makes every scan pay for rows nobody intended to open. Built by 0017.';

-- ---------------------------------------------------------------------------
-- 4. The two names, decided rather than left open
-- ---------------------------------------------------------------------------
-- Nothing to create, so nothing is created, and the decision is written where both harnesses
-- read. `agent_tool_calls` is answered by vw_tool_calls: the same rows, derived from the log
-- the live code already writes, with one writer instead of two. `tickets` has no writer, no
-- reader, and no consumer in the model - its only appearance is a LEFT JOIN in a superseded
-- file - and a table that only a dead join references is 0007's dead-vocabulary member wearing
-- a CREATE. Probe G is the guard that keeps this from rotting into folklore: it fails the day
-- something in the schema starts referencing either name, which is the moment the decision has
-- to be revisited rather than quietly reversed.

-- ---------------------------------------------------------------------------
-- 5. Privileges and the wall, the way 0009 does them
-- ---------------------------------------------------------------------------
-- Four new views over a tenant-coded table: SELECT to both read roles, then
-- security_invoker - AFTER the create, because 0009 measured that the reloption is dropped by
-- a replace and B21 counts views that would run as their owner.
GRANT SELECT ON vw_tool_calls, vw_tool_performance,
                vw_recent_interactions, vw_failed_interactions TO afpc_readonly, afpc_auditor;

ALTER VIEW vw_tool_calls           SET (security_invoker = true);
ALTER VIEW vw_tool_performance     SET (security_invoker = true);
ALTER VIEW vw_recent_interactions  SET (security_invoker = true);
ALTER VIEW vw_failed_interactions  SET (security_invoker = true);

-- ---------------------------------------------------------------------------
-- 6. Verify by behaving
-- ---------------------------------------------------------------------------
-- Fixtures are tagged by run_id so no probe counts a row some earlier migration left behind:
-- agent_interactions is written by 0013's and 0016's probes too, and a report view asserted
-- against the whole table would fail for someone else's data.
DO $$
DECLARE
    v_t2     uuid;
    v_i1     uuid;
    v_i2     uuid;
    v_i3     uuid;
    v_rows   bigint;
    v_val    numeric;
    v_txt    text;
    v_err    text;
    v_pct    numeric;
    v_n      int := 0;
    r        record;
BEGIN
    ------------------------------------------------------------------
    -- A. the three views the documentation has been advertising exist now, all four expose
    --    the tenant, all four run as the caller, and the two names 4.5 asked about are still
    --    absent - which is the decision, not an omission, and §4 says where the reasoning is.
    ------------------------------------------------------------------
    IF (SELECT count(*) FROM pg_class
         WHERE relnamespace = 'public'::regnamespace AND relkind = 'v'
           AND relname IN ('vw_tool_calls','vw_tool_performance',
                           'vw_recent_interactions','vw_failed_interactions')) <> 4 THEN
        RAISE EXCEPTION 'A failed: % of the four read-path views are installed',
            (SELECT count(*) FROM pg_class
              WHERE relnamespace = 'public'::regnamespace AND relkind = 'v'
                AND relname IN ('vw_tool_calls','vw_tool_performance',
                                'vw_recent_interactions','vw_failed_interactions'));
    END IF;
    IF EXISTS (SELECT 1 FROM pg_class c
                WHERE c.relname IN ('vw_tool_calls','vw_tool_performance',
                                    'vw_recent_interactions','vw_failed_interactions')
                  AND c.relkind = 'v'
                  AND NOT EXISTS (SELECT 1 FROM pg_attribute a
                                   WHERE a.attrelid = c.oid AND a.attname = 'tenant_id'
                                     AND a.attnum > 0 AND NOT a.attisdropped)) THEN
        RAISE EXCEPTION 'A failed: a listing view over a tenant-coded table does not expose '
                        'tenant_id, which is 0009''s rule for why the column had to be added';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_class c WHERE c.relkind = 'v'
                AND c.relname IN ('vw_tool_calls','vw_tool_performance',
                                  'vw_recent_interactions','vw_failed_interactions')
                AND coalesce(array_to_string(c.reloptions, ','), '')
                    NOT LIKE '%security_invoker=true%') THEN
        RAISE EXCEPTION 'A failed: one of the new views would run as its owner and skip the '
                        'wall - B21 will say so too, but this file should not need it';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_class WHERE relname IN ('agent_tool_calls','tickets')) THEN
        RAISE EXCEPTION 'A failed: 0017 decided against creating these and one is here: %',
            (SELECT string_agg(relname, ',' ) FROM pg_class
              WHERE relname IN ('agent_tool_calls','tickets'));
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- B. the derivation: one row per call, paired by position, in order. Tool names are
    --    namespaced per probe because vw_tool_performance has no run_id to filter on - a
    --    probe that aggregated over someone else's fixture would report a number nobody
    --    caused, which is the mistake 4_6's simulation arm made from the other side.
    ------------------------------------------------------------------
    INSERT INTO agent_interactions (conversation_id, run_id, bot_id, "timestamp",
                                    actions_taken, tool_observations, duration_ms)
         VALUES (gen_random_uuid(), '0017-B', '0017-bot', now(),
                 '[{"tool":"b_lookup","tool_input":"Suzy"},
                   {"tool":"b_update","tool_input":"Suzy"},
                   {"tool":"b_lookup","tool_input":"Bob"}]'::jsonb,
                 '[{"output":"2 matches","type":"str"},
                   {"output":"updated","type":"dict"},
                   {"output":"1 match","type":"str"}]'::jsonb,
                 120)
     RETURNING id INTO v_i1;

    SELECT count(*) INTO v_rows FROM vw_tool_calls WHERE interaction_id = v_i1;
    IF v_rows <> 3 THEN
        RAISE EXCEPTION 'B failed: a run of three tool steps derived % rows', v_rows;
    END IF;
    IF (SELECT count(*) FROM vw_tool_calls c
         WHERE c.interaction_id = v_i1
           AND c.step_number = 2
           AND c.tool_name = 'b_update'
           AND c.tool_input #> '{}' IS NOT NULL
           -- observation is the OUTPUT value, not the whole step element (the element's
           -- "type" is exposed beside it), so a scalar output is read with #>>'{}': the first
           -- draft of this assertion wrote ->>'output' and matched nothing, because the jsonb
           -- string "2 matches" has no key to index.
           AND c.observation #>> '{}' = 'updated'
           AND c.observations_aligned) <> 1 THEN
        RAISE EXCEPTION 'B failed: step 2 did not pair the tool with its own output: %',
            (SELECT string_agg(step_number::text || '=' || coalesce(tool_name,'-') || '->'
                              || coalesce(c.observation ->> 'output','-'), ',' ORDER BY step_number)
               FROM vw_tool_calls c WHERE c.interaction_id = v_i1);
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- C. the arithmetic the legacy definition got wrong, asserted as numbers. Two runs: a
    --    100 ms clean one that made one call, and a 900 ms one that made three calls to the
    --    same tool and then failed. The truth is 4 calls in 2 runs, mean run duration 500 ms,
    --    1 errored run. The fan-out version printed 700 ms and error_count 3 - measured on a
    --    clone with the legacy definition mounted, which is why the numbers in this probe are
    --    exact rather than approximate.
    ------------------------------------------------------------------
    INSERT INTO agent_interactions (conversation_id, run_id, bot_id, "timestamp",
                                    actions_taken, tool_observations, duration_ms)
         VALUES (gen_random_uuid(), '0017-C1', '0017-bot', now() - interval '1 minute',
                 '[{"tool":"c_lookup"},{"tool":"c_other"}]'::jsonb,
                 '[{"output":"x","type":"str"},{"output":"y","type":"str"}]'::jsonb,
                 100)
     RETURNING id INTO v_i2;
    INSERT INTO agent_interactions (conversation_id, run_id, bot_id, "timestamp",
                                    actions_taken, tool_observations, duration_ms, error_message)
         VALUES (gen_random_uuid(), '0017-C2', '0017-bot', now(),
                 '[{"tool":"c_lookup"},{"tool":"c_lookup"},{"tool":"c_lookup"}]'::jsonb,
                 '[{"output":"x","type":"str"},{"output":"y","type":"str"},{"output":"z","type":"str"}]'::jsonb,
                 900, 'the run failed at the third step')
     RETURNING id INTO v_i3;

    SELECT call_count, run_count, mean_run_duration_ms::text, errored_run_count::text,
           errored_run_pct
      INTO v_rows, v_val, v_txt, v_err, v_pct
      FROM vw_tool_performance WHERE tool_name = 'c_lookup';
    IF v_rows <> 4 OR v_val <> 2 OR v_txt <> '500.0' OR v_err <> '1' THEN
        RAISE EXCEPTION 'C failed: c_lookup reports % calls in % runs, mean run % ms, % '
                        'errored runs - the fan-out version printed 4/3 calls and 700 ms and '
                        'error_count 3, so at least one of these numbers is still counted at '
                        'the wrong grain',
            v_rows, v_val, v_txt, v_err;
    END IF;
    IF v_pct IS DISTINCT FROM 50.0 THEN
        RAISE EXCEPTION 'C failed: errored_run_pct is % where 1 of 2 runs is 50.0', v_pct;
    END IF;
    IF (SELECT count(*) FROM vw_tool_performance WHERE tool_name = 'c_other') <> 1
       OR (SELECT errored_run_count FROM vw_tool_performance WHERE tool_name = 'c_other') <> 0 THEN
        RAISE EXCEPTION 'C failed: a tool used only in the clean run does not report 0 errored '
                        'runs - the error is being attributed to every tool in reach';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- D. no truncation before a filter. Five runs of one bot, older than five runs of another:
    --    asking for the first bot must return five rows, where the legacy LIMIT-in-a-view
    --    returned zero (measured: 5 in the table, 0 through the view).
    ------------------------------------------------------------------
    INSERT INTO agent_interactions (conversation_id, run_id, bot_id, "timestamp")
         SELECT gen_random_uuid(), '0017-D-old' || g, '0017-bot-z', now() - interval '1 hour'
           FROM generate_series(1,5) g;
    INSERT INTO agent_interactions (conversation_id, run_id, bot_id, "timestamp")
         SELECT gen_random_uuid(), '0017-D-new' || g, '0017-bot-a', now()
           FROM generate_series(1,5) g;
    SELECT count(*) INTO v_rows FROM vw_recent_interactions WHERE bot_id = '0017-bot-z';
    IF v_rows <> 5 THEN
        RAISE EXCEPTION 'D failed: a filtered read of vw_recent_interactions found % of the 5 '
                        'rows that exist - a LIMIT inside a view runs before the caller''s '
                        'WHERE, which is how a debug view reports that nothing happened',
            v_rows;
    END IF;
    IF (SELECT count(*) FROM vw_failed_interactions
         WHERE run_id LIKE '0017-C%') <> 1 THEN
        RAISE EXCEPTION 'D failed: the failure listing reports % rows for the one run that '
                        'errored - the WHERE error_message IS NOT NULL is not the whole promise',
            (SELECT count(*) FROM vw_failed_interactions WHERE run_id LIKE '0017-C%');
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- E. the two shapes that used to break the report: an actions_taken that is not an array
    --    (the legacy view died for every reader, 22023), and arrays of different lengths (the
    --    outputs would have paired with the wrong tools). Both must be visible rather than
    --    fatal, and the second must announce itself.
    ------------------------------------------------------------------
    INSERT INTO agent_interactions (conversation_id, run_id, bot_id, "timestamp",
                                    actions_taken, tool_observations, duration_ms)
         VALUES (gen_random_uuid(), '0017-E-obj', '0017-bot', now(),
                 '{"tool":"e_broken"}'::jsonb, '[]'::jsonb, 10),
                (gen_random_uuid(), '0017-E-mis', '0017-bot', now(),
                 '[{"tool":"e_paired"},{"tool":"e_paired"}]'::jsonb,
                 '[{"output":"only one","type":"str"}]'::jsonb, 20);

    v_err := NULL;
    BEGIN
        SELECT count(*) INTO v_rows FROM vw_tool_performance;
    EXCEPTION WHEN OTHERS THEN
        v_err := SQLSTATE;
    END;
    IF v_err IS NOT NULL THEN
        RAISE EXCEPTION 'E failed: one malformed actions_taken still takes the report down '
                        'for every tenant (% - the legacy view died the same way)', v_err;
    END IF;
    IF (SELECT count(*) FROM vw_tool_calls WHERE run_id = '0017-E-obj') <> 0 THEN
        RAISE EXCEPTION 'E failed: a non-array actions_taken derived % rows - the guard is a '
                        'WHERE clause, not a crash waiting to happen',
            (SELECT count(*) FROM vw_tool_calls WHERE run_id = '0017-E-obj');
    END IF;
    IF (SELECT count(*) FROM vw_tool_calls c
         WHERE c.run_id = '0017-E-mis') <> 2 THEN
        RAISE EXCEPTION 'E failed: a run with 2 actions and 1 observation derived % rows, not 2',
            (SELECT count(*) FROM vw_tool_calls WHERE run_id = '0017-E-mis');
    END IF;
    -- The pair that is missing must be NULL and must say so; the pair that is present must
    -- still be there. A view that blanked BOTH would be throwing away good data to hide bad
    -- data, which is the same silence in a different place.
    IF (SELECT count(*) FROM vw_tool_calls c
         WHERE c.run_id = '0017-E-mis' AND c.step_number = 2
           AND c.observation IS NULL AND NOT c.observations_aligned) <> 1 THEN
        RAISE EXCEPTION 'E failed: the unpaired second step of a mismatched run is not visible '
                        'as a missing observation - silently wrong is the failure mode here';
    END IF;
    IF (SELECT count(*) FROM vw_tool_calls c
         WHERE c.run_id = '0017-E-mis' AND c.step_number = 1
           AND c.observation #>> '{}' = 'only one') <> 1 THEN
        RAISE EXCEPTION 'E failed: the one observation that DOES pair was discarded because its '
                        'run has a length mismatch';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- F. two tenants must not be added together, which is the reason 0003 deferred these
    --    views and 0009 made the column mandatory: an aggregate without the key is a report
    --    that is confidently wrong for every tenant in it.
    ------------------------------------------------------------------
    INSERT INTO tenants (name, slug) VALUES ('0017 second tenant', 'afpc-0017-t2')
     RETURNING tenant_id INTO v_t2;
    INSERT INTO agent_interactions (tenant_id, conversation_id, run_id, bot_id, "timestamp",
                                    actions_taken, tool_observations, duration_ms)
         VALUES (v_t2, gen_random_uuid(), '0017-F-t2', '0017-bot', now(),
                 '[{"tool":"c_lookup"}]'::jsonb, '[{"output":"x","type":"str"}]'::jsonb, 70);

    SELECT count(*) INTO v_rows FROM vw_tool_performance WHERE tool_name = 'c_lookup';
    IF v_rows <> 2 THEN
        RAISE EXCEPTION 'F failed: one tool used by two tenants prints % rows - the report is '
                        'adding tenants together', v_rows;
    END IF;
    SELECT sum(call_count) INTO v_val FROM vw_tool_performance WHERE tool_name = 'c_lookup';
    IF v_val <> 5 THEN
        RAISE EXCEPTION 'F failed: the two tenants'' rows hold % calls between them, not 5', v_val;
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- G. the decision, kept honest: no canonical object names either absent table. A view or
    --    function that referenced them would be a slow 42P01 waiting for someone to trust the
    --    schema, which is exactly how 4.5 read as a crisis.
    ------------------------------------------------------------------
    SELECT count(*) INTO v_rows
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f'
       AND NOT EXISTS (SELECT 1 FROM pg_depend d
                        WHERE d.objid = p.oid AND d.deptype = 'e')
       AND (pg_get_functiondef(p.oid) ~ '\mpostgres\..*(agent_tool_calls|tickets)\M'
            OR pg_get_functiondef(p.oid) ~ '\y(agent_tool_calls|tickets)\y');
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'G failed: % functions reference a table the schema does not define',
            v_rows;
    END IF;
    -- pg_get_viewdef is the whole definition text, so this is the same shape of check the
    -- function loop makes; no word boundary is needed for names this distinctive, and a regex
    -- metacharacter in a pattern is one more thing that can be wrong by itself (0015).
    SELECT count(*) INTO v_rows
      FROM pg_class c
     WHERE c.relkind = 'v' AND c.relnamespace = 'public'::regnamespace
       AND pg_get_viewdef(c.oid) ~ '(agent_tool_calls|tickets)';
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'G failed: % views reference agent_tool_calls or tickets, so 0017''s '
                        'decision has already been reversed by a join nobody noticed', v_rows;
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- H. the limit, demonstrated rather than mentioned: run_errored is a run-level fact, so
    --    every call in a failing run wears the failure. This is what a per-call error column
    --    would replace, and it is the honest boundary of deriving a log instead of keeping one.
    ------------------------------------------------------------------
    IF (SELECT count(*) FROM vw_tool_calls c
         WHERE c.interaction_id = v_i3 AND c.run_errored) <> 3 THEN
        RAISE EXCEPTION 'H failed: the three calls of a failing run do not all report it - the '
                        'column has stopped meaning what its name says';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = 'vw_tool_calls'::regclass
                AND a.attname IN ('error_message','call_error','step_error')) THEN
        RAISE EXCEPTION 'H failed: vw_tool_calls grew a per-call error column, which the base '
                        'table cannot support - the run is the finest grain that has one';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- I. both seats read the debug path: the application role sees its own tenant only, the
    --    audit role sees every tenant, which is the difference between a view that works and a
    --    view that works while telling the truth about whose rows they are.
    ------------------------------------------------------------------
    SET LOCAL ROLE afpc_app;
    PERFORM set_config('app.tenant_id',
        '00000000-0000-0000-0000-000000000001'::text, true);
    SELECT count(*) INTO v_rows FROM vw_recent_interactions
     WHERE run_id LIKE '0017-D%';
    IF v_rows <> 10 THEN
        RAISE EXCEPTION 'I failed: the application seat sees % of the 10 runs its tenant '
                        'owns, not 10 - a debug view that hides its own tenant''s rows is how '
                        'an agent starts doubting the database', v_rows;
    END IF;
    SELECT count(*) INTO v_rows FROM vw_recent_interactions
     WHERE run_id = '0017-F-t2';
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'I failed: the application seat can read another tenant''s interaction '
                        '(% rows visible that belong to tenant 2) - the view is '
                        'security_invoker but the wall is not being applied to it', v_rows;
    END IF;
    RESET ROLE;
    SET LOCAL ROLE afpc_readonly;
    SELECT count(*) INTO v_rows FROM vw_recent_interactions
     WHERE run_id = '0017-F-t2';
    RESET ROLE;
    IF v_rows <> 1 THEN
        RAISE EXCEPTION 'I failed: the audit seat sees % of the second tenant''s runs - 0009''s '
                        'audit_read_all policy and this view have not met', v_rows;
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- Cleanup. agent_interactions is tenant-coded and trailed, so removing fixtures leaves
    -- trail rows behind: that is 0013 working, not residue.
    ------------------------------------------------------------------
    DELETE FROM agent_interactions
     WHERE run_id LIKE '0017-%' OR bot_id IN ('0017-bot','0017-bot-z','0017-bot-a');
    DELETE FROM tenants WHERE slug = 'afpc-0017-t2';

    IF v_n <> 9 THEN
        RAISE EXCEPTION 'expected 9 behavioural verifications, completed %', v_n;
    END IF;
    RAISE NOTICE '4.5: % checks passed - the read path the documentation promised exists, it '
                 'counts calls at the call grain and runs at the run grain, a filter cannot be '
                 'starved by a truncation it did not ask for, one malformed row cannot take the '
                 'report down for everyone, two tenants are never added together, and the two '
                 'tables 4.5 asked for are absent by decision with nothing left pointing at '
                 'them', v_n;
END
$$;
