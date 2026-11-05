# Agent Tool Acceptance Plan

The question this answers, for **every tool both deployed agents register**: when a human prompts
the agent through its real interface, does the right tool get called, and did the database end up
meaning what the agent's answer said? A test plan that only checks the prose verifies the model's
vocabulary; this one verifies the system.

Executable form: [`scripts/agents/tool_testplan.sh`](../../scripts/agents/tool_testplan.sh). Run it
with the stack up (`afpc-pg`, `afpc-customer-service`, `afpc-inventory-agent`). It takes 10–25
minutes depending on the model server, prints one verdict line per case, and exits non-zero if
anything is not green. **The doc and the script are one artifact**: the cases below are the
script's cases, and the script header carries the same claim. Editing one without the other is
the drift this repository documents itself out of everywhere else.

## The verification discipline

Each case is asserted on three planes, and the planes are independent of each other:

1. **The call plane** — `vw_tool_calls` for the run: the named tool was actually invoked
   (`tool_name`), with arguments containing the fixture marker (`tool_input`), and the
   observation is an answer not an error (`observation_type`, `observations_aligned`).
2. **The state plane** — the tool's own SQL evidence: the view or table the tool claims to have
   read/written, queried directly. For reads, the fixture must be *findable* in the same view; for
   writes, the row's after-image plus its `audit_log` trail row.
3. **The trajectory plane** — the run's `agent_interactions` row exists, carries
   `response_sources` naming what a write touched (ADR-001's whole point), and agrees step for
   step with its observations.

The correlation key is the **`run_id`**, which `POST /api/chat` now returns on both agents
(the field existed and `omitempty` silently blanked it — a turn that could not be tied back to
its own trajectory row made plane 1 impossible from the outside; fixing that is half of why this
plan could become a script).

And a rule about this harness itself: **a psql error inside a check surfaces on the case's line**
("harness SQL error: …"), never as a quiet false. The first draft earned a PASS-with-a-weird-
detail from a source check whose `= 1` sat outside its quoted predicate — the SQL was invalid,
`sql_true` read the empty result as "condition false", and a broken test looked exactly like a
honest one that happened to fail. The doc's own line for case 4 claimed sources were asserted;
they were not, until the stderr capture said so in words.

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

## Deliberately not in this plan

- Multi-turn *conversations* and ambiguous-name refusals: those are door behaviours asserted by
  `db/tests/` probes, which run them against the database directly and deterministically.
- Performance and scale ("10,000 products"): a load-plan question, not an acceptance one.
- Anything requiring the model to be *creative* (tone, summarisation quality): no SQL can verify
  those, so no honest test plan pretends to; the planes above verify everything truth-apt about
  a turn.
