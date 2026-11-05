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
# plan that cannot be re-run is a demo. Expect 10-25 minutes: every case is a real turn through a
# real model, which is the only way to test what a human would experience.

set -u
CS=http://127.0.0.1:4550
IV=http://127.0.0.1:4560
DBQ=(docker exec -i afpc-pg psql -U postgres -d agent_first_erp_crm -tAF'|' -c)

TS=${FIXTURE_TS:-$(date +%H%M%S)}   # set FIXTURE_TS=<stamp> with CASE_FILTER to re-run one case
                                    # against an earlier run's fixture, rather than all 21 again
JANE="Jane Doe $TS"
EMAIL="jane.$TS@afpc.example.invalid"
PHONE="+1777$TS"
MKEY="harness.pref.$TS"
OUID=$(cat /proc/sys/kernel/random/uuid)
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
    if ! tool_called "$RID" "$tool"; then
        verdict "case $n: $name" 1 "the run never called $tool (http $HTTP)${QERRS:+ | $QERRS}"
        return
    fi
    DETAIL=""
    if [ "$tool" = "__none__" ] || $after; then
        verdict "case $n: $name" 0 "${DETAIL:-called $tool; state verified}"
    else
        verdict "case $n: $name" 1 "${DETAIL:-the database disagrees with the answer}${QERRS:+ | harness SQL error: $QERRS}"
    fi
}

echo "== 0 preflight: both agents up with their tools =="
for pair in "$CS crm_tools" "$IV inventory_tools"; do
    set -- $pair
    if ! curl -sf -m 5 "$1/api/health" | jq -e ".$2 > 0" >/dev/null; then
        echo "  ABORT: $1 reports no $2 - the acceptance plan cannot judge tools that are not registered"; exit 2
    fi
done
echo "  both surfaces registered (crm_tools, inventory_tools > 0)"

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
    true
}
case_run 20 reserve_inventory "$IV" \
  "Reserve 2 units of IN-1003 (Coolant 5L Jerrican) at the Main Warehouse for sales order $OUID, on behalf of the harness. Look up the item and warehouse ids with the read tools first." \
  reserve_inventory after_20

# ---------------------------------------------------------------------------
# the timer, and the cross-cutting invariants
# ---------------------------------------------------------------------------
echo "== case 21 + cross-cutting =="
if sql_true "EXISTS (SELECT 1 FROM agent_interactions
        WHERE bot_id='inventory' AND human_input='<scheduled inventory check>'
          AND timestamp > now() - interval '40 minutes' AND error_message IS NULL)"; then
    verdict "case 21: scheduled check ran" 0 "a tick inside the last interval, recorded clean"
else
    verdict "case 21: scheduled check ran" 1 "no scheduled-check trajectory row in the last 40 minutes"
fi

RUNIDS="${RUNIDS%,}"   # trim trailing comma for the IN lists
if [ -n "$RUNIDS" ] && [ -z "${CASE_FILTER:-}" ]; then
    n_runs=$(q "SELECT count(*) FROM agent_interactions WHERE run_id IN ($RUNIDS)")
    want=$(( $(grep -o "'," <<< "$RUNIDS" | wc -l) + 1 ))
    [ "$n_runs" -ge 15 ] && verdict "trajectory: every case run has its row" 0 "$n_runs rows for the harness runs" \
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
echo "  pass $PASS   fail $FAIL   (fixtures stamped $TS; order id $OUID)"
[ "$FAIL" = 0 ] || { echo "  failed: ${FAILED_CASES[*]}"; exit 1; }
