# ADR-006: Go Runtime Instead of the Python Reference

**Status:** Accepted
**Date:** November 2026
**Authors:** Agent First ERP CRM Team

---

## Context

The pattern started in Python, and it was the right call at the time: `archive/blueprint/bot.py` is ~215 lines
that hold config, eight tools, the agent, memory, and a Telegram handler in one readable file. It proved
the thesis - an agent that reads views, calls doors, and files its own trajectory is a *small* program -
and the whole design of this repository still descends from reading it.

Two deployed agents later, none of them run Python. The reason is not that Python is a poor language for
models and glue; it is that the shape of this workload - a long-lived service whose every turn does
network I/O against one Postgres, serves a browser over SSE, and must be restartable without amnesia -
hits four specific properties of the reference implementation, each measurable in the source rather than
argued.

## The four measurements

### 1. A connection per tool call, and none of them encrypted

`archive/blueprint/tools/*.py` opens its own database connection every time a tool runs: ten `conn =
get_db_connection()` sites and ten matching `conn.close()` calls across the eight modules, each one a
fresh `psycopg2.connect(**DB_CONFIG)` (`customer_lookup.py:22-28`). A three-tool turn is three
TCP handshakes, three authentications, three teardowns - and `grep sslmode archive/blueprint/` returns nothing,
so every one of those connections is plaintext to a server whose documented contract is
`sslmode=verify-full` against a CA with IP SANs. The reference predates the TLS work; the schema did not
stay behind.

The Go agents hold one `pgxpool` per process. `pkg/db/pg.go` sets `cfg.AfterConnect` to
`SELECT set_config('app.tenant_id', $1, false)` so the tenant is a property of the *connection* rather
than of the statement, and it is `set_config(..., false)` - not the transaction-local form - precisely
because `AfterConnect` runs outside any transaction and a transaction-scoped setting would evaporate
before the pool handed the connection to the query that needed it. Right now, on this server, both
agents are sitting on **one idle connection each** (`pg_stat_activity`), holding the tenant they claimed
at connect, doing zero work.

### 2. The event loop, the GIL, and where blocking goes

`bot.py` is an `async def handle_message` that calls `loop.run_in_executor(None, lambda:
agent.invoke(...))` (line 167-169) - the default thread pool, chosen because LangChain's tool calls are
synchronous psycopg2 inside an asyncio handler. So the concurrency story is: Python threads running
blocking database calls under a Global Interpreter Lock, in a process started by
`application.run_polling()` - one worker, one Telegram update queue, no way to serve a second one without
two processes and a shared-nothing checkpointer (see 3).

`net/http` gives the Go agents a goroutine per request for free, and `pgx` waits on the socket rather
than on a lock: a turn parked on Postgres costs ~4 KB of stack and no interpreter time, which is the
difference between "how many conversations can this box hold open" being a design question and being a
scheduling accident. The SSE endpoint is the same story - `streamHandler` flushes tokens as they arrive,
and the loop's `RunChatStream` fans out on a channel; the Python path has no equivalent because its
transport is a polled bot API, not a connection it owns.

### 3. Memory that dies with the process

`checkpointer = InMemorySaver()` (`bot.py:119`) means conversation state lives in one Python object. A
restart is amnesia; a second replica is a second, divergent memory; and nothing in the database knows
what the agent remembered mid-conversation. The requirements page still describes this as the design, and
it was - for a demo.

This is the reason `0023_agent_memory` exists, and why the Go agents have `MEMORY_DRIVER=db` (with
`file` retained only as an explicit, labelled fallback), and why a cold `thread_id` triggers
`Rehydrate`, which reads the thread's last turns back out of `vw_recent_interactions` keyed by a UUIDv5
of the thread id (`pkg/ids`) so **any** replica resolves the same conversation id. Two consequences worth
naming: the reference cannot horizontally scale, because scaling out multiplies its memories; and the
reference cannot be debugged after the fact, because the state a support question is about no longer
exists.

### 4. One binary, one surface, ten times the tools

The blueprint registers eight tools; `agents/customer_service/` registers fourteen and
`agents/inventory/` eleven, because a Go tool is a struct literal in a registry with a policy attached
(`ReadOnly`, `RequiresApproval`), so the shared six - clock, two web tools, three memory tools - are
*one package both agents import*, not eight copies of a `@tool` function. The registry is what
`GET /api/tools` answers from and what `scripts/docs/check_agent_docs.sh` diffs the README against; a
Python function has no comparable handle to inspect at runtime without importing it, which is the trap
`archive/blueprint/tests/` fell into: pytest imports modules, those modules connect and run DDL at import, and a
documentation page reported fifteen green tests that had actually just replaced two of the doors.

## Decision

**The Go backends in `agents/*/backend_go/` are the runtime. `archive/blueprint/` is lineage.**

- New agents are forked from `agents/customer_service/` and their domain package replaces `pkg/crm`. The
  inventory agent is the proof: `pkg/inventory` plus a prompt plus a timer, and the loop, pool, memory
  store and trajectory writer came along untouched.
- The blueprint stays in the repository — since 2026-11-05 archived as `archive/blueprint/`, a directory
  nothing runs and nothing is added to — because it is the shortest statement of the pattern in
  existence and because three harnesses still read its files: `code:tool_prefix` greps
  `archive/blueprint/**/*.py`, `code:cs_writes_through_doors` greps it for caller-side `INSERT`s, and
  `code:agent_docs_match_surface` compares `archive/blueprint/docs/views.md`'s column lists against
  `pg_attribute`. Deleting the directory would break checks that guard the deployed code.
- Where a page says "the same rules in one Python file," read it as the pattern's statement, not as a
  route. The on-ramp for a new agent is `agents/customer_service/backend_go/pkg/agent/agent.go`.

## Consequences

### Positive
- One connection pool, one tenant claim per connection, TLS `verify-full` on the data path - the security
  story the schema enforces and the runtime no longer undermines.
- Concurrency is a property of the runtime, not of how many bots a host can run.
- Memory and history survive restarts and are shared across replicas, because both live in Postgres.
- The trajectory is written by the loop's `defer`, so a run that panics or is cancelled still files its
  row - which is what makes the acceptance harness's three-plane verification possible at all.
- A new agent is a domain package and a README, not a re-derivation of the loop.

### Negative
- **The reference implementation cannot be copied any more.** A reader who follows `archive/blueprint/`'s setup
  gets a plaintext connection, an in-memory memory, and no trajectory row - correct pattern, wrong
  substrate. Every page that used to say "start by reading bot.py" now says what it is for: the pattern,
  once, in one file.
- Two implementations, one vocabulary. `add_customer` the stored function is the real contract; the
  Python wrapper around it is documentation that can rot, and has - twice, both times in
  `archive/blueprint/docs/`, whose phantom function names this sweep removed.
- The blueprint's own tests are inert (`archive/blueprint/tests/README.md` explains why nothing runs them), so
  the Python half has no regression net. Its guarantees are checked in SQL instead, where they live.
- Go raises the floor for a contribution: a reader who knows Python now has to read a router, a pool and
  a struct registry. The mitigation is that the file to read is one package deep, and `pkg/agent` is a
  loop with comments about why it is shaped that way.

### Neutral, but worth writing down
- "Python can't scale like Go" is the one-sentence version. The accurate version is the four
  measurements above - per-call connects, a thread pool under a GIL around blocking I/O, an in-process
  checkpointer, and a single polling worker - and each is fixable in Python in principle. Nobody is going
  to fix them, because the version that is already fixed is the one running on `:4550` and `:4560`.

## Verification

| Claim | Check |
|---|---|
| Pool, not per-call connects | `pg_stat_activity` grouped by `application_name` answers one row per agent at rest; `customer-service-agent` and `inventory-agent` are the two `AFPC_PG_APPNAME` values |
| Tenant on connect | `cfg.AfterConnect` in `pkg/db/pg.go`, and B-checks in `scripts/db/verify.sh` for the policies that read it |
| Memory in the database | `MEMORY_DRIVER` in `/api/health`; `agent_memories` rows; `db/tests/4_7_cs_agent_surface.sql` |
| Rehydration across restarts | `Rehydrate` reads `vw_recent_interactions`; `docker restart afpc-customer-service` then asking the same `thread_id` a follow-up question |
| Both agents registered and answering | `./scripts/agents/tool_testplan.sh` - 21 cases, 25 verdicts |
| The blueprint is inert, not load-bearing | `curl localhost:4550/api/tools` and `:4560` enumerate everything that ships; no `bot.py` process runs on this host |

## References
- Upstream lineage: `agents/jada/docs/enhancements/backend_go_migration_plan_w_benefits.md` — the JADA
  drop this loop descends from made the same switch (FastAPI + LangChain → Go) for the same class of
  reasons, with its own numbers: ~1.2 GB container memory down to ~100–150 MB, ~3–5 s import startup
  down to ~10 ms, goroutine SSE replacing a GIL-bound executor. Those are the upstream document's
  claims, not measurements from this server; the four above are.
- ADR-002 (database-first: the reason memory had to leave the process), ADR-003 (view-based reads, which
  is the rule both implementations obey), ADR-004 (agent-first interface: the chat surface the SSE
  endpoint implements)
- `docs/agent_requirements/customer_service/customer_service.md` - the requirement the Go agent meets
- `agents/customer_service/README.md`, `agents/inventory/README.md` - the runtimes
- `archive/blueprint/README.md`, `archive/blueprint/AGENT_SUMMARY.md` - the pattern, with its banner
