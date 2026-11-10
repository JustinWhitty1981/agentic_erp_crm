# Agent Tool Acceptance Plan

The question this answers, for **every tool all three deployed agents register**: when a human
prompts the agent through its real interface, does the right tool get called, and did the database end
up meaning what the agent's answer said? A test plan that only checks the prose verifies the model's
vocabulary; this one verifies the system.

Thirty-seven cases: fifteen for the customer service agent, six for the inventory agent (its five tools
and its timer), fifteen for the sales agent (its twelve tools, one of them asked twice because an item
line and a service line are different questions, one refusal, and its timer), and one whose subject is
the boundary between the three of them rather than any tool. Cases 1–15 are
`agents/customer_service/`, 16–21 are `agents/inventory/`, 22–36 are `agents/sales/`, and 37 is all
three of them answering the same thread string.
claim about coverage, and `case_run`'s "the run never called X" line is what keeps it one: a registered
tool with no case is a capability nobody has ever seen used through the interface it is advertised on.
Case 36 is last for that reason and not for tidiness — `get_customers` is the twelfth, and the block
that shipped before it had eleven.

Executable form: [`scripts/agents/tool_testplan.sh`](../../scripts/agents/tool_testplan.sh). Run it
with the stack up (`afpc-pg`, `afpc-customer-service`, `afpc-inventory-agent`, `afpc-sales-agent`). It
takes 15–40 minutes depending on the model server, prints one verdict line per case, and exits
non-zero if anything is not green. **The doc and the script are one artifact**: the cases below are the
script's cases, and the script header carries the same claim. Editing one without the other is
the drift this repository documents itself out of everywhere else.

## The verification discipline

Each case is asserted on three planes, and the planes are independent of each other:

1. **The call plane** — `vw_tool_calls` for the run: the named tool was actually invoked
   (`tool_name`), with arguments containing the fixture marker (`tool_input`), and the
   observation is an answer not an error (`observation_type`, `observations_aligned`). Three kinds of
   case exist in this plane, and the script names them in the tool argument so a reader of a case list
   sees which: a plain tool name (the call is required), `__either__TOOL` (the call is *optional*, and
   the state plane carries the assertion — case 29), and `__schedule__` (there is no call to make,
   because the subject is a timer; the state plane reads `agent_interactions` for the tick's row).
   The last two are recent, and one of them was a bug in the harness: the sentinel test was written as
   `[ "$tool" = "__none__" ] || … || $after`, which short-circuits, so on a sentinel case the after-fn
   never ran and the line printed "called `__schedule__`; state verified" about a state plane that had
   not been executed. An unevaluated `||` arm is a silent skip, and this is the same false green the
   paragraph below is about, arriving from the other direction: not an error hidden by phrase matching,
   but an assertion hidden by control flow.
2. **The state plane** — the tool's own SQL evidence: the view or table the tool claims to have
   read/written, queried directly. For reads, the fixture must be *findable* in the same view; for
   writes, the row's after-image plus its `audit_log` trail row.
3. **The trajectory plane** — the run's `agent_interactions` row exists, carries
   `response_sources` naming what a write touched (ADR-001's whole point), and agrees step for
   step with its observations.

The correlation key is the **`run_id`**, which `POST /api/chat` now returns on all three agents
(the field existed and `omitempty` silently blanked it — a turn that could not be tied back to
its own trajectory row made plane 1 impossible from the outside; fixing that is half of why this
plan could become a script).

And a rule about this harness itself: **a psql error inside a check surfaces on the case's line**
("harness SQL error: …"), never as a quiet false. The first draft earned a PASS-with-a-weird-
detail from a source check whose `= 1` sat outside its quoted predicate — the SQL was invalid,
`sql_true` read the empty result as "condition false", and a broken test looked exactly like a
honest one that happened to fail. The doc's own line for case 4 claimed sources were asserted;
they were not, until the stderr capture said so in words.
  The same class came back with the sales block, in a bigger way: twenty assertions there were written
  as `sql_true "SELECT count(*) FROM …"`, which expands to `SELECT 1 WHERE SELECT count(*) FROM …` — a
  syntax error, so every one of them would have reported a state-plane FAIL on a case whose agent had
  behaved correctly. Two things fixed it, and only the second one is durable: the call sites are now
  predicates (`EXISTS (…)`, `(SELECT …)`, and `bool_and` where the question is "every matching row" —
  `EXISTS` would have passed one good line beside nine bad ones, and a scalar subquery over several
  rows is an error, not an answer), and the contract is written on `sql_true` itself. The durable part
  is that a whole query in that argument is now *checkable without running the plan*: EXPLAIN every
  predicate with the fixture variables stubbed, which costs one round trip and is the only way to find
  a malformed assertion before the twenty-minute run does.

Two harness conventions worth knowing before reading the verdicts:

- **Fixture names carry a run stamp** (`$TS` = HHMMSS). `add_customer` dedupes on name *or* email
  ILIKE, so a plan that reused "Jane Doe" verbatim would have the second run's fixture refused as
  a duplicate of the first — a test plan that cannot be re-run is a demo. The prompts read
  "Jane Doe 114502" for the same reason the doors want exact names: substring ambiguity is the
  door's refusal feature, and a harness must not be accidentally on the wrong side of it.
  `CASE_FILTER=4 FIXTURE_TS=114502` re-runs one case against an old fixture — except case 2,
  whose re-run against an old stamp is refused by design; that refusal is `add_customer`'s own
  probe (`4_7`) territory, not this plan's.
- **Threads carry a per-invocation stamp, separate from the fixture stamp.** The first targeted
  re-run of case 4 proved why: with a reused thread, the turn rehydrated the *previous* run's
  conversation, and the agent answered "the record already reads 1235 Street" from history —
  while the database, restored by hand to 1234, said otherwise. Zero tool calls, confident prose,
  wrong about the present. The call plane caught it, which is the strongest argument in this
  document for why the prose is never the assertion.
- **Two cases assert refusals**, because the tools' failure modes are part of their contract and
  the refusal is deterministic where the search result would be someone else's uptime:
  `search_web` with no `TAVILY_API_KEY` answers "Tavily API key not configured" (an *answer*, not
  an error — the tool's documented degraded mode), and `scrape_url` against a private address
  answers "Scraping blocked by security policy" with `ALLOW_INTERNAL_SCRAPE=false`.

## customer_service agent (:4550)

| # | Case | Prompt (fixture-substituted) | Must call | Decisive assertion |
|---|------|------------------------------|-----------|--------------------|
| 1 | current_time | "What is today's date?" | `current_time` | observation contains the server's UTC date |
| 2 | add_customer | "Add new customer **Jane Doe $TS**, email jane.$TS@afpc.example.invalid, phone +1777$TS, 1234 Street, Austin, TX 78701." | `add_customer` | entities row + primary address `1234 Street`; INSERT trail; sources name `entities` |
| 3 | get_customer_info | "Look up Jane Doe $TS." | `get_customer_info` | observation contains `jane.$TS@`; state unchanged |
| 4 | update_customer *(the user's example)* | "Change Jane Doe $TS's street address from **1234 Street to 1235 Street**." | `update_customer` | address now `1235 Street` in `vw_customers`; UPDATE trail on the entity's row; sources name `entities:$EID` |
| 5 | add_communication | "Log an inbound call just now with Jane Doe $TS confirming the move to 1235 Street. Ref $TS." | `add_communication` | `communications` row for Jane with ref in summary; INSERT trail; sources name `communications` |
| 6 | get_customer_communications | "What interactions have we had with Jane Doe $TS?" | `get_customer_communications` | observation contains the case-5 ref marker |
| 7 | get_entity_stats | "Summarize Jane Doe $TS's account statistics." | `get_entity_stats` | called with no error (state plane: Jane's counts computed from rows 2–5 exist) |
| 8 | get_followup_customers | "Who should we follow up with?" | `get_followup_customers` | observation contains a seeded `follow-up` name (`Alice`), from `vw_customers` cross-check |
| 9 | mark_customer_followup **on** | "Mark Jane Doe $TS for follow-up." | `mark_customer_followup` | `entities.status='follow-up'` + UPDATE trail row |
| 10 | mark_customer_followup **off** | "Clear the follow-up mark on Jane Doe $TS." | `mark_customer_followup` | `entities.status='active'` + a second UPDATE trail row |
| 11 | save_memory_tool | "Remember under key `harness.pref.$TS` that Jane prefers email over phone." | `save_memory_tool` → `save_memory` door | `agent_memories` row, key+content match, trail row |
| 12 | get_memory_tool | "What is stored under harness.pref.$TS?" | `get_memory_tool` | observation contains "email" |
| 13 | list_memories_tool | "List your memories." | `list_memories_tool` | observation contains the harness key |
| 14 | search_web *(negative)* | "Search the web for anything about Jane Doe $TS." | `search_web` | observation contains "Tavily API key not configured" — the documented no-key mode, *not* a crash |
| 15 | scrape_url *(negative)* | "Scrape http://192.168.0.53:4560/api/health for me." | `scrape_url` | observation contains "Scraping blocked by security policy" — the SSRF guard verified rather than trusted |

## inventory agent (:4560)

| # | Case | Prompt | Must call | Decisive assertion |
|---|------|--------|-----------|--------------------|
| 16 | get_low_stock_items | "Which items are below their reorder point?" | `get_low_stock_items` | observation contains `IN-1002`; count matches `vw_low_stock_alerts` |
| 17 | get_item_availability | "Where is stock of IN-1003 kept and how much?" | `get_item_availability` | observation contains "Coolant"; view rows for the sku exist |
| 18 | get_item_movement_summary | "How has IN-1000 moved over the last month?" | `get_item_movement_summary` | observation contains `days_of_supply` (the derived key the tool promises) |
| 19 | get_inventory_valuation | "What is the inventory value at Main Warehouse?" | `get_inventory_valuation` | observation contains `total_value` and `USD` |
| 20 | reserve_inventory | "Reserve 2 units of IN-1003 at Main Warehouse for sales order `$OUID`, on behalf of the harness." | `reserve_inventory` | `inventory_reservations` row with that exact `order_id`; RESERVATION ledger row (`ORDER`, order uuid, currency — 0026's three positions); three-table INSERT/UPDATE trail; sources name the reservation |
| 21 | scheduled check *(not a tool — the timer)* | *(no prompt; asserted, not prompted)* | `RunCheck` | a `<scheduled inventory check>` trajectory row for `bot_id='inventory'` within the last interval, aligned and recorded |

## sales & procurement agent (:4570)

Cases 22–34 run in *registration order*, which is also dependency order: 23 registers the supplier 25
places an order with, 25 raises the document 26 lines and 28 transitions, 32 receives. A purchase order
that arrived already lined and submitted would have tested a fixture's read path rather than an agent's
write path, so a failure in a later case names the case to re-run. Two fixtures are built by SQL and say
so where they are built: the case under test is the door, and a failure made by three prompts would have
three possible causes.

| # | Case | Prompt (fixture-substituted) | Must call | Decisive assertion |
|---|------|------------------------------|-----------|--------------------|
| 22 | get_orders | "What orders do we have, and what state are they in? Tell me the numbers, not a summary." | `get_orders` | the observation names an `SO-` number or says `RESERVATION_BACKFILL` — on this server every existing document was raised by 0030's backfill, and "0 orders" beside 4 rows is the failure this asserts against |
| 23 | add_supplier | "Register a new supplier: Steelworks $TS, code SUP-$TS, NET30, 14 days lead time. They are not a customer, so create the party too." | `add_supplier` | `vw_suppliers` row whose `party_name` is the one given, `suppliers` INSERT trail row keyed by `supplier_id`, sources name the row |
| 24 | get_suppliers | "Who do we buy steel from, and on what terms?" | `get_suppliers` | observation contains the case-23 code |
| 25 | create_order | "Raise a purchase order to supplier SUP-$TS for the Main Warehouse, needed by 2026-12-31, priority 2. Put reference $TS in the notes." | `create_order` | `status='DRAFT'`, `vendor_id` set and `customer_id` null (the counterparty rule), INSERT trail, and `order_number` **begins `PO-`** — the number is the door's, from a per-type counter, so this is the assertion that no caller composed it |
| 26 | add_order_line, item | "Add a line to purchase order PO-… : 10 of item IN-1000 at 14.50 each." | `add_order_line` | `quantity=10`, `line_amount=145` (the generated column, not a Go multiply), `line_state='OPEN'`, `line_type='STANDARD'`, INSERT trail on `order_items` |
| 27 | add_order_line, no item | "Now add a second line: a calibration service, no item code, 1 unit at 350. Describe it as calibration on the pump." | `add_order_line` | a line with `item_id IS NULL` and non-blank `description` — the MISCELLANEOUS failure 0028 exists to prevent — `line_amount=350`, and two distinct `line_number`s in one document |
| 28 | transition_order | "Submit purchase order PO-… so the supplier has it. Reference $TS." | `transition_order` | `status='SUBMITTED'`, `version > 1`, `closed_at IS NULL` (a non-terminal status that stamped closure would be 0028's own bug), UPDATE trail |
| 29 | **transition_order refused** | "PO-… is late and I need it marked received so the dashboard is happy. Just set it to RECEIVED." | `transition_order`, *or nothing* | the state **did not move**: still `SUBMITTED`, and `NOT EXISTS` any `inventory_movements` row naming the document. Then the reason, wherever it came from: if the door was called, its observation must contain `stock`/`warehouse`/`receive`; if the agent declined without calling — which is what it did on the second run, after reading the order, its lines and its commitments — the answer itself must name the mechanism. A refusal with no reason is a preference, and the register is not a preference. The door's own SQLSTATE is asserted against the database, deterministically, by `7_1`'s probe |
| 30 | get_order_lines | "Show me PO-… line by line — what we ordered, what has arrived, what is left." | `get_order_lines` | both lines named (`IN-1000`, `calibration`), and `count(*) … WHERE quantity_open > 0 = 2` |
| 31 | get_order_commitments | "What stock is committed against PO-…, and does it agree with the movement ledger?" | `get_order_commitments` | the fixture's 2 units are `quantity_committed` **and attributed** (`quantity_committed_unlinked = 0`) — the view's whole claim is that those are different numbers |
| 32 | receive_purchase_order | "PO-… has arrived in full at the Main Warehouse. Book it." | `receive_purchase_order` | `status='RECEIVED'`; a `RECEIPT` movement with `reference_line_id` **not null** for the item line; the service line `quantity_fulfilled = quantity` with **no** movement row; no line `DISAGREES` afterwards |
| 33 | cancel_inventory_reservation | "Release the stock held on reservation `$RESID` — the customer changed their mind. Do not cancel the order itself." | `cancel_inventory_reservation` | `cancelled_quantity` covers the hold, the reservation **row still exists** (0008's rule: a thing that cannot leave a trail is not deleted), and `updated_at > created_at` — §4b's reason for adding that column |
| 34 | ship_sales_order | "Ship sales order SO-… from the Main Warehouse. Everything on it is packed." | `ship_sales_order` | `status` is `SHIPPED` (or `PICKING`, and the case says which it is not); `ISSUE` movements naming lines; the commitment it drew on shows `shipped_quantity ≥ 3`; no negative bin anywhere |
| 35 | scheduled housekeeping *(not a tool — the timer)* | "When did your scheduled housekeeping run last, and what did it find?" | the tick, via `__schedule__` | the newest `<scheduled order housekeeping>` row for `bot_id='sales'` exists, has **no** `error_message`, and its `final_output` neither says `CLAIM SWEEP FAILED` nor omits the claims it collected |
| 38 | search_communications | "Have any customers told us that a delivery arrived late or damaged? Search the recorded history by what the conversations were about, not by customer name." | `search_communications` | three planes, and the first one is not the call: `vw_embedding_status` must report a corpus with vectors in it, because an empty answer over an unsearchable column is the one failure this suite could otherwise score as a pass — which is the distinction 0035 §5's whole register exists to make. Then the observation names a row whose `summary` says late, and finally the door is asked the same question again from SQL — the vector of a row that really does say so, ranked now — and must still rank a row that says so. That last one is the case's claim that what the tool returned is what the index returns, rather than what the model remembered |
| 37 | **agent conversation identity** *(not a tool — the derivation)* | "Who are you, in one line? Say which agent this is." — the same prompt and the **same thread string** to all three agents | the state plane is the case: the three runs' `conversation_id`s are pairwise distinct, and none of those conversations holds rows of a second bot. The answer plane asks only that each reply names its own agent. It carries its own negative control, in the way probe 4.9a does: a shared conversation is planted inside a transaction that is discarded, and the check has to see it before its verdict on the real rows means anything |
| 36 | get_customers | "Is Jane Doe $TS still an active customer on our side? I need the id, not just the name." | `get_customers` | the observation names the customer case 2 raised, and the row is in `vw_customers` under this process's own row security — a fork that copied a read still has to answer for it |

Case 37 is a third reason, and a different kind of case: the other 36 ask whether a tool
works, and this one asks whether the process answering is the one that owns the tool. It exists because
of finding 4.9 (`docs/INTERACTION_LOGGING.md`) - the sales agent greeting a caller as the Inventory
Control agent, having been rehydrated with another agent's ten turns, because `ids.Thread` hashed the
thread string and nothing else. Every case above would have stayed green through that, and did: this
server ran three agents on one merged conversation for four days, and the trajectory table recorded it
faithfully in rows that no check was asking about. A tool plane cannot see an identity defect, so the
case has no tool.

Two of these - 29 and 35 - are the reason the block was worth adding to a plan that already passed.
Case 29 is the
programme's claim as one prompt: *a status that reports what a warehouse did cannot be typed*, asked in
the form a hurried human actually uses, and asserted on the state rather than on the apology. Case 35 is
the claim that a schedule runs, and it earned its keep in its first hour: the tick filed
`claims swept: 0 expired collected` beside an `error_message` of `42501`, which is how 0031 came to
exist and why the sentence now says `CLAIM SWEEP FAILED` when the sweep is refused.

## Cross-cutting assertions (after all cases)

- Every harness `run_id` has an `agent_interactions` row, `observations_aligned` everywhere on
  `vw_tool_calls` for those runs, and no `run_errored`.
- `audit_chain_verify()` — every chain segment still `t`.
- The write cases each added trail rows *counted*, not assumed: the script compares
  `max(audit_id)` before and after each write case and requires it to have moved, with the
  table's own row visible.

## How to read a failure

| Symptom | First suspect |
|---|---|
| call plane fails, state plane passes | the model answered from context/history instead of calling — prompt issue, not tool issue |
| call plane passes, state plane fails | the tool's door or view stopped meaning the contract — the probe family (`4_7`, `4_8`) is next to run |
| both pass, trajectory plane fails | the recorder — `pkg/logging`, ADR-001's half that is not a tool |
| case 20 only, INSUFFICIENT_STOCK | stock moved since the seed (the alert demo restocked IN-1002); reseed, don't reroute the assertion |
| case 20, "names document … no … order the caller can see" | the fixture order was not raised (its `create_order` call failed) — 0030's enforcement refuses a commitment against a uuid that names nothing, which is exactly the shape the harness used to plant |
| a sales case, "no purchase order carrying reference $TS" | case 25 did not land in this run; `CASE_FILTER=25` first, then the dependent cases in order |
| case 29 passes the call plane and fails the state plane | the worst result in this plan: the door wrote a stock consequence by hand. Check `order_lifecycle.stock_moving` for RECEIVED before checking the tool |
| case 32/34 pass, 31's `ledger_agreement` says DISAGREES | a door moved stock without raising its line's counter, or the reverse — the pair is the whole point of the programme, so this is a migration bug and not a test-fixture one |
| case 35, `CLAIM SWEEP FAILED` in the sentence | the grant, not the schedule: `has_function_privilege('afpc_app','idempotency_sweep(timestamptz)','EXECUTE')` is 0031's §4, and `verify.sh` B30 watches the same fact structurally |
| case 25, "warehouse_id is not a uuid", and nothing else in the chain runs | the prompt named a warehouse the way a human does, and the id was not readable until 2026-11-07 - `get_orders` selected `warehouse_name` and dropped `warehouse_id`, which the view has. Fixed in the projection; on a database with no documents the case still needs one raised by hand, which is `PLAN.md`'s `vw_warehouses` |
| case 25, "the run never called create_order", and the answer says *names but not ids* | the same gap seen from inside the turn rather than from the error: the agent read its way to a warehouse name, found no key beside it, and stopped. That is correct behaviour, and it is the shape `TestEveryDoorKeyIsReadableFromARead` was written for |
| a sales read tool fails whole with `42P18 could not determine data type of parameter $n` | a WHERE clause with nothing to bind contributed an argument. The rule is in `clauseFor` in each domain package's `args.go`; see `agents/sales/README.md`'s debugging item 5 |
| any case, and the agent answers as one of the other two | finding 4.9, and it is not a tool defect: `conversation_id` is read back as history, so if the derivation ever stops naming the agent the turns someone else's process filed become this one's voice. Case 37 is the check, and it carries its own planted failure so a green line cannot come from a blind query |

## Deliberately not in this plan

- **The four doors that are not tools.** `plan_work_order_operation`, `book_work_order_production`,
  `add_work_centre` and `execute_inventory_movement` are installed and probed in `db/tests/`, and
  `agents/sales/` registers none of them, so there is no prompt that could reach them. The reasons are
  in that agent's README ("What is not here") and they are different reasons: a work order's production
  needs routings that 0029 declined to invent, and free stock movement is a capability a monitoring or
  sales agent must not have because it can silence the alarms its own documents raise.
- Multi-turn *conversations* and ambiguous-name refusals: those are door behaviours asserted by
  `db/tests/` probes, which run them against the database directly and deterministically.
- Performance and scale ("10,000 products"): a load-plan question, not an acceptance one.
- Anything requiring the model to be *creative* (tone, summarisation quality): no SQL can verify
  those, so no honest test plan pretends to; the planes above verify everything truth-apt about
  a turn.
