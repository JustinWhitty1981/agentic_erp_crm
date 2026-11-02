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

# Sequences are not transactional, so every counter a case deliberately pushes past its
# ceiling has to be pulled back afterwards, or the next run inherits it. This is derived
# from the catalog rather than named: 0005 added tests that advance entities_id_seq too,
# and a hand-maintained list of exactly one sequence is how a harness starts lying.
# Restoring from max(id) with is_called=false means the next nextval() returns max(id)+1,
# which is what a fresh database would hand out.
DO_RESTORE="DO \$\$
DECLARE r record; v bigint;
BEGIN
    FOR r IN
        SELECT c.relname AS tbl, a.attname AS col,
               pg_get_serial_sequence(c.relname, a.attname) AS seq
          FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relname <> 'schema_migrations'
           AND a.attnum > 0 AND NOT a.attisdropped
           AND pg_get_serial_sequence(c.relname, a.attname) IS NOT NULL
         ORDER BY 1
    LOOP
        EXECUTE format('SELECT coalesce(max(%I), 0) FROM public.%I', r.col, r.tbl) INTO v;
        -- greatest(...,1): setval rejects 0, and an empty table's max() is 0. With
        -- is_called = false the next nextval() is 1, which is what an untouched sequence
        -- would hand out anyway.
        EXECUTE format('SELECT setval(%L, %s, false)', r.seq, greatest(v, 1));
    END LOOP;
END
\$\$;"

# Normalise first, so the run starts from the same counters a fresh database would have,
# then normalise again: the cases roll their own rows back, but the counters they moved do
# not come back with them.
printf '  %-38s' "normalising serial counters"
if ! printf '%s\n' "$DO_RESTORE" | psql_run -d "$DBNAME" -f - 2>&1 | grep -q "ERROR"; then echo "ok"
else echo "FAILED - the harness cannot vouch for the counters"; fi
BEFORE_SEQ="$(psql_run -d "$DBNAME" -tA -c \
    "SELECT sequencename||'='||coalesce(last_value::text,'-') FROM pg_sequences ORDER BY 1")"

RESULTS="$(mktemp -d)"
for f in "$DBROOT"/db/tests/*.sql; do
    base="$(basename "$f" .sql)"
    printf '  running %-34s' "$base"
    cat "$f" | psql_run -d "$DBNAME" -f - > "$RESULTS/$base.out" 2>&1 \
        && echo "" || echo "  (file reported an error; verdicts below)"
done

printf '  %-38s' "restoring serial counters"
if ! printf '%s\n' "$DO_RESTORE" | psql_run -d "$DBNAME" -f - 2>&1 | grep -q "ERROR"; then echo "ok"
else echo "FAILED - the harness cannot vouch for the counters"; fi
AFTER_SEQ="$(psql_run -d "$DBNAME" -tA -c \
    "SELECT sequencename||'='||coalesce(last_value::text,'-') FROM pg_sequences ORDER BY 1")"
[ "$BEFORE_SEQ" = "$AFTER_SEQ" ] || SEQ_DRIFT=1

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
# 5.1/5.3 and 5.4 are behavioural: a column of the wrong width and a key distribution that
# is merely bad both look entirely normal in the catalog, which is the lesson of 5.2. These
# rows are what stops 0005 being credited for a type it did not actually change.
"5_1_3_4_key_width_and_order|the >2^31 path failed|5.1|0005_key_types"
"5_1_3_4_key_width_and_order|threading dies here|5.3|0005_key_types"
"5_1_3_4_key_width_and_order|arrived out of order|5.4|0005_key_types"
"5_1_3_4_key_width_and_order|the nil-UUID sentinel|5.4|0005_key_types"
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
# 5.5 and 5.6 are about whether an index is USED, which is a statistics question and cannot be
# settled by reading pg_indexes - or by running anything on an empty table. These rows bring
# their own volume, so they reproduce on a pre-0006 database and go quiet on a post-0006 one.
# The file's fifth assertion - that the planner PREFERS the trigram once the table is large -
# deliberately has no row here: it cannot be evaluated at today's size, and a row that reads
# CLOSED because a branch was skipped would be the harness crediting itself for nothing.
"5_5_6_index_hygiene|no index can answer the entity-name lookup|5.5|0006_index_hygiene"
"5_5_6_index_hygiene|no index can answer the email duplicate check|5.5|0006_index_hygiene"
"5_5_6_index_hygiene|still scans the child table|5.6|0006_index_hygiene"
# Two rows for 5.6's hygiene half: the redundancy answer itself, and whether anything has
# counted it yet. The second is the one that would otherwise read CLOSED by silence.
"5_5_6_index_hygiene|no redundancy view exists yet|5.6|0006_index_hygiene"
# 5.9's rows are each half of a design claim, so each needs its own state: a CHECK that refuses
# a case variant, a CHECK that still accepts its own vocabulary, a code table that grows with an
# INSERT, a state machine that refuses an undefined value, and the free-text exceptions staying
# open on purpose with a reason attached.
"5_9_domain_values|accepted ACTIVE alongside active|5.9|0007_domain_constraints"
"5_9_domain_values|were refused by the constraint that publishes them|5.9|0007_domain_constraints"
"5_9_domain_values|no published vocabulary yet|5.9|0007_domain_constraints"
"5_9_domain_values|no master-data tables exist yet|5.9|0007_domain_constraints"
"5_9_domain_values|did not restrict an unknown code|5.9|0007_domain_constraints"
"5_9_domain_values|registered and is still refused|5.9|0007_domain_constraints"
"5_9_domain_values|accepted an undefined state|5.9|0007_domain_constraints"
"5_9_domain_values|is now constrained by|5.9|0007_domain_constraints"
"5_9_domain_values|are undocumented|5.9|0007_domain_constraints"
"5_5_6_index_hygiene|index pairs are redundant|5.6|0006_index_hygiene"
# 5.10's five rows are the destructions themselves, attempted. Block F of the same file
# deliberately has no row: the retained bin cascade succeeds before AND after 0008 alike, and
# a phrase that cannot reproduce on a pre-0008 database would read CLOSED through a branch
# that was never at risk. It is a regression guard, nothing more.
"5_10_delete_safety|a warehouse delete destroyed|5.10|0008_delete_safety"
"5_10_delete_safety|an item delete destroyed|5.10|0008_delete_safety"
"5_10_delete_safety|a session delete destroyed|5.10|0008_delete_safety"
"5_10_delete_safety|was not refused by its own constraint|5.10|0008_delete_safety"
"5_10_delete_safety|no explicit close-out path exists|5.10|0008_delete_safety"
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

# Row counts cannot see a moved counter, and a moved counter is exactly what the ceiling
# cases leave behind. A test that pushes a sequence past 2^31 and does not restore it has
# changed the persistent database as surely as an INSERT would have: the next run starts
# from a different key space, and only the first run of a suite reports the truth.
if [ "${SEQ_DRIFT:-0}" = "1" ]; then
    echo
    echo "  residue: SERIAL COUNTERS MOVED AND WERE NOT RESTORED"
    diff <(printf '%s\n' "$BEFORE_SEQ") <(printf '%s\n' "$AFTER_SEQ") | sed 's/^/    /'
    BAD_N=$((BAD_N+1))
fi

echo
printf '  known-open %s   closed %s   needs attention %s\n' "$OPEN_N" "$CLOSED_N" "$BAD_N"
rm -rf "$RESULTS"
[ "$BAD_N" -eq 0 ] || exit 1
