# Agent First ERP CRM Development Plan

## 📚 Documentation Navigation

Before starting work, AI agents should review:
- **[AGENTS.md](AGENTS.md)** - Complete guide for navigating this project
- **[README.md](README.md)** - Project overview
- **[architecture.md](architecture.md)** - System architecture, and what the three deployed agents are
- **[db/MIGRATIONS.md](db/MIGRATIONS.md)** - the ledger of what the schema review found and which migration closed it
- **[docs/agent_requirements/agent_test_plan.md](docs/agent_requirements/agent_test_plan.md)** - how a tool is proven, which is how "done" is defined here

---

## Current Status

✅ **Blueprint complete** - `archive/blueprint/bot.py`, the pattern in one Python file — lineage since
   [ADR-006](ARCHITECTURE_DECISION_RECORDS/ADR-006_go_runtime_over_python_reference.md) made the Go
   backends the runtime
✅ **Three agents deployed** - `agents/customer_service/` (`:4550`, 15 tools and an hourly embedding keeper), `agents/inventory/` (`:4560`, 11 tools and a 30-minute check timer), `agents/sales/` (`:4570`, 18 tools and an hourly keeper)
✅ **Schema enforced, not documented-only** - 30 applied migrations; `./scripts/db/verify.sh` reports 39 structural checks green, `./scripts/db/test-functions.sh` runs 126 mapped cases against one probe per review finding, no residue
✅ **Orders in the schema, of all three kinds, and driven by an agent** - `0027`-`0031` landed 2026-11-07: `orders`/`order_items` for SALES, PURCHASE and WORK, suppliers as a party extension, a work order's operation plan, the four fulfilment doors that finally release what `0015` started holding, and the one grant that let the keeper keep. Behavioural probes inside those files, `verify.sh` 37/0, `test-functions.sh` closed with no residue, and a clean from-zero lineage rebuilt twice to prove the order of it. `agents/sales/` registers twelve of the surface, declines two doors with reasons in its README, and its first hour of ticks is what found 0031
✅ **The backends read a row as the database means it** - fixed 2026-11-07, in all three forks, and the
   fix was found only by an agent's own sentence disagreeing with a view. Two shapes: pgx hands a
   `numeric` column to Go as `pgtype.Numeric`, a struct that `encoding/json` renders perfectly and `%v`
   renders as `{300000 -4 false finite true}`, so a *sum* of one is zero - which is how the sales tick
   filed "0 units held unresolved" beside `vw_order_commitments`' 13 and how the inventory check printed
   struct fields in a line meant for a human; and `integer` is an **int32**, which `intArg` did not
   handle, so a claim sweep's own count printed 0 whatever it collected. Both are `json.Number` and full
   integer coverage now, with `TestTheTickAddsUpWhatTheViewAddsUpTo`,
   `TestIntArgReadsEveryIntegerTheDriverSends` and `TestNormaliseMakesNumericColumnsReadable` holding
   the three forks to it. Alongside them: a WHERE clause with nothing to bind must contribute no
   argument, or Postgres refuses the whole query (`42P18`) - `get_suppliers` failed 20 of its 28 calls
   on its **default** path, which is the reason one acceptance case could not find a supplier the
   previous case had registered.
✅ **A method that catches itself** - `scripts/agents/tool_testplan.sh` prompts every registered tool of all three agents through the real endpoint and verifies the answer against the database (25 verdicts green 2026-11-04, 40 since the third agent landed); `scripts/docs/check_agent_docs.sh` fails when a README describes a tool or a view that is not there
⚠️ **`_schema_graph` exists and holds zero rows** - measured, not inferred. The older prose in this repository calls it "a knowledge graph of the entire schema for AI agent understanding", which describes the superseded loader that would have filled it and not this database. The graph an agent can actually query is the `vw_*` set plus `vw_domain_vocabulary`, `vw_rls_status`, `vw_audit_coverage` and `vw_idempotency_status`, all four derived from the catalog rather than maintained by hand. The documentation sweep of 2026-11-04/05 is what found the claim, which is the argument for the checks over the graph

## Now: one closed defect, and the two things its closing found

### 1. Semantic search — **closed 2026-11-09**
- [x] The embedder question resolved itself rather than being answered. An endpoint that accepts an
      explicit `dimensions` argument emits exactly the 1536 the columns declare, at norm 1.000000, on a
      Matryoshka truncation of a wider model. Measured before any code was written, on four texts: a
      near-paraphrase pair scores 0.811 native and 0.816 truncated; two unrelated texts 0.380/0.234 and
      0.411/0.251. Nothing about the shape of the answer got worse, so no column was changed, no index
      was rebuilt, and the "or change the columns" branch of this bullet was never needed.
- [x] `0035_semantic_search`: `embed_communications` (fills gaps, never re-derives a value that is
      already there, takes a claim), `search_similar_communications` (the ANN read, with the horizon
      **inside** the top-k), `vw_unembedded_communications` (the queue, and the composition rule in SQL
      rather than in a client), `vw_embedding_status` (the register), `embedding_space` (which model
      filled the column). Grants in §6, seven behavioural probes in §7, B31 in `verify.sh`.
- [x] The backfill question was settled by the same measurement that settled the rest: 25 rows, which
      the keeper drains in 1.1 s. It is a timer and not a migration, which also disposes of the second
      half of the old bullet - no `UPDATE` in a file, so no lock on a table the agents are reading.
- [x] The tool and its case: `search_communications`, acceptance case 38, and probe block `7d` in
      `db/tests/4_7_cs_agent_surface.sql` with 14 mapped CASES rows.
- **The finding worth keeping is not "add an embedder".** It is that the blocker was described, in four
      pages and one column comment, as a fact about models ("no embedder produces 1536; measured 1024
      and 4096") when it was a fact about one absent endpoint - the same model answers 1536 when asked.
      A measurement stated without the question it was answering turns into a constraint nobody re-tests,
      and this one sat in a COMMENT ON COLUMN where it was the first thing a reader met.
- **And two things that were not knowable from the documentation.** The width is a request and not a
      contract: the same request answered `400 dimensions exceed embedding length 1024` and, an hour
      earlier, `200 OK` with 1024 floats. And a column holding two models' vectors is a silent
      corruption no index, constraint or structural check can see, because both are 1536 numbers long.
      Which is why the schema now remembers which model filled it and the write door refuses rather than
      mixes. Both are asserted in SQL, not in prose: `db/tests/4_7_cs_agent_surface.sql` 7d-g and 7d-d.

### 2. `idempotency_sweep`'s keeper — **closed 2026-11-07**, and it paid a toll
- [x] Called by a container's timer: `agents/sales`' `runHousekeeping`, `runInventoryCheck`'s shape, hourly, every tick a trajectory row.
- [x] The privilege it needed: 0011 had revoked `EXECUTE` from `afpc_app` on purpose ("collection is an operator action"), so the keeper's first tick filed a clean-looking `0 expired collected` beside a `42501`. **0031** is the grant, and it grants on a measurement rather than on a paragraph: two tenants, one expired claim each, one `in_flight` claim, `afpc_app` sweeping its own tenant and leaving the other two rows alone.
- [x] Asserted in `db/tests/`? It is asserted in `verify.sh`, which is where a grant belongs: **B30** requires `afpc_app` to be able to execute the sweep, `PUBLIC` not to be able to, the function still to be SECURITY INVOKER, `afpc_app` still to have no BYPASSRLS, and `idempotency_keys` still to be RLS-FORCED. Any one of those five going false is the grant changing meaning, and the last two are the premise 0031's §3 measured rather than argued.
- The lesson is not "add a timer". It is that **a policy with a keeper but no grant is still unkept**, and the two halves land in different files.

## Done: the third agent, which is what the orders schema was for

Built 2026-11-07, in the order this page asked for: the requirements page, then the schema, then the Go.

- [x] `docs/agent_requirements/sales/sales.md` first, naming the views and the doors - and then
      corrected, because the first version of it guessed at three things the catalog does not agree
      with: SALES has no `SUBMITTED` (that is a PURCHASE word), `ship_sales_order` answers `PICKING` as
      well as `SHIPPED`, and `add_supplier`'s currency is a column default, not a party's. Each is now
      what the doors say, with the measured SQLSTATE beside it.
- [x] `agents/customer_service/` forked to `agents/sales/` (`:4570`, `AGENT_ROLE=sales`, its own `.env`
      and compose project), `pkg/crm` replaced by `pkg/orders`, trajectory writer and memory store kept.
      The fork is the evidence for the claim in `architecture.md`: one domain package, four identity
      strings, one working third agent.
- [x] Twelve domain tools - five reads (`vw_orders`, `vw_order_lines`, `vw_order_commitments`,
      `vw_suppliers`, `vw_customers`) and seven doors (`create_order`, `add_order_line`,
      `transition_order`, `add_supplier`, `ship_sales_order`, `receive_purchase_order`,
      `cancel_inventory_reservation`), each claiming a key (ADR-005) and recording what it touched. Two
      installed doors are deliberately unregistered (`book_work_order_production`,
      `plan_work_order_operation`), and their reason is a routing that does not exist.
- [x] `db/tests/7_1_orders.sql`, CASES rows in `test-functions.sh`, cases 22-36 in the acceptance plan,
      and case 37 - three agents asked who they are, on one shared thread string, which is the
      acceptance half of finding 4.9 and the only plane on which a wrong greeting is a failure,
      and `check_agent_docs.sh` green.
- [x] The `idempotency_sweep` keeper - item 2, which needed a migration (0031) that nobody had planned.

What is left of the third-agent programme is not the agent: it is `book_work_order_production`'s missing
routings, the registry that would let three agents share a discovery surface, and the CAO that has no
process yet.

## Now, item 3: the two test directories that write to the database they test

`archive/blueprint/tests/` and `scripts/tests/` hold the same five ad-hoc scripts, and two of them
(`test_create_functions.py`, `test_update_function.py`) connect at import with `POSTGRES_DB` defaulting
to **`agent_first_erp_crm`** and run, on the success path, `DROP FUNCTION IF EXISTS
add_customer(...)` / `update_customer(...)` then a stub `CREATE FUNCTION` returning `TRUE, 1, 1,
'Test'` — committed. `pytest archive/blueprint/tests/` imports every module it collects, so the command this
repository's own `AGENTS.md` listed as harness four does that without running a single assertion first.

- [ ] Guard the module bodies with `if __name__ == "__main__":` or delete the two files (they recreate
      pre-`0016`/pre-`0021` bodies of doors the migrations own — there is nothing left for them to check)
- [ ] Default `POSTGRES_DB` to a name that cannot be the live database, so a mistake fails loudly
- [ ] Then re-point `AGENTS.md`'s harness list at whatever survives, and say in `scripts/tests/README.md`
      and `archive/blueprint/tests/README.md` what the run costs

Found by this sweep, not by a failure: the docs said "run these", and the code said what running them does.

## Next: the queued migrations (numbered, so they cannot be lost)

- [ ] **`vw_order_commitments.reservation_id`, or a `vw_reservations`** - the sharper of the two gaps
      the acceptance run found, and it is a schema gap rather than a Go one:
      `cancel_inventory_reservation` takes `reservation_id`, and **no view in this database returns
      one**, so the door `0030` built to release stuck stock can be reached by a human with psql and
      not by a conversation. `0030` added `order_line_id` to `inventory_reservations` so the
      reconciliation could be a query, and left the table's own key out of the answer - which is the
      difference between seeing that a line is held and being able to say *which hold* to end. The
      half that works: `reserve_inventory_for_order` answers `reservation_id`, so a hold an agent
      raised itself is nameable afterwards; the half that does not is every hold that predates it,
      including all of this server's `RESERVATION_BACKFILL` rows. The work is one column in a view
      that already joins to that row, its grant, a `7_1` probe, and case 33 re-prompted so the agent
      finds the id rather than being handed it.
- [ ] **`vw_warehouses`, and `get_warehouses` on it** - the same class, one notch smaller than it
      looked: the ids are readable from `get_orders` and `get_order_lines` now (they were not, until
      the projection was fixed on 2026-11-07), so what is left open is the empty database - an agent
      handed "the Main Warehouse" before any document names it has nothing to resolve it with. The
      door is a view over `warehouses` - tenant-coded, RLS-forced, and keyed
      `UNIQUE (tenant_id, warehouse_code)` already, so the work is a SELECT plus 0009's obligations
      rather than a new shape - and then one registered read in `pkg/orders`, its row in the agent's
      README, a `7_1` probe, and cases 25 and 26 re-run against a database with no documents in it.
      The alternative, coercing a code into an id in the Go layer, is declined on 0002's grounds:
      two ways to name one identity is how a wrong document gets written quietly, and it is why the
      `create_order` tool refuses `MAIN` before any SQL runs.
      These two now take **0033** and **0034**: 0032 went to finding 4.9's conversation re-key, which
      arrived first, and `db/migrations/` numbers by arrival and not by importance - 0026 is the record
      of what happens when a file takes a number that was another file's plan.

| Task | Finding | Shape of the work |
|---|---|---|
| `0024_partitioning` | 6.6 | Partition the append-only tables (`agent_interactions`, `audit_log`, `inventory_movements`) and put BRIN on the time columns. `0013` refers to this number four times in prose; read those as "the partitioning migration" |
| `0025_temporal_controls` | 6.6 | Soft delete / bitemporal columns on `contacts`, `addresses`, `communications`. Depends on 0008's delete-safety rules staying true afterward |

Both were planned as `0019`/`0020` and moved — see "Why the two planned migrations moved" in `db/MIGRATIONS.md`. Take the next free number, never a reused one: `migrate.sh` refuses a file at or below the highest applied.

## Then: the roles the swarm needs

### 3. A fourth agent, and the registry that would make the four of them more than copies
- [ ] Pick a domain whose tables already exist. The accounting side has `currencies` and `currency_rates`
      and no agent that speaks them; the orders side has `orders` now, which is what `agents/sales` was
      for. Write the requirement page first, in the register `docs/agent_requirements/sales/sales.md`
      uses - views and doors that exist, not tables that were reviewed.
- [ ] Fork `agents/customer_service/`, replace the domain package, keep the loop, the trajectory writer
      and the memory store. That sequence has been executed twice: the inventory fork is the smaller diff
      (one package, four identity strings) and the sales fork adds the self-recording timer. One thing the
      two forks did not catch, because it is not a diff: an identity string that is also *part of a key*.
      `AGENT_ROLE` names the process in `agent_interactions.bot_id` **and** half of `conversation_id`, so
      a fork that keeps its parent's role keeps its parent's conversations - finding 4.9, and the reason
      the recipe in `AGENTS.md` now says what `AGENT_ROLE` is loaded with.
- [ ] **Agent registry:** still open, and still not a table. Before one exists, "an agent" is a process
      with an `AGENT_ROLE`, a set of grants, a port and a README; the honest statement of the gap is that
      two of the three places an agent's identity has to reach are already keyed by it (the row trail's
      `bot_id`, the conversation derivation) and one is not. `agent_memories` has no agent column at all:
      17 keys today from three writers, namespaced by convention, including `warehouse.main.id` and
      `tools.get_orders.broken`, which read as facts about the deployment rather than as one process's
      notes. 4.9 is what a missing discriminator costs when the value is *read back* as history; memory
      is the same shape one store away, and the registry is the same decision one level up.
- [ ] `bot_actions` and `human_sessions`: either give them writers (a human console logs in; an action
      audit beyond the row trail) or say in `db/README.md` that they are vestigial.

### 4. The CAO and the escalation it would receive
- [ ] Requirement 7's routing half: detection exists (sentiment, `escalated` outcomes, `get_entity_stats`); there is nothing to route *to*. A second agent with a validation prompt over the same views is the whole architecture decision
- [ ] Validation rules worth having, in SQL first: the claim an agent made versus the row that resulted. `scripts/agents/tool_testplan.sh` does this per release; a CAO does it per turn
- [ ] Multi-step validation (pre-action, post-action, periodic) and anomaly detection — `vw_failed_interactions` and `vw_tool_performance` are the inputs that already exist

### 5. Finish the CRM's own loose ends
- [ ] **`followups` has no writer.** `add_communication` sets the flags on the interaction and deliberately creates no task row (0021 §5 hands the decision over); `vw_pending_followups` reads an empty table. Decide: a task door, or retire the view
- [ ] **T2:** whether `entity_type` gets a writer, which is the same decision as `vw_customers`' filter (`= 'customer'` vs `IN ('customer','prospect')`). `code:vw_customers_filter` is the marker; whoever lands it adds the `closed()` branch, or probe `4_5`'s row stays honestly open
- [ ] **`orders` and `products`**, which three other plans keep assuming: inventory reservations already carry an `order_id` with nothing behind it
- [ ] T3: two-backend idempotency assertion in CI - the measurement that closed 0011's question came from a shell one-liner

## Medium-term: the operational floor

- [ ] **Alerting:** the trajectory has failures in it and nobody reads it on a schedule. A monitor over `vw_failed_interactions` and `vw_low_stock_alerts` is the difference between "queryable" and "watched"
- [ ] `GET /api/interactions` is the agent reading its own trajectory; a dashboard is not on this plan and `architecture.md`'s "No Dashboards" is deliberate
- [ ] Connection pooling (`pgbouncer`), if two agents become five; the pool today is per-process and lazy
- [ ] Backup and restore rehearsal: `scripts/db/db backup` exists, a restored database has not been proven to run the agents
- [ ] Load: the requirements' "10,000 products" claim is a load-plan question, and the honest answer today is that the views are indexed for a few hundred

## Long-Term (Future)

- [ ] Multi-agent collaboration, and an agent that can hand a thread to another with its trajectory intact
- [ ] Predictive analytics over the accumulated trail (forecasting from `inventory_movements`, trend detection from `communications`)
- [ ] Security audit and penetration testing; the SSRF and masking guards are asserted by the acceptance plan, which is not the same as an external review

## Success Metrics

- **Acceptance:** every registered tool has a case in `docs/agent_requirements/agent_test_plan.md`, and the suite is green - a tool no prompt exercises is a tool whose contract nobody knows
- **Schema:** `verify.sh` 38 green, `test-functions.sh` reporting no REGRESSION and only documented KNOWN-OPEN rows, no residue
- **Reliability:** the inventory timer's ticks have no gaps in `agent_interactions`; a missing row is an outage, not a log search
- **Response Time:** under 30 seconds for a typical single-tool turn on the local model; the plan's runs are the measurement
- **Honesty:** `scripts/docs/check_agent_docs.sh` green, and no page claiming a capability the code does not have in this deployment. The 2026-11-09 pass is the test case for the rule in both directions: four pages and a column comment asserted semantic search was impossible, on the strength of a measurement that had stopped being true, and a fifth would now assert it works for every vector column when it works for one

---

*This plan follows the blueprint-first approach: prove the pattern works, then replicate it — and make each claim a check. Everything above marked "done" was verified by running something, not by writing about it.*
