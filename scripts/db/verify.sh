#!/usr/bin/env bash
# Structural assertions against the live catalog. This is the scoreboard for the
# remediation work: it reads DATABASE_REVIEW.md findings as executable checks.
#
#   scripts/db/verify.sh            report; exit non-zero if anything is FAIL
#   scripts/db/verify.sh --strict   also treat DEFERRED as failure
#
# A check is DEFERRED when the migration that closes it has not been applied yet,
# so the report distinguishes "known gap, still queued" from "supposed to be fixed
# and is not". Nothing here is inferred from files: every number comes from
# pg_catalog / information_schema on the running database.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

STRICT=0
[ "${1:-}" = "--strict" ] && STRICT=1

load_env
require_running
ensure_database

PASS_N=0; FAIL_N=0; DEFER_N=0
REPORT=""

row() { REPORT+=$(printf '%-34s %-6s %-46s %s' "$1" "$2" "$3" "$4")$'\n'; }

# check <id> <closed-by-migration> <sql yielding offending count> <note>
check() {
    local id="$1" fixed_by="$2" sql="$3" note="$4"
    local applied bad
    applied=$(closed "$fixed_by")
    if [ "$applied" = "0" ]; then
        row "$id" "DEFER" "closed by $fixed_by" "$note"; DEFER_N=$((DEFER_N+1)); return
    fi
    bad=$(scalar "$sql")
    if [ "$bad" = "0" ]; then
        row "$id" "PASS" "" "$note"; PASS_N=$((PASS_N+1))
    else
        row "$id" "FAIL" "$bad offender(s)" "$note"; FAIL_N=$((FAIL_N+1))
    fi
}

expect() {  # expect <id> <sql> <expected exact string> <note>
    local got; got=$(scalar "$2")
    if [ "$got" = "$3" ]; then
        row "$1" "PASS" "" "$4 ($got)"; PASS_N=$((PASS_N+1))
    else
        row "$1" "FAIL" "got $got want $3" "$4"; FAIL_N=$((FAIL_N+1))
    fi
}

# ---------- A. single home / build integrity -------------------------------------
expect "A1 no twin schema" \
    "SELECT count(*) FROM information_schema.tables
      WHERE table_schema NOT IN ('public','information_schema','pg_catalog')
        AND table_type='BASE TABLE'" 0 \
    "tables living outside public (review 3.1)"

expect "A2 migrations complete" \
    "SELECT CASE WHEN (SELECT count(*) FROM public.schema_migrations) >=
        (SELECT count(*) FROM pg_proc WHERE 1=0) + (SELECT count(*) FROM public.schema_migrations)
        AND (SELECT count(*) FROM public.schema_migrations) > 0 THEN 0 ELSE 1 END" 0 \
    "at least one migration applied (file-vs-db compared by migrate.sh)"

check "A3 no cross-schema refs" "0001_baseline_canonical_port" \
    "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='public' AND p.prosrc ~ 'agent_first_erp_crm[.]'" 0 \
    "function bodies qualified to the vestigial schema (review 4.5)"

expect "A4 canonical tables present" \
    "SELECT count(*) FROM (VALUES ('_schema_graph'),('agent_interactions'),('audit_summary'),
        ('bot_actions'),('human_sessions'),('contacts'),('entities'),('addresses'),
        ('communications'),('entity_relationships'),('followups'),('item_categories'),
        ('inventory_items'),('inventory_movements'),('inventory_on_hand'),
        ('inventory_reservations'),('warehouses'),('locations')) AS want(t)
      WHERE NOT EXISTS (SELECT 1 FROM information_schema.tables s
                        WHERE s.table_schema='public' AND s.table_name = want.t)" 0 \
    "canonical tables missing from public (review 1.3 counts 18)"

# 8 COMMENT ON VIEW statements in the source named pre-vw_-rename objects and failed
# silently under psql's default error handling, so those descriptions existed in no
# database built from it. Checked by name, not in aggregate: descriptions are how an
# agent discovers what a view is for, and a partial set is the failure mode.
check "A5 comments reattached" "0001_baseline_canonical_port" \
    "SELECT count(*) FROM unnest(ARRAY['vw_agent_activity_summary','vw_communication_thread',
        'vw_customer_communications_summary','vw_customers','vw_entity_communication_stats',
        'vw_primary_contact_communications','vw_recent_communications','vw_item_availability']::regclass[]) AS v(oid)
      WHERE obj_description(v.oid) IS NULL" \
    "views the source commented but never attached a description to"

check "A6 auditor read-only" "0002_access_grants" \
    "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname='public' AND c.relkind IN ('r','v')
        AND has_table_privilege('afpc_auditor', c.oid, 'INSERT, UPDATE, DELETE, TRUNCATE')" \
    "objects where the audit role holds a write privilege"

check "A7 auditor sees everything" "0002_access_grants" \
    "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname='public' AND c.relkind='r'
        AND NOT has_table_privilege('afpc_auditor', c.oid, 'SELECT')" \
    "base tables invisible to the audit role"

# ---------- B. remediation scoreboard ----------------------------------------------
# Review 5.8's measurement was "tenancy columns across all 18 tables: 0 rows returned",
# so this asserts against that same list rather than "every table in public", which
# would either fail on _schema_graph (schema metadata, deliberately not tenant-scoped)
# or force a meaningless column onto it. Checked as NOT NULL + FK + tenant-led index,
# because a nullable tenant_id with no constraint satisfies the review's wording and
# defeats its purpose.
check "B1 5.8  tenant_id everywhere" "0003_tenant_foundation" \
    "SELECT count(*) FROM (VALUES ('entities'),('contacts'),('addresses'),
        ('entity_relationships'),('communications'),('followups'),('warehouses'),
        ('locations'),('item_categories'),('inventory_items'),('inventory_movements'),
        ('inventory_on_hand'),('inventory_reservations'),('human_sessions'),('bot_actions'),
        ('audit_summary'),('agent_interactions')) AS t(tbl)
      WHERE NOT EXISTS (
        SELECT 1 FROM information_schema.columns c
         WHERE c.table_schema='public' AND c.table_name=t.tbl
           AND c.column_name='tenant_id' AND c.is_nullable='NO' AND c.data_type='uuid'
           AND c.column_default LIKE 'afpc_current_tenant%'
           AND EXISTS (SELECT 1 FROM pg_constraint k WHERE k.contype='f'
                         AND k.conrelid = format('public.%I', t.tbl)::regclass
                         AND k.confrelid = 'public.tenants'::regclass
                         AND k.conkey @> ARRAY[(SELECT attnum FROM pg_attribute
                                                 WHERE attrelid=format('public.%I',t.tbl)::regclass
                                                   AND attname='tenant_id')]::int2[])
           AND EXISTS (SELECT 1 FROM pg_index i
                        WHERE i.indrelid = format('public.%I', t.tbl)::regclass
                          AND i.indkey[0] = (SELECT attnum FROM pg_attribute
                                             WHERE attrelid=format('public.%I',t.tbl)::regclass
                                               AND attname='tenant_id')))" \
    "business tables lacking a NOT NULL, FK'd, indexed tenant_id"

# The point of 5.8's warehouse-code example: uniqueness must be per-tenant, or a second
# tenant can never reuse code MAIN. Asserted by key shape, not by index count.
check "B1b 5.8 natural keys tenant-scoped" "0003_tenant_foundation" \
    "SELECT count(*) FROM (VALUES ('warehouses'),('item_categories'),('inventory_items'),
        ('locations'),('entity_relationships'),('audit_summary')) AS t(tbl)
      WHERE NOT EXISTS (SELECT 1 FROM pg_index i
          JOIN pg_attribute a ON a.attrelid=i.indrelid AND a.attnum=i.indkey[0]
          JOIN pg_class c ON c.oid=i.indrelid
         WHERE c.relname=t.tbl AND i.indisunique AND NOT i.indisprimary
           AND a.attname='tenant_id')" \
    "natural keys still globally unique (review 5.8's warehouse-code example)"

check "B2 5.9  domain values constrained" "0007_domain_constraints" \
    "SELECT count(*) FROM information_schema.columns c
      WHERE c.table_schema='public' AND c.data_type IN ('character varying','text','character')
        AND (c.column_name IN ('status','channel','direction','outcome','priority','sentiment_label',
             'role','address_type','session_status','bot_type','action_type','movement_type',
             'reference_type','unit_of_measure','order_type','cost_method','item_group','product_type',
             'warehouse_type','location_type','base_uom','weight_unit','dimension_unit')
             OR c.column_name LIKE '%type' OR c.column_name LIKE '%status')
        AND c.column_default IS NULL
        AND NOT EXISTS (SELECT 1 FROM information_schema.table_constraints tc
                        JOIN information_schema.constraint_column_usage ccu
                          ON tc.constraint_name=ccu.constraint_name
                        WHERE tc.constraint_type IN ('CHECK','FOREIGN KEY')
                          AND ccu.table_name=c.table_name AND ccu.column_name=c.column_name)
        AND NOT EXISTS (SELECT 1 FROM information_schema.check_constraints ch
                        WHERE ch.constraint_schema='public'
                          AND position(c.column_name in ch.check_clause) > 0)" \
    "status/type columns with no CHECK and no lookup FK"

check "B3 5.10 no CASCADE into stock" "0008_delete_safety" \
    "SELECT count(*) FROM pg_constraint c JOIN pg_class r ON r.oid=c.conrelid
      JOIN pg_namespace n ON n.oid=r.relnamespace
      WHERE n.nspname='public' AND c.contype='f' AND c.confdeltype='c'
        AND r.relname IN ('inventory_on_hand','inventory_reservations','locations','movements')" \
    "CASCADE edges that destroy stock rows"

# 4.2 from the catalog side. Deliberately a different assertion from the one in 0004:
# the migration proves the arbiter is inferable (behaviour), this proves the constraint
# is tenant-scoped at all (structure). The original version of this check only counted
# key columns, which passed a 5-column index that made the function's upsert impossible.
check "B4 4.2  on-hand row identity" "0004_on_hand_identity" \
    "SELECT CASE WHEN EXISTS (
        SELECT 1 FROM pg_index i
          JOIN pg_class tc ON tc.oid = i.indrelid AND tc.relname = 'inventory_on_hand'
          JOIN unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord) ON true
          JOIN pg_attribute a ON a.attrelid = tc.oid AND a.attnum = k.attnum
         WHERE i.indisunique AND k.ord <= i.indnatts AND a.attname = 'tenant_id'
           AND (SELECT count(*) FROM unnest(i.indkey) j) >= 5
     ) THEN 0 ELSE 1 END" \
    "inventory_on_hand has no unique identity including tenant_id"

check "B5 5.6  duplicate indexes" "0006_index_hygiene" \
    "SELECT count(*) FROM (
       SELECT indrelid, indkey, count(*) FROM pg_index
        WHERE indrelid IN (SELECT oid FROM pg_class WHERE relnamespace=(SELECT oid FROM pg_namespace WHERE nspname='public'))
        GROUP BY indrelid, indkey HAVING count(*) > 1) d" \
    "identical index column sets on the same table"

check "B6 5.5  entities/contacts indexed" "0006_index_hygiene" \
    "SELECT (6 - (SELECT count(*) FROM pg_index i JOIN pg_class t ON t.oid=i.indrelid
                   JOIN pg_namespace n ON n.oid=t.relnamespace
                  WHERE n.nspname='public' AND t.relname IN ('entities','contacts') AND i.indnatts>=1
                    AND NOT i.indisprimary))::float/1" \
    "entities/contacts carry only their primary key"

check "B7 5.7  RLS forced" "0009_rls_enforcement" \
    "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname='public' AND c.relkind='r' AND c.relname<>'schema_migrations'
        AND (c.relrowsecurity = false OR c.relforcerowsecurity = false)" \
    "business tables without ENABLE+FORCE ROW LEVEL SECURITY"

check "B8 5.2  thread refs bigint+FK" "0005_key_types" \
    "SELECT count(*) FROM information_schema.columns
      WHERE table_schema='public' AND table_name='communications'
        AND column_name IN ('parent_id','thread_root_id') AND data_type <> 'bigint'" \
    "narrowing integer columns referencing a bigint key (latent 2^31)"

check "B9 5.3  no integer PKs" "0005_key_types" \
    "SELECT count(*) FROM information_schema.columns c
      JOIN information_schema.table_constraints t ON t.table_name=c.table_name AND t.constraint_type='PRIMARY KEY'
      JOIN information_schema.key_column_usage k ON k.constraint_name=t.constraint_name AND k.column_name=c.column_name
      WHERE c.table_schema='public' AND c.data_type='integer' AND c.column_name LIKE '%id'" \
    "integer primary keys on tables that grow with tenant count"

check "B10 6.1 idempotency implemented" "0011_idempotency" \
    "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_class WHERE relname='idempotency_keys')
        AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgname LIKE '%version%')
       THEN 0 ELSE 1 END" \
    "ADR-005 table and version triggers"

check "B11 6.3 updated_at maintained" "0010_timestamp_triggers" \
    "SELECT count(*) FROM information_schema.columns c
      WHERE c.table_schema='public' AND c.column_name='updated_at'
        AND NOT EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_class r ON r.oid=t.tgrelid
                         JOIN pg_namespace n ON n.oid=r.relnamespace
                        WHERE n.nspname='public' AND r.relname=c.table_name
                          AND NOT t.tgisinternal
                          AND (t.tgtype::int & 2) = 2   -- INSERT
                          AND (t.tgtype::int & 4) = 4)  -- UPDATE" \
    "tables whose updated_at silently goes stale"

check "B12 6.4 hnsw on all embeddings" "0012_vector_indexing" \
    "SELECT count(*) FROM information_schema.columns c
      WHERE c.table_schema='public' AND c.udt_name='vector'
        AND NOT EXISTS (SELECT 1 FROM pg_index i JOIN pg_class t ON t.oid=i.indrelid
                         JOIN pg_am am ON am.oid=t.relam
                        WHERE relname LIKE '%embedding%' AND am.amname='hnsw')" \
    "embedding columns with no hnsw index"

# ---------- C. live inventory ----------------------------------------------------
# Domain objects only. Extension-owned functions/views would swamp the signal: 194
# of the 204 functions in public belong to pgvector, and the counts below are the
# ones DATABASE_REVIEW.md 1.3 reports, so they have to be comparable.
echo
echo "== catalog (domain objects, extensions excluded) =="
scalar "WITH ext AS (SELECT classid, objid FROM pg_depend
                     WHERE refclassid = 'pg_extension'::regclass AND deptype = 'e')
SELECT format('%s tables / %s views / %s functions / %s FKs / %s triggers',
    (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname='public' AND c.relkind='r'
        AND c.relname NOT IN ('schema_migrations')
        AND NOT EXISTS (SELECT 1 FROM ext WHERE ext.classid='pg_class'::regclass AND ext.objid=c.oid)),
    (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname='public' AND c.relkind='v'
        AND NOT EXISTS (SELECT 1 FROM ext WHERE ext.classid='pg_class'::regclass AND ext.objid=c.oid)),
    (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='public' AND p.prokind='f'
        AND NOT EXISTS (SELECT 1 FROM ext WHERE ext.classid='pg_proc'::regclass AND ext.objid=p.oid)),
    (SELECT count(*) FROM pg_constraint c JOIN pg_namespace n ON n.oid=c.connamespace
      WHERE n.nspname='public' AND c.contype='f'),
    (SELECT count(*) FROM pg_trigger t JOIN pg_class r ON r.oid=t.tgrelid
       JOIN pg_namespace n ON n.oid=r.relnamespace
      WHERE n.nspname='public' AND NOT t.tgisinternal))"
# FK columns whose first column leads no index. This is a QUERY-PLANNING measure, not a
# correctness one: measured on this server, Postgres' FK mechanism uses any index that
# contains the column as a key column, in any position. Keep the two numbers distinct -
# conflating them caused 0004 to drop an index it should have kept.
scalar "SELECT format('%s enums / %s CASCADE / %s RLS-forced / %s tenant-coded / %s dup index sets / %s FKs unindexed (any position) / %s FKs not leading (planning only)',
    (SELECT count(*) FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace WHERE n.nspname='public' AND t.typtype='e'),
    (SELECT count(*) FROM pg_constraint WHERE contype='f' AND confdeltype='c'),
    (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relrowsecurity AND c.relforcerowsecurity),
    (SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND column_name='tenant_id'),
    (SELECT count(*) FROM (SELECT indrelid, indkey FROM pg_index
        WHERE indrelid IN (SELECT oid FROM pg_class WHERE relnamespace=(SELECT oid FROM pg_namespace WHERE nspname='public'))
        GROUP BY indrelid, indkey HAVING count(*)>1) d),
    (SELECT count(*) FROM pg_constraint c
      WHERE c.contype='f' AND NOT EXISTS (SELECT 1 FROM pg_index i
        WHERE i.indrelid=c.conrelid AND (c.conkey)[1] = ANY(i.indkey))),
    (SELECT count(*) FROM pg_constraint c
      WHERE c.contype='f' AND NOT EXISTS (SELECT 1 FROM pg_index i
        WHERE i.indrelid=c.conrelid AND i.indkey[0]=(c.conkey)[1])))"

echo
echo "== scoreboard =="
printf '%s' "$REPORT"
echo
printf 'pass %s   fail %s   deferred %s\n' "$PASS_N" "$FAIL_N" "$DEFER_N"

if [ "$FAIL_N" -gt 0 ]; then exit 1; fi
if [ "$STRICT" = 1 ] && [ "$DEFER_N" -gt 0 ]; then exit 1; fi
exit 0
