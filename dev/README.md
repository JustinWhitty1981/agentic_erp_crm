# Development server: Postgres 17 + pgvector

This directory holds the local development database. The box it runs on is the primary
development server, so **the data volume is durable and is never recreated implicitly**.

| | |
|---|---|
| Container | `afpc-pg` (`pgvector/pgvector:pg17`, PostgreSQL 17.11, pgvector 0.8.x) |
| Data | volume `afpc_pgdata` — survives stop/start and `up`/`down` without `-v` |
| Secrets | `dev/.env`, mode 600, gitignored. Not in the repo, not in the image |
| TLS | volume `afpc_tls` at `/certs`; CA copy in `dev/tls/afpc-ca.crt` |
| Migrations | `db/migrations/`, applied in order by `scripts/db/migrate.sh` |
| The agent | container `afpc-customer-service` from `agents/customer_service/`, publishing `:4550`; `agents/jada` is the reference drop it was derived from and `:4545` is the container that predates it |
| Not here | the LiteLLM database (`litellm-db-1`) publishes no host port and is on its own network; nothing in this setup reads or routes to it |

## Auditing from any server on the network

Credentials are in `dev/.env` (`AFPC_AUDITOR_PASSWORD`). Copy the CA once — it is the
public half, and it is what lets you confirm you are talking to this database:

```bash
# <IP> is this machine's own address, the one the certificate was issued for. It is deliberately not
# written down in a page that gets cloned: an address is a fact about one network, and two copies of it
# - here and in a source file's default - is two things that can each be out of date.
scp justin@<IP>:~/agent-workspace/projects/agent_first/dev/tls/afpc-ca.crt .
psql "host=<IP> port=5432 dbname=agent_first_erp_crm user=afpc_auditor \
      sslmode=verify-full sslrootcert=afpc-ca.crt"
```

**Where to read `<IP>` off the machine itself.** `scripts/db/init.sh` puts it in
`agents/customer_service/.env` as `AFPC_PG_HOST`, and the leaf certificate carries every address that
will pass `verify-full`:

```bash
docker exec afpc-pg openssl x509 -in /certs/server.crt -noout -ext subjectAltName
```

The LAN address and the tailnet address are both in that list, so either works; the tailnet one reaches
the same port from anywhere the node is reachable. If you would rather not distribute the CA,
`sslmode=require` works but does not verify the certificate.

**The CA is stable across rebuilds.** `scripts/db/db fresh` destroys only the data volume;
the certificate volume survives, and `init.sh` regenerates the authority only if the
authority itself is missing (a leaf can be reissued from a surviving CA, and the CA can
only sign a new leaf if its key survived with it). If you ever see
`certificate could not be validated` after a rebuild, the CA genuinely changed — re-copy
`dev/tls/afpc-ca.crt` rather than downgrading to `sslmode=require`.

The role is read-only by three independent mechanisms, so a single oversight cannot
make it writable:

1. no `INSERT`/`UPDATE`/`DELETE`/`TRUNCATE` is granted, on this schema or any future
   one — `db/migrations/0002_access_grants.sql` sets default privileges so tables
   added by later migrations are visible to you the moment they exist;
2. `default_transaction_read_only = on` is set **at role level**, so even a mistaken
   grant fails inside the transaction;
3. `NOBYPASSRLS`, so you see the rows an agent sees, not the rows an owner sees.

Its session is also capped (`statement_timeout` 60s, `lock_timeout` 5s) so a wide
query cannot stall the box, and `log_statement = all` is set per role — every
statement you run is written to the server log, which is the part an auditor normally
has to ask for.

### What to look at while auditing

```sql
SELECT version, applied_at FROM public.schema_migrations ORDER BY version;  -- what has been applied
SELECT r.rolname, count(*) AS tracked_queries
  FROM pg_stat_statements s JOIN pg_roles r ON r.oid = s.userid GROUP BY 1;  -- per role
SELECT r.rolname, substring(s.query, 1, 60) AS query, s.calls, round(s.mean_exec_time::numeric,2) AS ms
  FROM pg_stat_statements s JOIN pg_roles r ON r.oid = s.userid
 ORDER BY s.total_exec_time DESC LIMIT 20;
SELECT datname, usename, client_addr, state, backend_start
  FROM pg_stat_activity ORDER BY backend_start;                             -- who is connected now
```

From 0010 on there is a second one, for the column a sync query depends on:

```sql
SELECT table_name, updated_at_not_null, moves_on_update, rewritten_by, verdict
  FROM public.vw_timestamp_status ORDER BY needs_attention DESC, table_name;  -- can I trust a watermark here?
```

`rewritten_by` is not documentation: it is the list of functions in `pg_proc` whose bodies contain
an `UPDATE` against that table, so the register changes when the write paths do. That is how
`addresses` turned out to need the column - the review lists it as merely missing one, and nothing
in the schema said anything rewrites it until the functions were asked.

From 0009 on, the structural question has a view:

```sql
SELECT table_name, rls_forced, read_predicate, write_predicate, verdict
  FROM public.vw_rls_status ORDER BY verdict, table_name;   -- what row security actually does
```

One thing to know before believing any query result here: **row security binds a role, not a
schema.** Connected as `afpc_app` the same `SELECT count(*) FROM warehouses` sees one tenant;
connected as `postgres` it sees every tenant, because a superuser bypasses row security however
the tables are configured - `FORCE` binds an owner, not a superuser. So auditing *as the
auditor* is the only way to see what the agents see, and `SET ROLE afpc_app` inside an owner
session is the way to check a specific tenant's view of the data without a password:

```sql
SET ROLE afpc_app; SET app.tenant_id = '<uuid>';  -- now you are one tenant
RESET ROLE;                                        -- SET LOCAL ROLE does not revert by itself
```

The audit account reads across tenants by policy (`audit_read_all`, `USING (true)`), so every
domain view now carries a `tenant_id` column to tell the rows apart, and the aggregate views
group by it - otherwise `vw_agent_activity_summary` would add two tenants' bots together under
one name.

The server log carries `user=`, `db=` and `host=` on every line, which is how the
masquerading in the next section was established rather than assumed.

`scripts/db/verify.sh` and `scripts/db/test-functions.sh` are the two reports the work
is being measured against; `make db-verify` and `make db-test` run them.

## How access is actually controlled

Worth stating precisely, because it is easy to believe a rule that cannot fire.

Connections arrive through a published container port, and Docker **rewrites the
source address to the bridge gateway** (`172.22.0.1` was observed in the server log for
a client that is not on that subnet at all). So `pg_hba` subnet lines cannot act as a
per-machine allow-list for LAN clients — any server that can route to `:5432` matches
the same rule. What actually gates access is, in order:

1. **TLS is required** for every network connection: `hostssl` rules only, and the
   plaintext catch-all is an explicit `reject`. Verified by attempting `sslmode=disable`.
2. **scram-sha-256 credentials**, per role, from `dev/.env`.
3. **Per-database grants** — `REVOKE CONNECT ON DATABASE postgres FROM PUBLIC`, so the
   maintenance database is not a landing spot.
4. **Per-role privileges**, which is what makes the audit account read-only.

If you want real per-address control, the change is to stop NAT-ing: run the container
with `network_mode: host` so Postgres sees the true peer address and `pg_hba` rules
become meaningful. That is a one-line compose change plus `listen_addresses`, and it is
deliberately not the default, because it removes the container's network isolation.

The LAN and tailnet rules are kept anyway: they are what matches a client that connects
directly (for example `--network host`), and they document intent.

## Commands

| | |
|---|---|
| `make dev-up` | start, apply roles/settings/migrations |
| `make dev-init` | re-apply roles, TLS, `pg_hba`, settings — idempotent, no data touched |
| `make dev-status` | container, volumes, migration state and checksum drift |
| `make db-verify` | structural assertions against `pg_catalog` |
| `make db-test` | execute the schema functions, report known-open / closed / regression |
| `make db-shell` | `psql` as the owner |
| `make db-audit` | `psql` as the view-only audit role, over TLS |
| `make db-backup` | `pg_dump -Fc` into `backup/` |
| `make db-fresh` | **destroy and rebuild** — asks for confirmation |

`make dev-init` restarts the container. `ssl` and `shared_preload_libraries` are
postmaster-context, so a reload is not enough; if the server fails to come back after a
TLS change, `init.sh` reverts `ssl` rather than leaving a persistent database unbootable.

## Things that will bite you if you do not know them

Every one of these was learned by a check failing on a rehearsal or a migration after the fact, not by
reading documentation about the database - and the count is deliberately not given, because the last
time this page carried one it had already drifted by seven entries, which is the exact failure this
session's whole documentation sweep is about. Keep the pattern: when something surprises you here, the
surprise goes in this section, and the check that would have caught it goes in `verify.sh` or a
`code:*` marker. An entry with no check behind it is a rumour, and it is also the one nobody re-reads.

**The leaf certificate has IP subjectAltNames and nothing else, and the CA has none at all** - so when a
connection refuses a name, read the list off the leaf (`docker exec afpc-pg openssl x509 -in
/certs/server.crt -noout -ext subjectAltName`) and not off `dev/tls/afpc-ca.crt`, which will show you
nothing and look like evidence that the certificate has no SANs. `sslmode=verify-full` therefore
validates against the addresses in `subjectAltName` - this machine's LAN and tailnet addresses - and
fails against `afpc-pg`, `localhost`,
`host.docker.internal` and any DNS name that reaches the same server - including from inside a
container on this box, which can route to the LAN address and should use it. The error reads like a
network fault (`x509: certificate is valid for <the SAN list>, not afpc-pg` reads like neither), and the
wrong fix is `require`, which encrypts and checks nothing. `agents/customer_service/docker-compose.yml`
sets the IP for this reason and says so at its top.

**There is no `go`, and no `make`, on the host's PATH** - the toolchain lives in an image. Build and
test with

```bash
docker run --rm -v "$PWD/agents/customer_service/backend_go":/src -w /src \
  -e PATH=/usr/local/go/bin:/usr/bin:/bin -e GOCACHE=/tmp/gc -e GOFLAGS=-mod=mod \
  golang:1.23-alpine go test ./...
```

The `PATH` is not decoration: `golang:1.23-alpine`'s `sh -lc` rebuilds PATH from profile and drops
`/usr/local/go/bin`, so without it `go` is "not found" inside a command that otherwise looks correct.

**`agents/jada/` is not yours.** It is owned by uid 10001 and its ACL mask makes it read-only to
`justin`, so a `sudo chown` is not available without a password and a build that writes into it fails
with a permission error that names nothing useful. The deployed agent therefore lives in
`agents/customer_service/`, tracked, with the reference drop left untouched - which is also the point:
the reference should stay what it was when it arrived, or it stops being a reference. `agents/jada/` is
therefore in `.gitignore` rather than merely untracked: an exclusion is the one form of that decision
that survives a `git add -A` - which would otherwise commit 68 files of vendored tree, as it did once,
and make the reference look like ours.

**`migrate.sh` refuses a number at or below the highest applied.** Correctly, but it means a planned
migration's number is *spent* the moment a later one is applied: 0019 and 0020 were plans, 0021-0023
were needed first, so the plans moved to 0024 and 0025. `0013` names `0019` four times in prose, and an
applied migration is checksum-frozen, so that number could not be reclaimed either. Renumber rather
than re-edit, and write the reason in db/MIGRATIONS.md - which is where this rule lives now.

**The agent starts degraded, and that is the failure mode to look for.** A database that is configured
and not answering does not stop the process: the CRM tools are not registered and `/api/health` answers
**503** with `degraded_reason`, so a monitor can page on the difference between "the container is up"
and "the agent can work". `docker ps` will say `healthy` only after the healthcheck's own probe
passes, so a 503 with no obvious error is the state to check first. Startup also probes for
`add_communication`, `save_memory` and `get_followup_customers`, which is how a database migrated to
before `0021` announces itself instead of failing on the first write.

**A streaming turn hangs for the whole timeout behind a buffering proxy.** SSE needs to reach the
client incrementally; anything that buffers the response turns a working agent into one that appears
frozen at the first token. `LLM_STREAM=false` answers the same turn in a single body, and that switch
exists for exactly this and nothing else.

**Compose does not interpolate `${...}` from an `env_file:` entry.** Variable expansion reads the shell
environment and the project directory's `.env` only, so a line like
`- AFPC_PG_PASSWORD=${AFPC_APP_PASSWORD}` - which looks like a translation between two names for one
secret - expands to *nothing* and sets the variable to the empty string. The agent starts, declines its
CRM tools, and answers `/api/health` 503 with a `degraded_reason`, while the credential sits one line
away in the file named under `env_file:`. This is how the first real `docker compose up` of
`agents/customer_service/` went degraded. The fix is not a compose line: `pkg/db` reads both names and
takes the first non-empty one. Related, and learned in the same start: paths in a compose file resolve
against **the compose file's own directory**, so `dev/.env` from `agents/customer_service/` is
`../../dev/.env`, and a wrong depth on a *certificate* bind mount is worse than a wrong depth on an env
file - Docker creates the missing source as an empty directory, the mount succeeds, and the failure
arrives as "certificate signed by unknown authority".

**A date column and a timestamp column need different parsing, and using one helper for both loses a
day.** `time.Parse("2006-01-02", "2026-11-10")` returns midnight **UTC**, and `.Local()` does not move
the clock - it relabels the same instant - so in a container six hours behind UTC the value formats back
out as `2026-11-09`. The customer service agent's `dateOnly` went through the timestamp helper, so every
follow-up booked from `agents/customer_service` stored the day before the one the caller named, while the
reply quoted the correct date. Two symptoms, then, and one cause: `2026-11-10` in prose, `2026-11-09` in
`communications.follow_up_date`, and `to_char(follow_up_date,'Day')` saying Monday about a Tuesday. A
`date` is a calendar day and must never pass through a zone; a bare *timestamp* has to be anchored with
`time.ParseInLocation`, which is the call that says what "local time is the caller's meaning" claims.
`pkg/crm`'s `TestDateArgumentIsNotMovedByTheServersZone` and `TestBareTimestampIsAnchoredLocally` pin
both, against fixed offsets rather than named zones so the assertion holds in whatever image runs it, and
both fail on the old code with the exact date this produced.

The rows that were already wrong are repaired, and `audit_log` says so: two UPDATE trail rows, `was`
2026-11-09, `became` 2026-11-10, `db_user` postgres. That trail is also the reason the repair was done in
SQL rather than through a function - 0021's door creates an interaction and nothing amends one, and a
correction to a mis-stored day is not an interaction with a customer.

**`set_config('app.tenant_id', $1, true)` inside a connection hook sets nothing.** The third argument
is `is_local`: the setting then belongs to the *transaction*, and a connect hook runs outside one, so the
implicit transaction carrying the SELECT ends immediately and the claim disappears. Every query that
follows resolves `afpc_current_tenant()` from `app.default_tenant_id` instead - which on this box is the
tenant the agent means, so the agent works, the writes land correctly, and the identity the row security
policies are built on is being inherited rather than asserted. Use `false` for a session-scoped claim
when the process serves one tenant, and set it inside the transaction when a pool is ever shared across
two. `agents/customer_service/backend_go/pkg/db`'s `TestTenantSurvivesTheConnection` reads
`current_setting('app.tenant_id', true)` back and requires the configured value; it skips without a
database, and it fails on the `true` form, which is the only reason the difference is recorded anywhere.

**A run's identity reaches a tool through a context value, or the writes silently lose their claim.**
If the loop stops putting the run in the context the tools run against, every write goes out with a
NULL idempotency key: no error, no log line, and a duplicate row per retry. `pkg/agent`'s
`TestRunIDReachesTheTool` is what notices, and it is the reason `pkg/turn` exists as a leaf package.

**`CREATE OR REPLACE FUNCTION` with a changed parameter list creates a SECOND function.**
"Or replace" matches by signature, and a new signature matches nothing: 0014 added two
DEFAULTed parameters to `execute_inventory_movement`, and every call to the name went
ambiguous - 4.4's own 42725, reproduced inside the migration fixing 4.x. A signature-changing
rewrite is `DROP FUNCTION IF EXISTS` (by full old signature) then `CREATE`. Assert the count
of heads from `pg_proc` if you doubt it; 0014's probe I does.

**`ON CONFLICT DO UPDATE` runs CHECK constraints against the tentative INSERT row.** The
conflicting row's UPDATE branch is not reached until the speculative insert resolves - and
"resolve" happens *after* the new tuple is checked. An `ADD`-style upsert whose INSERT-side
value can violate a column CHECK (0014's negative receipt vs `chk_quantities_non_negative`)
therefore fails in the way no reading of the statement predicts: the UPDATE-side CASE that
was supposed to handle the case never runs. Read the Failing-row DETAIL, not the docs.

**plpgsql's predefined condition names do not cover the SQLSTATE space.** `WHEN
cardinality_violation` caught neither 2201E nor 22012 in this build (measured: both escaped
the handler) - a WHEN arm naming the wrong thing is not a failing test, it is a test that
silently stops existing. Name conditions you've probed, use `WHEN SQLSTATE 'xxxxx'` when the
number is the fact, and let `WHEN OTHERS` + a SQLSTATE check be the fallback shape.

**`setval(seq, v, false)` hands out `v` itself, not `v+1`.** A test harness that "restores"
a sequence to `max(id)` with is_called=false therefore aims the next insert at an existing
row. Invisible for twelve migrations - every table a test touched rolled back to EMPTY,
where the value drawn is a formality - until `audit_log` became the first table with
committed migration-era rows, and the next audited write died on `audit_log_pkey` inside a
proving-unrelated probe. The mapped-row SURPRISE that surfaced it is the argument for the
whole scoreboard. Restoring a non-empty table's counter is `setval(v, true)`.

**A plpgsql body is not parsed until it is entered.** `atttypid = 'vector'::regclass`
where regtype was meant - CREATE FUNCTION succeeds, the statement inside has never been
analyzed, and the first call is the first compile. Migration files that run their checks
after creating their functions do not get an early warning from the DDL; only behaviour
probes parse them.

**`GENERATED ALWAYS AS IDENTITY` rejects explicit ids - including the one your trigger
needs.** A hash chain whose payload covers the row's position must draw `nextval()` itself
(under a lock, so key order and commit order agree) and insert the value; ALWAYS raises
`cannot insert a non-DEFAULT value`. `BY DEFAULT` keeps the guarantee honestly: an id
manufactured out of order breaks `prev_hash`, which is what verification is for.

**plpgsql substitutes two name levels, and `SELECT INTO` unpacks composites by position.**
`r.a.tenant_id` over a loop record (loop var → composite field → subfield) reaches the SQL
parser as a reference to a FROM item `a` - an error at runtime, not an optimization; and
`SELECT a INTO v_row` with a single composite column fills the target's FIRST field with
the row, not its fields. Hoist the subfields you filter or order by into the loop's query,
and expand with `a.*` for row-variable targets.

**`CREATE OR REPLACE VIEW` can add a column and can never drop one.** The first rehearsal of
0012 died on `cannot drop columns from view` while removing a projected `vector(1536)` -
0009's capture-rewrite-prove pattern only ever restated definitions with *more* columns, so it
never met the limit. The only mechanism is `DROP` + `CREATE`, which restarts the object's whole
life: reloptions gone (so `security_invoker` must be re-set), grants come back only via 0002's
default-privileges records (assert them, don't trust them), and the drop would auto-cascade to
any dependent view - so count dependents in `pg_depend` first and refuse if there are any.

**Planner *preference* for a vector index is not testable property, because the cost model
cannot see the thing the index is for.** The sort path's estimate never charges for
detoasting a 6 KB vector, and generic index costing scales hnsw's estimate with index size
(which a graph search does not pay), so measured unforced plans flip between the two paths
twice between 500 and 5000 rows while real buffer counts differ 35x (9053 vs 260). Assert
*usability* with the alternatives forbidden and *savings* in executed `EXPLAIN (ANALYZE,
BUFFERS)`, and treat preference as the cost-model detail 0006 called it.

**`pg_column_size()` detoasts, so it is the wrong instrument for a storage claim.** It
reports ~6148 bytes for a `vector(1536)` whether the row carries it inline or a toast pointer
does - a threshold on it fails against a schema that is storing things exactly as claimed.
Fork-size deltas (`pg_relation_size` main vs toast, before and after a known insert) are the
sound form; 0012's probe D does it that way and fails loudly if a future change ever inlines
the vectors, which is the evidence that would make the review's side-table prescription right.

**`EXPLAIN`'s per-node `Buffers:` lines are indented, and the root's totals come first.** A
capture loop matching `LIKE 'Buffers:%'` matches nothing and silently reports a NULL census;
matching `'%Buffers:%'` and taking the *first* hit takes the whole-tree total, while taking
the *last* lands inside the InitPlan (measured: 86 blocks of a 9053-block run). Both mistakes
printed in the same rehearsal of 0012's test file.

**`now()` is the transaction timestamp, so a timestamp test needs a pin, not a sleep.** Read a
column, update the row, read it again: inside one transaction both reads return the same instant,
whether or not a trigger is working. The test that survives is *pin the column to a past value,
then write, then ask whether it moved* - true at any transaction boundary, and it needs no
`pg_sleep`. The same fact makes a batch of twenty rows share one timestamp, which is what you want
from a change-data-capture reader and what you do not want to discover while debugging a probe.

**Trigger timing lives in `tgtype` bits that are easy to guess wrong.** Measured with probe
triggers: `ROW=1`, `BEFORE=2`, `INSERT=4`, `DELETE=8`, `UPDATE=16` - so `BEFORE UPDATE FOR EACH ROW`
is 19, `BEFORE INSERT OR UPDATE` is 23, and `AFTER INSERT OR UPDATE OR DELETE` is 29. Bit 2 is the
*timing*, not a command, which is how a check written as `& 2 = 2 AND & 4 = 4` and commented
"INSERT, UPDATE" ended up demanding a BEFORE INSERT trigger and never looking at UPDATE - green for
seven migrations, while flagging the two tables that were correctly maintained.

**A trigger function's `EXECUTE` is not checked against the role that fires it.** Measured:
`afpc_app` updated rows through a `BEFORE UPDATE` trigger whose function had been revoked from both
`PUBLIC` and `afpc_app`, and re-granting it changed nothing. Row-security policy quals behave the
opposite way - a missing grant there produces `permission denied for function` in the middle of an
ordinary `SELECT`, which is why 0009 keeps three helpers PUBLIC-executable. So revoking a trigger
function is safe and granting it is noise; the thing to reason about is who the server counts as the
caller, and for a trigger it is not the caller.

**A row-security predicate is a plan, so the resolver's volatility is a performance property.**
`USING (tenant_id = afpc_current_tenant())` reads correctly and costs a sequential scan: a
VOLATILE function in a qual is re-evaluated per row and cannot become an index condition. The
same clause against a STABLE resolver is an Index Cond - measured 479 ms against 53 ms on 600k
rows across two tenants. That is why `afpc_policy_tenant()` exists next to
`afpc_current_tenant()` and why the two have different volatility markers on purpose.

**`CREATE OR REPLACE VIEW` discards the view's reloptions, and `security_invoker` is a
reloption.** Setting it and then restating the definition sets it on the version about to be
replaced - 0009's own view probe caught that by returning both tenants' rows through a view
whose table was correctly filtered. Apply it *after* the rewrites; B21 checks it from the
catalog. The version default is not a safety net: a view created by a superuser in this cluster
keeps owner semantics with empty `reloptions`.

**`ALTER DEFAULT PRIVILEGES ... REVOKE ... FROM PUBLIC` is a no-op for functions.** For tables
it works, because a stored default-privileges record replaces the object's initial ACL. For
functions the initial ACL already grants EXECUTE to PUBLIC and the record only adds to it, so
the statement succeeds, changes nothing, and a function created afterwards is still callable by
every role. The mechanism that works is a per-object `REVOKE` (0008 did its two, 0009 did the
rest) plus verify.sh B22, which is not a duplicate of the sweep - it is the only thing that
keeps it closed.

**The view -> table dependency edges hang off the rule, not the view.** `pg_depend` rows with
`classid='pg_rewrite'` have `objid` equal to the *rewrite rule's* oid, so
`WHERE d.objid = 'vw_customers'::regclass` returns two rows about the view itself and nothing
about what it reads. A first draft of 0009's classifier used exactly that and concluded that
none of the fourteen views covered a tenant table. `information_schema.view_table_usage`
answers the question and is what the migration uses; the check that compares the rewritten
column lists against a pre-rewrite snapshot is what caught the reasoning.


**Never bind-mount a file from this repo into the container.** The `.sql` files are mode
`0660` and owned by a uid the container cannot read as. A mounted file fails with
`Permission denied`, and unless `ON_ERROR_STOP` is set psql still exits 0 — so a
migration loop can report complete success having created almost nothing. A review of
this schema hit exactly that and initially believed the files loaded cleanly. Everything
here therefore pipes SQL to `psql -f -` over stdin.

**`docker compose up -d` will not re-publish a port when only the interpolated bind
address changed.** It decided the configuration was unchanged and left a stale
`127.0.0.1` binding live after `PGBIND` had been set to `0.0.0.0`. `init.sh` now compares
the published address with the desired one and forces recreation; if you change `PGBIND`
by hand, use `up -d --force-recreate`.

**`pg_index.indkey` is zero-subscripted.** `indkey[0]` is the first key column. Slicing it
as `indkey[1:n]` silently omits that first column, which made an index-coverage check in
0004 report that `item_id` appeared in no index when it led the identity. Use
`attnum = ANY(indkey)` and compare against `indkey[0]` explicitly; with ORDINALITY, the
attribute at ordinal *k* is `indkey[k-1]`.

**A `CTE` does not outlive its statement.** `WITH x AS (...) UPDATE ...; DELETE ... USING x`
is a parse error - the second statement cannot see the first one's CTE. A migration that
combines them looks correct and only fails when the code path is reachable, which on an
empty development table it never is. 0004's duplicate-merge had exactly this bug and a
clone rehearsal is what found it.

**`ALTER TABLE ... ALTER COLUMN ... TYPE bigint` does not change the sequence behind it.**
The column becomes `bigint`; `entities_id_seq` stays `integer` with `max_value`
2147483647. The table can hold a value nothing can generate, and a check that reads the
column type reports it fixed. You need `ALTER SEQUENCE ... AS bigint` as well - it
preserves both the current value and the ownership link. `verify.sh` B14 asserts the pair.

**`pg_attribute` contains rows for indexes as well as tables.** A catalog query that looks
for "integer columns named id" without `c.relkind IN ('r','p')` will try
`ALTER TABLE addresses_pkey ALTER COLUMN id TYPE bigint` and fail. Same family as the
`indkey` zero-subscripting trap below: the catalog is wider than the schema you are
thinking about.

**`public` is not all yours.** pgvector installs 198 functions and 4 aggregates (`array_agg`,
`avg`, `sum`) into it. `pg_get_functiondef()` *raises* on an aggregate, so a loop over
`pg_proc` filtered only by namespace dies on a row that has nothing to do with you. Exclude
extension-owned objects via `pg_depend.deptype = 'e'`.

**`DROP VIEW` costs more than the view.** Postgres refuses to alter the type of a column a
view reads, so widening a key means dropping and recreating every view that touches it. The
recreation is faithful for columns, and grants come back on their own through 0002's
`ALTER DEFAULT PRIVILEGES` - but `COMMENT ON VIEW` lives on the view and dies with it, which
is how the baseline ended up with eight views that had no description. 0005 captures the
definitions and descriptions, and asserts the counts afterwards.

**An index-existence check is not an index-usage check, and `EXPLAIN` on an empty table proves
nothing.** 0006's first self-verification asserted "the lookup path uses the trigram index" by
explaining a query, and it failed on a database with zero rows - where a sequential scan is the
*correct* plan. Worse, forbidding the sequential path made the planner take a full btree scan of
`idx_entities_tenant_name` used as a filter, which also proves nothing. Two different assertions
are needed: *usable* (forbid the alternatives, require the access method to appear) and
*preferred* (needs statistics, so it belongs where rows exist - `db/tests/5_5_6_index_hygiene.sql`
inserts 10,000 inside a transaction, `ANALYZE`s, and rolls back; ANALYZE is transactional, so its
`pg_statistic` writes go away with the rows).

**`indkey::int[]` keeps `int2vector`'s zero-based subscripts.** So `(indkey::int[])[1:n]` skips
the first column and compares the wrong keys. Rebuild it as
`array_agg(v ORDER BY o) FROM unnest(indkey::int[]) WITH ORDINALITY q(v, o)` before slicing.
This is the third time this representation has produced a wrong answer here (0004 introspection,
0005 coverage, 0006 redundancy), and the 0006 instance was found only because a *guard* refused
to drop an index it believed was uncovered.

**A deduplication tiebreak can hide half the findings.** Pairing index checks with
`x.indexrelid < y.indexrelid` made the redundancy check report 3 pairs on this database and 0 on
a clone of it whose indexes had been recreated in the other order. Add a tiebreak only to a
branch that is otherwise symmetric.

**`RETURN` inside a plpgsql exception handler ends the enclosing block, not the handler.**
A probe that catches "the destruction was refused" and then `RETURN`s to skip its own failure
line silently skips whatever came after the BEGIN/EXCEPTION block too. Set a boolean in the
handler and read it after `END`. Related: the documented `cond EXCEPTION;` condition-name
declaration fails in this build ("type exception does not exist", in DO blocks and functions
alike), so the rollback-sentinel pattern uses `RAISE ... USING ERRCODE = 'P8xxx'` and
`WHEN SQLSTATE 'P8xxx'` - which is sturdier anyway, since an unrelated `raise_exception`
cannot be mistaken for the pass signal.

**A cascaded delete can raise an error that names neither the table you deleted from nor the
constraint you changed.** Before 0008, `DELETE FROM locations` on a stocked bin sometimes died
with `duplicate key value violates unique constraint "inventory_on_hand_key"` - 0004's identity
index - because the edge was `SET NULL` and the re-homed row collided with an existing
no-bin row. The delete's own constraint appeared nowhere. If a delete fails with a violation
on a *different* table, look at the referencing edges' `confdeltype`, not at the named index.

**`pg_get_constraintdef()` has two renderings of a membership test, and a filter that spells one
misses the other.** `= ANY ((ARRAY['a'::character varying, ...])::text[])` is what a constraint
written with an explicit array cast prints as; `= ANY (ARRAY['a'::text, ...])` is what the same kind
of constraint prints as when the cast was implied. A `LIKE '%= ANY ((ARRAY%'` filter therefore
reports half the CHECK constraints in the database as nonexistent - `vw_domain_vocabulary` found 1
of 20 on the first run. Match both with a regex, and have a test write every value the view
publishes, which is the only check that notices when the extraction stops working.

**A grep for a column name in a view definition is not a dependency query.** Asking "which views
read `version`?" with `position('version' in definition) > 0` matches `version()`, `substring(...)`
and any identifier that merely contains the string, and the negative form of the same question
("no view mentions it") matches nothing useful either. Ask the catalog: `pg_depend` rows from
`pg_rewrite` to `pg_attribute` list the columns a view actually reads. Run that way, the answer is
that **none of the 14 domain views reads any `version` column** - `vw_inventory_valuation` exists
and is one of the 14, but its columns come from `inventory_on_hand.quantity`/`unit_cost`, not from
the optimistic-lock counter. That settles 0010's "propagate `version` through the views" note:
there is no view to propagate it through, so 010 either drops that item or says which view it
meant. (`pg_views` shows 16 rows in `public`; the extra two are `pg_stat_statements*`, extension
-owned, which is why the catalog line counts 14.)

**`split_part` takes three arguments**, `cardinality()` ignores array subscripts while `array_length`
does not, and `unnest()` of a zero-based vector is still iterated in order - three small ways an
array comparison can be wrong in the direction that looks clean. When slicing a key list, rebuild
it through `unnest(...) WITH ORDINALITY` and `array_agg` first.

**`uuid_generate_v1mc()` is not time-ordered in the way you would expect.** Its leading
32 bits are `time_low`, which wraps every 429 seconds; across a boundary, 19 of 20 older
keys sort *after* a newer one, so the btree walks backward through pages it already passed.
`afpc_uuid_v7()` puts 48 bits of big-endian millisecond in front instead. See
`db/migrations/0005_key_types.sql` for the measurements.

**A global unique arbiter under forced row security loses writes silently.** `ON CONFLICT DO
NOTHING` reports `INSERT 0 0` for both "there was no conflict" and "there was a conflict with a
row you are not allowed to see" - so a dedup table keyed on the conflicting column alone lets one
tenant's key wedge another tenant's identical request with no error anywhere. Measured on a clone
while building 0011: tenant B claimed a key tenant A held, got `INSERT 0 0`, and saw zero rows for
its own request. The fix is the arbiter's column order - lead with `tenant_id` - and B10 now
asserts the order, not just the index's existence.

**`pg_get_functiondef()` always qualifies with `public.`**, so a body-scan regex written as
`(public\\.)?` - double backslash, meaning literal backslash - matches nothing, and a register
derived from function bodies reports zero rows: empty, which reads as clean, instead of wrong,
which reads as broken. Write `(public\.)?`. Every table-touching predicate in
`vw_idempotency_status` and `vw_timestamp_status` is built against that single backslash, and the
probe that compares the register against `pg_proc` is the guard against getting it wrong again.

**A test phrase a harness can only find after the fix reports SURPRISE, not progress.**
`test-functions.sh` decides KNOWN-OPEN from a grep of the run output, so a mapped phrase that lives
only in a post-migration failure branch - a stale-token refusal, say - cannot print before the
migration exists, and the harness says "stopped reproducing with no migration to explain why."
Migration-era test blocks therefore print their mapped phrases from the existence guard too, and
when adding a CASES row, put the phrase where the pre-fix database can reach it.

**A bare string literal in `RETURN QUERY` does not match a `varchar` OUT column.** A quoted
literal in a select list is `unknown`-typed, and plpgsql will not coerce `unknown` into
`character varying` - 42804, "structure of query does not match function result type". It will
coerce into `text`, which is why a body mixing the two looks half-broken rather than wholly:
0015's rewrite of `reserve_inventory_for_order` had to cast every status literal in the body,
not only the one in the error handler that finding 4.3 happened to reach. Write
`'SUCCESS'::varchar` in a function returning `TABLE(x, status varchar, ...)`.

**`SELECT col INTO var` says nothing when it matches the wrong number of rows.** Zero rows
leaves the variable untouched, so the guard below it tests NULL and evaluates UNKNOWN - neither
branch fires, and the function walks past its own refusal (0015 measured it: the reservation
door returned SUCCESS and wrote a commitment for an item with no on-hand rows at all). Several
rows keeps whichever row the scan happens to return first and discards the rest, without an
error and without a notice. Either way the fix is an aggregate - `coalesce(sum(...), 0)` - in a
statement whose row count you then check, not a bare column read into a scalar.

**`FOR UPDATE` cannot be combined with aggregates.** Locking the rows you are about to total
raises 42809. So the lock and the total are two statements: loop with `FOR UPDATE` to take the
locks in a deterministic order, then aggregate over the ids you collected. That is the shape
`afpc_pick_bins` has because of (0015), and the ordering is not cosmetic - two pickers that
visit bins in different orders deadlock on each other's partial writes.

**`scripts/db/db fresh` destroys the volume, which means every database in the cluster.** The
scratch clones you made for a rehearsal (`afpc_rehNN`) or an experiment (`afpc_expNN`) are gone
with it, silently, because they live in the same data directory as the main database. If a gate
step needs a clone afterwards, create it after the fresh run, not before.

**A structural check on a function body reads its comments as code.** `pg_get_functiondef()`
returns the whole `$$...$$` text including plpgsql comments, so an assertion like "this body
must not contain an `ERROR` status" written as a `LIKE` fires on the comment explaining why the
status does not exist - 0015's probe failed on precisely its own migration's prose. Prefer the
behavioural form (call it, look at what comes back); if a body scan is unavoidable, match the
statement shape, not the substring.

**A `RAISE EXCEPTION` inside a block whose own `WHEN OTHERS` watches another code reports the
wrong finding.** The probe's own failure is caught by its own handler: `P0001`, the SQLSTATE of
`RAISE`, comes back as the thing under test, and the message says the probe's assertion rather
than the function's behaviour. Assert outside the guarded block against a sentinel variable the
handler sets, or name the condition you are actually catching.

**Two catalog values are not the strings they look like.** `vw_domain_vocabulary.allowed_values`
is `text[]`, so `x = ANY ((SELECT allowed_values ...))` fails with "operator does not exist:
character varying = text[]" while `x = ANY (SELECT unnest(allowed_values) ...)` works - and the
scalar-subquery form is fine inside `unnest()` itself. And `max(uuid)` does not exist in this
build (uuid ordering is a PG18 feature): read one row out of a set-returning function with
`(array_agg(x))[1]`. Related trap in the same family: counting occurrences with
`regexp_matches` on a needle containing `(` or `)` counts the regex's groups, not the text -
measured 0 matches for a string that `replace()` found and rewrote. Count a literal substring
with `array_length(string_to_array(haystack, needle), 1) - 1`.

**A function name with two heads cannot be dropped, altered, or called by name.** With
`add_customer(text x10)` and `add_customer(text x13, boolean)` both installed, `DROP FUNCTION
add_customer` fails with "function name ... is not unique" (measured), and so does every call
whose positions both candidates accept. A collapse migration must name the full old signature
of every head it removes - and the register view shows the same fact from a different angle:
`vw_idempotency_status` emits one row per function *object*, so a domain function that appears
twice there is a fork, not a duplicate query.

**Two backend processes are how a race gets measured here, and the container filesystem is not
yours.** `docker compose exec -T postgres psql ... -f /tmp/opencode/x.sql` fails with "No such
file or directory": the host path is not mounted in the container. Pipe the script in on stdin
(`-f /dev/stdin < file`) and run the two sessions with `&` plus `wait`. That is how 0016 proved
what the idempotency claim is for: keyless, two calls one second apart leave 2 entities and 2
contacts; keyed, one customer and both callers answered the same `entity_id`, because the second
claim INSERT waits on the arbiter's unique index.

**A refusal chain answers with its first rule, not the one you are testing.** `add_customer`
checks names before contact points, so an all-NULL call reports "First name is required", not
"At least one of email or phone is required" - a probe asserting the second message fails while
the function behaves perfectly. Give the fixture only the defect under test, and when a probe's
verdict depends on *which* guard fired, assert the message as well as the outcome.

**A migration cannot open a second connection, so some assertions belong in CI instead.**
pgvector and pg_trgm are the only extensions 0000 installs: no `dblink`, no `postgres_fdw`, and
a `SET LOCAL ROLE` probe still runs in the same backend. Anything whose claim is about two
transactions at once - a claim that serialises, a lease that expires mid-write - can be measured
from this host but not shipped as a check, and the honest place for it is T3's replay job, not a
probe that looks like it tested something.

**A `LIMIT` inside a view is a filter that runs before yours.** `SELECT ... ORDER BY t DESC
LIMIT 100` in a view definition means a caller's `WHERE bot_id = 'x'` is applied to the 100 rows
the view already chose, not to the table. Measured with 5 old rows and 4 newer ones: the view
returned **0 rows** for the older bot while the table held 5. The order a view promises is not a
property it can hold either - an outer plan may re-sort - so the fix is to put neither the `LIMIT`
nor the `ORDER BY` in the view and show both in the documentation instead (0017).

**Fan-out makes a per-row number into a per-element number.** `jsonb_array_elements` over a
jsonb array column joins one row of the base table to N rows, so `avg(run_duration)` and
`SUM(error IS NOT NULL)` computed in that query are weighted by how many steps each run happened
to have. Measured: one errored run that used three tools printed `error_count = 3`, and a 900 ms
run beside a 100 ms one printed 700 ms where the mean of the two runs is 500. Aggregate the
elements separately from the rows: deduplicate back to `(group, row id)` with a second CTE, then
average that. And name the grain in the column, because a reader cannot tell from `avg_duration_ms`
which question was asked.

**`pg_depend` will not tell you which views read a table if you ask it with `classid = 'pg_class'`.**
A view's dependency on a base table is recorded against its `pg_rewrite` rule, per column, with
`refclassid`/`refobjid`/`refobjsubid`; the `pg_class` form returns zero rows and looks like an
answer. The census that finds dependents is `pg_depend JOIN pg_rewrite ON oid = objid JOIN
pg_class ON oid = ev_class`, and it repeats a view once per referenced column, which is why the
list is longer than the number of views.

**`count()` is not `count(*)`, and a scalar JSONB value has no key to index.** PostgreSQL refuses
bare `count()` as a parameterless aggregate (42601), so a hand-written view fails at creation with
a message that reads like a syntax slip. Separately: if a view projects `value -> 'output'`, it has
projected the *element's* field, but if it projects the output **value** - as `vw_tool_calls` does -
then `observation ->> 'output'` is always NULL, because a JSONB string has no keys, and the read is
`observation #>> '{}'`. Both mistakes were made in 0017's rehearsal and neither looked like what it
was in the failure output.

**A `RAISE` with the wrong number of arguments is reported at an unrelated line.** The compiler
pairs `%` placeholders with the argument list, and when a message is concatenated across several
lines it is easy to add an argument and not a placeholder: the error is
`too many parameters specified for RAISE`, and `psql` points at the `DO $$` - not the statement.
Count them before rehearsing, or grep the file for RAISEs whose placeholder and argument counts
disagree.

**A `code:` marker with no branch in `closed()` is inert, and the harness reads it as a finding.**
`_common.sh`'s `closed()` matches `code:*` with a catch-all that answers "not applied", so a CASES
row mapped to a marker nobody wrote is KNOWN-OPEN forever with a migration name attached that does
not exist. That is the right verdict for the wrong reason - the same failure as a test that passes
because a branch was skipped, wearing the opposite sign. `db/MIGRATIONS.md`'s marker table has a
"Watched by" column for this: say what greps the tree, or say "nothing yet".

**A probe that reads an aggregate view cannot filter by the row it inserted.** `vw_tool_performance`
is grouped by tenant and tool, so `WHERE run_id = ...` is not available and the assertion silently
sums every fixture in the database - including the ones earlier migrations left in
`agent_interactions`. Give each probe its own invented dimension values (0017 uses `c_lookup`,
`b_update` as tool names) so the number it reads is the number it caused. This is 0013's
"assert per-subject, never totals" for the case where the view has no subject to name. The same trap
has a second form, found at 0018: a probe that reports a *disagreement count* across the whole
schema will count the disagreements its own earlier probes manufactured on purpose, so the report
prints "1" on a clean database forever. Exclude the fixtures by their probe marker (`sku NOT LIKE
'0018-%'`) **and** assert that the excluded set is non-empty, so the exclusion cannot become a way of
making the number quietly disappear (0018's probe K does both).

**A column DEFAULT cannot read another column of its own row, and a generated column cannot read
another table.** `ALTER TABLE t ALTER COLUMN c SET DEFAULT f(other_id)` fails with `cannot use column
reference in DEFAULT expression`, and the subquery shape that suggests itself next fails with
`cannot use subquery in DEFAULT expression`. A generated column *can* name a same-row column, but its
expression must be immutable (`42P17`), and the only way past that is to mark a table-reading function
`IMMUTABLE` - which PostgreSQL accepts, and which then stores a value that goes stale on every edit to
the table it read. So "derive this column from that one" has exactly two homes in this schema: a
trigger, or the body that writes the row. 0018 chose the bodies, and chose a census probe over a
guarantee, and says so in its §0 (0018).

**Dropping and recreating a view restores the dependency that blocked your ALTER.** `ALTER COLUMN
... TYPE` is refused outright while any view reads the column (`cannot alter type of a column used by
a view or rule`, 0A000), so the pattern is capture, drop, alter, recreate. Doing that *one view at a
time* gets you exactly one ALTER in: recreating the first view re-establishes a dependency on the
column the second ALTER needs. Order is capture-all, drop-all, alter-all, recreate-all (0018 §4). And
when you ask `pg_depend` whether anything depends on a view, exclude the view itself - its `_RETURN`
rule is recorded as a dependent of it, so a naive census reports every view you are about to drop as
blocking its own drop.

**A unique index on a partitioned table must include the partition key, and the version that does is
a different promise.** `UNIQUE (a, b) WHERE open IS NULL` says "at most one live row per pair". On a
table partitioned by range over a *third* column, that index will not build, and the variant that
includes the partition key lets the same pair hold an open row in each partition. Partitioning an
append-only history table therefore quietly removes the arbiter it was written to have. Measured on a
scratch table (0018's Obligations), because this is the kind of constraint that reads fine in a plan
and fails in a migration.

**A foreign key check does not apply row-level security.** A derived value that comes from a row the
caller cannot see is derived from *nothing*: the lookup returns NULL, the referencing FK sees a valid
code, and the row lands. 0018's probe G' expected `23502` from this and got a successful INSERT
instead. Anything that reads a tenant-coded table must be `SECURITY INVOKER` for that reason, and
"the FK will catch it" is not true of a value, only of a key.

**Widening a candidate rule surfaces what it was skipping, including your own new table.**
`vw_domain_vocabulary`'s filter was `atttypid IN ('text','varchar')` plus a name shape, so the
`char(3)` currency columns were invisible to the view whose job is to report unconstrained domain
columns - and the moment bpchar was added to the list, `currencies.currency_code` appeared in it as
`UNDECIDED`, because a code table's key had started to look like a vocabulary. Master data is *values
referenced*, not a column that references, so the exemption is `c.oid NOT IN (derived code tables)`,
derived rather than named: the same fix as B19's global-table declaration and for the same reason (a
list nobody checks falls behind). The pair `verify.sh`'s B18 and the register are two implementations
of that one sentence, which is why both changed in the same commit (0018 §5).

**`char` blank padding makes a typo indistinguishable from its correction.** A row written as `'xt'`
into a `char(3)` matches `= 'xt'`, `= 'xt '` and `= 'xt  '` alike. Measured while writing 0018's
probe B. This is why the schema's currency vocabulary is now a membership FK with the ISO-4217 shape
CHECKed once on the master, rather than a shape CHECK repeated on every referencing column: four
copies of a rule is four chances to drift, and the width of a column was never the wall anyway.

**`now()` does not advance inside a transaction, so "did the trigger move `updated_at`?" is not a
question you can ask in a probe.** 0010's touch function *honours* a caller that names the column, so
the answerable pair is: an explicit value survives an UPDATE, and an unnamed UPDATE leaves the column
at the transaction's `now()`. The first draft of 0018's probe M asserted "it changed" and failed on
the clock rather than on the trigger (same trap `db/tests/6_3_timestamps.sql` documents; it is here
again because it is easy to fall into twice).

**A query alias that shadows a plpgsql variable is not an alias.** `FROM pg_trigger t` inside a block
that declared `t record` resolves `t.tgrelid` against the record and fails with `record "t" has no
field "tgrelid"`. Rename the alias (`tr`), not the variable. 0018 hit this in a probe and in a
`pg_namespace n` join in the same block that had `n` as a needle-loop column.
