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
# Restoring: setval(v, true) means the NEXT nextval is v+1, which is what a table whose
# committed max is v must hand out; setval(v, false) hands out v itself (this file's own
# plan recorded that fact for the 2^31 probe and the restore block here did not apply it).
# The old form - setval(max, false), commented as yielding max+1 - was invisible for twelve
# migrations because every table a test touched rolled back to EMPTY, and an empty table's
# restore is a formality. audit_log is the first table whose MIGRATION-era rows persist:
# the next audited write after a test run re-drew an existing audit_id and 4_1 surfaced it
# as an audit_log_pkey violation. An empty table still lands on 1 via the ELSE branch.
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
        IF v >= 1 THEN
            EXECUTE format('SELECT setval(%L, %s, true)', r.seq, v);
        ELSE
            EXECUTE format('SELECT setval(%L, 1, false)', r.seq);
        END IF;
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
"4_5_tools_vs_schema|the debug views the docs promise are missing|4.5|0017_interaction_readpath"
"4_5_tools_vs_schema|nothing derives the per-call answer|4.5|0017_interaction_readpath"
# 5b's line is the undecided prospect question, not 4.5's name/arity half: the review's own
# note says prospects are invisible to vw_customers, and measured, no function can write
# entities.entity_type at all. T2 owns both halves. It is mapped here so a green harness
# cannot hide a failing reproduction, which is what the row it replaces was doing.
"4_5_tools_vs_schema|update_customer success=f|4.5|code:vw_customers_filter"
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
# 5.7's four rows are the two halves of 5.7.3 (the GUC nothing sets, failing open on writes and
# closed on reads), plus the two properties that make the control usable rather than merely
# present: the tenant predicate must reach an index, and the agent role must be able to write a
# row at all. Blocks C and D of the same file have no row: an audit read and a view/table
# comparison both succeed on the pre-0009 database too, and a phrase that cannot reproduce
# would read CLOSED through a branch that was never at risk.
"5_7_row_level_security|an agent cannot record a movement|5.7|0009_rls_enforcement"
"5_7_row_level_security|an agent cannot read its own reservations|5.7|0009_rls_enforcement"
"5_7_row_level_security|the tenant predicate is not an index condition|5.7|0009_rls_enforcement"
"5_7_row_level_security|the app role cannot write a CRM row at all|5.7|0009_rls_enforcement"
# 6.3 gets seven rows because the finding is seven separate claims about what a write does to a
# value, and only two of them are in the review's table: the stale column and the trigger that
# covers UPDATE only. The others - a table something rewrites with no column at all, a row whose
# age cannot be read, one rule installed twice, a column declared two ways, and a control that
# reaches the owner but not the agent - each needed its own state, and each reproduces on the
# pre-0010 database and goes quiet on the post one (measured: 7 ERR rows, then 7 OK).
"6_3_timestamps|updated_at went stale on an ordinary write|6.3|0010_timestamp_triggers"
"6_3_timestamps|the same column is declared two ways|6.3|0010_timestamp_triggers"
"6_3_timestamps|an address edit leaves no timestamp anywhere|6.3|0010_timestamp_triggers"
"6_3_timestamps|the age of a stock row is unknowable|6.3|0010_timestamp_triggers"
"6_3_timestamps|the same rule is installed twice|6.3|0010_timestamp_triggers"
"6_3_timestamps|nothing publishes which tables maintain a write timestamp|6.3|0010_timestamp_triggers"
"6_3_timestamps|own write left updated_at|6.3|0010_timestamp_triggers"
"6_1_idempotency|a replayed mutation performs its work twice|6.1|0011_idempotency"
"6_1_idempotency|the same key reused for a different request answers from the cache|6.1|0011_idempotency"
"6_1_idempotency|a crashed attempt owns its key forever|6.1|0011_idempotency"
"6_1_idempotency|a displaced attempt can still certify work that ran twice|6.1|0011_idempotency"
"6_1_idempotency|two tenants collide on one claim key|6.1|0011_idempotency"
"6_1_idempotency|the version columns remain decoration|6.1|0011_idempotency"
"6_1_idempotency|expired claims are never collected|6.1|0011_idempotency"
"6_1_idempotency|no register exists to ask which calls are guarded|6.1|0011_idempotency"
# 6.4 gets five rows. The review's own framing ("the planner prefers hnsw") is deliberately
# not among them: measured, the ESTIMATES of the two ANN plans cross twice between 500 and
# 5000 rows because the cost model does not charge the sort path for detoasting vectors, so
# preference is an estimator property, not a schema one. What is mapped is the usability of
# the index, the real buffer savings (9053 vs 260 on the rehearsal clone), and the three
# census claims - each of which reproduces ERR on a pre-0012 database and goes quiet after.
"6_4_vectors|has no hnsw index to answer it|6.4|0012_vector_indexing"
"6_4_vectors|saves no reads over the exhaustive scan|6.4|0012_vector_indexing"
"6_4_vectors|a vector column of a base table leads no hnsw index|6.4|0012_vector_indexing"
"6_4_vectors|an under-trained ivfflat index is still mounted|6.4|0012_vector_indexing"
"6_4_vectors|a listing view still projects the vector|6.4|0012_vector_indexing"
# 6.2 gets four rows: the trail's existence, its accuracy under ordinary DML, the one
# promise that can only be proven by attempting the forbidden write, and the chain verdict
# from the seat that writes it. All four print from the existence guard before 0013 (so
# each reproduces as measured) and from a failure branch after (so each means regression
# if it returns).
"6_2_audit|ordinary writes leave no trail|6.2|0013_audit_log"
"6_2_audit|the audit chain does not verify|6.2|0013_audit_log"
"6_2_audit|accepted a rewrite|6.2|0013_audit_log"
"6_2_audit|a tenant-coded table is untrailed|6.2|0013_audit_log"
# 6.5 gets five rows, one per block, and each is the sentence the *pre-0018* branch prints. The
# review's evidence for this finding is a column census, and a census cannot say what a column
# does; the rows below are the four things it does (an invented code that lands, a receipt the
# column's ceiling refuses, a balance labelled in a currency the item never named, a register
# that cannot see the column at all) plus the absence 6.5 states outright. The post-0018 branches
# in the same file that print ERR when a mechanism is broken - a blended average, a refusal that
# wrote its ledger row first - are deliberately NOT mapped: crediting a migration with closing a
# case that never reproduced on any database is how the report starts flattering itself.
"6_5_money_currency|no currency master exists, so an invented code|6.5|0018_currencies"
"6_5_money_currency|money and quantity share one precision and the door multiplies|6.5|0018_currencies"
"6_5_money_currency|the balance a door created for a JPY item is kept in|6.5|0018_currencies"
"6_5_money_currency|there is no rate history anywhere|6.5|0018_currencies"
"6_5_money_currency|is outside the candidate set|6.5|0018_currencies"
# 4.5's remaining half is the customer service agent's own surface, and it is three findings
# wearing one number: a write path that lived in a Python file, a read path whose parameter
# reached no comparison, and an agent memory that lived in a container directory. Each row below
# prints from an existence guard on a pre-fix database and from a failure branch on a post-fix
# one, which is the pair that lets the report say KNOWN-OPEN and CLOSED honestly and REGRESSION
# if either ever comes back. 7a's "the refusal wrote a row" is scoped to this file by the
# per-file grep, so a similar phrase elsewhere cannot satisfy it.
"4_7_cs_agent_surface|there is no door for interactions|4.5|0021_communication_write"
"4_7_cs_agent_surface|an ambiguous name was resolved anyway|4.5|0021_communication_write"
"4_7_cs_agent_surface|the refusal wrote a row|4.5|0021_communication_write"
"4_7_cs_agent_surface|one idempotency key produced|4.5|0021_communication_write"
"4_7_cs_agent_surface|no door to create the interaction it tests|4.5|0021_communication_write"
"4_7_cs_agent_surface|the threshold is decorative|4.5|0022_followup_threshold"
"4_7_cs_agent_surface|moves the answer the wrong way|4.5|0022_followup_threshold"
"4_7_cs_agent_surface|labels it the interaction time|4.5|0022_followup_threshold"
"4_7_cs_agent_surface|cannot fire (rows=|4.5|0022_followup_threshold"
"4_7_cs_agent_surface|memory lives outside the database|ADR-002|0023_agent_memory"
# 4_8 is the inventory agent's surface (agents/inventory). 8a's phrase is 0026's defect - the
# ledger VALUES rotated against the column list - which no CASES row carried until the seed
# reproduced it by succeeding at a reservation for the first time since 0018. 8b's two phrases
# are 0015's signature contract the tool's positional Call is built on. 8c's column census is
# deliberately unmapped: it credits no past finding, and when it fires, the row to add maps it
# to whatever migration renamed the column - see the probe's own header.
"4_8_inventory_agent_surface|ledger values sit in the wrong|4.3|0026_reservation_ledger_order"
"4_8_inventory_agent_surface|parameter positions are not what|4.3|0015_reservation_locking"
"4_8_inventory_agent_surface|the reservation door answers|4.3|0015_reservation_locking"
"4_7_cs_agent_surface|normalisation is not agreed|ADR-002|0023_agent_memory"
# 7_1 is the orders programme's surface (agents/sales), and its rows are the pair 4_7's are: a
# phrase for the state a database before 0027-0030 reproduces, and a phrase for the mechanism
# existing and being broken. The pre-0028 guard phrases cannot fire after the migrations and the
# failure branches cannot fire before them, so each pair reads CLOSED on a current database,
# KNOWN-OPEN on an old one, and REGRESSION on the day a door stops meaning what its tool says.
# 1h's census and 1g's position phrase are the forward-looking kind 4_8 §8c/§8b established: they
# credit no past finding, and on the day one fires the row to edit names whatever migration moved.
"7_1_orders|there is no orders table at all|orders|0028_orders"
"7_1_orders|the counterparty rule is not a constraint|orders|0028_orders"
"7_1_orders|naming a customer was accepted|orders|0028_orders"
"7_1_orders|legal counterparty shapes now fails|orders|0028_orders"
"7_1_orders|no lifecycle register|orders|0028_orders"
"7_1_orders|wrote a stock-moving status|orders|0028_orders"
"7_1_orders|accepted expected_version 1|orders|0028_orders"
"7_1_orders|there is no order detail table|orders|0028_orders"
"7_1_orders|neither an item nor a description was accepted|orders|0028_orders"
"7_1_orders|accepted a COMPONENT line|orders|0029_work_orders"
"7_1_orders|none of the fulfilment doors are installed|orders|0030_order_fulfilment"
"7_1_orders|the write seat cannot execute|orders|0030_order_fulfilment"
"7_1_orders|change state with no claim attached|orders|0030_order_fulfilment"
"7_1_orders|there is no reconciliation view|orders|0030_order_fulfilment"
"7_1_orders|commitment of 4 reads as committed|orders|0030_order_fulfilment"
"7_1_orders|is still unresolved, which is the|orders|0030_order_fulfilment"
"7_1_orders|nothing enforces that a commitment names a document|orders|0030_order_fulfilment"
"7_1_orders|a STOCK hold naming no document is refused|orders|0030_order_fulfilment"
"7_1_orders|naming no document answered|orders|0030_order_fulfilment"
"7_1_orders|positions are not what pkg/orders calls them|orders|0030_order_fulfilment"
"7_1_orders|the read surface and the code disagree|orders|0030_order_fulfilment"

"4_7_cs_agent_surface|append-only is a comment, not a wall|ADR-002|0023_agent_memory"
"4_7_cs_agent_surface|attaches by census is missing|ADR-002|0023_agent_memory"
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
