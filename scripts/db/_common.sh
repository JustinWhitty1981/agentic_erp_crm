#!/usr/bin/env bash
# Shared plumbing for the database tooling in scripts/db/.
#
# SQL always reaches Postgres through stdin, never a bind-mount: this repo's .sql
# files are mode 0660 owned by uid 10001, so the container's postgres user (uid 999)
# cannot read them. A mounted file fails with "Permission denied", and because
# ON_ERROR_STOP is off by default the whole run reports success while creating
# nothing. That exact false pass is recorded in docs/database/DATABASE_REVIEW.md 1.2.
#
# Host-side reads are fine: dev/.env and db/migrations/* are readable by justin.

set -euo pipefail

DBROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE_FILE="$DBROOT/dev/docker-compose.yml"
ENV_FILE="$DBROOT/dev/.env"
MIGRATIONS_DIR="$DBROOT/db/migrations"
DBNAME="${DBNAME:-agent_first_erp_crm}"
CONTAINER="${CONTAINER:-afpc-pg}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

load_env() {
    # Point at the generator, not the template: dev/.env.example has deliberately empty
    # passwords, so copying it by hand produces a database that cannot start.
    [ -f "$ENV_FILE" ] || die "missing $ENV_FILE - run: scripts/db/db up (generates random local credentials)"
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
    : "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD not set in $ENV_FILE}"
}

require_running() {
    local state
    state="$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo missing)"
    [ "$state" = "running" ] || die "container $CONTAINER is '$state' - run 'make dev-up' first"
}

# psql inside the container. This image's exec user is root, and psql defaults to a
# database role named after the OS user, so -U must always be explicit or the
# connection fails with 'role "root" does not exist'.
#   -X no psqlrc, -q quiet, ON_ERROR_STOP=1 so a bad statement aborts the file
#   instead of being skipped while psql still exits 0.
psql_run() {
    docker compose -f "$COMPOSE_FILE" exec -T postgres \
        psql -X -q -U postgres -v ON_ERROR_STOP=1 "$@"
}

run_sql_file() {
    local file="$1"
    [ -r "$file" ] || die "cannot read $file"
    cat "$file" | psql_run -d "$DBNAME" -f -
}

run_sql() {
    psql_run -d "$DBNAME" -c "$1"
}

# Multi-statement SQL must go through stdin: psql -c with several statements uses the
# simple query protocol inside one implicit transaction, and ALTER SYSTEM / CREATE
# EXTENSION / CREATE INDEX CONCURRENTLY all refuse to run in a transaction block.
run_sql_multi() {
    printf '%s\n' "$1" | psql_run -d "$DBNAME" -f -
}

# Single value, unaligned and untitled, for assertions. Only leading/trailing
# whitespace is trimmed: stripping every space would turn "18 tables / 12 views"
# into "18tables/12views" in the reports.
scalar() {
    psql_run -d "$DBNAME" -tA -c "$1" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# Probe the maintenance database: on a volume whose first boot crashed part way
# through the entrypoint, POSTGRES_DB may not exist yet, and probing it would fail
# forever.
wait_ready() {
    local tries=60
    while [ $tries -gt 0 ]; do
        if docker compose -f "$COMPOSE_FILE" exec -T postgres \
            pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1; then
            return 0
        fi
        tries=$((tries - 1))
        sleep 1
    done
    die "database did not become ready; check 'docker logs $CONTAINER'"
}

# Connect to the cluster, not to a particular database.
psql_admin() {
    docker compose -f "$COMPOSE_FILE" exec -T postgres \
        psql -X -q -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"
}

ensure_database() {
    local exists
    exists=$(psql_admin -tA -c "SELECT 1 FROM pg_database WHERE datname='$DBNAME'" | tr -d '[:space:]')
    if [ "$exists" != "1" ]; then
        psql_admin -c "CREATE DATABASE \"$DBNAME\"" \
            || die "could not create database $DBNAME"
        echo "      created database $DBNAME (the volume's first boot did not finish)"
    fi
}

# Is the change that closes a given finding in place? A finding is closed either by
# a migration being applied or, for the code-side half of 3.1 and 4.5, by the working
# tree no longer containing the defect. Both harnesses call this so they can never
# disagree about what green means.
closed() {
    case "$1" in
        code:tool_prefix)
            # Scope is the code path, which is what 3.1's risk actually is: a running tool that
            # names a schema this migration set does not create. archive/blueprint/ also holds superseded
            # .sql copies and documentation examples, and those are T4's and db/README's problem
            # rather than a live failure - the prose half is watched by
            # code:agent_docs_match_surface, section 5 of the script behind it.
            #
            # 33 at 0017, swept to 0 in this session. The sweep is what turned
            # code:cs_writes_through_doors red, and that is the story worth reading below: the
            # INSERTs had been failing on the missing schema, so the marker's own regex - which
            # allowed `public.` or nothing, because qualified forms could not run - had never seen
            # them. De-qualifying the SQL made four real write bypasses visible at once.
            local n
            n=$(grep -ro --include='*.py' 'agent_first_erp_crm\.' archive/blueprint/ 2>/dev/null | wc -l)
            [ "$n" -eq 0 ] && echo 1 || echo 0 ;;
        code:cs_writes_through_doors)
            # 0021's rule, watched: recording an interaction goes through add_communication, and
            # not through an INSERT that whichever caller wrote it last happens to have kept
            # correct. Scope is every implementation that can run, which since 2026-11-07 means three
            # deployed agents: the whole of agents/ (the customer service original, the inventory fork,
            # the sales fork, and the reference drop inside it) plus the archived blueprint tools it was
            # derived from. The list this used to carry named two of those directories, which is the
            # shape of bug a list always is - a third agent could compose its own INSERT and this
            # marker would have gone on reporting 1, quietly certifying a surface nobody had looked at.
            # A .sql copy under scripts/database/ is superseded by db/README and grepping it would only
            # re-report §3.3.
            #
            # The qualified alternative is in the pattern on purpose. It was not in the first draft,
            # and that omission is how long the rule went unbroken-looking: four blueprint tools were
            # INSERTing into `agent_first_erp_crm.communications`, which matches nothing, fails at
            # runtime, and reads as a clean marker.
            local n
            n=$(grep -rn --include='*.go' --include='*.py' -E 'INSERT[[:space:]]+(INTO)[[:space:]]+((public|agent_first_erp_crm)\.)?communications' \
                    agents/ archive/blueprint/ 2>/dev/null | wc -l)
            [ "$n" -eq 0 ] && echo 1 || echo 0 ;;
        code:agent_docs_match_surface)
            # The documentation claim, watched by the script that can check it. A .md file that
            # lists a tool the binary does not register, or an env var the compose file stopped
            # setting, is the same class of rot as a stale view list, and it is why this session's
            # changes carry their doc edits in the same commit.
            if "$DBROOT/scripts/docs/check_agent_docs.sh" --quiet >/dev/null 2>&1; then
                echo 1
            else
                echo 0
            fi ;;
        code:*)
            echo 0 ;;
        *)
            scalar "SELECT count(*) FROM public.schema_migrations WHERE version = '$1'" ;;
    esac
}
