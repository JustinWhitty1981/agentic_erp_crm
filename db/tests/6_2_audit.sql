-- Finding 6.2, observed as behaviour: a trail an agent's ordinary writes actually feed,
-- history that the writing seat cannot alter, and a chain that says so.
--
-- The four mapped phrases each print from the existence guard (audit_log absent - the
-- pre-0013 state, where they reproduce exactly as 6.2 measured them) and from a post-fix
-- failure branch (where they mean the mechanism regressed). Two properties cannot be
-- checked statically and are why this file exists at all: an UPDATE's audit row must
-- contain EXACTLY the changed columns (0013's probe B does that claim at migration time;
-- here the cheaper count claim repeats it), and the append-only promise must bind the seat
-- that writes the table daily - afpc_app - not merely the ACL's prose.
--
-- Everything writes inside a transaction that rolls back. The trail rolls back with it,
-- which is itself a fact worth knowing: audit_log rows exist exactly as long as the
-- transactions they describe, and the chain's order is commit order, not attempt order.

-- The census half: does every in-scope table have its trigger, and is the exemption list
-- still the two named cases? (Catalog claim; no volume would make it more true.)
DO $$
DECLARE
    v_rows int;
    v_list text;
BEGIN
    IF to_regclass('public.audit_log') IS NULL THEN
        RAISE NOTICE 'VERDICT ERR ordinary writes leave no trail - the schema has no '
                     'row-level audit table at all (6.2, 0013)';
        RAISE NOTICE 'VERDICT ERR the audit chain does not verify because there is no chain '
                     '(6.2, 0013)';
        RAISE NOTICE 'VERDICT ERR audit history accepted a rewrite by default: there is no '
                     'history to protect (6.2, 0013)';
        RAISE NOTICE 'VERDICT ERR a tenant-coded table is untrailed - every one of them is, '
                     'pre-0013 (6.2)';
        RETURN;
    END IF;

    SELECT count(*), coalesce(string_agg(table_name, ', '), '-')
      INTO v_rows, v_list
      FROM vw_audit_coverage
     WHERE row_audited IS DISTINCT FROM (NOT exempted);
    IF v_rows = 0 THEN
        RAISE NOTICE 'VERDICT OK the audited flag and the exemption register agree on every '
                     'tenant-coded table';
    ELSE
        RAISE NOTICE 'VERDICT ERR a tenant-coded table is untrailed, or an exempted one is '
                     'trailed anyway (6.2): %', v_list;
    END IF;
END
$$;

-- The behaviour half, in the seat that matters.
BEGIN;
DO $$
DECLARE
    v_ent  bigint;
    v_rows bigint;
    v_ok   boolean;
BEGIN
    IF to_regclass('public.audit_log') IS NULL THEN
        RAISE NOTICE 'VERDICT INFO behaviour half skipped: the guard block above has '
                     'already stated the finding as measured (no audit_log yet)';
        RETURN;   -- nothing has been written; the file's ROLLBACK closes the transaction
    END IF;
    SET LOCAL ROLE afpc_app;

    INSERT INTO entities (name, entity_type) VALUES ('6.2 probe', 'customer')
     RETURNING id INTO v_ent;
    UPDATE entities SET status = 'inactive' WHERE id = v_ent;
    DELETE FROM entities WHERE id = v_ent;

    SELECT count(*) INTO v_rows FROM audit_log
     WHERE table_name = 'entities' AND row_pk->>'id' = v_ent::text;
    IF v_rows >= 3 THEN
        RAISE NOTICE 'VERDICT OK the insert, update and delete each left a trail row (%)',
            v_rows;
    ELSE
        RAISE NOTICE 'VERDICT ERR ordinary writes leave no trail: three DML statements '
                     'produced % audit rows (6.2)', v_rows;
    END IF;

    -- The claim 2.6 makes and only a behaviour test can prove: the role that writes the
    -- history every minute cannot alter it. A successful UPDATE here means some future
    -- migration re-widened the grant (B27 watches the ACL; this watches the truth).
    BEGIN
        UPDATE audit_log SET action = 'INSERT'
         WHERE table_name = 'entities' AND row_pk->>'id' = v_ent::text
           AND action = 'DELETE';
        RAISE NOTICE 'VERDICT ERR audit history accepted a rewrite from the application '
                     'seat (6.2): append-only by grant is not in effect';
    EXCEPTION
        WHEN insufficient_privilege THEN
            RAISE NOTICE 'VERDICT OK the write seat cannot alter the history it writes';
    END;

    -- And the chain as this role can actually see it: one segment per tenant-month, all
    -- verifying. NULL is a failure here, not a pass - bool_and over no segments would mean
    -- an invisible history, which is what 0009 taught about seats and controls.
    SELECT bool_and(chain_ok) INTO v_ok FROM audit_chain_verify();
    IF v_ok IS TRUE THEN
        RAISE NOTICE 'VERDICT OK the chain verifies from inside the seat that writes it';
    ELSE
        RAISE NOTICE 'VERDICT ERR the audit chain does not verify for the segments this '
                     'seat can see (6.2): history has been altered since it was written';
    END IF;
END
$$;
ROLLBACK;
