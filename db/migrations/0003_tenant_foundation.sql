-- 0003: tenancy foundation (DATABASE_REVIEW.md 5.8, plan item 2.1).
--
-- Review 5.8 measured "tenancy columns across all 18 tables: 0 rows returned", and
-- drew the consequence that matters: "Uniqueness is global, so a second customer
-- cannot reuse warehouse code MAIN". This migration gives every business table a
-- tenant and re-scopes every natural key to be unique *within* a tenant.
--
-- Why it runs before 0004 and 0006 rather than after: both of those create composite
-- indexes and unique constraints, and 2.1 asks that every one of them lead with the
-- tenant. Doing tenancy afterwards means building them twice.
--
-- Design decisions, and the reasoning:
--
--   * tenant_id is uuid NOT NULL on all 18 tables, with a foreign key to tenants.
--     The FK is not ceremony: once migration 0009's policies compare
--     tenant_id = current_setting('app.tenant_id')::uuid, a mistyped or uncreated
--     tenant silently yields a connection that reads nothing at all and looks
--     healthy. The FK turns that into an error at write time.
--   * The column default is a function, not a literal, because the fallback has to
--     be a deployment setting rather than a value baked into the schema. See
--     afpc_current_tenant() for why it is VOLATILE on purpose.
--   * No table gets tenant_id: `_schema_graph` (schema metadata, one copy per
--     database) and `schema_migrations` (created by the runner, not a migration).
--   * Existing natural keys are replaced, not merely supplemented, otherwise the
--     global uniqueness that blocks a second tenant would survive.
--   * Every existing table is empty on this database, so the backfills are no-ops
--     here and load-bearing on a populated copy. Both paths are written because
--     this migration set is meant to replay onto a copy of a real database.
--   * tenant_id is left out of PRIMARY KEYs. Keys are surrogate (uuid/bigint), so
--     composite PKs would buy nothing and would widen every referencing FK.

SET client_min_messages TO warning;

-- ---------------------------------------------------------------------------
-- 1. The tenant registry
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tenants (
    tenant_id       uuid            PRIMARY KEY DEFAULT gen_random_uuid(),
    slug            varchar(63)     NOT NULL UNIQUE,
    name            varchar(255)    NOT NULL,
    status          varchar(20)     NOT NULL DEFAULT 'active',
    is_active       boolean         NOT NULL DEFAULT true,
    created_at      timestamptz     NOT NULL DEFAULT now(),
    updated_at      timestamptz     NOT NULL DEFAULT now(),
    CONSTRAINT tenants_slug_format CHECK (slug ~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'),
    -- Migration 0007 replaces the free-text status with a CHECK'd lookup table;
    -- this narrows it now so a test cannot pass with status = 'Active'.
    CONSTRAINT tenants_status_check CHECK (status IN ('active', 'suspended', 'archived'))
);

COMMENT ON TABLE tenants IS
    'Root of the tenancy model. Every business row carries tenant_id and points here. '
    'Review 5.8: tenancy was absent, not thin.';
COMMENT ON COLUMN tenants.slug IS
    'Stable public identifier for URLs and configuration. Format-checked because it '
    'doubles as a key in logs where tenant_id is a UUID.';

-- Fixed, not generated: this id appears in dev/.env as AFPC_TENANT_ID, in every seed
-- file, and in the database-level app.default_tenant_id setting below. A generated id
-- would make those three disagree on a rebuilt database.
INSERT INTO tenants (tenant_id, slug, name, status)
VALUES ('00000000-0000-0000-0000-000000000001', 'default', 'Default tenant (single-tenant development)', 'active')
ON CONFLICT (tenant_id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. The tenant-resolution function used as the column default
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION afpc_current_tenant() RETURNS uuid
LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    -- Read into variables first. Testing current_setting('app.tenant_id', true)::uuid
    -- directly would raise 22P02 before the handler could produce a useful message, and
    -- a custom GUC reads as an EMPTY STRING, not NULL, once it has been set to '' - so
    -- both forms of "unset" have to be normalised before any cast is attempted.
    v_session  uuid;
    v_fallback uuid;
BEGIN
    BEGIN
        v_session := nullif(current_setting('app.tenant_id', true), '')::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
        -- Raised rather than coerced: a malformed tenant id means the caller has a
        -- configuration bug, and silently writing a different tenant's rows would hide
        -- it as a mysterious empty result set later.
        RAISE EXCEPTION 'app.tenant_id = % is not a uuid',
            quote_literal(current_setting('app.tenant_id', true))
            USING HINT = 'Set it per connection: SET app.tenant_id = ''<uuid>''';
    END;

    IF v_session IS NOT NULL THEN
        RETURN v_session;
    END IF;

    BEGIN
        v_fallback := nullif(current_setting('app.default_tenant_id', true), '')::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
        RAISE EXCEPTION 'app.default_tenant_id = % is not a uuid',
            quote_literal(current_setting('app.default_tenant_id', true));
    END;

    IF v_fallback IS NOT NULL THEN
        RETURN v_fallback;
    END IF;

    RAISE EXCEPTION 'no tenant context: neither app.tenant_id nor app.default_tenant_id is set'
        USING HINT = 'Agents must SET app.tenant_id per connection (review 5.8, plan 2.3). '
                     'A single-tenant deployment may instead set app.default_tenant_id.';
END
$$;

COMMENT ON FUNCTION afpc_current_tenant() IS
    'Resolves the tenant for a column default from app.tenant_id, falling back to '
    'app.default_tenant_id, and fails loudly when neither is set. Declared VOLATILE '
    'rather than STABLE on purpose: a column default marked STABLE can be evaluated '
    'once and constant-folded by the planner, which would silently put every row of a '
    'bulk insert into whichever tenant happened to be read first. It also normalises '
    'the empty string to unset, because a custom GUC reads as an empty string once it '
    'has been RESET or set to an empty value. This function is the convenience path for '
    'inserts; migration 0009''s row-level-security policies are the enforcement path, so '
    'a row defaulted here must never be the only thing keeping tenants apart.';

-- ---------------------------------------------------------------------------
-- 3. tenant_id on every business table
-- ---------------------------------------------------------------------------
-- The loop is over an explicit list rather than "all tables in public" so that a table
-- added by a later migration cannot quietly slip past tenancy: it has to be named here
-- or in its own migration. That is the failure mode 3.1 came from.
-- A per-table (tenant_id) index is only worth its write cost when no other index on
-- that table already leads with tenant_id: a btree whose FIRST column is tenant_id is a
-- (tenant_id) index for planning purposes, because leading columns of an equality
-- predicate need not be in the WHERE clause to be usable. This function exists so that
-- judgment is applied identically here and in 0004, which creates the on-hand identity
-- unique that makes inventory_on_hand's standalone index redundant later.
CREATE OR REPLACE FUNCTION afpc_drop_redundant_tenant_indexes() RETURNS text[]
LANGUAGE sql VOLATILE AS $$
    SELECT array_agg(idx) FROM (
        SELECT i.indexrelid::regclass::text AS idx
          FROM pg_index i
          JOIN pg_class c   ON c.oid = i.indrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
          JOIN pg_attribute lead ON lead.attrelid = i.indrelid AND lead.attnum = i.indkey[0]
         WHERE n.nspname = 'public' AND lead.attname = 'tenant_id'
           AND i.indexrelid::regclass::text LIKE 'idx_%_tenant'
           -- another index on the same table also leads with tenant_id, and is not this one
           AND EXISTS (SELECT 1 FROM pg_index j
                        WHERE j.indrelid = i.indrelid AND j.indexrelid <> i.indexrelid
                          AND j.indkey[0] = lead.attnum)
         GROUP BY i.indrelid, i.indexrelid
    ) d
$$;

COMMENT ON FUNCTION afpc_drop_redundant_tenant_indexes() IS
    'Names the idx_*_tenant indexes that are redundant because another index on the same '
    'table already leads with tenant_id. Called by 0003 and again by 0004.';

DO $$
DECLARE
    t        text;
    tables   text[] := ARRAY[
        'entities', 'contacts', 'addresses', 'entity_relationships', 'communications',
        'followups', 'warehouses', 'locations', 'item_categories', 'inventory_items',
        'inventory_movements', 'inventory_on_hand', 'inventory_reservations',
        'human_sessions', 'bot_actions', 'audit_summary', 'agent_interactions'
    ];
BEGIN
    FOREACH t IN ARRAY tables LOOP
        IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                        WHERE table_schema = 'public' AND table_name = t
                          AND column_name = 'tenant_id') THEN
            -- Added nullable: a default does NOT backfill rows that already exist, so
            -- setting NOT NULL with a default on a populated table would fail, and
            -- skipping the default would rewrite the table.
            EXECUTE format('ALTER TABLE public.%I ADD COLUMN tenant_id uuid', t);
            RAISE NOTICE 'tenant_id added to %', t;
        ELSIF NOT EXISTS (SELECT 1 FROM information_schema.columns
                        WHERE table_schema = 'public' AND table_name = t
                          AND column_name = 'tenant_id' AND is_nullable = 'NO') THEN
            RAISE NOTICE 'tenant_id on % exists but is nullable', t;
        END IF;

        -- COALESCE, not a bare assignment: on a copy that somehow has nulls, leaving a
        -- null behind would abort the NOT NULL step below and roll the whole migration
        -- back with an error that points at the wrong problem.
        EXECUTE format('UPDATE public.%I SET tenant_id = $1::uuid WHERE tenant_id IS NULL', t)
            USING '00000000-0000-0000-0000-000000000001';

        EXECUTE format('ALTER TABLE public.%I ALTER COLUMN tenant_id SET NOT NULL', t);
        EXECUTE format('ALTER TABLE public.%I ALTER COLUMN tenant_id SET DEFAULT afpc_current_tenant()', t);

        EXECUTE format(
            'ALTER TABLE public.%I DROP CONSTRAINT IF EXISTS %I,
                ADD CONSTRAINT %I FOREIGN KEY (tenant_id) REFERENCES tenants(tenant_id)
                    ON DELETE RESTRICT',
            t, t || '_tenant_id_fkey', t || '_tenant_id_fkey');

        EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON public.%I (tenant_id)',
            'idx_' || t || '_tenant', t);

        -- Naming is the point of the comment: an agent reading the catalog has to
        -- learn that this column, not a schema or a database, is what separates one
        -- customer's data from another's.
        EXECUTE format(
            'COMMENT ON COLUMN public.%I.tenant_id IS %L', t,
            'Owning tenant. Foreign key to public.tenants, NOT NULL, indexed. '
            'Row-level security filters on it (0009) and every composite unique '
            'and index leads with it (2.1). Resolved by afpc_current_tenant() when not '
            'supplied. Review 5.8.');
    END LOOP;
END
$$;

-- The deployment-level fallback, so a single-tenant install works with no code change
-- while a multi-tenant install must set app.tenant_id. Database-scoped rather than
-- role-scoped: it belongs to the data, and ALTER DATABASE survives into every copy.
-- current_database() rather than a literal so this replays onto a renamed or restored
-- copy, which is exactly what an audit or a staging refresh looks like.
DO $$
BEGIN
    EXECUTE format('ALTER DATABASE %I SET app.default_tenant_id = %L',
        current_database(), '00000000-0000-0000-0000-000000000001');
END
$$;

-- ---------------------------------------------------------------------------
-- 4. Natural keys become tenant-scoped
-- ---------------------------------------------------------------------------
-- Each pair of statements replaces a global unique with a tenant-unique one, and drops
-- the now-redundant single-column index that used to serve the lookup. Leaving both
-- would double the write cost of an INSERT for no read benefit; the duplicates are
-- counted by 0006 rather than papered over here.
DO $$
DECLARE
    s     text;
    stmts text[] := ARRAY[
        -- warehouses: review 5.8's example. MAIN was reserved for one tenant by
        -- another; now it is only reserved within a tenant.
        'ALTER TABLE warehouses DROP CONSTRAINT IF EXISTS warehouses_warehouse_code_key',
        'CREATE UNIQUE INDEX IF NOT EXISTS warehouses_warehouse_code_key
            ON warehouses (tenant_id, warehouse_code)',
        'DROP INDEX IF EXISTS idx_warehouses_code',
        'CREATE INDEX IF NOT EXISTS idx_warehouses_tenant_parent
            ON warehouses (tenant_id, parent_warehouse_id)',

        'ALTER TABLE item_categories DROP CONSTRAINT IF EXISTS item_categories_category_code_key',
        'CREATE UNIQUE INDEX IF NOT EXISTS item_categories_category_code_key
            ON item_categories (tenant_id, category_code)',
        'DROP INDEX IF EXISTS idx_categories_code',
        'CREATE INDEX IF NOT EXISTS idx_categories_tenant_parent
            ON item_categories (tenant_id, parent_category_id)',

        'ALTER TABLE inventory_items DROP CONSTRAINT IF EXISTS inventory_items_sku_key',
        'CREATE UNIQUE INDEX IF NOT EXISTS inventory_items_sku_key
            ON inventory_items (tenant_id, sku)',
        'DROP INDEX IF EXISTS idx_inventory_items_sku',
        'CREATE INDEX IF NOT EXISTS idx_inventory_items_tenant_active
            ON inventory_items (tenant_id, is_active)',
        'CREATE INDEX IF NOT EXISTS idx_inventory_items_tenant_group
            ON inventory_items (tenant_id, item_group)',
        'CREATE INDEX IF NOT EXISTS idx_inventory_items_tenant_category
            ON inventory_items (tenant_id, category_id)',

        'ALTER TABLE locations DROP CONSTRAINT IF EXISTS locations_warehouse_id_location_code_key',
        'CREATE UNIQUE INDEX IF NOT EXISTS locations_warehouse_id_location_code_key
            ON locations (tenant_id, warehouse_id, location_code)',
        'DROP INDEX IF EXISTS idx_locations_code',

        'ALTER TABLE entity_relationships DROP CONSTRAINT IF EXISTS entity_relationships_entity_id_contact_id_key',
        'CREATE UNIQUE INDEX IF NOT EXISTS entity_relationships_entity_id_contact_id_key
            ON entity_relationships (tenant_id, entity_id, contact_id)',
        'DROP INDEX IF EXISTS idx_primary_contact',
        'CREATE INDEX IF NOT EXISTS idx_primary_contact
            ON entity_relationships (tenant_id, entity_id, is_primary)',

        'ALTER TABLE audit_summary DROP CONSTRAINT IF EXISTS audit_summary_date_user_id_bot_id_key',
        'CREATE UNIQUE INDEX IF NOT EXISTS audit_summary_date_user_id_bot_id_key
            ON audit_summary (tenant_id, date, user_id, bot_id)',

        -- bot_actions.session_id is uuid: this FK was never indexed (part of the 12
        -- unindexed FK columns 0006 counts) and the leading tenant_id indexes it now.
        'DROP INDEX IF EXISTS idx_bot_actions_session_id',
        'CREATE INDEX IF NOT EXISTS idx_bot_actions_session_id
            ON bot_actions (tenant_id, session_id)',
        'CREATE INDEX IF NOT EXISTS idx_bot_actions_tenant_user_bot
            ON bot_actions (tenant_id, user_id, bot_id)',

        'DROP INDEX IF EXISTS idx_human_sessions_user_bot',
        'CREATE INDEX IF NOT EXISTS idx_human_sessions_user_bot
            ON human_sessions (tenant_id, user_id, bot_id)',
        'CREATE INDEX IF NOT EXISTS idx_human_sessions_tenant_login
            ON human_sessions (tenant_id, login_time)',

        -- Communications and follow-ups are the agent hot paths, so the tenant-scoped
        -- time-ordered index is the one that matters most.
        'CREATE INDEX IF NOT EXISTS idx_communications_tenant_entity_created
            ON communications (tenant_id, entity_id, created_at DESC)',
        'CREATE INDEX IF NOT EXISTS idx_communications_tenant_contact_created
            ON communications (tenant_id, contact_id, created_at DESC)',
        'CREATE INDEX IF NOT EXISTS idx_followups_tenant_entity
            ON followups (tenant_id, entity_id)',
        'CREATE INDEX IF NOT EXISTS idx_addresses_tenant_entity
            ON addresses (tenant_id, entity_id)',
        'CREATE INDEX IF NOT EXISTS idx_addresses_tenant_contact
            ON addresses (tenant_id, contact_id)',
        'CREATE INDEX IF NOT EXISTS idx_entities_tenant_name
            ON entities (tenant_id, name)',
        'CREATE INDEX IF NOT EXISTS idx_contacts_tenant_name
            ON contacts (tenant_id, last_name, first_name)',

        -- Stock lookups: the balance read for one item in one warehouse is the single
        -- hottest ERP query and it was a seq scan within the tenant before this.
        'DROP INDEX IF EXISTS idx_on_hand_item',
        'CREATE INDEX IF NOT EXISTS idx_on_hand_item
            ON inventory_on_hand (tenant_id, item_id)',
        'DROP INDEX IF EXISTS idx_on_hand_warehouse',
        'CREATE INDEX IF NOT EXISTS idx_on_hand_warehouse
            ON inventory_on_hand (tenant_id, warehouse_id)',
        'CREATE INDEX IF NOT EXISTS idx_on_hand_tenant_location
            ON inventory_on_hand (tenant_id, location_id)',

        'DROP INDEX IF EXISTS idx_reservations_order',
        'CREATE INDEX IF NOT EXISTS idx_reservations_order
            ON inventory_reservations (tenant_id, order_type, order_id)',
        'CREATE INDEX IF NOT EXISTS idx_reservations_tenant_item
            ON inventory_reservations (tenant_id, item_id)',

        'CREATE INDEX IF NOT EXISTS idx_movements_tenant_date
            ON inventory_movements (tenant_id, performed_at)',
        'CREATE INDEX IF NOT EXISTS idx_movements_tenant_item_date
            ON inventory_movements (tenant_id, item_id, performed_at)',

        'CREATE INDEX IF NOT EXISTS idx_agent_interactions_tenant_time
            ON agent_interactions (tenant_id, "timestamp" DESC)'
    ];
BEGIN
    FOREACH s IN ARRAY stmts LOOP
        EXECUTE s;
    END LOOP;
END
$$;

-- Section 3 created a standalone (tenant_id) index on every table; section 4 created
-- tenant-led composites on many of them, which makes the standalone copy redundant.
-- Run the cleanup after both, rather than reasoning about it table by table.
--
-- SET (not LOCAL) because this file's top-level client_min_messages = warning exists to
-- quiet the per-table ALTER chatter, and it would also quiet the one message worth
-- reading. SET is not transactional, so it is restored rather than left elevated.
SET client_min_messages TO notice;
DO $$
DECLARE
    dropped text[];
BEGIN
    SELECT afpc_drop_redundant_tenant_indexes() INTO dropped;
    IF dropped IS NOT NULL AND cardinality(dropped) > 0 THEN
        EXECUTE 'DROP INDEX ' || array_to_string(
            (SELECT array_agg(x) FROM unnest(dropped) AS x), ', ');
        RAISE NOTICE 'dropped % redundant (tenant_id) indexes, already a prefix of a '
                     'tenant-led composite: %', cardinality(dropped), array_to_string(dropped, ', ');
    END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- 5. Views, so an agent's default read is already tenant-shaped
-- ---------------------------------------------------------------------------
-- The canonical views expose tenant_id rather than filtering on it. They cannot filter:
-- a view owned by postgres runs as the owner and would bypass RLS (which is exactly why
-- 0009 uses security_invoker). Filtering inside the view would also make the predicate
-- invisible to a reader debugging an empty result.
--
-- They will not pick the column up on their own either: all 12 are explicit-column
-- SELECTs, not SELECT *, so adding a column to a base table changes no view. That is
-- reported rather than guessed at, because a view over tenant tables that omits
-- tenant_id becomes an unfilterable hole the moment 0009 lands.
DO $$
DECLARE
    v       record;
    missing text[] := ARRAY[]::text[];
BEGIN
    FOR v IN
        SELECT t.table_name AS view,
               (SELECT string_agg(DISTINCT u.table_name, ', ' ORDER BY u.table_name)
                  FROM information_schema.view_table_usage u
                 WHERE u.view_schema = 'public' AND u.view_name = t.table_name) AS bases
          FROM information_schema.views t
         WHERE t.table_schema = 'public' AND t.table_name LIKE 'vw_%'
         ORDER BY 1
    LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_attribute a
                        WHERE a.attrelid = format('public.%I', v.view)::regclass
                          AND a.attname = 'tenant_id'
                          AND a.attnum > 0 AND NOT a.attisdropped) THEN
            missing := array_append(missing, v.view || ' over ' || v.bases);
        END IF;
    END LOOP;

    IF cardinality(missing) > 0 THEN
        RAISE NOTICE 'views not exposing tenant_id: %', array_to_string(missing, ' | ');
        RAISE NOTICE 'deferred to 0009: rewriting 12 views is view work, and RLS is what '
                     'makes the omission unsafe rather than merely incomplete';
    END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- 6. Verification
-- ---------------------------------------------------------------------------
-- Fail the migration rather than record it as applied: a half-tenant schema is worse
-- than none, because it makes every later migration's assumptions look satisfied.
SET client_min_messages TO notice;
DO $$
DECLARE
    t          text;
    ok         boolean;
    tables     text[] := ARRAY[
        'entities', 'contacts', 'addresses', 'entity_relationships', 'communications',
        'followups', 'warehouses', 'locations', 'item_categories', 'inventory_items',
        'inventory_movements', 'inventory_on_hand', 'inventory_reservations',
        'human_sessions', 'bot_actions', 'audit_summary', 'agent_interactions', 'tenants'
    ];
BEGIN
    FOREACH t IN ARRAY tables LOOP
        IF t = 'tenants' THEN
            CONTINUE;   -- the root: its tenant_id is its primary key by definition
        END IF;
        SELECT count(*) = 1 INTO ok
            FROM information_schema.columns
            WHERE table_schema = 'public' AND table_name = t AND column_name = 'tenant_id'
              AND is_nullable = 'NO' AND data_type = 'uuid';
        IF NOT ok THEN
            RAISE EXCEPTION 'table %.tenant_id is missing, nullable, or not a uuid', t;
        END IF;

        IF NOT EXISTS (SELECT 1 FROM pg_constraint
                        WHERE conrelid = format('public.%I', t)::regclass
                          AND contype = 'f' AND conkey @> ARRAY[
                              (SELECT attnum FROM pg_attribute
                                WHERE attrelid = format('public.%I', t)::regclass
                                  AND attname = 'tenant_id')]::int2[]) THEN
            RAISE EXCEPTION 'table %.tenant_id has no foreign key to tenants', t;
        END IF;

        IF NOT EXISTS (SELECT 1 FROM pg_index i
                        WHERE i.indrelid = format('public.%I', t)::regclass
                          AND i.indkey[0] = (SELECT attnum FROM pg_attribute
                                WHERE attrelid = format('public.%I', t)::regclass
                                  AND attname = 'tenant_id')) THEN
            RAISE EXCEPTION 'table %.tenant_id leads no index, so every tenant-scoped '
                            'query on it is a sequential scan', t;
        END IF;
    END LOOP;

    -- The six keys the review named must now be tenant-scoped. Checked structurally,
    -- by column order, rather than by existence: a unique that does not lead with the
    -- tenant is the bug being fixed.
    IF (SELECT count(*) FROM pg_index i JOIN pg_class c ON c.oid = i.indrelid
          JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = i.indkey[0]
         WHERE c.relname IN ('warehouses', 'item_categories', 'inventory_items',
                             'locations', 'entity_relationships', 'audit_summary')
           AND i.indisunique AND NOT i.indisprimary AND a.attname = 'tenant_id') <> 6 THEN
        RAISE EXCEPTION 'expected 6 tenant-scoped natural keys, found a different set';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM tenants
                    WHERE tenant_id = '00000000-0000-0000-0000-000000000001') THEN
        RAISE EXCEPTION 'the default tenant is missing; seeds and dev/.env assume it exists';
    END IF;

    -- The redundancy the cleanup above is supposed to remove. Asserting it here means a
    -- future migration that adds a tenant-led composite cannot silently leave a
    -- duplicate (tenant_id) index behind: it has to call the cleanup too.
    IF EXISTS (SELECT 1 FROM unnest(afpc_drop_redundant_tenant_indexes()) AS x(idx)) THEN
        RAISE EXCEPTION 'redundant (tenant_id) indexes survive: %',
            (SELECT string_agg(idx, ', ')
              FROM unnest(afpc_drop_redundant_tenant_indexes()) AS x(idx));
    END IF;

    RAISE NOTICE 'tenancy verified: 17 tenant columns + tenants, all NOT NULL, FK''d, indexed; '
                 '6 natural keys tenant-scoped';
END
$$;
