-- 0000: extensions and shared primitives.
--
-- The canonical dump (0001) declares three columns as `public.vector(1536)`, so the
-- vector type must exist in schema public before any table is created. Everything
-- else here is groundwork the remediation migrations depend on.

CREATE EXTENSION IF NOT EXISTS vector     SCHEMA public;  -- type lives in public by design
CREATE EXTENSION IF NOT EXISTS pg_trgm    SCHEMA public;  -- trigram search on entities.name (5.5)
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" SCHEMA public; -- uuid_generate_v1mc()
CREATE EXTENSION IF NOT EXISTS pgcrypto   SCHEMA public;  -- gen_random_uuid()

-- Per-role, per-query statistics. This is what makes "audit the work being done"
-- answerable after the fact: which role ran what, how often, and how slowly. The
-- library is preloaded by scripts/db/init.sh (postmaster-context, so ALTER SYSTEM
-- alone is not enough).
CREATE EXTENSION IF NOT EXISTS pg_stat_statements SCHEMA public;

DO $$
BEGIN
    RAISE NOTICE 'pgvector % | pg %',
        (SELECT extversion FROM pg_extension WHERE extname = 'vector'),
        (SELECT setting FROM pg_settings WHERE name = 'server_version');
    -- Corrects a common assumption: uuidv7() arrived in PostgreSQL 18, not 17. On
    -- this server the time-ordered option is uuid_generate_v1mc(), or a hand-rolled
    -- uuidv7() over clock_timestamp(). Key-strategy migration 0003 depends on which
    -- of those is chosen, so state it rather than leave it implicit.
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'uuidv7') THEN
        RAISE NOTICE 'no native uuidv7() on PG17 - 0003 will use uuid_generate_v1mc()';
    END IF;
END
$$;
