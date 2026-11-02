#!/usr/bin/env bash
# Execute the schema functions against the live database and compare what they do
# with what DATABASE_REVIEW.md 4.x and 5.2 measured.
#
# Reading the report:
#   KNOWN-OPEN   the finding reproduces and its migration is not applied. Expected.
#   CLOSED       its migration is applied and it no longer reproduces.
#   REGRESSION   its migration is applied and it still reproduces.
#   SURPRISE     it stopped reproducing with no migration to explain why.
# Separating "expected red" from "unexpected red" is the point: on a database that
# persists for the life of the project a harness that cannot tell them apart becomes
# noise and gets ignored.
#
# Residue is checked. Every case wraps itself in a transaction, but an unwrapped
# DO block once committed a real customer here, and sequences are not transactional
# at all. So row counts are compared before and after, and the communications counter
# is reset from the table rather than from a remembered value.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

load_env
require_running
ensure_database

COUNTS_SQL="DO \$\$
DECLARE r record; n bigint;
BEGIN
    FOR r IN SELECT c.relname FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
              WHERE ns.nspname = 'public' AND c.relkind = 'r'
                AND c.relname <> 'schema_migrations' ORDER BY 1
    LOOP
        EXECUTE format('SELECT count(*) FROM public.%I', r.relname) INTO n;
        RAISE NOTICE 'COUNT % %', r.relname, n;
    END LOOP;
END
\$\$;"
snapshot() { psql_run -d "$DBNAME" -f - 2>&1 <<< "$COUNTS_SQL" | grep -o 'COUNT .*' | sort; }

BEFORE="$(snapshot)"

RESULTS="$(mktemp -d)"
for f in "$DBROOT"/db/tests/*.sql; do
    base="$(basename "$f" .sql)"
    printf '  running %-34s' "$base"
    cat "$f" | psql_run -d "$DBNAME" -f - > "$RESULTS/$base.out" 2>&1 \
        && echo "" || echo "  (file reported an error; verdicts below)"
done

# Restore the counter the 5.2 ceiling case advances on purpose.
run_sql "SELECT setval('communications_id_seq',
            COALESCE((SELECT max(id) FROM communications), 1), false);" >/dev/null 2>&1 || true

# file          | text meaning "the finding reproduces"        | finding | migration that closes it
CASES=(
"4_1_movement_missing_uom|VERDICT ERR P0001|4.1|0014_movement_contract"
"4_2_on_hand_no_identity|VERDICT ERR 42P10|4.2|0004_on_hand_identity"
"4_2_on_hand_no_identity|duplicate stock rows|4.2|0004_on_hand_identity"
"4_3_reserve_handler_crash|structure of query|4.3|0015_reservation_locking"
"4_4_add_customer_ambiguous|10-argument call: function|4.4|0016_single_add_customer"
"4_4_add_customer_ambiguous|4-argument call: function|4.4|0016_single_add_customer"
"4_4_add_customer_ambiguous|overloads of add_customer are installed|4.4|0016_single_add_customer"
"4_5_tools_vs_schema|finding 3.1|4.5|code:tool_prefix"
"4_5_tools_vs_schema|agent_tool_calls does not exist|4.5|0017_tool_call_log"
"4_5_tools_vs_schema|tickets does not exist|4.5|0017_tool_call_log"
"5_2_thread_key_ceiling|threading dies here|5.2|0005_key_types"
"5_2_thread_key_ceiling|thread_root_id has no FK|5.2|0005_key_types"
# 4.2 splits into two rows on purpose: 0004 makes the arbiter inferable and stops
# duplicate stock rows, but the ISSUE branch's silent zero-row update is a different
# defect that no constraint can express. Recording them together would let 0004 be
# credited with closing a hole that stays open.
"4_6_update_branch_vanishes|phantom issue|4.2|0014_movement_contract"
# The multi-bin deduction is the reservation/location half of the same defect family, and
# 0015 is where "honour location_id" is scheduled. Splitting it from the phantom-issue row
# means closing 0014 cannot be mistaken for closing this.
"4_6_update_branch_vanishes|warehouse-wide issue touched|4.2|0015_reservation_locking"
# 5.8 gets two rows: the tenancy column itself (closed by 0003) and row-level
# isolation, which is a different mechanism and lands in 0009. Reporting them as one
# assertion would let 0003 go green while an agent could still read a foreign row.
"5_8_tenancy|no tenant_id column, so a second|5.8|0003_tenant_foundation"
"5_8_tenancy|no row-level isolation yet|5.8|0009_rls_enforcement"
)

echo
printf '  %-30s %-12s %-6s %s\n' CASE STATE FINDING DETAIL
printf '  %-30s %-12s %-6s %s\n' "------------------------------" "------------" "------" "------"
OPEN_N=0; CLOSED_N=0; BAD_N=0
for row in "${CASES[@]}"; do
    IFS='|' read -r file want finding fixed_by <<< "$row"
    applied=$(closed "$fixed_by")
    if grep -qF "$want" "$RESULTS/$file.out" 2>/dev/null; then
        if [ "$applied" != "0" ]; then
            state="REGRESSION"; detail="still reproduces after $fixed_by"; BAD_N=$((BAD_N+1))
        else
            state="KNOWN-OPEN"; detail="reproduces as measured in the review"; OPEN_N=$((OPEN_N+1))
        fi
    else
        if [ "$applied" = "0" ]; then
            state="SURPRISE"; detail="passes, but $fixed_by is not applied"; BAD_N=$((BAD_N+1))
        else
            state="CLOSED"; detail="closed by $fixed_by"; CLOSED_N=$((CLOSED_N+1))
        fi
    fi
    printf '  %-30s %-12s %-6s %s\n' "$file" "$state" "$finding" "$detail"
done

echo
echo "  raw verdicts"
grep -h 'VERDICT' "$RESULTS"/*.out | sed "s/psql:<stdin>:[0-9]*: NOTICE:  /    /" | sort -u

AFTER="$(snapshot)"
if [ "$BEFORE" = "$AFTER" ]; then
    echo
    echo "  residue: none - row counts identical before and after"
else
    echo
    echo "  residue: TESTS WROTE TO THE PERSISTENT DATABASE"
    diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER") | sed 's/^/    /'
    BAD_N=$((BAD_N+1))
fi

echo
printf '  known-open %s   closed %s   needs attention %s\n' "$OPEN_N" "$CLOSED_N" "$BAD_N"
rm -rf "$RESULTS"
[ "$BAD_N" -eq 0 ] || exit 1
