# Customer Service Agent

The deployed customer service agent for Agent First ERP CRM: a Go backend, a React UI, and the
database's own functions behind every write. It is the reference implementation in `agents/jada`
rebuilt for this schema — same loop, same streaming, different surface.

Two things distinguish it from the reference drop, and both are the point of the directory:

- **The CRM is a tool surface, not a prompt.** Eleven of the fourteen registered tools touch Postgres:
  the eight CRM tools - four reading the `vw_*` views the schema publishes for agents (ADR-003), four
  calling stored functions - and the three memory tools over `agent_memories`. The other three (a clock,
  Tavily, and a guarded HTTP fetch) answer locally. No tool composes SQL against `entities` or
  `communications`, which is the rule 0021 put a scoreboard marker on.
- **Memory, history, and the trail live in the database.** What the agent was told to remember is
  rows in `agent_memories` (0023), not files in a container directory. What it said is a row in
  `agent_interactions`, and it is read back after a restart rather than lost with the process.

---

## Tools

The model's only documentation of what it can do. The descriptions in the source are longer than the
ones in this table — they carry the refusals — and `scripts/docs/check_agent_docs.sh` fails if a tool
appears here and not in the code, or in the code and not here.

| Tool | Reads / writes | What it is for |
|---|---|---|
| `get_customer_info` | read | Look up customers by name, email, phone, or id. One selector at a time. |
| `get_customer_communications` | read | One customer's recent interactions, newest first, with outcome and sentiment. |
| `get_entity_stats` | read | Per-customer counts: resolved, pending, escalated, sentiment, first and last contact. |
| `get_followup_customers` | read | Who needs contact, and which of the three reasons says so. |
| `add_customer` | write | Create an entity, a contact, their relationship, and an address. |
| `update_customer` | write | Change the fields of an existing customer, selected by name plus a contact point. |
| `add_communication` | write | Log one interaction. The only door that writes to `communications`. |
| `mark_customer_followup` | write | Set or clear the follow-up mark on a customer's status. |
| `save_memory_tool` | write | Append one fact under one key, into `agent_memories`. |
| `get_memory_tool` | read | A key's entries, newest first. |
| `list_memories_tool` | read | Every key, with how many entries each holds. |
| `current_time` | local | UTC and the container's local time, **each with its weekday named**, plus the local ISO week number. It exists because "next Tuesday" is not answerable from a date: a live turn that had to compute the weekday stored a Monday and told the customer Tuesday, and the row is what the follow-up list acts on. |
| `search_web` | local | Tavily search. Registered always; refuses without `TAVILY_API_KEY`. |
| `scrape_url` | local | One HTTP GET, read into text. Refuses private addresses unless `ALLOW_INTERNAL_SCRAPE` says otherwise. |

Two properties are worth knowing before you change the surface:

- **The write tools deduplicate a retry inside one run.** `add_customer`, `add_communication`, and
  `save_memory_tool` send an idempotency key derived from the run and the arguments they resolved
  (`pkg/ids`). A model that reissues a call after a timeout gets the first call's answer instead of a
  second row. Across runs the keys differ, because two conversations that mention the same customer
  are two events. See `ARCHITECTURE_DECISION_RECORDS/ADR-005`.
- **`agent_id` and `bot_id` come from `AGENT_ROLE`, not from a tool argument.** The audit columns are
  what make "which agent did this" answerable, and a value the model can type is a value the model can
  be asked to type.

## Environment

Every key the process reads. The ones with no default are the ones that change behaviour by being
absent, which is worth knowing when a deployment "works differently" on another machine.

### Database

| Variable | Default | Meaning |
|---|---|---|
| `AFPC_PG_HOST` | *(required — compose refuses without it)* | Host to connect to, and the reason there is no default: **it must be an IP the leaf certificate lists in its `subjectAltNames`**, which is a fact about whichever machine provisioned it. `scripts/db/init.sh` writes it to `agents/customer_service/.env` (gitignored) for exactly this reason, and `docker exec afpc-pg openssl x509 -in /certs/server.crt -noout -ext subjectAltName` reads the whole list off the running server. A hostname fails `verify-full`. |
| `AFPC_PG_PORT` | `5432` | |
| `AFPC_PG_DB` | `agent_first_erp_crm` | |
| `AFPC_PG_USER` | `afpc_app` | The runtime role. Read-only roles cannot write, and the tools would fail at the grant. |
| `AFPC_PG_PASSWORD` | *(required)* | Never defaulted, never logged. `AFPC_APP_PASSWORD` is accepted as the same credential, because that is the name `dev/.env` and `scripts/db/roles.sql` use; the first non-empty of the two wins, and `pkg/db`'s `resolvePassword` says why a compose line cannot do that translation. |
| `AFPC_TENANT_ID` | *(required)* | The tenant every connection claims. Refusing to start without it is deliberate: the server-side fallback is a real tenant, and not necessarily the intended one (review 2.3). |
| `AFPC_PG_SSLMODE` | `verify-full` | `require` encrypts without checking the name; `verify-ca` checks the chain but not the name, which is the mode that works when the host is reached through a name that is not in the certificate. |
| `AFPC_PG_SSLROOTCERT` | *(unset)* | The CA. Required by both `verify-*` modes. The container mounts `dev/tls/afpc-ca.crt` at `/etc/ssl/certs/afpc-ca.crt`. |
| `AFPC_PG_APPNAME` | `customer-service-agent` | What appears in `pg_stat_activity`, and the name to grep when the question is "which process wrote this". It is a label and not a credential, so it is safe to see in the log line the pool prints. |

The pool is lazy, but startup is not one shot: `connect()` pings and, on refusal, retries with
backoff for up to fifteen seconds before deciding the database is not there. The window is for the
host reboot — the agent and `afpc-pg` are separate compose projects, nothing orders them, and on
2026-11-04 the first dial landed 450ms before postgres logged itself ready. A database that stays
down does not stop the process; it leaves the CRM tools unregistered, and the difference between the
two ways that happens is visible in `/api/health`: `not configured` (200 — the file-backed mode of a
machine that has no database, chosen rather than broken) versus `configured but never connected`
(503 — the same environment's database refusing, which is what a monitor should page on).

### Model

| Variable | Default | Meaning |
|---|---|---|
| `LLM_PROVIDER` | `local` | `local` for an OpenAI-compatible endpoint; `azure_gcc_high` for Azure. |
| `VLLM_BASE_URL` | `http://192.168.0.42:18300/v1` | |
| `VLLM_MODEL` | `qwen3.8-flash-next` | |
| `LLM_STREAM` | `true` | Set to `false` behind a proxy that buffers SSE — with buffering on, a streaming turn hangs for the whole timeout. |
| `AZURE_OPENAI_API_KEY`, `AZURE_OPENAI_ENDPOINT`, `AZURE_OPENAI_API_VERSION`, `AZURE_OPENAI_BASE`, `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_DEPLOYMENT_NAME`, `SEGMENT`, `ENVIRONMENT` | *(Azure only)* | Read on the `azure_gcc_high` path. The reference implementation's defaults name its own deployment; this one does not deploy there. `AZURE_OPENAI_BASE` overrides the authority the OAuth token request is sent to, which is the knob for a sovereign cloud that is not `azure.us`. |

### Inherited from the reference, and inert here

Four groups the code reads and this deployment does not use. They are listed because the checker
treats "a key the code reads" as something a human must be able to find the meaning of, and because an
undocumented knob that is *off* is indistinguishable from one that is broken.

| Variable | Default | Meaning |
|---|---|---|
| `HIGHBYTE_MCP_ENABLED` | *(unset — enabled)* | The HighByte MCP client's own switch: `false`, `0` or `no` skips the session and registers no remote tools. Unset means *try*, which is why the other three need no value here. |
| `HIGHBYTE_MCP_URL` | `https://your-mcp-server:8885/mcp` | The MCP endpoint. The default is a placeholder from the reference implementation, so an empty session failure at startup is expected on this machine. |
| `HIGHBYTE_MCP_BEARER_TOKEN`, `MCP_BEARER_TOKEN` | *(unset)* | The token for that endpoint. The first name wins; `MCP_BEARER_TOKEN` is the older spelling the reference kept as a fallback. |
| `SSL_CERT_FILE` | the image's bundle | The trust store for outbound HTTPS, including the model server's TLS if it ever has any. Set in the Dockerfile, not in compose. The database ignores it: it has `AFPC_PG_SSLROOTCERT`. |
| `TAVILY_API_KEY`, `ALLOW_INTERNAL_SCRAPE`, `MAX_SCRAPE_BYTES` | *(unset)*, `false`, `2097152` | `search_web` and `scrape_url`. `MAX_SCRAPE_BYTES` caps the read, and a value that does not parse falls back to 2MB rather than to zero, so a typo gives the default instead of an empty document. |

### Behaviour

| Variable | Default | Meaning |
|---|---|---|
| `AGENT_ROLE` | `customer_service` | `communications.agent_id`, `agent_interactions.bot_id`, and the escalation label. |
| `LOG_LEVEL` | `info` | `debug` logs every tool call's arguments, masked. |
| `LOG_FORMAT` | `text` | `json` for anything that pipes logs into a collector. |
| `LOG_AGENT_INTERACTIONS` | `true` | `false` stops writing the trajectory. That is not a privacy switch — the trajectory is how a run is debugged, and switching it off removes the record rather than the sensitive part of it. |
| `MEMORY_DRIVER` | `db` | `file` selects the container-directory store. See below. |
| `MEMORY_DIR` | `memory_store` | Where `MEMORY_DRIVER=file` writes. |
| `API_KEYS` | *(unset — endpoints open)* | Comma-separated bearer tokens. Empty logs a warning at startup and says `DISABLED` in `/api/health`. |
| `CORS_ORIGINS` | the dev host on `:4550` | A wildcard plus a bearer token is any page on any laptop using this agent against this tenant. |
| `REQUIRE_WRITE_APPROVAL` | `false` | When true, every non-read tool needs `"approved": true` in its arguments. |
| `STRICT_TOOL_POLICIES` | `true` | Enforces the per-tool `RequiresApproval` flags. |
| `MAX_TOOL_ITERATIONS` | `10` | How many model round-trips one turn may take before the loop answers with what it has. |
| `MAX_BODY_BYTES` | `1048576` | Request body cap. |
| `TAVILY_API_KEY` | *(unset)* | Without it `search_web` is registered and refuses, which is honest in a way an absent tool is not. |
| `ALLOW_INTERNAL_SCRAPE` | `false` | The SSRF guard's override. |
| `HOST`, `PORT`, `TZ` | `0.0.0.0`, `8000`, `America/Chicago` | |

## Running it

```bash
cd agents/customer_service
docker compose up --build -d          # :4550
curl -s localhost:4550/api/health | jq
```

Verified on this server, 2026-11-04, against the seeded tenant: `/api/health` reports `healthy` with
`crm_tools: 8` and `memory_driver: db`; a lookup turn over SSE and a plain `POST /api/chat` both
complete; a turn that logs a call and marks the follow-up produced one `communications` row with
`agent_id = 'customer_service'`, one `entities.status` change, one live `add_communication` claim in
`idempotency_keys`, and a trajectory row whose `actions_taken` and `tool_observations` are six and six
with `response_sources` = `["entities:5", "communications:14"]`. That last item is the whole loop
asserted in one query: the run recorded what it touched, in the order it touched it.

Two endpoint bugs surfaced in that smoke test rather than in a unit test, which is worth saying because
the reason is instructive: `?view=tool_calls` and `?view=performance` shared one `ORDER BY
"timestamp"`, and neither view has a `timestamp` - so two of the four documented listings had returned
502 since they were written, and nothing had ever called them. `cmd/server/main_test.go` now compares
every projected and ordered column against `pg_attribute`; it skips without a database, and it fails on
the old query text, which is the only way a check like that earns its place.

Without Docker, from the backend directory — which needs a Go toolchain:

```bash
cd agents/customer_service/backend_go
export AFPC_PG_HOST=<the address in the certificate's SAN list> AFPC_PG_PASSWORD=... \
       AFPC_TENANT_ID=00000000-0000-0000-0000-000000000001 \
       AFPC_PG_SSLROOTCERT=../../dev/tls/afpc-ca.crt
go run ./cmd/server
```

On a machine with no Go and no database — the loop works, the CRM tools do not:

```bash
export MEMORY_DRIVER=file
go run ./cmd/server
```

## Endpoints

All of them answer for `AFPC_TENANT_ID`, so all of them are behind `API_KEYS` when it is set.

| | |
|---|---|
| `POST /api/chat` | `{message, thread_id?}` → `{response, thread_id, run_id}`. The `run_id` keys the `agent_interactions` row this turn wrote - without it the non-stream path had an answer that could not be tied to its own trajectory (the stream path always carried it via `SSEEvent.RunID`). |
| `POST /api/chat/stream` | The same turn as SSE: `token`, `status`, `tool`, `tool_result`, `error`, `done`. |
| `POST /api/reset` | Clears the in-process context for a thread. Not the history — see below. |
| `GET /api/history` | What the model is currently shown. |
| `GET /api/tools` | The registered surface, with each tool's policy. |
| `GET /api/interactions` | The trajectory: `?view=recent\|failed\|tool_calls\|performance&limit=&bot_id=`. `bot_id` filters three of the four - `performance` groups by tool across every agent, so asking it for one agent is refused rather than answered with everyone's rows. |
| `GET /api/health` | Status, including whether the database answered and what `MEMORY_DRIVER` is in force. A configured-but-unreachable database comes back 503; a deliberate no-database box is `degraded` at 200, because that mode was chosen and flapping on it would teach the monitor to ignore the flag. |

Every value in those responses is what `pkg/db`'s `normalise` decides a caller can read: timestamps in
RFC 3339 with their offset (0022's finding was that a timestamp without a zone is a different fact),
text held in bytes decoded rather than base64'd, and uuids rendered in the 8-4-4-4-12 form. The last one
is recent and it mattered: pgx hands a `uuid` column to an `any` target as a `[16]byte` **array**, and
`encoding/json` renders that as sixteen numbers, so `interaction_id` came back as
`[1,161,166,...]` - nothing failed, and no caller could quote the id it was given.
`pkg/db/normalise_test.go` pins the shape.

The two "history" endpoints are different things, and the distinction is the one a support
conversation most needs to get straight: `/api/history` is what the next prompt will contain, and
`/api/interactions` is everything that ever happened. Resetting the first leaves the second alone.

## What is *not* here

Four deferrals, each with the reason attached, because "not yet" without a reason reads like an
oversight:

- **Telegram.** The reference drop has a working adapter in the upstream checkout at
  `/home/justin/agents/dumb_agent`. This deployment starts with HTTP and the UI; the transport is a
  main.go change and nothing in the loop depends on which one is attached.
- **Semantic search.** `communications.embedding` and `contacts.embedding` exist and are empty.
  0012 built the hnsw indexes; nothing fills the vectors, because no embedder in this deployment
  produces the 1536 dimensions those columns declare — measured, the local models answer 1024 and
  4096. Requirement 1's "find customers who complained about shipping last week" is therefore
  unimplemented rather than approximated. A keyword-search tool was also left out: `communications.summary`
  has no trigram index, so it would be a `_seq scan` behind a tool the agent calls constantly.
- **The follow-up task table.** `add_communication` sets `follow_up_required` and `follow_up_date` on
  the interaction and deliberately creates no `followups` row — that table has no writer anywhere in
  the schema, and `vw_pending_followups` reads it. 0021's §5 hands the decision to whoever owns it.
- **Escalation to a CAO agent.** Requirement 7 asks for it. The detection half is there — sentiment,
  escalated outcomes, `get_entity_stats` — and the routing half needs a second agent to escalate to.

## Layout

```
agents/customer_service/
├── Dockerfile, docker-compose.yml
├── backend_go/
│   ├── cmd/server/main.go      wiring, auth, endpoints, startup order
│   └── pkg/
│       ├── agent/              the loop: prompt, tool dispatch, trajectory, rehydration
│       ├── crm/                the eight CRM tools and their argument coercion
│       ├── db/                 the pool: TLS modes, tenant on connect, row → JSON
│       ├── formatters/         truncation and fallback summaries (reference implementation)
│       ├── ids/                UUIDv5 derivations: conversation ids, claim keys
│       ├── llm/                Azure token provider
│       ├── logging/            slog + masking, and the agent_interactions writer
│       ├── mcp/                HighByte MCP client (inherited, unused here)
│       ├── memory/             agent_memories, with the file store as an explicit fallback
│       ├── tools/              the registry, and the non-CRM tools
│       └── turn/               what turn a call is running in — the leaf everything reads
└── frontend/                   the React UI, pointed at :4550
```

The import graph is a DAG with `ids` and `turn` as leaves. It is worth naming because the alternative
was tried first: run identity lived in `tools`, which made `memory` import `tools`, which `tools`
imports, and the fourth package that needed it resolved the cycle by copying the function.

## Testing

```bash
go test ./...           # everything below the loop, against fakes
go vet ./...
```

The module is named `jada-backend`, which is why test output reads `ok jada-backend/pkg/agent` for code
that lives in this directory. Renaming a module path touches every import and no behaviour, so the label
stayed; the packages under it are this agent's.

`pkg/llm` has one failing test that predates this directory: `TestGetAzureConfig` expects an
`openai.azure.us` endpoint and `azure_oauth.go` builds a `cognitiveservices.azure.us` one. Both files
are byte-identical to `agents/jada`, the deployment uses neither (this agent runs
`LLM_PROVIDER=local`), and deciding which of the two is right needs an Azure tenant to check against.
It is left failing and named here so a red `go test ./...` is explained rather than rediscovered.

The database side of the surface is tested in SQL, where the claims can actually be checked:
`db/tests/4_7_cs_agent_surface.sql`, run by `./scripts/db/test-functions.sh`, with the invariant
checks in `./scripts/db/verify.sh`.

## Related

- `docs/agent_requirements/customer_service/customer_service.md` — what this agent is specified to do
- `docs/INTERACTION_LOGGING.md` — reading a run back
- `db/migrations/0021_*.sql`, `0022_*.sql`, `0023_*.sql` — the three doors this deployment needed
- `agents/jada/` — the reference drop, unchanged and not the deployment
