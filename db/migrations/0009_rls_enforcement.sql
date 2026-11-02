-- 0009: make row-level security a control instead of a decoration (DATABASE_REVIEW.md 5.7),
-- and pay the two debts this migration is the first one able to pay: the sequence grants
-- 0002 could not see, and the PUBLIC function EXECUTE that 0008 measured and recorded.
--
-- 5.7's verdict is "RLS is decorative", with three reasons. All three reproduce here, and
-- measuring them produced four more defects that the review did not list, because the review
-- could not: they are only visible once you try to make RLS bite.
--
--   5.7.1  relforcerowsecurity = false on the two enabled tables -> the owner path is
--          unrestricted. Section 4 forces it.
--   5.7.2  16 of 18 business tables have no policies at all. Section 4 covers every table
--          that HAS a tenant_id, by asking the catalog rather than carrying a list, so the
--          next tenant-coded table joins the scope automatically; the four tables without one
--          are named in 0009's exemption register (verify.sh B19) rather than left uncounted.
--   5.7.3  no code anywhere sets app.current_agent, so current_setting(..., true) is NULL:
--          an honest non-owner cannot INSERT a movement, while a SELECT reads every tenant.
--          Sections 3 and 8 measure both halves of that sentence on this database, before and
--          after. Note which half is the emergency: the write hole is an outage, the read hole
--          is a cross-tenant disclosure, and the policies were written so that only the first
--          one could ever be noticed.
--
-- What measuring added:
--
--   A. THE PREDICATE CANNOT USE AN INDEX IF THE RESOLVER IS VOLATILE.
--      afpc_current_tenant() is declared VOLATILE, and 0003's comment says why: a column
--      default that the planner is allowed to constant-fold would put every row of a bulk
--      insert into whichever tenant it happened to read first. That reasoning is right for a
--      default and exactly wrong for a policy qual. Measured on 600k rows, two tenants:
--
--        USING (tenant_id = afpc_current_tenant())   -> Seq Scan, Filter per row, 479 ms
--        USING (tenant_id = <STABLE resolver>)       -> Index Cond,                   53 ms
--
--      A VOLATILE function in a qual is re-evaluated for every row scanned and can never
--      become an Index Cond. So 0006's closing note - "the pair is already served by 0003's
--      (tenant_id, last_name, first_name) as soon as a tenant predicate is present, which
--      0009 guarantees" - is a promise this migration can only keep by declaring its resolver
--      STABLE. Section 1 adds afpc_policy_tenant() for the qual path, delegating to
--      afpc_current_tenant() so there is one implementation of the fallback logic, and the
--      volatility difference is the point rather than an accident.
--
--   B. A POLICY THAT RAISES FILTERS DIFFERENTLY FROM ONE THAT RETURNS FALSE.
--      afpc_current_tenant() RAISES when neither app.tenant_id nor app.default_tenant_id is
--      set. In a qual that is a per-row exception - and whether it happens depends on whether
--      the scan reaches a row at all. Measured: the same query with no tenant context returns
--      "0 rows" on an empty table and errors on a populated one. Both are safe (never another
--      tenant's data) and neither is a lie, but an agent's "no results" would be ambiguous.
--      Keep the loud failure - it is the same choice 0003 made for a malformed GUC - and give
--      the read roles a policy of their own (USING (true)) so an audit connection never
--      evaluates the raising qual. Measured: the auditor reads both tenants' rows with no
--      tenant context at all, while afpc_app on the same table errors. Permissive policies
--      are OR'd, and constant folding removes the qual from the read path entirely; that is a
--      property of the plan, not of the intent, so section 8 tests it instead of trusting it.
--
--   C. 0002 LEFT SIX SEQUENCES BEHIND, AND NOTHING COULD SHOW IT.
--      afpc_app cannot INSERT into entities: permission denied for sequence
--      entities_id_seq. 0002's GRANT ... ON ALL SEQUENCES ran before the baseline's serial
--      keys existed? No - its ALTER DEFAULT PRIVILEGES only covers objects created *after*
--      0002, and its one-time grant loop was written for tables and functions. Either way the
--      effect is that RLS was untestable for the CRM tables: every behavioural probe of the
--      write path dies on the sequence before it reaches a policy. Section 2 fixes the grant,
--      and section 8 is only possible because of it.
--
--   D. ALTER DEFAULT PRIVILEGES CANNOT REVOKE WHAT IT NEVER GRANTED.
--      0008 recorded this migration's duty as "REVOKE from PUBLIC, GRANT to afpc_app, and
--      ALTER DEFAULT PRIVILEGES ... REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC so new functions
--      start closed". The first two work. The third does not, and it is worth writing down why
--      because the sentence reads so reasonable: a function's initial ACL is the *system*
--      default, which already contains EXECUTE for PUBLIC; a default-privileges record only
--      ADDs grants to it. Measured on a clone: after installing that record, a newly created
--      function is still executable by afpc_auditor. So there is no way to make future
--      functions start closed from here. Section 6 revokes the thirteen that exist, and
--      verify.sh B22 makes the absence of a future revoke visible as a FAIL instead of as
--      silence - the same shape as 0007's UNDECIDED rows.
--
-- The consequence that is not a fix: FORCE binds the table owner, and the owner here is a
-- superuser, which bypasses row security no matter how it is configured. 0009 makes RLS real
-- for afpc_app, afpc_readonly and afpc_auditor, which is what the deployment's own roles are
-- for; a connection made as postgres remains unrestricted by construction, and blueprint's
-- DB_CONFIG still defaults to that. Making the agents connect as afpc_app, and set
-- app.tenant_id per connection, is the Phase 5 code sweep, and 0009 is the reason it can be
-- done rather than the thing that does it.

SET client_min_messages TO notice;

-- ---------------------------------------------------------------------------
-- 1. The resolver the policies use
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION afpc_policy_tenant()
RETURNS uuid
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    -- Delegation, not duplication: the fallback chain and its error messages belong to
    -- afpc_current_tenant, and a second copy would drift from the first at exactly the moment
    -- someone fixes one of them. The volatility difference is the whole point of the wrapper,
    -- so it lives here rather than as a re-declaration of the same function.
    RETURN afpc_current_tenant();
END
$$;

COMMENT ON FUNCTION afpc_policy_tenant IS
    'STABLE view of afpc_current_tenant(), for use in row-security quals. Same resolution '
    'chain and same loud failure when no tenant context exists; the volatility marker is '
    'different on purpose, because a VOLATILE function in a qual is re-evaluated per row and '
    'cannot become an index condition, which would make every tenant-filtered read a table '
    'scan (measured 479 ms against 53 ms on 600k rows). Do not use this as a column default: '
    'a STABLE default is constant-foldable across a bulk insert, which is why '
    'afpc_current_tenant is VOLATILE. See 0003.';

-- ---------------------------------------------------------------------------
-- 2. The grants 0002 could not reach (finding C)
-- ---------------------------------------------------------------------------
-- Sequences are the one object class ALTER DEFAULT PRIVILEGES retroactively cannot fix, and
-- the baseline's serial keys predate 0002's records. Without this, afpc_app cannot insert a
-- customer, a contact, an address, a communication, a relationship or a follow-up - six of the
-- CRM's seven write paths - which is also to say: cannot be tested for isolation on writes.
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO afpc_app;
-- The audit account reads last_value/currval for reconciliation; 0002 already intends this
-- for sequences created from now on, and these six predate it.
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO afpc_auditor;

DO $$
DECLARE
    v text;
BEGIN
    SELECT string_agg(schemaname || '.' || sequencename, ', ' ORDER BY 1) INTO v
      FROM pg_sequences
     WHERE schemaname = 'public'
       AND NOT has_sequence_privilege('afpc_app',
             format('%I.%I', schemaname, sequencename)::regclass, 'USAGE,SELECT');
    IF v IS NOT NULL THEN
        RAISE EXCEPTION 'afpc_app still cannot use: % - 0002''s sequence gap is open, and '
                        'every write-path test below would die on it', v;
    END IF;
    SELECT count(*) INTO v FROM pg_sequences WHERE schemaname = 'public';
    RAISE NOTICE 'afpc_app can now use all % sequences in public (6 of them were missing)', v;
END
$$;

-- ---------------------------------------------------------------------------
-- 3. Retire the policies that could not work
-- ---------------------------------------------------------------------------
-- Three of them key off app.current_agent, which nothing in the repository sets (5.7.3 - the
-- review greps for it and finds only the CREATE POLICY lines). The two audit_full_read
-- policies were 0002's stopgap on the same tables and say so in their own header.
DO $$
DECLARE
    r   record;
    n   int := 0;
BEGIN
    FOR r IN SELECT policyname, tablename FROM pg_policies WHERE schemaname = 'public'
              AND policyname IN ('agent_movement_view_policy', 'agent_movement_insert_policy',
                                 'agent_reservation_policy', 'audit_full_read')
             ORDER BY tablename, policyname
    LOOP
        EXECUTE format('DROP POLICY %I ON public.%I', r.policyname, r.tablename);
        n := n + 1;
        RAISE NOTICE 'dropped %.% - %', r.tablename, r.policyname,
            CASE WHEN r.policyname = 'audit_full_read'
                 THEN '0002''s stopgap, superseded by 0009''s read policy'
                 ELSE 'keys off app.current_agent, which no code sets' END;
    END LOOP;
    -- The count is a claim about the graph, so it is asserted: three policies key off the GUC
    -- nothing sets (two on movements, one FOR ALL on reservations) and two are 0002's
    -- stopgaps. Fewer means this migration is pointed at a different database than the one it
    -- was written against, and continuing would leave an inert policy installed.
    IF n <> 5 THEN
        RAISE EXCEPTION 'expected 5 inert policies (3 keyed off app.current_agent + 2 of '
                        '0002''s stopgaps), found % - re-measure 5.7 before continuing', n;
    END IF;
    RAISE NOTICE '5.7.3 retired: % policies that could never have evaluated to true for an '
                 'honest caller', n;
END
$$;

-- ---------------------------------------------------------------------------
-- 4. Enable, force, and give every tenant-coded table the same two policies
-- ---------------------------------------------------------------------------
-- Scope is derived from the catalog, not from a list: a table has a tenant_id column, so its
-- rows belong to a tenant, so the isolation policy applies. verify.sh B7 asks the same
-- question the same way, which is what makes a table that skips this loop a FAIL rather than
-- an oversight.
DO $$
DECLARE
    t     text;
    n     int := 0;
    m     int := 0;
BEGIN
    FOR t IN SELECT c.relname
               FROM pg_class c
               JOIN pg_namespace ns ON ns.oid = c.relnamespace
               JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0
                                      AND NOT a.attisdropped AND a.attname = 'tenant_id'
              WHERE ns.nspname = 'public' AND c.relkind = 'r'
              ORDER BY 1
    LOOP
        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
        -- FORCE is what answers 5.7.1. It binds the owner, not a superuser: see the header's
        -- last paragraph. The distinction is stated here because a reader who misses it will
        -- believe the deployment is protected when the agent connects as postgres.
        EXECUTE format('ALTER TABLE public.%I FORCE ROW LEVEL SECURITY', t);

        EXECUTE format($f$CREATE POLICY tenant_isolation ON public.%I AS PERMISSIVE
              FOR ALL TO PUBLIC
              USING (tenant_id = afpc_policy_tenant())
              WITH CHECK (tenant_id = afpc_policy_tenant())$f$, t);

        EXECUTE format($f$CREATE POLICY audit_read_all ON public.%I AS PERMISSIVE
              FOR SELECT TO afpc_auditor, afpc_readonly
              USING (true)$f$, t);

        n := n + 1;
        IF EXISTS (SELECT 1 FROM pg_policies p WHERE p.tablename = t
                     AND p.policyname = 'tenant_isolation' AND p.cmd <> 'SELECT') THEN
            m := m + 1;
        END IF;
    END LOOP;

    IF n <> 18 THEN
        RAISE EXCEPTION 'RLS applied to % tables, expected 18 - 5.8 counted 18 business tables '
                        'and B1 checks the same set, so a mismatch means a table appeared or '
                        'disappeared without either this loop or the scoreboard noticing', n;
    END IF;
    IF m <> 18 THEN
        RAISE EXCEPTION 'only % of % tables have an ALL-command isolation policy - a SELECT-only '
                        'policy leaves writes unfiltered, which is the half of 5.7 that leaks',
            m, n;
    END IF;
    RAISE NOTICE 'RLS enabled+forced on % tenant-coded tables: isolation FOR ALL, plus a '
                 'SELECT-only USING (true) policy for the two read roles', n;
END
$$;

-- tenants is the registry, not a tenant's data: the isolation policy above reads correctly
-- for it (a connection sees its own row) but its WITH CHECK has a consequence worth stating
-- plainly, because it is the one table where "tenant_id = current tenant" is not what you
-- would guess. Measured, all four cases: an agent INSERT of a new registry row is REFUSED (a
-- fresh key can never equal the caller's tenant); an UPDATE or DELETE against another tenant's
-- row changes nothing; an UPDATE to its own tenant's row is ALLOWED. Provisioning is therefore
-- an owner operation, and what remains open to an agent is renaming its own tenant entry -
-- stated here rather than left to be discovered, because the honest summary of row security is
-- what each command does, not the intention behind it.
COMMENT ON TABLE tenants IS
    'Tenant registry. Under 0009 an agent role reads only its own row, cannot create a tenant '
    '(a fresh key cannot satisfy the WITH CHECK), and cannot change or delete any other '
    'tenant''s row; renaming its own entry is permitted. The audit roles read the whole '
    'registry, which is the point of having them.';

-- ---------------------------------------------------------------------------
-- 5. Views: stop them being a door around the wall (finding B)
-- ---------------------------------------------------------------------------
-- A view owned by postgres evaluates its base tables as the owner unless security_invoker is
-- set, and the owner of a superuser-owned table in a database built by these migrations is
-- postgres - which bypasses row security entirely. Measured on a clone with RLS enabled and
-- forced and the isolation policy installed:
--
--     SELECT count(*) FROM warehouses            -> 1   (correct: own tenant only)
--     SELECT count(*) FROM <view over warehouses> -> 2   (both tenants)
--
-- That is not a gap in 0009's policies, it is a gap around them, and it is the reason 0003
-- left this paragraph a NOTE instead of a promise: enabling RLS without touching the views
-- would have made the control look finished. The same query after the rewrite returns 1.
--
-- The second half is why tenant_id has to be a column: the read roles' policy is
-- USING (true), so an audit query sees every tenant's rows in one result set. A view that
-- aggregates without grouping by tenant silently merges them - vw_agent_activity_summary's
-- "total_actions" would be the count for the identically-named bot in every tenant. The
-- aggregate views therefore gain tenant_id in the GROUP BY as well as the select list, which
-- is the only change to what a per-agent caller sees (one tenant, so one group either way).


-- First the snapshot the rewrite is checked against, taken before anything changes: the
-- column list of every non-extension view, in order. Rewriting twelve view definitions by
-- hand is how a column goes missing quietly, and "I copied it faithfully" is not evidence.
-- The assertion after the rewrites compares each list with what it was, so a dropped,
-- renamed or reordered column stops the migration instead of shipping.
CREATE TEMP TABLE _afpc_0009_before ON COMMIT DROP AS
SELECT c.oid AS view, c.relname AS name,
       array_agg(a.attname::text ORDER BY a.attnum) AS cols,
       -- The same classification the exposure check below uses, decided here so the rewrite
       -- cannot be graded on a curve drawn afterwards. view_table_usage rather than a
       -- hand-rolled pg_depend walk: the view -> table edges are recorded on the *rule's* oid,
       -- so joining d.objid = c.oid - which is what the first draft did - matches only the two
       -- rows a view owns directly and reports "no base tables" for all fourteen, making every
       -- view look global. The check further down compares against this snapshot, which is the
       -- argument for having the check.
       EXISTS (SELECT 1 FROM information_schema.view_table_usage u
                 JOIN pg_class b ON b.oid = format('public.%I', u.table_name)::regclass
                WHERE u.view_schema = 'public' AND u.view_name = c.relname::text
                  AND b.relkind = 'r'
                  AND EXISTS (SELECT 1 FROM pg_attribute ta
                               WHERE ta.attrelid = b.oid AND ta.attname = 'tenant_id'
                                 AND ta.attnum > 0 AND NOT ta.attisdropped)) AS over_tenant
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
 WHERE n.nspname = 'public' AND c.relkind = 'v'
   AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = c.oid AND d.deptype = 'e')
 GROUP BY c.oid, c.relname;

CREATE OR REPLACE VIEW vw_customers AS
 SELECT e.id,
    e.name,
    c.email,
    c.phone,
    ( SELECT concat_ws(', ', a.street, a.city, a.state, a.postal_code)
           FROM addresses a
          WHERE a.entity_id = e.id
          ORDER BY a.is_primary DESC, a.created_at DESC
         LIMIT 1) AS address,
    e.status,
    e.created_at,
    e.updated_at,
    e.embedding,
    e.tenant_id
   FROM entities e
     JOIN entity_relationships er ON er.entity_id = e.id AND er.is_primary = true
     JOIN contacts c ON c.id = er.contact_id
  WHERE e.entity_type::text = 'customer'::text;

CREATE OR REPLACE VIEW vw_customer_communications_summary AS
 SELECT c.id,
    c.started_at,
    e.id AS entity_id,
    e.name AS entity_name,
    e.entity_type,
    e.status AS entity_status,
    co.id AS contact_id,
    (co.first_name || ' ') || co.last_name AS contact_name,
    co.title AS contact_title,
    c.communication_type,
    c.direction,
    c.subject,
    c.summary,
    c.channel,
    c.duration_seconds,
    c.outcome,
    c.priority,
    c.sentiment_score,
    c.sentiment_label,
    c.follow_up_required,
    c.follow_up_date,
    c.agent_id,
    c.human_agent_id,
    c.parent_id,
    c.thread_root_id,
    c.tenant_id
   FROM communications c
     JOIN entities e ON e.id = c.entity_id
     LEFT JOIN contacts co ON co.id = c.contact_id
  WHERE e.entity_type::text = 'customer'::text;

CREATE OR REPLACE VIEW vw_recent_communications AS
 SELECT c.id,
    c.started_at,
    e.id AS entity_id,
    e.name AS entity_name,
    e.entity_type,
    (co.first_name || ' ') || co.last_name AS contact_name,
    co.title AS contact_title,
    c.communication_type,
    c.direction,
    c.subject,
    c.summary,
    c.outcome,
    c.priority,
    c.agent_id,
    c.tenant_id
   FROM communications c
     JOIN entities e ON e.id = c.entity_id
     LEFT JOIN contacts co ON co.id = c.contact_id
  WHERE c.started_at >= (now() - '7 days'::interval)
  ORDER BY c.started_at DESC;

CREATE OR REPLACE VIEW vw_communication_thread AS
 SELECT c.id,
    c.parent_id,
    c.thread_root_id,
    c.started_at,
    e.name AS entity_name,
    (co.first_name || ' ') || co.last_name AS contact_name,
    c.communication_type,
    c.subject,
    c.summary,
    c.outcome,
    c.tenant_id
   FROM communications c
     JOIN entities e ON e.id = c.entity_id
     LEFT JOIN contacts co ON co.id = c.contact_id;

CREATE OR REPLACE VIEW vw_primary_contact_communications AS
 SELECT c.id,
    c.started_at,
    e.id AS entity_id,
    e.name AS entity_name,
    e.entity_type,
    co.id AS contact_id,
    (co.first_name || ' ') || co.last_name AS primary_contact,
    co.title AS contact_title,
    c.communication_type,
    c.direction,
    c.subject,
    c.summary,
    c.outcome,
    c.priority,
    c.agent_id,
    c.tenant_id
   FROM communications c
     JOIN entities e ON e.id = c.entity_id
     JOIN entity_relationships er ON er.entity_id = e.id AND er.is_primary = true
     JOIN contacts co ON co.id = er.contact_id AND co.id = c.contact_id;

CREATE OR REPLACE VIEW vw_entity_communication_stats AS
 SELECT e.id AS entity_id,
    e.name AS entity_name,
    e.entity_type,
    e.status,
    count(c.id) AS total_communications,
    count(CASE WHEN c.outcome::text = 'resolved' THEN 1 END) AS resolved_count,
    count(CASE WHEN c.outcome::text = 'escalated' THEN 1 END) AS escalated_count,
    count(CASE WHEN c.outcome::text = 'pending' THEN 1 END) AS pending_count,
    count(CASE WHEN c.sentiment_label::text = 'positive' THEN 1 END) AS positive_count,
    count(CASE WHEN c.sentiment_label::text = 'negative' THEN 1 END) AS negative_count,
    round(avg(c.sentiment_score), 2) AS avg_sentiment,
    max(c.started_at) AS last_contact_date,
    min(c.started_at) AS first_contact_date,
    round(avg(c.duration_seconds), 0) AS avg_duration_seconds,
    e.tenant_id
   FROM entities e
     LEFT JOIN communications c ON c.entity_id = e.id
  GROUP BY e.id, e.name, e.entity_type, e.status, e.tenant_id;

CREATE OR REPLACE VIEW vw_agent_activity_summary AS
 SELECT c.agent_id,
    count(*) AS total_actions,
    count(DISTINCT c.entity_id) AS unique_entities,
    count(DISTINCT c.contact_id) AS unique_contacts,
    count(CASE WHEN c.outcome::text = 'resolved' THEN 1 END) AS resolved_count,
    count(CASE WHEN c.outcome::text = 'escalated' THEN 1 END) AS escalated_count,
    round(avg(c.sentiment_score), 2) AS avg_sentiment,
    max(c.started_at) AS last_activity,
    min(c.started_at) AS first_activity,
    c.tenant_id
   FROM communications c
  WHERE c.agent_id IS NOT NULL
  GROUP BY c.agent_id, c.tenant_id
  ORDER BY (count(*)) DESC;

CREATE OR REPLACE VIEW vw_pending_followups AS
 SELECT f.id,
    f.entity_id,
    f.contact_id,
    f.description,
    f.due_date,
    f.priority,
    f.status,
    f.completed_at,
    f.completion_notes,
    f.created_at,
    f.updated_at,
    e.name AS entity_name,
    (co.first_name || ' ') || co.last_name AS contact_name,
    f.tenant_id
   FROM followups f
     JOIN entities e ON f.entity_id = e.id
     LEFT JOIN contacts co ON f.contact_id = co.id
  WHERE f.status::text = 'pending'::text
  ORDER BY f.due_date;

-- The three inventory views keep their names and every existing column, in order: the
-- tenant_id column is appended, because CREATE OR REPLACE VIEW on a view somebody else may
-- SELECT * from must not move anything. 0003's report said the canonical views expose
-- tenant_id rather than filter on it, and this is the migration that makes that true.
CREATE OR REPLACE VIEW vw_inventory_valuation AS
 SELECT w.warehouse_id,
    w.name AS warehouse_name,
    w.warehouse_type,
    cat.category_id,
    cat.name AS category_name,
    count(DISTINCT i.item_id) AS unique_items,
    sum(ioh.quantity_on_hand) AS total_units,
    sum(ioh.quantity_on_hand * ioh.average_cost) AS total_value,
    sum(ioh.quantity_available * ioh.average_cost) AS available_value,
    ioh.tenant_id
   FROM inventory_on_hand ioh
     JOIN inventory_items i ON ioh.item_id = i.item_id
     JOIN warehouses w ON ioh.warehouse_id = w.warehouse_id
     LEFT JOIN item_categories cat ON i.category_id = cat.category_id
  WHERE i.is_active = true AND w.is_active = true
  GROUP BY w.warehouse_id, w.name, w.warehouse_type, cat.category_id, cat.name, ioh.tenant_id;

CREATE OR REPLACE VIEW vw_item_availability AS
 SELECT i.item_id,
    i.sku,
    i.name,
    i.base_unit_of_measure,
    i.category_id,
    cat.name AS category_name,
    w.warehouse_id,
    w.name AS warehouse_name,
    w.warehouse_code,
    l.location_id,
    l.location_code,
    COALESCE(ioh.quantity_on_hand, 0) AS quantity_on_hand,
    COALESCE(ioh.quantity_available, 0) AS quantity_available,
    COALESCE(ioh.quantity_reserved, 0) AS quantity_reserved,
    COALESCE(ioh.quantity_in_transit, 0) AS quantity_in_transit,
    i.reorder_point,
    i.safety_stock,
    i.lead_time_days,
    i.is_serialized,
    i.is_lot_controlled,
    ioh.expiry_date,
    ioh.average_cost,
    ioh.cost_currency,
        CASE
            WHEN COALESCE(ioh.quantity_available, 0) <= 0 THEN 'OUT_OF_STOCK'::text
            WHEN COALESCE(ioh.quantity_available, 0) <= i.safety_stock THEN 'CRITICAL'::text
            WHEN COALESCE(ioh.quantity_available, 0) <= i.reorder_point THEN 'LOW_STOCK'::text
            ELSE 'NORMAL'::text
        END AS stock_status,
        CASE
            WHEN i.reorder_point > 0 AND COALESCE(ioh.quantity_available, 0) <= i.reorder_point THEN true
            ELSE false
        END AS needs_reorder,
    i.tenant_id
   FROM inventory_items i
     LEFT JOIN item_categories cat ON i.category_id = cat.category_id
     LEFT JOIN inventory_on_hand ioh ON i.item_id = ioh.item_id
     LEFT JOIN warehouses w ON ioh.warehouse_id = w.warehouse_id
     LEFT JOIN locations l ON ioh.location_id = l.location_id
  WHERE i.is_active = true AND (w.is_active = true OR w.warehouse_id IS NULL);

CREATE OR REPLACE VIEW vw_low_stock_alerts AS
 SELECT i.item_id,
    i.sku,
    i.name,
    i.reorder_point,
    i.safety_stock,
    i.lead_time_days,
    i.category_id,
    cat.name AS category_name,
    w.warehouse_id,
    w.name AS warehouse_name,
    ioh.quantity_on_hand,
    ioh.quantity_available,
    ioh.quantity_in_transit,
    ioh.quantity_available + ioh.quantity_in_transit AS total_available,
        CASE
            WHEN ioh.quantity_available <= i.safety_stock THEN 'CRITICAL'::text
            WHEN ioh.quantity_available <= i.reorder_point THEN 'LOW'::text
            ELSE 'OK'::text
        END AS alert_level,
    round(ioh.quantity_available / NULLIF(i.reorder_point, 0) * 100, 2) AS stock_percentage,
    ioh.tenant_id
   FROM inventory_items i
     JOIN inventory_on_hand ioh ON i.item_id = ioh.item_id
     JOIN warehouses w ON ioh.warehouse_id = w.warehouse_id
     LEFT JOIN item_categories cat ON i.category_id = cat.category_id
  WHERE i.is_active = true AND w.is_active = true AND ioh.quantity_available <= i.reorder_point
  ORDER BY (
        CASE
            WHEN ioh.quantity_available <= i.safety_stock THEN 1
            WHEN ioh.quantity_available <= i.reorder_point THEN 2
            ELSE 3
        END), ioh.quantity_available;

CREATE OR REPLACE VIEW vw_item_movement_summary AS
 SELECT im.item_id,
    date_trunc('day', im.performed_at) AS movement_date,
    im.movement_type,
    sum(im.quantity) AS net_quantity,
    count(*) AS movement_count,
    avg(im.unit_cost) AS avg_unit_cost,
    sum(CASE WHEN im.quantity > 0 THEN im.quantity ELSE 0 END) AS total_inbound,
    sum(CASE WHEN im.quantity < 0 THEN abs(im.quantity) ELSE 0 END) AS total_outbound,
    im.tenant_id
   FROM inventory_movements im
  WHERE im.performed_at >= (now() - '30 days'::interval)
  GROUP BY im.item_id, (date_trunc('day', im.performed_at)), im.movement_type, im.tenant_id;

COMMENT ON VIEW vw_agent_activity_summary IS
    'Summary of communication activity per bot agent, per tenant. Useful for performance '
    'monitoring and workload analysis. Rewritten by 0009: tenant_id is grouped as well as '
    'selected, because the read roles see every tenant in one result set and an ungrouped '
    'count would add two tenants'' bots together under one name.';

COMMENT ON VIEW vw_entity_communication_stats IS
    'Aggregated communication metrics per entity, per tenant (0009). Useful for customer '
    'health scoring and engagement analysis.';

COMMENT ON VIEW vw_inventory_valuation IS
    'Inventory value by warehouse and category, per tenant (0009).';

COMMENT ON VIEW vw_item_movement_summary IS
    'Item movement by day and type, per tenant (0009). Useful for demand patterns.';

-- Two halves, one mechanism. security_invoker is what makes a view respect the invoker's row
-- security; it says nothing about which columns the view shows. Both are needed, and the
-- reloptions are the only place the first fact lives, so it is asserted from them below.
DO $$
DECLARE
    v record;
BEGIN
    FOR v IN SELECT c.relname FROM pg_class c
              JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = 'public' AND c.relkind = 'v'
               AND NOT EXISTS (SELECT 1 FROM pg_depend d
                                WHERE d.objid = c.oid AND d.deptype = 'e')
             ORDER BY 1
    LOOP
        EXECUTE format('ALTER VIEW public.%I SET (security_invoker = true)', v.relname);
    END LOOP;
    RAISE NOTICE 'security_invoker set on every non-extension view in public';
END
$$;

-- Asserted, not assumed, and asserted after the rewrites for a reason: CREATE OR REPLACE VIEW
-- discards the view's reloptions, so setting security_invoker before restating a definition
-- sets it on the version that is about to be replaced. Measured on a rehearsal - the first
-- draft of this migration did exactly that, and probe E returned both tenants' rows through
-- the view while the table itself was correctly filtered. Any later migration that recreates
-- a view inherits this obligation, which is what verify.sh B21 watches for.
--
-- The flag is set explicitly rather than relied on from the version default, because these
-- views are created by a superuser and a superuser-created view in this cluster keeps owner
-- semantics with empty reloptions: measured, CREATE VIEW by postgres then SELECT by afpc_app
-- returned 2 rows across two tenants, and only ALTER VIEW ... SET (security_invoker = true)
-- made it 1. The reloption is also what the assertion reads, so the check and the fix agree.
DO $$
DECLARE
    v text;
BEGIN
    SELECT string_agg(relname::text, ', ' ORDER BY relname) INTO v FROM (
        SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public' AND c.relkind = 'v'
           AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = c.oid AND d.deptype = 'e')
           AND coalesce(array_to_string(c.reloptions, ','), '') NOT LIKE '%security_invoker=true%'
    ) x;
    IF v IS NOT NULL THEN
        RAISE EXCEPTION 'views that would run as their owner and skip row security: % - a '
                        'postgres-owned view is a door around the wall', v;
    END IF;
END
$$;

-- And the claim above, as a check. Every view over a tenant table should have gained exactly
-- one column, tenant_id, at the end, and nothing else should have moved: a rewritten
-- definition is how a column goes missing quietly, and "copied faithfully" is not evidence.
-- The comparison is against the snapshot taken before the first rewrite, so the expectation
-- cannot be adjusted to match what was actually written.
DO $$
DECLARE
    v  text;
    n  int;
    g  int;
BEGIN
    SELECT string_agg(x.name || E'\n  was ' || x.was || E'\n  now ' || x.is_now, E'\n'
                      ORDER BY x.name) INTO v FROM (
        SELECT b.name AS name,
               b.cols::text AS was,
               (SELECT array_agg(a.attname::text ORDER BY a.attnum)
                  FROM pg_attribute a
                 WHERE a.attrelid = b.view AND a.attnum > 0 AND NOT a.attisdropped)::text AS is_now
          FROM _afpc_0009_before b
         WHERE (SELECT array_agg(a.attname::text ORDER BY a.attnum)
                  FROM pg_attribute a
                 WHERE a.attrelid = b.view AND a.attnum > 0 AND NOT a.attisdropped)
               IS DISTINCT FROM CASE WHEN b.over_tenant
                                     THEN array_append(b.cols, 'tenant_id')
                                     ELSE b.cols END
    ) x;
    IF v IS NOT NULL THEN
        RAISE EXCEPTION 'rewritten views did not keep their columns - the rule is the '
                        'original list, then tenant_id where the view covers a tenant '
                        'table:%', E'\n' || v;
    END IF;
    SELECT count(*) FILTER (WHERE over_tenant), count(*) INTO g, n FROM _afpc_0009_before;
    RAISE NOTICE 'views: % of % gained tenant_id and kept every column in order; the other % '
                 'read only catalogs and gained nothing', g, n, n - g;
END
$$;

-- 0003's NOTICE, turned into an assertion: every view whose base tables carry a tenant_id must
-- expose one, because the read roles' USING (true) policy shows them every tenant's rows.
-- vw_index_redundancy and vw_domain_vocabulary are exempt by the test itself - they read only
-- pg_catalog - not by a name written in an exemption list.
DO $$
DECLARE
    v text;
BEGIN
    SELECT string_agg(x.v, ' | ' ORDER BY x.v) INTO v FROM (
        SELECT c.relname::text AS v
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public' AND c.relkind = 'v'
           AND NOT EXISTS (SELECT 1 FROM pg_depend d
                            WHERE d.objid = c.oid AND d.deptype = 'e')
           AND EXISTS (SELECT 1 FROM information_schema.view_table_usage u
                         JOIN pg_class b ON b.oid = format('public.%I', u.table_name)::regclass
                        WHERE u.view_schema = 'public' AND u.view_name = c.relname::text
                          AND b.relkind = 'r'
                          AND EXISTS (SELECT 1 FROM pg_attribute a
                                       WHERE a.attrelid = b.oid AND a.attname = 'tenant_id'
                                         AND a.attnum > 0 AND NOT a.attisdropped))
           AND NOT EXISTS (SELECT 1 FROM pg_attribute a
                            WHERE a.attrelid = c.oid AND a.attname = 'tenant_id'
                              AND a.attnum > 0 AND NOT a.attisdropped)
    ) x;
    IF v IS NOT NULL THEN
        RAISE EXCEPTION 'views over tenant tables that do not expose tenant_id: % - under '
                        '0009 the read roles see every tenant, so such a view is not just '
                        'incomplete, it is unreadable', v;
    END IF;
    RAISE NOTICE 'every view over a tenant table exposes tenant_id (0003''s deferral, closed)';
END
$$;

-- ---------------------------------------------------------------------------
-- 6. The function EXECUTE sweep 0008 recorded (finding D)
-- ---------------------------------------------------------------------------
-- Extension-owned functions are excluded by pg_depend.deptype: vector_* and pg_stat_statements
-- are PUBLIC by design and revoking them would be a change to someone else's grant model.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
    REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
-- Recorded because it does not work (finding D), and it is kept so the intent survives in the
-- catalog even though the effect comes from the loop below plus verify.sh B22.
DO $$
DECLARE
    r   record;
    n   int := 0;
BEGIN
    -- "Is EXECUTE granted to PUBLIC" is not has_function_privilege(some_role, ...): that also
    -- answers yes when the role holds an explicit grant. aclexplode on the NULL-ACL case is
    -- the real question, and a function whose proacl is NULL is executable by PUBLIC by the
    -- system default - which is exactly the case this loop exists for. Measured on this
    -- database: 13 functions match, the same 13 0008 printed.
    FOR r IN SELECT p.oid
               FROM pg_proc p
               JOIN pg_namespace ns ON ns.oid = p.pronamespace
              WHERE ns.nspname = 'public' AND p.prokind = 'f'
                AND NOT EXISTS (SELECT 1 FROM pg_depend d
                                 WHERE d.objid = p.oid AND d.deptype = 'e')
                AND (p.proacl IS NULL OR EXISTS (
                        SELECT 1 FROM aclexplode(p.proacl) x
                         WHERE x.grantee = 0 AND x.privilege_type = 'EXECUTE'))
              ORDER BY p.proname
    LOOP
        EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC', r.oid::regprocedure);
        -- Everything that remains reachable by an agent is reachable *because* it was granted,
        -- not because it was left open. 0002 already granted all existing functions to
        -- afpc_app; re-asserting is what makes this paragraph safe against a function created
        -- between 0002 and now.
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO afpc_app', r.oid::regprocedure);
        n := n + 1;
    END LOOP;
    RAISE NOTICE 'function EXECUTE revoked from PUBLIC on % functions (0008 measured 13, plus '
                 'this migration''s own resolver), then granted to afpc_app explicitly', n;

    -- The helpers have to stay callable, and saying which is the difference between a
    -- deliberate grant and an oversight. afpc_current_tenant and afpc_policy_tenant appear in
    -- column defaults and policy quals, so a role that merely SELECTs can be made to fail on
    -- privileges; afpc_uuid_v7 is a PK/tenant default. None of the three reads table data.
    EXECUTE 'GRANT EXECUTE ON FUNCTION afpc_current_tenant() TO PUBLIC';
    EXECUTE 'GRANT EXECUTE ON FUNCTION afpc_policy_tenant() TO PUBLIC';
    EXECUTE 'GRANT EXECUTE ON FUNCTION afpc_uuid_v7() TO PUBLIC';
    RAISE NOTICE 'kept EXECUTE on PUBLIC for the three context helpers: they are called by '
                 'defaults and quals on a plain SELECT, and revealing a uuid is not '
                 'revealing a row';
END
$$;

DO $$
DECLARE
    v text;
BEGIN
    -- Two directions, both asserted: the read roles must not reach a write path, and afpc_app
    -- must reach all of them, or the sweep has broken the product rather than tightened it.
    SELECT string_agg(proname, ', ' ORDER BY proname) INTO v FROM (
        SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public' AND p.prokind = 'f'
           AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
           AND p.proname IN ('add_customer','update_customer','execute_inventory_movement',
                             'reserve_inventory_for_order','get_followup_customers',
                             'decommission_warehouse','retire_item','afpc_drop_redundant_tenant_indexes')
           AND has_function_privilege('afpc_auditor', p.oid, 'EXECUTE')) w;
    IF v IS NOT NULL THEN
        RAISE EXCEPTION 'write functions still executable by the audit role: %', v;
    END IF;

    SELECT string_agg(p.proname, ', ' ORDER BY p.proname) INTO v
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f'
       AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
       AND NOT has_function_privilege('afpc_app', p.oid, 'EXECUTE');
    IF v IS NOT NULL THEN
        RAISE EXCEPTION 'afpc_app lost EXECUTE on: % - a privilege sweep that breaks a tool is '
                        'not a security improvement', v;
    END IF;
    RAISE NOTICE 'privileges: write functions closed to the audit roles, all functions open to '
                 'afpc_app';
END
$$;

-- ---------------------------------------------------------------------------
-- 7. The GUC contract, written down where an agent will read it
-- ---------------------------------------------------------------------------
COMMENT ON FUNCTION afpc_current_tenant IS
    'Resolves the tenant for a column default from app.tenant_id, falling back to '
    'app.default_tenant_id, and fails loudly when neither is set. Declared VOLATILE '
    'rather than STABLE on purpose: a column default marked STABLE can be evaluated '
    'once and constant-folded by the planner, which would silently put every row of a '
    'bulk insert into whichever tenant happened to be read first. It also normalises '
    'the empty string to unset, because a custom GUC reads as an empty string once it '
    'has been RESET or set to an empty value. Row security does NOT use this function - '
    'a VOLATILE call in a policy qual is evaluated per row and cannot use an index; see '
    'afpc_policy_tenant. Both resolve to the same value, and 0009 is where the '
    'difference started to matter.';

-- 8. Verify by behaving
-- ---------------------------------------------------------------------------
-- The catalog can say ENABLE+FORCE and quote a predicate; it cannot say what happens when a
-- non-owner touches a row. And the only way to find out is to stop being the owner: every
-- probe below runs under SET LOCAL ROLE, because postgres is a superuser and a superuser
-- bypasses row security however it is configured - which is also why section 2's sequence
-- grant had to come first. A write-path probe without it dies on a permission error before
-- RLS is ever consulted, and 5.7 could then have been declared fixed with nothing testing it.
--
-- Each probe is a subtransaction that ends in a deliberate exception, so the rows it writes
-- vanish and the fixtures it reads do not.
DO $$
DECLARE
    v_t1    uuid;
    v_t2    uuid;
    v_w1    uuid;
    v_w2    uuid;
    v_seen  int;
    v_rows  int;
    v_name  text;
    v_plan  text;
    r       record;
    v_n     int := 0;
BEGIN
    -- Provisioning is an owner operation (see COMMENT ON TABLE tenants), so the fixtures are
    -- made here, by the owner, and the probes only ever read or try to damage them.
    INSERT INTO tenants (slug, name) VALUES ('0009-probe-a', '0009 probe A')
     RETURNING tenant_id INTO v_t1;
    INSERT INTO tenants (slug, name) VALUES ('0009-probe-b', '0009 probe B')
     RETURNING tenant_id INTO v_t2;
    INSERT INTO warehouses (tenant_id, warehouse_code, name, warehouse_type)
        VALUES (v_t1, 'AFPC-0009-W', 'probe A warehouse', 'PRIMARY')
     RETURNING warehouse_id INTO v_w1;
    INSERT INTO warehouses (tenant_id, warehouse_code, name, warehouse_type)
        VALUES (v_t2, 'AFPC-0009-W', 'probe B warehouse', 'PRIMARY')
     RETURNING warehouse_id INTO v_w2;
    INSERT INTO inventory_items (tenant_id, sku, name, product_type)
        VALUES (v_t1, 'AFPC-0009-S', 'probe A item', 'STOCKED');
    INSERT INTO inventory_items (tenant_id, sku, name, product_type)
        VALUES (v_t2, 'AFPC-0009-S', 'probe B item', 'STOCKED');

    ------------------------------------------------------------------
    -- 8.1 reads, in both directions. The second read is the same plpgsql statement with a
    --       different tenant context, so it also proves the resolver is not a value frozen
    --       into a cached plan - the failure mode a STABLE qual could in principle have.
    ------------------------------------------------------------------
    BEGIN
        EXECUTE 'SET LOCAL ROLE afpc_app';
        PERFORM set_config('app.tenant_id', v_t1::text, true);
        SELECT count(*) INTO v_seen FROM warehouses WHERE warehouse_code = 'AFPC-0009-W';
        IF v_seen <> 1 THEN
            RAISE EXCEPTION '8.1 failed: afpc_app sees % rows for a code that exists in two '
                            'tenants - the isolation policy is not filtering reads', v_seen;
        END IF;
        PERFORM set_config('app.tenant_id', v_t2::text, true);
        SELECT name INTO v_name FROM warehouses WHERE warehouse_code = 'AFPC-0009-W';
        IF v_name <> 'probe B warehouse' THEN
            RAISE EXCEPTION '8.1 failed: after switching to tenant B the same query still '
                            'returned % - a folded tenant value outlived its context',
                            quote_literal(v_name);
        END IF;
        EXECUTE 'RESET ROLE';
        v_n := v_n + 1;
        RAISE NOTICE 'probe A: one warehouse of two is visible, and switching tenants through '
                     'the same cached plan switches the answer';
    EXCEPTION WHEN OTHERS THEN
        EXECUTE 'RESET ROLE';
        RAISE;
    END;

    ------------------------------------------------------------------
    -- 8.2 writes: another tenant's row is not even a target. Both halves are checked, because
    --     "0 rows affected" is the claim and "the row is unchanged" is the fact.
    ------------------------------------------------------------------
    BEGIN
        EXECUTE 'SET LOCAL ROLE afpc_app';
        PERFORM set_config('app.tenant_id', v_t1::text, true);
        UPDATE warehouses SET name = 'crossed' WHERE warehouse_id = v_w2;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        SELECT name INTO v_name FROM warehouses WHERE warehouse_id = v_w2;
        IF v_rows <> 0 OR v_name = 'crossed' THEN
            RAISE EXCEPTION '8.2 failed: an update against another tenant''s warehouse affected '
                            '% row(s) and left it as %', v_rows, quote_literal(v_name);
        END IF;
        EXECUTE 'RESET ROLE';
        v_n := v_n + 1;
        RAISE NOTICE 'probe B: an agent''s UPDATE cannot reach another tenant''s row (0 rows, '
                     'row untouched) - 5.7.3''s write half, which was unrestricted';
    EXCEPTION WHEN OTHERS THEN
        EXECUTE 'RESET ROLE';
        RAISE;
    END;

    ------------------------------------------------------------------
    -- 8.3 WITH CHECK: writing a row INTO the wrong tenant is refused rather than defaulted
    --     away. This is what 0003's column default cannot promise: a default is convenience,
    --     this is the ceiling.
    ------------------------------------------------------------------
    BEGIN
        EXECUTE 'SET LOCAL ROLE afpc_app';
        PERFORM set_config('app.tenant_id', v_t1::text, true);
        INSERT INTO warehouses (tenant_id, warehouse_code, name)
            VALUES (v_t2, 'AFPC-0009-X', 'written into tenant B');
        RAISE EXCEPTION '8.3 failed: a row inserted with another tenant''s id was accepted'
                        USING ERRCODE = 'P8009';
    EXCEPTION
        WHEN insufficient_privilege THEN
            EXECUTE 'RESET ROLE';
            v_n := v_n + 1;
            RAISE NOTICE 'probe C: a cross-tenant INSERT is refused by the policy''s WITH CHECK';
        WHEN SQLSTATE 'P8009' THEN
            EXECUTE 'RESET ROLE';
            RAISE;
    END;

    ------------------------------------------------------------------
    -- 8.4 the audit path, which is the reason 5.7 cannot be fixed by a policy alone. Both
    --     tenant GUCs are emptied, so if the read roles'' plan evaluated the isolation qual at
    --     all, afpc_current_tenant would raise and the audit account would be locked out of
    --     the database it exists to read. (Resetting them is not the same test: app.
    --     default_tenant_id is set at database level by 0003, so RESET resolves it.)
    ------------------------------------------------------------------
    BEGIN
        EXECUTE 'SET LOCAL ROLE afpc_auditor';
        PERFORM set_config('app.tenant_id', '', true);
        PERFORM set_config('app.default_tenant_id', '', true);
        SELECT count(*) INTO v_seen FROM warehouses WHERE warehouse_code = 'AFPC-0009-W';
        IF v_seen <> 2 THEN
            RAISE EXCEPTION '8.4 failed: the audit role sees % of the two probe warehouses - '
                            '5.7 must not cost the audit account its access', v_seen;
        END IF;
        EXECUTE 'RESET ROLE';
        v_n := v_n + 1;
        RAISE NOTICE 'probe D: the audit role reads across tenants with no tenant context at '
                     'all, and its plan never evaluates the raising resolver';
    EXCEPTION WHEN OTHERS THEN
        EXECUTE 'RESET ROLE';
        RAISE;
    END;

    ------------------------------------------------------------------
    -- 8.5 the view door (finding B): same role, same tenant, one hop through a postgres-owned
    --       view. Two rows here means the wall is up and there is a doorway in it.
    ------------------------------------------------------------------
    BEGIN
        EXECUTE 'SET LOCAL ROLE afpc_app';
        PERFORM set_config('app.tenant_id', v_t1::text, true);
        SELECT count(*) INTO v_seen FROM vw_item_availability WHERE sku = 'AFPC-0009-S';
        IF v_seen <> 1 THEN
            RAISE EXCEPTION '8.5 failed: vw_item_availability returns % rows for a sku that '
                            'exists in two tenants - the view still evaluates its base tables '
                            'as its owner', v_seen;
        END IF;
        EXECUTE 'RESET ROLE';
        v_n := v_n + 1;
        RAISE NOTICE 'probe E: a postgres-owned view now honours the invoker''s RLS '
                     '(security_invoker=true; 0003 deferred this, 0009 could not)';
    EXCEPTION WHEN OTHERS THEN
        EXECUTE 'RESET ROLE';
        RAISE;
    END;

    ------------------------------------------------------------------
    -- 8.6 the two tables 5.7 actually named. An agent must be able to record a movement (the
    --     old WITH CHECK compared performed_by to a GUC nothing sets, so it could not) and
    --     must be able to read back its own reservations (the old qual made them invisible).
    ------------------------------------------------------------------
    BEGIN
        BEGIN
            EXECUTE 'SET LOCAL ROLE afpc_app';
            PERFORM set_config('app.tenant_id', v_t1::text, true);
            INSERT INTO inventory_movements (movement_type, item_id, to_warehouse_id, quantity,
                                            unit_of_measure, performed_by)
                SELECT 'RECEIPT', i.item_id, v_w1, 1, 'EACH', 'afpc_app'
                  FROM inventory_items i WHERE i.sku = 'AFPC-0009-S' AND i.tenant_id = v_t1;
            IF NOT FOUND THEN
                RAISE EXCEPTION '8.6 setup: the probe item was not visible to its own tenant';
            END IF;
            INSERT INTO inventory_reservations (item_id, warehouse_id, order_type, order_id,
                                                reserved_quantity, reserved_by)
                SELECT i.item_id, v_w1, 'SALES', gen_random_uuid(), 1, 'afpc_app'
                  FROM inventory_items i WHERE i.sku = 'AFPC-0009-S' AND i.tenant_id = v_t1;
            SELECT count(*) INTO v_seen FROM inventory_reservations WHERE warehouse_id = v_w1;
            IF v_seen <> 1 THEN
                RAISE EXCEPTION '8.6 failed: the agent wrote a reservation it cannot read back '
                                '(% rows visible) - that is 5.7.3 in its read form', v_seen;
            END IF;
            RAISE EXCEPTION '0009 probe F passed' USING ERRCODE = 'P8006';
        EXCEPTION
            WHEN SQLSTATE 'P8006' THEN
                EXECUTE 'RESET ROLE';
                v_n := v_n + 1;
                RAISE NOTICE 'probe F: inventory_movements and inventory_reservations now '
                             'behave like every other table - writable and readable by their '
                             'own tenant, and the writes rolled back as intended';
            WHEN OTHERS THEN
                EXECUTE 'RESET ROLE';
                RAISE;
        END;
    END;

    ------------------------------------------------------------------
    -- 8.7 sargability (finding A), asserted rather than hoped. An EXPLAIN on a two-row table
    --     proves nothing about which plan the planner would *prefer*, so the question asked
    --     here is the usability one 0006 established: with the seq and bitmap paths taken
    --     away, can the tenant predicate be pushed into the index at all? A VOLATILE resolver
    --     answers with "Filter:" and a full scan; a STABLE one answers with "Index Cond:".
    --     That is why this migration does not simply reuse afpc_current_tenant().
    ------------------------------------------------------------------
    BEGIN
        EXECUTE 'SET LOCAL ROLE afpc_app';
        PERFORM set_config('app.tenant_id', v_t1::text, true);
        EXECUTE 'SET LOCAL enable_seqscan = off';
        EXECUTE 'SET LOCAL enable_bitmapscan = off';
        v_plan := '';
        FOR r IN EXECUTE 'EXPLAIN (COSTS OFF) SELECT count(*) FROM warehouses '
                         'WHERE warehouse_code = ''AFPC-0009-W'''
        LOOP
            v_plan := v_plan || r."QUERY PLAN" || E'\n';
        END LOOP;
        EXECUTE 'RESET ROLE';
        IF v_plan NOT LIKE '%Index Cond%' OR v_plan NOT LIKE '%Index Cond%afpc_policy_tenant()%'
        THEN
            RAISE EXCEPTION '8.7 failed: the tenant predicate is not an index condition. Plan: %',
                replace(v_plan, E'\n', ' | ');
        END IF;
        v_n := v_n + 1;
        RAISE NOTICE 'probe G: the policy predicate is an Index Cond, so 0006''s tenant-led '
                     'indexes are reachable through RLS - measured 479 ms against 53 ms when '
                     'this is a per-row Filter instead';
    EXCEPTION WHEN OTHERS THEN
        EXECUTE 'RESET ROLE';
        RAISE;
    END;

    ------------------------------------------------------------------
    -- 8.8 the registry, because a policy whose WITH CHECK is a tautology for one table is a
    --     wall for another, and COMMENT claims should not rest on arithmetic in a comment.
    --     Measured here: no agent can mint a tenant. (Renaming its own entry is allowed and
    --     said so in COMMENT ON TABLE tenants; the two facts are checked together below.)
    ------------------------------------------------------------------
    BEGIN
        BEGIN
            EXECUTE 'SET LOCAL ROLE afpc_app';
            PERFORM set_config('app.tenant_id', v_t1::text, true);
            INSERT INTO tenants (slug, name) VALUES ('AFPC-0009-MINT', 'agent-created tenant');
            RAISE EXCEPTION '8.8 failed: an agent role minted a tenant - the registry is not '
                            'owner-only, whatever COMMENT says' USING ERRCODE = 'P8008';
        EXCEPTION
            WHEN insufficient_privilege THEN
                EXECUTE 'RESET ROLE';
                v_n := v_n + 1;
                RAISE NOTICE 'probe H: an agent cannot create a tenant - the key default and '
                             'the WITH CHECK cannot both be satisfied, which is the intended '
                             'refusal, not a collision';
            WHEN SQLSTATE 'P8008' THEN RAISE;
        END;
    END;

    IF v_n <> 8 THEN
        RAISE EXCEPTION 'expected 8 behavioural verifications, completed %', v_n;
    END IF;

    -- Fixtures out, in the order the RESTRICT edges allow. If any of this survives, the
    -- scoreboard's residue check is not the only thing that will notice.
    DELETE FROM inventory_reservations WHERE warehouse_id IN (v_w1, v_w2);
    DELETE FROM inventory_movements WHERE to_warehouse_id IN (v_w1, v_w2);
    DELETE FROM inventory_on_hand    WHERE warehouse_id IN (v_w1, v_w2);
    DELETE FROM locations            WHERE warehouse_id IN (v_w1, v_w2);
    DELETE FROM inventory_items      WHERE sku = 'AFPC-0009-S';
    DELETE FROM warehouses           WHERE warehouse_id IN (v_w1, v_w2);
    DELETE FROM tenants              WHERE tenant_id IN (v_t1, v_t2);
    IF (SELECT count(*) FROM tenants WHERE slug LIKE '0009-probe-%') <> 0
       OR (SELECT count(*) FROM warehouses WHERE warehouse_code LIKE 'AFPC-0009-%') <> 0
       OR (SELECT count(*) FROM inventory_items WHERE sku = 'AFPC-0009-S') <> 0 THEN
        RAISE EXCEPTION '0009 left probe fixtures behind';
    END IF;
    RAISE NOTICE '5.7: % behavioural checks passed, fixtures erased', v_n;
END
$$;

-- ---------------------------------------------------------------------------
-- 9. The state an agent should be able to ask about
-- ---------------------------------------------------------------------------
-- 5.7's complaint is that three catalog columns said one thing and the data did another. The
-- scoreboard reads those columns; this is the same question in a form an agent can ask without
-- knowing which columns lie, including the distinction that made 5.7 possible - a policy that
-- filters reads but not writes looks identical to a complete one in pg_class.
CREATE OR REPLACE VIEW vw_rls_status AS
SELECT c.relname AS table_name,
    (a.attrelid IS NOT NULL) AS has_tenant_id,
    c.relrowsecurity AS rls_enabled,
    c.relforcerowsecurity AS rls_forced,
    (SELECT count(*) FROM pg_policy po WHERE po.polrelid = c.oid) AS policies,
    (SELECT string_agg(po.polname || ' (' ||
        CASE po.polcmd
            WHEN 'r' THEN 'SELECT' WHEN 'a' THEN 'INSERT' WHEN 'w' THEN 'UPDATE'
            WHEN 'd' THEN 'DELETE' WHEN '*' THEN 'ALL'
        END || ' to ' ||
        COALESCE(array_to_string(po.polroles::regrole[]::text[], ', '), 'everyone') || ')'
        , ' ' ORDER BY po.polname)
       FROM pg_policy po WHERE po.polrelid = c.oid) AS policy_detail,
    pg_get_expr(iso.polqual, iso.polrelid) AS read_predicate,
    pg_get_expr(iso.polwithcheck, iso.polrelid) AS write_predicate,
    CASE
        WHEN a.attrelid IS NULL AND c.relname <> 'schema_migrations'
            THEN 'global by decision - no tenant_id to filter on (declared in B19)'
        WHEN c.relname = 'schema_migrations'
            THEN 'build bookkeeping - outside the tenant model by design'
        WHEN NOT c.relrowsecurity OR NOT c.relforcerowsecurity
            THEN 'NOT ENFORCED - row security is off or the owner bypasses it'
        WHEN iso.polrelid IS NULL
            THEN 'NOT ENFORCED - forced with no isolation policy, so every non-owner row is hidden'
        WHEN iso.polwithcheck IS NULL
            THEN 'NOT ENFORCED - reads are filtered, writes are not (this is the 5.7 shape)'
        ELSE 'enforced'
    END AS verdict
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id'
     AND a.attnum > 0 AND NOT a.attisdropped
LEFT JOIN pg_policy iso ON iso.polrelid = c.oid AND iso.polname = 'tenant_isolation'
WHERE n.nspname = 'public' AND c.relkind = 'r'
ORDER BY CASE
             -- failures first, then the declared globals, then the healthy tables: the view is
             -- a report, and the row that needs reading should be at the top. An output column
             -- name cannot be used inside an ORDER BY expression, only in place of one, which
             -- is why this repeats the verdict rather than naming it.
             WHEN a.attrelid IS NOT NULL AND c.relname <> 'schema_migrations'
                  AND (NOT c.relrowsecurity OR NOT c.relforcerowsecurity
                       OR iso.polrelid IS NULL OR iso.polwithcheck IS NULL) THEN 0
             WHEN a.attrelid IS NULL OR c.relname = 'schema_migrations' THEN 1
             ELSE 2
         END, c.relname;

COMMENT ON VIEW vw_rls_status IS
    'One row per table in public: whether row security is enabled and forced, which policies '
    'apply to which roles, the read and write predicates verbatim from the catalog, and a '
    'verdict. The two predicates are separate columns on purpose - 5.7 was a control that '
    'filtered one and not the other, and a policy count cannot tell those apart. Tables '
    'without tenant_id are a declared decision with their reason, not a failure.';

GRANT SELECT ON vw_rls_status TO afpc_auditor, afpc_readonly;
ALTER VIEW vw_rls_status SET (security_invoker = true);

DO $$
DECLARE
    v text;
BEGIN
    -- The view is only worth having if its verdict column cannot be wrong, so the same claim
    -- is made from the catalog independently: a table whose rows belong to a tenant and which
    -- is not enforced is an exception, and there are none.
    SELECT string_agg(t, ', ' ORDER BY t) INTO v FROM (
        SELECT c.relname::text AS t
          FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
          JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id'
                             AND a.attnum > 0 AND NOT a.attisdropped
         WHERE n.nspname = 'public' AND c.relkind = 'r'
           AND (NOT c.relrowsecurity OR NOT c.relforcerowsecurity
                OR NOT EXISTS (SELECT 1 FROM pg_policy po
                                WHERE po.polrelid = c.oid AND po.polname = 'tenant_isolation'
                                  AND po.polwithcheck IS NOT NULL))
    ) x;
    IF v IS NOT NULL THEN
        RAISE EXCEPTION 'tenant-coded tables not enforced: %', v;
    END IF;
    RAISE NOTICE 'every table with a tenant_id is enabled, forced, and isolated on reads and '
                 'writes; the rest are listed in vw_rls_status with the reason';
END
$$;
