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

## Two things that will bite you if you do not know them

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
