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
| Not here | the LiteLLM database (`litellm-db-1`) publishes no host port and is on its own network; nothing in this setup reads or routes to it |

## Auditing from any server on the network

Credentials are in `dev/.env` (`AFPC_AUDITOR_PASSWORD`). Copy the CA once — it is the
public half, and it is what lets you confirm you are talking to this database:

```bash
scp justin@192.168.0.53:~/agent-workspace/projects/agent_first/dev/tls/afpc-ca.crt .
psql "host=192.168.0.53 port=5432 dbname=agent_first_erp_crm user=afpc_auditor \
      sslmode=verify-full sslrootcert=afpc-ca.crt"
```

`192.168.0.53` is the LAN address; the same port answers on the tailnet address
`100.70.251.57`. If you would rather not distribute the CA, `sslmode=require` works
but does not verify the certificate.

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

Thirty-one of these, each learned by a check failing on a rehearsal or a
migration after the fact - not by reading documentation about the database. Keep the pattern: when a migration surprises
you, the surprise goes here, and the check that would have caught it goes in verify.sh.

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
