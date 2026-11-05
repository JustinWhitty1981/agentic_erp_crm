# Agent First ERP CRM Development Plan

## 📚 Documentation Navigation

Before starting work, AI agents should review:
- **[AGENTS.md](AGENTS.md)** - Complete guide for navigating this project
- **[README.md](README.md)** - Project overview
- **[architecture.md](architecture.md)** - System architecture, and what the two deployed agents are
- **[db/MIGRATIONS.md](db/MIGRATIONS.md)** - the ledger of what the schema review found and which migration closed it
- **[docs/agent_requirements/agent_test_plan.md](docs/agent_requirements/agent_test_plan.md)** - how a tool is proven, which is how "done" is defined here

---

## Current Status

✅ **Blueprint complete** - `archive/blueprint/bot.py`, the pattern in one Python file — lineage since
   [ADR-006](ARCHITECTURE_DECISION_RECORDS/ADR-006_go_runtime_over_python_reference.md) made the Go
   backends the runtime
✅ **Two agents deployed** - `agents/customer_service/` (`:4550`, 14 tools) and `agents/inventory/` (`:4560`, 11 tools plus a 30-minute check timer)
✅ **Schema enforced, not documented-only** - 23 applied migrations; `./scripts/db/verify.sh` reports 37 structural checks green, `./scripts/db/test-functions.sh` runs one probe per review finding
✅ **A method that catches itself** - `scripts/agents/tool_testplan.sh` prompts every registered tool of both agents through the real endpoint and verifies the answer against the database (25 verdicts green, 2026-11-04); `scripts/docs/check_agent_docs.sh` fails when a README describes a tool or a view that is not there
⚠️ **`_schema_graph` exists** and is a knowledge graph of the schema; the documentation sweep of 2026-11-04/05 was the thing that actually caught drift, so treat the graph as an index, not as the source

## Now: the two known-open defects on the deployed surface

### 1. Semantic search is indexes without vectors
- [ ] Choose or build an embedder that emits the 1536 dimensions `communications.embedding` and `contacts.embedding` declare (measured: the local models answer 1024 and 4096) — or change the columns, which is a migration with a reindex in it
- [ ] Decide the backfill for existing rows, and who runs it: an `UPDATE` in a migration is a lock on a table the agents are reading
- [ ] Add the tool that reads them, and its case in `docs/agent_requirements/agent_test_plan.md`
- Blocked on: a model choice, not a code change. Requirement 1's "find customers who complained about shipping last week" stays unimplemented until then.

### 2. `idempotency_sweep` has no keeper
- [ ] Something must call it: a container's timer (the inventory agent's `RunCheck` is the working pattern), a cron entry, or the deployment's housekeeping phase
- [ ] Assert it in `db/tests/`: today the retention policy is a promise, and probe `6_1`'s §F already discovered the difference the hard way - it now sweeps to a baseline first, because an uncollected field makes an honest count into a false alarm
- Cheapest item on this page, and the one that keeps ADR-005's garbage-collection clause from being paper.

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

| Task | Finding | Shape of the work |
|---|---|---|
| `0024_partitioning` | 6.6 | Partition the append-only tables (`agent_interactions`, `audit_log`, `inventory_movements`) and put BRIN on the time columns. `0013` refers to this number four times in prose; read those as "the partitioning migration" |
| `0025_temporal_controls` | 6.6 | Soft delete / bitemporal columns on `contacts`, `addresses`, `communications`. Depends on 0008's delete-safety rules staying true afterward |

Both were planned as `0019`/`0020` and moved — see "Why the two planned migrations moved" in `db/MIGRATIONS.md`. Take the next free number, never a reused one: `migrate.sh` refuses a file at or below the highest applied.

## Then: the roles the swarm needs

### 3. A third agent, and the registry that would make it more than a copy
- [ ] Pick a domain whose tables already exist (the accounting side has `currencies` and `currency_rates`; sales does not have `orders` yet), write its requirement first in `docs/agent_requirements/<role>/<role>.md`, naming views and doors that exist
- [ ] Fork `agents/customer_service/`, replace `pkg/crm`, keep the loop, the trajectory writer and the memory store - that is the sequence the inventory agent proved in one working day
- [ ] **Agent registry:** still open, and still not a table. Before one exists, "an agent" is a process with an `AGENT_ROLE`, a set of grants, a port and a README; the honest first increment is `agent_interactions`-derived presence (`vw_agent_activity_summary` plus a heartbeat row) rather than a registry nobody keeps current
- [ ] `bot_actions` and `human_sessions`: either give them writers (a human console logs in; an action audit beyond the row trail) or say in `db/README.md` that they are vestigial. Two empty tables that documentation describes as live is how a debugger loses an afternoon

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
- **Schema:** `verify.sh` 37 green, `test-functions.sh` reporting no REGRESSION and only documented KNOWN-OPEN rows, no residue
- **Reliability:** the inventory timer's ticks have no gaps in `agent_interactions`; a missing row is an outage, not a log search
- **Response Time:** under 30 seconds for a typical single-tool turn on the local model; the plan's runs are the measurement
- **Honesty:** `scripts/docs/check_agent_docs.sh` green, and no page in this repository claiming semantic search works

---

*This plan follows the blueprint-first approach: prove the pattern works, then replicate it — and make each claim a check. Everything above marked "done" was verified by running something, not by writing about it.*
