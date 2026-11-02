-- 0002: access grants for the audit and runtime roles.
--
-- This is database-level privilege work, so it belongs in the migration stream
-- rather than in init.sh: it has to replay identically on every copy of this
-- schema, and it must stay correct as later migrations add tables. An auditor
-- who silently loses sight of a new table is worse than no audit trail at all.
--
-- Requires the cluster roles from scripts/db/init.sh (make dev-init).

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'afpc_auditor') THEN
        RAISE EXCEPTION 'role afpc_auditor is missing - run: make dev-init';
    END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- afpc_auditor: view only. Three independent guarantees, because a single
-- oversight in any one of them would still leave the role read-only:
--   1. no INSERT/UPDATE/DELETE/TRUNCATE is ever granted, and privileges on
--      future objects are granted as SELECT only (default privileges below);
--   2. ALTER ROLE ... SET default_transaction_read_only = on (scripts/db/roles.sql)
--      makes even a mistakenly granted write fail inside the transaction;
--   3. NOBYPASSRLS, so what the auditor sees is what an agent sees.
-- ---------------------------------------------------------------------------

GRANT USAGE ON SCHEMA public TO afpc_auditor;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO afpc_auditor;

-- Objects created by later migrations are covered the moment they appear.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
    GRANT SELECT ON TABLES TO afpc_auditor;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
    GRANT SELECT ON SEQUENCES TO afpc_auditor;

-- pg_catalog counts are useful for auditing structural work.
GRANT EXECUTE ON FUNCTION pg_stat_statements_reset TO afpc_auditor; -- revoked below, defensive
REVOKE EXECUTE ON FUNCTION pg_stat_statements_reset FROM afpc_auditor;

-- --------------------------------------------------------------- afpc_app ----
-- Agent runtime: DML but never DDL. Every write path in Phase 3 is a function
-- call, so EXECUTE is the grant that matters.
GRANT USAGE ON SCHEMA public TO afpc_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO afpc_app;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO afpc_app;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO afpc_app;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO afpc_app;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
    GRANT EXECUTE ON FUNCTIONS TO afpc_app;

GRANT USAGE ON SCHEMA public TO afpc_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO afpc_readonly;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
    GRANT SELECT ON TABLES TO afpc_readonly;

-- ---------------------------------------------------------------------------
-- Row-level-security visibility.
--
-- Two tables arrive with RLS enabled from the baseline (review 5.7) and their
-- policies key off current_setting('app.current_agent'), which no code sets, so a
-- non-owner would read zero rows from inventory_reservations. Until migration
-- 0009 replaces these with tenant-scoped policies, give the read-only roles an
-- explicit full-read policy so an audit of the data is possible at all. This is
-- deliberately a policy and not BYPASSRLS: an auditor must see the same rows the
-- agents see, and once 0009 lands these become redundant and are dropped there.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    t text;
    n int := 0;
BEGIN
    FOR t IN
        SELECT c.relname FROM pg_class c
          JOIN pg_namespace ns ON ns.oid = c.relnamespace
         WHERE ns.nspname = 'public' AND c.relkind = 'r' AND c.relrowsecurity
    LOOP
        -- Guarded rather than DROP POLICY IF EXISTS: the latter emits "does not exist,
        -- skipping" on every fresh build, which is noise in a migration log that an
        -- auditor reads.
        IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
                     AND tablename = t AND policyname = 'audit_full_read') THEN
            EXECUTE format('DROP POLICY audit_full_read ON public.%I', t);
        END IF;
        EXECUTE format(
            'CREATE POLICY audit_full_read ON public.%I FOR SELECT TO afpc_auditor, afpc_readonly USING (true)', t);
        n := n + 1;
    END LOOP;
    RAISE NOTICE 'audit read policies added on % RLS-enabled table(s); superseded by 0009', n;
END
$$;

-- ------------------------------------------------------------ verification ----
DO $$
DECLARE
    bad text;
BEGIN
    -- Fail the migration rather than silently ship a writable auditor.
    SELECT string_agg(c.relname, ', ') INTO bad
      FROM pg_class c
      JOIN pg_namespace ns ON ns.oid = c.relnamespace
     WHERE ns.nspname = 'public' AND c.relkind IN ('r', 'v')
       AND has_table_privilege('afpc_auditor', c.oid, 'INSERT, UPDATE, DELETE, TRUNCATE');
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'afpc_auditor holds a write privilege on: %', bad;
    END IF;

    SELECT string_agg(c.relname, ', ') INTO bad
      FROM pg_class c
      JOIN pg_namespace ns ON ns.oid = c.relnamespace
     WHERE ns.nspname = 'public' AND c.relkind = 'r'
       AND NOT has_table_privilege('afpc_auditor', c.oid, 'SELECT');
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'afpc_auditor cannot see table(s): %', bad;
    END IF;

    RAISE NOTICE 'auditor: SELECT on every base table, no write privilege anywhere';
END
$$;
