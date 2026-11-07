-- 0031: the keeper this server was told to run, given the privilege to run it with
--       (the sweep's grant; the orders programme's tail, and agents/sales' first hour of evidence)
--
-- WHY THIS FILE EXISTS
--
-- `db/MIGRATIONS.md` records that `idempotency_sweep` has had a policy and no keeper since 0011 wrote
-- the policy: "runs for nobody unless someone schedules it". 0030 collected the 28-row backlog that
-- produced and named the keeper as owed. `agents/sales/` is that keeper - a deterministic hourly tick,
-- `runInventoryCheck`'s shape, whose every run files a trajectory row so that "it ran" stays a query.
--
-- The first tick ran. It reported, truthfully and in the wrong register:
--
--   final_output  : claims swept: 0 expired collected; 4 lines reconciled, none disagreeing; ...
--   error_message : ERROR: permission denied for function idempotency_sweep (SQLSTATE 42501)
--
-- which is the sentence 0011's own decision wrote. 0011 created three functions and granted two of
-- them to `afpc_app`; the third it revoked explicitly, with a comment and an assertion, because in
-- July the only caller in the world was a human with psql:
--
--   -- Not afpc_app: garbage collection is an operator action. It is also safe to leave closed,
--   -- because every row it can delete is one nobody is waiting on.
--
-- That reasoning was sound when it was written and one of its two premises has since gone false.
-- "Operator action" described a fact about who would call it, and there is now a scheduled caller that
-- is not an operator. "Safe to leave closed" was measured against a backlog nobody collected, and the
-- backlog is the thing 0030 had to fix by hand. What the closure bought - an explicit decision that
-- garbage collection is not ambient - is still worth having; what it costs now is a keeper that runs
-- every hour, files an honest failure every hour, and collects nothing.
--
-- THE ARGUMENT FOR WIDENING IT, AND WHY IT IS NARROWER THAN IT SOUNDS
--
-- 0011 also chose SECURITY INVOKER for all three functions, on purpose, and said why: under DEFINER
-- the arbiter becomes one flat namespace no policy filters. That choice is what makes this grant
-- smaller than it looks. `idempotency_sweep` called by `afpc_app` runs its DELETE under 0009's row
-- security, so it deletes the calling tenant's expired claims - which is 0011's own COMMENT
-- describing exactly this case: "a sweep by afpc_app collects that tenant's rows and a sweep by the
-- owner collects everything - which is the right split for a table whose whole job is per-tenant
-- request identity." The grant does not widen what one sweep can reach; it lets the tenant-scoped
-- half of a split 0011 already designed be executed by the role on that half's side of it.
--
-- And the rows in question are, by the function's own WHERE clause, ones whose retention has lapsed:
-- every deletion is of a claim that can no longer answer a replay. 0011's second sentence is still
-- true about the consequence. Only its first is superseded.
--
-- This file therefore does three things: grants the EXECUTE, replaces 0011's assertion with the
-- assertion that is true now (the closure was a decision, this one is too, and a decision a later
-- migration can quietly reverse is not a decision), and PROVES the reach claim below rather than
-- resting on the COMMENT. §3 is the reason to believe §1: two tenants, one expired claim each, the
-- agent role sweeping one of them, and a count on the other. If row security ever stopped filtering
-- this DELETE, §3 fails and this grant becomes the thing 0011 was guarding against - which is the
-- correct relationship between a privilege and the claim that justifies it.
--
-- What it does NOT do: it does not schedule anything outside the agent, does not touch the policy
-- (lease and retention stay 0011's columns and 0011's COMMENT), and does not give the runtime role a
-- DELETE on the table beyond what the function's own statement already needed - afpc_app has had
-- table-level DELETE since 0002, so what was missing was one function grant and nothing else, which
-- is measured in §2 rather than assumed.

-- ---------------------------------------------------------------------------
-- 1. The grant, and the two facts it rests on
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_bypass  boolean;
    v_forced  boolean;
    v_invoker boolean;
BEGIN
    IF to_regprocedure('idempotency_sweep(timestamptz)') IS NULL THEN
        RAISE EXCEPTION '0031 cannot run: idempotency_sweep is not installed, so 0011 has not been applied';
    END IF;

    -- The three assertions that make this grant the narrow thing the header argues it is. Each is a
    -- fact about 0011's or 0009's design, not about this file, and each is checked BEFORE the GRANT
    -- because a grant justified by a property that is not there is 0011's original objection with the
    -- paperwork in favour.
    SELECT rolbypassrls INTO v_bypass FROM pg_roles WHERE rolname = 'afpc_app';
    IF v_bypass IS NULL THEN
        RAISE EXCEPTION '0031 cannot run: there is no afpc_app role, so this server was not provisioned by scripts/db/roles.sql';
    END IF;
    IF v_bypass THEN
        RAISE EXCEPTION '0031 refuses to grant: afpc_app holds BYPASSRLS, so a sweep it calls would '
                        'collect EVERY tenant''s claims and the tenant-scoping this grant rests on is '
                        'not real. Fix the role first - granting under those conditions would make '
                        '0011''s objection the correct one again';
    END IF;

    SELECT relrowsecurity AND relforcerowsecurity INTO v_forced
      FROM pg_class WHERE oid = 'idempotency_keys'::regclass;
    IF NOT coalesce(v_forced, false) THEN
        RAISE EXCEPTION '0031 refuses to grant: idempotency_keys is not RLS-FORCED, so the DELETE '
                        'inside the sweep is not filtered per tenant and one agent''s tick would '
                        'collect the fleet''s history';
    END IF;

    -- By oid of the exact signature rather than by name: a name-only test would pass on a second
    -- overload, and 0016 is the record of what two heads on one door do.
    SELECT NOT p.prosecdef INTO v_invoker
      FROM pg_proc p WHERE p.oid = 'idempotency_sweep(timestamptz)'::regprocedure;
    IF NOT coalesce(v_invoker, false) THEN
        RAISE EXCEPTION '0031 refuses to grant: idempotency_sweep is SECURITY DEFINER, which would '
                        'make this grant an owner-privileged sweep callable by any agent - 0011 '
                        'rejected that design for the arbiter in its own header';
    END IF;

    GRANT EXECUTE ON FUNCTION idempotency_sweep(timestamptz) TO afpc_app;

    -- PUBLIC stays closed. 0011 revoked it from the cluster and B22 counts anything still open; this
    -- grant is to one named role, which is the difference between a capability and a default.
    REVOKE EXECUTE ON FUNCTION idempotency_sweep(timestamptz) FROM PUBLIC;

    IF NOT has_function_privilege('afpc_app', 'idempotency_sweep(timestamptz)', 'EXECUTE') THEN
        RAISE EXCEPTION '0031 failed: the GRANT ran and afpc_app still cannot execute the sweep - a '
                        'role membership problem rather than a privilege problem, and the keeper would '
                        'go on failing every hour exactly as it does now';
    END IF;
END
$$;

COMMENT ON FUNCTION idempotency_sweep(timestamptz) IS
    'Deletes idempotency_keys rows whose retention has lapsed and returns the count; the policy it '
    'enforces is stated on the table (5-minute lease, lease plus 24 hours retention). It runs as '
    'its invoker, so under 0009 row security a sweep by afpc_app collects that tenant''s rows and '
    'a sweep by the owner collects everything - which is the right split for a table whose whole '
    'job is per-tenant request identity. Expired-but-still-in_flight claims are left alone (they '
    'are unclaimed work, not history) and reported as a NOTICE. 0011 closed this to the runtime '
    'role while the only caller was a human with psql; 0031 opened it again for the scheduled '
    'keeper in agents/sales, on the grounds above, and asserts the tenant-scoping here rather than '
    'only in prose. Nothing in the schema schedules it: the keeper is a Go ticker, and a migration '
    'that invented one would be a second place for the retention policy to live.';

-- ---------------------------------------------------------------------------
-- 2. What was actually missing, so the diagnosis survives a fix
-- ---------------------------------------------------------------------------
-- One line, and it matters which way it reads: the runtime role has had table-level DELETE on
-- idempotency_keys since 0002, so this was never a grant that needed two. Recording that stops the
-- next person from "completing" the fix by widening the table's privileges too, which would be the
-- opposite of the narrow change above.
DO $$
BEGIN
    IF NOT has_table_privilege('afpc_app', 'idempotency_keys', 'DELETE') THEN
        RAISE EXCEPTION '0031 is incomplete: afpc_app cannot DELETE from idempotency_keys, so the '
                        'sweep would now fail on its statement instead of on its function grant - '
                        'the keeper would look fixed and still collect nothing';
    END IF;
    IF has_schema_privilege('afpc_readonly', 'public', 'USAGE') AND
       has_function_privilege('afpc_readonly', 'idempotency_sweep(timestamptz)', 'EXECUTE') THEN
        RAISE EXCEPTION '0031 over-reached: a read-only role can execute a function whose whole body '
                        'is a DELETE';
    END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- 3. The reach, measured: two tenants, one sweep, one survivor
-- ---------------------------------------------------------------------------
-- The fixture lives inside a subtransaction that is then discarded, including the second tenant, so
-- this migration commits a privilege and changes no row. 0030's probe pattern, and the verdict is
-- captured in a variable and asserted OUTSIDE the handler for 0030's stated reason - a handler that
-- swallows an exception also swallows an assertion.
DO $$
DECLARE
    v_t1      uuid := '00000000-0000-0000-0000-000000000001';
    v_t2      uuid;
    v_got       int;
    v_left      int;
    v_live_kept int;
    v_res       text := 'not-run';
BEGIN
    BEGIN
        INSERT INTO tenants (slug, name) VALUES ('0031-probe', '0031 reach probe')
            RETURNING tenant_id INTO v_t2;

        -- Written as the owner, which is the only way to plant a row in a tenant the caller is not
        -- currently bound to. Both are past retention; one tenant's and one other tenant's.
        INSERT INTO idempotency_keys (idempotency_key, tenant_id, operation, request_hash, status,
                                      lease_expires_at, expires_at)
        VALUES (gen_random_uuid(), v_t1, '0031:t1-expired', 'h', 'completed',
                now() - interval '3 days', now() - interval '2 days'),
               (gen_random_uuid(), v_t2, '0031:t2-expired', 'h', 'completed',
                now() - interval '3 days', now() - interval '2 days'),
               -- The case the sweep must NOT collect: the same tenant, unexpired, unfinished work.
               (gen_random_uuid(), v_t1, '0031:t1-live', 'h', 'in_flight',
                now() - interval '10 minutes', now() + interval '23 hours');

        -- The agent role, bound to its own tenant, running exactly what the hourly tick runs.
        EXECUTE 'SET LOCAL ROLE afpc_app';
        PERFORM set_config('app.tenant_id', v_t1::text, true);
        v_got := idempotency_sweep();
        EXECUTE 'RESET ROLE';

        SELECT count(*) INTO v_left  FROM idempotency_keys WHERE operation = '0031:t2-expired';
        SELECT count(*) INTO v_live_kept FROM idempotency_keys WHERE operation = '0031:t1-live';

        IF v_got < 1 THEN
            v_res := format('collected %s rows in its own tenant, where the fixture put one past '
                            'retention - the grant landed and the keeper still does not collect', v_got);
        ELSIF v_left <> 1 THEN
            v_res := 'collected ANOTHER tenant''s expired claim (t2 row count after the sweep: '
                     || v_left || ') - row security is not filtering this DELETE, which is the '
                     'premise the grant rests on and the exact reach 0011 closed the function against';
        ELSIF v_live_kept <> 1 THEN
            v_res := 'deleted an in_flight claim that was inside its retention, erasing evidence of '
                     'work nobody finished - 6_1 §F''s half of the same policy, reached from this side';
        ELSE
            v_res := 'pass';
        END IF;

        RAISE EXCEPTION 'discard' USING ERRCODE = 'P0002';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'discard' AND v_res = 'not-run' THEN
            v_res := 'raised ' || SQLSTATE || ': ' || left(SQLERRM, 200);
        END IF;
    END;

    IF v_res <> 'pass' THEN
        RAISE EXCEPTION '0031 §3 failed: %', v_res;
    END IF;

    -- The notice carries the numbers the probe actually measured, not a restatement of the design.
    -- They are still readable here because plpgsql variables survive the subtransaction that
    -- discarded the rows: the counts are of rows that no longer exist, which is exactly what a
    -- migration that changes privileges and no data should be reporting.
    RAISE NOTICE '0031 §3: the agent role''s sweep collected % expired claim(s) in its own tenant; '
                 'the second tenant''s expired claim (% row) and this tenant''s unexpired in_flight '
                 'claim (% row) are both intact.', v_got, v_left, v_live_kept;
END
$$;

-- ---------------------------------------------------------------------------
-- 4. The state this file leaves behind, asserted
-- ---------------------------------------------------------------------------
-- 0011 carried an apply-time assertion that afpc_app must NOT be able to execute this function. It
-- ran once, on the database as it was in July, and a migration cannot be edited after it is applied -
-- so the record of which rule is current has to live where a reader arrives looking for it, which is
-- the next file's subject and this section's. Both directions are checked: the keeper's grant
-- present, and the cluster-wide capability 0011 objected to still absent. A file that only asserted
-- the first would let a later "cleanup" that granted to PUBLIC pass as 0031 working as intended.
DO $$
BEGIN
    IF NOT has_function_privilege('afpc_app', 'idempotency_sweep(timestamptz)', 'EXECUTE') THEN
        RAISE EXCEPTION '0031 did not take: afpc_app cannot execute idempotency_sweep, and '
                        'agents/sales'' keeper will go on failing every hour';
    END IF;
    IF has_function_privilege('public', 'idempotency_sweep(timestamptz)', 'EXECUTE') THEN
        RAISE EXCEPTION 'idempotency_sweep is executable by PUBLIC - collection was 0011''s explicit '
                        'example of a capability that should not be ambient, and 0031 changed one '
                        'role''s access, not the cluster''s';
    END IF;
END
$$;
