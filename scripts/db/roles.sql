-- Cluster-level roles for local development. Not a migration: roles are cluster
-- objects, outside any database, so 'make dev-init' applies this file.
-- Idempotent - safe to re-run, and re-running resets passwords from dev/.env.
--
-- Uses \if / \gset rather than DO blocks on purpose: psql does not interpolate
-- :'variables' inside dollar-quoted bodies, so a password placeholder in a DO block
-- reaches the server literally and fails with a syntax error.
--
-- Why these exist (docs/database/DATABASE_REVIEW.md 5.7, 5.8):
--   * The table owner bypasses ROW LEVEL SECURITY even when it is enabled, so a
--     non-owner login role is required before any row-level control is testable.
--     DDL stays with the owner (postgres); agents never connect as postgres.
--   * The legacy function files end with a GRANT EXECUTE to a ROLE named
--     agent_first_erp_crm - not a schema. Nothing in the repo created it, which was
--     a fourth independent reason 'make db-migrate' failed. Kept as an empty shell
--     until the identity registry (tenants/users/principals) replaces it.

-- dev/.env is authoritative: the volume may predate a regenerated password.
ALTER ROLE postgres WITH PASSWORD :'postgres_password';

SELECT (count(*) = 0)::text AS need FROM pg_roles WHERE rolname = 'agent_first_erp_crm' \gset
\if :need
CREATE ROLE agent_first_erp_crm NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
\endif

SELECT (count(*) = 0)::text AS need FROM pg_roles WHERE rolname = 'afpc_app' \gset
\if :need
CREATE ROLE afpc_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS PASSWORD :'app_password';
\else
ALTER ROLE afpc_app WITH LOGIN NOSUPERUSER NOBYPASSRLS PASSWORD :'app_password';
\endif

SELECT (count(*) = 0)::text AS need FROM pg_roles WHERE rolname = 'afpc_readonly' \gset
\if :need
CREATE ROLE afpc_readonly LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS PASSWORD :'readonly_password';
\else
ALTER ROLE afpc_readonly WITH LOGIN NOSUPERUSER NOBYPASSRLS PASSWORD :'readonly_password';
\endif

-- Human audit account. Read-only is enforced twice over: no DML is ever granted
-- (db/migrations/0002_access_grants.sql) and default_transaction_read_only is set at
-- role level below, so a mistaken grant still cannot write.
SELECT (count(*) = 0)::text AS need FROM pg_roles WHERE rolname = 'afpc_auditor' \gset
\if :need
CREATE ROLE afpc_auditor LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS
    PASSWORD :'auditor_password' VALID UNTIL '2027-12-31';
\else
ALTER ROLE afpc_auditor WITH LOGIN NOSUPERUSER NOBYPASSRLS
    PASSWORD :'auditor_password' VALID UNTIL '2027-12-31';
\endif

-- Session guards applied on connect, so a client cannot forget them.
ALTER ROLE afpc_auditor SET default_transaction_read_only = on;
ALTER ROLE afpc_auditor SET statement_timeout = '60s';
ALTER ROLE afpc_auditor SET lock_timeout = '5s';
ALTER ROLE afpc_auditor SET idle_in_transaction_session_timeout = '2min';
ALTER ROLE afpc_auditor SET search_path = public;
-- Every statement the auditor runs is written to the server log: the audit trail of
-- the audit, which is the first thing an auditor asks to see.
ALTER ROLE afpc_auditor SET log_statement = 'all';

ALTER ROLE afpc_app SET search_path = public;
ALTER ROLE afpc_app SET statement_timeout = '30s';
ALTER ROLE afpc_readonly SET default_transaction_read_only = on;
ALTER ROLE afpc_readonly SET search_path = public;

SELECT string_agg(rolname || CASE WHEN rolbypassrls THEN ' (BYPASSRLS!)' ELSE '' END, ', ' ORDER BY rolname) AS roles
    FROM pg_roles WHERE rolname LIKE 'afpc%' OR rolname = 'agent_first_erp_crm';
