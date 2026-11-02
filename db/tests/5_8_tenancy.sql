-- Finding 5.8: tenancy was absent, not thin. The review's concrete symptom:
-- "Uniqueness is global, so a second customer cannot reuse warehouse code MAIN."
-- This case builds that situation with two real tenants and asserts the outcome.
--
-- Before 0003 there is no tenant_id column anywhere, so the cross-tenant insert cannot
-- even be attempted and the case reports the finding. After 0003 both rows exist,
-- because warehouse_code is unique per tenant rather than per database.
--
-- The remaining blocks test the safety of the resolution path, which is what an agent
-- hits on every write: the column default is afpc_current_tenant(), reading
-- app.tenant_id with a deployment-level app.default_tenant_id behind it.
--
-- GUC mechanics this relies on, both measured rather than assumed:
--   * a custom GUC that has been RESET or set to empty reads as '', not NULL, so the
--     helper has to normalise both forms of unset;
--   * RESET does not reliably remove a database-level value from pg_settings, so these
--     blocks use set_config(..., false) to override it at session level and restore the
--     recorded value afterwards.

-- 8a. The review's scenario, plus the half that must not regress.
BEGIN;
DO $$
DECLARE
    v_t1 uuid := '00000000-0000-0000-0000-000000000001';
    v_t2 uuid;
    v_has boolean;
BEGIN
    SELECT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'public' AND table_name = 'warehouses'
                      AND column_name = 'tenant_id') INTO v_has;
    IF NOT v_has THEN
        RAISE NOTICE 'VERDICT ERR 00000 | warehouses has no tenant_id column, so a second '
                     'tenant cannot exist at all';
        RETURN;
    END IF;

    -- The tenant registry must be insertable without naming a key: a tenant row is
    -- created by an onboarding flow, which has no tenant context yet to resolve one.
    IF (SELECT column_default IS NULL FROM information_schema.columns
         WHERE table_schema = 'public' AND table_name = 'tenants'
           AND column_name = 'tenant_id') THEN
        RAISE NOTICE 'VERDICT ERR 00000 | tenants.tenant_id has no default, so the first '
                     'tenant of a new deployment cannot be inserted';
    END IF;

    INSERT INTO tenants (slug, name) VALUES ('second-tenant', 'Second Tenant')
        RETURNING tenant_id INTO v_t2;

    PERFORM set_config('app.tenant_id', v_t1::text, false);
    INSERT INTO warehouses (warehouse_code, name) VALUES ('MAIN', 'tenant one warehouse');

    PERFORM set_config('app.tenant_id', v_t2::text, false);
    INSERT INTO warehouses (warehouse_code, name) VALUES ('MAIN', 'tenant two warehouse');

    RAISE NOTICE 'VERDICT OK code MAIN accepted by two tenants (% rows, % distinct tenants)',
        (SELECT count(*) FROM warehouses WHERE warehouse_code = 'MAIN'),
        (SELECT count(DISTINCT tenant_id) FROM warehouses WHERE warehouse_code = 'MAIN');

    BEGIN
        INSERT INTO warehouses (warehouse_code, name) VALUES ('MAIN', 'duplicate within tenant two');
        RAISE NOTICE 'VERDICT ERR 00000 | per-tenant uniqueness did not hold - MAIN stored twice';
    EXCEPTION WHEN unique_violation THEN
        RAISE NOTICE 'VERDICT INFO within one tenant MAIN is still unique (23505, as intended)';
    END;

    PERFORM set_config('app.tenant_id', v_t1::text, false);
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'VERDICT ERR % | %', SQLSTATE, left(SQLERRM, 130);
END
$$;
ROLLBACK;

-- 8b. No tenant context anywhere must fail with an actionable message. This is the
-- property that makes the tenancy column trustworthy: a silent NULL, or a silent guess,
-- is how cross-tenant bugs become invisible.
BEGIN;
DO $$
DECLARE
    v_saved text := current_setting('app.default_tenant_id', true);
BEGIN
    PERFORM set_config('app.tenant_id', NULL, false);
    PERFORM set_config('app.default_tenant_id', '', false);

    BEGIN
        INSERT INTO warehouses (warehouse_code, name) VALUES ('AFPC-NO-TENANT', 'orphan row');
        RAISE NOTICE 'VERDICT ERR 00000 | a tenantless insert succeeded - the fallback '
                     'resolved to a tenant when none was configured';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM ILIKE '%no tenant context%' THEN
            RAISE NOTICE 'VERDICT OK tenantless insert refused with an actionable message';
        ELSE
            RAISE NOTICE 'VERDICT ERR 00000 | refused for a different reason: %',
                left(SQLERRM, 90);
        END IF;
    END;

    PERFORM set_config('app.default_tenant_id', coalesce(v_saved, ''), false);
END
$$;
ROLLBACK;

-- 8c. A malformed tenant id must say so, rather than failing as a cast error from
-- inside a default expression, which is what a naive current_setting(...)::uuid test
-- produces because custom GUCs read as '' when unset.
BEGIN;
DO $$
BEGIN
    PERFORM set_config('app.tenant_id', 'not-a-uuid', false);
    BEGIN
        INSERT INTO warehouses (warehouse_code, name) VALUES ('AFPC-BAD-GUC', 'x');
        RAISE NOTICE 'VERDICT ERR 00000 | a malformed app.tenant_id was accepted';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM ILIKE '%is not a uuid%' THEN
            RAISE NOTICE 'VERDICT OK malformed app.tenant_id named the setting and its value';
        ELSE
            RAISE NOTICE 'VERDICT ERR 00000 | failed, but the message does not name the '
                         'setting: %', left(SQLERRM, 90);
        END IF;
    END;
    PERFORM set_config('app.tenant_id', '00000000-0000-0000-0000-000000000001', false);
END
$$;
ROLLBACK;

-- 8d. Tenancy is real at the row level, not only in the catalog: tenant 1 must not be
-- able to see or overwrite tenant 2's rows through the plain table. This is the
-- assertion that stays red until 0009 adds policies; today it should report that rows
-- are visible across tenants, which is precisely what 0009 exists to fix.
BEGIN;
DO $$
DECLARE
    v_t1   uuid := '00000000-0000-0000-0000-000000000001';
    v_t2   uuid;
    v_see  int;
    v_own  int;
BEGIN
    INSERT INTO tenants (slug, name) VALUES ('rls-tenant', 'RLS Tenant')
        RETURNING tenant_id INTO v_t2;

    PERFORM set_config('app.tenant_id', v_t1::text, false);
    INSERT INTO warehouses (warehouse_code, name) VALUES ('AFPC-RLS-1', 't1');
    PERFORM set_config('app.tenant_id', v_t2::text, false);
    INSERT INTO warehouses (warehouse_code, name) VALUES ('AFPC-RLS-1', 't2');

    PERFORM set_config('app.tenant_id', v_t1::text, false);
    SELECT count(*) INTO v_see FROM warehouses WHERE warehouse_code = 'AFPC-RLS-1';
    -- An UPDATE that touches another tenant's row is the damaging version of the same
    -- hole: reads leak, writes corrupt.
    UPDATE warehouses SET name = 'hijacked'
        WHERE warehouse_code = 'AFPC-RLS-1' AND tenant_id = v_t2;
    GET DIAGNOSTICS v_own = ROW_COUNT;

    IF v_see > 1 OR v_own > 0 THEN
        RAISE NOTICE 'VERDICT ERR 00000 | tenant % sees % rows and changed % outside its '
                     'tenant - no row-level isolation yet (0009)', v_t1, v_see, v_own;
    ELSE
        RAISE NOTICE 'VERDICT OK tenant isolation holds at row level (% visible, % foreign '
                     'rows changed)', v_see, v_own;
    END IF;
END
$$;
ROLLBACK;
