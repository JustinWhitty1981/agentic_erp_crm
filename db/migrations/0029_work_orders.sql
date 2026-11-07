-- 0029: work orders, the plan they run against, and the ledger vocabulary they expose
--       (the orders programme, migration 3 of 4)
--
-- A WORK ORDER IS THE ONE DOCUMENT WITH NO COUNTERPARTY
--
-- 0028 gave it a header rule — neither customer nor vendor, because production is not an agreement
-- with anyone — and left the rest of its meaning in a column called line_type. That column has now
-- been proved useful rather than merely plausible: a work order consumes COMPONENT lines and yields
-- PRODUCT lines, and the thing between them is a plan of operations. This file adds that, and repairs
-- two vocabulary facts the addition exposes.
--
-- THE TWO REPAIRS, AND WHY THEY BELONG HERE AND NOT EARLIER
--
--   * `inventory_movements.reference_type` CHECKs {ADJUSTMENT, ORDER, PO, TICKET, TRANSFER}, and
--     0015's CASE maps PURCHASE→'PO' but SALES→'ORDER' and WORK→'ORDER'. So a movement made for a
--     work order and a movement made for a sales order are INDISTINGUISHABLE in the ledger, which is
--     a relationship that reads as if it were maintained. TICKET names a table 0017 deleted — a live
--     constraint pointing at a nonexistent thing, which is the same class of defect dressed smaller.
--     Both edits land here rather than in 0028 because the mapping is only wrong once a work order
--     exists, and a vocabulary change belongs with the door that would exercise it. Measured first:
--     zero movements use TICKET, so dropping the value rewrites no history.
--   * The CASE itself is edited by capture-transform, the way 0022 and 0026 edit installed bodies:
--     read the definition out of pg_proc, replace one needle, DROP by full signature, recreate. A
--     retyped body is a second implementation of the door that drifts from the one 0015 tuned, and
--     4.4's failure mode (two heads, one chosen by positional count) is one DROP away.
--
-- WHAT THIS DOES NOT DO
--
--   * It adds no routing master, no bill of materials, and no `source_routing_operation_id` column.
--     0028's header argued that a uuid column naming no table is the `order_id` defect waiting to be
--     discovered, and an anticipatory seam column is exactly that: unreadable by any key, unfilled by
--     any writer, and certain to be described as live by the next documentation pass. When routings
--     arrive they arrive as `routings` and `routing_operations` with a real key from
--     work_order_operations into them, in the same migration, which is what 0027's rule says an
--     honest seam looks like. §7 records it as owed rather than pre-built.
--   * It moves no stock. Nothing here touches inventory_on_hand; production output and component
--     consumption are 0030's doors, with the reservation half they share.
--   * `release_work_order` is not a door. RELEASED is a forward, non-stock-moving transition and
--     transition_order already implements exactly that rule; a second function enforcing the same
--     move is the duplication 0025's audit trail exists to catch.

SET client_min_messages TO notice;

-- ---------------------------------------------------------------------------
-- 1. work_centres: where the operations run
-- ---------------------------------------------------------------------------
-- Tenant-coded operational master data, not global: a bench is a place inside a warehouse, and a
-- warehouse is a tenant's. Which means the warehouse edge is the same composite form 0028 uses, and
-- a work centre cannot name somebody else's building.
CREATE TABLE IF NOT EXISTS work_centres (
    work_centre_id   uuid          PRIMARY KEY DEFAULT afpc_uuid_v7(),
    tenant_id        uuid          NOT NULL DEFAULT afpc_current_tenant(),
    warehouse_id     uuid          NOT NULL,
    work_centre_code varchar(50)   NOT NULL,
    name             text          NOT NULL,
    capacity_hours_per_day numeric(8,2),
    is_active        boolean       NOT NULL DEFAULT true,
    notes            text,
    created_at       timestamptz   NOT NULL DEFAULT now(),
    updated_at       timestamptz   NOT NULL DEFAULT now(),
    version          integer       NOT NULL DEFAULT 1,

    CONSTRAINT work_centres_tenant_id_fkey
        FOREIGN KEY (tenant_id) REFERENCES tenants (tenant_id) ON DELETE RESTRICT,
    CONSTRAINT work_centres_warehouse_in_tenant_fkey
        FOREIGN KEY (tenant_id, warehouse_id) REFERENCES warehouses (tenant_id, warehouse_id)
        ON DELETE RESTRICT,
    CONSTRAINT work_centres_code_per_tenant UNIQUE (tenant_id, work_centre_code),
    -- The FK target, not a second way to find a centre: an operation's composite key can only be
    -- tenant-led if the referenced pair is unique, which is the same shape 0027 gave entities and
    -- 0028 gave suppliers, warehouses and items.
    CONSTRAINT work_centres_tenant_centre_key UNIQUE (tenant_id, work_centre_id),
    -- The code convention suppliers and SKUs already keep, stated once.
    CONSTRAINT work_centres_code_format CHECK (work_centre_code ~ '^[A-Z0-9][A-Z0-9_-]{0,49}$'),
    CONSTRAINT work_centres_name_present CHECK (btrim(name) <> ''),
    -- NULL capacity is "not measured", not "zero" — the distinction vw_item_movement_summary draws
    -- for days-of-supply and suppliers.lead_time_days repeats. A work centre nobody has timed should
    -- read as unknown rather than as infinitely slow.
    CONSTRAINT work_centres_capacity_known CHECK (capacity_hours_per_day IS NULL
                                                  OR capacity_hours_per_day >= 0)
);

CREATE INDEX IF NOT EXISTS idx_work_centres_tenant_warehouse
    ON work_centres (tenant_id, warehouse_id);
-- The list a planner reads: this tenant's usable centres, in code order. The name is the one
-- idx_suppliers_tenant_active established; a placeholder name that wandered in here would outlive
-- the reason for it.
CREATE INDEX IF NOT EXISTS idx_work_centres_tenant_active
    ON work_centres (tenant_id, is_active, work_centre_code);

COMMENT ON TABLE work_centres IS
    'A place production happens: a bench, a line, a machine, always inside one warehouse of one '
    'tenant. Deliberately thin — this is the minimum a work order can point at. It is not a routing '
    'and not a resource pool; capacity_hours_per_day is a planning hint, NULL means nobody measured '
    'it, and nothing schedules against it yet. Built by 0029.';

-- ---------------------------------------------------------------------------
-- 2. work_order_operations: the plan on the document
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS work_order_operations (
    operation_id       uuid          PRIMARY KEY DEFAULT afpc_uuid_v7(),
    tenant_id          uuid          NOT NULL DEFAULT afpc_current_tenant(),
    order_id           uuid          NOT NULL,
    -- The line this operation acts on, when it acts on one: a PRODUCT line it yields or a COMPONENT
    -- it is machining. Nullable because an operation can be overhead — setup, inspection, queue — and
    -- a plan that forces every step to name a line invents lines.
    order_line_id      uuid,
    work_centre_id     uuid,

    sequence           integer       NOT NULL,
    description        text,
    planned_hours      numeric(10,2),
    actual_hours       numeric(10,2),
    quantity_produced  numeric(18,4) NOT NULL DEFAULT 0,
    quantity_scrapped  numeric(18,4) NOT NULL DEFAULT 0,
    status             varchar(20)   NOT NULL DEFAULT 'PENDING',
    started_at         timestamptz,
    completed_at       timestamptz,
    created_at         timestamptz   NOT NULL DEFAULT now(),
    updated_at         timestamptz   NOT NULL DEFAULT now(),
    version            integer       NOT NULL DEFAULT 1,

    CONSTRAINT work_order_operations_tenant_id_fkey
        FOREIGN KEY (tenant_id) REFERENCES tenants (tenant_id) ON DELETE RESTRICT,
    CONSTRAINT wo_operations_order_in_tenant_fkey
        FOREIGN KEY (tenant_id, order_id) REFERENCES orders (tenant_id, order_id)
        ON DELETE RESTRICT,
    CONSTRAINT wo_operations_line_in_tenant_fkey
        FOREIGN KEY (tenant_id, order_line_id) REFERENCES order_items (tenant_id, order_line_id)
        ON DELETE RESTRICT,
    CONSTRAINT wo_operations_centre_in_tenant_fkey
        FOREIGN KEY (tenant_id, work_centre_id) REFERENCES work_centres (tenant_id, work_centre_id)
        ON DELETE RESTRICT,

    CONSTRAINT wo_operations_sequence_positive CHECK (sequence > 0),
    CONSTRAINT wo_operations_sequence_per_order UNIQUE (tenant_id, order_id, sequence),
    -- A single-column membership CHECK, which is what the vocabulary register's census can read,
    -- plus the state-vs-stamps rule as its own multi-column CHECK. The two are not alternatives:
    -- one publishes the vocabulary, the other says a COMPLETED operation has a completion time.
    CONSTRAINT wo_operations_status_allowed CHECK (status IN ('PENDING','IN_PROGRESS','COMPLETED')),
    CONSTRAINT wo_operations_status_matches_stamps CHECK (
        (status = 'PENDING'     AND started_at IS NULL     AND completed_at IS NULL)
        OR (status = 'IN_PROGRESS' AND started_at IS NOT NULL AND completed_at IS NULL)
        OR (status = 'COMPLETED'   AND started_at IS NOT NULL AND completed_at IS NOT NULL)
    ),
    CONSTRAINT wo_operations_hours_sane CHECK (
        (planned_hours IS NULL OR planned_hours >= 0)
        AND (actual_hours IS NULL OR actual_hours >= 0)),
    CONSTRAINT wo_operations_quantities_non_negative CHECK (
        quantity_produced >= 0 AND quantity_scrapped >= 0),
    -- A completed operation that produced nothing and scrapped nothing is a step that is claimed to
    -- have happened and did not, which is the kind of row a costing review then has to discover.
    CONSTRAINT wo_operations_completed_produced_something CHECK (
        status <> 'COMPLETED' OR quantity_produced + quantity_scrapped > 0)
);

-- No (tenant_id, order_id, sequence) index of its own: wo_operations_sequence_per_order creates
-- exactly that one, and probe H re-asserts it. What is missing without these two is an index for
-- each of the other child-side keys — a composite foreign key's columns have to be reachable as a
-- unit, and 0006 measured what happens when they are not (479 buffers against 6).
CREATE INDEX IF NOT EXISTS wo_operations_tenant_line
    ON work_order_operations (tenant_id, order_line_id);
CREATE INDEX IF NOT EXISTS wo_operations_tenant_centre
    ON work_order_operations (tenant_id, work_centre_id);

COMMENT ON TABLE work_order_operations IS
    'The plan a work order runs: ordered steps, optionally assigned to a work centre and optionally '
    'acting on one line of the document, each with planned and actual hours and produced/scrapped '
    'quantities. sequence is unique within the order, and the status vocabulary is three values whose '
    'relationship to started_at/completed_at is a CHECK rather than a convention. This is the '
    'manufacturing model''s landing point: a routing master would add rows here by copy, and nothing '
    'in this table pretends to be one. Built by 0029.';

-- ---------------------------------------------------------------------------
-- 3. The wall, the trail, the counters — per table, by hand, for the reason 0023 and 0028 give
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    t text;
BEGIN
    FOR t IN SELECT unnest(ARRAY['work_centres','work_order_operations']) LOOP
        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE public.%I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON public.%I', t);
        EXECUTE format('CREATE POLICY tenant_isolation ON public.%I AS PERMISSIVE FOR ALL TO PUBLIC '
                       'USING (tenant_id = afpc_policy_tenant()) '
                       'WITH CHECK ((tenant_id = afpc_policy_tenant()))', t);
        EXECUTE format('DROP POLICY IF EXISTS audit_read_all ON public.%I', t);
        EXECUTE format('CREATE POLICY audit_read_all ON public.%I AS PERMISSIVE '
                       'FOR SELECT TO afpc_auditor, afpc_readonly USING (true)', t);
        EXECUTE format('DROP TRIGGER IF EXISTS afpc_audit_row ON public.%I', t);
        EXECUTE format('CREATE TRIGGER afpc_audit_row AFTER INSERT OR UPDATE OR DELETE ON public.%I '
                       'FOR EACH ROW EXECUTE FUNCTION afpc_audit_row()', t);
        EXECUTE format('DROP TRIGGER IF EXISTS afpc_touch_updated_at ON public.%I', t);
        EXECUTE format('CREATE TRIGGER afpc_touch_updated_at BEFORE INSERT OR UPDATE ON public.%I '
                       'FOR EACH ROW EXECUTE FUNCTION afpc_touch_updated_at()', t);
        EXECUTE format('DROP TRIGGER IF EXISTS afpc_bump_version ON public.%I', t);
        EXECUTE format('CREATE TRIGGER afpc_bump_version BEFORE UPDATE ON public.%I '
                       'FOR EACH ROW EXECUTE FUNCTION afpc_bump_version()', t);
    END LOOP;
END
$$;

-- ---------------------------------------------------------------------------
-- 4. The two doors
-- ---------------------------------------------------------------------------
-- add_work_centre exists because a master-data table with no writer is how `followups` got into the
-- documentation as a live feature (0021 §5's finding). Both doors take a claim, and neither restates a
-- constraint.
CREATE OR REPLACE FUNCTION add_work_centre(
    p_work_centre_code     text    DEFAULT NULL,
    p_warehouse_id         uuid    DEFAULT NULL,
    p_name                 text    DEFAULT NULL,
    p_capacity_hours_per_day numeric DEFAULT NULL,
    p_is_active            boolean DEFAULT true,
    p_notes                text    DEFAULT NULL,
    p_idempotency_key      uuid    DEFAULT NULL
) RETURNS TABLE(success boolean, work_centre_id uuid, message text)
LANGUAGE plpgsql AS $$
DECLARE
    v_claim record;
    v_state text := '';
    v_ok    boolean := true;
    v_msg   text;
    v_id    uuid;
BEGIN
    IF p_idempotency_key IS NOT NULL THEN
        SELECT * INTO v_claim FROM idempotency_claim(
            p_idempotency_key, 'add_work_centre',
            jsonb_build_object('code', p_work_centre_code, 'warehouse', p_warehouse_id,
                               'name', p_name, 'capacity', p_capacity_hours_per_day,
                               'active', p_is_active, 'notes', p_notes));
        v_state := v_claim.claim_state;
        IF v_state = 'replay' THEN
            success        := (v_claim.cached_response ->> 'success')::boolean;
            work_centre_id := (v_claim.cached_response ->> 'work_centre_id')::uuid;
            message        := v_claim.cached_response ->> 'message';
            RETURN NEXT;
            RETURN;
        ELSIF v_state = 'in_progress' THEN
            RAISE EXCEPTION 'add_work_centre: an attempt with key % is already in flight',
                p_idempotency_key USING ERRCODE = '40001';
        ELSIF v_state = 'conflict' THEN
            RAISE EXCEPTION 'add_work_centre: key % was settled for a DIFFERENT request',
                p_idempotency_key USING ERRCODE = 'P0001';
        END IF;
    END IF;

    -- p_warehouse_id is not validated here. It is a NOT NULL column with a composite key, which is
    -- two constraints that say the whole rule — including "not somebody else's building" — and a
    -- third copy in this body would be the arm 0015's guard turned into a false refusal.
    INSERT INTO work_centres (work_centre_code, warehouse_id, name, capacity_hours_per_day,
                              is_active, notes)
    VALUES (upper(btrim(coalesce(p_work_centre_code, ''))), p_warehouse_id, btrim(coalesce(p_name, '')),
            p_capacity_hours_per_day, coalesce(p_is_active, true),
            NULLIF(btrim(coalesce(p_notes, '')), ''))
    RETURNING work_centres.work_centre_id INTO v_id;

    v_msg := format('Work centre %s created in warehouse %s',
        (SELECT w.work_centre_code FROM work_centres w WHERE w.work_centre_id = v_id), p_warehouse_id);

    IF v_state = 'claimed' THEN
        PERFORM idempotency_complete(v_claim.claim_id, v_claim.current_token,
            jsonb_build_object('success', true, 'work_centre_id', v_id, 'message', v_msg));
    END IF;

    RETURN QUERY SELECT v_ok, v_id, v_msg;
    RETURN;
EXCEPTION
    WHEN OTHERS THEN
        IF v_state = 'claimed' THEN
            BEGIN
                PERFORM idempotency_complete(v_claim.claim_id, v_claim.current_token,
                                             NULL, false, SQLERRM);
            EXCEPTION WHEN OTHERS THEN NULL;
            END;
        END IF;
        RAISE EXCEPTION USING ERRCODE = SQLSTATE, MESSAGE = SQLERRM;
END
$$;

CREATE OR REPLACE FUNCTION plan_work_order_operation(
    p_order_id        uuid    DEFAULT NULL,
    p_sequence        integer DEFAULT NULL,
    p_description     text    DEFAULT NULL,
    p_order_line_id   uuid    DEFAULT NULL,
    p_work_centre_id  uuid    DEFAULT NULL,
    p_planned_hours   numeric DEFAULT NULL,
    p_idempotency_key uuid    DEFAULT NULL
) RETURNS TABLE(success boolean, operation_id uuid, sequence integer, message text)
LANGUAGE plpgsql AS $$
DECLARE
    v_claim  record;
    v_state  text := '';
    v_ok     boolean := true;
    v_msg    text;
    v_op     uuid;
    v_seq    integer;
    v_type   text;
    v_try    integer := 0;
BEGIN
    IF p_order_id IS NULL THEN
        RAISE EXCEPTION 'plan_work_order_operation: p_order_id is required — a step belongs to a plan'
            USING ERRCODE = '22023';
    END IF;

    IF p_idempotency_key IS NOT NULL THEN
        SELECT * INTO v_claim FROM idempotency_claim(
            p_idempotency_key, 'plan_work_order_operation',
            jsonb_build_object('order', p_order_id, 'sequence', p_sequence, 'desc', p_description,
                               'line', p_order_line_id, 'centre', p_work_centre_id,
                               'hours', p_planned_hours));
        v_state := v_claim.claim_state;
        IF v_state = 'replay' THEN
            success  := (v_claim.cached_response ->> 'success')::boolean;
            operation_id := (v_claim.cached_response ->> 'operation_id')::uuid;
            sequence := (v_claim.cached_response ->> 'sequence')::integer;
            message  := v_claim.cached_response ->> 'message';
            RETURN NEXT;
            RETURN;
        ELSIF v_state = 'in_progress' THEN
            RAISE EXCEPTION 'plan_work_order_operation: an attempt with key % is already in flight',
                p_idempotency_key USING ERRCODE = '40001';
        ELSIF v_state = 'conflict' THEN
            RAISE EXCEPTION 'plan_work_order_operation: key % was settled for a DIFFERENT request',
                p_idempotency_key USING ERRCODE = 'P0001';
        END IF;
    END IF;

    -- Two rules here are cross-row and cannot be CHECKs, so they are stated in the one door that
    -- writes the table rather than in three places that might forget:
    --   * the plan belongs to a WORK document (a routing on a purchase order is a plan for a thing
    --     nobody is building);
    --   * the line an operation acts on belongs to the SAME order. The composite key to order_items
    --     proves the line exists and is yours; only the pair (order_id, order_line_id) says it is the
    --     same document's, and a unique index that would let a key say it is prefix-redundant with
    --     the line key 0028 already needs for reservations. So the door says it, and probe F checks
    --     that the door still does.
    SELECT o.order_type INTO v_type FROM orders o WHERE o.order_id = p_order_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'plan_work_order_operation: order % is not a document this connection can see',
            p_order_id USING ERRCODE = '22023';
    END IF;
    IF v_type <> 'WORK' THEN
        RAISE EXCEPTION 'plan_work_order_operation: % is a % document and takes no operations plan',
            p_order_id, v_type
            USING ERRCODE = '23514',
                  HINT = 'operations are what a work order drives; a sales or purchase order is '
                         'carried out by movements against its lines, not by a plan';
    END IF;
    IF p_order_line_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM order_items i WHERE i.order_line_id = p_order_line_id
                                          AND i.order_id = p_order_id) THEN
        RAISE EXCEPTION
            'plan_work_order_operation: line % is not a line of order %', p_order_line_id, p_order_id
            USING ERRCODE = '23503',
                  HINT = 'the line exists and is yours — the composite key would have said so — but '
                         'it belongs to another document, and an operation that acts on another '
                         'order''s line would report output against the wrong commitment';
    END IF;

    LOOP
        v_try := v_try + 1;
        BEGIN
            INSERT INTO work_order_operations (order_id, sequence, description, order_line_id,
                                              work_centre_id, planned_hours)
            SELECT p_order_id,
                   -- coalesce INSIDE the aggregate, not around it: an order with no operations yet
                   -- has max() = NULL, and NULL + 1 is NULL rather than 1, so the outer coalesce alone
                   -- handed the NOT NULL column a null. Found by probe C's very first call, which is
                   -- the argument for behaviour over reading.
                   coalesce(p_sequence, (SELECT coalesce(max(w.sequence), 0) + 1
                                           FROM work_order_operations w
                                          WHERE w.order_id = p_order_id)),
                   NULLIF(btrim(coalesce(p_description, '')), ''), p_order_line_id,
                   p_work_centre_id, p_planned_hours
            RETURNING work_order_operations.operation_id, work_order_operations.sequence
                 INTO v_op, v_seq;
            EXIT;
        EXCEPTION WHEN unique_violation THEN
            IF p_sequence IS NOT NULL OR v_try >= 5 THEN
                RAISE EXCEPTION USING ERRCODE = SQLSTATE, MESSAGE = SQLERRM;
            END IF;
        END;
    END LOOP;

    v_msg := format('Operation %s planned on %s%s', v_seq,
        (SELECT o.order_number FROM orders o WHERE o.order_id = p_order_id),
        CASE WHEN p_description IS NOT NULL THEN ': ' || btrim(p_description) ELSE '' END);

    IF v_state = 'claimed' THEN
        PERFORM idempotency_complete(v_claim.claim_id, v_claim.current_token,
            jsonb_build_object('success', true, 'operation_id', v_op, 'sequence', v_seq,
                               'message', v_msg));
    END IF;

    RETURN QUERY SELECT v_ok, v_op, v_seq, v_msg;
    RETURN;
EXCEPTION
    WHEN OTHERS THEN
        IF v_state = 'claimed' THEN
            BEGIN
                PERFORM idempotency_complete(v_claim.claim_id, v_claim.current_token,
                                             NULL, false, SQLERRM);
            EXCEPTION WHEN OTHERS THEN NULL;
            END;
        END IF;
        RAISE EXCEPTION USING ERRCODE = SQLSTATE, MESSAGE = SQLERRM;
END
$$;

COMMENT ON FUNCTION plan_work_order_operation(uuid, integer, text, uuid, uuid, numeric, uuid) IS
    'Add a step to a work order''s plan, in sequence order. Two rules are cross-row and therefore '
    'live here rather than in a constraint: the document must be a WORK order, and a line the '
    'operation acts on must belong to the SAME document (the composite key to order_items proves the '
    'line exists and is the caller''s; only this door can say whether it is the right order''s, which '
    'is why probe F tests it). Omit p_sequence to append after the last step, and a collision on the '
    'unique index recomputes rather than losing the row. PENDING is the only starting status, and '
    'wo_operations_status_matches_stamps is what makes that true of the timestamps too. Built by 0029.';

-- ---------------------------------------------------------------------------
-- 5. The ledger vocabulary, repaired
-- ---------------------------------------------------------------------------
-- Same shape as the constraint being replaced — `(col IS NULL) OR col = ANY (ARRAY[...])` — because
-- vw_domain_vocabulary's `nulls` column is derived from the presence of that first arm, and an edit
-- that silently changes how NULL is published would be a documentation change smuggled into a
-- vocabulary change. Two values move: WORK joins, TICKET leaves.
DO $$
DECLARE
    v_n int;
BEGIN
    SELECT count(*) INTO v_n FROM inventory_movements WHERE reference_type = 'TICKET';
    IF v_n <> 0 THEN
        RAISE EXCEPTION '5 failed: % movements cite TICKET, so removing the value would rewrite '
                        'history rather than correct a vocabulary — decide what those rows point at '
                        'first', v_n;
    END IF;
    -- And the same guard for the value being added, from the other side: if something already filed a
    -- movement as WORK outside the CHECK, the CHECK was being bypassed.
    SELECT count(*) INTO v_n FROM inventory_movements WHERE reference_type IS NOT NULL
      AND reference_type NOT IN ('ADJUSTMENT','ORDER','PO','TRANSFER','TICKET');
    IF v_n <> 0 THEN
        RAISE EXCEPTION '5 failed: % movements already carry a reference_type the CHECK publishes '
                        'none of, which means a write path has been escaping the vocabulary', v_n;
    END IF;
END
$$;

ALTER TABLE inventory_movements
    DROP CONSTRAINT IF EXISTS inventory_movements_reference_type_allowed;
ALTER TABLE inventory_movements
    ADD CONSTRAINT inventory_movements_reference_type_allowed CHECK (
        reference_type IS NULL OR reference_type IN ('ADJUSTMENT','ORDER','PO','TRANSFER','WORK'));

COMMENT ON CONSTRAINT inventory_movements_reference_type_allowed ON inventory_movements IS
    'What a ledger row may say it is for. 0029 added WORK and removed TICKET: the first because a '
    'movement made for production was being filed as ORDER and so was indistinguishable from a sales '
    'commitment, the second because tickets were deleted by 0017 and a live constraint naming a '
    'nonexistent table is a relationship that reads as maintained. NULL remains allowed — an '
    'ADJUSTMENT with no document behind it is the honest case, and 0007 published it as such.';

-- ---------------------------------------------------------------------------
-- 6. One needle in one body: the mapping that collapsed WORK onto ORDER
-- ---------------------------------------------------------------------------
-- Capture-transform, the way 0022 rewrote get_followup_customers and 0026 repaired this very
-- function's INSERT. The definition is read out of pg_proc, one string is replaced, and the result is
-- recreated — so the body that ships is 0015's body with one mapping changed, not a re-typed summary
-- of it. 4.4's failure mode (two heads, one of them chosen by how many arguments a caller happened to
-- send) is avoided by dropping on the FULL signature before creating, and the grant is re-applied
-- because a fresh function object does not inherit the old one's ACL.
DO $$
DECLARE
    v_src   text;
    v_new   text;
    v_n     integer;
    v_sig   text;
BEGIN
    -- The signature is read out of the catalog rather than retyped here. Dropping by full signature is
    -- 4.4's requirement and 0015's, but writing the type list by hand adds a second copy that can
    -- disagree with the first — this file's draft had p_reserved_by and p_location_id transposed and
    -- the DROP answered 42883. pg_get_function_identity_arguments is the form that both identifies an
    -- overload and is valid inside DROP/GRANT; oid::regprocedure prints an OID-qualified name that
    -- neither accepts, which is the discovery two lines below this one records.
    SELECT pg_get_functiondef(p.oid),
           format('%s.%I(%s)', n.nspname, p.proname,
                  pg_get_function_identity_arguments(p.oid)) INTO v_src, v_sig
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'reserve_inventory_for_order'
       AND p.prokind = 'f';
    IF v_src IS NULL THEN
        RAISE EXCEPTION '6 failed: reserve_inventory_for_order is not installed, so the door whose '
                        'mapping this migration repairs does not exist';
    END IF;

    -- Asserted by count before anything is executed. 0026 is the lesson: its two needles each matched
    -- exactly once, which is how a text transform applied a rotation of the VALUES list and nobody
    -- noticed until a seed ran the door successfully for the first time.
    v_n := length(v_src) - length(replace(v_src, 'WHEN ''WORK''     THEN ''ORDER''', ''));
    IF v_n <> length('WHEN ''WORK''     THEN ''ORDER''') THEN
        RAISE EXCEPTION '6 failed: the WORK→ORDER needle was found % time(s) in the installed body, '
                        'expected exactly once — the mapping has already been edited, moved, or '
                        'reformatted, and a blind replace would rotate the CASE instead of fixing it',
            CASE WHEN v_n = 0 THEN 0 ELSE v_n / length('WHEN ''WORK''     THEN ''ORDER''') END;
    END IF;

    v_new := replace(v_src, 'WHEN ''WORK''     THEN ''ORDER''', 'WHEN ''WORK''     THEN ''WORK''');
    IF v_new = v_src THEN
        RAISE EXCEPTION '6 failed: the replace changed nothing';
    END IF;

    EXECUTE format('DROP FUNCTION %s', v_sig);
    EXECUTE v_new;

    -- The ACL, restored exactly as 0009 established it: closed to PUBLIC per object, because ALTER
    -- DEFAULT PRIVILEGES REVOKE is a no-op for functions, and a fresh function object starts open.
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC', v_sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO afpc_app', v_sig);

    -- One head, the arity contract 0016 established, and no overload that a positional call could
    -- silently reach.
    SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'reserve_inventory_for_order';
    IF v_n <> 1 THEN
        RAISE EXCEPTION '6 failed: % heads of reserve_inventory_for_order are installed — 4.4 in '
                        'this schema''s own recent history', v_n;
    END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- 7. The read paths
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_work_centres AS
SELECT w.tenant_id, w.work_centre_id, w.work_centre_code, w.name, w.warehouse_id,
       wh.warehouse_code, wh.name AS warehouse_name, w.capacity_hours_per_day,
       w.is_active, w.notes, w.created_at, w.updated_at, w.version,
       (SELECT count(*) FROM work_order_operations o
         WHERE o.tenant_id = w.tenant_id AND o.work_centre_id = w.work_centre_id
           AND o.status <> 'COMPLETED') AS open_operations
  FROM work_centres w
  LEFT JOIN warehouses wh ON wh.warehouse_id = w.warehouse_id;
ALTER VIEW vw_work_centres SET (security_invoker = true);
GRANT SELECT ON vw_work_centres TO afpc_readonly, afpc_auditor;

COMMENT ON VIEW vw_work_centres IS
    'Where production happens, with the building it is in and how many steps are still queued at it. '
    'open_operations is a correlated count rather than a grouped join because a work centre list is '
    'short by nature; 0022''s warning is about a loop doing per-row aggregates over a large set, not '
    'about an aggregate that has one row per master-data record.';

CREATE OR REPLACE VIEW vw_work_order_plan AS
SELECT op.tenant_id, op.order_id, o.order_number, op.operation_id, op.sequence,
       op.order_line_id, i.line_type, i.sku AS line_sku, i.item_name AS line_item_name,
       op.description, op.work_centre_id, wc.work_centre_code, wc.name AS work_centre_name,
       op.planned_hours, op.actual_hours,
       (op.actual_hours - op.planned_hours) AS hours_variance,
       op.quantity_produced, op.quantity_scrapped, op.status,
       op.started_at, op.completed_at, op.created_at, op.updated_at, op.version
  FROM work_order_operations op
  JOIN orders o ON o.order_id = op.order_id
  LEFT JOIN vw_order_lines i ON i.order_line_id = op.order_line_id
  LEFT JOIN work_centres wc ON wc.work_centre_id = op.work_centre_id;
ALTER VIEW vw_work_order_plan SET (security_invoker = true);
GRANT SELECT ON vw_work_order_plan TO afpc_readonly, afpc_auditor;

COMMENT ON VIEW vw_work_order_plan IS
    'A work order''s steps in sequence, with what each one acts on and where it runs, and the '
    'hours variance computed rather than stored. Reading through vw_order_lines rather than '
    'order_items directly is deliberate: line_state and line_sku are derived, and a plan view that '
    're-derived them would be the second copy 0018 refuses. No LIMIT, no ORDER BY (0017). Built by '
    '0029.';

-- ---------------------------------------------------------------------------
-- 8. Privileges
-- ---------------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION add_work_centre(text, uuid, text, numeric, boolean, text, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION plan_work_order_operation(uuid, integer, text, uuid, uuid, numeric, uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION add_work_centre(text, uuid, text, numeric, boolean, text, uuid) TO afpc_app;
GRANT  EXECUTE ON FUNCTION plan_work_order_operation(uuid, integer, text, uuid, uuid, numeric, uuid) TO afpc_app;

-- ---------------------------------------------------------------------------
-- 9. Verify by behaving
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_n        int := 0;
    v_centre   uuid;
    v_centre2  uuid;
    v_ord      uuid;
    v_ord2     uuid;
    v_op       uuid;
    v_seq      integer;
    v_line     uuid;
    v_line2    uuid;
    v_ent      bigint;
    v_wh       uuid;
    v_wh2      uuid;
    v_item     uuid;
    v_err      text;
    v_msg      text;
    v_cname    text;
    v_ok       boolean;
    v_found    bigint;
    v_td       uuid;
    v_t2       uuid;
    v_key      uuid;
    v_val      text;
    v_rid      uuid;
    v_oid      uuid;
    v_rstat    text;
    v_rmsg     text;
    r          record;
BEGIN
    ------------------------------------------------------------------
    -- A. enrolment, and the vocabulary this file exists to repair.
    ------------------------------------------------------------------
    FOR r IN SELECT t FROM unnest(ARRAY['work_centres','work_order_operations']) AS t LOOP
        IF (SELECT count(*) FROM information_schema.columns
             WHERE table_name = r.t AND column_name = 'tenant_id' AND is_nullable = 'NO'
               AND data_type = 'uuid' AND column_default LIKE 'afpc_current_tenant%') <> 1 THEN
            RAISE EXCEPTION 'A failed: %.tenant_id is not the tenancy column 0003 prescribes', r.t;
        END IF;
        IF (SELECT count(*) FROM pg_class c WHERE c.oid = format('public.%I', r.t)::regclass
             AND c.relrowsecurity AND c.relforcerowsecurity) <> 1 THEN
            RAISE EXCEPTION 'A failed: % is not ENABLE+FORCE row secured', r.t;
        END IF;
        IF (SELECT count(*) FROM pg_trigger tg WHERE tg.tgrelid = format('public.%I', r.t)::regclass
             AND tg.tgname = 'afpc_audit_row' AND NOT tg.tgisinternal) <> 1 THEN
            RAISE EXCEPTION 'A failed: no trail on % — B26 counts the disagreement', r.t;
        END IF;
        IF EXISTS (SELECT 1 FROM pg_constraint k
                    WHERE k.conrelid = format('public.%I', r.t)::regclass AND k.contype = 'f'
                      AND NOT EXISTS (SELECT 1 FROM pg_index i
                                       WHERE i.indrelid = k.conrelid
                                         AND i.indkey::int[] @> k.conkey::int[])) THEN
            SELECT string_agg(DISTINCT k.conname, ', ') INTO v_msg
              FROM pg_constraint k
             WHERE k.conrelid = format('public.%I', r.t)::regclass AND k.contype = 'f'
               AND NOT EXISTS (SELECT 1 FROM pg_index i
                                WHERE i.indrelid = k.conrelid AND i.indkey::int[] @> k.conkey::int[]);
            RAISE EXCEPTION 'A failed: % has a foreign key whose columns lead no index (%)', r.t, v_msg;
        END IF;
    END LOOP;
    -- The vocabulary, read back from the catalog rather than trusted from this file.
    SELECT string_agg(v, ',' ORDER BY v) INTO v_msg
      FROM (SELECT DISTINCT m[1] AS v FROM regexp_matches(
              (SELECT pg_get_constraintdef(oid) FROM pg_constraint
                WHERE conname = 'inventory_movements_reference_type_allowed'),
              '''([^'']+)''', 'g') m) x;
    IF v_msg IS DISTINCT FROM 'ADJUSTMENT,ORDER,PO,TRANSFER,WORK' THEN
        RAISE EXCEPTION 'A failed: reference_type publishes %, expected the five values 0029 names', v_msg;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM vw_domain_vocabulary d
                    WHERE d.table_name = 'inventory_movements' AND d.column_name = 'reference_type'
                      AND d.allowed_values::text LIKE '%WORK%'
                      AND d.allowed_values::text NOT LIKE '%TICKET%') THEN
        RAISE EXCEPTION 'A failed: the vocabulary register does not publish the repaired set, so the '
                        'agents'' documentation would still describe a TICKET that cannot be filed';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- B. work centres, and the building edge that cannot name another tenant's.
    ------------------------------------------------------------------
    SELECT tenant_id INTO v_td FROM tenants WHERE slug = 'default';
    INSERT INTO tenants (name, slug) VALUES ('0029 second tenant', 'afpc-0029-t2')
     RETURNING tenant_id INTO v_t2;
    SELECT warehouse_id INTO v_wh FROM warehouses WHERE tenant_id = v_td
     ORDER BY warehouse_code LIMIT 1;
    -- An item for the lines probe D adds. v_item was only assigned inside probe E on the first draft,
    -- so D's line arrived with a NULL item, no unit to resolve from it, and died on NOT NULL before
    -- any of the rules D means to test could speak.
    SELECT item_id INTO v_item FROM inventory_items WHERE tenant_id = v_td
     ORDER BY sku LIMIT 1;
    IF v_item IS NULL THEN
        SELECT item_id INTO v_item FROM inventory_items ORDER BY sku LIMIT 1;
    END IF;
    INSERT INTO warehouses (tenant_id, warehouse_code, name, warehouse_type)
    VALUES (v_t2, '0029T2WH', 'Tenant Two Store', 'PRIMARY') RETURNING warehouse_id INTO v_wh2;

    SELECT success, work_centre_id INTO v_ok, v_centre
      FROM add_work_centre('0029-BENCH', v_wh, 'Assembly bench 1', 16, true, NULL, NULL);
    IF NOT v_ok OR v_centre IS NULL THEN
        RAISE EXCEPTION 'B failed: a work centre could not be created — %', v_msg;
    END IF;
    v_err := NULL;
    BEGIN
        INSERT INTO work_centres (tenant_id, warehouse_id, work_centre_code, name)
        VALUES (v_td, v_wh2, '0029-CROSS', 'Borrowed building');
    EXCEPTION WHEN foreign_key_violation THEN
        v_err := '23503';
        GET STACKED DIAGNOSTICS v_cname = CONSTRAINT_NAME;
    END;
    IF v_err IS DISTINCT FROM '23503' OR v_cname IS DISTINCT FROM
       'work_centres_warehouse_in_tenant_fkey' THEN
        RAISE EXCEPTION 'B failed: a work centre naming another tenant''s warehouse answered % from '
                        '%; the composite key is what makes a place addressable rather than '
                        'guessable', coalesce(v_err,'no error: it was WRITTEN'), coalesce(v_cname,'-');
    END IF;
    v_err := NULL;
    BEGIN
        PERFORM * FROM add_work_centre('0029 bad', v_wh, 'Lower case', NULL, true, NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '23514' THEN
        RAISE EXCEPTION 'B failed: a lowercase work centre code answered %', coalesce(v_err,'none');
    END IF;
    v_err := NULL;
    BEGIN
        PERFORM * FROM add_work_centre('0029_NEGCAP', v_wh, 'Impossible capacity', -4, true, NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '23514' THEN
        RAISE EXCEPTION 'B failed: a negative daily capacity answered %', coalesce(v_err,'none');
    END IF;
    -- A centre with no name is refused by the same class of rule, from the blank side.
    v_err := NULL;
    BEGIN
        PERFORM * FROM add_work_centre('0029_BLANK', v_wh, '   ', NULL, true, NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '23514' THEN
        RAISE EXCEPTION 'B failed: a work centre with a blank name answered %', coalesce(v_err,'none');
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- C. operations on a work order: sequence, status, and the state-vs-stamps rule.
    ------------------------------------------------------------------
    SELECT order_id INTO v_ord FROM create_order('WORK', NULL, NULL, v_wh, NULL, NULL, NULL,
                                                 '0029 build a frame', 'MANUAL', NULL);
    IF v_ord IS NULL THEN
        RAISE EXCEPTION 'C failed: a work order could not be raised (0028''s door is the only way)';
    END IF;
    SELECT success, sequence INTO v_ok, v_seq
      FROM plan_work_order_operation(v_ord, NULL, 'Cut the frame', NULL, v_centre, 2.5, NULL);
    IF NOT v_ok OR v_seq <> 1 THEN
        RAISE EXCEPTION 'C failed: the first operation landed at sequence %', v_seq;
    END IF;
    SELECT sequence INTO v_seq FROM plan_work_order_operation(v_ord, NULL, 'Weld', NULL, v_centre,
                                                              1.5, NULL);
    IF v_seq <> 2 THEN
        RAISE EXCEPTION 'C failed: appending a second operation gave sequence % — the auto-append '
                        'reads max()+1 inside the insert, so a stale answer here means the '
                        'sub-select is not seeing the row the last call wrote', v_seq;
    END IF;
    -- An explicit collision is refused, not silently renumbered: the caller asked for a position.
    v_err := NULL;
    BEGIN
        PERFORM * FROM plan_work_order_operation(v_ord, 1, 'Displaces step 1', NULL, NULL, NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '23505' THEN
        RAISE EXCEPTION 'C failed: an operation naming a taken sequence answered % — a door that '
                        'quietly renumbered it would be inventing a plan the caller never asked for',
            coalesce(v_err, 'no error: it renumbered itself');
    END IF;
    -- status versus timestamps, both directions.
    v_err := NULL;
    BEGIN
        UPDATE work_order_operations SET started_at = now()
         WHERE order_id = v_ord AND sequence = 1;
    EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '23514' THEN
        RAISE EXCEPTION 'C failed: a PENDING operation given a start time answered % — the stamps '
                        'and the status are one claim, stated twice so it cannot half-rotate',
            coalesce(v_err, 'no error: it was stored');
    END IF;
    v_err := NULL;
    BEGIN
        UPDATE work_order_operations
           SET status = 'COMPLETED', started_at = now(), quantity_produced = 0, quantity_scrapped = 0
         WHERE order_id = v_ord AND sequence = 2;
    EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '23514' THEN
        RAISE EXCEPTION 'C failed: a COMPLETED operation with no completion time answered %',
            coalesce(v_err, 'no error: it was stored');
    END IF;
    -- The legal move, made by the constraints agreeing rather than one of them winning.
    UPDATE work_order_operations
       SET status = 'IN_PROGRESS', started_at = now()
     WHERE order_id = v_ord AND sequence = 2;
    UPDATE work_order_operations
       SET status = 'COMPLETED', completed_at = now(), quantity_produced = 4, actual_hours = 1.75
     WHERE order_id = v_ord AND sequence = 2;
    -- actual minus planned, so a positive variance is time the shop floor spent beyond the plan. The
    -- probe expected the other sign on the first run, which is what an unasserted convention is worth:
    -- the view said one thing and the test believed another, and only the arithmetic settled it.
    IF (SELECT hours_variance FROM vw_work_order_plan
         WHERE order_id = v_ord AND sequence = 2) IS DISTINCT FROM 0.25 THEN
        RAISE EXCEPTION 'C failed: hours_variance for 1.5 planned against 1.75 actual is %',
            (SELECT hours_variance FROM vw_work_order_plan WHERE order_id = v_ord AND sequence = 2);
    END IF;
    IF (SELECT status FROM vw_work_order_plan WHERE order_id = v_ord AND sequence = 2)
       IS DISTINCT FROM 'COMPLETED' THEN
        RAISE EXCEPTION 'C failed: the operation the two legal updates completed is not COMPLETED';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- D. the two cross-row rules that live in the door, and the line that belongs to someone else's
    --    document — the case the composite key cannot see.
    ------------------------------------------------------------------
    -- A real customer, made through the door: v_ent was still unset here on the first draft, and
    -- create_order then refused the row for having no counterparty, which is the CHECK working and
    -- the probe not noticing it had asked a different question.
    SELECT entity_id INTO v_ent
      FROM add_customer('0029', 'Planned', 'plan0029@afpc.example.invalid', NULL, NULL, NULL, NULL,
                        NULL, 'US', 'active', 'business', '0029 Planned Co', 'shipping', true, NULL);
    SELECT order_id INTO v_ord2 FROM create_order('SALES', v_ent, NULL, NULL, NULL, NULL, NULL,
                                                  '0029 not-a-plan', 'MANUAL', NULL);
    v_err := NULL;
    BEGIN
        PERFORM * FROM plan_work_order_operation(v_ord2, NULL, 'Machine', NULL, NULL, NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '23514' THEN
        RAISE EXCEPTION 'D failed: a plan on a SALES order answered % — operations are what a work '
                        'order drives, and this rule has no CHECK to hold it', coalesce(v_err,'none');
    END IF;
    -- A line from another document, same tenant: the key passes (the line exists and is yours) and
    -- only the door can refuse it.
    SELECT order_line_id INTO v_line FROM add_order_line(v_ord, v_item, NULL, 1, NULL, NULL, 'PRODUCT',
                                                         NULL, NULL, NULL, NULL, NULL);
    SELECT order_line_id INTO v_line2
      FROM add_order_line(v_ord2, v_item, NULL, 1, NULL, NULL, 'STANDARD', NULL, NULL, NULL, NULL, NULL);
    v_err := NULL;
    BEGIN
        PERFORM * FROM plan_work_order_operation(v_ord, NULL, 'Acts on another order', v_line2,
                                                 NULL, NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '23503' THEN
        RAISE EXCEPTION 'D failed: an operation pointing at another order''s line answered % — this '
                        'is the relationship no key on this table can express, so if the door stops '
                        'checking it, nothing does', coalesce(v_err, 'no error: it was stored');
    END IF;
    -- And the same line, on the order it belongs to, must be accepted — otherwise the refusal above
    -- could be a blanket failure misread as a rule working.
    SELECT success INTO v_ok FROM plan_work_order_operation(v_ord, NULL, 'Machine the bracket',
                                                            v_line, v_centre, 1, NULL);
    IF NOT v_ok THEN
        RAISE EXCEPTION 'D failed: an operation on its own document''s line was refused — the '
                        'cross-row check is over-broad';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- E. THE POINT OF THIS FILE, MEASURED. 0026's lesson applied forward: a text transform is
    --    asserted by the behaviour it was supposed to produce, inside a subtransaction that is then
    --    discarded so the probe leaves no commitment behind. Reading the verdict inside and asserting
    --    it outside is what keeps the discard from swallowing a failure.
    ------------------------------------------------------------------
    v_val := NULL;
    BEGIN
        -- One row, both columns. Two separate queries could each pick a different item's pair and
        -- the reservation would then be asked of an item that is not in that warehouse at all.
        SELECT a.item_id, a.warehouse_id INTO v_item, v_wh
          FROM vw_item_availability a WHERE a.quantity_available >= 5
         ORDER BY a.tenant_id, a.item_id LIMIT 1;
        -- The order id is captured, not generated inline: the ledger row's reference_id is the
        -- DOCUMENT, and a probe that matches it against the reservation id finds nothing and reports
        -- that as an empty verdict. 0015's own INSERT says so two lines after the CASE being tested.
        v_oid := gen_random_uuid();
        SELECT reservation_id, status, message INTO v_rid, v_rstat, v_rmsg
          FROM reserve_inventory_for_order(v_item, v_wh, 1, 'WORK', v_oid, '0029-probe', NULL, NULL);
        IF v_rstat = 'SUCCESS' THEN
            SELECT coalesce(m.reference_type, 'NULL') INTO v_val
              FROM inventory_movements m
             WHERE m.movement_type = 'RESERVATION' AND m.reference_id = v_oid
             LIMIT 1;
            v_val := coalesce(v_val, 'no RESERVATION ledger row named that document');
        ELSE
            -- coalesce, not ||: the door returns a row, so a NULL status here means the SELECT found
            -- nothing, and 'text' || NULL is NULL — which is how this probe first reported a real
            -- failure as an empty one.
            v_val := 'door answered ' || coalesce(v_rstat, 'NO ROW AT ALL');
        END IF;
        RAISE EXCEPTION 'discard' USING ERRCODE = 'P0002';
    EXCEPTION WHEN OTHERS THEN
        -- The subtransaction is rolled back by this handler and v_val survives it. SQLERRM is kept:
        -- a discard handler that swallows the error it discards turns a broken door into a probe that
        -- says "could not inspect", which is true and useless.
        v_val := coalesce(v_val, 'raised ' || SQLSTATE || ': ' || left(SQLERRM, 120));
    END;
    IF v_val IS DISTINCT FROM 'WORK' THEN
        RAISE EXCEPTION 'E failed: a reservation for a WORK order filed its ledger row as % — the '
                        'mapping is the whole reason this migration exists, and a production '
                        'commitment that reads as a sales one is a relationship that looks maintained',
            coalesce(v_val, 'nothing (the probe could not make a reservation to inspect)');
    END IF;
    -- The other three mappings, unchanged: a repair that rotated the CASE would move these too.
    FOR r IN SELECT t FROM unnest(ARRAY['SALES','PURCHASE','TRANSFER']) AS t LOOP
        SELECT CASE r.t WHEN 'SALES' THEN 'ORDER' WHEN 'PURCHASE' THEN 'PO'
                         WHEN 'TRANSFER' THEN 'TRANSFER' END INTO v_msg;
        -- Matched on whitespace rather than on the source's column alignment: 0015 padded each
        -- branch to line the THENs up, and 'WORK' has one more space than 'SALES', so a pattern with a
        -- fixed run of blanks checks the formatting rather than the mapping.
        IF NOT EXISTS (SELECT 1 FROM pg_proc p
                        WHERE p.proname = 'reserve_inventory_for_order'
                          AND pg_get_functiondef(p.oid) ~ ('WHEN ''' || r.t || '''\s+THEN '''
                                                    || v_msg || '''')) THEN
            RAISE EXCEPTION 'E failed: the % → % mapping is no longer in the body — the transform '
                            'that added WORK moved something else as well', r.t, v_msg;
        END IF;
    END LOOP;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- F. tenancy and the two views.
    ------------------------------------------------------------------
    SET LOCAL ROLE afpc_app;
    PERFORM set_config('app.tenant_id', v_t2::text, true);
    SELECT count(*) INTO v_found FROM vw_work_centres;
    IF v_found <> 0 THEN
        RAISE EXCEPTION 'F failed: tenant 2 sees % work centres belonging to tenant 1', v_found;
    END IF;
    SELECT count(*) INTO v_found FROM vw_work_order_plan;
    IF v_found <> 0 THEN
        RAISE EXCEPTION 'F failed: the plan view published % operations across the wall', v_found;
    END IF;
    RESET ROLE;
    SET LOCAL ROLE afpc_app;
    PERFORM set_config('app.tenant_id', v_td::text, true);
    IF NOT EXISTS (SELECT 1 FROM vw_work_centres WHERE work_centre_id = v_centre) THEN
        RAISE EXCEPTION 'F failed: the owning tenant cannot see its own work centre through the view';
    END IF;
    SELECT count(*) INTO v_found FROM vw_work_order_plan WHERE order_id = v_ord;
    IF v_found <> 3 THEN
        RAISE EXCEPTION 'F failed: the plan of a work order with three operations reads % rows',
            v_found;
    END IF;
    RESET ROLE;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- G. delete safety, demonstrated on both new edges.
    ------------------------------------------------------------------
    v_err := NULL;
    BEGIN
        DELETE FROM work_centres WHERE work_centre_id = v_centre;
    EXCEPTION WHEN foreign_key_violation THEN
        v_err := '23503';
        GET STACKED DIAGNOSTICS v_cname = CONSTRAINT_NAME;
    END;
    IF v_err IS DISTINCT FROM '23503' OR v_cname IS DISTINCT FROM 'wo_operations_centre_in_tenant_fkey' THEN
        RAISE EXCEPTION 'G failed: deleting a work centre with operations on it answered % from % — '
                        'a plan must outlive the bench it was assigned to, or say it did not',
            coalesce(v_err,'no error'), coalesce(v_cname,'-');
    END IF;
    -- On a document with a plan and NO lines. v_ord has both, and the first draft found that
    -- order_items' key answers before the plan's — then, having cleared the lines, discovered that
    -- an operation pointing at one of them answers before that. Both refusals are correct and each
    -- one masks the assertion, so the test moves to a document where the plan is the only dependent
    -- (0028's probe L learned the same lesson the hard way and says why at greater length).
    SELECT order_id INTO v_ord2 FROM create_order('WORK', NULL, NULL, v_wh, NULL, NULL, NULL,
                                                  '0029 delete-anchor', 'MANUAL', NULL);
    PERFORM * FROM plan_work_order_operation(v_ord2, NULL, 'Only step', NULL, NULL, NULL, NULL);
    v_err := NULL;
    BEGIN
        DELETE FROM orders WHERE order_id = v_ord2;
    EXCEPTION WHEN foreign_key_violation THEN
        v_err := '23503';
        GET STACKED DIAGNOSTICS v_cname = CONSTRAINT_NAME;
    END;
    IF v_err IS DISTINCT FROM '23503' OR v_cname IS DISTINCT FROM 'wo_operations_order_in_tenant_fkey' THEN
        RAISE EXCEPTION 'G failed: deleting a document with a plan on it answered % from %',
            coalesce(v_err,'no error: it was deleted'), coalesce(v_cname,'-');
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- H. indexes, and the claim that the sequence unique is the only order-side index (the mistake
    --    this file made on its first draft, in the direction of an index identical to a constraint).
    ------------------------------------------------------------------
    IF (SELECT count(*) FROM vw_index_redundancy) <> 0 THEN
        RAISE EXCEPTION 'H failed: 0029 added a redundant index pair, which 0006''s invariant forbids';
    END IF;
    IF (SELECT count(*) FROM pg_indexes WHERE tablename = 'work_order_operations'
         AND indexdef LIKE '%tenant_id, order_id, sequence%') <> 1 THEN
        RAISE EXCEPTION 'H failed: % indexes carry (tenant_id, order_id, sequence) on '
                        'work_order_operations; the unique constraint is one of them, and a second '
                        'copy is what 5.6 counts',
            (SELECT count(*) FROM pg_indexes WHERE tablename = 'work_order_operations'
              AND indexdef LIKE '%tenant_id, order_id, sequence%');
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- I. the trail and the registers.
    ------------------------------------------------------------------
    FOR r IN SELECT t FROM unnest(ARRAY['work_centres','work_order_operations']) AS t LOOP
        IF NOT EXISTS (SELECT 1 FROM vw_audit_coverage a WHERE a.table_name = r.t AND a.row_audited) THEN
            RAISE EXCEPTION 'I failed: % is not trailead', r.t;
        END IF;
        SELECT verdict INTO v_msg FROM vw_timestamp_status WHERE table_name = r.t;
        IF v_msg IS DISTINCT FROM 'maintained' THEN
            RAISE EXCEPTION 'I failed: the timestamp register says % of %', coalesce(v_msg,'nothing'), r.t;
        END IF;
    END LOOP;
    IF (SELECT count(*) FROM audit_log WHERE table_name = 'work_order_operations'
          AND action = 'INSERT') < 3 THEN
        RAISE EXCEPTION 'I failed: the plan wrote % audit rows after at least three inserts',
            (SELECT count(*) FROM audit_log WHERE table_name = 'work_order_operations'
              AND action = 'INSERT');
    END IF;
    IF (SELECT count(*) FROM audit_chain_verify() WHERE NOT chain_ok) <> 0 THEN
        RAISE EXCEPTION 'I failed: the chain does not verify after 0029';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- J. retried calls, on both doors, plus the register crediting them.
    ------------------------------------------------------------------
    v_key := gen_random_uuid();
    SELECT work_centre_id INTO v_centre2
      FROM add_work_centre('0029-IDEM', v_wh, 'Idempotent bench', NULL, true, NULL, v_key);
    SELECT work_centre_id INTO v_centre2
      FROM add_work_centre('0029-IDEM', v_wh, 'Idempotent bench', NULL, true, NULL, v_key);
    IF (SELECT count(*) FROM work_centres WHERE work_centre_code = '0029-IDEM') <> 1 THEN
        RAISE EXCEPTION 'J failed: one claim produced % work centres',
            (SELECT count(*) FROM work_centres WHERE work_centre_code = '0029-IDEM');
    END IF;
    v_key := gen_random_uuid();
    PERFORM * FROM plan_work_order_operation(v_ord, NULL, 'Deburr', NULL, NULL, 0.5, v_key);
    PERFORM * FROM plan_work_order_operation(v_ord, NULL, 'Deburr', NULL, NULL, 0.5, v_key);
    IF (SELECT count(*) FROM work_order_operations w WHERE w.order_id = v_ord
          AND w.description = 'Deburr') <> 1 THEN
        RAISE EXCEPTION 'J failed: a replayed plan step produced % rows',
            (SELECT count(*) FROM work_order_operations WHERE description = 'Deburr');
    END IF;
    IF (SELECT count(*) FROM vw_idempotency_status s
         WHERE s.function IN ('add_work_centre','plan_work_order_operation') AND NOT s.unguarded) <> 2 THEN
        RAISE EXCEPTION 'J failed: the idempotency register credits % of 0029''s two doors',
            (SELECT count(*) FROM vw_idempotency_status s
              WHERE s.function IN ('add_work_centre','plan_work_order_operation') AND NOT s.unguarded);
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- Cleanup, in the order the keys require: plans, then documents, then lines, then the centres and
    -- the buildings, then the tenants. Everything created through a door is removed by tenant scope,
    -- the way 0028 argues it should be.
    ------------------------------------------------------------------
    DELETE FROM work_order_operations WHERE tenant_id IN (v_td, v_t2);
    -- Lines before headers. This block first had orders second, and the run died in cleanup with
    -- order_items_order_in_tenant_fkey naming a document whose own lines the DELETE had not yet
    -- removed — the exact RESTRICT ordering the 0028 file argues for in its own cleanup and then
    -- broke here. The order is the deepest child first, all the way up.
    DELETE FROM order_items WHERE tenant_id IN (v_td, v_t2);
    DELETE FROM orders WHERE tenant_id IN (v_td, v_t2);
    DELETE FROM document_counters WHERE tenant_id IN (v_td, v_t2);
    DELETE FROM idempotency_keys WHERE operation IN ('add_work_centre','plan_work_order_operation',
                                                     'create_order','add_order_line');
    DELETE FROM work_centres WHERE tenant_id IN (v_td, v_t2);
    DELETE FROM warehouses WHERE tenant_id = v_t2;
    DELETE FROM suppliers WHERE entity_id IN (SELECT id FROM entities WHERE name LIKE '002_ %');
    DELETE FROM addresses WHERE entity_id IN (SELECT id FROM entities WHERE name LIKE '002_ %');
    DELETE FROM entity_relationships
     WHERE entity_id IN (SELECT id FROM entities WHERE name LIKE '002_ %')
        OR contact_id IN (SELECT id FROM contacts WHERE email LIKE '%0028@afpc.example.invalid'
                                                OR email LIKE '%0029@afpc.example.invalid');
    DELETE FROM contacts WHERE email IN ('orders0028@afpc.example.invalid',
                                         'anchor0028@afpc.example.invalid',
                                         't2orders0028@afpc.example.invalid',
                                         'plan0029@afpc.example.invalid');
    -- No DELETE from inventory_reservations anywhere in this block, and that is deliberate: the four
    -- commitments the demo seed made in 0026's era are the rows 0030 exists to backfill, and a
    -- cleanup that cleared them would silently erase the only evidence that the reservation gap is
    -- real. Probe E's own reservation is discarded by its subtransaction, which is why it needs no
    -- delete.
    DELETE FROM entities WHERE name LIKE '002_ %' OR tenant_id = v_t2;
    DELETE FROM tenants WHERE slug = 'afpc-0029-t2';

    IF v_n <> 10 THEN
        RAISE EXCEPTION 'expected 10 behavioural verifications, completed %', v_n;
    END IF;
    RAISE NOTICE '0029: % checks passed - a work order has a plan, the plan cannot act on another '
                 'document''s line, a production commitment files its ledger row as WORK rather than '
                 'as a sales one, and the vocabulary no longer admits a document type whose table '
                 'was deleted in 0017', v_n;
END
$$;

-- ---------------------------------------------------------------------------
-- 10. Obligations this file leaves open, on purpose
-- ---------------------------------------------------------------------------
-- * Routings and bills of materials. When they land they bring `routings` and
--   `routing_operations` with a real key from work_order_operations into them, in the same migration.
--   No anticipatory `source_routing_operation_id` column was added here: a uuid that names no table is
--   the `inventory_reservations.order_id` defect, and 0028's header says why.
-- * Production stock movement. COMPLETED quantities on an operation do not move stock, and PRODUCT
--   line fulfilment is written by 0030's door with the ledger row that makes the status honest — the
--   same stock_moving rule 0028 put on the header applies to a line.
-- * `actual_hours` is free to exceed `planned_hours`, and hours_variance publishes the difference
--   instead of a CHECK refusing it: a plan that is missed is a fact a shop floor reports, not an
--   invalid row.
-- * The two cross-row rules in plan_work_order_operation (WORK-only, line-belongs-to-the-document)
--   have no constraint behind them, which makes this door the only writer that must not be bypassed.
--   `code:cs_writes_through_doors` is the guard that keeps that true of the tools; probe D is the one
--   that keeps it true of this file.
