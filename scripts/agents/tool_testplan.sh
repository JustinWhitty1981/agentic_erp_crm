#!/usr/bin/env bash
# scripts/agents/tool_testplan.sh — the agent tool acceptance harness.
#
# docs/agent_requirements/agent_test_plan.md is this file's plan; this file is that plan's
# execution. The doc's case table and the cases below are the same artifact maintained in two
# notations, and they fail together: a case here carries the number its doc row has.
#
# What "verification" means here: the agent's prose is never the assertion. Each case checks
#   (1) the call happened  - vw_tool_calls, keyed by the run_id POST /api/chat returns,
#   (2) the state is real  - the same views and tables the agent read and the doors wrote,
#   (3) the run recorded  - agent_interactions, aligned observations, and the audit trail.
# A pass means the database agrees with what was said; a fail says which plane disagreed.
#
# Fixtures carry the run stamp $TS because add_customer refuses a duplicate name OR email, and a
# plan that cannot be re-run is a demo. Expect 15-40 minutes: every case is a real turn through a
# real model, which is the only way to test what a human would experience.
#
# Cases 22-36 are the third agent's surface: one per registered tool, one tool asked twice because an
# item line and a service line are different questions to the same door, one refusal that carries the
# whole programme's claim (29), and the timer. Cases 22-34 DEPEND on each other in
# registration order: 23 registers the supplier 25 places the order with, 25 makes the document 26
# lines and 28 transitions, 32 receives. That is not an accident to work around - a purchase order
# that arrives already lined and submitted would test the read path of a fixture rather than the
# write path of an agent. Each dependent case therefore names the case to re-run when its fixture is
# missing, and the fixtures carry $TS so a re-run raises a new document instead of colliding with the
# last one. Case 34's SALES fixture is the exception and says so where it is built: the case under
# test is the ship door, and a fixture made by three prompts would fail with three possible causes.

set -u
CS=http://127.0.0.1:4550
IV=http://127.0.0.1:4560
SA=http://127.0.0.1:4570
DBQ=(docker exec -i afpc-pg psql -U postgres -d agent_first_erp_crm -tAF'|' -c)

TS=${FIXTURE_TS:-$(date +%H%M%S)}   # set FIXTURE_TS=<stamp> with CASE_FILTER to re-run one case
                                    # against an earlier run's fixture, rather than all 21 again
JANE="Jane Doe $TS"
EMAIL="jane.$TS@afpc.example.invalid"
PHONE="+1777$TS"
MKEY="harness.pref.$TS"
# Case 20's order id, and the reason it is not a uuid the shell invented. Every version of this plan
# before 0030 passed `$(cat /proc/sys/kernel/random/uuid)` here, and the reservation accepted it: the
# commitment was filed against a document that named no row, which is the exact shape thirteen units
# sat in for a hundred thousand hours. §3b's trigger now answers 23503, so the fixture raises a REAL
# sales order through the door - which makes this case assert the thing it always claimed (a
# reservation on an order) instead of the residue the schema used to permit.
OUID=""
OENT=$( "${DBQ[@]}" "SELECT id FROM entities WHERE entity_type='customer' ORDER BY id LIMIT 1")
OUID=$( "${DBQ[@]}" "SELECT order_id FROM create_order('SALES',$OENT,NULL,
        (SELECT warehouse_id FROM warehouses WHERE warehouse_code='MAIN'),NULL,'2026-12-31',NULL,
        'tool_testplan fixture $TS','MANUAL',NULL)")
if [ -z "$OUID" ]; then echo "  ABORT: case 20's fixture order could not be raised (0030 refuses a commitment against a document that does not exist, and gen_random_uuid() is no longer one)"; exit 2; fi
echo "  fixture: sales order $OUID raised for case 20 to reserve against"
SUPCODE="SUP-$TS"                          # suppliers_code_format wants [A-Z0-9][A-Z0-9_-]{0,49}
SUPNAME="Steelworks $TS"
WHMAIN=$( "${DBQ[@]}" "SELECT warehouse_id FROM warehouses WHERE warehouse_code='MAIN'")
# Threads carry a per-invocation stamp, NOT just the fixture stamp: a filtered re-run against an
# old FIXTURE_TS must not rehydrate the previous run's conversation. Measured on the second such
# re-run, the agent answered "the record already reads 1235" from week-old-in-minutes history and
# called ZERO tools while the database said otherwise - correct by its context, wrong about the
# state, and the call plane caught it. Acceptance turns start with no memory of prior attempts.
NOW=$(date +%s)
RUNIDS=""
PASS=0 FAIL=0
FAILED_CASES=()

QERR=$(mktemp); QERRS=""
q() { "${DBQ[@]}" "$1" 2>"$QERR" | tr -d '\r' | head -1
      if grep -q '^ERROR' "$QERR"; then
          QERRS="$(grep -m1 '^ERROR' "$QERR")";
      fi; }

chat() { # chat <base-url> <thread> <prompt>  -> RID, REPLY, HTTP
    local body out
    body=$(jq -nc --arg m "$3" --arg t "$2" '{message:$m, thread_id:$t}')
    out=$(curl -s -m 300 -w '\n%{http_code}' -X POST "$1/api/chat" \
          -H 'Content-Type: application/json' -d "$body")
    HTTP=$(printf '%s' "$out" | tail -1)
    local json; json=$(printf '%s' "$out" | sed '$d')
    REPLY=$(printf '%s' "$json" | jq -r '.response // empty')
    RID=$(printf '%s' "$json" | jq -r '.run_id // empty')
    [ -n "$RID" ] && RUNIDS="$RUNIDS'$RID',"
}

tool_called() { [ "$(q "SELECT count(*) FROM vw_tool_calls WHERE run_id='$1' AND tool_name='$2'")" -ge 1 ]; }
tool_errored() { [ "$(q "SELECT count(*) FROM vw_tool_calls WHERE run_id='$1' AND tool_name='$2' AND observation_type='error'")" -ge 1 ]; }
obs_has() { [ "$(q "SELECT count(*) FROM vw_tool_calls WHERE run_id='$1' AND tool_name='$2' AND observation::text ILIKE '%$3%'")" -ge 1 ]; }
sql_true() { [ -n "$(q "SELECT 1 WHERE $1")" ]; }
# wait_for <fn...> polls a condition for up to 15 seconds. The one thing it exists for: the
# trajectory row is written by the recorder's defer, which can land just after the chat response
# returns - a check that reads agent_interactions the instant the turn ends races its own commit.
# (Case 4 proved this on the first run: it reported, correctly at that microsecond, that sources
# were missing from a row that had them 50ms later.)
wait_for() { local deadline=$((SECONDS + 15)); while ! "$@"; do
        [ "$SECONDS" -lt "$deadline" ] || return 1; sleep 1; done; }
max_audit() { q "SELECT coalesce(max(audit_id),0) FROM audit_log"; }
want_case() { [ -z "${CASE_FILTER:-}" ] || [[ ",$CASE_FILTER," == *",$1,"* ]]; }

verdict() { # verdict <case> <ok:0/1> <detail>
    if [ "$2" = 0 ]; then
        printf '  %-42s PASS  %s\n' "$1" "$3"; PASS=$((PASS+1))
    else
        printf '  %-42s FAIL  %s\n' "$1" "$3"; FAIL=$((FAIL+1)); FAILED_CASES+=("$1")
    fi
}

# case <n> <name> <base> <prompt> <tool> <after-fn>
# after-fn receives nothing; it returns 0 and may set DETAIL.
case_run() {
    local n="$1" name="$2" base="$3" prompt="$4" tool="$5" after="$6"
    if ! want_case "$n"; then
        printf '  %-42s SKIP  filtered\n' "case $n: $name"
        return
    fi
    QERRS=""   # a psql error anywhere since the last reset makes a false a WITNESS, not a verdict
    chat "$base" "tp_${n}_${TS}_${NOW}" "$prompt"
    if [ -z "$RID" ]; then verdict "case $n: $name" 1 "no run_id returned"; return; fi
    # Three kinds of case, distinguished by what the call plane can prove.
    PASSNOTE="called $tool"
    case "$tool" in
        __either__*)
            # The door's refusal is the best evidence, and declining before asking is the second best:
            # both leave the state untouched, and only one puts a SQLSTATE in the trail. Case 29 is this
            # shape - see its comment for why the state plane carries the assertion.
            tool="${tool#__either__}"
            PASSNOTE="called $tool"
            if tool_called "$RID" "$tool"; then
                CALLPLANE=door
            else
                CALLPLANE=declined
                PASSNOTE="never asked the door (it declined first)"
            fi ;;
        __*)
            # A case whose subject is the schedule rather than a tool has no call plane: nothing in the
            # turn invoked `__schedule__`, because that is not a tool name - it is the marker that says
            # "the state plane is the whole assertion", and the state plane reads agent_interactions,
            # which is the table the tick writes. Case 35 died here with "the run never called
            # __schedule__" until the sentinel was honoured where it is *checked* rather than only where
            # it is excused.
            PASSNOTE="no call plane (a schedule, not a tool)"
            CALLPLANE=none ;;
        *)
            if ! tool_called "$RID" "$tool"; then
                verdict "case $n: $name" 1 "the run never called $tool (http $HTTP)${QERRS:+ | $QERRS}"
                return
            fi
            CALLPLANE=required ;;
    esac
    # The state plane runs for EVERY case that has one, including the sentinel cases. The test used to
    # read `[ "$tool" = "__none__" ] || ... || $after`, and `||` short-circuits: on a sentinel the
    # after-fn was skipped and the case still printed "state verified", which is a verdict the harness
    # had not earned. An empty $after is the only thing that legitimately skips it, and no case in this
    # file is written that way.
    DETAIL=""
    if [ -n "$after" ] && ! $after; then
        verdict "case $n: $name" 1 "${DETAIL:-the database disagrees with the answer}${QERRS:+ | harness SQL error: $QERRS}"
    else
        verdict "case $n: $name" 0 "${DETAIL:-$PASSNOTE; state verified}"
    fi
}

echo "== 0 preflight: all three agents up with their tools =="
for pair in "$CS crm_tools" "$IV inventory_tools" "$SA order_tools"; do
    set -- $pair
    if ! curl -sf -m 5 "$1/api/health" | jq -e ".$2 > 0" >/dev/null; then
        echo "  ABORT: $1 reports no $2 - the acceptance plan cannot judge tools that are not registered"; exit 2
    fi
done
echo "  all three surfaces registered (crm_tools, inventory_tools, order_tools > 0)"

# ---------------------------------------------------------------------------
# customer_service agent
# ---------------------------------------------------------------------------
echo "== cases 1-15: the customer service agent (:4550) =="

after_1() { obs_has "$RID" current_time "$(date -u +%F)"; }   # the tool read the same clock the harness knows
case_run 1 current_time "$CS" "What is today's date? Answer with the tool, not from memory." current_time after_1

need_eid() { [ -n "$EID" ] || EID=$(q "SELECT id FROM vw_customers WHERE name='$JANE'"); [ -n "$EID" ]; }

EID=""
after_2() {
    EID=$(q "SELECT id FROM vw_customers WHERE name='$JANE'")
    [ -n "$EID" ] || { DETAIL="no customer named $JANE"; return 1; }
    sql_true "(SELECT count(*) FROM addresses WHERE entity_id=$EID AND street='1234 Street') = 1
              AND (SELECT count(*) FROM audit_log WHERE table_name='entities'
                   AND row_pk->>'id'='$EID' AND action='INSERT') >= 1" || { DETAIL="row exists but street/trail missing"; return 1; }
    [ "$(max_audit)" -gt "$a2_0" ] || { DETAIL="the audit counter never moved during the case"; return 1; }
    true
}
a2_0=$(max_audit)
case_run 2 add_customer "$CS" \
  "Add a new customer: first name Jane, last name Doe $TS, email $EMAIL, phone $PHONE, living at 1234 Street, Austin, TX 78701." \
  add_customer after_2

after_3() { obs_has "$RID" get_customer_info "$EMAIL"; }
case_run 3 get_customer_info "$CS" "Look up the customer Jane Doe $TS and tell me what you find." get_customer_info after_3

after_4() {   # the user's example: the address change itself
    need_eid || { DETAIL="fixture customer not findable (run case 2 first, or fix the name)"; return 1; }
    local now; now=$(q "SELECT street FROM addresses WHERE entity_id=$EID AND is_primary")
    [ "$now" = "1235 Street" ] || { DETAIL="primary street is '$now', not 1235 Street"; return 1; }
    sql_true "EXISTS (SELECT 1 FROM audit_log al
        WHERE al.table_name='addresses' AND al.action='UPDATE'
          AND (al.row_pk->>'id')::bigint IN (SELECT id FROM addresses WHERE entity_id=$EID)
          AND al.old_values::text LIKE '%1234%' AND al.occurred_at > now() - interval '10 minutes')" ||
        { DETAIL="address moved but no UPDATE trail naming the old value"; return 1; }
    wait_for sql_true "(SELECT count(*) FROM agent_interactions ai WHERE ai.run_id='$RID'
               AND jsonb_array_length(coalesce(ai.response_sources,'[]'::jsonb)) > 0) = 1" ||
        { DETAIL="the run's trajectory row never recorded response_sources"; return 1; }
    true
}
case_run 4 update_customer "$CS" \
  "Change Jane Doe $TS's street address from 1234 Street to 1235 Street. The email is $EMAIL." \
  update_customer after_4

after_5() {
    need_eid || return 1
    sql_true "EXISTS (SELECT 1 FROM communications WHERE entity_id=$EID AND summary ILIKE '%$TS%')
              AND EXISTS (SELECT 1 FROM audit_log al
                          JOIN communications c ON c.id = (al.row_pk->>'id')::bigint
                          WHERE al.table_name='communications' AND al.action='INSERT'
                            AND c.entity_id=$EID AND c.summary ILIKE '%$TS%')" ||
        { DETAIL="no logged interaction with the marker, or it left no trail"; return 1; }
    true
}
case_run 5 add_communication "$CS" \
  "Log a phone call that just happened with Jane Doe $TS: she confirmed the move to 1235 Street. Mention reference $TS in the summary." \
  add_communication after_5

after_6() { obs_has "$RID" get_customer_communications "$TS"; }
case_run 6 get_customer_communications "$CS" "What communications have we had with Jane Doe $TS?" get_customer_communications after_6

after_7() { ! tool_errored "$RID" get_entity_stats; }
case_run 7 get_entity_stats "$CS" "Summarize the account statistics for Jane Doe $TS." get_entity_stats after_7

after_8() { obs_has "$RID" get_followup_customers "Alice"; }   # seeded follow-up rows must surface
case_run 8 get_followup_customers "$CS" "Which customers should we follow up with?" get_followup_customers after_8

after_9() { need_eid || return 1
            [ "$(q "SELECT status FROM entities WHERE id=$EID")" = "follow-up" ] &&
            sql_true "EXISTS (SELECT 1 FROM audit_log WHERE table_name='entities' AND row_pk->>'id'='$EID'
                       AND action='UPDATE' AND occurred_at > now() - interval '5 minutes')"; }
case_run 9 mark_followup_on "$CS" "Mark customer Jane Doe $TS for follow-up, id $EID." mark_customer_followup after_9

after_10() { need_eid || return 1
             [ "$(q "SELECT status FROM entities WHERE id=$EID")" = "active" ]; }
case_run 10 mark_followup_off "$CS" "Now clear the follow-up mark on Jane Doe $TS, entity id $EID." mark_customer_followup after_10

after_11() {
    sql_true "EXISTS (SELECT 1 FROM agent_memories WHERE memory_key='$MKEY' AND content ILIKE '%email%')" ||
        { DETAIL="memory row absent"; return 1; }
    true
}
case_run 11 save_memory "$CS" \
  "Remember this under the key $MKEY: Jane prefers email over phone for account notices." \
  save_memory_tool after_11

after_12() { obs_has "$RID" get_memory_tool "email"; }
case_run 12 get_memory "$CS" "What do you remember under the key $MKEY?" get_memory_tool after_12

after_13() { obs_has "$RID" list_memories_tool "$MKEY"; }
case_run 13 list_memories "$CS" "List everything you currently remember." list_memories_tool after_13

after_14() { obs_has "$RID" search_web "Tavily API key"; }
case_run 14 search_web_no_key "$CS" "Search the web for anything about $JANE." search_web after_14

after_15() { obs_has "$RID" scrape_url "blocked by security policy"; }
case_run 15 scrape_internal_guard "$CS" "Use your scrape tool on http://192.168.0.53:4560/api/health and tell me what it contains." scrape_url after_15

# ---------------------------------------------------------------------------
# inventory agent
# ---------------------------------------------------------------------------
echo "== cases 16-20: the inventory agent (:4560) =="

after_16() {
    obs_has "$RID" get_low_stock_items "IN-1002" &&
    [ "$(q "SELECT count(*) FROM vw_low_stock_alerts")" -ge 1 ]
}
case_run 16 get_low_stock_items "$IV" "Which items are below their reorder point right now?" get_low_stock_items after_16

after_17() { obs_has "$RID" get_item_availability "Coolant"; }
case_run 17 get_item_availability "$IV" "Where is stock of IN-1003 kept, and how much of it is there per warehouse?" get_item_availability after_17

after_18() { obs_has "$RID" get_item_movement_summary "days_of_supply"; }
case_run 18 get_item_movement_summary "$IV" "How has IN-1000 moved over the last month, and how many days of supply are left?" get_item_movement_summary after_18

after_19() { obs_has "$RID" get_inventory_valuation "USD" && obs_has "$RID" get_inventory_valuation "total_value"; }
case_run 19 get_inventory_valuation "$IV" "What is the inventory value at the Main Warehouse?" get_inventory_valuation after_19

after_20() {
    sql_true "EXISTS (SELECT 1 FROM inventory_reservations r WHERE r.order_id='$OUID' AND r.reserved_quantity=2)" ||
        { DETAIL="no reservation for the order the prompt named"; return 1; }
    sql_true "EXISTS (SELECT 1 FROM inventory_movements m
        WHERE m.movement_type='RESERVATION' AND m.reference_type='ORDER' AND m.reference_id='$OUID')" ||
        { DETAIL="the commitment's ledger row is missing or misfiled (0026's positions)"; return 1; }
    sql_true "EXISTS (SELECT 1 FROM audit_log WHERE table_name='inventory_reservations' AND action='INSERT'
               AND occurred_at > now() - interval '5 minutes')" ||
        DETAIL="reservation exists but left no trail"
    # The order this commitment names now resolves, which is the difference between 0030 and before:
    # a reservation whose document exists is one a door can release and a report can attribute.
    sql_true "EXISTS (SELECT 1 FROM orders o WHERE o.order_id='$OUID' AND o.order_type='SALES')" ||
        DETAIL="the reservation names an order that is not there - §3b's enforcement should have refused the write"
    true
    true
}
case_run 20 reserve_inventory "$IV" \
  "Reserve 2 units of IN-1003 (Coolant 5L Jerrican) at the Main Warehouse for sales order $OUID, on behalf of the harness. Look up the item and warehouse ids with the read tools first." \
  reserve_inventory after_20


# ---------------------------------------------------------------------------
# sales & procurement agent
# ---------------------------------------------------------------------------
echo "== cases 22-36: the sales & procurement agent (:4570) =="

# The four orders this server already has were raised by 0030's backfill, not by anybody's business.
# Case 22 asserts the agent can see them AND say what they are, which is the one place in the plan
# where "no rows" and "rows whose origin is a data-cleanup decision" must not read the same.
after_22() {
    [ "$(q "SELECT count(*) FROM vw_orders")" -ge 1 ] || { DETAIL="no documents at all"; return 1; }
    obs_has "$RID" get_orders "SO-0000" || obs_has "$RID" get_orders "RESERVATION_BACKFILL" ||
        { DETAIL="the run listed orders without naming a single one of them"; return 1; }
    true
}
case_run 22 get_orders "$SA" \
  "What orders do we have, and what state are they in? Tell me the numbers, not a summary." get_orders after_22

after_23() {
    SID=$(q "SELECT supplier_id FROM vw_suppliers WHERE supplier_code='$SUPCODE'")
    [ -n "$SID" ] || { DETAIL="no supplier with code $SUPCODE"; return 1; }
    sql_true "EXISTS (SELECT 1 FROM audit_log WHERE table_name='suppliers' AND action='INSERT' AND row_pk->>'supplier_id'='$SID')" || { DETAIL="registered with no trail"; return 1; }
    [ "$(q "SELECT party_name FROM vw_suppliers WHERE supplier_id='$SID'")" = "$SUPNAME" ] ||
        DETAIL="the supplier row does not carry the party name the prompt gave"
    true
}
case_run 23 add_supplier "$SA" \
  "Register a new supplier: $SUPNAME, code $SUPCODE, payment terms NET30, 14 days lead time. They sell us steel. They are not a customer, so create the party too." \
  add_supplier after_23

after_24() { obs_has "$RID" get_suppliers "$SUPCODE"; }
case_run 24 get_suppliers "$SA" "Who do we buy steel from, and on what terms?" get_suppliers after_24

POID=""
need_po() { [ -n "$POID" ] || POID=$(q "SELECT order_id FROM vw_orders WHERE order_type='PURCHASE' AND notes ILIKE '%$TS%' LIMIT 1"); [ -n "$POID" ]; }

after_25() {
    need_po || { DETAIL="no purchase order carrying reference $TS - run case 25 without a filter"; return 1; }
    sql_true "(SELECT status='DRAFT' AND vendor_id IS NOT NULL AND customer_id IS NULL FROM orders WHERE order_id='$POID')" ||
        { DETAIL="the document exists but is not an unshipped purchase order with exactly one counterparty"; return 1; }
    sql_true "EXISTS (SELECT 1 FROM audit_log WHERE table_name='orders' AND action='INSERT' AND row_pk->>'order_id'='$POID')" || DETAIL="raised with no trail"
    # The number is issued by the door, from a per-type counter - so a PURCHASE order answers PO-*,
    # and an agent or a tool that composed the string would get this wrong in the quiet direction.
    [ "$(q "SELECT left(order_number,3) FROM orders WHERE order_id='$POID'")" = "PO-" ] ||
        DETAIL="a purchase order numbered $(q "SELECT order_number FROM orders WHERE order_id='$POID'")"
    true
}
case_run 25 create_order "$SA" \
  "Raise a purchase order to supplier $SUPCODE for the Main Warehouse, needed by 2026-12-31, priority 2. Look the warehouse id up from the documents you can already read rather than typing its name, and put reference $TS in the notes." \
  create_order after_25

after_26() {
    need_po || return 1
    LIN=$(q "SELECT order_line_id FROM vw_order_lines WHERE order_id='$POID' AND item_id=(SELECT item_id FROM inventory_items WHERE sku='IN-1003') LIMIT 1")
    [ -n "$LIN" ] || { DETAIL="no line for IN-1000 on the fixture order"; return 1; }
    sql_true "(SELECT quantity=10 AND line_amount=145 AND line_state='OPEN' AND line_type='STANDARD' FROM vw_order_lines WHERE order_line_id='$LIN')" ||
        { DETAIL="the line exists but its amount or state is not what 10 x 14.50 says: $(q "SELECT quantity||'/'||coalesce(line_amount::text,'null')||'/'||line_state FROM vw_order_lines WHERE order_line_id='$LIN'")"; return 1; }
    sql_true "EXISTS (SELECT 1 FROM audit_log WHERE table_name='order_items' AND action='INSERT' AND row_pk->>'order_line_id'='$LIN')" || DETAIL="lined with no trail"
    true
}
case_run 26 add_order_line_item "$SA" \
  "Add a line to purchase order $(q "SELECT order_number FROM orders WHERE order_id='$POID'"): 10 of item IN-1003 at 14.50 each - it is the coolant we already buy, so its id is on an existing order line." \
  add_order_line after_26

after_27() {
    need_po || return 1
    LSV=$(q "SELECT order_line_id FROM vw_order_lines WHERE order_id='$POID' AND item_id IS NULL LIMIT 1")
    [ -n "$LSV" ] || { DETAIL="the service line was filed against an item, which is the MISCELLANEOUS failure 0028 exists to prevent"; return 1; }
    sql_true "(SELECT btrim(description) <> '' AND quantity=1 AND line_amount=350 FROM order_items WHERE order_line_id='$LSV')" ||
        { DETAIL="a line with no item carries no words or no amount"; return 1; }
    # The line number is the door's, allocated under the document's unique index - so two lines must
    # be 1 and 2 and never 2 and 2, which is what a caller composing the number would get wrong under
    # concurrency rather than under this prompt.
    [ "$(q "SELECT count(DISTINCT line_number) FROM order_items WHERE order_id='$POID'")" = "2" ] ||
        DETAIL="two lines share a line_number in one document"
    true
}
case_run 27 add_order_line_service "$SA" \
  "Now add a second line to the same purchase order: a calibration service, no item code, 1 unit at 350. Describe it as calibration on the pump." \
  add_order_line after_27

after_28() {
    need_po || return 1
    [ "$(q "SELECT status FROM orders WHERE order_id='$POID'")" = "SUBMITTED" ] ||
        { DETAIL="status is $(q "SELECT status FROM orders WHERE order_id='$POID'"), not SUBMITTED"; return 1; }
    sql_true "(SELECT version > 1 AND closed_at IS NULL FROM orders WHERE order_id='$POID')" ||
        { DETAIL="a write that did not move version, or a non-terminal status that stamped closed_at"; return 1; }
    sql_true "EXISTS (SELECT 1 FROM audit_log WHERE table_name='orders' AND action='UPDATE' AND row_pk->>'order_id'='$POID' AND occurred_at > now() - interval '10 minutes')" ||
        DETAIL="moved with no trail"
    true
}
case_run 28 transition_order "$SA" \
  "Submit purchase order $(q "SELECT order_number FROM orders WHERE order_id='$POID'") so the supplier has it. Reference $TS." \
  transition_order after_28

# THE refusal case, and the most important one in the plan. The claim being tested is not "the tool
# answers an error" - it is that the database cannot be told a warehouse did something it did not do.
# So the assertion is on the STATE after the turn: still SUBMITTED, and no movement naming the document.
#
# The call plane is optional here, and that is a decision rather than a looseness. Measured on the
# second run of this case, the agent read the order, read its lines, read its commitments, and then
# declined in one paragraph that named `receive_purchase_order` as the only door that produces
# RECEIVED - without calling `transition_order` at all. That answer is better than the one this case
# asked for: it spends no write attempt on a status it already knows is not writable, and it tells the
# human which door would move the state and what that door costs. Failing it for the absence of a
# SQLSTATE would be asserting the wrong thing. What the case will not accept is the state moving, and
# what it will not accept is a *reasonless* refusal - so the reason has to appear either in the door's
# observation (the call happened) or in the answer (the call did not), and `7_1`'s probe is where the
# door's own refusal is tested against the database rather than against a model.
after_29() {
    need_po || return 1
    [ "$(q "SELECT status FROM orders WHERE order_id='$POID'")" = "SUBMITTED" ] ||
        { DETAIL="the order became $(q "SELECT status FROM orders WHERE order_id='$POID'") - a stock consequence was written by typing, which is the failure 0028's register exists to stop"; return 1; }
    sql_true "NOT EXISTS (SELECT 1 FROM inventory_movements m WHERE m.reference_id='$POID')" ||
        { DETAIL="the status was refused and the stock moved anyway"; return 1; }
    if [ "$CALLPLANE" = door ]; then
        obs_has "$RID" transition_order "stock" || obs_has "$RID" transition_order "warehouse" ||
            obs_has "$RID" transition_order "receive" ||
            { DETAIL="refused correctly, but the door's reason never reached the trajectory row"; return 1; }
        return 0
    fi
    # Declined without asking: the answer itself has to carry the mechanism, because "no" without a
    # reason is a model's opinion and this case exists to show that the register is not one.
    printf '%s' "$REPLY" | grep -qiE 'receive_purchase_order|stock|movement|warehouse' ||
        { DETAIL="the state held and the agent declined, but never said why, which is a preference and not a rule"; return 1; }
    true
}
case_run 29 transition_refused "$SA" \
  "Purchase order $(q "SELECT order_number FROM orders WHERE order_id='$POID'") is late and I need it marked received so the dashboard is happy. Just set it to RECEIVED." \
  __either__transition_order after_29

after_30() {
    need_po || return 1
    obs_has "$RID" get_order_lines "IN-1003" || obs_has "$RID" get_order_lines "calibration" ||
        { DETAIL="the answer named neither line"; return 1; }
    [ "$(q "SELECT count(*) FROM vw_order_lines WHERE order_id='$POID' AND quantity_open > 0")" = "2" ] ||
        DETAIL="not both lines are still open"
    true
}
case_run 30 get_order_lines "$SA" \
  "Show me purchase order $(q "SELECT order_number FROM orders WHERE order_id='$POID'") line by line - what we ordered, what has arrived, what is left." \
  get_order_lines after_30

# 31's fixture: a commitment naming the PO's item LINE, made through the door that 0030 §5.5 grew for
# it. Made by SQL on purpose - the inventory agent's reserve tool is case 20 and this is not testing
# whether a model can ask for a reservation, it is testing whether the reconciliation view can tell
# attributed held stock from unattributed, which needs a line to point at.
if need_po; then
  LIN=$(q "SELECT order_line_id FROM vw_order_lines WHERE order_id='$POID' AND item_id IS NOT NULL LIMIT 1")
  ITEM=$(q "SELECT item_id FROM order_items WHERE order_line_id='$LIN'")
  "${DBQ[@]}" "SELECT reservation_id FROM reserve_inventory_for_order('$ITEM','$WHMAIN',2,'PURCHASE','$POID','tool_testplan $TS',NULL,NULL,'$LIN')" >/dev/null 2>&1
  echo "  fixture: 2 units committed against $POID line $(q "SELECT line_number FROM order_items WHERE order_line_id='$LIN'")"
fi
after_31() {
    need_po || return 1
    sql_true "(SELECT quantity_committed >= 2 AND quantity_unresolved >= 2 AND quantity_committed_unlinked = 0 FROM vw_order_commitments WHERE order_id='$POID' AND item_id IS NOT NULL)" ||
        { DETAIL="the held stock is not attributed to the line it was held for: $(q "SELECT coalesce(quantity_committed,0)||' committed, '||coalesce(quantity_committed_unlinked,0)||' unlinked' FROM vw_order_commitments WHERE order_id='$POID' LIMIT 1")"; return 1; }
    obs_has "$RID" get_order_commitments "$POID" || obs_has "$RID" get_order_commitments "PURCHASE" ||
        DETAIL="the answer did not carry the rows the view holds"
    true
}
case_run 31 get_order_commitments "$SA" \
  "What stock is committed against purchase order $(q "SELECT order_number FROM orders WHERE order_id='$POID'"), and does it agree with the movement ledger?" \
  get_order_commitments after_31

after_32() {
    need_po || return 1
    [ "$(q "SELECT status FROM orders WHERE order_id='$POID'")" = "RECEIVED" ] ||
        { DETAIL="still $(q "SELECT status FROM orders WHERE order_id='$POID'") after the receipt door ran"; return 1; }
    sql_true "EXISTS (SELECT 1 FROM inventory_movements m WHERE m.movement_type='RECEIPT' AND m.reference_id='$POID' AND m.reference_line_id IS NOT NULL)" ||
        { DETAIL="stock arrived with no ledger row naming the line - 0030 §1's whole point"; return 1; }
    sql_true "(SELECT bool_and(quantity_fulfilled = quantity) FROM order_items i WHERE i.order_id='$POID' AND i.item_id IS NOT NULL) AND (SELECT count(*) FROM order_items i WHERE i.order_id='$POID' AND i.item_id IS NOT NULL) > 0" || { DETAIL="the item line's counter did not move with its receipt"; return 1; }
    sql_true "(SELECT bool_and(quantity_fulfilled = quantity) FROM order_items i WHERE i.order_id='$POID' AND i.item_id IS NULL) AND (SELECT count(*) FROM order_items i WHERE i.order_id='$POID' AND i.item_id IS NULL) > 0" ||
        { DETAIL="the SERVICE line was left unfulfilled - a door that books no movement for a service still has to book it as delivered"; return 1; }
    # The reconciliation has to AGREE with itself afterwards, or the counters and the ledger are two
    # truths again, which is what the whole programme was for.
    [ "$(q "SELECT count(*) FROM vw_order_commitments WHERE order_id='$POID' AND ledger_agreement='DISAGREES'")" = "0" ] ||
        DETAIL="a line's counter and its ledger rows disagree after a door that writes both"
    true
}
case_run 32 receive_purchase_order "$SA" \
  "Purchase order $(q "SELECT order_number FROM orders WHERE order_id='$POID'") has arrived in full at the Main Warehouse. Book it." \
  receive_purchase_order after_32

# 33's fixture: a commitment with nothing settled, on a document of its own. Same reasoning as 31 -
# the case is the release door, and the release needs something to release.
RESID=""
if need_eid; then
  "${DBQ[@]}" "SELECT order_id FROM create_order('SALES',$EID,NULL,'$WHMAIN',NULL,'2026-12-20',NULL,'tool_testplan release fixture $TS','MANUAL',NULL)" >/dev/null 2>&1
  REL_ORD=$(q "SELECT order_id FROM vw_orders WHERE notes ILIKE '%release fixture $TS%' LIMIT 1")
  REL_LIN=$(q "SELECT order_line_id FROM add_order_line('$REL_ORD',(SELECT item_id FROM inventory_items WHERE sku='IN-1004'),NULL,5,40,NULL,'STANDARD','$WHMAIN',NULL,NULL,NULL,NULL)")
  RESID=$(q "SELECT reservation_id FROM reserve_inventory_for_order((SELECT item_id FROM inventory_items WHERE sku='IN-1004'),'$WHMAIN',5,'SALES','$REL_ORD','tool_testplan $TS',NULL,NULL,'$REL_LIN')")
  echo "  fixture: reservation $RESID holding 5 units for $REL_ORD"
fi
after_33() {
    [ -n "$RESID" ] || { DETAIL="the release fixture could not be made"; return 1; }
    sql_true "(SELECT cancelled_quantity >= 5 AND reserved_quantity - coalesce(shipped_quantity,0) - coalesce(cancelled_quantity,0) = 0 FROM inventory_reservations WHERE reservation_id='$RESID')" ||
        { DETAIL="still holding: $(q "SELECT coalesce(cancelled_quantity,0)||' of '||reserved_quantity||' cancelled' FROM inventory_reservations WHERE reservation_id='$RESID'")"; return 1; }
    sql_true "EXISTS (SELECT 1 FROM inventory_reservations WHERE reservation_id='$RESID')" ||
        { DETAIL="releasing a commitment deleted it - 0008's rule for a thing that cannot leave a trail"; return 1; }
    sql_true "(SELECT updated_at > created_at FROM inventory_reservations WHERE reservation_id='$RESID')" ||
        DETAIL="the settled commitment cannot say WHEN it settled (§4b's whole reason for existing)"
    true
}
# The reservation id is in the prompt rather than discovered, and that is a statement about the surface
# and not a shortcut: `vw_order_commitments` carries every fact about a commitment except its own row's
# key, so no read in any agent returns a reservation_id at all. Case 33 tests the door, which is what it
# is for; the discovery gap is a migration, named in agents/sales/README.md and in PLAN.md.
case_run 33 cancel_inventory_reservation "$SA" \
  "Release the stock held on reservation $RESID - the customer changed their mind about the order. Do not cancel the order itself." \
  cancel_inventory_reservation after_33

# 34's fixture, stated as SQL because the case is the ship door and nothing else: a SALES order with
# one item line, the stock committed against that line, and enough on hand to issue. Three prompts
# would make a failure here ambiguous.
SHIP_ORD=""
if need_eid; then
  "${DBQ[@]}" "SELECT order_id FROM create_order('SALES',$EID,NULL,'$WHMAIN',NULL,'2026-12-19',NULL,'tool_testplan ship fixture $TS','MANUAL',NULL)" >/dev/null 2>&1
  SHIP_ORD=$(q "SELECT order_id FROM vw_orders WHERE notes ILIKE '%ship fixture $TS%' LIMIT 1")
  SHIP_LIN=$(q "SELECT order_line_id FROM add_order_line('$SHIP_ORD',(SELECT item_id FROM inventory_items WHERE sku='IN-1001'),NULL,3,25,NULL,'STANDARD','$WHMAIN',NULL,NULL,NULL,NULL)")
  "${DBQ[@]}" "SELECT reservation_id FROM reserve_inventory_for_order((SELECT item_id FROM inventory_items WHERE sku='IN-1001'),'$WHMAIN',3,'SALES','$SHIP_ORD','tool_testplan $TS',NULL,NULL,'$SHIP_LIN')" >/dev/null 2>&1
  echo "  fixture: sales order $SHIP_ORD with 3 of IN-1001 committed to its line"
fi
after_34() {
    [ -n "$SHIP_ORD" ] || { DETAIL="the ship fixture could not be made"; return 1; }
    [ "$(q "SELECT status FROM orders WHERE order_id='$SHIP_ORD'")" = "SHIPPED" ] ||
        { DETAIL="status is $(q "SELECT status FROM orders WHERE order_id='$SHIP_ORD'") - the door answers SHIPPED or PICKING, and neither of those is what I see"; return 1; }
    sql_true "EXISTS (SELECT 1 FROM inventory_movements m WHERE m.movement_type='ISSUE' AND m.reference_id='$SHIP_ORD' AND m.reference_line_id IS NOT NULL)" ||
        { DETAIL="shipped with no ledger row naming the line"; return 1; }
    sql_true "EXISTS (SELECT 1 FROM inventory_reservations r WHERE r.order_id='$SHIP_ORD' AND coalesce(shipped_quantity,0) >= 3)" ||
        { DETAIL="the stock left but the commitment it was released from still says held - §5.2's settle step is what this asserts"; return 1; }
    sql_true "NOT EXISTS (SELECT 1 FROM vw_item_availability WHERE quantity_available < 0)" || DETAIL="the issue produced a negative bin"
    true
}
case_run 34 ship_sales_order "$SA" \
  "Ship sales order $(q "SELECT order_number FROM orders WHERE order_id='$SHIP_ORD'") from the Main Warehouse. Everything on it is packed." \
  ship_sales_order after_34

after_35() {
    LAST=$(q "SELECT run_id FROM agent_interactions WHERE bot_id='sales'
                AND human_input LIKE '<scheduled order housekeeping%'
              ORDER BY timestamp DESC LIMIT 1")
    [ -n "$LAST" ] || { DETAIL="no <scheduled order housekeeping...> trajectory row - the timer is not "
                              "armed, or it has never finished a tick (ORDERS_HOUSEKEEPING_INTERVAL_MINUTES, "
                              "and the boot log line that says what it armed itself with)"; return 1; }
    sql_true "(SELECT error_message IS NULL FROM agent_interactions WHERE run_id='$LAST')" ||
        { DETAIL="the tick failed: $(q "SELECT left(error_message,90) FROM agent_interactions WHERE run_id='$LAST'")"; return 1; }
    # 0031's acceptance, from the other side: a tick whose sweep was refused used to file this same
    # clean-looking sentence, so the assertion is on the sentence too and not only on error_message.
    # Both halves, because 0031's grant shows up in the sentence and not only in error_message. Matching
    # "collected" alone would pass on the failure form too - that sentence ends with the same word -
    # which is precisely how a keeper that could not collect anything looked kept.
    sql_true "(SELECT final_output NOT ILIKE '%CLAIM SWEEP FAILED%' AND final_output ILIKE '%expired collected%' FROM agent_interactions WHERE run_id='$LAST')" ||
        { DETAIL=$(q "SELECT left(final_output,120) FROM agent_interactions WHERE run_id='$LAST'"); return 1; }
    true
}
# ---------------------------------------------------------------------------
# the timers, and the cross-cutting invariants
# ---------------------------------------------------------------------------
echo "== case 21, cases 35-36 + cross-cutting =="
if sql_true "EXISTS (SELECT 1 FROM agent_interactions
        WHERE bot_id='inventory' AND human_input='<scheduled inventory check>'
          AND timestamp > now() - interval '40 minutes' AND error_message IS NULL)"; then
    verdict "case 21: scheduled check ran" 0 "a tick inside the last interval, recorded clean"
else
    verdict "case 21: scheduled check ran" 1 "no scheduled-check trajectory row in the last 40 minutes"
fi
case_run 35 orders_housekeeping "$SA" \
  "When did your scheduled housekeeping run last, and what did it find?" __schedule__ after_35

# The last of the twelve, and last for a reason: it is the only sales tool whose fixture belongs to
# another agent (case 2 raises Jane), so it cannot join the dependency chain above without making a
# purchase-order case wait on a customer-service one. What it asserts is that a FORK that copies a read
# still has to answer for it: get_customers is vw_customers through the same door the service agent
# reads, under this process's own row security, and a stale copy of that view's column list would show
# up here rather than in a README.
after_36() {
    need_eid || { DETAIL="case 2's customer is not there to read"; return 1; }
    obs_has "$RID" get_customers "$JANE" || { DETAIL="the answer did not name the customer the prompt asked about"; return 1; }
    sql_true "EXISTS (SELECT 1 FROM vw_customers WHERE id='$EID')" ||
        { DETAIL="the row it described is not in the view the tool reads"; return 1; }
    true
}
case_run 36 get_customers "$SA" \
  "Is Jane Doe $TS still an active customer on our side? I need the id, not just the name." \
  get_customers after_36

# ---------------------------------------------------------------------------
# case 37: three agents, one thread string, three conversations.
#
# Not a tool case, and the reason is the defect it exists for. `ids.Thread` hashed the caller's thread
# string alone, so with three backends on one namespace and one tenant - and every web UI posting the
# same thread string, the literal 'default' until 2026-11-08 - one thread named ONE conversation
# between all three. `pkg/agent`'s Rehydrate reads history by that id, and the sales agent answered
# "Hi" with "I'm the Inventory Control Agent" plus a shelf report it had never read: ten worked
# examples of another agent's voice, ahead of a correct system prompt. 0032 and the two-argument
# derivation fixed it; probe 4.9 watches the table. This is the case that watches what a person gets,
# because a green table and a wrong greeting are compatible, and only one of them is a defect nobody
# has to notice.
#
# Three planes, in the order that makes a failure legible: the call plane is that each turn filed a
# trajectory row (the cross-cutting checks below read RUNIDS, which chat() appended); the state plane
# is that the three conversation ids are pairwise distinct AND that none of them holds rows of two
# bots; the answer plane is that each reply names its own agent.
if want_case 37; then
    # The detector proves itself first, which is probe 4.9a's discipline applied here: plant one
    # conversation held by two agents inside a transaction that is discarded, and require the check to
    # see it. A green line from a query that cannot see its own subject is the false green this file
    # has now been caught printing twice - once through a phrase map, once through an unevaluated ||
    # arm - and a third time would be a habit.
    PLANT37=$("${DBQ[@]}" "BEGIN;
        INSERT INTO agent_interactions (conversation_id, run_id, bot_id, telegram_chat_id,
                                        \"timestamp\", human_input, final_output, tenant_id)
        VALUES ('00000000-0000-5000-8000-000000000371', '00000000-0000-4000-8000-000000003701',
                'inventory', 'planted-37', now(), '<planted 37>', 'x',
                        (SELECT tenant_id FROM tenants LIMIT 1)),
               ('00000000-0000-5000-8000-000000000371', '00000000-0000-4000-8000-000000003702',
                'sales', 'planted-37', now(), '<planted 37>', 'y',
                        (SELECT tenant_id FROM tenants LIMIT 1));
        SELECT CASE WHEN EXISTS (SELECT 1 FROM agent_interactions
                                  WHERE conversation_id = '00000000-0000-5000-8000-000000000371'
                                  GROUP BY conversation_id
                                 HAVING count(DISTINCT bot_id) > 1)
                    THEN 'seen' ELSE 'blind' END;
        ROLLBACK;" | tr -d '\r' | head -1)
    [ "$PLANT37" = seen ] || D37="case 37 cannot see a shared conversation even with one planted, so any verdict it reaches here is about nothing"
    T37="tp37_${TS}_${NOW}"
    D37=""
    SEEN=""
    CONV37=""
    for who in "customer_service|$CS" "inventory|$IV" "sales|$SA"; do
        bot="${who%%|*}"; base="${who#*|}"
        chat "$base" "$T37" "Who are you, in one line? Say which agent this is."
        if [ -z "$RID" ]; then D37="$bot filed no run_id (http $HTTP)"; break; fi
        conv=$(q "SELECT conversation_id FROM agent_interactions WHERE run_id='$RID'")
        if [ -z "$conv" ]; then D37="$bot's run $RID has no trajectory row to read a conversation from"; break; fi
        case "|$SEEN|" in *"|$conv|"*)
            D37="$bot and an earlier agent answered the same thread under one conversation id ($conv)"
            break ;;
        esac
        SEEN="$SEEN|$conv"
        CONV37="$CONV37'$conv',"
        # The word each agent has to use about itself. Deliberately a substring test on prose: an
        # answer that names the right agent in the wrong register still tells a human who they are
        # talking to, which is the whole of what this case is for.
        case "$bot" in
            customer_service) own='customer service' ;;
            inventory)        own='inventor' ;;
            sales)            own='sales|procurement' ;;
        esac
        if ! printf '%s' "$REPLY" | grep -qiE "$own"; then
            D37="$bot answered without naming itself ($(printf '%s' "$REPLY" | tr '\n' ' ' | cut -c1-90)...)"
            break
        fi
    done
    if [ -z "$D37" ] && [ -n "$CONV37" ]; then
        # The state plane, and the one that would have failed every day this server has been up:
        # no conversation these turns touched may hold another agent's turns.
        CONV37="${CONV37%,}"
        if ! sql_true "NOT EXISTS (SELECT 1 FROM agent_interactions
                           WHERE conversation_id IN ($CONV37)
                           GROUP BY conversation_id HAVING count(DISTINCT bot_id) > 1)"; then
            D37="a conversation this run started already belongs to two agents: $(q "SELECT string_agg(conversation_id||'='||(string_agg(DISTINCT bot_id, '+')), ', ') FROM agent_interactions WHERE conversation_id IN ($CONV37) GROUP BY conversation_id")"
        else
            DETAIL="3 agents, 1 thread string, $(printf '%s\n' "$SEEN" | tr -cd '|' | wc -c | tr -d ' ') distinct conversations"
            verdict "case 37: agent_conversation_identity" 0 "$DETAIL"
        fi
        [ -n "$D37" ] && verdict "case 37: agent_conversation_identity" 1 "$D37"
    else
        [ -n "$D37" ] && verdict "case 37: agent_conversation_identity" 1 "$D37"
    fi
else
    printf '  %-42s SKIP  filtered\n' "case 37: agent_conversation_identity"
fi

RUNIDS="${RUNIDS%,}"   # trim trailing comma for the IN lists
if [ -n "$RUNIDS" ] && [ -z "${CASE_FILTER:-}" ]; then
    want=$(( $(grep -o "'," <<< "$RUNIDS" | wc -l) + 1 ))
    # Counted against the number of run ids THIS invocation collected, not against a literal. The
    # literal this replaces said 15 when the plan had 21 cases, so the check passed for six cases'
    # worth of missing rows and would have passed for twenty more after the third agent landed.
    n_runs=0
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        n_runs=$(q "SELECT count(*) FROM agent_interactions WHERE run_id IN ($RUNIDS)")
        [ "${n_runs:-0}" -ge "$want" ] && break
        sleep 1     # the recorder's defer can land just after the response - see wait_for above
    done
    [ "${n_runs:-0}" -ge "$want" ] && verdict "trajectory: every case run has its row" 0 "$n_runs rows for the $want harness runs" \
        || verdict "trajectory: every case run has its row" 1 "only $n_runs of $want run_ids resolved to rows"

    bad=$(q "SELECT count(*) FROM vw_tool_calls WHERE run_id IN ($RUNIDS) AND NOT observations_aligned")
    [ "${bad:-1}" = "0" ] && verdict "observations align per step, all runs" 0 "actions_taken and tool_observations agree everywhere" \
        || verdict "observations align per step, all runs" 1 "$bad misaligned steps"

    bad=$(q "SELECT count(*) FROM vw_tool_calls WHERE run_id IN ($RUNIDS) AND run_errored")
    [ "${bad:-1}" = "0" ] && verdict "no harness run errored" 0 "every recorded turn finished" \
        || verdict "no harness run errored" 1 "an errored run among the harness rows"
fi

bad_chain=$(q "SELECT count(*) FROM audit_chain_verify() v WHERE NOT v.chain_ok")
[ "${bad_chain:-x}" = "0" ] && verdict "audit chain still intact after the writes" 0 "every segment valid" \
    || verdict "audit chain still intact after the writes" 1 "chain_ok=false somewhere (${bad_chain:-unreadable})"

echo
echo "  pass $PASS   fail $FAIL   (fixtures stamped $TS; inventory order $OUID, purchase order ${POID:-none})"
[ "$FAIL" = 0 ] || { echo "  failed: ${FAILED_CASES[*]}"; exit 1; }
