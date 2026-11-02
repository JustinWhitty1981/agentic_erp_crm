#!/usr/bin/env bash
# Apply development reference data. Seeds are re-runnable by contract, not by
# bookkeeping: every statement must be safe to repeat (ON CONFLICT DO NOTHING, or a
# guarded insert). Anything that is part of the schema contract - the default tenant
# row, domain code tables - belongs in a migration, not here.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

load_env
require_running
ensure_database

shopt -s nullglob
files=("$DBROOT"/db/seeds/*.sql)
if [ ${#files[@]} -eq 0 ]; then
    echo "seeds: none in db/seeds/ (data lives in the agents' own test fixtures for now)"
    exit 0
fi

for f in "${files[@]}"; do
    if run_sql_file "$f" >/dev/null 2>&1; then
        printf '%-46s seeded\n' "$(basename "$f")"
    else
        printf '%-46s FAILED\n' "$(basename "$f")"
        cat "$f" | psql_run -d "$DBNAME" -f - >/dev/null   # re-run to surface the error
        exit 1
    fi
done

scalar "SELECT format('%s entities / %s contacts / %s communications',
    (SELECT count(*) FROM entities), (SELECT count(*) FROM contacts),
    (SELECT count(*) FROM communications))" 2>/dev/null || true
