#!/usr/bin/env bash
# Provision this host as the development database server: roles, TLS, network
# exposure, server settings, query statistics. Idempotent - run it any time.
#
#   scripts/db/init.sh            full provision; recreates the container if the
#                                 published address must change
#   scripts/db/init.sh --no-net   keep the 127.0.0.1 binding
#
# Nothing here destroys data: the data volume is only touched by role grants,
# postgresql.auto.conf and pg_hba.conf rewrites.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

WANT_NET=1
[ "${1:-}" = "--no-net" ] && WANT_NET=0

load_env
require_running
wait_ready
ensure_database

PGDATA_PATH=/var/lib/postgresql/data
PG_UID=$(docker compose -f "$COMPOSE_FILE" exec -T postgres id -u postgres | tr -d '\r\n')

# Addresses this machine is known by, for the certificate SANs.
LAN_IP=$(ip -4 -o route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -1)
TS_IP=$(ip -4 -o addr show dev tailscale0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
# The LAN subnet is the one on the default-route interface. 'ip route show scope
# link' is wrong here: Docker bridges are also link-scope and would be picked first.
LAN_IFACE=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
LAN_CIDR=$(ip -4 -o addr show dev "${LAN_IFACE:-eno1}" 2>/dev/null | awk '{print $4}' | grep -m1 '/')
# pg_hba compares client_ip & netmask to the literal address, so a rule written as
# 10.0.1.23/24 can never match - the host bits must be zero. Normalise to network.
LAN_SUBNET=$(python3 -c "import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]).network)" \
             "$LAN_CIDR" 2>/dev/null || echo "$LAN_CIDR")
DOCKER_SUBNET=$(docker network inspect afpc_net --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null | tr -d '\r')
[ -n "$DOCKER_SUBNET" ] || DOCKER_SUBNET=172.17.0.0/16

# ---------------------------------------------------------------- 1. roles ----
cat "$(dirname "${BASH_SOURCE[0]}")/roles.sql" | docker compose -f "$COMPOSE_FILE" exec -T postgres \
    psql -X -q -U postgres -v ON_ERROR_STOP=1 \
         -v app_password="$AFPC_APP_PASSWORD" \
         -v readonly_password="$AFPC_READONLY_PASSWORD" \
         -v auditor_password="$AFPC_AUDITOR_PASSWORD" \
         -v postgres_password="$POSTGRES_PASSWORD" \
         -d "$DBNAME" -f -
echo "[1/5] roles applied (dev/.env is the source of truth for passwords)"

# Keep the maintenance database out of reach so tools land in the right one.
run_sql_multi "
REVOKE CONNECT ON DATABASE postgres FROM PUBLIC;
GRANT CONNECT ON DATABASE \"$DBNAME\" TO afpc_app, afpc_readonly, afpc_auditor;
CREATE TABLE IF NOT EXISTS public.schema_migrations (
    version     text        PRIMARY KEY,
    filename    text        NOT NULL,
    checksum    text        NOT NULL,
    applied_at  timestamptz NOT NULL DEFAULT now()
);
"
echo "      (no tool should connect to the 'postgres' database; the dev env uses $DBNAME)"

# -------------------------------------------------- 2. server configuration ----
run_sql_multi "
ALTER SYSTEM SET password_encryption = 'scram-sha-256';
ALTER SYSTEM SET shared_preload_libraries = 'pg_stat_statements';
ALTER SYSTEM SET pg_stat_statements.track = 'all';
ALTER SYSTEM SET pg_stat_statements.max = 10000;
ALTER SYSTEM SET listen_addresses = '*';
ALTER SYSTEM SET max_connections = 100;
ALTER SYSTEM SET shared_buffers = '512MB';
ALTER SYSTEM SET wal_compression = 'on';
ALTER SYSTEM SET log_min_duration_statement = 250;
ALTER SYSTEM SET log_statement = 'mod';
ALTER SYSTEM SET log_line_prefix = '%m [%p] user=%u db=%d app=%a host=%h ';
ALTER SYSTEM SET log_checkpoints = 'on';
ALTER SYSTEM SET log_lock_waits = 'on';
ALTER SYSTEM SET track_activities = 'on';
-- Cluster-level tenant fallback, mirrored by the database-level setting that
-- db/migrations/0003_tenant_foundation.sql applies. Needed because ALTER DATABASE SET
-- is recorded in pg_db_role_setting, which CREATE DATABASE ... TEMPLATE does NOT copy:
-- without this, a clone or a restored copy of this database has no tenant context and
-- every INSERT fails in afpc_current_tenant(). The database-level value still wins where
-- it exists, so an override made deliberately is never silently replaced by this one.
ALTER SYSTEM SET app.default_tenant_id = '${AFPC_TENANT_ID:-00000000-0000-0000-0000-000000000001}';
"
echo "[2/5] settings written to postgresql.auto.conf on the data volume"

# ------------------------------------------------------------------ 3. TLS ----
docker compose -f "$COMPOSE_FILE" exec -T \
    -e SAN_IPS="IP:127.0.0.1${LAN_IP:+,IP:$LAN_IP}${TS_IP:+,IP:$TS_IP}" \
    postgres bash -s <<'REMOTE'
set -eu
umask 077
mkdir -p /certs
# CA and leaf are generated under separate guards. The original condition tested for a
# missing leaf and then regenerated the CA inside it, so every rebuild that lost
# server.crt minted a NEW AUTHORITY - which silently invalidates the ca.crt an auditor
# pinned for sslmode=verify-full. The authority must outlive the leaf it signs.
if [ ! -s /certs/ca.crt ] || [ ! -s /certs/ca.key ]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout /certs/ca.key -out /certs/ca.crt \
        -subj "/CN=Agent First ERP CRM development CA" >/dev/null 2>&1
    echo "      generated a new private CA"
fi
if [ ! -s /certs/server.crt ] || [ ! -s /certs/server.key ]; then
    openssl req -newkey rsa:2048 -nodes \
        -keyout /certs/server.key -out /certs/server.csr \
        -subj "/CN=afpc-pg" >/dev/null 2>&1
    printf 'subjectAltName = %s\nextendedKeyUsage = serverAuth\n' "$SAN_IPS" > /certs/leaf.cnf
    openssl x509 -req -in /certs/server.csr -CA /certs/ca.crt -CAkey /certs/ca.key \
        -CAcreateserial -days 825 -extfile /certs/leaf.cnf \
        -out /certs/server.crt >/dev/null 2>&1
    rm -f /certs/server.csr /certs/leaf.cnf
    echo "      issued a new leaf certificate from the existing CA"
fi
# Fail loudly here. A half-populated /certs with ssl=on is the unbootable state that the
# revert logic at the end of this script exists to recover from.
test -s /certs/server.crt && test -s /certs/server.key && test -s /certs/ca.crt
chmod 644 /certs/ca.crt /certs/server.crt
chmod 600 /certs/server.key
REMOTE
docker compose -f "$COMPOSE_FILE" exec -T -u root postgres \
    chown "$PG_UID":"$PG_UID" /certs/ca.key /certs/ca.crt /certs/server.crt /certs/server.key 2>/dev/null || true

# Hand auditors the CA (public half only) so sslmode=verify-full is possible.
umask 022; mkdir -p "$DBROOT/dev/tls"
docker compose -f "$COMPOSE_FILE" exec -T postgres cat /certs/ca.crt > "$DBROOT/dev/tls/afpc-ca.crt"

# Tell every agent stack which address to use, next door to its own compose file.
#
# The compose files require AFPC_PG_HOST and deliberately have no default, because the only value
# that can work is an address the leaf certificate names in its subjectAltNames - a fact about
# whichever machine provisioned it, not of the repository. A committed fallback would be wrong for
# every other clone and would point a stranger's connections at somebody's private LAN. This is the
# one place that knows both halves: the SAN list is being built a few lines above, from the same
# variables. Compose reads the PROJECT DIRECTORY's .env for ${...} interpolation - and only that,
# not the files it lists under env_file: - so one of these per project is what makes the required
# variable resolvable after a provisioning run.
#
# One generated file per agent directory that has a docker-compose.yml, because a second COPY of a
# fact is what 0018 §3b and this session's reservation rotation both warn about: the copy is right
# the day it is made, and init.sh can keep every copy current at once only if it OWNS them all.
# That replaced an early design where agents/inventory read customer_service's file through a
# cross-directory env_file - which feeds container environment, never interpolation, so a
# re-provision would update one agent's host and silently not the other's.
#
# An existing setting is left alone. Whoever typed it meant it, and silently rewriting it during a
# re-provision - which init.sh otherwise is careful to permit - is how a working host edit disappears.
if [ -n "$LAN_IP" ]; then
    for AGENT_ENV in "$DBROOT"/agents/*/docker-compose.yml; do
        [ -f "$AGENT_ENV" ] || continue
        AGENT_ENV="$(dirname "$AGENT_ENV")/.env"
        AGENT_REL="${AGENT_ENV#"$DBROOT"/}"
        if [ -f "$AGENT_ENV" ] && grep -q '^AFPC_PG_HOST=' "$AGENT_ENV"; then
            echo "[3/5] $AGENT_REL already sets AFPC_PG_HOST - left as is"
        elif [ ! -w "$(dirname "$AGENT_ENV")" ]; then
            # A directory this user cannot write is not this project's agent to provision - here, the
            # reference drop under agents/. The redirect below used to fail and set -e ended the whole
            # run at step 3, so `db up` had been exiting 1 since the drop landed without ever reaching
            # migrate or seed. Skipping with a line is the honest version of that: the drop is a copy
            # of somebody else's deployment, and no compose file in this repository starts it.
            echo "[3/5] $AGENT_REL is not writable by this user - skipped (not a deployed agent)"
        else
            mkdir -p "$(dirname "$AGENT_ENV")"
            { printf '# Written by scripts/db/init.sh; gitignored, because it names a private address on a\n'
              printf '# specific network rather than anything about this project.\n'
              printf '#\n'
              printf '# The docker-compose.yml beside this file requires AFPC_PG_HOST and has no default:\n'
              printf '# sslmode=verify-full only validates against an address the leaf certificate lists, and\n'
              printf '# that list is %s. The tailnet address works from anywhere the node is reachable.%s\n' \
                  "${LAN_IP}${TS_IP:+, $TS_IP}" ""
              printf 'AFPC_PG_HOST=%s\n' "$LAN_IP"; } > "$AGENT_ENV"
            echo "[3/5] wrote $AGENT_REL (AFPC_PG_HOST=$LAN_IP)"
        fi
    done
fi

run_sql_multi "
ALTER SYSTEM SET ssl = on;
ALTER SYSTEM SET ssl_cert_file = '/certs/server.crt';
ALTER SYSTEM SET ssl_key_file = '/certs/server.key';
ALTER SYSTEM SET ssl_ca_file = '/certs/ca.crt';
ALTER SYSTEM SET ssl_min_protocol_version = 'TLSv1.2';
ALTER SYSTEM SET ssl_prefer_server_ciphers = on;
"
echo "[3/5] TLS on; CA exported to dev/tls/afpc-ca.crt (SAN: ${LAN_IP:-?} ${TS_IP:+$TS_IP})"

# ------------------------------------------------------------ 4. pg_hba.conf ----
# Rules are generated from what the host is actually plugged into. Addresses that
# match nothing are refused, so there is no implicit catch-all to weaken later.
cat > /tmp/afpc-pg_hba.$$ <<EOF
# Generated by scripts/db/init.sh - manual edits are overwritten on the next run.
#
# Local socket trust lets the runner and 'make db-shell' connect as the owner. The
# socket lives inside the container's filesystem namespace and the data volume is
# not bind-mounted, so no host process can reach it.
local   all             all                                     trust
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256

# Agent containers on the project network.
hostssl all             all             $DOCKER_SUBNET        scram-sha-256

# Development network and tailnet, TLS required.
hostssl all             afpc_auditor    ${LAN_SUBNET:-192.168.0.0/24}  scram-sha-256
hostssl all             afpc_auditor    100.64.0.0/10         scram-sha-256
hostssl all             afpc_auditor    fd00::/8              scram-sha-256
hostssl all             all             ${LAN_SUBNET:-192.168.0.0/24}  scram-sha-256
hostssl all             all             100.64.0.0/10         scram-sha-256

# Never accept plaintext credentials on a network.
host    all             all             0.0.0.0/0             reject
host    all             all             ::/0                  reject
EOF
docker compose -f "$COMPOSE_FILE" exec -T -u root postgres \
    bash -c "cat > $PGDATA_PATH/pg_hba.conf && chown $PG_UID:$PG_UID $PGDATA_PATH/pg_hba.conf && chmod 600 $PGDATA_PATH/pg_hba.conf" \
    < /tmp/afpc-pg_hba.$$
rm -f /tmp/afpc-pg_hba.$$
echo "[4/5] pg_hba: containers $DOCKER_SUBNET | LAN ${LAN_SUBNET:-192.168.0.0/24} | tailnet 100.64.0.0/10 | TLS mandatory"

# ------------------------------------------------------ 5. expose and restart --
# ssl and shared_preload_libraries are postmaster-context, so a reload is not enough:
# without this restart every hostssl rule reports "cannot match because SSL is
# disabled". If the server does not come back, TLS is reverted rather than leaving a
# persistent development database unbootable.
if [ "$WANT_NET" = 1 ]; then
    sed -i 's/^PGBIND=.*/PGBIND=0.0.0.0/' "$ENV_FILE"
fi

# `up -d` does not re-publish a port when only the interpolated bind address
# changed - it decided the config was unchanged and left the old loopback binding
# live. Compare what is actually published with what is wanted, and recreate if they
# differ. Recreating does not touch the data volume.
DESIRED_BIND="${PGBIND:-127.0.0.1}"
PUBLISHED=$(docker inspect -f '{{range $p, $b := .NetworkSettings.Ports}}{{range $b}}{{.HostIP}} {{end}}{{end}}' "$CONTAINER" 2>/dev/null | tr -d '\r' | awk '{print $1}')
if [ "${PUBLISHED:-none}" != "$DESIRED_BIND" ]; then
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d --force-recreate >/dev/null 2>&1 || true
    sleep 3
fi
docker compose -f "$COMPOSE_FILE" restart >/dev/null 2>&1 || true
sleep 3
require_running
if ! wait_ready; then
    run_sql_multi "ALTER SYSTEM SET ssl = off;" || true
    docker compose -f "$COMPOSE_FILE" restart >/dev/null 2>&1 || true
    die "server did not come back - TLS reverted; inspect: docker logs $CONTAINER"
fi

echo "[5/5] live configuration:"
psql_run -d "$DBNAME" -c "SELECT name, setting, pending_restart::text
    FROM pg_settings
    WHERE name IN ('server_version','listen_addresses','ssl','ssl_min_protocol_version',
                   'password_encryption','shared_preload_libraries') ORDER BY name;"
psql_run -d "$DBNAME" -c "SELECT line_number, type, array_to_string(database,' ') AS db,
        array_to_string(user_name,' ') AS roles, address, auth_method, COALESCE(error,'') AS error
    FROM pg_hba_file_rules ORDER BY line_number;"
psql_run -d "$DBNAME" -tA -c "SELECT format('%s login roles  |  %s',
        count(*), string_agg(rolname, ', ' ORDER BY rolname))
    FROM pg_roles WHERE rolcanlogin AND rolname LIKE 'afpc%'"
psql_run -d "$DBNAME" -tA -c "SELECT CASE WHEN count(*) = 0 THEN
        'pg_stat_statements NOT installed - add it to 0000_extensions'
        ELSE 'pg_stat_statements ' || max(extversion) END
    FROM pg_extension WHERE extname = 'pg_stat_statements'"
