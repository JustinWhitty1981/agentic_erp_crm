-- Finding 4.4: add_customer is ambiguous and cannot be called with defaulted
-- arguments. Two overloads exist (10 and 14 arguments) and in the 14-argument form
-- every parameter has a default, so Postgres cannot prefer one by exclusion.
--
-- Measured on this server, which narrows the review:
--   * 14 positional arguments resolves and INSERTS correctly (see 4a) - so the
--     blueprint tool's arity and its result unpacking are both right, contrary to
--     the "wrong arity / different shape" reading in 4.5;
--   * 10 and 4 positional arguments are both ambiguous (42725), because each
--     candidate accepts the same number of argument positions.
-- The fix is therefore one overload, not four.
--
-- Wrapped in a transaction: an earlier revision of this file was not, and its
-- successful call committed a real customer into the persistent development
-- database. That is the hazard this harness exists to catch.
BEGIN;

-- 4a. The call blueprint/tools/add_customer.py issues: 14 positional arguments,
-- unpacked into success, entity_id, contact_id, message.
DO $$
DECLARE r record;
BEGIN
    FOR r IN SELECT * FROM add_customer(
        'Ada', 'Lovelace', 'ada@example.invalid', '+15550100', '1 Analytical Way',
        'London', NULL, NULL, 'US', 'active', 'individual', NULL, 'home', true)
    LOOP
        RAISE NOTICE 'VERDICT OK 14-argument call resolved: success=% entity=% contact=% msg=%',
            r.success, r.entity_id, r.contact_id, left(r.message, 40);
    END LOOP;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'VERDICT ERR % | %', SQLSTATE, left(SQLERRM, 110);
END
$$;

-- 4b. Ten positional arguments: both candidates accept 10 positions, so neither wins.
DO $$
BEGIN
    PERFORM * FROM add_customer('Ada', 'Lovelace', 'ada10@example.invalid', '+15550100',
        '1 Analytical Way', 'London', NULL, NULL, 'US', 'active');
    RAISE NOTICE 'VERDICT OK 10-argument call resolved';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'VERDICT ERR % | 10-argument call: %', SQLSTATE, left(SQLERRM, 90);
END
$$;

-- 4c. A short call: same failure.
DO $$
BEGIN
    PERFORM * FROM add_customer('Ada', 'Lovelace', 'ada4@example.invalid', '+15550100');
    RAISE NOTICE 'VERDICT OK 4-argument call resolved';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'VERDICT ERR % | 4-argument call: %', SQLSTATE, left(SQLERRM, 90);
END
$$;

-- 4c. The catalog view of the same problem: how many candidates each arity has.
DO $$
DECLARE
    n int;
BEGIN
    SELECT count(*) INTO n FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
     WHERE ns.nspname = 'public' AND p.proname = 'add_customer';
    IF n > 1 THEN
        RAISE NOTICE 'VERDICT ERR 00000 | % overloads of add_customer are installed', n;
    ELSE
        RAISE NOTICE 'VERDICT OK single overload';
    END IF;
END
$$;
ROLLBACK;
