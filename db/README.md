# db/ — the single source of truth for schema

`db/migrations/` is the only place schema is defined. The three directories that used to
hold copies of the same DDL are superseded:

| Superseded | Was | Now |
|---|---|---|
| `blueprint/agent_swarm_schema.sql` | 1417-line older variant, byte-identical twin in `scripts/database/` | `0001_baseline_canonical_port.sql` |
| `scripts/database/agent_swarm_schema.sql` | same file, second copy | same as above |
| `docs/database/agent_first_erp_crm_schema.sql` | canonical 1947-line dump, referenced by a Makefile target that pointed at a path where it does not exist | `0001_baseline_canonical_port.sql` |
| `*/08_create_views.sql` (3 copies) | prefixed views; `vw_customers` filtered differently from the canonical one | views live in `0001` (see also 0009 for the `vw_customers` filter decision) |
| `*/09_*customer_functions.sql` (2 copies) | `add_customer` / `update_customer`, plus a `GRANT` to a role nothing created | `0001` carries the functions; grants in `0002`. The interaction door those files never had is `0021`'s |
| `*/10_audit_log.sql` (2 copies) | created `agent_first_erp_crm.audit_log` — the twin schema | `0013` (row-level audit in `public`) |
| `*/11_interaction_logging.sql` | unqualified, the only file that ever succeeded | `0001` |
| `*/setup_sample_data.sql` (3 copies) | **created a second copy of 8 tables** — the root of the schema split | `db/seeds/` (data only, never DDL) |

## Why the split happened

`setup_sample_data.sql:5` ran `CREATE SCHEMA agent_first_erp_crm` followed by
`CREATE TABLE IF NOT EXISTS agent_first_erp_crm.entities` and seven more. Seeding therefore
created the second schema, while `08`/`09`/`10` assumed it already existed — so migrate
could never pass before seed, and seed created the fork the tools then hard-coded. Seed
files in this directory must never contain DDL.

## Conventions

- Filenames `NNNN_short_name.sql`, applied in lexicographic order by `scripts/db/migrate.sh`.
- One migration per finding, so `scripts/db/verify.sh` can map a check to the migration
  that closes it and report PASS / FAIL / DEFERRED honestly.
- Forward-only. Never edit an applied migration: `migrate.sh` stores a checksum and will
  refuse to proceed on drift.
- Numbers are assigned at the time of writing, not reserved in advance. `migrate.sh` rejects any
  file numbered at or below the highest applied version, so a migration that exists only as a row
  in `db/MIGRATIONS.md` is a plan with a number that can be taken by accident: when `0021`-`0023`
  were applied, the planned `0019`/`0020` became impossible to apply to this database and moved to
  `0024`/`0025`. If a planned migration is referenced in the prose of an applied one - `0013`
  names `0019` four times as the partitioning decision - the reference is to the decision, and
  `db/MIGRATIONS.md` says which file now carries it.
- Wrap in a transaction by default. A file may opt out with a `migrate:no-transaction`
  line in its first 30 statements, which `CREATE INDEX CONCURRENTLY` requires.
- Roles are cluster-level and do not belong here: see `scripts/db/roles.sql`.

## Seeds

`db/seeds/` holds development data and nothing else. `scripts/db/seed.sh` applies every
`*.sql` there in filename order, so a seed is re-runnable by contract: a file that cannot be
run twice is a file that breaks the rebuild loop, and `add_customer` refuses a duplicate rather
than absorbing one, so the guard is a `NOT EXISTS` on the identifying contact, never an
`ON CONFLICT` around a function call.

Two rules follow from how the rest of this directory works. A seed sets `app.tenant_id`
explicitly even though `init.sh` mirrors `app.default_tenant_id` with `ALTER SYSTEM`, because
relying on the fallback is the mistake review 2.3 was written to close. And a seed writes
through the doors, not around them: a direct `INSERT` would let broken validation reach the
demo data, and the customer service agent would meet a database whose real behaviour differs
from the one the tools are tested against. The exceptions are stated in the file - a backdated
`created_at` is something no door can express.

## Status

Applied to the development server with `make db-migrate`. Verify with `make db-verify`,
execute the functions with `make db-test`.
