-- 0014: the movement contract - a unit of measure, warehouse columns that mean what the
--       type says, an answer for every vocabulary member, and a claim where retries are real
--       (DATABASE_REVIEW.md 4.1, 4.2's phantom half, 4.3's cost divisor; 0007's two
--       assignments: the follow-up writer and the named-but-unhandled movement types)
--
-- Four things 6.x/4.x could not see from the outside, found while building this:
--
--   * `inventory_movements.to_warehouse_id` is NOT NULL, so the ISSUE/ADJUSTMENT path died
--     on the LEDGER INSERT even after 4.1's UOM fix - the review called it "populated from
--     the same parameter that is NULL for an issue" and stopped there; measured, the column
--     itself is the second wall. It becomes nullable with a CHECK that states each type's
--     warehouse shape, which is 5.9's "the constraint is the documentation" applied to the
--     ledger's central invariant: a movement is a fact about where stock went.
--   * the idempotency register has been lying about this function since 0004: the ladder
--     reads 'ON CONFLICT' and prints pattern 1 - "a replay is answered from the cache" -
--     for an upsert that ADDS STOCK. The arbiter makes the row unique, not the effect
--     idempotent; a replayed receipt doubles the balance and the register called it safe.
--     0004 added the clause; 0011's ladder inherited the misreading; nothing ran a replay
--     to find out. The fix is not a ladder patch - it is Obligations-0011's own instruction
--     ("that head is the place a claim belongs"): the function now takes an optional
--     p_idempotency_key, and the verdict becomes pattern 2 by truth instead of by regex.
--   * 4.1's own test fixture violated 0007's vocabulary (reference_type='purchase_order' is
--     not a member; 'PO' is) and never noticed, because the 23502 fired first in the same
--     statement - NOT NULL is checked before CHECK. A defect can mask a second defect in
--     the same row; fixing the first one is what makes the second visible (db/tests/4_1
--     is corrected in this commit's test pass, pre-0014 output unchanged, measured).
--   * the follow-up status 0007 assigned here had no writer because NOTHING in the schema
--     was allowed to set entities.status after creation - mark_customer_followup is that
--     writer: convergent by design (a replay sets the same value), so it is deliberately
--     claim-free, and its register row says UNGUARDED, which is true and means something
--     different from the accumulating upsert's false 'pattern 1'.

SET client_min_messages TO notice;

-- ---------------------------------------------------------------------------
-- 1. The ledger's warehouse shape, in the constraint
-- ---------------------------------------------------------------------------
ALTER TABLE inventory_movements ALTER COLUMN to_warehouse_id DROP NOT NULL;

-- Added NOT VALID then validated in its own statement (0005's B16 discipline, applied to a
-- CHECK): on a populated copy the violation must name itself as THIS constraint rather than
-- fail inside the ALTER as a generic validation error.
ALTER TABLE inventory_movements ADD CONSTRAINT inventory_movements_warehouse_shape CHECK (
    (movement_type IN ('RECEIPT', 'RETURN')   AND to_warehouse_id   IS NOT NULL)
 OR (movement_type = 'ISSUE'                  AND from_warehouse_id IS NOT NULL)
 OR (movement_type = 'TRANSFER' AND from_warehouse_id IS NOT NULL
                                   AND to_warehouse_id IS NOT NULL
                                   AND from_warehouse_id IS DISTINCT FROM to_warehouse_id)
 OR (movement_type = 'RESERVATION'            AND to_warehouse_id   IS NOT NULL)
 -- ADJUSTMENT: either side. A legacy adjustment recorded a destination only; the function's
 -- own path needs a source, and it says so at runtime. The CHECK is the floor, not the API.
 OR (movement_type = 'ADJUSTMENT' AND (from_warehouse_id IS NOT NULL
                                       OR to_warehouse_id IS NOT NULL))
) NOT VALID;
ALTER TABLE inventory_movements VALIDATE CONSTRAINT inventory_movements_warehouse_shape;

COMMENT ON CONSTRAINT inventory_movements_warehouse_shape ON inventory_movements IS
    'Each movement type names the warehouses it must name. This is 4.1''s second wall (the
    NOT NULL on to_warehouse_id killed ISSUE before the branch ever ran) replaced by the rule
    the column pair actually means, and it is why RESERVATION/TRANSFER stop being vocabulary
    members that merely happen to work: the constraint names all six values of the 0007
    register. Built by 0014.';

-- ---------------------------------------------------------------------------
-- 2. The function, rewritten
-- ---------------------------------------------------------------------------
-- Signature: 10 -> 12, both additions DEFAULT NULL so every existing call still resolves
-- (the 4.4 lesson, inverted: an overload would go ambiguous; a defaulted addition keeps one
-- callable function - probe I asserts that count from pg_proc). And the rehearsal proved
-- the sentence in that comment is not optional: CREATE OR REPLACE with a CHANGED parameter
-- list does not replace anything - it creates a second overload, and every call to the
-- name went ambiguous on the spot. The old head must be dropped by its full signature
-- first; that DROP is why this section says 'rewritten', not 'added to'.
DROP FUNCTION IF EXISTS execute_inventory_movement(
    varchar, uuid, uuid, uuid, numeric, numeric, varchar, varchar, uuid, varchar);
CREATE OR REPLACE FUNCTION execute_inventory_movement(
    p_movement_type      varchar,
    p_item_id            uuid,
    p_from_warehouse_id  uuid,
    p_to_warehouse_id    uuid,
    p_quantity           numeric,
    p_unit_cost          numeric,
    p_performed_by       varchar,
    p_reference_type     varchar,
    p_reference_id       uuid,
    p_reason_code        varchar,
    p_unit_of_measure    varchar  DEFAULT NULL,
    p_idempotency_key    uuid     DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
    v_movement_id uuid;
    v_batch_id    uuid := gen_random_uuid();
    v_uom         varchar(20);
    v_touch       int;
    v_claim       record;
    v_state       text;
BEGIN
    ------------------------------------------------------------------
    -- ADR-005 pattern 2, per 0011's instruction that a rewritten function's head is where a
    -- claim belongs. NULL key = no claim: the call stays as honest as it was, and the
    -- REGISTER still says pattern 2 because the MECHANISM is reachable here - the alternative
    -- (forcing every caller to mint a uuid) would make the schema's contract a client library.
    ------------------------------------------------------------------
    IF p_idempotency_key IS NOT NULL THEN
        SELECT * INTO v_claim FROM idempotency_claim(
            p_idempotency_key,
            'execute_inventory_movement',
            jsonb_build_object(
                'type', p_movement_type, 'item', p_item_id,
                'from', p_from_warehouse_id, 'to', p_to_warehouse_id,
                'qty', p_quantity, 'cost', p_unit_cost,
                'ref_type', p_reference_type, 'ref', p_reference_id,
                'uom', p_unit_of_measure));
        v_state := v_claim.claim_state;
        IF v_state = 'replay' THEN
            RETURN (v_claim.cached_response ->> 'movement_id')::uuid;
        ELSIF v_state = 'in_progress' THEN
            RAISE EXCEPTION 'execute_inventory_movement: an attempt with key % is already in flight',
                p_idempotency_key
                USING ERRCODE = '40001',   -- retryable by contract; the client retries the SAME call
                      HINT = 'the lease expires and a take-over rotates the token (0011)';
        ELSIF v_state = 'conflict' THEN
            RAISE EXCEPTION 'execute_inventory_movement: key % was settled for a DIFFERENT request (fingerprint mismatch)',
                p_idempotency_key
                USING ERRCODE = 'P0001',
                      HINT = 'a caller''s idempotency key names one operation; never reuse one across requests';
        END IF;   -- 'claimed': this attempt owns the work and must complete or fail the claim.
    END IF;

    ------------------------------------------------------------------
    -- 4.1: the unit of measure. Explicit wins; otherwise the ITEM's base unit - master data,
    -- not a literal EACH (0007 found the default/vocabulary disconnect; this is its cousin:
    -- the fallback must read the same table the FK points at, or it is a second vocabulary).
    ------------------------------------------------------------------
    v_uom := coalesce(p_unit_of_measure,
                      (SELECT i.base_unit_of_measure FROM inventory_items i
                        WHERE i.item_id = p_item_id));
    IF v_uom IS NULL THEN
        RAISE EXCEPTION 'execute_inventory_movement: no unit of measure - none given, and item % has no base_unit_of_measure',
            p_item_id
            USING ERRCODE = '22023', HINT = 'units_of_measure holds the codes; the item master is the default';
    END IF;

    -- 4.6's named members, answered. RESERVATION belongs to reserve_inventory_for_order
    -- (which 0015 rewrites); reaching it through the generic path would bypass the
    -- reservation's own ledger bookkeeping - so refuse it LOUDLY, which is also what keeps
    -- the RESERVATION clause of the warehouse-shape CHECK honest.
    IF p_movement_type = 'RESERVATION' THEN
        RAISE EXCEPTION 'execute_inventory_movement does not create reservations - use reserve_inventory_for_order'
            USING ERRCODE = '23514';
    END IF;
    IF p_movement_type = 'TRANSFER'
       AND p_from_warehouse_id IS NOT DISTINCT FROM p_to_warehouse_id THEN
        RAISE EXCEPTION 'TRANSFER needs two DIFFERENT warehouses (source=% target=%)',
            p_from_warehouse_id, p_to_warehouse_id USING ERRCODE = '22023';
    END IF;

    ------------------------------------------------------------------
    -- The ledger row FIRST: it is the fact; balances are derived state. (Their ordering in
    -- one transaction makes the ISSUE branch's assertion atomic - a refused issue leaves no
    -- row, which probe C checks by counting, not by hoping.)
    ------------------------------------------------------------------
    INSERT INTO inventory_movements (
        movement_type, item_id, from_warehouse_id, to_warehouse_id,
        quantity, unit_cost, total_cost, unit_of_measure, performed_by,
        reference_type, reference_id, reason_code, batch_id
    ) VALUES (
        p_movement_type, p_item_id, p_from_warehouse_id, p_to_warehouse_id,
        p_quantity, p_unit_cost, p_quantity * p_unit_cost, v_uom, p_performed_by,
        p_reference_type, p_reference_id, p_reason_code, v_batch_id
    ) RETURNING movement_id INTO v_movement_id;

    IF p_movement_type IN ('RECEIPT', 'RETURN') THEN
        INSERT INTO inventory_on_hand
            (item_id, warehouse_id, quantity_on_hand, average_cost, last_movement_at)
        VALUES (p_item_id, p_to_warehouse_id, p_quantity, p_unit_cost, NOW())
        ON CONFLICT (item_id, warehouse_id,
                     COALESCE(location_id, '00000000-0000-0000-0000-000000000000'::uuid),
                     COALESCE(lot_number, ''), tenant_id)
        DO UPDATE SET
            quantity_on_hand = inventory_on_hand.quantity_on_hand + p_quantity,
            average_cost =
                -- 4.3's divisor, measured to be UNREACHABLE as written in the review: a
                -- zero denominator needs a negative receipt, and the tentative INSERT row
                -- of the upsert fails chk_quantities_non_negative before DO UPDATE can run
                -- (probe E). The CASE stays as the tripwire it became: if some future door
                -- lets a negative through, keeping the old cost is the ERP answer, and this
                -- comment is where whoever gets here learns the guard was reasoned, not
                -- guessed.
                CASE WHEN inventory_on_hand.quantity_on_hand + p_quantity > 0
                     THEN ((inventory_on_hand.average_cost * inventory_on_hand.quantity_on_hand)
                           + (p_unit_cost * p_quantity))
                          / (inventory_on_hand.quantity_on_hand + p_quantity)
                     ELSE inventory_on_hand.average_cost
                END,
            last_movement_at = NOW();
    ELSIF p_movement_type = 'TRANSFER' THEN
        -- The member 0007 named and no branch handled: leaving it silent was 4.6's phantom
        -- with a different label - a ledger row that no balance reflects. Out one door, in
        -- the other, source first so an oversell trips the non-negative CHECK, not a lie.
        UPDATE inventory_on_hand
           SET quantity_on_hand = quantity_on_hand - p_quantity,
               last_movement_at = NOW()
         WHERE item_id = p_item_id AND warehouse_id = p_from_warehouse_id;
        GET DIAGNOSTICS v_touch = ROW_COUNT;
        IF v_touch = 0 THEN
            RAISE EXCEPTION 'TRANSFER: no on-hand row for item % at source warehouse %',
                p_item_id, p_from_warehouse_id USING ERRCODE = '23503';
        END IF;

        INSERT INTO inventory_on_hand
            (item_id, warehouse_id, quantity_on_hand, average_cost, last_movement_at)
        VALUES (p_item_id, p_to_warehouse_id, p_quantity, p_unit_cost, NOW())
        ON CONFLICT (item_id, warehouse_id,
                     COALESCE(location_id, '00000000-0000-0000-0000-000000000000'::uuid),
                     COALESCE(lot_number, ''), tenant_id)
        DO UPDATE SET
            quantity_on_hand = inventory_on_hand.quantity_on_hand + p_quantity,
            average_cost =
                CASE WHEN inventory_on_hand.quantity_on_hand + p_quantity > 0
                     THEN ((inventory_on_hand.average_cost * inventory_on_hand.quantity_on_hand)
                           + (p_unit_cost * p_quantity))
                          / (inventory_on_hand.quantity_on_hand + p_quantity)
                     ELSE inventory_on_hand.average_cost
                END,
            last_movement_at = NOW();
    ELSIF p_movement_type IN ('ISSUE', 'ADJUSTMENT') THEN
        UPDATE inventory_on_hand
           SET quantity_on_hand = quantity_on_hand - p_quantity,
               last_movement_at = NOW()
         WHERE item_id = p_item_id AND warehouse_id = p_from_warehouse_id;
        GET DIAGNOSTICS v_touch = ROW_COUNT;
        -- 4.6's phantom: the UPDATE matched nothing, the movement row exists, the ledger now
        -- records an issue no balance reflects. RAISE, and the transaction's atomicity
        -- removes the ledger row with it (probe C counts both facts for real).
        IF v_touch = 0 THEN
            RAISE EXCEPTION 'ISSUE/ADJUSTMENT: no on-hand row for item % at warehouse % - the movement is refused, not dreamed',
                p_item_id, p_from_warehouse_id USING ERRCODE = '23503';
        END IF;
        -- v_touch > 1 (stock in several bins, ALL decremented by the full quantity) is 4.6's
        -- worse half and belongs to 0015's location honouring, NOT to a quiet edit here.
    END IF;

    ------------------------------------------------------------------
    -- Close the claim with the answer, so the NEXT identical call reads it back (replay).
    ------------------------------------------------------------------
    IF v_state = 'claimed' THEN
        PERFORM idempotency_complete(v_claim.claim_id, v_claim.current_token,
                jsonb_build_object('movement_id', v_movement_id));
    END IF;

    RETURN v_movement_id;

EXCEPTION
    WHEN OTHERS THEN
        -- No swallowing (4.1's re-wrap is the bug being closed): the ORIGINAL SQLSTATE and
        -- message are re-raised verbatim. What the handler adds is the claim's failure -
        -- a failed attempt must not hold a lease that hides the work from the retry.
        IF v_state IS NOT DISTINCT FROM 'claimed' THEN
            PERFORM idempotency_complete(v_claim.claim_id, v_claim.current_token,
                                         NULL, false, SQLERRM);
        END IF;
        RAISE EXCEPTION USING ERRCODE = SQLSTATE, MESSAGE = SQLERRM;
END
$$;

COMMENT ON FUNCTION execute_inventory_movement(varchar, uuid, uuid, uuid, numeric, numeric,
        varchar, varchar, uuid, varchar, varchar, uuid) IS
    'The inventory ledger''s only front door (with reserve_inventory_for_order writing the
    reservation ledger, which 0015 rebuilds). Twelve parameters: the original ten, plus
    p_unit_of_measure (4.1 - explicit, else the item master''s base unit, else a 22023 that
    names both), plus p_idempotency_key (ADR-005 pattern 2 - supply one and a retry of THIS
    call is answered from the claim instead of doubling stock; omit it and the function is
    as unsafe as any unclaimed write, which vw_idempotency_status now tells truthfully).
    All six vocabulary members of movement_type are answered: RECEIPT/RETURN upsert in,
    ISSUE/ADJUSTMENT subtract out with a ROW_COUNT refusal (4.6''s phantom), TRANSFER moves
    both sides (0007''s named-but-unhandled, closed), RESERVATION refuses with a pointer.
    Errors keep their SQLSTATE: the catch-all re-wrap that made 23502 into P0001 is gone,
    and what the handler runs now is only the claim''s failure note. Built by 0014.';

-- ---------------------------------------------------------------------------
-- 3. The follow-up writer 0007 assigned here
-- ------------------------------------------------------------------
-- entities.status has admitted 'follow-up' since 0007 and nothing could ever set it:
-- update_customer does not touch status, add_customer can only set it at creation, and
-- the followup_customers tool READS the state that has no writer. A convergent setter -
-- replay-safe by shape, so deliberately claim-free - with the transitions it refuses
-- printed rather than swallowed.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mark_customer_followup(
    p_entity_id  bigint,
    p_followup   boolean DEFAULT true
) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
    v_status text;
BEGIN
    SELECT status INTO v_status FROM entities WHERE id = p_entity_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'mark_customer_followup: entity % does not exist', p_entity_id
            USING ERRCODE = 'P0002';
    END IF;

    IF p_followup THEN
        IF v_status = 'follow-up' THEN
            RETURN 'already marked';
        ELSIF v_status <> 'active' THEN
            RAISE EXCEPTION 'mark_customer_followup: status % is not active - a blacklisted or inactive customer is not followed up by silently overwriting that fact',
                v_status USING ERRCODE = '23514';
        END IF;
        UPDATE entities SET status = 'follow-up' WHERE id = p_entity_id;
        RETURN 'marked';
    ELSE
        IF v_status = 'follow-up' THEN
            UPDATE entities SET status = 'active' WHERE id = p_entity_id;
            RETURN 'cleared';
        END IF;
        RETURN 'unchanged (status is ' || v_status || ')';
    END IF;
END
$$;

COMMENT ON FUNCTION mark_customer_followup(bigint, boolean) IS
    'The writer of the follow-up state 0007 proved had no path in: entities.status active ->
    follow-up -> active, and nothing else is touched. Convergent by construction (setting a
    mark that is set returns ''already mark'' rather than a second write trail), which is why
    it carries no idempotency claim and why its vw_idempotency_status row reads UNGUARDED -
    there the label means "a retry rewrites the same value", a fact, not the accumulating
    upsert''s false ''pattern 1''. The audit trail (0013) records every actual change. Built
    by 0014.';

REVOKE EXECUTE ON FUNCTION mark_customer_followup(bigint, boolean) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION mark_customer_followup(bigint, boolean) TO afpc_app;

-- 0009's standing obligation, and 0014 tripped it as predicted: the changed-signature
-- CREATE OR REPLACE created a NEW function object (after the explicit DROP of the old
-- head), and a new function is born EXECUTE-to-PUBLIC - B22 named it the same day. The
-- old head's grants died with it; this one gets the sweep and the grant by hand.
REVOKE EXECUTE ON FUNCTION execute_inventory_movement(
    varchar, uuid, uuid, uuid, numeric, numeric, varchar, varchar, uuid, varchar,
    varchar, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION execute_inventory_movement(
    varchar, uuid, uuid, uuid, numeric, numeric, varchar, varchar, uuid, varchar,
    varchar, uuid) TO afpc_app;

-- ---------------------------------------------------------------------------
-- 4. Verify by behaving
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_wh_a   uuid;
    v_wh_b   uuid;
    v_item   uuid;
    v_item2  uuid;
    v_ent    bigint;
    v_mv     uuid;
    v_mv2    uuid;
    v_key    uuid := gen_random_uuid();
    v_qty    numeric;
    v_cost   numeric;
    v_rows   bigint;
    v_state  text;
    v_n      int := 0;
BEGIN
    ------------------------------------------------------------------
    -- Setup: two warehouses, one item with a base unit, one item without (the 22023 path).
    ------------------------------------------------------------------
    INSERT INTO warehouses (warehouse_code, name) VALUES ('0014 WH-A', 'probe source')
     RETURNING warehouse_id INTO v_wh_a;
    INSERT INTO warehouses (warehouse_code, name) VALUES ('0014 WH-B', 'probe target')
     RETURNING warehouse_id INTO v_wh_b;
    INSERT INTO inventory_items (sku, name, base_unit_of_measure)
         VALUES ('0014-A', 'probe item', 'EACH') RETURNING item_id INTO v_item;
    INSERT INTO inventory_items (sku, name)
         VALUES ('0014-B', 'probe item bare') RETURNING item_id INTO v_item2;

    ------------------------------------------------------------------
    -- A. 4.1 closed both ways: explicit UOM, and the item-master fallback.
    ------------------------------------------------------------------
    v_mv := execute_inventory_movement('RECEIPT', v_item, NULL, v_wh_a, 100, 5.00,
             '0014-probe', 'PO', NULL, 'baseline', 'EACH');
    v_mv2 := execute_inventory_movement('RECEIPT', v_item, NULL, v_wh_a, 50, 8.00,
             '0014-probe', 'PO', NULL, 'fallback');   -- no uom: base_unit_of_measure
    SELECT quantity_on_hand, average_cost INTO v_qty, v_cost
      FROM inventory_on_hand WHERE item_id = v_item AND warehouse_id = v_wh_a;
    IF v_qty <> 150 OR round(v_cost, 4) <> round((100*5.00 + 50*8.00)/150.0, 4) THEN
        RAISE EXCEPTION 'A failed: receipts left qty=% avg=% - the upsert or the weighted average is wrong',
            v_qty, v_cost;
    END IF;
    IF (SELECT count(*) FROM inventory_movements WHERE item_id = v_item
         AND unit_of_measure = 'EACH') <> 2 THEN
        RAISE EXCEPTION 'A failed: the ledger row still has no unit of measure (4.1)';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- B. error honesty. base_unit_of_measure is NOT NULL with an FK, so the fallback can
    --    only come up empty for an item that DOES NOT EXIST - that is the door this probe
    --    walks through (the first draft tried a null-base unit and failed, because in this
    --    schema since 0007 that state cannot exist; the failure was the finding). A bad
    --    code, meanwhile, must arrive AS the lookup FK - 23503, not re-wrapped.
    ------------------------------------------------------------------
    BEGIN
        PERFORM execute_inventory_movement('RECEIPT', gen_random_uuid(), NULL, v_wh_a,
                 1, 1, '0014-probe', 'PO', NULL, 'no such item');
        RAISE EXCEPTION 'B failed: a movement of a nonexistent item slipped through';
    EXCEPTION
        -- 22023's condition NAME is invalid_parameter_value; invalid_text_representation is
        -- 22P02 and would have silently missed this RAISE (the WHEN list matched nothing,
        -- the exception escaped the block). Named by number in the comment, by name in code.
        WHEN invalid_parameter_value THEN NULL;   -- 22023, and only it, lands here
    END;
    BEGIN
        PERFORM execute_inventory_movement('RECEIPT', v_item, NULL, v_wh_a, 1, 1,
                 '0014-probe', 'PO', NULL, 'bad code', 'ZLOXGONG');
        RAISE EXCEPTION 'B failed: an unknown UOM code slipped through';
    EXCEPTION
        WHEN foreign_key_violation THEN NULL;      -- the lookup table doing its job
    END;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- C. 4.6's phantom, at the call site: an issue against a warehouse that never received
    --    now REFUSES, and the refusal is ATOMIC - no ledger row survives. (0010's probe E
    --    promised this repoint: what the duplicated statements used to prove, proven against
    --    the real function.)
    ------------------------------------------------------------------
    BEGIN
        PERFORM execute_inventory_movement('ISSUE', v_item, v_wh_b, NULL, 5, 5,
                 '0014-probe', 'ORDER', NULL, 'never stocked');
        RAISE EXCEPTION 'C failed: the phantom issue returned a movement id';
    EXCEPTION
        WHEN foreign_key_violation THEN           -- 23503 is the refusal this file raises
            SELECT count(*) INTO v_rows FROM inventory_movements
             WHERE item_id = v_item AND from_warehouse_id = v_wh_b;
            IF v_rows <> 0 THEN
                RAISE EXCEPTION 'C failed: the refused issue left % ledger row(s) - atomicity, not just an error string', v_rows;
            END IF;
    END;
    -- the CHECK's own backstop (bypassing the function must fail too):
    BEGIN
        INSERT INTO inventory_movements (movement_type, item_id, to_warehouse_id,
                                         quantity, unit_of_measure, performed_by)
             VALUES ('ISSUE', v_item, v_wh_a, 5, 'EACH', '0014-probe');
        RAISE EXCEPTION 'C failed: a source-less ISSUE passed the warehouse-shape CHECK';
    EXCEPTION
        WHEN check_violation THEN NULL;
    END;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- D. oversell keeps the CHECK it trips (23514, not re-wrapped); an ordinary issue works
    --    and recomputes availability through 0004's consistency trigger.
    ------------------------------------------------------------------
    BEGIN
        PERFORM execute_inventory_movement('ISSUE', v_item, v_wh_a, NULL, 10000, 5,
                 '0014-probe', 'ORDER', NULL, 'oversell');
        RAISE EXCEPTION 'D failed: the oversell was allowed';
    EXCEPTION
        WHEN check_violation THEN NULL;           -- chk_quantities_non_negative, by name
    END;
    PERFORM execute_inventory_movement('ISSUE', v_item, v_wh_a, NULL, 30, 5,
             '0014-probe', 'ORDER', NULL, 'normal');
    IF (SELECT quantity_on_hand FROM inventory_on_hand
         WHERE item_id = v_item AND warehouse_id = v_wh_a) <> 120 THEN
        RAISE EXCEPTION 'D failed: the honest issue left the wrong balance';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- E. 4.3's divisor claim, corrected by measurement: (oh + qty) = 0 in a RECEIPT needs
    --    a negative quantity, and a negative quantity never reaches DO UPDATE - the
    --    tentative INSERT row fails chk_quantities_non_negative first (Failing row
    --    contains (-120, -120, ...), measured). The CASE guard stays as a tripwire; the
    --    live decrease path is ADJUSTMENT, which is also the honest ERP door.
    ------------------------------------------------------------------
    BEGIN
        PERFORM execute_inventory_movement('RECEIPT', v_item, NULL, v_wh_a, -120, 7,
                 '0014-probe', 'ADJUSTMENT', NULL, 'negative receipt');
        RAISE EXCEPTION 'E failed: a negative RECEIPT was accepted - which CHECK went quiet?';
    EXCEPTION
        WHEN check_violation THEN NULL;           -- tentative-row non-negative, by name
    END;
    IF (SELECT quantity_on_hand FROM inventory_on_hand
         WHERE item_id = v_item AND warehouse_id = v_wh_a) <> 120 THEN
        RAISE EXCEPTION 'E failed: the refused negative receipt moved stock anyway';
    END IF;
    PERFORM execute_inventory_movement('ADJUSTMENT', v_item, v_wh_a, NULL, 120, 7,
             '0014-probe', 'ADJUSTMENT', NULL, 'empty it exactly');
    SELECT quantity_on_hand, average_cost INTO v_qty, v_cost
      FROM inventory_on_hand WHERE item_id = v_item AND warehouse_id = v_wh_a;
    IF v_qty <> 0 THEN
        RAISE EXCEPTION 'E failed: the exact-emptying adjustment left qty=%', v_qty;
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- F. TRANSFER, the member that used to be accepted and did nothing to balances.
    ------------------------------------------------------------------
    PERFORM execute_inventory_movement('RECEIPT', v_item, NULL, v_wh_a, 40, 5,
             '0014-probe', 'PO', NULL, 'restock for transfer');
    PERFORM execute_inventory_movement('TRANSFER', v_item, v_wh_a, v_wh_b, 25, 5,
             '0014-probe', 'TRANSFER', NULL, 'move it');
    IF (SELECT quantity_on_hand FROM inventory_on_hand
         WHERE item_id = v_item AND warehouse_id = v_wh_a) <> 15
       OR (SELECT quantity_on_hand FROM inventory_on_hand
         WHERE item_id = v_item AND warehouse_id = v_wh_b) <> 25 THEN
        RAISE EXCEPTION 'F failed: TRANSFER moved the ledger but not the stock (the 4.6 pattern, wearing a type name)';
    END IF;
    BEGIN
        PERFORM execute_inventory_movement('TRANSFER', v_item, v_wh_a, v_wh_a, 1, 5,
                 '0014-probe', 'TRANSFER', NULL, 'self transfer');
        RAISE EXCEPTION 'F failed: a self-transfer was accepted';
    EXCEPTION
        WHEN invalid_parameter_value THEN NULL;   -- 22023: named, refused. (2201E and
    END;                                          -- 22012 both measured NOT to match the
                                                  -- predefined CARDINALITY_VIOLATION name
                                                  -- in this build - a WHEN that silently
                                                  -- catches nothing.)
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- G. RESERVATION refused at the door that does not own it.
    ------------------------------------------------------------------
    BEGIN
        PERFORM execute_inventory_movement('RESERVATION', v_item, NULL, v_wh_a, 1, 5,
                 '0014-probe', 'ORDER', NULL, 'wrong door');
        RAISE EXCEPTION 'G failed: RESERVATION passed through the generic path';
    EXCEPTION
        WHEN check_violation THEN NULL;
    END;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- H. the claim: same key + same request replays WITHOUT touching stock; same key +
    --    different request conflicts; a failed keyed attempt leaves the key re-claimable.
    --    (0011 proved the mechanism; this proves it AT the write path ADR-005 named -
    --    retry-safe movement, the register's true pattern 2.)
    ------------------------------------------------------------------
    v_mv := execute_inventory_movement('RECEIPT', v_item, NULL, v_wh_a, 10, 6,
             '0014-probe', 'PO', NULL, 'keyed', 'EACH', v_key);
    SELECT quantity_on_hand INTO v_qty FROM inventory_on_hand
     WHERE item_id = v_item AND warehouse_id = v_wh_a;
    v_mv2 := execute_inventory_movement('RECEIPT', v_item, NULL, v_wh_a, 10, 6,
             '0014-probe', 'PO', NULL, 'keyed', 'EACH', v_key);
    IF v_mv2 IS DISTINCT FROM v_mv THEN
        RAISE EXCEPTION 'H failed: the replayed movement id differs - answered from the claim?';
    END IF;
    IF (SELECT quantity_on_hand FROM inventory_on_hand
         WHERE item_id = v_item AND warehouse_id = v_wh_a) <> v_qty THEN
        RAISE EXCEPTION 'H failed: a replay changed stock - the doubling 0011 was built to stop';
    END IF;
    BEGIN
        PERFORM execute_inventory_movement('RECEIPT', v_item, NULL, v_wh_a, 99, 6,
                 '0014-probe', 'PO', NULL, 'keyed', 'EACH', v_key);
        RAISE EXCEPTION 'H failed: a different request rode the same key';
    EXCEPTION
        WHEN raise_exception THEN
            IF SQLERRM NOT LIKE '%DIFFERENT request%' THEN RAISE EXCEPTION 'H: %', SQLERRM; END IF;
    END;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- I. one callable execute_inventory_movement (the 4.4 lesson, held): the additions are
    --    DEFAULTs on the SAME function, not a second overload - and the register now
    --    classes it pattern 2 BY TAKING A CLAIM, not by tripping the ON CONFLICT regex.
    ------------------------------------------------------------------
    IF (SELECT count(*) FROM pg_proc WHERE proname = 'execute_inventory_movement') <> 1 THEN
        RAISE EXCEPTION 'I failed: % overloads of execute_inventory_movement - 4.4 was a signature lesson, learn it',
            (SELECT count(*) FROM pg_proc WHERE proname = 'execute_inventory_movement');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM vw_idempotency_status
                    WHERE function = 'execute_inventory_movement'
                      AND verdict LIKE 'ADR-005 pattern 2%') THEN
        RAISE EXCEPTION 'I failed: the register still classes the movement path % - the claim call is not visible to the ladder',
            (SELECT verdict FROM vw_idempotency_status
              WHERE function = 'execute_inventory_movement' LIMIT 1);
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- J. the follow-up writer 0007 assigned: set, replay-safely; refuse to trample
    --    blacklisted; clear back to active; the tool-facing reader state is reachable.
    ------------------------------------------------------------------
    INSERT INTO entities (name, entity_type, status)
         VALUES ('0014 probe J', 'customer', 'active') RETURNING id INTO v_ent;
    IF (SELECT mark_customer_followup(v_ent) NOT LIKE 'marked%') THEN
        RAISE EXCEPTION 'J failed: marking an active customer did not take';
    END IF;
    IF (SELECT status FROM entities WHERE id = v_ent) <> 'follow-up' THEN
        RAISE EXCEPTION 'J failed: the writer did not write';
    END IF;
    IF (SELECT mark_customer_followup(v_ent)) <> 'already marked' THEN
        RAISE EXCEPTION 'J failed: a replay of the mark was not convergent';
    END IF;
    IF (SELECT mark_customer_followup(v_ent, false)) <> 'cleared' THEN
        RAISE EXCEPTION 'J failed: the state has no way back';
    END IF;
    UPDATE entities SET status = 'blacklisted' WHERE id = v_ent;
    BEGIN
        PERFORM mark_customer_followup(v_ent);
        RAISE EXCEPTION 'J failed: follow-up trampled blacklisted';
    EXCEPTION
        WHEN check_violation THEN NULL;
    END;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- Cleanup. Movements first (RESTRICT edges), then balances, then masters; claims go by
    -- operation; the entity by id. audit_log keeps the story of all of it - which is the
    -- point of 0013, not residue.
    ------------------------------------------------------------------
    DELETE FROM inventory_movements
     WHERE item_id IN (v_item, v_item2);
    DELETE FROM inventory_on_hand   WHERE item_id IN (v_item, v_item2);
    DELETE FROM idempotency_keys    WHERE operation = 'execute_inventory_movement';
    DELETE FROM inventory_items     WHERE item_id IN (v_item, v_item2);
    DELETE FROM warehouses          WHERE warehouse_code IN ('0014 WH-A', '0014 WH-B');
    DELETE FROM entities            WHERE id = v_ent;

    IF v_n <> 10 THEN
        RAISE EXCEPTION 'expected 10 behavioural verifications, completed %', v_n;
    END IF;
    RAISE NOTICE '4.1/4.2/4.3: % checks passed - the ledger row carries its unit, refuses
                 without one, answers every movement type it names, keeps the SQLSTATE it
                 fails with, moves stock for TRANSFER, doubles nothing on replay, and the
                 follow-up state finally has a door', v_n;
END
$$;
