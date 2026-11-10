-- 0035: the vectors the indexes have been waiting for, and the two doors that put them there
--       (finding 6.4's other half; PLAN.md's "Now" item 1; requirement 1's unimplemented sentence)
--
-- WHY THIS FILE EXISTS
--
-- 0012 built three hnsw indexes and, in its own header, declined to build the read path: "indexing a
-- capability nobody queries is B12's scoreboard, not a feature; wiring a semantic-search tool is
-- Phase 5 code work." It also proved the ANN path works by inserting 500 synthetic `random()::real`
-- vectors inside a rolled-back transaction, in db/tests/6_4_vectors.sql, which still runs today. That is
-- the whole of what this repository had: an index proven on numbers that mean nothing, and a column
-- proven empty on rows that mean something. Measured again today: 25 communications, 22 entities, 15
-- contacts, ZERO non-null embeddings, and
-- docs/agent_requirements/customer_service/customer_service.md requirement 1 still reading "Semantic
-- search is not implemented."
--
-- The blocker was never the schema. It was recorded in four places as "no embedder in this deployment
-- produces the 1536 dimensions the columns declare (measured: the local models answer 1024 and 4096)" -
-- in 0021's column comment, in agents/customer_service/README.md, in architecture.md, in PLAN.md. What
-- changed is that the deployment now has a server that answers an explicit dimension: an embedder behind
-- LiteLLM, asked for `dimensions: 1536`, returns exactly 1536 floats at L2 norm 1.000000 - which is what
-- `vector_cosine_ops` wants and what the columns are typed for. The truncation is Matryoshka, so it is
-- the same model's representation rather than a different, smaller one. Measured on four texts: a
-- near-paraphrase pair scores 0.811 native and 0.816 truncated; two unrelated texts 0.380/0.234 native
-- and 0.411/0.251 truncated. Nothing about the shape of the answer got worse.
--
-- So this file adds what 0012 deferred and nothing else: one door that writes a vector, one door that
-- searches by one, the fact that makes a swapped embedder a refusal rather than a silent change of
-- meaning, and the register that says how much of the corpus is searchable at all. It changes no column
-- and no index, because both were finished work a year ago.
--
-- ---------------------------------------------------------------------------
-- THE FOUR MEASUREMENTS THAT DECIDED THE DESIGN
-- ---------------------------------------------------------------------------
--
--   1. A MODEL SWAP IS INVISIBLE, AND THAT IS THE DEFECT THIS FILE'S §1 EXISTS FOR.
--      Two embedding models both produce 1536 floats. A column holding vectors from one and then from
--      another still inserts, still indexes, still answers `ORDER BY embedding <=> $1` with a plan nobody
--      would question, and returns a ranking that is plausible and wrong - because a distance between a
--      vector from model A and one from model B is a number with no interpretation. Nothing in pgvector,
--      in the catalog, or in verify.sh's existing 38 checks can see it. The rule therefore lives in a
--      door that asks the writer which model it used and refuses when the answer disagrees with what is
--      already in the table: ADR-002's own argument, applied to a fact the schema had never held before.
--
--   2. THE DIMENSION ARGUMENT IS A REQUEST, NOT A CONTRACT - MEASURED TWICE, DIFFERENTLY.
--      Asking the smaller model of the pair for 1536 today answers
--      `400: dimensions 1536 exceeds embedding length 1024`. The identical call an hour earlier answered
--      200 OK with a 1024-element vector and no complaint of any kind. Two behaviours, one question, an
--      hour apart, from a server this repository does not own. So neither the HTTP status nor the
--      response's shape can be trusted alone: the Go client asserts the length it was promised, and §3
--      re-asserts it with `vector_dims()` before it writes. The tail is already covered by the type -
--      `vector(1536)` refuses a 1024-element row with 22000 - which is why this file can be strict about
--      the head without being clever.
--
--   3. THE AUDIT TRIGGER ALREADY EXPECTED EMBEDDINGS, AND ITS OWN WORDS SET THE WRITE RULE.
--      afpc_audit_row strips vector columns from what it stores and substitutes a `<vector omitted>`
--      sentinel on both sides - "their text rendering is 60x the rest of an audit row's work, measured at
--      0.09 ms vs 0.0015 ms per row, and no auditor compares coordinate lists". A backfill therefore
--      costs a normal-sized trail row per row embedded, not 6 KB of toast, which is what makes §3 cheap
--      enough to run against a table the agents are reading. But the same function logs "a no-op rewrite
--      ... the row WAS written", so §3's UPDATE carries `AND c.embedding IS NULL`: a keeper that
--      re-writes a row it did not change files a trail row every tick forever.
--
--   4. ROW SECURITY AND ANN INTERACT, AND THE INTERESTING FAILURE IS IN THE FILTER'S POSITION.
--      The hnsw graph holds every tenant's vectors and every date; the policy and the horizon decide what
--      counts. "Find customers who complained about shipping last week" is a top-k question *inside* a
--      window, so the window must be applied by the scan and not afterwards: filter-after-limit answers
--      "the four closest rows, if any of them happen to be recent", and on a corpus where the nearest
--      matches are old that is an empty list that reads as no complaint. §4 therefore puts both the
--      tenant's row security and p_days inside the subquery the LIMIT runs in. pgvector 0.8.7's filtered
--      iterative scan (measured: extversion) is the mechanism that keeps the window from starving the
--      top-k, and db/tests/8_1_semantic_search.sql is what notices if that stops being true - including
--      the other direction, a foreign tenant's nearer row surfacing, which 0009's forced policy says is
--      not possible and this probe checks anyway.
--
-- ---------------------------------------------------------------------------
-- WHAT IS DELIBERATELY NOT HERE
-- ---------------------------------------------------------------------------
--
--   * entities.embedding and contacts.embedding stay empty. Requirement 1's sentence is a question about
--     what was SAID, and that is in communications; a customer's own vector would embed a name and an
--     address, which is what vw_customers and a WHERE clause are for. Those columns and their indexes are
--     untouched, §5 says so per-table, and B12 keeps requiring the indexes exist. The claim this file
--     makes is about one column, and the documentation must not outrun it.
--   * No trigger that embeds on write. A communications INSERT that called out to a model server would
--     make every CRM write as available as a GPU three machines away, and 0021's door is not built to
--     fail that way. The keeper is the writer. A row logged at 14:00 is searchable after the next tick,
--     and §5's newest_embedded_at is what makes that gap a number rather than a rumour.
--   * No keyword fallback. Measured again for the record: pg_trgm is installed (1.6) and there is no
--     trigram index on communications.summary, so the alternative the requirements page declined is
--     still a sequential scan behind a call the agent makes constantly.
--   * search_similar_communications takes a vector and not a sentence. The schema cannot call an
--     embedder, and a door that pretended otherwise would be lying about what it does. Words to numbers
--     is the tool's job, and it is the place where the model's hands stay off the coordinates.

\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------------
-- 1. Which model filled this column. One row, global, and the only durable statement of it.
-- ---------------------------------------------------------------------------
-- A table and not a comment, because a comment cannot be joined to, cannot be refused against, and
-- cannot be checked without a human reading it - and §3 needs all three. It holds identity facts only:
-- how many rows are embedded is derived in §5 from the rows themselves, because a count stored next to
-- the counted table is 0018 §3b's second copy of a fact, waiting to become the wrong one.
CREATE TABLE IF NOT EXISTS public.embedding_space (
    space_key   text         NOT NULL,
    model       text         NOT NULL,
    dimensions  integer      NOT NULL,
    served_by   text         NOT NULL,
    updated_at  timestamptz  NOT NULL DEFAULT now(),

    -- One space per filled column, and the key is the TABLE whose column it describes - which is the
    -- fact §3 refuses on. Named rather than an integer so B9's "no integer PKs" stays about keys, and so
    -- a second vector column becomes a row here rather than a schema change.
    CONSTRAINT embedding_space_pkey PRIMARY KEY (space_key),
    CONSTRAINT embedding_space_key_shape CHECK (space_key = 'communications'),

    -- The literal here and verify.sh's B31 are the two halves of one rule, and neither is redundant:
    -- this catches a row written wrong, and that catches a migration that widened the column and left
    -- this number behind. A CHECK cannot read pg_attribute (it must be immutable), which is the only
    -- reason the pair exists instead of one check.
    CONSTRAINT embedding_space_is_the_declared_shape CHECK (dimensions = 1536),
    CONSTRAINT embedding_space_model_is_named CHECK (btrim(model) <> '')
);

COMMENT ON TABLE embedding_space IS
    'One row per vector column that has been filled, naming the model that filled it, the width it '
    'declared, and the endpoint it came from. Global by declaration (verify.sh B19) and untrailed for '
    'the reason 0018 §2 established for currencies: audit_log.tenant_id is NOT NULL, so a row with no '
    'tenant has no trail to write. It exists because a column filled by two models answers a similarity '
    'query with distances that have no meaning, and nothing else in this schema can see that. Written '
    'only by embed_communications, which refuses any call whose model disagrees with the row. Built '
    'by 0035.';

COMMENT ON COLUMN embedding_space.model IS
    'The embedder whose weights produced every vector in communications.embedding. Enforcing this is '
    'not bookkeeping: a distance across two models is not a distance, and the refusal that reads this '
    'column is the only check that can tell a deliberate reindex from a quiet corruption.';

COMMENT ON COLUMN embedding_space.served_by IS
    'Where that model was being served from when the rows were written, supplied by the caller rather '
    'than guessed at - the schema cannot see the network. It is the field that makes "the endpoint '
    'changed" a fact rather than an archaeology project.';

-- B11's obligation arrives the moment an updated_at column does: a timestamp no trigger maintains is
-- 6.3's finding re-opened on a brand new table. Same function every other table uses, so B25 has one
-- implementation to find rather than two.
DROP TRIGGER IF EXISTS afpc_touch_updated_at ON public.embedding_space;
CREATE TRIGGER afpc_touch_updated_at
    BEFORE UPDATE ON public.embedding_space
    FOR EACH ROW EXECUTE FUNCTION afpc_touch_updated_at();

-- ---------------------------------------------------------------------------
-- 2. The read door: the ANN search 0012 deferred.
-- ---------------------------------------------------------------------------
-- A function and not a view, because it takes its question as an argument - ADR-003's boundary, the same
-- reasoning that made get_followup_customers a function rather than a vw_* (0022). A view cannot hold a
-- parameter, and a tool reading one would have to type a vector literal into its own ORDER BY.
--
-- SECURITY INVOKER, stated because it is the default and because 0011 chose INVOKER for a reason that
-- applies harder here: under DEFINER the ANN top-k would be drawn from every tenant's vectors with only
-- the final projection hidden, which is a leak of *how many* rows someone else has, and a wrong answer
-- besides.
CREATE OR REPLACE FUNCTION search_similar_communications(
    p_query_vector public.vector(1536),
    p_days         integer  DEFAULT NULL,
    p_limit        integer  DEFAULT 10
)
RETURNS TABLE(
    communication_id   bigint,
    entity_id          bigint,
    customer_name      text,
    customer_status    text,
    communication_type character varying(50),
    direction          character varying(10),
    channel            character varying(50),
    subject            text,
    summary            text,
    started_at         timestamp with time zone,
    sentiment_label    character varying(20),
    outcome            character varying(50),
    similarity         double precision
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    ------------------------------------------------------------------
    -- 0015's rule for reads, which 0022 restated for a register: a wrong argument is refused before any
    -- work, because an answer computed from a misread parameter is indistinguishable from an answer. A
    -- NULL vector is not "search everything" - it is a caller with no embedding asking anyway, and the
    -- honest response is a SQLSTATE rather than an empty ranking that reads like one.
    ------------------------------------------------------------------
    IF p_query_vector IS NULL THEN
        RAISE EXCEPTION 'search_similar_communications: p_query_vector is NULL - the query embedding '
                        'is the question, and there is no meaning in asking what is closest to nothing'
            USING ERRCODE = '22023';
    END IF;

    IF p_limit IS NULL OR p_limit < 1 THEN
        RAISE EXCEPTION 'search_similar_communications: p_limit must be a positive number of rows '
                        '(% given) - it is a count, not an offset', coalesce(p_limit::text, 'NULL')
            USING ERRCODE = '22023';
    END IF;
    IF p_limit > 100 THEN
        -- Clamped rather than refused, because 100 is not nonsense, it is over budget: it is the cap
        -- pkg/crm imposes for the same reason every other read here does (tool output truncates well
        -- below it), stated in the door so a hand-run psql call and an agent call cannot disagree about
        -- what one call returns.
        p_limit := 100;
    END IF;
    IF p_days IS NOT NULL AND p_days < 0 THEN
        RAISE EXCEPTION 'search_similar_communications: p_days % is negative - it is an age in days, '
                        'not an offset', p_days
            USING ERRCODE = '22023',
                  HINT = 'omit the argument to search the whole recorded history';
    END IF;

    RETURN QUERY
    -- The subquery is the whole design, and it is not decoration. Two predicates had to move inside the
    -- scan's LIMIT: row security (automatic, because the function runs as the invoker) and the horizon.
    -- Applied after the limit, "who complained about shipping last week" answers with the closest rows
    -- and then asks whether any of them were recent - which on a corpus where the nearest matches are
    -- old is an empty list that reads as "nobody complained". The join to entities is outside because it
    -- cannot change which rows are closest, and doing it first would put a btree probe in front of the
    -- index that is the point of the call.
    SELECT top.id,
           top.entity_id,
           e.name,
           e.status,
           top.communication_type,
           top.direction,
           top.channel,
           top.subject,
           top.summary,
           top.started_at,
           top.sentiment_label,
           top.outcome,
           -- 1 - cosine distance, computed in SQL and not in Go. The reason is the 2026-11-07 fix's
           -- reason, stated once more: a number computed in two places is two places that can disagree,
           -- and the plane that reads this value without converting it is the trajectory row.
           top.similarity
      FROM (
            SELECT c.id, c.entity_id, c.communication_type, c.direction, c.channel,
                   c.subject, c.summary, c.started_at, c.sentiment_label, c.outcome,
                   (1.0 - (c.embedding <=> p_query_vector))::double precision AS similarity
              FROM communications c
             WHERE c.embedding IS NOT NULL
               AND (p_days IS NULL
                    -- started_at and not created_at: 0022's measurement, arriving on the read path.
                    -- created_at is when a row was written, started_at is when the interaction happened,
                    -- and "last week" is a claim about the conversation. A backfill sharpens the
                    -- difference, because an import writes today a row whose subject is forty days old.
                    OR c.started_at >= now() - make_interval(days => p_days))
             ORDER BY c.embedding <=> p_query_vector
             LIMIT p_limit
           ) top
      JOIN entities e ON e.id = top.entity_id
     -- The outer ORDER BY is what makes the answer stable: the inner LIMIT chose these rows by
     -- distance, and a join is free to hand them back in any order it likes.
     ORDER BY top.similarity DESC;
END
$$;

COMMENT ON FUNCTION search_similar_communications(public.vector(1536), integer, integer) IS
    'The closest recorded communications to a query vector: the rows, the customer named on each, and a '
    'similarity of 1 - cosine distance. p_days narrows INSIDE the ANN scan rather than after it, which '
    'is what makes "in the last week" mean a search of the last week instead of a filter applied to the '
    'nearest rows whatever their age; row security applies there too, so the top-k is drawn from what the '
    'caller may see. p_limit defaults to 10 and is clamped at 100. Rows with no embedding cannot be '
    'returned, which is the difference between this door answering "nothing is similar" and answering '
    '"nothing is searchable" - the second is vw_embedding_status''s subject and the tool reads it before '
    'saying the first. A vector is a parameter and never a result: 0012 removed the projection from '
    'vw_customers after measuring a projecting scan at ~300x the buffers, and 6_4 (c) fails any view '
    'that puts one back. Built by 0035.';

-- ---------------------------------------------------------------------------
-- 3. The write door. The only thing in this database that fills a vector.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION embed_communications(
    p_items           jsonb,
    p_model           text,
    p_served_by       text   DEFAULT NULL,
    p_idempotency_key uuid   DEFAULT NULL
)
RETURNS TABLE(success boolean, rows_embedded integer, rows_refused integer, message text)
LANGUAGE plpgsql
AS $$
DECLARE
    v_claim  record;
    v_state  text := '';
    v_cid    uuid;          -- the claim's own key, in a scalar. See the EXCEPTION block: an unassigned
    v_token  uuid;          -- record's FIELD cannot be tested for NULL without raising 55000, and AND
    v_space  record;        -- does not promise to short-circuit.
    v_done   integer := 0;
    v_bad    integer := 0;
    v_off    integer;
    v_msg    text;
BEGIN
    ------------------------------------------------------------------
    -- Arguments, all of them, before anything is read or written (0015's rule).
    ------------------------------------------------------------------
    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
        RAISE EXCEPTION 'embed_communications: p_items must be a JSON array of {"communication_id": '
                        'n, "embedding": "[f,f,...]"} - got %',
                        coalesce(jsonb_typeof(p_items), 'NULL')
            USING ERRCODE = '22023';
    END IF;
    IF p_model IS NULL OR btrim(p_model) = '' THEN
        -- Not defaulted, and not guessed from current_setting: the whole of §1's rule rests on every
        -- write naming its own author, and a door that fills in a model name when none is supplied
        -- cannot tell the keeper from a stranger.
        RAISE EXCEPTION 'embed_communications: p_model is required - this function refuses a write '
                        'whose embedder it cannot name'
            USING ERRCODE = '22023';
    END IF;

    v_off := jsonb_array_length(p_items);

    -- Shape, then width. An element with no id or no vector is a caller that built its request from
    -- something other than the keeper's own SELECT, and an id named twice in one call is not "last one
    -- wins" - it is two batches colliding, and the row cannot say which vector it should have ended
    -- with. Both are refused whole: a partial embed is the mixed-corpus state §1 exists to prevent,
    -- arrived at by accident instead of by a model swap.
    SELECT count(*) INTO v_bad
      FROM jsonb_array_elements(p_items) x
     WHERE (x -> 'communication_id') IS NULL
        OR jsonb_typeof(x -> 'communication_id') <> 'number'
        OR (x -> 'embedding') IS NULL;
    IF v_bad > 0 THEN
        RAISE EXCEPTION 'embed_communications: % element(s) of p_items are not '
                        '{"communication_id": n, "embedding": vector} - the door fills gaps, it does '
                        'not guess which rows were meant', v_bad
            USING ERRCODE = '22023';
    END IF;

    SELECT count(*) INTO v_bad
      FROM (SELECT (x ->> 'communication_id')::bigint AS cid
              FROM jsonb_array_elements(p_items) x GROUP BY 1 HAVING count(*) > 1) d;
    IF v_bad > 0 THEN
        RAISE EXCEPTION 'embed_communications: % communication id(s) appear more than once in one '
                        'call', v_bad USING ERRCODE = '22023';
    END IF;

    -- The width, asserted here and in the client, against measurement 2 above. Both forms are cast to
    -- the UNBOUNDED vector type: a JSON array of numbers and a pgvector rendering reach the same text.
    -- So this is a length question with the door's own message, and not a typmod failure three
    -- statements downstream, which is how a wrong-model bug would otherwise be reported as a
    -- wrong-syntax one.
    SELECT count(*) INTO v_bad
      FROM (SELECT vector_dims(CASE WHEN jsonb_typeof(x -> 'embedding') = 'string'
                                   THEN (x ->> 'embedding')::public.vector
                                   ELSE ((x -> 'embedding')::text)::public.vector END) AS dims
              FROM jsonb_array_elements(p_items) x) q
     WHERE q.dims <> 1536;
    IF v_bad > 0 THEN
        RAISE EXCEPTION 'embed_communications: % of the % vectors offered are not 1536 dimensions. '
                        'The embedder was asked for that width and did not answer it - check '
                        'EMBEDDING_MODEL against embedding_space, which says % filled this column',
            v_bad, v_off, p_model USING ERRCODE = '22023';
    END IF;

    ------------------------------------------------------------------
    -- The rule this file exists for, enforced before the claim is taken so a refused call cannot leave
    -- a settled claim for a write that never happened.
    ------------------------------------------------------------------
    -- No FOR UPDATE here, and that is a grant question rather than a style one: embedding_space is
    -- readable and insertable by the runtime role and NOT updatable (below, §6), so a locking read
    -- would fail every keeper tick with 42501 for the sake of a race that cannot produce a wrong
    -- answer. Two first-writes in flight settle one INSERT and bounce the other off the primary key,
    -- and ON CONFLICT DO NOTHING makes even that invisible. 0031's lesson, applied forward: a policy
    -- whose keeper lacks the privilege is unkept, and the same is true of a lock nobody needs.
    IF NOT EXISTS (SELECT 1 FROM embedding_space WHERE space_key = 'communications') THEN
        -- The first write in this database's life. It stamps the space with what it used, which is the
        -- only way the fact can ever have been true without someone being asked to remember it.
        INSERT INTO embedding_space (space_key, model, dimensions, served_by)
             VALUES ('communications', p_model, 1536, coalesce(p_served_by, 'not stated'))
        ON CONFLICT (space_key) DO NOTHING;
        RAISE NOTICE 'embedding_space stamped: communications.embedding is now %''s space', p_model;
    END IF;

    SELECT * INTO v_space FROM embedding_space WHERE space_key = 'communications';
    IF v_space.space_key IS NULL THEN
        RAISE EXCEPTION 'embed_communications: embedding_space holds no row for communications '
                        'immediately after the door read it, so the table that enforces the '
                        'one-model rule cannot be read';
    ELSIF v_space.model <> p_model THEN
        RAISE EXCEPTION 'embed_communications: communications.embedding was filled by %, and this '
                        'call names %. A distance between a vector from one model and a vector from '
                        'the other has no interpretation, so the write is refused rather than mixed.',
            v_space.model, p_model
            USING ERRCODE = '23514',
                  HINT = 'to change embedder deliberately: UPDATE embedding_space SET model = ..., '
                         'served_by = ... AND dimensions = 1536, then re-embed every row - the keeper '
                         'only fills NULLs, so a re-stamp on its own leaves BOTH models in the column '
                         'and the ranking wrong for every query that crosses them';
    END IF;

    ------------------------------------------------------------------
    -- The claim: ADR-005 pattern 2, and the reason it matters here more than elsewhere is that this
    -- function is called over a backlog by a timer, where a retry after a half-finished batch is the
    -- ordinary case rather than the accident.
    ------------------------------------------------------------------
    IF p_idempotency_key IS NOT NULL THEN
        SELECT * INTO v_claim FROM idempotency_claim(
            p_idempotency_key, 'embed_communications',
            jsonb_build_object('items', v_off, 'model', p_model));
        v_state := v_claim.claim_state;
        v_cid   := v_claim.claim_id;
        v_token := v_claim.current_token;
        IF v_state = 'replay' THEN
            success       := (v_claim.cached_response ->> 'success')::boolean;
            rows_embedded := (v_claim.cached_response ->> 'rows_embedded')::integer;
            rows_refused  := (v_claim.cached_response ->> 'rows_refused')::integer;
            message       := v_claim.cached_response ->> 'message';
            RETURN NEXT; RETURN;
        ELSIF v_state = 'in_progress' THEN
            RAISE EXCEPTION 'embed_communications: an attempt with key % is already in flight',
                p_idempotency_key USING ERRCODE = '40001';
        ELSIF v_state = 'conflict' THEN
            RAISE EXCEPTION 'embed_communications: key % was settled for a DIFFERENT request',
                p_idempotency_key USING ERRCODE = 'P0001';
        END IF;
    END IF;

    IF v_off = 0 THEN
        success := true; rows_embedded := 0; rows_refused := 0;
        message := 'nothing was offered';
        RETURN NEXT;
        IF p_idempotency_key IS NOT NULL THEN
            PERFORM idempotency_complete(v_cid, v_token,
                jsonb_build_object('success', success, 'rows_embedded', rows_embedded,
                                   'rows_refused', rows_refused, 'message', message));
        END IF;
        RETURN;
    END IF;

    ------------------------------------------------------------------
    -- The write, in one statement.
    --
    --   AND c.embedding IS NULL - the keeper's rule, and 3 above's reason. This door fills gaps. It
    --       never re-derives a vector that is already there, because re-embedding a corpus is §1's
    --       deliberate two-statement operation and must not be a side effect of a tick that had
    --       nothing to do.
    --   count(*) from a data-modifying CTE, and not GET DIAGNOSTICS: SELECT INTO sets ROW_COUNT to
    --       1-or-0 depending on whether the looped-into variable saw a row, so the obvious form of
    --       this line reports "1 embedded" about a batch of eight. That is the same class of defect as
    --       the numeric struct one the 2026-11-07 pass fixed - a count that is confidently wrong,
    --       printed next to a JSON payload that looks right.
    --
    -- No `IS DISTINCT FROM` here, and that is a decision rather than an omission: `IS NULL` already
    -- excludes every row whose value equals or differs from the offered one, so the second predicate
    -- would be a restatement of the first. It is the reason a repeated tick files zero audit rows.
    ------------------------------------------------------------------
    WITH offered AS (
        SELECT (x ->> 'communication_id')::bigint AS cid,
               CASE WHEN jsonb_typeof(x -> 'embedding') = 'string'
                    THEN (x ->> 'embedding')::public.vector
                    ELSE ((x -> 'embedding')::text)::public.vector END AS vec
          FROM jsonb_array_elements(p_items) x
    ), wrote AS (
        UPDATE communications c
           SET embedding = o.vec
          FROM offered o
         WHERE c.id = o.cid
           AND c.embedding IS NULL
        RETURNING c.id
    )
    SELECT count(*) INTO v_done FROM wrote;

    v_bad := v_off - v_done;
    v_msg := format('%s of %s offered row(s) embedded at 1536 dimensions by %s',
                    v_done, v_off, p_model);
    IF v_bad > 0 THEN
        -- Three causes, and they are not separable from here without a second pass that would race the
        -- rows the agents are writing anyway: already embedded by an earlier tick, invisible to this
        -- connection's row security, or deleted between the keeper's SELECT and this statement. All
        -- three mean the same thing to the keeper, which is "not my gap next hour", and none of them
        -- means "0 left", which is why §5's view and not this count is the coverage answer.
        v_msg := v_msg || format(', %s not written (already embedded, not visible to this '
                                'connection, or gone)', v_bad);
    END IF;
    IF v_done = 0 THEN
        v_msg := v_msg || '. Nothing new this call; vw_embedding_status is the coverage answer';
    END IF;

    success := true; rows_embedded := v_done; rows_refused := v_bad; message := v_msg;
    RETURN NEXT;

    IF p_idempotency_key IS NOT NULL THEN
        PERFORM idempotency_complete(v_cid, v_token,
            jsonb_build_object('success', success, 'rows_embedded', rows_embedded,
                               'rows_refused', rows_refused, 'message', message));
    END IF;

EXCEPTION WHEN OTHERS THEN
    -- The claim has to be settled as failed or it sits in flight for the lease and every retry of this
    -- batch answers 40001, which is 0031's lesson about a mechanism whose other half lives in a
    -- different file. Same block every other door in this schema carries.
    IF p_idempotency_key IS NOT NULL AND v_cid IS NOT NULL THEN
        BEGIN
            PERFORM idempotency_complete(v_cid, v_token, NULL, false, SQLERRM);
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
    END IF;
    RAISE EXCEPTION USING ERRCODE = SQLSTATE, MESSAGE = SQLERRM;
END
$$;

COMMENT ON FUNCTION embed_communications(jsonb, text, text, uuid) IS
    'Fills communications.embedding for the rows named in p_items and nothing else: it never re-derives '
    'a vector that is already there (the keeper''s rule, and the reason a repeated tick files no audit '
    'rows), refuses the call when any offered vector is not 1536 wide, and refuses it outright when '
    'p_model disagrees with the model recorded in embedding_space - because a column holding two '
    'models'' vectors answers a similarity query with numbers that have no meaning, and no other check '
    'in this database can see that happening. Stamps embedding_space on the first write it ever '
    'performs. Takes an idempotency claim (ADR-005 pattern 2) and settles it as failed on any error, '
    'because a timer retries this call in the ordinary course of working. SECURITY INVOKER, so another '
    'tenant''s id is not found here exactly as it is not found everywhere else (0018''s single message '
    'for both cases). Built by 0035.';

-- ---------------------------------------------------------------------------
-- 4. What the column's own comment says. 0021 wrote "no embedder in this deployment produces the 1536
--    dimensions the column declares", and from this file that sentence is false in the one place a
--    reader meets the column first - which is the class of defect check_agent_docs.sh exists for, on the
--    database side of the documentation.
-- ---------------------------------------------------------------------------
COMMENT ON COLUMN public.communications.embedding IS
    'The embedding of what was said in this interaction, at the width 0001 declared and 0012 indexed. '
    'Written by embed_communications and by nothing else; the keeper that calls it is in '
    'agents/customer_service. A row that is NULL here is invisible to every similarity query, and '
    'vw_embedding_status publishes how many rows that is. Which model produced the values is a fact '
    'about the whole column and lives in embedding_space, not per row - mixing two of them is what '
    'that table exists to make impossible. Read through search_similar_communications and never '
    'through a view: 0012 measured a projecting scan at ~300x the buffers of a non-projecting one, and '
    '6_4 (c) fails any view that puts a vector back in a listing. Built by 0001, first written by '
    '0035.';

-- ---------------------------------------------------------------------------
-- 5. The register: how much of this is actually searchable.
-- ---------------------------------------------------------------------------
-- The catalog supplies the COLUMN list and the code supplies the COUNTS, because a generic view over
-- three tables cannot name three aggregates without knowing which table it is reading. What the catalog
-- half buys is the property every other register in this schema has: a fourth vector column appears
-- here as an EMPTY row the day someone adds it, rather than as no row at all and a green harness.
CREATE OR REPLACE VIEW vw_embedding_status AS
WITH census AS (
    -- One aggregate per table, and the same shape for all three: the newest vector's arrival is the
    -- row's own update time, valid because §3's door is the column's only writer and never rewrites one.
    SELECT 'communications'::text AS table_name,
           count(*)                                          AS n_rows,
           count(*) FILTER (WHERE embedding IS NOT NULL)     AS n_with,
           max(CASE WHEN embedding IS NOT NULL THEN updated_at END) AS newest_embedded_at
      FROM communications
    UNION ALL
    SELECT 'entities', count(*), count(*) FILTER (WHERE embedding IS NOT NULL),
           max(CASE WHEN embedding IS NOT NULL THEN updated_at END)
      FROM entities
    UNION ALL
    SELECT 'contacts', count(*), count(*) FILTER (WHERE embedding IS NOT NULL),
           max(CASE WHEN embedding IS NOT NULL THEN updated_at END)
      FROM contacts
), spaces AS (
    SELECT c.relname::text AS table_name,
           a.attname::text AS column_name,
           CASE a.atttypmod WHEN -1 THEN NULL ELSE a.atttypmod END AS declared_dims,
           -- The 0-based subscript is the whole predicate, and the form above it was wrong: casting
           -- int2vector to int[] yields an array whose LOWER BOUND is 0, so `indkey::int[] =
           -- ARRAY[attnum]` compares {0:0}={27} against {1:27} and is false for every index in the
           -- database, quietly, forever. B12 and 5_5_6 both use indkey[0] for this reason; the
           -- register's first draft reported every vector column as UNINDEXED because it did not, and
           -- nothing downstream noticed because the branch it feeds sits behind PARTIAL.
           EXISTS (SELECT 1
                     FROM pg_index i
                     JOIN pg_class ic ON ic.oid = i.indexrelid
                    WHERE i.indrelid = c.oid
                      AND i.indnatts = 1
                      AND i.indkey[0]::int = a.attnum::int
                      AND ic.relam = (SELECT oid FROM pg_am WHERE amname = 'hnsw')) AS hnsw_led
      FROM pg_attribute a
      JOIN pg_class c     ON c.oid = a.attrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relkind = 'r' AND a.attnum > 0
       AND NOT a.attisdropped AND a.atttypid = 'vector'::regtype
)
SELECT s.table_name,
       s.column_name,
       s.declared_dims,
       s.hnsw_led,
       coalesce(k.n_rows, 0)::bigint AS rows_total,
       coalesce(k.n_with, 0)::bigint AS rows_embedded,
       (coalesce(k.n_rows, 0) > 0 AND coalesce(k.n_with, 0) = 0) AS searchable_at_all,
       k.newest_embedded_at,
       es.model     AS embedded_by,
       es.dimensions AS stamped_dimensions,
       es.served_by  AS served_by,
       CASE
         WHEN coalesce(k.n_with, 0) = 0 THEN
             'EMPTY - no row carries a vector, so a similarity query over this column answers '
             || '"nothing is similar" while the truth is "nothing is searchable". '
             || CASE WHEN s.table_name = 'communications'
                     THEN 'The keeper fills it; its ticks are rows in agent_interactions.'
                     ELSE 'Nothing writes this column: 0035 leaves it empty by decision, and '
                          'B12 still requires its index.' END
         WHEN k.n_rows > k.n_with THEN
             format('PARTIAL - %s of %s rows are searchable; the rest are invisible to a similarity '
                    || 'query and there is no keyword fallback for them (no trigram index on '
                    || 'summary exists, which is why one was never the alternative)',
                    k.n_with, k.n_rows)
         WHEN es.model IS NULL THEN
             'UNSTAMPED - the column holds vectors and embedding_space names no model, so something '
             'other than embed_communications wrote them'
         WHEN es.dimensions IS DISTINCT FROM s.declared_dims THEN
             format('MISMATCH - the stamp says %s dimensions and the column declares %s',
                    es.dimensions, s.declared_dims)
         WHEN NOT s.hnsw_led THEN
             'UNINDEXED - vectors are stored and no hnsw index leads the column, so every similarity '
             'query is a sequential scan (6.4 verbatim, arriving again)'
         ELSE 'COMPLETE'
       END AS verdict
  FROM spaces s
  LEFT JOIN census k ON k.table_name = s.table_name
  LEFT JOIN embedding_space es
         ON es.space_key = CASE WHEN s.table_name = 'communications' AND s.column_name = 'embedding'
                                THEN 'communications' END
 ORDER BY s.table_name, s.column_name;

ALTER VIEW vw_embedding_status SET (security_invoker = true);

COMMENT ON VIEW vw_embedding_status IS
    'One row per vector column in the database, taken from the catalog: what it declares, whether an '
    'hnsw index leads it, how many of its rows carry a vector at all, the newest of those, which model '
    'the stamp credits and from where, and a verdict of EMPTY / PARTIAL / UNSTAMPED / MISMATCH / '
    'UNINDEXED / COMPLETE. It exists because "nothing matched" and "nothing is searchable" are '
    'indistinguishable in a similarity query''s result set, and a tool that cannot tell them apart '
    'teaches a human to distrust a correct empty answer. The counts are read from the rows and never '
    'from embedding_space, which holds identity only - a count stored next to the counted table is '
    '0018 §3b''s second copy of a fact. Built by 0035.';

-- ---------------------------------------------------------------------------
-- 5b. The keeper's queue, and the definition of what gets embedded.
-- ---------------------------------------------------------------------------
-- Two things live here that could have lived in Go, and neither should.
--
-- The first is the queue itself. Every other read path in this schema goes through a view or a
-- function (ADR-003), and the two keepers already deployed read vw_* rather than a table -
-- agents/sales' tick scans vw_order_commitments for exactly the reason it states: "a rule restated in
-- Go is a rule that can drift from the rule the database enforces". A keeper that selects FROM
-- communications WHERE embedding IS NULL in a Go string is that sentence, unenforced.
--
-- The second is the composition of the text, which is the more important half. What an embedding
-- MEANS for a communication is a decision about the data - subject, summary, and body, whitespace
-- collapsed, capped at a length the embedder is billed for - and a decision about the data that lives
-- in a client library is a decision nobody can query, probe, or contradict. It is also the decision
-- that, if it drifts, makes the corpus silently inhomogeneous: some rows embedded from
-- summary alone, some from the whole text, all of them 1536 numbers long and comparable to each other
-- only in the sense that all distances between them are meaningless. So the rule is in SQL, one time,
-- and db/tests/8_1_semantic_search.sql fails the day a row's document stops being what this says.
--
-- No ORDER BY, per 0017's rule that a view cannot hold one for an outer plan. The keeper's own SELECT
-- supplies it, and gets to choose whether it is draining a backlog by id or keeping up by recency.
CREATE OR REPLACE VIEW vw_unembedded_communications AS
WITH composed AS (
    -- One statement of what an embedding of a communication is made FROM. It appears once, in this
    -- CTE, and the three columns derived below are all readings of it - four copies of the same
    -- expression is how a view starts disagreeing with itself about what it means.
    --
    -- \s+ collapses rather than merely trims, and that is a quality decision, not tidiness: a
    -- full_content pasted out of an email carries the indentation and paragraph breaks of the client
    -- it came from, and those characters are tokens the embedder attends to. Two rows recording the
    -- same conversation with different paste spacing would otherwise land at different vectors.
    SELECT c.id, c.entity_id, e.name, c.communication_type, c.direction, c.started_at, c.created_at,
           btrim(regexp_replace(concat_ws(' ',
               coalesce(c.subject, ''),
               coalesce(c.summary, ''),
               coalesce(c.full_content, '')),
               '\s+', ' ', 'g')) AS document
      FROM communications c
      JOIN entities e ON e.id = c.entity_id
     WHERE c.embedding IS NULL
)
SELECT id            AS communication_id,
       entity_id,
       name          AS customer_name,
       communication_type,
       direction,
       started_at,
       created_at,
       -- The cap is a cost bound, stated here rather than in a client so a probe can read it back:
       -- an embedder is billed and timed per token, and a full_content holding a pasted contract is
       -- not worth thirty times the queue behind it.
       left(document, 4000)          AS embeddable_text,
       char_length(document) > 4000  AS truncated,
       -- A row with nothing to say has no embedding, and the keeper must report that rather than work
       -- around it: an empty string still produces a valid unit-norm vector, and every such vector
       -- sits close to every other empty document's, so the corpus fills with rows that match each
       -- other and nothing else. A ranking poisoned by arithmetic that is correct.
       document = ''                 AS nothing_to_embed
  FROM composed;

ALTER VIEW vw_unembedded_communications SET (security_invoker = true);

COMMENT ON VIEW vw_unembedded_communications IS
    'One row per communication no embedder has described yet, with the text that decision is made '
    'from: subject, summary and body, whitespace-collapsed, capped at 4000 characters, in SQL and '
    'not in a client, so the meaning of a vector is a fact about the schema that a probe can hold '
    'the keeper to. `truncated` and `nothing_to_embed` are the two cases a keeper has to report '
    'rather than work around - the second because an empty document still produces a valid, '
    'unit-norm vector that sits close to every other empty document''s vector, which is how a '
    'corpus fills with rows that match each other and nothing else. Row security applies through '
    'the base tables. Built by 0035.';

-- ---------------------------------------------------------------------------
-- 6. Grants, in the order the registers expect.
-- ---------------------------------------------------------------------------
-- 0002's default privileges already reached every object below the moment it appeared; what a default
-- cannot do is close a door to PUBLIC, which is B22's scoreboard and 0009 §D's note about the one thing
-- ALTER DEFAULT PRIVILEGES could not make retroactive.
REVOKE EXECUTE ON FUNCTION search_similar_communications(public.vector(1536), integer, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION embed_communications(jsonb, text, text, uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION search_similar_communications(public.vector(1536), integer, integer) TO afpc_app;
GRANT  EXECUTE ON FUNCTION embed_communications(jsonb, text, text, uuid) TO afpc_app;
-- The keeper stamps its own space on the first write and never rewrites it, so it needs INSERT and not
-- DELETE: a runtime role that could empty this table could also silently un-enforce §1.
GRANT  SELECT, INSERT ON embedding_space TO afpc_app;
GRANT  SELECT ON embedding_space, vw_embedding_status TO afpc_readonly, afpc_auditor;
GRANT  SELECT ON vw_unembedded_communications TO afpc_readonly, afpc_auditor;

-- ---------------------------------------------------------------------------
-- 7. Prove it, or it did not happen.
-- ---------------------------------------------------------------------------
-- Every block below writes, so every block is followed by the cleanup it owes. 0030's §8 and 0031's §3
-- both established the pattern of measuring inside the migration that made the measurement possible,
-- and the residue check in test-functions.sh is the net under the ones this block forgets.
DO $$
DECLARE
    v_r      record;
    v_n      bigint;
    v_chk    bigint;
    v_vec    text;
    v_new    text;
    v_old    text;
    v_prior  text;
    v_ent    bigint;
    v_now_id bigint;
    v_old_id bigint;
    v_gap_id   bigint;
    v_blank_id bigint;
    v_long_id  bigint;
    v_before bigint;
BEGIN
    -- Set aside anything already stamped (there is nothing on a first apply, and a re-apply would be a
    -- different database), so the probe can test the refusal without destroying the real fact.
    SELECT model INTO v_prior FROM embedding_space WHERE space_key = 'communications';

    ---------------------------------------------------------------------
    -- A. the two halves of the width rule agree with each other and with the column.
    ---------------------------------------------------------------------
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'embedding_space_is_the_declared_shape') THEN
        RAISE EXCEPTION 'A failed: the width rule is a paragraph instead of a constraint';
    END IF;
    IF (SELECT CASE atttypmod WHEN -1 THEN NULL ELSE atttypmod END
          FROM pg_attribute WHERE attrelid = 'communications'::regclass
            AND attname = 'embedding') <> 1536 THEN
        RAISE EXCEPTION 'A failed: the column no longer declares 1536, and this file''s CHECK, §3''s '
                        'assertion and the embedder''s request are four statements of a number that '
                        'has to move together';
    END IF;
    RAISE NOTICE 'VERDICT OK 0035 | the declared width is a constraint and it matches the column';

    ---------------------------------------------------------------------
    -- B. a short vector is refused BY THE DOOR, whatever the embedder answered. Measurement 2 above is
    --    the reason: the same server gave two different shapes to the same request an hour apart.
    ---------------------------------------------------------------------
    INSERT INTO embedding_space (space_key, model, dimensions, served_by)
         VALUES ('communications', '0035-probe-one', 1536, 'the migration''s own probe')
    ON CONFLICT (space_key) DO UPDATE SET model = EXCLUDED.model;

    v_vec := '[' || (SELECT string_agg('0.001', ',') FROM generate_series(1, 1024)) || ']';
    BEGIN
        PERFORM * FROM embed_communications(
            jsonb_build_array(jsonb_build_object('communication_id', 1, 'embedding', v_vec)),
            '0035-probe-one');
        RAISE EXCEPTION 'B failed: a 1024-dimension vector reached a vector(1536) column without '
                        'being refused by name. The embedder answered exactly that shape today with '
                        'status 200 and no complaint';
    EXCEPTION
        WHEN others THEN
            -- 22023, and not raise_exception: PL/pgSQL maps RAISE ... USING ERRCODE to its condition
            -- name, and a handler written for P0001 silently misses every refusal the door actually
            -- makes. That is the same "the guard can only evaluate UNKNOWN" shape 0022 found in
            -- get_followup_customers, one level up: an assertion that cannot fire reads as one that
            -- passed.
            IF SQLSTATE::text <> '22023' OR SQLERRM NOT LIKE '%not 1536 dimensions%' THEN
                RAISE EXCEPTION 'B failed: the short vector produced % (%) instead of the door''s own '
                                'refusal by width', SQLERRM, SQLSTATE;
            END IF;
    END;
    RAISE NOTICE 'VERDICT OK 0035 | a short vector is refused by name, not by a cast error';

    ---------------------------------------------------------------------
    -- C. the second model is refused in SQL. This is the whole of §1's reason to exist, and it is the
    --    one assertion in this file that no other object in the schema could back.
    ---------------------------------------------------------------------
    BEGIN
        PERFORM * FROM embed_communications('[]'::jsonb, '0035-probe-two');
        RAISE EXCEPTION 'C failed: naming a second embedder was accepted. A distance across two '
                        'models is not a distance, and this file was written because nothing else '
                        'in this database could notice';
    EXCEPTION
        WHEN check_violation THEN
            IF SQLERRM NOT LIKE '%was filled by%' THEN
                RAISE EXCEPTION 'C failed for the wrong reason: %', SQLERRM;
            END IF;
        WHEN others THEN
            RAISE EXCEPTION 'C failed: a second embedder produced % (%)', SQLERRM, SQLSTATE;
    END;
    RAISE NOTICE 'VERDICT OK 0035 | the second model is refused by the door, in SQL, not in a comment';

    ---------------------------------------------------------------------
    -- D. a real vector of the right width writes exactly one row, and does not write it twice.
    --
    --    The fixture is this block's own, and §7's cleanup removes it. That is not tidiness: an empty
    --    database is a legal place to apply a migration (it is what `scripts/db/db fresh` builds), and
    --    the first rehearsal of this file read "the first communication", got NULL for its id, and then
    --    spent its whole assertion budget testing the door's shape validation instead of its write.
    ---------------------------------------------------------------------
    DELETE FROM embedding_space WHERE space_key = 'communications';   -- let D's write stamp afresh

    INSERT INTO entities (name, entity_type, status)
         VALUES ('0035 probe customer', 'customer', 'active')
      RETURNING id INTO v_ent;
    INSERT INTO communications (entity_id, communication_type, direction, subject, summary, started_at)
         VALUES (v_ent, 'call', 'inbound', 'late delivery',
                 '0035 probe: the customer said the shipment arrived two weeks late and damaged',
                 now())
      RETURNING id INTO v_now_id;
    INSERT INTO communications (entity_id, communication_type, direction, subject, summary, started_at)
         VALUES (v_ent, 'email', 'inbound', 'the same complaint, older',
                 '0035 probe: an older complaint about the same late shipment',
                 now() - interval '400 days')
      RETURNING id INTO v_old_id;

    SELECT count(*) INTO v_before FROM communications WHERE embedding IS NOT NULL;

    v_new := '[' || (SELECT string_agg('0.002', ',') FROM generate_series(1, 1536)) || ']';
    v_old := '[' || (SELECT string_agg('0.001', ',') FROM generate_series(1, 1536)) || ']';
    PERFORM * FROM embed_communications(jsonb_build_array(
        jsonb_build_object('communication_id', v_now_id, 'embedding', v_new),
        jsonb_build_object('communication_id', v_old_id, 'embedding', v_old)), '0035-probe-one');

    SELECT count(*) INTO v_n FROM communications WHERE embedding IS NOT NULL;
    IF v_n <> v_before + 2 THEN
        RAISE EXCEPTION 'D failed: % rows carry a vector where % were expected. A door offered two ids '
                        'wrote %', v_n, v_before + 2, v_n - v_before;
    END IF;
    IF (SELECT model FROM embedding_space) IS DISTINCT FROM '0035-probe-one' THEN
        RAISE EXCEPTION 'D failed: the write did not stamp the space it wrote into, so the next '
                        'caller has nothing to be refused against';
    END IF;

    -- Re-offer the same two rows: zero written, and no second audit row for either. This is the
    -- keeper's own steady state, and the reason §3's UPDATE carries `AND c.embedding IS NULL` - afpc_
    -- audit_row logs a no-op rewrite, so a tick with nothing to do would otherwise file two trail rows
    -- an hour, forever, about a table nobody changed.
    SELECT rows_embedded INTO v_n FROM embed_communications(jsonb_build_array(
        jsonb_build_object('communication_id', v_now_id, 'embedding', v_new),
        jsonb_build_object('communication_id', v_old_id, 'embedding', v_old)), '0035-probe-one');
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'D failed: re-offering an embedded row wrote % rows again, so every idle tick '
                        'files audit history for a table that did not change', v_n;
    END IF;
    RAISE NOTICE 'VERDICT OK 0035 | the door fills gaps, stamps its space, and writes a row once';

    ---------------------------------------------------------------------
    -- E. the register distinguishes the three states, and lists one row per vector column the catalog
    --    has rather than per column this file thought of.
    ---------------------------------------------------------------------
    SELECT * INTO v_r FROM vw_embedding_status WHERE table_name = 'communications';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'E failed: vw_embedding_status carries no row for communications. The census '
                        'is derived from the catalog, and a column that is not in it is a column '
                        'nobody can find';
    END IF;
    IF v_r.rows_embedded <> v_before + 2 THEN
        RAISE EXCEPTION 'E failed: the register says % embedded after this block wrote %',
            v_r.rows_embedded, v_before + 2;
    END IF;
    IF v_r.searchable_at_all <> (v_r.rows_total > 0 AND v_r.rows_embedded = 0) THEN
        RAISE EXCEPTION 'E failed: the register''s own two columns disagree, so the EMPTY verdict is '
                        'computed from a different predicate than the flag a caller would test';
    END IF;
    IF (SELECT verdict FROM vw_embedding_status WHERE table_name = 'entities') NOT LIKE 'EMPTY%' THEN
        RAISE EXCEPTION 'E failed: entities, which this file leaves alone BY DECISION, is reported as '
                        '%. The scope of the claim is the claim',
            (SELECT verdict FROM vw_embedding_status WHERE table_name = 'entities');
    END IF;
    IF (SELECT count(*) FROM vw_embedding_status) <>
       (SELECT count(*) FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public' AND c.relkind = 'r' AND a.attnum > 0
           AND NOT a.attisdropped AND a.atttypid = 'vector'::regtype) THEN
        RAISE EXCEPTION 'E failed: the register and the catalog have started to disagree about how '
                        'many vector columns exist';
    END IF;
    -- The register's own claim about the index, against a second expression of the same fact. The
    -- first version of this view asked `indkey::int[] = ARRAY[attnum]`, which is false for every index
    -- in the database because the cast carries lower bound 0, and it would have sat unnoticed behind
    -- the PARTIAL branch of the verdict until the corpus filled. Two predicates that agree are the
    -- cheapest way to find the one that cannot be true.
    IF v_r.hnsw_led <> EXISTS (SELECT 1 FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid
                                WHERE i.indrelid = 'communications'::regclass
                                  AND ic.relam = (SELECT oid FROM pg_am WHERE amname = 'hnsw')) THEN
        RAISE EXCEPTION 'E failed: the register says hnsw_led=% and the catalog says otherwise, so the '
                        'UNINDEXED branch of the verdict is a sentence about a predicate nobody read',
            v_r.hnsw_led;
    END IF;
    IF NOT v_r.hnsw_led THEN
        RAISE EXCEPTION 'E failed: 0012 built the hnsw indexes and this database still has them, so a '
                        'register that does not see them is wrong about every column it lists';
    END IF;
    RAISE NOTICE 'VERDICT OK 0035 | the register counts from the rows, and its verdicts are its own math';

    ---------------------------------------------------------------------
    -- F. the read door refuses a NULL question, ranks by the cosine the index says it is, and applies
    --    its window INSIDE the top-k. That third clause is measurement 4: filter-after-limit answers
    --    "the nearest rows, if any are recent", and here the nearest row is deliberately 400 days old,
    --    so a wrongly-placed predicate returns exactly one row and it is the wrong one.
    ---------------------------------------------------------------------
    BEGIN
        PERFORM * FROM search_similar_communications(NULL);
        RAISE EXCEPTION 'F failed: a NULL query vector was accepted, which is 0022''s trap wearing a '
                        'different hat - there is no meaning in a ranking against nothing';
    EXCEPTION
        WHEN others THEN
            IF SQLSTATE::text <> '22023' OR SQLERRM NOT LIKE '%p_query_vector is NULL%' THEN
                RAISE EXCEPTION 'F failed: a NULL vector produced % (%) and not the refusal',
                    SQLERRM, SQLSTATE;
            END IF;
    END;

    -- Searched for the OLD complaint's own vector, with no horizon: the old row is the nearest thing to
    -- the question there is, and must come first.
    SELECT count(*) INTO v_n FROM search_similar_communications(v_old::public.vector(1536), NULL, 5);
    IF v_n < 2 THEN
        RAISE EXCEPTION 'F failed: % rows from an unhorizoned search over a corpus with vectors in it',
            v_n;
    END IF;
    SELECT count(*) INTO v_chk FROM search_similar_communications(v_old::public.vector(1536), NULL, 5)
     WHERE communication_id = v_old_id AND similarity NOT BETWEEN 0.999 AND 1.001;
    IF v_chk <> 0 THEN
        RAISE EXCEPTION 'F failed: a row''s similarity to its own vector is not ~1, so the distance is '
                        'not the cosine vector_cosine_ops promises and the index''s opinion is fiction';
    END IF;

    -- The same question with a 30-day horizon: the old row must be gone and the recent one must still
    -- be reachable, which is the one case where the filter's position changes the answer.
    SELECT count(*) INTO v_n FROM search_similar_communications(
        v_old::public.vector(1536), 30, 5) WHERE communication_id = v_old_id;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'F failed: p_days=30 returned a 400-day-old row, so the horizon is applied '
                        'after the LIMIT and "last week" means whatever the nearest neighbours were';
    END IF;
    SELECT count(*) INTO v_n FROM search_similar_communications(
        v_old::public.vector(1536), 30, 5) WHERE communication_id = v_now_id;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'F failed: the horizon starved the top-k of the recent row that is in it, so '
                        'the filtered scan is not finding past the excluded neighbours';
    END IF;
    IF (SELECT customer_name FROM search_similar_communications(v_old::public.vector(1536), NULL, 1))
       IS DISTINCT FROM '0035 probe customer' THEN
        RAISE EXCEPTION 'F failed: the search answers without the customer named on the row, which is '
                        'the half of requirement 1 that makes a ranking actionable';
    END IF;
    RAISE NOTICE 'VERDICT OK 0035 | the window is inside the scan, and the customer is on the row';

    ---------------------------------------------------------------------
    -- G. the queue, and the composition rule the queue carries.
    --
    --    What an embedding is made FROM lives in the view and not in a client, so the only way to
    --    prove the rule is the one that matters: hand it a row whose three text columns disagree with
    --    each other and read back which words the vector will be built from. A client-side composer
    --    would pass this test by construction, which is the whole problem with testing it there.
    ---------------------------------------------------------------------
    -- What the queue is FOR, stated as membership rather than as a count: a count assumes the
    -- deployment has rows in it, which the from-zero rehearsal of this very file proved is not a
    -- safe assumption (the first draft asserted "at least two", and failed on an empty database,
    -- which is the cleanest case there is and the one a migration must survive).
    SELECT count(*) INTO v_n FROM vw_unembedded_communications
     WHERE communication_id IN (v_now_id, v_old_id);
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'G failed: the queue still holds % of the two rows §D embedded, so the keeper '
                        'would re-offer them every tick and afpc_audit_row would log a rewrite of a '
                        'row that did not change', v_n;
    END IF;

    INSERT INTO communications (entity_id, communication_type, direction, subject, summary,
                                full_content, started_at)
         VALUES (v_ent, 'note', 'internal', '  Shipping ',
                 'the pallet arrived late,   again', E'  and   wet  ', now())
      RETURNING id INTO v_gap_id;
    -- Blank in every text column, and so a row the keeper must decline rather than describe.
    INSERT INTO communications (entity_id, communication_type, direction, subject, summary,
                                full_content, started_at)
         VALUES (v_ent, 'note', 'internal', '   ', '', NULL, now())
      RETURNING id INTO v_blank_id;
    -- Long enough to be capped, which is the difference between a cost bound and a wish.
    INSERT INTO communications (entity_id, communication_type, direction, subject, summary,
                                full_content, started_at)
         VALUES (v_ent, 'email', 'inbound', 'long',
                 'x' || repeat('y', 4200), NULL, now())
      RETURNING id INTO v_long_id;

    -- The other half of membership: a row that does not reach the queue is a row no keeper will ever
    -- embed, and nothing downstream would say so.
    SELECT count(*) INTO v_n FROM vw_unembedded_communications
     WHERE communication_id IN (v_gap_id, v_blank_id, v_long_id);
    IF v_n <> 3 THEN
        RAISE EXCEPTION 'G failed: % of the three rows made for this block are queued', v_n;
    END IF;

    SELECT embeddable_text, truncated, nothing_to_embed INTO v_r
      FROM vw_unembedded_communications WHERE communication_id = v_gap_id;
    IF position('  ' in v_r.embeddable_text) > 0
       OR v_r.embeddable_text NOT LIKE 'Shipping the pallet arrived late, again and wet' THEN
        RAISE EXCEPTION 'G failed: the view composes % from subject, summary and body. The spacing '
                        'rule is the rule, and it is in the view because a client that restated it '
                        'differently would produce vectors that are not of the same thing',
            quote_literal(v_r.embeddable_text);
    END IF;
    IF v_r.truncated OR v_r.nothing_to_embed THEN
        RAISE EXCEPTION 'G failed: a short, complete row reports truncated=% nothing_to_embed=%',
            v_r.truncated, v_r.nothing_to_embed;
    END IF;

    SELECT nothing_to_embed, embeddable_text INTO v_r
      FROM vw_unembedded_communications WHERE communication_id = v_blank_id;
    IF NOT v_r.nothing_to_embed OR v_r.embeddable_text <> '' THEN
        RAISE EXCEPTION 'G failed: a row with nothing in any text column is queueable as %, so the '
                        'keeper would embed it and the corpus would gain a vector that matches every '
                        'other empty row', quote_literal(v_r.embeddable_text);
    END IF;

    SELECT truncated, char_length(embeddable_text) INTO v_r
      FROM vw_unembedded_communications WHERE communication_id = v_long_id;
    IF NOT v_r.truncated THEN
        RAISE EXCEPTION 'G failed: a 4200-character document was not reported as capped';
    END IF;
    IF (SELECT char_length(embeddable_text) FROM vw_unembedded_communications
         WHERE communication_id = v_long_id) <> 4000 THEN
        RAISE EXCEPTION 'G failed: the cap is stated as 4000 and the view hands out % characters, so '
                        'the number in the comment and the number in the code are two numbers',
            (SELECT char_length(embeddable_text) FROM vw_unembedded_communications
              WHERE communication_id = v_long_id);
    END IF;
    RAISE NOTICE 'VERDICT OK 0035 | the queue is a view, and what it embeds is stated once, in SQL';

    ---------------------------------------------------------------------
    -- Cleanup. This block embedded two rows, stamped one fact and made one customer; none of it is
    -- true about this database, and leaving the stamp behind would make the keeper's first real call a
    -- refusal. Measurement 1 in the other direction: the residue IS the mixed corpus.
    ---------------------------------------------------------------------
    DELETE FROM communications WHERE id IN (v_now_id, v_old_id, v_gap_id, v_blank_id, v_long_id);
    DELETE FROM entities       WHERE id = v_ent;
    UPDATE communications SET embedding = NULL WHERE embedding IS NOT NULL;
    DELETE FROM embedding_space WHERE model LIKE '0035-probe%';
    IF v_prior IS NOT NULL THEN
        INSERT INTO embedding_space (space_key, model, dimensions, served_by)
             VALUES ('communications', v_prior, 1536, 'restored by 0035 §7')
        ON CONFLICT (space_key) DO UPDATE SET model = EXCLUDED.model;
    END IF;
END
$$;

-- No ledger INSERT here: schema_migrations' row, checksum and filename are migrate.sh's to write,
-- and 0032 ends the same way. A migration that records itself cannot be refused by a harness.
