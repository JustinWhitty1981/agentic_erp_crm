--
-- pgschema database dump
--

-- Dumped from database version PostgreSQL 16.14
-- Dumped by pgschema version 1.12.0


--
-- Name: _schema_graph; Type: TABLE; Schema: -; Owner: -
--

CREATE TABLE IF NOT EXISTS _schema_graph (
    node_id uuid DEFAULT gen_random_uuid(),
    node_type varchar(50) NOT NULL,
    node_name varchar(255) NOT NULL,
    description text,
    properties jsonb,
    relationships jsonb,
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now(),
    CONSTRAINT _schema_graph_pkey PRIMARY KEY (node_id)
);


COMMENT ON TABLE _schema_graph IS 'Knowledge graph of the agent_first_erp_crm schema for AI agent understanding. Query this table to understand the entire system structure.';

--
-- Name: audit_summary; Type: TABLE; Schema: -; Owner: -
--

CREATE TABLE IF NOT EXISTS audit_summary (
    summary_id uuid DEFAULT gen_random_uuid(),
    date date NOT NULL,
    user_id varchar(50) NOT NULL,
    bot_id varchar(50) NOT NULL,
    total_sessions integer DEFAULT 0 NOT NULL,
    total_actions integer DEFAULT 0 NOT NULL,
    successful_actions integer DEFAULT 0 NOT NULL,
    failed_actions integer DEFAULT 0 NOT NULL,
    avg_session_duration_minutes numeric(10,2),
    created_at timestamptz DEFAULT now(),
    CONSTRAINT audit_summary_pkey PRIMARY KEY (summary_id),
    CONSTRAINT audit_summary_date_user_id_bot_id_key UNIQUE (date, user_id, bot_id)
);

--
-- Name: idx_audit_summary_date; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_audit_summary_date ON audit_summary (date);

--
-- Name: idx_audit_summary_user_bot; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_audit_summary_user_bot ON audit_summary (user_id, bot_id);

--
-- Name: contacts; Type: TABLE; Schema: -; Owner: -
--

CREATE TABLE IF NOT EXISTS contacts (
    id SERIAL,
    first_name text NOT NULL,
    last_name text NOT NULL,
    email text,
    phone text,
    title text,
    status text DEFAULT 'active',
    preferences jsonb,
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now(),
    embedding public.vector(1536),
    CONSTRAINT contacts_pkey PRIMARY KEY (id)
);

--
-- Name: entities; Type: TABLE; Schema: -; Owner: -
--

CREATE TABLE IF NOT EXISTS entities (
    id SERIAL,
    entity_type varchar(50) DEFAULT 'customer' NOT NULL,
    name text NOT NULL,
    legal_name text,
    tax_id varchar(50),
    industry varchar(100),
    website text,
    status text DEFAULT 'active',
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now(),
    embedding public.vector(1536),
    CONSTRAINT entities_pkey PRIMARY KEY (id)
);

--
-- Name: addresses; Type: TABLE; Schema: -; Owner: -
--

CREATE TABLE IF NOT EXISTS addresses (
    id SERIAL,
    entity_id integer,
    contact_id integer,
    address_type varchar(50),
    street text,
    city text,
    state text,
    postal_code text,
    country text DEFAULT 'US',
    is_primary boolean DEFAULT false,
    created_at timestamptz DEFAULT now(),
    CONSTRAINT addresses_pkey PRIMARY KEY (id),
    CONSTRAINT addresses_contact_id_fkey FOREIGN KEY (contact_id) REFERENCES contacts (id),
    CONSTRAINT addresses_entity_id_fkey FOREIGN KEY (entity_id) REFERENCES entities (id)
);

--
-- Name: idx_addresses_contact; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_addresses_contact ON addresses (contact_id);

--
-- Name: idx_addresses_entity; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_addresses_entity ON addresses (entity_id);

--
-- Name: communications; Type: TABLE; Schema: -; Owner: -
--

CREATE TABLE IF NOT EXISTS communications (
    id BIGSERIAL,
    entity_id integer NOT NULL,
    contact_id integer,
    communication_type varchar(50) NOT NULL,
    direction varchar(10) NOT NULL,
    subject text,
    summary text NOT NULL,
    full_content text,
    channel varchar(50),
    started_at timestamptz DEFAULT now() NOT NULL,
    ended_at timestamptz,
    duration_seconds integer,
    agent_id varchar(50),
    human_agent_id integer,
    sentiment_score numeric(3,2),
    sentiment_label varchar(20),
    outcome varchar(50),
    priority varchar(20),
    follow_up_required boolean DEFAULT false,
    follow_up_date date,
    follow_up_action text,
    attachments jsonb DEFAULT '[]',
    parent_id integer,
    thread_root_id integer,
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now(),
    embedding public.vector(1536),
    CONSTRAINT communications_pkey PRIMARY KEY (id),
    CONSTRAINT communications_contact_id_fkey FOREIGN KEY (contact_id) REFERENCES contacts (id),
    CONSTRAINT communications_entity_id_fkey FOREIGN KEY (entity_id) REFERENCES entities (id),
    CONSTRAINT communications_human_agent_id_fkey FOREIGN KEY (human_agent_id) REFERENCES contacts (id),
    CONSTRAINT communications_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES communications (id)
);

--
-- Name: idx_comm_contact; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_comm_contact ON communications (contact_id);

--
-- Name: idx_comm_created; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_comm_created ON communications (created_at);

--
-- Name: idx_comm_entity; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_comm_entity ON communications (entity_id);

--
-- Name: idx_comm_type; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_comm_type ON communications (communication_type);

--
-- Name: idx_comms_contact; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_comms_contact ON communications (contact_id);

--
-- Name: idx_comms_direction; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_comms_direction ON communications (direction);

--
-- Name: idx_comms_embedding; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_comms_embedding ON communications USING ivfflat (embedding vector_cosine_ops) WITH (lists=100);

--
-- Name: idx_comms_entity; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_comms_entity ON communications (entity_id);

--
-- Name: idx_comms_followup; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_comms_followup ON communications (follow_up_required, follow_up_date) WHERE (follow_up_required = true);

--
-- Name: idx_comms_outcome; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_comms_outcome ON communications (outcome);

--
-- Name: idx_comms_parent; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_comms_parent ON communications (parent_id);

--
-- Name: idx_comms_priority; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_comms_priority ON communications (priority);

--
-- Name: idx_comms_sentiment; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_comms_sentiment ON communications (sentiment_label);

--
-- Name: idx_comms_thread_root; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_comms_thread_root ON communications (thread_root_id);

--
-- Name: idx_comms_type; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_comms_type ON communications (communication_type);

--
-- Name: entity_relationships; Type: TABLE; Schema: -; Owner: -
--

CREATE TABLE IF NOT EXISTS entity_relationships (
    id SERIAL,
    entity_id integer NOT NULL,
    contact_id integer NOT NULL,
    role varchar(100),
    is_primary boolean DEFAULT false,
    start_date date,
    end_date date,
    notes text,
    created_at timestamptz DEFAULT now(),
    CONSTRAINT entity_relationships_pkey PRIMARY KEY (id),
    CONSTRAINT entity_relationships_entity_id_contact_id_key UNIQUE (entity_id, contact_id),
    CONSTRAINT entity_relationships_contact_id_fkey FOREIGN KEY (contact_id) REFERENCES contacts (id),
    CONSTRAINT entity_relationships_entity_id_fkey FOREIGN KEY (entity_id) REFERENCES entities (id)
);

--
-- Name: idx_primary_contact; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_primary_contact ON entity_relationships (entity_id) WHERE (is_primary = true);

--
-- Name: followups; Type: TABLE; Schema: -; Owner: -
--

CREATE TABLE IF NOT EXISTS followups (
    id BIGSERIAL,
    entity_id integer NOT NULL,
    contact_id integer,
    description text NOT NULL,
    due_date timestamptz,
    priority varchar(20) DEFAULT 'medium',
    status varchar(20) DEFAULT 'pending',
    completed_at timestamptz,
    completion_notes text,
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now(),
    CONSTRAINT followups_pkey PRIMARY KEY (id),
    CONSTRAINT followups_contact_id_fkey FOREIGN KEY (contact_id) REFERENCES contacts (id),
    CONSTRAINT followups_entity_id_fkey FOREIGN KEY (entity_id) REFERENCES entities (id)
);

--
-- Name: idx_followup_entity; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_followup_entity ON followups (entity_id);

--
-- Name: idx_followup_status; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_followup_status ON followups (status);

--
-- Name: human_sessions; Type: TABLE; Schema: -; Owner: -
--

CREATE TABLE IF NOT EXISTS human_sessions (
    session_id uuid DEFAULT gen_random_uuid(),
    user_id varchar(50) NOT NULL,
    user_name varchar(100) NOT NULL,
    bot_id varchar(50) NOT NULL,
    bot_type varchar(50) NOT NULL,
    login_time timestamptz DEFAULT now() NOT NULL,
    logout_time timestamptz,
    ip_address inet,
    user_agent text,
    session_status varchar(20) DEFAULT 'active' NOT NULL,
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now(),
    contact_id integer,
    entity_id integer,
    CONSTRAINT human_sessions_pkey PRIMARY KEY (session_id),
    CONSTRAINT human_sessions_contact_id_fkey FOREIGN KEY (contact_id) REFERENCES contacts (id),
    CONSTRAINT human_sessions_entity_id_fkey FOREIGN KEY (entity_id) REFERENCES entities (id)
);

--
-- Name: idx_human_sessions_bot_id; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_human_sessions_bot_id ON human_sessions (bot_id);

--
-- Name: idx_human_sessions_login_time; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_human_sessions_login_time ON human_sessions (login_time);

--
-- Name: idx_human_sessions_status; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_human_sessions_status ON human_sessions (session_status);

--
-- Name: idx_human_sessions_user_bot; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_human_sessions_user_bot ON human_sessions (user_id, bot_id);

--
-- Name: idx_human_sessions_user_id; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_human_sessions_user_id ON human_sessions (user_id);

--
-- Name: bot_actions; Type: TABLE; Schema: -; Owner: -
--

CREATE TABLE IF NOT EXISTS bot_actions (
    action_id uuid DEFAULT gen_random_uuid(),
    session_id uuid NOT NULL,
    user_id varchar(50) NOT NULL,
    bot_id varchar(50) NOT NULL,
    action_type varchar(50) NOT NULL,
    action_description text,
    input_parameters jsonb,
    output_result jsonb,
    success boolean NOT NULL,
    error_message text,
    execution_time_ms integer,
    timestamp timestamptz DEFAULT now() NOT NULL,
    created_at timestamptz DEFAULT now(),
    contact_id integer,
    entity_id integer,
    CONSTRAINT bot_actions_pkey PRIMARY KEY (action_id),
    CONSTRAINT bot_actions_contact_id_fkey FOREIGN KEY (contact_id) REFERENCES contacts (id),
    CONSTRAINT bot_actions_entity_id_fkey FOREIGN KEY (entity_id) REFERENCES entities (id),
    CONSTRAINT bot_actions_session_id_fkey FOREIGN KEY (session_id) REFERENCES human_sessions (session_id) ON DELETE CASCADE
);

--
-- Name: idx_bot_actions_action_type; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_bot_actions_action_type ON bot_actions (action_type);

--
-- Name: idx_bot_actions_bot_id; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_bot_actions_bot_id ON bot_actions (bot_id);

--
-- Name: idx_bot_actions_session_id; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_bot_actions_session_id ON bot_actions (session_id);

--
-- Name: idx_bot_actions_session_user; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_bot_actions_session_user ON bot_actions (session_id, user_id);

--
-- Name: idx_bot_actions_success; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_bot_actions_success ON bot_actions (success);

--
-- Name: idx_bot_actions_timestamp; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_bot_actions_timestamp ON bot_actions ("timestamp");

--
-- Name: idx_bot_actions_user_id; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_bot_actions_user_id ON bot_actions (user_id);

--
-- Name: item_categories; Type: TABLE; Schema: -; Owner: -
--

CREATE TABLE IF NOT EXISTS item_categories (
    category_id uuid DEFAULT gen_random_uuid(),
    category_code varchar(50) NOT NULL,
    name varchar(255) NOT NULL,
    description text,
    parent_category_id uuid,
    category_level integer DEFAULT 1,
    default_cost_method varchar(20) DEFAULT 'AVERAGE',
    default_reorder_point numeric(12,4) DEFAULT 0,
    default_safety_stock numeric(12,4) DEFAULT 0,
    created_at timestamptz DEFAULT now() NOT NULL,
    updated_at timestamptz DEFAULT now() NOT NULL,
    CONSTRAINT item_categories_pkey PRIMARY KEY (category_id),
    CONSTRAINT item_categories_category_code_key UNIQUE (category_code),
    CONSTRAINT item_categories_parent_category_id_fkey FOREIGN KEY (parent_category_id) REFERENCES item_categories (category_id) ON DELETE SET NULL
);

--
-- Name: idx_categories_code; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_categories_code ON item_categories (category_code);

--
-- Name: idx_categories_parent; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_categories_parent ON item_categories (parent_category_id);

--
-- Name: inventory_items; Type: TABLE; Schema: -; Owner: -
--

CREATE TABLE IF NOT EXISTS inventory_items (
    item_id uuid DEFAULT gen_random_uuid(),
    sku varchar(50) NOT NULL,
    name varchar(255) NOT NULL,
    description text,
    category_id uuid,
    product_type varchar(50) DEFAULT 'STOCKED' NOT NULL,
    item_group varchar(100),
    base_unit_of_measure varchar(20) DEFAULT 'EACH' NOT NULL,
    weight numeric(12,4),
    weight_unit varchar(20) DEFAULT 'KG',
    dimensions_length numeric(10,2),
    dimensions_width numeric(10,2),
    dimensions_height numeric(10,2),
    dimension_unit varchar(20) DEFAULT 'CM',
    cost_method varchar(20) DEFAULT 'AVERAGE' NOT NULL,
    standard_cost numeric(12,4),
    last_cost numeric(12,4),
    currency_code character(3) DEFAULT 'USD' NOT NULL,
    reorder_point numeric(12,4) DEFAULT 0,
    reorder_quantity numeric(12,4),
    safety_stock numeric(12,4) DEFAULT 0,
    lead_time_days integer DEFAULT 0,
    min_order_qty numeric(12,4),
    order_multiple numeric(12,4) DEFAULT 1,
    is_active boolean DEFAULT true NOT NULL,
    is_serialized boolean DEFAULT false NOT NULL,
    is_lot_controlled boolean DEFAULT false NOT NULL,
    shelf_life_days integer,
    created_by varchar(100),
    created_at timestamptz DEFAULT now() NOT NULL,
    updated_at timestamptz DEFAULT now() NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    CONSTRAINT inventory_items_pkey PRIMARY KEY (item_id),
    CONSTRAINT inventory_items_sku_key UNIQUE (sku),
    CONSTRAINT inventory_items_category_id_fkey FOREIGN KEY (category_id) REFERENCES item_categories (category_id),
    CONSTRAINT chk_cost_positive CHECK (standard_cost >= 0::numeric AND last_cost >= 0::numeric),
    CONSTRAINT chk_sku_format CHECK (sku::text ~ '^[A-Z0-9-]+$'::text)
);

--
-- Name: idx_inventory_items_active; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_inventory_items_active ON inventory_items (is_active) WHERE (is_active = true);

--
-- Name: idx_inventory_items_category; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_inventory_items_category ON inventory_items (category_id);

--
-- Name: idx_inventory_items_group; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_inventory_items_group ON inventory_items (item_group) WHERE (is_active = true);

--
-- Name: idx_inventory_items_sku; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_inventory_items_sku ON inventory_items (sku);

--
-- Name: warehouses; Type: TABLE; Schema: -; Owner: -
--

CREATE TABLE IF NOT EXISTS warehouses (
    warehouse_id uuid DEFAULT gen_random_uuid(),
    warehouse_code varchar(50) NOT NULL,
    name varchar(255) NOT NULL,
    description text,
    parent_warehouse_id uuid,
    warehouse_type varchar(50) DEFAULT 'PRIMARY' NOT NULL,
    address_line1 varchar(255),
    city varchar(100),
    state varchar(100),
    postal_code varchar(20),
    country character(2) DEFAULT 'US',
    is_active boolean DEFAULT true NOT NULL,
    allows_negative boolean DEFAULT false NOT NULL,
    default_warehouse boolean DEFAULT false NOT NULL,
    timezone varchar(50) DEFAULT 'America/Chicago',
    created_at timestamptz DEFAULT now() NOT NULL,
    updated_at timestamptz DEFAULT now() NOT NULL,
    CONSTRAINT warehouses_pkey PRIMARY KEY (warehouse_id),
    CONSTRAINT warehouses_warehouse_code_key UNIQUE (warehouse_code),
    CONSTRAINT warehouses_parent_warehouse_id_fkey FOREIGN KEY (parent_warehouse_id) REFERENCES warehouses (warehouse_id) ON DELETE SET NULL
);

--
-- Name: idx_warehouses_active; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_warehouses_active ON warehouses (is_active) WHERE (is_active = true);

--
-- Name: idx_warehouses_code; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_warehouses_code ON warehouses (warehouse_code);

--
-- Name: idx_warehouses_parent; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_warehouses_parent ON warehouses (parent_warehouse_id);

--
-- Name: locations; Type: TABLE; Schema: -; Owner: -
--

CREATE TABLE IF NOT EXISTS locations (
    location_id uuid DEFAULT gen_random_uuid(),
    warehouse_id uuid NOT NULL,
    location_code varchar(50) NOT NULL,
    zone varchar(50),
    aisle varchar(20),
    rack varchar(20),
    shelf varchar(20),
    bin varchar(20),
    location_type varchar(50) DEFAULT 'STORAGE' NOT NULL,
    capacity_units numeric(12,4),
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamptz DEFAULT now() NOT NULL,
    updated_at timestamptz DEFAULT now() NOT NULL,
    CONSTRAINT locations_pkey PRIMARY KEY (location_id),
    CONSTRAINT locations_warehouse_id_location_code_key UNIQUE (warehouse_id, location_code),
    CONSTRAINT locations_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES warehouses (warehouse_id) ON DELETE CASCADE
);

--
-- Name: idx_locations_code; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_locations_code ON locations (warehouse_id, location_code);

--
-- Name: idx_locations_type; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_locations_type ON locations (location_type) WHERE (is_active = true);

--
-- Name: idx_locations_warehouse; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_locations_warehouse ON locations (warehouse_id);

--
-- Name: inventory_movements; Type: TABLE; Schema: -; Owner: -
--

CREATE TABLE IF NOT EXISTS inventory_movements (
    movement_id uuid DEFAULT gen_random_uuid(),
    movement_type varchar(50) NOT NULL,
    reference_type varchar(50),
    reference_id uuid,
    item_id uuid NOT NULL,
    from_warehouse_id uuid,
    from_location_id uuid,
    to_warehouse_id uuid NOT NULL,
    to_location_id uuid,
    quantity numeric(12,4) NOT NULL,
    unit_of_measure varchar(20) NOT NULL,
    conversion_factor numeric(12,6) DEFAULT 1.0,
    unit_cost numeric(12,4),
    total_cost numeric(15,4),
    currency_code character(3) DEFAULT 'USD' NOT NULL,
    lot_number varchar(100),
    serial_number varchar(255),
    reason_code varchar(50),
    notes text,
    performed_by varchar(100) NOT NULL,
    performed_at timestamptz DEFAULT now() NOT NULL,
    batch_id uuid,
    transaction_id uuid DEFAULT gen_random_uuid(),
    CONSTRAINT inventory_movements_pkey PRIMARY KEY (movement_id),
    CONSTRAINT inventory_movements_from_location_id_fkey FOREIGN KEY (from_location_id) REFERENCES locations (location_id),
    CONSTRAINT inventory_movements_from_warehouse_id_fkey FOREIGN KEY (from_warehouse_id) REFERENCES warehouses (warehouse_id),
    CONSTRAINT inventory_movements_item_id_fkey FOREIGN KEY (item_id) REFERENCES inventory_items (item_id) ON DELETE RESTRICT,
    CONSTRAINT inventory_movements_to_location_id_fkey FOREIGN KEY (to_location_id) REFERENCES locations (location_id),
    CONSTRAINT inventory_movements_to_warehouse_id_fkey FOREIGN KEY (to_warehouse_id) REFERENCES warehouses (warehouse_id),
    CONSTRAINT chk_quantity_nonzero CHECK (quantity <> 0::numeric)
);

--
-- Name: idx_movements_batch; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_movements_batch ON inventory_movements (batch_id);

--
-- Name: idx_movements_date; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_movements_date ON inventory_movements (performed_at DESC);

--
-- Name: idx_movements_item; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_movements_item ON inventory_movements (item_id);

--
-- Name: idx_movements_reference; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_movements_reference ON inventory_movements (reference_type, reference_id);

--
-- Name: idx_movements_type_date; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_movements_type_date ON inventory_movements (movement_type, performed_at DESC);

--
-- Name: idx_movements_warehouse; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_movements_warehouse ON inventory_movements (to_warehouse_id);

--
-- Name: inventory_movements; Type: RLS; Schema: -; Owner: -
--

ALTER TABLE inventory_movements ENABLE ROW LEVEL SECURITY;

--
-- Name: agent_movement_insert_policy; Type: POLICY; Schema: -; Owner: -
--

CREATE POLICY agent_movement_insert_policy ON inventory_movements FOR INSERT TO PUBLIC WITH CHECK ((performed_by)::text = current_setting('app.current_agent', true));

--
-- Name: agent_movement_view_policy; Type: POLICY; Schema: -; Owner: -
--

CREATE POLICY agent_movement_view_policy ON inventory_movements FOR SELECT TO PUBLIC USING (true);

--
-- Name: inventory_on_hand; Type: TABLE; Schema: -; Owner: -
--

CREATE TABLE IF NOT EXISTS inventory_on_hand (
    on_hand_id uuid DEFAULT gen_random_uuid(),
    item_id uuid NOT NULL,
    warehouse_id uuid NOT NULL,
    location_id uuid,
    quantity_on_hand numeric(12,4) DEFAULT 0 NOT NULL,
    quantity_available numeric(12,4) DEFAULT 0 NOT NULL,
    quantity_reserved numeric(12,4) DEFAULT 0 NOT NULL,
    quantity_in_transit numeric(12,4) DEFAULT 0 NOT NULL,
    quantity_damaged numeric(12,4) DEFAULT 0 NOT NULL,
    lot_number varchar(100),
    serial_numbers jsonb,
    expiry_date date,
    average_cost numeric(12,4),
    cost_currency character(3) DEFAULT 'USD' NOT NULL,
    last_counted_at timestamptz,
    last_movement_at timestamptz DEFAULT now() NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    CONSTRAINT inventory_on_hand_pkey PRIMARY KEY (on_hand_id),
    CONSTRAINT inventory_on_hand_item_id_fkey FOREIGN KEY (item_id) REFERENCES inventory_items (item_id) ON DELETE CASCADE,
    CONSTRAINT inventory_on_hand_location_id_fkey FOREIGN KEY (location_id) REFERENCES locations (location_id) ON DELETE SET NULL,
    CONSTRAINT inventory_on_hand_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES warehouses (warehouse_id) ON DELETE CASCADE,
    CONSTRAINT chk_available_calculation CHECK (quantity_available = (quantity_on_hand - quantity_reserved)),
    CONSTRAINT chk_quantities_non_negative CHECK (quantity_on_hand >= 0::numeric AND quantity_available >= 0::numeric AND quantity_reserved >= 0::numeric)
);

--
-- Name: idx_on_hand_available; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_on_hand_available ON inventory_on_hand (item_id, quantity_available) WHERE (quantity_available > (0)::numeric);

--
-- Name: idx_on_hand_expiry; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_on_hand_expiry ON inventory_on_hand (expiry_date) WHERE (expiry_date IS NOT NULL);

--
-- Name: idx_on_hand_item; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_on_hand_item ON inventory_on_hand (item_id);

--
-- Name: idx_on_hand_location; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_on_hand_location ON inventory_on_hand (location_id);

--
-- Name: idx_on_hand_low_stock; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_on_hand_low_stock ON inventory_on_hand (item_id, quantity_available);

--
-- Name: idx_on_hand_warehouse; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_on_hand_warehouse ON inventory_on_hand (warehouse_id);

--
-- Name: inventory_reservations; Type: TABLE; Schema: -; Owner: -
--

CREATE TABLE IF NOT EXISTS inventory_reservations (
    reservation_id uuid DEFAULT gen_random_uuid(),
    item_id uuid NOT NULL,
    warehouse_id uuid NOT NULL,
    location_id uuid,
    order_type varchar(50) NOT NULL,
    order_id uuid NOT NULL,
    order_line_id uuid,
    reserved_quantity numeric(12,4) NOT NULL,
    shipped_quantity numeric(12,4) DEFAULT 0,
    cancelled_quantity numeric(12,4) DEFAULT 0,
    lot_number varchar(100),
    serial_numbers jsonb,
    priority integer DEFAULT 1,
    reserved_at timestamptz DEFAULT now() NOT NULL,
    expected_ship_date date,
    reserved_by varchar(100),
    notes text,
    CONSTRAINT inventory_reservations_pkey PRIMARY KEY (reservation_id),
    CONSTRAINT inventory_reservations_item_id_fkey FOREIGN KEY (item_id) REFERENCES inventory_items (item_id) ON DELETE CASCADE,
    CONSTRAINT inventory_reservations_location_id_fkey FOREIGN KEY (location_id) REFERENCES locations (location_id),
    CONSTRAINT inventory_reservations_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES warehouses (warehouse_id) ON DELETE CASCADE,
    CONSTRAINT chk_reservation_quantities CHECK ((shipped_quantity + cancelled_quantity) <= reserved_quantity)
);

--
-- Name: idx_reservations_item; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_reservations_item ON inventory_reservations (item_id);

--
-- Name: idx_reservations_order; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_reservations_order ON inventory_reservations (order_type, order_id);

--
-- Name: idx_reservations_priority; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_reservations_priority ON inventory_reservations (item_id, priority);

--
-- Name: idx_reservations_ship_date; Type: INDEX; Schema: -; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_reservations_ship_date ON inventory_reservations (expected_ship_date) WHERE (expected_ship_date IS NOT NULL);

--
-- Name: inventory_reservations; Type: RLS; Schema: -; Owner: -
--

ALTER TABLE inventory_reservations ENABLE ROW LEVEL SECURITY;

--
-- Name: agent_reservation_policy; Type: POLICY; Schema: -; Owner: -
--

CREATE POLICY agent_reservation_policy ON inventory_reservations TO PUBLIC USING ((reserved_by)::text = current_setting('app.current_agent', true));

--
-- Name: execute_inventory_movement(varchar, uuid, uuid, uuid, numeric, numeric, varchar, varchar, uuid, varchar); Type: FUNCTION; Schema: -; Owner: -
--

CREATE OR REPLACE FUNCTION execute_inventory_movement(
    p_movement_type varchar,
    p_item_id uuid,
    p_from_warehouse_id uuid,
    p_to_warehouse_id uuid,
    p_quantity numeric,
    p_unit_cost numeric,
    p_performed_by varchar,
    p_reference_type varchar,
    p_reference_id uuid,
    p_reason_code varchar
)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_movement_id UUID;
    v_batch_id UUID := gen_random_uuid();
BEGIN
    INSERT INTO inventory_movements (
        movement_type, item_id, from_warehouse_id, to_warehouse_id,
        quantity, unit_cost, total_cost, performed_by, reference_type, reference_id, reason_code, batch_id
    ) VALUES (
        p_movement_type, p_item_id, p_from_warehouse_id, p_to_warehouse_id,
        p_quantity, p_unit_cost, p_quantity * p_unit_cost, p_performed_by,
        p_reference_type, p_reference_id, p_reason_code, v_batch_id
    ) RETURNING movement_id INTO v_movement_id;

    IF p_movement_type IN ('RECEIPT', 'RETURN') THEN
        INSERT INTO inventory_on_hand (item_id, warehouse_id, quantity_on_hand, average_cost, last_movement_at)
        VALUES (p_item_id, p_to_warehouse_id, p_quantity, p_unit_cost, NOW())
        ON CONFLICT (item_id, warehouse_id, COALESCE(location_id, '00000000-0000-0000-0000-000000000000'::UUID), COALESCE(lot_number, ''))
        DO UPDATE SET
            quantity_on_hand = inventory_on_hand.quantity_on_hand + p_quantity,
            average_cost = (
                (inventory_on_hand.average_cost * inventory_on_hand.quantity_on_hand) + (p_unit_cost * p_quantity)
            ) / (inventory_on_hand.quantity_on_hand + p_quantity),
            last_movement_at = NOW();
    ELSIF p_movement_type IN ('ISSUE', 'ADJUSTMENT') THEN
        UPDATE inventory_on_hand
        SET quantity_on_hand = quantity_on_hand - p_quantity, last_movement_at = NOW()
        WHERE item_id = p_item_id AND warehouse_id = p_from_warehouse_id;
    END IF;

    RETURN v_movement_id;
EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'Movement failed: %', SQLERRM;
END;
$$;

--
-- Name: reserve_inventory_for_order(uuid, uuid, numeric, varchar, uuid, varchar); Type: FUNCTION; Schema: -; Owner: -
--

CREATE OR REPLACE FUNCTION reserve_inventory_for_order(
    p_item_id uuid,
    p_warehouse_id uuid,
    p_quantity numeric,
    p_order_type varchar,
    p_order_id uuid,
    p_reserved_by varchar
)
RETURNS TABLE(reservation_id uuid, status varchar, message text)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_available DECIMAL;
    v_reservation_id UUID;
BEGIN
    SELECT COALESCE(quantity_available, 0) INTO v_available
    FROM inventory_on_hand WHERE item_id = p_item_id AND warehouse_id = p_warehouse_id;

    IF v_available < p_quantity THEN
        RETURN QUERY SELECT NULL::UUID, 'INSUFFICIENT_STOCK',
            'Only ' || v_available || ' available, requested ' || p_quantity;
        RETURN;
    END IF;

    INSERT INTO inventory_reservations (item_id, warehouse_id, order_type, order_id, reserved_quantity, reserved_by, priority)
    VALUES (p_item_id, p_warehouse_id, p_order_type, p_order_id, p_quantity, p_reserved_by, 1)
    RETURNING reservation_id INTO v_reservation_id;

    UPDATE inventory_on_hand
    SET quantity_reserved = quantity_reserved + p_quantity,
        quantity_available = quantity_available - p_quantity
    WHERE item_id = p_item_id AND warehouse_id = p_warehouse_id;

    INSERT INTO inventory_movements (movement_type, item_id, to_warehouse_id, quantity, reason_code, performed_by, reference_type, reference_id)
    VALUES ('RESERVATION', p_item_id, p_warehouse_id, p_quantity, 'ORDER_COMMITMENT', p_reserved_by, p_order_type, p_order_id);

    RETURN QUERY SELECT v_reservation_id, 'SUCCESS', 'Reserved ' || p_quantity || ' units for order ' || p_order_id;
EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT NULL::UUID, 'ERROR', SQLERRM;
END;
$$;

--
-- Name: split_name(text); Type: FUNCTION; Schema: -; Owner: -
--

CREATE OR REPLACE FUNCTION split_name(
    full_name text
)
RETURNS TABLE(first_name text, last_name text)
LANGUAGE plpgsql
VOLATILE
AS $$
BEGIN
    -- Simple split: first word is first name, rest is last name
    -- For more complex logic, we'd need a more sophisticated parser
    RETURN QUERY
    SELECT
        SPLIT_PART(full_name, ' ', 1) as first_name,
        CASE
            WHEN POSITION(' ' IN full_name) > 0
            THEN SUBSTRING(full_name FROM POSITION(' ' IN full_name) + 1)
            ELSE ''
        END as last_name;
END;
$$;

--
-- Name: update_communications_updated_at(); Type: FUNCTION; Schema: -; Owner: -
--

CREATE OR REPLACE FUNCTION update_communications_updated_at()
RETURNS trigger
LANGUAGE plpgsql
VOLATILE
AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

--
-- Name: update_on_hand_consistency(); Type: FUNCTION; Schema: -; Owner: -
--

CREATE OR REPLACE FUNCTION update_on_hand_consistency()
RETURNS trigger
LANGUAGE plpgsql
VOLATILE
AS $$
BEGIN
    NEW.quantity_available := NEW.quantity_on_hand - NEW.quantity_reserved;
    RETURN NEW;
END;
$$;

--
-- Name: update_updated_at_column(); Type: FUNCTION; Schema: -; Owner: -
--

CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS trigger
LANGUAGE plpgsql
VOLATILE
AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

--
-- Name: trg_on_hand_consistency; Type: TRIGGER; Schema: -; Owner: -
--

CREATE OR REPLACE TRIGGER trg_on_hand_consistency
    BEFORE INSERT OR UPDATE ON inventory_on_hand
    FOR EACH ROW
    EXECUTE FUNCTION update_on_hand_consistency();

--
-- Name: update_communications_updated_at; Type: TRIGGER; Schema: -; Owner: -
--

CREATE OR REPLACE TRIGGER update_communications_updated_at
    BEFORE UPDATE ON communications
    FOR EACH ROW
    EXECUTE FUNCTION update_communications_updated_at();

--
-- Name: update_human_sessions_updated_at; Type: TRIGGER; Schema: -; Owner: -
--

CREATE OR REPLACE TRIGGER update_human_sessions_updated_at
    BEFORE UPDATE ON human_sessions
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

--
-- Name: agent_activity_summary; Type: VIEW; Schema: -; Owner: -
--

CREATE OR REPLACE VIEW agent_activity_summary AS
 SELECT agent_id,
    count(*) AS total_actions,
    count(DISTINCT entity_id) AS unique_entities,
    count(DISTINCT contact_id) AS unique_contacts,
    count(
        CASE
            WHEN outcome::text = 'resolved'::text THEN 1
            ELSE NULL::integer
        END) AS resolved_count,
    count(
        CASE
            WHEN outcome::text = 'escalated'::text THEN 1
            ELSE NULL::integer
        END) AS escalated_count,
    round(avg(sentiment_score), 2) AS avg_sentiment,
    max(started_at) AS last_activity,
    min(started_at) AS first_activity
   FROM communications c
  WHERE agent_id IS NOT NULL
  GROUP BY agent_id
  ORDER BY (count(*)) DESC;


COMMENT ON VIEW agent_activity_summary IS 'Summary of communication activity per bot agent. Useful for performance monitoring and workload analysis.';

--
-- Name: communication_thread_view; Type: VIEW; Schema: -; Owner: -
--

CREATE OR REPLACE VIEW communication_thread_view AS
 SELECT c.id,
    c.parent_id,
    c.thread_root_id,
    c.started_at,
    e.name AS entity_name,
    (co.first_name || ' '::text) || co.last_name AS contact_name,
    c.communication_type,
    c.subject,
    c.summary,
    c.outcome
   FROM communications c
     JOIN entities e ON e.id = c.entity_id
     LEFT JOIN contacts co ON co.id = c.contact_id;


COMMENT ON VIEW communication_thread_view IS 'Shows communication threading hierarchy. Useful for reconstructing conversation flows.';

--
-- Name: customer_communications_summary; Type: VIEW; Schema: -; Owner: -
--

CREATE OR REPLACE VIEW customer_communications_summary AS
 SELECT c.id,
    c.started_at,
    e.id AS entity_id,
    e.name AS entity_name,
    e.entity_type,
    e.status AS entity_status,
    co.id AS contact_id,
    (co.first_name || ' '::text) || co.last_name AS contact_name,
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
    c.thread_root_id
   FROM communications c
     JOIN entities e ON e.id = c.entity_id
     LEFT JOIN contacts co ON co.id = c.contact_id
  WHERE e.entity_type::text = 'customer'::text;


COMMENT ON VIEW customer_communications_summary IS 'All communications for customers with full entity and contact context. Ideal for agent queries and dashboards.';

--
-- Name: customers; Type: VIEW; Schema: -; Owner: -
--

CREATE OR REPLACE VIEW customers AS
 SELECT e.id,
    e.name,
    c.email,
    c.phone,
    (((((a.street || ', '::text) || a.city) || ', '::text) || a.state) || ' '::text) || a.postal_code AS address,
    e.status,
    e.created_at,
    e.updated_at,
    e.embedding
   FROM entities e
     JOIN entity_relationships er ON er.entity_id = e.id AND er.is_primary = true
     JOIN contacts c ON c.id = er.contact_id
     LEFT JOIN addresses a ON a.entity_id = e.id AND a.is_primary = true
  WHERE e.entity_type::text = 'customer'::text;


COMMENT ON VIEW customers IS 'Backward compatibility view: Maps entities/contacts to legacy customers table structure.';

--
-- Name: entity_communication_stats; Type: VIEW; Schema: -; Owner: -
--

CREATE OR REPLACE VIEW entity_communication_stats AS
 SELECT e.id AS entity_id,
    e.name AS entity_name,
    e.entity_type,
    e.status,
    count(c.id) AS total_communications,
    count(
        CASE
            WHEN c.outcome::text = 'resolved'::text THEN 1
            ELSE NULL::integer
        END) AS resolved_count,
    count(
        CASE
            WHEN c.outcome::text = 'escalated'::text THEN 1
            ELSE NULL::integer
        END) AS escalated_count,
    count(
        CASE
            WHEN c.outcome::text = 'pending'::text THEN 1
            ELSE NULL::integer
        END) AS pending_count,
    count(
        CASE
            WHEN c.sentiment_label::text = 'positive'::text THEN 1
            ELSE NULL::integer
        END) AS positive_count,
    count(
        CASE
            WHEN c.sentiment_label::text = 'negative'::text THEN 1
            ELSE NULL::integer
        END) AS negative_count,
    round(avg(c.sentiment_score), 2) AS avg_sentiment,
    max(c.started_at) AS last_contact_date,
    min(c.started_at) AS first_contact_date,
    round(avg(c.duration_seconds), 0) AS avg_duration_seconds
   FROM entities e
     LEFT JOIN communications c ON c.entity_id = e.id
  GROUP BY e.id, e.name, e.entity_type, e.status;


COMMENT ON VIEW entity_communication_stats IS 'Aggregated communication metrics per entity. Useful for customer health scoring and engagement analysis.';

--
-- Name: pending_followups; Type: VIEW; Schema: -; Owner: -
--

CREATE OR REPLACE VIEW pending_followups AS
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
    (co.first_name || ' '::text) || co.last_name AS contact_name
   FROM followups f
     JOIN entities e ON f.entity_id = e.id
     LEFT JOIN contacts co ON f.contact_id = co.id
  WHERE f.status::text = 'pending'::text
  ORDER BY f.due_date;

--
-- Name: primary_contact_communications; Type: VIEW; Schema: -; Owner: -
--

CREATE OR REPLACE VIEW primary_contact_communications AS
 SELECT c.id,
    c.started_at,
    e.id AS entity_id,
    e.name AS entity_name,
    e.entity_type,
    co.id AS contact_id,
    (co.first_name || ' '::text) || co.last_name AS primary_contact,
    co.title AS contact_title,
    c.communication_type,
    c.direction,
    c.subject,
    c.summary,
    c.outcome,
    c.priority,
    c.agent_id
   FROM communications c
     JOIN entities e ON e.id = c.entity_id
     JOIN entity_relationships er ON er.entity_id = e.id AND er.is_primary = true
     JOIN contacts co ON co.id = er.contact_id AND co.id = c.contact_id;


COMMENT ON VIEW primary_contact_communications IS 'Communications exclusively with primary contacts. Ideal for tracking executive-level interactions.';

--
-- Name: recent_communications; Type: VIEW; Schema: -; Owner: -
--

CREATE OR REPLACE VIEW recent_communications AS
 SELECT c.id,
    c.started_at,
    e.id AS entity_id,
    e.name AS entity_name,
    e.entity_type,
    (co.first_name || ' '::text) || co.last_name AS contact_name,
    co.title AS contact_title,
    c.communication_type,
    c.direction,
    c.subject,
    c.summary,
    c.outcome,
    c.priority,
    c.agent_id
   FROM communications c
     JOIN entities e ON e.id = c.entity_id
     LEFT JOIN contacts co ON co.id = c.contact_id
  WHERE c.started_at >= (now() - '7 days'::interval)
  ORDER BY c.started_at DESC;


COMMENT ON VIEW recent_communications IS 'All communications from the last 7 days across all entity types. Useful for activity feeds and monitoring.';

--
-- Name: v_inventory_valuation; Type: VIEW; Schema: -; Owner: -
--

CREATE OR REPLACE VIEW v_inventory_valuation AS
 SELECT w.warehouse_id,
    w.name AS warehouse_name,
    w.warehouse_type,
    cat.category_id,
    cat.name AS category_name,
    count(DISTINCT i.item_id) AS unique_items,
    sum(ioh.quantity_on_hand) AS total_units,
    sum(ioh.quantity_on_hand * ioh.average_cost) AS total_value,
    sum(ioh.quantity_available * ioh.average_cost) AS available_value
   FROM inventory_on_hand ioh
     JOIN inventory_items i ON ioh.item_id = i.item_id
     JOIN warehouses w ON ioh.warehouse_id = w.warehouse_id
     LEFT JOIN item_categories cat ON i.category_id = cat.category_id
  WHERE i.is_active = true AND w.is_active = true
  GROUP BY w.warehouse_id, w.name, w.warehouse_type, cat.category_id, cat.name;

--
-- Name: v_item_availability; Type: VIEW; Schema: -; Owner: -
--

CREATE OR REPLACE VIEW v_item_availability AS
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
    COALESCE(ioh.quantity_on_hand, 0::numeric) AS quantity_on_hand,
    COALESCE(ioh.quantity_available, 0::numeric) AS quantity_available,
    COALESCE(ioh.quantity_reserved, 0::numeric) AS quantity_reserved,
    COALESCE(ioh.quantity_in_transit, 0::numeric) AS quantity_in_transit,
    i.reorder_point,
    i.safety_stock,
    i.lead_time_days,
    i.is_serialized,
    i.is_lot_controlled,
    ioh.expiry_date,
    ioh.average_cost,
    ioh.cost_currency,
        CASE
            WHEN COALESCE(ioh.quantity_available, 0::numeric) <= 0::numeric THEN 'OUT_OF_STOCK'::text
            WHEN COALESCE(ioh.quantity_available, 0::numeric) <= i.safety_stock THEN 'CRITICAL'::text
            WHEN COALESCE(ioh.quantity_available, 0::numeric) <= i.reorder_point THEN 'LOW_STOCK'::text
            ELSE 'NORMAL'::text
        END AS stock_status,
        CASE
            WHEN i.reorder_point > 0::numeric AND COALESCE(ioh.quantity_available, 0::numeric) <= i.reorder_point THEN true
            ELSE false
        END AS needs_reorder
   FROM inventory_items i
     LEFT JOIN item_categories cat ON i.category_id = cat.category_id
     LEFT JOIN inventory_on_hand ioh ON i.item_id = ioh.item_id
     LEFT JOIN warehouses w ON ioh.warehouse_id = w.warehouse_id
     LEFT JOIN locations l ON ioh.location_id = l.location_id
  WHERE i.is_active = true AND (w.is_active = true OR w.warehouse_id IS NULL);


COMMENT ON VIEW v_item_availability IS 'Agent-friendly view for checking item availability across all warehouses';

--
-- Name: v_item_movement_summary; Type: VIEW; Schema: -; Owner: -
--

CREATE OR REPLACE VIEW v_item_movement_summary AS
 SELECT item_id,
    date_trunc('day'::text, performed_at) AS movement_date,
    movement_type,
    sum(quantity) AS net_quantity,
    count(*) AS movement_count,
    avg(unit_cost) AS avg_unit_cost,
    sum(
        CASE
            WHEN quantity > 0::numeric THEN quantity
            ELSE 0::numeric
        END) AS total_inbound,
    sum(
        CASE
            WHEN quantity < 0::numeric THEN abs(quantity)
            ELSE 0::numeric
        END) AS total_outbound
   FROM inventory_movements
  WHERE performed_at >= (now() - '30 days'::interval)
  GROUP BY item_id, (date_trunc('day'::text, performed_at)), movement_type;

--
-- Name: v_low_stock_alerts; Type: VIEW; Schema: -; Owner: -
--

CREATE OR REPLACE VIEW v_low_stock_alerts AS
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
    round(ioh.quantity_available::numeric / NULLIF(i.reorder_point, 0::numeric)::numeric * 100::numeric, 2) AS stock_percentage
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

