-- 0036: move communications.embedding into qwen3-embedding:4b's space, and empty it so that can be true
--       (the embedder change 0035's register was written to make a decision instead of an accident)
--
-- WHY THIS IS A MIGRATION AND NOT AN ENVIRONMENT EDIT
--
-- `agents/customer_service/.env` names the embedder, and changing that one line changes what the keeper
-- writes and what `search_communications` turns a query into. 0035 anticipated exactly that, and put
-- the answer in `public.embedding_space`: the door refuses any write naming a model other than the one
-- that filled the column, because two embedders both answer 1536 floats, a column holding both still
-- inserts and indexes and searches, and the ranking it returns is a plausible ordering of nonsense that
-- no check in pgvector, `pg_catalog`, or verify.sh's 38 B-checks can see.
--
-- So pointing `EMBEDDING_MODEL` at a new model without restamping makes every keeper tick fail with a
-- 23514 the door means to raise. Restamping WITHOUT clearing makes it worse: the keeper only fills NULLs,
-- so the old vectors stay exactly where they are, and the column ends up holding both models with a
-- register crediting neither of them honestly. 0035's own HINT on that exception says the second half is
-- required - "then re-embed every row" - and nothing in the repository had a way to perform it. This is.
--
-- WHY 4b
--
-- `qwen3-embedding:latest` - the name stamped into the register on 2026-11-10, the only embedder this
-- database has ever written with - is 7.6B parameters and 4.68 GB on the Ollama host. `qwen3-embedding:4b`
-- is 4.0B and 2.50 GB, which is why it answers faster on both ends of the job: measured on this server,
-- four texts at an explicit 1536 came back in 0.10s against `:latest`'s 0.13s warm, and the first call
-- after either model had been idle cost 4.3s against 6.8s. The corpus is small, the queue is normally
-- empty, and 0035's width rule survives intact: asked for 1536, 4b answers exactly 1536 floats at L2 norm
-- 1.000000, which is what `vector_cosine_ops` wants and what `pkg/embed.Client.Dimensions` demands. It
-- answers 2560 when not asked, so the width has to be requested rather than assumed - the same rule
-- 0035 §1 records for the 0.6b, which cannot answer 1536 at all and said `400 dimensions exceeds
-- embedding length 1024`.
--
-- What is given up is 3.6B parameters of ranking quality, on a corpus of 26 rows where `:latest` was not
-- visibly wrong about anything. That trade is the operator's to make and it was made deliberately; what
-- was NOT the operator's to make is the mixed-column state that a config edit alone would have produced,
-- which is the thing this file exists to prevent.
--
-- The predicate, because the file has to survive being applied twice. The vectors to clear are the ones
-- that PREdate the restamp, and a vector cannot be recognised from itself - that is 0035's whole thesis -
-- so the register's own timestamp does the recognising: §2 clears what is older than or equal to
-- `embedding_space.updated_at` as §1 leaves it. `<=` rather than `<` because a row written in the same
-- transaction as the restamp shares its `now()`, and such a row is by definition one this file produced.
-- Re-running is safe for a reason that lives in §1 and not here: the UPDATE carries
-- `AND model IS DISTINCT FROM v_target`, so a register that already names 4b is not touched, its
-- `updated_at` does not jump past every vector the keeper has since written, and §2 matches nothing. A
-- restamp that moved the timestamp would be a committed migration silently re-emptying a healthy corpus.
-- §2 takes its count before the UPDATE, because an UPDATE that clears nothing is indistinguishable from
-- one that never ran, and `FOUND` would describe §1 rather than §2.
--
-- Applies as postgres, which is the only role that can UPDATE embedding_space: 0035 §6 grants afpc_app
-- SELECT and INSERT and deliberately not UPDATE, so the runtime role cannot restamp its own guard. The
-- audit trigger records every vector this clears; 0013 replaces the value with a `<vector omitted>`
-- sentinel, so the trail is 26 small rows and not 26 copies of 6 KB of floats.

\set ON_ERROR_STOP on

-- The target, in one place. §1 restamps to this and §3 reports on it, so the file cannot half-move.
DO $restamp$
DECLARE
    v_target   constant text := 'qwen3-embedding:4b';
    v_served   constant text := 'http://192.168.0.53:4000/v1';
    r          record;
    v_cleared  bigint;
BEGIN
    ---------------------------------------------------------------------------
    -- §1 the register, moved to the new name by the only role that can.
    ---------------------------------------------------------------------------
    UPDATE public.embedding_space
       SET model = v_target, served_by = v_served, dimensions = 1536
     WHERE space_key = 'communications'
       -- The whole file is re-runnable only because of this line. Without it the UPDATE touches
       -- embedding_space on a second run, afpc_touch_updated_at moves its updated_at past every
       -- vector the keeper has since written, and §2 clears the corpus this migration exists to
       -- rebuild. The register already naming the target is the state "already restamped by a
       -- previous run", and it must be inert.
       AND model IS DISTINCT FROM v_target;

    IF NOT FOUND THEN
        RAISE NOTICE '0036 §1: embedding_space already names %. Nothing to restamp, so nothing below '
                     'will clear a vector that a keeper filled with it', v_target;
    END IF;

    ---------------------------------------------------------------------------
    -- §2 the vectors that were written under some other model. They cannot be recognised from the
    --    vector - that is 0035's whole thesis - so the register's timestamp does the recognising.
    ---------------------------------------------------------------------------
    SELECT count(*) INTO v_cleared
      FROM public.communications
     WHERE embedding IS NOT NULL
       AND updated_at <= (SELECT updated_at FROM public.embedding_space
                           WHERE space_key = 'communications');

    UPDATE public.communications
       SET embedding = NULL
     WHERE embedding IS NOT NULL
       AND updated_at <= (SELECT updated_at FROM public.embedding_space
                           WHERE space_key = 'communications');

    RAISE NOTICE '0036 §2: cleared % vector(s) written before the restamp. The keeper fills NULLs only, '
                 'so this is the re-embed 0035''s HINT asks for, and vw_unembedded_communications is now '
                 'its queue again', v_cleared;

    ---------------------------------------------------------------------------
    -- §3 the register, read back, so the file reports what it committed rather than what it meant.
    ---------------------------------------------------------------------------
    SELECT * INTO r FROM public.embedding_space WHERE space_key = 'communications';
    RAISE NOTICE '0036 §3: communications.embedding is now the space of % (dimensions %, served by %)',
                 r.model, r.dimensions, r.served_by;

    ---------------------------------------------------------------------------
    -- §4 the post-conditions. Each one is the state this file exists to produce, and a run that
    --    commits without them would be the mixed column wearing different clothes.
    ---------------------------------------------------------------------------
    IF r.model <> v_target THEN
        RAISE EXCEPTION '0036 §4: embedding_space still names % after the restamp', r.model;
    END IF;

    IF (SELECT count(*) FROM public.communications
         WHERE embedding IS NOT NULL
           AND updated_at < r.updated_at) > 0 THEN
        RAISE EXCEPTION '0036 §4: % vector(s) predate the restamp and are still in the column, so it now '
                        'holds two models'' vectors and every query that crosses them is wrong',
            (SELECT count(*) FROM public.communications
              WHERE embedding IS NOT NULL AND updated_at < r.updated_at);
    END IF;

    IF EXISTS (SELECT 1 FROM public.communications WHERE embedding IS NOT NULL
                 AND vector_dims(embedding) <> 1536) THEN
        RAISE EXCEPTION '0036 §4: a vector in communications is not 1536 wide, which is the column''s '
                        'CHECK and B31 speaking with one voice - this cannot be reached';
    END IF;

    RAISE NOTICE '0036 §4: VERDICT OK the register names %, and no vector in the column predates it',
                 v_target;
END
$restamp$;
