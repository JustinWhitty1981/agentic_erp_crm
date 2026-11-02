#!/usr/bin/env bash
# Apply pending migrations in filename order, with drift and ordering enforcement.
#
#   scripts/db/migrate.sh            apply what is pending
#   scripts/db/migrate.sh --status   report applied vs. on-disk, change nothing
#
# Guarantees this provides, none of which the Makefile it replaces had:
#   * ON_ERROR_STOP=1, so a failing statement aborts the file instead of being
#     skipped while psql still exits 0.
#   * One transaction per file, so a partial application is impossible. A file may
#     opt out with a 'migrate:no-transaction' directive in its first 30 lines, which
#     is what CREATE INDEX CONCURRENTLY requires.
#   * A checksum per applied file. Editing history is an error, not silent drift,
#     because this database is expected to persist for the life of the project.
#   * Version numbers must strictly increase over what is already applied, so
#     nothing can be inserted into the middle of the history: that migration would
#     never run on a populated copy, which is exactly how the fork in 3.1 stayed
#     unnoticed. Comparison is on the 4-digit prefix, not the whole filename.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

STATUS_ONLY=0
ALLOW_DRIFT=0
for arg in "$@"; do
    case "$arg" in
        --status) STATUS_ONLY=1 ;;
        --allow-checksum-drift) ALLOW_DRIFT=1 ;;
        *) die "unknown argument: $arg" ;;
    esac
done

load_env
require_running
wait_ready
ensure_database

run_sql_multi "SET client_min_messages TO warning;
CREATE TABLE IF NOT EXISTS public.schema_migrations (
    version     text        PRIMARY KEY,
    filename    text        NOT NULL,
    checksum    text        NOT NULL,
    applied_at  timestamptz NOT NULL DEFAULT now()
);
" >/dev/null

# Applied state, loaded once rather than per file.
declare -A APPLIED_SUM=()
while IFS='|' read -r ver sum; do
    [ -n "$ver" ] && APPLIED_SUM["$ver"]="$sum"
done < <(psql_run -d "$DBNAME" -tA -F'|' -c "SELECT version, checksum FROM public.schema_migrations ORDER BY version")

HIGHEST=$(psql_run -d "$DBNAME" -tA -c "SELECT COALESCE(max(split_part(version,'_',1)), '0000') FROM public.schema_migrations" | tr -d '\r\n ')

printf '%-44s %-12s %s\n' MIGRATION STATE DETAIL
printf '%-44s %-12s %s\n' "--------------------------------------------" "------------" "------"
FAILED=0
for file in "$MIGRATIONS_DIR"/*.sql; do
    [ -e "$file" ] || die "no migrations in $MIGRATIONS_DIR"
    ver="$(basename "$file" .sql)"
    num="${ver%%_*}"
    sum="$(sha256sum "$file" | cut -d' ' -f1)"

    if [ -n "${APPLIED_SUM[$ver]:-}" ]; then
        if [ "${APPLIED_SUM[$ver]}" != "$sum" ]; then
            printf '%-44s %-12s %s\n' "$ver" "DRIFT" "changed after applying; add a new migration instead"
            FAILED=1
        else
            printf '%-44s %-12s %s\n' "$ver" "applied" ""
        fi
        continue
    fi

    if [ "$STATUS_ONLY" = 1 ]; then
        printf '%-44s %-12s %s\n' "$ver" "pending" ""
        continue
    fi

    # Strictly increasing, so a file spliced into the middle of history is rejected
    # rather than silently skipped on the next populated copy.
    if [ "$((10#$num))" -le "$((10#$HIGHEST))" ] && [ "${#APPLIED_SUM[@]}" -gt 0 ]; then
        printf '%-44s %-12s %s\n' "$ver" "OUT OF ORDER" "$num is not above the applied $HIGHEST"
        FAILED=1
        continue
    fi

    txn_flag="-1"
    head -30 "$file" | grep -q 'migrate:no-transaction' && txn_flag=""

    started=$(date +%s%N)
    if cat "$file" | psql_run -d "$DBNAME" $txn_flag >/dev/null 2>"/tmp/afpc-mig.$$.err"; then
        printf '%-44s %-12s %sms\n' "$ver" "APPLIED" "$(( ($(date +%s%N) - started) / 1000000 ))"
        # Migration NOTICEs are part of the record: 0003 reports which redundant indexes
        # it removed and which views are still not tenant-aware. Discarding them on
        # success would make a clean run look silent and an audited run unauditable.
        grep -E 'NOTICE|WARNING' "/tmp/afpc-mig.$$.err" \
            | sed -e 's/^[^:]*: *//' -e 's/^/       ! /' -e 's/^! /       ! /' || true
        run_sql "INSERT INTO public.schema_migrations (version, filename, checksum)
                 VALUES ('$ver', '$(basename "$file")', '$sum');" >/dev/null
        APPLIED_SUM["$ver"]="$sum"   # keep the closing summary honest: it used to lag by one
        [ "$num" \> "$HIGHEST" ] && HIGHEST="$num"
    else
        printf '%-44s %-12s %s\n' "$ver" "FAILED" "$(tr '\n' ' ' < "/tmp/afpc-mig.$$.err" | cut -c1-150)"
        rm -f "/tmp/afpc-mig.$$.err"
        exit 1        # a failure here means the transaction rolled back; stop, do not continue
    fi
    rm -f "/tmp/afpc-mig.$$.err"
done

# Anything recorded as applied but no longer on disk.
for ver in "${!APPLIED_SUM[@]}"; do
    [ -f "$MIGRATIONS_DIR/$ver.sql" ] || { printf '%-44s %-12s %s\n' "$ver" "MISSING FILE" "applied but absent from db/migrations/"; FAILED=1; }
done

echo
printf 'database %s  applied %s  on disk %s\n' "$DBNAME" "${#APPLIED_SUM[@]}" "$(ls "$MIGRATIONS_DIR"/*.sql | wc -l)"
exit $FAILED
