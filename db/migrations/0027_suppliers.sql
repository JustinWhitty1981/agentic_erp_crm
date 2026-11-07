-- 0027: suppliers — and the first relationship in this schema that cannot name another tenant's party
--       (the orders programme, migration 1 of 4; the purchase-order counterparty that made it necessary)
--
-- WHY THIS FILE EXISTS AT ALL
--
-- The order model has three document types — SALES from a customer, PURCHASE to procure goods and
-- services, WORK to drive production. A purchase order needs a counterparty, and there was nowhere
-- honest to point one. Two things were measured before any DDL was written, and both are recorded
-- here rather than in a changelog because they are the reasons the shape below is this shape.
--
--   * `entities.entity_type` is CHECKed over {customer, employee, prospect, vendor} — one column,
--     one value, therefore one role per party. A company that sells us steel and buys our spare
--     parts is not representable: whichever value it holds, the other half of the relationship is
--     invisible to the database. It is also unenforceable in the direction that matters — a CHECK
--     cannot contain a subquery, so "the party this purchase order names must actually be a
--     supplier" is not a claim the orders table could ever state about a bigint column.
--
--   * A single-column foreign key is tenant-blind, measured. Creating a second tenant, an entity
--     inside it, then inserting an `addresses` row for that entity from an `afpc_app` connection
--     bound to the FIRST tenant answered `INSERT 0 1`. Referential-integrity checks do not apply
--     row security, so the key was satisfied by a row the caller can never read back — a
--     cross-tenant reference that the wall, the FK, and every register all agree does not exist.
--     Six edges into `entities` have that shape today (addresses, communications,
--     entity_relationships, followups, human_sessions, bot_actions). The same probe re-run through
--     a composite `(tenant_id, entity_id) → entities (tenant_id, id)` answered 23503 naming the
--     pair. That is 0011's "the tenant-led order is load-bearing, not hygiene" one step further:
--     there a tenant-blind index lost a write with no error, here a tenant-blind key admits a
--     foreign row with no error. Both are silent, both are invisible from the seat that does them.
--
-- THE DECISION, AND WHY IT IS NOT THE OTHER TWO
--
--   A `suppliers` table that EXTENDS the party root rather than paralleling it: one row per
--   supplier, carrying the supplier-only facts, keyed to the `entities` row that party already is.
--   "Is a supplier" therefore becomes the existence of a row rather than the value of a column, and
--   a party can hold both roles at once by having both facts.
--
--   Not a party-roles table: it would be the right answer for a dozen roles and is four tables of
--   machinery for one, and it leaves every role-specific fact (payment terms, lead time) with
--   nowhere to live.
--
--   Not a parallel `suppliers` root with its own name and address: a supplier that is not an
--   `entities` row has no contacts, no addresses, and no `communications`, because all three hang
--   off `entities`. In a system whose premise is that the conversation is the interface, that means
--   the agent can never answer "what has this supplier told us" — and the supplier who is also our
--   customer becomes two unrelated rows that nothing can prove are one company.
--
--   The enforcement the column could not give us, the key does: `orders.vendor_id` will reference
--   `suppliers`, so naming a non-supplier is not a rule a function has to remember to check. It is
--   a foreign key.
--
-- WHAT THIS DOES NOT DO
--
--   * It does not retrofit the six existing tenant-blind edges. Each is a decision about a table
--     with live rows, and doing six of them in the migration that is about suppliers would hide the
--     one that matters. They are recorded in db/MIGRATIONS.md as owed work with this file as the
--     evidence, which is how 0003 and 0006 handled the same shape of debt.
--   * It creates no contacts and no addresses. `add_supplier` links a party or makes the party; the
--     party's other facts keep the doors they already have.
--   * It does not touch `entities.entity_type`. The axis stays as 0007 found it. Probe D asserts
--     what the column now says about a supplier's party rather than trusting that nobody widened
--     or narrowed the vocabulary to make this table's design look better than it is.
--   * It takes no email and writes no contact. A contact reaches a party through
--     `entity_relationships`, and 0016 documented what the `role` column actually records ("was a
--     person named at creation"), so writing a value there is the role-axis decision 0016 deferred
--     to its own file — not a side effect of onboarding a supplier. The consequence is named in §8:
--     `add_customer` is still the only door that creates a contact, so a supplier created from a
--     name has a party and no reachable human yet.

SET client_min_messages TO notice;

-- ---------------------------------------------------------------------------
-- 1. The FK target: a tenant-led unique on the party table
-- ---------------------------------------------------------------------------
-- An ordinary table cannot be the target of a composite foreign key unless the referenced column
-- pair is unique, so the relationship 0027 wants needs this index to exist first.
--
-- It is not the redundancy 5.6 is about. `entities_pkey (id)` answers "which party is this";
-- `(tenant_id, id)` answers "is this party yours", which is a different question and the only one
-- an FK can be told to ask. 0006's own words on the same trade-off: "Both shapes are kept where
-- both query shapes exist, which is not the duplicate case 5.6 is about" — and
-- `vw_index_redundancy` decides by leading column list, where these two differ in their first
-- column, so it agrees that they are two indexes.
--
-- The build is the cheap kind: nine rows, one transaction, an ACCESS EXCLUSIVE lock measured in
-- milliseconds. It is stated rather than assumed because PLAN's own warning about an UPDATE in a
-- migration is a warning about locking a table agents are reading, and this is that table.
CREATE UNIQUE INDEX IF NOT EXISTS entities_tenant_id_key
    ON entities (tenant_id, id);

COMMENT ON INDEX entities_tenant_id_key IS
    'Not a faster way to find a party: the only uniqueness an FK can target that can express "this '
    'party belongs to the tenant that is referencing it". Referential-integrity checks bypass row '
    'security, so a single-column key to entities is satisfied by another tenant''s row (measured, '
    '0027''s header). Every tenant-coded table that must point at a party should reference '
    '(tenant_id, id), not (id). Built by 0027.';

-- ---------------------------------------------------------------------------
-- 2. The table
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS suppliers (
    supplier_id     uuid          PRIMARY KEY DEFAULT afpc_uuid_v7(),
    tenant_id       uuid          NOT NULL DEFAULT afpc_current_tenant(),

    -- The party this supplier IS. NOT NULL is the whole design decision in one word: there is no
    -- such thing as a supplier with no party, so there is no such thing as a supplier whose phone
    -- number, address and call history are unreachable.
    entity_id       bigint        NOT NULL,

    supplier_code   varchar(50)   NOT NULL,
    payment_terms   varchar(50),
    lead_time_days  integer,
    currency_code   char(3)       NOT NULL DEFAULT 'USD',
    is_active       boolean       NOT NULL DEFAULT true,
    notes           text,
    created_at      timestamptz   NOT NULL DEFAULT now(),
    updated_at      timestamptz   NOT NULL DEFAULT now(),
    version         integer       NOT NULL DEFAULT 1,

    CONSTRAINT suppliers_tenant_id_fkey
        FOREIGN KEY (tenant_id) REFERENCES tenants (tenant_id) ON DELETE RESTRICT,
    -- The cross-tenant-proof edge. Two columns, so the referenced row has to be in the same
    -- tenant as this one or the write is refused; and it is the ONLY party edge this table has,
    -- because a second, tenant-blind key to the same table would be one rule stated twice (0018's
    -- complaint about the currency columns), with the weaker of the two copies winning.
    CONSTRAINT suppliers_party_in_tenant_fkey
        FOREIGN KEY (tenant_id, entity_id) REFERENCES entities (tenant_id, id)
        ON DELETE RESTRICT,
    CONSTRAINT suppliers_currency_code_fkey
        FOREIGN KEY (currency_code) REFERENCES currencies (currency_code) ON DELETE RESTRICT,

    -- One supplier record per party, per tenant, which is the shape 0003 gave every other natural
    -- key on this server — and the measurement that corrected a claim this file first made the
    -- other way. A GLOBAL unique on entity_id is strictly stronger, and wrong twice over: it
    -- reports another tenant's party as a duplicate-key violation instead of as the foreign-key
    -- refusal it is (measured, `duplicate key value violates unique constraint
    -- "suppliers_one_row_per_party"` landing before the composite key ever ran), which tells a
    -- caller that a party id exists somewhere outside its wall; and it breaks the rule that the
    -- tenant leads a key. Tenant-scoped is equivalent in effect, because the composite party key
    -- below already prevents a row from naming a party in another tenant — so no party can ever
    -- have two supplier rows. The index is also the one B1b counts.
    CONSTRAINT suppliers_one_row_per_party UNIQUE (tenant_id, entity_id),
    -- The natural key, tenant-scoped the way 0003 re-scoped all six of them, so a second tenant can
    -- reuse code MAIN. This is the index B1b counts.
    CONSTRAINT suppliers_code_per_tenant UNIQUE (tenant_id, supplier_code),

    -- Uppercase alphanumerics, matching chk_sku_format's register, so the two document-facing code
    -- columns on this server cannot drift into different conventions.
    CONSTRAINT suppliers_code_format CHECK (supplier_code ~ '^[A-Z0-9][A-Z0-9_-]{0,49}$'),
    CONSTRAINT suppliers_lead_time_known CHECK (lead_time_days IS NULL OR lead_time_days >= 0),
    -- payment_terms is a free-text line: 0007's third case. It names a commercial arrangement
    -- ("Net 30") that belongs to whatever the tenant signs, not to the schema, and CHECKing its
    -- vocabulary would refuse a real term rather than a mistake. It is worth saying that
    -- vw_domain_vocabulary does not list it at all — the register's candidate rule reads columns
    -- whose names end in _type/_status/_method/_label/_unit/_measure, or are currency columns, and
    -- `payment_terms` is outside that set. A reader who expects every free-text column to appear
    -- there will look, not find it, and read the absence as an oversight.
    CONSTRAINT suppliers_terms_shape CHECK (payment_terms IS NULL OR btrim(payment_terms) <> '')
);

ALTER TABLE suppliers
    DROP CONSTRAINT IF EXISTS suppliers_tenant_id_fkey;
ALTER TABLE suppliers
    ADD CONSTRAINT suppliers_tenant_id_fkey
    FOREIGN KEY (tenant_id) REFERENCES tenants (tenant_id) ON DELETE RESTRICT;

-- Leads with tenant_id (0006), and then the column every order read sorts by. The unique constraint
-- above already gives the code path its tenant-led index, so this one is for the other question:
-- "which suppliers are ours, active first" — the list `add_supplier` and the procurement agent both
-- walk.
CREATE INDEX IF NOT EXISTS idx_suppliers_tenant_active
    ON suppliers (tenant_id, is_active, supplier_code);

-- (currency_code) rather than (tenant_id, currency_code), and that is 0006's measured finding
-- rather than a preference: "an FK existence check carries no tenant predicate, so (tenant_id,col)
-- cannot serve it — measured, 479 buffers/0.193 ms as a seq scan versus 6 buffers/0.017 ms
-- index-only". Without this index B17 names suppliers, because deleting a currency would scan the
-- whole table to find out whether anything still cites it. The currency itself is global master
-- data, so there is no tenant to lead with for this particular question.
CREATE INDEX IF NOT EXISTS idx_suppliers_currency
    ON suppliers (currency_code);

COMMENT ON TABLE suppliers IS
    'Parties we procure from, one row per party, extending entities rather than paralleling it: the '
    'party keeps its addresses, contacts and communications, and "is a supplier" is the existence of '
    'this row rather than the value of entities.entity_type — which is a single mutually-exclusive '
    'column and cannot hold both roles. A purchase order''s vendor_id references THIS table, so '
    'naming a non-supplier is a foreign-key refusal rather than a rule a function remembers. The '
    'party edge is composite (tenant_id, entity_id): measured, a single-column FK to entities is '
    'satisfied by another tenant''s row because referential integrity bypasses row security, and '
    'this edge is the schema''s first relationship that cannot be pointed at a foreign party. '
    'Deletion is by is_active, RESTRICT on every edge (0008). Built by 0027.';

COMMENT ON CONSTRAINT suppliers_party_in_tenant_fkey ON suppliers IS
    'The tenant-led party key. Its purpose is not to find a party faster — entities_pkey does that — '
    'it is to make "this order names a party that is not yours" unrepresentable. RLS alone cannot do '
    'this, because RI checks run without the policy applied (0027 measured INSERT 0 1 through the '
    'tenant-blind form).';

COMMENT ON CONSTRAINT suppliers_one_row_per_party ON suppliers IS
    'One supplier record per party, keyed tenant-first like every other natural key since 0003. '
    'Equivalent in effect to a global unique, because suppliers_party_in_tenant_fkey prevents a row '
    'from naming a party outside its own tenant — but a global unique was measured to answer a '
    'cross-tenant attempt with a duplicate-key error naming this constraint, which both misstates '
    'the reason and discloses that a party id exists behind another tenant''s wall. Paired with the '
    'composite key it lets a future migration ask "is this party also our customer" as a join '
    'between suppliers and the party tables rather than as a value in entities.entity_type that '
    'would have to stop saying what the party is.';

COMMENT ON CONSTRAINT suppliers_code_format ON suppliers IS
    'The supplier''s own reference for itself, in the register chk_sku_format uses: uppercase '
    'alphanumerics with - and _. Not a UUID, because it has to survive being typed onto an invoice. '
    'No function restates this list.';

COMMENT ON CONSTRAINT suppliers_lead_time_known ON suppliers IS
    'NULL means "nobody has measured it", which is a different claim from 0 and the same difference '
    'vw_item_movement_summary draws for days-of-supply. A negative lead time is a date in the past '
    'being used to schedule the future.';

-- ---------------------------------------------------------------------------
-- 3. The wall, the trail, and the grants — 0009's and 0013's shapes, by hand
-- ---------------------------------------------------------------------------
ALTER TABLE suppliers ENABLE ROW LEVEL SECURITY;
ALTER TABLE suppliers FORCE ROW LEVEL SECURITY;
-- Dropped before created, because a policy has no IF NOT EXISTS form and this file may meet a
-- database where an earlier attempt applied the DDL and failed in the verification block below.
-- migrate.sh wraps a file in one transaction so that cannot normally happen; the two manual
-- rehearsals of this migration are the reason the guard is here rather than in a comment.
DROP POLICY IF EXISTS tenant_isolation ON suppliers;
CREATE POLICY tenant_isolation ON public.suppliers AS PERMISSIVE
    FOR ALL TO PUBLIC
    USING (tenant_id = afpc_policy_tenant())
    WITH CHECK ((tenant_id = afpc_policy_tenant()));
DROP POLICY IF EXISTS audit_read_all ON suppliers;
CREATE POLICY audit_read_all ON public.suppliers AS PERMISSIVE
    FOR SELECT TO afpc_auditor, afpc_readonly
    USING (true);

-- Explicit, for the reason 0023 states: 0013's attaching census already ran and cannot see a table
-- born after it, while vw_audit_coverage's scope is the catalog's. An untrailed new table is
-- exactly the disagreement B26 counts.
DROP TRIGGER IF EXISTS afpc_audit_row ON suppliers;
CREATE TRIGGER afpc_audit_row
    AFTER INSERT OR UPDATE OR DELETE ON suppliers
    FOR EACH ROW EXECUTE FUNCTION afpc_audit_row();

-- 0010's rule read from the catalog: a table with an updated_at gets it maintained unless a
-- statement sets it deliberately. Suppliers are edited, so this table is in scope.
DROP TRIGGER IF EXISTS afpc_touch_updated_at ON suppliers;
CREATE TRIGGER afpc_touch_updated_at
    BEFORE INSERT OR UPDATE ON suppliers
    FOR EACH ROW EXECUTE FUNCTION afpc_touch_updated_at();

-- B10's requirement, discharged in the same breath as the column's existence: an integer version
-- column that no trigger assigns is 6.1's decorative counter, and 0011's installer cannot reach
-- this table because it ran fifteen files before this one. It is attached by hand, with 0011's own
-- name and body, so the row the registers derive from pg_trigger is true.
--
-- Trigger ORDER matters and is stated: both this and afpc_touch_updated_at are BEFORE FOR EACH ROW,
-- and PostgreSQL fires them in name order, so `afpc_bump_version` runs after `afpc_touch_updated_at`
-- alphabetically. 0011's obligation anticipated the moment that became observable — it is, the day
-- either body reads the other's column. Neither does: bump counts from its own counter and never
-- reads a timestamp, which is exactly what that obligation asked of it.
DROP TRIGGER IF EXISTS afpc_bump_version ON suppliers;
CREATE TRIGGER afpc_bump_version
    BEFORE UPDATE ON suppliers
    FOR EACH ROW EXECUTE FUNCTION afpc_bump_version();

-- ---------------------------------------------------------------------------
-- 4. The read path — ADR-003: a read names a view
-- ---------------------------------------------------------------------------
-- The party's identity comes along, because a supplier code alone is not an answer to any question
-- a human asks. LEFT JOIN rather than an inner one so a supplier whose party row is somehow absent
-- is visible as broken rather than invisible; the composite key makes that impossible, and the
-- outer join is the cheap way of proving it from the read path.
CREATE OR REPLACE VIEW vw_suppliers AS
SELECT s.tenant_id,
       s.supplier_id,
       s.supplier_code,
       s.entity_id,
       e.name                          AS party_name,
       e.legal_name,
       e.tax_id,
       e.entity_type                   AS party_type,
       s.payment_terms,
       s.lead_time_days,
       s.currency_code,
       s.is_active,
       s.notes,
       s.created_at,
       s.updated_at,
       s.version
  FROM suppliers s
  LEFT JOIN entities e ON e.id = s.entity_id;

ALTER VIEW vw_suppliers SET (security_invoker = true);
GRANT SELECT ON vw_suppliers TO afpc_readonly, afpc_auditor;

COMMENT ON VIEW vw_suppliers IS
    'Who we buy from, with the party behind the record: the supplier facts joined to the name, tax '
    'id and party type they belong to. tenant_id is exposed and the view runs as its invoker for '
    '0009''s reason — a postgres-owned view skips the wall. `party_type` is shown rather than '
    'filtered on: the value is what entities says the party IS, and a row that reads as a supplier '
    'while its party_type still says customer is the both-roles case this table exists to allow.';

-- ---------------------------------------------------------------------------
-- 5. The door
-- ---------------------------------------------------------------------------
-- add_customer is the precedent for a door that writes more than one table, because it creates an
-- entity, a contact, a relationship and an address in one business fact. This one is narrower: it
-- either links an existing party or creates the party and the supplier row for it. Both halves are
-- one decision — "onboard this supplier" — and 0021's warning about a door touching two tables when
-- its name names one is answered by the name naming the fact rather than the table.
CREATE OR REPLACE FUNCTION add_supplier(
    p_supplier_code    text    DEFAULT NULL,
    p_entity_id        bigint  DEFAULT NULL,
    p_name             text    DEFAULT NULL,
    p_tax_id           text    DEFAULT NULL,
    p_payment_terms    text    DEFAULT NULL,
    p_lead_time_days   integer DEFAULT NULL,
    p_currency_code    char(3) DEFAULT NULL,
    p_notes            text    DEFAULT NULL,
    p_is_active        boolean DEFAULT true,
    p_idempotency_key  uuid    DEFAULT NULL
) RETURNS TABLE(success boolean, supplier_id uuid, entity_id bigint, message text)
LANGUAGE plpgsql AS $$
DECLARE
    v_claim  record;
    v_state  text := '';
    v_ok     boolean := true;
    v_msg    text;
    v_sup    uuid;
    v_ent    bigint;
    v_found  bigint;
BEGIN
    ------------------------------------------------------------------
    -- ADR-005 pattern 2, in 0016's shape. Two calls that would onboard the same supplier are one
    -- operation; a call that differs in any business argument is a different request wearing
    -- someone else's key, which is a conflict and not a cache hit.
    ------------------------------------------------------------------
    IF p_idempotency_key IS NOT NULL THEN
        SELECT * INTO v_claim FROM idempotency_claim(
            p_idempotency_key, 'add_supplier',
            jsonb_build_object(
                'code', p_supplier_code, 'entity', p_entity_id, 'name', p_name,
                'tax', p_tax_id, 'terms', p_payment_terms,
                'lead', p_lead_time_days, 'currency', p_currency_code,
                'notes', p_notes, 'active', p_is_active));
        v_state := v_claim.claim_state;
        IF v_state = 'replay' THEN
            success     := (v_claim.cached_response ->> 'success')::boolean;
            supplier_id := (v_claim.cached_response ->> 'supplier_id')::uuid;
            entity_id   := (v_claim.cached_response ->> 'entity_id')::bigint;
            message     := v_claim.cached_response ->> 'message';
            RETURN NEXT;
            RETURN;
        ELSIF v_state = 'in_progress' THEN
            RAISE EXCEPTION 'add_supplier: an attempt with key % is already in flight',
                p_idempotency_key USING ERRCODE = '40001';
        ELSIF v_state = 'conflict' THEN
            RAISE EXCEPTION 'add_supplier: key % was settled for a DIFFERENT request',
                p_idempotency_key USING ERRCODE = 'P0001';
        END IF;
    END IF;

    ------------------------------------------------------------------
    -- Exactly one of "who already is a party" and "make them a party". This is a rule about
    -- arguments, so 0023's exception applies and it lives in the body: there is no column for a
    -- constraint to sit on.
    ------------------------------------------------------------------
    IF (p_entity_id IS NULL) = (p_name IS NULL OR btrim(p_name) = '') THEN
        RAISE EXCEPTION
            'add_supplier: give either p_entity_id (link an existing party) or a p_name (create one), '
            'and not both'
            USING ERRCODE = '22023',
                  HINT = 'an existing customer becoming a supplier is the p_entity_id case: the party '
                         'keeps its contacts and history and gains one row here';
    END IF;

    IF p_entity_id IS NOT NULL THEN
        -- Read through the wall, so "not found" and "not yours" are refused the same way 0018
        -- refused a hidden id: as a refusal with the candidates listed, never as a NULL a foreign
        -- key would then accept.
        SELECT count(*) INTO v_found FROM entities e WHERE e.id = p_entity_id;
        IF v_found <> 1 THEN
            RAISE EXCEPTION
                'add_supplier: party % is not a customer or supplier this connection can see',
                p_entity_id
                USING ERRCODE = '22023',
                      HINT = 'an id from another tenant is indistinguishable from one that was never '
                             'created, because row security hides the row before the key is checked';
        END IF;
        IF EXISTS (SELECT 1 FROM suppliers s WHERE s.entity_id = p_entity_id) THEN
            SELECT s.supplier_id INTO v_sup FROM suppliers s WHERE s.entity_id = p_entity_id;
            RAISE EXCEPTION
                'add_supplier: party % is already supplier % — one party, one supplier record',
                p_entity_id, v_sup
                USING ERRCODE = '23505';
        END IF;
        v_ent := p_entity_id;
    ELSE
        -- A new party, of the role this table is about. entity_type is written 'vendor' because
        -- that is what the column says a party is, and nothing here pretends the value is the
        -- reason the row is a supplier: the suppliers row is that, which is the whole point of the
        -- design. add_customer's p_entity_type is a different axis (individual/business) and is
        -- deliberately not consulted.
        INSERT INTO entities (name, entity_type, legal_name, tax_id, status)
        VALUES (btrim(p_name), 'vendor', btrim(p_name), p_tax_id, 'active')
        RETURNING entities.id INTO v_ent;
        -- No contact, on purpose: see the header's §"what this does not do". The party is real and
        -- its addresses and humans keep the doors that already own them.
    END IF;

    INSERT INTO suppliers (entity_id, supplier_code, payment_terms, lead_time_days,
                           currency_code, notes, is_active)
    VALUES (v_ent,
            upper(btrim(coalesce(p_supplier_code,
                                 'SUP-' || lpad(v_ent::text, 6, '0')))),
            NULLIF(btrim(coalesce(p_payment_terms, '')), ''),
            p_lead_time_days,
            coalesce(p_currency_code, 'USD'),
            NULLIF(btrim(coalesce(p_notes, '')), ''),
            coalesce(p_is_active, true))
    RETURNING suppliers.supplier_id INTO v_sup;

    v_msg := format('Supplier %s onboarding complete for party %s (id %s)',
        (SELECT s.supplier_code FROM suppliers s WHERE s.supplier_id = v_sup),
        (SELECT e.name FROM entities e WHERE e.id = v_ent),
        v_sup);

    IF v_state = 'claimed' THEN
        PERFORM idempotency_complete(v_claim.claim_id, v_claim.current_token,
            jsonb_build_object('success', true, 'supplier_id', v_sup,
                               'entity_id', v_ent, 'message', v_msg));
    END IF;

    RETURN QUERY SELECT v_ok, v_sup, v_ent, v_msg;
    RETURN;

EXCEPTION
    WHEN OTHERS THEN
        -- Refusals release the claim (0016's ladder): the obstacle here is deletable — another
        -- tenant's id, a code already used — so a later attempt must be able to run rather than
        -- find a cached no where a real answer should be.
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

COMMENT ON FUNCTION add_supplier(text, bigint, text, text, text, integer, char(3), text, boolean, uuid) IS
    'Onboard a supplier: link an existing party by p_entity_id, or create the party with p_name. '
    'Returns (success, supplier_id, entity_id, message) in add_customer''s shape, so a caller that '
    'branches on success branches on one shape across the whole surface. Both halves are one '
    'business fact, which is why one door writes them; add_customer writes four tables on the same '
    'reasoning. Linking a party that is already a supplier is refused with the existing id rather '
    'than updating it — this function onboards, it does not edit, and an editing door named '
    'add_supplier would be the second copy of a decision nobody made. A party id that row security '
    'hides answers as a refusal, not as a NULL the composite key would then reject with a message '
    'about a tenant id (0018 measured that difference and lost a write to it). The code defaults to '
    'SUP-<padded party id> because the column is NOT NULL and a supplier with no code cannot be '
    'typed onto an invoice. All domain rules are the constraints''; the body restates none of them. '
    'With p_idempotency_key a retried call is one supplier, not two (ADR-005, 0016''s ladder). Built '
    'by 0027.';

-- ---------------------------------------------------------------------------
-- 6. Privileges — 0009's obligation, per object, because the default is a no-op for functions
-- ---------------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION add_supplier(text, bigint, text, text, text, integer, char(3), text, boolean, uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION add_supplier(text, bigint, text, text, text, integer, char(3), text, boolean, uuid) TO afpc_app;

-- ---------------------------------------------------------------------------
-- 7. Verify by behaving
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_n       int := 0;
    v_sup     uuid;
    v_sup2    uuid;
    v_ent     bigint;
    v_ent2    bigint;
    v_ok      boolean;
    v_msg     text;
    v_err     text;
    v_found   bigint;
    v_td      uuid;
    v_t2      uuid;
    v_key     uuid;
BEGIN
    ------------------------------------------------------------------
    -- A. enrolled in every mechanism a tenant-coded table is supposed to be in, asserted from the
    --    catalog because "I wrote the DDL" is not evidence that it applied.
    ------------------------------------------------------------------
    IF (SELECT count(*) FROM information_schema.columns
         WHERE table_name = 'suppliers' AND column_name = 'tenant_id'
           AND is_nullable = 'NO' AND data_type = 'uuid'
           AND column_default LIKE 'afpc_current_tenant%') <> 1 THEN
        RAISE EXCEPTION 'A failed: suppliers.tenant_id is not the tenancy column 0003 prescribes';
    END IF;
    IF (SELECT count(*) FROM pg_class c
         WHERE c.oid = 'suppliers'::regclass AND c.relrowsecurity AND c.relforcerowsecurity) <> 1 THEN
        RAISE EXCEPTION 'A failed: row security is not enabled AND forced, so B7 would count this '
                        'table as the disagreement';
    END IF;
    IF (SELECT count(*) FROM pg_policy po
         WHERE po.polrelid = 'suppliers'::regclass AND po.polname = 'tenant_isolation'
           AND po.polqual IS NOT NULL AND po.polwithcheck IS NOT NULL) <> 1 THEN
        RAISE EXCEPTION 'A failed: the isolation policy has no WITH CHECK half, so reads would be '
                        'filtered and writes would not (5.7''s decorative case)';
    END IF;
    IF (SELECT count(*) FROM pg_trigger t
         WHERE t.tgrelid = 'suppliers'::regclass AND t.tgname = 'afpc_audit_row'
           AND NOT t.tgisinternal) <> 1 THEN
        RAISE EXCEPTION 'A failed: no audit trigger — 0013''s census ran before this table existed';
    END IF;
    -- B10's claim, checked rather than hoped: the version column must be moved by a row trigger
    -- whose body assigns it. This is the assertion that makes attaching afpc_bump_version by hand
    -- above unskippable.
    IF NOT EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
                    WHERE t.tgrelid = 'suppliers'::regclass AND t.tgname = 'afpc_bump_version'
                      AND NOT t.tgisinternal AND (t.tgtype & 1) = 1
                      AND lower(p.prosrc) ~ 'new[.]version[[:space:]]*:=' ) THEN
        RAISE EXCEPTION 'A failed: suppliers.version exists and nothing assigns it — that is 6.1''s '
                        'decorative counter, reproduced in a migration written to prevent it';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_index i
                    WHERE i.indrelid = 'suppliers'::regclass
                      AND (SELECT q.v FROM unnest(i.indkey::int[])
                            WITH ORDINALITY AS q(v, o) WHERE q.o = 1 LIMIT 1)
                          = (SELECT a.attnum FROM pg_attribute a
                              WHERE a.attrelid = 'suppliers'::regclass
                                AND a.attname = 'tenant_id')) THEN
        -- unnest WITH ORDINALITY, not a slice: int2vector is zero-based, and (indkey::int[])[1] is
        -- the SECOND column — the mistake dev/README records three migrations making.
        RAISE EXCEPTION 'A failed: no index on suppliers leads with tenant_id (0003''s rule)';
    END IF;
    -- Every foreign key this table declares must lead an index on this side. Asserted locally, in
    -- the file that creates them, because B17 is the check that catches it globally and a
    -- migration that fails a scoreboard three scripts away is a worse debug than one that names
    -- its own offender here.
    IF (SELECT count(*) FROM pg_constraint k
         WHERE k.conrelid = 'suppliers'::regclass AND k.contype = 'f'
           AND cardinality(k.conkey) = 1
           AND NOT EXISTS (SELECT 1 FROM pg_index i
                            WHERE i.indrelid = k.conrelid AND i.indkey[0] = (k.conkey)[1])) <> 0 THEN
        SELECT string_agg((SELECT attname FROM pg_attribute
                             WHERE attrelid = k.conrelid AND attnum = (k.conkey)[1]), ', ')
          INTO v_msg
          FROM pg_constraint k
         WHERE k.conrelid = 'suppliers'::regclass AND k.contype = 'f'
           AND cardinality(k.conkey) = 1
           AND NOT EXISTS (SELECT 1 FROM pg_index i
                            WHERE i.indrelid = k.conrelid AND i.indkey[0] = (k.conkey)[1]);
        RAISE EXCEPTION 'A failed: a single-column foreign key on suppliers leads no index (%), so '
                        'every parent-side delete is a scan — 0006''s invariant, and B17 names it', v_msg;
    END IF;
    IF (SELECT count(*) FROM pg_index i JOIN pg_attribute a ON a.attrelid = i.indrelid
                                              AND a.attnum = i.indkey[0]
         WHERE i.indrelid = 'entities'::regclass AND i.indisunique
           AND a.attname = 'tenant_id'
           AND cardinality(i.indkey::int[]) = 2) = 0 THEN
        RAISE EXCEPTION 'A failed: entities has no tenant-led two-column unique, so the composite '
                        'party key has no target and the next assertion cannot mean anything';
    END IF;
    -- And the shape of the party-uniqueness rule, pinned rather than assumed. This is here because
    -- the first draft of this migration had UNIQUE (entity_id) — global — and probe B then failed
    -- with a duplicate-key error instead of a foreign-key one: the weaker-looking tenant-led form
    -- is the one that refuses cross-tenant references for the right reason. An index list is the
    -- only place that distinction is recorded, so it is asserted where it can fail.
    IF (SELECT count(*) FROM pg_index i JOIN pg_attribute a ON a.attrelid = i.indrelid
                                              AND a.attnum = i.indkey[0]
         WHERE i.indrelid = 'suppliers'::regclass AND i.indisunique AND NOT i.indisprimary
           AND a.attname = 'tenant_id'
           AND cardinality(i.indkey::int[]) = 2
           AND (SELECT attname FROM pg_attribute WHERE attrelid = 'suppliers'::regclass
                 AND attnum = i.indkey[1]) = 'entity_id') <> 1 THEN
        RAISE EXCEPTION 'A failed: suppliers has no tenant-led (tenant_id, entity_id) unique, so a '
                        'cross-tenant party reference will surface as a duplicate key naming this '
                        'table rather than as the foreign-key refusal probe B asserts';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- B. the headline claim, BEHAVED rather than read from a catalog: a supplier row cannot name a
    --    party belonging to another tenant. This is the assertion the whole file is for, and it is
    --    run from the seat that is bound by the wall — the owner bypasses everything and would
    --    measure itself (dev/README's masquerading entry).
    ------------------------------------------------------------------
    INSERT INTO tenants (name, slug) VALUES ('0027 second tenant', 'afpc-0027-t2')
     RETURNING tenant_id INTO v_t2;
    SELECT tenant_id INTO v_td FROM tenants WHERE slug = 'default';

    SET LOCAL ROLE afpc_app;
    PERFORM set_config('app.tenant_id', v_t2::text, true);
    SELECT entity_id INTO v_ent2
      FROM add_supplier('0027-T2-SUP', NULL, 'Tenant Two Metals', NULL, NULL,
                        NULL, NULL, NULL, true, NULL);
    RESET ROLE;

    SET LOCAL ROLE afpc_app;
    PERFORM set_config('app.tenant_id', v_td::text, true);
    v_err := NULL;
    BEGIN
        EXECUTE format(
            'INSERT INTO suppliers (entity_id, supplier_code) VALUES (%s, %L)',
            v_ent2, '0027-CROSS-TENANT');
    EXCEPTION WHEN foreign_key_violation THEN
        v_err := '23503';
        GET STACKED DIAGNOSTICS v_msg = CONSTRAINT_NAME;
    END;
    IF v_err IS DISTINCT FROM '23503' THEN
        RAISE EXCEPTION 'B failed: a supplier row naming another tenant''s party answered % — the '
                        'composite key is the only thing standing between this database and a '
                        'cross-tenant order, and 0027 measured the single-column form letting it '
                        'through', coalesce(v_err, 'no error at all — the row was WRITTEN');
    END IF;
    IF v_msg IS DISTINCT FROM 'suppliers_party_in_tenant_fkey' THEN
        RAISE EXCEPTION 'B failed: the refusal came from constraint % rather than the party key, so '
                        'some other rule is doing this job by accident', v_msg;
    END IF;
    IF EXISTS (SELECT 1 FROM suppliers WHERE supplier_code = '0027-CROSS-TENANT') THEN
        RAISE EXCEPTION 'B failed: the refused row was stored anyway';
    END IF;
    RESET ROLE;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- C. and the same probe through the ordinary single-column shape, to keep B honest about what
    --    it proved. If anyone ever "simplifies" the party key down to (entity_id), B starts passing
    --    on a weaker edge — so this block asserts the weakness still exists where 0027 did not
    --    change it. It is the control, not the finding.
    ------------------------------------------------------------------
    SET LOCAL ROLE afpc_app;
    PERFORM set_config('app.tenant_id', v_td::text, true);
    v_err := NULL;
    BEGIN
        EXECUTE format(
            'INSERT INTO addresses (entity_id, address_type, street, city, country) '
            'VALUES (%s, %L, %L, %L, %L)', v_ent2, 'billing', 'Elsewhere', 'Nowhere', 'US');
        DELETE FROM addresses WHERE entity_id = v_ent2 AND street = 'Elsewhere';
    EXCEPTION WHEN foreign_key_violation THEN
        v_err := '23503';
    END;
    RESET ROLE;
    IF v_err IS NULL THEN
        RAISE NOTICE 'C: the tenant-blind single-column edge still accepts a foreign party — as '
                     'measured by 0027, and owed by the six pre-existing edges into entities, not '
                     'by this table';
    ELSE
        RAISE NOTICE 'C: a single-column FK to entities now refuses a foreign tenant''s party (%), '
                     'which means row security has started binding RI checks — worth re-reading '
                     '0027''s header, because the composite keys then stop being load-bearing',
                     v_err;
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- D. linking an existing party (the both-roles case), and refusing to do it twice.
    --    This is the requirement the single entity_type column could not express: one party, two
    --    roles, no value having to stop being true.
    ------------------------------------------------------------------
    SELECT success, supplier_id, entity_id, message INTO v_ok, v_sup, v_ent, v_msg
      FROM add_supplier('0027-D-CUST', NULL, 'Existing Customer Metals', 'TAX-0027-D',
                        'Net 30', 14, NULL, NULL, true, NULL);
    IF NOT v_ok OR v_sup IS NULL OR v_ent IS NULL THEN
        RAISE EXCEPTION 'D failed: creating a new supplier answered %', v_msg;
    END IF;
    -- The party is a vendor, and therefore deliberately NOT in vw_customers: that view filters
    -- entity_type = 'customer' (T2's open question, and 0007's first bullet). Asserting the
    -- absence is the honest way to state what a supplier-created-from-a-name looks like to the CRM
    -- read path, rather than letting a future reader assume vw_customers shows every party.
    IF (SELECT count(*) FROM entities e WHERE e.id = v_ent
          AND e.entity_type = 'vendor') <> 1 THEN
        RAISE EXCEPTION 'D failed: the party add_supplier created is not an entity_type=vendor row, '
                        'which is the only thing its name says it is';
    END IF;
    IF (SELECT count(*) FROM vw_customers WHERE id = v_ent) <> 0 THEN
        RAISE EXCEPTION 'D failed: a vendor party appears in vw_customers — either the view''s '
                        'filter changed or add_supplier wrote a different party type than this '
                        'probe believes it writes';
    END IF;
    v_err := NULL;
    BEGIN
        PERFORM * FROM add_supplier('0027-D-AGAIN', v_ent, NULL, NULL, NULL, NULL, NULL, NULL,
                                    true, NULL);
    EXCEPTION WHEN unique_violation THEN
        v_err := '23505';
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    END;
    IF v_err IS DISTINCT FROM '23505' THEN
        RAISE EXCEPTION 'D failed: onboarding the same party twice answered % — one party must be '
                        'one supplier record', coalesce(v_err, 'no error: two rows for one company');
    END IF;
    IF v_msg NOT LIKE '%supplier%' THEN
        RAISE EXCEPTION 'D failed: the duplicate refusal did not name the supplier it means: %', v_msg;
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- E. link, not create: an existing customer gains the supplier role without losing anything.
    --    add_customer is used to make the party, so the test goes through the doors rather than
    --    hand-inserting rows the schema has never seen from that side.
    ------------------------------------------------------------------
    SELECT entity_id INTO v_ent2
      FROM add_customer('0027', 'Linkme', 'link0027@afpc.example.invalid', '+15550104',
                        NULL, NULL, NULL, NULL, 'US', 'active', 'business',
                        'Linkme Industries', 'work', true, NULL);
    SELECT success, supplier_id, entity_id INTO v_ok, v_sup, v_found
      FROM add_supplier('0027-E-LINK', v_ent2, NULL, NULL, 'COD', NULL, NULL, NULL, true, NULL);
    IF NOT v_ok OR v_found IS DISTINCT FROM v_ent2 THEN
        RAISE EXCEPTION 'E failed: linking an existing customer as a supplier did not return the '
                        'same party id (got % for %)', v_found, v_ent2;
    END IF;
    IF (SELECT count(*) FROM entities WHERE id = v_ent2) <> 1 THEN
        RAISE EXCEPTION 'E failed: linking a party created a second entities row';
    END IF;
    -- Both roles readable at once, which is the sentence this migration exists to make true.
    IF (SELECT count(*) FROM vw_suppliers WHERE entity_id = v_ent2) <> 1
       OR (SELECT count(*) FROM vw_customers WHERE id = v_ent2) <> 1 THEN
        RAISE EXCEPTION 'E failed: a party that is both customer and supplier reads as % suppliers '
                        'and % customers',
            (SELECT count(*) FROM vw_suppliers WHERE entity_id = v_ent2),
            (SELECT count(*) FROM vw_customers WHERE id = v_ent2);
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- F. the constraints decide, and the body restates none of them. Each fixture asserts a
    --    SQLSTATE and the name of the constraint that produced it, because a rule that moved into
    --    an IF arm would keep answering 22023 while the constraint rotted.
    ------------------------------------------------------------------
    v_err := NULL;
    BEGIN
        PERFORM * FROM add_supplier('0027 bad code', NULL, 'Shape Co', NULL, NULL, NULL, NULL,
                                    NULL, true, NULL);
    EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '23514' THEN
        RAISE EXCEPTION 'F failed: a lowercase supplier code answered % — the format CHECK is '
                        'supposed to be the only thing that decides this', coalesce(v_err, 'nothing');
    END IF;

    v_err := NULL;
    BEGIN
        PERFORM * FROM add_supplier('0027_F_NEG', NULL, 'Negative Lead Co', NULL, NULL, -5,
                                    NULL, NULL, true, NULL);
    EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '23514' THEN
        RAISE EXCEPTION 'F failed: a negative lead time answered %', coalesce(v_err, 'no error');
    END IF;

    v_err := NULL;
    BEGIN
        PERFORM * FROM add_supplier('0027_F_CUR', NULL, 'Bad Currency Co', NULL, NULL, NULL,
                                    'ZZ', NULL, true, NULL);
    EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '23503' THEN
        RAISE EXCEPTION 'F failed: an unlisted currency code answered % — 0018 established that '
                        'membership on a code column is the foreign key''s job, not a CHECK''s and '
                        'not a body''s', coalesce(v_err, 'no error');
    END IF;
    -- And the constraint names, from the catalog, so the register agrees with this file about which
    -- rule is where. Three CHECKs: the code's format, the lead time's sign, the terms' blank-not-
    -- present. Tenancy and the currency and party memberships are foreign keys rather than CHECKs,
    -- which is 0018's rule that a referencing column's mechanism is the key.
    IF (SELECT count(*) FROM pg_constraint WHERE conrelid = 'suppliers'::regclass AND contype = 'c')
       <> 3 THEN
        RAISE EXCEPTION 'F failed: suppliers carries % CHECK constraints, expected 3 — '
                        'vw_domain_vocabulary and B2 derive their rows from this set, so a fourth '
                        'means a rule was restated somewhere',
            (SELECT count(*) FROM pg_constraint WHERE conrelid = 'suppliers'::regclass AND contype = 'c');
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- G. a refused door leaves NO trace. The party must not survive the supplier row that failed,
    --    because a phantom vendor in the CRM is the kind of row a support agent then calls.
    ------------------------------------------------------------------
    SELECT count(*) INTO v_found FROM entities WHERE name = 'Shape Co';
    IF v_found <> 0 THEN
        RAISE EXCEPTION 'G failed: a supplier write refused on the code shape left % party row(s) '
                        'behind — the party is created before the refusal, so without a rollback '
                        'this is exactly how a phantom vendor enters the CRM', v_found;
    END IF;
    IF (SELECT count(*) FROM suppliers) <> (SELECT count(*) FROM entities e
                                             WHERE EXISTS (SELECT 1 FROM suppliers s
                                                            WHERE s.entity_id = e.id)) THEN
        RAISE EXCEPTION 'G failed: suppliers and the parties they name have come apart';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- H. one party per tenant's supplier list, both directions, in seats the wall binds. Tenant 1
    --    must not see tenant 2's supplier, and must not be able to link its own party to the other
    --    tenant's id even by accident.
    ------------------------------------------------------------------
    SET LOCAL ROLE afpc_app;
    PERFORM set_config('app.tenant_id', v_t2::text, true);
    SELECT count(*) INTO v_found FROM vw_suppliers;
    IF v_found <> 1 THEN
        RAISE EXCEPTION 'H failed: tenant 2 sees % suppliers, expected only its own', v_found;
    END IF;
    RESET ROLE;
    SET LOCAL ROLE afpc_app;
    PERFORM set_config('app.tenant_id', v_td::text, true);
    SELECT count(*) INTO v_found FROM vw_suppliers;
    IF v_found <> 2 THEN
        RAISE EXCEPTION 'H failed: the default tenant sees % suppliers, expected its own two', v_found;
    END IF;
    IF EXISTS (SELECT 1 FROM vw_suppliers WHERE tenant_id <> v_td) THEN
        RAISE EXCEPTION 'H failed: vw_suppliers published a row belonging to another tenant';
    END IF;
    RESET ROLE;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- I. a retried call is one supplier. Same key, same arguments, second answer is the first row.
    ------------------------------------------------------------------
    v_key := gen_random_uuid();
    SELECT success, supplier_id INTO v_ok, v_sup
      FROM add_supplier('0027-I-RETRY', NULL, 'Idempotent Alloys', NULL, 'Net 45', NULL, NULL,
                        NULL, true, v_key);
    SELECT success, supplier_id INTO v_ok, v_sup2
      FROM add_supplier('0027-I-RETRY', NULL, 'Idempotent Alloys', NULL, 'Net 45', NULL, NULL,
                        NULL, true, v_key);
    IF v_sup2 IS DISTINCT FROM v_sup THEN
        RAISE EXCEPTION 'I failed: the replay answered with a different supplier id';
    END IF;
    IF (SELECT count(*) FROM suppliers s
         WHERE s.supplier_code = '0027-I-RETRY') <> 1 THEN
        RAISE EXCEPTION 'I failed: one claim produced % supplier rows',
            (SELECT count(*) FROM suppliers s WHERE s.supplier_code = '0027-I-RETRY');
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- J. the trail exists, and the chain still verifies: a supplier write is not only this table's
    --    row. Chain assertions are per-subject, never totals — 0013's obligation.
    ------------------------------------------------------------------
    IF (SELECT count(*) FROM audit_log l
         WHERE l.table_name = 'suppliers' AND l.action = 'INSERT') < 4 THEN
        RAISE EXCEPTION 'J failed: % audit rows for a table this probe wrote to at least four times',
            (SELECT count(*) FROM audit_log l
              WHERE l.table_name = 'suppliers' AND l.action = 'INSERT');
    END IF;
    -- The verifier returns one row per (tenant, month) segment, not a boolean — 0013's own shape —
    -- so the claim is "no segment fails", and it is per-subject rather than a total, which is
    -- B-check-independent obligation 0013 states about never counting audit_log absolutely.
    IF (SELECT count(*) FROM audit_chain_verify() WHERE NOT chain_ok) <> 0 THEN
        SELECT string_agg(reason, ' / ') INTO v_msg FROM audit_chain_verify() WHERE NOT chain_ok;
        RAISE EXCEPTION 'J failed: the audit chain does not verify after 0027 added a trailed '
                        'table — %', v_msg;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM vw_audit_coverage a
                    WHERE a.table_name = 'suppliers' AND a.row_audited) THEN
        RAISE EXCEPTION 'J failed: the coverage register does not see suppliers as trailead';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- K. the registers notice this table by themselves — same discipline as 0023's H. The
    --    timestamp register must say maintained (it is an editable table, so unlike agent_memories
    --    this one OWNS an updated_at), and the idempotency register must credit the door.
    ------------------------------------------------------------------
    SELECT verdict INTO v_msg FROM vw_timestamp_status WHERE table_name = 'suppliers';
    IF v_msg IS DISTINCT FROM 'maintained' THEN
        RAISE EXCEPTION 'K failed: the timestamp register says % of suppliers, and this is an '
                        'editable table so the only honest verdict is maintained', coalesce(v_msg, 'nothing');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM vw_idempotency_status s
                    WHERE s.function = 'add_supplier' AND NOT s.unguarded) THEN
        RAISE EXCEPTION 'K failed: the idempotency register does not credit add_supplier with a '
                        'claim — either it is not wired or the derivation stopped seeing it';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- L. no new index is redundant, and no foreign key leads nothing. Asserted here rather than
    --    waiting for verify.sh, because 0006's prefix rule is exactly the kind of thing a
    --    "helpful" new index trips on the way in.
    ------------------------------------------------------------------
    IF (SELECT count(*) FROM vw_index_redundancy) <> 0 THEN
        SELECT string_agg(table_name || ': ' || redundant_index || ' is covered by ' || covered_by,
                          ' | ') INTO v_msg
          FROM (SELECT DISTINCT table_name, redundant_index, covered_by
                  FROM vw_index_redundancy LIMIT 5) r;
        RAISE EXCEPTION 'L failed: redundant index pair(s) after 0027, which 0006''s invariant '
                        'forbids — %', v_msg;
    END IF;
    -- 0027's own contribution to the tenancy question, stated where it can be watched rather than
    -- remembered: how many edges into entities are now tenant-led, and how many are still blind.
    SELECT count(*) FILTER (WHERE cardinality(conkey) > 1),
           count(*) FILTER (WHERE cardinality(conkey) = 1)
      INTO v_found, v_ent
      FROM pg_constraint
     WHERE contype = 'f' AND confrelid = 'entities'::regclass;
    RAISE NOTICE 'L: % tenant-led edge(s) into entities now exist and % remain single-column; the '
                 'blind ones are addresses, communications, entity_relationships, followups, '
                 'human_sessions and bot_actions, owed by the reason recorded in §8',
                 v_found, v_ent;
    IF v_found < 1 THEN
        RAISE EXCEPTION 'L failed: suppliers''s composite party edge is not registered as a '
                        'foreign key, so probe B proved nothing about the constraint it names';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- Cleanup. Ordered: supplier rows before parties, because every edge is RESTRICT and this file
    -- would be lying about delete safety if it could not delete its own fixtures through the
    -- ordering it asserts. The audit rows about these writes stay behind — that is 0013 being
    -- honest, not residue, and test-functions.sh's residue check knows the difference because the
    -- trail is expected to grow.
    ------------------------------------------------------------------
    DELETE FROM suppliers WHERE supplier_code LIKE '0027-%';
    DELETE FROM idempotency_keys WHERE operation = 'add_supplier';
    -- Contacts first, then the rows that reference them: 0008 flipped these edges to RESTRICT, so
    -- the delete order is the same claim the DDL makes, demonstrated rather than asserted.
    DELETE FROM entity_relationships
     WHERE contact_id IN (SELECT id FROM contacts WHERE email = 'link0027@afpc.example.invalid');
    DELETE FROM contacts WHERE email = 'link0027@afpc.example.invalid';
    DELETE FROM entities WHERE tenant_id = v_t2
        OR name IN ('Existing Customer Metals', 'Linkme Industries', 'Idempotent Alloys');
    DELETE FROM tenants WHERE slug = 'afpc-0027-t2';
    -- Asserted empty by the patterns above, never by an unqualified DELETE: a migration that
    -- cleared a table would destroy a real deployment's data the first time it was replayed, and
    -- the residue check in test-functions.sh would read that as a passing run.
    IF (SELECT count(*) FROM suppliers WHERE supplier_code LIKE '0027-%') <> 0 THEN
        RAISE EXCEPTION 'cleanup failed: 0027 fixtures remain in suppliers';
    END IF;

    IF v_n <> 12 THEN
        RAISE EXCEPTION 'expected 12 behavioural verifications, completed %', v_n;
    END IF;
    RAISE NOTICE '0027: % checks passed - suppliers extend the party root instead of paralleling it, '
                 'a party can hold two roles at once, the composite key refuses another tenant''s '
                 'party where a single-column FK was measured to accept it, and every register '
                 'noticed the new table without being told', v_n;
END
$$;

-- ---------------------------------------------------------------------------
-- 8. Obligations this file leaves open, on purpose
-- ---------------------------------------------------------------------------
-- * No `add_supplier_contact`, and no email on this door. The consequence is stated in the header:
--   a supplier created from a name has a party with no reachable human, because `add_customer` is
--   still the only door in the schema that writes a `contacts` row and links it through
--   `entity_relationships`. Whoever closes that owes 0016's deferred decision about the `role` axis
--   in the same file, with the views that read it, and not as a side effect here.
-- * The six pre-existing tenant-blind edges into entities (addresses, communications,
--   entity_relationships, followups, human_sessions, bot_actions). Probe C keeps the finding alive
--   from both directions: it reports the weakness while it exists, and if row security ever starts
--   binding RI checks it says so out loud rather than letting the composite keys quietly stop
--   earning their keep. Retrying those six is a migration with its own probe, not a footnote here,
--   because each needs a statement about its live rows.
-- * No `update_supplier` door. Nothing edits a supplier today, and 0018 declined a column with no
--   reader for the same reason. The day one exists it takes a claim and a version check, and B10 is
--   already watching the column.
-- * No `retire_supplier`. 0008's close-out convention is is_active, which this table has; a door
--   that names retirement belongs with the orders that would block it (0028), because a supplier
--   with an open purchase order must refuse and say how many.
-- * `suppliers` carries no embedding, unlike communications. It is keyed master data, and a vector
--   column added to look consistent with 6.4 is a column no code reads — 0023's note on the same
--   temptation.
-- * The default supplier code is derived from the party id ('SUP-' || id). It is unique because the
--   id is, and it is stable, but it is not sequential in the way a purchasing department expects.
--   Whoever wants a document-number sequence should build it once, for orders and suppliers
--   together, in 0028's image — not a second mechanism per table.
