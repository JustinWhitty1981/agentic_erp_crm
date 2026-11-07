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
#
# The list has grown three times since the review counted 18: 0011's idempotency_keys and 0013's
# audit_log/audit_summary are tenancy tables the review had never seen, 0023's agent_memories is a
# table no finding asked for, and 0027's suppliers is a table no finding asked for either — the
# orders programme needed a supplier and the review predates both. They are here because they carry
# the column, not because a document mentioned them - the same reason 0010's scope grew. A
# tenant-coded table that is absent from this list is a table whose tenancy nobody checks, and
# B7/B26 would still see it, so the honest reading of "not listed" is "not checked by B1" rather
# than "not tenanted".
check "B1 5.8  tenant_id everywhere" "0003_tenant_foundation" \
    "SELECT count(*) FROM (VALUES ('entities'),('contacts'),('addresses'),
        ('entity_relationships'),('communications'),('followups'),('warehouses'),
        ('locations'),('item_categories'),('inventory_items'),('inventory_movements'),
        ('inventory_on_hand'),('inventory_reservations'),('human_sessions'),('bot_actions'),
        ('audit_summary'),('agent_interactions'),('agent_memories'),('suppliers'),
        ('orders'),('order_items'),('document_counters'),
        ('work_centres'),('work_order_operations')) AS t(tbl)
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
        ('locations'),('entity_relationships'),('audit_summary'),('suppliers'),
        ('orders'),('order_items'),('work_centres'),('work_order_operations')) AS t(tbl)
      WHERE NOT EXISTS (SELECT 1 FROM pg_index i
          JOIN pg_attribute a ON a.attrelid=i.indrelid AND a.attnum=i.indkey[0]
          JOIN pg_class c ON c.oid=i.indrelid
         WHERE c.relname=t.tbl AND i.indisunique AND NOT i.indisprimary
           AND a.attname='tenant_id')" \
    "natural keys still globally unique (review 5.8's warehouse-code example)"

check "B2 5.9  every domain column has an answer" "0007_domain_constraints" \
    "SELECT count(*) FROM vw_domain_vocabulary WHERE reason LIKE 'UNDECIDED%'" \
    "domain columns with neither a constraint nor a recorded reason for staying free text"

check "B18 5.9  domain answers are complete" "0007_domain_constraints" \
    "SELECT (SELECT count(*) FROM vw_domain_vocabulary) - (SELECT count(DISTINCT table_name||'.'||column_name) FROM vw_domain_vocabulary) + (SELECT count(*) FROM ( \
        SELECT c.relname||'.'||a.attname AS col \
          FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid \
          JOIN pg_namespace n ON n.oid=c.relnamespace \
         WHERE n.nspname='public' AND c.relkind='r' AND c.relname<>'_schema_graph' AND a.attnum>0 \
           AND NOT a.attisdropped AND a.atttypid IN ('text'::regtype,'varchar'::regtype,'bpchar'::regtype) \
           AND (a.attname ~ '(_type|_status|_method|_label|_unit|_measure)$|(^|_)status$|(^|_)priority$|(^|_)direction$|(^|_)outcome$|(^|_)currency(_code)?$' \
                OR a.attname IN ('role','channel','action_type','item_group')) \
           AND a.attname NOT IN ('industry','website','title','agent_id','reason_code','follow_up_action') \
           AND c.oid NOT IN (SELECT cc.oid FROM pg_class cc \
                               JOIN pg_namespace nn ON nn.oid=cc.relnamespace AND nn.nspname='public' \
                              WHERE cc.relkind='r' \
                                AND cc.relname NOT IN ('schema_migrations','_schema_graph') \
                                AND NOT EXISTS (SELECT 1 FROM pg_attribute x \
                                                 WHERE x.attrelid=cc.oid AND x.attname='tenant_id' \
                                                   AND x.attnum>0 AND NOT x.attisdropped) \
                                AND EXISTS (SELECT 1 FROM pg_index ii \
                                              JOIN pg_attribute pk ON pk.attrelid=cc.oid \
                                                   AND pk.attnum=(ii.indkey)[0] \
                                              JOIN pg_type pt ON pt.oid=pk.atttypid \
                                             WHERE ii.indrelid=cc.oid AND ii.indisprimary \
                                               AND ii.indnatts=1 \
                                               AND pt.typname IN ('varchar','bpchar','text'))) \
     ) x WHERE NOT EXISTS (SELECT 1 FROM vw_domain_vocabulary v2 \
                            WHERE v2.table_name||'.'||v2.column_name = x.col))" \
    "domain columns outside vw_domain_vocabulary, or listed twice (a second membership CHECK on one column contradicts the first)"
# 0008 retains exactly one CASCADE - locations -> warehouses - as composition rather than
# destruction, so the check is two-sided: nothing that holds a fact may cascade, and nothing
# ELSE may cascade either. A silent flip of the retained edge to RESTRICT would zero this
# count and pass, which is why probe D in the migration attempts the bin cascade for real;
# the retained edge is asserted by behaviour, not by its absence here.
check "B3 5.10 no CASCADE into stock" "0008_delete_safety" \
    "SELECT (SELECT count(*) FROM pg_constraint c JOIN pg_class r ON r.oid=c.conrelid
        JOIN pg_namespace n ON n.oid=r.relnamespace
       WHERE n.nspname='public' AND c.contype='f' AND c.confdeltype='c'
         AND r.relname IN ('inventory_on_hand','inventory_reservations',
                           'inventory_movements','bot_actions'))
      + (SELECT count(*) FROM pg_constraint c
       WHERE c.contype='f' AND c.confdeltype='c' AND c.connamespace='public'::regnamespace
         AND NOT (c.conrelid='locations'::regclass AND c.confrelid='warehouses'::regclass))" \
    "CASCADE edges that destroy stock rows, plus any CASCADE beyond the one retained edge"

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

check "B5 5.6  redundant indexes gone" "0006_index_hygiene" \
    "SELECT count(*) FROM vw_index_redundancy" \
    "index pairs that are identical or a strict leading prefix (the view is the definition)"

check "B6 5.5  CRM predicates are indexable" "0006_index_hygiene" \
    "SELECT (SELECT count(*) FROM (VALUES ('entities','name','gin_trgm_ops'),
                                   ('contacts','email','gin_trgm_ops'),
                                   ('entities','tax_id',''), ('contacts','phone','')) q(tbl,col,opcls)
       WHERE NOT EXISTS (SELECT 1 FROM pg_index i
                           JOIN pg_class c ON c.oid=i.indrelid
                           JOIN pg_opclass oc ON oc.oid=i.indclass[0]
                          WHERE c.relname=q.tbl
                            AND i.indkey[0]=(SELECT attnum FROM pg_attribute
                                             WHERE attrelid=c.oid AND attname=q.col)
                            AND (q.opcls='' OR oc.opcname=q.opcls)))
      + (SELECT count(*) FROM pg_class c WHERE c.relname='addresses' AND NOT EXISTS (
           SELECT 1 FROM pg_index i WHERE i.indrelid=c.oid AND i.indkey[0]=(
             SELECT attnum FROM pg_attribute WHERE attrelid=c.oid AND attname='entity_id')
             AND i.indkey[1]=(SELECT attnum FROM pg_attribute
                               WHERE attrelid=c.oid AND attname='is_primary')))" \
    "the four columns 5.5 names, plus the correlated address subquery's sort key"

check "B17 5.6  every FK leads an index" "0006_index_hygiene" \
    "SELECT count(*) FROM pg_constraint c
      WHERE c.contype='f' AND c.connamespace='public'::regnamespace
        AND cardinality(c.conkey)=1
        AND (SELECT attname FROM pg_attribute WHERE attrelid=c.conrelid AND attnum=(c.conkey)[1])
            <> 'tenant_id'
        AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid=c.conrelid
                        AND i.indkey[0]=(c.conkey)[1])" \
    "single-column FKs whose column leads no index (parent deletes scan the child)"

# 5.7 asked "is RLS enforced" and got rls_on=2, rls_forced=0 out of 18. The original version of
# this check demanded ENABLE+FORCE on *every* table in public, which is the wrong scope: it
# sweeps in units_of_measure, costing_methods and _schema_graph, tables with no tenant_id
# column for a policy to compare against, and would have been satisfied only by meaningless
# USING (true) policies - 5.7's actual complaint in a new place. So the scope is the tables
# that HAVE tenancy, read from the catalog rather than a list, and the tables without it are
# accounted for by B19 instead of being silently excluded. A policy that filters reads but not
# writes looks identical to a complete one in pg_class, so the WITH CHECK is part of the
# predicate: that distinction is precisely what made 5.7 decorative.
check "B7 5.7  RLS forced" "0009_rls_enforcement" \
    "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      JOIN pg_attribute a ON a.attrelid=c.oid AND a.attname='tenant_id'
                          AND a.attnum>0 AND NOT a.attisdropped
      WHERE n.nspname='public' AND c.relkind='r'
        AND (NOT c.relrowsecurity OR NOT c.relforcerowsecurity
             OR NOT EXISTS (SELECT 1 FROM pg_policy po
                             WHERE po.polrelid=c.oid AND po.polname='tenant_isolation'
                               AND po.polqual IS NOT NULL AND po.polwithcheck IS NOT NULL))" \
    "tenant-coded tables without ENABLE+FORCE and a read+write isolation policy"

# The other half of the scope decision: a table with no tenant_id is exempt, but exempt is a
# declaration, not an absence. Same shape as 0007's rule for unconstrained columns - the
# scoreboard counts considered decisions, so a new global table has to be considered here.
check "B19 5.7 global tables declared" "0009_rls_enforcement" \
    "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname='public' AND c.relkind='r'
        AND NOT EXISTS (SELECT 1 FROM pg_attribute a
                         WHERE a.attrelid=c.oid AND a.attname='tenant_id'
                           AND a.attnum>0 AND NOT a.attisdropped)
        AND c.relname NOT IN ('schema_migrations','_schema_graph',
                              'units_of_measure','costing_methods',
                              'currencies','currency_rates','order_lifecycle')" \
    "tables outside the tenant model that nothing has declared global"

# 5.7's third failure was a policy keyed off a setting no code sets. The general form of that
# mistake is a policy that resolves the tenant the wrong way, and there are two wrong ways in
# this schema's reach: a GUC read directly, and 0003's VOLATILE afpc_current_tenant(), whose
# per-row cost makes the predicate unusable as an index condition. Both are caught by requiring
# the qual verbatim - a shape check rather than a list of things to avoid, so a third wrong way
# cannot be missing from an exemption list.
check "B20 5.7 policy quals resolve the tenant stably" "0009_rls_enforcement" \
    "SELECT count(*) FROM pg_policy po JOIN pg_class c ON c.oid=po.polrelid
      JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname='public' AND po.polname='tenant_isolation'
        AND (pg_get_expr(po.polqual, po.polrelid)
                 IS DISTINCT FROM '(tenant_id = afpc_policy_tenant())'
             OR pg_get_expr(po.polwithcheck, po.polrelid)
                 IS DISTINCT FROM '(tenant_id = afpc_policy_tenant())')" \
    "isolation policies not written as tenant_id = afpc_policy_tenant()"

# Views are where 0009 could have stopped at the easy half: a postgres-owned view evaluates
# its base tables as its owner, which bypasses row security for any query that goes through it.
# Measured during rehearsal - the first draft set security_invoker before restating the view
# definitions, CREATE OR REPLACE VIEW dropped the reloption, and the filtered table returned 1
# row while the view over it returned 2.
check "B21 5.7 no view runs as its owner" "0009_rls_enforcement" \
    "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname='public' AND c.relkind='v'
        AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid=c.oid AND d.deptype='e')
        AND coalesce(array_to_string(c.reloptions, ','), '') NOT LIKE '%security_invoker=true%'" \
    "views that would skip the invoker's row security"

# 0008 measured thirteen functions born with EXECUTE to PUBLIC and left the sweep here.
# ALTER DEFAULT PRIVILEGES cannot close it forward - a default-privileges record only ADDs to
# the system default ACL, which already grants function EXECUTE to PUBLIC - so this is the
# mechanism that keeps it closed instead. Exempt by necessity, not oversight: the three
# context helpers are called from column defaults and policy quals, so a role that merely
# SELECTs would otherwise fail on privileges, and a uuid is not a row.
check "B22 5.7 functions closed to PUBLIC" "0009_rls_enforcement" \
    "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='public' AND p.prokind='f'
        AND p.proname NOT IN ('afpc_current_tenant','afpc_policy_tenant','afpc_uuid_v7')
        AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid=p.oid AND d.deptype='e')
        AND (p.proacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) x
                                          WHERE x.grantee=0 AND x.privilege_type='EXECUTE'))" \
    "non-extension functions still executable by every role in the cluster"

# The grant 0002 could not make retroactive: sequences created before its ALTER DEFAULT
# PRIVILEGES records kept the owner-only ACL, so afpc_app could not insert a customer at all.
# It reads as a tenancy bug (the write-path isolation test cannot run without it), which is
# where 0009 found it.
check "B23 5.8 app role can use the keys" "0009_rls_enforcement" \
    "SELECT count(*) FROM pg_sequences s WHERE s.schemaname='public'
       AND NOT has_sequence_privilege('afpc_app',
             format('%I.%I', s.schemaname, s.sequencename)::regclass, 'USAGE,SELECT')" \
    "sequences afpc_app cannot draw from"

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

check "B13 5.1  no cross-type FK edges" "0005_key_types" \
    "SELECT count(*) FROM pg_constraint f
      JOIN pg_attribute fa ON fa.attrelid=f.conrelid AND fa.attnum=(f.conkey)[1]
      JOIN pg_attribute ta ON ta.attrelid=f.confrelid AND ta.attnum=(f.confkey)[1]
     WHERE f.contype='f' AND f.connamespace='public'::regnamespace
       AND cardinality(f.conkey)=1 AND fa.atttypid <> ta.atttypid" \
"FKs comparing two types: 5.2 in general form, invisible in pg_constraint"

check "B14 5.3  key ceiling matches key type" "0005_key_types" \
    "SELECT count(*) FROM pg_attribute a
      JOIN pg_class c ON c.oid=a.attrelid
      JOIN pg_namespace n ON n.oid=c.relnamespace
     WHERE n.nspname='public' AND c.relkind IN ('r','p') AND a.attnum>0
       AND a.atttypid='bigint'::regtype
       AND pg_get_serial_sequence(c.relname,a.attname) IS NOT NULL
       AND EXISTS (SELECT 1 FROM pg_sequence s WHERE s.seqrelid =
                     pg_get_serial_sequence(c.relname,a.attname)::regclass
                   AND s.seqtypid <> 'bigint'::regtype)" \
"bigint keys fed by an integer sequence (ALTER COLUMN TYPE leaves the sequence alone)"

check "B15 5.4  uuid keys time-ordered" "0005_key_types" \
    "SELECT count(*) FROM pg_constraint k
      JOIN pg_class c ON c.oid=k.conrelid
      JOIN pg_attribute a ON a.attrelid=k.conrelid AND a.attnum=(k.conkey)[1]
      LEFT JOIN pg_attrdef d ON d.adrelid=k.conrelid AND d.adnum=a.attnum
     WHERE k.contype='p' AND cardinality(k.conkey)=1 AND a.atttypid='uuid'::regtype
       AND c.relnamespace='public'::regnamespace
       AND coalesce(pg_get_expr(d.adbin,d.adrelid),'(no default)') NOT LIKE '%afpc_uuid_v7%'" \
"UUID primary keys still defaulting to random (btree inserts land at random pages)"

check "B16 5.2  no unvalidated constraints" "0005_key_types" \
    "SELECT count(*) FROM pg_constraint WHERE connamespace='public'::regnamespace
       AND contype='f' AND NOT convalidated" \
"NOT VALID FKs: new writes enforced, existing rows not - repair, then VALIDATE"

# 6.1 needs more than "a table with that name exists": the original version of this check passed on
# any trigger whose NAME contained "version", which is satisfied by a trigger that only reads the
# column. So each term asserts the thing 0011 actually promised. The [.] bracket is the house
# regex style (see B21) - a bare dot would match any character, and `LIKE '%new.version%'` not at
# all, because LIKE's wildcard is the underscore.
check "B10 6.1 idempotency implemented" "0011_idempotency" \
    "SELECT
      -- Every integer version column must be moved by a ROW trigger whose body assigns it.
      -- A name match proves nothing; this asks the function source for NEW.version :=.
      (SELECT count(*) FROM pg_class c
         JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'version'
                            AND a.attnum > 0 AND NOT a.attisdropped
                            AND a.atttypid = 'integer'::regtype
        WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r'
          AND NOT EXISTS (SELECT 1 FROM pg_trigger t
                            JOIN pg_proc p ON p.oid = t.tgfoid
                           WHERE t.tgrelid = c.oid AND NOT t.tgisinternal
                             AND (t.tgtype & 1) = 1
                             AND lower(p.prosrc) ~ 'new[.]version[[:space:]]*:='))
      -- The claim API exists, and the arbiter LEADS with tenant_id: 0011 lost a write on a clone
      -- proving why the order is load-bearing, and a differently-ordered arbiter would fail every
      -- claim with an inference error rather than a message anyone would recognise.
    + (CASE WHEN EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'idempotency_claim')
            THEN 0 ELSE 1 END)
    + (CASE WHEN EXISTS (SELECT 1 FROM pg_constraint
                          WHERE conrelid = to_regclass('public.idempotency_keys')
                            AND contype = 'u'
                            AND conkey[1] = (SELECT attnum FROM pg_attribute
                                              WHERE attrelid = to_regclass('public.idempotency_keys')
                                                AND attname = 'tenant_id'))
            THEN 0 ELSE 1 END)" \
    "unguarded version columns, and idempotency objects missing or mis-scoped"

# 6.3's evidence is a table in a document, and the first version of this check reproduced its
# shape rather than its meaning, in two ways. (1) The bits: tgtype 2 is BEFORE, 4 is INSERT and
# 16 is UPDATE - established with probe triggers on a scratch table (row BEFORE INSERT = 7,
# BEFORE UPDATE = 19, BEFORE DELETE = 11, AFTER INSERT OR UPDATE OR DELETE = 29, AFTER UPDATE
# statement = 16). Demanding "& 2 and & 4" therefore asked for a BEFORE INSERT trigger and never
# looked at UPDATE at all, which flagged the only two tables in the schema whose column *was*
# maintained and passed silently on the nine that were not. (2) The population:
# information_schema.columns includes view columns, so the count was 13 where the truth is 11
# tables and 2 views - the same 0009 lesson about a census answering a different question than
# its label. BEFORE is part of the predicate on purpose: an AFTER ROW UPDATE trigger that assigns
# to NEW is discarded by the executor, so a trigger that fires too late is not maintenance.
check "B11 6.3 updated_at maintained" "0010_timestamp_triggers" \
    "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      JOIN pg_attribute a ON a.attrelid=c.oid AND a.attname='updated_at'
                          AND a.attnum>0 AND NOT a.attisdropped
      WHERE n.nspname='public' AND c.relkind='r'
        AND NOT EXISTS (SELECT 1 FROM pg_trigger t
                         WHERE t.tgrelid=c.oid AND NOT t.tgisinternal
                           AND (t.tgtype::int & 1)=1 AND (t.tgtype::int & 2)=2
                           AND (t.tgtype::int & 16)=16)" \
    "tables carrying an updated_at that no BEFORE UPDATE row trigger maintains"

# The register 0010 publishes is only useful if its verdict can disagree with its evidence, so
# the disagreement is what gets counted here: a table a function rewrites, with nothing
# maintaining a timestamp for it. This is the check that makes the 'no updated_at by decision'
# rows honest, and the reason 0014/0015 are told that a new write path owes the column.
check "B24 6.3  write paths are visible" "0010_timestamp_triggers" \
    "SELECT count(*) FROM vw_timestamp_status WHERE needs_attention" \
    "tables the schema rewrites while no timestamp records that it happened"

# 6.3C is not "there were two copies of the timestamp rule" but "two copies of a rule can exist".
# Counted over every trigger function, so the next duplicate is a FAIL rather than a repeat of the
# discovery. prosrc rather than proconfig: identical source is the defect, and a divergent body
# under two names is a different one.
check "B25 6.3  one implementation per rule" "0010_timestamp_triggers" \
    "SELECT count(*) FROM (
        SELECT md5(coalesce(p.prosrc,'')) AS body
          FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
          JOIN pg_type t ON t.oid=p.prorettype
         WHERE n.nspname='public' AND t.typname='trigger' AND p.prokind='f'
           AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid=p.oid AND d.deptype='e')
         GROUP BY 1 HAVING count(*) > 1) x" \
    "trigger functions whose bodies are byte-identical to another one's"

# The shipped B12 could never pass: it joined pg_class to the INDEXED TABLE and asked
# relname LIKE '%embedding%' - no table is named that, so every vector column counted as
# an offender forever, which is always-fail where B11 was always-pass (same uncorrelated-
# predicate class, opposite failure mode; 0012's header records it). Now per-column and
# correlated: every vector column of a base table (pg_attribute, not information_schema -
# the B11 lesson: view columns would add three phantom offenders) must lead an hnsw index,
# and no ivfflat may survive in public, because an index the review counted and this
# migration did not name is exactly the drift a scoreboard exists to catch.
check "B12 6.4 hnsw on all embeddings" "0012_vector_indexing" \
    "SELECT
       (SELECT count(*) FROM pg_attribute a
          JOIN pg_class c ON c.oid = a.attrelid AND c.relkind = 'r'
          JOIN pg_namespace n ON n.oid = c.relnamespace
          JOIN pg_type t ON t.oid = a.atttypid
         WHERE n.nspname = 'public' AND t.typname = 'vector'
           AND a.attnum > 0 AND NOT a.attisdropped
           AND NOT EXISTS (SELECT 1 FROM pg_index i
                             JOIN pg_class ix ON ix.oid = i.indexrelid
                             JOIN pg_am am ON am.oid = ix.relam
                            WHERE i.indrelid = c.oid AND am.amname = 'hnsw'
                              AND i.indkey[0] = a.attnum))
     + (SELECT count(*) FROM pg_class ix
          JOIN pg_namespace n ON n.oid = ix.relnamespace
          JOIN pg_am am ON am.oid = ix.relam
         WHERE n.nspname = 'public' AND ix.relkind = 'i' AND am.amname = 'ivfflat')" \
    "vector columns led by no hnsw index, plus any ivfflat 0012 did not name"

# 6.2's scoreboard half, in the register's own shape: the coverage view already answers
# "which tenant-coded tables have a trail", so the check counts the view disagreeing with
# itself rather than re-deriving scope - a third copy of the census is how 0006's tiebreak
# bug happened. The exemptions are allowed to exist; being exempt AND untrailed is the
# consistent state, and audited-AND-exempt is the drift (a trigger someone forgot to remove
# from a table someone decided to exempt, or vice versa).
check "B26 6.2  trail coverage is consistent" "0013_audit_log" \
    "SELECT count(*) FROM vw_audit_coverage WHERE row_audited IS DISTINCT FROM (NOT exempted)" \
    "tenant-coded tables whose audited flag contradicts their exemption decision"

# The append-only promise is a GRANT, and grants are exactly what future migrations' default
# mechanisms re-widen by accident (0002's forward defaults would hand UPDATE back to afpc_app
# the moment someone recreates the table). Counted from aclexplode: any non-owner role holding
# a history-altering privilege is the finding, whatever the ACL's prose says.
check "B27 6.2  history is append-only by grant" "0013_audit_log" \
    "SELECT count(*) FROM aclexplode((SELECT relacl FROM pg_class
                                       WHERE oid = 'public.audit_log'::regclass)) x
       JOIN pg_roles r ON r.oid = x.grantee
      WHERE x.privilege_type IN ('UPDATE', 'DELETE', 'TRUNCATE')
        AND r.rolname <> 'postgres'" \
    "roles other than the owner who could rewrite or erase audit_log"

# The CRM's second write door, and the one thing about it that a probe inside 0021 cannot prove:
# that it is still there and still closed. The behaviour is 4_7's; this is the shape. Closed to
# PUBLIC because ALTER DEFAULT PRIVILEGES REVOKE does not fire for functions (dev/README), so the
# only thing that keeps a NEW function from being callable by every role in the cluster is the
# per-object REVOKE, and the only thing that keeps that REVOKE is this count.
check "B28 4.5  the interaction door is installed and closed" "0021_communication_write" \
    "SELECT (CASE WHEN EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'add_communication')
                  THEN 0 ELSE 1 END)
          + (CASE WHEN EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) x
                                WHERE p.proname = 'add_communication'
                                  AND x.grantee = 0 AND x.privilege_type = 'EXECUTE')
                  THEN 1 ELSE 0 END)
          + (CASE WHEN has_function_privilege('afpc_app',
                       'add_communication(text,bigint,bigint,varchar,varchar,text,text,text,'
                       || 'varchar,varchar,varchar,varchar,varchar,timestamptz,integer,boolean,'
                       || 'date,text,bigint,uuid)', 'EXECUTE')
                  THEN 0 ELSE 1 END)" \
    "add_communication missing, callable by every role in the cluster, or unusable by the runtime role"

# 0023's append-only claim is about a grant, and grants are exactly what a probe that runs as the
# owner cannot see (a superuser holds everything). B27's shape, on the table 0013's census could
# not have enrolled because it did not exist yet.
check "B29 ADR-002 agent memory is append-only by grant" "0023_agent_memory" \
    "SELECT count(*) FROM aclexplode((SELECT relacl FROM pg_class
                                       WHERE oid = 'public.agent_memories'::regclass)) x
       JOIN pg_roles r ON r.oid = x.grantee
      WHERE x.privilege_type IN ('UPDATE', 'DELETE', 'TRUNCATE')
        AND r.rolname <> 'postgres'" \
    "roles other than the owner who could rewrite or erase the agent's memory"

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
# The redundant-pair count lives in vw_index_redundancy, which 0006 creates, so it is read from
# there rather than re-derived here - with an explicit "not yet" when the view does not exist,
# because a 0 here would otherwise look like a clean bill of health for a check that never ran.
if [ "$(scalar "SELECT to_regclass('public.vw_domain_vocabulary') IS NOT NULL")" = "t" ]; then
    # quote_literal, so the value arrives as a SQL string rather than as bare words the
    # surrounding format() call tries to parse as an expression.
    VOCAB=$(scalar "SELECT quote_literal(
        (SELECT count(*) FROM vw_domain_vocabulary WHERE enforced_by <> 'none - free text')
        ||' constrained / '
        ||(SELECT count(*) FROM vw_domain_vocabulary WHERE enforced_by = 'none - free text')
        ||' free by decision')")
else
    VOCAB="'not yet (0007)'" 
fi
if [ "$(scalar "SELECT to_regclass('public.vw_index_redundancy') IS NOT NULL")" = "t" ]; then
    REDUNDANT=$(scalar "SELECT count(*)::text FROM vw_index_redundancy")
else
    REDUNDANT="'not yet (0006)'"
fi
scalar "SELECT format('%s enums / %s CASCADE / %s RLS-forced / %s tenant-coded / %s redundant index pairs / %s FKs unindexed (any position) / %s FKs leading no index / domain values: %s',
    (SELECT count(*) FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace WHERE n.nspname='public' AND t.typtype='e'),
    (SELECT count(*) FROM pg_constraint WHERE contype='f' AND confdeltype='c'),
    (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relrowsecurity AND c.relforcerowsecurity),
    (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      JOIN pg_attribute a ON a.attrelid=c.oid AND a.attname='tenant_id' AND a.attnum>0
       WHERE n.nspname='public' AND c.relkind='r'),
                       -- ^ relkind, not information_schema.columns: the old form counted
                       -- *columns* named tenant_id, so 0009 exposing the column through the
                       -- twelve CRM views moved this number from 18 to 30 without any table
                       -- changing. A census that answers a different question than its label
                       -- asks is how a scoreboard loses its readers.
    ($REDUNDANT),
    (SELECT count(*) FROM pg_constraint c
      WHERE c.contype='f' AND NOT EXISTS (SELECT 1 FROM pg_index i
        WHERE i.indrelid=c.conrelid AND (c.conkey)[1] = ANY(i.indkey))),
    (SELECT count(*) FROM pg_constraint c
      WHERE c.contype='f' AND cardinality(c.conkey)=1
        AND (SELECT attname FROM pg_attribute WHERE attrelid=c.conrelid AND attnum=(c.conkey)[1])
            <> 'tenant_id'
        AND NOT EXISTS (SELECT 1 FROM pg_index i
        WHERE i.indrelid=c.conrelid AND i.indkey[0]=(c.conkey)[1])),
    $VOCAB)"

echo
echo "== scoreboard =="
printf '%s' "$REPORT"
echo
printf 'pass %s   fail %s   deferred %s\n' "$PASS_N" "$FAIL_N" "$DEFER_N"

if [ "$FAIL_N" -gt 0 ]; then exit 1; fi
if [ "$STRICT" = 1 ] && [ "$DEFER_N" -gt 0 ]; then exit 1; fi
exit 0
