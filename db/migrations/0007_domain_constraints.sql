-- 0007: define what the status and type columns may contain
-- (DATABASE_REVIEW.md 5.9; plan P4).
--
-- 5.9 counts 31 free-text domain columns and 0 enums, and makes the argument that matters:
-- "Nothing distinguishes active / Active / ACTIVE / cancelled / canceled." That is not a
-- tidiness complaint. Three consequences in this schema are already real:
--
--   * vw_customers filters `entity_type = 'customer'` and add_customer writes `entity_type =
--     'customer'`, so those agree - but nothing says they MUST, and add_customer's
--     p_entity_type ('individual' | 'business') is tested by the function and then never
--     stored, so the axis the parameter names is invisible to the database entirely.
--   * get_followup_customers branches on `rec.status = 'follow-up'`, where rec.status is
--     entities.status, whose only documented values are active / inactive / blacklisted
--     (docs/database/schema.md:43). No code in the repository writes 'follow-up'. The most
--     prominent reason the follow-up tool advertises to an agent -
--     blueprint/tools/followup_customers.py:36, "Their status is marked as 'follow-up'" - is
--     reachable only by a value the schema does not define. This is 5.9's abstract point as a
--     live defect, and it is recorded against 0014 in db/MIGRATIONS.md.
--   * execute_inventory_movement branches on ('RECEIPT','RETURN') and ('ISSUE','ADJUSTMENT')
--     while schema.md:352 documents the vocabulary as including 'TRANSFER' and 'RESERVATION'.
--     A movement_type outside those four literals is accepted by the insert and updates no
--     stock. That is finding 4.6, and it is unfixable while the vocabulary is undeclared:
--     "handled" and "not handled" cannot be distinguished.
--
-- THE RULE THIS MIGRATION APPLIES, AND WHY IT IS NOT "ADD A CHECK EVERYWHERE"
--
--   Membership is asserted with a CHECK where the repository can name the COMPLETE set: a
--   documented value list, or a value the code branches on. Both are claims about this codebase,
--   so they belong in DDL, and an unexpected value is then a bug rather than a row.
--
--   Membership is asserted with a lookup table where the set names something in the world that
--   grows - a unit of measure, a costing method. Those are master data: the review's phrase for
--   this layer. Being wrong about one of these should cost an INSERT, not a migration, because a
--   deployment that cannot record a weight in pounds has an outage with a DDL dependency.
--
--   Neither, where the set genuinely belongs to whatever is installed rather than to the schema -
--   an agent's action_type names a tool, and a tool can be added without touching the database.
--   Those are left as free text and SAY SO in vw_domain_vocabulary, so the count of unconstrained
--   columns in 5.9 becomes a count of considered decisions rather than of oversights. Silently
--   CHECKing action_type would break every new agent tool; silently skipping it would look the
--   same in the scoreboard. Only the second is recoverable, and only the first is honest about it.
--
-- The sets below cite their evidence in the constraint comment itself, so an operator asking
-- "why is CROSS_DOCK not allowed?" gets an answer from the catalog rather than from a changelog.
-- Where the evidence is a documentation line, it is quoted as such; where it is the code, the
-- function is named. Two of these lists are therefore longer than schema.md's (RETURN, which the
-- code writes, and follow-up, which the code reads); none is longer than the evidence allows.
--
-- WHAT THIS DOES NOT DO
--
--   * It does not convert any column to an enum. 5.9 notes "0 enums" but an enum is the wrong
--     tool here: adding a value needs a migration, an enum cannot be restricted per tenant, and
--     the label would then be its own type in every view signature - 0005's view machinery
--     multiplied by fifteen. The review's finding is that the VALUES are undefined, not that
--     the TYPE mechanism is wrong.
--   * It does not add `follow-up` to entities.status as a *feature* - it is admitted because the
--     code reads it, so excluding it would make that branch provably dead rather than visible.
--   * It does not touch entity_relationships.role or inventory_items.item_group. Both are named
--     by 5.9's sample list and both are descriptions, not codes: schema.md:77 gives the examples
--     "Procurement Manager" and "Owner" for a field the functions populate with 'Customer' and
--     'Business Contact'. Constraining them would be an inventory of every job title on earth.

SET client_min_messages TO notice;

-- ---------------------------------------------------------------------------
-- 1. The two vocabularies that are master data
-- ---------------------------------------------------------------------------
-- Reference tables, not business tables: like `tenants` they are global by construction, so
-- they carry no tenant_id (0003's rule is about rows that belong to someone; a kilogram does
-- not). That exception is stated in the table comment because the alternative - each tenant
-- redefining what a kilogram is - is not a thing anyone wants to debug.

CREATE TABLE IF NOT EXISTS units_of_measure (
    uom_code     varchar(20)  PRIMARY KEY,
    label        text         NOT NULL,
    uom_kind     varchar(20)  NOT NULL DEFAULT 'QUANTITY'
                              CHECK (uom_kind IN ('QUANTITY','WEIGHT','DIMENSION','VOLUME','TIME')),
    -- 6.3's updated_at finding does not apply to reference data that is edited by a
    -- migration rather than by an operator, but is_active lets a deployment retire a unit
    -- without deleting rows that inventory_items still point at (see RESTRICT below).
    is_active    boolean      NOT NULL DEFAULT true,
    created_at   timestamptz  NOT NULL DEFAULT now()
);

COMMENT ON TABLE units_of_measure IS
    'Master data: the units an item can be counted, weighed or measured in. Referenced by '
    'inventory_items.base_unit_of_measure, inventory_items.weight_unit, '
    'inventory_items.dimension_unit and inventory_movements.unit_of_measure. Global reference '
    'data, deliberately not tenant-scoped: a kilogram is the same in every tenant. Adding a '
    'unit is an INSERT, not a migration - which is the whole reason this is a table and not a '
    'CHECK. Built by 0007 (review 5.9).';

CREATE TABLE IF NOT EXISTS costing_methods (
    cost_method_code  varchar(20)  PRIMARY KEY,
    label             text         NOT NULL,
    is_active         boolean      NOT NULL DEFAULT true,
    created_at        timestamptz  NOT NULL DEFAULT now()
);

COMMENT ON TABLE costing_methods IS
    'Master data: how an item''s cost is derived. Referenced by inventory_items.cost_method and '
    'item_categories.default_cost_method - the same vocabulary in two columns, which is the '
    'second reason this is a table: a CHECK would state the list twice and let the two copies '
    'drift. Global reference data. Built by 0007 (review 5.9).';

INSERT INTO units_of_measure (uom_code, label, uom_kind) VALUES
    -- 'EACH', 'KG' and 'CM' are the codes this repository already writes; the rest are the
    -- units those three imply (schema.md's item and movement blocks weigh in KG and measure in
    -- CM, and a movement's unit_of_measure is NOT NULL, so SOME set exists implicitly).
    ('EACH', 'Each',       'QUANTITY'),
    ('SET',  'Set',        'QUANTITY'),
    ('PCS',  'Piece',      'QUANTITY'),
    ('HR',   'Hour',       'TIME'),
    ('DAY',  'Day',        'TIME'),
    ('KG',   'Kilogram',   'WEIGHT'),
    ('G',    'Gram',       'WEIGHT'),
    ('LB',   'Pound',      'WEIGHT'),
    ('OZ',   'Ounce',      'WEIGHT'),
    ('M',    'Metre',      'DIMENSION'),
    ('CM',   'Centimetre', 'DIMENSION'),
    ('MM',   'Millimetre', 'DIMENSION'),
    ('M3',   'Cubic metre','VOLUME'),
    ('L',    'Litre',      'VOLUME'),
    ('ML',   'Millilitre', 'VOLUME')
ON CONFLICT (uom_code) DO NOTHING;

INSERT INTO costing_methods (cost_method_code, label) VALUES
    -- AVERAGE is this schema's own default (schema.md:229, and the same default repeated as
    -- item_categories.default_cost_method); STANDARD and MOVING are the alternatives that
    -- default-cost-method-per-category only means something if a category can disagree.
    ('AVERAGE',  'Average cost'),
    ('STANDARD', 'Standard cost'),
    ('MOVING',   'Moving average'),
    ('FIFO',     'First in, first out'),
    ('LIFO',     'Last in, first out')
ON CONFLICT (cost_method_code) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. The vocabularies the repository can name in full
-- ---------------------------------------------------------------------------
-- One table of decisions, then one loop. The reason to drive it from a list rather than write
-- fifteen ALTER statements is that each entry also carries the evidence and the violation
-- report, and the loop applies the same policy to all of them: validate when the existing rows
-- agree with the documentation, install NOT VALID and name the disagreements when they do not.
-- 0005 established that pattern for a foreign key on a populated copy; it matters more here,
-- because a CHECK that fails on live data aborts the migration with no information about which
-- rows are wrong.
CREATE TEMP TABLE _afpc_0007_domains ON COMMIT DROP AS
SELECT * FROM (VALUES
     ('entities','entity_type',
      ARRAY['customer','vendor','prospect','employee'],
      'docs/database/schema.md:37 documents the set; add_customer writes ''customer'' and vw_customers filters on it')
    ,('entities','status',
      ARRAY['active','inactive','blacklisted','follow-up'],
      'docs/database/schema.md:43 documents active/inactive/blacklisted; follow-up is READ by get_followup_customers (0001:1288) and written by nothing - admitted so the branch is visible rather than provably dead')
    ,('contacts','status',
      ARRAY['active','inactive','blacklisted'],
      'no list is documented for contacts.status; the same party-lifecycle set as entities.status is the only evidence available, and its DEFAULT is ''active''')
    ,('addresses','address_type',
      ARRAY['billing','shipping','headquarters','mailing','home'],
      'docs/database/schema.md:97 documents the set; add_customer''s p_address_type DEFAULT is ''home''')
    ,('communications','communication_type',
      ARRAY['email','call','meeting','ticket','chat','note','telegram','sms'],
      'docs/database/schema.md:123 documents six; telegram and sms are added because this is a Telegram-integrated deployment and a channel absent from its own vocabulary is a constraint that will be bypassed rather than obeyed')
    ,('communications','direction',
      ARRAY['inbound','outbound','internal'],
      'docs/database/schema.md:124 documents the set; the tools write inbound and outbound')
    ,('communications','outcome',
      ARRAY['resolved','escalated','pending','closed'],
      'docs/database/schema.md:136 documents the set; vw_entity_communication_stats counts resolved and escalated, and the tools write pending and resolved')
    ,('communications','priority',
      ARRAY['low','medium','high'],
      'docs/database/schema.md:172 documents the set')
    ,('communications','sentiment_label',
      ARRAY['positive','neutral','negative','mixed'],
      'docs do not list it; the sample data uses positive and neutral, and a sentiment label that is not one of the classifier''s outputs is a bug worth refusing. NULL is allowed and is the common case')
    ,('followups','status',
      ARRAY['pending','completed','cancelled','overdue'],
      'docs/database/schema.md:173 documents pending/completed/cancelled; overdue is added because vw_pending_followups distinguishes overdue work, and a state a view reports cannot be undefined')
    ,('followups','priority',
      ARRAY['low','medium','high'],
      'docs/database/schema.md:172, and its DEFAULT is ''medium''')
    ,('human_sessions','session_status',
      ARRAY['active','completed','terminated','expired'],
      'docs/database/schema.md lists active/completed/terminated; expired is the fourth state any session with a login_time and no logout_time reaches')
    ,('human_sessions','bot_type',
      ARRAY['customer_service','inventory','communication','orchestrator','unknown'],
      'docs/database/schema.md gives "customer_service", "inventory" as examples (an example, not a list) and architecture.md names the four agent roles; unknown is for a row written before its bot was registered')
    ,('inventory_movements','movement_type',
      ARRAY['RECEIPT','ISSUE','TRANSFER','ADJUSTMENT','RESERVATION','RETURN'],
      'docs/database/schema.md:352 documents five; RETURN is written by execute_inventory_movement''s own branch (0001). Naming this set is what makes 4.6''s "a type that moves no stock" a declarable fact - TRANSFER and RESERVATION are in the vocabulary and in neither branch, which is 0014''s')
    ,('inventory_movements','reference_type',
      ARRAY['ORDER','PO','TRANSFER','ADJUSTMENT','TICKET'],
      'docs/database/schema.md:353 documents ORDER/PO/TRANSFER; ADJUSTMENT and TICKET are the reference types the other two movements that need no order would name')
    ,('warehouses','warehouse_type',
      ARRAY['PRIMARY','SECONDARY','TRANSIT'],
      'schema.md:267 defaults to PRIMARY and names no list; SECONDARY is what parent_warehouse_id on the same table implies, and TRANSIT is the only other type the schema''s own columns (no zone, no dock) can mean. Thinnest evidence in this file: the constraint comment carries it, and 0007 records it in db/MIGRATIONS.md')
    ,('locations','location_type',
      ARRAY['STORAGE','PICK','RECEIVING','SHIPPING','QUARANTINE'],
      'schema.md:299 defaults to STORAGE and names no list; the rest are the positions a bin can hold in the model the other location columns (aisle, rack, shelf, bin, zone) describe. Thin evidence - stated here so a deployment that needs a wider set knows it was a guess, not a specification')
    ,('inventory_items','product_type',
      ARRAY['STOCKED','SERVICE','CONSUMABLE','ASSEMBLY'],
      'schema.md defaults to STOCKED and names no list; SERVICE is the only type a stock table cannot hold, CONSUMABLE and ASSEMBLY are what reorder_point and the movement ledger imply exist. Thin evidence - stated here so a deployment that needs a wider set knows it was a guess, not a specification')
    ,('inventory_reservations','order_type',
      ARRAY['SALES','PURCHASE','TRANSFER','WORK','STOCK'],
      'reserve_inventory_for_order passes p_order_type straight through with no validation and no default, and reference_type''s documented ORDER/PO/TRANSFER are the same axis named twice. Thin evidence - stated here so a deployment that needs a wider set knows it was a guess, not a specification')
) AS d(tbl, col, allowed, evidence);

DO $$
DECLARE
    r           record;
    v_bad       text;
    v_nbad      bigint;
    v_con       text;
    v_list      text;
    v_ok        int := 0;
    v_notvalid  int := 0;
BEGIN
    FOR r IN SELECT * FROM _afpc_0007_domains ORDER BY tbl, col LOOP
        v_con  := r.tbl || '_' || r.col || '_allowed';
        v_list := (SELECT string_agg('''' || a || '''', ', ' ORDER BY a) FROM unnest(r.allowed) a);

        IF EXISTS (SELECT 1 FROM pg_constraint
                    WHERE connamespace = 'public'::regnamespace
                      AND conrelid = format('public.%I', r.tbl)::regclass AND conname = v_con) THEN
            RAISE NOTICE '%.%: constraint already present', r.tbl, r.col;
            CONTINUE;
        END IF;

        -- What the existing rows actually contain, before deciding anything. Reporting the
        -- distinct offenders rather than a count is the difference between a migration an
        -- operator can act on and one they have to debug at 2am.
        EXECUTE format(
            'SELECT count(*), coalesce(string_agg(v, '', '' ORDER BY v), '''') FROM '
            '(SELECT DISTINCT %I::text AS v FROM public.%I WHERE %I IS NOT NULL AND %I <> ALL(%L::text[])) x',
            r.col, r.tbl, r.col, r.col, r.allowed)
        INTO v_nbad, v_bad;

        IF v_nbad = 0 THEN
            EXECUTE format('ALTER TABLE public.%I ADD CONSTRAINT %I CHECK (%I IS NULL OR %I::text = ANY(ARRAY[%s]))',
                           r.tbl, v_con, r.col, r.col, v_list);
            v_ok := v_ok + 1;
        ELSE
            -- Same choice 0005 made for thread_root_id: enforce every new write, refuse to
            -- rewrite anyone's history, and say which values are the problem. A migration that
            -- aborts here would tell the operator nothing at all.
            EXECUTE format('ALTER TABLE public.%I ADD CONSTRAINT %I CHECK (%I IS NULL OR %I::text = ANY(ARRAY[%s])) NOT VALID',
                           r.tbl, v_con, r.col, r.col, v_list);
            v_notvalid := v_notvalid + 1;
            RAISE WARNING '%.% holds % value(s) outside the documented set: %. The CHECK is '
                          'installed NOT VALID - new writes are refused, existing rows are not. '
                          'Repair them, then ALTER TABLE %I VALIDATE CONSTRAINT %I.',
                          r.tbl, r.col, v_nbad, v_bad, r.tbl, v_con;
        END IF;

        EXECUTE format('COMMENT ON CONSTRAINT %I ON public.%I IS %L', v_con, r.tbl,
            'Review 5.9: ' || r.col || ' accepts only the values ' || v_list || '. Evidence: '
            || r.evidence);
    END LOOP;
    RAISE NOTICE '5.9: % membership checks added, % needing validation after a data repair',
        v_ok, v_notvalid;
END
$$;

-- ---------------------------------------------------------------------------
-- 3. The master-data foreign keys
-- ---------------------------------------------------------------------------
-- Four columns, two vocabularies. RESTRICT on delete: retiring a unit of measure is an
-- is_active flag, not the destruction of the items that were counted in it - which is the
-- 5.10 lesson applied before 0008 has to enforce it.
DO $$
DECLARE
    r        record;
    v_ref    text;
    v_idx    text;
    v_name   text;
BEGIN
    FOR r IN
        SELECT * FROM (VALUES
             ('inventory_items','base_unit_of_measure','units_of_measure','uom_code', true)
            ,('inventory_items','weight_unit','units_of_measure','uom_code', false)
            ,('inventory_items','dimension_unit','units_of_measure','uom_code', false)
            ,('inventory_movements','unit_of_measure','units_of_measure','uom_code', true)
            ,('inventory_items','cost_method','costing_methods','cost_method_code', true)
            ,('item_categories','default_cost_method','costing_methods','cost_method_code', false)
        ) AS t(tbl, col, reftbl, refcol, nn)
    LOOP
        v_name := r.tbl || '_' || r.col || '_fkey';
        IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = v_name
                     AND connamespace = 'public'::regnamespace) THEN
            RAISE NOTICE 'master data: %.% already references %', r.tbl, r.col, r.reftbl;
            CONTINUE;
        END IF;

        -- Leading coverage first: 0006 made "every foreign key leads an index" an invariant,
        -- and a migration that adds foreign keys without indexes would break the check that
        -- exists to catch exactly that.
        v_idx := 'idx_' || replace(r.tbl, 'inventory_', '') || '_' || r.col;
        EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON public.%I (%I)%s', v_idx, r.tbl, r.col,
                       CASE WHEN r.nn THEN '' ELSE ' WHERE ' || quote_ident(r.col) || ' IS NOT NULL' END);

        EXECUTE format('ALTER TABLE public.%I ADD CONSTRAINT %I FOREIGN KEY (%I) REFERENCES public.%I (%I) ON DELETE RESTRICT',
                       r.tbl, v_name, r.col, r.reftbl, r.refcol);
        RAISE NOTICE 'master data: %.% -> %.% (% index)', r.tbl, r.col, r.reftbl, r.refcol,
            CASE WHEN r.nn THEN 'plain' ELSE 'partial' END;
    END LOOP;
END
$$;

-- ---------------------------------------------------------------------------
-- 4. Publish the answer, for the agent as well as the auditor
-- ---------------------------------------------------------------------------
-- 5.9's finding is that an agent cannot know what to write. Adding fifteen CHECK constraints
-- fixes the database and leaves that second half unfixed: the values are now in pg_constraint,
-- which is not something a customer-service agent queries. This view is the same information in
-- the shape ADR-003 says to expose it in, so "what can I put in followups.status" is a SELECT.
--
-- It reads the constraints rather than restating the lists, which is the only reason a view like
-- this stays true: a hand-copied vocabulary drifts the first time someone validates a column
-- the migration forgot.
CREATE OR REPLACE VIEW vw_domain_vocabulary AS
WITH dom AS (
    -- Every domain-shaped text column in public, derived rather than listed. This is what makes
    -- the view safe to trust: a column nobody thought about appears here as "none - free text",
    -- and section 5 refuses to finish while such a row has no reason attached to it.
    SELECT c.relname::text AS table_name, a.attname::text AS column_name, c.oid AS reloid,
           a.attnum, a.attnotnull
      FROM pg_attribute a
      JOIN pg_class c ON c.oid = a.attrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relkind = 'r' AND a.attnum > 0 AND NOT a.attisdropped
       -- _schema_graph is the schema's own metadata table, outside the business model for the
       -- same reason 0003 left it out of tenancy: it describes the database, not the tenant.
       AND c.relname <> '_schema_graph'
       AND a.atttypid IN ('text'::regtype, 'varchar'::regtype)
       AND (a.attname ~ '(_type|_status|_method|_label|_unit|_measure)$|(^|_)status$|(^|_)priority$|(^|_)direction$|(^|_)outcome$'
            OR a.attname IN ('role','channel','action_type','item_group','unit_of_measure','base_unit_of_measure'))
       -- columns that merely end in a domain-ish word without naming a domain
       AND a.attname NOT IN ('industry','website','title','agent_id','reason_code','follow_up_action')
), chk AS (
    SELECT c.conrelid, (c.conkey)[1] AS attnum, c.conname, c.convalidated,
           (SELECT array_agg(m[1] ORDER BY m[1])
              FROM regexp_matches(pg_get_constraintdef(c.oid),
                                  E'\'([^\']+)\'::(character varying|text)', 'g') m) AS vals
      FROM pg_constraint c
     WHERE c.contype = 'c' AND c.connamespace = 'public'::regnamespace
       AND cardinality(c.conkey) = 1
       -- Two renderings, and a LIKE that spells only one of them silently reports the other
       -- form as "no constraint": a CHECK written as `= ANY(ARRAY[...])` prints as
       -- `= ANY (ARRAY['a'::text, ...])`, while one written with an explicit array cast prints
       -- as `= ANY ((ARRAY['a'::character varying, ...])::text[])`. 0003's tenants.status uses
       -- the second form and this migration's loop generates the first.
       AND pg_get_constraintdef(c.oid) ~ '= ANY \(\(?ARRAY\['
), lk AS (
    SELECT c.conrelid, (c.conkey)[1] AS attnum, c.conname, c.convalidated, c.confrelid
      FROM pg_constraint c
     WHERE c.contype = 'f' AND c.connamespace = 'public'::regnamespace
       AND c.confrelid IN ('units_of_measure'::regclass, 'costing_methods'::regclass)
), codes AS (
    SELECT 'units_of_measure'::regclass::text AS ref,
           array_agg(uom_code::text ORDER BY uom_code) AS vals FROM units_of_measure
    UNION ALL
    SELECT 'costing_methods'::regclass::text,
           array_agg(cost_method_code::text ORDER BY cost_method_code) FROM costing_methods
), reasons AS (
    -- The considered exceptions, keyed by column. Anything free-text that is NOT here is an
    -- oversight, and 5.2 says so rather than letting it read as a decision.
    SELECT * FROM (VALUES
      ('entity_relationships','role',
       'A job title, not a code: schema.md:77 gives "Procurement Manager" and "Owner" as examples '
       'and the functions write Customer and Business Contact. Enumerating job titles is an '
       'encyclopedia project, not master data.'),
      ('inventory_items','item_group',
       'A merchandising hierarchy owned by whoever installs the ERP, referenced by nothing. A CHECK '
       'here would be the first constraint a real deployment has to drop.'),
      ('bot_actions','action_type',
       'Names a tool, and a tool is added without touching the schema - constraining it would make '
       'every new agent a migration. The audit value of this column comes from the row that acted, '
       'not from the name of what was done.'),
      ('communications','channel',
       'Names an integration endpoint, which changes with deployments rather than with releases. '
       'communication_type carries the semantics queries depend on and is constrained.')
    ) AS r(tbl, col, reason)
)
SELECT d.table_name,
       d.column_name,
       CASE WHEN k.conname IS NOT NULL THEN 'check'
            WHEN l.conname IS NOT NULL THEN 'lookup table'
            ELSE 'none - free text' END                        AS enforced_by,
       coalesce(k.conname, l.conname)                          AS rule,
       coalesce(k.convalidated, l.convalidated, true)          AS enforced_on_existing_rows,
       CASE WHEN d.attnotnull THEN 'NULL refused' ELSE 'NULL allowed' END AS nulls,
       k.vals                                                  AS allowed_values,
       cd.vals                                                 AS lookup_values,
       l.confrelid::regclass::text                             AS lookup_table,
       coalesce(rs.reason,
                CASE WHEN k.conname IS NOT NULL OR l.conname IS NOT NULL THEN NULL
                     ELSE 'UNDECIDED - 5.9 asks why this column has no published answer' END) AS reason
  FROM dom d
  LEFT JOIN chk k     ON k.conrelid = d.reloid AND k.attnum = d.attnum
  LEFT JOIN lk  l     ON l.conrelid = d.reloid AND l.attnum = d.attnum
  LEFT JOIN codes cd  ON cd.ref = l.confrelid::regclass::text
  LEFT JOIN reasons rs ON rs.tbl = d.table_name AND rs.col = d.column_name;

COMMENT ON VIEW vw_domain_vocabulary IS
    'What each status/type column accepts, where that answer now lives, and why. enforced_by is '
    '''check'' (the value list is extracted live from pg_constraint), ''lookup table'' (the values '
    'are the current rows of the referenced code table) or ''none - free text'' with the reason it '
    'stayed open. One row per domain column in public, derived from the catalog, so a column '
    'nobody considered shows up as UNDECIDED rather than absent. Review 5.9''s finding is that an '
    'agent cannot know what to write; the constraints make the database correct and this view '
    'makes that correctness queryable. Built by db/migrations/0007_domain_constraints.sql.';

-- ---------------------------------------------------------------------------
-- 5. Verification
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v           bigint;
    v_total     bigint;
    v_free      bigint;
    v_declared  bigint;
    v_list      text;
BEGIN
    -- 5.1 Coverage, by construction rather than by counting. vw_domain_vocabulary's rows come
    --     from a catalog scan, so a domain column cannot be missing from it; the only way to be
    --     absent is to be excluded by the name filter, which 5.2 then cannot justify. Same shape
    --     of argument 0006 reached about index coverage: assert the invariant over the set the
    --     catalog defines, and the list of things you thought of stops being load-bearing.
    SELECT count(*) FILTER (WHERE enforced_by = 'check'),
           count(*) FILTER (WHERE enforced_by = 'lookup table'),
           count(*) FILTER (WHERE enforced_by = 'none - free text'),
           count(*)
      INTO v, v_total, v_free, v_declared FROM vw_domain_vocabulary;
    RAISE NOTICE '5.9: % columns CHECKed, % backed by master data, % free text by decision, '
                 '% domain columns declared in all', v, v_total, v_free, v_declared;

    -- 5.1b One column, one answer. A second membership CHECK on a column already constrained
    --     does not refine it, it contradicts it - and the contradiction only shows up when a
    --     legal row is refused, by whichever constraint the planner happens to evaluate first.
    --     The rehearsal caught it by accident: a probe constraint added alongside
    --     entities_status_allowed made the view print that column twice, with two different
    --     value sets, and 5.1's count quietly overstated coverage by one.
    SELECT count(*) INTO v FROM (
        SELECT table_name, column_name FROM vw_domain_vocabulary
         WHERE enforced_by = 'check'
         GROUP BY 1,2 HAVING count(*) > 1) d;
    IF v > 0 THEN
        RAISE EXCEPTION '% domain column(s) carry more than one membership constraint: %', v,
            (SELECT string_agg(table_name || '.' || column_name, ', ') FROM (
                SELECT table_name, column_name FROM vw_domain_vocabulary
                 WHERE enforced_by = 'check' GROUP BY 1,2 HAVING count(*) > 1) z);
    END IF;

    -- 5.2 The invariant 5.9 actually needs. Not "how many CHECKs exist" - "does every domain
    --     column have an answer, and is the answer justified". A column that is free text
    --     because nobody looked is indistinguishable from one that is free text by decision,
    --     unless the difference is asserted.
    SELECT count(*) INTO v FROM vw_domain_vocabulary
     WHERE reason LIKE 'UNDECIDED%' OR reason IS NULL AND enforced_by = 'none - free text';
    IF v > 0 THEN
        SELECT string_agg(table_name || '.' || column_name, ', ') INTO v_list
          FROM vw_domain_vocabulary
         WHERE reason LIKE 'UNDECIDED%' OR (reason IS NULL AND enforced_by = 'none - free text');
        RAISE EXCEPTION 'review 5.9: % domain column(s) have no published answer and no recorded '
                        'reason for being free text: %', v, v_list;
    END IF;

    -- 5.3 No column may default to a value its own constraint rejects. This is the failure mode
    --     a membership CHECK creates and a code table does not notice: the DDL that sets
    --     DEFAULT 'AVERAGE' and the INSERT that populates costing_methods are written in
    --     different sections of the same file, and nothing connects them. base_unit_of_measure
    --     defaults to EACH, which is why the seed says EACH - an earlier draft of this table used
    --     EA, and this check is what would have caught it.
    SELECT count(*) INTO v FROM (
        SELECT vv.table_name, vv.column_name,
               split_part(regexp_replace(pg_get_expr(d.adbin, d.adrelid), '''', '', 'g'), '::', 1) AS def_value,
               coalesce(vv.allowed_values, vv.lookup_values) AS may_hold
          FROM vw_domain_vocabulary vv
          JOIN pg_class c ON c.oid = vv.table_name::regclass
          JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = vv.column_name
          JOIN pg_attrdef d ON d.adrelid = c.oid AND d.adnum = a.attnum
         WHERE coalesce(vv.allowed_values, vv.lookup_values) IS NOT NULL
           AND pg_get_expr(d.adbin, d.adrelid) LIKE '%''%'
    ) q
     WHERE q.def_value <> ALL(q.may_hold);
    IF v > 0 THEN
        SELECT string_agg(table_name || '.' || column_name || ' defaults to ' || def_value ||
                          ' but may hold ' || array_to_string(may_hold, '/'), E'\n  ')
          INTO v_list
          FROM (
            SELECT vv.table_name, vv.column_name,
                   split_part(regexp_replace(pg_get_expr(d.adbin, d.adrelid), '''', '', 'g'), '::', 1) AS def_value,
                   coalesce(vv.allowed_values, vv.lookup_values) AS may_hold
              FROM vw_domain_vocabulary vv
              JOIN pg_class c ON c.oid = vv.table_name::regclass
              JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = vv.column_name
              JOIN pg_attrdef d ON d.adrelid = c.oid AND d.adnum = a.attnum
             WHERE coalesce(vv.allowed_values, vv.lookup_values) IS NOT NULL
               AND pg_get_expr(d.adbin, d.adrelid) LIKE '%''%'
          ) r
         WHERE r.def_value <> ALL(r.may_hold);
        RAISE EXCEPTION '% column(s) default to a value their own constraint rejects:%', v, v_list;
    END IF;

    -- 5.3b A lookup-backed column whose table is empty would reject every insert the moment the
    --      FK lands. Checked, because seeding is the part of a migration that a re-run of an
    --      ON CONFLICT DO NOTHING silently skips.
    IF (SELECT count(*) FROM units_of_measure) < 3 OR (SELECT count(*) FROM costing_methods) < 3 THEN
        RAISE EXCEPTION 'the master-data tables are not seeded, so the foreign keys added above '
                        'would reject every row written to them';
    END IF;

    -- 5.4 The master-data tables must be populated and reachable, and every new FK must lead
    --     an index (0006's invariant, asserted here at the moment it could first be broken).
    IF (SELECT count(*) FROM units_of_measure) < 3 OR (SELECT count(*) FROM costing_methods) < 3 THEN
        RAISE EXCEPTION 'the master-data tables are not seeded, so the FKs added above will '
                        'reject every row';
    END IF;
    SELECT count(*) INTO v FROM pg_constraint c
     WHERE c.contype = 'f' AND c.connamespace = 'public'::regnamespace
       AND c.confrelid IN ('units_of_measure'::regclass, 'costing_methods'::regclass)
       AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = c.conrelid
                        AND i.indkey[0] = (c.conkey)[1]);
    IF v > 0 THEN
        RAISE EXCEPTION '% of the new master-data foreign keys lead no index', v;
    END IF;

    -- 5.5 The claim 5.9 was really about, executed: the same word in the wrong case must be
    --     refused, and refused by name. If this silently succeeds, every constraint above is
    --     decoration.
    BEGIN
        INSERT INTO entities (name, entity_type, status) VALUES ('AFPC Case Probe', 'customer', 'ACTIVE');
        RAISE EXCEPTION 'a case variant of entities.status was accepted, so 5.9 is not closed';
    EXCEPTION
        WHEN check_violation THEN
            GET STACKED DIAGNOSTICS v_list = CONSTRAINT_NAME;
            IF v_list IS DISTINCT FROM 'entities_status_allowed' THEN
                RAISE EXCEPTION 'the case probe was refused by an unexpected constraint: %', v_list;
            END IF;
            RAISE NOTICE 'case variants refused by name: %', v_list;
        WHEN unique_violation THEN
            RAISE NOTICE 'skipped: the probe row collided with an existing one';
    END;

    RAISE NOTICE 'domain values verified against % rows of the vocabulary view',
        (SELECT count(*) FROM vw_domain_vocabulary);
END
$$;
